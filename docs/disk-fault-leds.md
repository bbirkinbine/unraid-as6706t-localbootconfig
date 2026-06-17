# Per-bay red / fault LEDs (disk-error indication)

Scripts: [`boot/config/scripts/disk-led.sh`](../boot/config/scripts/disk-led.sh) (lifecycle/control)
and [`boot/config/scripts/disk-led.pl`](../boot/config/scripts/disk-led.pl) (the GPIO engine) —
the **same** daemon that drives the green activity LEDs, extended to also drive the reds.

Lights each bay's **red** LED when Unraid has **disabled** that bay's disk (the red-X /
`DISK_DSBL` state), mirroring how Asustor's ADM lights a failed drive's tray red so the disk to
replace is obvious at a glance. On stock Unraid these red lines sit dark (same kernel gap as the
greens — see [disk-leds.md](./disk-leds.md)), so a failed drive otherwise gives **no front-panel
indication at all**.

## Behavior (what it does)

Strict **2-state, ADM-faithful** scheme per bay:

| Bay state | LED |
| --------- | --- |
| Normal | **green** (disk-activity flicker, as before) |
| Disk disabled / failed | **solid red** (green flicker suppressed on that bay) |

There is intentionally **no amber / warning state** — that matches ADM's trays, which are
effectively green-vs-red. Yellow/rebuilding/SMART-warning states are **not** surfaced on the bay
LED (see *Design decisions* below). Amber/3-state remains a clearly-scoped optional future
(`DL_FAULT_3STATE`, not implemented) — see the last section.

## How ADM uses the red bay LED (the behavior we mirror)

Confirmed against ASUSTOR's official documentation for this product family:

