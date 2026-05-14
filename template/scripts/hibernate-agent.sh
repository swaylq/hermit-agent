#!/bin/bash
# hibernate-agent.sh — Pause an idle agent: kill claude + bun + chrome, free
# RAM, preserve session JSONL so wake-agent.sh can `claude --resume` it.
#
# Usage: hibernate-agent.sh <agent-name>
#
# Effects:
#   - Saves session_id + hibernated_at + launch_cmd to <agent>/.claude/state/paused.json
#   - Marks session-status.json state=paused (so status-reporter doesn't bag it as "down")
#   - Sets remain-on-exit on the tmux session so the pane survives claude exit
#   - Kills claude pid, bun child (Telegram MCP), and chrome via chrome-launcher.sh
#   - Removes agent.pid (presence = "claude alive"; absence + paused.json = "hibernated")

set -euo pipefail

NAME="${1:?Usage: hibernate-agent.sh <agent-name>}"

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

# Claude Code stores per-project session JSONLs under
# ~/.claude/projects/<dashified-absolute-path>/. Derive the path the same way
# `multi-agent-status-report.sh` does (replace `/` with `-`).
agents_root_enc=$(echo "$AGENTS_ROOT" | sed 's|/|-|g')
PROJ_DIR="$HOME/.claude/projects/${agents_root_enc}-${NAME}"

mkdir -p "$STATE_DIR"
now=$(date +%s)

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

[ -d "$AGENT_DIR" ] || { log "agent dir not found: $AGENT_DIR"; exit 1; }
[ -f "$PID_FILE" ] || { log "no agent.pid — already hibernated or never started"; exit 1; }

PID=$(cat "$PID_FILE")
if ! kill -0 "$PID" 2>/dev/null; then
  log "claude pid $PID already dead — cleaning up state and exiting"
  rm -f "$PID_FILE"
  exit 0
fi

# Resolve session_id: most-recently-modified JSONL in the project dir.
# Claude Code writes a new JSONL per session; resuming appends to the same file.
if [ -d "$PROJ_DIR" ]; then
  LATEST_JSONL=$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1)
  SESSION_ID=$(basename "${LATEST_JSONL:-}" .jsonl)
else
  SESSION_ID=""
fi

if [ -z "$SESSION_ID" ]; then
  log "no session JSONL found at $PROJ_DIR — refusing to hibernate (wake would have nothing to resume)"
  exit 1
fi

log "hibernating $NAME (claude pid=$PID, session_id=$SESSION_ID)"

# Capture the launch cmdline so wake can respawn with the same flags
# (--effort, --channels, etc differ per agent). Strip any existing --resume
# arg so wake can append a fresh one without duplicates.
ORIG_CMD=$(ps -p "$PID" -o command= 2>/dev/null | sed -E 's/[[:space:]]+--resume[[:space:]]+[^[:space:]]+//g')

# Persist state BEFORE we start killing — if anything below fails, wake-agent.sh
# can still recover from this file.
jq -n \
  --arg sid "$SESSION_ID" \
  --argjson ts "$now" \
  --arg pid "$PID" \
  --arg cmd "$ORIG_CMD" \
  '{session_id:$sid, hibernated_at:$ts, prev_pid:($pid|tonumber), launch_cmd:$cmd}' \
  > "$PAUSED_FILE"

# Update session-status.json so status-reporter recognizes paused state.
if [ -f "$SS_FILE" ]; then
  tmp=$(mktemp)
  jq --argjson ts "$now" '.state="paused" | .paused_at=$ts' "$SS_FILE" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$SS_FILE" || rm -f "$tmp"
fi

# Set remain-on-exit so the tmux pane stays after claude exits — wake uses
# respawn-pane to restart, which needs the pane to still exist.
if tmux has-session -t "=$SESSION" 2>/dev/null; then
  tmux set-option -t "=$SESSION" remain-on-exit on 2>/dev/null || true
  tmux set-window-option -t "=$SESSION" remain-on-exit on 2>/dev/null || true
  log "tmux session $SESSION remain-on-exit on"
else
  log "warning: tmux session $SESSION not found — wake will need to create a fresh session"
fi

# Find bun child (Telegram MCP server) and kill it explicitly. Killing claude
# alone usually reaps bun, but bun has been known to outlive its parent in
# obscure cases; explicit kill keeps the state clean.
BUN_PIDS=()
for child in $(pgrep -P "$PID" 2>/dev/null); do
  for grand in $(pgrep -P "$child" -f 'bun.*server\.ts' 2>/dev/null); do
    BUN_PIDS+=("$grand")
  done
done

# Kill claude (SIGTERM, then SIGKILL fallback).
log "killing claude pid=$PID"
kill "$PID" 2>/dev/null || true
for i in $(seq 1 15); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  log "claude refused SIGTERM after 15s, sending SIGKILL"
  kill -9 "$PID" 2>/dev/null || true
fi

# Mop up any surviving bun children.
if [ "${#BUN_PIDS[@]}" -gt 0 ]; then
  for b in "${BUN_PIDS[@]}"; do
    if kill -0 "$b" 2>/dev/null; then
      log "killing surviving bun child pid=$b"
      kill "$b" 2>/dev/null || true
    fi
  done
fi

# Chrome (optional — only if the agent has chrome-launcher installed).
if [ -x "$AGENT_DIR/scripts/chrome-launcher.sh" ]; then
  log "stopping chrome"
  bash "$AGENT_DIR/scripts/chrome-launcher.sh" stop 2>&1 | sed 's/^/  chrome: /' | tee -a "$LOG"
else
  log "no chrome-launcher.sh — skipping chrome stop"
fi

# Remove agent.pid — its absence + paused.json is how monitoring distinguishes
# "hibernated" from "down" / "alive".
rm -f "$PID_FILE"

log "✅ $NAME hibernated"
echo "session_id=$SESSION_ID"
