#!/bin/bash
set -euo pipefail

OUTPUT_PATH="${1:-${TMPDIR:-/tmp}/sdr2hdr-tiny-verification-fixture.mp4}"
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required to generate the self-contained media fixture" >&2
  exit 2
fi

# The fixture is synthetic, deterministic, tiny, and contains no calibration
# or holdout content. It exists only to exercise AVFoundation/media plumbing.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=64x36:rate=24" \
  -t 1 \
  -an \
  -c:v libx264 -pix_fmt yuv420p \
  -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv \
  -movflags +faststart \
  "$OUTPUT_PATH"

echo "generated self-contained fixture: $OUTPUT_PATH"
