#!/usr/bin/env python3
"""Focused contract tests for LIVE source provenance recovery."""

from __future__ import annotations

import json
import copy
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import recover_live31_source_provenance as recovery  # noqa: E402


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def fake_mapping(
    local_group: str,
    official_name: str,
    *,
    mapping_status: str = "PROVEN",
    source_status: str = "PROVEN",
    pair_status: str = "PROVEN",
) -> dict[str, str]:
    return {
        "localGroupId": local_group,
        "canonicalLocalName": local_group.split(":", 1)[-1],
        "canonicalOfficialName": official_name,
        "officialCandidateSourceId": f"AVT-VQDB-UHD-2-HDR/{official_name}",
        "sourceMasterId": f"AVT-VQDB-UHD-2-HDR/{official_name}",
        "mappingStatus": mapping_status,
        "sourceMasterStatus": source_status,
        "pairRelationship": pair_status,
    }


def test_current_artifact_contract() -> None:
    authority = json.loads(
        (ROOT / "config/live31-source-authority-index.json").read_text(encoding="utf-8")
    )
    require(authority["gitObjectFormat"] == "sha1", "Git object format is not explicit")
    require(
        all("gitBlobOID" in source and "blobSHA256" not in source for source in authority["canonicalSources"]),
        "Git blob OID field is mislabeled as SHA-256",
    )
    artifact = json.loads(
        (ROOT / "results/live31-source-provenance-recovery.json").read_text(encoding="utf-8")
    )
    require(artifact["localInferredGroups"] == 31, "local LIVE group count changed")
    require(artifact["officialOpenSourceContentCount"] == 31, "official count changed")
    require(artifact["numericCountMatchOnly"] is True, "count-match marker missing")
    require(artifact["numericCountUsedAsProof"] is False, "count used as proof")
    require(artifact["summary"]["proven"] == 31, "proven mapping count changed")
    require(artifact["summary"]["oneToOneOfficialMapping"] == "PASS", "one-to-one mapping failed")
    require(artifact["summary"]["duplicateMappings"] == [], "duplicate mapping recorded")
    require(artifact["summary"]["unmappedOfficial"] == [], "official mapping is incomplete")
    require(
        all(
            "gitBlobOID" in mapping["officialSourceEvidence"]
            and mapping["officialSourceEvidence"].get("gitObjectFormat") == "sha1"
            and "repositoryBlob" not in mapping["officialSourceEvidence"]
            for mapping in artifact["mappings"]
        ),
        "official Git identity field is mislabeled",
    )
    require(all(recovery.is_promotion_eligible(mapping) for mapping in artifact["mappings"]), "ineligible proven mapping")
    claims = recovery.validate_artifact_contract(artifact)
    require(claims["mappingCount"] == 31, "mapping claims were not recomputed")


def test_duplicate_official_mapping_is_rejected() -> None:
    mappings = [fake_mapping("local-a", "same"), fake_mapping("local-b", "same")]
    try:
        recovery.validate_mapping_contract(mappings, ["same"])
    except ValueError as error:
        require("duplicate official mappings" in str(error), "wrong duplicate failure")
    else:
        raise AssertionError("duplicate official mapping was accepted")


def test_same_official_source_for_two_local_source_ids_is_rejected() -> None:
    mappings = [fake_mapping("local-a", "official-a"), fake_mapping("local-b", "official-b")]
    mappings[0]["sourceMasterId"] = "AVT-VQDB-UHD-2-HDR/shared"
    mappings[1]["sourceMasterId"] = "AVT-VQDB-UHD-2-HDR/shared"
    try:
        recovery.validate_mapping_contract(mappings, ["official-a", "official-b"])
    except ValueError:
        pass
    else:
        raise AssertionError("two local source IDs shared one official source")


