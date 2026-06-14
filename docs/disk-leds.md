# Per-bay disk-activity LEDs

Scripts: [`boot/config/scripts/disk-led.sh`](../boot/config/scripts/disk-led.sh) (lifecycle/control)
and [`boot/config/scripts/disk-led.pl`](../boot/config/scripts/disk-led.pl) (the GPIO engine)
Installed + started by: [`boot/config/go`](../boot/config/go)

Lights the **six green front-bay LEDs** from real disk activity — the thing ADM does out of
the box but stock Unraid does not. On Unraid these LEDs sit dark even with the Asustor
platform driver installed; this brings them back.

## Why Unraid doesn't do this itself

On most Linux distros the Asustor driver "just works": it registers LED devices named
`sata1:green:disk` … `sata6:green:disk` and the kernel's `disk-activity` trigger blinks
them. **Unraid's kernel is built without the pieces that make that happen.** Confirmed
against Unraid's own kernel configs (5.19 → 6.12 → the 6.18 on this box):

```
# CONFIG_LEDS_GPIO is not set            <- no driver to create the sataN:*:disk LED devices
# CONFIG_LEDS_TRIGGER_DISK is not set    <- no "disk-activity" trigger to blink them
# CONFIG_KEYBOARD_GPIO_POLLED is not set
CONFIG_LEDS_CLASS=m                      <- the LED class itself IS present (NIC LEDs use it)
```

So the Asustor `asustor` module advertises a `leds-gpio` platform device, but with no
`leds-gpio` driver to bind it, **no `/sys/class/leds/sata*` entries are ever created** and
the lines are never driven. This has been the case on every Unraid kernel checked — it has
never worked on stock Unraid, and it's a kernel-config gap, not a misconfiguration.

The "proper" fix (Path B) would be to compile three out-of-tree kernel modules
(`leds-gpio`, `ledtrig-disk`, `ledtrig-blkdev`) against the exact Unraid kernel and rebuild
them on every Unraid update. This script takes the lighter path: drive the GPIO lines from
userspace and emulate the trigger. Full background in
[asustor-platform-driver.md](./asustor-platform-driver.md).

## Why Perl (not Python / gpioset / C)

> **The first question everyone asks.** With no `leds-gpio` and no `/sys/class/gpio`
> (legacy sysfs-GPIO is also compiled out), the *only* way to drive these lines is the
> **GPIO character device** (`/dev/gpiochipN`), which requires `ioctl()` calls with packed
> C structs. So the real question is "what on a stock Unraid box can issue that ioctl?":
>
> | Candidate | Why not |
> | --------- | ------- |
> | **bash** | Can't do `ioctl()` at all, and the sysfs-GPIO fallback is gone. |
> | **`gpioset`** (libgpiod) | The natural tool — but **not in Unraid's base**; needs a package you'd have to persist and reinstall every kernel update. |
> | **C helper** | Lowest overhead, but there is **no compiler** on the box; means shipping a cross-compiled binary blob with kernel-ABI fragility. |
> | **python3** | Would be clean (`fcntl.ioctl`) — but **also not installed** (NerdTools dependency). |
> | **perl** | **Already in Unraid's base image** (`/usr/bin/perl`), with `sysopen` + `ioctl` + `pack`/`unpack` + `select` — using only the core `Fcntl` module. **Zero install, no compiler, no plugins.** |
>
> Perl is chosen by elimination, not elegance: it's the one capable interpreter that's part
> of the OS itself, so the whole feature survives a USB-flash restore and Unraid upgrades
> with nothing extra to fetch or rebuild.

## Bay → LED → disk mapping

Facing the unit, **left → right**. The green-LED GPIO offsets were verified on this
hardware with the `test` sweep and cross-checked against the driver's `AS6706` table; the
disk side is resolved at runtime from the ata port (so it follows the physical bay, not the
`sdX` letter, which can change):

| Bay | Green LED GPIO offset | SATA port | Device (at capture) |
| --- | --------------------- | --------- | ------------------- |
| 1 (leftmost) | 12 | ata1 | `sda` |
| 2 | 46 | ata2 | `sdb` |
| 3 | 51 | ata3 | `sdc` |
| 4 | 63 | ata4 | `sdd` |
| 5 | 61 | ata5 | `sde` |
| 6 (rightmost) | 58 | ata6 | `sdf` |

The red fault LEDs (`sataN:red:disk`, active-low) are deliberately **left untouched** — the
daemon only requests the six green lines.

