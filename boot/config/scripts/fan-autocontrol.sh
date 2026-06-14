#!/bin/bash
#
# fan-autocontrol.sh - standalone fan controller for Asustor Lockerstor 6 Gen 2 (AS6706T)
#
# Controls the single wired system-fan circuit (it8625 pwm1, tach fan1_input) by blending
# CPU, NVMe and (when present) SATA HDD temperatures. Sensors are resolved by driver NAME
# every cycle, so it survives hwmon renumbering across reboots and HDD hotplug.
#
# Usage: fan-autocontrol.sh {start|stop|restart|status|run}
#
# --------------------------------------------------------------------------------------
# TUNABLES  (pwm is 0-255; temps in whole degrees C)
# Each source has its own curve. The controller computes a target pwm per source and
# drives the fan at the HIGHEST of them (whichever component is hottest wins).
# --------------------------------------------------------------------------------------
INTERVAL=10            # seconds between adjustments
MINPWM=51              # floor (~20%, ~800 RPM) - fan proven to spin reliably here
MAXPWM=255             # ceiling (100%)
SAFE_PWM=160           # pwm to leave the fan at if the daemon is stopped (~63%)

# Output smoothing (anti-hunt). The N5105 package temp bounces several degrees every
# cycle at idle; without damping the fan chases each spike and surges audibly. Each
# cycle the fan moves only ceil(1/SMOOTH_DIV) of the way toward the new target, so a
# one-cycle spike barely moves it while sustained load still ramps fully within
# ~SMOOTH_DIV cycles (~30s at INTERVAL=10). Set to 1 to disable smoothing.
SMOOTH_DIV=3

# CPU package (coretemp). N5105 idles ~56-65C (measured), throttles at 105C. Floor sits
# above the idle band so the fan stays at MINPWM when the chip is only micro-boosting,
# and only ramps under genuine sustained load.
CPU_MINTEMP=62         # below this -> MINPWM
CPU_MAXTEMP=85         # at/above this -> MAXPWM

# NVMe SSDs (nvme Composite). Warn ~70C.
NVME_MINTEMP=45
NVME_MAXTEMP=72

# SATA HDDs (drivetemp). Idle ~25-34C measured; WD Red/Red Pro + He shucks rated to
# 60-65C but live longest <~50C. Stay at floor until 40C, ramp to full by 52C.
HDD_MINTEMP=40
HDD_MAXTEMP=52

PIDFILE=/var/run/fan-autocontrol.pid
LOGFILE=/var/log/fan-autocontrol.log
LOGMAX=200000          # truncate log past ~200KB

# --------------------------------------------------------------------------------------
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"; }

rotate_log() {
  [ -f "$LOGFILE" ] || return
  local sz; sz=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
  [ "$sz" -gt "$LOGMAX" ] && : > "$LOGFILE"
}

# Find the hwmon directory whose name == $1 (first match). Echoes path or nothing.
hwmon_by_name() {
  local want="$1" d
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue
    [ "$(cat "$d/name" 2>/dev/null)" = "$want" ] && { echo "$d"; return 0; }
  done
  return 1
}

# Resolve the it8625 pwm/fan/enable paths into globals PWM, FAN, EN.
resolve_pwm() {
  local d; d=$(hwmon_by_name it8625) || return 1
  PWM="$d/pwm1"; FAN="$d/fan1_input"; EN="$d/pwm1_enable"
  [ -w "$PWM" ]
}

# Linear interpolation: temp_milli mintempC maxtempC -> pwm (clamped MINPWM..MAXPWM)
calc_pwm() {
  local tm=$1 lo=$2 hi=$3
  local t=$(( tm / 1000 ))
  if   [ "$t" -le "$lo" ]; then echo "$MINPWM"; return; fi
  if   [ "$t" -ge "$hi" ]; then echo "$MAXPWM"; return; fi
  echo $(( MINPWM + (t - lo) * (MAXPWM - MINPWM) / (hi - lo) ))
}

# Given a drivetemp hwmon dir, echo its backing block device (e.g. sdf) or nothing.
hwmon_block() {
  local b blk=""
  for b in "$1/device/block"/*; do [ -e "$b" ] && blk=${b##*/}; done
  echo "$blk"
}

# True (0) if /dev/<blk> is spun down. hdparm -C uses CHECK POWER MODE, which reports
# the power state WITHOUT waking the drive (unlike reading its temperature).
hdd_is_standby() {
  local st
  st=$(hdparm -C "/dev/$1" 2>/dev/null | awk '/drive state/{print $4}')
  [ "$st" = "standby" ] || [ "$st" = "sleeping" ]
}

