# V6.2 Scene-Adaptive Expansion Report

## 1. Input Findings

V6.2 starts from the production-based V6.1 result. The production reference is
`d97c3d3c8fbf71447ff8b94a7fa7a77c5d25bebf`, and the default production preset
remains `calibrated-v4`. V4 versus V2 still shows a generic diffuse-midtone
difference, but V6.1 established that a single global low-mid reduction or a
global band limit does not generalize:

- V6.1 primary classification: `GLOBAL_CURVE_LIMITATION`.
- V6.1 secondary classification: `METRIC_MISMATCH`.
- The previous BL045 Validation delta was `+0.023884086`.
- Its `diffuse_white` and `highlight` components accounted for approximately
  75.8% of that increase.
- A test6.mp4 file is unavailable in this worktree. Face-specific attribution
  therefore remains unconfirmed.

This stage evaluates whether a bounded scene-adaptive *budget* can predict the
amount of the existing V4 low-mid term from causal SDR statistics. It does not
create a V6.2 production preset and does not change any V4 calibration value.

## 2. HLG/PQ Confounding Analysis

The analysis used eight local, non-protected paired records and 41 scenes from
`data_video/visual-regression/v6-development-manifest.json`. Only Tune and
Validation records were prepared. HLG and PQ are retained as offline
stratification labels; neither label is present in the runtime controller.

The transfer groups are strongly imbalanced: all HLG records are K-Choreo and
all PQ records are LIVE. The observable feature means show the same separation:

| Split | Reference label | Scenes | P50 | P90 | P99 | Dynamic stops | Highlight occupancy | Midtone occupancy | Near-black occupancy | Shadow top |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Tune | HLG | 30 | 0.3667 | 0.5875 | 0.7896 | 1.4628 | 0.4350 | 0.2808 | 0.2500 | 0.2150 |
| Tune | PQ | 2 | 0.1250 | 0.6250 | 0.9375 | 3.3867 | 0.7563 | 0.5002 | 0.3750 | 0.0563 |
| Validation | HLG | 7 | 0.2813 | 0.6205 | 0.7902 | 1.7036 | 0.4051 | 0.4415 | 0.3214 | 0.1348 |
| Validation | PQ | 2 | 0.0938 | 0.5000 | 0.8125 | 3.3917 | 0.7086 | 0.4117 | 0.3750 | 0.0563 |

An offline leave-one-out nearest-observable-feature diagnostic predicts the
reference label with accuracy `0.902439`. This is evidence that the current
dataset family composition can expose the transfer label through SDR content.
It is not evidence that a runtime transfer classifier is valid. Twelve nearest
cross-label scene comparisons also contain large demand differences, often
`bestScale 0` versus `bestScale 1`, but no exact same-content HLG/PQ pair exists.
The current data cannot separate transfer-family effect from scene-family
confounding. `HLG expansion required / PQ expansion reduced` is therefore not a
runtime design rule.

## 3. Runtime Feature Analysis

`HDRV62SceneFeatures` in
`Sources/HDRCore/HDRV62SceneAdaptiveExpansion.swift:103` uses only causal SDR
statistics: P01, P05, P50, P90, P99, scene shadow anchors, highlight
occupancy, near-black occupancy, midtone occupancy, and a log dynamic-range
proxy. The offline runner uses the same 16x9 production estimator grid, rather
than the denser evaluation grid. Runtime percentile state is causally smoothed
with the existing temporal stability state in `HDRProcessor`; no look-ahead is
used. No transfer label, HDR reference, category, scene ID, family, face, or
skin feature enters the controller.

Correlations below are with the offline `bestScale` demand target, not with the
HLG/PQ label. Values are Pearson / Spearman:

| Feature | Tune | Validation |
|---|---:|---:|
| P50 | -0.306 / -0.355 | +0.009 / +0.097 |
| P90 | -0.467 / -0.503 | +0.583 / +0.093 |
| P99 | -0.419 / -0.555 | +0.507 / +0.239 |
| Highlight occupancy | +0.119 / +0.297 | +0.143 / +0.138 |
| Dynamic-range stops | +0.089 / +0.330 | -0.477 / -0.093 |
| Midtone occupancy | +0.182 / +0.368 | +0.715 / +0.710 |
| Shadow top | -0.348 / -0.352 | -0.243 / -0.344 |

The sign and rank of the feature relationships change between Tune and
Validation. Validation contains only nine scenes, and the two PQ scenes are a
different content family from the HLG scenes. No single feature has stable
out-of-sample evidence sufficient to justify a new global controller.

## 4. Expansion Demand Target

