#!/bin/bash
#
# lcd-info.sh - drive the Asustor front-panel LCD with live system info.
#   Top line:    primary IPv4 address (falls back to hostname)
#   Bottom line: CPU package temp + system fan RPM   e.g. "CPU 58C 1200rpm"
#
# Uses /usr/local/sbin/asustor-lcd.sh to emit the LCM serial frames on /dev/ttyS1.
# Usage: lcd-info.sh {start|stop|restart|status|run}
#
INTERVAL=10
WRITER=/usr/local/sbin/asustor-lcd.sh
PIDFILE=/var/run/lcd-info.pid

hwmon_by_name() {
  local want="$1" d
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue
    [ "$(cat "$d/name" 2>/dev/null)" = "$want" ] && { echo "$d"; return 0; }
  done
  return 1
}

primary_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')
  [ -z "$ip" ] && ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  [ -z "$ip" ] && ip=$(hostname 2>/dev/null)
  echo "$ip"
}

build_lines() {
  L1=$(primary_ip)
  local c d cpu="--" rpm="----"
  d=$(hwmon_by_name coretemp); [ -n "$d" ] && [ -r "$d/temp1_input" ] && cpu=$(( $(cat "$d/temp1_input")/1000 ))
  d=$(hwmon_by_name it8625);   [ -n "$d" ] && [ -r "$d/fan1_input" ] && rpm=$(cat "$d/fan1_input")
  L2=$(printf 'CPU %sC %srpm' "$cpu" "$rpm")
}

run_loop() {
  trap 'rm -f "$PIDFILE"; exit 0' TERM INT
  local last=""
  while true; do
    build_lines
    if [ "$L1|$L2" != "$last" ]; then
      "$WRITER" "$L1" "$L2"
      last="$L1|$L2"
    fi
    sleep "$INTERVAL"
  done
}

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

case "$1" in
  run)   run_loop ;;
  start)
    if is_running; then echo "already running (pid $(cat $PIDFILE))"; exit 0; fi
    [ -x "$WRITER" ] || { echo "missing $WRITER"; exit 1; }
    setsid "$0" run >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    is_running && echo "started (pid $(cat $PIDFILE))" || { echo "failed"; exit 1; }
    ;;
  stop)
    if is_running; then kill -TERM "$(cat $PIDFILE)"; sleep 1; echo "stopped"; else echo "not running"; fi
    ;;
  restart) "$0" stop; sleep 1; "$0" start ;;
  status)
    is_running && echo "lcd-info: RUNNING (pid $(cat $PIDFILE))" || echo "lcd-info: stopped"
    build_lines; echo "would display:"; echo "  L1: $L1"; echo "  L2: $L2"
    ;;
  *) echo "Usage: $0 {start|stop|restart|status|run}"; exit 1 ;;
esac
