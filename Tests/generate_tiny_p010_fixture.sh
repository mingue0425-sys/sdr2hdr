#!/bin/bash
set -euo pipefail

OUTPUT_PATH="${1:-${TMPDIR:-/tmp}/sdr2hdr-tiny-p010-verification-fixture.mp4}"
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR"

if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "ffmpeg and python3 are required to generate the self-contained P010 fixture" >&2
  exit 2
fi

if ! ffmpeg -hide_banner -h encoder=libx265 >/dev/null 2>&1; then
  echo "ffmpeg with the libx265 Main10 encoder is required to generate the P010 fixture" >&2
  exit 2
fi

# Build a small lossless P010 source so the fixture contains real 10-bit code
# values (including adjacent near-black levels) before it is compressed into
# HEVC Main10. It is synthetic and contains no calibration, holdout, or
# external media.
RAW_PATH="${OUTPUT_PATH}.raw.p010"
trap 'rm -f "$RAW_PATH"' EXIT
python3 - "$RAW_PATH" <<'PY'
import struct
import sys

path = sys.argv[1]
width = 64
height = 36
frames = 24

def clamp(value):
    return max(64, min(940, value))

with open(path, "wb") as handle:
    for frame in range(frames):
        y_plane = bytearray(width * height * 2)
        for y in range(height):
            for x in range(width):
                if x < 16 and y < 12:
                    code = 64 + ((x + y + frame) % 32)
                elif x < 32 and y < 12:
                    code = 128 + ((x * 8 + frame) % 128)
                elif x >= 48 and y < 12:
                    code = 940
                elif x < 16 and y >= 12:
                    code = 512
                elif x < 32 and y >= 12:
                    code = 700
                elif x < 48 and y >= 12:
                    code = 820
                else:
                    code = 64 + ((x * 7 + y * 3 + frame) % 877)
                struct.pack_into("<H", y_plane, (y * width + x) * 2, clamp(code) << 6)
        handle.write(y_plane)

        uv_plane = bytearray((width // 2) * (height // 2) * 4)
        for y in range(height // 2):
            for x in range(width // 2):
                if x < 8:
                    cb, cr = 512, 512
                elif x < 16:
                    cb, cr = 384, 768
                elif x < 24:
                    cb, cr = 768, 384
                else:
                    cb, cr = 512, 512
                offset = (y * (width // 2) + x) * 4
                struct.pack_into("<HH", uv_plane, offset, cb << 6, cr << 6)
        handle.write(uv_plane)
PY

ffmpeg -hide_banner -loglevel error -y \
  -f rawvideo -pix_fmt p010le -s 64x36 -r 24 -i "$RAW_PATH" \
  -an \
  -c:v libx265 \
  -x265-params "profile=main10:lossless=1:log-level=error:colorprim=bt709:transfer=bt709:colormatrix=bt709" \
  -pix_fmt yuv420p10le \
  -color_primaries bt709 \
  -color_trc bt709 \
  -colorspace bt709 \
  -color_range tv \
  -tag:v hvc1 \
  -movflags +faststart \
  "$OUTPUT_PATH"

echo "generated self-contained P010 fixture: $OUTPUT_PATH"