def test_numeric_count_alone_is_not_proven() -> None:
    require(31 == 31, "test premise changed")
    require(recovery.is_promotion_eligible(fake_mapping("local", "official")), "valid mapping rejected")
    require(
        not recovery.is_promotion_eligible(
            fake_mapping("local", "official", mapping_status="HEURISTIC", source_status="HEURISTIC", pair_status="UNKNOWN")
        ),
        "numeric or heuristic evidence promoted",
    )


def test_missing_pair_relationship_is_not_eligible() -> None:
    mapping = fake_mapping("local", "official", source_status="PROVEN", pair_status="UNKNOWN")
    require(not recovery.is_promotion_eligible(mapping), "missing pair relationship was eligible")
    try:
        recovery.validate_mapping_contract([mapping], ["official"])
    except ValueError:
        pass
    else:
        raise AssertionError("proven source without proven pair was accepted")


def test_protected_path_is_rejected() -> None:
    try:
        recovery.assert_safe_candidate_path("data_video/Frozen/hidden.mp4")
    except ValueError:
        pass
    else:
        raise AssertionError("protected candidate path was accepted")


def test_official_canonical_list_is_unique() -> None:
    require(len(recovery.OFFICIAL_CONTENT_NAMES) == 31, "official canonical list count changed")
    require(len(set(recovery.OFFICIAL_CONTENT_NAMES)) == 31, "official canonical names are duplicated")


def test_mapping_mutation_matrix_is_fail_closed() -> None:
    original = json.loads(
        (ROOT / "results/live31-source-provenance-recovery.json").read_text(encoding="utf-8")
    )

    mutations: dict[str, object] = {}

    deleted = copy.deepcopy(original)
    deleted["mappings"].pop()
    mutations["delete mapping"] = deleted

    duplicated = copy.deepcopy(original)
    duplicated["mappings"][1] = copy.deepcopy(duplicated["mappings"][0])
    mutations["duplicate mapping"] = duplicated

    swapped = copy.deepcopy(original)
    swapped["mappings"][0]["canonicalOfficialName"], swapped["mappings"][1]["canonicalOfficialName"] = (
        swapped["mappings"][1]["canonicalOfficialName"],
        swapped["mappings"][0]["canonicalOfficialName"],
    )
    mutations["swap official IDs"] = swapped

    duplicate_source = copy.deepcopy(original)
    duplicate_source["mappings"][1]["sourceMasterId"] = duplicate_source["mappings"][0]["sourceMasterId"]
    mutations["duplicate sourceMasterId"] = duplicate_source

    summary_only = copy.deepcopy(original)
    summary_only["summary"]["proven"] = 30
    mutations["alter summary only"] = summary_only

    mapping_only = copy.deepcopy(original)
    mapping_only["mappings"][0]["mappingStatus"] = "HEURISTIC"
    mutations["alter mapping only"] = mapping_only

    thirty_two = copy.deepcopy(original)
    thirty_two["mappings"].append(copy.deepcopy(thirty_two["mappings"][0]))
    mutations["insert 32nd fake mapping"] = thirty_two

    unknown = copy.deepcopy(original)
    unknown["mappings"][0]["canonicalOfficialName"] = "Unknown_Content"
    mutations["replace official ID with unknown"] = unknown

    missing_pair = copy.deepcopy(original)
    missing_pair["mappings"][0].pop("pairRelationship")
    mutations["remove pairRelationship proof"] = missing_pair

    for label, mutation in mutations.items():
        try:
            recovery.validate_artifact_contract(mutation)  # type: ignore[arg-type]
        except ValueError:
            continue
        raise AssertionError(f"LIVE31 mutation was accepted: {label}")


if __name__ == "__main__":
    test_current_artifact_contract()
    test_duplicate_official_mapping_is_rejected()
    test_same_official_source_for_two_local_source_ids_is_rejected()
    test_numeric_count_alone_is_not_proven()
    test_missing_pair_relationship_is_not_eligible()
    test_protected_path_is_rejected()
    test_official_canonical_list_is_unique()
    test_mapping_mutation_matrix_is_fail_closed()
    print("LIVE 31 source provenance tests: PASS")
