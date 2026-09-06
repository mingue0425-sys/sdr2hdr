#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_PATH="$(mktemp -t sdr2hdr-tiny-fixture).mp4"
trap 'rm -f "$FIXTURE_PATH"' EXIT

"$REPOSITORY_ROOT/Tests/generate_tiny_media_fixture.sh" "$FIXTURE_PATH"

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "ffprobe is required to validate the generated fixture" >&2
  exit 2
fi

ffprobe -v error \
  -select_streams v:0 \
  -show_entries stream=codec_name,width,height,pix_fmt,r_frame_rate \
  -of csv=p=0 \
  "$FIXTURE_PATH"

echo "self-contained tiny media fixture: PASS"
