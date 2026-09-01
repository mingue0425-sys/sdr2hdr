#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/data_video" "$TEST_ROOT/dataset" "$TEST_ROOT/results"
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

printf 'validated artifact\n' > "$TEST_ROOT/results/audit.json"
cache_store audit test-input-key "$TEST_ROOT/results/audit.json"
cache_hit audit test-input-key "$TEST_ROOT/results/audit.json"

printf 'tampered artifact\n' > "$TEST_ROOT/results/audit.json"
if cache_hit audit test-input-key "$TEST_ROOT/results/audit.json"; then
  echo 'FAIL: mutated artifact was accepted by cache' >&2
  exit 1
fi

echo 'verify script cache regression tests: PASS'
