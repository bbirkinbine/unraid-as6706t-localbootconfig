# TODO

Future work for this repo. Each item links to its design doc where one exists.

## Per-bay red / fault LEDs — **shipped** (2-state, ADM-faithful)

The six **red** front-bay LEDs are now driven from Unraid's disk-fault state by the existing
[disk-LED daemon](docs/disk-leds.md): a bay goes **solid red** when its disk is disabled
(`color=red-*` / `DISK_DSBL`), with the green activity flicker suppressed on that bay — mirroring
how ADM lights a failed tray. Strict 2-state (no amber), gated on `mdState="STARTED"`.

**Design + research:** [docs/disk-fault-leds.md](docs/disk-fault-leds.md)

Done:

- [x] Extend `disk-led.pl` to request the six red lines (active-low → logical `1` = on).
- [x] Poll `/var/local/emhttp/disks.ini` (+ `var.ini` for `mdState`) every ~15 s; join by `device` to the bay map.
- [x] `color=red` / `DISK_DSBL` → **solid red**; suppress green on faulted bays; gate all on `mdState="STARTED"`.
- [x] Empty/`_NP` bays left alone; `numErrors`/SMART **not** used to light red (strict disabled-only rule).
- [x] `disk-led.sh fault-test N [secs]` for safe hardware verification; `status` shows per-bay color + fault.
- [x] Docs + same-daemon wiring (`go` unchanged — it already installs both scripts).

Remaining (on-hardware, deploy to nas2):

- [x] Run `disk-led.sh fault-test 1..6` on the box — confirmed each bay lights red **left→right** with green off (verified on NAS-OFFSITE, 2026-06-17). Red offsets `13 47 52 48 62 60` are now hardware-verified, not just from the driver table.
- [ ] Confirm a real/forced `DISK_DSBL` lights the correct bay and clears on rebuild (will trigger naturally; not simulated on the live data array).

## Optional future — amber / 3-state warnings

Add a **warning** state (rebuilding / SMART / read-errors → amber) between green and red. Blocked on
one quick hardware check — whether each bay's green+red is a single **bi-color LED** that blends to
amber (3-state) or two discrete colors (so warning = blink-red). The blend test is in
[docs/disk-fault-leds.md](docs/disk-fault-leds.md) and needs the array idle. The daemon already reads
`DL_FAULT_3STATE` (default off) as the on-switch. The shipped 2-state build does **not** need this.
