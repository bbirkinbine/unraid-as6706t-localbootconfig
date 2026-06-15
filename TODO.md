# TODO

Future work for this repo. Each item links to its design doc where one exists.

## Per-bay red / fault LEDs (disk error indication)

Drive the six **red** front-bay LEDs from Unraid's disk-fault state, mirroring how
ADM lights a failed drive's tray red. This builds directly on the existing
[disk-activity green-LED daemon](docs/disk-leds.md) — the red GPIO lines are already
known (offsets `13 47 52 48 62 60`, **active-low**) and are currently left untouched.

**Status:** researched + designed, **not implemented.** Blocked on one quick hardware
check — whether each bay's green+red is a single **bi-color LED** that blends to
**amber** (giving a 3-state green / amber / red scheme like ADM) or two discrete
colors (so green/red only, using solid-vs-blink red for fault-vs-warning). The blend
test (`green+red` on one bay) needs the array idle and was deferred while the mover
was running.

**Design + research write-up:** [docs/disk-fault-leds.md](docs/disk-fault-leds.md)

Checklist:

- [ ] Confirm the amber blend on a bay (drive green+red together) — settles 3-state vs 2-state.
- [ ] Extend `disk-led.pl` to also request the red lines (active-low → raw `0` = on).
- [ ] Poll `/var/local/emhttp/disks.ini` (+ `var.ini` for `mdState`) every ~15 s; join by `device` to the existing bay map.
- [ ] Map: `color=red` / `DISK_DSBL` / `numErrors>0` / SMART `FAILED` → **solid red**;
      `color=yellow` (rebuilding / not-ready) → **amber or blink red**; **gate all on `mdState="STARTED"`** (a stopped array reports parity as `DISK_INVALID` / `yellow-on`, which is not a fault).
- [ ] Decide SMART-warning and empty-bay behavior (proposed defaults: blink for SMART/`numErrors`, leave empty bays alone).
- [ ] Document + wire into `go` (same install/start pattern; likely the same daemon, not a new one).

## NVMe disk-activity indicator (green status LED)

Repurpose the front-panel green **status** LED (`gpled1`, GP47) — currently neutralized at
boot via `gpled1_blink=0` — to **flicker on NVMe activity**, so the internal M.2 cache pool
gets the same at-a-glance activity telemetry the six SATA bays already have. Single LED,
several drives → an **aggregate** "any NVMe doing I/O?" flicker; idle = dark, activity =
flicker (same model as a bay LED). Like the fault LEDs, this extends the existing
[disk-activity daemon](docs/disk-leds.md) rather than adding a second process.

**Status:** researched + designed, **not implemented.** Blocked on one quick hardware check
— whether the `gpled1` hwmon node accepts a direct `1`/`0` value write (→ simple per-tick
sysfs toggle) or only exposes `gpled1_blink` (→ fall back to a coarse "recent-activity"
blink, or to the GPIO chardev). Unlike the bay LEDs this LED *has* a sysfs interface, so the
sysfs path is simpler than the chardev — if the value node exists.

**Design + research write-up:** [docs/nvme-activity-led.md](docs/nvme-activity-led.md)

Checklist:

- [ ] Confirm which physical LED `gpled1`/GP47 is and its current resting state (solid vs off) on the box.
- [ ] Confirm `gpled1` accepts a direct `1`/`0` value write (vs only `gpled1_blink`) — settles sysfs vs chardev.
- [ ] Confirm the NVMe device names/count (2 per spec vs 4 mentioned); correct [hardware.md](docs/hardware.md) if needed.
- [ ] Extend `disk-led.pl` to drive `gpled1` from NVMe-aggregate activity (write-on-change; set `gpled1_blink=0` first).
- [ ] Extend `disk-led.sh`: `NVME_ACTIVITY` / `GPLED_GLOB` / `NVME_REGEX` config + show the indicator in `status`.
- [ ] Reconcile the `go` `gpled1_blink=0` step with the daemon now owning the LED.
- [ ] Document + wire into `go` (same daemon, not a new one).