Demand was constructed with the offline coefficient scale sweep

`[0, 0.125, 0.25, 0.375, 0.50, 0.625, 0.75, 0.875, 1.0]`.

Scale `1.0` is the V4 low-mid term, and scale `0.0` is the no-low-mid ablation.
The V4 coefficient remains `0.08` throughout this analysis. Each scene stores
the best scale, second-best scale, objective gap, local curvature, acceptable
interval, and a reliability weight. Flat surfaces receive lower weight.

| Split | Scenes | Best-scale distribution | Mean best scale | Mean reliability |
|---|---:|---|---:|---:|
| Tune | 32 | 0:1, 0.375:1, 0.50:1, 0.625:3, 0.75:2, 1:24 | 0.9063 | 0.8604 |
| Validation | 9 | 0:1, 0.625:1, 1:7 | 0.9444 | 0.8152 |

The aggregate hides the transfer/family imbalance. Tune HLG has mean best scale
`0.9292` and mean reliability `0.9151`; Tune PQ has mean best scale `0.1875`
and mean reliability only `0.0396`. Validation HLG has mean best scale
`0.9464`; Validation PQ has mean best scale `0.5000`.

Representative surfaces show why the best-scale label must be weighted. The
Tune PQ interview scene has best scale `0.375`, but its objective gap is only
`0.0000454` and reliability is approximately `0.0053`; its surface is
effectively flat. Validation PQ programming night has best scale `0` with gap
`0.0079991`, while Validation PQ campfire has best scale `1` with gap
`0.0022409`. HLG scenes such as `video1` scene 0021 prefer an interior scale
near `0.75`. The demand direction is therefore scene dependent even within the
same reference label.

## 5. Demand Surface Reliability

Reliability is derived from the separation and curvature of the sampled
objective surface. It is used for fitting weights and is not a runtime input.
The low reliability of the two Tune PQ scenes prevents them from being treated
as reliable labels for a controller. The Validation surface is useful for
diagnosis, but it is too small to support repeated threshold tuning.

The result is not a stable monotone mapping from one SDR statistic to demand.
The adaptive experiment therefore has a useful negative result: the current
paired set does not support adding a more complex learned controller.

## 6. Feature Correlations

The feature evidence supports the hypotheses only conditionally:

- Highlight occupancy is weakly positive in both splits and does not predict
  the opposing scene responses with useful strength.
- Dynamic range is weakly positive on Tune and negative on Validation.
- Midtone occupancy has the strongest Validation Pearson/Spearman values, but
  its Tune relationship is weaker and points in a different fitted context.
- Lower shadow anchors correlate with larger demand in both splits, but this is
  coupled to scene family and does not establish that the anchor itself should
  be changed.

These are diagnostic correlations. They do not justify a controller keyed to
HLG/PQ or to any content category.

## 7. Candidate Controllers

The comparison set was:

| Candidate | Runtime rule |
|---|---|
| `V4_BASELINE` | Existing V4 scene-relative curve, unchanged |
| `V6_NO_LOWMID` | Offline reference ablation with low-mid contribution set to zero |
| `V6_BL045` | Offline reference candidate from V6 structural search |
| `V6.2_ADAPTIVE_A` | Highlight occupancy demand, minimum budget 0.65, Tune-fitted range `[0, 0.45]` |
| `V6.2_ADAPTIVE_B` | Dynamic-range demand, minimum budget 0.65, Tune-fitted range `[0.25, 1.5]` stops |
| `V6.2_ADAPTIVE_C` | Compact combination, minimum budget 0.65, weights `0.50 / 0.30 / 0.20` for highlight/range/midtone |

The runtime formula is `effectiveLowMid = V4LowMid * expansionBudget`.
The V4 low-mid coefficient stays `0.08`; the shoulder formula, contrast, and
highlight strength remain unchanged. The bounded budget math is in
`Sources/HDRCore/HDRV62SceneAdaptiveExpansion.swift:186`, and the V6.2 curve
path is a separate revision at `HDRToneCurveRevision.sceneAdaptiveV62Candidate`
(`Sources/HDRCore/HDRConfiguration.swift:36`).

## 8. Tune Results

Controller parameters were fitted on Tune demand surfaces only. The following
Tune results are in the existing objective/diagnostic metric units:

