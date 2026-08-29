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
CACHE_VERSION="pre-v5-fast-cache-v1"

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
    cache_store correctness "$key"
  fi
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

  # Seed the fast cache only after the full content-validating run succeeds.
  AUDIT_KEY="$(fingerprint audit)"
  CORRECTNESS_INPUT_KEY="$(fingerprint correctness)"
  CORRECTNESS_KEY="$(printf '%s\n%s\n' "$AUDIT_KEY" "$CORRECTNESS_INPUT_KEY" | shasum -a 256 | awk '{print $1}')"
  cache_store audit "$AUDIT_KEY"
  cache_store correctness "$CORRECTNESS_KEY"
fi

print_summary
printf '\nTOTAL VERIFY TIME: %ss (%s mode)\n' "$((SECONDS - TOTAL_START))" "$MODE"
