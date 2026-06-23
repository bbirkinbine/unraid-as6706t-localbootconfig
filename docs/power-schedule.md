# Scheduled power-off + RTC self-wake

[`power-schedule.sh`](../boot/config/scripts/power-schedule.sh) lets a NAS that
only needs to be awake for part of the day **power itself off when idle** and
**wake itself back up** later via the motherboard's RTC alarm — always re-arming
the next wake *before* it shuts down, so it can never strand itself dark (the
whole point, for a box you can't walk over to).

It's a general engine. It ships **inert and opt-in**: out of the box it does
nothing, and it is **not** started from [`go`](../boot/config/go) by default. You
turn it on per-machine with a small config file. The rest of this doc is the
mechanism, the scenarios it supports, how to enable it, and how the underlying
hardware wake was tested — followed by a worked example (this repo's box, a
secondary/offsite Unraid NAS).

> **Power-off vs. just spinning disks down.** The lower-effort alternative is to
> leave the box on 24/7 and let the HDDs spin down between backups (~15–25 W
> idling vs. ~5 W fully off on this N5105). A full power-off is the lower-power
> option, and **one power-cycle per day is mechanically a non-issue** for the
> drives (~365/yr against Start/Stop ratings in the tens of thousands). Power-off
> is only worth it if the box can wake *itself* — which is what the RTC alarm
> below makes possible.

## The hardware capability: RTC wake from S5

The board's CMOS real-time clock can fire a **hardware power-on** when an alarm
time is reached, even from a full soft-off (S5). The kernel reports it at boot:

```
rtc_cmos 00:01: alarms up to one month, y3k, 242 bytes nvram
```

The alarm is a single epoch value (UTC-based) at
`/sys/class/rtc/rtc0/wakealarm`. ASUSTOR's own ADM firmware ships a "Power
Scheduling" feature that rides on this same RTC alarm, which is why the silicon
supports it — the only open question was whether the AMI BIOS (V1.21) honours it
under **Unraid** instead of ADM.

### How it was tested

Before building any of this, the wake was proven by hand on the real box
(AS6706T, BIOS V1.21, Unraid 7.3.1):

```bash
# 1. confirm the alarm exists and is writable
ls -l /sys/class/rtc/rtc0/wakealarm        # -rw-r--r-- root
grep -i alarm /proc/driver/rtc             # alarm_IRQ : no   (nothing armed yet)
dmesg | grep 'alarms up to'                # rtc_cmos ... alarms up to one month

# 2. arm a wake 5 minutes out and verify it took
echo 0 > /sys/class/rtc/rtc0/wakealarm
echo $(( $(date +%s) + 300 )) > /sys/class/rtc/rtc0/wakealarm
grep -i alarm /proc/driver/rtc             # alarm_IRQ : yes
cat /sys/class/rtc/rtc0/wakealarm          # ~10-digit epoch, ~5 min ahead

# 3. power off, hands off, and watch it come back
poweroff
#   from another machine:  until ping -c1 nas.local; do sleep 5; done
```

Result: the box powered itself **back on ~5 minutes later**, untouched —
confirming RTC wake works under Unraid on this hardware. `power-schedule.sh
test-wake [secs]` re-runs exactly that sequence (default 300 s) on demand — it
**powers the box off** and prompts for confirmation first. Run it on any new box
before trusting the schedule (the alarm range and BIOS behaviour differ between
models and firmware), but **only where you can power the box back on if wake
fails** — not blind on a remote box.

> **Wake-on-LAN was rejected** for the offsite role: a WoL magic packet has to
> originate on the box's *local* LAN, but the backup is triggered from offsite,
> so there's no LAN-local sender. RTC wake is fully self-contained. (If you *do*
> have a WoL/BIOS wake source, the engine supports it — set `WAKE_EXTERNAL=1` and
> it'll handle just the power-off side.)

## How the engine works

Two jobs, in one small bash daemon:

1. **Arm** — compute the next wake from `WAKE_TIMES` (the soonest upcoming of a
   list of local `HHMM` times) and write **and read-back-verify** the RTC alarm.
   Done defensively at start, and again right before every shutdown.
2. **Watch** — a loop (`LOOP_SECS`, default 60 s) that decides when to power off
   according to `POWEROFF_MODE`, then runs the shutdown sequence.

### Power-off scenarios (`POWEROFF_MODE`)

| Mode | When it powers off |
| ---- | ------------------ |
| `none` *(default)* | Never automatically. Use when something else triggers it — e.g. your push job ends with `ssh root@nas power-schedule.sh off`. |
| `idle` | After `STAY_UP_UNTIL`, once the box has been **idle** for `IDLE_SHUTDOWN_MIN` minutes. Best when the backup length varies — it won't cut a long job short. |
| `fixed` | At `POWEROFF_AT`. Waits out an active transfer first unless `FIXED_FORCE=1`. Best when you want a predictable off-time. |

### How "idle" is decided

Each tick the box is marked **busy** (idle timer resets) if *any* hold:

| Signal | Catches |
| ------ | ------- |
| an interactive login (`who`) | you, working over SSH — it won't power off under you |
| an established connection on `BUSY_PORTS` (445 / 873 / 2049) | an attached SMB / rsync-daemon / NFS client |
| an `rsync` or `rclone` process | rsync-over-ssh pushes, or a local copy |
| NIC throughput ≥ `THRESH_KBPS` | any active transfer, whatever the protocol |

Throughput is the universal safety net; the connection/process checks keep the
box up through mid-transfer **lulls** (e.g. a large file being hashed) when bytes
briefly stop but the client is still attached.

## Safety — it must never strand itself

* **Verified arm before every shutdown.** It confirms the RTC reads the alarm
  back *and* `alarm_IRQ` flipped to `yes` before issuing `poweroff`. If arming
  fails, or no wake is configured (`WAKE_TIMES` empty and `WAKE_EXTERNAL=0`), it
  **aborts the shutdown and stays on**.
* **A wake stays armed at all times** (re-armed each tick once the one-shot alarm
  is spent), so a **manual** power-off — Unraid GUI, `poweroff`, the power button —
  also brings the box back, not just the scheduled shutdown. You don't have to
  remember to use `power-schedule.sh off`. (Consequence: to keep the box
  *deliberately* off — vacation, decommission — stop the daemon and clear the
  alarm: `power-schedule.sh stop; echo 0 > /sys/class/rtc/rtc0/wakealarm`, then
  power off. Otherwise it will wake at the next `WAKE_TIMES`.)
* **`ENABLED=0` by default.** `start` refuses until you set `ENABLED=1` in the
  config — so a fresh clone, or an accidental run, does nothing.
* **`DRY_RUN=1` by default.** It logs `WOULD power off …` and stays up, so you
  can watch a full cycle before trusting it.
* **Inhibit flags.** `touch /dev/shm/power-schedule.keepawake` (until reboot) or
  `/boot/config/power-schedule.disable` (persistent) blocks shutdown entirely.
* **Breadcrumb.** Each shutdown appends one line to
  `/boot/config/power-schedule.last` (on USB, survives the power-off) with the
  time and the next armed wake — proof the cycle is working.

## How to run it

> **⚠️ Step 0 — verify Unraid's timezone first.** `WAKE_TIMES`, `STAY_UP_UNTIL`,
> and `POWEROFF_AT` are **local wall-clock times** in whatever zone Unraid is set
> to. Unraid **defaults to UTC** and does **not** auto-detect your location, so a
> wrong zone makes the box wake and sleep at the wrong real-world hour. Set it in
> the web UI — **Settings → Date and Time → Time zone** (leave NTP on) — then run
> `date` on the box and confirm it prints **your** local time and zone (e.g.
> `... EDT`), not UTC. Don't configure any times below until that reads correctly.
> See [Timezone — what the HHMM times mean](#timezone--what-the-hhmm-times-mean).

1. **Test the hardware wake** (see above): `power-schedule.sh test-wake 300`. ⚠️ **This
   powers the box OFF** and relies on the RTC to bring it back in ~5 min. It prompts for
   confirmation first, and if wake fails the box stays off until powered on by hand — so
   **only run it where you have physical or remote-PDU access**, never blind on a remote
   box. Only continue if the box wakes itself.
2. **Create the config** from the example:
   ```bash
   cp /boot/config/scripts/power-schedule.conf.example /boot/config/power-schedule.conf
   # edit /boot/config/power-schedule.conf: set WAKE_TIMES, POWEROFF_MODE, ENABLED=1
   ```
   (`/boot/config/power-schedule.conf` is gitignored — it's per-machine.)
3. **Start it** (leave `DRY_RUN=1` for now) and check it:
   ```bash
   install -m 755 /boot/config/scripts/power-schedule.sh /usr/local/sbin/
   power-schedule.sh start
   power-schedule.sh status
   ```
4. **Watch one full cycle.** Next day: `power-schedule.sh status` and
   `cat /var/log/power-schedule.log`. Confirm it logged a single `DRY_RUN: WOULD
   power off …` at a sensible time (after the backups drained, not mid-transfer).
5. **Enable for real:** set `DRY_RUN=0` in the conf, then `power-schedule.sh
   restart`.
6. **Make it survive reboots:** uncomment the two `power-schedule.sh` lines in
   [`go`](../boot/config/go).

### Commands

```bash
power-schedule.sh status            # enabled/mode, armed wake, time-to-wake, live busy/idle, last shutdown
power-schedule.sh arm [HHMM]        # manually (re)arm the next wake (default: next of WAKE_TIMES)
power-schedule.sh off               # arm next wake + power off NOW (manual "go back to sleep")
power-schedule.sh test-wake [secs]  # POWERS OFF, must self-wake in secs (default 300); prompts first
power-schedule.sh start|stop|restart|reload   # reload = restart (applies config edits)
```

> **Applying a config change:** the daemon reads `/boot/config/power-schedule.conf`
> only at startup, so after editing it run `power-schedule.sh reload` (an alias for
> `restart`) to apply — a reboot applies it too. `status` prints a `CHANGED:` line
> whenever the on-disk config differs from what the running daemon loaded, so you're
> not left thinking an edit took effect when it hasn't.

## Timezone — what the HHMM times mean

> **Verify this in the Unraid UI before enabling the schedule** — Settings → Date
> and Time → Time zone. A wrong zone makes every wake and power-off fire at the
> wrong real-world time.

`WAKE_TIMES`, `STAY_UP_UNTIL`, and `POWEROFF_AT` are **local wall-clock** times in
whatever zone Unraid is set to (**Settings → Date and Time**). The script feeds
them to GNU `date`, which resolves them against the system zone, then writes the
resulting absolute **epoch** to the RTC. Two consequences:

* **DST is handled** — `2345` stays 23:45 in summer and winter.
* It works **regardless of whether the hardware RTC is kept in UTC or local
  time** — the kernel converts the epoch for the RTC (verified by `test-wake`).

Unraid's clock runs in **local time** per the configured zone, stays accurate via
**NTP (on by default)**, but **defaults to GMT/UTC until you pick a zone** and does
not auto-detect location. So confirm the zone is right before trusting the
schedule — otherwise `2345` fires at the wrong real-world moment:

```bash
date                       # should show your local time + zone (e.g. EDT), not UTC
power-schedule.sh status   # the 'armed' line prints the wake in local time + zone (%Z)
```

## Config keys

Set these in `/boot/config/power-schedule.conf` (sourced over the script's
defaults). Full annotated list in
[`power-schedule.conf.example`](../boot/config/scripts/power-schedule.conf.example).

| Key | Default | Meaning |
| --- | ------- | ------- |
| `ENABLED` | `0` | `start` refuses unless `1` |
| `DRY_RUN` | `1` | `1` = observe only; `0` = real shutdowns |
| `WAKE_TIMES` | *(empty)* | space-separated local 24h `HHMM` times (`2345`, `0905`); the soonest upcoming is armed |
| `WAKE_EXTERNAL` | `0` | `1` = WoL/BIOS wakes it; allows power-off without arming RTC |
| `POWEROFF_MODE` | `none` | `none` \| `idle` \| `fixed` |
| `STAY_UP_UNTIL` | `0300` | *(idle)* earliest local time a shutdown may happen |
| `IDLE_SHUTDOWN_MIN` | `30` | *(idle)* idle minutes past the floor before powering off |
| `POWEROFF_AT` | `0500` | *(fixed)* local time to power off |
| `FIXED_FORCE` | `0` | *(fixed)* `1` = power off even mid-transfer |
| `THRESH_KBPS` | `100` | NIC rx+tx below this (KB/s) = idle |
| `BUSY_PORTS` | `445 873 2049` | attached-client ports; add `22` for rsync-over-ssh |

**Time format & validation.** `WAKE_TIMES`, `STAY_UP_UNTIL`, and `POWEROFF_AT` are
24-hour `HHMM` local times (e.g. `2345`, `0905`). `HH:MM` (`23:45`, `9:45`) is
accepted and **normalized** automatically. Out-of-range or junk values — and
**ambiguous bare 3-digit times like `945`** (write `0945` or `9:45`) — are
**rejected at start**: the daemon refuses to run and `status` shows the offending
value, rather than silently scheduling the wrong hour. Anything it auto-normalized
is reported on `start` and `status` (e.g. `fixed : normalized: WAKE_TIMES:'23:45'->2345`).

## Example: this repo's box (secondary / offsite Unraid NAS)

`NAS-OFFSITE` is a backup **target** only. The primary NAS pushes overnight jobs
at **00:00, 01:00, 01:30, 02:00** (the 02:00 one is the largest); the rest of the
day it has no reason to be on. Its `/boot/config/power-schedule.conf`:

```sh
ENABLED=1
DRY_RUN=0
WAKE_TIMES="2345"        # wake ~15 min before the 00:00 job
POWEROFF_MODE=idle
STAY_UP_UNTIL="0300"     # don't even consider shutdown before 03:00 (covers the 02:00 job's tail)
IDLE_SHUTDOWN_MIN=30     # after 03:00, off once idle 30 min
THRESH_KBPS=100
```

So: wakes itself at 23:45 → backups run → stays up through 03:00 no matter what →
powers off once the last job has been done for 30 min → arms the next 23:45 wake
on the way down. If the big 02:00 job is still transferring at 03:00, the
watchdog sees the traffic and waits.

Note that `STAY_UP_UNTIL`, `IDLE_SHUTDOWN_MIN`, and `THRESH_KBPS` are written out
even though they equal the script's built-in defaults. That's deliberate: pinning
them in the conf keeps this box's policy visible in one place and means it won't
silently change if a future version of the script ever ships different defaults.

## BIOS: surviving a real power outage

The CMOS battery keeps the RTC (and a pending alarm) running through a brief
outage, but if mains is fully cut the board won't power on by itself when power
returns unless the BIOS is set for it. For an offsite box, set **Restore on AC
Power Loss → Power On** (or *Last State*) in BIOS setup so it recovers without a
visit.
