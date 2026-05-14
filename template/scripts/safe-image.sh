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

# Claude API rejects images by content-type derived from bytes, not extension.
# Only jpeg/png are universally safe; anything else (tiff, heic, gif, webp,
# bmp, …) must be transcoded to PNG even when it's already within MAX_PX.
# Past incident: 2026-05-14 — script wrote `.safe.png` containing TIFF bytes
# because `sips --resampleWidth` preserves source encoding by default. Every
# Read of that file 400'd with "Image format image/png not supported", and
# because the bad image stayed in context the next turn re-hit the same 400 —
# Stop hooks never fired, sessions wedged at state=running.
FMT=$(sips -g format "$INPUT" 2>/dev/null | awk '/format:/{print $2}')
case "$FMT" in
  jpeg|png) NEEDS_TRANSCODE=0 ;;
  *)        NEEDS_TRANSCODE=1 ;;
esac

if (( LONG <= MAX_PX )) && [ "$NEEDS_TRANSCODE" -eq 0 ]; then
  # Already safe (within size limit AND in an API-supported format)
  echo "$INPUT"
  exit 0
fi

# Build output path: /path/to/file.jpg → /path/to/file.safe.png
DIR=$(dirname "$INPUT")
BASE=$(basename "$INPUT")
NAME="${BASE%.*}"
SAFE="$DIR/${NAME}.safe.png"

# Copy then convert. `-s format png` is what actually changes the encoded
# bytes; without it sips emits the source format regardless of the output
# filename. Resample only when we exceed MAX_PX — small-but-wrong-format
# inputs just need transcoding.
cp "$INPUT" "$SAFE"

sips_args=(-s format png)
if (( LONG > MAX_PX )); then
  if (( W >= H )); then
    sips_args+=(--resampleWidth "$MAX_PX")
  else
    sips_args+=(--resampleHeight "$MAX_PX")
  fi
fi

sips "${sips_args[@]}" "$SAFE" >/dev/null 2>&1

echo "$SAFE"
