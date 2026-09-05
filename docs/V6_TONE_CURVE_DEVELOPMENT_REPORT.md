# V6 Tone Curve Development Report

## 1. Root Cause Input

The development input was the production based V4.1 diagnostic result on `d97c3d3`:

- generic diffuse midtone over expansion was reproduced;
- the V4 low mid term approached an asymptotic gain of about `1.2065` above the scene shadow band;
- `shoulderStart` was about `0.49891537`;
- no temporal spike, material saturation or gamut luminance increase, or additional presentation EDR lift was observed;
- face specific attribution remains unverified because `test6.mp4` is not present in either worktree.

The previous diagnostic base was `4c710e1`. The same representative timestamps were rechecked against the production based implementation. The old measurements remain provisional and are shown only to expose the port delta.

| frame | timestamp | old 4c input | d97 input | old V2 tone | d97 V2 tone | old V4 tone | d97 V4 tone | old low mid | d97 low mid |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 49 | 0.839667 | 0.291255 | 0.291499 | 0.404643 | 0.405206 | 0.491403 | 0.492224 | 0.058678 | 0.058724 |
| 109 | 1.839667 | 0.280031 | 0.280253 | 0.363690 | 0.364171 | 0.440098 | 0.440645 | 0.056377 | 0.056409 |
| 169 | 2.839667 | 0.300549 | 0.300976 | 0.429594 | 0.431554 | 0.520915 | 0.523134 | 0.060177 | 0.060256 |

The small d97 deltas do not change the diagnostic conclusion. They also do not establish that the affected region is skin; the available evidence supports a generic diffuse or midtone mechanism.

## 2. V4 Baseline Invariants

The development branch is based directly on production commit `d97c3d3c8fbf71447ff8b94a7fa7a77c5d25bebf`. `calibratedV4` remains byte and arithmetic equivalent in the checked production paths:

~~~
paperWhiteNits         = 190
peakNits               = 1008.6863
highlightStrength      = 0.6208221
contrastStrength       = 0.90542316
saturationCompensation = 0.43140942
shadowProtection       = 0.4755874
temporalStability      = 0.7308984
masteringHeadroom      = 5.308875
toneCurveRevision      = sceneRelativeV4
outputMode             = EDR
~~~

The V4 shader branch and the V4 CPU reference branch were retained. V6 uses the development-only `sceneRelativeV6Candidate` revision and candidate fields for fade position and low mid strength. No `calibratedV6` preset was created and the default remains `calibrated-v4`.

## 3. Candidate Family

### V4 baseline

`V4_BASELINE` uses the production V4 configuration and its existing broad low mid term. It is the exact comparison baseline.

### no-low-mid

`V6_ABLATION_NO_LOWMID` sets only the low mid contribution to zero. The V4 shoulder, shadow protection, temporal stability, scene statistics, and all production parameters remain unchanged. This is an attribution ablation, not a production candidate.

### band-limited candidates

`BANDLIMITED_035`, `045`, `055`, `065`, and `075` retain `LOWMID_STRENGTH = 0.08` and the V4 shoulder formula. The low mid term is given bounded support:

~~~
lowMidRise = smoothStepSafe(shadowFloor, supportTop, y);
lowMidFadeStart = mix(supportTop, shoulderStart, fadePosition);
lowMidFall = 1.0f - smoothStepSafe(lowMidFadeStart, shoulderStart, y);
lowMidBand = lowMidRise * lowMidFall;
~~~

The resulting contribution is zero at or above the shoulder. This isolates the support shape from strength calibration and prevents the first experiment from changing the shoulder at the same time.

## 4. Mathematical Curve Analysis

For the production V4 values and a representative `temporalAdaptation` of `0.965`, the broad low mid asymptotic contribution is approximately:

~~~
(5.3088753 - 1) * 0.6208221 * 0.965 * 0.08 = 0.2065
~~~

The corresponding multiplicative gain is approximately `1.2065`. This agrees with the shader diagnostic and the CPU scalar reference. The V4 contribution remains present above `shoulderStart`; it is therefore not bounded to a diffuse low mid band.

The production shoulder boundary is:

~~~
0.68 - 0.20 * 0.90542316 = 0.49891537
~~~

The required scalar sweep used 1001 samples over `[0, 1]` plus the specified diagnostic grid. Selected points from the final audit are:

