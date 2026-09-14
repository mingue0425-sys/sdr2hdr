#!/usr/bin/env python3
"""Verify the media-free V6 corpus-contract preregistration."""

from __future__ import annotations

import copy
import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "results/calibration-rebase-preregistration-v6.json"
BASELINE = "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9"
V4 = "bdbf705973fa43f92ab60435bfa04dc1656fdf52c4a8687070d1185b30c809fc"
V5 = "6ae84a8a245858c2328bfe2c80811f12cdd1375e86109ec2f83d4bd3a6cdb43e"


def fail(message: str) -> None:
    raise SystemExit(f"V6 preregistration verification: FAIL: {message}")


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def canonical(value: object) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def command_prefix() -> list[str]:
    binary = ROOT / ".build/debug/HDRCalibrate"
    return [str(binary)] if binary.is_file() else ["swift", "run", "HDRCalibrate"]


def run_cli(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command_prefix() + arguments, cwd=ROOT, text=True, capture_output=True, check=False)


def load(path: Path) -> dict[str, object]:
    require(path.is_file(), f"missing artifact: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"invalid JSON: {error}")
    require(isinstance(value, dict), "artifact root is not an object")
    return value


def check_artifact(artifact: dict[str, object]) -> None:
    require(artifact.get("artifactVersion") == 6, "artifact version is not V6")
    require(artifact.get("status") == "PREREGISTERED_V6_CORPUS_CONTRACT_EXECUTION_BOUND", "V6 status drift")
    require(artifact.get("preregistrationInvalidated") is False, "V6 is invalidated")
    require(artifact.get("correctnessBaseline") == BASELINE, "baseline drift")
    require(artifact.get("invalidatedV4SearchDefinitionHash") == V4, "V4 historical identity drift")
    require(artifact.get("invalidatedV5SearchDefinitionHash") == V5, "V5 historical identity drift")
    require(artifact.get("v5Status") == "AUDIT_INVALIDATED_BY_REAUDIT", "V5 status is not historical")
    require(artifact.get("candidateShortlistSize") == 3, "candidate shortlist drift")

    contract = artifact.get("corpusContract")
    require(isinstance(contract, dict), "typed corpus contract missing")
    require(contract.get("minimumTunePairCount") == 5, "Tune cardinality drift")
    require(contract.get("minimumValidationPairCount") == 6, "Validation cardinality drift")
    require(contract.get("tuneCardinalityOperator") == "AT_LEAST", "Tune cardinality operator drift")
    require(contract.get("validationCardinalityOperator") == "AT_LEAST", "Validation cardinality operator drift")
    require(contract.get("requiredFamilyLabels") == ["LIVE"], "family label drift")
    require(contract.get("familyDisjointRoles") is True, "family disjointness drift")
    coverage = contract.get("coverageRule")
    require(isinstance(coverage, dict), "typed coverage rule missing")
    require(coverage.get("requiredDimensions") == ["FAMILY_LABEL"], "coverage dimension drift")
    require(coverage.get("missingCategoryPolicy") == "REJECT_BEFORE_OBJECTIVE_EVALUATION", "coverage failure policy drift")

    for key in (
        "policyDefinitionHashV6",
        "preparationDefinitionHashV6",
        "metricDefinitionHashV6",
        "colorScienceDefinitionHashV6",
        "gateDefinitionHashV6",
        "searchAlgorithmDefinitionHashV6",
        "runnerDefinitionHashV6",
        "bt709FinalRunnerSemanticHashV6",
        "bt1886FinalRunnerSemanticHashV6",
        "searchDefinitionHashV6",
    ):
        value = artifact.get(key)
        require(isinstance(value, str) and len(value) == 64 and value == value.lower(), f"{key} is not a V6 identity")
    require(artifact.get("searchDefinitionHashV6") != V5, "V5 identity reused as V6")
    require(artifact.get("corpusDefinitionHash") == "NOT_YET_CREATED", "corpus identity exists")
    require(artifact.get("experimentBindingHash") == "NOT_YET_CREATED", "experiment identity exists")
    require(artifact.get("objectiveEvaluations") == 0, "objective evaluation was recorded")

    search = artifact.get("searchDefinition")
    require(isinstance(search, dict), "search definition missing")
    require(search.get("candidatePolicies") == ["bt709SourceLinear", "bt1886ReferenceDisplay"], "policy set drift")
    require(search.get("searchBudgetPerPolicy") == 192, "budget drift")
    require(search.get("seed") == 20260912, "seed drift")
    require(search.get("candidateShortlistSize") == 3, "search shortlist drift")
    require(search.get("corpusContract") == contract, "search/runner corpus contract diverged")


def check_regeneration(committed: dict[str, object]) -> None:
    with tempfile.TemporaryDirectory(prefix="sdr2hdr-v6-prereg-") as directory:
        generated = Path(directory) / "regenerated.json"
        documentation = Path(directory) / "regenerated.md"
        result = run_cli(["preregister-v6", "--output", str(generated), "--documentation", str(documentation)])
        require(result.returncode == 0, f"V6 generator failed: {result.stdout}{result.stderr}")
        regenerated = load(generated)
        require(canonical(regenerated) == canonical(committed), "canonical regenerated V6 differs")
        require(documentation.is_file(), "V6 documentation missing")
    print("canonical regenerated V6 artifact == canonical committed artifact: PASS")


def check_verify_only() -> None:
    relative = str(ARTIFACT.relative_to(ROOT))
    result = run_cli(["run-preregistered-v6", "--verify-only", "--preregistration", relative])
    require(
        result.returncode == 0,
        f"V6 verify-only failed (exit {result.returncode}): {result.stdout}{result.stderr}",
    )
    output = result.stdout + result.stderr
    for marker in (
        "V6 preregistration canonical validation: PASS",
        "V6 preregistered execution binding: PASS",
        "runtime derived from seal: YES",
        "corpus contract consumed by runner: YES",
        "policy-specific final runner identity match: PASS",
        "candidate shortlist: 3",
        "minimum Tune pairs: 5",
        "minimum Validation pairs: 6",
        "validation comparison: AT_LEAST",
        "family-disjoint roles: YES",
        "objective evaluations: 0",
        "media execution: NOT RUN",
    ):
        require(marker in output, f"V6 verify-only output missing: {marker}")
    print("V6 verify-only execution binding: PASS")

    result = run_cli(["verify-preregistration-v6", "--preregistration", relative])
    require(result.returncode == 0, f"canonical V6 validator failed: {result.stdout}{result.stderr}")
    print("canonical V6 validator: PASS")


def check_overrides() -> None:
    relative = str(ARTIFACT.relative_to(ROOT))
    for override in (("--seed", "20260823"), ("--select", "8"), ("--policy", "bt709SourceLinear")):
        result = run_cli(["run-preregistered-v6", "--verify-only", *override, "--preregistration", relative])
        output = result.stdout + result.stderr
        require(result.returncode != 0, f"runtime override accepted: {' '.join(override)}")
        require("PREREGISTRATION_MISMATCH" in output, f"wrong override error: {' '.join(override)}")
    print("V6 runtime override rejection before candidate generation: PASS")


def check_fake_hash_rejection(artifact: dict[str, object]) -> None:
    mutated = copy.deepcopy(artifact)
    contract = mutated["corpusContract"]
    require(isinstance(contract, dict), "contract missing for fake artifact")
    contract["minimumValidationPairCount"] = 3
    search = mutated["searchDefinition"]
    require(isinstance(search, dict), "search missing for fake artifact")
    search_contract = search["corpusContract"]
    require(isinstance(search_contract, dict), "search contract missing for fake artifact")
    search_contract["minimumValidationPairCount"] = 3
    with tempfile.TemporaryDirectory(prefix="sdr2hdr-v6-fake-") as directory:
        path = Path(directory) / "fake.json"
        path.write_bytes(canonical(mutated))
        result = run_cli(["verify-preregistration-v6", "--preregistration", str(path)])
        output = result.stdout + result.stderr
        require(result.returncode != 0, "fake V6 JSON with copied search hash was accepted")
        require("PREREGISTRATION" in output.upper() or "ENCODING FAILED" in output.upper(), "fake artifact failed opaquely")
    print("fake V6 artifact with copied hash text rejected: PASS")


def main() -> int:
    artifact = load(ARTIFACT)
    check_artifact(artifact)
    check_regeneration(artifact)
    check_verify_only()
    check_overrides()
    check_fake_hash_rejection(artifact)
    print("V6 preregistration verification: PASS")
    print("media qualification/hash, corpus split/seal, Tune, Validation, Frozen evaluation: NOT RUN")
    print("objective evaluations: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