# Read every relevant temp this cycle, return the winning pwm + a human reason string.
# Sets globals: TARGET, REASON
compute_target() {
  TARGET=$MINPWM; REASON="floor"
  local d name tf val p blk

  # CPU package = coretemp temp1_input
  d=$(hwmon_by_name coretemp)
  if [ -n "$d" ] && [ -r "$d/temp1_input" ]; then
    val=$(cat "$d/temp1_input"); p=$(calc_pwm "$val" "$CPU_MINTEMP" "$CPU_MAXTEMP")
    [ "$p" -gt "$TARGET" ] && { TARGET=$p; REASON="CPU $((val/1000))C"; }
  fi

  # All nvme devices (there can be several hwmonN named "nvme")
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue
    [ "$(cat "$d/name")" = "nvme" ] || continue
    [ -r "$d/temp1_input" ] || continue
    val=$(cat "$d/temp1_input"); p=$(calc_pwm "$val" "$NVME_MINTEMP" "$NVME_MAXTEMP")
    [ "$p" -gt "$TARGET" ] && { TARGET=$p; REASON="NVMe $((val/1000))C"; }
  done

  # All SATA HDDs via drivetemp. Skip any disk that is spun down: reading temp1_input
  # issues an ATA command through the drivetemp driver and would wake it, defeating
  # idle spin-down. A standby disk is cool and idle, so excluding it from the curve is
  # also thermally correct.
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue
    [ "$(cat "$d/name")" = "drivetemp" ] || continue
    [ -r "$d/temp1_input" ] || continue
    blk=$(hwmon_block "$d")
    [ -n "$blk" ] && hdd_is_standby "$blk" && continue
    val=$(cat "$d/temp1_input"); p=$(calc_pwm "$val" "$HDD_MINTEMP" "$HDD_MAXTEMP")
    [ "$p" -gt "$TARGET" ] && { TARGET=$p; REASON="HDD $((val/1000))C"; }
  done
}

run_loop() {
  modprobe drivetemp 2>/dev/null   # enable per-HDD temps if any SATA disks are fitted
  if ! resolve_pwm; then
    log "FATAL: could not find writable it8625 pwm1 - is asustor_it87 loaded?"
    exit 1
  fi
  echo 1 > "$EN" 2>/dev/null        # manual/software mode
  log "started (pwm=$PWM interval=${INTERVAL}s)"

  trap 'on_exit' TERM INT
  local last=-1
  SMOOTHED=-1                         # current applied pwm; snaps to first target on startup
  while true; do
    rotate_log
    resolve_pwm || { log "lost pwm path, retrying"; sleep "$INTERVAL"; continue; }
    echo 1 > "$EN" 2>/dev/null
    compute_target

    # Move SMOOTHED a fraction of the way toward TARGET (ceil-rounded so it always
    # advances at least 1 step and converges exactly). First cycle snaps immediately.
    if [ "$SMOOTHED" -lt 0 ]; then
      SMOOTHED=$TARGET
    else
      local delta=$(( TARGET - SMOOTHED ))
      if   [ "$delta" -gt 0 ]; then SMOOTHED=$(( SMOOTHED + (delta + SMOOTH_DIV - 1) / SMOOTH_DIV ))
      elif [ "$delta" -lt 0 ]; then SMOOTHED=$(( SMOOTHED - ((-delta) + SMOOTH_DIV - 1) / SMOOTH_DIV )); fi
    fi

    echo "$SMOOTHED" > "$PWM" 2>/dev/null
    if [ "$SMOOTHED" != "$last" ]; then
      log "pwm=$SMOOTHED (target=$TARGET) rpm=$(cat "$FAN" 2>/dev/null) driver=$REASON"
      last=$SMOOTHED
    fi
    sleep "$INTERVAL"
  done
}

on_exit() {
  log "stopping -> setting safe pwm $SAFE_PWM"
  resolve_pwm && { echo 1 > "$EN" 2>/dev/null; echo "$SAFE_PWM" > "$PWM" 2>/dev/null; }
  rm -f "$PIDFILE"
  exit 0
}

is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

case "$1" in
  run)   run_loop ;;
  start)
    if is_running; then echo "already running (pid $(cat $PIDFILE))"; exit 0; fi
    setsid "$0" run >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    is_running && echo "started (pid $(cat $PIDFILE))" || { echo "failed - see $LOGFILE"; exit 1; }
    ;;
  stop)
    if is_running; then
      kill -TERM "$(cat $PIDFILE)" 2>/dev/null
      for i in 1 2 3 4 5; do is_running || break; sleep 1; done
      kill -9 "$(cat $PIDFILE)" 2>/dev/null
      rm -f "$PIDFILE"; echo "stopped"
    else echo "not running"; fi
    ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  status)
    resolve_pwm || { echo "it8625 pwm not found"; exit 1; }
    is_running && echo "daemon: RUNNING (pid $(cat $PIDFILE))" || echo "daemon: stopped"
    echo "pwm1   : $(cat "$PWM")/255   (enable=$(cat "$EN"))"
    echo "fan1   : $(cat "$FAN") RPM"
    for d in /sys/class/hwmon/hwmon*; do
      n=$(cat "$d/name" 2>/dev/null)
      case "$n" in
        coretemp) [ -r "$d/temp1_input" ] && echo "CPU    : $(( $(cat $d/temp1_input)/1000 ))C" ;;
        nvme)     [ -r "$d/temp1_input" ] && echo "NVMe   : $(( $(cat $d/temp1_input)/1000 ))C ($d)" ;;
        drivetemp)
          blk=$(hwmon_block "$d")
          if [ -n "$blk" ] && hdd_is_standby "$blk"; then
            echo "HDD    : standby   ($blk)"
          elif [ -r "$d/temp1_input" ]; then
            echo "HDD    : $(( $(cat $d/temp1_input)/1000 ))C ($blk)"
          fi ;;
      esac
    done
    ;;
  *) echo "Usage: $0 {start|stop|restart|status|run}"; exit 1 ;;
esac
