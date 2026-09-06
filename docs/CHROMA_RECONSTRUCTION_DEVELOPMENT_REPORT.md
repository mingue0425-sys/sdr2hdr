# Chroma Reconstruction Development Report

## Baseline

- production baseline: `main@a7a43ff` (merge of P010 PR #3; parent production SHA `570d763`)
- development branch: `chroma-reconstruction-development`
- candidate implementation: siting-aware bilinear reconstruction, explicitly selected by configuration/CLI
- production default: legacy nearest reconstruction remains selected by `calibratedV4`

The branch was created only after `main` was fast-forwarded to `a7a43ff`. No V4/V6 tuning, Frozen/Virgin access, or objective evaluation was performed.

## Current Chroma Path

Before this change, both NV12 and P010 used the same integer nearest lookup:

```text
luma (x, y) → chroma (x / 2, y / 2) → one UV sample
```

The new development path is:

```text
CVPixelBuffer chroma-location attachment
→ resolved first chroma sample center in luma-edge coordinates
→ explicit 4-tap bilinear reconstruction
→ range/code normalization
→ existing YCbCr conversion and V4 processing
```

The same `reconstructedChroma()` geometry helper is used by the NV12 main kernel, P010 main kernel, both debug kernels, and both temporal luminance estimator kernels. The legacy nearest branch remains an exact integer lookup when the reconstruction mode is `.nearest`.

## Chroma Geometry

CoreVideo SDK metadata was checked against the local macOS SDK. Supported locations are:

| CoreVideo location | First chroma center `(x, y)` in luma-edge units |
|---|---:|
| `Center` | `(1.0, 1.0)` |
| `Left` | `(0.5, 1.0)` |
| `TopLeft` | `(0.5, 0.5)` |
| `Top` | `(1.0, 0.5)` |
| `BottomLeft` | `(0.5, 1.5)` |
| `Bottom` | `(1.0, 1.5)` |
| `DV420` | `(0.5, 1.0)` progressive approximation; field alternation is retained in diagnostics |

For progressive media only the top-field attachment is used by CoreVideo. If both fields agree, that location is used. If metadata is absent or unusable, the documented fallback is `unspecified(default=center)`. If top and bottom fields disagree, the resolver fails safe to centered geometry and records the mismatch in diagnostics.

The actual compressed fixtures reported `Left` for both fields:

```text
H.264 420v: top=left, bottom=left
HEVC Main10 x420: top=left, bottom=left
```

NV12 uses `r8Unorm/rg8Unorm` and P010 uses `r16Unorm/rg16Unorm`; only code-value normalization differs. Spatial geometry is shared.

## Accuracy

The synthetic edge tests use an independent scalar plane reference with a known continuous chroma transition at luma coordinate 32.0. Values below are mean absolute reconstructed chroma error, edge displacement in luma pixels, and P95 RGB channel error respectively.

| direction | method | mean chroma error | edge displacement | RGB P95 error |
|---|---|---:|---:|---:|
| vertical | nearest | 0.0078125 | 0.25 | 0.029257774 |
| vertical | centered bilinear | 0.008056641 | 0.50 | 0.049212486 |
| vertical | siting-aware bilinear | 0.00048828125 | 0.00 | 0.000000000 |
| horizontal | nearest | 0.0078125 | 0.25 | 0.029257774 |
| horizontal | centered bilinear | 0.008056641 | 0.50 | 0.049212486 |
| horizontal | siting-aware bilinear | 0.00048828125 | 0.00 | 0.000000000 |

The result is a geometry result for the known left/top-left synthetic fixtures. It does not claim that every real-media edge has zero error.

Independent scalar-to-Metal readback parity was:

```text
NV12 maximum RGB error: 0.00012040138
P010 maximum RGB error: 0.000120431185
```

The 2×2 precision/reconstruction matrix was exercised for NV12 nearest, NV12 siting-aware, P010 nearest, and P010 siting-aware. Exactly representable signals had zero NV12/P010 delta in both reconstruction modes, while the chroma fixture produced a `0.043823242` nearest-to-siting-aware output delta for both precisions.

Neutral Cb/Cr stayed neutral for both formats (`maxChannelSpread=0.0`), and grayscale output stayed unchanged between nearest and siting-aware paths (`maxDelta=0.0`). Boundary scalar tests cover all four image edges with clamped sampling.

## Temporal Alignment

The temporal estimator calls the same geometry helper as the visible main path. On the alternating synthetic chroma fixture, the estimator produced finite causal statistics and committed sequence 1 without regression. The measured P50 luminance differed between nearest and siting-aware modes as expected from the different spatial sample (`0.3359375` versus `0.3046875`); both main and estimator use the selected mode consistently.

## Real-Media E2E

Both existing compressed fixtures were run through the candidate reconstruction path:

```text
compressed H.264 / HEVC Main10 MP4
→ AVURLAsset
→ AVPlayerItemVideoOutput
→ 420v / x420 CVPixelBuffer
→ CoreVideo chroma metadata resolution
→ CVMetalTextureCache Y/UV planes
→ HDRProcessor calibratedV4
→ RGBA16Float HDRFrame
→ offscreen presentation
→ finite, non-zero readback
```

Each fixture processed ten sequential frames. Command buffers completed without GPU errors, output remained finite and non-zero, and adaptive/GPU sequence counters reached 10. The tests explicitly selected `.sitingAwareBilinear`; the production default remains nearest until a broader quality and performance gate promotes the candidate.

## Performance

Local Apple M2 measurement, 640×360, 30 warmup frames and 300 measured frames:

| path | GPU p50 (ms) | GPU p95 (ms) | GPU p99 (ms) | CPU p50 (ms) | CPU p95 (ms) | CPU p99 (ms) |
|---|---:|---:|---:|---:|---:|---:|
| NV12 nearest | 0.164 | 0.176 | 0.616 | 0.012 | 0.014 | 0.018 |
| NV12 siting-aware bilinear | 0.084 | 0.195 | 0.284 | 0.010 | 0.013 | 0.018 |
| P010 nearest | 0.064 | 0.186 | 0.194 | 0.013 | 0.015 | 0.018 |
| P010 siting-aware bilinear | 0.073 | 0.215 | 0.221 | 0.013 | 0.013 | 0.017 |

The benchmark is a local development measurement; the very small GPU timings are subject to scheduling noise. The siting-aware candidate has a measurable p95 cost in this run, especially for P010, so it is exposed as an explicit candidate rather than silently becoming the production default.

## Tests and Commands

Executed locally:

```text
swift test -c debug --disable-index-store: PASS (243 tests, 6 skipped)
swift test -c release --disable-index-store: PASS (243 tests, 6 skipped)
swift build -c debug --disable-index-store: PASS
swift build -c release --disable-index-store: PASS
bash Tests/verify_tiny_media_fixture.sh: PASS
bash Tests/verify_script_cache_test.sh: PASS
./RUN_MACOS_VERIFY.sh self-contained: PASS
./RUN_MACOS_VERIFY.sh p010: PASS
git diff --check: PASS
```

The existing self-contained verification already runs the compressed 8-bit and P010 real-media stages, so no CI workflow change was required for the synthetic chroma suite. A remote CI run was not initiated from this local branch.

`./RUN_MACOS_VERIFY.sh fast` was not run because it belongs to the larger dataset verification workflow; no protected dataset was opened for this development validation.

## Production Invariants

```text
calibratedV4 parameters changed: NO
toneExpand arithmetic changed: NO
temporal parameters changed: NO
histogram strategy changed: NO
P010 normalization changed: NO
EDR mapping changed: NO
production default reconstruction changed: NO
```

The shader change is restricted to input chroma sampling dispatch and calls to the shared reconstruction helper. V4 luminance, tone-expansion, temporal, histogram, and presentation arithmetic remain unchanged.

## Dataset Isolation

```text
K-Choreo accessed: NO
Virgin Frozen accessed: NO
Objective evaluations: 0
```

## Remaining Risks

- The compressed fixtures expose `Left` siting; broader real-media coverage is still needed for all CoreVideo locations and codec/container combinations.
- `DV420` is represented by a documented progressive approximation because its metadata describes alternating field phase; interlaced field-aware reconstruction remains separate work.
- The candidate currently uses four manual texture reads. Its quality improvement is measured on independent synthetic geometry fixtures, while its broader GPU cost and visual benefit require more media coverage before production promotion.
- No 4:2:0 CPU full-frame conversion or BGRA intermediate was added.

## Git State

The feature branch is based on `a7a43ff` and contains the implementation, tests, and this report. Main was not modified or pushed from this work.
