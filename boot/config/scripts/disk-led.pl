#!/usr/bin/perl
#
# disk-led.pl - per-bay disk-activity LED engine for Asustor Lockerstor 6 Gen2 (AS6706T)
#
# Drives the six green front-bay LEDs directly through the GPIO *character device*
# (/dev/gpiochipN, exposed by the asustor_gpio_it87 driver) and emulates the kernel's
# "disk-activity" LED trigger in userspace by polling /proc/diskstats.
#
# It also repurposes the front-panel green *status* LED (it87_gp47) as a configurable status
# light - NVMe-activity flicker by default, or forced off / solid-on. It is driven through the
# same GPIO character device as the bay LEDs (a separate one-line request; GPIO offset 31 on
# the AS6706T). See docs/nvme-activity-led.md.
#
# Why this exists: Unraid's kernel is built WITHOUT CONFIG_LEDS_GPIO and the disk LED
# triggers (CONFIG_LEDS_TRIGGER_DISK / _BLKDEV), so the in-kernel path that lights these
# LEDs on other distros simply isn't present. There is also no gpioset (libgpiod), no
# python, and no C compiler in Unraid's base image. Perl *is* in the base image and can
# issue the GPIO uAPI ioctls via core Fcntl + pack/unpack - so it is the one dependency-
# free way to drive these lines. See docs/disk-leds.md ("Why Perl").
#
# Not meant to be run by hand - disk-led.sh sets the environment and manages it.
#
# Environment (set by disk-led.sh):
#   DL_OFFSETS      space-separated GPIO line offsets for bay1..bayN green LEDs
#   DL_INTERVAL_MS  activity poll interval in ms (default 100)
#   DL_CTL          override control file on tmpfs (bay -> on|off|locate)
#   DL_LOG          log file on tmpfs
#   DL_MODE         "sweep" = one-shot identify sweep then exit; otherwise run the daemon
#   DL_STATUS_LED    green status LED (gp47) mode: nvme = flicker on NVMe I/O (default),
#                    off = force dark, on = force solid
#   DL_STATUS_OFFSET GPIO chardev line offset of the status LED (default 31 = it87_gp47)
#   DL_NVME_REGEX    which /proc/diskstats devices count as NVMe (default = whole namespaces)
#   DL_RED_OFFSETS   space-separated GPIO offsets for bay1..bayN red/fault LEDs (active-low)
#   DL_FAULT_POLL_MS how often to re-read Unraid disk state for faults, in ms (default 15000)
#   DL_DISKS_INI     Unraid per-disk state file (default /var/local/emhttp/disks.ini)
#   DL_VAR_INI       Unraid array state file, for mdState (default /var/local/emhttp/var.ini)
#   DL_FAULT_3STATE  reserved: 1 = amber/3-state warnings (not implemented; 2-state only)
#
use strict;
use warnings;
use Fcntl qw(O_RDWR);

