#!/bin/bash
# asustor-lcd.sh - write two lines to the Asustor front-panel LCD (LCM over /dev/ttyS1)
# Usage: asustor-lcd.sh "top line" "bottom line"
# Frame: F0 12 27 <line> 00 <16 chars, space-padded> <checksum=(sum of prev bytes)&0xFF>
PORT=/dev/ttyS1

send_line() {            # $1 = line index (0 top / 1 bottom), $2 = text
  local idx=$1 text=$2
  text=$(printf '%-16.16s' "$text")          # pad/truncate to exactly 16 chars
  # header bytes: F0 12 27 <idx> 00
  local -a bytes=(240 18 39 $idx 0)
  local i c sum=0 payload=""
  for c in 240 18 39 $idx 0; do sum=$((sum + c)); done
  for ((i=0;i<16;i++)); do
    printf -v c '%d' "'${text:i:1}"          # char -> decimal code
    sum=$((sum + c))
    payload+=$(printf '\\x%02x' "$c")
  done
  local ck=$((sum & 255))
  printf '\xf0\x12\x27'"$(printf '\\x%02x' $idx)"'\x00'"$payload""$(printf '\\x%02x' $ck)" > "$PORT"
}

stty -F "$PORT" 115200 raw 2>/dev/null
send_line 0 "$1"
send_line 1 "$2"
