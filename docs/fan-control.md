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
| `SMOOTH_DIV` | `3` | output damping; higher = slower/smoother |
| `CPU_MINTEMP` / `CPU_MAXTEMP` | `62` / `85` | CPU curve (N5105 idles ~56–65 °C, throttles 105 °C) |
| `NVME_MINTEMP` / `NVME_MAXTEMP` | `45` / `72` | NVMe curve (warn ~70 °C) |
| `HDD_MINTEMP` / `HDD_MAXTEMP` | `40` / `52` | HDD curve (idle ~25–34 °C; longest life <~50 °C) |

The curve is a clamped linear interpolation: at/below `MINTEMP` → `MINPWM`,
at/above `MAXTEMP` → `MAXPWM`, linear in between.

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
