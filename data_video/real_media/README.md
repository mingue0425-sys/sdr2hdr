# External real-media corpus

This directory contains the external corpus manifest and acquisition metadata.
The playable media files are kept outside the repository and are supplied
through `HDR_REAL_MEDIA_ROOT`.

Populate `external-manifest.json` with local files before running:

```bash
HDR_REAL_MEDIA_ROOT=/Volumes/game/sdr2hdr-real-media \
  ./RUN_MACOS_VERIFY.sh real-media

HDR_REAL_MEDIA_ROOT=/Volumes/game/sdr2hdr-real-media \
  ./RUN_MACOS_VERIFY.sh real-media-validation
```

Each source must have a SHA-256, source-family provenance, split, category,
strict metadata expectations where known, and fixed representative windows.
Development and validation sources may not share a `sourceFamily`. The
external runner records nearest and siting-aware results side by side; it does
not make an HDR quality or promotion decision without a paired HDR reference.

The deterministic compressed-media matrix in
`Tests/RealMediaRegression/manifest.json` remains the mandatory CI gate.

## Acquisition snapshot (2026-09-06)

See [ACQUISITION_REPORT.md](ACQUISITION_REPORT.md) for 16 families / 17
sources, splits, provenance and explicit coverage gaps. `sources/` contains
one metadata entry per playable source. Media remains external.

The configured local corpus was exercised on 2026-09-06:

- development: 12 sources, 0 failures, 0 metadata-only skips;
- validation: 5 sources, 0 failures, 1 metadata-only skip.

`blender-elephants-dream-hevc8` is explicitly `engineEvaluation:
metadata-only` because its repaired derivative carries SMPTE 170M
colorimetry, outside the current HDRCore BT.709 SDR runtime domain. Its hash
and metadata are still inspected; it is not reported as an HDRCore runtime
pass. Virgin Frozen accessed: NO; Objective evaluations: 0.
