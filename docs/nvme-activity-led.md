# NVMe disk-activity indicator (green status LED) — design & research (future work)

> **Status: planned, not implemented.** This captures the research and proposed design
> so it can be built later. Tracked in [TODO.md](../TODO.md). It extends the working
> [disk-activity green-LED daemon](./disk-leds.md).

The goal: repurpose the front-panel green **status** LED — the one `go` currently
neutralizes at boot — to **flicker on NVMe activity**, so the internal M.2 cache pool
gets the same at-a-glance activity telemetry the six SATA bays already have.

## Why the NVMe slots have no activity light today

The six front bays each have a green LED that the
[disk-activity daemon](./disk-leds.md) drives from `/proc/diskstats`. The internal
**M.2 NVMe slots have no dedicated front-panel LED at all** — they sit behind the
chassis with no tray and no light pipe. So everything that hits the NVMe cache pool —
the BTRFS write cache, the mover's source reads, Docker/appdata, any VMs — is
**completely invisible on the front panel**, even though it's often the busiest storage
in the box.

There is exactly **one spare, repurposable green LED** on the front: the **status LED**
(`gpled1`, GP47), which the `go` script currently neutralizes:

```bash
# from boot/config/go
for f in /sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1_blink; do
  [ -w "$f" ] && echo 0 > "$f"
done
```

Pegging that otherwise-static LED to aggregate NVMe activity turns a light that conveys
nothing dynamic into useful telemetry — and it loosely echoes ADM, where the green
system-status LED blinks during system activity.

## Current behavior of the status LED (confirm on box)

`go` writes `0` to `gpled1_blink`. Per [front-panel-lcd.md](./front-panel-lcd.md) this
disables the *blink* so the LED **sits solid**; in practice it's recalled as sitting
**off**. Either way it conveys nothing dynamic today, so repurposing it loses no
information. **The exact resting state (solid vs off) should be confirmed on the box**,
since the indicator replaces whatever that resting state currently is.

