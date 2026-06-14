# Per-bay red / fault LEDs — design & research (future work)

> **Status: planned, not implemented.** This captures the research and proposed design
> so it can be built later. Tracked in [TODO.md](../TODO.md). It extends the working
> [disk-activity green-LED daemon](./disk-leds.md).

The goal: light each bay's **red** LED when that disk is in a fault/error condition,
the way Asustor's ADM does natively — so a failed drive's bay is obvious at a glance.

## How ADM does it natively

On ADM the red tray LED means a **drive access error / failure**. When a disk fails (or
a RAID volume goes degraded), the failed bay's tray LED turns **solid red** to mark
which disk to replace, and the system status LED flashes **red+green**.
([Asustor: what the LEDs mean](https://www.asustor.com/en/knowledge/detail/?group_id=602))

## How Unraid exposes disk faults

Unraid's canonical "bad drive" is the **disabled / red-X** state (`status="DISK_DSBL"`):
a write failed, so Unraid drops the disk from the array and emulates it from parity
until it's rebuilt. Alongside that it tracks per-disk read/write **error counts**,
**SMART** health, and temperature.

All of it is in **`/var/local/emhttp/disks.ini`** (one section per slot), refreshed by
emhttp. The authoritative decision logic is Unraid's own
[`dynamix monitor`](https://github.com/limetech/dynamix/blob/master/plugins/dynamix/scripts/monitor)
script, which keys off the per-disk **`color`** field (`strtok(color,'-')`):

| `color` | meaning | Unraid alert level |
| ------- | ------- | ------------------ |
| `green-*` | normal | — |
| `yellow-*` | not ready / content being reconstructed / parity-sync in progress | **warning** |
| `red-*` | error state (disabled / `DISK_DSBL`) | **alert** |

Supporting signals:

- **`numErrors`** — per-disk read/write error counter; `>0` is flagged even before a disk is fully disabled.
- **SMART health** — cached by the monitor at `/var/local/emhttp/smart/<name>` (look for the overall-health `PASSED`/`FAILED` line). Read the cache rather than running `smartctl` (or use `smartctl -n standby -H` so a spun-down disk isn't woken).
- **Array state** — `mdState` in `/var/local/emhttp/var.ini`.

### Important nuance: a stopped array is not a fault

Captured live with the array **stopped**, the two parity disks read as
`status="DISK_INVALID"` / `color="yellow-on"` — purely because the array is stopped, not
because anything is wrong. So the fault logic **must gate on `mdState="STARTED"`**, or
every array stop would light the parity bays amber.

## Bay → Unraid slot mapping (live, this box)

Joins cleanly to the existing bay→`sdX` map (bay N ↔ ata N):

| Bay | Device | Unraid slot |
| --- | ------ | ----------- |
| 1 | sda | parity |
| 2 | sdb | parity2 |
| 3 | sdc | disk1 |
| 4 | sdd | disk2 |
| 5 | sde | disk3 |
| 6 | sdf | disk4 |

(The `cache`/`cache2` NVMe devices are the M.2 slots, not front bays.)

## Open question — is "yellow" even available? (blocks the final design)

There is no dedicated amber line. **Amber is only possible if each bay's green and red
are a single bi-color LED sharing one light pipe** — then driving both at once blends to
amber, giving a true 3-state scheme. If they're discrete, we're limited to green or red
per bay. The mafredri driver hints these "sometimes appear as one," so it's plausible,
but it must be confirmed visually.

**Test (run with the array idle):** briefly own one bay's two lines and drive green,
then red, then both — and look. Green=12 (active-high, `1`=on), red=13 (active-low,
`0`=on) for bay 1:

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

- **Amber** → 3-state: green = healthy, **amber = warning**, red = failed.
- **Discrete** → 2-state: green vs red, using **solid red = failed**, **blink red = warning**.

## Proposed implementation

Extend the *same* daemon (no second process):

1. Also request the six red lines (`13 47 52 48 62 60`) in the line request. They're
   **active-low**, so either set the per-line `ACTIVE_LOW` flag in the uAPI config or
   invert in software (raw `0` = on).
2. On a **slow** cadence (~15 s — fault state changes slowly, unlike activity), read
   `disks.ini` + `var.ini`, and for each bay look up its disk by `device`.
3. Drive per bay (only when `mdState="STARTED"`):
   - `color=red` / `DISK_DSBL` / `numErrors>0` / SMART `FAILED` → **solid red**
   - `color=yellow` (rebuilding / not-ready) → **amber** (if bi-color) or **blink red**
   - otherwise → red off
4. Greens keep doing activity on the 100 ms loop exactly as today.

Cost stays negligible: the fault check is a 15 s poll of two small tmpfs `.ini` files
(plus the cached SMART files) — it never touches the disks, so it stays spin-down safe.
