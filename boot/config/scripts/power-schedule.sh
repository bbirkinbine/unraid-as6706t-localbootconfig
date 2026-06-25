#!/bin/bash
#
# power-schedule.sh - RTC self-wake + scheduled power-off engine for Unraid on
#                     Asustor hardware (developed on a Lockerstor 6 Gen2 / AS6706T).
#
# WHAT IT'S FOR
#   Let a NAS that only needs to be awake for part of the day power itself OFF
#   when idle and WAKE ITSELF back up later via the motherboard's RTC alarm -
#   always re-arming the next wake BEFORE shutting down so it can never strand
#   itself (important for an offsite/secondary box you can't walk over to).
#
#   This file is the *mechanism*. It ships INERT and generic: out of the box it
#   does nothing (ENABLED=0, POWEROFF_MODE=none). Your site-specific schedule
#   lives in an external config so a clone of this public repo never powers
#   anyone's box off by surprise. See docs/power-schedule.md for the full guide,
#   how it was tested, and a worked example (this repo's secondary Unraid NAS).
#
# HOW THE WAKE WORKS
#   The board's CMOS RTC fires a hardware power-on (even from full soft-off / S5)
#   when the alarm at /sys/class/rtc/rtc0/wakealarm (an epoch, UTC-based) is hit.
#   Verify your own hardware first with:  power-schedule.sh test-wake 300
#   (arms a wake 5 min out and powers off; the box should return on its own).
#
# CONFIG
#   Defaults below are conservative. Override them in:  /boot/config/power-schedule.conf
#   (copy boot/config/scripts/power-schedule.conf.example and edit). That file is
#   sourced over these defaults, kept off the box's flash backup of the repo, and
#   is where you set ENABLED=1 once you've tested.
#
# Usage:
#   power-schedule.sh start|stop|restart|reload|status|run   # reload = restart (applies conf edits)
#   power-schedule.sh arm [HHMM]      # manually (re)arm next wake (default: next of WAKE_TIMES)
#   power-schedule.sh off             # arm next wake + power off NOW (manual "go back to sleep")
#   power-schedule.sh test-wake [sec] [yes]  # POWERS OFF now, must self-wake in [sec] (default 300).
#                                            # Prompts for confirmation; pass 'yes' to skip. Don't run
#                                            # on a remote box you can't physically power on.
#
# --------------------------------------------------------------------------------------
# DEFAULTS  (override in /boot/config/power-schedule.conf - do NOT edit per-site values here)
# --------------------------------------------------------------------------------------
ENABLED=0                 # 0 = inert: `start` refuses. Set 1 in the conf once configured + tested.
DRY_RUN=1                 # 1 = observe only: log "WOULD power off" but stay up. 0 = real shutdowns.

# -- Wake (power ON) ---------------------------------------------------------
WAKE_TIMES=""             # space-separated local HHMM list; the soonest upcoming one is armed.
                          #   e.g. "2345"  or  "0145 1330" for two windows a day. Empty = manage no wake.
WAKE_EXTERNAL=0           # 1 = something else wakes the box (WoL, BIOS power-on schedule). Lets the
                          #   box power off even with WAKE_TIMES empty. (With both unset it REFUSES to
                          #   power off, so it can't strand itself.)

# -- Power OFF ---------------------------------------------------------------
POWEROFF_MODE=none        # none  = never auto power off (default; e.g. another host calls `off`)
                          # idle  = after STAY_UP_UNTIL, off once idle for IDLE_SHUTDOWN_MIN minutes
                          # fixed = at POWEROFF_AT, off (waits out an active transfer unless FIXED_FORCE=1)
STAY_UP_UNTIL="0300"      # [idle]  earliest local time a shutdown may happen
IDLE_SHUTDOWN_MIN=30      # [idle]  idle minutes (past STAY_UP_UNTIL) before powering off
POWEROFF_AT="0500"        # [fixed] local time to power off
FIXED_FORCE=0             # [fixed] 1 = power off at POWEROFF_AT even mid-transfer (default: wait for idle)

# -- "Busy" detection (idle mode, and fixed mode's wait-for-idle) ------------
THRESH_KBPS=100           # data-NIC rx+tx below this (KB/s) counts as idle. Tune ABOVE idle chatter,
                          #   BELOW a real transfer (slow WAN backups can be only a few hundred KB/s).