my @OFF  = split ' ', ($ENV{DL_OFFSETS} // '12 46 51 63 61 58');
my $N    = scalar @OFF;
my $IVAL = (($ENV{DL_INTERVAL_MS} // 100) + 0) / 1000;
my $CTL  = $ENV{DL_CTL} // '/dev/shm/disk-led.ctl';
my $LOG  = $ENV{DL_LOG};
my $MODE = $ENV{DL_MODE} // '';

# Red/fault LED config. The six bay red LEDs are active-LOW (raw 0 = lit). We drive them from
# Unraid's disk-fault state to mirror ADM's solid-red failed tray. See docs/disk-fault-leds.md.
my @ROFF         = split ' ', ($ENV{DL_RED_OFFSETS} // '13 47 52 48 62 60');
my $RN           = scalar @ROFF;
my $FAULT_MS     = ($ENV{DL_FAULT_POLL_MS} // 15000) + 0;
my $DISKS_INI    = $ENV{DL_DISKS_INI} // '/var/local/emhttp/disks.ini';
my $VAR_INI      = $ENV{DL_VAR_INI}   // '/var/local/emhttp/var.ini';
my $FAULT_3STATE = ($ENV{DL_FAULT_3STATE} // 0) + 0;   # reserved (amber); 2-state for now

# GPIO character-device uAPI (v2) ioctl request codes for x86_64. Computed from
# linux/gpio.h and validated live on this hardware.
#   GPIO_GET_CHIPINFO_IOCTL     _IOR (0xB4, 0x01, struct gpiochip_info[68])
#   GPIO_V2_GET_LINE_IOCTL      _IOWR(0xB4, 0x07, struct gpio_v2_line_request[592])
#   GPIO_V2_LINE_SET_VALUES_IOCTL _IOWR(0xB4, 0x0F, struct gpio_v2_line_values[16])
use constant {
    GPIO_GET_CHIPINFO  => 0x8044B401,
    GPIO_V2_GET_LINE   => 0xC250B407,
    GPIO_V2_SET_VALUES => 0xC010B40F,
    LINE_FLAG_OUTPUT   => 8,            # GPIO_V2_LINE_FLAG_OUTPUT (bit 3)
    LINE_FLAG_ACTIVE_LOW => 2,         # GPIO_V2_LINE_FLAG_ACTIVE_LOW (bit 1)
};

sub logmsg {
    return unless $LOG;
    open(my $f, '>>', $LOG) or return;
    my @t = localtime;
    printf $f "%04d-%02d-%02d %02d:%02d:%02d %s\n",
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0], $_[0];
    close $f;
}

# Find the asustor_gpio_it87 chip among /dev/gpiochip* by its chip NAME, rather than
# trusting a fixed gpiochip0 - robust to renumbering or extra gpiochips appearing.
# Retries for ~60s to ride out the boot race with the driver loading.
sub open_chip {
    for (1 .. 60) {
        for my $path (sort glob '/dev/gpiochip*') {
            sysopen(my $fh, $path, O_RDWR) or next;
            my $info = "\0" x 68;        # struct gpiochip_info { name[32]; label[32]; lines u32 }
            if (defined ioctl($fh, GPIO_GET_CHIPINFO, $info)) {
                my $name  = unpack('Z32', $info);
                my $label = unpack('Z32', substr($info, 32, 32));
                return ($fh, $path, $name) if $name =~ /it87/i || $label =~ /it87/i;
            }
            close $fh;
        }
        sleep 1;
    }
    return ();
}

my ($CHIP, $cpath, $cname) = open_chip();
defined $CHIP or do { logmsg("FATAL: no asustor_gpio_it87 gpiochip found"); die "no it87 gpiochip\n"; };

# Request the N green lines as outputs (default 0 = off). The returned line-request fd
# owns those lines for our lifetime; values latch until we change them or the fd closes
# (on exit), at which point the kernel releases the lines and the LEDs go dark.
my $req = pack('L64', @OFF, (0) x (64 - $N))
        . pack('a32', 'as6706-disk-led')
        . pack('Q', LINE_FLAG_OUTPUT) . pack('L', 0) . pack('L5', (0) x 5) . ("\0" x 240)
        . pack('L', $N) . pack('L', 0) . pack('L5', (0) x 5) . pack('l', 0);
defined ioctl($CHIP, GPIO_V2_GET_LINE, $req) or do { logmsg("FATAL: GET_LINE ioctl: $!"); die "GET_LINE: $!"; };
open(my $LINE, '+<&=', unpack('l', substr($req, 588, 4))) or die "fdopen line fd: $!";

my $ALL  = (1 << $N) - 1;
my $RALL = (1 << $RN) - 1;
# Set all managed lines at once. bits/mask are indexed by request position (bay i -> bit i-1).
sub set_bits { defined ioctl($LINE, GPIO_V2_SET_VALUES, pack('QQ', $_[0], $ALL)) or logmsg("SET_VALUES: $!"); }

# Status LED (it87_gp47) line-request fd for the NVMe-activity indicator, or undef when
# disabled/unavailable. It's driven through the GPIO chardev exactly like the bay LEDs - the
# IT87 honors this pin's data register (verified on hardware), so it gets true on/off flicker.
# A separate one-line request (not folded into the bay lines) keeps it out of the bay sweep.
# Resolved below, after the sweep short-circuit. See docs/nvme-activity-led.md.
my $SLINE;
sub sled_set { defined $SLINE and (ioctl($SLINE, GPIO_V2_SET_VALUES, pack('QQ', $_[0] ? 1 : 0, 1)) or logmsg("status SET_VALUES: $!")); }

# Fault (red) LED line-request fd, or undef when disabled/unavailable. Active-low (set via the
# uAPI ACTIVE_LOW flag, like the status LED), so logical 1 = lit and the code stays plain. A
# separate request keeps the active-low reds out of the active-high green bay request.
my $RLINE;
sub rled_set { defined $RLINE and (ioctl($RLINE, GPIO_V2_SET_VALUES, pack('QQ', $_[0], $RALL)) or logmsg("red SET_VALUES: $!")); }

$SIG{TERM} = $SIG{INT} = sub { eval { set_bits(0); sled_set(0); rled_set(0); }; exit 0; };

sub nap { select(undef, undef, undef, $_[0]); }

# One-shot identify sweep: all on, then step bay 1..N. Used by `disk-led.sh test` when the
# daemon is not running (it briefly owns the lines itself, then releases on exit).
if ($MODE eq 'sweep') {
    set_bits($ALL); nap(1.5); set_bits(0); nap(0.6);
    for my $i (0 .. $N - 1) { set_bits(1 << $i); nap(1.2); }
    set_bits(0);
    exit 0;
}

# Status LED (gp47) setup, skipped above for one-shot sweeps. Request the status-LED line as a
# second output and apply the chosen mode: 'off'/'on' set it once (the value latches while we
# hold the line); 'nvme' (default) starts it dark and is then driven per-tick from aggregate
# NVMe activity in the main loop. On failure, log once and leave $SLINE undef - the bay LEDs are
# unaffected. (The chip's hardware blink for this LED is disabled in boot/config/go, so it can't
# override our data-register control.)
my $nvme_re  = $ENV{DL_NVME_REGEX} // '^nvme[0-9]+n[0-9]+$';
my $NVME_RE  = qr/$nvme_re/;
my $LED_MODE = lc($ENV{DL_STATUS_LED} // 'nvme');
$LED_MODE = 'nvme' unless $LED_MODE eq 'off' || $LED_MODE eq 'on';   # any unknown value -> default
{
    my $soff = ($ENV{DL_STATUS_OFFSET} // 31) + 0;
    # gp47 is ACTIVE-LOW (lights when the pin is driven low - same as the red bay LEDs, and
    # verified on hardware), so set the uAPI ACTIVE_LOW flag. The kernel then inverts for us:
    # logical 1 = on (pin low), logical 0 = off (pin high) - so the rest of the code stays plain.
    my $sreq = pack('L64', $soff, (0) x 63)
             . pack('a32', 'as6706-status-led')
             . pack('Q', LINE_FLAG_OUTPUT | LINE_FLAG_ACTIVE_LOW) . pack('L', 0) . pack('L5', (0) x 5) . ("\0" x 240)
             . pack('L', 1) . pack('L', 0) . pack('L5', (0) x 5) . pack('l', 0);
    if (defined ioctl($CHIP, GPIO_V2_GET_LINE, $sreq)
            and open($SLINE, '+<&=', unpack('l', substr($sreq, 588, 4)))) {
        if    ($LED_MODE eq 'off') { sled_set(0); logmsg("status LED: forced OFF (gp offset $soff)"); }
        elsif ($LED_MODE eq 'on')  { sled_set(1); logmsg("status LED: forced ON (gp offset $soff)"); }
        else                       { sled_set(0); logmsg("status LED: NVMe-activity mode (gp offset $soff)"); }  # start dark
    } else {
        logmsg("status LED: GET_LINE offset $soff failed ($!) - disabled");
        undef $SLINE;
    }
}

# Fault (red) LED setup, skipped above for one-shot sweeps. Request the six red lines as a single
# active-low output group (raw 0 = lit) and start them dark. On failure, log once and leave $RLINE
# undef - the green bays and status LED are unaffected, and fault indication is simply disabled.
{
    my $rreq = pack('L64', @ROFF, (0) x (64 - $RN))
             . pack('a32', 'as6706-fault-led')
             . pack('Q', LINE_FLAG_OUTPUT | LINE_FLAG_ACTIVE_LOW) . pack('L', 0) . pack('L5', (0) x 5) . ("\0" x 240)
             . pack('L', $RN) . pack('L', 0) . pack('L5', (0) x 5) . pack('l', 0);
    if (defined ioctl($CHIP, GPIO_V2_GET_LINE, $rreq)
            and open($RLINE, '+<&=', unpack('l', substr($rreq, 588, 4)))) {
        rled_set(0);   # all reds off to start
        logmsg("fault LEDs: offsets @ROFF (active-low) ready");
        logmsg("fault LEDs: 3-state requested but not implemented - using 2-state") if $FAULT_3STATE;
    } else {
        logmsg("fault LEDs: GET_LINE failed ($!) - red/fault indication disabled");
        undef $RLINE;
    }
}

# bay (1..N) -> block device (sdX), resolved by SATA/ata port. A front bay is physically
# wired to an ata port, so bay i maps to ata i; we then look up whichever sdX currently
# sits on that port. Keyed on the ata number (not the drive letter) so it survives sd*
# renumbering and hotplug. Re-resolved periodically.
sub resolve_map {
    my %m;
    for my $p (glob '/sys/block/sd*') {
        my $name = (split m{/}, $p)[-1];
        my $tgt  = readlink($p) // next;
        $m{$1} = $name if $tgt =~ m{/ata(\d+)/};
    }
    return %m;   # ata-number => sdX
}

# device => completed-I/O count (reads + writes). Reading /proc/diskstats only touches
# in-kernel counters, so it NEVER wakes a spun-down disk and adds no disk I/O.
sub read_act {
    my %a;
    open(my $f, '<', '/proc/diskstats') or return %a;
    while (<$f>) { my @F = split; next unless @F >= 8; $a{$F[2]} = $F[3] + $F[7]; }
    close $f;
    return %a;
}

# override map: bay => on|off|locate (absent bay => normal activity mode). tmpfs file,
# re-read every tick (cheap), so disk-led.sh can change behavior without restarting us.
sub read_ctl {
    my %o;
    if (open(my $f, '<', $CTL)) {
        while (<$f>) { my ($b, $mode) = split; $o{$b} = $mode if defined $mode; }
        close $f;
    }
    return %o;
}

# Per-bay fault state from Unraid's emhttp files (disks.ini + var.ini). Refreshed on a slow
# cadence - faults change slowly, and these are small tmpfs files, so this never touches the
# disks and stays spin-down safe. A bay is faulted iff its disk's `color` is red-* (Unraid's
# DISK_DSBL / red-X disabled drive). Gated on mdState=STARTED: a stopped array reports parity as
# DISK_INVALID/yellow-on, which is NOT a fault. Returns a 1-based array ($f[bay] = 0|1). This is
# the strict 2-state ADM model - yellow/warning states are intentionally not surfaced here.
sub poll_faults {
    my $mref = shift;                       # ata-number => sdX
    my @f = (0) x ($RN + 1);                # 1-based by bay; [0] unused
    open(my $v, '<', $VAR_INI) or return @f;
    my $started = 0;
    while (<$v>) { if (/^mdState\s*=\s*"?([^"\r\n]+)"?/) { $started = ($1 eq 'STARTED'); last; } }
    close $v;
    return @f unless $started;              # array stopped -> nothing is a fault

    my %color;                              # sdX => color (e.g. "red-on")
    if (open(my $d, '<', $DISKS_INI)) {
        my ($dev, $col, $st);
        my $flush = sub {
            return if !defined $dev || $dev eq '' || !defined $col;
            return if defined $st && $st =~ /_NP$/;     # skip missing/not-present slots
            $color{$dev} = $col;
        };
        while (<$d>) {
            if (/^\[/) { $flush->(); ($dev, $col, $st) = (undef, undef, undef); next; }
            if    (/^device\s*=\s*"?([^"\r\n]*)"?/) { ($dev = $1) =~ s{^/dev/}{}; }
            elsif (/^color\s*=\s*"?([^"\r\n]*)"?/)  { $col = $1; }
            elsif (/^status\s*=\s*"?([^"\r\n]*)"?/) { $st  = $1; }
        }
        $flush->();
        close $d;
    }
    for my $i (1 .. $RN) {
        my $sd = $mref->{$i} // next;
        my $c  = $color{$sd} // next;
        $f[$i] = 1 if (split /-/, $c)[0] eq 'red';
    }
    return @f;
}

logmsg("started: chip=$cpath ($cname) bays=$N interval=" . int($IVAL * 1000) . "ms");
my %prev       = read_act();
my %map        = ();
my $mapsig     = '';
my $resolve_in = 0;
my $tick       = 0;
my $nvme_prev  = 0; $nvme_prev += $prev{$_} for grep { $_ =~ $NVME_RE } keys %prev;  # baseline NVMe I/O count
my $sled_on    = -1;                                                                 # -1 => force first write
my @fault       = (0) x ($RN + 1);                          # 1-based per-bay fault state (slow poll)
my $fault_in    = 0;                                        # ticks until next fault poll (0 => now)
my $FAULT_TICKS = int($FAULT_MS / ($IVAL * 1000)) || 1;     # activity ticks per fault poll
my $red_bits    = -1;                                       # last red bitmask written (-1 => force)

while (1) {
    if ($resolve_in <= 0) {
        %map = resolve_map();
        my $sig = join(',', map { "$_=" . ($map{$_} // '-') } 1 .. $N);
        if ($sig ne $mapsig) { logmsg("bay map: $sig"); $mapsig = $sig; }
        $resolve_in = 50;                       # re-resolve ~every 5s (50 * 100ms)
    }
    $resolve_in--;

    # Refresh per-bay fault state on the slow cadence (cheap file reads, no disk I/O). The red
    # lines themselves are written every tick below, so manual red-tests stay responsive.
    if ($RLINE && $fault_in <= 0) {
        @fault = poll_faults(\%map);
        $fault_in = $FAULT_TICKS;
    }
    $fault_in--;

    my %act = read_act();
    my %ovr = read_ctl();
    my $bits  = 0;     # green (active-high) bitmask
    my $rbits = 0;     # red   (active-low, logical 1 = lit) bitmask
    for my $i (1 .. $N) {
        my $mode   = $ovr{$i};
        my $red_on = $fault[$i] || (defined $mode && $mode eq 'red');   # disk fault or manual red-test
        my $on     = 0;
        if    ($red_on)                            { $on = 0; }         # faulted bay: red only, green off
        elsif (defined $mode && $mode eq 'on')     { $on = 1; }
        elsif (defined $mode && $mode eq 'off')    { $on = 0; }
        elsif (defined $mode && $mode eq 'locate') { $on = (($tick % 4) < 2) ? 1 : 0; }  # ~2.5 Hz blink
        else {
            my $d = $map{$i};
            if (defined $d) { my $c = $act{$d} // 0; $on = ($c != ($prev{$d} // $c)) ? 1 : 0; }
        }
        $bits  |= (1 << ($i - 1)) if $on;
        $rbits |= (1 << ($i - 1)) if $red_on;
    }
    set_bits($bits);
    if ($RLINE && $rbits != $red_bits) {
        rled_set($rbits); $red_bits = $rbits;
        logmsg("red LEDs: bays=" . (join(',', grep { $rbits & (1 << ($_ - 1)) } 1 .. $N) || 'none'));
    }

    # NVMe activity -> status LED (nvme mode only; off/on were set once at startup). One LED for
    # several drives, so aggregate: on when ANY nvme namespace's counter moved since last tick.
    # Write only on change (a quiet pool issues no writes; a busy one writes at most twice/edge).
    if (defined $SLINE && $LED_MODE eq 'nvme') {
        my $sum = 0; $sum += $act{$_} for grep { $_ =~ $NVME_RE } keys %act;
        my $on  = ($sum != $nvme_prev) ? 1 : 0;
        if ($on != $sled_on) { sled_set($on); $sled_on = $on; }
        $nvme_prev = $sum;
    }

    %prev = %act;
    $tick++;
    nap($IVAL);
}
