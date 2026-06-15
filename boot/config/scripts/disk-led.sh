#!/bin/bash
#
# disk-led.sh - per-bay disk-activity LEDs for Asustor Lockerstor 6 Gen2 (AS6706T)
#
# Lights the six green front-bay LEDs from real disk activity. Unraid's kernel ships
# WITHOUT CONFIG_LEDS_GPIO and the disk-activity LED trigger, so even with the Asustor
# platform driver loaded these LEDs stay dark - the in-kernel trigger that drives them on
# other distros isn't compiled in. This drives the GPIO lines directly and emulates the
# trigger in userspace.
#
# It also drives the front-panel green STATUS LED (gpled1): by default an aggregate
# NVMe-activity light (the internal M.2 slots have no LED of their own), or forced off / solid
# via STATUS_LED below. See the STATUS_LED config block and docs/nvme-activity-led.md.
#
# The actual line I/O is done by disk-led.pl (pure Perl + core Fcntl) because Unraid's base
# image has no gpioset/libgpiod, no python, and no compiler - perl is the one capable
# interpreter present. This wrapper just handles the daemon lifecycle and manual overrides,
# mirroring fan-autocontrol.sh. Full background: docs/disk-leds.md.
#
# Usage:
#   disk-led.sh start|stop|restart|status|run
#   disk-led.sh test                 # identify sweep: all on, then bay 1..6 in turn
#   disk-led.sh locate N [secs]      # blink bay N to find a drive (clears after secs, if given)
#   disk-led.sh on N | off N         # force bay N's green LED on/off
#   disk-led.sh auto [N|all]         # clear override(s) -> back to activity mode
#
# --------------------------------------------------------------------------------------
# CONFIG
# --------------------------------------------------------------------------------------
INTERVAL_MS=100                       # activity poll interval (10 Hz). 150-250 lowers idle
                                      # CPU wakeups further with no visible difference.

# Green (activity) LED GPIO line offsets, bay 1..6 LEFT->RIGHT facing the unit. Verified on
# this hardware (sweep) and against the driver's AS6706 lookup table:
#   bay1=12  bay2=46  bay3=51  bay4=63  bay5=61  bay6=58
GREEN_OFFSETS="12 46 51 63 61 58"
NBAYS=6

# Front-panel green STATUS LED (gpled1) - what to do with it. The internal M.2 NVMe slots have
# no front-panel LED of their own, so by default this LED becomes an aggregate "any NVMe busy?"
# activity flicker (idle = dark), the same model as a bay LED. Unlike the bay LEDs, gpled1 has a
# hwmon sysfs node, so it's driven by a plain write (no chardev). The daemon actively asserts the
# chosen state, so "off" is genuinely dark regardless of the LED's power-on resting value.
STATUS_LED=nvme                       # nvme = flicker on NVMe I/O (default) | off = force dark | on = force solid
GPLED_GLOB="/sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1"  # status-LED value node
NVME_REGEX='^nvme[0-9]+n[0-9]+$'      # /proc/diskstats devices counted as NVMe (whole namespaces)

PIDFILE=/var/run/disk-led.pid
LOGFILE=/var/log/disk-led.log         # /var/log is tmpfs (RAM) on Unraid - no USB-flash wear
CTL=/dev/shm/disk-led.ctl             # override control file (tmpfs)
PL="$(dirname "$0")/disk-led.pl"      # the Perl engine, installed alongside this script

# --------------------------------------------------------------------------------------
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

valid_bay() { [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le "$NBAYS" ] 2>/dev/null; }

# Set one bay's override mode in the (tmpfs) control file; daemon picks it up next tick.
set_override() {
  local bay=$1 mode=$2
  touch "$CTL" 2>/dev/null
  { grep -v "^$bay " "$CTL" 2>/dev/null; echo "$bay $mode"; } > "$CTL.tmp" && mv "$CTL.tmp" "$CTL"
}
clear_override() {
  local bay=$1
  if [ "$bay" = all ]; then : > "$CTL" 2>/dev/null; return; fi
  grep -v "^$bay " "$CTL" 2>/dev/null > "$CTL.tmp"; mv "$CTL.tmp" "$CTL" 2>/dev/null
}

# Resolve bay (1..NBAYS) -> sdX via ata port, into the associative array BAYDEV.
resolve_baydev() {
  unset BAYDEV; declare -gA BAYDEV
  local d n tgt
  for d in /sys/block/sd*; do
    [ -e "$d" ] || continue
    n=$(basename "$d"); tgt=$(readlink "$d")
    [[ "$tgt" =~ /ata([0-9]+)/ ]] && BAYDEV[${BASH_REMATCH[1]}]=$n
  done
}

