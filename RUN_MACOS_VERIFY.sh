#!/bin/bash
set -euo pipefail

MODE="${1:-full}"
ROOT="${2:-$(pwd)}"

case "$MODE" in
  fast|full|prime|self-contained|p010|automatic-decode|regression|regression-full|multiflight|multiflight-diagnostic|pure-metal-multiflight|hdr-stage-isolation|real-media|real-media-validation) ;;
  *)
    echo "usage: $0 [fast|full|prime|self-contained|p010|automatic-decode|regression|regression-full|multiflight|multiflight-diagnostic|pure-metal-multiflight|hdr-stage-isolation|real-media|real-media-validation] [repo-root]" >&2
    exit 2
    ;;
esac

cd "$ROOT"
mkdir -p results .build/pre-v6-verify-cache
CACHE_DIR="$ROOT/.build/pre-v6-verify-cache"
CACHE_VERSION="pre-v6-fast-cache-v3-semantic-sealed"

stage() {
  local label="$1"
  shift
  local started=$SECONDS
  printf '\n== %s ==\n' "$label"
  "$@"
  printf '== %s complete: %ss ==\n' "$label" "$((SECONDS - started))"
}

calibrator_for() {
  local config="$1"
  local bin_dir
  bin_dir="$(swift build -c "$config" --disable-index-store --show-bin-path)"
  printf '%s/HDRCalibrate' "$bin_dir"
}

# The fast cache is intentionally metadata-based for media: it fingerprints
# media path + size + mtime instead of re-hashing multi-GB video payloads.
# `full` never trusts this cache and always performs the Tune/Validation
# content-validating preflight. Virgin Frozen bytes remain sealed.
fingerprint() {
  local scope="$1"
  python3 - "$ROOT" "$scope" "$CACHE_VERSION" <<'PY'
import hashlib, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
scope = sys.argv[2]
version = sys.argv[3]
h = hashlib.sha256()

def add_text(label, value):
    h.update(label.encode()); h.update(b'\0'); h.update(value.encode()); h.update(b'\0')

def add_file(path):
    p = pathlib.Path(path)
    if p.is_absolute():
        try:
            rel = str(p.relative_to(root))
        except ValueError:
            rel = str(p)
    else:
        rel = str(p)
    add_text('path', rel)
    if not p.exists():
        add_text('missing', rel)
        return
    h.update(p.read_bytes())
    h.update(b'\0')

add_text('version', version)
add_text('scope', scope)
for rel in ('Package.swift', 'data_video/manifest-v4.json', 'dataset/holdout-provenance-v5.json'):
    add_file(root / rel)

source_roots = [root/'Sources/HDRCalibration', root/'Sources/HDRCore']
if scope != 'audit':
    # The CLI owns semantic exit-code behavior for correctness-review, so it is
    # part of the correctness cache identity as well.
    add_file(root/'Sources/HDRCalibrate/main.swift')
    frozen_plan = os.environ.get('V6_FROZEN_PLAN')
    if frozen_plan:
        add_file(pathlib.Path(frozen_plan))
        add_file(pathlib.Path(frozen_plan).with_suffix('.sha256'))

for base in source_roots:
    if base.exists():
        for p in sorted(base.rglob('*.swift')):
            add_file(p)

# Media/stat evidence. Every JSON control/provenance/lock file is a correctness
# input and is hashed byte-for-byte. Large media remains metadata-based in fast
# mode; backups are explicitly ignored.
data = root/'data_video'
if data.exists():
    for p in sorted(x for x in data.rglob('*') if x.is_file()):
        if '.bak' in p.name:
            continue
        if p.suffix.lower() == '.json':
            add_file(p)
            continue
        st = p.stat()
        add_text('media-stat', f'{p.relative_to(root)}|{st.st_size}|{st.st_mtime_ns}')

print(h.hexdigest())
PY
}

cache_hit() {
  local name="$1" key="$2"
  shift 2
  [ "${FORCE_VERIFY:-0}" != "1" ] || return 1
  [ -f "$CACHE_DIR/$name.key" ] || return 1
  [ "$(cat "$CACHE_DIR/$name.key")" = "$key" ] || return 1
  [ -f "$CACHE_DIR/$name.artifacts" ] || return 1
  local artifact
  for artifact in "$@"; do
    [ -s "$artifact" ] || return 1
  done
  [ "$(artifact_fingerprint "$@")" = "$(cat "$CACHE_DIR/$name.artifacts")" ] || return 1
}

artifact_fingerprint() {
  python3 - "$@" <<'PYARTIFACT'
import hashlib, pathlib, sys
h = hashlib.sha256()
for arg in sys.argv[1:]:
    path = pathlib.Path(arg)
    h.update(str(path).encode()); h.update(b'\0')
    if not path.exists() or path.stat().st_size == 0:
        h.update(b'missing-or-empty\0')
    else:
        h.update(path.read_bytes()); h.update(b'\0')
print(h.hexdigest())
PYARTIFACT
}

cache_store() {
  local name="$1" key="$2"
  shift 2
  printf '%s\n' "$key" > "$CACHE_DIR/$name.key.tmp"
  artifact_fingerprint "$@" > "$CACHE_DIR/$name.artifacts.tmp"
  mv "$CACHE_DIR/$name.key.tmp" "$CACHE_DIR/$name.key"
  mv "$CACHE_DIR/$name.artifacts.tmp" "$CACHE_DIR/$name.artifacts"
}


inputs_newest_mtime_ns() {
  local scope="$1"
  python3 - "$ROOT" "$scope" <<'PYMTIME'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1])
scope = sys.argv[2]
paths = [root/'Package.swift', root/'data_video/manifest-v4.json', root/'dataset/holdout-provenance-v5.json']
source_roots = [root/'Sources/HDRCalibration', root/'Sources/HDRCore']
if scope != 'audit':
    paths.append(root/'Sources/HDRCalibrate/main.swift')
    frozen_plan = os.environ.get('V6_FROZEN_PLAN')
    if frozen_plan:
        plan_path = pathlib.Path(frozen_plan)
        paths.extend([plan_path, plan_path.with_suffix('.sha256')])
for base in source_roots:
    if base.exists():
        paths.extend(sorted(base.rglob('*.swift')))
data = root/'data_video'
if data.exists():
    paths.extend(sorted(p for p in data.rglob('*') if p.is_file() and '.bak' not in p.name))
mt = 0
for p in paths:
    if p.exists():
        mt = max(mt, p.stat().st_mtime_ns)
print(mt)
PYMTIME
}

artifacts_oldest_mtime_ns() {
  python3 - "$@" <<'PYART'
import pathlib, sys
vals=[]
for arg in sys.argv[1:]:
    p=pathlib.Path(arg)
    if not p.exists() or p.stat().st_size == 0:
        print(0); raise SystemExit
    vals.append(p.stat().st_mtime_ns)
print(min(vals) if vals else 0)
PYART
}

prime_cache_from_current_artifacts() {
  local calibrator="$1"
  local audit_key correctness_input_key correctness_key
  local audit_input_mtime audit_artifact_mtime correctness_input_mtime correctness_artifact_mtime

  audit_key="$(fingerprint audit)"
  correctness_input_key="$(fingerprint correctness)"
  correctness_key="$(printf '%s\n%s\n' "$audit_key" "$correctness_input_key" | shasum -a 256 | awk '{print $1}')"

  audit_input_mtime="$(inputs_newest_mtime_ns audit)"
  audit_artifact_mtime="$(artifacts_oldest_mtime_ns results/dataset-v4-final.json data_video/dataset-v4-lock.json)"
  correctness_input_mtime="$(inputs_newest_mtime_ns correctness)"
  correctness_artifact_mtime="$(artifacts_oldest_mtime_ns results/pre-v5-final-correctness.json results/pre-v5-frozen-coverage-policy.json results/temporal-burst-parity.json results/v6-prepared-evaluation-plan.json results/v6-prepared-evaluation-plan.sha256)"

  if [ "$audit_artifact_mtime" -lt "$audit_input_mtime" ]; then
    echo 'REFUSED: dataset audit artifacts are older than current audit inputs.' >&2
    echo 'Run ./RUN_MACOS_VERIFY.sh full (or fast once) before priming.' >&2
    return 1
  fi
  if [ "$correctness_artifact_mtime" -lt "$correctness_input_mtime" ]; then
    echo 'REFUSED: correctness artifacts are older than current correctness inputs.' >&2
    echo 'Run ./RUN_MACOS_VERIFY.sh full (or fast once) before priming.' >&2
    return 1
  fi

  # Never bless an artifact set that is fresh but semantically failing.
  assert_pre_v6_ready "$calibrator"
  cache_store audit "$audit_key" \
    results/dataset-v4-final.json \
    data_video/dataset-v4-lock.json
  cache_store correctness "$correctness_key" \
    results/pre-v5-final-correctness.json \
    results/pre-v5-frozen-coverage-policy.json \
    results/temporal-burst-parity.json \
    results/v6-prepared-evaluation-plan.json \
    results/v6-prepared-evaluation-plan.sha256
  echo 'FAST CACHE PRIMED from fresh existing artifacts.'
  echo 'No objective evaluation was performed by this operation.'
}

run_audit() {
  local calibrator="$1"
  # V6 preflight must not open Virgin Frozen media.  Validate the existing
  # hash-bound audit/lock evidence while hashing only Tune/Validation bytes;
  # the explicit dataset-audit command remains available for a new holdout
  # acquisition outside this verification flow.
  "$calibrator" dataset-audit-preflight \
    --manifest data_video/manifest-v4.json \
    --output results/dataset-v4-final.json
}

