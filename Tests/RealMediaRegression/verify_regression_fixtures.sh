#!/bin/bash
set -euo pipefail

FIXTURE_DIR="${1:?usage: verify_regression_fixtures.sh <fixture-directory>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_PATH="${HDR_REAL_MEDIA_REGRESSION_MANIFEST:-$SCRIPT_DIR/manifest.json}"
RESULT_PATH="${HDR_REAL_MEDIA_REGRESSION_PROBE_RESULTS:-$FIXTURE_DIR/probe-results.json}"

command -v ffprobe >/dev/null 2>&1 || {
  echo "UNSUPPORTED_GENERATOR_CAPABILITY: ffprobe is unavailable" >&2
  exit 2
}

python3 - "$MANIFEST_PATH" "$FIXTURE_DIR" "$RESULT_PATH" <<'PY'
import json
import math
import pathlib
import subprocess
import sys

manifest_path = pathlib.Path(sys.argv[1])
fixture_dir = pathlib.Path(sys.argv[2])
result_path = pathlib.Path(sys.argv[3])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
results = []
failures = []

def probe(path, selector):
    command = [
        "ffprobe", "-v", "error", "-print_format", "json",
        selector, str(path),
    ]
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    return json.loads(completed.stdout)

def distinct_count(values, tolerance=0.0005):
    representatives = []
    for value in values:
        if not math.isfinite(value):
            continue
        if not any(abs(value - representative) <= tolerance for representative in representatives):
            representatives.append(value)
    return len(representatives)

for fixture in manifest["fixtures"]:
    fixture_id = fixture["id"]
    marker = fixture_dir / f"{fixture_id}.UNSUPPORTED"
    if marker.exists():
        results.append({"id": fixture_id, "status": "skipped", "reason": marker.read_text(encoding="utf-8").strip()})
        continue
    path = fixture_dir / f"{fixture_id}.mp4"
    if not path.exists():
        failures.append(f"{fixture_id}: fixture file is missing")
        continue
    try:
        streams = probe(path, "-show_streams")
        frames_document = probe(path, "-show_frames")
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        failures.append(f"{fixture_id}: ffprobe failed: {error}")
        continue
    video_streams = [stream for stream in streams.get("streams", []) if stream.get("codec_type") == "video"]
    if len(video_streams) != 1:
        failures.append(f"{fixture_id}: expected one video stream, got {len(video_streams)}")
        continue
    stream = video_streams[0]
    expected_codec = fixture["codec"]
    if stream.get("codec_name") != expected_codec:
        failures.append(f"{fixture_id}: codec expected {expected_codec}, got {stream.get('codec_name')}")
    pix_fmt = stream.get("pix_fmt")
    if fixture["sourceBitDepth"] == 10:
        if pix_fmt != "yuv420p10le":
            failures.append(f"{fixture_id}: Main10 pixel format expected yuv420p10le, got {pix_fmt}")
        if stream.get("profile") != "Main 10":
            failures.append(f"{fixture_id}: Main10 profile expected 'Main 10', got {stream.get('profile')}")
    elif pix_fmt not in {"yuv420p", "yuvj420p"}:
        failures.append(f"{fixture_id}: 8-bit pixel format unexpected: {pix_fmt}")
    if fixture["sourceBitDepth"] == 8 and fixture["codec"] == "hevc" and stream.get("profile") != "Main":
        failures.append(f"{fixture_id}: HEVC 8-bit profile expected 'Main', got {stream.get('profile')}")
    expected_range = "pc" if fixture["range"] == "full" else "tv"
    if stream.get("color_range") != expected_range:
        failures.append(f"{fixture_id}: range expected {expected_range}, got {stream.get('color_range')}")
    for key, expected in (("color_space", "bt709"), ("color_transfer", "bt709"), ("color_primaries", "bt709")):
        if stream.get(key) != expected:
            failures.append(f"{fixture_id}: {key} expected {expected}, got {stream.get(key)}")
    rate_text = stream.get("r_frame_rate", "0/1")
    numerator, denominator = rate_text.split("/", 1)
    measured_rate = float(numerator) / float(denominator)
    if abs(measured_rate - fixture["frameRate"]) > 0.01:
        failures.append(f"{fixture_id}: nominal frame rate expected {fixture['frameRate']}, got {rate_text}")
    frame_records = [frame for frame in frames_document.get("frames", []) if frame.get("media_type") == "video"]
    timestamps = []
    for frame in frame_records:
        value = frame.get("best_effort_timestamp_time")
        if value is None:
            continue
        timestamp = float(value)
        if not math.isfinite(timestamp):
            failures.append(f"{fixture_id}: non-finite frame timestamp")
        timestamps.append(timestamp)
    if len(timestamps) < fixture["minimumFrames"]:
        failures.append(f"{fixture_id}: ffprobe saw {len(timestamps)} frames, expected at least {fixture['minimumFrames']}")
    deltas = [right - left for left, right in zip(timestamps, timestamps[1:])]
    if any(delta <= 0 for delta in deltas):
        failures.append(f"{fixture_id}: ffprobe timestamps are not strictly increasing")
    distinct = distinct_count(deltas)
    if distinct < fixture["minimumDistinctFrameDurations"]:
        failures.append(f"{fixture_id}: distinct frame durations {distinct} below expected {fixture['minimumDistinctFrameDurations']}")
    results.append({
        "id": fixture_id,
        "status": "pass" if not any(failure.startswith(f"{fixture_id}:") for failure in failures) else "fail",
        "codec": stream.get("codec_name"),
        "pixelFormat": pix_fmt,
        "range": stream.get("color_range"),
        "transfer": stream.get("color_transfer"),
        "matrix": stream.get("color_space"),
        "frameCount": len(timestamps),
        "distinctFrameDurations": distinct,
        "timestamps": timestamps,
    })

result_path.parent.mkdir(parents=True, exist_ok=True)
result_path.write_text(json.dumps({"manifest": manifest["baseline"], "fixtures": results}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)
for result in results:
    print(f"FIXTURE_PROBE id={result['id']} status={result['status']}")
print(f"REGRESSION_FIXTURE_PROBE: PASS ({len(results)} fixtures)")
PY
