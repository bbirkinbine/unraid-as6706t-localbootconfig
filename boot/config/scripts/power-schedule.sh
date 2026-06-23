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
#   power-schedule.sh start|stop|restart|status|run
#   power-schedule.sh arm [HHMM]      # manually (re)arm next wake (default: next of WAKE_TIMES)
#   power-schedule.sh off             # arm next wake + power off NOW (manual "go back to sleep")
#   power-schedule.sh test-wake [sec] # arm sec-from-now (default 300) + poweroff - the bring-up test
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
BUSY_PORTS="445 873 2049" # established connections on these LOCAL ports = client attached: SMB / rsync
                          #   daemon / NFS. (rsync-over-ssh is caught by the rsync process check.)
LOOP_SECS=60              # watchdog tick
IFACE=""                  # data interface; empty = autodetect the default-route iface (usually br0)
ARM_GUARD_MIN=10          # refuse to arm a wake less than this many minutes out (sanity check)

CONF=/boot/config/power-schedule.conf
[ -r "$CONF" ] && . "$CONF"     # site overrides win over the defaults above

RTC=/sys/class/rtc/rtc0/wakealarm
PIDFILE=/var/run/power-schedule.pid
LOGFILE=/var/log/power-schedule.log          # /var/log is tmpfs (RAM) on Unraid - no USB-flash wear
STATEF=/dev/shm/power-schedule.state         # live watchdog state for `status` (tmpfs)
BREADCRUMB=/boot/config/power-schedule.last   # one line per shutdown on USB (survives poweroff)

# --------------------------------------------------------------------------------------
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }
fmt() { date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null; }

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

# Shutdown is inhibited while either flag exists (manual "keep it awake").
inhibited() { [ -e /boot/config/power-schedule.disable ] || [ -e /dev/shm/power-schedule.keepawake ]; }

