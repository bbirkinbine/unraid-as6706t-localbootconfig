# NVMe disk-activity indicator (green status LED)

Part of the [disk-activity LED daemon](./disk-leds.md) — same scripts
([`disk-led.sh`](../boot/config/scripts/disk-led.sh) lifecycle /
[`disk-led.pl`](../boot/config/scripts/disk-led.pl) engine), installed + started by
[`go`](../boot/config/go).

Repurposes the front-panel green **status** LED (`gpled1`, GP47) as an aggregate
**NVMe-activity** light. The internal M.2 NVMe slots have no front-panel LED of their own,
so everything that hits the NVMe cache pool — the BTRFS write cache, the mover's source
reads, Docker/appdata, any VMs — was invisible on the front panel even though it's often
the busiest storage in the box. Now that one green LED flickers whenever any NVMe is busy,
the same way the six bay LEDs flicker for the SATA disks. It also loosely echoes ADM,
where the green status LED blinks during system activity.

> **One remaining check, deferred by choice.** The engine drives `gpled1` through its
> hwmon **sysfs value node** and self-disables cleanly if that node is absent or rejects
> writes — so shipping it is safe regardless. What hasn't been eyeballed yet is whether the
> LED *physically* lights when toggled on this box. See
> [Verifying on the box](#verifying-on-the-box).

## Why the NVMe slots had no light

The six front bays each have a green LED the [daemon](./disk-leds.md) drives from
`/proc/diskstats`. The internal **M.2 NVMe slots have no dedicated front-panel LED** —
they sit behind the chassis with no tray and no light pipe. The only spare, repurposable
green LED on the front is the **status LED** (`gpled1`, GP47), which `go` already
neutralized at boot (`gpled1_blink=0`). Pegging that otherwise-static light to NVMe
activity turns it into useful telemetry at no extra hardware cost.

## One LED, several drives → an aggregate flicker

A single LED can't show per-drive activity, so the indicator is an **aggregate**: it's on
when *any* `nvme*` namespace did I/O this tick, off otherwise. That's the same flicker
model as one bay LED, just OR'd across every NVMe device:

- **Idle → dark.** No NVMe I/O ⇒ LED off.
- **Activity → flicker.** Any NVMe I/O in a tick lights it for that tick.

So the whole front panel reads consistently: dark = quiet, flicker = working.

## How it works

The key difference from the bay LEDs: `gpled1` is controlled through **hwmon sysfs**
(`/sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1`), not the GPIO character
device. The bay LEDs needed Perl + the chardev precisely *because* they have no `/sys`
interface ([why Perl](./disk-leds.md#why-perl-not-python--gpioset--c)); the status LED
*does* have one, so this rides along as a plain file write — simpler, not harder.

Folded into the existing engine (no second process):

- **At startup** (after the boot race for the GPIO chip, and skipped for one-shot `test`
  sweeps): resolve `gpled1` by glob and require the value node to be **writable**; write
  `0` to `gpled1_blink` so the hardware blink can't fight the software toggling. If no
  writable node is found, log once and leave the indicator off — the bay LEDs are
  unaffected.
- **Each tick** (the same ~100 ms loop the bay LEDs use): sum the completed-I/O counters
  of all matching `nvme*` namespaces in `/proc/diskstats`; if the sum moved since the
  previous tick → write `1`, else `0`. **Writes happen only on change**, so a quiet pool
  issues no writes at all and a busy one writes at most twice per flicker edge. A write
  error self-disables the indicator (logged once) rather than spamming the log.
- **On stop / exit:** the LED is set to `0` (dark), same clean release as the bay lines.

## NVMe device selection

Matches **whole namespaces** in `/proc/diskstats` — `^nvme[0-9]+n[0-9]+$` — which excludes
partitions (`...p1`). Devices are enumerated dynamically every tick, so the **count
doesn't matter to the design**: the AS6706T ships with **2 × M.2 NVMe** per spec
([hardware.md](./hardware.md)), but if this box actually has more, they're picked up
automatically. (Confirm the real count on the box and fix `hardware.md` if it differs.)

## Properties (inherited from the daemon)

- **No USB-flash wear.** `gpled1*` are driver/hwmon attributes, not files on `/boot`.
- **Spin-down safe.** Only `/proc/diskstats` is read (in-kernel counters) — no disk is
  touched, and NVMe doesn't spin down anyway.
- **Negligible cost.** The diskstats read already happens for the bay LEDs; this adds one
  conditional sysfs write per flicker edge. No measurable heat or fan-curve impact.

## Tunables

At the top of [`disk-led.sh`](../boot/config/scripts/disk-led.sh), alongside the bay-LED
tunables:

| Variable | Value | Meaning |
| -------- | ----- | ------- |
| `NVME_ACTIVITY` | `1` | `1` = drive the status LED from NVMe activity; `0` = leave `gpled1` alone (old "solid, not blinking" behavior) |
| `GPLED_GLOB` | `/sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1` | the status-LED **value** node (resolved by glob, since `hwmon`/`asustor_it87` numbers shift across boots). The blink node is the same path + `_blink`. |
| `NVME_REGEX` | `^nvme[0-9]+n[0-9]+$` | which `/proc/diskstats` devices count as NVMe |

## Usage

There's nothing to run — the indicator is part of the daemon and starts with it. The state
shows up in `status`:

```bash
disk-led.sh status
```

```
daemon : RUNNING (pid 1234)
...
  bay1 (gpio 12) -> sda
  ... (bays 2..6) ...
nvme   : indicator ON -> green status LED /sys/devices/platform/asustor_it87.0/hwmon/hwmon3/gpled1
         aggregating: nvme0n1 nvme1n1
overrides: none (all bays = activity)
```

If the value node can't be found/written, `status` shows
`green status LED MISSING (no writable gpled1)` and the daemon logs the same to
`/var/log/disk-led.log` — the bay LEDs keep working regardless.

## How it's wired into boot

Same install/start as the bay LEDs (from [`go`](../boot/config/go)) — it's the same
daemon. The one extra detail is the status LED's blink: `go` still pre-seeds
`gpled1_blink=0` so the LED isn't blinking before the daemon grabs it (and so the old solid
behavior is preserved if `NVME_ACTIVITY=0`), and the daemon re-asserts `gpled1_blink=0`
itself when it takes over.

## Verifying on the box

The deferred check is purely visual — does writing `1`/`0` to `gpled1` actually light the
LED? Watch the front panel during NVMe I/O (e.g. while the mover runs or a large write
lands on the cache pool); it should flicker green. To test the node directly without the
daemon:

```bash
g=$(ls /sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1 | head -1)
echo 0 > "${g}_blink"            # hardware blink off
echo 1 > "$g"; sleep 2           # expect: solid green
echo 0 > "$g"; sleep 2           # expect: dark
```

If the LED **doesn't** respond (e.g. only `gpled1_blink` is writable, no value node), the
indicator self-disables and the fallbacks noted in the
[original design](#nvme-disk-activity-indicator-green-status-led) apply: a coarse
"blink while recently active" mode using `gpled1_blink`, or driving the LED on the GPIO
chardev like the bay LEDs (its line offset would have to be discovered — the driver's
`GP47` name is not necessarily chardev offset 47, which is already the bay-2 *red* line).

## Prerequisite

Like everything else here, the `gpled1` hwmon node only exists if the **Asustor platform
driver** is installed — see [asustor-platform-driver.md](./asustor-platform-driver.md). If
`disk-led.sh status` reports the LED as `MISSING`, that driver isn't loaded (or the value
node isn't named `gpled1` on your firmware — adjust `GPLED_GLOB`).
