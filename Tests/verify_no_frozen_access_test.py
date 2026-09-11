#!/usr/bin/env python3
"""Unit-style negative and positive tests for the static access guard."""

from __future__ import annotations

import copy
import importlib.util
import tempfile
from pathlib import Path


GUARD_PATH = Path(__file__).with_name("verify_no_frozen_access.py")
SPEC = importlib.util.spec_from_file_location("pre_frozen_guard", GUARD_PATH)
assert SPEC is not None and SPEC.loader is not None
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


def scope_fixture() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "scopeMode": "ALLOWLIST_ONLY",
        "scopeFile": "config/pre-frozen-seal-scope.json",
        "productionRoots": ["Sources/HDRCore", "Sources/HDRPlayer"],
        "shaderFiles": [
            "Sources/HDRCore/Shaders/SDRToHDR.metal",
            "Sources/HDRPlayer/Shaders/Presentation.metal",
        ],
        "exactFiles": [
            "Package.swift",
            "data_video/real_media/external-manifest.json",
        ],
        "resultFiles": ["results/example.json"],
        "verificationFiles": [
            "Tests/verify_no_frozen_access.py",
            "RUN_MACOS_VERIFY.sh",
            ".github/workflows/macos-ci.yml",
        ],
        "plannedVerificationFiles": ["Tests/verify_pre_frozen_seal.py"],
        "verificationFileBaselines": {"RUN_MACOS_VERIFY.sh": "0" * 64},
        "legacyVerificationExceptions": {"RUN_MACOS_VERIFY.sh": ["Frozen path injection"]},
        "mediaPolicy": {
            "approvedExplicitMediaFiles": [
                "data_video/real_media/external-manifest.json"
            ],
            "frozenRootConfigured": False,
            "frozenPathInjectedOnlyForEvaluation": True,
            "broadMediaEnumeration": "FORBIDDEN",
            "dataVideoDirectoryRoots": "FORBIDDEN",
        },
    }


def errors_for(scope: dict[str, object]) -> list[str]:
    return GUARD.validate_scope(scope)


def assert_rejected(scope: dict[str, object], label: str) -> None:
    errors = errors_for(scope)
    assert errors, f"expected rejection: {label}"


def main() -> None:
    valid = scope_fixture()
    assert not errors_for(valid), errors_for(valid)

    rejected = copy.deepcopy(valid)
    rejected["productionRoots"] = ["data_video/foo"]
    assert_rejected(rejected, "media production root")

    rejected = copy.deepcopy(valid)
    rejected["resultFiles"] = ["data_video/result.json"]
    assert_rejected(rejected, "media result file")

    rejected = copy.deepcopy(valid)
    rejected["exactFiles"] = ["Package.swift", "data_video/unapproved.json"]
    assert_rejected(rejected, "unapproved explicit media file")

    rejected = copy.deepcopy(valid)
    rejected["mediaPolicy"]["approvedExplicitMediaFiles"] = []
    assert_rejected(rejected, "missing approved media reverse mapping")

    for path in (
        "data_video/real_media/",
        "data_video/../outside.json",
        "../data_video/outside.json",
        "/data_video/outside.json",
        "data_video/*",
    ):
        rejected = copy.deepcopy(valid)
        rejected["exactFiles"] = [path]
        rejected["mediaPolicy"]["approvedExplicitMediaFiles"] = [path]
        assert_rejected(rejected, f"invalid path {path}")

    rejected = copy.deepcopy(valid)
    rejected["verificationFiles"] = ["data_video/script.py"]
    assert_rejected(rejected, "media verification file")

    blocked_texts = (
        "rg --files data_video",
        "rg --files ./data_video",
        "find ../repo/data_video",
        "tree data_video",
        "ls -R data_video",
        "du -a data_video",
        "fd . data_video",
        "Path(root / 'data_video').rglob('*')",
        "Path(ROOT).rglob('*')",
        "os.walk('data_video')",
        "glob.glob('data_video/**')",
        "find .",
    )
    for text in blocked_texts:
        assert any(pattern.search(text) for _, pattern in GUARD.STATIC_BROAD_SCAN_PATTERNS), text

    assert not any(
        pattern.search("for path in sorted(base.rglob('*.swift'))")
        for _, pattern in GUARD.STATIC_BROAD_SCAN_PATTERNS
    )

    with tempfile.TemporaryDirectory(dir=GUARD.ROOT, prefix=".pre-frozen-guard-") as temporary:
        temporary_path = Path(temporary)
        safe = temporary_path / "safe.py"
        safe.write_text("print('safe')\n", encoding="utf-8")
        safe_relative = safe.relative_to(GUARD.ROOT).as_posix()
        errors: list[str] = []
        GUARD.validate_target(safe_relative, errors, valid, scan_text=True)
        assert not errors, errors

        bad = temporary_path / "bad.py"
        bad.write_text("rg --files data_video\n", encoding="utf-8")
        bad_relative = bad.relative_to(GUARD.ROOT).as_posix()
        errors = []
        GUARD.validate_target(bad_relative, errors, valid, scan_text=True)
        assert errors

    print("verify_no_frozen_access_test: PASS")


if __name__ == "__main__":
    main()
