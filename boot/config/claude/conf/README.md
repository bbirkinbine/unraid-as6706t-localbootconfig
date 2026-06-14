# `claude/conf/` — intentionally partial

This mirrors `/boot/config/claude/conf/` on the NAS, the persistent home for the
Claude Code CLI (see [`docs/claude-cli-persistence.md`](../../../../docs/claude-cli-persistence.md)).

Only the non-secret file is committed:

- `settings.json` ✅ — CLI settings (just the theme).

Deliberately **not** committed (see [`docs/security.md`](../../../../docs/security.md)):

- `.credentials.json` ❌ — your Claude **OAuth token**. Secret.
- `.claude.json` ❌ — local state: identity + per-project history.

And not committed because it's large + re-downloadable:

- `../share/versions/*` ❌ — the ~250 MB self-updating CLI binary.
