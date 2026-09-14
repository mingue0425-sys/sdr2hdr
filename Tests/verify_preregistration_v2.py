#!/usr/bin/env python3
"""Verify that the historical V2 preregistration remains retired.

V2 is intentionally not regenerated as a current experiment. Its bytes and
identity remain for audit history, but the execution path must reject it.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "results/calibration-rebase-preregistration-v2.json"
V1 = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608"
V2 = "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41"


def main() -> int:
    if not ARTIFACT.is_file():
        print("historical V2 artifact: FAIL: artifact is missing")
        return 1
    artifact = json.loads(ARTIFACT.read_text(encoding="utf-8"))
    checks = [
        (artifact.get("searchDefinitionHashV2") == V2, "V2 identity changed"),
        (artifact.get("oldSearchDefinitionHash") == V1, "V1 identity changed"),
        (artifact.get("oldHashStatus") == "RETIRED_INVALIDATED", "V1 status is not retired"),
        (artifact.get("oldHashEligibleForCalibration") is False, "V1 remains eligible"),
        (artifact.get("preregistrationInvalidated") is True, "V2 invalidation flag is false"),
        (artifact.get("status") == "AUDIT_INVALIDATED", "V2 status is not audit-invalidated"),
        (artifact.get("corpusDefinitionHash") == "NOT_YET_CREATED", "corpus identity was created"),
        (artifact.get("experimentBindingHash") == "NOT_YET_CREATED", "experiment identity was created"),
        (artifact.get("objectiveEvaluations") == 0, "objective count is nonzero"),
    ]
    for passed, reason in checks:
        if not passed:
            print(f"historical V2 artifact: FAIL: {reason}")
            return 1
    print("historical V2 artifact: PASS")
    print("V1=RETIRED_INVALIDATED; V2=AUDIT_INVALIDATED; neither is calibration-eligible")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
