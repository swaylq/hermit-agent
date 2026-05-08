#!/bin/bash
# Usage: with-timeout.sh <seconds> <cmd> [args...]
#
# Run <cmd> with a hard runtime limit. macOS ships no `timeout(1)` by default,
# so this script fills that gap using a watchdog subshell.
#
# Exit codes:
#   0                 — command exited successfully in time
#   <cmd's code>      — command exited on its own in time
#   124               — command hit the timeout and was killed (matches GNU timeout)
#   125               — invocation error (missing args)

set -u

if [ $# -lt 2 ]; then
  echo "Usage: $0 <seconds> <cmd> [args...]" >&2
  exit 125
fi

TIMEOUT_S="$1"
shift

"$@" &
CMD_PID=$!

# Watchdog: after TIMEOUT_S, send TERM; if still alive 5s later, KILL.
(
  sleep "$TIMEOUT_S"
  kill -0 "$CMD_PID" 2>/dev/null || exit 0
  # Mark FIRST so the parent sees it even if wait returns immediately after TERM.
  touch "/tmp/with-timeout.${CMD_PID}.fired"
  kill -TERM "$CMD_PID" 2>/dev/null
  sleep 5
  kill -0 "$CMD_PID" 2>/dev/null && kill -KILL "$CMD_PID" 2>/dev/null
) &
WATCHDOG_PID=$!
disown "$WATCHDOG_PID" 2>/dev/null || true

wait "$CMD_PID"
CMD_EXIT=$?

# Reap the watchdog cleanly if the command finished first.
kill "$WATCHDOG_PID" 2>/dev/null
wait "$WATCHDOG_PID" 2>/dev/null

FIRED_MARKER="/tmp/with-timeout.${CMD_PID}.fired"
if [ -f "$FIRED_MARKER" ]; then
  rm -f "$FIRED_MARKER"
  exit 124
fi

exit "$CMD_EXIT"