run_correctness() {
  local calibrator="$1"
  rm -f \
    results/pre-v5-final-correctness.json \
    results/pre-v5-final-correctness.md \
    results/pre-v5-holdout-provenance.json \
    results/pre-v5-temporal-burst-parity.json \
    results/temporal-burst-parity.json \
    results/pre-v5-new-hlg-holdout-audit.json \
    results/v6-prepared-evaluation-plan.json \
    results/v6-prepared-evaluation-plan.sha256

  if [ -n "${V6_FROZEN_PLAN:-}" ]; then
    "$calibrator" correctness-review \
      --manifest data_video/manifest-v4.json \
      --prepared-frozen-plan "$V6_FROZEN_PLAN" \
      --output results/correctness-review-fixes.json \
      | tee results/pre-v5-macos-correctness.log
  else
    "$calibrator" correctness-review \
      --manifest data_video/manifest-v4.json \
      --output results/correctness-review-fixes.json \
      | tee results/pre-v5-macos-correctness.log
  fi
}


assert_pre_v6_ready() {
  local calibrator="$1"
  "$calibrator" verify-prepared-plan \
    --prepared-plan results/v6-prepared-evaluation-plan.json
  python3 - "$ROOT" <<'PYVERIFY'
import json
import math
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
results = root / "results"
errors = []

def load_required(path):
    if path is None:
        return None
    try:
        relative = path.relative_to(root)
    except ValueError:
        relative = path
    if not path.exists():
        errors.append(f"missing required artifact: {relative}")
        return None
    if path.stat().st_size == 0:
        errors.append(f"empty required artifact: {relative}")
        return None
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(
                handle,
                parse_constant=lambda value: (_ for _ in ()).throw(
                    ValueError(f"non-finite JSON number {value!r}")
                ),
            )
    except Exception as exc:
        errors.append(f"invalid JSON in {relative}: {exc}")
        return None

final_path = results / "pre-v5-final-correctness.json"
coverage_path = results / "pre-v5-frozen-coverage-policy.json"
plan_path = results / "v6-prepared-evaluation-plan.json"
plan_hash_path = results / "v6-prepared-evaluation-plan.sha256"
burst_candidates = [
    results / "temporal-burst-parity.json",
    results / "pre-v5-temporal-burst-parity.json",
]

final = load_required(final_path)
coverage = load_required(coverage_path)
plan = load_required(plan_path)

burst_path = next(
    (path for path in burst_candidates if path.exists() and path.stat().st_size > 0),
    None,
)
if burst_path is None:
    errors.append("missing required artifact: results/temporal-burst-parity.json")
    burst = None
else:
    burst = load_required(burst_path)

if isinstance(final, dict):
    verdict = final.get("verdict")
    if verdict != "CORRECTNESS_READY_FOR_V6":
        errors.append(
            f"correctness verdict is {verdict!r}, expected 'CORRECTNESS_READY_FOR_V6'"
        )

    for key in ("virginFrozenObjectiveEvaluationCount", "objectiveEvaluationCount"):
        value = final.get(key)
        if type(value) is not int or value != 0:
            errors.append(
                f"{key} must be the integer 0 during correctness review, got {value!r}"
            )

    checks = final.get("checks")
    if not isinstance(checks, list):
        errors.append("pre-v5-final-correctness.json has no checks array")
    else:
        checks_by_id = {}
        for index, check in enumerate(checks):
            if not isinstance(check, dict):
                errors.append(
                    f"correctness check at index {index} is not an object"
                )
                continue

            check_id = check.get("id")
            if not isinstance(check_id, str) or not check_id:
                errors.append(f"correctness check at index {index} has no valid id")
                continue
            if check_id in checks_by_id:
                errors.append(f"duplicate correctness check id: {check_id}")
                continue
            checks_by_id[check_id] = check

            required = check.get("required")
            executed = check.get("executed")
            status = check.get("status")
            if not isinstance(required, bool):
                errors.append(
                    f"correctness check {check_id} has non-boolean required={required!r}"
                )
            if not isinstance(executed, bool):
                errors.append(
                    f"correctness check {check_id} has non-boolean executed={executed!r}"
                )
            if required is True and (executed is not True or status != "PASS"):
                errors.append(
                    f"required check {check_id} is not PASS/executed "
                    f"(status={status!r}, executed={executed!r})"
                )

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
        }
        for check_id in sorted(critical | {"v6PreparedEvaluationPlan"}):
            check = checks_by_id.get(check_id)
            if check is None:
                errors.append(f"missing critical correctness check: {check_id}")
            elif (
                check.get("required") is not True
                or check.get("executed") is not True
                or check.get("status") != "PASS"
            ):
                errors.append(
                    f"critical check {check_id} must be required, executed, and PASS"
                )

if isinstance(plan, dict):
    plan_hash = plan.get("planSHA256")
    if (
        not isinstance(plan_hash, str)
        or len(plan_hash) != 64
        or any(character not in "0123456789abcdef" for character in plan_hash)
    ):
        errors.append("v6-prepared-evaluation-plan.json has no canonical planSHA256")
    plan_body = plan.get("plan")
    pair_order = plan_body.get("pairOrder") if isinstance(plan_body, dict) else None
    if (
        not isinstance(pair_order, list)
        or not pair_order
        or any(not isinstance(pair_id, str) or not pair_id for pair_id in pair_order)
        or len(set(pair_order)) != len(pair_order)
    ):
        errors.append("v6-prepared-evaluation-plan.json has no pairOrder")
    if not plan_hash_path.exists() or plan_hash_path.stat().st_size == 0:
        errors.append("missing required artifact: results/v6-prepared-evaluation-plan.sha256")
    else:
        sealed_hash = plan_hash_path.read_text(encoding="utf-8").strip()
        if sealed_hash != plan_hash:
            errors.append("v6 PreparedEvaluationPlan hash sidecar does not match artifact")

if isinstance(coverage, dict):
    for key in ("transferStatus", "pairCountStatus", "familyStatus"):
        status = coverage.get(key)
        if status != "PASS":
            errors.append(
                f"frozen coverage {key}={status!r}, expected 'PASS'"
            )

if isinstance(burst, dict):
    status = burst.get("status")
    if status != "PASS":
        errors.append(
            f"temporal burst parity status={status!r}, expected 'PASS'"
        )

    evidence = burst.get("evidence")
    if not isinstance(evidence, dict):
        errors.append("temporal burst parity evidence is missing")
    else:
        counts = evidence.get("counts", {})
        numerical = evidence.get("numerical", {})
        max_in_flight = (
            counts.get("maxFramesInFlight")
            if isinstance(counts, dict)
            else None
        )
        max_error = (
            numerical.get("maxAbsoluteError")
            if isinstance(numerical, dict)
            else None
        )

        if type(max_in_flight) is not int or max_in_flight < 2:
            errors.append(
                "temporal burst parity did not exercise a burst "
                f"(maxFramesInFlight={max_in_flight!r})"
            )

        if (
            not isinstance(max_error, (int, float))
            or isinstance(max_error, bool)
            or not math.isfinite(float(max_error))
            or max_error < 0
            or max_error > 1e-6
        ):
            errors.append(
                "temporal burst parity numerical mismatch "
                f"(maxAbsoluteError={max_error!r}, expected <= 1e-6)"
            )

if errors:
    print("PRE-V6 VERIFY FAILED:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    raise SystemExit(1)

print("PRE-V6 semantic gates: PASS")
PYVERIFY
}

run_audit_cached() {
  local calibrator="$1" key="$2"
  if cache_hit audit "$key" \
      results/dataset-v4-final.json \
      data_video/dataset-v4-lock.json; then
    printf '\n== dataset audit / evidence refresh ==\n'
    echo 'CACHE HIT: manifest/source/media metadata unchanged; reusing validated dataset audit evidence'
    echo 'NOTE: full mode always revalidates media content.'
  else
    stage 'dataset audit / evidence refresh' run_audit "$calibrator"
    cache_store audit "$key" \
      results/dataset-v4-final.json \
      data_video/dataset-v4-lock.json
  fi
}

run_correctness_cached() {
  local calibrator="$1" key="$2"
  if cache_hit correctness "$key" \
      results/pre-v5-final-correctness.json \
      results/pre-v5-frozen-coverage-policy.json \
      results/temporal-burst-parity.json \
      results/v6-prepared-evaluation-plan.json \
      results/v6-prepared-evaluation-plan.sha256; then
    printf '\n== correctness review ==\n'
    echo 'CACHE HIT: correctness inputs and artifacts unchanged; reusing pre-V6 correctness artifacts'
  else
    stage 'correctness review' run_correctness "$calibrator"
  fi

  # Cache presence/freshness is not sufficient. A cached FAIL must remain a
  # failing verification and must never be promoted into a green cache entry.
  assert_pre_v6_ready "$calibrator"
  cache_store correctness "$key" \
    results/pre-v5-final-correctness.json \
    results/pre-v5-frozen-coverage-policy.json \
    results/temporal-burst-parity.json \
    results/v6-prepared-evaluation-plan.json \
    results/v6-prepared-evaluation-plan.sha256
}