- **Drive-tray LED → solid RED = "an access error is detected on a hard drive."**
  ([ASUSTOR online help — Drive](https://www.asustor.com/en/online/online_help?id=30))
- **Normal = green**, which also flickers on activity; in hibernation the tray LED "flashes once
  every 10 seconds."
- The **system status LED** flashes red+green when a drive failure degrades the volume.
  ([What do the LEDs on my NAS mean?](https://www.asustor.com/en/knowledge/detail/?group_id=602))

Net: ADM's per-tray model is **green (normal/activity) vs solid red (failure)** — no per-tray
amber. That is exactly what we implement.

## How Unraid exposes disk faults (the source of truth)

Confirmed against Unraid's own
[`dynamix monitor`](https://github.com/limetech/dynamix/blob/master/plugins/dynamix/scripts/monitor)
decision logic and a live capture on this box (Unraid 7.3.1, kernel 6.18.33-Unraid):

All per-slot state lives in **`/var/local/emhttp/disks.ini`** (one section per slot), refreshed by
emhttp. The authoritative fault signal is the per-disk **`color`** field; `monitor` keys off
`strtok(color,'-')`:

| `color` | meaning | Unraid alert level | our bay LED |
| ------- | ------- | ------------------ | ----------- |
| `green-*` | normal | — | green (activity) |
| `yellow-*` | not ready / reconstructing / parity-sync | warning | **(ignored — no amber)** |
| `red-*` | disabled / `DISK_DSBL` | alert | **solid red** |

- `monitor` skips `flash` and any slot whose `status` ends in `_NP` (missing/not-present). We do
  the same — an absent/missing slot is not lit red.
- Array state is **`mdState`** in `/var/local/emhttp/var.ini`.

### Important nuance: a stopped array is not a fault

Captured live with the array **stopped**, the two parity disks read as `status="DISK_INVALID"` /
`color="yellow-on"` — purely because the array is stopped, not because anything is wrong. The fault
logic therefore **gates on `mdState="STARTED"`**; a stopped array lights nothing. (It would not have
lit anyway under the strict `red-*`-only rule, but the gate is explicit and cheap.)

## Design decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Behavior model | **Strict 2-state** (green / solid-red) | Matches ADM's actual tray behavior; needs no bi-color amber test. |
| What lights red | **Disabled drive only** (`strtok(color,'-') eq 'red'`, i.e. `DISK_DSBL`) | Unraid's canonical "bad drive"; high-confidence, low false-positive. `numErrors`/SMART are not used to light red. |
| Green on a faulted bay | **Suppressed** (red only) | Matches ADM (a failed tray is solid red), and avoids any green+red blend on bi-color bays. |
| Yellow / rebuild / SMART | **Not shown on the bay** | Same as ADM trays; keeps the panel unambiguous. |
| Array stopped | **All reds off** (`mdState != STARTED`) | A stopped array is not a fault. |

## Bay → LED → Unraid slot mapping (this box)

Joins cleanly to the existing bay→`sdX` ata-port map (bay N ↔ ata N), so it follows the physical
bay, not the `sdX` letter:

| Bay | Green offset (active-high) | Red offset (active-low) | SATA | Device@capture | Unraid slot |
| --- | -------------------------- | ----------------------- | ---- | -------------- | ----------- |
| 1 | 12 | 13 | ata1 | sda | parity |
| 2 | 46 | 47 | ata2 | sdb | parity2 |
| 3 | 51 | 52 | ata3 | sdc | disk1 |
| 4 | 63 | 48 | ata4 | sdd | disk2 |
| 5 | 61 | 62 | ata5 | sde | disk3 |
| 6 | 58 | 60 | ata6 | sdf | disk4 |

The red lines are **active-low** (raw `0` = lit). The engine sets the uAPI `ACTIVE_LOW` flag on the
red line-request (exactly as it already does for the front status LED), so logical `1` = lit and the
rest of the code stays plain. (The `cache`/`cache2` NVMe devices are the M.2 slots, not front bays.)

## How it works, in one paragraph

The engine requests the six red lines as a **separate** active-low line-request (kept out of the
active-high green request) and holds them for its lifetime. On a **slow ~15 s cadence**
(`FAULT_POLL_MS`) it reads `var.ini` (`mdState`) and `disks.ini`, joins each bay's `sdX` to its
`color`, and caches a per-bay fault flag — a bay is faulted iff its disk's `color` is `red-*` and the
array is `STARTED`. Every 100 ms tick it then writes the red lines (only on change) from that cached
flag OR'd with any manual `fault-test` override, and **suppresses the green activity bit** for any
faulted bay so it shows red only. The fault check never touches the disks (small tmpfs `.ini` files
only), so it stays spin-down safe and adds negligible cost on top of the activity loop.

## Tunables

At the top of [`disk-led.sh`](../boot/config/scripts/disk-led.sh):

| Variable | Value | Meaning |
| -------- | ----- | ------- |
| `RED_OFFSETS` | `13 47 52 48 62 60` | bay 1→6 red-LED GPIO offsets (active-low) |
| `FAULT_POLL_MS` | `15000` | how often to re-read Unraid disk state (faults change slowly) |
| `DISKS_INI` | `/var/local/emhttp/disks.ini` | per-disk state (overridable for testing) |
| `VAR_INI` | `/var/local/emhttp/var.ini` | array state, for `mdState` (overridable for testing) |
| `FAULT_3STATE` | `0` | reserved: amber/3-state warnings (not implemented) |

## Usage / verification

`disk-led.sh status` now shows the array state and, per bay, the green+red GPIO offsets, the mapped
`sdX`, its Unraid `color`, and a `<== FAULT (red)` marker when disabled.

```bash
disk-led.sh status               # per-bay color + fault state + mdState
disk-led.sh fault-test N [secs]  # force bay N's RED on (green off) to verify the red lines
```

`fault-test` is the safe hardware check — no real disk failure needed. It forces a bay solid red
(green off) via the tmpfs override file; `disk-led.sh auto N` clears it. Run `fault-test 1` … `6`
and confirm each bay lights red left→right and its green goes dark.

To validate the fault *logic* without a failure, point the daemon at crafted state files via
`DL_DISKS_INI` / `DL_VAR_INI` containing `color="red-on"` for one slot and `mdState="STARTED"`, and
confirm the matching bay goes red within one poll; then verify a `STOPPED` `mdState` lights nothing.

## Optional future: amber / 3-state warnings

A richer scheme would add a **warning** state (rebuilding / SMART / read-errors → amber) between
green and red. There is **no dedicated amber line**: amber is only possible if each bay's green+red
is a single **bi-color LED** that blends when both are driven. That needs a one-time visual check,
run with the array idle:

```perl
# perl /tmp/yellow-test.pl  (stop the daemon first so it frees the green line)
use Fcntl qw(O_RDWR);
my ($GET,$SET,$OUT)=(0xC250B407,0xC010B40F,8);
my @o=(12,13);
sysopen(my $c,"/dev/gpiochip0",O_RDWR) or die $!;
my $req=pack("L64",@o,(0)x62).pack("a32","yellow-test")
  .pack("Q",$OUT).pack("L",0).pack("L5",(0)x5).("\0"x240)
  .pack("L",2).pack("L",0).pack("L5",(0)x5).pack("l",0);
defined ioctl($c,$GET,$req) or die "GET:$!";
open(my $L,"+<&=",unpack("l",substr($req,588,4))) or die $!;
sub set{my($g,$r)=@_;my $b=($g?1:0)|(($r?0:1)<<1);ioctl($L,$SET,pack("QQ",$b,3));}
set(1,0); sleep 2;   # green
set(0,1); sleep 2;   # red
set(1,1); sleep 4;   # both -> amber?
set(0,0);
```

- **Amber** → a true 3-state (green = healthy, amber = warning, red = failed) becomes possible.
- **Discrete** → fall back to solid-red = failed, **blink**-red = warning.

If pursued, gate it behind `FAULT_3STATE=1` (the daemon already reads `DL_FAULT_3STATE` and logs that
3-state is requested but not implemented), mapping `color=yellow-*` → amber/blink. The current 2-state
build does **not** require this test.
