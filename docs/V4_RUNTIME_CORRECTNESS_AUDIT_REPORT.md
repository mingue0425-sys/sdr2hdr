# V4 Runtime Correctness Audit Report

## Scope

This patch removes correctness defects in the V4 runtime and evaluation paths. It does not retune V4/V5/V6 parameters, create a new tone curve, or change the calibrated V4 tone-expansion arithmetic.

- Branch: `v6-tone-curve-development`
- Base commit: `f9bc116d2d1e31e9a36b572981f0deea949fa427`
- Production reference: `d97c3d3c8fbf71447ff8b94a7fa7a77c5d25bebf`
- Frozen accessed: NO
- Virgin Frozen accessed: NO
- Objective evaluations: 0

## Changes and Evidence

### P0-1: atomic adaptive state

`HDRAdaptiveStateStore` now owns temporal adaptation, scene shadow statistics, validity, generation, and a common committed sequence. `HDRProcessor.process()` captures one snapshot for shader parameters. Automatic GPU completion updates validate generation and sequence while holding the same transaction lock, then commit both state families together. Configuration changes, seek resets, and history clears advance the generation before old completion handlers can update state.

Regression coverage includes coherent process snapshots, reverse completion order, stale generation rejection, reset rejection, and equal consumed/produced temporal and scene versions in the production burst trace.

### P0-2: EDR headroom safety

`EDRHeadroomSmoother` clamps a downward target immediately and smooths only upward motion. Invalid capability values are sanitized. `DisplayCapabilities` and `HDRDisplayState` normalize current headroom so the safe current value cannot exceed potential capability. Reverse timestamps contribute no additional movement, and long gaps are bounded by the existing smoothing policy.

Tests cover `4.0 -> 1.5`, ramp-up, NaN/infinity, zero/negative values, timestamp reversal, long gaps, and current/potential mismatch.

### P0-3: paired metric correspondence

V2 metrics, the legacy `ErrorMetrics` evaluator, and V6.2 scalar demand diagnostics now validate reference, generated, and source samples by shared index. They never independently compact paired arrays. `SceneMetrics.invalidPairedSampleCount` records excluded correspondence positions and remains backward-decodable for older JSON reports.

The regression fixture `[1, NaN, 3, 4]` versus `[1, 2, NaN, 4]` keeps only indices 0 and 3, reports two invalid samples, and produces zero error. Independent filtering would incorrectly compare 3 with 2.

### P1-1: content-time temporal adaptation

Timestamped automatic adaptation and scene statistics use

```text
alpha = 1 - exp(-dt / tau)
```

where `dt` comes from the media timestamp. The old 60 Hz step is retained only for untimestamped/manual callers. Reversed or duplicate timestamps are treated as discontinuities; gaps greater than 0.5 seconds snap to the new target. Tests cover 24, 30, 60, and 120 fps plus VFR timestamps and a large discontinuity.

### P1-2: paused seek redraw

`PlaybackSeekRedrawGate` gives every seek a generation. A current seek completion clears the relevant frame and temporal state, requests a new video-output notification, marks the frame for redraw, and invokes the display callback without temporarily playing the item. Late completions are rejected. The controller path is covered by the gate and existing frame-selection tests; media-backed paused-seek execution remains environment-dependent because the local fixture is absent.

### P1-3: mirrored track transforms

`VideoOrientation` now preserves rotation and horizontal/vertical reflection bits. The presentation shader applies the same transform decomposition as the CPU ROI path. Tests cover direct mirrors, rotation, and rotated reflection geometry. The full affine translation component remains a placement detail; the orientation resolver compares the linear transform and the renderer supplies display geometry separately.

### P1-4: scene histogram precision

The runtime scene estimator keeps its 16x9 sampling grid and changes only the histogram from 16 linear bins to 64 linear bins. This removes the old 0.0000...0.0625 shadow bucket collapse without adding a CPU readback or changing V4 tone-curve arithmetic.

Offline diagnostic comparison covers:

