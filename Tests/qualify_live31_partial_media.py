#!/usr/bin/env python3
"""Qualify the downloaded LIVE31 reference subset without quality evaluation.

This script consumes only the author-provided acquisition manifest and the
exact filenames named by that manifest.  It performs no recursive discovery,
no content hashing, and no objective/pixel-quality calculation.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import math
import os
import shlex
import stat
import statistics
import subprocess
import sys
from fractions import Fraction
from pathlib import Path
from typing import Any


CODE_BASELINE = "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9"
V4_HEAD = "b605d8cbab02d21e2de95cf7e025175af30a1877"
SEARCH_DEFINITION_V4 = "bdbf705973fa43f92ab60435bfa04dc1656fdf52c4a8687070d1185b30c809fc"
QUALIFICATION_VERSION = "live31-partial-media-qualification-v1"
QUALIFICATION_DISPOSITION = "REGENERATE_REQUIRED"
V4_HASH_STATUS = "AUDIT_INVALIDATED"
EXPECTED_REFERENCE_RESOLUTION = [3840, 2160]
EXPECTED_DOWNLOADED_COUNT = 20
EXPECTED_PENDING = {
    "0_Balance_Forest",
    "5_Conversation_Bed",
    "8_Drawing",
    "12_Guitar_Tripod",
    "15_Knitting_Total",
    "16_Night_Biking",
    "19_Parcours",
    "22_Programming_Night",
    "25_River",
    "28_Swan",
    "30_Yoga",
}

STATUS_ORDER = [
    "CORRUPT_OR_UNREADABLE",
    "METADATA_CONFLICT",
    "UNSUPPORTED_FORMAT",
    "STRUCTURAL_MISMATCH",
    "NEEDS_ALIGNMENT_CHECK",
    "NOT_QUALIFIED",
    "QUALIFIED_WITH_DOCUMENTED_VARIANCE",
    "QUALIFIED",
]


def command_version(command: str) -> str:
    result = subprocess.run(
        [command, "-version"],
        check=False,
        capture_output=True,
        text=True,
    )
    first_line = (result.stdout or result.stderr).splitlines()
    return first_line[0] if first_line else "UNAVAILABLE"


def run_json(command: list[str], timeout: int = 240) -> tuple[dict[str, Any] | None, str | None]:
    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        return None, (result.stderr or result.stdout or f"exit {result.returncode}").strip()
    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError as exc:
        return None, f"invalid JSON: {exc}"


def parse_int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def parse_float(value: Any) -> float | None:
    if value is None or value == "":
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def parse_fraction(value: Any) -> Fraction | None:
    if value is None or value in ("", "0/0", "N/A"):
        return None
    text = str(value)
    try:
        if "/" in text:
            numerator, denominator = text.split("/", 1)
            if int(denominator) == 0:
                return None
            return Fraction(int(numerator), int(denominator))
        return Fraction(text)
    except (ValueError, ZeroDivisionError):
        return None


def fraction_json(value: Fraction | None) -> str | None:
    return None if value is None else f"{value.numerator}/{value.denominator}"


def safe_component_check(path: Path, trusted_anchor: Path) -> dict[str, Any]:
    """lstat every component without resolving symlinks."""

    if not path.is_absolute():
        return {"exists": False, "safe": False, "reason": "NON_ABSOLUTE_PATH"}
    if "\x00" in str(path):
        return {"exists": False, "safe": False, "reason": "NUL_PATH"}
    try:
        path.relative_to(trusted_anchor)
    except ValueError:
        return {"exists": False, "safe": False, "reason": "OUTSIDE_TRUSTED_ANCHOR"}

    current = Path(path.anchor)
    for component in path.parts[1:]:
        if component in ("", ".", ".."):
            return {"exists": False, "safe": False, "reason": "LEXICAL_ESCAPE"}
        current /= component
        try:
            mode = os.lstat(current).st_mode
        except FileNotFoundError:
            return {"exists": False, "safe": True, "reason": "MISSING_COMPONENT"}
        except OSError as exc:
            return {"exists": False, "safe": False, "reason": f"LSTAT_ERROR:{exc}"}
        if stat.S_ISLNK(mode):
            return {"exists": True, "safe": False, "reason": "SYMLINK_COMPONENT"}

    mode = os.lstat(path).st_mode
    return {
        "exists": True,
        "safe": True,
        "regularFile": stat.S_ISREG(mode),
        "symlink": stat.S_ISLNK(mode),
        "fileType": (
            "regular"
            if stat.S_ISREG(mode)
            else "directory"
            if stat.S_ISDIR(mode)
            else "fifo"
            if stat.S_ISFIFO(mode)
            else "socket"
            if stat.S_ISSOCK(mode)
            else "device"
            if stat.S_ISCHR(mode) or stat.S_ISBLK(mode)
            else "other"
        ),
        "byteSize": os.lstat(path).st_size if stat.S_ISREG(mode) else None,
    }


def stream_value(stream: dict[str, Any], key: str) -> Any:
    value = stream.get(key)
    return None if value in (None, "N/A", "") else value


def normalize_asset_metadata(raw: dict[str, Any]) -> dict[str, Any]:
    streams = raw.get("streams", [])
    video_streams = [s for s in streams if s.get("codec_type") == "video"]
    audio_streams = [s for s in streams if s.get("codec_type") == "audio"]
    video = video_streams[0] if video_streams else {}
    format_data = raw.get("format", {})
    bits_raw = parse_int(stream_value(video, "bits_per_raw_sample"))
    bits_coded = parse_int(stream_value(video, "bits_per_coded_sample"))
    bit_values = [v for v in (bits_raw, bits_coded) if v is not None]
    bit_depth = bit_values[0] if bit_values and len(set(bit_values)) == 1 else None
    bit_depth_source = "ffprobe_bits_per_raw_or_coded_sample" if bit_depth is not None else None
    # Some valid HEVC files omit bits_per_raw_sample.  Treat the parsed
    # stream pixel format and codec profile as joint evidence; never use a
    # filename or a bare substring alone to infer depth.
    if bit_depth is None:
        pixel_format = stream_value(video, "pix_fmt")
        codec = stream_value(video, "codec_name")
        profile = stream_value(video, "profile")
        if codec == "hevc" and pixel_format == "yuv420p" and profile == "Main":
            bit_depth = 8
            bit_depth_source = "ffprobe_codec_profile_and_pixel_format"
        elif codec == "hevc" and pixel_format == "yuv420p10le" and profile == "Main 10":
            bit_depth = 10
            bit_depth_source = "ffprobe_codec_profile_and_pixel_format"
    side_data = video.get("side_data_list", [])
    display_matrix = next(
        (entry for entry in side_data if entry.get("side_data_type") == "Display Matrix"),
        None,
    )
    tags = video.get("tags", {}) or {}
    return {
        "container": format_data.get("format_name"),
        "containerLongName": format_data.get("format_long_name"),
        "videoStreamCount": len(video_streams),
        "audioStreamCount": len(audio_streams),
        "codec": stream_value(video, "codec_name"),
        "codecLongName": stream_value(video, "codec_long_name"),
        "profile": stream_value(video, "profile"),
        "level": stream_value(video, "level"),
        "width": parse_int(stream_value(video, "width")),
        "height": parse_int(stream_value(video, "height")),
        "pixelFormat": stream_value(video, "pix_fmt"),
        "reportedBitsPerRawSample": bits_raw,
        "reportedBitsPerCodedSample": bits_coded,
        "bitDepth": bit_depth,
        "bitDepthSource": bit_depth_source,
        "colorRange": stream_value(video, "color_range"),
        "colorPrimaries": stream_value(video, "color_primaries"),
        "colorTransfer": stream_value(video, "color_transfer"),
        "colorMatrix": stream_value(video, "color_space"),
        "sampleAspectRatio": stream_value(video, "sample_aspect_ratio"),
        "displayAspectRatio": stream_value(video, "display_aspect_ratio"),
        "nominalFPS": stream_value(video, "r_frame_rate"),
        "averageFPS": stream_value(video, "avg_frame_rate"),
        "timeBase": stream_value(video, "time_base"),
        "duration": parse_float(stream_value(video, "duration")),
        "frameCount": parse_int(stream_value(video, "nb_frames")),
        "startTime": parse_float(stream_value(video, "start_time")),
        "startPTS": parse_int(stream_value(video, "start_pts")),
        "rotation": tags.get("rotate") or (display_matrix or {}).get("rotation"),
        "formatDuration": parse_float(stream_value(format_data, "duration")),
        "formatStartTime": parse_float(stream_value(format_data, "start_time")),
        "formatBitRate": parse_int(stream_value(format_data, "bit_rate")),
    }


def inspect_pts(path: Path, ffprobe: str, time_base: str | None) -> tuple[dict[str, Any], str | None]:
    command = [
        ffprobe,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_packets",
        "-show_entries",
        "packet=pts,dts,pts_time,dts_time,duration,duration_time",
        "-of",
        "json",
        str(path),
    ]
    try:
        raw, error = run_json(command, timeout=300)
    except subprocess.TimeoutExpired:
        return {"status": "TIMEOUT"}, "PTS inspection timeout"
    if raw is None:
        return {"status": "FAILED"}, error
    packets = raw.get("packets", [])
    pts = [parse_int(packet.get("pts")) for packet in packets]
    pts = [value for value in pts if value is not None]
    dts = [parse_int(packet.get("dts")) for packet in packets]
    dts = [value for value in dts if value is not None]
    selected = pts or dts
    if not selected:
        return {
            "status": "UNKNOWN",
            "packetCount": len(packets),
            "ptsCount": 0,
            "usedClock": "DTS" if dts else None,
        }, None

    presentation = sorted(selected)
    presentation_deltas = [b - a for a, b in zip(presentation, presentation[1:])]
    positive_deltas = [delta for delta in presentation_deltas if delta > 0]
    median_delta = statistics.median(positive_deltas) if positive_deltas else None
    large_threshold = median_delta * 2 if median_delta is not None else None
    large_discontinuities = (
        sum(1 for delta in presentation_deltas if large_threshold is not None and delta > large_threshold)
        if large_threshold is not None
        else None
    )
    distinct_positive = sorted(set(positive_deltas))
    base = parse_fraction(time_base)
    return {
        "status": "PASS",
        "packetCount": len(packets),
        "ptsCount": len(pts),
        "usedClock": "PTS" if pts else "DTS",
        "packetOrderMonotonic": all(a <= b for a, b in zip(selected, selected[1:])),
        "presentationOrderMonotonic": all(a <= b for a, b in zip(presentation, presentation[1:])),
        "duplicateCount": len(selected) - len(set(selected)),
        "negativeTimestampCount": sum(1 for value in selected if value < 0),
        "firstTimestamp": presentation[0],
        "lastTimestamp": presentation[-1],
        "medianPositiveDeltaTicks": median_delta,
        "distinctPositiveDeltaTicks": distinct_positive[:32],
        "distinctPositiveDeltaCount": len(distinct_positive),
        "largeDiscontinuityCount": large_discontinuities,
        "vfrLike": len(distinct_positive) > 1,
        "timeBase": time_base,
        "firstTimestampSeconds": float(presentation[0] * base) if base else None,
        "lastTimestampSeconds": float(presentation[-1] * base) if base else None,
    }, None


def structural_decode(path: Path, duration: float | None, ffmpeg: str) -> dict[str, Any]:
    if duration is None or not math.isfinite(duration) or duration <= 0:
        positions = [0.0]
    else:
        positions = [0.0, duration * 0.25, duration * 0.5, duration * 0.75, max(0.0, duration - 0.5)]
    unique_positions: list[float] = []
    for position in positions:
        rounded = round(position, 3)
        if rounded not in unique_positions:
            unique_positions.append(rounded)

    probes = []
    for position in unique_positions:
        command = [
            ffmpeg,
            "-v",
            "error",
            "-nostdin",
            "-ss",
            f"{position:.3f}",
            "-i",
            str(path),
            "-map",
            "0:v:0",
            "-frames:v",
            "1",
            "-f",
            "null",
            "-",
        ]
        try:
            result = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=180,
            )
            probes.append(
                {
                    "positionSeconds": position,
                    "success": result.returncode == 0,
                    "exitCode": result.returncode,
                    "stderr": (result.stderr or "")[:500],
                }
            )
        except subprocess.TimeoutExpired as exc:
            probes.append(
                {
                    "positionSeconds": position,
                    "success": False,
                    "exitCode": None,
                    "stderr": f"timeout: {exc}",
                }
            )
    return {
        "mode": "STRUCTURAL_DECODE_ONLY",
        "fixedPositionRule": "0%, 25%, 50%, 75%, max(duration-0.5s)",
        "probes": probes,
        "allSuccessful": all(probe["success"] for probe in probes),
    }


def inspect_asset(
    path: Path,
    relative_path: str,
    role: str,
    approved_root: Path,
    trusted_anchor: Path,
    ffprobe: str,
    ffmpeg: str,
) -> dict[str, Any]:
    resolution = safe_component_check(path, trusted_anchor)
    asset: dict[str, Any] = {
        "role": role,
        "relativePath": relative_path,
        "approvedDevelopmentRoot": str(approved_root),
        "absolutePath": str(path),
        "regularFile": bool(resolution.get("regularFile", False)),
        "symlink": bool(resolution.get("symlink", False)),
        "filesystem": resolution,
        "byteSize": resolution.get("byteSize"),
        "tool": "ffprobe",
        "metadataStatus": "NOT_RUN",
        "rawMetadata": None,
        "normalizedMetadata": None,
        "ptsStructure": None,
        "structuralDecode": None,
        "issues": [],
    }
    if not resolution.get("exists") or not resolution.get("safe"):
        asset["metadataStatus"] = "NOT_AVAILABLE"
        asset["issues"].append(resolution.get("reason", "MISSING_OR_UNSAFE_PATH"))
        return asset
    if not resolution.get("regularFile") or resolution.get("symlink"):
        asset["metadataStatus"] = "NOT_AVAILABLE"
        asset["issues"].append("NOT_REGULAR_NON_SYMLINK_FILE")
        return asset

    command = [
        ffprobe,
        "-v",
        "error",
        "-show_streams",
        "-show_format",
        "-of",
        "json",
        str(path),
    ]
    try:
        raw, error = run_json(command, timeout=300)
    except subprocess.TimeoutExpired:
        raw, error = None, "metadata probe timeout"
    if raw is None:
        asset["metadataStatus"] = "FAILED"
        asset["issues"].append(error or "FFPROBE_FAILED")
        return asset

    normalized = normalize_asset_metadata(raw)
    asset["metadataStatus"] = "PASS"
    asset["rawMetadata"] = raw
    asset["normalizedMetadata"] = normalized
    try:
        pts, pts_error = inspect_pts(path, ffprobe, normalized.get("timeBase"))
    except subprocess.TimeoutExpired:
        pts, pts_error = {"status": "TIMEOUT"}, "PTS inspection timeout"
    asset["ptsStructure"] = pts
    if pts_error:
        asset["issues"].append(f"PTS_INSPECTION:{pts_error}")
    asset["structuralDecode"] = structural_decode(path, normalized.get("duration"), ffmpeg)
    if not asset["structuralDecode"]["allSuccessful"]:
        asset["issues"].append("STRUCTURAL_DECODE_FAILURE")
    return asset


def add_issue(issues: list[dict[str, Any]], code: str, detail: str, severity: str = "review") -> None:
    issues.append({"code": code, "detail": detail, "severity": severity})


def qualify_asset(asset: dict[str, Any], role: str) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    if not asset["regularFile"] or asset["symlink"]:
        add_issue(issues, "CORRUPT_OR_UNREADABLE", "not a regular non-symlink file", "reject")
        return issues
    if asset["metadataStatus"] != "PASS" or asset["normalizedMetadata"] is None:
        add_issue(issues, "CORRUPT_OR_UNREADABLE", "ffprobe metadata unavailable", "reject")
        return issues
    metadata = asset["normalizedMetadata"]
    if metadata["videoStreamCount"] != 1:
        add_issue(issues, "STRUCTURAL_MISMATCH", "expected exactly one video stream", "reject")
    if metadata["container"] is None or "mp4" not in metadata["container"]:
        add_issue(issues, "UNSUPPORTED_FORMAT", f"unsupported container {metadata['container']!r}", "reject")
    if metadata["width"] != EXPECTED_REFERENCE_RESOLUTION[0] or metadata["height"] != EXPECTED_REFERENCE_RESOLUTION[1]:
        add_issue(issues, "STRUCTURAL_MISMATCH", "not the official 3840x2160 reference resolution", "reject")
    if metadata["codec"] not in {"hevc", "h265"}:
        add_issue(issues, "UNSUPPORTED_FORMAT", f"unexpected {role} codec {metadata['codec']!r}", "reject")
    expected_bits = 8 if role == "SDR" else 10
    if metadata["bitDepth"] is None:
        add_issue(issues, "NOT_QUALIFIED", "MISSING_METADATA: parsed bit depth unavailable", "reject")
    elif metadata["bitDepth"] != expected_bits:
        add_issue(issues, "UNSUPPORTED_FORMAT", f"expected {expected_bits}-bit, got {metadata['bitDepth']}", "reject")

    transfer = metadata["colorTransfer"]
    primaries = metadata["colorPrimaries"]
    matrix = metadata["colorMatrix"]
    if role == "SDR":
        if transfer in {"smpte2084", "arib-std-b67"}:
            add_issue(issues, "METADATA_CONFLICT", f"SDR is tagged {transfer}", "reject")
        elif transfer is None:
            add_issue(issues, "NOT_QUALIFIED", "MISSING_METADATA: SDR transfer", "reject")
        elif transfer not in {"bt709", "iec61966-2-1"}:
            add_issue(issues, "METADATA_CONFLICT", f"unsupported SDR transfer {transfer}", "reject")
        if primaries is None or matrix is None:
            add_issue(issues, "NOT_QUALIFIED", "MISSING_METADATA: SDR primaries or matrix", "reject")
        if primaries not in {None, "bt709"} or matrix not in {None, "bt709"}:
            add_issue(issues, "METADATA_CONFLICT", "SDR primaries/matrix conflict", "reject")
        if metadata["profile"] not in {None, "Main"}:
            add_issue(issues, "PROFILE_VARIANCE", f"SDR codec profile {metadata['profile']!r}")
    else:
        if transfer is None or primaries is None or matrix is None:
            add_issue(issues, "NOT_QUALIFIED", "MISSING_METADATA: HDR transfer/primaries/matrix", "reject")
        if transfer not in {None, "smpte2084"} or primaries not in {None, "bt2020"} or matrix not in {None, "bt2020nc"}:
            add_issue(issues, "METADATA_CONFLICT", "HDR10 color metadata conflict", "reject")
        if metadata["profile"] not in {None, "Main 10"}:
            add_issue(issues, "PROFILE_VARIANCE", f"HDR10 codec profile {metadata['profile']!r}")

    if metadata["colorRange"] in {None, "unknown"}:
        add_issue(issues, "RANGE_UNSPECIFIED", "color range is unspecified")
    elif metadata["colorRange"] not in {"tv", "pc"}:
        add_issue(issues, "METADATA_CONFLICT", f"invalid color range {metadata['colorRange']!r}", "reject")
    if asset["structuralDecode"] is None or not asset["structuralDecode"]["allSuccessful"]:
        add_issue(issues, "CORRUPT_OR_UNREADABLE", "fixed structural decode probe failed", "reject")
    pts = asset["ptsStructure"] or {}
    if pts.get("status") not in {"PASS", "UNKNOWN"}:
        add_issue(issues, "CORRUPT_OR_UNREADABLE", "PTS structural inspection failed", "reject")
    if pts.get("status") == "PASS" and (
            not pts.get("presentationOrderMonotonic", True)
            or pts.get("duplicateCount", 0) > 0
            or pts.get("negativeTimestampCount", 0) > 0
            or (pts.get("largeDiscontinuityCount") or 0) > 0
    ):
        add_issue(issues, "PTS_VARIANCE", "non-ideal PTS structure requires pair alignment review")
    return issues


def duration_value(metadata: dict[str, Any]) -> float | None:
    return metadata.get("duration") if metadata.get("duration") is not None else metadata.get("formatDuration")


def fps_fraction(metadata: dict[str, Any]) -> Fraction | None:
    return parse_fraction(metadata.get("averageFPS")) or parse_fraction(metadata.get("nominalFPS"))


def pair_qualification(sdr: dict[str, Any], hdr: dict[str, Any]) -> tuple[str, list[dict[str, Any]], dict[str, Any]]:
    issues = qualify_asset(sdr, "SDR") + qualify_asset(hdr, "HDR10")
    sdr_meta = sdr.get("normalizedMetadata") or {}
    hdr_meta = hdr.get("normalizedMetadata") or {}
    compatibility: dict[str, Any] = {
        "resolution": "UNKNOWN",
        "aspect": "UNKNOWN",
        "duration": "UNKNOWN",
        "fps": "UNKNOWN",
        "pts": "UNKNOWN",
    }

    if sdr_meta.get("width") == hdr_meta.get("width") and sdr_meta.get("height") == hdr_meta.get("height"):
        compatibility["resolution"] = "EXACT_MATCH"
    else:
        compatibility["resolution"] = "STRUCTURAL_MISMATCH"
        add_issue(issues, "STRUCTURAL_MISMATCH", "SDR/HDR coded dimensions differ", "reject")

    sdr_sar = parse_fraction(sdr_meta.get("sampleAspectRatio"))
    hdr_sar = parse_fraction(hdr_meta.get("sampleAspectRatio"))
    if sdr_sar == hdr_sar and sdr_meta.get("displayAspectRatio") == hdr_meta.get("displayAspectRatio"):
        compatibility["aspect"] = "ASPECT_MATCH"
    else:
        compatibility["aspect"] = "ASPECT_MISMATCH"
        add_issue(issues, "STRUCTURAL_MISMATCH", "SDR/HDR SAR or DAR differs", "reject")
    if sdr_meta.get("rotation") != hdr_meta.get("rotation"):
        add_issue(issues, "STRUCTURAL_MISMATCH", "SDR/HDR orientation differs", "reject")

    sdr_duration = duration_value(sdr_meta)
    hdr_duration = duration_value(hdr_meta)
    if sdr_duration is not None and hdr_duration is not None:
        absolute = abs(sdr_duration - hdr_duration)
        relative = absolute / max(sdr_duration, hdr_duration, 1e-9)
        compatibility["duration"] = {
            "durationSDR": sdr_duration,
            "durationHDR": hdr_duration,
            "absoluteDifference": absolute,
            "relativeDifference": relative,
            "status": "COMPATIBLE" if absolute <= 0.25 or relative <= 0.005 else "NEEDS_ALIGNMENT_CHECK",
        }
        if compatibility["duration"]["status"] != "COMPATIBLE":
            add_issue(issues, "NEEDS_ALIGNMENT_CHECK", "duration difference exceeds fixed structural tolerance")
    else:
        compatibility["duration"] = {"status": "UNKNOWN"}
        add_issue(issues, "NOT_QUALIFIED", "MISSING_METADATA: duration", "reject")

    sdr_fps = fps_fraction(sdr_meta)
    hdr_fps = fps_fraction(hdr_meta)
    if sdr_fps is not None and hdr_fps is not None:
        fps_difference = abs(float(sdr_fps - hdr_fps))
        compatibility["fps"] = {
            "fpsSDR": fraction_json(sdr_fps),
            "fpsHDR": fraction_json(hdr_fps),
            "difference": fps_difference,
            "status": "EXACT_MATCH" if sdr_fps == hdr_fps else "COMPATIBLE_WITH_ALIGNMENT" if fps_difference <= 0.01 else "NEEDS_ALIGNMENT_CHECK",
        }
        if compatibility["fps"]["status"] == "NEEDS_ALIGNMENT_CHECK":
            add_issue(issues, "NEEDS_ALIGNMENT_CHECK", "SDR/HDR frame rates differ")
    else:
        compatibility["fps"] = {"status": "UNKNOWN"}
        add_issue(issues, "NOT_QUALIFIED", "MISSING_METADATA: frame rate", "reject")

    sdr_pts = sdr.get("ptsStructure") or {}
    hdr_pts = hdr.get("ptsStructure") or {}
    if sdr_pts.get("status") == "PASS" and hdr_pts.get("status") == "PASS":
        structurally_consistent = (
            sdr_pts.get("presentationOrderMonotonic")
            and hdr_pts.get("presentationOrderMonotonic")
            and sdr_pts.get("duplicateCount", 0) == 0
            and hdr_pts.get("duplicateCount", 0) == 0
            and sdr_pts.get("negativeTimestampCount", 0) == 0
            and hdr_pts.get("negativeTimestampCount", 0) == 0
            and sdr_pts.get("vfrLike") == hdr_pts.get("vfrLike")
        )
        compatibility["pts"] = "NOT_PROVEN"
        compatibility["ptsStructuralEvidence"] = (
            "CONSISTENT_PRESENTATION_TIMESTAMP_STRUCTURE"
            if structurally_consistent
            else "STRUCTURAL_TIMESTAMP_VARIANCE"
        )
    else:
        compatibility["pts"] = "NOT_PROVEN"
        compatibility["ptsStructuralEvidence"] = "INSUFFICIENT_TIMESTAMP_EVIDENCE"

    codes = {issue["code"] for issue in issues}
    if "CORRUPT_OR_UNREADABLE" in codes:
        status = "CORRUPT_OR_UNREADABLE"
    elif "METADATA_CONFLICT" in codes:
        status = "METADATA_CONFLICT"
    elif "UNSUPPORTED_FORMAT" in codes:
        status = "UNSUPPORTED_FORMAT"
    elif "STRUCTURAL_MISMATCH" in codes:
        status = "STRUCTURAL_MISMATCH"
    elif "NEEDS_ALIGNMENT_CHECK" in codes or "PTS_VARIANCE" in codes:
        status = "NEEDS_ALIGNMENT_CHECK"
    elif "NOT_QUALIFIED" in codes:
        status = "NOT_QUALIFIED"
    elif any(issue["code"].endswith("VARIANCE") or issue["code"] in {"PROFILE_VARIANCE", "RANGE_UNSPECIFIED"} for issue in issues):
        status = "QUALIFIED_WITH_DOCUMENTED_VARIANCE"
    else:
        status = "QUALIFIED"
    return status, issues, compatibility


def read_inputs(manifest_path: Path, provenance_path: Path) -> tuple[list[dict[str, str]], dict[str, dict[str, Any]]]:
    with manifest_path.open(newline="") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != 31:
        raise RuntimeError(f"expected 31 manifest rows, got {len(rows)}")
    provenance = json.loads(provenance_path.read_text())
    mapping_by_local = {mapping["canonicalLocalName"]: mapping for mapping in provenance["mappings"]}
    if len(mapping_by_local) != 31:
        raise RuntimeError("provenance mapping is not 31-to-31")
    return rows, mapping_by_local


def build_document(artifact: dict[str, Any]) -> str:
    summary = artifact["summary"]
    lines = [
        "# LIVE31 Partial Media Qualification",
        "",
        "This is structural/metadata qualification only. No SHA-256 content hashing,",
        "quality objective, candidate scoring, Tune, Validation, or Frozen evaluation",
        "was performed.",
        "",
        "## Scope",
        "",
        f"- Code/V4 head: `{artifact['v4SemanticHead']}`",
        f"- Correctness baseline: `{artifact['correctnessBaseline']}`",
        f"- SearchDefinitionHashV4: `{artifact['searchDefinitionHashV4']}`",
        f"- Qualification version: `{artifact['qualificationVersion']}`",
        f"- Downloaded pairs: {summary['downloadedPairCount']} / 20",
        f"- Acquisition-pending contents: {summary['acquisitionPendingCount']} / 11",
        "- Approved root: `/Volumes/game/LIVE31-development-acquisition/references`",
        "",
        "## Result",
        "",
        f"- Exact downloaded pairs resolved: {summary['exactDownloadedPairsResolved']} / 20",
        f"- Eligible independent families for promotion: {summary['eligibleIndependentFamilies']}",
        f"- Qualification disposition: `{artifact['qualificationDisposition']}`",
        f"- Exact temporal proof: `{artifact['exactTemporalStatus']}`",
        f"- V4 SearchDefinitionHash status: `{artifact['searchDefinitionHashV4Status']}`",
        f"- Structural decode failures: {summary['structuralDecodeFailureCount']}",
        f"- Media objective metrics: NO",
        f"- Frozen media accessed: NO",
        f"- New protected-path exposure: NO",
        f"- Objective evaluations: 0",
        "",
        "| Status | Count |",
        "|---|---:|",
    ]
    for status in [
        "QUALIFIED",
        "QUALIFIED_WITH_DOCUMENTED_VARIANCE",
        "NEEDS_ALIGNMENT_CHECK",
        "METADATA_CONFLICT",
        "STRUCTURAL_MISMATCH",
        "UNSUPPORTED_FORMAT",
        "CORRUPT_OR_UNREADABLE",
        "NOT_QUALIFIED",
    ]:
        lines.append(f"| `{status}` | {summary['statusCounts'].get(status, 0)} |")
    lines.extend(["", "## Downloaded pair evidence", ""])
    lines.append("| Content | SDR | HDR10 | Status | Resolution | Duration | FPS | PTS |")
    lines.append("|---|---|---|---|---|---|---|---|")
    for pair in artifact["downloadedPairs"]:
        compat = pair["compatibility"]
        duration = compat["duration"]
        duration_text = duration.get("status", "UNKNOWN") if isinstance(duration, dict) else str(duration)
        fps = compat["fps"]
        fps_text = fps.get("status", "UNKNOWN") if isinstance(fps, dict) else str(fps)
        lines.append(
            f"| `{pair['canonicalLocalName']}` | `{pair['sdr']['relativePath']}` | "
            f"`{pair['hdr10']['relativePath']}` | `{pair['status']}` | "
            f"`{compat['resolution']}` | `{duration_text}` | `{fps_text}` | `{compat['pts']}` |"
        )
    lines.extend(["", "## Acquisition pending", ""])
    for item in artifact["acquisitionPending"]:
        lines.append(f"- `{item['canonicalLocalName']}` — `ACQUISITION_PENDING` ({item['reason']})")
    lines.extend(
        [
            "",
            "## Metadata summaries",
            "",
            "The following summaries are counts of observed ffprobe normalized fields;",
            "they are not quality metrics and were not used to tune V4 semantics.",
            "",
            "```json",
            json.dumps(artifact["metadataSummary"], indent=2, sort_keys=True),
            "```",
            "",
            "## Tooling and rules",
            "",
            f"- ffprobe: `{artifact['tools']['ffprobeVersion']}`",
            f"- ffmpeg: `{artifact['tools']['ffmpegVersion']}`",
            "- Metadata source: ffprobe stream/format JSON; raw output is retained in the JSON artifact.",
            "- Structural decode: fixed `0%, 25%, 50%, 75%, max(duration-0.5s)` positions; decoded pixels were not inspected.",
            "- Exact temporal match is NOT PROVEN by metadata/PTS summaries alone; the 20 pair labels require regeneration.",
            "- Exact content hashing: NOT RUN in this phase; acquisition-manifest declared hashes were not recomputed.",
            "- V4 thresholds, matcher semantics, metric constants, gates, and ranking were not changed.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--provenance", type=Path, required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--doc", type=Path, required=True)
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    args = parser.parse_args()

    rows, mapping_by_local = read_inputs(args.manifest, args.provenance)
    trusted_anchor = Path("/Volumes/game")
    root_check = safe_component_check(args.root, trusted_anchor)
    if (
        not root_check.get("exists")
        or not root_check.get("safe")
        or root_check.get("fileType") != "directory"
    ):
        raise RuntimeError(f"approved development root is unavailable or unsafe: {root_check}")

    downloaded = [row for row in rows if row["SDR_download_succeeded"] == "True" and row["HDR10_download_succeeded"] == "True"]
    pending = [row for row in rows if row not in downloaded]
    if len(downloaded) != EXPECTED_DOWNLOADED_COUNT:
        raise RuntimeError(f"expected 20 downloaded pairs, got {len(downloaded)}")
    actual_pending = {row["canonical_source"] for row in pending}
    if actual_pending != EXPECTED_PENDING:
        raise RuntimeError(f"pending set differs from pinned scope: {sorted(actual_pending)}")

    generated_at = dt.datetime.now(dt.timezone.utc).isoformat()
    pairs: list[dict[str, Any]] = []
    status_counts = {status: 0 for status in STATUS_ORDER}
    decode_failures = 0
    metadata_summary: dict[str, dict[str, dict[str, int]]] = {"SDR": {}, "HDR10": {}}

    def count_metadata(role: str, metadata: dict[str, Any]) -> None:
        fields = {
            "container": metadata.get("container"),
            "codec": metadata.get("codec"),
            "profile": metadata.get("profile"),
            "resolution": f"{metadata.get('width')}x{metadata.get('height')}",
            "pixelFormat": metadata.get("pixelFormat"),
            "bitDepth": str(metadata.get("bitDepth")),
            "colorPrimaries": metadata.get("colorPrimaries"),
            "colorTransfer": metadata.get("colorTransfer"),
            "colorMatrix": metadata.get("colorMatrix"),
            "colorRange": metadata.get("colorRange"),
            "nominalFPS": metadata.get("nominalFPS"),
            "averageFPS": metadata.get("averageFPS"),
            "timeBase": metadata.get("timeBase"),
        }
        for field, value in fields.items():
            key = "UNKNOWN" if value is None else str(value)
            metadata_summary[role].setdefault(field, {})[key] = metadata_summary[role].setdefault(field, {}).get(key, 0) + 1

    for row in downloaded:
        local_name = row["canonical_source"]
        mapping = mapping_by_local.get(local_name)
        if mapping is None:
            raise RuntimeError(f"no proven LIVE mapping for {local_name}")
        sdr_relative = row["SDR_reference_filename"]
        hdr_relative = row["HDR10_reference_filename"]
        sdr_path = args.root / sdr_relative
        hdr_path = args.root / hdr_relative
        sdr = inspect_asset(sdr_path, sdr_relative, "SDR", args.root, trusted_anchor, args.ffprobe, args.ffmpeg)
        hdr = inspect_asset(hdr_path, hdr_relative, "HDR10", args.root, trusted_anchor, args.ffprobe, args.ffmpeg)
        status, issues, compatibility = pair_qualification(sdr, hdr)
        sdr["qualificationIssues"] = qualify_asset(sdr, "SDR")
        hdr["qualificationIssues"] = qualify_asset(hdr, "HDR10")
        if sdr.get("normalizedMetadata"):
            count_metadata("SDR", sdr["normalizedMetadata"])
        if hdr.get("normalizedMetadata"):
            count_metadata("HDR10", hdr["normalizedMetadata"])
        if sdr.get("structuralDecode") and not sdr["structuralDecode"]["allSuccessful"]:
            decode_failures += 1
        if hdr.get("structuralDecode") and not hdr["structuralDecode"]["allSuccessful"]:
            decode_failures += 1
        status_counts[status] = status_counts.get(status, 0) + 1
        pairs.append(
            {
                "canonicalLocalName": local_name,
                "canonicalOfficialName": mapping["canonicalOfficialName"],
                "sourceMasterId": mapping["sourceMasterId"],
                "localGroupId": mapping["localGroupId"],
                "pairProvenance": {
                    "mappingStatus": mapping["mappingStatus"],
                    "pairRelationship": mapping["pairRelationship"],
                    "officialProvenanceURL": mapping["officialSourceEvidence"]["provenanceURL"],
                    "officialRepositoryCommit": mapping["officialSourceEvidence"]["repositoryCommit"],
                    "acquisitionManifestProvenance": row["provenance"],
                    "acquisitionManifestDeclaredSHA256": "PRESENT_NOT_RECOMPUTED",
                },
                "sdr": sdr,
                "hdr10": hdr,
                "status": status,
                "issues": issues,
                "compatibility": compatibility,
            }
        )

    pending_items = []
    for row in pending:
        pending_items.append(
            {
                "canonicalLocalName": row["canonical_source"],
                "canonicalOfficialName": mapping_by_local[row["canonical_source"]]["canonicalOfficialName"],
                "sourceMasterId": mapping_by_local[row["canonical_source"]]["sourceMasterId"],
                "status": "ACQUISITION_PENDING",
                "reason": "reference SDR/HDR10 pair not downloaded; no path probe performed",
            }
        )

    artifact = {
        "artifactKind": "LIVE31_PARTIAL_MEDIA_QUALIFICATION",
        "artifactVersion": 1,
        "qualificationVersion": QUALIFICATION_VERSION,
        "generatedAt": generated_at,
        "correctnessBaseline": CODE_BASELINE,
        "v4SemanticHead": V4_HEAD,
        "searchDefinitionHashV4": SEARCH_DEFINITION_V4,
        "searchDefinitionHashV4Status": V4_HASH_STATUS,
        "qualificationDisposition": QUALIFICATION_DISPOSITION,
        "qualificationEvidenceStatus": "RETAINED_STRUCTURAL_METADATA_AND_DECODE_ONLY",
        "exactTemporalStatus": "NOT_PROVEN",
        "historicalPrereRegistrations": {
            "V1": "RETIRED_INVALIDATED",
            "V2": "AUDIT_INVALIDATED",
            "V3": "AUDIT_INVALIDATED",
            "V4": "AUDIT_INVALIDATED",
        },
        "scope": {
            "canonicalContents": 31,
            "downloadedPairs": EXPECTED_DOWNLOADED_COUNT,
            "acquisitionPending": len(pending_items),
            "qualityMetricsRun": False,
            "contentHashingRun": False,
            "tuneRun": False,
            "validationRun": False,
            "frozenEvaluationRun": False,
            "objectiveEvaluations": 0,
            "protectedDataAccessed": False,
            "corpusPromotionAllowed": False,
        },
        "approvedDevelopmentRoot": str(args.root),
        "inputManifest": str(args.manifest),
        "inputProvenanceArtifact": str(args.provenance),
        "tools": {
            "ffprobePath": args.ffprobe,
            "ffprobeVersion": command_version(args.ffprobe),
            "ffmpegPath": args.ffmpeg,
            "ffmpegVersion": command_version(args.ffmpeg),
            "metadataCommandSemantics": "ffprobe -v error -show_streams -show_format -of json exact-path",
            "ptsCommandSemantics": "ffprobe -v error -select_streams v:0 -show_packets exact-path; summary only",
            "decodeCommandSemantics": "ffmpeg -v error -nostdin -ss fixed-position -i exact-path -map 0:v:0 -frames:v 1 -f null -",
        },
        "qualificationRules": {
            "referenceResolution": "3840x2160 from acquisition report official FR reference",
            "sdr": "one MP4 video stream, HEVC Main, parsed 8-bit from codec/profile/pixel-format evidence, BT.709 or sRGB-compatible transfer, no PQ/HLG conflict",
            "hdr10": "one MP4 video stream, HEVC, parsed 10-bit, PQ transfer, BT.2020 primaries/matrix",
            "durationToleranceSeconds": 0.25,
            "durationRelativeTolerance": 0.005,
            "decodeProbePositions": "0%, 25%, 50%, 75%, max(duration-0.5s)",
            "noQualityDecision": True,
            "noV4SemanticMutation": True,
        },
        "metadataSummary": metadata_summary,
        "downloadedPairs": pairs,
        "acquisitionPending": pending_items,
        "summary": {
            "canonicalContents": 31,
            "downloadedPairCount": len(pairs),
            "exactDownloadedPairsResolved": sum(
                1
                for pair in pairs
                if pair["sdr"]["regularFile"] and not pair["sdr"]["symlink"] and pair["hdr10"]["regularFile"] and not pair["hdr10"]["symlink"]
            ),
            "acquisitionPendingCount": len(pending_items),
            "statusCounts": status_counts,
            "eligibleIndependentFamilies": 0,
            "promotionBlockedReason": "REGENERATE_REQUIRED_AND_EXACT_TEMPORAL_NOT_PROVEN",
            "structuralDecodeFailureCount": decode_failures,
            "qualityBasedSelection": False,
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
    args.doc.parent.mkdir(parents=True, exist_ok=True)
    args.doc.write_text(build_document(artifact))
    print(json.dumps(artifact["summary"], indent=2, sort_keys=True))
    print("media objective metrics: NO")
    print("content SHA-256 hashing: NOT RUN")
    print("protected data accessed: NO")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"qualification failed closed: {exc}", file=sys.stderr)
        raise SystemExit(2)