DISK_THRESH_KBPS=2000     # array+cache disk read+write below this (KB/s) counts as idle. Catches LOCAL
                          #   work that has NO network: a `cp`/`tar`/`dd` an admin is running, appdata/VM
                          #   backups, etc. (mover/parity/scrub are also named explicitly below). Real
                          #   storage work runs at tens of MB/s; tune ABOVE idle chatter. 0 = disable.
BUSY_PORTS="445 873 2049" # established connections on these LOCAL ports = client attached: SMB / rsync
                          #   daemon / NFS. (rsync-over-ssh is caught by the rsync process check; add 22
                          #   here if you want ANY ssh connection - incl. SFTP/SCP - to hold the box up.)
LOOP_SECS=60              # watchdog tick
IFACE=""                  # data interface; empty = autodetect the default-route iface (usually br0)
ARM_GUARD_MIN=10          # refuse to arm a wake less than this many minutes out (sanity check)

CONF=/boot/config/power-schedule.conf
[ -r "$CONF" ] && . "$CONF"     # site overrides win over the defaults above

RTC=/sys/class/rtc/rtc0/wakealarm
PIDFILE=/var/run/power-schedule.pid
LOGFILE=/var/log/power-schedule.log          # /var/log is tmpfs (RAM) on Unraid - no USB-flash wear
STATEF=/dev/shm/power-schedule.state         # live watchdog state for `status` (tmpfs)
RUNCFG=/dev/shm/power-schedule.running       # config the running daemon loaded - lets status flag edits
BREADCRUMB=/boot/config/power-schedule.last   # one line per shutdown on USB (survives poweroff)

# --------------------------------------------------------------------------------------
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }
fmt() { date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null; }

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

# Shutdown is inhibited while either flag exists (manual "keep it awake").
inhibited() { [ -e /boot/config/power-schedule.disable ] || [ -e /dev/shm/power-schedule.keepawake ]; }

