#!/bin/bash
# Unit test for hook-block-nested-subagent.sh.
#
# The payloads below are the REAL shapes captured from a live nested spawn on 2026-09-07
# (a PreToolUse logger wired via --settings, then a prompt that made a subagent spawn a
# subagent). That provenance is the point of this file: version 1 of the hook was "verified"
# on 104 agents against JSON invented by hand, passed every time, and blocked nothing —
# it keyed on parent_session_id and on "/subagents/" in transcript_path, and neither ever
# appears in a real event. If you change the detection, capture events again; do not invent.
#
#   bash scripts/hook-block-nested-subagent.test.sh
set -u
HOOK="$(dirname "$0")/hook-block-nested-subagent.sh"
pass=0; fail=0

check() { # <name> <expected: deny|allow> <json>
  local got
  got=$(printf '%s' "$3" | "$HOOK" 2>/dev/null | python3 -c \
    'import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])
except Exception: print("allow")')
  if [ "$got" = "$2" ]; then pass=$((pass+1)); echo "  ok   $1"
  else fail=$((fail+1)); echo "  FAIL $1 — expected $2, got $got"; fi
}

# Inside a subagent, agent_id + agent_type are present. This is the one that must be denied.
check "nested Agent call is blocked" deny \
  '{"session_id":"s","transcript_path":"/p/s.jsonl","cwd":"/c","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{},"tool_use_id":"t","agent_id":"a99d0886bfbe8da24","agent_type":"general-purpose"}'
check "nested Task call is blocked" deny \
  '{"session_id":"s","transcript_path":"/p/s.jsonl","cwd":"/c","hook_event_name":"PreToolUse","tool_name":"Task","tool_input":{},"tool_use_id":"t","agent_id":"a1","agent_type":"general-purpose"}'
# Top-level: no agent_id at all. Must stay allowed — this is the sanctioned wide sweep.
check "top-level Agent call is allowed" allow \
  '{"session_id":"s","transcript_path":"/p/s.jsonl","cwd":"/c","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{},"tool_use_id":"t"}'
# Other tools inside a subagent are none of this hook's business.
check "Bash inside a subagent is allowed" allow \
  '{"session_id":"s","transcript_path":"/p/s.jsonl","cwd":"/c","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{},"tool_use_id":"t","agent_id":"a99d0886bfbe8da24","agent_type":"general-purpose"}'
# Fail-open.
check "malformed input is allowed" allow 'not json at all'
check "empty input is allowed" allow ''

echo "$pass passed · $fail failed"
[ "$fail" -eq 0 ] || exit 1
