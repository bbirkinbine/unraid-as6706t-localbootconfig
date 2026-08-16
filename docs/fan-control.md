# Custom fan control

Script: [`boot/config/scripts/fan-autocontrol.sh`](../boot/config/scripts/fan-autocontrol.sh)
Installed + started by: [`boot/config/go`](../boot/config/go)

This is the headline customization on this machine: a small, dependency-free
daemon that drives the single AS6706T system fan from a blend of CPU, NVMe, and
HDD temperatures.

## Why it exists (and what it replaced)

Unraid's usual answer is the **Dynamix Auto Fan Control** plugin
(`dynamix.system.autofan`). It was tried and **removed** (it now sits in
`/boot/config/plugins-removed/`) because:

- it drives fans from **HDD temperature only**, ignoring the CPU and NVMe — and
  on this box the N5105 package and the NVMe SSDs are the parts that actually get
  hot, while the HDDs sit cool;
- it expects a more conventional fan/PWM layout and doesn't cleanly handle the
  Asustor IT8625 single-channel setup;
- a ~150-line script gives full control over the curves, smoothing, and
  spin-down behavior, with no plugin-update surprises.

So the autofan plugin was uninstalled and replaced with this standalone script.

## What it does, in one paragraph

Every `INTERVAL` seconds it reads the CPU package temp (`coretemp`), every NVMe
drive (`nvme`), and every spun-up SATA HDD (`drivetemp`). For each source it maps
the temperature onto that source's own min→max curve to get a target PWM, then
drives the fan at the **highest** of those targets (whichever component is
hottest wins). The output is smoothed so a one-cycle CPU spike barely nudges the
fan, while sustained load still ramps it fully within ~30 s.

## Key design decisions

- **Resolve sensors by driver *name*, every cycle.** It finds the fan via the
  hwmon whose `name` is `it8625`, the CPU via `coretemp`, etc. — never a fixed
  `hwmon3`. This survives hwmon renumbering across reboots and HDD hotplug.
- **Highest-wins blend.** Independent curves per source; the fan tracks the
  hottest component rather than an average, so a hot NVMe can't be "hidden" by
  cool HDDs.
- **Anti-hunt smoothing (`SMOOTH_DIV`).** The N5105 package temp bounces several
  degrees each cycle at idle. Each tick the fan moves only `ceil(1/SMOOTH_DIV)`
  of the way toward the new target, so it doesn't audibly surge chasing spikes.
  Set `SMOOTH_DIV=1` to disable.
- **Spin-down aware.** Before reading a HDD's temperature it checks the drive
  power state with `hdparm -C`, which uses CHECK POWER MODE and does **not** wake
  the disk. A standby disk is skipped entirely — both because reading its temp
  would spin it up (defeating idle spin-down) and because a standby disk is cool
  and idle anyway.
- **Fail-safe on stop.** On `stop`/exit it leaves the fan at `SAFE_PWM` (~63%) so
  the box is never left with the fan parked low if the daemon dies.
- **Self-contained.** Pure bash + `hdparm` + sysfs. No Python, no plugins.

## Tunables

All at the top of the script (PWM is 0–255; temps in whole °C):

| Variable | Value | Meaning |
| -------- | ----- | ------- |
| `INTERVAL` | `10` | seconds between adjustments |
| `MINPWM` | `51` | floor (~20%, ~800 RPM — proven to spin reliably) |
| `MAXPWM` | `255` | ceiling (100%) |
| `SAFE_PWM` | `160` | PWM left on the fan if the daemon is stopped (~63%) |
| `SMOOTH_DIV` | `5` | output damping; higher = slower/smoother |
| `CPU_MINTEMP` / `CPU_MAXTEMP` | `62` / `85` | CPU curve (N5105 idles ~56–65 °C, throttles 105 °C) |
| `NVME_MINTEMP` / `NVME_MAXTEMP` | `45` / `72` | NVMe curve (warn ~70 °C) |
| `HDD_MINTEMP` / `HDD_MAXTEMP` | `38` / `45` | HDD curve — `MAXTEMP` is pinned to Unraid's default disk warning threshold; see below |

The curve is a clamped linear interpolation: at/below `MINTEMP` → `MINPWM`,
at/above `MAXTEMP` → `MAXPWM`, linear in between.

## Tuning the HDD curve for your workload

