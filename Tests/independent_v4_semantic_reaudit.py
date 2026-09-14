#!/usr/bin/env python3
"""Bounded independent guard for the V4 re-audit.

This script checks lineage, artifact status, the bounded semantic inventory,
and the known unordered-reduction regression patterns. It intentionally does
not claim that a static script proves semantic completeness; the call-graph
inventory and typed-owner tests are the evidence under review.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "results/calibration-rebase-preregistration-v4.json"
INVENTORY = ROOT / "config/v4-semantic-source-inventory.json"
V1 = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608"
V2 = "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41"
V3 = "7a2fcf82bb40b45f774d942dac62a57d5c75b7cba16b5415a295ed8a68db8889"
AREAS = {
    "Preparation",
    "Matcher",
    "Metric / ICtCp / PQ",
    "Gate / ranking / failure",
    "Final runner adapter",
    "Deterministic ordering / reduction",
    "Materialization-root path safety",
}


def fail(message: str) -> None:
    raise SystemExit(f"bounded V4 static guard: FAIL: {message}")


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def load(path: Path) -> object:
    require(path.is_file(), f"missing {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid JSON in {path}: {error}")


def check_artifact() -> None:
    artifact = load(ARTIFACT)
    require(isinstance(artifact, dict), "artifact root is not an object")
    require(artifact.get("artifactVersion") == 4, "artifact is not V4")
    require(artifact.get("status") == "AUDIT_INVALIDATED", "V4 status drift")
    require(artifact.get("preregistrationInvalidated") is True, "V4 invalidation flag is false")
    require(artifact.get("retiredV1SearchDefinitionHash") == V1, "V1 lineage drift")
    require(artifact.get("invalidatedV2SearchDefinitionHash") == V2, "V2 lineage drift")
    require(artifact.get("invalidatedV3SearchDefinitionHash") == V3, "V3 lineage drift")
    require(artifact.get("corpusDefinitionHash") == "NOT_YET_CREATED", "corpus identity exists")
    require(artifact.get("experimentBindingHash") == "NOT_YET_CREATED", "experiment identity exists")
    require(artifact.get("objectiveEvaluations") == 0, "objective evaluation was recorded")


def check_inventory() -> None:
    inventory = load(INVENTORY)
    require(isinstance(inventory, dict), "inventory root is not an object")
    require(inventory.get("status") == "REVIEW_AID_NOT_PROOF", "inventory claim changed")
    require(inventory.get("staticCompletenessClaim") == "NOT_PROVEN_BY_STATIC_SCRIPT", "static claim overstates evidence")
    require(inventory.get("unownedSemanticConstants") == [], "inventory has an unowned semantic")
    entries = inventory.get("entries")
    require(isinstance(entries, list), "inventory entries are not a list")
    require({entry.get("area") for entry in entries} == AREAS, "bounded area inventory drift")
    required_keys = {
        "area",
        "runtimeSource",
        "semanticFields",
        "typedOwner",
        "identityOwner",
        "gap",
        "fix",
        "mutationTest",
        "classification",
    }
    for entry in entries:
        require(isinstance(entry, dict), "inventory entry is not an object")
        require(required_keys <= set(entry), f"incomplete inventory entry: {entry.get('area')}")


def check_known_ordering_regressions() -> None:
    bounded_files = (
        ROOT / "Sources/HDRCalibration/V2Metrics.swift",
        ROOT / "Sources/HDRCalibration/V2Runner.swift",
        ROOT / "Sources/HDRCalibration/V4Calibration.swift",
    )
    forbidden = ("Dictionary.values.reduce", "families.values")
    for path in bounded_files:
        text = path.read_text(encoding="utf-8")
        for token in forbidden:
            require(token not in text, f"known unordered reduction pattern remains: {path}:{token}")


def main() -> int:
    check_artifact()
    check_inventory()
    check_known_ordering_regressions()
    print("bounded independent V4 static guard: PASS")
    print("semantic completeness: NOT_PROVEN_BY_STATIC_SCRIPT")
    print("V4 semantic closure evidence remains the typed-owner call graph and mutation tests")
    print("protected media bytes/stat/probe/hash/decode: NO")
    print("objective evaluations: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
