#!/bin/bash
# claude-persist.sh — keep Claude Code CLI alive across reboots on Unraid.
#
# Unraid's root filesystem (/, /root, /usr overlay, /var/local) is RAM and is
# rebuilt every boot, so anything Claude installs into /root vanishes. The boot
# pool (/boot) is the only persistent, writable, early-mounted storage, so the
# live install + auth live there and this script recreates the RAM-side links
# on every boot. It is idempotent and self-seeding: run it once by hand after a
# fresh `claude` install to capture it, and it's wired into /boot/config/go to
# replay on every boot.
set -u

STORE=/boot/config/claude     # persistent home on the boot pool
SHARE="$STORE/share"          # holds versions/<ver> executables (self-updates land here)
CONF="$STORE/conf"            # holds .credentials.json / settings.json / .claude.json
HOME_DIR=/root

mkdir -p "$SHARE/versions" "$CONF"

# --- Seed the persistent store from a fresh RAM install (first run / after a manual reinstall) ---
if [ -d "$HOME_DIR/.local/share/claude/versions" ] && [ ! -L "$HOME_DIR/.local/share/claude" ]; then
  cp -a "$HOME_DIR/.local/share/claude/versions/." "$SHARE/versions/" 2>/dev/null
fi
for f in .credentials.json settings.json; do
  [ -f "$HOME_DIR/.claude/$f" ] && [ ! -L "$HOME_DIR/.claude/$f" ] && cp -a "$HOME_DIR/.claude/$f" "$CONF/$f"
done
[ -f "$HOME_DIR/.claude.json" ] && [ ! -L "$HOME_DIR/.claude.json" ] && cp -a "$HOME_DIR/.claude.json" "$CONF/.claude.json"

# --- Recreate the RAM-side links pointing at the persistent store ---
# 1. Binary tree: self-updates write through the symlink onto the boot pool and survive reboot.
mkdir -p "$HOME_DIR/.local/share" "$HOME_DIR/.local/bin"
rm -rf "$HOME_DIR/.local/share/claude"
ln -sfn "$SHARE" "$HOME_DIR/.local/share/claude"

# 2. Launcher on PATH -> newest installed version.
latest=$(ls -1 "$SHARE/versions"/* 2>/dev/null | sort -V | tail -n1)
if [ -n "$latest" ]; then
  ln -sfn "$latest" "$HOME_DIR/.local/bin/claude"
  ln -sfn "$latest" /usr/local/bin/claude   # /usr/local/bin is on PATH for all shells
fi

# 3. Auth + config: symlink so token refreshes and setting changes also persist.
mkdir -p "$HOME_DIR/.claude"
for f in .credentials.json settings.json; do
  [ -f "$CONF/$f" ] && ln -sfn "$CONF/$f" "$HOME_DIR/.claude/$f"
done
[ -f "$CONF/.claude.json" ] && ln -sfn "$CONF/.claude.json" "$HOME_DIR/.claude.json"

echo "claude-persist: linked $(readlink -f "$HOME_DIR/.local/bin/claude" 2>/dev/null || echo '<none>')"
