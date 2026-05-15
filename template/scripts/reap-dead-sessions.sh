#!/bin/bash
# reap-dead-sessions.sh — Reap stale Claude Code session JSONLs across the hermit fleet.
#
# A session is "dead" iff ALL three hold:
#   1. session_id != <agent>/.claude/state/session-status.json .session_id   (active)
#   2. session_id != <agent>/.claude/state/paused.json .session_id           (hibernation wake target)
#      ← critical: deleting this would brick the agent's wake-up
#   3. JSONL mtime older than --age-days (default 3, env REAP_AGE_DAYS) — buffer for manual
#      `claude --resume`. Protection check runs BEFORE mtime check, so paused/active sessions
#      are safe regardless of age.
#
# Reaped files go to the OS recycle bin so recovery is one drag away:
#   macOS: /usr/bin/trash      (preinstalled on most setups; `brew install trash` if missing)
#   Linux: gio trash           (GLib utility; usually present with any desktop)
#   neither: refuse to run     (a silent `mv` would surprise users; explicit failure is safer)
#
# Companion subdir at <proj>/<sid>/ (Claude writes both with the same UUID) is reaped together.
#
# Scope: only canonical per-agent project dirs derived from AGENTS_ROOT (matches the
# hibernate-agent / multi-agent-status-report convention). Nested project dirs created
# by running `claude` inside an agent's subdirectory have no session-status.json mapping
# and are skipped — handle those manually.
#
# Designed to run as a daily LaunchAgent / systemd timer on the master/coordinator
# hermit only — workers would just duplicate work scanning the same fleet.
#
# Env overrides:
#   AGENTS_ROOT     — directory to scan (default: parent of HUB_DIR)
#   REAP_AGE_DAYS   — buffer window in days (default 3)
#   DRY_RUN=1       — same as --dry-run flag
#
# Usage:
#   reap-dead-sessions.sh                # live run
#   reap-dead-sessions.sh --dry-run      # report what would be reaped, touch nothing
#   reap-dead-sessions.sh --age-days 7   # raise the buffer window

set -uo pipefail
export PATH=$HOME/.local/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$PATH

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HUB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
: "${AGENTS_ROOT:=$(cd "$HUB_DIR/.." && pwd)}"
: "${REAP_AGE_DAYS:=3}"
: "${DRY_RUN:=0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --age-days) REAP_AGE_DAYS="$2"; shift 2 ;;
    --root) AGENTS_ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \?//;$d'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

LOG="$HUB_DIR/.claude/state/reap-dead-sessions.log"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

command -v jq >/dev/null 2>&1 || { echo "error: jq missing" | tee -a "$LOG" >&2; exit 1; }

trash_backend=""
if command -v trash >/dev/null 2>&1; then
  trash_backend="trash"
elif command -v gio >/dev/null 2>&1; then
  trash_backend="gio"
else
  echo "error: no trash backend (need /usr/bin/trash on macOS or 'gio trash' on Linux)" | tee -a "$LOG" >&2
  exit 1
fi
trash_one() {
  if [ "$trash_backend" = "trash" ]; then trash "$1" 2>/dev/null
  else gio trash "$1" 2>/dev/null
  fi
}

# AGENTS_ROOT → Claude projects dir prefix (mirrors hibernate-agent.sh / multi-agent-status-report.sh).
agents_root_enc=$(echo "$AGENTS_ROOT" | sed 's|/|-|g')

now=$(date +%s)
threshold=$(( REAP_AGE_DAYS * 86400 ))

reap_count=0
keep_active=0
keep_paused=0
keep_fresh=0
total_bytes=0
per_agent_summary=()

human_bytes() {
  local b=$1
  if [ "$b" -lt 1024 ]; then echo "${b}B"
  elif [ "$b" -lt 1048576 ]; then awk "BEGIN{printf \"%.1fK\", $b/1024}"
  elif [ "$b" -lt 1073741824 ]; then awk "BEGIN{printf \"%.1fM\", $b/1048576}"
  else awk "BEGIN{printf \"%.2fG\", $b/1073741824}"
  fi
}

# Cross-platform stat shims (BSD on macOS, GNU on Linux).
mtime_of() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
size_of()  { stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0; }

