#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-$(pwd)}"
MANIFEST="$ROOT/data_video/manifest-v4.json"
PAIR_ID="live_16_night_biking_3840x2160_15000k"
MARKER="CONSUMED_HOLDOUT: V4 Virgin Frozen objective was previously exposed; excluded from all future virgin holdouts."

if [[ ! -f "$MANIFEST" ]]; then
  echo "manifest not found: $MANIFEST" >&2
  exit 2
fi

python3 - "$MANIFEST" "$PAIR_ID" "$MARKER" <<'PY'
import json, pathlib, shutil, sys, datetime
manifest = pathlib.Path(sys.argv[1])
pair_id = sys.argv[2]
marker = sys.argv[3]
data = json.loads(manifest.read_text())
pairs = data.get("pairs", [])
found = False
for pair in pairs:
    if pair.get("id") != pair_id:
        continue
    found = True
    before = pair.get("virginFrozen", False)
    pair["virginFrozen"] = False
    notes = pair.get("notes") or ""
    if marker not in notes:
        pair["notes"] = (notes + ("; " if notes else "") + marker)
    print(f"{pair_id}: virginFrozen {before} -> {pair['virginFrozen']}")
if not found:
    raise SystemExit(f"pair not found in manifest: {pair_id}")
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
backup = manifest.with_name(manifest.name + ".pre-v5-holdout-" + stamp + ".bak")
shutil.copy2(manifest, backup)
manifest.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print(f"backup: {backup}")
print("manifest updated; rerun dataset-audit to refresh lock/evidence hashes")
PY