print_summary() {
  printf '\n== verification summary ==\n'

  if [ -f results/pre-v5-final-correctness.json ]; then
    if command -v plutil >/dev/null 2>&1; then
      printf 'correctness verdict: '
      plutil -extract verdict raw results/pre-v5-final-correctness.json 2>/dev/null || echo UNKNOWN
      printf 'virgin Frozen objective evaluations: '
      plutil -extract virginFrozenObjectiveEvaluationCount raw results/pre-v5-final-correctness.json 2>/dev/null || echo UNKNOWN
    else
      echo 'results/pre-v5-final-correctness.json present'
    fi
  else
    echo 'MISSING: results/pre-v5-final-correctness.json'
  fi

  local burst='results/temporal-burst-parity.json'
  if [ ! -f "$burst" ] && [ -f results/pre-v5-temporal-burst-parity.json ]; then
    burst='results/pre-v5-temporal-burst-parity.json'
  fi
  if [ -f "$burst" ]; then
    if command -v plutil >/dev/null 2>&1; then
      printf 'burst parity: '
      plutil -extract status raw "$burst" 2>/dev/null || echo UNKNOWN
      printf 'max frames in flight: '
      plutil -extract evidence.counts.maxFramesInFlight raw "$burst" 2>/dev/null || echo UNKNOWN
      printf 'max absolute error: '
      plutil -extract evidence.numerical.maxAbsoluteError raw "$burst" 2>/dev/null || echo UNKNOWN
    else
      echo "$burst present"
    fi
  else
    echo 'MISSING: temporal burst parity artifact'
  fi

  if [ "${VERBOSE_RESULTS:-0}" = "1" ]; then
    for f in \
      results/pre-v5-holdout-provenance.json \
      results/pre-v5-new-hlg-holdout-audit.json \
      "$burst" \
      results/pre-v5-frozen-coverage-policy.json \
      results/pre-v5-final-correctness.json; do
      [ -f "$f" ] || continue
      echo "--- $f"
      cat "$f"
      echo
    done
  fi
}