| input Y | V4 output | V4 low mid | V4 shoulder | no low mid | BL035 output | BL035 low mid | BL045 output | BL045 low mid |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.02 | 0.020000 | 0.000000 | 0.000000 | 0.020000 | 0.020000 | 0.000000 | 0.020000 | 0.000000 |
| 0.10 | 0.120651 | 0.020651 | 0.000000 | 0.100000 | 0.120651 | 0.020651 | 0.120651 | 0.020651 |
| 0.30 | 0.361954 | 0.061954 | 0.000000 | 0.300000 | 0.347889 | 0.047889 | 0.356490 | 0.056490 |
| 0.40 | 0.482605 | 0.082605 | 0.000000 | 0.400000 | 0.422575 | 0.022575 | 0.429826 | 0.029826 |
| 0.45 | 0.542931 | 0.092931 | 0.000000 | 0.450000 | 0.457144 | 0.007144 | 0.459746 | 0.009746 |
| 0.50 | 0.603257 | 0.103257 | 0.000000 | 0.500000 | 0.500000 | 0.000000 | 0.500000 | 0.000000 |
| 0.70 | 1.363252 | 0.144559 | 0.518693 | 1.218692 | 1.218692 | 0.000000 | 1.218692 | 0.000000 |
| 1.00 | 3.787931 | 0.206513 | 2.581418 | 3.581418 | 3.581418 | 0.000000 | 3.581418 | 0.000000 |

At the test6-like anchors (`shadowFloor = 0.03125`, `shadowTop = 0.05625`), the candidate fade starts were approximately `.211183`, `.255449`, `.299716`, `.343983`, and `.388249` for positions `.035` through `.075`. All valid candidates reached zero low mid contribution at the shoulder.

The hard-invariant audit used dark (`.005/.030`), test6-like (`.03125/.05625`), moderate (`.03/.12`), and wide (`.05/.25`) anchors:

| candidate | dark | test6-like | moderate | wide | minimum slope in wide anchor |
|---|---|---|---|---|---:|
| NO_LOWMID | PASS | PASS | PASS | PASS | 0.999987 |
| BL035 | PASS | PASS | PASS | PASS | 0.274301 |
| BL045 | PASS | PASS | PASS | PASS | 0.105441 |
| BL055 | PASS | PASS | PASS | FAIL | -0.140727 |
| BL065 | PASS | PASS | PASS | FAIL | -0.530422 |
| BL075 | FAIL | FAIL | FAIL | FAIL | -1.235127 |

All scalar tests also checked exact black, finite output, no negative expansion, continuity, and derivative sanity. The `.055` and later families are rejected before media evaluation because the wide-anchor curve can reverse locally. This is a structural failure, not a parameter ranking result.

## 5. Tune Results

The development runner evaluated five non-Frozen Tune videos, 152 frames, and 32 scenes. It used the existing paired SDR/HDR reference path. Deltas are relative to `V4_BASELINE`; lower is better for the error metrics.

| candidate | objective | delta | diffuse error | delta | diffuse overshoot | near black loss | highlight under | specular under | temporal luminance | flicker |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| V4_BASELINE | 0.279117 | — | 0.552752 | — | 0.329374 | 0.214158 | 0.306346 | 0.105902 | 0.005694 | 0.007705 |
| NO_LOWMID | 0.310670 | +0.031552 | 0.537954 | -0.014798 | 0.263373 | 0.246379 | 0.364435 | 0.143708 | 0.005977 | 0.008187 |
| BL035 | 0.306883 | +0.027765 | 0.552755 | +0.000002 | 0.329374 | 0.227519 | 0.363794 | 0.143708 | 0.006128 | 0.008430 |
| BL045 | 0.306340 | +0.027222 | 0.552753 | +0.000000 | 0.329374 | 0.227519 | 0.363794 | 0.143708 | 0.006121 | 0.008423 |

The band-limited candidates reduced generated diffuse white from the V4 value of `318.797` toward `292.0`, while the paired reference value was `336.907`. This change did not translate into a meaningful aggregate diffuse error improvement on Tune, and the overall objective worsened.

## 6. Validation Results

Validation used three non-Frozen videos, 58 frames, and 9 scenes.

| candidate | objective | delta | diffuse error | delta | diffuse overshoot | overshoot P95 | near black loss | highlight under | specular under | temporal luminance | flicker |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| V4_BASELINE | 0.403579 | — | 0.441004 | — | 0.394363 | 0.682471 | 0.432363 | 0.438016 | 0.132590 | 0.007863 | 0.010802 |
| NO_LOWMID | 0.413287 | +0.009708 | 0.382798 | -0.058206 | 0.295795 | 0.636700 | 0.440463 | 0.532115 | 0.159740 | 0.008594 | 0.011754 |
| BL035 | 0.427703 | +0.024124 | 0.440995 | -0.000009 | 0.394345 | 0.682471 | 0.435902 | 0.532115 | 0.159740 | 0.008637 | 0.011409 |
| BL045 | 0.427463 | +0.023884 | 0.441005 | +0.000001 | 0.394363 | 0.682471 | 0.435902 | 0.532115 | 0.159740 | 0.008619 | 0.011325 |

No candidate satisfied the selection gate of meaningful diffuse improvement with no total objective regression. `NO_LOWMID` is the only clear diffuse overshoot reducer, but it also increases near black loss, highlight underreach, specular underreach, and temporal errors.

