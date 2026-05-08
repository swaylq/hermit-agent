#!/bin/bash
# {{AGENT_NAME}} bridge launcher.
# Loads .env and runs scripts/tg-bridge.py inside a tmux session.

set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
SESSION="codex-{{AGENT_NAME}}"

if [ ! -f "$WORKDIR/.env" ]; then
    echo "missing $WORKDIR/.env (copy .env.template, fill TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID)" >&2
    exit 1
fi

# Export .env into shell env (treat as KEY=VAL lines, ignore # comments).
set -a
# shellcheck disable=SC1091
source "$WORKDIR/.env"
set +a

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "session $SESSION already exists; attach with: tmux attach -t $SESSION"
    exit 0
fi

tmux new-session -d -s "$SESSION" -c "$WORKDIR" \
    "TELEGRAM_BOT_TOKEN='$TELEGRAM_BOT_TOKEN' TELEGRAM_CHAT_ID='$TELEGRAM_CHAT_ID' python3 $WORKDIR/scripts/tg-bridge.py"

echo "started tmux session: $SESSION"
echo "  attach:   tmux attach -t $SESSION"
echo "  stop:     tmux kill-session -t $SESSION"
echo "  thread:   $WORKDIR/state/thread.txt"
