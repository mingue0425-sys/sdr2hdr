# V4 Runtime Correctness Hardening Report

## Scope

This pass starts from `8395ee4` on `v6-tone-curve-development`. It hardens
runtime state publication, completion diagnostics, estimator attribution, seek
redraw orchestration, and display headroom safety. It does not tune V4, search
V6 parameters, access Frozen media, or run an objective evaluation.

## Required status table

| 항목 | 8395ee4 상태 | 발견한 문제 | 수정 | 테스트 | 결과 |
|---|---|---|---|---|---|
| Adaptive state | One outer store existed, but leaf updates were separately modeled and scene acceptance was implicit | A future scene rejection could leave temporal and scene generations conceptually split | Value-semantic candidate state; publish only after required component sequence checks pass | Rollback, reversed completion, stale generation, non-scene mode, concurrent snapshot tests | PASS |
| Completion bookkeeping | GPU completion and adaptive completion shared an ambiguous compatibility name | A completed GPU command could be mistaken for an accepted causal update | Separate `lastGPUCompletedSequence` and `lastAdaptiveCommittedSequence`; trace records generation and both meanings | Out-of-order and stale-generation ledger tests; Metal trace assertions | PASS |
| Histogram estimator | Production behavior was encoded as a fixed 64-bin linear layout | The layout was not named in configuration and candidate layouts were not comparable | Added explicit `HDRSceneHistogramStrategy`; V4 production remains `.linear64`; log/shadow-dense layouts are diagnostic-only | Synthetic A–G distributions, p50 separability, quantization and perturbation measurements | PASS |
| Temporal/histogram attribution | 16-linear/frame-based to 64-linear/timestamp-based changes were bundled in prior history | A V4 output delta could not be attributed to one behavior | Added deterministic old/new temporal × old/new histogram reference matrix | Static, ramp, cut, and VFR scalar output sequences | PASS |
| Paused seek | Generation gate rejected late callbacks, but AVFoundation redraw behavior had no deterministic orchestration seam | A successful paused seek could leave the old frame displayed | Added one-shot `PlaybackSeekRedrawCoordinator` and connected it to seek completion and output flush | Latest seek, late completion, failed seek, duplicate callback, resume behavior | PASS |
| EDR presentation safety | Headroom smoothing was already asymmetric | A caller could still pass a stale smoother value between capability updates | Added final call-site clamp to current usable display capability | 4→1.5, potential mismatch, NaN, SDR fallback | PASS |
| Media verification | Fast verification required external K-Choreo files | The blocker was not isolated from self-contained plumbing checks | Added deterministic tiny synthetic MP4 generator and `self-contained` verification mode | `RUN_MACOS_VERIFY.sh self-contained` | PASS |

## Adaptive transaction invariant

`HDRAdaptiveStateStore` now owns one value-semantic `HDRAdaptiveState` behind
one lock. A GPU completion is evaluated against a copied candidate. The
candidate is published only after all required sequence transitions and the
common generation check succeed.

For scene-relative revisions, every accepted automatic commit satisfies:

```text
candidate.generation == completion.generation
candidate.temporal.sequence == completion.sequence
candidate.scene.sequence == completion.sequence
candidate.committedSequence == completion.sequence
candidate.lastAdaptiveCommittedSequence == completion.sequence
```

For revisions without scene-relative state, the scene sequence is not a
required component; temporal sequence, `committedSequence`, and
`lastAdaptiveCommittedSequence` still agree. A rejected transaction returns a
snapshot of the previously published state and never assigns the candidate.

GPU completion is intentionally separate bookkeeping:

```text
lastGPUCompletedSequence = highest current-generation completed command
lastAdaptiveCommittedSequence = highest current-generation accepted causal update
```

Therefore an out-of-order or rejected completion can advance the GPU ledger
without changing adaptive state. Completion traces are emitted only for an
accepted adaptive update and include generation, GPU completion sequence, and
adaptive committed sequence.

## Histogram strategy decision

The production strategy is explicit and unchanged from the current runtime:

```text
HDRSceneHistogramStrategy.production = .linear64
HDRConfiguration.calibratedV4.sceneHistogramStrategy = .linear64
```

`.linear16`, `.log64`, and `.shadowDense64` are available for offline and
diagnostic comparisons. The Metal estimator receives the selected strategy as
an explicit parameter; V4 production arithmetic and its 64-bin linear behavior
are unchanged by this pass.

The synthetic diagnostic used seven distributions: near-black, deep shadow,
shadow, lifted shadow, dark-mid, mixed, and dark-plus-highlight bimodal. The
first five representative p50 estimates were:

| distribution | linear16 | linear64 | log64 | shadowDense64 |
|---|---:|---:|---:|---:|
| 0.001 | 0.031250 | 0.007813 | 0.001065 | 0.001953 |
| 0.005 | 0.031250 | 0.007813 | 0.005066 | 0.005859 |
| 0.010 | 0.031250 | 0.007813 | 0.010132 | 0.009766 |
| 0.025 | 0.031250 | 0.023438 | 0.024097 | 0.025391 |
| 0.050 | 0.031250 | 0.054688 | 0.048194 | 0.048828 |

