#!/bin/bash
# patch-telegram-plugin.sh — Locally strip the buggy orphan watchdog from
# claude-plugins-official/telegram/server.ts.
#
# Background: the plugin's `process.ppid !== bootPpid` watchdog at
# server.ts:670 fires false positives during normal bun-wrapper startup
# (the wrapper exits/execs and the OS reparents this child to init,
# which the watchdog mis-reads as "parent Claude died"). The plugin
# self-terminates roughly every ~5s on affected hosts, claude doesn't
# notice, MCP tools silently disappear, and the agent goes mute until
# someone runs ./restart.sh.
#
# anthropics/claude-plugins-official is read-only to external contributors
# (github-actions auto-closes non-Anthropic PRs within minutes), so the
# upstream fix in draft PR #1424 has been stalled for a month. Patching
# the local plugin cache is the only way to get the fix today.
#
# Patches both locations so a fresh `claude plugin install` won't undo it:
#   ~/.claude/plugins/cache/claude-plugins-official/telegram/<ver>/server.ts
#   ~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts
#
# Idempotent: re-running on already-patched files is a no-op. start.sh and
# restart.sh call this before spawning claude so Anthropic re-syncing the
# marketplace from GCS (which overwrites the patch) doesn't silently
# regress the next launch.
#
# Effect: kicks in when a fresh bun reads server.ts at startup. An
# already-running bun keeps the old code until its next restart.

set -uo pipefail

CACHE_GLOB="$HOME/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts"
MARKETPLACE_FILE="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"

patch_file() {
  local f=$1
  [ -f "$f" ] || return 0
  if ! grep -q '^const bootPpid = process.ppid$' "$f"; then
    echo "  already patched: $f"
    return 0
  fi
  python3 - "$f" <<'PY'
import sys
path = sys.argv[1]
with open(path, 'r') as fh:
    src = fh.read()

old = (
    "// Orphan watchdog: stdin events above don't reliably fire when the parent\n"
    "// chain (`bun run` wrapper → shell → us) is severed by a crash. Poll for\n"
    "// reparenting (POSIX) or a dead stdin pipe and self-terminate.\n"
    "const bootPpid = process.ppid\n"
    "setInterval(() => {\n"
    "  const orphaned =\n"
    "    (process.platform !== 'win32' && process.ppid !== bootPpid) ||\n"
    "    process.stdin.destroyed ||\n"
    "    process.stdin.readableEnded\n"
    "  if (orphaned) shutdown()\n"
    "}, 5000).unref()\n"
)
new = (
    "// Stdin EOF watchdog (LOCAL PATCH, hermit-agent): the upstream block also\n"
    "// did a `process.ppid !== bootPpid` check that fires falsely when the\n"
    "// bun-run wrapper exits/execs during normal startup and reparents this\n"
    "// child to init. stdin EOF alone is the reliable signal — the kernel\n"
    "// closes our MCP pipe whenever Claude Code dies regardless of any\n"
    "// intermediate wrappers. See anthropics/claude-plugins-official PR\n"
    "// #1424 commit 3 (stalled in DRAFT) for the upstream-equivalent fix.\n"
    "setInterval(() => {\n"
    "  if (process.stdin.destroyed || process.stdin.readableEnded) shutdown()\n"
    "}, 5000).unref()\n"
)
if old not in src:
    sys.stderr.write(f"  ERR: orphan-watchdog block not found verbatim in {path}; manual review needed (plugin version may have changed)\n")
    sys.exit(2)
with open(path, 'w') as fh:
    fh.write(src.replace(old, new))
print(f"  patched: {path}")
PY
}

echo "patching telegram plugin server.ts (drop ppid orphan-watchdog check)"
for f in $CACHE_GLOB; do
  patch_file "$f"
done
patch_file "$MARKETPLACE_FILE"
