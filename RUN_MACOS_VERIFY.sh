#!/bin/bash
set -euo pipefail

MODE="${1:-full}"
ROOT="${2:-$(pwd)}"

case "$MODE" in
  fast|full|prime) ;;
  *)
    echo "usage: $0 [fast|full|prime] [repo-root]" >&2
    exit 2
    ;;
esac

cd "$ROOT"
mkdir -p results .build/pre-v5-verify-cache
CACHE_DIR="$ROOT/.build/pre-v5-verify-cache"
CACHE_VERSION="pre-v5-fast-cache-v2-fail-closed"

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
# `full` never trusts this cache and always performs the content-validating audit.
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
    rel = str(p.relative_to(root)) if p.is_absolute() else str(p)
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

if scope == 'audit':
    source_roots = [root/'Sources/HDRCalibration']
else:
    source_roots = [root/'Sources/HDRCalibration', root/'Sources/HDRCore']
    # The CLI owns semantic exit-code behavior for correctness-review, so it is
    # part of the correctness cache identity as well.
    add_file(root/'Sources/HDRCalibrate/main.swift')

for base in source_roots:
    if base.exists():
        for p in sorted(base.rglob('*.swift')):
            add_file(p)

# Media/stat evidence. JSON files are generated/manifest state and are handled
# separately above; backups are explicitly ignored.
data = root/'data_video'
if data.exists():
    for p in sorted(x for x in data.rglob('*') if x.is_file()):
        if p.suffix.lower() == '.json' or '.bak' in p.name:
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
  local artifact
  for artifact in "$@"; do
    [ -s "$artifact" ] || return 1
  done
}

cache_store() {
  local name="$1" key="$2"
  printf '%s\n' "$key" > "$CACHE_DIR/$name.key.tmp"
  mv "$CACHE_DIR/$name.key.tmp" "$CACHE_DIR/$name.key"
}


inputs_newest_mtime_ns() {
  local scope="$1"
  python3 - "$ROOT" "$scope" <<'PYMTIME'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
scope = sys.argv[2]
paths = [root/'Package.swift', root/'data_video/manifest-v4.json', root/'dataset/holdout-provenance-v5.json']
source_roots = [root/'Sources/HDRCalibration'] if scope == 'audit' else [root/'Sources/HDRCalibration', root/'Sources/HDRCore']
if scope != 'audit':
    paths.append(root/'Sources/HDRCalibrate/main.swift')
for base in source_roots:
    if base.exists():
        paths.extend(sorted(base.rglob('*.swift')))
data = root/'data_video'
if data.exists():
    paths.extend(sorted(p for p in data.rglob('*') if p.is_file() and p.suffix.lower() != '.json' and '.bak' not in p.name))
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
  local audit_key correctness_input_key correctness_key
  local audit_input_mtime audit_artifact_mtime correctness_input_mtime correctness_artifact_mtime

  audit_key="$(fingerprint audit)"
  correctness_input_key="$(fingerprint correctness)"
  correctness_key="$(printf '%s\n%s\n' "$audit_key" "$correctness_input_key" | shasum -a 256 | awk '{print $1}')"

  audit_input_mtime="$(inputs_newest_mtime_ns audit)"
  audit_artifact_mtime="$(artifacts_oldest_mtime_ns results/dataset-v4-final.json data_video/dataset-v4-lock.json)"
  correctness_input_mtime="$(inputs_newest_mtime_ns correctness)"
  correctness_artifact_mtime="$(artifacts_oldest_mtime_ns results/pre-v5-final-correctness.json results/pre-v5-frozen-coverage-policy.json results/temporal-burst-parity.json)"

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
  assert_pre_v5_ready
  cache_store audit "$audit_key"
  cache_store correctness "$correctness_key"
  echo 'FAST CACHE PRIMED from fresh existing artifacts.'
  echo 'No objective evaluation was performed by this operation.'
}

run_audit() {
  local calibrator="$1"
  "$calibrator" dataset-audit \
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
    results/pre-v5-new-hlg-holdout-audit.json

  "$calibrator" correctness-review \
    --manifest data_video/manifest-v4.json \
    --output results/correctness-review-fixes.json \
    | tee results/pre-v5-macos-correctness.log
}


