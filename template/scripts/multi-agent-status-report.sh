#!/bin/bash
# Multi-agent + scheduled-task status digest.
#
# Scans every sibling agent directory under a configurable root (defaults to the
# parent of this agent's directory) and reports a per-agent status digest to the
# Telegram chat configured in this agent's settings.local.json. Also probes any
# LaunchAgent plists matching the `com.hermit-agent.*` label convention and
# reports their freshness (runs counter delta + last exit code).
#
# Per-agent status is derived from:
#   - agent.pid + kill -0 (alive?)
#   - .claude/state/session-status.json (running / idle / stuck)
#   - last_tool_ts / last_user_prompt_ts / last_stop_ts
#
# Task checks (auto-discovered):
#   - LaunchAgent interval task: track launchctl `runs` delta; stale if no
#     delta for > 1.5× interval; 🟥 if last exit != 0
#
# Cadence:
#   - any state change vs last_alert → push immediately
#   - any stuck agent OR any task bad → push every 10 min (STUCK_COOLDOWN)
#   - otherwise → push every 30 min (NORMAL_COOLDOWN)
#
# Designed to run as a LaunchAgent every 10 minutes. See
# com.hermit-agent.<name>.status-reporter.plist template.
#
# Env overrides:
#   AGENTS_ROOT  — directory to scan for agent folders (default: parent of this script's agent)
#   DRY_RUN=1    — print the digest instead of pushing to Telegram

set -u
export PATH=$HOME/.local/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:$PATH

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HUB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HUB_NAME="$(basename "$HUB_DIR")"
: "${AGENTS_ROOT:=$(cd "$HUB_DIR/.." && pwd)}"
ALERT_FILE="$HUB_DIR/.claude/state/multi-agent-alert.json"

STUCK_THRESHOLD_SEC=300
STUCK_COOLDOWN=600
NORMAL_COOLDOWN=1800

mkdir -p "$(dirname "$ALERT_FILE")"

token=$(jq -r '.env.TELEGRAM_BOT_TOKEN // empty' "$HUB_DIR/.claude/settings.local.json" 2>/dev/null)
chat_id=$(jq -r '.env.TELEGRAM_CHAT_ID // empty' "$HUB_DIR/.claude/settings.local.json" 2>/dev/null)
[ -z "$token" ] && exit 0
[ -z "$chat_id" ] && exit 0

now=$(date +%s)

fmt_duration() {
  local s=$1
  if [ "$s" -lt 0 ]; then echo "?"
  elif [ "$s" -lt 60 ]; then echo "${s}s"
  elif [ "$s" -lt 3600 ]; then echo "$((s/60))m"
  else echo "$((s/3600))h$(( (s%3600)/60 ))m"
  fi
}

# launchctl probes — used by the tasks section to monitor scheduled plists.
launchctl_pid() {
  launchctl list 2>/dev/null | awk -v l="$1" '$3==l {print $1; exit}'
}
launchctl_exit() {
  launchctl list 2>/dev/null | awk -v l="$1" '$3==l {print $2; exit}'
}
launchctl_runs() {
  launchctl print "gui/$(id -u)/$1" 2>/dev/null | awk -F= '/^[ \t]*runs =/ {gsub(/[^0-9]/,"",$2); print $2; exit}'
}

# tmux pane state probe — distinguishes real stuck from stale session-status.json.
# Claude Code's Stop hook can miss on abnormal turn exit (TLS / 500 / AUP /
# scheduled-task interrupt), leaving state=running forever. We double-check
# the tmux pane: "idle" = just ❯ prompt, "churning" = running an animated
# tool/thinking turn. "unknown" means don't trust either signal.
pane_state_check() {
  local session="$1"
  if ! tmux has-session -t "$session" 2>/dev/null; then
    echo "unknown"
    return
  fi
  local pane
  pane=$(tmux capture-pane -t "$session" -p 2>/dev/null)
  [ -z "$pane" ] && { echo "unknown"; return; }
  # Strip trailing blank lines before windowing. tmux capture-pane returns the
  # full pane height (50 rows for the standard restart.sh layout); a freshly
  # restarted agent with only ~10 lines of content leaves ~40 trailing blanks,
  # so plain `tail -6` scrapes only emptiness and returns "unknown" → self-heal
  # never fires and session-status stays stuck at running indefinitely.
  local trimmed
  trimmed=$(echo "$pane" | awk '{a[NR]=$0; if(NF)last=NR} END {for(i=1;i<=last;i++) print a[i]}')
  # Reject completion summaries like "✻ Brewed for 2m 11s" — they share the
  # verb prefix with the active form ("Brewing") and would false-positive as
  # churning, defeating the self-heal path. The "for [0-9]" anchor matches the
  # duration tail Claude Code prints after a turn finishes.
  if echo "$trimmed" | tail -6 | grep -E "^[[:space:]]*[✻✢][[:space:]]+(Churn|Cook|Brew|Work|Think|Compact|Running|Saut|Crunch|Actualiz|Cogit|Ponder|Simmer|Processing|Stew|Grilling|Bak|Roast|Digest)" | grep -qvE " for [0-9]+"; then
    echo "churning"
    return
  fi
  # Idle prompt within last 6 lines. Three forms:
  #   `❯ `         — empty input box
  #   `❯ Try "…"`  — Claude Code v2.x rotating placeholder suggestions
  #   `❯ <text>`   — user typed (or got pasted) something but didn't Enter —
  #                  still idle, just waiting for submit. The earlier churning
  #                  check already rules out active turns (matches verb prefix
  #                  minus " for [0-9]+" tail), so any line starting with `❯`
  #                  at this point is idle regardless of input-box contents.
  # (Past incident: 2026-05-17 master-skill held `❯ 全部 commit` after a 529
  # turn-abort; status digest fired 🟥 stuck 1h42m for a fully idle agent.)
  if echo "$trimmed" | tail -6 | grep -qE "^❯([[:space:]]*$|[[:space:]]+.+$)"; then
    echo "idle"
    return
  fi
  echo "unknown"
}

