# Persisting the Claude Code CLI across reboots

Script: [`boot/config/scripts/claude-persist.sh`](../boot/config/scripts/claude-persist.sh)

The Claude Code CLI installs itself into `/root` and `/root/.local`. On Unraid
those live in the RAM root (see
[unraid-boot-and-persistence.md](./unraid-boot-and-persistence.md)), so a normal
`claude` install **evaporates on every reboot** — the binary, your login, and
your settings all vanish. This script makes Claude survive reboots by keeping the
real files on the boot pool and recreating the RAM-side links each boot.

## The problem, concretely

A fresh `claude` install creates:

| RAM-root path | What it is |
| ------------- | ---------- |
| `/root/.local/share/claude/versions/<ver>` | the actual CLI executable(s); self-updates land here |
| `/root/.local/bin/claude` | launcher on `PATH` |
| `/root/.claude/.credentials.json` | OAuth token (your login) |
| `/root/.claude/settings.json` | settings (theme, etc.) |
| `/root/.claude.json` | local state (onboarding, per-project history) |

All of that is under `/root` → RAM → gone after reboot.

## The strategy: store on `/boot`, symlink into RAM

The persistent copy lives on the boot pool at **`/boot/config/claude/`**:

```
/boot/config/claude/
├── share/versions/<ver>     ← the CLI executable(s)  (gitignored: large, re-downloadable)
└── conf/
    ├── .credentials.json     ← OAuth token  (gitignored: SECRET)
    ├── settings.json         ← settings     (committed: just the theme)
    └── .claude.json          ← local state  (gitignored: history/identity)
```

On each boot, `claude-persist.sh` recreates the RAM-side paths as **symlinks**
pointing back at that store:

- `/root/.local/share/claude` → `…/claude/share`
  (so **self-updates write through the symlink onto the boot pool** and survive)
- `/root/.local/bin/claude` and `/usr/local/bin/claude` → the newest
  `share/versions/*` (launcher on `PATH` for every shell)
- `/root/.claude/.credentials.json`, `/root/.claude/settings.json`,
  `/root/.claude.json` → the files under `conf/`
  (so **token refreshes and settings changes also persist**)

Because the live paths are symlinks onto persistent storage, anything Claude
writes later — a self-update, a refreshed token, a changed setting — lands on the
boot pool automatically. No re-capture needed.

## Idempotent + self-seeding

The script is safe to run repeatedly. The first time you run it after a fresh
`claude` install, it **seeds** the persistent store: if it finds a real (non-symlink)
install in `/root`, it copies it into `/boot/config/claude/` before flipping the
RAM side to symlinks. After that, every run just re-links.

So the workflow is:

```bash
# 1. Install Claude Code normally (one time, into the RAM root):
curl -fsSL https://claude.ai/install.sh | bash      # or the current install method
claude            # log in once

# 2. Capture it onto the boot pool + wire up the links:
/boot/config/scripts/claude-persist.sh

# 3. After any reboot, replay the links:
/boot/config/scripts/claude-persist.sh
```

## Why it's NOT run automatically at boot

In [`boot/config/go`](../boot/config/go) the Claude lines are present but
**commented out**, on purpose:

```bash
# --- Persist Claude Code CLI across reboots (RAM root) — DISABLED on boot ---
# Intentionally not run automatically so it can't interfere with normal boot.
#   /boot/config/scripts/claude-persist.sh
```

The rationale: a developer-convenience tool should not be in the critical boot
path of a backup server. If a future Claude layout change ever made the script
misbehave, you don't want it wedging an unattended boot. It's a deliberate
trade-off — **Claude is re-established by hand after a reboot** by running the one
command above. Uncomment the two lines in `go` if you'd rather have it automatic.

## What's in this repo vs. what isn't

- ✅ Committed: the `claude-persist.sh` script itself, and
  `boot/config/claude/conf/settings.json` (it only contains
  `{"theme": "light-daltonized"}`).
- ❌ Not committed (see [security.md](./security.md)):
  - `.credentials.json` — your **OAuth token**; never publish.
  - `.claude.json` — local state including identity and per-project history.
  - `share/versions/*` — the ~250 MB self-updating binary; `claude` re-downloads
    it.
