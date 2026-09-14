#!/usr/bin/env python3
"""Synthetic, media-free tests for LIVE31 qualification trust boundaries."""

from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Tests/qualify_live31_partial_media.py"
SPEC = importlib.util.spec_from_file_location("live31_qualification", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"LIVE31 qualification guards: FAIL: {message}")


def pts(sequence: list[int], time_base: str) -> dict[str, object]:
    return {
        "status": "PASS",
        "presentationTimestamps": sequence,
        "timeBase": time_base,
        "presentationOrderMonotonic": all(a <= b for a, b in zip(sequence, sequence[1:])),
        "duplicateCount": len(sequence) - len(set(sequence)),
        "negativeTimestampCount": sum(value < 0 for value in sequence),
    }


def test_temporal_matrix() -> None:
    exact, _ = MODULE.compare_temporal_sequences(
        pts([0, 1001, 2002], "1/60000"),
        pts([0, 1, 2], "1001/60000"),
    )
    require(exact == "EXACT_TEMPORAL_MATCH", "different rational timebases rejected despite equal timeline")

    mutations = (
        (pts([0, 1001], "1/60000"), pts([0, 1001, 2002], "1/60000"), "frame count mismatch"),
        (pts([0, 1001, 2002], "1/60000"), pts([0, 1000, 2000], "1/60000"), "cadence mismatch"),
        (pts([0, 1001, 2002], "1/60000"), pts([1, 1002, 2003], "1/60000"), "shifted timestamp"),
        (pts([0, 1001, 1001], "1/60000"), pts([0, 1001, 2002], "1/60000"), "duplicate timestamp"),
        (pts([0, 2002, 1001], "1/60000"), pts([0, 1001, 2002], "1/60000"), "non-monotonic presentation sequence"),
        (pts([-1, 1000, 2001], "1/60000"), pts([0, 1001, 2002], "1/60000"), "negative timestamp"),
    )
    for left, right, label in mutations:
        result, _ = MODULE.compare_temporal_sequences(left, right)
        require(result != "EXACT_TEMPORAL_MATCH", f"false exact match: {label}")


def test_path_matrix() -> None:
    with tempfile.TemporaryDirectory(prefix="live31-path-guards-") as directory:
        # Resolve only the temporary fixture's trusted anchor; production
        # qualification never resolves an untrusted media path.
        base = Path(directory).resolve() / "anchor"
        approved = base / "references"
        approved.mkdir(parents=True)
        (approved / "asset.mp4").write_bytes(b"fixture")
        require(
            MODULE.safe_component_check(approved / "asset.mp4", approved, base)["safe"],
            "valid relative child rejected",
        )

        for value in (
            str(base / "sibling" / "asset.mp4"),
            "../sibling/asset.mp4",
            "asset\x00.mp4",
            "Frozen/asset.mp4",
            "Virgin/asset.mp4",
        ):
            require(not MODULE.validate_manifest_relative_path(value)["safe"], f"unsafe manifest path accepted: {value!r}")

        parent_link = base / "parent-link"
        parent_link.symlink_to(base, target_is_directory=True)
        parent_root = parent_link / "references"
        require(
            not MODULE.safe_component_check(parent_root / "asset.mp4", parent_root, base)["safe"],
            "approved-root parent symlink accepted",
        )

        root_link = base / "root-link"
        root_link.symlink_to(approved, target_is_directory=True)
        require(
            not MODULE.safe_component_check(root_link / "asset.mp4", root_link, base)["safe"],
            "approved root symlink accepted",
        )

        nested = approved / "nested"
        nested.mkdir()
        nested_link = nested / "link"
        nested_link.symlink_to(approved / "asset.mp4")
        require(
            not MODULE.safe_component_check(nested_link, approved, base)["safe"],
            "nested symlink accepted",
        )

        protected = base / "synthetic-protected"
        protected.mkdir()
        protected_link = approved / "protected-link"
        protected_link.symlink_to(protected, target_is_directory=True)
        require(
            not MODULE.safe_component_check(protected_link / "asset.mp4", approved, base)["safe"],
            "symlink to synthetic protected root accepted",
        )


def main() -> int:
    test_temporal_matrix()
    test_path_matrix()
    print("LIVE31 qualification temporal synthetic matrix: PASS")
    print("LIVE31 qualification root-containment synthetic matrix: PASS")
    print("protected media accessed: NO")
    print("objective evaluations: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
