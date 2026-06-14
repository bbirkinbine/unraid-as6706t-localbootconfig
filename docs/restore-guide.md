# Restore guide: redeploying these scripts after a reinstall

This repo holds only the **hardware-specific custom scripts**, so "restore" here
means *getting those scripts running again* on a fresh (or rebuilt) Unraid
install. It does **not** cover rebuilding your array, shares, users, or network —
those are reconfigured through the Unraid GUI and are intentionally not in this
repo. Read [unraid-boot-and-persistence.md](./unraid-boot-and-persistence.md)
first if the "RAM root / `/boot` is the only persistence" model isn't familiar.

## 0. Prerequisites

- A booted Unraid on the AS6706T (any working install).
- This repo, cloned to your workstation (or just the files under `boot/config/`).

## 1. Install the Asustor platform driver (prerequisite)

The scripts talk to hardware (`pwm1`, `fan1_input`, the LED GPIO, the LCD) that
only exists once the Asustor drivers are loaded. Without this, the fan script
will report *"it8625 pwm not found"*.

1. Install **Community Applications** (Unraid's plugin store) if it isn't already.
2. From Community Applications, install **Asustor Platform Drivers**
   (`unraid-asustorpfd`).
3. **Reboot** — the drivers need it.

See [asustor-platform-driver.md](./asustor-platform-driver.md) for what this
provides and why the `it87` blacklist matters. **Do not** install Dynamix Auto
Fan Control — it would fight the custom daemon for `pwm1`.

## 2. Copy the scripts + boot hook into `/boot/config`

Place these repo files at the matching paths on the Unraid USB stick (mount the
stick on your workstation, or `scp` them once SSH is up):

| Repo file | → destination on NAS |
| --------- | -------------------- |
| `boot/config/scripts/fan-autocontrol.sh` | `/boot/config/scripts/fan-autocontrol.sh` |
| `boot/config/scripts/asustor-lcd.sh` | `/boot/config/scripts/asustor-lcd.sh` |
| `boot/config/scripts/lcd-info.sh` | `/boot/config/scripts/lcd-info.sh` |
| `boot/config/scripts/claude-persist.sh` | `/boot/config/scripts/claude-persist.sh` |
| `boot/config/modprobe.d/it87.conf` | `/boot/config/modprobe.d/it87.conf` |
| `boot/config/go` | `/boot/config/go` |

> ⚠️ **`go` is the one file to merge, not blindly overwrite.** A stock Unraid
> already has a `/boot/config/go`. If yours is stock (just the `emhttp` line),
> replacing it is fine. If you've added *other* customizations to `go`, copy in
> only the script-install/start blocks from this repo's `go` rather than clobbering
> the whole file.

Make the scripts executable:

```bash
chmod +x /boot/config/scripts/*.sh
```

What `go` does on the next boot: installs + starts the
[fan controller](./fan-control.md), disables the blinking
[green status LED](./front-panel-lcd.md#disabling-the-blinking-status-led), and
installs + starts the [LCD info daemon](./front-panel-lcd.md). (The Claude
persistence lines in `go` are intentionally left commented out — see
[claude-cli-persistence.md](./claude-cli-persistence.md).)

## 3. Reboot and verify

A reboot is needed anyway for the Asustor drivers + the `it87` blacklist to take
effect. After it comes back up:

```bash
fan-autocontrol.sh status     # daemon RUNNING; shows pwm/rpm + CPU/NVMe/HDD temps
lcd-info.sh status            # daemon RUNNING; front LCD shows IP + CPU/fan
```

Expected results:

- The front **LCD** shows the IP on line 1 and `CPU ..C ..rpm` on line 2.
- The green status **LED** is solid, not blinking.
- `fan-autocontrol.sh status` lists the fan PWM/RPM and each temperature source.

If `fan-autocontrol.sh status` says *"it8625 pwm not found"*, the Asustor driver
didn't load — recheck step 1 (and that the reboot happened).

## 4. (Optional) Re-establish Claude Code

Per [claude-cli-persistence.md](./claude-cli-persistence.md) — it's intentionally
not automatic on boot:

```bash
# install claude + log in once, then run the persist script:
/boot/config/scripts/claude-persist.sh
```

---

## Pre-push checklist

Before pushing this repo anywhere public, confirm no secret slipped in:

```bash
# 1. Nothing sensitive is tracked by filename:
git ls-files | grep -E '\.(key|pem|crt)$|credentials|shadow|passwd|secrets|\.env$' && \
  echo "!! REVIEW THE ABOVE" || echo "clean: no secret-looking filenames tracked"

# 2. No obvious tokens/keys in tracked content:
git grep -nE 'BEGIN (RSA|OPENSSH|EC|PRIVATE)|sk-ant-|oauth|aws_secret' \
  $(git ls-files) || echo "clean: no obvious secret strings"

# 3. The .env login is ignored, not tracked:
git check-ignore .env && echo ".env correctly ignored"
```