# Canonicalize an HH:MM-ish value to "HHMM" (echoed), or return 1 if it isn't a real 24h time.
# Accepts 2345, 23:45, 9:45 (-> 0945), with stray spaces; rejects junk and out-of-range values.
# Note: a BARE 3-digit value (945) is rejected as ambiguous - write 0945 or 9:45.
norm_hhmm() {
  local v="${1//[[:space:]]/}" h m
  case "$v" in
    '')   return 1 ;;
    *:*)  h=${v%%:*}; m=${v##*:} ;;                              # colon form: hour:minute
    *)    [ ${#v} -eq 4 ] || return 1; h=${v:0:2}; m=${v:2:2} ;; # bare form: must be 4 digits
  esac
  case "$h" in ''|*[!0-9]*) return 1 ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  h=$((10#$h)); m=$((10#$m))
  { [ "$h" -le 23 ] && [ "$m" -le 59 ]; } || return 1
  printf '%02d%02d' "$h" "$m"
}

# Validate + canonicalize the configured times ONCE (after the conf is sourced). Rewrites
# WAKE_TIMES / STAY_UP_UNTIL / POWEROFF_AT to canonical HHMM, records anything it had to fix in
# TIME_FIXED, and anything it can't parse in TIME_ERRORS. Callers refuse to act when TIME_ERRORS
# is set, so a typo'd time fails loudly at start instead of silently mis-scheduling.
TIME_ERRORS=""; TIME_FIXED=""
validate_times() {
  local var raw t n out
  if [ -n "$WAKE_TIMES" ]; then
    out=""
    for t in $WAKE_TIMES; do
      if n=$(norm_hhmm "$t"); then
        out="$out $n"; [ "$n" != "$t" ] && TIME_FIXED="$TIME_FIXED WAKE_TIMES:'$t'->$n"
      else TIME_ERRORS="$TIME_ERRORS WAKE_TIMES='$t'"; fi
    done
    WAKE_TIMES="${out# }"
  fi
  for var in STAY_UP_UNTIL POWEROFF_AT; do
    raw=${!var}
    if n=$(norm_hhmm "$raw"); then
      [ "$n" != "$raw" ] && TIME_FIXED="$TIME_FIXED $var:'$raw'->$n"; printf -v "$var" '%s' "$n"
    else TIME_ERRORS="$TIME_ERRORS $var='$raw'"; fi
  done
}

# Signature of the behaviourally-significant config. The daemon writes this at startup (RUNCFG);
# status compares it against the current on-disk values to show a "restart to apply" hint.
config_sig() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
    "$ENABLED" "$DRY_RUN" "$WAKE_TIMES" "$WAKE_EXTERNAL" "$POWEROFF_MODE" \
    "$STAY_UP_UNTIL" "$IDLE_SHUTDOWN_MIN" "$POWEROFF_AT" "$FIXED_FORCE" "$THRESH_KBPS" "$DISK_THRESH_KBPS"
}

# Epoch of the next local HH:MM strictly in the future (today's, or tomorrow's if already passed).
# Input is canonicalized first, so callers may pass "2345" or "23:45". GNU date does the rest.
next_epoch() {
  local hhmm H M t now
  hhmm=$(norm_hhmm "$1") || return 1
  H=${hhmm:0:2} M=${hhmm:2:2}
  t=$(date -d "$H:$M" +%s 2>/dev/null) || return 1
  now=$(date +%s)
  [ "$t" -le "$((now + 60))" ] && t=$(date -d "$H:$M tomorrow" +%s 2>/dev/null)
  echo "$t"
}

# Soonest upcoming epoch among WAKE_TIMES (empty output if WAKE_TIMES is unset).
compute_next_wake() {
  local hhmm t best=""
  for hhmm in $WAKE_TIMES; do
    t=$(next_epoch "$hhmm") || continue
    { [ -z "$best" ] || [ "$t" -lt "$best" ]; } && best=$t
  done
  [ -n "$best" ] && echo "$best"
}

# Auto-detect the data interface (default-route iface), else first of br0/bond0/eth0.
detect_iface() {
  [ -n "$IFACE" ] && { echo "$IFACE"; return; }
  local i c
  i=$(ip route show default 2>/dev/null | awk '{for(j=1;j<=NF;j++) if($j=="dev"){print $(j+1); exit}}')
  [ -z "$i" ] && for c in br0 bond0 eth0; do [ -e "/sys/class/net/$c" ] && { i=$c; break; }; done
  echo "$i"
}

# Write + VERIFY a specific wake epoch. Returns 0 only if the RTC reads it back and alarm_IRQ=yes.
arm_epoch() {
  local target=$1 now rb irq
  now=$(date +%s)
  if [ "$target" -lt "$((now + ARM_GUARD_MIN*60))" ]; then
    log "arm: refusing target $(fmt "$target") - under ${ARM_GUARD_MIN}m out"; return 1
  fi
  [ -w "$RTC" ] || { log "arm: $RTC not writable"; return 1; }
  echo 0 > "$RTC" 2>/dev/null                 # clear any stale alarm first
  echo "$target" > "$RTC" 2>/dev/null
  rb=$(cat "$RTC" 2>/dev/null)
  irq=$(awk '/alarm_IRQ/{print $3}' /proc/driver/rtc 2>/dev/null)
  if [ "$rb" = "$target" ] && [ "$irq" = yes ]; then
    log "arm: wake set for $(fmt "$target") (epoch $target)"; return 0
  fi
  log "arm: VERIFY FAILED (wanted $target, readback '$rb', alarm_IRQ '$irq')"; return 1
}

# Arm the next scheduled wake. Echoes the target epoch on success. Optional arg = one-off HHMM.
arm_next_wake() {
  local target
  if [ -n "$1" ]; then target=$(next_epoch "$1"); else target=$(compute_next_wake); fi
  [ -n "$target" ] || { log "arm: no WAKE_TIMES configured"; return 1; }
  arm_epoch "$target" && echo "$target"
}

# Total sectors (read + written) across the real array + cache block devices, from /proc/diskstats.
# Whole-disk lines only (sdX / nvmeXnY) - skip partitions and md* so we don't double-count; x512 = bytes.
disk_sectors() {
  awk '$3 ~ /^(sd[a-z]+|nvme[0-9]+n[0-9]+)$/ {s += $6 + $10} END {print s+0}' /proc/diskstats 2>/dev/null
}

# Echo space-separated reasons the box is "busy" right now (empty = idle).
# Arg 1 = NIC KB/s this tick; arg 2 = array+cache disk KB/s this tick.
is_busy() {
  local kbps=$1 dkbps=$2 r="" p cnt md m
  who 2>/dev/null | grep -q . && r="$r login"            # an interactive login = admin present
  for p in $BUSY_PORTS; do                               # a storage client attached?
    cnt=$(ss -Htn state established "sport = :$p" 2>/dev/null | grep -c .)
    [ "${cnt:-0}" -gt 0 ] && r="$r $p:$cnt"
  done
  pgrep -x rsync  >/dev/null 2>&1 && r="$r rsync"         # rsync server (rsync-over-ssh or daemon)
  pgrep -x rclone >/dev/null 2>&1 && r="$r rclone"
  pgrep -x sftp-server >/dev/null 2>&1 && r="$r sftp"    # SFTP subsystem = an admin/file-transfer session
  pgrep -x scp         >/dev/null 2>&1 && r="$r scp"     # scp server side (old protocol; new scp = sftp)
  # Unraid Mover (cache<->array) is local disk I/O - zero net traffic, no client port, and runs as the
  # compiled 'move' binary, NOT rsync - so it's invisible to every check above. Its pidfile exists for
  # the whole run (stock mover + ca.mover.tuning both use it); gate on a live pid so a stale one (mover
  # killed mid-run) can't pin the box up forever.
  { [ -f /var/run/mover.pid ] && kill -0 "$(cat /var/run/mover.pid 2>/dev/null)" 2>/dev/null; } && r="$r mover"
  # A parity check / disk rebuild / clear is md-resync I/O: also purely local (no net, no client port)
  # and FAR costlier to interrupt than a mover. mdResync>0 while such an op is active (running OR paused);
  # mdResyncAction names which ("check P Q", "recon P", "clear", ...). mdResyncAction is stale when idle,
  # so gate on mdResync, not the action.
  md=$(/usr/local/sbin/mdcmd status 2>/dev/null)
  if [ "$(awk -F= '/^mdResync=/{print $2}' <<<"$md")" -gt 0 ] 2>/dev/null; then
    r="$r resync:$(awk -F= '/^mdResyncAction=/{print $2}' <<<"$md" | tr ' ' '_')"
  fi
  # A btrfs/zfs scrub is local read I/O with no network - same risk class as parity. (A throttled scrub
  # can dip below DISK_THRESH_KBPS, so name it explicitly rather than rely only on the disk net below.)
  for m in $(findmnt -nrt btrfs -o TARGET 2>/dev/null | grep '^/mnt/'); do
    btrfs scrub status "$m" 2>/dev/null | grep -qiE 'status:[[:space:]]*running' && { r="$r scrub"; break; }
  done
  case "$r" in *scrub*) : ;; *) zpool status 2>/dev/null | grep -q 'scrub in progress' && r="$r scrub" ;; esac
  # Network catch-all: any active transfer of ANY protocol (FTP, SFTP, WebDAV, iSCSI...) shows up here.
  [ "${kbps:-0}" -ge "$THRESH_KBPS" ] && r="$r net:${kbps}KB/s"
  # Disk catch-all: any local-disk work with no network (admin cp/tar/dd, appdata/VM backup) shows here.
  [ "${DISK_THRESH_KBPS:-0}" -gt 0 ] && [ "${dkbps:-0}" -ge "$DISK_THRESH_KBPS" ] && r="$r disk:${dkbps}KB/s"
  echo "${r# }"
}

