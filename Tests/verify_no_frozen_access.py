#!/usr/bin/env python3
"""Static guard for the pre-Frozen allowlist protocol.

This guard deliberately reads only the committed scope file and explicit target
files supplied by the caller. It never discovers files from the repository
root, and it never walks a media directory.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]


def rel_path(value: object, label: str, errors: list[str], *, directory: bool) -> str | None:
    if not isinstance(value, str) or not value:
        errors.append(f"{label}: expected a non-empty relative path")
        return None
    if value.startswith("/"):
        errors.append(f"{label}: absolute path is forbidden")
    parts = PurePosixPath(value).parts
    if ".." in parts:
        errors.append(f"{label}: parent traversal is forbidden")
    if any(token in value for token in ("*", "?", "[", "]")):
        errors.append(f"{label}: glob syntax is forbidden")
    if directory:
        if value.endswith("/"):
            errors.append(f"{label}: directory path must not end with slash")
    elif value.endswith("/"):
        errors.append(f"{label}: file path must not end with slash")
    return value


def validate_scope(scope: dict[str, object]) -> list[str]:
    errors: list[str] = []
    if scope.get("scopeMode") != "ALLOWLIST_ONLY":
        errors.append("scopeMode must be ALLOWLIST_ONLY")

    media_policy = scope.get("mediaPolicy")
    if not isinstance(media_policy, dict):
        errors.append("mediaPolicy is missing")
    elif media_policy.get("frozenRootConfigured") is not False:
        errors.append("frozenRootConfigured must be false during sealing")
    elif media_policy.get("broadMediaEnumeration") != "FORBIDDEN":
        errors.append("broadMediaEnumeration must be FORBIDDEN")

    roots = scope.get("productionRoots")
    if not isinstance(roots, list) or not roots:
        errors.append("productionRoots must be a non-empty list")
    else:
        for index, value in enumerate(roots):
            rel_path(value, f"productionRoots[{index}]", errors, directory=True)

    for key in ("shaderFiles", "exactFiles", "resultFiles", "verificationFiles"):
        values = scope.get(key)
        if not isinstance(values, list):
            errors.append(f"{key} must be a list")
            continue
        seen: set[str] = set()
        for index, value in enumerate(values):
            path = rel_path(value, f"{key}[{index}]", errors, directory=False)
            if path is not None and path in seen:
                errors.append(f"{key}: duplicate path {path}")
            if path is not None:
                seen.add(path)

    approved = media_policy.get("approvedExplicitMediaFiles", []) if isinstance(media_policy, dict) else []
    exact = scope.get("exactFiles", [])
    if isinstance(approved, list) and isinstance(exact, list):
        for value in approved:
            if value not in exact:
                errors.append(f"approved media file is not exact-listed: {value}")
            if isinstance(value, str) and value in {"data_video", "data_video/", "sdr2hdr-real-media"}:
                errors.append(f"media directory is not an approved explicit file: {value}")

    for key in ("productionRoots", "shaderFiles", "exactFiles", "resultFiles", "verificationFiles"):
        values = scope.get(key, [])
        if isinstance(values, list):
            for value in values:
                if isinstance(value, str) and value in {"data_video", "sdr2hdr-real-media"}:
                    errors.append(f"broad media root is present in {key}: {value}")

    return errors


STATIC_BROAD_SCAN_PATTERNS = (
    ("shell media listing", re.compile(r"\b(?:rg\s+--files|find|tree|ls\s+-R|du\s+-a|fd\s+\.)\s+[^\n]*data_video", re.IGNORECASE)),
    ("data-video glob", re.compile(r"(?:glob|iglob)\s*\([^\n]*data_video", re.IGNORECASE)),
    ("data-video recursive walk", re.compile(r"(?:rglob|os\.walk|os\.scandir|iterdir)\s*\([^\n]*(?:data_video|repo|root)", re.IGNORECASE)),
    ("wildcard recursive root walk", re.compile(r"(?:Path\([^\n]*\)|repo_root|root)\s*\.rglob\s*\(\s*[\"']\*", re.IGNORECASE)),
    ("Frozen path injection", re.compile(r"\b(?:HDR_FROZEN_ROOT|FROZEN_ROOT|V6_FROZEN_PLAN)\b", re.IGNORECASE)),
)


def validate_target(path_value: str, errors: list[str]) -> None:
    path = (ROOT / path_value).resolve()
    if not path.is_relative_to(ROOT):
        errors.append(f"target escapes repository: {path_value}")
        return
    if not path.exists() or not path.is_file():
        errors.append(f"target is missing or not a file: {path_value}")
        return
    if path.is_symlink():
        errors.append(f"target must not be a symlink: {path_value}")
        return
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        errors.append(f"target is not UTF-8 text: {path_value}: {error}")
        return
    for label, pattern in STATIC_BROAD_SCAN_PATTERNS:
        if pattern.search(text):
            errors.append(f"{path_value}: forbidden {label} pattern")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scope", default="config/pre-frozen-seal-scope.json")
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--workflow", action="append", default=[])
    args = parser.parse_args()

    errors: list[str] = []
    scope_path = (ROOT / args.scope).resolve()
    if not scope_path.is_relative_to(ROOT) or not scope_path.is_file():
        errors.append(f"scope is missing or escapes repository: {args.scope}")
    else:
        try:
            scope = json.loads(scope_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            errors.append(f"cannot load scope: {error}")
        else:
            if not isinstance(scope, dict):
                errors.append("scope root must be an object")
            else:
                errors.extend(validate_scope(scope))

    for target in [*args.target, *args.workflow]:
        validate_target(target, errors)

    if errors:
        print("NO_FROZEN_ACCESS_GUARD = FAIL")
        for error in errors:
            print(f"reason = {error}")
        return 1

    print("NO_FROZEN_ACCESS_GUARD = PASS")
    print("scope = ALLOWLIST_ONLY")
    print("broad media enumeration = BLOCKED")
    print("Frozen root injection = DISABLED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
