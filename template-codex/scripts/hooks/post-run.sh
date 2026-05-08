#!/bin/bash
# post-run hook — runs after codex returns a reply, before daemon sends to Telegram.
#
# Receives via env:
#   CODEX_PROMPT       user's incoming message
#   CODEX_REPLY        codex agent reply (raw)
#   CODEX_THREAD_ID    current thread uuid
#   CODEX_CHAT_ID      Telegram chat_id
#
# If this script prints non-empty text to stdout, the daemon will REPLACE the
# reply with that text before sending. Useful for redaction / markdown stripping.
# Print nothing → daemon sends original reply unchanged.
#
# Default behaviour: strip the most common Markdown emphasis/code marks so
# Telegram plain-text reads cleanly even if codex slipped some in. Also append a
# tiny daily-log line.

set -euo pipefail

# --- daily log (side effect, not visible to user) -----------------------------
log_dir="$(cd "$(dirname "$0")/../.." && pwd)/memory"
mkdir -p "$log_dir"
log="$log_dir/$(date +%Y-%m-%d).md"
{
  printf '\n## %s — turn\n' "$(date +%H:%M:%S)"
  printf '> prompt: %s\n' "${CODEX_PROMPT:0:200}"
  printf '> reply : %s\n' "${CODEX_REPLY:0:200}"
} >> "$log"

# --- markdown strip on the reply ----------------------------------------------
# Remove common markdown markers without rewriting the whole text.
# Conservative: drop only the marker characters, not the content they wrap.
printf '%s' "$CODEX_REPLY" | sed -E '
  s/`+([^`]*)`+/\1/g;
  s/\*\*([^*]+)\*\*/\1/g;
  s/__([^_]+)__/\1/g;
  s/^#+ //g;
  s/\[([^]]+)\]\(([^)]+)\)/\1 (\2)/g;
'
