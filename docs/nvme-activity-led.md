# NVMe disk-activity indicator (green status LED)

Part of the [disk-activity LED daemon](./disk-leds.md) — same scripts
([`disk-led.sh`](../boot/config/scripts/disk-led.sh) lifecycle /
[`disk-led.pl`](../boot/config/scripts/disk-led.pl) engine), installed + started by
[`go`](../boot/config/go).

Repurposes the front-panel green **status** LED (`it87_gp47`) as an aggregate
**NVMe-activity** light. The internal M.2 NVMe slots have no front-panel LED of their own,
so everything that hits the NVMe cache pool — the BTRFS write cache, the mover's source
reads, Docker/appdata, any VMs — was invisible on the front panel even though it's often
the busiest storage in the box. Now that one green LED flickers whenever any NVMe is busy,
the same way the six bay LEDs flicker for the SATA disks. It also loosely echoes ADM,
where the green status LED blinks during system activity.

> **Verified on the hardware** (AS6706T, Unraid 7.3.1): idle → dark; an SMB write to the
> cache pool flickers it (NVMe writes, mirrored to both M.2 drives); a `mover` run flickers
> it from the cache *reads*. See [How it was verified](#how-it-was-verified).

## Why the NVMe slots had no light

The six front bays each have a green LED the [daemon](./disk-leds.md) drives from
`/proc/diskstats`. The internal **M.2 NVMe slots have no dedicated front-panel LED** — they
sit behind the chassis with no tray and no light pipe. The only spare, repurposable green
LED on the front is the **status LED** (`it87_gp47`), which `go` already neutralized at
boot (`gpled1_blink=0`, to stop a fresh install's annoying blink). Pegging that otherwise-
idle light to NVMe activity turns it into useful telemetry at no extra hardware cost.

## Choosing what the LED does (`STATUS_LED`)

Because this hijacks a shared front-panel LED, it's a **setting**, not a fixed behavior —
set `STATUS_LED` at the top of [`disk-led.sh`](../boot/config/scripts/disk-led.sh):

| `STATUS_LED` | The green status LED… |
| ------------ | --------------------- |
| `nvme` *(default)* | flickers on aggregate NVMe activity (idle = dark) |
| `off` | is forced **dark** |
| `on` | is forced **solid green** |

The daemon **holds the GPIO line and actively drives it**, so `off` is genuinely dark and
`on` genuinely solid *while the daemon runs* — regardless of the LED's power-on resting
state. `off` is the clean way to keep the pre-feature "no distracting light" behavior. (When
the daemon is **stopped**, the line is released and the pin reverts to its hardware default,
which is solid-on — same as the bay LEDs returning to their default on release.)

The rest of this doc describes the default `nvme` mode.

## One LED, several drives → an aggregate flicker

A single LED can't show per-drive activity, so the indicator is an **aggregate**: it's on
when *any* `nvme*` namespace did I/O this tick, off otherwise. That's the same flicker model
as one bay LED, just OR'd across every NVMe device:

- **Idle → dark.** No NVMe I/O ⇒ LED off.
- **Activity → flicker.** Any NVMe I/O in a tick lights it for that tick.

(OR-ing matters in practice: BTRFS RAID1 mirrors *writes* to both M.2 drives but serves
*reads* from just one, so a mover run shows activity on only one device — the aggregate
catches it either way.)

## How it works

Unlike the documented `gpled1` hwmon nodes (`gpled1_blink` / `gpled1_blink_freq`), there is
**no on/off value node** for this LED — the only steady on/off control is the **GPIO
character device**, the very same mechanism the bay LEDs use
([why](./disk-leds.md#why-perl-not-python--gpioset--c)). So the status LED is driven exactly
like a bay LED: a line request on the it87 gpiochip, set via `ioctl`.

Two hardware facts (both confirmed live, see below) shape the implementation:

- **The pin is active-low** — it lights when driven *low*. The line request sets the uAPI
  `GPIO_V2_LINE_FLAG_ACTIVE_LOW` flag, so the kernel inverts for us and the code stays
  plain (logical `1` = on, `0` = off).
- **Its released/default state is solid-on**, so the LED only behaves while the daemon is
  holding the line.

Folded into the existing engine (no second process):

- **At startup** (after the boot race for the GPIO chip; skipped for one-shot `test`
  sweeps): request `it87_gp47` (offset 31) as a **separate one-line output** (kept out of
  the bay sweep) with the active-low flag. `off`/`on` set the value once — it latches while
  the line is held; `nvme` starts it dark and then drives it per-tick. If the line request
  fails, log once and disable — the bay LEDs are unaffected.
- **Each tick** (`nvme` mode only; the same ~100 ms loop the bay LEDs use): sum the
  completed-I/O counters of all matching `nvme*` namespaces in `/proc/diskstats`; if the sum
  moved since the previous tick → drive `1`, else `0`. **Writes happen only on change**, so
  a quiet pool issues no `ioctl`s at all and a busy one writes at most twice per flicker edge.
- **On stop / exit:** the line is driven to `0` and released (after which the pin floats
  back to its solid-on default).

## NVMe device selection

Matches **whole namespaces** in `/proc/diskstats` — `^nvme[0-9]+n[0-9]+$` — which excludes
partitions (`...p1`). Devices are enumerated dynamically every tick, so the **count doesn't
matter to the design**. Confirmed on this box: **2 × M.2 NVMe** (`nvme0n1`, `nvme1n1`) — the
BTRFS RAID1 cache pool — matching the AS6706T spec ([hardware.md](./hardware.md)).

## Properties (inherited from the daemon)

- **No USB-flash wear.** The status LED is driven by a GPIO `ioctl`, not a file on `/boot`.
- **Spin-down safe.** Only `/proc/diskstats` is read (in-kernel counters) — no disk is
  touched, and NVMe doesn't spin down anyway.
- **Negligible cost.** The diskstats read already happens for the bay LEDs; this adds one
  conditional `ioctl` per flicker edge. No measurable heat or fan-curve impact.

## Tunables

At the top of [`disk-led.sh`](../boot/config/scripts/disk-led.sh), alongside the bay-LED
tunables:

| Variable | Value | Meaning |
| -------- | ----- | ------- |
| `STATUS_LED` | `nvme` | what the green status LED does: `nvme` = NVMe-activity flicker (default), `off` = forced dark, `on` = forced solid (see [Modes](#choosing-what-the-led-does-status_led)) |
| `STATUS_OFFSET` | `31` | GPIO chardev line offset of the status LED (`31` = `it87_gp47` on the AS6706T) |
| `NVME_REGEX` | `^nvme[0-9]+n[0-9]+$` | which `/proc/diskstats` devices count as NVMe (only used in `nvme` mode) |

## Usage

There's nothing to run — the indicator is part of the daemon and starts with it. The state
shows up in `status`:

```bash
disk-led.sh status
```

```
daemon : RUNNING (pid 1022316)
...
  bay1 (gpio 12) -> sda
  ... (bays 2..6) ...
led    : status LED = NVMe activity (gpio offset 31)
led    :   aggregating nvme0n1 nvme1n1
overrides: none (all bays = activity)
```

In `off`/`on` mode the `led` line reads `status LED forced OFF` / `forced ON / solid`
instead.

## How it's wired into boot

Same install/start as the bay LEDs (from [`go`](../boot/config/go)) — it's the same daemon.
The one extra detail is `go`'s `gpled1_blink=0` pre-seed: a fresh Unraid install leaves this
LED blinking, and disabling the chip's hardware blink there ensures the blink generator
can't fight the daemon's GPIO data-register control once the daemon grabs the line.

## How it was verified

The mechanism was settled directly on the box, because the obvious sysfs path turned out
not to exist:

1. **No value node.** The asustor driver exposes only `gpled1_blink` / `gpled1_blink_freq`
   for this LED — hardware-blink control, no on/off value. So a sysfs toggle was a dead end.
2. **The GPIO line works.** Probing the it87 gpiochip showed `it87_gp47` at line **offset
   31**, free to request as an output; driving it on/off visibly toggled the LED.
3. **Active-low.** With the daemon driving logical-`0` at idle the LED stayed *lit*, so the
   pin lights when low → the `ACTIVE_LOW` flag was added, after which idle went **dark**.
4. **Activity flicker**, confirmed by sampling `/proc/diskstats` alongside the LED: an SMB
   copy drove ~1,700 writes/s to **both** M.2 drives (RAID1 mirror) → flicker; a `mover` run
   drove continuous **reads** from one drive → flicker; idle → no I/O → dark.

(One observation from testing: the LED leads Unraid's web-UI activity display by a second or
two — the daemon samples the kernel counters 10×/s in real time, while the web UI polls only
every few seconds.)

## Prerequisite

The it87 `/dev/gpiochip*` only exists if the **Asustor platform driver** is installed (it
provides `asustor_gpio_it87`) — see [asustor-platform-driver.md](./asustor-platform-driver.md).
If `disk-led.sh status` reports the chip as `MISSING`, that driver isn't loaded. If the
status LED is on a different GPIO line on your firmware, adjust `STATUS_OFFSET`.
