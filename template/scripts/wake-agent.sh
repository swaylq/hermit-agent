#!/bin/bash
# wake-agent.sh — Wake a hibernated agent: respawn its tmux pane with
# `claude --resume <session_id>` so the conversation picks up where it left off.
#
# Usage: wake-agent.sh <agent-name>
#
# Expects <agent>/.claude/state/paused.json from hibernate-agent.sh.
# After wake, agent.pid is written and session-status.json state flips back to
# running/idle via Claude Code's normal SessionStart hook.

set -euo pipefail

NAME="${1:?Usage: wake-agent.sh <agent-name>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HUB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${AGENTS_ROOT:=$(cd "$HUB_DIR/.." && pwd)}"

AGENT_DIR="$AGENTS_ROOT/$NAME"
SESSION="claude-$NAME"
STATE_DIR="$AGENT_DIR/.claude/state"
PAUSED_FILE="$STATE_DIR/paused.json"
SS_FILE="$STATE_DIR/session-status.json"
PID_FILE="$AGENT_DIR/agent.pid"
LOG="$AGENT_DIR/hibernate.log"

CHANNEL="plugin:telegram@claude-plugins-official"
CLAUDE_BIN="$(command -v claude || echo "$HOME/.local/bin/claude")"

log() { echo "[$(date '+%F %T')] wake: $*" | tee -a "$LOG"; }

[ -d "$AGENT_DIR" ] || { log "agent dir not found: $AGENT_DIR"; exit 1; }
[ -f "$PAUSED_FILE" ] || { log "no paused.json — agent not hibernated"; exit 1; }

SESSION_ID=$(jq -r '.session_id // empty' "$PAUSED_FILE")
HIBERNATED_AT=$(jq -r '.hibernated_at // 0' "$PAUSED_FILE")
LAUNCH_CMD=$(jq -r '.launch_cmd // empty' "$PAUSED_FILE")

if [ -z "$SESSION_ID" ]; then
  log "paused.json missing session_id — cannot resume"
  exit 1
fi

# Idempotency: if agent.pid already exists and is alive, nothing to wake.
if [ -f "$PID_FILE" ]; then
  existing=$(cat "$PID_FILE" 2>/dev/null)
  if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
    log "agent.pid $existing already alive — wake is a no-op"
    rm -f "$PAUSED_FILE"
    exit 0
  fi
fi

now=$(date +%s)
slept=$(( now - HIBERNATED_AT ))
log "waking $NAME (session_id=$SESSION_ID, hibernated ${slept}s ago)"

# Reuse the original launch cmdline so per-agent flags (--effort, --channels,
# --agent, …) survive the round-trip. Fall back to a minimal default if
# hibernate didn't capture it (older paused.json).
if [ -n "$LAUNCH_CMD" ]; then
  CMD="cd $AGENT_DIR && exec $LAUNCH_CMD --resume $SESSION_ID"
else
  CMD="cd $AGENT_DIR && exec $CLAUDE_BIN --dangerously-skip-permissions --channels $CHANNEL --resume $SESSION_ID"
fi

start_pane() {
  if tmux has-session -t "=$SESSION" 2>/dev/null; then
    # remain-on-exit was set by hibernate so the pane should be in dead/idle state
    tmux respawn-pane -t "=$SESSION:" -k "$CMD"
    log "respawned pane in existing session $SESSION"
  else
    tmux new-session -d -s "$SESSION" -x 200 -y 50 "$CMD"
    log "created new tmux session $SESSION"
  fi
}

resolve_pid() {
  local pane_pid
  pane_pid=$(tmux display -p -t "=$SESSION:" '#{pane_pid}' 2>/dev/null)
  [ -z "$pane_pid" ] && return 1
  if ps -p "$pane_pid" -o command= 2>/dev/null | grep -q 'claude'; then
    echo "$pane_pid"
  else
    pgrep -P "$pane_pid" -n -f 'claude' 2>/dev/null
  fi
}

plugin_alive() {
  local claude_pid="$1"
  [ -z "$claude_pid" ] && return 1
  local pid
  for pid in $(pgrep -P "$claude_pid" 2>/dev/null); do
    pgrep -P "$pid" -f 'bun.*server\.ts' >/dev/null 2>&1 && return 0
  done
  return 1
}

start_pane

# Claude Code's plugin sync + JSONL replay takes 5-15s depending on session size.
# Poll up to 30s for the pid to come up.
NEW_PID=""
for i in $(seq 1 15); do
  sleep 2
  NEW_PID=$(resolve_pid || true)
  [ -n "$NEW_PID" ] && break
done

if [ -z "$NEW_PID" ]; then
  log "❌ could not resolve new claude pid after 30s"
  exit 1
fi

# Old/large sessions trigger a "Resume from summary / Resume full session as-is /
# Don't ask me again" modal — Claude Code's cost guardrail. Without dismissal,
# the resumed session blocks until somebody picks an option, so no inbound
# message gets processed. We pick option 1 (summary) by default: full resume
# can cost several dollars per wake, and the compact preserves enough context
# for the agent to handle the inbound message. Detection window: 15s.
for i in $(seq 1 15); do
  pane=$(tmux capture-pane -t "=$SESSION:" -p 2>/dev/null | tail -25)
  if echo "$pane" | grep -qE "Resume from summary|Resume full session as-is"; then
    tmux send-keys -t "=$SESSION:" "1" Enter 2>/dev/null
    log "auto-dismissed resume-summary prompt (picked: 1 / summary)"
    break
  fi
  # Already past prompt — REPL ready.
  if echo "$pane" | grep -qE "^❯[[:space:]]*$|^❯[[:space:]]+Try "; then
    break
  fi
  sleep 1
done

# Wait a bit more for bun to spawn.
plugin_up="no"
for i in $(seq 1 10); do
  if plugin_alive "$NEW_PID"; then
    plugin_up="yes"
    break
  fi
  sleep 1
done

echo "$NEW_PID" > "$PID_FILE"

# Flip session-status state. Stop hook will eventually update it to idle/running
# once the first turn finishes — for now mark resuming.
if [ -f "$SS_FILE" ]; then
  tmp=$(mktemp)
  jq --argjson ts "$now" 'del(.paused_at) | .state="idle" | .last_resume_ts=$ts' "$SS_FILE" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$SS_FILE" || rm -f "$tmp"
fi

# Done. paused.json out of the way so monitoring stops treating it as paused.
rm -f "$PAUSED_FILE"

log "✅ $NAME woken (pid=$NEW_PID, plugin=$plugin_up, slept=${slept}s)"
echo "pid=$NEW_PID plugin=$plugin_up"
