#!/usr/bin/env python3
"""Static guard for the pre-Frozen allowlist protocol.

The guard reads one committed scope file and only the exact verification files
listed in that scope (plus optional explicit CLI targets). It never discovers
files from the repository root, and it never walks a media directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
SELF_RELATIVE_PATH = "Tests/verify_no_frozen_access.py"
MEDIA_ROOT = "data_video"


def is_under_media_root(path: str) -> bool:
    parts = PurePosixPath(path).parts
    return bool(parts) and parts[0] == MEDIA_ROOT


def is_approved_media_file(path: str, approved: set[str]) -> bool:
    return path in approved


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
    if value.endswith("/"):
        kind = "directory" if directory else "file"
        errors.append(f"{label}: {kind} path must not end with slash")
    return value


def validate_scope(scope: dict[str, object]) -> list[str]:
    errors: list[str] = []
    if scope.get("scopeMode") != "ALLOWLIST_ONLY":
        errors.append("scopeMode must be ALLOWLIST_ONLY")

    scope_file = scope.get("scopeFile")
    if scope_file != "config/pre-frozen-seal-scope.json":
        errors.append("scopeFile must point to the committed scope file")

    media_policy = scope.get("mediaPolicy")
    if not isinstance(media_policy, dict):
        errors.append("mediaPolicy is missing")
    else:
        if media_policy.get("frozenRootConfigured") is not False:
            errors.append("frozenRootConfigured must be false during sealing")
        if media_policy.get("broadMediaEnumeration") != "FORBIDDEN":
            errors.append("broadMediaEnumeration must be FORBIDDEN")
        if media_policy.get("dataVideoDirectoryRoots") != "FORBIDDEN":
            errors.append("dataVideoDirectoryRoots must be FORBIDDEN")

    roots = scope.get("productionRoots")
    if not isinstance(roots, list) or not roots:
        errors.append("productionRoots must be a non-empty list")
    else:
        for index, value in enumerate(roots):
            path = rel_path(value, f"productionRoots[{index}]", errors, directory=True)
            if path is not None and is_under_media_root(path):
                errors.append(f"productionRoots[{index}]: data_video paths are forbidden")

    category_keys = ("shaderFiles", "resultFiles", "verificationFiles", "plannedVerificationFiles")
    category_paths: dict[str, set[str]] = {}
    for key in category_keys:
        values = scope.get(key)
        if not isinstance(values, list):
            errors.append(f"{key} must be a list")
            category_paths[key] = set()
            continue
        seen: set[str] = set()
        category_paths[key] = seen
        for index, value in enumerate(values):
            path = rel_path(value, f"{key}[{index}]", errors, directory=False)
            if path is None:
                continue
            if path in seen:
                errors.append(f"{key}: duplicate path {path}")
            seen.add(path)
            if is_under_media_root(path):
                errors.append(f"{key}[{index}]: data_video paths are forbidden")

    if category_paths.get("verificationFiles", set()) & category_paths.get("plannedVerificationFiles", set()):
        errors.append("verificationFiles and plannedVerificationFiles must be disjoint")

    exact_values = scope.get("exactFiles")
    exact_paths: set[str] = set()
    if not isinstance(exact_values, list):
        errors.append("exactFiles must be a list")
    else:
        for index, value in enumerate(exact_values):
            path = rel_path(value, f"exactFiles[{index}]", errors, directory=False)
            if path is None:
                continue
            if path in exact_paths:
                errors.append(f"exactFiles: duplicate path {path}")
            exact_paths.add(path)

    approved_values = media_policy.get("approvedExplicitMediaFiles", []) if isinstance(media_policy, dict) else []
    approved_paths: set[str] = set()
    if not isinstance(approved_values, list):
        errors.append("approvedExplicitMediaFiles must be a list")
    else:
        for index, value in enumerate(approved_values):
            path = rel_path(value, f"approvedExplicitMediaFiles[{index}]", errors, directory=False)
            if path is None:
                continue
            approved_paths.add(path)
            if not is_under_media_root(path):
                errors.append(f"approvedExplicitMediaFiles[{index}]: must start with data_video/")
            if path not in exact_paths:
                errors.append(f"approved media file is not exact-listed: {path}")

    for path in exact_paths:
        if is_under_media_root(path) and not is_approved_media_file(path, approved_paths):
            errors.append(f"exactFiles media path is not approved explicitly: {path}")

    baselines = scope.get("verificationFileBaselines", {})
    if not isinstance(baselines, dict):
        errors.append("verificationFileBaselines must be an object")
    else:
        for value, digest in baselines.items():
            path = rel_path(value, "verificationFileBaselines path", errors, directory=False)
            if path is not None and path not in category_paths.get("verificationFiles", set()):
                errors.append(f"baseline path is not a verification file: {path}")
            if not isinstance(digest, str) or re.fullmatch(r"[0-9a-fA-F]{64}", digest) is None:
                errors.append(f"verification baseline must be a SHA-256 hex digest: {value}")

    exceptions = scope.get("legacyVerificationExceptions", {})
    if not isinstance(exceptions, dict):
        errors.append("legacyVerificationExceptions must be an object")
    else:
        for value, labels in exceptions.items():
            path = rel_path(value, "legacy exception path", errors, directory=False)
            if path is not None and path not in category_paths.get("verificationFiles", set()):
                errors.append(f"legacy exception path is not a verification file: {path}")
            if not isinstance(labels, list) or not all(isinstance(label, str) for label in labels):
                errors.append(f"legacy exception labels must be a string list: {value}")

    return errors


STATIC_BROAD_SCAN_PATTERNS = (
    (
        "shell media listing",
        re.compile(r"\b(?:rg\s+--files|find|tree|ls\s+-R|du\s+-a|fd\s+\.)[^\n]*\bdata_video(?:[/\s]|$)", re.IGNORECASE),
    ),
    (
        "shell repository listing",
        re.compile(r"(?m)^\s*(?:rg\s+--files|find|tree|ls\s+-R|du\s+-a|fd\s+\.)\s+\.(?:[/\s]|$)", re.IGNORECASE),
    ),
    (
        "data-video glob",
        re.compile(r"(?:glob|iglob)\s*\([^\n]*data_video", re.IGNORECASE),
    ),
    (
        "data-video recursive walk",
        re.compile(r"(?:rglob|os\.walk|os\.scandir|iterdir)\s*\([^\n]*data_video", re.IGNORECASE),
    ),
    (
        "data-video path recursive walk",
        re.compile(r"(?:Path|pathlib\.Path)\s*\([^\n]*data_video[^\n]*\)\s*\.\s*(?:rglob|glob|iglob|iterdir)\s*\(", re.IGNORECASE),
    ),
    (
        "data-video alias assignment",
        re.compile(r"\b(?:data|media_root|media)\s*=\s*[^\n]*data_video", re.IGNORECASE),
    ),
    (
        "data-video alias traversal",
        re.compile(r"\b(?:data|media_root|media)\s*\.\s*(?:rglob|glob|iglob|walk|scandir|iterdir)\s*\(", re.IGNORECASE),
    ),
    (
        "generic repository recursive walk",
        re.compile(r"(?:os\.walk|os\.scandir)\s*\(\s*(?:ROOT|root|repo_root|repo)\b", re.IGNORECASE),
    ),
    (
        "generic repository rglob",
        re.compile(r"(?:Path|pathlib\.Path)\s*\(\s*(?:ROOT|root|repo_root|repo)\s*\)\s*\.\s*rglob\s*\(", re.IGNORECASE),
    ),
    (
        "generic root rglob",
        re.compile(r"\b(?:ROOT|root|repo_root|repo)\s*\.\s*rglob\s*\(", re.IGNORECASE),
    ),
    (
        "Frozen path injection",
        re.compile(r"\b(?:HDR_FROZEN_ROOT|FROZEN_ROOT|V6_FROZEN_PLAN)\b", re.IGNORECASE),
    ),
)


def validate_target(
    path_value: str,
    errors: list[str],
    scope: dict[str, object],
    *,
    scan_text: bool,
) -> None:
    normalized = rel_path(path_value, "verification target", errors, directory=False)
    if normalized is None:
        return
    if is_under_media_root(normalized):
        errors.append(f"verification target is under data_video: {normalized}")
        return

    lexical = ROOT / normalized
    if lexical.is_symlink():
        errors.append(f"target must not be a symlink: {normalized}")
        return
    if not lexical.exists() or not lexical.is_file():
        errors.append(f"target is missing or not a file: {normalized}")
        return
    path = lexical.resolve()
    if not path.is_relative_to(ROOT):
        errors.append(f"target escapes repository: {normalized}")
        return

    baselines = scope.get("verificationFileBaselines", {})
    expected = baselines.get(normalized) if isinstance(baselines, dict) else None
    digest: str | None = None
    if expected is not None:
        digest = hashlib.sha256(lexical.read_bytes()).hexdigest()
        if digest != expected:
            errors.append(f"verification target changed from its sealed baseline: {normalized}")

    if not scan_text:
        return
    try:
        text = lexical.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        errors.append(f"target is not UTF-8 text: {normalized}: {error}")
        return

    exceptions = scope.get("legacyVerificationExceptions", {})
    allowed_labels = set(exceptions.get(normalized, [])) if isinstance(exceptions, dict) else set()
    baseline_matches = expected is not None and digest == expected
    for label, pattern in STATIC_BROAD_SCAN_PATTERNS:
        if pattern.search(text) and not (baseline_matches and label in allowed_labels):
            errors.append(f"{normalized}: forbidden {label} pattern")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scope", default="config/pre-frozen-seal-scope.json")
    parser.add_argument("--target", action="append", default=[])
    parser.add_argument("--workflow", action="append", default=[])
    args = parser.parse_args()

    errors: list[str] = []
    scope_lexical = ROOT / args.scope
    if scope_lexical.is_symlink():
        errors.append(f"scope must not be a symlink: {args.scope}")
        scope: dict[str, object] = {}
    elif not scope_lexical.is_file():
        errors.append(f"scope is missing: {args.scope}")
        scope = {}
    else:
        scope_path = scope_lexical.resolve()
        if not scope_path.is_relative_to(ROOT):
            errors.append(f"scope escapes repository: {args.scope}")
            scope = {}
        else:
            try:
                loaded = json.loads(scope_lexical.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
                errors.append(f"cannot load scope: {error}")
                scope = {}
            else:
                if not isinstance(loaded, dict):
                    errors.append("scope root must be an object")
                    scope = {}
                else:
                    scope = loaded
                    errors.extend(validate_scope(scope))

    scope_targets = scope.get("verificationFiles", [])
    if not isinstance(scope_targets, list):
        scope_targets = []
    targets = {value for value in [*scope_targets, *args.target, *args.workflow] if isinstance(value, str)}
    for target in sorted(targets):
        validate_target(
            target,
            errors,
            scope,
            scan_text=target != SELF_RELATIVE_PATH,
        )

    if errors:
        print("NO_FROZEN_ACCESS_GUARD = FAIL")
        for error in errors:
            print(f"reason = {error}")
        return 1

    print("NO_FROZEN_ACCESS_GUARD = PASS")
    print("scope = ALLOWLIST_ONLY")
    print("broad media enumeration = BLOCKED")
    print("Frozen root injection = DISABLED")
    print("verification files = PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