## What it does, in one paragraph

Every `INTERVAL_MS` (default 100 ms) the Perl engine reads `/proc/diskstats`, and for each
bay compares its disk's completed-I/O counter to the previous tick. Changed → that bay's
green LED is on for the tick; unchanged → off. The result is a flicker that tracks activity,
just like the hardware trigger would — which, notably, also works by polling block-device
stats on an interval, so this is no more wasteful than the in-kernel approach. The engine
holds all six GPIO lines for its whole lifetime via one line-request fd and sets them in a
single ioctl per tick.

## Key design decisions

- **Resolve the chip by name, the disks by ata port.** The engine scans `/dev/gpiochip*`
  and picks the one whose chip name matches `it87` (not a hardcoded `gpiochip0`), and maps
  bay → `sdX` by the ata port number — both survive renumbering and hotplug.
- **Spin-down safe.** It only reads `/proc/diskstats` (in-kernel counters), which **never
  wakes a spun-down disk** and generates no disk I/O. A standby disk simply shows no counter
  change, so its LED stays off — which is also correct.
- **No USB-flash wear.** All state is in RAM: the log is `/var/log` (tmpfs) and the override
  file is `/dev/shm`. Nothing in the loop ever writes to `/boot`.
- **Manual control coexists with activity mode.** `locate`/`on`/`off` write to a tmpfs
  override file the daemon reads each tick, so a single owner keeps the lines while you can
  still force a bay (e.g. to find a drive) without stopping the daemon.
- **Self-contained.** Pure Perl + core `Fcntl` via the GPIO chardev. No gpioset, no python,
  no compiler, no plugins — see *Why Perl* above.

## Tunables

At the top of [`disk-led.sh`](../boot/config/scripts/disk-led.sh):

| Variable | Value | Meaning |
| -------- | ----- | ------- |
| `INTERVAL_MS` | `100` | activity poll interval (10 Hz). 150–250 lowers idle CPU wakeups further with no visible difference |
| `GREEN_OFFSETS` | `12 46 51 63 61 58` | bay 1→6 green-LED GPIO line offsets (left→right) |
| `NBAYS` | `6` | number of front bays |

## Usage

```bash
disk-led.sh start            # start the daemon (forks via setsid, writes a pidfile)
disk-led.sh stop             # stop and release the lines (LEDs go dark)
disk-led.sh restart
disk-led.sh status           # daemon state, chip presence, and the live bay -> disk map
disk-led.sh test             # identify sweep: all on, then bay 1..6 in turn
disk-led.sh locate N [secs]  # blink bay N to find a drive (auto-clears after secs, if given)
disk-led.sh on N | off N     # force bay N's green LED on/off
disk-led.sh auto [N|all]     # clear override(s) -> back to activity mode
```

- PID file: `/var/run/disk-led.pid`
- Log: `/var/log/disk-led.log` (tmpfs)
- Override file: `/dev/shm/disk-led.ctl` (tmpfs)

`status` is the quick health check — it prints the daemon state, whether the GPIO chip is
present, and each bay's current `sdX` mapping.

## Resource cost

Featherweight, and lighter than the SMART/temperature polling already running. Per tick it
reads one procfs file and issues one ioctl; at 10 Hz that's well under 0.5 % of one core, no
measurable heat, and no fan-curve impact. The only genuine care-abouts are baked in: never
poke the disks directly (uses `/proc/diskstats`), and never write to the USB flash (RAM-only
state). The single tiny trade-off is that 10 Hz wakeups keep the CPU out of its very deepest
idle state slightly more often — fractions of a watt; raise `INTERVAL_MS` to trim it.

## How it's wired into boot

From [`boot/config/go`](../boot/config/go):

```bash
install -m 755 /boot/config/scripts/disk-led.pl /usr/local/sbin/disk-led.pl
install -m 755 /boot/config/scripts/disk-led.sh /usr/local/sbin/disk-led.sh
/usr/local/sbin/disk-led.sh start
```

`run_loop` waits up to 30 s for `/dev/gpiochip0` to appear (the boot race with the driver
loading) before handing off to the Perl engine.

## Prerequisite

The `/dev/gpiochip*` for the IT8625 only exists if the **Asustor platform driver** is
installed (it provides `asustor_gpio_it87`) — see
[asustor-platform-driver.md](./asustor-platform-driver.md). If `disk-led.sh status` reports
the chip as `MISSING`, that driver isn't loaded.
