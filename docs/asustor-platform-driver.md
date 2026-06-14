# Asustor platform drivers (the `asustorpfd` plugin)

To control Asustor-specific hardware — the IT8625 fan/PWM, the front-panel LEDs,
and the LCD — Unraid needs kernel drivers that aren't in the stock image. These
come from a community plugin. This is the foundation the fan and LCD scripts are
built on; without it, none of the `/sys/class/hwmon/.../pwm1` or LED paths exist.

## The plugin chain

```
Unraid plugin:   unraid-asustorpfd  (author: Terebi42)
                 https://github.com/Terebi42/unraid-asustor-pfd
        │  wraps and ships, per kernel version, a compiled package of…
        ▼
Driver source:   asustor-platform-driver  (author: mafredri)
                 https://github.com/mafredri/asustor-platform-driver
```

- **`unraid-asustorpfd.plg`** is the Unraid plugin manifest. On install it
  downloads a kernel-version-matched `.txz` package, verifies its MD5, installs
  the drivers, and (per the plugin's logic) manages an `it87` blacklist. A reboot
  is required after install.
- The package it installs (e.g.
  `asustor_pfd-20251207-6.18.33-Unraid-1.txz`) contains mafredri's drivers built
  against the **exact running kernel** (here, `6.18.33-Unraid`). Because it's
  kernel-specific, **do not** commit or rely on an old `.txz` after an Unraid
  update — let the plugin re-fetch the matching build.

On this server the plugin's persistent state lives at
`/boot/config/plugins/asustorpfd/` (the `.txz` package + an update helper). That
directory is intentionally **not** committed — it's a re-downloadable binary
blob. Reinstall the plugin from **Community Applications** (search "Asustor
Platform Drivers"), or directly from its
[plugin URL](https://github.com/Terebi42/unraid-asustor-pfd). A reboot is
required after installing.

## What the drivers provide

Once loaded, the Asustor platform drivers expose (names as seen on this board):

| Driver | Gives you |
| ------ | --------- |
| `asustor_it87` | the IT8625 hardware monitor as hwmon `it8625`: `pwm1`, `pwm1_enable`, `fan1_input` |
| `asustor` (GPIO/LED platform) | front-panel LEDs under `/sys/devices/platform/asustor_it87.*/.../gpled*` and the GPIO needed for the LCD |

These are exactly the sysfs paths the [fan controller](./fan-control.md) writes
(`pwm1`) and the `go` script pokes (`gpled1_blink`).

## The `it87` blacklist — why it exists

File: [`boot/config/modprobe.d/it87.conf`](../boot/config/modprobe.d/it87.conf)

```
blacklist it87
```

The **mainline `it87`** driver will try to claim the IT8625 but doesn't drive it
correctly on this board. The Asustor fork registers as **`asustor_it87`**
instead. If both were allowed to load they'd fight over the chip, so the stock
`it87` is blacklisted, leaving the Asustor driver in sole control. This is the
classic gotcha when doing fan control on Asustor (and many QNAP/other ITE-based)
NAS units under a generic Linux: *make sure the right IT87 variant owns the
chip.*

> Note: the asustorpfd plugin also manages an `it87` blacklist as part of its own
> install/uninstall logic. Keeping this explicit `modprobe.d/it87.conf` in
> `/boot/config` makes the intent durable and visible independent of plugin
> state. If you ever fully remove the plugin, revisit this file too.