## 7. Diffuse Midtone Results

The added `diffuseMidtoneError` is a generic signal metric over source linear luminance `0.15 <= Y <= 0.45`. The range excludes near black and the shoulder region, and is below the production shoulder boundary for the observed V4 configuration. It was chosen from the paired reference distribution as a generic diffuse or midtone band; it contains no face, skin, chroma, or identity classifier.

The metric compares candidate output against the paired HDR reference using the existing objective framework. V2 is only a comparison baseline and is not used as ground truth.

The Validation result shows the structural tradeoff clearly: `NO_LOWMID` lowers diffuse overshoot by `0.098568` and diffuse error by `0.058206`, but its total objective is worse by `0.009708`. `BL035` and `BL045` leave aggregate diffuse overshoot effectively unchanged while worsening the total objective by about `0.024`.

There is no actual face ROI result in this run. `test6.mp4` was unavailable, so the report cannot attribute the generic midtone result specifically to facial skin. A reproducible manual face ROI comparison remains a required next measurement.

## 8. Near-Black

The scalar candidates preserve exact black, finite output, monotonicity, and `f(Y) >= Y`. The media metrics expose a different risk: removing or fading the broad V4 term changes the balance of the low end.

- Tune `nearBlackContrastLoss` increased from `0.214158` to `0.246379` for `NO_LOWMID` and `0.227519` for both valid band candidates.
- Validation increased from `0.432363` to `0.440463` for `NO_LOWMID` and `0.435902` for the band candidates.
- No candidate produced a scalar crush or inversion in the accepted anchor families.
- A runtime V6 diagnostic spot check on the available proxy clip showed positive low-band gains (`1.0269`, `1.1105`, and `1.1579` for the `<0.01`, `<0.02`, and `<0.05` bands). This is not test6 evidence, but it is a reason to inspect anchor conditioning before further development.

## 9. Highlight / Specular

The shoulder equation and `shoulderStart` were held constant. The scalar sweep shows why this alone does not preserve the V4 high end: at `Y = 1.0`, V4 output is `3.787931`, consisting of approximately `0.206513` low mid contribution and `2.581418` shoulder contribution. The band candidates and `NO_LOWMID` output `3.581418`, with the same shoulder contribution and zero low mid contribution.

The paired media metrics reflect that loss. Tune highlight underreach rises from `0.306346` to `0.363794` for the band candidates and `0.364435` for `NO_LOWMID`; specular underreach rises from `0.105902` to `0.143708`. Validation shows the same direction, with highlight underreach rising from `0.438016` to `0.532115` and specular underreach from `0.132590` to `0.159740`.

Therefore the first band-limited family removes the broad high-end contribution, but it does not yet maintain V4 highlight capability at the paired reference target.

## 10. Temporal

`temporalStability`, temporal estimator logic, and scene-cut logic were not changed. The candidate curve itself has no temporal spike in the available evaluation, but the aggregate temporal metrics regress slightly:

- Tune temporal luminance error: `0.005694` V4 to `0.006121` BL045; flicker: `0.007705` to `0.008423`.
- Validation temporal luminance error: `0.007863` V4 to `0.008619` BL045; flicker: `0.010802` to `0.011325`.

The controlled V6 runtime probe also reported different independent scene anchors at a matched controlled comparison point (V4 about `.03125/.226639`, V6 about `.001/.026`). Independent state is required, but exact same-frame scene-state identity has not yet been proven. This is a remaining architecture risk before any candidate could be promoted.

The evaluator's spatial path intentionally uses neutral non-evolving scene statistics for spatial metrics; its temporal metrics use causal windows. The scalar anchor audit, rather than the spatial media score, is the evidence for anchor behavior in this run.

## 11. Performance

The following proxy measurements used the release-built player with the available `test.mp4`, a five second run, and zero late drops. They are development measurements rather than a repeated test6 median.

| mode | GPU p50 / p95 ms | CPU submission p50 / p95 ms | late drops |
|---|---:|---:|---:|
| Normal V4 | 0.515 / 0.726 | 0.206 / 0.565 | 0 |
| Quick V2 | 0.515 / 0.727 | 0.235 / 0.601 | 0 |
| Controlled A/B | 0.901 / 0.978 | 0.220 / 0.760 | 0 |
| DEBUG V4 | 0.703 / 2.903 | 0.290 / 0.771 | 0 |
| Controlled A/B + DEBUG | 0.698 / 5.351 | 0.238 / 0.693 | 0 |
| Normal V6 BL045 | 0.517 / 0.739 | 0.252 / 0.575 | 0 |
| Controlled V6 BL045 | 0.544 / 1.014 | 0.208 / 0.539 | 0 |
| DEBUG V6 BL045 | 0.674 / 2.963 | 0.271 / 0.668 | 0 |