**The shipped HDD values suit a lightly-loaded box in a cool room. They are a
starting point, not a universal default.** They were originally `40` / `52`, picked
from datasheet reasoning when this script was written and never measured against a
real sustained load; the current `40` / `45` come from the measurements below, taken
on one machine in a 22.8 °C room. What is right for *your* box depends on things
this repo cannot know: ambient temperature, which drives are fitted, how many bays
are populated, duty cycle, and how much fan noise you will put up with.

So tune them. This section is how.

### The one part that isn't a matter of taste

Everything else below is preference. This isn't:

> **Set `HDD_MAXTEMP` equal to your Unraid disk temperature warning threshold, so
> the fan reaches 100 % exactly as the platform starts warning. Never above it.**

Unraid's default warning is **45 °C** (*Settings → Disk Settings*; stored as `hot`
in `dynamix.cfg`, with `max` as the critical threshold). A `HDD_MAXTEMP` of 52 sits
7 °C past that, which means the fan is still only at 53 % while the webGUI has
already started flagging the disk as hot and emailing you about it. The fan
controller and the platform disagree about what "too warm" means, and the platform
is the one sending the notifications.

This matters more than it first appears, because **Unraid schedules a parity check
monthly by default** (`0 0 1 * *`), and it runs the entire array at sustained
sequential read for a long time — 34–37 hours on this box's 20 TB array. That is not
an exotic edge case. It is the most common heavy workload an Unraid box ever sees,
and it is exactly when the top of the curve gets used.

### Measure your own box

You need one sustained, array-wide load. A parity check is the canonical choice: it
is the workload the curve exists for, and you can start one on demand from
*Main → Check*. A disk rebuild works too.

With that running, sample the fan and every drive once a minute:

```bash
hw=$(for d in /sys/class/hwmon/hwmon*; do
       [ "$(cat $d/name 2>/dev/null)" = it8625 ] && echo $d; done)
while true; do
  printf '%s pwm=%s rpm=%s' "$(date +%H:%M:%S)" "$(cat $hw/pwm1)" "$(cat $hw/fan1_input)"
  for d in /sys/class/hwmon/hwmon*; do
    [ "$(cat $d/name 2>/dev/null)" = drivetemp ] || continue
    for b in "$d"/device/block/*; do
      printf ' %s=%sC' "${b##*/}" "$(( $(cat $d/temp1_input)/1000 ))"
    done
  done
  printf '\n'
  sleep 60
done
```

Three things to know before you read the output:

- **This board reports no ambient temperature.** Don't go looking — every candidate
  was checked:

  | Candidate | Reading | Why it's useless |
  | --- | --- | --- |
  | `acpitz` / `thermal_zone0` | `27800` m°C, never varies | Hardcoded ACPI constant |
  | `it8625` `temp1/2/3` | `-128000` m°C | IT86xx not-connected sentinel; pins unpopulated, and there is no `temp*_type` attribute to reconfigure |
  | DIMM SPD (`jc42`) | absent | i2c has only an EEPROM at `0-0050` |
  | Seagate attr 190 `Airflow_Temperature_Cel` | equals attr 194 | Mirrors drive temp despite the name |
  | NVMe `Sensor 2` | ~5–6 °C above room, responsive | Best proxy available, but it is the SSD's own board temp and it moves with fan speed |

  Every sensor that responds at all is downstream of the fan, so none of them
  isolates room air from cooling. For a true ambient reading you need external
  hardware — a USB thermistor (TEMPer-class, ideally on a short extension so the
  port's own heat doesn't skew it) or a networked smart-home sensor. For one-off
  curve comparisons, a thermometer at the intake and a written-down number is
  entirely sufficient.

- **The IT8625's own automatic fan mode is wired to a dead sensor.**
  `pwm1_auto_channels_temp` is `1`, meaning hardware auto-mode follows `temp1` —
  which reads −128 °C. This is why the daemon sets `pwm1_enable=1` (manual) and
  drives the fan itself: on this board, software control isn't a preference, it's
  the only thing that works.

- **Give it half an hour.** Drives heat-soak fast and then sit flat. On this box the
  array climbed from 40 °C to its plateau in about 30 minutes and then held within
  1 °C for the next five hours. Anything shorter measures the transient, not the
  equilibrium.
- **A 60 s sample aliases the oscillation.** It will make a drive that is really
  cycling 43↔45 look like it is parked at 43. `/var/log/fan-autocontrol.log` records
  every PWM change at 10 s resolution and is the honest source for how much the
  temperature is actually swinging.

### Choosing values

