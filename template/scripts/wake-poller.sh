#!/bin/bash
# wake-poller.sh — Poll Telegram getUpdates for each hibernated agent and wake
# the agent if a message is queued. Designed to run as a 60s LaunchAgent /
# systemd timer.
#
# Why this exists: hibernate-agent.sh kills the per-agent bun, so the bot's
# polling loop stops. Telegram's API still queues incoming updates (they sit
# in the bot's update queue until *somebody* calls getUpdates with an
# advancing offset). This script peeks each paused bot's queue from the
# outside; on any pending update it calls wake-agent.sh, which respawns
# claude+bun. The freshly started bun then calls getUpdates with its own
# offset and drains the queue — we never ACK from here, so no race.
#
# Hot path: when nothing is paused, the script exits in <100ms after the
# first dir scan finds zero paused.json files. Curl only fires for paused
# bots, and timeout=0 returns immediately.
#
# Env overrides:
#   AGENTS_ROOT  — directory to scan (default: parent of this script's agent)
#   CURL_TIMEOUT — seconds to wait for getUpdates HTTP call (default 3)
#   DRY_RUN=1    — log would-wake decisions, don't actually wake

set -uo pipefail
export PATH=$HOME/.local/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$PATH

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HUB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${AGENTS_ROOT:=$(cd "$HUB_DIR/.." && pwd)}"
: "${CURL_TIMEOUT:=3}"
LOG="$HUB_DIR/.claude/state/wake-poller.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# Fast-path: gather paused agents first; bail if none.
paused_agents=()
for dir in "$AGENTS_ROOT"/*/; do
  [ -f "$dir/.claude/state/paused.json" ] && paused_agents+=("$(basename "$dir")")
done
[ "${#paused_agents[@]}" -eq 0 ] && exit 0

for name in "${paused_agents[@]}"; do
  dir="$AGENTS_ROOT/$name"
  settings="$dir/.claude/settings.local.json"
  [ -f "$settings" ] || { log "$name: no settings.local.json, skip"; continue; }

  token=$(jq -r '.env.TELEGRAM_BOT_TOKEN // empty' "$settings" 2>/dev/null)
  [ -z "$token" ] && { log "$name: no TELEGRAM_BOT_TOKEN, skip"; continue; }

  # Peek without ACK: no offset arg, timeout=0 for immediate return.
  resp=$(curl -sS -m "$CURL_TIMEOUT" "https://api.telegram.org/bot${token}/getUpdates?limit=1&timeout=0" 2>/dev/null)
  ok=$(echo "$resp" | jq -r '.ok // false' 2>/dev/null)
  if [ "$ok" != "true" ]; then
    desc=$(echo "$resp" | jq -r '.description // "unknown"' 2>/dev/null)
    log "$name: getUpdates failed — $desc"
    continue
  fi

  count=$(echo "$resp" | jq -r '.result | length' 2>/dev/null)
  [ -z "$count" ] && count=0
  [ "$count" -eq 0 ] && continue

  update_id=$(echo "$resp" | jq -r '.result[0].update_id // "?"' 2>/dev/null)

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would wake $name (update_id=$update_id pending)"
    continue
  fi

  log "waking $name (update_id=$update_id pending)"
  if bash "$SCRIPT_DIR/wake-agent.sh" "$name" >> "$LOG" 2>&1; then
    log "  $name woken successfully"
  else
    log "  wake-agent.sh failed for $name (exit $?)"
  fi
done