# Ensure a future wake exists (or an external one is asserted), then power off. With arg "force"
# it ignores DRY_RUN. If no wake can be guaranteed it ABORTS - never strand the box.
do_scheduled_poweroff() {
  local force=$1 target rec wake
  if [ -n "$WAKE_TIMES" ]; then
    target=$(arm_next_wake) || {
      log "SHUTDOWN ABORTED: could not arm next wake - staying ON to avoid stranding the box"; return 1; }
    wake="next wake $(fmt "$target")"
  elif [ "$WAKE_EXTERNAL" = 1 ]; then
    wake="wake is EXTERNAL (WoL/BIOS) - not arming RTC"
    log "$wake"
  else
    log "SHUTDOWN ABORTED: no wake configured (WAKE_TIMES empty, WAKE_EXTERNAL=0) - would strand the box"
    return 1
  fi
  rec="$(date '+%Y-%m-%d %H:%M:%S') poweroff; $wake"
  echo "$rec" >> "$BREADCRUMB" 2>/dev/null    # persistent breadcrumb on USB (once/day = negligible wear)
  logger -t power-schedule "$rec"
  if [ "$DRY_RUN" = 1 ] && [ "$force" != force ]; then
    log "DRY_RUN: WOULD power off now ($wake). Set DRY_RUN=0 in $CONF to enable."
    return 0
  fi
  log "$rec"
  sync
  poweroff
}

