#!/bin/bash
# restart.sh — kill the daemon's tmux session and respawn via start.sh.
# State (state/thread.txt, state/update_id.txt) is preserved on disk so the
# daemon resumes the same Telegram chat thread and Codex thread.

set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")" && pwd)"
SESSION="codex-{{AGENT_NAME}}"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "killing tmux session: $SESSION"
    tmux kill-session -t "$SESSION"
    sleep 1
fi

exec "$WORKDIR/start.sh"