Linear64 still collapses the 0.001 and 0.005 scenes into the same p50 bin.
Log64 and shadowDense64 separate them. This is recorded as a candidate
estimator finding, not as a production behavior change.

## Output delta attribution

The diagnostic matrix compares:

```text
A old temporal + linear16 histogram
B timestamp temporal + linear16 histogram
C old temporal + linear64 histogram
D timestamp temporal + linear64 histogram
```

The rows below report mean absolute normalized BT.2020 luminance deltas from
the A baseline. They are deterministic CPU/reference diagnostics, not real
media measurements.

| sequence | temporal-only B-A | histogram-only C-A | combined D-A | interaction |
|---|---:|---:|---:|---:|
| static-gray | 0.000000 | 0.018398 | 0.018398 | 0.000000 |
| near-black-ramp | 0.000000 | 0.001068 | 0.001068 | 0.000000 |
| static-gray-ramp | 0.000000 | 0.003069 | 0.003069 | 0.000000 |
| alternating-dark-bright | 0.000000 | 0.000821 | 0.000821 | 0.000000 |
| slow-luminance-ramp | 0.000000 | 0.004725 | 0.004725 | 0.000000 |
| abrupt-scene-cut | 0.000000 | 0.005913 | 0.005913 | 0.000000 |
| vfr-ramp | 0.002310 | 0.004549 | 0.006854 | 0.000005 |

The current production endpoint is D. This pass does not alter that endpoint;
it makes the separate contributions reproducible and testable. The VFR row
shows why timestamp behavior needs its own attribution axis even when fixed
rate sequences are identical.

## Paused seek and geometry

`PlaybackSeekRedrawCoordinator` gives each seek a generation token, keeps only
the newest pending request, and returns one redraw action for one successful
current completion. The action requests media-data notification and redraw;
playback resumes only when the seek began while playing. Failed, duplicate, or
late completions return no action. Output flush invalidates the pending token.

The existing affine resolver was reaudited across rotation and reflection
bases. Equivalent affine matrices are reported through a canonical orientation
decomposition because their linear components are identical when translation
is ignored.

## EDR safety and metadata

`EDRHeadroomSmoother` still clamps decreases immediately and smooths only
increases. `EDRHeadroomSafety.clampPresentationHeadroom` now applies a final
cap at the actual current usable display state immediately before every
production presentation encode. This ensures the value passed to the
presentation shader cannot exceed current or potential capability after a
screen migration or brightness drop.

The preset audit found the shared `HDRPresetResolver.productionDefault` and
the existing `effectivePeakNits`/`effectiveOutputHeadroom` semantics in use.
The calibrated V4 preset remains the production default and its calibration
values are unchanged.

## Real-media validation

The standard command was executed:

```text
FORCE_VERIFY=1 ./RUN_MACOS_VERIFY.sh fast
```

It stopped in the dataset audit because the external K-Choreo SDR file is not
present. No Frozen or Virgin Frozen media was opened and no objective was run.

A self-contained path was added and executed successfully:

```text
./RUN_MACOS_VERIFY.sh self-contained
```

It generated a temporary 64×36, one-second, 24 fps synthetic H.264 MP4,
validated it with `ffprobe`, and ran the debug test suite. The fixture is
created in a temporary directory and is not committed.

## Frozen isolation

```text
Virgin Frozen accessed: NO
Objective evaluations: 0
Frozen holdout workflow: NOT RUN
```

Tests that validate fail-closed Frozen policy use synthetic metadata and do not
open holdout media.

## Tests and verification

The final verification run completed with 218 tests, 5 skipped, and 0
failures in both Debug and Release. The self-contained verification also
completed with 218 tests, 5 skipped, and 0 failures.

```text
swift test -c debug --disable-index-store: PASS (218 executed, 5 skipped)
swift test -c release --disable-index-store: PASS (218 executed, 5 skipped)
swift build -c release: PASS
bash Tests/verify_script_cache_test.sh: PASS
git diff --check: PASS
./RUN_MACOS_VERIFY.sh self-contained: PASS
```

## New issues

1. **P2 — external real-media fixture unavailable.** The standard fast path
   still cannot perform dataset audit without the user-provided K-Choreo files.
   The self-contained path now isolates AVFoundation/media plumbing from that
   dependency.
2. **P2 — candidate histogram layouts lack real-media evidence in this
   environment.** Log64 and shadowDense64 are diagnostic-only until Tune and
   Validation media are available.
3. **P2 — no real AVPlayer end-to-end media fixture is present.** The paused
   seek coordinator is covered deterministically; the external AVPlayerItem
   pipeline still needs a legal small fixture in a future media-enabled gate.

## Remaining technical debt

- 10-bit SDR/P010 input remains a separate implementation project.
- Proper 4:2:0 chroma reconstruction and chroma-siting metadata remain open.
- Real-media CI still needs a legal, reproducible dataset contract.
- Frozen family × transfer cross-design remains protected and was not expanded.

## Git

The implementation commit is `240520f` (`fix(hdr): harden runtime
correctness invariants`). This report is committed separately so the code and
verification record remain independently reviewable. Unrelated pre-existing
files, if any, remain untouched.
