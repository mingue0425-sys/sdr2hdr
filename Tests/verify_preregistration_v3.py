#!/usr/bin/env python3
"""Regenerate and verify the execution-bound V3 preregistration.

This invokes only the typed semantic generator and the verify-only execution
binding. It does not open a manifest or media and performs zero evaluations.
"""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMMITTED = ROOT / "results/calibration-rebase-preregistration-v3.json"
V1 = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608"
V2 = "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41"


def canonical(path: Path) -> str:
    return json.dumps(
        json.loads(path.read_text(encoding="utf-8")),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def command_prefix() -> list[str]:
    binary = ROOT / ".build/debug/HDRCalibrate"
    return [str(binary)] if binary.is_file() else ["swift", "run", "HDRCalibrate"]


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=ROOT, text=True, capture_output=True)


def main() -> int:
    if not COMMITTED.is_file():
        print("V3 preregistration regeneration: FAIL: committed artifact is missing")
        return 1
    with tempfile.TemporaryDirectory(dir=ROOT, prefix=".preregistration-v3-") as temporary:
        generated = Path(temporary) / "calibration-rebase-preregistration-v3.json"
        result = run(command_prefix() + [
            "preregister-v3", "--output", str(generated.relative_to(ROOT))
        ])
        if result.returncode != 0:
            print(result.stdout, end="")
            print(result.stderr, end="")
            return result.returncode
        if canonical(generated) != canonical(COMMITTED):
            print("V3 preregistration regeneration: FAIL: committed artifact differs")
            return 1
        artifact = json.loads(generated.read_text(encoding="utf-8"))
        checks = [
            (artifact.get("artifactVersion") == 3, "artifact version is not V3"),
            (artifact.get("status") == "PREREGISTERED_V3_EXECUTION_BOUND_SEMANTIC_ONLY", "status is not current V3"),
            (artifact.get("preregistrationInvalidated") is False, "V3 is invalidated"),
            (artifact.get("retiredV1SearchDefinitionHash") == V1, "V1 lineage changed"),
            (artifact.get("invalidatedV2SearchDefinitionHash") == V2, "V2 lineage changed"),
            (artifact.get("corpusDefinitionHash") == "NOT_YET_CREATED", "corpus identity was created"),
            (artifact.get("experimentBindingHash") == "NOT_YET_CREATED", "experiment identity was created"),
            (artifact.get("objectiveEvaluations") == 0, "objective count is nonzero"),
            (artifact["searchDefinition"]["searchBudgetPerPolicy"] == 192, "budget is not 192"),
            (artifact["searchDefinition"]["searchAlgorithmDefinition"]["globalCandidateCount"] == 128, "global phase is not 128"),
            (artifact["searchDefinition"]["searchAlgorithmDefinition"]["localCandidateCount"] == 64, "local phase is not 64"),
            (artifact["searchDefinition"]["searchAlgorithmDefinition"]["phaseOrdering"] == ["sensitivity", "global", "local"], "phase ordering drift"),
            (artifact["searchDefinition"]["shortlistSize"] == 3, "shortlist is not 3"),
            (artifact["searchDefinition"]["splitSeed"] == 92, "split seed drift"),
            (set(artifact["preparationDefinition"]["policyConfigurations"]) == {
                "bt709SourceLinear", "bt1886ReferenceDisplay"
            }, "policy-specific preparation configurations drift"),
        ]
        for passed, reason in checks:
            if not passed:
                print(f"V3 preregistration regeneration: FAIL: {reason}")
                return 1

        verify = run(command_prefix() + [
            "run-preregistered", "--verify-only", "--preregistration",
            str(generated.relative_to(ROOT)),
        ])
        if verify.returncode != 0 or "runtime semantic identity match: PASS" not in verify.stdout:
            print(verify.stdout, end="")
            print(verify.stderr, end="")
            print("V3 execution binding: FAIL")
            return 1

        rejected = run(command_prefix() + [
            "run-preregistered", "--verify-only", "--seed", "20260823",
            "--preregistration", str(generated.relative_to(ROOT)),
        ])
        if rejected.returncode == 0 or "PREREGISTRATION_MISMATCH" not in (rejected.stdout + rejected.stderr):
            print("V3 override rejection: FAIL: legacy seed was accepted")
            return 1

    print("V3 preregistration regeneration: PASS")
    print("recovery exit: 0")
    print("canonical regenerated artifact == canonical committed artifact")
    print("runtime derived from seal: YES; runtime semantic identity match: PASS")
    print("override rejection: PASS; objective evaluations: 0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
