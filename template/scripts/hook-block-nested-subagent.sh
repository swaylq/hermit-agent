#!/bin/bash
# hook-block-nested-subagent.sh — PreToolUse block for a subagent spawning another subagent.
#
# AGENTS.md says "never one inside another". This is the mechanical floor under that rule,
# because the rule alone did not hold: on 2026-09-06 a session fanned out to 3 subagents,
# one of which spawned 2 more, and 87% of that session's spend came from subagents the
# parent never saw the inside of. On 2026-09-07 a zhinan-wifi session reached spawnDepth 3
# with 18 subagents — with the first version of this hook installed and doing nothing.
#
# Detection — verified against real captured events, not invented ones:
#   PreToolUse payload = {session_id, transcript_path, cwd, prompt_id?,
#                         hook_event_name, tool_name, tool_input, tool_use_id}
#   and, ONLY when the call originates inside a subagent, {agent_id, agent_type}.
# So `agent_id` present is the whole test. The first version looked for parent_session_id
# (exists only in this binary's telemetry schema, never in a hook payload) and for
# "/subagents/" in transcript_path (transcript_path is always the PARENT's transcript;
# the subagent's own file arrives as agent_transcript_path, and only on SubagentStop).
# Both signals were absent from every real event, so the hook allowed everything while
# looking installed and healthy on 104 agents.
#
# Fail-open by design: any parse problem, any unexpected shape, we exit 0 and allow. A
# wrongly blocked Agent call is a broken session; a wrongly allowed one is just expensive.

exec /usr/bin/env python3 -c '
import json, sys

try:
    event = json.load(sys.stdin)
except Exception:
    sys.exit(0)

try:
    if event.get("tool_name") not in ("Agent", "Task"):
        sys.exit(0)

    # Present only when this tool call is being made from inside a subagent.
    if not event.get("agent_id"):
        sys.exit(0)

    reason = (
        "Blocked: you are already running inside a subagent, and a subagent may not spawn "
        "another one (AGENTS.md, Subagents HARD RULE). Nesting is the single most expensive "
        "shape available to you — the parent cannot see what the grandchild does, and every "
        "level pays for its own fresh context. "
        "Do the work in this turn instead: run the searches or reads yourself and return the "
        "conclusion. If it genuinely does not fit, return what you have plus a note saying "
        "what is still missing, and let the top-level session decide."
    )

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
except Exception:
    sys.exit(0)
sys.exit(0)
'
