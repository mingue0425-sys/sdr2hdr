# SDR Interpretation / Calibration Rebase

## 1. Baseline

This cycle starts from correctness baseline `bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9`, the PR #12 merge commit. The implementation lineage before that commit and the historical calibrated V4 evidence remain recorded separately.

The prior calibration quality evidence is not reusable for this implementation. `calibratedV4` remains present as a historical configuration and was not overwritten or promoted.

## 2. Problem statement

The corrected implementation must define how an SDR program signal becomes a linear-light source observation before tone expansion. A source transfer tag describes what the source advertises. An SDR interpretation policy describes the rendering-domain model selected for an ITU-R BT.709 tagged SDR signal.

The project objective is:

```text
SDR observation
→ explicit source interpretation
→ parameterized tone expansion
→ BT.2020 EDR/PQ output
```

Source-domain semantics are therefore part of calibration identity.

## 3. Signal metadata and interpretation policy

`SDRSourceTransferTag` is separate from `SDRInputInterpretationPolicy`.

Source tags include `ituR709`, `sRGB`, `explicitGamma`, `linear`, `unsupportedHDR`, and `unknown`. The resolver records:

```text
sourceTransferTag
requestedPolicy
selectedPolicy
effectiveTransfer
fallbackUsed
fallbackReason
```

An explicit sRGB tag always resolves to sRGB. Explicit gamma follows its metadata. Explicit linear input remains linear. PQ and HLG are not admitted to the automatic SDR path.

An untagged source uses an explicit configuration: `assumeBT709SourceLinear`, `assumeBT1886ReferenceDisplay`, or `reject`. A fallback is recorded in the resolution and is never silent.

## 4. Standards model

BT.709 describes source and production signal characteristics, including its OETF. `bt709SourceLinear` applies the inverse BT.709 OETF to encoded R'G'B'.

BT.1886 describes a reference-display EOTF. `bt1886ReferenceDisplay` applies its parameterized EOTF to an encoded BT.709 program signal. The implementation carries black luminance `L_B`, white luminance `L_W`, and gamma and derives the root-domain terms. The ideal reference experiment uses `L_B = 0`, `L_W = 1`, and gamma `2.4`; these are normalized calibration parameters, not physical display measurements.

sRGB is a distinct source transfer characteristic. It is a metadata correctness path and is not a third global competitor to the two BT.709 interpretation policies.

## 5. Implemented policies

The public policy names are:

```text
bt709SourceLinear
bt1886ReferenceDisplay
sRGB
explicitGamma
linear
```

The two policy candidates in the calibration preregistration are `bt709SourceLinear` and `bt1886ReferenceDisplay`. The runtime, scalar reference, offline sampler, preparation path, and calibration parameter round-trip all carry the same policy identity.

## 6. Independent numerical anchors

The independent scalar tests use equations in the test source rather than calling the production helper to create expected values.

```text
BT.709 inverse at 0.0 = 0.0
BT.709 inverse at 0.5 ≈ 0.2595894
BT.709 inverse at 1.0 = 1.0

ideal-black BT.1886 at 0.0 = 0.0
ideal-black BT.1886 at 0.5 ≈ 0.1894646
ideal-black BT.1886 at 1.0 = 1.0

sRGB inverse at 128/255 ≈ 0.2158605
```

The tests cover both piecewise breakpoints below, at, and above the knee; finite, monotonic, continuous-within-tolerance, exact black, and exact white behavior; and a non-zero-black BT.1886 fixture.

## 7. Runtime/reference parity

`HDRProcessor` resolves metadata with the configured policy and passes BT.1886 parameters into Metal. `HDRReference` has a policy-aware overload. `OfflinePixelSampler` resolves the same metadata and policy before normalizing video or full range. The CPU scalar reference and the Metal implementation are checked on a tagged BT.1886 BGRA sample.

NV12 and P010 use the same normalized signal domain and policy. Range normalization happens before transfer evaluation. Chroma reconstruction and siting behavior remain the existing architecture and are covered by the existing regression suite.

## 8. Tune preregistration

`results/calibration-rebase-preregistration.json` freezes the experiment before any Validation result can be used. It records the two candidates, equal per-policy search budgets, seed, parameter ranges, existing metric definitions, hard correctness gates, safety gates, shortlist size, selection rule, deterministic tie-break, and failure policy.

The canonical search-definition hash is:

```text
7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608
```

