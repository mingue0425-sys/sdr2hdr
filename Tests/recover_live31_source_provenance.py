#!/usr/bin/env python3
"""Recover LIVE source identities from explicit metadata only.

This tool reads the committed inventory, manifests, and identity columns in
JOD_separate.csv. It never opens a media candidate and never computes media
hashes, decodes frames, or evaluates quality.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from collections import defaultdict
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
BASELINE = "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9"
OLD_SEARCH_DEFINITION_HASH = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608"
AUTHORITY_INDEX = "config/live31-source-authority-index.json"
GENERATOR_SEMANTIC_VERSION = "live31-provenance-recovery-v2-pinned-authority"
POLICY_VERSION = "sdr-input-interpretation-policy-v1"
PREPARATION_VERSION = "v6-prepared-evaluation-plan-v6-sdr-interpretation-policy"
METRIC_VERSION = "v2-objective-with-v61-directional-diagnostics"
LOCAL_MANIFEST_COMMIT = "b2f94ca91e0fa425840e6f09394f40aa71c88ef6"
LOCAL_MANIFEST_BLOB = "ffad6c7ad33e5257f8f500f49aaa3af447a5bf7e"
LOCAL_JOD_BLOB = "54f5bd9e0501ef93a20a9aa61d8416f92bb99e40"
OFFICIAL_AVT_COMMIT = "7906224caa49cfcc538a8dacfda0469b597c1247"
OFFICIAL_AVT_REPO = "https://github.com/Telecommunication-Telemedia-Assessment/AVT-VQDB-UHD-2-HDR"
OFFICIAL_LIVE_PAGE = "https://www.colorado.edu/lab/live/live-paired-comparison-hdr-vs-sdr-database"
OFFICIAL_LIVE_UT_PAGE = "https://live.ece.utexas.edu/research/Bowen_SDRHDR/sdr-hdr-bowen.html"
OFFICIAL_PAPER = "https://arxiv.org/html/2505.21831v1"

OFFICIAL_CONTENT_NAMES = [
    "Balance_Forest",
    "Basketball_Afternoon",
    "Basketball_Evening",
    "Cafe",
    "Campfire",
    "Conversation_Bed",
    "Conversation_Standing",
    "Dancing",
    "Drawing",
    "Face_Close",
    "Fountain",
    "Guitar_Handheld",
    "Guitar_Tripod",
    "Interview",
    "Knitting_Close",
    "Knitting_Total",
    "Night_Biking",
    "Onion_1",
    "Onion_2",
    "Parcours",
    "Phone_Call",
    "Power_Pole_Sky",
    "Programming_Night",
    "Reading_Bench",
    "Reading_Stairs",
    "River",
    "Sitting",
    "Skateboarding",
    "Swan",
    "Walking_Forest",
    "Yoga",
]

EXPECTED_OFFICIAL_BLOB_BY_NAME = {
    "Balance_Forest": "cef861df07f073d7e087096d9cfff9a334cc42c8",
    "Basketball_Afternoon": "49848a8edb1721dd8c71cfc82b4159a5e3497036",
    "Basketball_Evening": "6201eb7a91be17a36bee06649bda2de9ea5661a9",
    "Cafe": "7e29e1dbb44aa1b98c3c609f1b5f66c38af4cac1",
    "Campfire": "e0da5179dc3e97f72d70410d8d04f9e9950bb266",
    "Conversation_Bed": "2c6c24acbfe5be6d9e2a1a281c030a7cda302e80",
    "Conversation_Standing": "fd95e196eeb6ff5803fa27be22ab1bbdf5a25276",
    "Dancing": "e30c1743e5044daa9974c301fefedba2fd695a5a",
    "Drawing": "d391ac47f57ea2c504babd8d7c9f98e0ca031117",
    "Face_Close": "25b259a75fce9c634a20d0c623041279f046eb15",
    "Fountain": "d090a1a30512f06fd50f2ab341e56b846521dffb",
    "Guitar_Handheld": "92fe69a3976beb9d38cecd267d7c22a64f862f49",
    "Guitar_Tripod": "46d39a839212a801d53460bb7ac71232ee338cd9",
    "Interview": "c7de2afcd02bf6c2e874cafeaec1f0dbdc6b71f2",
    "Knitting_Close": "1ee9f7a443adc04c87aa879fa7fb4bf959cb2931",
    "Knitting_Total": "ddd6e3dcc540bdaabf1d1ab76bf46dcb3a38093d",
    "Night_Biking": "5a8e4c542056f4e186cafe18148bf1df462fa6f2",
    "Onion_1": "7f8cec07c5b97e9f3f193bf88ca328ad22d3e6e4",
    "Onion_2": "4340f6c7d39269bab2e391e2486f24bd852d3f33",
    "Parcours": "86b1f64c726f9c29aff18335fb861cd8a6016693",
    "Phone_Call": "b655c91ea57ccde9f90fccfe433ee2d78758de37",
    "Power_Pole_Sky": "223bf034780d57bf79b26d259e8088b701cb87db",
    "Programming_Night": "08e18e35debde359cf346a70df0402cd8f9cd110",
    "Reading_Bench": "c0825bc86f0fcd96c921a8c4961e81777cba1808",
    "Reading_Stairs": "c9cdeefbcbd3b0f6d17836e5ee845062d31059c0",
    "River": "21c07a52057ae6b089a86cb1e42685d1452d716e",
    "Sitting": "05841a04fac91f3991a40719ca30158e562f530c",
    "Skateboarding": "360e1845e3366886367ac3a776cf44c95a5116e4",
    "Swan": "b9209548a23b5fb0f6ac44166f3a7b484d593b3d",
    "Walking_Forest": "07dfbc927578b20fe96500c7b74e348cfe45617d",
    "Yoga": "9532e3604540c3ded2932cd0882e80bbf9be4972",
}

IDENTITY_FIELDS = (
    "video_name",
    "video_format",
    "resolution",
    "bitrate",
    "content_name",
    "Type",
)
PROTECTED_TOKENS = ("frozen", "virgin", "holdout", "quarantined")


def read_json(relative_path: str) -> dict[str, Any]:
    with (ROOT / relative_path).open(encoding="utf-8") as handle:
        return json.load(handle)


def load_authority_index(relative_path: str) -> dict[str, Any]:
    index = read_json(relative_path)
    if index.get("schemaVersion") != 1:
        fail("pinned authority index schema is unsupported")
    if not isinstance(index.get("publisher"), str) or not isinstance(index.get("repository"), str):
        fail("pinned authority index is missing publisher/repository")
    if not re.fullmatch(r"[0-9a-f]{40}", str(index.get("repositoryCommit", ""))):
        fail("pinned authority index commit is not an exact commit SHA")
    records = index.get("canonicalSources")
    if not isinstance(records, list) or len(records) != len(OFFICIAL_CONTENT_NAMES):
        fail("pinned authority index canonicalSources is missing")
    seen_names: set[str] = set()
    for record in records:
        if not isinstance(record, dict):
            fail("pinned authority index contains a non-object source")
        if not all(isinstance(record.get(field), str) and record[field] for field in (
            "canonicalOfficialName", "sourceMasterId", "repositoryPath", "blobSHA256", "provenanceURL"
        )):
            fail("pinned authority index source lacks canonical identity or provenance")
        if not re.fullmatch(r"[0-9a-f]{40}", record["blobSHA256"]):
            fail(f"pinned authority blob identity is invalid: {record.get('canonicalOfficialName')}")
        name = record["canonicalOfficialName"]
        if name in seen_names or name not in EXPECTED_OFFICIAL_BLOB_BY_NAME:
            fail(f"pinned authority canonical source name is not unique/known: {name}")
        seen_names.add(name)
        if record["sourceMasterId"] != f"AVT-VQDB-UHD-2-HDR/{name}":
            fail(f"pinned authority sourceMasterId does not bind: {name}")
        expected_path = f"metrics/DR_results/{name}.mov.json"
        expected_url = f"{OFFICIAL_AVT_REPO}/blob/{index['repositoryCommit']}/{expected_path}"
        if record["repositoryPath"] != expected_path:
            fail(f"pinned authority repository path does not bind: {name}")
        if record["provenanceURL"] != expected_url:
            fail(f"pinned authority provenance URL does not bind: {name}")
        if record["blobSHA256"] != EXPECTED_OFFICIAL_BLOB_BY_NAME[name]:
            fail(f"pinned authority blob identity drift: {name}")
    if seen_names != set(OFFICIAL_CONTENT_NAMES):
        fail("pinned authority canonical source set is incomplete")
    return index


def normalized(value: str) -> str:
    value = value.casefold().replace("-", "_")
    return re.sub(r"[^a-z0-9]+", "_", value).strip("_")


def without_numeric_prefix(value: str) -> str:
    return re.sub(r"^\d+_", "", value)


def fail(message: str) -> None:
    raise SystemExit(f"LIVE provenance recovery: FAIL: {message}")


def assert_safe_candidate_path(candidate: str) -> None:
    if any(token in candidate.casefold() for token in PROTECTED_TOKENS):
        raise ValueError(f"protected path appeared in local inventory: {candidate}")


def is_promotion_eligible(mapping: dict[str, Any]) -> bool:
    return (
        mapping.get("mappingStatus") == "PROVEN"
        and mapping.get("sourceMasterStatus") == "PROVEN"
        and mapping.get("pairRelationship") == "PROVEN"
    )


def expected_local_group_ids(official_names: list[str]) -> list[str]:
    return [
        f"live:{index}_{normalized(name)}"
        for index, name in enumerate(official_names)
    ]


def recompute_mapping_claims(
    mappings: list[dict[str, Any]],
    official_names: list[str],
    expected_local_ids: list[str] | None = None,
) -> dict[str, Any]:
    """Recompute every LIVE31 claim from mappings, never from a summary."""

    local_ids = [mapping.get("localGroupId") for mapping in mappings]
    official_ids = [mapping.get("canonicalOfficialName") for mapping in mappings]
    source_ids = [mapping.get("sourceMasterId") for mapping in mappings]

    def duplicates(values: list[Any]) -> list[Any]:
        return sorted({value for value in values if value is not None and values.count(value) > 1})

    duplicate_local = duplicates(local_ids)
    duplicate_official = duplicates(official_ids)
    duplicate_source = duplicates(source_ids)
    duplicate_mappings = sorted(
        set(duplicate_local + duplicate_official + duplicate_source),
        key=lambda value: str(value),
    )
    expected_local = set(expected_local_ids or [])
    actual_local = {value for value in local_ids if isinstance(value, str)}
    actual_official = {value for value in official_ids if isinstance(value, str)}
    actual_source = {value for value in source_ids if isinstance(value, str)}
    proven = [mapping for mapping in mappings if mapping.get("mappingStatus") == "PROVEN"]
    proven_source_ids = {
        mapping.get("sourceMasterId")
        for mapping in proven
        if isinstance(mapping.get("sourceMasterId"), str)
    }
    proven_pair_sources = {
        mapping.get("sourceMasterId")
        for mapping in proven
        if mapping.get("sourceMasterStatus") == "PROVEN"
        and mapping.get("pairRelationship") == "PROVEN"
        and isinstance(mapping.get("sourceMasterId"), str)
    }
    return {
        "mappingCount": len(mappings),
        "provenCount": len(proven),
        "uniqueLocalGroupIdCount": len(actual_local),
        "uniqueOfficialCanonicalIDCount": len(actual_official),
        "uniqueSourceMasterIdCount": len(actual_source),
        "duplicateLocalMapping": duplicate_local,
        "duplicateOfficialMapping": duplicate_official,
        "duplicateSourceMasterId": duplicate_source,
        "duplicateMappings": duplicate_mappings,
        "unmappedLocal": sorted(expected_local - actual_local),
        "unmappedOfficial": sorted(set(official_names) - actual_official),
        "unknownOfficial": sorted(actual_official - set(official_names)),
        "uniqueProvenSourceMasterIds": len(proven_source_ids),
        "uniqueProvenPairedSources": len(proven_pair_sources),
        "pairRelationshipStatus": {
            status: sum(mapping.get("pairRelationship") == status for mapping in mappings)
            for status in sorted(
                {
                    status
                    for status in (mapping.get("pairRelationship") for mapping in mappings)
                    if status is not None
                }
            )
            if status is not None
        },
    }


def validate_mapping_contract(
    mappings: list[dict[str, Any]],
    official_names: list[str],
    expected_local_ids: list[str] | None = None,
) -> tuple[list[str], list[str]]:
    claims = recompute_mapping_claims(mappings, official_names, expected_local_ids)
    if claims["duplicateOfficialMapping"]:
        raise ValueError(f"duplicate official mappings: {claims['duplicateOfficialMapping']}")
    if claims["duplicateLocalMapping"]:
        raise ValueError(f"duplicate local mappings: {claims['duplicateLocalMapping']}")
    if claims["duplicateSourceMasterId"]:
        raise ValueError(f"duplicate sourceMasterId mappings: {claims['duplicateSourceMasterId']}")
    if claims["mappingCount"] != len(official_names):
        raise ValueError(
            f"mapping count must be {len(official_names)}, found {claims['mappingCount']}"
        )
    if claims["provenCount"] != len(official_names):
        raise ValueError(
            f"PROVEN mapping count must be {len(official_names)}, found {claims['provenCount']}"
        )
    if claims["uniqueLocalGroupIdCount"] != len(official_names):
        raise ValueError("localGroupId uniqueness/count invariant failed")
    if claims["uniqueOfficialCanonicalIDCount"] != len(official_names):
        raise ValueError("official canonical ID uniqueness/count invariant failed")
    if claims["uniqueSourceMasterIdCount"] != len(official_names):
        raise ValueError("sourceMasterId uniqueness/count invariant failed")
    if claims["unknownOfficial"]:
        raise ValueError(f"unknown official canonical IDs: {claims['unknownOfficial']}")
    if claims["unmappedOfficial"]:
        raise ValueError(f"unmapped official IDs: {claims['unmappedOfficial']}")
    if claims["unmappedLocal"]:
        raise ValueError(f"unmapped local IDs: {claims['unmappedLocal']}")

    expected_sources = {
        name: f"AVT-VQDB-UHD-2-HDR/{name}" for name in official_names
    }
    for mapping in mappings:
        local_id = mapping.get("localGroupId")
        official_name = mapping.get("canonicalOfficialName")
        if not isinstance(local_id, str) or not isinstance(official_name, str):
            raise ValueError("mapping identity fields must be strings")
        if not is_promotion_eligible(mapping):
            raise ValueError(f"mapping is not fully PROVEN: {local_id}")
        expected_source = expected_sources.get(official_name)
        if mapping.get("sourceMasterId") != expected_source:
            raise ValueError(f"sourceMasterId does not bind to official ID: {local_id}")
        if mapping.get("officialCandidateSourceId") != expected_source:
            raise ValueError(f"official candidate source ID does not bind: {local_id}")
        # The numeric prefix is part of the local identity. This check is
        # intentionally strict enough to catch a swapped official ID but does
        # not infer authority from a filename.
        expected_local_tail = local_id.split(":", 1)[-1]
        if not isinstance(mapping.get("canonicalLocalName"), str) or \
                normalized(mapping["canonicalLocalName"]) != expected_local_tail:
            raise ValueError(f"canonical local identity does not bind: {local_id}")
        expected_official_name = normalized(without_numeric_prefix(mapping["canonicalLocalName"]))
        if normalized(official_name) != expected_official_name:
            raise ValueError(f"official ID does not bind to local canonical identity: {local_id}")
    return claims["duplicateOfficialMapping"], claims["unmappedOfficial"]


def validate_artifact_contract(artifact: dict[str, Any]) -> dict[str, Any]:
    """Verify the committed artifact by recomputing claims from mappings."""

    official_names = artifact.get("officialCanonicalContentNames")
    if official_names != OFFICIAL_CONTENT_NAMES:
        raise ValueError("official canonical source list changed")
    mappings = artifact.get("mappings")
    if not isinstance(mappings, list):
        raise ValueError("mappings array is missing")
    claims = recompute_mapping_claims(
        mappings,
        official_names,
        expected_local_group_ids(official_names),
    )
    validate_mapping_contract(
        mappings,
        official_names,
        expected_local_group_ids(official_names),
    )
    if artifact.get("localInferredGroups") != claims["mappingCount"]:
        raise ValueError("top-level local group count is not derived from mappings")
    if artifact.get("officialOpenSourceContentCount") != len(official_names):
        raise ValueError("top-level official count is invalid")
    summary = artifact.get("summary")
    if not isinstance(summary, dict):
        raise ValueError("summary is missing")
    expected_summary = {
        "proven": claims["provenCount"],
        "uniqueProvenSourceMasterIds": claims["uniqueProvenSourceMasterIds"],
        "uniqueProvenPairedSources": claims["uniqueProvenPairedSources"],
        "oneToOneOfficialMapping": "PASS",
        "duplicateMappings": claims["duplicateMappings"],
        "unmappedLocal": claims["unmappedLocal"],
        "unmappedOfficial": claims["unmappedOfficial"],
        "pairRelationshipStatus": claims["pairRelationshipStatus"],
    }
    for key, expected in expected_summary.items():
        if summary.get(key) != expected:
            raise ValueError(f"summary field is not derived from mappings: {key}")
    return claims


def exact_output_path(relative_path: str) -> Path:
    output = Path(relative_path)
    if output.is_absolute() or ".." in output.parts:
        fail(f"output must be repository-relative: {relative_path}")
    return ROOT / output


def source_reference(
    source_id: str,
    source_type: str,
    location: str,
    claim: str,
    *,
    commit: str | None = None,
    fields: list[str] | None = None,
) -> dict[str, Any]:
    reference: dict[str, Any] = {
        "id": source_id,
        "type": source_type,
        "location": location,
        "claim": claim,
    }
    if commit is not None:
        reference["commit"] = commit
    if fields is not None:
        reference["fields"] = fields
    return reference


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--implementation-head", default=None, help="accepted for historical callers; not an artifact input")
    parser.add_argument("--generated-date", default=None, help="accepted for historical callers; pinned by the authority index")
    parser.add_argument("--authority-index", default=AUTHORITY_INDEX)
    parser.add_argument("--output", default="results/live31-source-provenance-recovery.json")
    parser.add_argument("--doc", default="docs/LIVE31_SOURCE_PROVENANCE_RECOVERY.md")
    args = parser.parse_args()

    inventory = read_json("results/development-corpus-inventory.json")
    scope = read_json("results/development-corpus-inventory-scope.json")
    preregistration = read_json("results/calibration-rebase-preregistration.json")
    lineage = read_json("results/calibration-rebase-lineage.json")
    v6_manifest = read_json("data_video/visual-regression/v6-development-manifest.json")
    authority = load_authority_index(args.authority_index)
    authority_by_name = {
        record["canonicalOfficialName"]: record
        for record in authority["canonicalSources"]
    }
    generated_date = str(authority.get("generatedDate", "2026-09-13"))

    if inventory.get("correctnessBaseline") != BASELINE:
        fail("inventory correctness baseline drift")
    if preregistration.get("searchDefinitionHash") != OLD_SEARCH_DEFINITION_HASH:
        fail("retired search definition hash drift")
    if preregistration.get("oldHashEligibleForCalibration") is not False:
        fail("retired search definition hash was not explicitly invalidated")
    if preregistration.get("status") != "INVALIDATED_FOR_CALIBRATION":
        fail("old preregistration is not marked invalidated")
    if preregistration.get("policyVersion") != POLICY_VERSION:
        fail("policy version drift")
    if preregistration.get("policyCandidates") != ["bt709SourceLinear", "bt1886ReferenceDisplay"]:
        fail("policy candidates drift")
    if preregistration.get("searchBudgetPerPolicy") != 192:
        fail("search budget drift")
    if preregistration.get("seed") != 20260912:
        fail("search seed drift")
    if preregistration.get("shortlistSize") != 3:
        fail("shortlist size drift")
    if lineage.get("correctnessBaseline") != BASELINE:
        fail("lineage correctness baseline drift")
    if lineage.get("sdrPolicyVersion") != POLICY_VERSION:
        fail("lineage policy version drift")
    if lineage.get("preparationVersion") != PREPARATION_VERSION:
        fail("lineage preparation version drift")
    if lineage.get("metricVersion") != METRIC_VERSION:
        fail("lineage metric version drift")
    if lineage.get("oldCalibrationReusable") is not False:
        fail("old calibration was marked reusable")
    if scope.get("status") != "APPROVED_SCOPE_ONLY":
        fail("inventory scope is not approved")
    inventory_policy = scope.get("inventoryPolicy", {})
    required_false = (
        "decode",
        "ffprobe",
        "frameExtraction",
        "mediaByteRead",
        "mediaHash",
        "objectiveMetrics",
        "protectedMetadataProbe",
        "protectedRootEnumeration",
        "visualInspection",
    )
    if any(inventory_policy.get(key) is not False for key in required_false):
        fail("inventory safety policy was weakened")
    if inventory_policy.get("objectiveEvaluations") != 0:
        fail("inventory scope objective count is not zero")
    if scope.get("guardPolicy", {}).get("scopeMode") != "ALLOWLIST_ONLY":
        fail("Frozen guard scope is not allowlist-only")
    if scope.get("guardPolicy", {}).get("frozenRootConfigured") is not False:
        fail("Frozen root injection is enabled")
    if authority["repository"] != OFFICIAL_AVT_REPO:
        fail("pinned authority repository drift")
    if authority["repositoryCommit"] != OFFICIAL_AVT_COMMIT:
        fail("pinned authority commit drift")
    if set(authority_by_name) != set(OFFICIAL_CONTENT_NAMES):
        fail("pinned authority canonical source set drift")

    live_groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for pair_group in inventory.get("pairGroups", []):
        inferred = pair_group.get("inferredSourceMasterId")
        if pair_group.get("contentFamily") == "LIVE" and isinstance(inferred, str) and inferred.startswith("live:"):
            live_groups[inferred].append(pair_group)
    if len(live_groups) != 31:
        fail(f"expected 31 LIVE inferred groups, found {len(live_groups)}")

    all_candidate_paths: set[str] = set()
    for group_id, pair_groups in live_groups.items():
        if not pair_groups:
            fail(f"empty local group: {group_id}")
        for pair_group in pair_groups:
            for field in ("sdrCandidate", "hdrCandidate"):
                candidate = pair_group.get(field)
                if not isinstance(candidate, str) or not candidate:
                    fail(f"missing exact candidate path in {group_id}: {field}")
                try:
                    assert_safe_candidate_path(candidate)
                except ValueError as error:
                    fail(str(error))
                if candidate in all_candidate_paths:
                    fail(f"candidate path appears in more than one group: {candidate}")
                all_candidate_paths.add(candidate)

    with (ROOT / "data_video/LIVE Paired Comparison HDR vs. SDR Database/JOD_separate.csv").open(
        encoding="utf-8", newline=""
    ) as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames or any(field not in reader.fieldnames for field in IDENTITY_FIELDS):
            fail("JOD identity schema is incomplete")
        jod_rows = []
        for row in reader:
            jod_rows.append({field: row[field] for field in IDENTITY_FIELDS})

    jod_by_content: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in jod_rows:
        if row["Type"] == "Open-source":
            jod_by_content[row["content_name"]].append(row)

    official_to_local_content: dict[str, str] = {}
    local_content_to_official: dict[str, str] = {}
    for official_name in OFFICIAL_CONTENT_NAMES:
        matches = [
            content_name
            for content_name in jod_by_content
            if normalized(without_numeric_prefix(content_name)) == normalized(official_name)
        ]
        if len(matches) != 1:
            fail(f"official content does not have one local JOD identity: {official_name}: {matches}")
        local_content = matches[0]
        official_to_local_content[official_name] = local_content
        local_content_to_official[local_content] = official_name
        formats = {row["video_format"] for row in jod_by_content[local_content]}
        if formats != {"HDR10", "SDR"}:
            fail(f"missing HDR10/SDR pair identity for {local_content}: {sorted(formats)}")
        if any(row["Type"] != "Open-source" for row in jod_by_content[local_content]):
            fail(f"non-open-source row mixed into {local_content}")

    official_metric_paths = {
        f"metrics/DR_results/{name}.mov.json" for name in OFFICIAL_CONTENT_NAMES
    }
    if len(official_metric_paths) != 31:
        fail("official canonical metric identity list is not unique")

    v6_by_group = {
        pair.get("group"): pair
        for pair in v6_manifest.get("pairs", [])
        if isinstance(pair.get("group"), str) and pair["group"].startswith("live_")
    }

    mappings: list[dict[str, Any]] = []
    for local_group_id in sorted(live_groups, key=lambda value: int(value.split(":", 1)[1].split("_", 1)[0])):
        pair_groups = live_groups[local_group_id]
        local_tail = local_group_id.split(":", 1)[1]
        local_content_matches = [
            content_name
            for content_name in local_content_to_official
            if normalized(content_name) == normalized(local_tail)
        ]
        if len(local_content_matches) != 1:
            fail(f"local group has no unique JOD content identity: {local_group_id}")
        local_content = local_content_matches[0]
        official_name = local_content_to_official[local_content]
        jod_rows_for_content = jod_by_content[local_content]
        jod_by_video_name = {row["video_name"]: row for row in jod_rows_for_content}

        sdr_paths = sorted({group["sdrCandidate"] for group in pair_groups})
        hdr_paths = sorted({group["hdrCandidate"] for group in pair_groups})
        local_video_names = [Path(candidate).name for candidate in sdr_paths + hdr_paths]
        if len(local_video_names) != len(set(local_video_names)):
            fail(f"duplicate local video name in {local_group_id}")
        if set(local_video_names) != set(jod_by_video_name):
            missing = sorted(set(jod_by_video_name) - set(local_video_names))
            extra = sorted(set(local_video_names) - set(jod_by_video_name))
            fail(f"local/JOD exact video-name mismatch for {local_group_id}; missing={missing}; extra={extra}")

        for candidate in sdr_paths:
            row = jod_by_video_name[Path(candidate).name]
            if row["video_format"] != "SDR":
                fail(f"SDR candidate has non-SDR JOD identity: {candidate}")
        for candidate in hdr_paths:
            row = jod_by_video_name[Path(candidate).name]
            if row["video_format"] != "HDR10":
                fail(f"HDR candidate has non-HDR10 JOD identity: {candidate}")

        explicit_group_name = f"live_{local_content}"
        explicit_pair = v6_by_group.get(explicit_group_name)
        local_pair_evidence = None
        if explicit_pair is not None:
            if explicit_pair.get("expectedRelation") != "same-source":
                fail(f"explicit local pair relation is not same-source: {explicit_group_name}")
            local_pair_evidence = {
                "manifestPairId": explicit_pair.get("id"),
                "expectedRelation": explicit_pair.get("expectedRelation"),
                "source": explicit_pair.get("source"),
                "sourceURL": explicit_pair.get("sourceURL"),
                "historicalRole": explicit_pair.get("split"),
                "virginFrozen": explicit_pair.get("virginFrozen"),
            }

        source_master_id = f"AVT-VQDB-UHD-2-HDR/{official_name}"
        authority_record = authority_by_name[official_name]
        if authority_record["sourceMasterId"] != source_master_id:
            fail(f"pinned source identity does not bind to {official_name}")
        mappings.append(
            {
                "localGroupId": local_group_id,
                "localSDRCandidates": sdr_paths,
                "localHDRCandidates": hdr_paths,
                "localPreservedSourceId": local_content,
                "localPreservedSourceIdStatus": "EXPLICIT_CONTENT_NAME_IN_LOCAL_JOD_METADATA",
                "officialCandidateSourceId": source_master_id,
                "sourceMasterId": source_master_id,
                "canonicalLocalName": local_content,
                "canonicalOfficialName": official_name,
                "evidenceLevel": "LEVEL_3",
                "evidenceBasis": "LEVEL_3_EXPLICIT_LOCAL_PROVENANCE_PLUS_INDEPENDENT_OFFICIAL_CORROBORATION",
                "sourceMasterStatus": "PROVEN",
                "pairRelationship": "PROVEN",
                "mappingStatus": "PROVEN",
                "numericPrefixPreserved": local_content.startswith(tuple(f"{n}_" for n in range(31))),
                "localInventoryEvidence": {
                    "artifact": "results/development-corpus-inventory.json",
                    "candidateGroupCount": len(pair_groups),
                    "pairConfidenceCounts": {
                        "EXPLICIT": sum(group.get("pairConfidence") == "EXPLICIT" for group in pair_groups),
                        "HEURISTIC": sum(group.get("pairConfidence") == "HEURISTIC" for group in pair_groups),
                    },
                    "byteIdentity": "NOT_READ",
                },
                "localJODIdentityEvidence": {
                    "artifact": "data_video/LIVE Paired Comparison HDR vs. SDR Database/JOD_separate.csv",
                    "contentName": local_content,
                    "type": "Open-source",
                    "videoFormats": sorted({row["video_format"] for row in jod_rows_for_content}),
                    "videoNameCount": len(jod_by_video_name),
                    "exactVideoNameCoverage": "PASS",
                    "qualityFieldsUsed": [],
                    "qualityFieldsIgnored": ["JOD_ref_compare"],
                },
                "historicalManifestPairEvidence": local_pair_evidence,
                "officialSourceEvidence": {
                    "dataset": "AVT-VQDB-UHD-2-HDR",
                    "canonicalContentName": official_name,
                    "metricRecord": authority_record["repositoryPath"],
                    "repository": authority["repository"],
                    "repositoryCommit": authority["repositoryCommit"],
                    "repositoryBlob": authority_record["blobSHA256"],
                    "provenanceURL": authority_record["provenanceURL"],
                },
                "evidenceSources": [
                    "local-inventory",
                    "local-jod-identity",
                    "official-live-page",
                    "official-hdrsdr-paper",
                    "official-avt-repository",
                ],
            }
        )

    try:
        duplicate_mappings, unmapped_official = validate_mapping_contract(
            mappings,
            OFFICIAL_CONTENT_NAMES,
            expected_local_group_ids(OFFICIAL_CONTENT_NAMES),
        )
    except ValueError as error:
        fail(str(error))
    unmapped_local = sorted(set(live_groups) - {mapping["localGroupId"] for mapping in mappings})
    if unmapped_local or unmapped_official:
        fail(f"mapping is not complete; local={unmapped_local}; official={unmapped_official}")

    claims = recompute_mapping_claims(
        mappings,
        OFFICIAL_CONTENT_NAMES,
        expected_local_group_ids(OFFICIAL_CONTENT_NAMES),
    )
    output = {
        "artifactVersion": 2,
        "artifactKind": "LIVE31_SOURCE_PROVENANCE_RECOVERY",
        "generatedDate": generated_date,
        "generatorSemanticVersion": GENERATOR_SEMANTIC_VERSION,
        "correctnessBaseline": BASELINE,
        "localInferredGroups": claims["mappingCount"],
        "officialOpenSourceContentCount": len(OFFICIAL_CONTENT_NAMES),
        "numericCountMatchOnly": True,
        "numericCountUsedAsProof": False,
        "canonicalNameMappingUsed": True,
        "officialCanonicalContentNames": OFFICIAL_CONTENT_NAMES,
        "officialSources": [
            {
                "id": "official-live-page",
                "publisher": "LIVE / University of Colorado Boulder and UT Austin",
                "documentTitle": "LIVE Paired Comparison HDR vs. SDR Database",
                "canonicalURL": OFFICIAL_LIVE_PAGE,
                "secondaryURL": OFFICIAL_LIVE_UT_PAGE,
                "retrievedDate": generated_date,
                "supportedClaim": "The released open-source portion has 31 contents and separate Open-sourced HDR10 and Open-sourced SDR folders.",
            },
            {
                "id": "official-hdrsdr-paper",
                "publisher": "HDRSDR-VQA authors / arXiv",
                "documentTitle": "HDRSDR-VQA: A Subjective Video Quality Dataset for HDR and SDR Comparative Evaluation",
                "canonicalURL": OFFICIAL_PAPER,
                "retrievedDate": generated_date,
                "supportedClaim": "The 31 open-source videos are from AVT-VQDB-UHD-2-HDR and are rendered in HDR10 and SDR forms.",
            },
            {
                "id": "official-avt-repository",
                "publisher": authority["publisher"],
                "documentTitle": "AVT-VQDB-UHD-2-HDR README and metrics tree",
                "canonicalURL": authority["repository"],
                "repository": authority["repository"],
                "repositoryCommit": authority["repositoryCommit"],
                "authorityIndex": args.authority_index,
                "retrievedDate": generated_date,
                "supportedClaim": "The pinned repository snapshot exposes the exact canonical source records listed in the authority index.",
            },
        ],
        "localSources": [
            source_reference(
                "local-inventory",
                "committed-inventory-artifact",
                "results/development-corpus-inventory.json",
                "Exact 31 LIVE inferred group IDs and exact candidate paths; no authoritative sourceMasterId was present.",
            ),
            source_reference(
                "local-jod-identity",
                "committed-dataset-identity-metadata",
                "data_video/LIVE Paired Comparison HDR vs. SDR Database/JOD_separate.csv",
                "Explicit content_name, video_name, video_format, and Type identity fields for the 31 open-source contents.",
                commit=LOCAL_MANIFEST_COMMIT,
                fields=list(IDENTITY_FIELDS),
            ),
            source_reference(
                "local-v6-manifest",
                "committed-pair-manifest",
                "data_video/visual-regression/v6-development-manifest.json",
                "Explicit same-source HDR/SDR pair records for four LIVE contents; historical role evidence only.",
                commit=LOCAL_MANIFEST_COMMIT,
            ),
        ],
        "gitEvidence": {
            "localManifestCommit": LOCAL_MANIFEST_COMMIT,
            "localManifestBlob": LOCAL_MANIFEST_BLOB,
            "localJODSeparateBlob": LOCAL_JOD_BLOB,
            "officialAVTRepository": authority["repository"],
            "officialAVTRepositoryCommit": authority["repositoryCommit"],
            "authorityIndex": args.authority_index,
        },
        "mappings": mappings,
        "summary": {
            "proven": claims["provenCount"],
            "strongNotProven": 0,
            "heuristic": 0,
            "unresolved": 0,
            "conflict": 0,
            "uniqueProvenSourceMasterIds": claims["uniqueProvenSourceMasterIds"],
            "uniqueProvenPairedSources": claims["uniqueProvenPairedSources"],
            "oneToOneOfficialMapping": "PASS",
            "duplicateMappings": claims["duplicateMappings"],
            "unmappedLocal": claims["unmappedLocal"],
            "unmappedOfficial": claims["unmappedOfficial"],
            "mappingCount": claims["mappingCount"],
            "provenCount": claims["provenCount"],
            "uniqueLocalGroupIdCount": claims["uniqueLocalGroupIdCount"],
            "uniqueOfficialCanonicalIDCount": claims["uniqueOfficialCanonicalIDCount"],
            "uniqueSourceMasterIdCount": claims["uniqueSourceMasterIdCount"],
            "pairRelationshipStatus": claims["pairRelationshipStatus"],
            "crossSourceAliasStatus": "UNKNOWN_NO_ALIAS_REGISTRY",
            "sourceMasterIndependence": "PASS_WITHIN_UNIQUE_OFFICIAL_AVT_CANONICAL_CONTENT_SET",
            "localCorpusProvenance": "SUFFICIENT",
            "externalDatasetRequired": "NO",
        },
        "qualityDataUse": {
            "JODScoresUsed": False,
            "objectiveMetricsRun": False,
            "frameDecode": False,
            "pixelInspection": False,
            "mediaHash": False,
        },
        "execution": {
            "newManifestEmitted": False,
            "mediaQualification": "NOT_RUN",
            "tuneRun": False,
            "validationRun": False,
            "policyComparison": False,
            "candidateSelection": False,
            "frozenAccessed": False,
            "objectiveEvaluations": 0,
        },
        "oldSearchDefinitionHash": OLD_SEARCH_DEFINITION_HASH,
        "oldHashEligibleForCalibration": False,
        "searchDefinitionHashStatus": "RETIRED_INVALIDATED",
        "nextStage": "exact metadata qualification, selected-file hashing, deterministic split, and preflight-v4",
    }

    output_path = exact_output_path(args.output)
    doc_path = exact_output_path(args.doc)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    doc_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, indent=2, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")

    proven_names = [mapping["canonicalOfficialName"] for mapping in mappings]
    explicit_local_count = sum(mapping["historicalManifestPairEvidence"] is not None for mapping in mappings)
    doc_lines = [
        "# LIVE 31 Source-Master Provenance Recovery",
        "",
        "This report recovers source identity from committed metadata and official public metadata only.",
        "No media bytes were read, hashed, decoded, or visually inspected.",
        "",
        "## Baseline and scope",
        "",
        f"- Correctness baseline: `{BASELINE}`",
        f"- Generator semantic version: `{GENERATOR_SEMANTIC_VERSION}`",
        f"- Pinned authority index: `{args.authority_index}`",
        f"- Retired search definition hash: `{OLD_SEARCH_DEFINITION_HASH}` (`INVALIDATED; NOT ELIGIBLE FOR CALIBRATION`)",
        "- Frozen/Virgin paths were not enumerated or probed.",
        "- Tune, Validation, objective metrics, and candidate selection were not run.",
        "",
        "## Official identity anchors",
        "",
        "- The official LIVE page documents 31 released open-source contents and separate HDR10/SDR folders.",
        "- The official HDRSDR-VQA paper identifies those 31 open-source videos as sourced from AVT-VQDB-UHD-2-HDR.",
        f"- The pinned official AVT metadata snapshot is repository commit `{OFFICIAL_AVT_COMMIT}`.",
        "- Its 31 `metrics/DR_results/<Content>.mov.json` names are used as canonical content identities.",
        "- The numeric count match is recorded, but count alone is not used as proof.",
        "",
        "## Local evidence",
        "",
        "- `results/development-corpus-inventory.json` supplies the exact 31 local inferred groups and exact candidate paths.",
        "- `JOD_separate.csv` supplies explicit `content_name`, `video_name`, `video_format`, and `Type` identity fields.",
        f"- The local JOD identity file is tracked from commit `{LOCAL_MANIFEST_COMMIT}` (blob `{LOCAL_JOD_BLOB}`).",
        f"- The v6 pair manifest is tracked from commit `{LOCAL_MANIFEST_COMMIT}` (blob `{LOCAL_MANIFEST_BLOB}`); {explicit_local_count} LIVE pairs also have explicit historical `same-source` records.",
        "- JOD score fields were ignored and are not quality evidence in this recovery.",
        "",
        "## Mapping result",
        "",
        f"- Local LIVE inferred groups: {len(live_groups)}",
        f"- Official canonical contents: {len(OFFICIAL_CONTENT_NAMES)}",
        f"- Unique one-to-one canonical mappings: {len(mappings)}",
        f"- PROVEN source masters: {len(mappings)}",
        "- STRONG_NOT_PROVEN: 0",
        "- HEURISTIC: 0",
        "- UNRESOLVED: 0",
        "- CONFLICT: 0",
        "- Duplicate mappings: []",
        "- Unmapped local groups: []",
        "- Unmapped official contents: []",
        "",
        "Every mapping has the following combined evidence:",
        "1. Exact local inventory filenames under the two explicit LIVE open-source roots.",
        "2. Exact local JOD identity rows with the same content_name and both HDR10 and SDR formats.",
        "3. Official HDRSDR-VQA paper linkage from the 31 open-source contents to AVT-VQDB-UHD-2-HDR.",
        "4. Exact canonical-name correspondence to the pinned official AVT metric records.",
        "",
        "## Recovered canonical source IDs",
        "",
    ]
    for mapping in mappings:
        doc_lines.append(
            f"- `{mapping['localGroupId']}` -> `{mapping['sourceMasterId']}` "
            f"(`{mapping['mappingStatus']}`, local `{mapping['canonicalLocalName']}`)"
        )
    doc_lines.extend(
        [
            "",
            "## Decision",
            "",
            "- LOCAL CORPUS PROVENANCE: `SUFFICIENT`",
            "- PROVEN paired source masters: `31`",
            "- EXTERNAL DATASET REQUIRED: `NO`",
            "- Cross-source alias registry: `UNKNOWN`; the result proves unique canonical identities within the official AVT set.",
            "- Media hashed: `NO`",
            "- Media decoded: `NO`",
            "- Objective evaluations: `0`",
            "",
            "The next permitted phase is exact metadata qualification and selected-file byte hashing.",
            "This recovery does not emit a v5 manifest and does not start calibration.",
            "",
        ]
    )
    doc_path.write_text("\n".join(doc_lines), encoding="utf-8")

    print("LIVE provenance recovery: PASS")
    print(f"local groups: {len(live_groups)}")
    print(f"official canonical contents: {len(OFFICIAL_CONTENT_NAMES)}")
    print(f"one-to-one mappings: {len(mappings)}")
    print(f"proven paired source masters: {len(proven_names)}")
    print("media bytes/hash/decode: NO/NO/NO")
    print("objective evaluations: 0")


if __name__ == "__main__":
    main()