| Knob | How to pick it |
| ---- | -------------- |
| `HDD_MINTEMP` | Just above the hottest your drives get when the array is *not* under sustained load. Below this the fan sits at `MINPWM` and the box is quiet. Too low and you pay idle noise for nothing; too high and a busy array gets no help until it is already warm. |
| `HDD_MAXTEMP` | See the rule above — at or just above your Unraid warning threshold. |
| `SMOOTH_DIV` | Raise it whenever you steepen the curve. |

Narrowing the band steepens the response — more authority, but the fan swings
harder on every 1 °C flicker:

| Band | Slope | PWM at 43 °C | PWM at 45 °C |
| ---- | ----- | ------------ | ------------ |
| 40 → 52 (original) | 17 PWM/°C | 102 (40 %) | 136 (53 %) |
| 40 → 46 | 34 PWM/°C | 153 (60 %) | 221 (87 %) |
| **40 → 45 (shipped)** | 41 PWM/°C | 173 (68 %) | 255 (100 %) |
| 38 → 45 | 29 PWM/°C | 197 (77 %) | 255 (100 %) |

All four were run on this box during a rebuild. `40 → 46` and `38 → 45` both held the
hottest disk at the same 43 °C despite a 43 PWM difference between them — evidence
that at 43 °C that drive was **not airflow-limited**, and that pouring more air at it
buys nothing. That is why the shipped curve keeps `MINTEMP` at 40 rather than
lowering it: the useful work is done by raising the *top* of the ramp, not by
starting it earlier.

`HDD_MINTEMP` is self-targeting: lowering it changes nothing on a box whose drives
idle cool, and progressively engages the fan on a busy box whose drives sit warm. If
your array idles in the low 40s — where the shipped curve is already ramping —
lowering `HDD_MINTEMP` is the right move, so the fan starts before the drives are in
trouble. If your array idles in the 20s like this one, leave it alone.

Whichever band you choose, remember that **narrowing it steepens the response and so
demands more damping**. Going from `40 → 52` to `40 → 45` takes the slope from 17 to
41 PWM/°C, meaning a single 1 °C tick now moves the target 41 PWM instead of 17. At
`SMOOTH_DIV=3` that lands as a ~110 RPM step within ten seconds — audible. Hence the
matching bump to `SMOOTH_DIV=5`, which halves the first-cycle move to ~70 RPM.

### Worked example — this box

Measured during a disk rebuild (sustained ~180 MB/s write to one 20 TB member,
full-speed read on the other five), in a **22.8 °C / 73 °F room** — measured with a
room thermometer, not by the box, which has no ambient sensor. If your NAS sits in
an enclosed cabinet its intake air will be warmer than the room reading.

| | `40 → 52`, `SMOOTH_DIV=3` (original) | `40 → 45`, `SMOOTH_DIV=5` (shipped) |
| --- | --- | --- |
| Rebuild-target drive | 45–46 °C, flat for 5 h 06 m | **43 °C** |
| Fan | 136–153 PWM, ~1740 RPM | 173 PWM, ~1985 RPM |
| Unraid "disk is hot" alerts | **26 in 4 h 39 m** | **0** |

Idle behavior is unchanged — `HDD_MINTEMP` stayed at 40 and these drives rest at
24–25 °C, so below 40 °C the fan still sits at its 51 PWM floor. The cost is ~240 RPM
more under sustained load, which on this box means during a rebuild or the monthly
parity check and at no other time.

Convergence was clean rather than oscillatory, despite the steeper slope — the
controller walked `132 → 139 → 146 → 152 → 157 → 161 → 164 → 166 → 168 → 170 → 172 →
173` and stopped, with no sawtooth between the 42 °C and 43 °C targets.

**Measurement honesty:** the "before" column is a five-hour plateau and is solid. The
"after" column is a much shorter window on this exact curve, though the 43 °C figure
is corroborated by two other curves tested the same evening (`40 → 46` and `38 → 45`
both settled the same drive at 42–43 °C). Treat the alert count as the robust result
and the exact temperature as ±1 °C.

### Predicting this for your own room

Temperature *rise over intake air* is the portable number — it transfers to other
rooms in a way that absolute temperatures do not. Under the sustained load above,
with all six bays populated and the fan at 173 PWM, this chassis settles at:

| Bay | Rise over room air |
| --- | --- |
| 1 (nearest intake) | ~14 °C |
| 2 | ~15 °C |
| 3 | ~16 °C |
| 4 | ~18 °C |
| 5 | ~20 °C *(write target — includes the write penalty)* |
| 6 | ~19 °C |