# Epoch of the next local HH:MM strictly in the future (today's, or tomorrow's if already passed).
# GNU date: a bare "HH:MM" means today at that time; "HH:MM tomorrow" the day after.
next_epoch() {
  local H=${1:0:2} M=${1:2:2} t now
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

# Echo space-separated reasons the box is "busy" right now (empty = idle). Arg 1 = KB/s this tick.
is_busy() {
  local kbps=$1 r="" p cnt
  who 2>/dev/null | grep -q . && r="$r login"            # an interactive login = admin present
  for p in $BUSY_PORTS; do                               # a storage client attached?
    cnt=$(ss -Htn state established "sport = :$p" 2>/dev/null | grep -c .)
    [ "${cnt:-0}" -gt 0 ] && r="$r $p:$cnt"
  done
  pgrep -x rsync  >/dev/null 2>&1 && r="$r rsync"         # rsync server (rsync-over-ssh or daemon)
  pgrep -x rclone >/dev/null 2>&1 && r="$r rclone"
  [ "${kbps:-0}" -ge "$THRESH_KBPS" ] && r="$r net:${kbps}KB/s"
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
  trap 'log "watchdog stopping"; exit 0' TERM INT
  local iface; iface=$(detect_iface)
  [ -z "$iface" ] && { log "FATAL: no data interface found"; exit 1; }
  local rxf=/sys/class/net/$iface/statistics/rx_bytes
  local txf=/sys/class/net/$iface/statistics/tx_bytes

  # Floor = the daily time the shutdown window opens (idle: STAY_UP_UNTIL; fixed: POWEROFF_AT).
  local floor_time="$STAY_UP_UNTIL"; [ "$POWEROFF_MODE" = fixed ] && floor_time="$POWEROFF_AT"
  local floor; floor=$(next_epoch "$floor_time")
  log "watchdog up: mode=$POWEROFF_MODE iface=$iface wake='${WAKE_TIMES:-none}' floor=$floor_time (next $(fmt "$floor")) idle=${IDLE_SHUTDOWN_MIN}m thresh=${THRESH_KBPS}KB/s dry_run=$DRY_RUN"

  local prx ptx pt rx tx now dt db kbps idle=0 reason fire
  prx=$(cat "$rxf" 2>/dev/null || echo 0); ptx=$(cat "$txf" 2>/dev/null || echo 0); pt=$(date +%s)
  while sleep "$LOOP_SECS"; do
    now=$(date +%s)
    rx=$(cat "$rxf" 2>/dev/null || echo "$prx"); tx=$(cat "$txf" 2>/dev/null || echo "$ptx")
    dt=$((now - pt)); [ "$dt" -lt 1 ] && dt=1
    db=$(( (rx - prx) + (tx - ptx) )); [ "$db" -lt 0 ] && db=0     # guard counter wrap/reset
    kbps=$(( db / dt / 1024 ))
    prx=$rx; ptx=$tx; pt=$now

    reason=$(is_busy "$kbps")
    if [ -n "$reason" ]; then idle=0; else idle=$((idle + LOOP_SECS)); fi

    printf 'ts=%s mode=%s armed=%s floor=%s idle_s=%s kbps=%s busy=%s\n' \
      "$now" "$POWEROFF_MODE" "$(cat "$RTC" 2>/dev/null)" "$floor" "$idle" "$kbps" "${reason:-none}" \
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

case "$1" in
  run) run_loop ;;

  start)
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
    is_running && echo "started (pid $(cat "$PIDFILE"))" || { echo "failed - see $LOGFILE"; exit 1; }
    ;;

  stop)
    if is_running; then
      kill -TERM "$(cat "$PIDFILE")" 2>/dev/null
      for _ in 1 2 3 4 5; do is_running || break; sleep 1; done
      kill -9 "$(cat "$PIDFILE")" 2>/dev/null
      rm -f "$PIDFILE"; echo "stopped"
    else echo "not running"; fi
    ;;

  restart) "$0" stop; sleep 1; "$0" start ;;

  status)
    is_running && echo "daemon : RUNNING (pid $(cat "$PIDFILE"))" || echo "daemon : stopped"
    echo "enabled: $([ "$ENABLED" = 1 ] && echo yes || echo 'no (ENABLED=0 - inert)')"
    if [ "$DRY_RUN" = 1 ]; then echo "mode   : $POWEROFF_MODE | DRY-RUN (observe only - will NOT power off)"
    else echo "mode   : $POWEROFF_MODE | ARMED (real shutdowns enabled)"; fi
    echo "wake   : times='${WAKE_TIMES:-none}' external=$WAKE_EXTERNAL"
    a=$(cat "$RTC" 2>/dev/null); now=$(date +%s)
    if [ -n "$a" ] && [ "$a" -gt "$now" ] 2>/dev/null; then
      printf "armed  : %s (in %dh%02dm)\n" "$(fmt "$a")" $(( (a-now)/3600 )) $(( ((a-now)%3600)/60 ))
    elif [ -n "$a" ] && [ "$a" -gt 0 ] 2>/dev/null; then echo "armed  : $(fmt "$a") (in the past - not pending)"
    else echo "armed  : (none)"; fi
    awk '/alarm_IRQ/{print "alarm  : alarm_IRQ="$3}' /proc/driver/rtc 2>/dev/null
    echo "config : stay-up-until=$STAY_UP_UNTIL idle=${IDLE_SHUTDOWN_MIN}m poweroff-at=$POWEROFF_AT thresh=${THRESH_KBPS}KB/s ports='$BUSY_PORTS' iface=$(detect_iface)"
    echo "conf   : $([ -r "$CONF" ] && echo "$CONF" || echo "(none - using built-in defaults)")"
    [ -r "$STATEF" ] && { printf "live   : "; cat "$STATEF"; }
    inhibited && echo "inhibit: ACTIVE - keepawake/disable flag present, will not power off"
    [ -r "$BREADCRUMB" ] && echo "last   : $(tail -n1 "$BREADCRUMB")"
    true                          # status is informational - always exit 0
    ;;

  arm)
    if t=$(arm_next_wake "${2:-}"); then echo "armed wake for $(fmt "$t")"
    else echo "arm FAILED - see $LOGFILE (is WAKE_TIMES set, or pass an HHMM?)"; exit 1; fi
    ;;

  off)
    echo "arming next wake and powering off now..."
    do_scheduled_poweroff force || { echo "could NOT guarantee a wake - refusing to power off (see $LOGFILE)"; exit 1; }
    ;;

  test-wake)
    secs=${2:-300}; now=$(date +%s); target=$((now + secs))
    [ -w "$RTC" ] || { echo "$RTC not writable"; exit 1; }
    echo 0 > "$RTC"; echo "$target" > "$RTC"
    rb=$(cat "$RTC" 2>/dev/null)
    [ "$rb" = "$target" ] || { echo "RTC verify failed (readback '$rb') - aborting"; exit 1; }
    echo "armed wake for $(fmt "$target") (${secs}s out). Powering off; the box should return on its own."
    logger -t power-schedule "test-wake ${secs}s -> $(fmt "$target")"
    sync; poweroff
    ;;

  *) echo "Usage: $0 {start|stop|restart|status|run|arm [HHMM]|off|test-wake [secs]}"; exit 1 ;;
esac