run_loop() {
  [ -r "$PL" ] || { log "FATAL: engine $PL not found"; exit 1; }
  # Wait out the boot race: a gpiochip must exist before the engine can grab lines.
  local i; for i in $(seq 1 30); do ls /dev/gpiochip* >/dev/null 2>&1 && break; sleep 1; done
  export DL_OFFSETS="$GREEN_OFFSETS" DL_INTERVAL_MS="$INTERVAL_MS" DL_CTL="$CTL" DL_LOG="$LOGFILE"
  export DL_STATUS_LED="$STATUS_LED" DL_GPLED_GLOB="$GPLED_GLOB" DL_NVME_REGEX="$NVME_REGEX"
  exec perl "$PL"                     # replaces this process; pidfile stays valid
}

case "$1" in
  run) run_loop ;;

  start)
    if is_running; then echo "already running (pid $(cat "$PIDFILE"))"; exit 0; fi
    : > "$CTL" 2>/dev/null              # start clean: no stale overrides
    setsid "$0" run >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    is_running && echo "started (pid $(cat "$PIDFILE"))" || { echo "failed - see $LOGFILE"; exit 1; }
    ;;

  stop)
    if is_running; then
      kill -TERM "$(cat "$PIDFILE")" 2>/dev/null
      for i in 1 2 3 4 5; do is_running || break; sleep 1; done
      kill -9 "$(cat "$PIDFILE")" 2>/dev/null
      rm -f "$PIDFILE"; echo "stopped"
    else echo "not running"; fi
    ;;

  restart) "$0" stop; sleep 1; "$0" start ;;

  status)
    is_running && echo "daemon : RUNNING (pid $(cat "$PIDFILE"))" || echo "daemon : stopped"
    echo "engine : $PL"
    echo "chip   : $( [ -e /dev/gpiochip0 ] && echo present || echo 'MISSING - is asustor_gpio_it87 loaded?')"
    echo "poll   : ${INTERVAL_MS}ms"
    resolve_baydev
    read -ra offs <<< "$GREEN_OFFSETS"
    for i in $(seq 1 "$NBAYS"); do
      printf "  bay%d (gpio %-2s) -> %s\n" "$i" "${offs[$((i-1))]}" "${BAYDEV[$i]:-(empty)}"
    done
    gp=$(ls $GPLED_GLOB 2>/dev/null | head -1)
    case "${STATUS_LED,,}" in
      off) echo "led    : forced OFF -> ${gp:-MISSING (no writable gpled1)}" ;;
      on)  echo "led    : forced ON (solid) -> ${gp:-MISSING (no writable gpled1)}" ;;
      *)   nv=$(ls -d /sys/block/nvme* 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')
           echo "led    : NVMe activity -> ${gp:-MISSING (no writable gpled1)}"
           echo "led    :   aggregating ${nv:-(no nvme devices found)}" ;;
    esac
    if [ -s "$CTL" ]; then echo "overrides:"; sed 's/^/  bay/' "$CTL"; else echo "overrides: none (all bays = activity)"; fi
    ;;

  test)
    if is_running; then
      echo "sweeping via the running daemon (watch the front panel)..."
      for i in $(seq 1 "$NBAYS"); do
        { for j in $(seq 1 "$NBAYS"); do [ "$j" = "$i" ] && echo "$j on" || echo "$j off"; done; } > "$CTL"
        sleep 1.2
      done
      : > "$CTL"; echo "done"
    else
      echo "daemon not running - running a standalone sweep (watch the front panel)..."
      DL_OFFSETS="$GREEN_OFFSETS" DL_MODE=sweep perl "$PL" && echo "done"
    fi
    ;;

  locate)
    valid_bay "$2" || { echo "usage: $0 locate N [secs]   (N = 1..$NBAYS)"; exit 1; }
    is_running || { echo "daemon not running - start it first (a one-shot can't hold an LED)"; exit 1; }
    set_override "$2" locate
    if [ -n "$3" ]; then echo "bay $2 blinking for ${3}s"; sleep "$3"; clear_override "$2"; echo "cleared"
    else echo "bay $2 blinking - run '$0 auto $2' to stop"; fi
    ;;

  on|off)
    valid_bay "$2" || { echo "usage: $0 $1 N   (N = 1..$NBAYS)"; exit 1; }
    is_running || { echo "daemon not running - start it first (a one-shot can't hold an LED)"; exit 1; }
    set_override "$2" "$1"; echo "bay $2 forced $1"
    ;;

  auto)
    clear_override "${2:-all}"; echo "override cleared for ${2:-all} -> activity mode"
    ;;

  *) echo "Usage: $0 {start|stop|restart|status|run|test|locate N [secs]|on N|off N|auto [N|all]}"; exit 1 ;;
esac
