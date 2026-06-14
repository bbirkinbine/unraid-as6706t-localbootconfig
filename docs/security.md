# Security: what is deliberately NOT in this repo

This is a **public** repository. It contains only **portable, non-secret
scripts** — nothing tied to one server's identity and no credentials. Many files
that live alongside these scripts in `/boot/config` on a real server are
**intentionally excluded** because they're secrets, machine identity, PII, or
just specific to one setup. Common secret patterns are also blocked by
[`.gitignore`](../.gitignore) as a second line of defense.

**Back the secrets up separately and privately** (an encrypted archive, a
password manager, or Unraid's own USB flash backup) — they are *not* here and
*not* meant to be.

## Excluded: secrets & machine identity (never commit)

| Path on NAS (`/boot/config/…`) | What it is | Why excluded |
| ------------------------------ | ---------- | ------------ |
| `*.key` (e.g. `Unleashed.key`) | **Unraid license key** | tied to your purchase / USB GUID; never publish |
| `passwd`, `shadow` | local Linux accounts + **password hashes** | credential material |
| `smbpasswd`, `secrets.tdb` | Samba users + **machine secret** | credential material |
| `ssh/ssh_host_*_key` | **SSH host private keys** | private keys |
| `ssh/root/authorized_keys` | keys allowed to log in | access control list |
| `ssl/` | TLS **certificates and private keys** | private keys |
| `wireguard/` | WireGuard **VPN private keys** | private keys |
| `rclone/rclone.conf` | rclone remotes (cloud tokens/obscured pw) | credential material (empty on this box, still excluded by pattern) |
| `claude/conf/.credentials.json` | **Claude Code OAuth token** | your login |
| `claude/conf/.claude.json` | Claude local state | identity + per-project history |
| `claude/share/versions/*` | the Claude CLI binary (~250 MB) | huge, re-downloadable (not secret, just noise) |
| `machine-id`, `random-seed` | machine identity / RNG seed | should be unique per install; not reused |
| `.env` (repo root) | the SSH login used to pull these files | credential; for local use only |

## Excluded: per-server setup (not secret, just out of scope)

These aren't dangerous to publish, but they describe *one specific server* rather
than portable hardware behavior, so they're left out and reconfigured via the
Unraid GUI on a rebuild: `ident.cfg`, `disk.cfg`, `share.cfg`, `shares/*.cfg`,
`pools/*.cfg`, `docker.cfg`, `domain.cfg`, `network*.cfg`, the dashboard/editor
GUI prefs, the disk bay/serial inventory, `super.dat` (array assignment), and the
list of non-hardware plugins (Tailscale, unBALANCE, etc.).

## How to back up the excluded secrets

Pick one:

- **Unraid's built-in flash backup** — *Main → Flash → Flash Backup*, or the
  Unraid Connect "Flash backup" feature. This captures the *entire* `/boot`
  (including all the secrets) into a downloadable zip. Store it somewhere private.
- **Manual encrypted archive**, e.g. from a workstation:

  ```bash
  ssh root@nas 'tar -C /boot -czf - config' | \
    gpg -c -o unraid-boot-config.$(date +%F).tar.gz.gpg
  ```

  Keep the resulting `.gpg` somewhere private (it contains everything, secrets
  included).

## If a secret is ever committed by mistake

1. **Rotate it** — a secret that touched a public repo is compromised even after
   deletion (it's cached/forked/indexed). Regenerate the SSH host keys, re-issue
   the cert, re-auth Claude/Tailscale, change passwords, etc.
2. Then scrub history (`git filter-repo` or BFG) and force-push, but treat step 1
   as the real fix — removal alone is not sufficient.

## Before the first `git push`

Run the staged-content scan in [restore-guide.md](./restore-guide.md#pre-push-checklist)
(or simply `git grep` the staged tree for obvious tokens) so nothing slipped past
the denylist.