The BT.1886 policy and preparation plan identities participate in SHA-256 identity. An old V5 preparation plan cannot be accepted by adding a sidecar or policy name.

## 9. Tune results

The approved Tune/Validation manifest is not configured in this checkout/session. No calibration media was opened. The Tune artifact records:

```text
status: BLOCKED_MISSING_DATA
candidate evidence: []
objective evaluations: 0
```

Synthetic transfer fixtures provide correctness anchors only. They do not stand in for Tune data.

## 10. Frozen shortlist

No shortlist was frozen because the required approved Tune data is unavailable. The candidate artifact's local configuration-freeze flag describes the protocol only; it does not refer to the repository's Frozen dataset.

## 11. Validation results

Validation was not run. The Validation artifact records `BLOCKED_MISSING_DATA`. No policy, threshold, metric, search space, or parameter was changed after a result was exposed.

## 12. Candidate selection

No policy or candidate was selected. The result is:

```text
CALIBRATION_REBASE = BLOCKED_MISSING_DATA
SELECTED SDR POLICY = NONE
NEW CANDIDATE = NONE
PRODUCTION DEFAULT CHANGED = NO
```

This is an honest data-availability result, not a claim that either standard model is preferred.

## 13. Calibration lineage

The new lineage is `calibration-rebase-2026-09-sdr-policy-v1`. Its artifact records:

```text
correctnessBaseline = bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9
sdrPolicyVersion = sdr-input-interpretation-policy-v1
preparationVersion = v6-prepared-evaluation-plan-v6-sdr-interpretation-policy
metricVersion = v2-objective-with-v61-directional-diagnostics
frozenAccessed = false
objectiveEvaluations = 0
oldCalibrationReusable = false
```

Tune and Validation identities remain `UNAVAILABLE`; they are not invented from old V4 output.

## 14. Regression tests

The PR #12 baseline suite remains the gate: Debug and Release must have zero failures, and the existing release build, Frozen guard, cache regression, self-contained integration, automatic decode, 12-fixture matrix, 28-run multi-flight matrix, native completion observer, and Metal debug-layer checks remain required. New tests cover transfer anchors, BT.1886 non-zero black, metadata-to-policy resolution, explicit fallback, old plan rejection, policy hash participation, NV12/P010 normalization parity, and CPU/Metal parity.

The PR #12 near-black correction remains required. Exact black stays black and representable near-black survives quantization. Any collapse caused by policy propagation is a blocker.

## 15. Performance

The release synthetic 4K measurement used warmup 30 and 300 measured frames on Apple M2:

| workload | p50 | p95 | p99 | worst |
| --- | ---: | ---: | ---: | ---: |
| NV12 → EDR | 2.059 ms | 2.755 ms | 2.796 ms | 2.805 ms |
| P010 → EDR | 2.278 ms | 3.280 ms | 3.637 ms | 3.677 ms |
| P010 → PQ | 2.553 ms | 3.573 ms | 3.921 ms | 3.928 ms |
| presentation-only | 0.844 ms | 1.726 ms | 2.386 ms | 3.233 ms |

These are synthetic offscreen timings for the transform or presentation stage. They are recorded without converting them into actual playback FPS or end-to-end latency, and `PERFORMANCE IMPROVEMENT CLAIMED = NO` remains in force. The PR #12 numbers are historical reference evidence; a direct percentage comparison is not made unless the workload definition is identical.

## 16. Remaining risks

```text
HIGH: approved Tune/Validation corpus is unavailable in this session
HIGH: original PTS preservation for VFR temporal proxy is unproven
HIGH: source↔binary causal build provenance is unproven
UNMEASURED: physical display calibration and colorimetric accuracy
MEDIUM: a 16×9 sparse proxy may miss a small highlight
```

The existing PR #11 allowlist-only guard remains unchanged. Frozen/Virgin content was not enumerated, probed, decoded, hashed, or evaluated.

## 17. Final verdict

```text
FINAL VERDICT: BLOCKED_MISSING_DATA
ENGINE STATUS: EXPERIMENTAL
CALIBRATION STATUS: REBASE_REQUIRED
PRE_FROZEN READINESS: NOT YET EVALUATED
PRODUCTION QUALITY: NOT APPROVED
Frozen accessed: NO
Objective evaluations: 0
```

The policy infrastructure and preregistration are reviewable, but no calibration candidate is available until an approved Tune/Validation manifest is explicitly configured.
