#!/usr/bin/env python3
"""Independent Stage B re-audit for the frozen semantic-only v2 artifact.

The semantic checks in this file do not call the Swift canonicalizer.  They
recompute the documented JSON representation and SHA-256 identities in Python,
then run the focused adversarial and production-path tests as black boxes.
No protected or qualification media is opened by this audit.
"""

from __future__ import annotations

import copy
import hashlib
import json
import math
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PREREG = ROOT / "results/calibration-rebase-preregistration-v2.json"
LIVE31 = ROOT / "results/live31-source-provenance-recovery.json"
OLD_HASH = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608"


def fail(message: str) -> None:
    raise SystemExit(f"independent Stage B re-audit: FAIL: {message}")


def canonical(value: object) -> str:
    """Render the v2 canonical JSON contract without Swift code."""

    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            fail("non-finite value entered the independent canonicalizer")
        if value == 0:
            return "0"
        rendered = repr(value)
        if rendered.endswith(".0") and "e" not in rendered:
            rendered = rendered[:-2]
        return rendered.replace("e", "E")
    if isinstance(value, str):
        # Foundation JSONEncoder's canonical string encoding escapes solidus
        # characters; preserve that byte-level behavior independently here.
        return json.dumps(value, ensure_ascii=False, separators=(",", ":")).replace("/", "\\/")
    if isinstance(value, list):
        return "[" + ",".join(canonical(item) for item in value) + "]"
    if isinstance(value, dict):
        keys = list(value)
        if not all(isinstance(key, str) for key in keys):
            fail("non-string object key entered the independent canonicalizer")
        keys.sort(key=lambda key: key.encode("utf-8"))
        return "{" + ",".join(
            canonical(key) + ":" + canonical(value[key]) for key in keys
        ) + "}"
    fail(f"unsupported independent canonical value: {type(value).__name__}")


def digest(value: object) -> str:
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def assert_equal(actual: object, expected: object, label: str) -> None:
    if actual != expected:
        fail(f"{label}: expected {expected!r}, found {actual!r}")


def check_semantic_seal() -> None:
    artifact = json.loads(PREREG.read_text(encoding="utf-8"))
    assert_equal(artifact["artifactVersion"], 2, "artifact version")
    assert_equal(artifact["status"], "PREREGISTERED_V2_SEMANTIC_ONLY", "artifact status")
    assert_equal(artifact["preregistrationInvalidated"], False, "new invalidation flag")
    assert_equal(artifact["oldSearchDefinitionHash"], OLD_HASH, "retired hash")
    assert_equal(artifact["oldHashEligibleForCalibration"], False, "old hash eligibility")
    assert_equal(artifact["oldHashStatus"], "RETIRED_INVALIDATED", "old hash status")
    assert_equal(artifact["corpusDefinitionHash"], "NOT_YET_CREATED", "corpus identity")
    assert_equal(artifact["experimentBindingHash"], "NOT_YET_CREATED", "experiment identity")
    assert_equal(artifact["objectiveEvaluations"], 0, "objective count")

    for object_key, hash_key in (
        ("policyDefinition", "policyDefinitionHash"),
        ("preparationDefinition", "preparationDefinitionHash"),
        ("metricDefinition", "metricDefinitionHash"),
        ("searchDefinition", "searchDefinitionHashV2"),
    ):
        assert_equal(digest(artifact[object_key]), artifact[hash_key], hash_key)

    def changed(object_key: str, label: str, mutate: object) -> None:
        value = copy.deepcopy(artifact[object_key])
        mutate(value)
        if digest(value) == artifact[
            {
                "policyDefinition": "policyDefinitionHash",
                "preparationDefinition": "preparationDefinitionHash",
                "metricDefinition": "metricDefinitionHash",
                "searchDefinition": "searchDefinitionHashV2",
            }[object_key]
        ]:
            fail(f"semantic mutation did not change identity: {label}")

    changed("policyDefinition", "BT.1886 L_B", lambda value: value["bt1886Parameters"].update(blackLuminance=0.001))
    changed("policyDefinition", "BT.1886 L_W", lambda value: value["bt1886Parameters"].update(whiteLuminance=2))
    changed("policyDefinition", "BT.1886 gamma", lambda value: value["bt1886Parameters"].update(gamma=2.2))
    changed("policyDefinition", "candidate set", lambda value: value["candidateList"].append("sRGB"))
    changed("preparationDefinition", "preparationVersion", lambda value: value.update(preparationVersion="mutated"))
    changed("metricDefinition", "metricVersion", lambda value: value.update(metricVersion="mutated"))
    changed("metricDefinition", "metric direction", lambda value: value.update(direction="maximize"))
    changed("searchDefinition", "search budget", lambda value: value.update(searchBudgetPerPolicy=193))
    changed("searchDefinition", "seed", lambda value: value.update(seed=20260913))
    changed("searchDefinition", "parameter lower bound", lambda value: value["parameterBounds"]["paperWhiteNits"].update(lower=191))
    changed("searchDefinition", "parameter upper bound", lambda value: value["parameterBounds"]["paperWhiteNits"].update(upper=246))
    changed("searchDefinition", "hard gate", lambda value: value["hardGates"].append("mutated gate"))
    changed("searchDefinition", "safety gate", lambda value: value["safetyGates"].append("mutated safety"))
    changed("searchDefinition", "shortlist size", lambda value: value.update(shortlistSize=4))
    changed("searchDefinition", "tie-break", lambda value: value["tieBreakRule"].append("mutated tie-break"))
    changed("searchDefinition", "failure policy", lambda value: value["failurePolicy"].append("mutated failure"))
    changed("searchDefinition", "candidate set", lambda value: value["policyCandidates"].append("sRGB"))

    reordered = {key: artifact["policyDefinition"][key] for key in reversed(list(artifact["policyDefinition"]))}
    assert_equal(digest(reordered), artifact["policyDefinitionHash"], "cosmetic object-key order")
    assert_equal(canonical({"value": -0.0}), canonical({"value": 0.0}), "negative zero normalization")
    print("semantic seal v2: PASS (independent canonical recomputation and mutation matrix)")


