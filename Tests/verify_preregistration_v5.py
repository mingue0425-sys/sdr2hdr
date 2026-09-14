#!/usr/bin/env python3
"""Verify the media-free V5 execution-bound preregistration."""

from __future__ import annotations

import copy
import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "results/calibration-rebase-preregistration-v5.json"
BASELINE = "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9"
V4 = "bdbf705973fa43f92ab60435bfa04dc1656fdf52c4a8687070d1185b30c809fc"


def fail(message: str) -> None:
    raise SystemExit(f"V5 preregistration verification: FAIL: {message}")


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


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
    require(artifact.get("artifactVersion") == 5, "artifact version is not V5")
    require(artifact.get("status") == "PREREGISTERED_V5_EXECUTION_BOUND_SEMANTIC_ONLY", "V5 status drift")
    require(artifact.get("preregistrationInvalidated") is False, "V5 is invalidated")
    require(artifact.get("correctnessBaseline") == BASELINE, "baseline drift")
    require(artifact.get("invalidatedV4SearchDefinitionHash") == V4, "V4 historical identity drift")
    require(artifact.get("candidateShortlistSize") == 3, "candidate shortlist drift")
    requirement = artifact.get("validationCorpusRequirement")
    require(isinstance(requirement, dict), "validation corpus requirement missing")
    require(requirement.get("minimumValidationPairCount") == 6, "validation corpus cardinality drift")
    require(requirement.get("minimumValidationPairCount") != artifact.get("candidateShortlistSize"), "shortlist/cardinality collapsed")
    require(artifact.get("corpusDefinitionHash") == "NOT_YET_CREATED", "corpus identity exists")
    require(artifact.get("experimentBindingHash") == "NOT_YET_CREATED", "experiment identity exists")
    require(artifact.get("objectiveEvaluations") == 0, "objective evaluation was recorded")
    for key in (
        "policyDefinitionHashV5",
        "preparationDefinitionHashV5",
        "metricDefinitionHashV5",
        "colorScienceDefinitionHashV5",
        "gateDefinitionHashV5",
        "searchAlgorithmDefinitionHashV5",
        "runnerDefinitionHashV5",
        "bt709FinalRunnerSemanticHash",
        "bt1886FinalRunnerSemanticHash",
        "searchDefinitionHashV5",
    ):
        value = artifact.get(key)
        require(isinstance(value, str) and len(value) == 64 and value == value.lower(), f"{key} is not a V5 identity")
    search = artifact.get("searchDefinition")
    require(isinstance(search, dict), "search definition missing")
    require(search.get("candidatePolicies") == ["bt709SourceLinear", "bt1886ReferenceDisplay"], "policy set drift")
    require(search.get("searchBudgetPerPolicy") == 192, "budget drift")
    require(search.get("seed") == 20260912, "seed drift")
    require(search.get("candidateShortlistSize") == 3, "search shortlist drift")


def check_regeneration(committed: dict[str, object]) -> None:
    with tempfile.TemporaryDirectory(prefix="sdr2hdr-v5-prereg-") as directory:
        generated = Path(directory) / "regenerated.json"
        documentation = Path(directory) / "regenerated.md"
        result = run_cli(["preregister-v5", "--output", str(generated), "--documentation", str(documentation)])
        require(result.returncode == 0, f"V5 generator failed: {result.stdout}{result.stderr}")
        regenerated = load(generated)
        require(canonical(regenerated) == canonical(committed), "canonical regenerated V5 differs")
        require(documentation.is_file(), "V5 documentation missing")
    print("canonical regenerated V5 artifact == canonical committed artifact: PASS")


def check_verify_only() -> None:
    relative = str(ARTIFACT.relative_to(ROOT))
    result = run_cli(["run-preregistered-v5", "--verify-only", "--preregistration", relative])
    require(result.returncode == 0, f"V5 verify-only failed: {result.stdout}{result.stderr}")
    output = result.stdout + result.stderr
    for marker in (
        "V5 preregistered execution binding: PASS",
        "runtime derived from seal: YES",
        "policy-specific final runner identity match: PASS",
        "candidate shortlist: 3",
        "validation corpus minimum pairs: 6",
        "objective evaluations: 0",
        "media execution: NOT RUN",
    ):
        require(marker in output, f"V5 verify-only output missing: {marker}")
    print("V5 verify-only execution binding: PASS")


def check_overrides() -> None:
    relative = str(ARTIFACT.relative_to(ROOT))
    for override in (("--seed", "20260823"), ("--select", "8"), ("--policy", "bt709SourceLinear")):
        result = run_cli(["run-preregistered-v5", "--verify-only", *override, "--preregistration", relative])
        output = result.stdout + result.stderr
        require(result.returncode != 0, f"runtime override accepted: {' '.join(override)}")
        require("PREREGISTRATION_MISMATCH" in output, f"wrong override error: {' '.join(override)}")
    print("V5 runtime override rejection before candidate generation: PASS")


def check_adapter_mutation_rejection(artifact: dict[str, object]) -> None:
    mutated = copy.deepcopy(artifact)
    mutated["bt709FinalRunnerSemanticHash"] = "0" * 64
    search = mutated["searchDefinition"]
    require(isinstance(search, dict), "search object missing for mutation")
    search["bt709FinalRunnerSemanticHash"] = "0" * 64
    with tempfile.TemporaryDirectory(prefix="sdr2hdr-v5-mutation-") as directory:
        path = Path(directory) / "mutated.json"
        path.write_bytes(canonical(mutated))
        result = run_cli(["run-preregistered-v5", "--verify-only", "--preregistration", str(path)])
        output = result.stdout + result.stderr
        require(result.returncode != 0, "policy-specific final runner mutation accepted")
        require(
            "PREREGISTRATION" in output.upper() or "ENCODING FAILED" in output.upper(),
            "mutation failed without a preregistration error",
        )
    print("policy-specific final-runner adapter mutation rejection: PASS")


def main() -> int:
    artifact = load(ARTIFACT)
    check_artifact(artifact)
    check_regeneration(artifact)
    check_verify_only()
    check_overrides()
    check_adapter_mutation_rejection(artifact)
    print("V5 preregistration verification: PASS")
    print("media qualification/hash, corpus split/seal, Tune, Validation, Frozen evaluation: NOT RUN")
    print("objective evaluations: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