| Candidate | Objective | Diffuse signed | Positive overshoot | Negative undershoot | Highlight | Shadow |
|---|---:|---:|---:|---:|---:|---:|
| V4 baseline | 0.277592 | 0.134015 | 0.140821 | 0.254009 | 0.209274 | 0.645764 |
| No low-mid | 0.307407 | 0.057845 | 0.071716 | 0.331339 | 0.262508 | 0.667029 |
| BL045 | 0.304816 | 0.115932 | 0.126958 | 0.259532 | 0.259245 | 0.663494 |
| Adaptive A | 0.277539 | 0.134015 | 0.140815 | 0.257313 | 0.207501 | 0.649447 |
| Adaptive B | 0.277156 | 0.134015 | 0.140819 | 0.259519 | 0.206757 | 0.651366 |
| Adaptive C | 0.279518 | 0.127623 | 0.134802 | 0.263287 | 0.210791 | 0.649152 |

Tune fitting produces small gains for A and B, but it does not resolve the
scene-family conflict. Tune results were frozen as a parameter checkpoint
before any Validation result was used.

## 9. Parameter Freeze

The fitted parameters held fixed for the single Validation evaluation were:

- Adaptive A: minimum budget `0.65`, highlight thresholds `0.00 / 0.45`.
- Adaptive B: minimum budget `0.65`, dynamic-range thresholds `0.25 / 1.50`.
- Adaptive C: minimum budget `0.65`, weights `0.50 / 0.30 / 0.20`.

This is a development parameter freeze. It is unrelated to Frozen media or the
sealed holdout; no protected evaluation was opened.

## 10. Validation Results

| Candidate | Objective | Delta vs V4 | Diffuse signed | Positive overshoot | Negative undershoot | Diffuse MAE | Highlight | Shadow |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| V4 baseline | 0.401963080 | 0 | 0.141264 | 0.171791 | 0.149715 | 0.321506 | 0.263989 | 0.895009 |
| No low-mid | 0.409735875 | +0.007772795 | 0.031918 | 0.069630 | 0.231006 | 0.300636 | 0.268440 | 0.898683 |
| BL045 | 0.426598581 | +0.024635501 | 0.117319 | 0.160011 | 0.170849 | 0.330861 | 0.307136 | 0.898632 |
| Adaptive A | 0.401984743 | +0.000021663 | 0.141264 | 0.171790 | 0.150855 | 0.322646 | 0.263248 | 0.896298 |
| Adaptive B | 0.401837741 | -0.000125339 | 0.141264 | 0.171791 | 0.150478 | 0.322269 | 0.263006 | 0.896299 |
| Adaptive C | 0.405076838 | +0.003113758 | 0.135234 | 0.167561 | 0.158867 | 0.326428 | 0.269622 | 0.896016 |

Adaptive B has a very small total objective improvement, but its positive
diffuse overshoot is unchanged at the reported precision. It fails the gate
requiring directional improvement. Adaptive A slightly lowers positive
overshoot but has a worse total objective. Adaptive C lowers positive
overshoot while increasing other error terms. No adaptive candidate passes all
gates.

## 11. Directional Diffuse Error

Directional metrics were added next to the existing absolute objective. The
generic source-linear interval is `0.15 <= Y <= 0.45`; it is chosen to cover
ordinary diffuse signal above the deep-shadow region and below the V4 shoulder,
not to represent skin or any other semantic class. The metric is excluded from
the weighted production objective and is reported as a companion diagnostic.

On Validation, V4 has positive overshoot `0.171791` and negative undershoot
`0.149715`. No-low-mid reduces positive overshoot to `0.069630`, but increases
negative undershoot to `0.231006`; this is a direction trade, not a clear
improvement. BL045 leaves positive overshoot at `0.160011` and increases total
diffuse MAE to `0.330861`. A and B leave the positive term effectively at the
V4 value. C reduces it to `0.167561` while increasing negative undershoot to
`0.158867`.

The signed companion keeps the sign, while positive/negative terms retain the
two directions and MAE retains the magnitude. This avoids treating a bright
error and a dark error as the same failure. V2 remains a comparison baseline;
it is never used as the HDR target.

## 12. Highlight / Diffuse-White

For the current production-grid replay, BL045 raises the Validation
`diffuse_white` component by `+0.010257512` and `highlight` by `+0.007766464`.
Together they are `73.1%` of its `+0.024635501` replay delta. The earlier V6.1
official evaluation reported `+0.009902309` and `+0.008196860`, respectively,
and `+0.023884086` total. The small numeric difference is retained as a
methodology difference between the earlier evaluator and this production-grid
spatial diagnostic; both runs agree on the failure and on the two dominant
components.

Adaptive A lowers diffuse-white by `0.000077477` and highlight by `0.000133451`
but loses on total objective by `0.000021663`. Adaptive B lowers them by
`0.000120565` and `0.000177002`, producing the small total improvement, but
does not lower directional positive diffuse error. C raises both by
`0.001219776` and `0.001013939`.

