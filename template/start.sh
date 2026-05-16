#!/bin/bash
# Start the hermit agent in a detached tmux session.
# Usage: ./start.sh           — launch if not running
#        ./start.sh --attach  — launch and attach to the tmux session
#        ./start.sh --status  — show whether the session is running

set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_NAME="$(basename "$DIR")"
SESSION="claude-$AGENT_NAME"
CLAUDE_BIN="{{CLAUDE_BIN}}"
CHANNEL="plugin:telegram@claude-plugins-official"

if ! command -v tmux >/dev/null 2>&1; then
  echo "Error: tmux not found. Install via 'brew install tmux'." >&2
  exit 1
fi

if [ ! -x "$CLAUDE_BIN" ]; then
  # fallback: find claude on PATH
  CLAUDE_BIN="$(command -v claude || true)"
  if [ -z "$CLAUDE_BIN" ]; then
    echo "Error: claude CLI not found. Install from https://claude.com/claude-code." >&2
    exit 1
  fi
fi

CMD="cd $DIR && $CLAUDE_BIN --dangerously-skip-permissions --channels $CHANNEL"

cmd_status() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    pane_pid=$(tmux display -p -t "$SESSION" '#{pane_pid}' 2>/dev/null)
    echo "tmux session '$SESSION' is up (pane PID: $pane_pid)."
    [ -f "$DIR/agent.pid" ] && echo "agent.pid: $(cat "$DIR/agent.pid")"
  else
    echo "tmux session '$SESSION' is not running."
  fi
}

cmd_start() {
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Already running (tmux session: $SESSION). Use './start.sh --attach' to attach, or './restart.sh' to restart."
    return 0
  fi

  # Re-apply the local telegram-plugin orphan-watchdog patch before the
  # first bun spawn. Idempotent and a no-op if the patch script isn't
  # present or the upstream code has changed.
  if [ -x "$DIR/scripts/patch-telegram-plugin.sh" ]; then
    "$DIR/scripts/patch-telegram-plugin.sh" || true
  fi

  tmux new-session -d -s "$SESSION" -x 200 -y 50 "$CMD"
  sleep 4

  pane_pid=$(tmux display -p -t "$SESSION" '#{pane_pid}' 2>/dev/null)
  new_pid=""
  if [ -n "$pane_pid" ]; then
    if ps -p "$pane_pid" -o command= 2>/dev/null | grep -q "$(basename "$CLAUDE_BIN")"; then
      new_pid="$pane_pid"
    else
      new_pid=$(pgrep -P "$pane_pid" -n -f "$(basename "$CLAUDE_BIN")" 2>/dev/null)
    fi
  fi
  [ -n "$new_pid" ] && echo "$new_pid" > "$DIR/agent.pid"

  echo "Started hermit agent '$AGENT_NAME'."
  echo "  tmux session: $SESSION"
  [ -n "$new_pid" ] && echo "  agent.pid:    $new_pid"
  echo ""
  echo "Next steps:"
  echo "  1. Send any Telegram message to your bot."
  echo "  2. Attach to the session with 'tmux attach -t $SESSION' (detach: Ctrl-b d)."
  echo "  3. To restart: './restart.sh'  |  To stop: 'tmux kill-session -t $SESSION'"
}

case "${1:-start}" in
  --attach) cmd_start; tmux attach -t "$SESSION" ;;
  --status) cmd_status ;;
  start|"") cmd_start ;;
  *)        echo "Usage: ./start.sh [--attach|--status]" >&2; exit 1 ;;
esac