# Shell regression tests source the functions above without building Swift or
# touching correctness artifacts.
if [ "${VERIFY_SCRIPT_LIBRARY_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

if [ "$MODE" = "self-contained" ] || [ "$MODE" = "p010" ] || [ "$MODE" = "automatic-decode" ]; then
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sdr2hdr-tiny-e2e.XXXXXX")"
  FIXTURE_PATH="$FIXTURE_DIR/tiny-sdr.mp4"
  P010_FIXTURE_PATH="$FIXTURE_DIR/tiny-p010-sdr.mp4"
  trap 'rm -rf "$FIXTURE_DIR"' EXIT
  command -v ffmpeg >/dev/null 2>&1 || {
    echo 'SELF-CONTAINED REAL-MEDIA VERIFY: FAIL (ffmpeg is required)' >&2
    exit 2
  }
  command -v ffprobe >/dev/null 2>&1 || {
    echo 'SELF-CONTAINED REAL-MEDIA VERIFY: FAIL (ffprobe is required)' >&2
    exit 2
  }
  if [ "$MODE" = "automatic-decode" ]; then
    AUTOMATIC_FIXTURE_DIR="$FIXTURE_DIR/automatic-regression"
    stage 'automatic decode precision fixture generation' \
      bash Tests/RealMediaRegression/generate_regression_fixtures.sh "$AUTOMATIC_FIXTURE_DIR"
    stage 'automatic decode precision fixture contracts' \
      bash Tests/RealMediaRegression/verify_regression_fixtures.sh "$AUTOMATIC_FIXTURE_DIR"
    stage 'automatic H.264/HEVC source precision selection and Metal integration' env \
      HDR_AUTOMATIC_H264_FIXTURE="$AUTOMATIC_FIXTURE_DIR/h264-8-video-24-dark-gradient.mp4" \
      HDR_AUTOMATIC_HEVC8_FIXTURE="$AUTOMATIC_FIXTURE_DIR/hevc-8-video-30-chroma-edge.mp4" \
      HDR_AUTOMATIC_MAIN10_FIXTURE="$AUTOMATIC_FIXTURE_DIR/hevc-main10-video-24-dark-gradient.mp4" \
      swift test -c debug --disable-index-store \
        --filter RealMediaIntegrationTests/testAutomatic
    echo 'AUTOMATIC DECODE PRECISION VERIFY: PASS'
    echo 'Source format descriptions were inspected before AVPlayerItemVideoOutput creation.'
    echo 'Virgin Frozen accessed: NO'
    echo 'Objective evaluations: 0'
    exit 0
  fi
  if [ "$MODE" = "self-contained" ]; then
    stage 'self-contained tiny 8-bit media fixture' bash Tests/verify_tiny_media_fixture.sh "$FIXTURE_PATH"
    stage 'real-media AVFoundation 8-bit production nearest integration' env \
      HDR_SELF_CONTAINED_FIXTURE="$FIXTURE_PATH" \
      swift test -c debug --disable-index-store --filter RealMediaIntegrationTests/testGeneratedFixtureRunsThroughProductionNearestPath
    stage 'real-media AVFoundation 8-bit siting-aware candidate integration' env \
      HDR_SELF_CONTAINED_FIXTURE="$FIXTURE_PATH" \
      swift test -c debug --disable-index-store --filter RealMediaIntegrationTests/testGeneratedFixtureRunsThroughSitingAwareCandidate
  fi
  stage 'self-contained tiny compressed P010 fixture' bash Tests/verify_tiny_p010_fixture.sh "$P010_FIXTURE_PATH"
  stage 'real-media AVFoundation P010 production nearest integration' env \
    HDR_P010_SELF_CONTAINED_FIXTURE="$P010_FIXTURE_PATH" \
    swift test -c debug --disable-index-store --filter RealMediaIntegrationTests/testGeneratedP010FixtureRunsThroughProductionNearestPath
  stage 'real-media AVFoundation P010 siting-aware candidate integration' env \
    HDR_P010_SELF_CONTAINED_FIXTURE="$P010_FIXTURE_PATH" \
    swift test -c debug --disable-index-store --filter RealMediaIntegrationTests/testGeneratedP010FixtureRunsThroughSitingAwareCandidate
  if [ "$MODE" = "self-contained" ]; then
    echo 'SELF-CONTAINED REAL-MEDIA VERIFY: PASS'
  else
    echo 'P010 REAL-MEDIA VERIFY: PASS'
  fi
  echo 'AVFoundation decode, CVPixelBuffer metadata, HDRProcessor Metal, and offscreen presentation were exercised.'
  echo 'No dataset audit, correctness review, objective evaluation, or holdout media access was performed.'
  exit 0
fi

if [ "$MODE" = "regression" ] || [ "$MODE" = "regression-full" ]; then
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sdr2hdr-real-media-regression.XXXXXX")"
  trap 'rm -rf "$FIXTURE_DIR"' EXIT
  command -v ffmpeg >/dev/null 2>&1 || {
    echo 'REAL-MEDIA REGRESSION VERIFY: FAIL (ffmpeg is required)' >&2
    exit 2
  }
  command -v ffprobe >/dev/null 2>&1 || {
    echo 'REAL-MEDIA REGRESSION VERIFY: FAIL (ffprobe is required)' >&2
    exit 2
  }
  stage 'manifest-driven compressed fixture generation' \
    bash Tests/RealMediaRegression/generate_regression_fixtures.sh "$FIXTURE_DIR"
  stage 'manifest-driven ffprobe fixture contracts' \
    bash Tests/RealMediaRegression/verify_regression_fixtures.sh "$FIXTURE_DIR"
  stage 'mandatory real-media regression matrix' env \
    HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR="$FIXTURE_DIR" \
    HDR_REAL_MEDIA_REGRESSION_CANDIDATE="$(git rev-parse HEAD 2>/dev/null || printf 'working-tree')" \
    HDR_REAL_MEDIA_REGRESSION_RESULTS="$ROOT/results/real-media-regression.json" \
    swift test -c debug --disable-index-store \
      --filter RealMediaRegressionTests/testManifestDrivenRegressionMatrixRunsBothModes
  if [ "$MODE" = "regression-full" ]; then
    stage 'release real-media regression matrix' env \
      HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR="$FIXTURE_DIR" \
      HDR_REAL_MEDIA_REGRESSION_CANDIDATE="$(git rev-parse HEAD 2>/dev/null || printf 'working-tree')" \
      HDR_REAL_MEDIA_REGRESSION_RESULTS="$ROOT/results/real-media-regression-release.json" \
      swift test -c release --disable-index-store \
        --filter RealMediaRegressionTests/testManifestDrivenRegressionMatrixRunsBothModes
  fi
  regression_reports=("$ROOT/results/real-media-regression.json")
  if [ "$MODE" = "regression-full" ]; then
    regression_reports+=("$ROOT/results/real-media-regression-release.json")
  fi
  python3 - "${regression_reports[@]}" <<'PY'
import json
import sys

for report_name in sys.argv[1:]:
    with open(report_name, encoding="utf-8") as handle:
        document = json.load(handle)
    if document.get("skipped", 0) != 0:
        raise SystemExit(f"mandatory regression contains skipped fixtures: {report_name}")
    if document.get("failures", 0) != 0:
        raise SystemExit(f"mandatory regression contains failed fixtures: {report_name}")
PY
  echo 'REAL-MEDIA REGRESSION VERIFY: PASS'
  echo 'Production nearest and siting-aware candidate were both evaluated for every available manifest fixture.'
  echo 'Virgin Frozen accessed: NO'
  echo 'Objective evaluations: 0'
  exit 0
fi

if [ "$MODE" = "multiflight" ]; then
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sdr2hdr-real-media-multiflight.XXXXXX")"
  trap 'rm -rf "$FIXTURE_DIR"' EXIT
  command -v ffmpeg >/dev/null 2>&1 || {
    echo 'REAL-MEDIA MULTIFLIGHT VERIFY: FAIL (ffmpeg is required)' >&2
    exit 2
  }
  command -v ffprobe >/dev/null 2>&1 || {
    echo 'REAL-MEDIA MULTIFLIGHT VERIFY: FAIL (ffprobe is required)' >&2
    exit 2
  }
  stage 'multi-flight compressed fixture generation' \
    bash Tests/RealMediaRegression/generate_regression_fixtures.sh "$FIXTURE_DIR"
  stage 'multi-flight ffprobe fixture contracts' \
    bash Tests/RealMediaRegression/verify_regression_fixtures.sh "$FIXTURE_DIR"
  MULTIFLIGHT_BASELINE="$(git merge-base origin/main HEAD 2>/dev/null || \
    git merge-base main HEAD 2>/dev/null || echo 'manifest-baseline')"
  stage 'two-flight and three-flight real-media HDR processing' env \
    HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR="$FIXTURE_DIR" \
    HDR_REAL_MEDIA_MULTIFLIGHT_PROGRESS=1 \
    HDR_REAL_MEDIA_MULTIFLIGHT_BASELINE="$MULTIFLIGHT_BASELINE" \
    HDR_REAL_MEDIA_REGRESSION_CANDIDATE="$(git rev-parse HEAD 2>/dev/null || printf 'working-tree')" \
    HDR_REAL_MEDIA_MULTIFLIGHT_RESULTS="$ROOT/results/real-media-multiflight.json" \
    swift test -c debug --disable-index-store \
      --filter RealMediaMultiFlightTests/testDeterministicMatrixRunsWithTwoAndThreeFlights
  python3 - "$ROOT/results/real-media-multiflight.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)

if document.get("failures", 0) != 0:
    raise SystemExit("multi-flight regression contains failed mode runs")
expected_runs = document.get("fixtureCount", 0) * 4
if document.get("runCount") != expected_runs:
    raise SystemExit(
        f"multi-flight run count {document.get('runCount')} does not match {expected_runs}"
    )
for fixture in document.get("fixtures", []):
    for mode in fixture.get("modes", []):
        if mode.get("maxObservedInFlight", 0) < mode.get("flightDepth", 0):
            raise SystemExit(
                f"{fixture.get('id')} depth {fixture.get('flightDepth')} did not overlap"
            )
PY
  echo 'REAL-MEDIA MULTIFLIGHT VERIFY: PASS'
  echo 'Serial control was retained; two-flight and three-flight paths exercised NV12 and P010.'
  echo 'Virgin Frozen accessed: NO'
  echo 'Objective evaluations: 0'
  exit 0
fi

if [ "$MODE" = "multiflight-diagnostic" ]; then
  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sdr2hdr-real-media-multiflight-diagnostic.XXXXXX")"
  DIAGNOSTIC_DIR="$ROOT/results/multiflight-vmapple-diagnostic"
  DIAGNOSTIC_RESULT="$ROOT/results/multiflight-vmapple-diagnostic.json"
  trap 'rm -rf "$FIXTURE_DIR"' EXIT
  command -v ffmpeg >/dev/null 2>&1 || {
    echo 'REAL-MEDIA MULTIFLIGHT DIAGNOSTIC: FAIL (ffmpeg is required)' >&2
    exit 2
  }
  command -v ffprobe >/dev/null 2>&1 || {
    echo 'REAL-MEDIA MULTIFLIGHT DIAGNOSTIC: FAIL (ffprobe is required)' >&2
    exit 2
  }
  mkdir -p "$DIAGNOSTIC_DIR"
  rm -f "$DIAGNOSTIC_RESULT"
  for case_name in A B C D; do
    rm -f "$DIAGNOSTIC_DIR/$case_name.log" \
      "$DIAGNOSTIC_DIR/$case_name.result.json" \
      "$DIAGNOSTIC_DIR/$case_name.metadata.json" \
      "$DIAGNOSTIC_DIR/$case_name.timing.json"
  done

  stage 'multi-flight diagnostic compressed fixture generation' \
    bash Tests/RealMediaRegression/generate_regression_fixtures.sh "$FIXTURE_DIR"
  stage 'multi-flight diagnostic ffprobe fixture contracts' \
    bash Tests/RealMediaRegression/verify_regression_fixtures.sh "$FIXTURE_DIR"

  DIAGNOSTIC_FIXTURE="${HDR_MULTIFLIGHT_DIAGNOSTIC_FIXTURE:-h264-8-video-24-chroma-edge}"
  DIAGNOSTIC_FRAMES="${HDR_MULTIFLIGHT_DIAGNOSTIC_FRAMES:-2}"
  DIAGNOSTIC_FLIGHT_DEPTH="${HDR_MULTIFLIGHT_DIAGNOSTIC_FLIGHT_DEPTH:-2}"
  DIAGNOSTIC_MODES="${HDR_MULTIFLIGHT_DIAGNOSTIC_MODES:-nearest}"
  DIAGNOSTIC_PHASE="${HDR_MULTIFLIGHT_DIAGNOSTIC_PHASE:-minimal}"
  DIAGNOSTIC_WORK_BYTES="${HDR_MULTIFLIGHT_SCHEDULING_WORK_BYTES:-$((32 * 1024 * 1024))}"
  DIAGNOSTIC_WORK_PASSES="${HDR_MULTIFLIGHT_SCHEDULING_WORK_PASSES:-8}"
  DIAGNOSTIC_OS="$(sw_vers -productVersion 2>/dev/null || printf 'unknown')"
  DIAGNOSTIC_KERNEL="$(uname -sr 2>/dev/null || printf 'unknown')"
  DIAGNOSTIC_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"
  MULTIFLIGHT_BASELINE="$(git merge-base origin/main HEAD 2>/dev/null || \
    git merge-base main HEAD 2>/dev/null || echo 'manifest-baseline')"

  for case_name in A B C D; do
    case "$case_name" in
      A) debug_layer=1; scheduling_work=1 ;;
      B) debug_layer=0; scheduling_work=1 ;;
      C) debug_layer=1; scheduling_work=0 ;;
      D) debug_layer=0; scheduling_work=0 ;;
    esac
    log_path="$DIAGNOSTIC_DIR/$case_name.log"
    result_path="$DIAGNOSTIC_DIR/$case_name.result.json"
    metadata_path="$DIAGNOSTIC_DIR/$case_name.metadata.json"
    timing_path="$DIAGNOSTIC_DIR/$case_name.timing.json"
    start_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set +e
    env \
      MTL_DEBUG_LAYER="$debug_layer" \
      HDR_MULTIFLIGHT_SCHEDULING_WORK="$scheduling_work" \
      HDR_MULTIFLIGHT_SCHEDULING_WORK_BYTES="$DIAGNOSTIC_WORK_BYTES" \
      HDR_MULTIFLIGHT_SCHEDULING_WORK_PASSES="$DIAGNOSTIC_WORK_PASSES" \
      HDR_MULTIFLIGHT_DIAGNOSTIC_CASE="$case_name" \
      HDR_MULTIFLIGHT_DIAGNOSTIC_FIXTURE="$DIAGNOSTIC_FIXTURE" \
      HDR_MULTIFLIGHT_DIAGNOSTIC_FRAMES="$DIAGNOSTIC_FRAMES" \
      HDR_MULTIFLIGHT_DIAGNOSTIC_FLIGHT_DEPTH="$DIAGNOSTIC_FLIGHT_DEPTH" \
      HDR_MULTIFLIGHT_DIAGNOSTIC_MODES="$DIAGNOSTIC_MODES" \
      HDR_MULTIFLIGHT_DIAGNOSTIC_PHASE="$DIAGNOSTIC_PHASE" \
      HDR_MULTIFLIGHT_DEEP_PROGRESS=1 \
      HDR_REAL_MEDIA_MULTIFLIGHT_PROGRESS=1 \
      HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR="$FIXTURE_DIR" \
      HDR_REAL_MEDIA_MULTIFLIGHT_BASELINE="$MULTIFLIGHT_BASELINE" \
      HDR_REAL_MEDIA_REGRESSION_CANDIDATE="$(git rev-parse HEAD 2>/dev/null || printf 'working-tree')" \
      HDR_MULTIFLIGHT_DIAGNOSTIC_OS="$DIAGNOSTIC_OS" \
      HDR_MULTIFLIGHT_DIAGNOSTIC_KERNEL="$DIAGNOSTIC_KERNEL" \
      HDR_MULTIFLIGHT_DIAGNOSTIC_ARCH="$DIAGNOSTIC_ARCH" \
      HDR_MULTIFLIGHT_DIAGNOSTIC_RESULT="$result_path" \
      HDR_MULTIFLIGHT_DIAGNOSTIC_METADATA="$metadata_path" \
      swift test -c debug --disable-index-store \
        --filter RealMediaMultiFlightDiagnosticTests/testVMAppleDiagnosticCase \
        >"$log_path" 2>&1
    status=$?
    set -e
    end_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$timing_path" "$status" "$start_timestamp" "$end_timestamp" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
    "exitCode": int(sys.argv[2]),
    "processStartTimestamp": sys.argv[3],
    "processEndTimestamp": sys.argv[4],
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    echo "MULTIFLIGHT_DIAGNOSTIC_CASE case=$case_name exit=$status log=$log_path"
  done

  python3 - "$DIAGNOSTIC_RESULT" "$DIAGNOSTIC_DIR" "$DIAGNOSTIC_FIXTURE" \
    "$DIAGNOSTIC_FRAMES" "$DIAGNOSTIC_FLIGHT_DEPTH" "$DIAGNOSTIC_WORK_BYTES" \
    "$DIAGNOSTIC_WORK_PASSES" "$DIAGNOSTIC_MODES" "$DIAGNOSTIC_PHASE" "$DIAGNOSTIC_OS" \
    "$DIAGNOSTIC_KERNEL" "$DIAGNOSTIC_ARCH" <<'PY'