# Telegram plugin liveness check. Each agent's claude process spawns a `bun`
# child that runs the MCP Telegram server (server.ts). If that bun dies, the
# claude process stays alive but goes silent: no inbound messages reach the
# session, and reply tools fail. We detect by checking for a `bun … telegram`
# child of the agent's claude pid.
# Past incident: an agent's bun died sometime after a successful turn (no
# crash report, no system OOM signal — clean exit somehow). The user's
# subsequent message sat in Telegram's queue for hours until manual restart.
# Returns: dead | ok | unknown (no claude pid file)
plugin_check() {
  local agent=$1
  local pid_file="$AGENTS_ROOT/$agent/agent.pid"
  [ ! -f "$pid_file" ] && { echo "unknown"; return; }
  local pid
  pid=$(cat "$pid_file" 2>/dev/null)
  [ -z "$pid" ] && { echo "unknown"; return; }
  kill -0 "$pid" 2>/dev/null || { echo "unknown"; return; }
  local bun_child
  bun_child=$(ps -ef | awk -v p="$pid" '$3==p && /bun.*telegram/ {print $2}' | head -1)
  if [ -z "$bun_child" ]; then
    echo "dead"
  else
    echo "ok"
  fi
}

# /loop dynamic-mode detector. A `/loop <prompt>` running in dynamic mode ends
# each tick with a ScheduleWakeup tool call and goes idle until the wakeup
# fires (interval can be up to 3600s). During that wait:
#   - session-status state=running (the /loop is the active "turn")
#   - last_tool_ts is stale (from when the last tick ran)
#   - pane is idle (❯ prompt)
# Without this check, the existing stuck heuristic (`running + progress_since
# >= 300s`) misfires as 🟥 stuck on a perfectly healthy agent waiting between
# ticks. Past incident: agent flagged stuck 8h+ while sitting between hourly
# /loop wakeups — pane idle, JSONL full of ScheduleWakeup tool history.
# Returns: loop_pending | clean
loop_dynamic_check() {
  local agent=$1
  local proj="$HOME/.claude/projects/-Users-mac-claudeclaw-${agent}"
  [ -d "$proj" ] || { echo "clean"; return; }
  local latest
  latest=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1)
  [ -z "$latest" ] && { echo "clean"; return; }
  # ScheduleWakeup tool_use appears in the assistant entry's content array; its
  # tool_result follows a few lines later. Either appearance in the JSONL tail
  # is sufficient — between ticks there are only system + tool_result entries
  # appended after the wakeup call, all within ~30 lines.
  if tail -30 "$latest" 2>/dev/null | grep -q '"name":"ScheduleWakeup"\|"Next wakeup scheduled"'; then
    echo "loop_pending"
  else
    echo "clean"
  fi
}

# Error-marker scan in the last ~30 pane lines. Distinguishes genuine
# token-revocation (manual /login required) from transient backend 403
# (often self-recovers, or a single nudge revives the turn).
# Returns: token_invalid | 403_transient | clean
pane_error_check() {
  local session="$1"
  local pane recent
  pane=$(tmux capture-pane -t "$session" -p 2>/dev/null)
  [ -z "$pane" ] && { echo "clean"; return; }
  # Same trailing-blank trim as pane_state_check — tail -30 on a 50-line pane
  # with 40 trailing blanks would scrape mostly emptiness and miss API errors.
  recent=$(echo "$pane" | awk '{a[NR]=$0; if(NF)last=NR} END {for(i=1;i<=last;i++) print a[i]}' | tail -30)
  if echo "$recent" | grep -qE "Account is no longer a member|organization associated with this token"; then
    echo "token_invalid"
  elif echo "$recent" | grep -qE "API Error: 403|Please run /login"; then
    echo "403_transient"
  else
    echo "clean"
  fi
}

# Cooldown + retry policy for transient 403 nudge:
# - First seen: start cooldown timer; next 3 min just observe.
# - 3 min after first seen, no nudge yet: tmux send-keys "继续刚才的任务" Enter; mark count=1.
# - 5 min after nudge, still 403: escalate to 🆘 (probably not transient).
# - On clean recovery (pane churning OR pane idle w/o 403 markers): episode cleared next pass.
NUDGE_COOLDOWN_SEC=180
NUDGE_ESCALATE_SEC=300
NUDGE_TEXT="继续刚才的任务"

