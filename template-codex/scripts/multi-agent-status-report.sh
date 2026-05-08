#!/bin/bash
# multi-agent-status-report.sh — single-agent stub for codex hermit.
#
# This is a minimal port of asst's multi-agent monitor. For a single demo
# agent it prints daemon health, thread state, and recent token cost. The
# loop is structured so adding more agents later is mechanical: list them
# in AGENTS array, point AGENTS_ROOT at the parent dir, run.
#
# Output goes to stdout. Wire to launchd / cron later if you want periodic
# digests pushed to Telegram.

set -euo pipefail

AGENTS_ROOT="${AGENTS_ROOT:-/Users/mac/claudeclaw}"
AGENTS=( "${@:-codex-demo}" )

emoji_for_state() {
    case "$1" in
        ok)        echo "✅" ;;
        idle)      echo "💤" ;;
        wedged)    echo "🆘" ;;
        no-thread) echo "🆕" ;;
        *)         echo "❓" ;;
    esac
}

agent_state() {
    local agent="$1"
    local dir="$AGENTS_ROOT/$agent"
    [ -d "$dir" ] || { echo "missing"; return; }
    if ! tmux has-session -t "$agent" 2>/dev/null; then
        echo "wedged"
        return
    fi
    if [ ! -s "$dir/state/thread.txt" ]; then
        echo "no-thread"
        return
    fi
    # If daemon process is still alive AND we've had a turn in the last hour,
    # call it ok; if daemon is alive but no recent turn, idle.
    local pids
    pids=$(pgrep -f "$dir/scripts/tg-bridge.py" 2>/dev/null || true)
    [ -z "$pids" ] && { echo "wedged"; return; }
    # Daily log file mtime as proxy for last activity.
    local log="$dir/memory/$(date +%Y-%m-%d).md"
    if [ -f "$log" ]; then
        local age
        age=$(( $(date +%s) - $(stat -f %m "$log") ))
        if [ "$age" -lt 3600 ]; then
            echo "ok"
            return
        fi
    fi
    echo "idle"
}

echo "📡 codex hermit status — $(date '+%Y-%m-%d %H:%M:%S')"
echo

for agent in "${AGENTS[@]}"; do
    state=$(agent_state "$agent")
    em=$(emoji_for_state "$state")
    dir="$AGENTS_ROOT/$agent"
    thread=$(cat "$dir/state/thread.txt" 2>/dev/null | head -c 8 || echo "—")
    log="$dir/memory/$(date +%Y-%m-%d).md"
    log_size=$( [ -f "$log" ] && stat -f %z "$log" || echo 0 )
    pid=$(pgrep -f "$dir/scripts/tg-bridge.py" 2>/dev/null | head -1 || echo "—")
    printf "%s %-20s state=%-10s pid=%-6s thread=%s log=%dB\n" \
        "$em" "$agent" "$state" "$pid" "$thread" "$log_size"
done

# Token cost — best effort via ccusage (works for codex too if installed).
if command -v ccusage >/dev/null 2>&1; then
    echo
    echo "💰 cost (today, codex):"
    ccusage daily --since "$(date +%Y%m%d)" 2>/dev/null | tail -5 || true
fi
