#!/bin/bash
# idle-hibernator.sh — Scan sibling agents and hibernate any that have been
# idle longer than IDLE_THRESHOLD_SEC (default 48h).
#
# Designed to run as a LaunchAgent / systemd timer every ~10 minutes. Pairs
# with wake-poller.sh, which routes inbound Telegram messages back to
# hibernated agents.
#
# Env overrides:
#   IDLE_THRESHOLD_SEC  — hibernate cutoff in seconds (default 172800 = 48h)
#   AGENTS_ROOT         — directory to scan (default: parent of this script's agent)
#   HIBERNATOR_SELF     — agent name to exclude (typically the coordinator running this script;
#                         set by the LaunchAgent plist substitution at install time)
#   DRY_RUN=1           — log decisions, don't actually hibernate

set -uo pipefail
export PATH=$HOME/.local/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$PATH

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HUB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${AGENTS_ROOT:=$(cd "$HUB_DIR/.." && pwd)}"
: "${IDLE_THRESHOLD_SEC:=172800}"
: "${HIBERNATOR_SELF:=}"
LOG="$HUB_DIR/.claude/state/idle-hibernator.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

now=$(date +%s)
hibernated_now=()

for dir in "$AGENTS_ROOT"/*/; do
  name=$(basename "$dir")
  # Skip the coordinator itself (it runs this script + wake-poller; hibernating
  # it would leave the fleet without a wake path until something woke it).
  [ -n "$HIBERNATOR_SELF" ] && [ "$name" = "$HIBERNATOR_SELF" ] && continue
  [ -f "$dir/CLAUDE.md" ] || continue

  pid_file="$dir/agent.pid"
  ss="$dir/.claude/state/session-status.json"
  paused="$dir/.claude/state/paused.json"

  # Already hibernated: skip silently.
  [ -f "$paused" ] && continue

  # Must be alive.
  [ -f "$pid_file" ] || continue
  pid=$(cat "$pid_file" 2>/dev/null)
  [ -z "$pid" ] && continue
  kill -0 "$pid" 2>/dev/null || continue

  # Must have valid state file.
  [ -f "$ss" ] || continue

  state=$(jq -r '.state // "unknown"' "$ss" 2>/dev/null)
  last_stop=$(jq -r '.last_stop_ts // 0' "$ss" 2>/dev/null)

  # Only hibernate clean-idle agents. Skip running / stuck / 403 episodes.
  [ "$state" = "idle" ] || continue
  [ "$last_stop" -eq 0 ] && continue

  age=$((now - last_stop))
  [ "$age" -lt "$IDLE_THRESHOLD_SEC" ] && continue

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would hibernate $name (idle ${age}s, threshold ${IDLE_THRESHOLD_SEC}s)"
    continue
  fi

  log "hibernating $name (idle ${age}s)"
  if bash "$SCRIPT_DIR/hibernate-agent.sh" "$name" >> "$LOG" 2>&1; then
    hibernated_now+=("$name")
  else
    log "  hibernate-agent.sh failed for $name (exit $?)"
  fi
done

if [ ${#hibernated_now[@]} -gt 0 ]; then
  log "completed: hibernated ${#hibernated_now[@]} agent(s): ${hibernated_now[*]}"
fi