def check_live31_bijection() -> None:
    artifact = json.loads(LIVE31.read_text(encoding="utf-8"))
    mappings = artifact.get("mappings")
    if not isinstance(mappings, list) or len(mappings) != 31:
        fail("LIVE31 mapping count is not 31")
    local_ids = [mapping.get("localGroupId") for mapping in mappings]
    official_ids = [mapping.get("canonicalOfficialName") for mapping in mappings]
    source_ids = [mapping.get("sourceMasterId") for mapping in mappings]
    if len(set(local_ids)) != 31 or len(set(official_ids)) != 31 or len(set(source_ids)) != 31:
        fail("LIVE31 identity uniqueness invariant failed")
    if any(mapping.get("mappingStatus") != "PROVEN" for mapping in mappings):
        fail("LIVE31 mapping status is not fully PROVEN")
    if any(mapping.get("sourceMasterStatus") != "PROVEN" for mapping in mappings):
        fail("LIVE31 source status is not fully PROVEN")
    if any(mapping.get("pairRelationship") != "PROVEN" for mapping in mappings):
        fail("LIVE31 pair status is not fully PROVEN")
    if any(
        mapping.get("sourceMasterId")
        != f"AVT-VQDB-UHD-2-HDR/{mapping.get('canonicalOfficialName')}"
        for mapping in mappings
    ):
        fail("LIVE31 sourceMasterId does not bind to official canonical ID")
    if artifact.get("summary", {}).get("duplicateMappings") != []:
        fail("LIVE31 summary reports duplicate mappings")
    if artifact.get("summary", {}).get("unmappedLocal") != []:
        fail("LIVE31 summary reports unmapped local IDs")
    if artifact.get("summary", {}).get("unmappedOfficial") != []:
        fail("LIVE31 summary reports unmapped official IDs")
    print("LIVE31 bijection: PASS (independent mapping claims)")


def run_black_box(label: str, command: list[str], *, metal_debug: bool = False) -> None:
    environment = os.environ.copy()
    if metal_debug:
        environment["MTL_DEBUG_LAYER"] = "1"
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        output = (result.stdout + result.stderr).splitlines()
        tail = "\n".join(output[-20:])
        fail(f"{label} failed with exit {result.returncode}\n{tail}")
    print(f"{label}: PASS")


def main() -> int:
    if not PREREG.is_file():
        fail("frozen v2 preregistration artifact is missing")
    check_semantic_seal()
    check_live31_bijection()

    run_black_box("v2 generator reproduction", [sys.executable, "Tests/verify_preregistration_v2.py"])
    run_black_box("LIVE31 regeneration", [sys.executable, "Tests/verify_live31_regeneration.py"])
    run_black_box("LIVE31 mutation tests", [sys.executable, "Tests/test_live31_source_provenance.py"])
    run_black_box("symlink adversarial matrix", [sys.executable, "Tests/test_inventory_development_corpus.py"])
    run_black_box(
        "old-plan relabel attack",
        [
            "swift", "test", "-c", "debug", "--disable-index-store",
            "--filter", "CalibrationTests/testPreparedPlanRelabelAttackWithNonEmptyStructuralDecisionsIsRejected",
        ],
    )
    run_black_box(
        "NV12/P010 independent CPU oracle",
        [
            "swift", "test", "-c", "debug", "--disable-index-store",
            "--filter", "P010Tests/testProductionNV12P010PolicyMatrixUsesIndependentCPUOracle",
        ],
        metal_debug=True,
    )
    run_black_box(
        "CPU/Metal BT.1886 edge parity",
        [
            "swift", "test", "-c", "debug", "--disable-index-store",
            "--filter", "SDRInterpretationPolicyTests/testBT1886PolicyReachesGPUAndScalarReference",
        ],
        metal_debug=True,
    )
    run_black_box(
        "fallback requested/selected diagnostics",
        [
            "swift", "test", "-c", "debug", "--disable-index-store",
            "--filter", "SDRInterpretationPolicyTests/testFrameDiagnosticsRetainRequestedAndSelectedPolicySeparately",
        ],
        metal_debug=True,
    )
    run_black_box(
        "BT.1886 invalid-domain fail-closed test",
        [
            "swift", "test", "-c", "debug", "--disable-index-store",
            "--filter", "SDRInterpretationPolicyTests/testBT1886InvalidDomainFailsBeforeDispatchAndInvalidScalarIsVisible",
        ],
    )
    print("independent Stage B re-audit: PASS")
    print("BLOCKER=0 HIGH=0")
    print("protected media bytes/stat/probe/hash/decode: NO")
    print("objective evaluations: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
