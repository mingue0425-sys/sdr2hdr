#!/usr/bin/env python3
"""Verify the media-free historical V4 artifact and its invalidation.

This verifier regenerates the historical V4 object from the pinned Swift
implementation, compares canonical JSON, and proves that the executable V4
entry point rejects it. It does not discover, hash, decode, qualify, or
evaluate media.
"""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "results/calibration-rebase-preregistration-v4.json"
BASELINE = "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9"
V1 = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608"
V2 = "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41"
V3 = "7a2fcf82bb40b45f774d942dac62a57d5c75b7cba16b5415a295ed8a68db8889"


def fail(message: str) -> None:
    raise SystemExit(f"V4 preregistration verification: FAIL: {message}")


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
    return subprocess.run(
        command_prefix() + arguments,
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def load_artifact(path: Path) -> dict[str, object]:
    require(path.is_file(), f"missing artifact: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"artifact is not valid UTF-8 JSON: {error}")
    require(isinstance(value, dict), "artifact root is not an object")
    return value


def check_artifact(artifact: dict[str, object]) -> None:
    require(artifact.get("artifactVersion") == 4, "artifact version is not V4")
    require(
        artifact.get("status") == "AUDIT_INVALIDATED",
        "artifact status drift",
    )
    require(artifact.get("preregistrationInvalidated") is True, "V4 invalidation flag is false")
    require(artifact.get("correctnessBaseline") == BASELINE, "correctness baseline drift")
    require(artifact.get("retiredV1SearchDefinitionHash") == V1, "V1 lineage drift")
    require(artifact.get("invalidatedV2SearchDefinitionHash") == V2, "V2 lineage drift")
    require(artifact.get("invalidatedV3SearchDefinitionHash") == V3, "V3 lineage drift")
    require(artifact.get("corpusDefinitionHash") == "NOT_YET_CREATED", "corpus identity exists")
    require(artifact.get("experimentBindingHash") == "NOT_YET_CREATED", "experiment identity exists")
    require(artifact.get("objectiveEvaluations") == 0, "objective evaluation was recorded")

    for key in (
        "colorScienceDefinitionHash",
        "policyDefinitionHashV4",
        "preparationDefinitionHashV4",
        "metricDefinitionHashV4",
        "gateDefinitionHash",
        "searchAlgorithmDefinitionHashV4",
        "runnerDefinitionHash",
        "searchDefinitionHashV4",
    ):
        value = artifact.get(key)
        require(isinstance(value, str) and len(value) == 64, f"{key} is not a V4 identity")

    seal = artifact.get("seal")
    require(isinstance(seal, dict), "seal is not an object")
    search = seal.get("searchDefinition")
    require(isinstance(search, dict), "search definition is not an object")
    algorithm = search.get("searchAlgorithmDefinition")
    require(isinstance(algorithm, dict), "search algorithm definition is not an object")
    runner = search.get("runnerDefinition")
    require(isinstance(runner, dict), "runner definition is not an object")

    require(
        search.get("policyCandidates") == ["bt709SourceLinear", "bt1886ReferenceDisplay"],
        "candidate policy set drift",
    )
    require(search.get("searchBudgetPerPolicy") == 192, "per-policy budget drift")
    require(search.get("seed") == 20260912, "seed drift")
    require(search.get("shortlistSize") == 3, "shortlist drift")
    require(algorithm.get("globalCandidateCount") == 128, "global budget drift")
    require(algorithm.get("localCandidateCount") == 64, "local budget drift")
    require(algorithm.get("totalCandidatesPerPolicy") == 192, "algorithm total drift")
    require(
        algorithm.get("phaseOrdering") == ["sensitivity", "global", "local"],
        "phase ordering drift",
    )
    require(isinstance(algorithm.get("parameterRepresentation"), dict), "parameter representation missing")
    require(isinstance(algorithm.get("sensitivityAxes"), list), "typed sensitivity axes missing")
    require(runner.get("requiredValidationPairCount") == 3, "final runner shortlist drift")


def check_regeneration(committed: dict[str, object]) -> None:
    with tempfile.TemporaryDirectory(prefix="sdr2hdr-v4-prereg-") as directory:
        generated = Path(directory) / "regenerated.json"
        documentation = Path(directory) / "regenerated.md"
        result = run_cli([
            "preregister-v4",
            "--output",
            str(generated),
            "--documentation",
            str(documentation),
        ])
        require(result.returncode == 0, f"V4 generator failed: {result.stdout}{result.stderr}")
        regenerated = load_artifact(generated)
        require(canonical(regenerated) == canonical(committed), "canonical regenerated artifact differs")
        require(documentation.is_file(), "generated V4 documentation is missing")
    print("canonical regenerated artifact == canonical committed artifact: PASS")


def check_verify_only() -> None:
    relative = str(ARTIFACT.relative_to(ROOT))
    result = run_cli(["run-preregistered", "--verify-only", "--preregistration", relative])
    require(result.returncode != 0, "invalidated V4 verify-only execution was accepted")
    output = result.stdout + result.stderr
    require("audit-invalidated" in output.lower(), "wrong V4 invalidation error")
    print("V4 verify-only execution rejection: PASS")


def check_overrides() -> None:
    relative = str(ARTIFACT.relative_to(ROOT))
    probes = (
        ["--seed", "20260823"],
        ["--select", "8"],
        ["--policy", "bt709SourceLinear"],
    )
    for override in probes:
        result = run_cli([
            "run-preregistered",
            "--verify-only",
            *override,
            "--preregistration",
            relative,
        ])
        output = result.stdout + result.stderr
        require(result.returncode != 0, f"runtime override accepted: {' '.join(override)}")
        require("PREREGISTRATION_MISMATCH" in output, f"wrong override error: {' '.join(override)}")
    print("V4 runtime override rejection before candidate generation: PASS")


def check_legacy_routes_are_not_preregistered() -> None:
    for command in ("v2-run", "v3-run", "v4-run"):
        result = run_cli([command])
        output = result.stdout + result.stderr
        require(result.returncode != 0, f"ambiguous legacy route was accepted: {command}")
        require("development" in output.lower() or "legacy" in output.lower(), f"legacy route was not labeled: {command}")
    print("legacy search routes explicitly separated from preregistered execution: PASS")


def main() -> int:
    committed = load_artifact(ARTIFACT)
    check_artifact(committed)
    check_regeneration(committed)
    check_verify_only()
    check_legacy_routes_are_not_preregistered()
    print("V4 historical invalidation verification: PASS")
    print("media qualification/hash/decode, Tune, Validation, Frozen evaluation: NOT RUN")
    print("objective evaluations: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