Normal V6 BL045 GPU p95 is about `1.8%` above Normal V4 in this proxy run, within the `5%` development gate. Debug readback has the expected higher cost. The combined controlled V6 plus DEBUG run was performed while the display was in an SDR fallback state, so its `6.930 ms` GPU p95 is not directly comparable to the EDR rows.

The production default remains debug off, controlled A/B off, ROI off, and calibrated V4. No realtime synchronization wait was added to the production path.

## 12. Tests

Completed checks:

- `swift build -c debug --disable-index-store`: PASS
- `swift build -c release --disable-index-store`: PASS
- `swift test -c debug --disable-index-store`: PASS, 179 tests, 5 skipped, 0 failures
- `git diff --check`: PASS
- `v6-curve-audit`: PASS for dense 1001 point sweeps and all accepted candidates/anchors
- `v6-evaluate`: PASS, 8 allowed non-Frozen pairs, 8 prepared, 5 Tune videos, 3 Validation videos, no skipped pairs
- V4 exact output/reference checks, V6 monotonicity, exact black, continuity, finite output, slope, shoulder fade, CPU/reference and Metal parity, anchor extremes, temporal isolation, near black, highlight, and diagnostic parity tests are included and passing.

`RUN_MACOS_VERIFY.sh fast` was not run. The existing workflow enters protected Frozen or holdout related paths and can mutate evaluation artifacts; this development stage explicitly forbids that workflow. No Frozen or Virgin media or objective command was run.

## 13. Candidate Ranking

1. `V4_BASELINE` remains the overall gate leader and is the only configuration with no measured candidate regression. It is retained as production baseline.
2. `NO_LOWMID` gives the strongest diffuse overshoot reduction, but fails the total objective, near black, highlight, specular, and temporal no-regression requirements.
3. `BANDLIMITED_045` is the best valid band candidate by aggregate objective, but its diffuse metrics are effectively unchanged and its total objective and highlight metrics regress.
4. `BANDLIMITED_035` passes the mathematical invariants but has a slightly worse objective than BL045 and the same material highlight regression.
5. `BANDLIMITED_055`, `065`, and `075` are rejected by hard curve invariants for one or more anchor families and were not used for media selection.

## 14. Selected V6 Development Candidate

**NONE.** No candidate meets all of the required gates. The band-limited family is a useful structural direction, but this first fixed-strength implementation does not preserve the V4 highlight and near black behavior while improving the generic diffuse metric. No candidate was promoted, no `calibratedV6` preset was created, and the production default was not changed.

## 15. Rejected Candidates and Why

- `NO_LOWMID`: useful attribution ablation, rejected as a development winner because the broad term appears to contribute to highlight and shadow objectives as well as diffuse overshoot.
- `BL035`: mathematical invariants pass, but aggregate diffuse overshoot is unchanged and total Tune/Validation objectives worsen.
- `BL045`: best valid band score, but still fails the no-regression gate; it also removes the V4 high-end low mid contribution.
- `BL055`: wide-anchor slope becomes negative.
- `BL065`: wide-anchor slope becomes more negative.
- `BL075`: slope failures occur across all tested anchor families.

## 16. Remaining Risks

- The actual `test6.mp4` face ROI is still unavailable. Face versus same-luminance non-skin attribution is therefore unverified.
- The spatial evaluator neutralizes evolving scene statistics, so media scores do not exercise the observed production shadow anchors directly.
- The fixed generic diffuse range `0.15...0.45` should be checked against a larger available reference distribution before it is used for calibration.
- The matched controlled V6 probe exposed different V4 and V6 scene anchor values. The independent state path needs a same-buffer, same-timestamp state audit before promotion.
- Performance measurements need repeated runs and a consistent EDR display state for a final median and p95 gate.
- Candidate low-band behavior may lift dark content as anchors move; the proxy near black gains warrant dedicated anchor transition fixtures.

## 17. Frozen Status

~~~
Frozen accessed: NO
Virgin Frozen accessed: NO
Objective evaluations: 0
~~~

The manifest contains only non-Frozen Tune/Validation or development reference pairs. No protected evaluation infrastructure was bypassed.

## 18. Recommended Next Step

Keep V4 immutable and obtain the missing `test6.mp4` for a manual, normalized generic face ROI plus a same-luminance non-skin ROI across at least three frames. In parallel, resolve the controlled V4/V6 scene-state discrepancy and add anchor transition fixtures that cover near black through shoulder overlap. Then revisit a bounded low mid family that explicitly preserves the paired highlight and near black targets, using Tune/Validation only.

The next iteration should continue to change the mathematical support and state conditioning one factor at a time. It should not add a skin or face heuristic, change V4 production coefficients, create a production V6 preset, or open Frozen/Virgin evaluation.
