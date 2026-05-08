#!/bin/bash
# safe-image.sh — Resize images so the long edge is ≤ MAX_PX before feeding to context.
# Uses macOS sips (zero external dependencies).
#
# Usage: safe-image.sh <image-path> [max-px]
# Output: prints the safe path to stdout (original if already small, .safe.png if resized)
# Exit 0 on success, 1 on error.

set -euo pipefail

MAX_PX="${2:-1800}"
INPUT="$1"

if [[ ! -f "$INPUT" ]]; then
  echo "error: file not found: $INPUT" >&2
  exit 1
fi

# Get dimensions
W=$(sips -g pixelWidth  "$INPUT" 2>/dev/null | awk '/pixelWidth/{print $2}')
H=$(sips -g pixelHeight "$INPUT" 2>/dev/null | awk '/pixelHeight/{print $2}')

if [[ -z "$W" || -z "$H" || "$W" == "<nil>" || "$H" == "<nil>" || ! "$W" =~ ^[0-9]+$ || ! "$H" =~ ^[0-9]+$ ]]; then
  echo "error: cannot read dimensions (W='$W' H='$H'): $INPUT" >&2
  exit 1
fi

LONG=$(( W > H ? W : H ))

if (( LONG <= MAX_PX )); then
  # Already safe
  echo "$INPUT"
  exit 0
fi

# Build output path: /path/to/file.jpg → /path/to/file.safe.png
DIR=$(dirname "$INPUT")
BASE=$(basename "$INPUT")
NAME="${BASE%.*}"
SAFE="$DIR/${NAME}.safe.png"

# Copy then resize (sips modifies in place)
cp "$INPUT" "$SAFE"

if (( W >= H )); then
  sips --resampleWidth "$MAX_PX" "$SAFE" >/dev/null 2>&1
else
  sips --resampleHeight "$MAX_PX" "$SAFE" >/dev/null 2>&1
fi

echo "$SAFE"