# Per-agent current context size.
# Source A (preferred): tmux pane scrape — Claude Code REPL renders
#   `new task? /clear to save XXX.Xk tokens` at idle, which is what the user sees.
# Source B (fallback): latest JSONL assistant entry's usage (input + cache_creation
#   + cache_read + output) — works when pane indicator is not visible (low context,
#   running, or just-rotated session).
# Returns "<numeric_tokens> <display>" on stdout, empty on no signal.
agent_ctx_size() {
  local agent=$1
  local pane_match val display numeric
  pane_match=$(tmux capture-pane -t "claude-${agent}" -p 2>/dev/null \
    | tail -3 \
    | grep -oE '[0-9]+(\.[0-9]+)?k tokens' \
    | tail -1)
  if [ -n "$pane_match" ]; then
    val=${pane_match% tokens}; val=${val%k}
    display="${val%.*}k"
    numeric=$(echo "$val * 1000 / 1" | bc 2>/dev/null)
    [ -n "$numeric" ] && echo "$numeric $display"
    return
  fi
  # Project dir name = AGENTS_ROOT path with /→- substitutions, plus -<agent>.
  # E.g. AGENTS_ROOT=/Users/mac/claudeclaw → -Users-mac-claudeclaw-<agent>.
  local agents_root_enc
  agents_root_enc=$(echo "$AGENTS_ROOT" | sed 's|/|-|g')
  local proj="$HOME/.claude/projects/${agents_root_enc}-${agent}"
  [ -d "$proj" ] || return
  local latest
  latest=$(ls -t "$proj"/*.jsonl 2>/dev/null | head -1)
  [ -z "$latest" ] && return
  local sum
  sum=$(grep '"type":"assistant"' "$latest" 2>/dev/null \
    | tail -1 \
    | jq -r '.message.usage | (.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens + .output_tokens) // 0' 2>/dev/null)
  if [ -n "$sum" ] && [ "$sum" != "null" ] && [ "$sum" -gt 0 ]; then
    if [ "$sum" -ge 1000000 ]; then
      display=$(printf '%.1fM' "$(echo "$sum/1000000" | bc -l)")
    else
      display="$((sum / 1000))k"
    fi
    echo "$sum $display"
  fi
}

lines=()
states_joined=""
any_stuck=0
any_active=0
down_list=()
ctx_entries=()

# Consecutive-stuck escalation: if an agent stays stuck across >=2 back-to-back
# digests (20+ min at the default 10-min cadence), the line promotes from
# 🟥 stuck → 🆘 CRITICAL with a restart suggestion. Count resets on any non-stuck
# outcome (idle / healed / running).
prev_stuck_counts_json="{}"
prev_nudges_json="{}"
if [ -f "$ALERT_FILE" ]; then
  prev_stuck_counts_json=$(jq -c '.stuck_counts // {}' "$ALERT_FILE" 2>/dev/null)
  [ -z "$prev_stuck_counts_json" ] && prev_stuck_counts_json="{}"
  prev_nudges_json=$(jq -c '.nudges // {}' "$ALERT_FILE" 2>/dev/null)
  [ -z "$prev_nudges_json" ] && prev_nudges_json="{}"
fi
stuck_counts_entries=()
# Per-agent 403 episode tracking. Only entries for agents currently in an
# active 403 episode get persisted — clean recovery clears the entry.
nudges_entries=()

# ---------- Agents ----------
for dir in "$AGENTS_ROOT"/*/; do
  name=$(basename "$dir")
  [ ! -f "$dir/CLAUDE.md" ] && continue

  pid_file="$dir/agent.pid"
  paused_file="$dir/.claude/state/paused.json"

  # Hibernated agents (idle-hibernator.sh wrote paused.json + removed agent.pid).
  # Distinguish from "down" so the digest doesn't false-alarm; wake-poller.sh
  # will respawn the agent on inbound Telegram.
  if [ -f "$paused_file" ]; then
    hibernated_at=$(jq -r '.hibernated_at // 0' "$paused_file" 2>/dev/null)
    [ "$hibernated_at" = "null" ] && hibernated_at=0
    if [ "$hibernated_at" -gt 0 ]; then
      dur=$(fmt_duration $((now - hibernated_at)))
      lines+=("💤 $name · hibernated $dur")
    else
      lines+=("💤 $name · hibernated")
    fi
    states_joined+="$name=paused;"
    any_active=1
    continue
  fi

  alive=0
  if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
  fi

  state_file="$dir/.claude/state/session-status.json"

  if [ "$alive" -eq 0 ]; then
    down_list+=("$name")
    states_joined+="$name=down;"
    continue
  fi

  any_active=1

  if [ ! -f "$state_file" ]; then
    lines+=("🔘 $name · no state")
    states_joined+="$name=nostate;"
    continue
  fi

  state=$(jq -r '.state // "idle"' "$state_file" 2>/dev/null)
  last_user=$(jq -r '.last_user_prompt_ts // 0' "$state_file" 2>/dev/null)
  last_tool=$(jq -r '.last_tool_ts // 0' "$state_file" 2>/dev/null)
  last_stop=$(jq -r '.last_stop_ts // 0' "$state_file" 2>/dev/null)

  if [ "$state" = "running" ]; then
    progress_since=$(( now - (last_tool > last_user ? last_tool : last_user) ))
    if [ "$progress_since" -ge "$STUCK_THRESHOLD_SEC" ]; then
      computed=stuck
    else
      computed=running
    fi
  else
    computed=idle
  fi

  # /loop dynamic-mode short-circuit. If the agent is between scheduled wakeups
  # of a long-running /loop, state=running is correct and last_tool age is
  # expected to be large. Detect this BEFORE the pane / 403 paths so we don't
  # false-flag, self-heal-reset, or otherwise disrupt a healthy /loop agent.
  if [ "$computed" = "stuck" ]; then
    loop_state=$(loop_dynamic_check "$name")
    if [ "$loop_state" = "loop_pending" ]; then
      computed=loop_pending
    fi
  fi

  # Self-heal + 403/token-invalid handling.
  # - state=running stuck + pane idle: Stop hook likely missed (TLS/500/AUP abort)
  #   OR an API 403 aborted the turn. Distinguish via pane_error_check:
  #     • token_invalid: hardcoded fail markers ("Account is no longer a member" /
  #       "organization associated with this token") → 🆘, do not nudge.
  #     • 403_transient: "API Error: 403" without the fail markers → cooldown +
  #       single nudge attempt → escalate to 🆘 if no recovery.
  #     • clean: vanilla Stop-hook-missed → reset state to idle.
  nudge_pending_age=0
  cooldown_remaining=0
  if [ "$computed" = "stuck" ]; then
    pane_state=$(pane_state_check "claude-$name")
    if [ "$pane_state" = "idle" ]; then
      err_state=$(pane_error_check "claude-$name")

      prev_first_seen=$(echo "$prev_nudges_json" | jq -r --arg k "$name" '.[$k].first_seen // 0')
      prev_last_retry=$(echo "$prev_nudges_json" | jq -r --arg k "$name" '.[$k].last_retry // 0')
      prev_count=$(echo "$prev_nudges_json" | jq -r --arg k "$name" '.[$k].count // 0')
      [ "$prev_first_seen" = "null" ] && prev_first_seen=0
      [ "$prev_last_retry" = "null" ] && prev_last_retry=0
      [ "$prev_count" = "null" ] && prev_count=0

      case "$err_state" in
        token_invalid)
          computed=token_invalid
          [ "$prev_first_seen" -eq 0 ] && prev_first_seen=$now
          nudges_entries+=("\"$name\":{\"first_seen\":$prev_first_seen,\"last_retry\":$prev_last_retry,\"count\":$prev_count,\"kind\":\"token_invalid\"}")
          ;;
        403_transient)
          [ "$prev_first_seen" -eq 0 ] && prev_first_seen=$now
          seen_age=$(( now - prev_first_seen ))
          retry_age=$(( now - prev_last_retry ))

          if [ "$prev_count" -ge 1 ] && [ "$retry_age" -ge "$NUDGE_ESCALATE_SEC" ]; then
            computed=403_escalated
          elif [ "$prev_count" -ge 1 ]; then
            computed=403_nudged_pending
            nudge_pending_age=$retry_age
          elif [ "$seen_age" -ge "$NUDGE_COOLDOWN_SEC" ]; then
            if [ "${DRY_RUN:-0}" != "1" ]; then
              tmux send-keys -t "claude-$name" "$NUDGE_TEXT" Enter 2>/dev/null
            fi
            prev_last_retry=$now
            prev_count=1
            computed=403_nudged
          else
            computed=403_pending
            cooldown_remaining=$(( NUDGE_COOLDOWN_SEC - seen_age ))
          fi
          nudges_entries+=("\"$name\":{\"first_seen\":$prev_first_seen,\"last_retry\":$prev_last_retry,\"count\":$prev_count,\"kind\":\"403_transient\"}")
          ;;
        clean)
          tmp_state=$(mktemp)
          jq --argjson ts "$now" '.state="idle" | .last_stop_ts=$ts' "$state_file" > "$tmp_state" 2>/dev/null \
            && mv "$tmp_state" "$state_file"
          computed=idle
          last_stop=$now
          states_joined+="healed_${name};"
          ;;
      esac
    fi
  fi

  # Escalation counter: increment when stuck, reset otherwise.
  prev_stuck=$(echo "$prev_stuck_counts_json" | jq -r --arg k "$name" '.[$k] // 0')
  [ "$prev_stuck" = "null" ] && prev_stuck=0
  if [ "$computed" = "stuck" ]; then
    stuck_count=$((prev_stuck + 1))
  else
    stuck_count=0
  fi
  stuck_counts_entries+=("\"$name\":$stuck_count")

  case "$computed" in
    idle)
      if [ "$last_stop" -gt 0 ]; then
        dur=$(fmt_duration $((now - last_stop)))
        lines+=("🟢 $name · idle $dur")
      else
        lines+=("🟢 $name · idle")
      fi
      ;;
    running)
      if [ "$last_tool" -ge "$last_user" ]; then
        dur=$(fmt_duration $((now - last_tool)))
      else
        dur=$(fmt_duration $((now - last_user)))
      fi
      lines+=("🟨 $name · running $dur")
      ;;
    stuck)
      tool_dur=$(fmt_duration $((now - last_tool)))
      if [ "$stuck_count" -ge 2 ]; then
        lines+=("🆘 $name · CRITICAL stuck $tool_dur (${stuck_count}× · consider restart)")
      else
        lines+=("🟥 $name · stuck $tool_dur")
      fi
      any_stuck=1
      ;;
    token_invalid)
      lines+=("🆘 $name · TOKEN INVALID — manual /login required")
      any_stuck=1
      ;;
    403_pending)
      lines+=("🟨 $name · 403 detected (cooldown ${cooldown_remaining}s)")
      ;;
    403_nudged)
      lines+=("🟧 $name · auto-nudged after 403")
      ;;
    403_nudged_pending)
      dur=$(fmt_duration $nudge_pending_age)
      lines+=("🟧 $name · awaiting nudge effect ($dur since nudge)")
      ;;
    403_escalated)
      lines+=("🆘 $name · 403 persists after nudge — manual investigation")
      any_stuck=1
      ;;
    loop_pending)
      tick_age=$(fmt_duration $((now - last_tool)))
      lines+=("🟡 $name · /loop waiting (last tick ${tick_age} ago)")
      ;;
  esac

  states_joined+="$name=$computed;"

  # Telegram plugin liveness — silent failure mode if bun dies, claude stays
  # alive but agent goes deaf. Mark the line + force any_stuck so cooldown
  # tightens to 10-min cadence; user must restart agent manually (auto-restart
  # would lose mid-turn state).
  plugin_state=$(plugin_check "$name")
  if [ "$plugin_state" = "dead" ]; then
    last_idx=$(( ${#lines[@]} - 1 ))
    lines[$last_idx]+=" · 🆘 TG plugin dead (restart needed)"
    states_joined+="${name}_plugin=dead;"
    any_stuck=1
  fi

  # Capture current context size for this agent (alive only — down agents have
  # no live REPL to scrape and a stale JSONL would mislead).
  ctx_data=$(agent_ctx_size "$name")
  [ -n "$ctx_data" ] && ctx_entries+=("$ctx_data $name")
done

if [ ${#down_list[@]} -gt 0 ]; then
  IFS=','
  lines+=("⚫ ${down_list[*]} · down")
  unset IFS
fi

# ---------- Tasks ----------
# Auto-discover all `com.hermit-agent.*.plist` LaunchAgents and probe their
# freshness via launchctl `runs` delta + last exit code. Users who add cron
# plists under the conventional naming get monitored automatically; nothing
# in here is hub-specific.
task_lines=()
any_task_bad=0
task_runs_entries=()
task_ts_entries=()

prev_runs_json="{}"
prev_ts_json="{}"
if [ -f "$ALERT_FILE" ]; then
  prev_runs_json=$(jq -c '.task_runs // {}' "$ALERT_FILE" 2>/dev/null)
  prev_ts_json=$(jq -c '.task_runs_ts // {}' "$ALERT_FILE" 2>/dev/null)
  [ -z "$prev_runs_json" ] && prev_runs_json="{}"
  [ -z "$prev_ts_json" ] && prev_ts_json="{}"
fi

check_daemon() {
  local label=$1 display=$2
  local pid
  pid=$(launchctl_pid "$label")
  if [ -n "$pid" ] && [ "$pid" != "-" ]; then
    task_lines+=("🟢 $display · up")
    states_joined+="tk_${display}=up;"
  else
    task_lines+=("🟥 $display · down")
    states_joined+="tk_${display}=down;"
    any_task_bad=1
  fi
}

check_interval_agent() {
  local label=$1 display=$2 interval_sec=$3 log_path="${4:-}"
  local runs exit_code
  runs=$(launchctl_runs "$label")
  exit_code=$(launchctl_exit "$label")
  [ -z "$runs" ] && runs=0
  [ -z "$exit_code" ] && exit_code=0

  local prev_runs prev_ts
  prev_runs=$(echo "$prev_runs_json" | jq -r --arg k "$label" '.[$k] // 0')
  prev_ts=$(echo "$prev_ts_json" | jq -r --arg k "$label" '.[$k] // 0')
  [ "$prev_runs" = "null" ] && prev_runs=0
  [ "$prev_ts" = "null" ] && prev_ts=0

  # launchctl's `runs` counter resets to 0 on every load (reboot, plist edit,
  # bootstrap). For tasks that have a log file, fall back to log mtime so a
  # task that ran fine pre-reboot doesn't suddenly read "never ran".
  local current_ts
  if [ "$runs" -gt "$prev_runs" ] || [ "$prev_ts" -eq 0 ]; then
    current_ts=$now
  else
    current_ts=$prev_ts
  fi
  local effective_runs=$runs
  if [ "$runs" -eq 0 ] && [ -n "$log_path" ] && [ -f "$log_path" ]; then
    local log_mtime
    log_mtime=$(stat -f %m "$log_path" 2>/dev/null || stat -c %Y "$log_path" 2>/dev/null)
    if [ -n "$log_mtime" ] && [ "$log_mtime" -gt 0 ]; then
      current_ts=$log_mtime
      effective_runs=1
    fi
  fi

  task_runs_entries+=("\"$label\":$runs")
  task_ts_entries+=("\"$label\":$current_ts")

  local stale_threshold=$((interval_sec * 3 / 2))
  local age=$((now - current_ts))

  if [ "$exit_code" != "0" ]; then
    task_lines+=("🟥 $display · last exit $exit_code")
    states_joined+="tk_${display}=err${exit_code};"
    any_task_bad=1
  elif [ "$effective_runs" -eq 0 ]; then
    task_lines+=("🟨 $display · never ran")
    states_joined+="tk_${display}=never;"
    any_task_bad=1
  elif [ "$age" -gt "$stale_threshold" ]; then
    task_lines+=("🟨 $display · stale $(fmt_duration $age)")
    states_joined+="tk_${display}=stale;"
    any_task_bad=1
  else
    task_lines+=("🟢 $display · ran $(fmt_duration $age) ago")
    states_joined+="tk_${display}=ok;"
  fi
}

# Calendar-based task check (e.g. daily reaper). launchctl runs counter doesn't
# carry meaningful timing for these — use log mtime directly.
check_cron_mtime() {
  local display=$1 log_path=$2 interval_sec=$3
  if [ ! -f "$log_path" ]; then
    task_lines+=("🟨 $display · never ran")
    states_joined+="tk_${display}=never;"
    any_task_bad=1
    return
  fi
  local mtime age stale_threshold
  mtime=$(stat -f %m "$log_path" 2>/dev/null || stat -c %Y "$log_path" 2>/dev/null)
  age=$((now - mtime))
  stale_threshold=$((interval_sec * 3 / 2))
  if [ "$age" -gt "$stale_threshold" ]; then
    task_lines+=("🟨 $display · stale $(fmt_duration $age)")
    states_joined+="tk_${display}=stale;"
    any_task_bad=1
  else
    task_lines+=("🟢 $display · ran $(fmt_duration $age) ago")
    states_joined+="tk_${display}=ok;"
  fi
}

# Auto-discover hermit-agent LaunchAgent plists. Convention:
#   com.hermit-agent.<agent>.<task>.plist
# Display name drops the `com.hermit-agent.` prefix so it reads "<agent>.<task>".
# Skips:
#   - plists without StartInterval (calendar-based tasks like reap-dead-sessions
#     are checked separately via check_cron_mtime below)
#   - this agent's own status-reporter (it always reads "ran 0s ago" — by definition,
#     if you're reading this digest, the reporter just fired)
SELF_STATUS_REPORTER_LABEL="com.hermit-agent.${HUB_NAME}.status-reporter"
for plist in "$HOME"/Library/LaunchAgents/com.hermit-agent.*.plist; do
  [ -f "$plist" ] || continue
  label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$plist" 2>/dev/null)
  interval=$(/usr/libexec/PlistBuddy -c "Print :StartInterval" "$plist" 2>/dev/null)
  [ -z "$label" ] && continue
  [ -z "$interval" ] && continue
  [ "$label" = "$SELF_STATUS_REPORTER_LABEL" ] && continue
  display="${label#com.hermit-agent.}"
  # Convention: <agent>/.claude/state/<task>.log lets us recover from launchctl
  # runs counter resets (reboot etc.) by reading log mtime as fallback.
  agent_part="${label#com.hermit-agent.}"
  agent_name="${agent_part%%.*}"
  task_name="${agent_part#*.}"
  log_path="$AGENTS_ROOT/$agent_name/.claude/state/${task_name}.log"
  check_interval_agent "$label" "$display" "$interval" "$log_path"
done

# Calendar-based tasks (no StartInterval, so the auto-discover loop skips them).
# reap-dead-sessions fires daily at 04:10 — tolerance 36h (1.5× day) before stale.
SELF_REAPER_PLIST="$HOME/Library/LaunchAgents/com.hermit-agent.${HUB_NAME}.reap-dead-sessions.plist"
if [ -f "$SELF_REAPER_PLIST" ]; then
  reaper_log="$HUB_DIR/.claude/state/reap-dead-sessions.log"
  check_cron_mtime reap-dead-sessions "$reaper_log" 86400
fi

# Chrome CDP port collision check — two sibling agents claiming the same port
# means one of them is talking to the wrong Chrome (one IPv4, one fell back to
# IPv6 via Chrome's silent dual-stack rebind). Scan all sibling chrome.json
# files; flag any port claimed by 2+ live agents. Defense in depth on top of
# the deterministic-port + force-IPv4 fixes in chrome-launcher.sh.
declare -A cdp_port_owners=()
cdp_collisions=()
for cj in "$AGENTS_ROOT"/*/browser/chrome.json; do
  [ -f "$cj" ] || continue
  agent_name=$(basename "$(dirname "$(dirname "$cj")")")
  cport=$(jq -r '.cdp_port // empty' "$cj" 2>/dev/null)
  cpid=$(jq -r '.pid // empty' "$cj" 2>/dev/null)
  [ -z "$cport" ] && continue
  [ -z "$cpid" ] || [ "$cpid" = "null" ] && continue
  kill -0 "$cpid" 2>/dev/null || continue
  if [ -n "${cdp_port_owners[$cport]:-}" ]; then
    cdp_collisions+=("port $cport: ${cdp_port_owners[$cport]} ↔ $agent_name")
    cdp_port_owners[$cport]="${cdp_port_owners[$cport]},$agent_name"
  else
    cdp_port_owners[$cport]="$agent_name"
  fi
done
for collision in "${cdp_collisions[@]:-}"; do
  [ -z "$collision" ] && continue
  task_lines+=("🟥 chrome-cdp · collision · $collision")
  states_joined+="tk_chrome_cdp=collision_${collision// /_};"
  any_task_bad=1
done

# ---------- Exit if nothing to say ----------
[ "$any_active" -eq 0 ] && [ ${#down_list[@]} -eq 0 ] && [ "$any_task_bad" -eq 0 ] && exit 0

# ---------- Cooldown + change detection ----------
last_alert_ts=0
last_states=""
if [ -f "$ALERT_FILE" ]; then
  last_alert_ts=$(jq -r '.last_alert_ts // 0' "$ALERT_FILE" 2>/dev/null)
  last_states=$(jq -r '.last_states // ""' "$ALERT_FILE" 2>/dev/null)
fi

if [ "$any_stuck" -eq 1 ] || [ "$any_task_bad" -eq 1 ]; then
  cooldown=$STUCK_COOLDOWN
else
  cooldown=$NORMAL_COOLDOWN
fi

should_alert=0
[ "$last_alert_ts" -eq 0 ] && should_alert=1
[ "$last_states" != "$states_joined" ] && should_alert=1
[ $((now - last_alert_ts)) -ge "$cooldown" ] && should_alert=1

if [ "$should_alert" -eq 0 ]; then
  # Still persist task counters + escalation state so we don't lose tracking
  # between alert windows. `${arr[*]:-}` is required because `set -u` errors on
  # empty-array deref; these arrays are empty when nothing of that kind exists.
  task_runs_json="{$(IFS=,; echo "${task_runs_entries[*]:-}")}"
  task_ts_json="{$(IFS=,; echo "${task_ts_entries[*]:-}")}"
  stuck_counts_json="{$(IFS=,; echo "${stuck_counts_entries[*]:-}")}"
  nudges_json="{$(IFS=,; echo "${nudges_entries[*]:-}")}"
  jq -n \
    --argjson ts "$last_alert_ts" \
    --arg s "$last_states" \
    --argjson runs "$task_runs_json" \
    --argjson runs_ts "$task_ts_json" \
    --argjson stuck "$stuck_counts_json" \
    --argjson nudges "$nudges_json" \
    '{last_alert_ts:$ts, last_states:$s, task_runs:$runs, task_runs_ts:$runs_ts, stuck_counts:$stuck, nudges:$nudges}' \
    > "$ALERT_FILE"
  exit 0
fi

# ---------- Compose message ----------
msg="📡 agents"$'\n'
for line in "${lines[@]}"; do
  msg+="$line"$'\n'
done

if [ ${#task_lines[@]} -gt 0 ]; then
  msg+=$'\n'"⏱ tasks"$'\n'
  for line in "${task_lines[@]}"; do
    msg+="$line"$'\n'
  done
fi

# Per-agent current context — sorted desc, 🟧 marker at >=500k (auto-compact zone
# for 1M models is around 800k+, but >=500k = "consider /clear soon").
if [ ${#ctx_entries[@]} -gt 0 ]; then
  ctx_line=""
  while read -r num display agent; do
    [ -z "$num" ] && continue
    marker=""
    [ "$num" -ge 500000 ] && marker="🟧 "
    [ -n "$ctx_line" ] && ctx_line+=" · "
    ctx_line+="${marker}${agent} ${display}"
  done <<< "$(printf '%s\n' "${ctx_entries[@]}" | sort -rn -k1)"
  if [ -n "$ctx_line" ]; then
    msg+=$'\n'"📚 context"$'\n'"$ctx_line"$'\n'
  fi
fi

# ---------- Claude Code usage section ----------
# Three data sources: (1) live 5h+weekly quota via /status panel scraped from a
# throwaway probe REPL — see scripts/claude-quota-probe.sh for the why; (2)
# active 5h block burn rate + projection from ccusage blocks; (3) today's
# per-agent cost+tokens from ccusage daily. Each source fails independently;
# missing data is silently dropped from the section. Requires `npx` and the
# ccusage npm package (auto-fetched by npx); skipped silently if npx is
# unavailable.
fmt_tokens() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    printf '%.1fM' "$(echo "$n / 1000000" | bc -l)"
  elif [ "$n" -ge 1000 ]; then
    printf '%dk' "$((n / 1000))"
  else
    echo "$n"
  fi
}
fmt_cost() {
  printf '$%d' "$(printf '%.0f' "$1")"
}

usage_lines=()

# Quota probe (best-effort).
if [ -x "$SCRIPT_DIR/claude-quota-probe.sh" ]; then
  probe_out=$("$SCRIPT_DIR/claude-quota-probe.sh" 2>/dev/null)
  if [ -n "$probe_out" ] && grep -q "PROBE_OK=1" <<< "$probe_out"; then
    eval "$probe_out"
    reset5_short=$(echo "$QUOTA_5H_RESET" | sed 's/ (.*//')
    resetw_short=$(echo "$QUOTA_WEEKLY_RESET" | sed 's/ (.*//; s/ at .*//')
    usage_lines+=("5h: ${QUOTA_5H_PCT}% (resets $reset5_short)")
    usage_lines+=("week: ${QUOTA_WEEKLY_PCT}% (resets $resetw_short)")
  fi
fi

# Active 5h block burn / projection. Skip if npx missing.
if command -v npx >/dev/null 2>&1; then
  blocks_json=$(npx -y ccusage@latest blocks --json --active 2>/dev/null)
  if [ -n "$blocks_json" ]; then
    block_cost=$(echo "$blocks_json" | jq -r '.blocks[0].costUSD // empty' 2>/dev/null)
    burn_per_h=$(echo "$blocks_json" | jq -r '.blocks[0].burnRate.costPerHour // empty' 2>/dev/null)
    proj_cost=$(echo "$blocks_json" | jq -r '.blocks[0].projection.totalCost // empty' 2>/dev/null)
    rem_min=$(echo "$blocks_json" | jq -r '.blocks[0].projection.remainingMinutes // empty' 2>/dev/null)
    if [ -n "$block_cost" ]; then
      line="block: $(fmt_cost "$block_cost")"
      [ -n "$burn_per_h" ] && line+=" · burn $(fmt_cost "$burn_per_h")/h"
      [ -n "$proj_cost" ] && line+=" · proj $(fmt_cost "$proj_cost")"
      if [ -n "$rem_min" ]; then
        h=$((rem_min / 60))
        m=$((rem_min % 60))
        [ "$h" -gt 0 ] && line+=" (${h}h${m}m left)" || line+=" (${m}m left)"
      fi
      usage_lines+=("$line")
    fi
  fi

  # Today's per-agent breakdown.
  daily_json=$(npx -y ccusage@latest daily --json --since "$(date +%Y%m%d)" -i 2>/dev/null)
  if [ -n "$daily_json" ]; then
    total_cost=$(echo "$daily_json" | jq -r '(try .totals.totalCost catch 0) // 0' 2>/dev/null || echo 0)
    total_tok=$(echo "$daily_json" | jq -r '(try .totals.totalTokens catch 0) // 0' 2>/dev/null || echo 0)
    if [ -n "$total_cost" ] && [ "$total_cost" != "0" ]; then
      usage_lines+=("today: $(fmt_cost "$total_cost") / $(fmt_tokens "$total_tok") tok")
      # Top 3 spenders today.
      top=$(echo "$daily_json" | jq -r '
        .projects | to_entries
        | map({name: .key, cost: ([.value[] | .totalCost] | add // 0)})
        | sort_by(-.cost)
        | .[0:3]
        | .[] | "\(.cost) \(.name)"
      ' 2>/dev/null)
      if [ -n "$top" ]; then
        top_line=""
        # Strip the encoded user/home prefix so the project shows as just its
        # leaf name. Prefix encoding is /a/b/c → -a-b-c, so the last segment
        # after the final '-' is usually meaningful.
        agents_root_enc=$(echo "$AGENTS_ROOT" | sed 's|/|-|g')
        while IFS=' ' read -r c name; do
          [ -z "$c" ] && continue
          short=$(echo "$name" | sed -E "s|^${agents_root_enc}-||; s|^-Users-[^-]+-||; s|^-home-[^-]+-||; s|-$||")
          if [ ${#short} -gt 18 ]; then
            short="${short:0:17}…"
          fi
          [ -n "$top_line" ] && top_line+=" · "
          top_line+="$short $(fmt_cost "$c")"
        done <<< "$top"
        [ -n "$top_line" ] && usage_lines+=("$top_line")
      fi
    fi
  fi
fi

if [ ${#usage_lines[@]} -gt 0 ]; then
  msg+=$'\n'"💰 claude code"$'\n'
  for line in "${usage_lines[@]}"; do
    msg+="$line"$'\n'
  done
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "=== DRY-RUN: would POST to Telegram ==="
  echo "$msg"
  echo "=== END DRY-RUN ==="
else
  curl -sS -m 10 -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d "chat_id=${chat_id}" \
    --data-urlencode "text=${msg}" >/dev/null 2>&1
fi

task_runs_json="{$(IFS=,; echo "${task_runs_entries[*]:-}")}"
task_ts_json="{$(IFS=,; echo "${task_ts_entries[*]:-}")}"
stuck_counts_json="{$(IFS=,; echo "${stuck_counts_entries[*]:-}")}"
nudges_json="{$(IFS=,; echo "${nudges_entries[*]:-}")}"
jq -n \
  --argjson ts "$now" \
  --arg s "$states_joined" \
  --argjson runs "$task_runs_json" \
  --argjson runs_ts "$task_ts_json" \
  --argjson stuck "$stuck_counts_json" \
  --argjson nudges "$nudges_json" \
  '{last_alert_ts:$ts, last_states:$s, task_runs:$runs, task_runs_ts:$runs_ts, stuck_counts:$stuck, nudges:$nudges}' \
  > "$ALERT_FILE"

exit 0