## 13. PQ / HLG Stratification

Validation transfer strata from the same offline run are:

| Candidate | HLG objective | HLG positive / negative diffuse | HLG highlight | PQ objective | PQ positive / negative diffuse | PQ highlight |
|---|---:|---:|---:|---:|---:|---:|
| V4 baseline | 0.254798 | 0.001096 / 0.358661 | 0.280631 | 0.475546 | 0.257139 / 0.045243 | 0.255669 |
| No low-mid | 0.324591 | 0.000881 / 0.528326 | 0.389573 | 0.452308 | 0.104004 / 0.082347 | 0.207874 |
| BL045 | 0.303365 | 0.001095 / 0.385567 | 0.389555 | 0.488215 | 0.239469 / 0.063490 | 0.265927 |
| Adaptive A | 0.254863 | 0.001094 / 0.362080 | 0.278407 | 0.475546 | 0.257139 / 0.045243 | 0.255669 |
| Adaptive B | 0.254422 | 0.001096 / 0.360950 | 0.277681 | 0.475546 | 0.257139 / 0.045243 | 0.255669 |
| Adaptive C | 0.262391 | 0.001025 / 0.380645 | 0.291799 | 0.476420 | 0.250829 / 0.047978 | 0.258534 |

V4 is strong on the HLG/K-Choreo group because those scenes mostly demand a
large low-mid budget. The PQ/LIVE group contains scenes where reducing the term
helps, but the adaptive controllers do not generalize that distinction: A and
B are effectively V4 on the two PQ Validation scenes, and C is slightly worse.
Because the runtime features nearly reveal the family label, this result is
consistent with reference-family confounding rather than evidence for a
transfer-aware production algorithm.

## 14. Family Robustness

The family diagnostic fits demand on the other family and evaluates the held
out family. Runtime still receives no family label.

| Candidate | K-Choreo Validation objective | LIVE Validation objective | Demand RMSE K-Choreo | Demand RMSE LIVE |
|---|---:|---:|---:|---:|
| V4 baseline | 0.254798 | 0.475546 | n/a | n/a |
| Adaptive A | 0.254863 | 0.475546 | 0.6026 | 0.7071 |
| Adaptive B | 0.254422 | 0.475546 | 0.9555 | 0.7071 |
| Adaptive C | 0.262391 | 0.476420 | 0.5058 | 0.7094 |

There are only two LIVE Validation scenes, so this leave-family result is a
warning rather than a promotion gate. It does show that the apparent small
aggregate gains do not form a reliable family-independent demand predictor.

## 15. Temporal Stability

The adaptive budget consumes the previous completed causal percentile state.
The runtime state update uses `HDRSceneStatistics.causalBlend` and the existing
temporal stability value; it does not read future frames. The measured budget
sequence diagnostics over 41 sparse scenes were:

| Candidate | Mean frame delta | P95 frame delta | Maximum delta | Scene-cut recovery measured |
|---|---:|---:|---:|---|
| Adaptive A | 0.02191 | 0.08943 | 0.35000 | No |
| Adaptive B | 0.01547 | 0.01607 | 0.35000 | No |
| Adaptive C | 0.029998 | 0.13515 | 0.28000 | No |

The maximum includes startup invalid-to-valid state and sparse scene transitions.
No actual scene-cut recovery window was available in this sparse diagnostic, so
these numbers cannot certify flicker-free cut recovery. Candidate C has the
largest continuous-sequence risk. Existing Validation temporal flicker is
`0.045159` for V4, `0.045167` for A, `0.045165` for B, and `0.045287` for C;
no change to `temporalStability` was made.

## 16. Performance

Current release binary, Apple M2, 1920x1080, EDR, 30 warmup frames and 300
measured frames, three sequential runs per preset. Values are medians of the
three run-level percentiles:

| Preset | GPU p50 | GPU p95 | p95 vs V4 | CPU submission p50 | CPU submission p95 |
|---|---:|---:|---:|---:|---:|
| Normal V4 | 0.410 ms | 0.419 ms | baseline | 0.011 ms | 0.038 ms |
| Adaptive A | 0.417 ms | 0.429 ms | +2.4% | 0.012 ms | 0.038 ms |
| Adaptive B | 0.429 ms | 0.443 ms | +5.7% | 0.026 ms | 0.039 ms |
| Adaptive C | 0.432 ms | 0.497 ms | +18.6% | 0.029 ms | 0.039 ms |

