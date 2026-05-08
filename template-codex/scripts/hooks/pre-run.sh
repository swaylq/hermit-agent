#!/bin/bash
# pre-run hook — runs before each codex turn, for the incoming user prompt.
#
# Receives via env:
#   CODEX_PROMPT       user's incoming message
#   CODEX_THREAD_ID    current thread uuid (empty on first turn)
#   CODEX_CHAT_ID      Telegram chat_id
#
# Exit code: 0 = continue normal flow; non-zero = abort this turn (daemon
# replies to user with an abort notice and skips the codex call entirely).
#
# Use cases:
#   - safe-image.sh on attached image paths before they reach codex
#   - reject prompts containing tokens / secrets / blacklisted patterns
#   - pre-flight rate-limit check before burning a codex exec call
#
# Default behaviour: no-op pass-through. Edit to add real pre-flight logic.

set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")/../.." && pwd)"

# --- image safety ----------------------------------------------------
# Detect plausible image paths in the prompt (absolute paths ending in
# .png/.jpg/.jpeg/.webp/.gif/.bmp/.tiff). For each one that exists, resize
# in place via safe-image.sh so codex picks up the safe version. The
# user/codex still references the same path, but the file on disk is
# guaranteed within MAX_PX.
img_paths=$(printf '%s' "${CODEX_PROMPT:-}" | grep -oE '/[A-Za-z0-9_./-]+\.(png|jpg|jpeg|webp|gif|bmp|tiff)' | sort -u || true)
for img in $img_paths; do
  [ -f "$img" ] || continue
  if ! safe="$("$WORKDIR/scripts/safe-image.sh" "$img" 2>/dev/null)"; then
    echo "pre-run: safe-image.sh failed on $img — aborting turn" >&2
    exit 1
  fi
  # If safe-image.sh produced a .safe.png alongside, replace the original
  # so codex reading the original path still gets the safe content.
  if [ "$safe" != "$img" ] && [ -f "$safe" ]; then
    mv -f "$safe" "$img"
  fi
done

exit 0
