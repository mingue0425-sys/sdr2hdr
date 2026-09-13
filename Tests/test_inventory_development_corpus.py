#!/usr/bin/env python3
"""Focused safety and determinism tests for the development inventory tool."""

from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path
from typing import List, Optional


SCRIPT_PATH = Path(__file__).with_name("inventory_development_corpus.py")
SPEC = importlib.util.spec_from_file_location("development_inventory", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def assert_rejected(root_relative: str, excluded: Optional[List[str]] = None) -> None:
    try:
        MODULE.validate_root_locator(root_relative, excluded or [])
    except MODULE.InventoryError:
        return
    raise AssertionError(f"root should be rejected: {root_relative}")


def main() -> int:
    for broad_root in (".", "data_video", "data_video/real_media"):
        assert_rejected(broad_root)
    for protected_root in ("data_video/Frozen", "data_video/virgin_candidates", "data_video/holdout"):
        assert_rejected(protected_root)
    assert_rejected("data_video/../outside")
    assert_rejected("/Volumes/game/sdr2hdr/data_video/video1")
    assert_rejected("data_video/video3", ["data_video/video3"])

    normalized = MODULE.normalize_repo_locator(
        "/Volumes/game/sdr2hdr/data_video/LIVE Paired Comparison HDR vs. SDR Database/open-sourced_SDR/22_Programming_Night_SDR_3840x2160_15000k.mp4"
    )
    assert normalized == (
        "data_video/LIVE Paired Comparison HDR vs. SDR Database/open-sourced_SDR/"
        "22_Programming_Night_SDR_3840x2160_15000k.mp4"
    )
    assert MODULE.live_variant_key(
        "22_Programming_Night_HDR10_3840x2160_15000k.mp4"
    ) == MODULE.live_variant_key(
        "22_Programming_Night_SDR_3840x2160_15000k.mp4"
    )
    assert MODULE.live_family_key("22_Programming_Night_HDR10_3840x2160_15000k.mp4") == "22_programming_night"

    with tempfile.TemporaryDirectory() as temporary:
        materialization_root = Path(temporary)
        safe_root = materialization_root / "data_video" / "safe"
        safe_root.mkdir(parents=True)
        (safe_root / "fixture.mp4").write_bytes(b"fixture")
        (safe_root / "notes.txt").write_text("metadata", encoding="utf-8")
        records = MODULE.walk_approved_root(materialization_root, "data_video/safe", [])
        assert [record["relativePath"] for record in records] == ["data_video/safe/fixture.mp4"]
        symlink_target = materialization_root / "outside.mp4"
        symlink_target.write_bytes(b"outside")
        (safe_root / "linked.mp4").symlink_to(symlink_target)
        try:
            MODULE.walk_approved_root(materialization_root, "data_video/safe", [])
        except MODULE.InventoryError:
            pass
        else:
            raise AssertionError("symlink media candidate should be rejected")

    print("development corpus inventory tests: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