import json
import pathlib
import sys

result_path = pathlib.Path(sys.argv[1])
diagnostic_dir = pathlib.Path(sys.argv[2])
fixture = sys.argv[3]
frames = int(sys.argv[4])
flight_depth = int(sys.argv[5])
work_bytes = int(sys.argv[6])
work_passes = int(sys.argv[7])
mode_names = [mode.strip() for mode in sys.argv[8].split(",") if mode.strip()]
phase = sys.argv[9]
fallback_environment = {
    "os": sys.argv[10],
    "kernel": sys.argv[11],
    "architecture": sys.argv[12],
    "metalDevice": "unknown",
    "fixture": fixture,
    "frames": frames,
    "flightDepth": flight_depth,
    "mode": mode_names[0] if mode_names else "nearest",
}

def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None

def signal_for(exit_code, log_lines):
    if exit_code is None:
        return None
    if any(
        "SIGTRAP" in line or
        "signal 5" in line or
        "signal: 5" in line or
        "signal code 5" in line
        for line in log_lines
    ):
        return 5
    if 129 <= exit_code <= 192:
        return exit_code - 128
    return None

cases = []
for case_name, debug_layer, scheduling_work in (
    ("A", True, True),
    ("B", False, True),
    ("C", True, False),
    ("D", False, False),
):
    log_path = diagnostic_dir / f"{case_name}.log"
    result_payload = read_json(diagnostic_dir / f"{case_name}.result.json")
    metadata_payload = read_json(diagnostic_dir / f"{case_name}.metadata.json")
    timing_payload = read_json(diagnostic_dir / f"{case_name}.timing.json") or {}
    try:
        log_lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        log_lines = []
    deep_markers = [line for line in log_lines if "MULTIFLIGHT_DEEP_PROGRESS " in line]
    regular_markers = [line for line in log_lines if "MULTIFLIGHT_PROGRESS " in line]
    all_markers = [
        line for line in log_lines
        if "MULTIFLIGHT_DEEP_PROGRESS " in line or "MULTIFLIGHT_PROGRESS " in line
    ]
    last_marker = (all_markers or [None])[-1]
    raw_exit = timing_payload.get("exitCode")
    signal = signal_for(raw_exit, log_lines)
    payload_status = result_payload.get("status") if result_payload else None
    if payload_status in {"PASS", "FAIL", "ERROR"} and signal is None and raw_exit == 0:
        test_result = payload_status
    elif signal is not None:
        test_result = "SIGNAL"
    else:
        test_result = "FAIL"
    environment = (metadata_payload or {}).get("environment") or fallback_environment
    if result_payload and result_payload.get("environment"):
        environment = result_payload["environment"]
    case_record = {
        "case": case_name,
        "environment": environment,
        "metalDebugLayer": debug_layer,
        "metalDebugLayerValue": "1" if debug_layer else "0",
        "schedulingWork": scheduling_work,
        "schedulingWorkEnabled": scheduling_work,
        "schedulingWorkBytes": work_bytes if scheduling_work else 0,
        "schedulingWorkPasses": work_passes if scheduling_work else 0,
        "schedulingWorkStorageMode": "shared",
        "schedulingWorkEncoder": "blit",
        "presentationAudit": (result_payload or {}).get("presentationAudit", {
            "perCommandWritableDiagnosticBuffer": True,
            "fallbackSourceTextureReadOnly": True,
            "diagnosticBufferLifetimeUntilGPUCompletion": True,
        }),
        "processStartTimestamp": timing_payload.get("processStartTimestamp"),
        "processEndTimestamp": timing_payload.get("processEndTimestamp"),
        "exitCode": raw_exit,
        "signal": signal,
        "testResult": test_result,
        "classification": "PASS" if test_result == "PASS" else "FAIL",
        "lastProgressMarker": last_marker,
        "deepProgressMarkerCount": len(deep_markers),
        "result": (result_payload or {}).get("result"),
        "error": (result_payload or {}).get("error"),
        "log": str(log_path),
    }
    cases.append(case_record)

by_case = {case["case"]: case for case in cases}
passed = {name: by_case[name]["testResult"] == "PASS" for name in "ABCD"}
if passed == {"A": False, "B": True, "C": False, "D": True}:
    classification = "METAL_VALIDATION_LAYER_VMAPPLE_INTERACTION"
elif passed == {"A": False, "B": False, "C": True, "D": True}:
    classification = "TEST_SCHEDULING_WORK_VMAPPLE_INCOMPATIBILITY"
elif all(not value for value in passed.values()):
    classification = "REAL_MULTIFLIGHT_CONCURRENCY_REGRESSION_SUSPECTED"
elif passed == {"A": False, "B": True, "C": True, "D": True}:
    classification = "VALIDATION_PLUS_SCHEDULING_WORK_INTERACTION"
elif all(passed.values()):
    classification = "MINIMAL_REPRO_NOT_REPRODUCED"
else:
    classification = "MATRIX_PATTERN_UNCLASSIFIED"

devices = sorted({case["environment"].get("metalDevice", "unknown") for case in cases})
document = {
    "schemaVersion": 1,
    "phase": phase,
    "environment": {
        "os": fallback_environment["os"],
        "kernel": fallback_environment["kernel"],
        "architecture": fallback_environment["architecture"],
        "metalDevices": devices,
    },
    "fixture": fixture,
    "frames": frames,
    "flightDepth": flight_depth,
        "mode": mode_names[0] if len(mode_names) == 1 else mode_names,
    "classification": classification,
    "cases": cases,
}
result_path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  echo "REAL-MEDIA MULTIFLIGHT DIAGNOSTIC: evidence written to $DIAGNOSTIC_RESULT"
  echo 'This diagnostic mode records case failures; it does not convert SIGTRAP or exit status 5 into PASS.'
  echo 'Virgin Frozen accessed: NO'
  echo 'Objective evaluations: 0'
  exit 0
fi

