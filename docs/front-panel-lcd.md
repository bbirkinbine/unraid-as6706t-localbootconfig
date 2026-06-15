# Front-panel LCD and status LED

The AS6706T has a 2×16 character LCD on the front, plus status LEDs. Two scripts
drive the LCD, and the `go` file disables the blinking green status LED.

## The two scripts

| Script | Role |
| ------ | ---- |
| [`asustor-lcd.sh`](../boot/config/scripts/asustor-lcd.sh) | low-level writer — puts two lines of text on the LCD |
| [`lcd-info.sh`](../boot/config/scripts/lcd-info.sh) | daemon — refreshes the LCD with live system info every 10 s |

`lcd-info.sh` is the daemon you run; it calls `asustor-lcd.sh` to actually paint
the screen.

## `asustor-lcd.sh` — the LCM serial protocol

The LCD is an "LCM" character module reached over a serial port at
**`/dev/ttyS1`, 115200 baud, raw**. Each line is sent as a framed packet:

```
F0 12 27 <line> 00  <16 data bytes, space-padded>  <checksum>
         │    │                                      │
         │    └─ line index: 0 = top, 1 = bottom     └─ (sum of all prior bytes) & 0xFF
         └─ fixed header
```

Usage:

```bash
asustor-lcd.sh "top line" "bottom line"
```

It pads/truncates each string to exactly 16 chars, computes the running
checksum, and writes the raw bytes to the port. (Reverse-engineered framing; it's
specific to this Asustor LCM.)

## `lcd-info.sh` — the live info daemon

Displays, refreshing every `INTERVAL` (10 s) and only repainting when the text
actually changes:

```
┌────────────────┐
│ 192.168.1.226  │   ← line 1: primary IPv4 (falls back to hostname)
│ CPU 58C 1200rpm│   ← line 2: CPU package temp + system fan RPM
└────────────────┘
```

- **Primary IP** is found via `ip route get 1.1.1.1` (the source address of the
  default route), falling back to the first global-scope address, then hostname.
- **CPU temp** comes from the `coretemp` hwmon; **fan RPM** from the `it8625`
  `fan1_input` — the same sensors the [fan controller](./fan-control.md) uses.

Usage (same start/stop/status pattern as the fan daemon):

```bash
lcd-info.sh start     # fork the refresh loop, write a pidfile
lcd-info.sh stop
lcd-info.sh restart
lcd-info.sh status    # show state + what it would display right now
```

- PID file: `/var/run/lcd-info.pid`
- It expects the writer at `/usr/local/sbin/asustor-lcd.sh` (where `go` installs
  it).

## Disabling the blinking status LED

The Asustor front panel's green status LED (`gpled1`, GPIO GP47) blinks by
default, which is distracting on an always-on box. The `go` script writes `0` to
its `gpled1_blink` sysfs node so it sits **solid** instead:

```bash
for f in /sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1_blink; do
  [ -w "$f" ] && echo 0 > "$f"
done
```

(The glob is used because the exact `asustor_it87.N` and `hwmonN` numbers aren't
fixed across boots — same defensive pattern as the fan script.)

> **This LED is now repurposed.** The [disk-activity daemon](./disk-leds.md) drives the
> status-LED pin (`it87_gp47`) directly through the **GPIO chardev** — by default as an
> aggregate **NVMe-activity** indicator (flickers when the M.2 cache pool is busy), or forced
> **off** / **solid on** via its `STATUS_LED` setting. The `go` step above is now just a
> pre-seed that disables the chip's hardware blink so it can't fight the daemon's control.
> See [nvme-activity-led.md](./nvme-activity-led.md).

## How it's wired into boot

From [`boot/config/go`](../boot/config/go):

```bash
install -m 755 /boot/config/scripts/asustor-lcd.sh /usr/local/sbin/asustor-lcd.sh
install -m 755 /boot/config/scripts/lcd-info.sh    /usr/local/sbin/lcd-info.sh
/usr/local/sbin/lcd-info.sh start
```

## Prerequisite

Like the fan controller, the LCD GPIO/serial and the `it8625`/`coretemp` sensors
depend on the [Asustor platform driver](./asustor-platform-driver.md) being
installed.
