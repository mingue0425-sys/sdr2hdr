#!/usr/bin/env python3
"""Focused contract tests for LIVE source provenance recovery."""

from __future__ import annotations

import json
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
        "canonicalOfficialName": official_name,
        "sourceMasterId": f"test/{official_name}",
        "mappingStatus": mapping_status,
        "sourceMasterStatus": source_status,
        "pairRelationship": pair_status,
    }


def test_current_artifact_contract() -> None:
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
    require(all(recovery.is_promotion_eligible(mapping) for mapping in artifact["mappings"]), "ineligible proven mapping")


def test_duplicate_official_mapping_is_rejected() -> None:
    mappings = [fake_mapping("local-a", "same"), fake_mapping("local-b", "same")]
    try:
        recovery.validate_mapping_contract(mappings, ["same"])
    except ValueError as error:
        require("duplicate official mappings" in str(error), "wrong duplicate failure")
    else:
        raise AssertionError("duplicate official mapping was accepted")


def test_same_official_source_for_two_local_source_ids_is_rejected() -> None:
    mappings = [fake_mapping("local-a", "same"), fake_mapping("local-b", "same")]
    mappings[0]["sourceMasterId"] = "source/id-a"
    mappings[1]["sourceMasterId"] = "source/id-b"
    try:
        recovery.validate_mapping_contract(mappings, ["same"])
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


if __name__ == "__main__":
    test_current_artifact_contract()
    test_duplicate_official_mapping_is_rejected()
    test_same_official_source_for_two_local_source_ids_is_rejected()
    test_numeric_count_alone_is_not_proven()
    test_missing_pair_relationship_is_not_eligible()
    test_protected_path_is_rejected()
    test_official_canonical_list_is_unique()
    print("LIVE 31 source provenance tests: PASS")