for agent_dir in "$AGENTS_ROOT"/*/; do
  name=$(basename "$agent_dir")
  [ ! -f "$agent_dir/CLAUDE.md" ] && continue

  proj_dir="$HOME/.claude/projects/${agents_root_enc}-${name}"
  [ -d "$proj_dir" ] || continue

  protected=()
  ss_file="$agent_dir/.claude/state/session-status.json"
  active_sid=""
  if [ -f "$ss_file" ]; then
    active_sid=$(jq -r '.session_id // empty' "$ss_file" 2>/dev/null || true)
    [ -n "$active_sid" ] && protected+=("$active_sid")
  fi
  paused_file="$agent_dir/.claude/state/paused.json"
  paused_sid=""
  if [ -f "$paused_file" ]; then
    paused_sid=$(jq -r '.session_id // empty' "$paused_file" 2>/dev/null || true)
    [ -n "$paused_sid" ] && protected+=("$paused_sid")
  fi

  # Refuse to reap an agent that has neither active nor paused session id —
  # missing state means we can't tell what's safe to drop.
  if [ ${#protected[@]} -eq 0 ]; then
    printf '  skip %-22s no session-status.json / paused.json — refusing to reap\n' "$name"
    log "skip $name: no protected session ids"
    continue
  fi

  agent_reaped=0
  agent_bytes=0

  for jsonl in "$proj_dir"/*.jsonl; do
    [ -f "$jsonl" ] || continue
    sid=$(basename "$jsonl" .jsonl)

    is_protected=0
    for p in "${protected[@]}"; do
      if [ "$sid" = "$p" ]; then is_protected=1; break; fi
    done
    if [ "$is_protected" -eq 1 ]; then
      if [ "$sid" = "$active_sid" ]; then keep_active=$((keep_active + 1))
      else keep_paused=$((keep_paused + 1))
      fi
      continue
    fi

    mtime=$(mtime_of "$jsonl")
    age=$(( now - mtime ))
    if [ "$age" -lt "$threshold" ]; then
      keep_fresh=$((keep_fresh + 1))
      continue
    fi

    sub_dir="$proj_dir/$sid"
    bytes=$(size_of "$jsonl")
    if [ -d "$sub_dir" ]; then
      sub_bytes=$(du -sk "$sub_dir" 2>/dev/null | awk '{print $1*1024}')
      bytes=$(( bytes + ${sub_bytes:-0} ))
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      printf '  DRY %-22s %s  age=%-3dd  size=%s\n' "$name" "${sid:0:8}" $((age / 86400)) "$(human_bytes "$bytes")"
    else
      trash_one "$jsonl" || { echo "  warn: trash failed for $jsonl" | tee -a "$LOG" >&2; continue; }
      [ -d "$sub_dir" ] && trash_one "$sub_dir"
      log "reaped $name $sid (age=${age}s, ${bytes}B)"
    fi

    agent_reaped=$((agent_reaped + 1))
    agent_bytes=$(( agent_bytes + bytes ))
    reap_count=$((reap_count + 1))
    total_bytes=$(( total_bytes + bytes ))
  done

  if [ "$agent_reaped" -gt 0 ]; then
    per_agent_summary+=("$(printf '  %-22s %3d sessions  %s' "$name" "$agent_reaped" "$(human_bytes "$agent_bytes")")")
  fi
done

prefix=""
[ "$DRY_RUN" -eq 1 ] && prefix="[DRY-RUN] "

if [ "${#per_agent_summary[@]}" -gt 0 ]; then
  printf '\n%sper-agent:\n' "$prefix"
  printf '%s\n' "${per_agent_summary[@]}"
fi

printf '\n%sreaped %d  ·  freed %s  ·  kept %d active / %d paused / %d fresh (<%dd)\n' \
  "$prefix" "$reap_count" "$(human_bytes "$total_bytes")" "$keep_active" "$keep_paused" "$keep_fresh" "$REAP_AGE_DAYS"

[ "$DRY_RUN" -eq 0 ] && log "reaped=$reap_count freed=$total_bytes active_kept=$keep_active paused_kept=$keep_paused fresh_kept=$keep_fresh"
