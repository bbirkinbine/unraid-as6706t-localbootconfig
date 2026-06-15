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

## NVMe disk-activity indicator — on-box verification

**Implemented:** the disk-activity daemon now flickers the front-panel green **status** LED
(`gpled1`) on aggregate NVMe activity via the LED's hwmon sysfs node — see
[docs/nvme-activity-led.md](docs/nvme-activity-led.md). The code self-disables cleanly if the
node isn't writable, so two visual checks were deliberately deferred rather than blocking:

- [ ] Confirm `gpled1` physically lights when toggled (watch the front panel during NVMe I/O,
      or run the snippet in the doc). If only `gpled1_blink` works, switch to the coarse-blink fallback.
- [ ] Confirm the real NVMe device count (2 per spec vs 4 mentioned); fix [hardware.md](docs/hardware.md) if it differs.
