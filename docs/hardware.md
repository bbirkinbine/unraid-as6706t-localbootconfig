# Hardware: Asustor Lockerstor 6 Gen 2 (AS6706T)

This documents the specific machine these configs target, and the on-board
hardware that the custom scripts talk to. Knowing the chips involved is what
makes the fan and LCD scripts understandable.

## System summary

| Component | Detail |
| --------- | ------ |
| Model | Asustor Lockerstor 6 Gen 2, model **AS6706T** |
| CPU | Intel **Celeron N5105** (Jasper Lake, 4 cores, 2.0 GHz base, 10 W TDP) |
| Super-I/O / hardware monitor | **ITE IT8625** (fan PWM + tach + GPIO for LEDs/LCD) |
| Drive bays | **6 × 3.5"** SATA hot-swap |
| M.2 slots | **2 × NVMe** (PCIe) |
| Front panel | character **LCD** (2×16) + status/network/USB LEDs, over an internal serial/GPIO link |
| BIOS | V1.21 |
| Role here | Unraid 7.3.1, hostname `NAS-OFFSITE` — an offsite backup target |

## The IT8625 — why it matters

The single most important chip for this repo is the **ITE IT8625** Super-I/O
controller. It exposes:

- **`pwm1`** — PWM duty cycle (0–255) for the **one** system fan circuit. The
  AS6706T wires all chassis cooling to this single controllable channel.
- **`fan1_input`** — the fan tachometer (RPM readback).
- **GPIO lines** driving the **front-panel LEDs** (e.g. the green status LED on
  `gpled1`) and the **LCD** backlight/control.

The mainline Linux `it87` driver does **not** properly support the IT8625 on
this board. Instead we use a patched fork shipped by the Asustor platform-driver
plugin, which binds as **`asustor_it87`** and presents the chip under
`/sys/class/hwmon/` with the name **`it8625`**. The custom scripts resolve the
fan by that *driver name* rather than a fixed `hwmonN` number, so they keep
working even when hwmon devices get renumbered across reboots. See
[asustor-platform-driver.md](./asustor-platform-driver.md) for the driver, and
[fan-control.md](./fan-control.md) for how the fan is actually driven.

## Temperature sources

The fan controller blends several independent temperature sensors, each surfaced
by a different kernel driver under `/sys/class/hwmon/`:

| Sensor | hwmon `name` | Source |
| ------ | ------------ | ------ |
| CPU package | `coretemp` | Intel N5105 on-die sensor |
| NVMe SSDs | `nvme` | each M.2 drive's Composite sensor |
| SATA HDDs | `drivetemp` | per-disk SATA temperature (needs `modprobe drivetemp`) |
| Fan chip ambient / fan | `it8625` | the IT8625 itself (pwm + tach) |

## Drive bays (general note)

The six bays are physically numbered 1–6, left to right. **The `/dev/sdX` letters
are not stable** — they shuffle based on boot enumeration order. The ATA port
(`ata1`..`ata6`) *is* wired to the physical bay and is stable, and Unraid binds
array slots to the drive **serial number**, so disks should always be assigned by
serial / `by-id`, never by `sdX`.

(The specific disk inventory for any given server — serials, which bay holds what
— is setup-specific and intentionally **not** part of this repo. Generate a
current map on the box itself with the snippet below and keep it wherever you keep
your own server notes.)

```bash
for blk in /sys/block/sd*; do d=$(basename "$blk"); \
  ata=$(readlink -f "$blk/device" | grep -o 'ata[0-9]*' | head -1); \
  echo "$ata $d $(cat "$blk/device/model") $(lsblk -dno SIZE /dev/$d)"; done | sort
```

## Front panel: LCD + LEDs

The AS6706T has a small front-panel **LCD** (two lines of 16 characters) and a
set of status LEDs. Both hang off the IT8625 GPIO / an internal serial link:

- The **LCD** is written by sending framed packets over `/dev/ttyS1` at 115200
  baud (the "LCM" protocol). See
  [front-panel-lcd.md](./front-panel-lcd.md).
- The **green status LED** (`gpled1`) blinks by default; the `go` script disables
  the blink by writing `0` to its `gpled1_blink` sysfs node so it sits solid.
  See [front-panel-lcd.md](./front-panel-lcd.md).

## NVMe

The board has **two M.2 NVMe slots** (used here for a BTRFS RAID1 cache pool, but
the pool layout is setup-specific and configured in the GUI, not part of this
repo). Each NVMe drive's temperature is surfaced under hwmon as `nvme` and feeds
the [fan controller](./fan-control.md).
