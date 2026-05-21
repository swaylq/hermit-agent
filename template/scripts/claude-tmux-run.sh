#!/bin/bash
# claude-tmux-run.sh — Run a prompt through an ephemeral interactive `claude`
# session inside a throwaway tmux. Stays in the Claude Max INTERACTIVE billing
# bucket (separate from the Agent SDK bucket that `claude -p` draws against
# starting 2026-06-15; that bucket is much smaller and charges full API rates
# on overage).
#
# Usage:
#   ./scripts/claude-tmux-run.sh <prompt-file> [timeout-sec=1200] [grace-boot=8]
#
# Exit codes:
#   0   — turn completed; pane scroll-back printed to stdout
#   1   — invocation error / claude failed to reach idle prompt / tmux missing
#   124 — turn exceeded timeout, session was killed (matches GNU `timeout`)
#
# Design notes:
# - Spawns a unique tmux session per invocation, kills it on exit (trap), so
#   parallel cron tasks don't collide. Pane size is 200x50 to match the rest
#   of the hermit-agent runtime; if you change it elsewhere keep it consistent.
# - Boot grace (default 8s) waits for the claude REPL to render its banner and
#   land on the idle `❯` prompt before we paste the prompt in. Tighter than
#   this and we get a race where send-keys arrives at the shell, not claude.
# - Completion is detected by polling the pane: require N consecutive samples
#   where the bottom shows the idle `❯` prompt and no spinner verb (`✻ Brewing`,
#   `✢ Thinking`, etc.) is active. The "for <duration>" tail distinguishes
#   *completed* spinners ("✻ Brewed for 38s") from active ones — a completed
#   spinner is left over from the just-finished turn and means we're idle, not
#   still working.
# - Trailing blank rows in the pane are stripped before windowing, so a short-
#   content pane doesn't fool the bottom-line check (same bug fixed in
#   pane_state_check at hermit-agent v0.1.55).
# - This script does NOT pass `--channels` to claude, so no MCP plugins load.
#   That keeps startup fast (~8s instead of 15-20s) and avoids accidentally
#   sending Telegram from a cron context. If a cron needs to report back via
#   Telegram, use Bot API curl in the prompt (see AGENTS.md Cron Safety).

set -uo pipefail

PROMPT_FILE="${1:-}"
TIMEOUT_S="${2:-1200}"
GRACE_BOOT="${3:-8}"
POLL_INTERVAL=3
DONE_GRACE=4

if [ -z "$PROMPT_FILE" ] || [ ! -f "$PROMPT_FILE" ]; then
  echo "Usage: $0 <prompt-file> [timeout-sec=1200] [grace-boot=8]" >&2
  exit 1
fi

command -v tmux   >/dev/null || { echo "tmux not found in PATH" >&2; exit 1; }
command -v claude >/dev/null || { echo "claude not found in PATH" >&2; exit 1; }

# tmux uses session:window:pane syntax so dots and colons in the session name
# confuse the target resolver ("can't find window: ..."). Sanitize to [A-Za-z0-9_-]
# only — keep enough of the prompt filename to be useful in `tmux ls` output.
PROMPT_SLUG=$(basename "$PROMPT_FILE" .md | tr -c 'A-Za-z0-9_-' '_' | cut -c1-40)
SESSION="claude-cron-${PROMPT_SLUG}-$$"

cleanup() { tmux kill-session -t "=$SESSION" 2>/dev/null || true; }
trap cleanup EXIT

# Boot ephemeral claude
tmux new-session -d -s "$SESSION" -x 200 -y 50 "claude --dangerously-skip-permissions"
sleep "$GRACE_BOOT"

# Confirm claude reached the idle prompt — without this, send-keys could land
# in a partially-initialized REPL and get eaten.
if ! tmux capture-pane -t "$SESSION" -p \
     | awk '{a[NR]=$0; if(NF)last=NR} END {for(i=1;i<=last;i++) print a[i]}' \
     | tail -6 \
     | grep -qE "^❯([[:space:]]*$|[[:space:]]+.+$)"; then
  echo "claude did not reach idle prompt within ${GRACE_BOOT}s; aborting" >&2
  tmux capture-pane -t "$SESSION" -p >&2
  exit 1
fi

# Paste prompt and submit. load-buffer reads the file verbatim; paste-buffer
# with `-p` emits bracketed-paste sequences so a multi-line prompt arrives as
# ONE input (intermediate newlines stay as in-buffer line breaks, not Enter
# presses that would submit halves of the prompt). Trailing send-keys Enter
# is what actually fires the turn.
tmux load-buffer "$PROMPT_FILE"
tmux paste-buffer -p -t "$SESSION"
sleep 0.5
tmux send-keys -t "$SESSION" Enter

# Poll for completion
START_TS=$(date +%s)
idle_streak=0
spinner_re='^[[:space:]]*[✻✢][[:space:]]+(Churn|Cook|Brew|Work|Think|Compact|Running|Saut|Crunch|Actualiz|Cogit|Ponder|Simmer|Processing|Stew|Grilling|Bak|Roast|Digest)'
idle_re='^❯([[:space:]]*$|[[:space:]]+.+$)'

while true; do
  now=$(date +%s)
  elapsed=$((now - START_TS))
  if [ "$elapsed" -ge "$TIMEOUT_S" ]; then
    echo "TIMEOUT after ${elapsed}s; killing session" >&2
    cleanup
    exit 124
  fi

  pane=$(tmux capture-pane -t "$SESSION" -p 2>/dev/null)
  if [ -z "$pane" ]; then
    idle_streak=0
    sleep "$POLL_INTERVAL"
    continue
  fi

  trimmed=$(echo "$pane" | awk '{a[NR]=$0; if(NF)last=NR} END {for(i=1;i<=last;i++) print a[i]}')
  bottom=$(echo "$trimmed" | tail -6)

  # Active spinner (excluding completed "for [0-9]+" tail) → still working
  if echo "$bottom" | grep -qE "$spinner_re" \
     && echo "$bottom" | grep -E "$spinner_re" | grep -qvE " for [0-9]+"; then
    idle_streak=0
  elif echo "$bottom" | grep -qE "$idle_re"; then
    idle_streak=$((idle_streak + 1))
    if [ "$idle_streak" -ge "$DONE_GRACE" ]; then
      break
    fi
  else
    # Pane neither shows active spinner nor idle prompt — keep waiting; don't
    # advance streak (e.g., mid-render, modal dialog, error banner).
    idle_streak=0
  fi

  sleep "$POLL_INTERVAL"
done

# Dump the full scroll-back so the caller can grep / parse. Caller is expected
# to know what to look for in the agent's response (a fixed marker string in
# the prompt makes this trivial).
tmux capture-pane -t "$SESSION" -p -S - -E -
