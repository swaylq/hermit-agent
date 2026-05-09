#!/bin/bash
# run-cron.sh — wrapper for cron/<task>.md prompts.
# Loads .env, runs `codex exec` with a 1200s ceiling, then posts the agent's
# last message to Telegram (since codex exec has no native Telegram channel).
#
# Usage: run-cron.sh <task-name>
#   <task-name> matches a file at cron/<task-name>.md whose contents are
#   handed to codex as the user prompt.
#
# Logs to .codex/state/cron-<task>.log (rotated by launchd).

set -euo pipefail

TASK="${1:-}"
if [ -z "$TASK" ]; then
    echo "usage: $0 <task-name>" >&2
    exit 2
fi

WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"
PROMPT_FILE="$WORKDIR/cron/$TASK.md"
STATE_DIR="$WORKDIR/.codex/state"
LOG="$STATE_DIR/cron-$TASK.log"
LAST="$STATE_DIR/cron-$TASK.last.txt"

if [ ! -f "$PROMPT_FILE" ]; then
    echo "no prompt file: $PROMPT_FILE" >&2
    exit 2
fi

mkdir -p "$STATE_DIR"

# Load env (.env), but never echo it.
set -a
# shellcheck disable=SC1091
[ -f "$WORKDIR/.env" ] && source "$WORKDIR/.env"
set +a

cd "$WORKDIR"

PROMPT="$(cat "$PROMPT_FILE")"

{
    printf '\n=== %s — fire %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$TASK"
} >> "$LOG"

if "$WORKDIR/scripts/with-timeout.sh" 1200 \
        codex exec --json --output-last-message "$LAST" \
        --skip-git-repo-check \
        --dangerously-bypass-approvals-and-sandbox \
        "$PROMPT" \
        >> "$LOG" 2>&1; then
    REPLY="$(cat "$LAST" 2>/dev/null || echo '(no last message)')"
    {
        printf '\n--- last message ---\n%s\n' "$REPLY"
    } >> "$LOG"

    # Post a brief summary to Telegram so sway sees fire results.
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        SUMMARY="[cron $TASK] $(printf '%s' "$REPLY" | head -c 1500)"
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${SUMMARY}" \
            > /dev/null
    fi
else
    rc=$?
    {
        printf '\n--- failed (exit=%d) ---\n' "$rc"
    } >> "$LOG"
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=[cron $TASK] failed (exit=$rc) — see $LOG" \
            > /dev/null
    fi
    exit "$rc"
fi
