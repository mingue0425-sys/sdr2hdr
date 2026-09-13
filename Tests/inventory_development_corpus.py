#!/usr/bin/env python3
"""Inventory only the committed, explicitly approved development roots.

This tool reads exact committed manifests, then collects filesystem metadata
from the roots named by the inventory scope. It never reads media bytes,
decodes media, invokes ffprobe, or computes objective metrics.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
from collections import Counter, defaultdict
from pathlib import Path, PurePosixPath
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Set, Tuple


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SCOPE = REPO_ROOT / "results/development-corpus-inventory-scope.json"
DEFAULT_OUTPUT = REPO_ROOT / "results/development-corpus-inventory.json"
DEFAULT_DOC = REPO_ROOT / "docs/DEVELOPMENT_CORPUS_INVENTORY.md"

KNOWN_METADATA_PATHS = (
    "data_video/visual-regression/v6-development-manifest.json",
    "data_video/manifest.json",
    "data_video/manifest-v2.json",
    "data_video/real_media/external-manifest.json",
    "config/pre-frozen-seal-scope.json",
)

MEDIA_EXTENSIONS = {
    ".avi",
    ".m2ts",
    ".m4v",
    ".mkv",
    ".mov",
    ".mp4",
    ".mxf",
    ".ts",
    ".webm",
    ".y4m",
}

PROTECTED_TOKENS = (
    "frozen",
    "virgin",
    "holdout",
    "quarantined",
    ".hdr-frozen-consumption",
)

BROAD_ROOTS = {
    ".",
    "data_video",
    "data_video/live paired comparison hdr vs. sdr database",
    "data_video/real_media",
}


class InventoryError(RuntimeError):
    pass


def read_json_exact(relative_path: str) -> Dict[str, Any]:
    file_path = REPO_ROOT / relative_path
    return json.loads(file_path.read_text(encoding="utf-8"))


def normalize_repo_locator(locator: Any) -> Optional[str]:
    """Normalize only an explicit repository-relative data_video locator."""

    if not isinstance(locator, str) or not locator or "\x00" in locator:
        return None
    value = locator.replace("\\", "/")
    if value.startswith("/"):
        marker = "/data_video/"
        if marker not in value:
            return None
        value = "data_video/" + value.split(marker, 1)[1]
    elif not value.startswith("data_video/"):
        return None
    pure = PurePosixPath(value)
    if pure.is_absolute() or ".." in pure.parts:
        return None
    return pure.as_posix()


def normalize_manifest_relative_locator(base: str, locator: Any) -> Optional[str]:
    if not isinstance(locator, str) or locator.startswith("/"):
        return normalize_repo_locator(locator)
    return normalize_repo_locator(f"data_video/{base}/{locator}")


def validate_root_locator(root_relative: str, excluded_roots: Sequence[str]) -> None:
    if not isinstance(root_relative, str) or not root_relative:
        raise InventoryError("included root must be a non-empty relative path")
    pure = PurePosixPath(root_relative)
    folded = pure.as_posix().casefold()
    if pure.is_absolute() or ".." in pure.parts or folded in BROAD_ROOTS:
        raise InventoryError(f"broad or unsafe inventory root rejected: {root_relative}")
    if any(token in folded for token in PROTECTED_TOKENS):
        raise InventoryError(f"protected inventory root rejected: {root_relative}")
    for excluded_root in excluded_roots:
        excluded = PurePosixPath(excluded_root).as_posix().rstrip("/")
        if folded == excluded.casefold() or folded.startswith(excluded.casefold() + "/"):
            raise InventoryError(f"excluded protected root requested: {root_relative}")


def load_scope(scope_path: Path) -> Tuple[Dict[str, Any], List[Dict[str, Any]], List[str]]:
    scope = json.loads(scope_path.read_text(encoding="utf-8"))
    if scope.get("status") != "APPROVED_SCOPE_ONLY":
        raise InventoryError("scope is not APPROVED_SCOPE_ONLY")
    if scope.get("inventoryPolicy", {}).get("mediaByteRead") is not False:
        raise InventoryError("scope permits media byte reads")
    if scope.get("inventoryPolicy", {}).get("objectiveMetrics") is not False:
        raise InventoryError("scope permits objective metrics")
    excluded = [entry["path"] for entry in scope.get("excludedProtectedRoots", [])]
    included = scope.get("includedRoots")
    if not isinstance(included, list) or not included:
        raise InventoryError("scope has no included roots")
    for entry in included:
        validate_root_locator(entry.get("path"), excluded)
        if entry.get("recursiveInventoryAllowed") is not True:
            raise InventoryError(f"recursive inventory not explicitly allowed: {entry.get('path')}")
    return scope, included, excluded


def is_under_root(relative_path: str, root_relative: str) -> bool:
    normalized_path = PurePosixPath(relative_path).as_posix()
    normalized_root = PurePosixPath(root_relative).as_posix().rstrip("/")
    return normalized_path == normalized_root or normalized_path.startswith(normalized_root + "/")


def walk_approved_root(
    materialization_root: Path,
    root_relative: str,
    excluded_roots: Sequence[str],
) -> List[Dict[str, Any]]:
    """Walk one already-approved root, collecting metadata only."""

    validate_root_locator(root_relative, excluded_roots)
    root_path = materialization_root / root_relative
    if root_path.is_symlink():
        raise InventoryError(f"approved root is a symlink: {root_relative}")
    if not root_path.exists() or not root_path.is_dir():
        return []
    resolved_root = root_path.resolve()
    try:
        resolved_root.relative_to(materialization_root.resolve())
    except ValueError as error:
        raise InventoryError(f"approved root escapes materialization root: {root_relative}") from error

    records: List[Dict[str, Any]] = []
    for directory, directory_names, file_names in os.walk(
        root_path,
        topdown=True,
        followlinks=False,
    ):
        directory_path = Path(directory)
        directory_names.sort()
        file_names.sort()
        for directory_name in list(directory_names):
            child_path = directory_path / directory_name
            if child_path.is_symlink():
                raise InventoryError(f"symlink directory encountered: {child_path.relative_to(materialization_root)}")
        for file_name in file_names:
            file_path = directory_path / file_name
            if file_path.is_symlink():
                raise InventoryError(f"symlink media candidate encountered: {file_path.relative_to(materialization_root)}")
            if file_path.suffix.casefold() not in MEDIA_EXTENSIONS:
                continue
            relative_path = file_path.relative_to(materialization_root).as_posix()
            file_stat = file_path.stat()
            records.append(
                {
                    "relativePath": relative_path,
                    "fileName": file_path.name,
                    "extension": file_path.suffix.casefold(),
                    "byteSize": file_stat.st_size,
                    "parentPath": file_path.parent.relative_to(materialization_root).as_posix(),
                    "inventoryRoot": root_relative,
                }
            )
    return records


def structured_transfer(record: Mapping[str, Any], side: str) -> Any:
    metadata = record.get("metadata")
    if isinstance(metadata, Mapping):
        side_metadata = metadata.get(side)
        if isinstance(side_metadata, Mapping):
            return side_metadata.get("transfer") or side_metadata.get("transferFunction")
    expected = record.get("expected")
    if side == "sdr" and isinstance(expected, Mapping):
        return expected.get("transfer")
    return None


def add_membership(
    membership: Dict[str, List[Dict[str, Any]]],
    locator: Optional[str],
    detail: Dict[str, Any],
) -> None:
    if locator is not None:
        membership[locator].append(detail)


def build_manifest_membership() -> Tuple[Dict[str, List[Dict[str, Any]]], List[Dict[str, Any]], List[Dict[str, Any]]]:
    membership: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    current_pairs: List[Dict[str, Any]] = []
    historical_conflicts: List[Dict[str, Any]] = []

    current_path = "data_video/visual-regression/v6-development-manifest.json"
    current_manifest = read_json_exact(current_path)
    for record in current_manifest.get("pairs", []):
        pair_id = record.get("id")
        pair = {
            "pairId": pair_id,
            "candidateGroupId": record.get("group"),
            "contentFamily": record.get("contentFamily"),
            "expectedRelation": record.get("expectedRelation"),
            "existingRole": record.get("split"),
            "virginFrozen": record.get("virginFrozen"),
            "sourceMasterId": record.get("sourceMasterId"),
            "source": record.get("source"),
            "manifestPath": current_path,
            "sdrPath": normalize_repo_locator(record.get("sdr")),
            "hdrPath": normalize_repo_locator(record.get("hdr")),
            "pairConfidence": "EXPLICIT",
            "pairOrigin": "documented-local-pair",
        }
        current_pairs.append(pair)
        for side in ("sdr", "hdr"):
            locator = pair[f"{side}Path"]
            add_membership(
                membership,
                locator,
                {
                    "manifestPath": current_path,
                    "recordId": pair_id,
                    "side": side,
                    "assetRole": side,
                    "existingRole": record.get("split"),
                    "contentFamily": record.get("contentFamily"),
                    "candidateGroupId": record.get("group"),
                    "expectedRelation": record.get("expectedRelation"),
                    "virginFrozen": record.get("virginFrozen"),
                    "declaredTransfer": structured_transfer(record, side),
                    "source": record.get("source"),
                },
            )

    for historical_path in ("data_video/manifest.json", "data_video/manifest-v2.json"):
        historical = read_json_exact(historical_path)
        for record in historical.get("pairs", []):
            pair_id = record.get("id")
            for side in ("sdr", "hdr"):
                locator = normalize_manifest_relative_locator("", record.get(side))
                if locator is None:
                    continue
                if not locator.startswith("data_video/"):
                    continue
                add_membership(
                    membership,
                    locator,
                    {
                        "manifestPath": historical_path,
                        "recordId": pair_id,
                        "side": side,
                        "assetRole": side,
                        "existingRole": record.get("split"),
                        "expectedRelation": record.get("expectedRelation"),
                        "historical": True,
                    },
                )
            if record.get("split") == "frozen":
                historical_conflicts.append(
                    {
                        "manifestPath": historical_path,
                        "recordId": pair_id,
                        "split": "frozen",
                        "sdrPath": normalize_manifest_relative_locator("", record.get("sdr")),
                        "hdrPath": normalize_manifest_relative_locator("", record.get("hdr")),
                    }
                )

    external_path = "data_video/real_media/external-manifest.json"
    external_manifest = read_json_exact(external_path)
    for record in external_manifest.get("sources", []):
        source_id = record.get("id")
        base = "data_video/real_media"
        locator = normalize_manifest_relative_locator("real_media", record.get("fileName"))
        detail = {
            "manifestPath": external_path,
            "recordId": source_id,
            "side": "sdr" if record.get("sdrEvidence") else None,
            "assetRole": "unpaired-source",
            "existingRole": record.get("split"),
            "pairStatus": record.get("pairStatus"),
            "sourceFamily": record.get("sourceFamily"),
            "declaredTransfer": (record.get("expected") or {}).get("transfer"),
            "declaredRange": (record.get("expected") or {}).get("range"),
            "source": record.get("sourceFamily"),
        }
        add_membership(membership, locator, detail)
        original = record.get("original")
        if isinstance(original, Mapping):
            original_locator = normalize_manifest_relative_locator("real_media", original.get("fileName"))
            add_membership(
                membership,
                original_locator,
                {
                    **detail,
                    "assetRole": "related-original",
                    "recordId": source_id,
                },
            )

    return membership, current_pairs, historical_conflicts


def name_hint(relative_path: str, memberships: Sequence[Mapping[str, Any]]) -> Tuple[str, str]:
    sides = {entry.get("side") for entry in memberships if entry.get("side") in {"sdr", "hdr"}}
    if len(sides) == 1:
        return next(iter(sides)).upper(), "manifest-membership"
    folded = relative_path.casefold()
    if "open-sourced_hdr10" in folded or re.search(r"(?:^|[_ .-])(?:hdr10|pq|hlg)(?:[_ .-]|$)", folded):
        return "HDR", "path-or-name-hint"
    if "open-sourced_sdr" in folded or re.search(r"(?:^|[_ .-])sdr(?:[_ .-]|$)", folded):
        return "SDR", "path-or-name-hint"
    if "hdr" in folded:
        return "HDR", "path-or-name-hint"
    return "UNKNOWN", "none"


def file_records_with_membership(
    raw_records: Sequence[Dict[str, Any]],
    membership: Mapping[str, Sequence[Mapping[str, Any]]],
) -> List[Dict[str, Any]]:
    records: List[Dict[str, Any]] = []
    for raw in raw_records:
        relative_path = raw["relativePath"]
        entries = list(membership.get(relative_path, []))
        hint, hint_source = name_hint(relative_path, entries)
        transfers = sorted(
            {
                str(entry.get("declaredTransfer"))
                for entry in entries
                if entry.get("declaredTransfer") is not None
            }
        )
        records.append(
            {
                **raw,
                "nameHint": hint,
                "nameHintSource": hint_source,
                "authoritativeTransfer": transfers[0] if len(transfers) == 1 else None,
                "declaredTransferValues": transfers,
                "manifestMembership": entries,
                "existingSidecars": [],
            }
        )
    return records


def live_variant_key(file_name: str) -> str:
    stem = Path(file_name).stem.casefold()
    return re.sub(r"(?:^|_)(?:hdr10|hdr|sdr)(?=_|$)", "_", stem).strip("_")


def live_family_key(file_name: str) -> str:
    stem = live_variant_key(file_name)
    previous = None
    while previous != stem:
        previous = stem
        stem = re.sub(r"_(?:\d{3,5}x\d{3,5}|\d{2,6}k)$", "", stem)
    return stem.strip("_")


def inferred_group_identity(content_family: Any, group: Any) -> Optional[str]:
    if not group:
        return None
    group_text = str(group)
    if content_family == "LIVE" and group_text.casefold().startswith("live_"):
        return "live:" + group_text[5:].casefold()
    return "group:" + group_text.casefold()


def is_live_asset(relative_path: str) -> bool:
    return "data_video/live paired comparison hdr vs. sdr database/" in relative_path.casefold()


def known_manifest_locator_bases() -> Set[Path]:
    current_manifest = read_json_exact("data_video/visual-regression/v6-development-manifest.json")
    bases: Set[Path] = set()
    for record in current_manifest.get("pairs", []):
        for side in ("sdr", "hdr"):
            locator = record.get(side)
            if not isinstance(locator, str) or not locator.startswith("/"):
                continue
            marker = "/data_video/"
            if marker in locator:
                bases.add(Path(locator.split(marker, 1)[0]))
    return bases


def inferred_pair_group(
    sdr_record: Mapping[str, Any],
    hdr_record: Mapping[str, Any],
    pair_key: str,
) -> Dict[str, Any]:
    family_key = live_family_key(sdr_record["fileName"])
    return {
        "candidateGroupId": f"heuristic-live:{pair_key}",
        "pairId": None,
        "sourceMasterId": None,
        "inferredSourceMasterId": "live:" + family_key,
        "familyIdentityStatus": "INFERRED",
        "contentFamily": "LIVE",
        "sdrCandidate": sdr_record["relativePath"],
        "hdrCandidate": hdr_record["relativePath"],
        "pairConfidence": "HEURISTIC",
        "existingRole": None,
        "expectedRelation": None,
        "pairOrigin": "filename-variant-under-explicit-LIVE-roots",
        "sourceDataset": "LIVE Paired Comparison HDR vs. SDR Database",
        "provenanceSource": "inventory filename grouping; no authoritative sourceMasterId",
        "technicalQualification": "NOT_RUN",
        "byteIdentity": "NOT_READ",
    }


def explicit_pair_group(
    pair: Mapping[str, Any],
) -> Dict[str, Any]:
    group = pair.get("candidateGroupId")
    identity_status = "PROVEN" if pair.get("sourceMasterId") else ("INFERRED" if group else "UNKNOWN")
    return {
        "candidateGroupId": group,
        "pairId": pair.get("pairId"),
        "sourceMasterId": pair.get("sourceMasterId"),
        "inferredSourceMasterId": inferred_group_identity(pair.get("contentFamily"), group)
        if identity_status == "INFERRED" else None,
        "familyIdentityStatus": identity_status,
        "contentFamily": pair.get("contentFamily"),
        "sdrCandidate": pair.get("sdrPath"),
        "hdrCandidate": pair.get("hdrPath"),
        "pairConfidence": "EXPLICIT",
        "existingRole": pair.get("existingRole"),
        "expectedRelation": pair.get("expectedRelation"),
        "pairOrigin": pair.get("pairOrigin"),
        "sourceDataset": "LIVE Paired Comparison HDR vs. SDR Database"
        if pair.get("contentFamily") == "LIVE" else "user-provided-local",
        "provenanceSource": pair.get("manifestPath"),
        "virginFrozen": pair.get("virginFrozen"),
        "technicalQualification": "NOT_RUN",
        "byteIdentity": "NOT_READ",
    }


def build_pair_inventory(
    media_records: Sequence[Mapping[str, Any]],
    current_pairs: Sequence[Mapping[str, Any]],
    excluded_roots: Sequence[str],
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]], Set[str], List[Dict[str, Any]]]:
    media_paths = {record["relativePath"] for record in media_records}
    pairs: List[Dict[str, Any]] = []
    excluded_pairs: List[Dict[str, Any]] = []
    pair_paths: Set[str] = set()

    for pair in current_pairs:
        sdr_path = pair.get("sdrPath")
        hdr_path = pair.get("hdrPath")
        if not sdr_path or not hdr_path:
            excluded_pairs.append({**pair, "status": "INVALID_EXPLICIT_LOCATOR"})
            continue
        if any(is_under_root(candidate, root) for candidate in (sdr_path, hdr_path) for root in excluded_roots):
            excluded_pairs.append({**pair, "status": "PROTECTED_ROOT_EXCLUDED"})
            continue
        if sdr_path not in media_paths or hdr_path not in media_paths:
            excluded_pairs.append({**pair, "status": "EXACT_MEDIA_NOT_PRESENT"})
            continue
        group = explicit_pair_group(pair)
        pairs.append(group)
        pair_paths.update((sdr_path, hdr_path))

    live_buckets: Dict[str, Dict[str, List[Mapping[str, Any]]]] = defaultdict(lambda: {"SDR": [], "HDR": []})
    for record in media_records:
        relative_path = record["relativePath"]
        if not is_live_asset(relative_path) or relative_path in pair_paths:
            continue
        hint = record["nameHint"]
        if hint not in {"SDR", "HDR"}:
            continue
        live_buckets[live_variant_key(record["fileName"])] [hint].append(record)

    heuristic_pairs: List[Dict[str, Any]] = []
    for pair_key in sorted(live_buckets):
        bucket = live_buckets[pair_key]
        if len(bucket["SDR"]) == 1 and len(bucket["HDR"]) == 1:
            group = inferred_pair_group(bucket["SDR"][0], bucket["HDR"][0], pair_key)
            heuristic_pairs.append(group)
            pair_paths.update((group["sdrCandidate"], group["hdrCandidate"]))
        elif bucket["SDR"] or bucket["HDR"]:
            excluded_pairs.append(
                {
                    "candidateGroupId": f"heuristic-live:{pair_key}",
                    "status": "AMBIGUOUS_VARIANT_MATCH",
                    "sdrCandidates": [entry["relativePath"] for entry in bucket["SDR"]],
                    "hdrCandidates": [entry["relativePath"] for entry in bucket["HDR"]],
                }
            )
    pairs.extend(heuristic_pairs)

    return pairs, excluded_pairs, pair_paths, heuristic_pairs


def unpaired_group_summary(
    media_records: Sequence[Mapping[str, Any]],
    paired_paths: Set[str],
) -> Dict[str, Any]:
    groups: Dict[str, Dict[str, Any]] = {}
    unknown_files: List[str] = []
    for record in media_records:
        if record["relativePath"] in paired_paths:
            continue
        memberships = record.get("manifestMembership", [])
        source_families = sorted(
            {entry.get("sourceFamily") for entry in memberships if entry.get("sourceFamily")}
        )
        if source_families:
            key = f"external:{source_families[0]}"
            identity_status = "INFERRED"
            provenance = "external-manifest sourceFamily; source master not declared"
        else:
            key = f"unpaired:{record['parentPath']}"
            identity_status = "UNKNOWN"
            provenance = "no pair or source-master metadata"
        group = groups.setdefault(
            key,
            {
                "groupId": key,
                "sourceMasterId": None,
                "familyIdentityStatus": identity_status,
                "pairStatus": "UNPAIRED",
                "provenanceSource": provenance,
                "media": [],
            },
        )
        group["media"].append(record["relativePath"])
        if record["nameHint"] == "UNKNOWN":
            unknown_files.append(record["relativePath"])
    return {
        "groups": [groups[key] for key in sorted(groups)],
        "unknownMediaFiles": sorted(unknown_files),
    }


def count_families(pair_groups: Sequence[Mapping[str, Any]]) -> Dict[str, Any]:
    proven = {entry["sourceMasterId"] for entry in pair_groups if entry.get("sourceMasterId")}
    inferred = {
        entry.get("inferredSourceMasterId")
        for entry in pair_groups
        if entry.get("familyIdentityStatus") == "INFERRED" and entry.get("inferredSourceMasterId")
    }
    unknown = {
        entry.get("candidateGroupId")
        for entry in pair_groups
        if entry.get("familyIdentityStatus") == "UNKNOWN"
    }
    return {
        "provenIndependentPairedFamilies": sorted(proven),
        "likelyIndependentPairedFamilies": sorted(inferred),
        "unknownFamilies": sorted(unknown),
    }


def render_markdown(inventory: Mapping[str, Any]) -> str:
    summary = inventory["summary"]
    roots = inventory["scope"]["includedRoots"]
    pair_counts = summary["pairConfidenceCounts"]
    lines = [
        "# Existing Local Development Corpus Inventory",
        "",
        "This inventory uses only committed, explicitly approved non-Frozen development roots.",
        "It records filesystem metadata and manifest relationships; it does not read media bytes, hash media, invoke ffprobe, decode frames, or run objective metrics.",
        "",
        "## Scope",
        "",
        f"- Correctness baseline: `{inventory['correctnessBaseline']}`",
        f"- Scope status: `{inventory['scope']['status']}`",
        f"- Materialization root: `{inventory['materializationRoot']}` (exact known manifest base; not a production default)",
        f"- Approved roots scanned: {len(roots)}",
        "- Protected root enumeration: `NO`",
        "- Objective evaluations: `0`",
        "",
        "Approved roots:",
        "",
    ]
    lines.extend(f"- `{entry['path']}`" for entry in roots)
    lines.extend(
        [
            "",
            "Protected historical roots were excluded by path identity. `data_video/video3` is excluded because historical manifests mark it Frozen despite conflicting later metadata; `data_video/video6` is excluded because manifest-v2 marks it Frozen. Their directories were not accessed.",
            "",
            "## Inventory summary",
            "",
            f"- Media candidate files: {summary['mediaCandidateFiles']}",
            f"- Explicit SDR/HDR pair groups: {summary['explicitPairGroups']}",
            f"- Strong pair groups: {summary['strongPairGroups']}",
            f"- Heuristic pair groups: {summary['heuristicPairGroups']}",
            f"- Unknown media files: {summary['unknownMediaFiles']}",
            f"- SDR-only groups: {summary['sdrOnlyGroups']}",
            f"- HDR-only groups: {summary['hdrOnlyGroups']}",
            f"- Qualified SDR/HDR families: {summary['qualifiedSDRHDRFamilies']} (technical qualification not run)",
            f"- Metadata mismatches: `{summary['metadataMismatches']}` (ffprobe not run)",
            f"- Technical qualification: `{summary['technicalQualification']}`",
            "",
            "Pair confidence counts:",
            "",
            f"- EXPLICIT: {pair_counts['EXPLICIT']}",
            f"- STRONG: {pair_counts['STRONG']}",
            f"- HEURISTIC: {pair_counts['HEURISTIC']}",
            f"- UNKNOWN: {pair_counts['UNKNOWN']}",
            "",
            "## Source-master reconstruction",
            "",
            f"- Proven independent paired families: {len(summary['provenIndependentPairedFamilies'])}",
            f"- Likely independent paired families (inferred only): {len(summary['likelyIndependentPairedFamilies'])}",
            f"- Unknown paired families: {len(summary['unknownFamilies'])}",
            "",
            "The current manifests provide explicit pair relationships and per-pair group labels, but no authoritative `sourceMasterId`. Inferred groups remain development leads and are not promotion-grade evidence.",
            "",
            f"- K-Choreo candidate groups: {summary['kChoreoCandidateGroups']}",
            f"- LIVE candidate groups: {summary['liveCandidateGroups']}",
            f"- Existing coarse family overlap: {json.dumps(summary['existingCoarseFamilyOverlap'], ensure_ascii=False)}",
            f"- Candidate family overlap: `{summary['candidateFamilyOverlap']}`",
            f"- Source-master independence: `{summary['sourceMasterIndependence']}`",
            "",
            "## Pair and qualification limits",
            "",
            "- Existing role assignments were recorded as evidence only; no new Tune/Validation split was created.",
            "- Pair identity for additional LIVE files is filename-based and marked `HEURISTIC`.",
            "- No current media SHA-256 was computed.",
            "- No frame alignment, temporal compatibility, or pixel inspection was performed.",
            "- Existing external-manifest media are SDR-only and do not create paired calibration families.",
            "",
            "## Decision",
            "",
            f"- Existing local corpus status: `{summary['existingLocalCorpusStatus']}`",
            f"- Inferred corpus status: `{summary['inferredCorpusStatus']}`",
            f"- Promotion-grade available: `{summary['promotionGradeAvailable']}`",
            f"- External dataset required: `{summary['externalDatasetRequired']}`",
            "- Tune: `NO`",
            "- Validation: `NO`",
            "- Frozen accessed: `NO`",
            "- Objective evaluations: `0`",
            "",
            "The inventory is a discovery and provenance screen only. It does not emit the v5 calibration manifest and does not authorize calibration search.",
            "",
        ]
    )
    return "\n".join(lines)


def run(
    scope_path: Path,
    output_path: Path,
    doc_path: Path,
    materialization_root: Path,
) -> Dict[str, Any]:
    scope, included_entries, excluded_roots = load_scope(scope_path)
    if not materialization_root.is_absolute():
        raise InventoryError("materialization root must be an explicit absolute path")
    if materialization_root.is_symlink():
        raise InventoryError("materialization root must not be a symlink")
    if materialization_root.resolve() not in {base.resolve() for base in known_manifest_locator_bases()}:
        raise InventoryError("materialization root is not an exact base from the committed v6 manifest")
    if not materialization_root.exists() or not materialization_root.is_dir():
        raise InventoryError(f"materialization root is unavailable: {materialization_root}")
    membership, current_pairs, historical_conflicts = build_manifest_membership()

    raw_records: List[Dict[str, Any]] = []
    root_counts: Dict[str, int] = {}
    missing_roots: List[str] = []
    for entry in included_entries:
        root_relative = entry["path"]
        root_records = walk_approved_root(materialization_root, root_relative, excluded_roots)
        if not (materialization_root / root_relative).exists():
            missing_roots.append(root_relative)
        root_counts[root_relative] = len(root_records)
        raw_records.extend(root_records)

    media_records = file_records_with_membership(raw_records, membership)
    pair_groups, excluded_pairs, paired_paths, heuristic_pairs = build_pair_inventory(
        media_records,
        current_pairs,
        excluded_roots,
    )
    unpaired = unpaired_group_summary(media_records, paired_paths)
    family_counts = count_families(pair_groups)

    pair_confidence_counts = Counter(entry["pairConfidence"] for entry in pair_groups)
    pair_origin_counts = Counter(entry["pairOrigin"] for entry in pair_groups)
    source_dataset_counts = Counter(entry["sourceDataset"] for entry in pair_groups)
    kchoreo_groups = {
        entry.get("candidateGroupId")
        for entry in pair_groups
        if entry.get("contentFamily") == "K-Choreo"
    }
    live_groups = {
        entry.get("inferredSourceMasterId") or entry.get("candidateGroupId")
        for entry in pair_groups
        if entry.get("contentFamily") == "LIVE"
    }
    coarse_roles: Dict[str, Set[str]] = defaultdict(set)
    for pair in current_pairs:
        if pair.get("contentFamily") and pair.get("existingRole") in {"tune", "validation"}:
            coarse_roles[pair["existingRole"]].add(pair["contentFamily"])
    coarse_overlap = sorted(coarse_roles.get("tune", set()) & coarse_roles.get("validation", set()))

    proven_family_count = len(family_counts["provenIndependentPairedFamilies"])
    likely_family_count = len(family_counts["likelyIndependentPairedFamilies"])
    if proven_family_count >= 4:
        corpus_status = "PROMOTION_GRADE_AVAILABLE"
        inferred_status = "PROMOTION_GRADE_AVAILABLE"
        external_required = "NO"
    elif proven_family_count >= 2:
        corpus_status = "MINIMUM_VIABLE"
        inferred_status = "MINIMUM_VIABLE"
        external_required = "UNDECIDED"
    elif likely_family_count >= 6:
        corpus_status = "INSUFFICIENT"
        inferred_status = "PROMISING_INFERRED_ONLY"
        external_required = "YES"
    elif likely_family_count >= 4:
        corpus_status = "INSUFFICIENT"
        inferred_status = "MARGINAL_INFERRED_ONLY"
        external_required = "YES"
    else:
        corpus_status = "INSUFFICIENT"
        inferred_status = "INSUFFICIENT"
        external_required = "YES"

    inventory: Dict[str, Any] = {
        "inventoryVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "correctnessBaseline": scope["correctnessBaseline"],
        "pr": scope.get("pr"),
        "materializationRoot": str(materialization_root),
        "scope": {
            "status": scope["status"],
            "scopeArtifact": "results/development-corpus-inventory-scope.json",
            "includedRoots": included_entries,
            "excludedProtectedRoots": scope.get("excludedProtectedRoots", []),
            "excludedBroadRoots": scope.get("excludedBroadRoots", []),
        },
        "metadataSources": list(KNOWN_METADATA_PATHS),
        "rootCounts": root_counts,
        "missingRoots": missing_roots,
        "media": media_records,
        "pairGroups": pair_groups,
        "excludedPairGroups": excluded_pairs,
        "unpairedGroups": unpaired["groups"],
        "historicalFrozenRoleRecords": historical_conflicts,
        "execution": {
            "protectedRootEnumerated": False,
            "protectedMetadataProbed": False,
            "protectedBytesRead": False,
            "mediaBytesRead": False,
            "mediaHashed": False,
            "ffprobeRun": False,
            "mediaDecoded": False,
            "frameExtracted": False,
            "visualInspection": False,
            "objectiveMetricsRun": False,
            "tuneRun": False,
            "validationRun": False,
            "objectiveEvaluations": 0,
        },
        "summary": {
            "approvedDevelopmentRootsScanned": len(included_entries) - len(missing_roots),
            "mediaCandidateFiles": len(media_records),
            "explicitPairGroups": pair_confidence_counts["EXPLICIT"],
            "strongPairGroups": pair_confidence_counts["STRONG"],
            "heuristicPairGroups": pair_confidence_counts["HEURISTIC"],
            "unknownPairGroups": pair_confidence_counts["UNKNOWN"],
            "unknownMediaFiles": len(unpaired["unknownMediaFiles"]),
            "explicitSDRHDRPairs": pair_confidence_counts["EXPLICIT"],
            "strongSDRHDRPairs": pair_confidence_counts["STRONG"],
            "heuristicSDRHDRPairs": pair_confidence_counts["HEURISTIC"],
            "pairOriginCounts": dict(sorted(pair_origin_counts.items())),
            "sourceDatasetCounts": dict(sorted(source_dataset_counts.items())),
            "qualifiedSDRHDRFamilies": 0,
            "sdrOnlyGroups": sum(1 for group in unpaired["groups"] if any(
                entry.get("nameHint") == "SDR" for entry in media_records if entry["relativePath"] in group["media"]
            )),
            "hdrOnlyGroups": sum(1 for group in unpaired["groups"] if any(
                entry.get("nameHint") == "HDR" for entry in media_records if entry["relativePath"] in group["media"]
            )),
            "metadataMismatches": "NOT_RUN",
            "technicalQualification": "NOT_RUN",
            "pairConfidenceCounts": {
                "EXPLICIT": pair_confidence_counts["EXPLICIT"],
                "STRONG": pair_confidence_counts["STRONG"],
                "HEURISTIC": pair_confidence_counts["HEURISTIC"],
                "UNKNOWN": pair_confidence_counts["UNKNOWN"],
            },
            **family_counts,
            "kChoreoCandidateGroups": len(kchoreo_groups),
            "liveCandidateGroups": len(live_groups),
            "existingCoarseFamilyOverlap": coarse_overlap,
            "candidateFamilyOverlap": "NOT_EVALUATED_NO_NEW_SPLIT",
            "sourceMasterIndependence": "UNKNOWN_NO_AUTHORITATIVE_SOURCE_MASTER_ID",
            "historicalFrozenConflictCount": len(historical_conflicts),
            "excludedPairGroupCount": len(excluded_pairs),
            "existingLocalCorpusStatus": corpus_status,
            "inferredCorpusStatus": inferred_status,
            "promotionGradeAvailable": corpus_status == "PROMOTION_GRADE_AVAILABLE",
            "externalDatasetRequired": external_required,
        },
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(inventory, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    doc_path.parent.mkdir(parents=True, exist_ok=True)
    doc_path.write_text(render_markdown(inventory), encoding="utf-8")
    return inventory


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", type=Path, default=DEFAULT_SCOPE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--doc", type=Path, default=DEFAULT_DOC)
    parser.add_argument("--media-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        inventory = run(args.scope, args.output, args.doc, args.media_root)
    except (InventoryError, OSError, ValueError, KeyError) as error:
        print(f"development corpus inventory: FAIL: {error}")
        return 1
    summary = inventory["summary"]
    print("development corpus inventory: PASS")
    print(f"approved roots scanned: {summary['approvedDevelopmentRootsScanned']}")
    print(f"media candidate files: {summary['mediaCandidateFiles']}")
    print(f"explicit/strong/heuristic pairs: {summary['explicitPairGroups']}/{summary['strongPairGroups']}/{summary['heuristicPairGroups']}")
    print(f"proven/likely paired families: {len(summary['provenIndependentPairedFamilies'])}/{len(summary['likelyIndependentPairedFamilies'])}")
    print(f"existing local corpus: {summary['existingLocalCorpusStatus']}")
    print("protected roots enumerated: NO")
    print("media bytes read/hashed/decoded: NO/NO/NO")
    print("objective evaluations: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
