#!/bin/bash
# hook-block-askuserquestion.sh — PreToolUse block for AskUserQuestion.
#
# AskUserQuestion is Claude Code's built-in tool for prompting the user to pick
# from a set of options. It renders a TUI modal directly to stdin/stdout — in
# the hermit-agent headless tmux + Telegram setup, the user never sees it and
# the turn hangs forever waiting on stdin.
#
# Block the call and tell the agent to use Telegram reply with numbered options
# instead. The reason text reaches the model so it can adapt mid-turn.

exec /usr/bin/env python3 -c '
import json, sys

try:
    event = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

if event.get("tool_name") != "AskUserQuestion":
    sys.exit(0)

reason = (
    "AskUserQuestion is disabled in this hermit (headless tmux + Telegram). "
    "Its TUI modal renders to the local pane only — the user is on Telegram and never sees it, "
    "so the turn would hang forever waiting on stdin. "
    "Instead: send a Telegram reply via mcp__plugin_telegram_telegram__reply with the "
    "options as numbered lines (e.g. \"1. <label>\\n2. <label>\\n3. <label>\"), end the turn, "
    "and let the user answer in the next inbound message."
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }
}))
sys.exit(0)
'
