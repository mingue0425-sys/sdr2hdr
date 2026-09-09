# DV420 Chroma Reconstruction Report

## Baseline

```text
production baseline: main@a1e4a6506723da53212b2ad86fcde11f44bc4a92
branch: dv420-correctness-development
production chroma reconstruction: nearest
```

This change is limited to making the current candidate reconstruction decision
safe for the CoreVideo `DV420` chroma-location attachment. No tone-curve,
temporal, histogram, P010 normalization, automatic decode, or EDR behavior was
changed.

## Current DV420 Path

Before this change, `HDRChromaSamplingGeometryResolver` resolved `DV420` to a
single provisional geometry `(0.5, 1.0)`. A requested
`.sitingAwareBilinear` mode therefore reached the shared `reconstructedChroma`
bilinear helper and treated DV420 as if Cb and Cr shared that center. This does
not represent DV420's possible component-specific and field-dependent phase.

The resolver now preserves the source siting label and geometry for
diagnostics/legacy nearest behavior, while `HDRChromaReconstructionResolver`
performs the reconstruction decision before shader parameters are created:

| resolved siting | requested mode | effective mode | fallback |
|---|---|---|---|
| `center`, `left`, `topLeft`, `top`, `bottomLeft`, `bottom` | nearest | nearest | no |
| `center`, `left`, `topLeft`, `top`, `bottomLeft`, `bottom` | siting-aware bilinear | siting-aware bilinear | no |
| `dv420` | nearest | nearest | no |
| `dv420` | siting-aware bilinear | nearest | yes, `dv420RequiresComponentSpecificPhase` |
| `unspecified` | siting-aware bilinear | siting-aware bilinear | no; existing centered fallback policy |

The effective mode is passed to the common `HDRShaderParameters` used by the
NV12/P010 main, DEBUG, and temporal kernels. The debug snapshot records both
requested and effective modes plus the typed fallback reason.

## Chroma Geometry

`HDRChromaSamplingGeometryResolver` continues to map the CoreVideo attachment
constants to the existing shared geometry model. For `DV420`, `(0.5, 1.0)` is
retained only as a deterministic diagnostic/nearest-path representation. It is
never consumed by the current siting-aware bilinear path after the new decision
is resolved.

The metadata path was exercised with
`kCVImageBufferChromaLocation_DV420`, which resolves to
`HDRChromaSiting.dv420` with `metadataWasExplicit == true`.

## NV12/P010 Parity

The same CPU decision is used for both input layouts. Explicit nearest and
DV420-requested bilinear fallback produced identical output in the synthetic
Metal fixtures:

```text
NV12 DV420 fallback max RGB delta: 0.0
P010 DV420 fallback max RGB delta: 0.0
DV420 temporal-statistics fallback max delta: 0.0
```

This preserves the existing nearest coordinates and does not add a separate
DV420 sampling branch in Metal.

## Supported Siting Candidate Regression

The decision remains bilinear for `center`, `left`, `topLeft`, `top`,
`bottomLeft`, and `bottom`. Existing scalar/Metal geometry tests continue to
cover the supported candidate path. The fallback is therefore limited to the
unsupported DV420 combination rather than changing the candidate behavior for
metadata that the current shared-center model can represent.

## Diagnostics

For a DV420 frame requesting the candidate, the diagnostic fields are:

```text
resolvedChromaSiting = dv420
requestedChromaReconstructionMode = siting-aware-bilinear
effectiveChromaReconstructionMode = nearest
chromaReconstructionMode = nearest
chromaReconstructionFallbackReason = dv420RequiresComponentSpecificPhase
```

`chromaReconstructionMode` remains the effective mode for compatibility with
existing consumers.

## Real-Media Validation

The deterministic and external media paths were rerun after the fallback was
added:

```text
deterministic regression-full: PASS
  12/12 fixtures, skipped=0, failures=0
  DEBUG and RELEASE matrix paths both passed

external development: PASS
  12 sources, failures=0
  automatic NV12=10, P010=2, fallback=0, mismatch=0

external validation: PASS
  5 manifest sources, failures=0
  4 runtime sources and 1 metadata-only source
  automatic NV12=4, P010=0, fallback=0, mismatch=0
```

The external corpus reports `left` chroma location for its inspected sources;
no DV420 source was encountered:

```text
DV420 external sources encountered: 0
DV420 fallback count: 0
```

The metadata-only validation source remains outside the HDRCore BT.709 runtime
domain under its existing policy. No acquisition timeout, threshold,
minimum-frame, or manifest policy was changed in this PR.

## Test Results

```text
swift test -c debug --disable-index-store: PASS (303 tests, 15 conditional skips)
swift test -c release --disable-index-store: PASS (303 tests, 15 conditional skips)
swift build -c release --disable-index-store: PASS
bash Tests/verify_script_cache_test.sh: PASS
./RUN_MACOS_VERIFY.sh self-contained: PASS
./RUN_MACOS_VERIFY.sh p010: PASS
./RUN_MACOS_VERIFY.sh automatic-decode: PASS
./RUN_MACOS_VERIFY.sh regression: PASS (12/12, skipped=0, failures=0)
./RUN_MACOS_VERIFY.sh regression-full: PASS (DEBUG and RELEASE, 12/12, skipped=0, failures=0)
HDR_REAL_MEDIA_ROOT=... ./RUN_MACOS_VERIFY.sh real-media: PASS (12 sources, failures=0)
HDR_REAL_MEDIA_ROOT=... ./RUN_MACOS_VERIFY.sh real-media-validation: PASS (5 sources, failures=0)
git diff --check: PASS
```

The focused chroma suite passed 23 tests, including the DV420 decision,
metadata, NV12/P010 parity, diagnostic, and temporal alignment tests.

## Production Invariants

```text
calibratedV4 changed: NO
toneExpand changed: NO
temporal changed: NO
histogram changed: NO
P010 normalization changed: NO
EDR changed: NO
production chroma default: nearest
```

No changes were made to `HDRConfiguration.calibratedV4` or
`Sources/HDRCore/Shaders/SDRToHDR.metal`. The production shader arithmetic and
the existing nearest branch remain unchanged.

## Future Full DV420 Design

Full DV420 support remains a separate task and is not promoted by this change.
An accurate implementation will need:

- Cb-specific horizontal and vertical phase;
- Cr-specific horizontal and vertical phase;
- progressive versus field-coded behavior;
- top-field and bottom-field phase handling;
- identical NV12/P010 geometry with separate code-depth normalization;
- a Metal sampling formulation validated against independent scalar code;
- synthetic ground truth for field and component phase; and
- real-media validation with explicit DV420 metadata.

Until those requirements are implemented and validated, DV420 candidate
bilinear reconstruction must continue to fall back to nearest.

## Dataset Isolation

```text
K-Choreo accessed: NO
Virgin Frozen accessed: NO
Objective evaluations: 0
```

## Git State

The branch remains based on `main@a1e4a650`. Production `main` was not modified
or pushed by this work. The implementation, tests, and this report are kept in
separate focused commits.
