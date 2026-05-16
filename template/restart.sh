#!/bin/bash
# Restart Claude Code agent in this directory.
# Usage: ./restart.sh <old_pid>
#
# Uses tmux respawn-pane (not send-keys) so that a still-alive REPL in the
# pane doesn't interpret the launch command as a chat message.

set -u

OLD_PID="${1:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_NAME="$(basename "$DIR")"
SESSION="claude-$AGENT_NAME"
LOG="$DIR/restart.log"
CLAUDE_BIN="{{CLAUDE_BIN}}"
CHANNEL="plugin:telegram@claude-plugins-official"

# Fallback: find claude on PATH if the baked-in binary is gone
if [ ! -x "$CLAUDE_BIN" ]; then
  CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
fi
if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
  echo "[$(date)] ERROR: claude CLI not found on PATH or at '{{CLAUDE_BIN}}'" >> "$LOG"
  exit 1
fi

CMD="cd $DIR && $CLAUDE_BIN --dangerously-skip-permissions --channels $CHANNEL"

# Re-apply the local telegram-plugin orphan-watchdog patch before respawning.
# Claude plugin sync can overwrite ~/.claude/plugins from GCS, and the patch
# only takes effect for the bun that spawns next. Idempotent; no-op if
# already patched or if the patch script isn't present.
if [ -x "$DIR/scripts/patch-telegram-plugin.sh" ]; then
  "$DIR/scripts/patch-telegram-plugin.sh" >> "$LOG" 2>&1
fi

echo "[$(date)] Restart initiated, old PID=$OLD_PID, bin=$CLAUDE_BIN" >> "$LOG"

# Allow current session to flush Telegram replies
sleep 3

# Kill the old process if a valid PID was given
if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
  kill "$OLD_PID"
  for i in $(seq 1 10); do
    kill -0 "$OLD_PID" 2>/dev/null || break
    sleep 1
  done
  kill -0 "$OLD_PID" 2>/dev/null && kill -9 "$OLD_PID"
  echo "[$(date)] Old process killed" >> "$LOG"
fi

sleep 2

start_pane() {
  if tmux has-session -t "=$SESSION" 2>/dev/null; then
    tmux respawn-pane -t "=$SESSION:" -k "$CMD"
    echo "[$(date)] Respawned pane in existing session" >> "$LOG"
  else
    tmux new-session -d -s "$SESSION" -x 200 -y 50 "$CMD"
    echo "[$(date)] Created new session" >> "$LOG"
  fi
}

resolve_pid() {
  local pane_pid
  pane_pid=$(tmux display -p -t "=$SESSION:" '#{pane_pid}' 2>/dev/null)
  [ -z "$pane_pid" ] && return 1
  # Preferred: pane_pid IS claude (respawn-pane exec's the command directly, no shell wrapper).
  if ps -p "$pane_pid" -o command= 2>/dev/null | grep -q "$(basename "$CLAUDE_BIN")"; then
    echo "$pane_pid"
  else
    # Fallback: shell wrapper hosts claude as a direct child.
    pgrep -P "$pane_pid" -n -f "$(basename "$CLAUDE_BIN")" 2>/dev/null
  fi
}

plugin_alive() {
  local claude_pid="$1"
  [ -z "$claude_pid" ] && return 1
  # Process tree: claude → "bun run ... start" wrapper → "bun server.ts"
  local pid
  for pid in $(pgrep -P "$claude_pid" 2>/dev/null); do
    pgrep -P "$pid" -f 'bun.*server\.ts' >/dev/null 2>&1 && return 0
  done
  return 1
}

start_pane
sleep 4
NEW_PID=$(resolve_pid)

# Plugin-alive check: claude may start OK but telegram plugin's bun subprocess
# can silently fail to spawn (historical race on shared node_modules). Retry once.
if [ -n "$NEW_PID" ] && ! plugin_alive "$NEW_PID"; then
  sleep 4
  if ! plugin_alive "$NEW_PID"; then
    echo "[$(date)] Plugin subprocess missing — retrying claude once" >> "$LOG"
    kill "$NEW_PID" 2>/dev/null
    sleep 2
    start_pane
    sleep 6
    NEW_PID=$(resolve_pid)
  fi
fi

if [ -n "$NEW_PID" ]; then
  echo "$NEW_PID" > "$DIR/agent.pid"
  plugin_alive "$NEW_PID" && plugin_note="plugin up" || plugin_note="PLUGIN MISSING"
  echo "[$(date)] New PID=$NEW_PID ($plugin_note, channel=$CHANNEL)" >> "$LOG"
else
  echo "[$(date)] WARNING: Could not resolve new claude PID via tmux pane" >> "$LOG"
fi
