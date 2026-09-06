#!/bin/bash
# hook-block-nested-subagent.sh — PreToolUse block for a subagent spawning another subagent.
#
# AGENTS.md says "never one inside another". This is the mechanical floor under that rule,
# because the rule alone did not hold: on 2026-09-06 a session fanned out to 3 subagents,
# one of which spawned 2 more, and the nested branch alone cost 19M tokens — 87% of the
# whole session's spend came from subagents it never saw the inside of.
#
# Detection: a PreToolUse event fired inside a subagent carries `parent_session_id`, and
# its `transcript_path` sits under `<session>/subagents/`. Either signal is enough.
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

    parent = event.get("parent_session_id") or ""
    transcript = event.get("transcript_path") or ""
    in_subagent = bool(parent) or "/subagents/" in transcript
    if not in_subagent:
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
