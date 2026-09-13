#!/usr/bin/env python3
"""Verify that the historical V3 preregistration remains invalidated.

V3 is retained as audit evidence only.  It is deliberately not regenerated
or accepted by the current execution API; V4 is the only current semantic
generator.  This guard performs no media access and no objective evaluation.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "results/calibration-rebase-preregistration-v3.json"
V1 = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608"
V2 = "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41"
V3 = "7a2fcf82bb40b45f774d942dac62a57d5c75b7cba16b5415a295ed8a68db8889"


def main() -> int:
    if not ARTIFACT.is_file():
        print("historical V3 artifact: FAIL: artifact is missing")
        return 1
    artifact = json.loads(ARTIFACT.read_text(encoding="utf-8"))
    checks = [
        (artifact.get("searchDefinitionHashV3") == V3, "V3 identity changed"),
        (artifact.get("retiredV1SearchDefinitionHash") == V1, "V1 identity changed"),
        (artifact.get("invalidatedV2SearchDefinitionHash") == V2, "V2 identity changed"),
        (artifact.get("preregistrationInvalidated") is True, "V3 invalidation flag is false"),
        (artifact.get("status") == "AUDIT_INVALIDATED", "V3 status is not audit-invalidated"),
        (artifact.get("corpusDefinitionHash") == "NOT_YET_CREATED", "corpus identity was created"),
        (artifact.get("experimentBindingHash") == "NOT_YET_CREATED", "experiment identity was created"),
        (artifact.get("objectiveEvaluations") == 0, "objective count is nonzero"),
    ]
    for passed, reason in checks:
        if not passed:
            print(f"historical V3 artifact: FAIL: {reason}")
            return 1
    print("historical V3 artifact: PASS")
    print("V1=RETIRED_INVALIDATED; V2=AUDIT_INVALIDATED; V3=AUDIT_INVALIDATED")
    print("V3 is not regenerated or calibration-eligible")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
