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

`results/calibration-rebase-preregistration.json` is the historical v1 record. It is retained for audit lineage, but it is invalidated and cannot authorize calibration. The repaired semantic-only v2 record is generated separately at `results/calibration-rebase-preregistration-v2.json` after the implementation and mandatory tests are frozen.

The retired v1 search-definition hash is:

```text
7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608
```

The retired v1 record is not a corpus seal. The v2 artifact separates policy, preparation, metric, and search identities; it intentionally does not create a corpus or experiment-binding identity before media qualification. An old V5 preparation plan cannot be accepted by adding a sidecar or policy name.

## 9. Family-disjoint corpus reissue preflight

The historical paired manifest was read at its exact committed path and was
left unchanged:

```text
path: data_video/visual-regression/v6-development-manifest.json
manifest version: 4
manifest SHA-256: 26cab0df016dc1ed17f2b70fc8e1dc10cf7677907994c24937479fb423259c8c
records: 8
historical roles: Tune 5 / Validation 3
status: HISTORICAL_MANIFEST_UNCHANGED
```

The only content families in the approved eight-record universe are
`K-Choreo` and `LIVE`, with four records each. The split viability check used
only `contentFamily`, historical split role, record counts, and pair identity.
It did not read media bytes, decode frames, inspect images, or run metrics.

The family-atomic candidates are:

| family assignment | Tune records | Validation records | moved records | Tune families | Validation families | promotion-grade diversity |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `K-Choreo → Tune`, `LIVE → Validation` | 4 | 4 | 3 | 1 | 1 | FAIL |
| `K-Choreo → Validation`, `LIVE → Tune` | 4 | 4 | 5 | 1 | 1 | FAIL |

The first assignment is selected by the preregistered deterministic ordering
because it moves fewer historical records. Both candidates have zero family
overlap, but each side has only one family. The required minimum of two
distinct families in both Tune and Validation is therefore impossible with
this two-family universe. Family atomicity is preserved; the promotion-grade
family-diversity gate fails.

The result is recorded in
[`results/calibration-corpus-preflight-v2.json`](../results/calibration-corpus-preflight-v2.json).
The earlier
[`results/calibration-corpus-preflight.json`](../results/calibration-corpus-preflight.json)
remains preserved as the historical overlap preflight. No v5 manifest was
emitted, so no new dataset identity, current byte hash, corpus definition
hash, or experiment binding hash was created. Identity anchoring stops at the
structural viability gate; no media bytes were read.

The historical preregistration remains preserved but is invalidated. Its
source-equivalent Swift `JSONEncoder` hash is retired and is not eligible for
calibration. The v2 semantic seal is separate and does not claim to seal the
future Tune/Validation corpus.

```text
family overlap for selected rejected assignment: []
family-level split independence: PASS_FOR_REJECTED_ASSIGNMENT
promotion-grade family diversity: FAIL (1 family / 1 family; required 2 / 2)
current byte identity: NOT_ESTABLISHED
source/reference hash coverage: NOT_STARTED
media decoded: NO
media hashed: NO
Tune run: NO
Validation run: NO
objective evaluations: 0
status: BLOCKED_INSUFFICIENT_FAMILY_DIVERSITY
```

Synthetic transfer fixtures provide correctness anchors only. They do not stand in for Tune data.

## 10. Frozen shortlist

No shortlist was frozen because the family-diversity gate failed before v5
manifest emission and media materialization. A future
`configurationFrozenForReadiness` flag would describe a candidate
configuration only; it would not refer to the repository's Frozen dataset.

## 11. Validation results

Validation was not run. The structural blocker was established before any
Validation metric or media bytes were exposed. No policy, threshold, metric,
search space, parameter, or split role was changed.

## 12. Candidate selection

No policy or candidate was selected. The result is:

```text
CALIBRATION_REBASE = BLOCKED_INSUFFICIENT_FAMILY_DIVERSITY
SELECTED SDR POLICY = NONE
NEW CANDIDATE = NONE
PRODUCTION DEFAULT CHANGED = NO
```

This is an honest structural preflight result, not a claim that either
standard model is preferred. A trusted corpus expansion with at least two
families on each side is required before exact byte identity anchoring and the
preregistered search can resume.

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

The historical Tune and Validation roles were used only for the deterministic
viability calculation. No new Tune/Validation corpus identity was issued, no
old V4 output was used to reconstruct a corpus, and no historical score was
reused.

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
HIGH: approved eight-record universe has only two families, so strict two-family-per-split diversity is impossible
HIGH: no v5 corpus was emitted and current paired-manifest byte identity remains unanchored
UNKNOWN: source-master-level independence is absent from the approved manifest metadata
HIGH: original PTS preservation for VFR temporal proxy is unproven
The repaired plan path requires current-implementation regeneration from exact
sealed preparation inputs before evaluator entry. Corpus qualification and
the final experiment binding remain unperformed.
UNMEASURED: physical display calibration and colorimetric accuracy
MEDIUM: a 16×9 sparse proxy may miss a small highlight
```

The existing PR #11 allowlist-only guard remains unchanged. Frozen/Virgin content was not enumerated, probed, decoded, hashed, or evaluated.

## 17. Final verdict

```text
FINAL VERDICT: BLOCKED_INSUFFICIENT_FAMILY_DIVERSITY
ENGINE STATUS: EXPERIMENTAL
CALIBRATION STATUS: REBASE_REQUIRED
PRE_FROZEN READINESS: NOT YET EVALUATED
PRODUCTION QUALITY: NOT APPROVED
Frozen accessed: NO
Objective evaluations: 0
```

The policy infrastructure and repaired v2 semantic preregistration remain
reviewable, but no
calibration candidate is available. The exact historical manifest path was
found and remains untouched. A family-atomic assignment can remove overlap,
but the approved universe cannot provide two distinct families to each split,
so the strict corpus reissue preflight blocks before byte identity anchoring.
