# Dataset V4

`manifest-v4.json` is the default manifest for adding SDR/HDR calibration pairs.
The older `manifest.json` and `manifest-v2.json` remain unchanged for historical
experiments.

## Pair layout

Paths in the manifest are relative to `data_video/` unless absolute:

```json
{
  "id": "example_pair",
  "sdr": "new_pair/source_sdr.mov",
  "hdr": "new_pair/source_hdr.mov",
  "source": "official repository or user-owned source",
  "sourceURL": "https://...",
  "license": "license name or user-provided-local",
  "licenseURL": "https://...",
  "expectedRelation": "same-master",
  "contentCategory": ["daylight", "skin"],
  "contentFamily": "source family",
  "split": "tune",
  "virginFrozen": false,
  "group": "master-family-id",
  "notes": "provenance and known grade differences"
}
```

External roots are supported without copying large media into the repository.
For example, the LIVE import uses:

```json
{
  "roots": {
    "live": "/Volumes/game/sdr2hdr/data_video/LIVE Paired Comparison HDR vs. SDR Database"
  },
  "sdr": "live:open-sourced_SDR/example_SDR.mp4",
  "hdr": "live:open-sourced_HDR10/example_HDR10.mp4"
}
```

The `dataset-import-live` command discovers the local LIVE directory, probes
all matched variants, validates metadata, and validates a bounded set of
canonical source variants before proposing a diversity-balanced selection:

```bash
swift run -c release HDRCalibrate dataset-import-live \
  --root "/path/to/LIVE Paired Comparison HDR vs. SDR Database" \
  --manifest data_video/manifest-v4.json \
  --select 6 --dry-run
```

Remove `--dry-run` only after reviewing the generated discovery and selection
artifacts. The importer does not evaluate HDRCore objectives. `virginFrozen`
pairs are integrity/alignment checked only and are unavailable to calibration
search/evaluation.

Supported relations are `same-master`, `same-source`,
`same-content-different-grade`, `related-content`, and `unknown`. Only the first
two are eligible for the main calibration set. A `same-content-different-grade`
pair is retained as conditional/diagnostic evidence and is never treated as
pixel-perfect ground truth.

## Audit

Run the dataset-only audit:

```bash
swift run -c release HDRCalibrate dataset-audit \
  --manifest data_video/manifest-v4.json \
  --output results/dataset-v4-final.json
```

The audit performs file existence, SHA-256 integrity, ffprobe/AVFoundation
metadata validation, first/middle/last decode smoke, five-point temporal
alignment, spatial compatibility checks, and diversity reporting. It does not
run HDRCore objectives, calibration search, or frozen evaluation.

It writes:

```text
results/dataset-v4-final.json
results/dataset-v4-report.md
results/dataset-v4-metadata.json
results/dataset-v4-alignment.json
results/dataset-v4-diversity.json
data_video/dataset-v4-lock.json
```

`virginFrozen: true` pairs may be inspected for integrity and alignment, but
the dataset audit hard-codes `objectiveEvaluated: false`. Keep them out of all
search/validation commands until a separate experiment explicitly finalizes
its candidate.

## Source policy

Prefer user-owned files, official test media, and sources with an explicit
license. Record source and license URLs. A filename is never evidence that a
file is HDR or that two files are a pair. HDR must declare PQ/HLG-compatible
transfer and BT.2020 primaries, or have a manifest fallback explicitly backed
by source documentation. Missing/unclear rights, different edits, failed
decode, and low-confidence alignment stay out of the main calibration set.
The local LIVE import currently records `LICENSE_REVIEW_REQUIRED` because no
license notice was found beside the local media; this is a provenance flag,
not a redistribution claim.

The V4 audit does not download media. Public-source acquisition notes are kept
in `results/dataset-v4-acquisition.json`; when an official source requires a
manual download, place the files under a new pair directory and rerun the
audit.
