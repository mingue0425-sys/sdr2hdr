#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GENERATED_TEMPORARY_FIXTURE=0
if [ "$#" -gt 0 ]; then
  FIXTURE_PATH="$1"
else
  FIXTURE_PATH="$(mktemp -t sdr2hdr-tiny-p010-fixture).mp4"
  GENERATED_TEMPORARY_FIXTURE=1
fi
if [ "$GENERATED_TEMPORARY_FIXTURE" -eq 1 ]; then
  trap 'rm -f "$FIXTURE_PATH"' EXIT
fi

"$REPOSITORY_ROOT/Tests/generate_tiny_p010_fixture.sh" "$FIXTURE_PATH"

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "ffprobe is required to validate the generated P010 fixture" >&2
  exit 2
fi

PIX_FMT="$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of default=noprint_wrappers=1:nokey=1 "$FIXTURE_PATH")"
CODEC="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$FIXTURE_PATH")"
RANGE="$(ffprobe -v error -select_streams v:0 -show_entries stream=color_range -of default=noprint_wrappers=1:nokey=1 "$FIXTURE_PATH")"

if [ "$PIX_FMT" != "yuv420p10le" ] || [ "$CODEC" != "hevc" ] || [ "$RANGE" != "tv" ]; then
  echo "P010 fixture metadata mismatch: codec=$CODEC pix_fmt=$PIX_FMT range=$RANGE" >&2
  exit 1
fi

echo "self-contained P010 compressed fixture: PASS (codec=$CODEC pix_fmt=$PIX_FMT range=$RANGE)"