| Strategy | Resolution | Diagnostic result |
|---|---:|---|
| linear16 | 16 bins | 0.001, 0.01, and 0.05 collapse into the first bucket |
| linear64 | 64 bins | separates 0.05 from the two darker distributions |
| log64 | 64 bins | separates all three distributions with logarithmic shadow resolution |
| shadowDense64 | 64 bins | separates all three distributions with piecewise shadow resolution |

Only `linear64` is used by the runtime shader. The other layouts are comparison-only and cannot affect production output. The current Apple M2 synthetic benchmark reports GPU p50/p95 of 0.570/0.681 ms and CPU submission p50/p95 of 0.019/0.036 ms for calibrated V4 at 1920x1080, 60 measured frames after 10 warm-up frames. No alternate histogram shader was introduced, so their GPU cost is intentionally not presented as a runtime measurement.

### Preset and headroom semantics

`HDRPresetResolver` is now the shared resolver for player, sample, and benchmark preset names. The default is `calibrated-v4`. `HDRConfiguration.effectiveOutputHeadroom` and metadata `effectivePeakNits` make the EDR/PQ ceiling rule explicit:

```text
EDR: effective peak = paperWhiteNits * min(peakNits / paperWhiteNits, masteringHeadroom)
PQ:  effective peak = peakNits
```

The V4 production values and `sceneRelativeV4` revision remain exact.

## Production arithmetic audit

`HDRConfiguration.calibratedV4` was not changed. The production `toneExpand()` branch in `Sources/HDRCore/Shaders/SDRToHDR.metal` retains the existing `lowMidExpansion`, `shoulderExpansion`, protection, and clamp arithmetic. The shader diff contains only the temporal estimator histogram layout/binning change. Existing V4 parameter and CPU/Metal parity tests continue to pass.

## Tests and verification

| Command | Result |
|---|---|
| `swift test -c debug --disable-index-store` | PASS — 208 tests, 5 skipped |
| `swift test -c release --disable-index-store` | PASS — 208 tests, 5 skipped |
| `swift build -c release` | PASS |
| `bash Tests/verify_script_cache_test.sh` | PASS |
| `git diff --check` | PASS |
| `.build/arm64-apple-macosx/release/HDRBenchmark --frames 60 --warmup 10 --preset calibrated-v4` | PASS — Apple M2 synthetic runtime measurement |
| `./RUN_MACOS_VERIFY.sh fast` | BLOCKED by missing local media fixture during dataset audit |

The fast verification script failed before its correctness stages because the manifest references a missing local media file:

```text
The file “[K-Choreo 8K HDR] ... [a2RiqFAohlo].f628.mp4” couldn’t be opened because there is no such file.
```

The script did not modify tracked or visible `results/`/`data_video/` worktree state. The full verification mode was not run because the required media dataset is unavailable and this patch does not authorize opening protected Frozen/Virgin evaluation media.

## New issues found

1. **P1 environment gap:** real-media fast/full verification cannot run until the manifest-referenced K-Choreo media is restored.
2. **P1 integration coverage gap:** paused-seek redraw and display migration need AVPlayer/AVPlayerItemVideoOutput fixtures for end-to-end coverage; pure generation gates and capability tests are covered locally.
3. **P2 estimator comparison gap:** log and shadow-dense layouts are implemented as offline diagnostics only. A GPU cost comparison requires a controlled device benchmark branch and must not be mixed into V4 production without a separate review.

## Deliberately deferred technical debt

- 10-bit SDR/P010 input and a native 10-bit Metal representation.
- Proper 4:2:0 chroma reconstruction and chroma-siting metadata. The current NV12 path remains the existing 8-bit path.
- Real-media CI and fixture provisioning.
- Frozen family × transfer dataset expansion.
- Full end-to-end paused-seek and screen-migration tests with real AVFoundation media.

## Git state at report generation

This report is part of the current correctness patch. Unrelated user files were not reset, deleted, or stashed. Final file lists and worktree state are reported with the completion message.
