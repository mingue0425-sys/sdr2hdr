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
    assert_rejected(r"C:\data_video\video1")
    assert_rejected(r"\\server\share\video1")
    assert_rejected("data_video/safe\x00injection")
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

        def assert_walk_rejected(root_relative: str, message: str) -> None:
            try:
                MODULE.walk_approved_root(materialization_root, root_relative, [])
            except MODULE.InventoryError:
                return
            raise AssertionError(message)

        # Every case below is rejected by lstat of the lexical component chain
        # before os.walk can reach the link target. The target files are only
        # fixtures; no target directory is enumerated.
        direct_target = materialization_root / "data_video" / "direct-target"
        direct_target.mkdir()
        (direct_target / "target.mp4").write_bytes(b"target")
        direct_root = materialization_root / "data_video" / "direct-link"
        direct_root.symlink_to(direct_target, target_is_directory=True)
        assert_walk_rejected("data_video/direct-link", "direct symlink root was traversed")

        intermediate_target = materialization_root / "data_video" / "intermediate-target"
        intermediate_target.mkdir()
        (intermediate_target / "leaf").mkdir()
        (intermediate_target / "leaf" / "target.mp4").write_bytes(b"target")
        intermediate_link = materialization_root / "data_video" / "safe" / "intermediate"
        intermediate_link.symlink_to(intermediate_target, target_is_directory=True)
        assert_walk_rejected(
            "data_video/safe/intermediate/leaf",
            "intermediate symlink component was traversed",
        )

        chain_target = materialization_root / "data_video" / "chain-target"
        chain_target.mkdir()
        chain_a = materialization_root / "data_video" / "chain-a"
        chain_b = materialization_root / "data_video" / "chain-b"
        chain_a.symlink_to(chain_b, target_is_directory=True)
        chain_b.symlink_to(chain_target, target_is_directory=True)
        assert_walk_rejected("data_video/chain-a", "nested symlink chain was traversed")

        protected_target = materialization_root / "data_video" / "Frozen"
        protected_target.mkdir()
        (protected_target / "protected.mp4").write_bytes(b"protected")
        (materialization_root / "data_video" / "protected-link").symlink_to(
            protected_target, target_is_directory=True
        )
        assert_walk_rejected("data_video/protected-link", "symlink to protected root was traversed")

        parent_target = materialization_root / "data_video"
        (materialization_root / "data_video" / "parent-link").symlink_to(
            parent_target, target_is_directory=True
        )
        assert_walk_rejected(
            "data_video/parent-link/safe",
            "symlink to parent of protected root was traversed",
        )

        repository_link = materialization_root / "data_video" / "repository-link"
        repository_link.symlink_to(materialization_root, target_is_directory=True)
        assert_walk_rejected(
            "data_video/repository-link/data_video/safe",
            "symlink to repository root was traversed",
        )

        materialization_link = Path(temporary).with_name(Path(temporary).name + "-link")
        materialization_link.symlink_to(materialization_root, target_is_directory=True)
        try:
            try:
                MODULE.validate_no_symlink_components(materialization_link)
            except MODULE.InventoryError:
                pass
            else:
                raise AssertionError("symlink materialization root was accepted")
        finally:
            materialization_link.unlink()

        assert_rejected("data_video/safe/../../outside")
        assert_rejected("/absolute/injection")

    print("development corpus inventory tests: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