assert_pre_v5_ready() {
  python3 - "$ROOT" <<'PYVERIFY'
import json
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
            return json.load(handle)
    except Exception as exc:
        errors.append(f"invalid JSON in {relative}: {exc}")
        return None

final_path = results / "pre-v5-final-correctness.json"
coverage_path = results / "pre-v5-frozen-coverage-policy.json"
burst_candidates = [
    results / "temporal-burst-parity.json",
    results / "pre-v5-temporal-burst-parity.json",
]

final = load_required(final_path)
coverage = load_required(coverage_path)

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
    if verdict != "CORRECTNESS_READY_FOR_V5":
        errors.append(
            f"correctness verdict is {verdict!r}, expected 'CORRECTNESS_READY_FOR_V5'"
        )

    for key in ("virginFrozenObjectiveEvaluationCount", "objectiveEvaluationCount"):
        value = final.get(key)
        if value != 0:
            errors.append(
                f"{key} must be 0 during correctness review, got {value!r}"
            )

    checks = final.get("checks")
    if not isinstance(checks, list):
        errors.append("pre-v5-final-correctness.json has no checks array")
    else:
        seen = set()
        for check in checks:
            if not isinstance(check, dict):
                errors.append(
                    "pre-v5-final-correctness.json contains a non-object check"
                )
                continue

            check_id = str(check.get("id", "<missing-id>"))
            seen.add(check_id)
            required = bool(check.get("required", True))
            status = check.get("status")
            executed = check.get(
                "executed",
                status not in ("NOT_RUN", "NOT_MEASURED", "SKIPPED"),
            )
            if required and (executed is not True or status != "PASS"):
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
        }
        missing = sorted(critical - seen)
        if missing:
            errors.append(
                "missing critical correctness checks: " + ", ".join(missing)
            )

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

        if (
            not isinstance(max_in_flight, (int, float))
            or isinstance(max_in_flight, bool)
            or max_in_flight < 2
        ):
            errors.append(
                "temporal burst parity did not exercise a burst "
                f"(maxFramesInFlight={max_in_flight!r})"
            )

        if (
            not isinstance(max_error, (int, float))
            or isinstance(max_error, bool)
            or max_error > 1e-6
        ):
            errors.append(
                "temporal burst parity numerical mismatch "
                f"(maxAbsoluteError={max_error!r}, expected <= 1e-6)"
            )

if errors:
    print("PRE-V5 VERIFY FAILED:", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    raise SystemExit(1)

print("PRE-V5 semantic gates: PASS")
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
    cache_store audit "$key"
  fi
}

run_correctness_cached() {
  local calibrator="$1" key="$2"
  if cache_hit correctness "$key" \
      results/pre-v5-final-correctness.json \
      results/pre-v5-frozen-coverage-policy.json \
      results/temporal-burst-parity.json; then
    printf '\n== correctness review ==\n'
    echo 'CACHE HIT: correctness inputs unchanged; reusing pre-V5 correctness artifacts'
  else
    stage 'correctness review' run_correctness "$calibrator"
  fi

  # Cache presence/freshness is not sufficient. A cached FAIL must remain a
  # failing verification and must never be promoted into a green cache entry.
  assert_pre_v5_ready
  cache_store correctness "$key"
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

TOTAL_START=$SECONDS

if [ "$MODE" = "prime" ]; then
  prime_cache_from_current_artifacts
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
  assert_pre_v5_ready

  # Seed the fast cache only after the full content-validating run succeeds.
  AUDIT_KEY="$(fingerprint audit)"
  CORRECTNESS_INPUT_KEY="$(fingerprint correctness)"
  CORRECTNESS_KEY="$(printf '%s\n%s\n' "$AUDIT_KEY" "$CORRECTNESS_INPUT_KEY" | shasum -a 256 | awk '{print $1}')"
  cache_store audit "$AUDIT_KEY"
  cache_store correctness "$CORRECTNESS_KEY"
fi

print_summary
printf '\nTOTAL VERIFY TIME: %ss (%s mode)\n' "$((SECONDS - TOTAL_START))" "$MODE"