There is a real ~5 °C front-to-back gradient across the bay stack, so **which slot a
drive occupies matters as much as which drive it is.** Add ~3 °C to the hottest bay
if that drive is the write target of a rebuild rather than being read.

Apply this to your own room to predict where you will land:

| Room | Hottest bay under sustained load |
| --- | --- |
| 20 °C / 68 °F | ~40 °C |
| 23 °C / 73 °F | ~43 °C — this box |
| 27 °C / 81 °F | ~47 °C |
| 30 °C / 86 °F | ~50 °C |

This is why the original `HDD_MAXTEMP=52` was a poor default even though it never
hurt anything here. **This box is in a cool room and still crossed Unraid's 45 °C
warning threshold during a rebuild.** A NAS in a 27 °C room — an ordinary summer, or
a warm closet — sits around 47 °C under every monthly parity check, and the old curve
answered that with `51 + (47−40) × 17 ≈ 170` PWM, or 67 %: a third of the cooling
still held in reserve while the platform raised alarms. The shipped `40 → 45` curve
is at 100 % for anything at or above 45 °C.

**Caveat on this measurement:** the two halves were taken ~25 minutes apart and the
room was not instrumented (see above — this board has no usable ambient sensor), so
ambient drift is not excluded. The 2–3 °C drop is consistent with the airflow change
on its own: mean PWM went from ~143 to ~167, and for forced convection ΔT scales
roughly as airflow^−0.7, which predicts ~2 °C for a 17 % increase. Rebuild
throughput also fell ~6 % over the same window as the resync moved to inner tracks,
worth a few tenths more. No appeal to ambient is needed to explain the result, but
it is not ruled out either.

### What a curve cannot fix

The AS6706T has **one** system fan for six bays. It will not hold six drives below
45 °C at constant load in a warm room — there is not enough fan, and no curve
conjures airflow that isn't there. If your array runs hot continuously rather than
during monthly maintenance, the honest answer is *both*: tune the curve **and**
raise Unraid's warning threshold.

Raising it is not cheating. 45 °C is a conservative default, not a cliff — every
drive in this class is specified to 60–65 °C, and large-fleet reliability data shows
no meaningful failure correlation below roughly 50 °C. The counters that actually
track thermal harm are `Time in Over-Temperature` and the lifetime max in
`smartctl -x`; if those look healthy, a drive sitting at 47 °C under load is fine
regardless of what the dashboard colours it.

### Applying a change

`/boot/config/go` installs the script to `/usr/local/sbin/` at boot, so **editing the
flash copy alone does nothing until you reboot.** That asymmetry is useful:

```bash
# Test live (reverts on reboot — a free safety net):
vi /usr/local/sbin/fan-autocontrol.sh
fan-autocontrol.sh restart

# Persist once you're happy:
vi /boot/config/scripts/fan-autocontrol.sh
```

`restart` parks the fan at `SAFE_PWM` while it cycles, so there is no cooling gap —
safe to do mid-parity-check.

## Usage

```bash
fan-autocontrol.sh start     # start the daemon (forks via setsid, writes a pidfile)
fan-autocontrol.sh stop      # stop and park the fan at SAFE_PWM
fan-autocontrol.sh restart
fan-autocontrol.sh status    # show daemon state, current pwm/rpm, and every temp
fan-autocontrol.sh run       # run the loop in the foreground (used internally)
```

- PID file: `/var/run/fan-autocontrol.pid`
- Log: `/var/log/fan-autocontrol.log` (auto-truncated past ~200 KB)

`status` is the quick health check — it prints the daemon state, `pwm1/255`
(with enable mode), `fan1` RPM, and the CPU / NVMe / HDD temperatures (HDDs in
standby are shown as `standby` rather than being woken).

## How it's wired into boot

From [`boot/config/go`](../boot/config/go):

```bash
install -m 755 /boot/config/scripts/fan-autocontrol.sh /usr/local/sbin/fan-autocontrol.sh
/usr/local/sbin/fan-autocontrol.sh start
```

The daemon also `modprobe drivetemp` on startup so per-HDD temperatures are
available, and writes `pwm1_enable=1` (manual/software PWM mode) so the firmware
stops auto-managing the fan and hands control to the script.

## Prerequisite

The `it8625` hwmon node only exists if the **Asustor platform driver** is
installed and the mainline `it87` is blacklisted — see
[asustor-platform-driver.md](./asustor-platform-driver.md). If
`fan-autocontrol.sh status` reports *"it8625 pwm not found"*, that driver isn't
loaded.