The mechanism difference that matters: this LED is controlled through **hwmon sysfs**
(`/sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1*`) — *not* through the GPIO
character device the bay LEDs use. The bay LEDs needed Perl + the chardev precisely
*because* they have no `/sys` interface ([why Perl](./disk-leds.md#why-perl-not-python--gpioset--c)).
The status LED **does** have one, so this indicator can be a plain sysfs write — simpler
than the bay-LED path, not harder.

## One LED, several drives → an aggregate flicker

A single LED can't show per-drive activity, so the indicator is necessarily an
**aggregate**: "did *any* NVMe namespace do I/O this tick?" That's the same flicker model
as one bay LED, just OR'd across every `nvme*` device.

Chosen behavior (see the design question that settled it):

- **Idle → dark.** When no NVMe is doing I/O, the LED is off.
- **Activity → flicker.** Any NVMe I/O in a tick lights it for that tick.

This mirrors exactly how the six bay LEDs already behave, so the whole front panel reads
consistently: dark = quiet, flicker = working.

## Mechanism (proposed): sysfs toggle, not the chardev

Because `gpled1` is exposed via hwmon sysfs, the natural engine is a per-tick sysfs
write — no `ioctl`, no chardev line request:

1. **Once at startup:** write `0` to `gpled1_blink` so the hardware blink can't fight our
   software toggling (this subsumes the current `go` step).
2. **Each tick:** if any `nvme*` counter changed since the previous tick → `echo 1 >
   gpled1`; otherwise → `echo 0 > gpled1`. **Write only when the state changes**, so a
   quiet pool issues no writes at all and a busy one writes at most twice per flicker.

Properties carry over from the existing daemon:

- **No USB-flash wear.** `gpled1*` are driver/hwmon attributes, not files on `/boot`.
- **Spin-down safe.** It reads only `/proc/diskstats` (in-kernel counters), so it never
  touches a disk — and NVMe doesn't spin down anyway.
- **Negligible cost.** It reuses the activity poll the daemon already runs; the only
  addition is one conditional sysfs write per state change.

## Open question (blocks the final design): does `gpled1` accept direct on/off?

The plan above assumes a **writable value node** — i.e. `gpled1` itself takes `1`/`0` —
alongside the known `gpled1_blink`. This must be confirmed on the box, the same way the
fault-LED design is blocked on the amber-blend test.

**Quick test (daemon for the bay LEDs can stay running — this only touches `gpled1`):**

```bash
# find the node
ls /sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1*
g=$(ls /sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1 | head -1)
echo 0 > "${g}_blink"            # make sure hardware blink is off
echo 1 > "$g"; sleep 2           # should go solid green
echo 0 > "$g"; sleep 2           # should go dark
```

- **It toggles** → use the sysfs path above. Done.
- **Only `gpled1_blink` is writable (no value node)** → fall back to one of:
  - **(a) Coarse "recent-activity" mode.** Enable `gpled1_blink` whenever NVMe was active
    in the last few seconds, disable it when idle. Loses fine per-tick flicker but still
    signals "the cache pool is busy," using only the node we know exists.
  - **(b) Drive it on the GPIO chardev** like the bay LEDs. This needs the status LED's
    chardev **line offset**, which must be *discovered, not assumed*: the driver's
    `GP47` name does **not** necessarily equal chardev offset 47 (offset 47 is already the
    bay-2 *red* line in the [fault-LED map](./disk-fault-leds.md)), and the driver may
    already claim the status LED as a managed LED, leaving its line unavailable on the
    chardev. More work and more fragile than sysfs — only if (a) won't do.

## Where it lives (proposed): fold into the existing daemon

Extend the *same* daemon rather than adding a second process — the same call the
[fault-LED design](./disk-fault-leds.md#proposed-implementation) makes:

- **`disk-led.pl`** already reads `/proc/diskstats` every ~100 ms and already sees the
  `nvme*` rows in its activity map (it doesn't filter them out). Add: compute the
  NVMe-aggregate "changed?" boolean each tick and drive `gpled1` via sysfs (write-on-change).
- **`disk-led.sh`** gains the config (enable flag, the `gpled1` sysfs glob, the NVMe
  device regex) and reports the indicator's state in `status`.
- **`go`** — the daemon now *owns* `gpled1`, so its startup re-asserts `gpled1_blink=0`
  itself; the standalone `gpled1_blink` loop in `go` becomes redundant and can be removed
  (or left as a harmless pre-seed). Document the hand-off either way.

Rationale: one process, one `/proc/diskstats` read per tick already happening, and the
bay greens keep doing their thing on the same loop — the NVMe indicator is just one more
output of it.

## NVMe device selection

- Match **whole namespaces** in `/proc/diskstats` — `^nvme\d+n\d+$` — and exclude
  partitions (`...p1`) so the match is clean. (For a boolean "any activity" even
  partitions wouldn't hurt, but the whole-namespace match is tidier.)
- **Count:** the AS6706T ships with **2 × M.2 NVMe** slots per spec
  ([hardware.md](./hardware.md)); there may be more in this box (an M.2 expansion or
  different layout was mentioned). The daemon **enumerates `nvme*` dynamically**, so the
  count doesn't change the design — but the actual devices/count should be confirmed on
  the box and `hardware.md` corrected if it really is 4.

## Proposed tunables

At the top of [`disk-led.sh`](../boot/config/scripts/disk-led.sh), alongside the existing
ones:

| Variable | Proposed default | Meaning |
| -------- | ---------------- | ------- |
| `NVME_ACTIVITY` | `1` | enable the NVMe-activity status-LED indicator |
| `GPLED_GLOB` | `/sys/devices/platform/asustor_it87.*/hwmon/hwmon*/gpled1` | the status-LED value node (resolved by glob, like the existing defensive patterns) |
| `NVME_REGEX` | `^nvme[0-9]+n[0-9]+$` | which `/proc/diskstats` devices count as NVMe |

## Cost

Negligible, and strictly less than the bay-LED work it rides along with: it adds nothing
to the poll (the diskstats read already happens) and at most one sysfs write per flicker
edge. No disk I/O, no flash wear, no measurable heat or fan-curve impact — the same
profile as [disk-leds.md](./disk-leds.md#resource-cost).

## Checklist

(Also tracked in [TODO.md](../TODO.md).)

- [ ] Confirm which physical LED `gpled1`/GP47 is and its current resting state (solid vs off) on the box.
- [ ] Confirm `gpled1` accepts a direct `1`/`0` value write (vs only `gpled1_blink`) — settles sysfs vs chardev.
- [ ] Confirm the NVMe device names/count (2 vs 4); correct [hardware.md](./hardware.md) if needed.
- [ ] Extend `disk-led.pl`: NVMe-aggregate activity → drive `gpled1` (write-on-change; `gpled1_blink=0` first).
- [ ] Extend `disk-led.sh`: `NVME_ACTIVITY` / `GPLED_GLOB` / `NVME_REGEX` config + show the indicator in `status`.
- [ ] Reconcile the `go` `gpled1_blink=0` step with the daemon now owning the LED.
- [ ] Document (flip this doc to "implemented") + add the README rows + the boot-wiring note.
