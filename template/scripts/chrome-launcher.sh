#!/bin/bash
# chrome-launcher.sh — Launch and manage a dedicated Chrome instance with CDP.
#
# Each agent gets an isolated Chrome profile and a unique CDP port in 19900-19999.
#
# Usage:
#   chrome-launcher.sh start     — launch Chrome (find free port, save config)
#   chrome-launcher.sh stop      — stop Chrome
#   chrome-launcher.sh restart   — stop + start
#   chrome-launcher.sh status    — show state
#   chrome-launcher.sh port      — print saved CDP port
#
# Config saved to: <AGENT_DIR>/browser/chrome.json
# Profile stored at: <AGENT_DIR>/browser/user-data/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BROWSER_DIR="$AGENT_DIR/browser"
CHROME_JSON="$BROWSER_DIR/chrome.json"
USER_DATA_DIR="$BROWSER_DIR/user-data"
CHROME_LOG="$BROWSER_DIR/chrome.log"

# Chrome binary detection (macOS)
CHROME_BIN="${CHROME_BIN:-}"
if [ -z "$CHROME_BIN" ]; then
  if [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
    CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  elif [ -x "/Applications/Chromium.app/Contents/MacOS/Chromium" ]; then
    CHROME_BIN="/Applications/Chromium.app/Contents/MacOS/Chromium"
  elif command -v google-chrome &>/dev/null; then
    CHROME_BIN="$(command -v google-chrome)"
  elif command -v chromium &>/dev/null; then
    CHROME_BIN="$(command -v chromium)"
  else
    echo "❌ Chrome not found. Set CHROME_BIN env var." >&2
    exit 1
  fi
fi

# Deterministic per-agent port. Hash agent name to a stable offset within
# 19900-19999 so two sibling hermits never compete for the same slot. Sidesteps
# the find_free_port TOCTOU race where lsof saw the port free during a brief
# Chrome restart window and two agents ended up sharing the same port (one
# IPv4, one IPv6 — the upstream asst hub hit this 2026-05-15 between two agents).
deterministic_port() {
  local name=$1
  local offset
  offset=$(printf '%s' "$name" | cksum | awk '{print $1 % 100}')
  echo $((19900 + offset))
}

# Returns 0 if any other sibling agent's chrome.json claims this port AND
# that PID is alive. Hash collisions are rare (100 slots) but not impossible.
sibling_owns_port() {
  local port=$1 self_dir=$2
  local agents_root
  agents_root="$(cd "$self_dir/.." && pwd)"
  local cj
  for cj in "$agents_root"/*/browser/chrome.json; do
    [ -f "$cj" ] || continue
    case "$cj" in "$self_dir/browser/chrome.json") continue ;; esac
    local sib_port sib_pid
    sib_port=$(python3 -c "import json; print(json.load(open('$cj')).get('cdp_port', ''))" 2>/dev/null || true)
    sib_pid=$(python3 -c "import json; print(json.load(open('$cj')).get('pid', ''))" 2>/dev/null || true)
    [ "$sib_port" = "$port" ] && [ -n "$sib_pid" ] && kill -0 "$sib_pid" 2>/dev/null && return 0
  done
  return 1
}

find_free_port() {
  # Linear fallback for when the deterministic port is taken (hash collision,
  # external process, etc). Skip ports owned by live sibling agents even if
  # their Chrome isn't currently bound (covers the launch-window race).
  local port
  for port in $(seq 19900 19999); do
    lsof -i ":$port" &>/dev/null && continue
    sibling_owns_port "$port" "$AGENT_DIR" && continue
    echo "$port"
    return 0
  done
  echo "❌ No free port in 19900-19999 range" >&2
  exit 1
}

get_saved_port() {
  if [ -f "$CHROME_JSON" ]; then
    python3 -c "import json; print(json.load(open('$CHROME_JSON')).get('cdp_port', ''))" 2>/dev/null || true
  fi
}

get_saved_pid() {
  if [ -f "$CHROME_JSON" ]; then
    python3 -c "import json; print(json.load(open('$CHROME_JSON')).get('pid', ''))" 2>/dev/null || true
  fi
}

is_chrome_running() {
  local pid
  pid=$(get_saved_pid)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

start_chrome() {
  if is_chrome_running; then
    local port=$(get_saved_port)
    local pid=$(get_saved_pid)
    echo "✅ Chrome already running (PID: $pid, CDP: $port)"
    return 0
  fi

  mkdir -p "$USER_DATA_DIR" "$BROWSER_DIR"

  local AGENT_NAME
  AGENT_NAME="$(basename "$AGENT_DIR")"
  local DEFAULT_PROFILE_DIR="$USER_DATA_DIR/Default"
  local PREFS_FILE="$DEFAULT_PROFILE_DIR/Preferences"
  local LOCAL_STATE="$USER_DATA_DIR/Local State"
  local AVATAR_INDEX
  AVATAR_INDEX=$(printf '%s' "$AGENT_NAME" | cksum | awk '{print $1 % 26}')

  mkdir -p "$DEFAULT_PROFILE_DIR"

  # Seed profile name so Chrome's avatar menu shows the agent name
  python3 - <<PY
import json, os
name = "$AGENT_NAME"
idx = $AVATAR_INDEX
prefs_path = "$PREFS_FILE"
state_path = "$LOCAL_STATE"

try:
    prefs = json.load(open(prefs_path)) if os.path.exists(prefs_path) else {}
except Exception:
    prefs = {}
prefs.setdefault("profile", {})
prefs["profile"]["name"] = name
prefs["profile"]["avatar_index"] = idx
with open(prefs_path, "w") as f:
    json.dump(prefs, f)

try:
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
except Exception:
    state = {}
state.setdefault("profile", {}).setdefault("info_cache", {}).setdefault("Default", {})
info = state["profile"]["info_cache"]["Default"]
info["name"] = name
info["avatar_icon"] = f"chrome://theme/IDR_PROFILE_AVATAR_{idx}"
info["is_using_default_name"] = False
info["is_using_default_avatar"] = False
with open(state_path, "w") as f:
    json.dump(state, f)
PY

  # Pick port: try deterministic (hash of agent name) first, fall back to scan.
  local port
  port=$(deterministic_port "$AGENT_NAME")
  if lsof -i ":$port" &>/dev/null || sibling_owns_port "$port" "$AGENT_DIR"; then
    echo "ℹ️  Deterministic port $port taken; scanning…" >&2
    port=$(find_free_port)
  fi

  echo "🚀 Launching Chrome as profile \"$AGENT_NAME\" (CDP port: $port)..."

  # --remote-debugging-address=127.0.0.1 pins CDP to IPv4 explicitly. Chrome's
  # default behavior on macOS is to silently fall back to [::1] when 127.0.0.1:port
  # is taken, which corrupts ownership tracking — chrome.json says "we own port X"
  # but Chrome is actually listening on a different IP family. Forcing IPv4 makes
  # port conflicts hard-fail instead of silently rebinding.
  nohup "$CHROME_BIN" \
    --remote-debugging-port="$port" \
    --remote-debugging-address=127.0.0.1 \
    --user-data-dir="$USER_DATA_DIR" \
    --no-first-run \
    --no-default-browser-check \
    --disable-default-apps \
    --disable-popup-blocking \
    --disable-translate \
    --disable-sync \
    --window-size=1280,800 \
    > "$CHROME_LOG" 2>&1 &

  local chrome_pid=$!
  disown

  local attempts=0
  while [ $attempts -lt 15 ]; do
    if curl -s --max-time 1 "http://127.0.0.1:$port/json/version" &>/dev/null; then
      python3 -c "
import json
config = {
    'cdp_port': $port,
    'pid': $chrome_pid,
    'user_data_dir': '$USER_DATA_DIR',
    'chrome_bin': '$CHROME_BIN'
}
with open('$CHROME_JSON', 'w') as f:
    json.dump(config, f, indent=2)
"
      echo "✅ Chrome ready (PID: $chrome_pid, CDP: $port)"
      echo "📁 Profile: $USER_DATA_DIR"
      return 0
    fi
    sleep 1
    attempts=$((attempts + 1))
  done

  echo "❌ Chrome failed to start. Check $CHROME_LOG" >&2
  kill "$chrome_pid" 2>/dev/null || true
  exit 1
}

stop_chrome() {
  local pid
  pid=$(get_saved_pid)

  if [ -z "$pid" ]; then
    echo "ℹ️  No Chrome instance recorded."
    return 0
  fi

  if kill -0 "$pid" 2>/dev/null; then
    echo "🛑 Stopping Chrome (PID: $pid)..."
    kill "$pid" 2>/dev/null
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null
      sleep 1
    fi
    echo "✅ Chrome stopped."
  else
    echo "ℹ️  Chrome (PID: $pid) already stopped."
  fi

  if [ -f "$CHROME_JSON" ]; then
    python3 -c "
import json
config = json.load(open('$CHROME_JSON'))
config['pid'] = None
with open('$CHROME_JSON', 'w') as f:
    json.dump(config, f, indent=2)
"
  fi
}

status_chrome() {
  echo "--- Chrome Status ---"
  if [ ! -f "$CHROME_JSON" ]; then
    echo "⭕ No Chrome config found."
    return 0
  fi

  local pid port
  pid=$(get_saved_pid)
  port=$(get_saved_port)

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "🟢 Running (PID: $pid)"
  else
    echo "🔴 Stopped"
  fi
  echo "🔌 CDP port: ${port:-not set}"
  echo "📁 Profile: $USER_DATA_DIR"

  if [ -n "$port" ] && curl -s --max-time 1 "http://127.0.0.1:$port/json/version" &>/dev/null; then
    echo "🌐 CDP responding on port $port"
  elif [ -n "$port" ]; then
    echo "⭕ CDP not responding on port $port"
  fi
}

case "${1:-status}" in
  start)   start_chrome ;;
  stop)    stop_chrome ;;
  restart) stop_chrome; sleep 1; start_chrome ;;
  status)  status_chrome ;;
  port)    get_saved_port ;;
  *)       echo "Usage: chrome-launcher.sh {start|stop|restart|status|port}" >&2; exit 1 ;;
esac
