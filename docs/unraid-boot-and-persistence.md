# How Unraid boots, and what actually persists

This is the single most important concept behind this whole repo. If you
understand this, everything else (why there's a `go` file, why Claude needs a
"persist" script, why custom drivers live where they do) follows naturally.

## Unraid runs entirely from RAM

Unraid boots from a USB flash drive, but it does **not** run from it the way a
normal Linux distro runs from its disk. At boot, the bootloader loads a set of
compressed archives off the USB stick:

| File on USB (`/boot`) | What it is |
| --------------------- | ---------- |
| `bzimage`             | the Linux kernel |
| `bzroot`              | the root filesystem, unpacked into RAM |
| `bzroot-gui`          | the GUI-mode root overlay |
| `bzmodules`           | kernel modules |
| `bzfirmware`          | firmware blobs |

`bzroot` is extracted into a RAM filesystem and becomes `/`. **That means the
entire operating system — `/`, `/root`, `/usr`, `/etc`, `/var`, everything
except the mount points below — is volatile and is rebuilt from scratch on every
single boot.** Anything you install, configure, or drop into the live
filesystem after boot is gone the moment you reboot.

This is by design. It's why Unraid is so resilient: a bad config can almost
always be fixed by rebooting, and the OS image itself is read-only and
checksummed (`*.sha256`).

## The USB stick is the only persistent storage that mounts early

The USB flash drive is mounted at **`/boot`** (it's a FAT32 volume, labeled
`UNRAID`). Everything under `/boot` survives reboots because it physically lives
on the stick, not in RAM.

Within `/boot`:

- `/boot/config/` — **this is where all persistent configuration lives.** Unraid
  reads it at boot to reconstruct your server: array assignment, shares, users,
  network, plugins, SSL certs, the license key, and so on.
- The `bz*` files — the OS image itself (managed by Unraid updates; don't touch).

Your array disks and pools (`/mnt/...`) are also persistent, of course — but
they only mount **after** the array is started, which happens late in boot and
can require a parity check or a manual start. So the array is not a safe place to
put things that need to exist *early* in boot (like a fan-control daemon that
should run before disks even spin up). That leaves `/boot/config` as the one
place that is both persistent **and** available early.

## `/boot/config/go` — the one user hook into boot

Near the end of boot, Unraid executes **`/boot/config/go`** as a shell script.
Stock, it contains exactly one meaningful line:

```bash
#!/bin/bash
# Start the Management Utility
/usr/local/sbin/emhttp
```

`emhttp` is the Unraid management daemon (the web GUI / array engine). The `go`
file is the officially-sanctioned place to add your own boot-time commands. This
is where this server installs and starts its custom daemons. See
[`boot/config/go`](../boot/config/go) — it:

1. starts `emhttp` (stock),
2. installs + starts the [custom fan controller](./fan-control.md),
3. turns off the blinking front-panel status LED,
4. installs + starts the [LCD info daemon](./front-panel-lcd.md), and
5. documents (commented out) how to re-establish [Claude CLI](./claude-cli-persistence.md).

Because `/` is RAM, the pattern throughout `go` is **"copy from `/boot/config`
into the live filesystem, then run it"**:

```bash
install -m 755 /boot/config/scripts/fan-autocontrol.sh /usr/local/sbin/fan-autocontrol.sh
/usr/local/sbin/fan-autocontrol.sh start
```

The source of truth is the file on the USB stick; the copy in `/usr/local/sbin`
is disposable and recreated every boot.

## What Unraid persists for you (the contents of `/boot/config`)

`/boot/config` holds far more than this repo does — most of it is GUI-managed and
specific to one server's setup. This repo **only** captures the portable,
hardware-specific custom scripts; everything tied to *this* server's identity
(shares, users, array assignment, network, pools, GUI prefs) is deliberately left
out and reconfigured through the GUI on a rebuild.

| Path | Purpose | In this repo? |
| ---- | ------- | ------------- |
| `go` | boot script — **your customizations** | ✅ yes |
| `scripts/` | **your custom scripts** (not a stock dir) | ✅ yes |
| `modprobe.d/it87.conf` | kernel module blacklist (lets the Asustor fan driver load) | ✅ yes |
| `ident.cfg`, `disk.cfg`, `network.cfg` | server name / disk policy / NIC | ❌ setup-specific (GUI) |
| `share.cfg`, `shares/*.cfg`, `pools/*.cfg` | shares + pool definitions | ❌ setup-specific (GUI) |
| `docker.cfg`, `domain.cfg` | Docker / VM engine settings | ❌ setup-specific (GUI) |
| `plugins/*.plg` | installed plugins | 📄 the driver plugin is documented, not committed |
| `super.dat` | **array assignment** (which disk is in which slot) | ❌ secret-ish (disk serials, binary) |
| `*.key` | **Unraid license** | ❌ never commit |
| `passwd`, `shadow`, `smbpasswd`, `secrets.tdb` | accounts + Samba | ❌ never commit |
| `ssh/`, `ssl/`, `wireguard/` | private keys | ❌ never commit |

See [security.md](./security.md) for what's deliberately excluded and how to back
the rest up privately.

## The practical upshot

To make any customization survive a reboot on Unraid, you have exactly three
options:

1. **Put the file in `/boot/config`** and have `go` copy/symlink it into place at
   boot (what the fan, LCD, and Claude setups all do).
2. **Install it as a plugin** (`.plg`), which Unraid replays at boot.
3. **Put it on the array** and accept that it's only available *after* the array
   starts (fine for Docker `appdata`, not for early-boot daemons).

This repo is essentially a curated, documented backup of option (1) for this
specific machine, plus notes for reproducing options (2) and (3).