run_loop() {
  trap 'log "watchdog stopping"; rm -f "$RUNCFG"; exit 0' TERM INT
  [ -n "$TIME_ERRORS" ] && { log "FATAL: invalid time config:$TIME_ERRORS"; exit 1; }
  config_sig > "$RUNCFG" 2>/dev/null    # record the config we loaded, so status can flag later edits
  local iface; iface=$(detect_iface)
  [ -z "$iface" ] && { log "FATAL: no data interface found"; exit 1; }
  local rxf=/sys/class/net/$iface/statistics/rx_bytes
  local txf=/sys/class/net/$iface/statistics/tx_bytes

  # Floor = the daily time the shutdown window opens (idle: STAY_UP_UNTIL; fixed: POWEROFF_AT).
  local floor_time="$STAY_UP_UNTIL"; [ "$POWEROFF_MODE" = fixed ] && floor_time="$POWEROFF_AT"
  local floor; floor=$(next_epoch "$floor_time")
  log "watchdog up: mode=$POWEROFF_MODE iface=$iface wake='${WAKE_TIMES:-none}' floor=$floor_time (next $(fmt "$floor")) idle=${IDLE_SHUTDOWN_MIN}m thresh=${THRESH_KBPS}KB/s dry_run=$DRY_RUN"

  local prx ptx pt rx tx now dt db kbps idle=0 reason fire a pdsk dsk ddb dkbps
  prx=$(cat "$rxf" 2>/dev/null || echo 0); ptx=$(cat "$txf" 2>/dev/null || echo 0); pt=$(date +%s)
  pdsk=$(disk_sectors)
  while sleep "$LOOP_SECS"; do
    now=$(date +%s)

    # Keep a future wake armed at ALL times - not just right before the scheduled shutdown - so a
    # MANUAL power-off (Unraid GUI, `poweroff`, the power button) also brings the box back, and not
    # only the scheduled one. The RTC alarm is one-shot: it's consumed when it fires while we're
    # still up, so re-arm as soon as it reads spent/missing. (No-op when wake is external.)
    if [ -n "$WAKE_TIMES" ]; then
      a=$(cat "$RTC" 2>/dev/null)
      { [ -z "$a" ] || [ "$a" = 0 ] || [ "$a" -le "$now" ] 2>/dev/null; } && arm_next_wake >/dev/null
    fi

    rx=$(cat "$rxf" 2>/dev/null || echo "$prx"); tx=$(cat "$txf" 2>/dev/null || echo "$ptx")
    dt=$((now - pt)); [ "$dt" -lt 1 ] && dt=1
    db=$(( (rx - prx) + (tx - ptx) )); [ "$db" -lt 0 ] && db=0     # guard counter wrap/reset
    kbps=$(( db / dt / 1024 ))
    dsk=$(disk_sectors); ddb=$(( dsk - pdsk )); [ "$ddb" -lt 0 ] && ddb=0   # guard reboot/counter reset
    dkbps=$(( ddb * 512 / dt / 1024 ))
    prx=$rx; ptx=$tx; pt=$now; pdsk=$dsk

    reason=$(is_busy "$kbps" "$dkbps")
    if [ -n "$reason" ]; then idle=0; else idle=$((idle + LOOP_SECS)); fi

    printf 'ts=%s mode=%s armed=%s floor=%s idle_s=%s kbps=%s dkbps=%s busy=%s\n' \
      "$now" "$POWEROFF_MODE" "$(cat "$RTC" 2>/dev/null)" "$floor" "$idle" "$kbps" "$dkbps" "${reason:-none}" \
      > "$STATEF" 2>/dev/null

    fire=0
    case "$POWEROFF_MODE" in
      idle)  [ "$now" -ge "$floor" ] && [ "$idle" -ge "$((IDLE_SHUTDOWN_MIN*60))" ] && fire=1 ;;
      fixed) if [ "$now" -ge "$floor" ]; then
               { [ "$FIXED_FORCE" = 1 ] || [ -z "$reason" ]; } && fire=1
             fi ;;
      none)  : ;;
    esac

    if [ "$fire" = 1 ]; then
      if inhibited; then
        log "would power off (mode=$POWEROFF_MODE) but INHIBITED (keepawake/disable flag) - staying up"
      else
        log "shutdown condition met (mode=$POWEROFF_MODE, idle=${idle}s, past $(fmt "$floor")) -> sequence"
        do_scheduled_poweroff
      fi
      # Only reached if we did NOT power off (dry-run/inhibited/abort): cool down + re-pin to next day.
      idle=0; floor=$(next_epoch "$floor_time")
      log "still up; next floor $(fmt "$floor")"
    fi
  done
}