All measured paths remain far below a 16.7 ms 60 fps frame budget. A is within
the requested `<=5%` GPU p95 target. B is just above it in this three-run
sample, and C fails it. The benchmark waits for completion to measure GPU time;
that synchronization is benchmark-only and was not introduced into the
realtime player path. Production default remains V4 with diagnostics and
controlled A/B disabled.

## 17. Why BL045 Failed

BL045 applies the same band-limited reduction to every scene. The demand data
shows that most HLG scenes prefer scale `1.0` or a nearby high scale, so BL045
removes energy where the paired reference expects the V4 lift. On the other
side, the PQ scenes contain cases preferring scale `0` and cases preferring
scale `1`; a global band cannot satisfy both.

The objective decomposition confirms the consequence rather than merely
describing BL045 as visually worse. In the earlier official V6.1 result,
`diffuse_white +0.009902309` and `highlight +0.008196860` were the two dominant
positive terms. The current production-grid replay reproduces the same pattern
at `+0.010257512` and `+0.007766464`. The band limit therefore removes useful
diffuse-white and highlight energy in high-demand scenes while not providing a
stable correction for low-demand scenes.

## 18. Candidate Verdict

**`GLOBAL_V4_STILL_BEST`**

No adaptive candidate satisfies the complete gate:

- Adaptive A has a slightly worse total Validation objective.
- Adaptive B improves total objective by only `0.000125339`, but its positive
  diffuse overshoot is unchanged.
- Adaptive C worsens total objective by `0.003113758` and has the largest
  performance overhead.
- No candidate establishes robust leave-family generalization.

The analysis also records `REFERENCE_FAMILY_CONFOUNDING` as a secondary data
risk and retains `METRIC_MISMATCH` as the reason directional signed metrics are
needed. The result does not justify a more complex model, a transfer label
branch, or another global tone curve search.

## 19. Face-Specific Status

`test6.mp4` is unavailable. Face-specific attribution is **NOT CONFIRMED**.
The manifest's category tags are metadata for analysis only and were not used
as runtime features or masks. No face detector, skin detector, skin LUT, or
skin-specific heuristic was added.

## 20. Protected Holdout Status

- Frozen accessed: **NO**.
- Virgin Frozen accessed: **NO**.
- Holdout objective evaluations: **0**.
- Protected media access: `false`.
- Prepared records: 8; skipped records: 0; scenes: 41.

The analysis JSON was written to `/tmp/v6.2-scene-adaptive-final.json` and is a
development diagnostic artifact, not a production result or a protected
evaluation artifact.

## 21. Recommended Next Step

Keep V4 as the production and default runtime. Before implementing V6.3 or a
new V6.2 family, obtain a transfer-balanced paired development set with the
same content families represented in both reference transfers, and obtain
test6.mp4 for the requested human-selected generic face and matched non-skin
ROI measurements. Then run a sequential evaluator with actual scene cuts and
the production causal estimator so anchor and budget transitions are measured
on real frame timing.

The next mathematical question is whether a low-dimensional observable budget
can generalize after that balancing. No V6.2 candidate is promoted here, no
`calibratedV6` preset is created, and no production arithmetic is changed.

## 22. Tests

- `swift build -c debug --disable-index-store`: PASS.
- `swift build -c release --disable-index-store`: PASS.
- `swift test -c debug --disable-index-store`: PASS, 198 tests executed, 5
  environment-dependent tests skipped, 0 failures.
- V6.2 targeted tests: PASS, 10 tests, including V4 endpoint, zero-budget
  endpoint, bounded/finite budget, causal smoothing, and Metal↔CPU parity.
- `git diff --check`: PASS.
- V6.2 runner: PASS, 8 allowed records, 41 scenes, 6 candidates, 0 protected
  objective evaluations.
- `RUN_MACOS_VERIFY.sh fast`: not run because this repository's verify workflow
  writes or evaluates protected Frozen/holdout artifacts; this stage is
  explicitly holdout-protected.

The added tests also cover deterministic runtime features, budget bounds,
causal behavior, no transfer-label dependency, parameter freeze, directional
metric signs, bin boundaries, aggregation consistency, V4 production values,
and CPU/reference parity.

## 23. Git State

The worktree contains the pre-existing V4.1/V6 diagnostic changes and unrelated
dirty files. They were preserved in place; no reset, clean, stash, or destructive
checkout was used. The V6.2 report and diagnostic source/test changes remain
uncommitted so their ownership can be reviewed before any checkpoint commit.

Current branch: `v6-tone-curve-development`.

Production commit used by the implementation and runner:
`d97c3d3c8fbf71447ff8b94a7fa7a77c5d25bebf`.
