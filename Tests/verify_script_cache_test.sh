#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p \
  "$TEST_ROOT/data_video" \
  "$TEST_ROOT/dataset" \
  "$TEST_ROOT/results" \
  "$TEST_ROOT/Sources/HDRCalibration" \
  "$TEST_ROOT/Sources/HDRCore"
printf '{}\n' > "$TEST_ROOT/Package.swift"
printf '{}\n' > "$TEST_ROOT/data_video/manifest-v4.json"
printf '{"revision":1}\n' > "$TEST_ROOT/data_video/dataset-v4-lock.json"
printf '{}\n' > "$TEST_ROOT/dataset/holdout-provenance-v5.json"

set -- fast "$TEST_ROOT"
VERIFY_SCRIPT_LIBRARY_ONLY=1 source "$REPOSITORY_ROOT/RUN_MACOS_VERIFY.sh"

first_key="$(fingerprint audit)"
printf '{"revision":2}\n' > "$TEST_ROOT/data_video/dataset-v4-lock.json"
second_key="$(fingerprint audit)"
if [ "$first_key" = "$second_key" ]; then
  echo 'FAIL: data_video JSON mutation did not invalidate fingerprint' >&2
  exit 1
fi

printf 'first\n' > "$TEST_ROOT/Sources/HDRCore/Runtime.swift"
first_key="$(fingerprint audit)"
printf 'second\n' > "$TEST_ROOT/Sources/HDRCore/Runtime.swift"
second_key="$(fingerprint audit)"
if [ "$first_key" = "$second_key" ]; then
  echo 'FAIL: HDRCore mutation did not invalidate audit fingerprint' >&2
  exit 1
fi

printf 'validated artifact\n' > "$TEST_ROOT/results/audit.json"
cache_store audit test-input-key "$TEST_ROOT/results/audit.json"
cache_hit audit test-input-key "$TEST_ROOT/results/audit.json"

printf 'tampered artifact\n' > "$TEST_ROOT/results/audit.json"
if cache_hit audit test-input-key "$TEST_ROOT/results/audit.json"; then
  echo 'FAIL: mutated artifact was accepted by cache' >&2
  exit 1
fi

python3 - "$TEST_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
results = root / "results"
critical = {
    "holdoutProvenance",
    "transferCoverageSemantics",
    "frozenPairCountSemantics",
    "familyCoverageSemantics",
    "newHLGVirginHoldout",
    "realTemporalWindowPreparation",
    "temporalBurstParity",
    "runtime-measurement",
    "freeze-integrity",
    "v6FrozenPreparedEvaluationPlan",
    "v6PreparedEvaluationPlan",
}
checks = [
    {"id": check_id, "required": True, "executed": True, "status": "PASS"}
    for check_id in sorted(critical)
]
(results / "pre-v5-final-correctness.json").write_text(json.dumps({
    "verdict": "CORRECTNESS_READY_FOR_V6",
    "virginFrozenObjectiveEvaluationCount": 0,
    "objectiveEvaluationCount": 0,
    "checks": checks,
}), encoding="utf-8")
(results / "pre-v5-frozen-coverage-policy.json").write_text(json.dumps({
    "transferStatus": "PASS",
    "pairCountStatus": "PASS",
    "familyStatus": "PASS",
}), encoding="utf-8")
plan_hash = "a" * 64
(results / "v6-prepared-evaluation-plan.json").write_text(json.dumps({
    "planSHA256": plan_hash,
    "plan": {"pairOrder": ["pair"]},
}), encoding="utf-8")
(results / "v6-prepared-evaluation-plan.sha256").write_text(
    plan_hash + "\n", encoding="utf-8"
)
(results / "temporal-burst-parity.json").write_text(json.dumps({
    "status": "PASS",
    "evidence": {
        "counts": {"maxFramesInFlight": 2},
        "numerical": {"maxAbsoluteError": 0},
    },
}), encoding="utf-8")
PY

FAKE_CALIBRATOR="$TEST_ROOT/fake-calibrator"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_CALIBRATOR"
chmod +x "$FAKE_CALIBRATOR"
assert_pre_v6_ready "$FAKE_CALIBRATOR" >/dev/null

python3 - "$TEST_ROOT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]) / "results/pre-v5-final-correctness.json"
document = json.loads(path.read_text(encoding="utf-8"))
document["checks"].append({
    "id": "holdoutProvenance",
    "required": False,
    "executed": False,
    "status": "FAIL",
})
path.write_text(json.dumps(document), encoding="utf-8")
PY
if assert_pre_v6_ready "$FAKE_CALIBRATOR" >/dev/null 2>&1; then
  echo 'FAIL: duplicate critical check ID bypassed semantic gate' >&2
  exit 1
fi

python3 - "$TEST_ROOT" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1]) / "results/pre-v5-final-correctness.json"
document = json.loads(path.read_text(encoding="utf-8"))
document["checks"] = document["checks"][:-1]
document["objectiveEvaluationCount"] = False
path.write_text(json.dumps(document), encoding="utf-8")
PY
if assert_pre_v6_ready "$FAKE_CALIBRATOR" >/dev/null 2>&1; then
  echo 'FAIL: boolean objective count bypassed semantic gate' >&2
  exit 1
fi

python3 - "$TEST_ROOT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
final_path = root / "results/pre-v5-final-correctness.json"
document = json.loads(final_path.read_text(encoding="utf-8"))
document["objectiveEvaluationCount"] = 0
final_path.write_text(json.dumps(document), encoding="utf-8")
burst_path = root / "results/temporal-burst-parity.json"
burst = json.loads(burst_path.read_text(encoding="utf-8"))
burst["evidence"]["numerical"]["maxAbsoluteError"] = float("nan")
burst_path.write_text(json.dumps(burst), encoding="utf-8")
PY
if assert_pre_v6_ready "$FAKE_CALIBRATOR" >/dev/null 2>&1; then
  echo 'FAIL: NaN numerical evidence bypassed semantic gate' >&2
  exit 1
fi

python3 - "$TEST_ROOT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
burst_path = root / "results/temporal-burst-parity.json"
burst = json.loads(burst_path.read_text(encoding="utf-8"), parse_constant=lambda _: 0)
burst["evidence"]["numerical"]["maxAbsoluteError"] = 0
burst_path.write_text(json.dumps(burst), encoding="utf-8")
plan_path = root / "results/v6-prepared-evaluation-plan.json"
plan = json.loads(plan_path.read_text(encoding="utf-8"))
plan["planSHA256"] = "G" * 64
plan["plan"]["pairOrder"] = ["pair", "pair"]
plan_path.write_text(json.dumps(plan), encoding="utf-8")
(root / "results/v6-prepared-evaluation-plan.sha256").write_text(
    plan["planSHA256"] + "\n", encoding="utf-8"
)
PY
if assert_pre_v6_ready "$FAKE_CALIBRATOR" >/dev/null 2>&1; then
  echo 'FAIL: malformed plan identity bypassed semantic gate' >&2
  exit 1
fi

echo 'verify script cache regression tests: PASS'
