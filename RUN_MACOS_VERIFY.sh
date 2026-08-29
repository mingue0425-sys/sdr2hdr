#!/bin/bash
set -euo pipefail

ROOT="${1:-$(pwd)}"
cd "$ROOT"
mkdir -p results

printf '\n== debug build ==\n'
swift build -c debug
printf '\n== debug tests ==\n'
swift test -c debug
printf '\n== release build ==\n'
swift build -c release
printf '\n== release tests ==\n'
swift test -c release

printf '\n== dataset audit ==\n'
swift run -c release HDRCalibrate dataset-audit \
  --manifest data_video/manifest-v4.json \
  --output results/dataset-v4-final.json

printf '\n== correctness review ==\n'
swift run -c release HDRCalibrate correctness-review \
  --manifest data_video/manifest-v4.json \
  --output results/correctness-review-fixes.json \
  | tee results/pre-v5-macos-correctness.log

printf '\n== key result files ==\n'
for f in \
  results/pre-v5-new-hlg-holdout-audit.json \
  results/temporal-burst-parity.json \
  results/pre-v5-frozen-coverage-policy.json \
  results/pre-v5-final-correctness.json; do
  if [ -f "$f" ]; then
    echo "--- $f"
    cat "$f"
    echo
  fi
done