if [ "$MODE" = "pure-metal-multiflight" ]; then
  PURE_METAL_DIR="$ROOT/results/vmapple-pure-metal-multiflight"
  PURE_METAL_RESULT="$ROOT/results/vmapple-pure-metal-multiflight.json"
  mkdir -p "$PURE_METAL_DIR"
  rm -f "$PURE_METAL_RESULT"
  rm -f "$PURE_METAL_DIR"/*

  PURE_METAL_OS="$(sw_vers -productVersion 2>/dev/null || printf 'unknown')"
  PURE_METAL_KERNEL="$(uname -sr 2>/dev/null || printf 'unknown')"
  PURE_METAL_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"
  PURE_METAL_BASELINE="$(git merge-base origin/main HEAD 2>/dev/null || \
    git merge-base main HEAD 2>/dev/null || echo 'manifest-baseline')"

  run_pure_metal_probe() {
    local probe="$1"
    local test_name="$2"
    local debug_layer="$3"
    local log_path="$PURE_METAL_DIR/${probe}.debug${debug_layer}.log"
    local timing_path="$PURE_METAL_DIR/${probe}.debug${debug_layer}.timing.json"
    local start_timestamp end_timestamp status

    start_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set +e
    env \
      MTL_DEBUG_LAYER="$debug_layer" \
      HDR_PURE_METAL_PROBE="$probe" \
      HDR_PURE_METAL_DEBUG_LAYER="$debug_layer" \
      swift test -c debug --disable-index-store \
        --filter "MetalConcurrentCommandBufferProbeTests/$test_name" \
        >"$log_path" 2>&1
    status=$?
    set -e
    end_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$timing_path" "$status" "$start_timestamp" "$end_timestamp" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
    "exitCode": int(sys.argv[2]),
    "processStartTimestamp": sys.argv[3],
    "processEndTimestamp": sys.argv[4],
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    echo "PURE_METAL_PROBE probe=$probe debugLayer=$debug_layer exit=$status log=$log_path"
  }

  PURE_METAL_PROBES=(
    P1_empty
    P2_blit
    P3_compute
    P4_render
    P5_compute_render_blit
    P6_shared_pipeline
    P7_shared_readonly_texture
  )
  PURE_METAL_TESTS=(
    testP1EmptyCommandBuffers
    testP2BlitCommandBuffers
    testP3ComputeCommandBuffers
    testP4RenderCommandBuffers
    testP5ComputeRenderBlitCommandBuffers
    testP6SharedPipelineStates
    testP7SharedReadOnlyTexture
  )

  stage 'pure Metal device inventory' run_pure_metal_probe P0_device_inventory testP0DeviceInventory 0
  for index in "${!PURE_METAL_PROBES[@]}"; do
    stage "pure Metal ${PURE_METAL_PROBES[$index]} debug layer OFF" \
      run_pure_metal_probe \
      "${PURE_METAL_PROBES[$index]}" \
      "${PURE_METAL_TESTS[$index]}" \
      0
  done

  if ! python3 - "$PURE_METAL_DIR/P1_empty.debug0.log" <<'PY'
import json
import pathlib
import sys

try:
    lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
except FileNotFoundError:
    lines = []
passed = False
for line in lines:
    if line.startswith("PURE_METAL_PROBE_RESULT "):
        try:
            passed = json.loads(line[len("PURE_METAL_PROBE_RESULT "):]).get("status") == "PASS"
        except json.JSONDecodeError:
            passed = False
raise SystemExit(0 if passed else 1)
PY
  then
    stage 'pure Metal P1 serial empty control' \
      run_pure_metal_probe P1_serial_empty testP1SerialEmptyCommandBuffers 0
  fi

  while read -r debug_probe debug_test; do
    [ -n "$debug_probe" ] || continue
    stage "pure Metal ${debug_probe} debug layer ON" \
      run_pure_metal_probe "$debug_probe" "$debug_test" 1
  done < <(
    python3 - "$PURE_METAL_DIR" "${PURE_METAL_PROBES[@]}" <<'PY'
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
test_names = {
    "P1_empty": "testP1EmptyCommandBuffers",
    "P2_blit": "testP2BlitCommandBuffers",
    "P3_compute": "testP3ComputeCommandBuffers",
    "P4_render": "testP4RenderCommandBuffers",
    "P5_compute_render_blit": "testP5ComputeRenderBlitCommandBuffers",
    "P6_shared_pipeline": "testP6SharedPipelineStates",
    "P7_shared_readonly_texture": "testP7SharedReadOnlyTexture",
}
for probe in sys.argv[2:]:
    path = directory / f"{probe}.debug0.log"
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        continue
    passed = False
    for line in lines:
        prefix = "PURE_METAL_PROBE_RESULT "
        if line.startswith(prefix):
            try:
                passed = json.loads(line[len(prefix):]).get("status") == "PASS"
            except json.JSONDecodeError:
                passed = False
    if passed:
        print(probe, test_names[probe])
PY
  )

  set +e
  python3 - "$PURE_METAL_RESULT" "$PURE_METAL_DIR" "$PURE_METAL_OS" \
    "$PURE_METAL_KERNEL" "$PURE_METAL_ARCH" "$PURE_METAL_BASELINE" \
    <<'PY'
import json
import pathlib
import sys

result_path = pathlib.Path(sys.argv[1])
directory = pathlib.Path(sys.argv[2])
os_version = sys.argv[3]
kernel = sys.argv[4]
architecture = sys.argv[5]
baseline = sys.argv[6]

probe_specs = [
    ("P1_empty", "TWO EMPTY COMMAND BUFFERS", "testP1EmptyCommandBuffers"),
    ("P2_blit", "TWO BLIT COMMAND BUFFERS", "testP2BlitCommandBuffers"),
    ("P3_compute", "TWO COMPUTE COMMAND BUFFERS", "testP3ComputeCommandBuffers"),
    ("P4_render", "TWO RENDER COMMAND BUFFERS", "testP4RenderCommandBuffers"),
    ("P5_compute_render_blit", "COMPUTE + RENDER + BLIT", "testP5ComputeRenderBlitCommandBuffers"),
    ("P6_shared_pipeline", "SHARED PIPELINE STATES", "testP6SharedPipelineStates"),
    ("P7_shared_readonly_texture", "SHARED READ-ONLY TEXTURE", "testP7SharedReadOnlyTexture"),
]

def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None

def signal_for(exit_code, lines):
    if any(
        "SIGTRAP" in line or
        "unexpected signal code 5" in line or
        "signal code 5" in line or
        "signal 5" in line
        for line in lines
    ):
        return 5
    if exit_code is not None and 129 <= exit_code <= 192:
        return exit_code - 128
    return None

def parse_record(probe, description, test_name, debug_layer):
    log_path = directory / f"{probe}.debug{debug_layer}.log"
    timing_path = directory / f"{probe}.debug{debug_layer}.timing.json"
    timing = read_json(timing_path) or {}
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        lines = []
    payload = None
    device = None
    for line in lines:
        if line.startswith("PURE_METAL_PROBE_RESULT "):
            try:
                payload = json.loads(line[len("PURE_METAL_PROBE_RESULT "):])
            except json.JSONDecodeError:
                payload = None
        if line.startswith("PURE_METAL_DEVICE_JSON "):
            try:
                device = json.loads(line[len("PURE_METAL_DEVICE_JSON "):])
            except json.JSONDecodeError:
                device = None
    exit_code = timing.get("exitCode")
    signal = signal_for(exit_code, lines)
    if payload and payload.get("status") == "PASS" and exit_code == 0 and signal is None:
        status = "PASS"
    elif signal is not None:
        status = "SIGNAL"
    else:
        status = "FAIL"
    markers = [
        line for line in lines
        if line.startswith("PURE_METAL_PROGRESS ") or
           line.startswith("PURE_METAL_PROBE_ERROR ") or
           line.startswith("PURE_METAL_PROBE_RESULT ")
    ]
    return {
        "probe": probe,
        "description": description,
        "test": test_name,
        "debugLayer": int(debug_layer),
        "exitCode": exit_code,
        "signal": signal,
        "result": status,
        "commandBuffersCommitted": (payload or {}).get("commandBuffersCommitted", 0),
        "commandBuffersCompleted": (payload or {}).get("commandBuffersCompleted", 0),
        "completionHandlers": (payload or {}).get("completionHandlers"),
        "error": (payload or {}).get("error"),
        "lastMarker": markers[-1] if markers else None,
        "log": str(log_path),
        "timing": timing,
        "device": device,
    }

inventory = parse_record(
    "P0_device_inventory",
    "DEVICE INVENTORY",
    "testP0DeviceInventory",
    0,
).get("device") or {}

baseline_records = [parse_record(probe, description, test_name, 0)
                    for probe, description, test_name in probe_specs]
serial_control = None
if (directory / "P1_serial_empty.debug0.log").exists():
    serial_control = parse_record(
        "P1_serial_empty",
        "SERIAL EMPTY COMMAND BUFFER CONTROL",
        "testP1SerialEmptyCommandBuffers",
        0,
    )
debug_records = []
for probe, description, test_name in probe_specs:
    baseline_record = next(record for record in baseline_records if record["probe"] == probe)
    if baseline_record["result"] == "PASS":
        debug_records.append(parse_record(probe, description, test_name, 1))

first_failing = next(
    (record["probe"] for record in baseline_records if record["result"] != "PASS"),
    None,
)
if first_failing == "P1_empty":
    classification = "PARAVIRTUAL_BASIC_MULTIFLIGHT_FAILURE"
elif first_failing == "P2_blit":
    classification = "PARAVIRTUAL_CONCURRENT_BLIT_LIMITATION_SUSPECTED"
elif first_failing == "P3_compute":
    classification = "PARAVIRTUAL_CONCURRENT_COMPUTE_LIMITATION_SUSPECTED"
elif first_failing == "P4_render":
    classification = "PARAVIRTUAL_CONCURRENT_RENDER_LIMITATION_SUSPECTED"
elif first_failing == "P5_compute_render_blit":
    classification = "PARAVIRTUAL_MULTI_ENCODER_LIMITATION_SUSPECTED"
elif first_failing == "P6_shared_pipeline":
    classification = "PARAVIRTUAL_SHARED_PIPELINE_STATE_LIMITATION_SUSPECTED"
elif first_failing == "P7_shared_readonly_texture":
    classification = "PARAVIRTUAL_SHARED_READONLY_TEXTURE_LIMITATION_SUSPECTED"
elif any(record["result"] != "PASS" for record in debug_records):
    classification = "METAL_DEBUG_LAYER_INTERACTION"
elif all(record["result"] == "PASS" for record in baseline_records):
    classification = "PURE_METAL_MULTIFLIGHT_PASS"
else:
    classification = "PURE_METAL_PROBE_EXECUTION_FAILURE"

document = {
    "schemaVersion": 1,
    "baseline": baseline,
    "environment": {
        "os": os_version,
        "kernel": kernel,
        "architecture": architecture,
    },
    "device": inventory,
    "probes": baseline_records,
    "serialControl": serial_control,
    "debugLayerValidation": debug_records,
    "firstFailingProbe": first_failing,
    "classification": classification,
    "commandBufferContract": {
        "baseline": "two command buffers are fully encoded before either is waited",
        "requiredStatus": "completed",
        "requiredError": None,
    },
}
result_path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps({
    "classification": classification,
    "firstFailingProbe": first_failing,
    "device": inventory,
}, sort_keys=True))
raise SystemExit(0 if classification == "PURE_METAL_MULTIFLIGHT_PASS" else 1)
PY
  pure_metal_status=$?
  set -e
  echo "PURE METAL MULTIFLIGHT: artifact=$PURE_METAL_RESULT"
  echo 'Virgin Frozen accessed: NO'
  echo 'Objective evaluations: 0'
  exit "$pure_metal_status"
fi

if [ "$MODE" = "hdr-stage-isolation" ]; then
  HDR_STAGE_DIR="$ROOT/results/vmapple-hdr-stage-isolation"
  HDR_STAGE_RESULT="$ROOT/results/vmapple-hdr-stage-isolation.json"
  PURE_METAL_RESULT="$ROOT/results/vmapple-pure-metal-multiflight.json"
  mkdir -p "$HDR_STAGE_DIR"
  rm -f "$HDR_STAGE_RESULT" "$HDR_STAGE_DIR"/*

  if [ ! -s "$PURE_METAL_RESULT" ]; then
    python3 - "$HDR_STAGE_RESULT" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "schemaVersion": 1,
    "status": "SKIPPED",
    "reason": "pure Metal artifact is missing",
    "stages": [],
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    echo 'HDR STAGE ISOLATION: SKIPPED (pure Metal artifact is missing)'
    exit 0
  fi
  PURE_METAL_CLASSIFICATION="$(python3 - "$PURE_METAL_RESULT" <<'PY'
import json
import sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("classification", ""))
except (OSError, json.JSONDecodeError):
    print("")
PY
)"
  if [ "$PURE_METAL_CLASSIFICATION" != "PURE_METAL_MULTIFLIGHT_PASS" ]; then
    python3 - "$HDR_STAGE_RESULT" "$PURE_METAL_CLASSIFICATION" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "schemaVersion": 1,
    "status": "SKIPPED",
    "reason": "pure Metal ladder did not pass",
    "pureMetalClassification": sys.argv[2],
    "stages": [],
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    echo "HDR STAGE ISOLATION: SKIPPED (pure Metal classification=$PURE_METAL_CLASSIFICATION)"
    exit 0
  fi

  FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sdr2hdr-real-media-hdr-stage.XXXXXX")"
  trap 'rm -rf "$FIXTURE_DIR"' EXIT
  command -v ffmpeg >/dev/null 2>&1 || {
    echo 'HDR STAGE ISOLATION: FAIL (ffmpeg is required)' >&2
    exit 2
  }
  command -v ffprobe >/dev/null 2>&1 || {
    echo 'HDR STAGE ISOLATION: FAIL (ffprobe is required)' >&2
    exit 2
  }
  stage 'HDR stage compressed fixture generation' \
    bash Tests/RealMediaRegression/generate_regression_fixtures.sh "$FIXTURE_DIR"
  stage 'HDR stage ffprobe fixture contracts' \
    bash Tests/RealMediaRegression/verify_regression_fixtures.sh "$FIXTURE_DIR"

  HDR_STAGE_FIXTURE="${HDR_PRODUCTION_STAGE_FIXTURE:-h264-8-video-24-chroma-edge}"
  HDR_STAGE_FRAMES="${HDR_PRODUCTION_STAGE_FRAMES:-2}"
  HDR_STAGE_OS="$(sw_vers -productVersion 2>/dev/null || printf 'unknown')"
  HDR_STAGE_KERNEL="$(uname -sr 2>/dev/null || printf 'unknown')"
  HDR_STAGE_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"
  HDR_STAGE_BASELINE="$(git merge-base origin/main HEAD 2>/dev/null || \
    git merge-base main HEAD 2>/dev/null || echo 'manifest-baseline')"

  HDR_STAGE_NAMES=(
    H1_HDRProcessor_only
    H2_HDRProcessor_plus_raw_blit
    H3_HDRProcessor_plus_presentation
    H4_full_path
  )
  for stage_name in "${HDR_STAGE_NAMES[@]}"; do
    log_path="$HDR_STAGE_DIR/$stage_name.log"
    timing_path="$HDR_STAGE_DIR/$stage_name.timing.json"
    start_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set +e
    env \
      MTL_DEBUG_LAYER=0 \
      HDR_PRODUCTION_STAGE="$stage_name" \
      HDR_PRODUCTION_COMPLETION_MODE=waitUntilCompleted \
      HDR_PRODUCTION_STAGE_FIXTURE="$HDR_STAGE_FIXTURE" \
      HDR_PRODUCTION_STAGE_FRAMES="$HDR_STAGE_FRAMES" \
      HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR="$FIXTURE_DIR" \
      HDR_REAL_MEDIA_REGRESSION_MANIFEST="$ROOT/Tests/RealMediaRegression/manifest.json" \
      HDR_REAL_MEDIA_REGRESSION_GATES="$ROOT/Tests/RealMediaRegression/gates.json" \
      swift test -c debug --disable-index-store \
        --filter RealMediaHDRStageIsolationTests/testVMAppleHDRStage \
        >"$log_path" 2>&1
    status=$?
    set -e
    end_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$timing_path" "$status" "$start_timestamp" "$end_timestamp" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "exitCode": int(sys.argv[2]),
    "processStartTimestamp": sys.argv[3],
    "processEndTimestamp": sys.argv[4],
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    echo "HDR_STAGE stage=$stage_name exit=$status log=$log_path"
  done

  HDR_COMPLETION_CONTROL_NAMES=(
    H4_completion_handler_direct_wait
    H4_completion_handler_async_waiter
  )
  HDR_COMPLETION_CONTROL_SETTINGS=(
    completion-handler-direct-wait
    async-waiter
  )
  for control_index in "${!HDR_COMPLETION_CONTROL_NAMES[@]}"; do
    completion_control_name="${HDR_COMPLETION_CONTROL_NAMES[$control_index]}"
    completion_control_setting="${HDR_COMPLETION_CONTROL_SETTINGS[$control_index]}"
    completion_control_log="$HDR_STAGE_DIR/$completion_control_name.log"
    completion_control_timing="$HDR_STAGE_DIR/$completion_control_name.timing.json"
    completion_control_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set +e
    env \
      MTL_DEBUG_LAYER=0 \
      HDR_PRODUCTION_STAGE=H4_full_path \
      HDR_PRODUCTION_COMPLETION_MODE="$completion_control_setting" \
      HDR_PRODUCTION_STAGE_FIXTURE="$HDR_STAGE_FIXTURE" \
      HDR_PRODUCTION_STAGE_FRAMES="$HDR_STAGE_FRAMES" \
      HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR="$FIXTURE_DIR" \
      HDR_REAL_MEDIA_REGRESSION_MANIFEST="$ROOT/Tests/RealMediaRegression/manifest.json" \
      HDR_REAL_MEDIA_REGRESSION_GATES="$ROOT/Tests/RealMediaRegression/gates.json" \
      swift test -c debug --disable-index-store \
        --filter RealMediaHDRStageIsolationTests/testVMAppleHDRStage \
        >"$completion_control_log" 2>&1
    completion_control_status=$?
    set -e
    completion_control_end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$completion_control_timing" "$completion_control_status" \
      "$completion_control_start" "$completion_control_end" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "exitCode": int(sys.argv[2]),
    "processStartTimestamp": sys.argv[3],
    "processEndTimestamp": sys.argv[4],
}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
    echo "HDR_STAGE control=$completion_control_setting exit=$completion_control_status log=$completion_control_log"
  done

  set +e
  python3 - "$HDR_STAGE_RESULT" "$HDR_STAGE_DIR" "$HDR_STAGE_FIXTURE" \
    "$HDR_STAGE_FRAMES" "$HDR_STAGE_OS" "$HDR_STAGE_KERNEL" "$HDR_STAGE_ARCH" \
    "$HDR_STAGE_BASELINE" <<'PY'
import json
import pathlib
import sys

result_path = pathlib.Path(sys.argv[1])
directory = pathlib.Path(sys.argv[2])
fixture = sys.argv[3]
frames = int(sys.argv[4])
os_version = sys.argv[5]
kernel = sys.argv[6]
architecture = sys.argv[7]
baseline = sys.argv[8]
stage_names = [
    "H1_HDRProcessor_only",
    "H2_HDRProcessor_plus_raw_blit",
    "H3_HDRProcessor_plus_presentation",
    "H4_full_path",
]

def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None

def signal_for(exit_code, lines):
    if any(
        "SIGTRAP" in line or
        "unexpected signal code 5" in line or
        "signal code 5" in line or
        "signal 5" in line
        for line in lines
    ):
        return 5
    if exit_code is not None and 129 <= exit_code <= 192:
        return exit_code - 128
    return None

stages = []
for stage in stage_names:
    log_path = directory / f"{stage}.log"
    timing = read_json(directory / f"{stage}.timing.json") or {}
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        lines = []
    payload = None
    for line in lines:
        if line.startswith("HDR_STAGE_RESULT "):
            try:
                payload = json.loads(line[len("HDR_STAGE_RESULT "):])
            except json.JSONDecodeError:
                payload = None
    exit_code = timing.get("exitCode")
    signal = signal_for(exit_code, lines)
    if payload and payload.get("status") == "PASS" and exit_code == 0 and signal is None:
        status = "PASS"
    elif signal is not None:
        status = "SIGNAL"
    else:
        status = "FAIL"
    markers = [
        line for line in lines
        if line.startswith("HDR_STAGE_PROGRESS ") or
           line.startswith("HDR_STAGE_RESULT ")
    ]
    stages.append({
        "stage": stage,
        "status": status,
        "exitCode": exit_code,
        "signal": signal,
        "completionMode": (payload or {}).get("completionMode", "waitUntilCompleted"),
        "frames": (payload or {}).get("frames", frames),
        "commandBuffersCommitted": (payload or {}).get("commandBuffersCommitted", 0),
        "commandBuffersCompleted": (payload or {}).get("commandBuffersCompleted", 0),
        "error": (payload or {}).get("error"),
        "lastMarker": markers[-1] if markers else None,
        "log": str(log_path),
        "timing": timing,
    })

completion_control_specs = [
    ("H4_completion_handler_direct_wait", "completionHandler+directWait"),
    ("H4_completion_handler_async_waiter", "completionHandler+asyncWaiter"),
]
completion_controls = []
for control_name, default_mode in completion_control_specs:
    control_log_path = directory / f"{control_name}.log"
    control_timing = read_json(directory / f"{control_name}.timing.json") or {}
    try:
        control_lines = control_log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        control_lines = []
    control_payload = None
    for line in control_lines:
        if line.startswith("HDR_STAGE_RESULT "):
            try:
                control_payload = json.loads(line[len("HDR_STAGE_RESULT "):])
            except json.JSONDecodeError:
                control_payload = None
    control_exit_code = control_timing.get("exitCode")
    control_signal = signal_for(control_exit_code, control_lines)
    if control_payload and control_payload.get("status") == "PASS" and control_exit_code == 0 and control_signal is None:
        control_status = "PASS"
    elif control_signal is not None:
        control_status = "SIGNAL"
    else:
        control_status = "FAIL"
    control_markers = [
        line for line in control_lines
        if line.startswith("HDR_STAGE_PROGRESS ") or
           line.startswith("HDR_STAGE_RESULT ")
    ]
    completion_controls.append({
        "control": "completion-handler-direct-wait" if "direct_wait" in control_name else "completion-handler+async-waiter",
        "stage": "H4_full_path",
        "completionMode": (control_payload or {}).get("completionMode", default_mode),
        "status": control_status,
        "exitCode": control_exit_code,
        "signal": control_signal,
        "frames": (control_payload or {}).get("frames", frames),
        "commandBuffersCommitted": (control_payload or {}).get("commandBuffersCommitted", 0),
        "commandBuffersCompleted": (control_payload or {}).get("commandBuffersCompleted", 0),
        "error": (control_payload or {}).get("error"),
        "lastMarker": control_markers[-1] if control_markers else None,
        "log": str(control_log_path),
        "timing": control_timing,
    })
completion_control = next(
    (control for control in completion_controls if control["control"] == "completion-handler+async-waiter"),
    None,
)
first_failing_control = next(
    (control["control"] for control in completion_controls if control["status"] != "PASS"),
    None,
)

first_failing = next((stage["stage"] for stage in stages if stage["status"] != "PASS"), None)
if first_failing is not None:
    classification = f"HDR_STAGE_FAILURE:{first_failing}"
elif first_failing_control is not None:
    classification = "HDR_COMPLETION_HANDLER_ASYNC_WAITER_FAILURE"
else:
    classification = "HDR_STAGES_ALL_PASS"
document = {
    "schemaVersion": 1,
    "baseline": baseline,
    "status": "PASS" if first_failing is None and first_failing_control is None else "FAIL",
    "classification": classification,
    "pureMetalClassification": "PURE_METAL_MULTIFLIGHT_PASS",
    "environment": {
        "os": os_version,
        "kernel": kernel,
        "architecture": architecture,
        "fixture": fixture,
        "frames": frames,
    },
    "stages": stages,
    "firstFailingStage": first_failing,
    "completionControls": completion_controls,
    "completionControl": completion_control,
    "firstFailingControl": first_failing_control,
}
result_path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps({"classification": classification, "firstFailingStage": first_failing}, sort_keys=True))
raise SystemExit(0 if first_failing is None and first_failing_control is None else 1)
PY
  hdr_stage_status=$?
  set -e
  echo "HDR STAGE ISOLATION: artifact=$HDR_STAGE_RESULT"
  echo 'Virgin Frozen accessed: NO'
  echo 'Objective evaluations: 0'
  exit "$hdr_stage_status"
fi

if [ "$MODE" = "real-media" ] || [ "$MODE" = "real-media-validation" ]; then
  if [ -z "${HDR_REAL_MEDIA_ROOT:-}" ]; then
    echo 'EXTERNAL REAL-MEDIA: SKIPPED (HDR_REAL_MEDIA_ROOT not set)'
    echo 'Virgin Frozen accessed: NO'
    echo 'Objective evaluations: 0'
    exit 0
  fi
  command -v ffprobe >/dev/null 2>&1 || {
    echo 'EXTERNAL REAL-MEDIA: FAIL (ffprobe is required)' >&2
    exit 2
  }
  EXTERNAL_MANIFEST="${HDR_EXTERNAL_MEDIA_MANIFEST:-$ROOT/data_video/real_media/external-manifest.json}"
  [ -f "$EXTERNAL_MANIFEST" ] || {
    echo "EXTERNAL REAL-MEDIA: FAIL (manifest missing: $EXTERNAL_MANIFEST)" >&2
    exit 2
  }
  EXTERNAL_SPLIT='development'
  EXTERNAL_FILTER='ExternalRealMediaRegressionTests/testExternalDevelopmentCorpusRunsWhenConfigured'
  EXTERNAL_RESULT="$ROOT/results/external-real-media-development.json"
  if [ "$MODE" = "real-media-validation" ]; then
    EXTERNAL_SPLIT='validation'
    EXTERNAL_FILTER='ExternalRealMediaRegressionTests/testExternalValidationCorpusRunsWhenConfigured'
    EXTERNAL_RESULT="$ROOT/results/external-real-media-validation.json"
  fi
  SOURCE_COUNT="$(python3 - "$EXTERNAL_MANIFEST" "$EXTERNAL_SPLIT" <<'PY'
import json
import sys
document = json.load(open(sys.argv[1], encoding='utf-8'))
print(sum(1 for source in document.get('sources', []) if source.get('split') == sys.argv[2]))
PY
)"
  if [ "$SOURCE_COUNT" = '0' ]; then
    echo "EXTERNAL REAL-MEDIA: SKIPPED (manifest has no $EXTERNAL_SPLIT sources)"
    echo 'Virgin Frozen accessed: NO'
    echo 'Objective evaluations: 0'
    exit 0
  fi
  stage "external real-media $EXTERNAL_SPLIT corpus" env \
    HDR_REAL_MEDIA_ROOT="$HDR_REAL_MEDIA_ROOT" \
    HDR_EXTERNAL_MEDIA_MANIFEST="$EXTERNAL_MANIFEST" \
    HDR_EXTERNAL_MEDIA_RESULTS="$EXTERNAL_RESULT" \
    swift test -c debug --disable-index-store --filter "$EXTERNAL_FILTER"
  echo "EXTERNAL REAL-MEDIA VERIFY ($EXTERNAL_SPLIT): PASS"
  echo 'Virgin Frozen accessed: NO'
  echo 'Objective evaluations: 0'
  exit 0
fi

TOTAL_START=$SECONDS

if [ "$MODE" = "prime" ]; then
  stage 'debug HDRCalibrate build' swift build -c debug --disable-index-store --product HDRCalibrate
  CALIBRATOR="$(calibrator_for debug)"
  prime_cache_from_current_artifacts "$CALIBRATOR"
  print_summary
  printf '\nTOTAL VERIFY TIME: %ss (%s mode)\n' "$((SECONDS - TOTAL_START))" "$MODE"
  exit 0
fi

if [ "$MODE" = "fast" ]; then
  stage 'debug HDRCalibrate build' swift build -c debug --disable-index-store --product HDRCalibrate
  CALIBRATOR="$(calibrator_for debug)"

  AUDIT_KEY="$(fingerprint audit)"
  run_audit_cached "$CALIBRATOR" "$AUDIT_KEY"

  # Unit/integration tests remain mandatory in fast mode; only expensive media
  # validation and correctness re-decode may be cached.
  stage 'debug tests' swift test -c debug --disable-index-store

  CORRECTNESS_INPUT_KEY="$(fingerprint correctness)"
  CORRECTNESS_KEY="$(printf '%s\n%s\n' "$AUDIT_KEY" "$CORRECTNESS_INPUT_KEY" | shasum -a 256 | awk '{print $1}')"
  run_correctness_cached "$CALIBRATOR" "$CORRECTNESS_KEY"
else
  stage 'release HDRCalibrate build' swift build -c release --disable-index-store --product HDRCalibrate
  CALIBRATOR="$(calibrator_for release)"
  stage 'dataset audit / evidence refresh' run_audit "$CALIBRATOR"

  stage 'debug tests' swift test -c debug --disable-index-store
  stage 'release tests' swift test -c release --disable-index-store
  stage 'correctness review' run_correctness "$CALIBRATOR"
  assert_pre_v6_ready "$CALIBRATOR"

  # Seed the fast cache only after the full content-validating run succeeds.
  AUDIT_KEY="$(fingerprint audit)"
  CORRECTNESS_INPUT_KEY="$(fingerprint correctness)"
  CORRECTNESS_KEY="$(printf '%s\n%s\n' "$AUDIT_KEY" "$CORRECTNESS_INPUT_KEY" | shasum -a 256 | awk '{print $1}')"
  cache_store audit "$AUDIT_KEY" \
    results/dataset-v4-final.json \
    data_video/dataset-v4-lock.json
  cache_store correctness "$CORRECTNESS_KEY" \
    results/pre-v5-final-correctness.json \
    results/pre-v5-frozen-coverage-policy.json \
    results/temporal-burst-parity.json \
    results/v6-prepared-evaluation-plan.json \
    results/v6-prepared-evaluation-plan.sha256
fi

print_summary
printf '\nTOTAL VERIFY TIME: %ss (%s mode)\n' "$((SECONDS - TOTAL_START))" "$MODE"
