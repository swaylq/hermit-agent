#!/bin/bash
# boot hook — runs once at daemon startup (Codex equivalent of Claude Code's
# SessionStart hook).
#
# No env beyond the daemon's own. Use it for:
#   - state init / migration
#   - redact stale tokens from previous sessions
#   - validate config / fail-fast on missing deps
#   - log "agent online" for monitoring
#
# Exit code != 0 logs a warning but does not stop the daemon.
# Default: write a startup line to today's daily log.

set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")/../.." && pwd)"
log_dir="$WORKDIR/memory"
mkdir -p "$log_dir"
log="$log_dir/$(date +%Y-%m-%d).md"

if [ ! -f "$log" ]; then
  printf '# %s — codex-demo daily log\n' "$(date +%Y-%m-%d)" > "$log"
fi
printf '\n## %s — bridge boot\n' "$(date +%H:%M:%S)" >> "$log"

# --- FIRST_RUN.md welcome flow ---------------------------------------
# If FIRST_RUN.md exists, send the block between --- markers via Telegram,
# then delete the file so this fires only once per workspace.
first_run="$WORKDIR/FIRST_RUN.md"
if [ -f "$first_run" ]; then
  # Load token from .env without exposing on cli (env-only).
  if [ -f "$WORKDIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$WORKDIR/.env"
    set +a
  fi
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    # Extract content between the first two --- delimiter lines.
    msg=$(awk '/^---$/{n++; next} n==1 {print}' "$first_run")
    if [ -n "$msg" ]; then
      # POST via curl with --data-urlencode so newlines and unicode survive.
      curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${msg}" \
        > /dev/null && rm -f "$first_run"
      printf '## %s — FIRST_RUN welcome sent + file removed\n' "$(date +%H:%M:%S)" >> "$log"
    fi
  fi
fi