validate_times    # canonicalize/validate the configured times before dispatching any subcommand

case "$1" in
  run) run_loop ;;

  start)
    if [ -n "$TIME_ERRORS" ]; then
      echo "CONFIG ERROR - invalid time value(s):$TIME_ERRORS"
      echo "  Use 24-hour HHMM, e.g. 2345 (11:45 PM) or 0905 (9:05 AM). 'HH:MM' like 23:45 is fine too."
      log "start refused: invalid time config:$TIME_ERRORS"; exit 1
    fi
    [ -n "$TIME_FIXED" ] && { echo "note   : normalized time(s):$TIME_FIXED"; log "normalized:$TIME_FIXED"; }
    is_running && { echo "already running (pid $(cat "$PIDFILE"))"; exit 0; }
    if [ "$ENABLED" != 1 ]; then
      echo "power-schedule is DISABLED (ENABLED=0)."
      echo "Configure $CONF (see power-schedule.conf.example) and set ENABLED=1 to use it."
      log "start refused: ENABLED=0"
      exit 0
    fi
    if [ "$POWEROFF_MODE" = none ] && [ -z "$WAKE_TIMES" ]; then
      echo "nothing to do: POWEROFF_MODE=none and no WAKE_TIMES. Set them in $CONF."
      log "start: nothing to do (mode=none, no wake)"
      exit 0
    fi
    # Defensive: guarantee a future wake exists even if we never reach a clean shutdown
    # (manual reboot, crash, power restored after an outage).
    [ -n "$WAKE_TIMES" ] && { arm_next_wake >/dev/null || log "WARNING: boot-time wake arm failed"; }
    setsid "$0" run >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    if is_running; then
      echo "started (pid $(cat "$PIDFILE"))"
      echo "note   : wake/off times are LOCAL time - right now it is $(date '+%a %Y-%m-%d %H:%M %Z')."
      echo "         If that isn't your local time, fix Unraid -> Settings -> Date and Time, then restart."
    else echo "failed - see $LOGFILE"; exit 1; fi
    ;;

  stop)
    if is_running; then
      kill -TERM "$(cat "$PIDFILE")" 2>/dev/null
      for _ in 1 2 3 4 5; do is_running || break; sleep 1; done
      kill -9 "$(cat "$PIDFILE")" 2>/dev/null
      rm -f "$PIDFILE"; echo "stopped"
    else echo "not running"; fi
    ;;

  restart|reload) "$0" stop; sleep 1; "$0" start ;;   # reload = restart; applies config edits

  status)
    is_running && echo "daemon : RUNNING (pid $(cat "$PIDFILE"))" || echo "daemon : stopped"
    if is_running && [ -r "$RUNCFG" ] && [ "$(cat "$RUNCFG")" != "$(config_sig)" ]; then
      echo "CHANGED: on-disk config differs from the running daemon -> run '$0 reload' to apply"
    fi
    echo "enabled: $([ "$ENABLED" = 1 ] && echo yes || echo 'no (ENABLED=0 - inert)')"
    [ -n "$TIME_ERRORS" ] && echo "ERROR  : invalid time(s):$TIME_ERRORS  -> fix $CONF and restart"
    [ -n "$TIME_FIXED" ] && echo "fixed  : normalized:$TIME_FIXED"
    if [ "$DRY_RUN" = 1 ]; then echo "mode   : $POWEROFF_MODE | DRY-RUN (observe only - will NOT power off)"
    else echo "mode   : $POWEROFF_MODE | ARMED (real shutdowns enabled)"; fi
    echo "wake   : times='${WAKE_TIMES:-none}' external=$WAKE_EXTERNAL"
    echo "now    : $(date '+%a %Y-%m-%d %H:%M:%S %Z')  <- confirm this is your LOCAL time (Unraid: Settings -> Date and Time)"
    a=$(cat "$RTC" 2>/dev/null); now=$(date +%s)
    if [ -n "$a" ] && [ "$a" -gt "$now" ] 2>/dev/null; then
      printf "armed  : %s (in %dh%02dm)\n" "$(fmt "$a")" $(( (a-now)/3600 )) $(( ((a-now)%3600)/60 ))
    elif [ -n "$a" ] && [ "$a" -gt 0 ] 2>/dev/null; then echo "armed  : $(fmt "$a") (in the past - not pending)"
    else echo "armed  : (none)"; fi
    awk '/alarm_IRQ/{print "alarm  : alarm_IRQ="$3}' /proc/driver/rtc 2>/dev/null
    echo "config : stay-up-until=$STAY_UP_UNTIL idle=${IDLE_SHUTDOWN_MIN}m poweroff-at=$POWEROFF_AT thresh=${THRESH_KBPS}KB/s disk-thresh=${DISK_THRESH_KBPS}KB/s ports='$BUSY_PORTS' iface=$(detect_iface)"
    echo "conf   : $([ -r "$CONF" ] && echo "$CONF" || echo "(none - using built-in defaults)")"
    [ -r "$STATEF" ] && { printf "live   : "; cat "$STATEF"; }
    inhibited && echo "inhibit: ACTIVE - keepawake/disable flag present, will not power off"
    [ -r "$BREADCRUMB" ] && echo "last   : $(tail -n1 "$BREADCRUMB")"
    true                          # status is informational - always exit 0
    ;;

  arm)
    n="${2:-}"
    if [ -n "$n" ]; then n=$(norm_hhmm "$2") || { echo "invalid time '$2' - use HHMM (e.g. 2345) or HH:MM"; exit 1; }; fi
    if t=$(arm_next_wake "$n"); then echo "armed wake for $(fmt "$t")"
    else echo "arm FAILED - see $LOGFILE (is WAKE_TIMES set, or pass an HHMM?)"; exit 1; fi
    ;;

  off)
    echo "arming next wake and powering off now..."
    do_scheduled_poweroff force || { echo "could NOT guarantee a wake - refusing to power off (see $LOGFILE)"; exit 1; }
    ;;

  test-wake)
    secs=${2:-300}
    # This command POWERS THE BOX OFF. Confirm first, unless 'yes'/'-y' is passed. Over a
    # non-interactive shell (ssh 'cmd', a script) read hits EOF and we abort - it can't fire blind.
    if [ "$3" != yes ] && [ "$3" != -y ]; then
      echo "WARNING: 'test-wake' POWERS OFF this system NOW, then relies on the RTC alarm to power"
      echo "         it back on in ${secs}s (~$((secs/60)) min). If RTC wake does NOT work on this"
      echo "         hardware, the box stays OFF until powered on by hand (power button / remote PDU)."
      echo "         Do NOT run this on a remote box you cannot physically reach."
      printf "Type 'yes' to power off and test the wake: "
      read -r ans || ans=""
      [ "$ans" = yes ] || { echo "aborted - nothing changed, system still running."; exit 0; }
    fi
    now=$(date +%s); target=$((now + secs))
    [ -w "$RTC" ] || { echo "$RTC not writable - NOT powering off"; exit 1; }
    echo 0 > "$RTC"; echo "$target" > "$RTC"
    rb=$(cat "$RTC" 2>/dev/null)
    [ "$rb" = "$target" ] || { echo "RTC verify failed (readback '$rb') - NOT powering off"; exit 1; }
    echo "armed wake for $(fmt "$target") (${secs}s out). Powering off; the box should return on its own."
    logger -t power-schedule "test-wake ${secs}s -> $(fmt "$target")"
    sync; poweroff
    ;;

  *) echo "Usage: $0 {start|stop|restart|reload|status|run|arm [HHMM]|off|test-wake [secs] [yes]}"
     echo "       (reload = restart, applies config edits; test-wake and off POWER THE BOX OFF)"; exit 1 ;;
esac
