#!/bin/bash
set -euo pipefail

OUTPUT_DIR="${1:-${TMPDIR:-/tmp}/sdr2hdr-real-media-regression}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUTPUT_DIR"

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "UNSUPPORTED_GENERATOR_CAPABILITY: required tool '$1' is unavailable" >&2
    exit 2
  }
}

require_tool ffmpeg
require_tool ffprobe
require_tool python3

FFMPEG_ENCODERS="$(ffmpeg -hide_banner -encoders 2>/dev/null || true)"
HAS_H264=0
HAS_HEVC=0
if printf '%s\n' "$FFMPEG_ENCODERS" | rg -q '(^|[[:space:]])libx264([[:space:]]|$)'; then HAS_H264=1; fi
if printf '%s\n' "$FFMPEG_ENCODERS" | rg -q '(^|[[:space:]])libx265([[:space:]]|$)'; then HAS_HEVC=1; fi

mark_unsupported() {
  local id="$1"
  shift
  printf '%s\n' "$*" > "$OUTPUT_DIR/$id.UNSUPPORTED"
  echo "UNSUPPORTED_GENERATOR_CAPABILITY fixture=$id reason=$*"
}

generate_raw() {
  local raw_path="$1"
  local width="$2"
  local height="$3"
  local frame_count="$4"
  local bit_depth="$5"
  local range="$6"
  local content="$7"
  python3 - "$raw_path" "$width" "$height" "$frame_count" "$bit_depth" "$range" "$content" <<'PY'
import math
import pathlib
import struct
import sys

path = pathlib.Path(sys.argv[1])
width = int(sys.argv[2])
height = int(sys.argv[3])
frame_count = int(sys.argv[4])
bit_depth = int(sys.argv[5])
range_name = sys.argv[6]
content = sys.argv[7]

if width % 2 or height % 2:
    raise SystemExit("fixture dimensions must be even")

max_code = (1 << bit_depth) - 1
if range_name == "video":
    y_low = 16 << (bit_depth - 8)
    y_high = 235 << (bit_depth - 8)
    c_low = 16 << (bit_depth - 8)
    c_high = 240 << (bit_depth - 8)
else:
    y_low = 0
    y_high = max_code
    c_low = 0
    c_high = max_code
c_center = 128 << (bit_depth - 8)

def clamp(value, low, high):
    return max(low, min(high, int(round(value))))

def yuv_for_rgb(red, green, blue):
    y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    u = -0.1146 * red - 0.3854 * green + 0.5000 * blue + 0.5
    v = 0.5000 * red - 0.4542 * green - 0.0458 * blue + 0.5
    return (
        clamp(y * (y_high - y_low) + y_low, y_low, y_high),
        clamp(u * (c_high - c_low) + c_low, c_low, c_high),
        clamp(v * (c_high - c_low) + c_low, c_low, c_high),
    )

def base_luma(x, y, frame):
    if content == "dark-gradient":
        if bit_depth == 10:
            steps = [64, 65, 66, 68, 72, 80, 96, 128, 192, 256, 384, 512]
            return steps[x % len(steps)]
        steps = [16, 17, 18, 19, 20, 22, 24, 28, 32, 40, 52, 72]
        return steps[x % len(steps)]
    if content == "near-black":
        if bit_depth == 10:
            steps = [64, 65, 66, 67, 68, 70, 72, 76, 80, 88, 96, 112, 128, 160, 192, 224]
        else:
            steps = [16, 17, 18, 19, 20, 21, 22, 24, 26, 28, 30, 32]
        return steps[(x + y * 3) % len(steps)]
    fraction = (x / max(width - 1, 1)) * 0.65 + (y / max(height - 1, 1)) * 0.15
    return clamp(y_low + fraction * (y_high - y_low), y_low, y_high)

def color_at(x, y, frame):
    if content == "neutral-color":
        if x < width // 2 and y < height // 2:
            return (0.18, 0.18, 0.18)
        if x >= width // 2 and y < height // 2:
            return (0.80, 0.08, 0.08)
        if x < width // 2 and y >= height // 2:
            return (0.08, 0.80, 0.08)
        return (0.08, 0.08, 0.80)
    if content == "chroma-edge":
        if x < width // 2:
            return (0.42, 0.42, 0.42)
        if y < height // 2:
            return (0.90, 0.06, 0.06)
        return (0.06, 0.06, 0.90)
    if content == "motion":
        red_start = (frame * 3) % max(width - 12, 1)
        blue_start = (width - 12 - (frame * 2) % max(width - 12, 1))
        if red_start <= x < red_start + 12 and 8 <= y < height - 8:
            return (0.90, 0.05, 0.05)
        if blue_start <= x < blue_start + 12 and 4 <= y < height // 2:
            return (0.05, 0.05, 0.90)
        return (0.35, 0.35, 0.35)
    return None

with path.open("wb") as output:
    for frame in range(frame_count):
        y_plane = [0] * (width * height)
        u_plane = [c_center] * ((width // 2) * (height // 2))
        v_plane = [c_center] * ((width // 2) * (height // 2))
        for y in range(height):
            for x in range(width):
                color = color_at(x, y, frame)
                if color is None:
                    y_plane[y * width + x] = base_luma(x, y, frame)
                else:
                    y_code, _, _ = yuv_for_rgb(*color)
                    y_plane[y * width + x] = y_code
        for by in range(height // 2):
            for bx in range(width // 2):
                samples = []
                for py in (by * 2, by * 2 + 1):
                    for px in (bx * 2, bx * 2 + 1):
                        color = color_at(px, py, frame)
                        if color is None:
                            samples.append((0.5, 0.5, 0.5))
                        else:
                            samples.append(color)
                red = sum(item[0] for item in samples) / len(samples)
                green = sum(item[1] for item in samples) / len(samples)
                blue = sum(item[2] for item in samples) / len(samples)
                _, u_code, v_code = yuv_for_rgb(red, green, blue)
                index = by * (width // 2) + bx
                u_plane[index] = u_code
                v_plane[index] = v_code
        if bit_depth == 8:
            output.write(bytes(y_plane))
            output.write(bytes(u_plane))
            output.write(bytes(v_plane))
        else:
            for code in y_plane:
                output.write(struct.pack("<H", code << 6))
            for index in range(len(u_plane)):
                output.write(struct.pack("<H", u_plane[index] << 6))
                output.write(struct.pack("<H", v_plane[index] << 6))
PY
}

generate_one() {
  local id="$1"
  local codec="$2"
  local bit_depth="$3"
  local range="$4"
  local rate="$5"
  local timing="$6"
  local content="$7"
  local encoder
  local pixel_format
  local frames
  local raw_path="$OUTPUT_DIR/$id.raw"
  local output_path="$OUTPUT_DIR/$id.mp4"

  if [ "$codec" = "h264" ]; then
    if [ "$HAS_H264" -ne 1 ]; then
      mark_unsupported "$id" "libx264 encoder is unavailable"
      return 0
    fi
    encoder=libx264
    pixel_format=yuv420p
  else
    if [ "$HAS_HEVC" -ne 1 ]; then
      mark_unsupported "$id" "libx265 encoder is unavailable"
      return 0
    fi
    encoder=libx265
    if [ "$bit_depth" -eq 10 ]; then
      pixel_format=p010le
    else
      pixel_format=yuv420p
    fi
  fi

  if [ "$timing" = "vfr" ]; then
    frames=24
  else
    frames="$rate"
  fi
  generate_raw "$raw_path" 64 36 "$frames" "$bit_depth" "$range" "$content"

  local range_option=tv
  if [ "$range" = "full" ]; then range_option=pc; fi
  local -a command=(
    ffmpeg -hide_banner -loglevel error -y
    -f rawvideo -pixel_format "$pixel_format" -video_size 64x36
    -framerate "$rate" -i "$raw_path"
    -frames:v "$frames"
    -c:v "$encoder" -preset ultrafast
  )
  if [ "$codec" = "h264" ]; then
    command+=( -profile:v high -crf 18 -pix_fmt yuv420p )
  else
    if [ "$bit_depth" -eq 10 ]; then
      command+=( -x265-params "profile=main10:lossless=1" -pix_fmt yuv420p10le -tag:v hvc1 )
    else
      command+=( -x265-params "profile=main:lossless=1" -pix_fmt yuv420p -tag:v hvc1 )
    fi
  fi
  local filters="setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=$range_option"
  if [ "$timing" = "vfr" ]; then
    filters+=",setpts='PTS+if(gt(N,0),floor(N/3)/${rate}/TB,0)'"
  fi
  command+=(
    -color_range "$range_option"
    -colorspace bt709 -color_primaries bt709 -color_trc bt709
    -movflags +faststart+write_colr
    -vf "$filters"
  )
  if [ "$timing" = "vfr" ]; then
    command+=( -fps_mode vfr )
  fi
  command+=( "$output_path" )
  "${command[@]}"
  rm -f "$raw_path"
  echo "GENERATED fixture=$id path=$output_path"
}

generate_one h264-8-video-24-dark-gradient h264 8 video 24 cfr dark-gradient
generate_one h264-8-video-30-neutral-color h264 8 video 30 cfr neutral-color
generate_one h264-8-video-60-motion h264 8 video 60 cfr motion
generate_one h264-8-full-30-neutral-color h264 8 full 30 cfr neutral-color
generate_one hevc-8-video-30-chroma-edge hevc 8 video 30 cfr chroma-edge
generate_one hevc-main10-video-24-dark-gradient hevc 10 video 24 cfr dark-gradient
generate_one hevc-main10-video-30-chroma-edge hevc 10 video 30 cfr chroma-edge
generate_one hevc-main10-video-60-motion hevc 10 video 60 cfr motion
generate_one h264-8-video-vfr-motion h264 8 video 24 vfr motion
generate_one hevc-main10-video-vfr-motion hevc 10 video 24 vfr motion
generate_one hevc-main10-video-24-near-black hevc 10 video 24 cfr near-black
generate_one h264-8-video-24-chroma-edge h264 8 video 24 cfr chroma-edge

echo "REAL-MEDIA REGRESSION FIXTURES: GENERATED"
