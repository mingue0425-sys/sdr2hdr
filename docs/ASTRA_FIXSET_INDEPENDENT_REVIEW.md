# Astra fixset — independent correctness review

Date: 2026-09-12

This review is an independent check of the uncommitted Astra correctness
fixset against production baseline `064d9a3e99e216e317c23ba0a160da6f95ebef1e`.
It is not a quality approval, a calibration report, or a Frozen evaluation.

## Boundary and decision

The review did not enumerate, open, decode, or hash any Frozen, Virgin Frozen,
holdout, or `data_video` subtree. The only media used by the new proxy test is
generated in a temporary directory and is not a calibration objective asset.

No preset was retuned, no candidate was promoted, and no historical calibration
score was reused as evidence for the corrected implementation.

Final decision: **ACCEPT_FIXSET** for the correctness baseline, subject to the
residual risks below. This decision does not change the engine status from
`EXPERIMENTAL` and does not approve production HDR quality.

## Claim matrix

| Astra claim | Verdict | Independent reproduction / evidence | Regression coverage |
|---|---|---|---|
| Core near-black double attenuation | CONFIRMED | Direct `pow(code / 255, 4)` anchors for codes `[0, 1, 2, 4, 8]`; exact black, finite/non-negative output, monotonic ordering, and binary16 quantization are checked. | `AuditRegressionTests.testNeutralNearBlackPreservesLinearLightBeforeHalfQuantization` |
| Presentation near-black cutoff | CONFIRMED | EDR mapping now guards only exact zero; representable positive half samples remain nonzero. | `AuditPresentationTests.testEDRPresentationPreservesRepresentableNearBlack` |
| Encoded Y′ used as linear luminance | CONFIRMED | All four evaluation preparation paths use metadata-aware `linearLumaGrid`; the diffuse gate remains explicitly linear `[0.15, 0.45]`. | `V61ErrorAttributionTests`, `CalibrationTests.testV6PreparedPlan...` |
| Prepared-plan semantic invalidation | CONFIRMED | The preparation identifier is `v6-prepared-evaluation-plan-v5-linear-source-luminance`; changing only an old artifact's version and recomputing its hash is rejected. | `CalibrationTests.testV6PreparedPlanCanonicalHashAndExactIdentityValidation` |
| sRGB interpretation | CONFIRMED | Independent code-value 128 anchor is approximately `0.2158605`; the inverse-BT.709 result `0.2614815` is not accepted. | `AuditIntegrityTests.testSourceLinearLuminanceHonorsSRGBMetadata` |
| Runtime/offline SDR transfer policy | CONFIRMED for BT.709, sRGB, gamma, and linear | Runtime and offline paths call the same `HDRInputMetadata.resolve` policy. Gamma conversion revalidates both the source `Double` and shader `Float`. PQ/HLG remain reference-media semantics, not SDR input fallbacks. | `AuditRegressionTests`, `HDRMathTests`, `P010Tests`, `V61ErrorAttributionTests` |
| FFmpeg transfer/matrix/range preservation | CONFIRMED | Source tags are recovered from CoreMedia or complete ffprobe metadata; matrix is passed to swscale; pixels are converted full-range→video-range before rawvideo output; output is relabelled with the source transfer/matrix. Missing range is now fail-closed instead of `in_range=auto`. | `AuditProxyColorTests`; temporary sRGB, PQ, and HLG fixtures |
| Proxy fixture precision | CONFIRMED | sRGB remains 8-bit; PQ/HLG fixtures are genuine `yuv420p10le` / Main10 sources before P010 proxy decoding. | `AuditProxyColorTests.testTemporalProxyPreservesSourceColorAndNormalizesRange` |
| PQ absolute anchors | CONFIRMED | Independent 100-nit and 1,000-nit encode/decode anchors are checked, not only round-trip parity. | `AuditRegressionTests.testPQAbsoluteAnchorsIndependentOfRoundTrip` |
| Signed calibration diagnostic | CONFIRMED | `reference=100`, `generated=50` yields `ln(51/101) ≈ -0.683294884`; the signed region field remains negative. | `AuditIntegrityTests.testSignedMidtoneDiagnosticRetainsUnderPrediction` |
| Objective/diagnostic separation | CONFIRMED | Weighted objective terms remain absolute/non-negative; only the region diagnostic carries the signed residual. | `V2Metrics` implementation and metric tests |
| Temporal resize accumulation | CONFIRMED for serial resize lifetime | Twenty size changes retain at most the three output slots and their estimator buffers; old slots remain alive only while a returned frame or GPU command owns them. | `AuditRegressionTests.testResolutionChangesRetireTemporalBuffersWithOutputSlots` |
| Multi-flight generation isolation | CONFIRMED in state/resource unit coverage; real-media matrix is separately reported below | Completion acceptance is gated by generation and monotonic sequence; late old-generation completion cannot publish adaptive state. | `HDRMultiFlightOrderingTests`, `HDRMathTests`, `P010Tests` |
| Double→Float gamma validation | CONFIRMED | `Double.greatestFiniteMagnitude`→`Float.infinity` and tiny positive→`Float(0)` are rejected after conversion. | `AuditRegressionTests.testGammaMetadataMustRemainFiniteAndPositiveInShaderPrecision` |
| Metal shader cache invalidation | CONFIRMED | Changing a `.metal` fixture changes the cache fingerprint. | `Tests/verify_script_cache_test.sh` |
| Media-content cache preflight | CONFIRMED | A cache hit still invokes Tune/Validation content validation; a failing validator cannot be converted into a cache hit. | `Tests/verify_script_cache_test.sh` |
| Shell failure propagation | CONFIRMED | Explicit `|| return $?` propagation covers the verifier→`tee` pipeline and conditional/OR-list call contexts. | `Tests/verify_script_cache_test.sh` |
| Benchmark failure semantics | CONFIRMED by source and unit gates | GPU timestamps are required; command creation/encoding/commit define CPU submission; wait is excluded; initialization, execution, and timestamp failures are not normal results. | `CalibrationTests.testV4RuntimeBenchmarkCollectsRealGPUAndCPUSamples`, benchmark implementation |
| Local Frozen consumption ledger | CONFIRMED as a repository-local durable guard | Per-asset SHA-256 receipt uses exclusive creation, `O_NOFOLLOW`, file/directory fsync, and fail-closed partial claims; eight concurrent claims produce one winner. | `AuditIntegrityTests` |
| Global exactly-once Frozen evaluation | REJECTED as a claim | A local ledger cannot prevent deletion, another checkout, re-encoding, legacy evaluators, or custody bypass. | Limitation intentionally documented |

## Metric contract

The following contract is the one used for this review. A metric's sign is not
inferred from its field name.

| Metric family | Domain and unit | Sign / expected range | Direction |
|---|---|---|---|
| `objective` and weighted contributions | Composite of normalized, nits-scaled, ICtCp, ratio, and fraction terms; dimensionless | Non-negative; not a physical unit and not a bounded quality percentage | Lower is better |
| `luminanceError`, `midtoneError`, `diffuseWhiteError`, `highlightError`, `shadowError`, percentile region errors | `abs(ln((generated nits + 1) / (reference nits + 1)))`; dimensionless | `≥ 0`, finite for accepted samples | Lower is better |
| `absoluteNitError` | Mean absolute nits difference divided by 1,000 nits; dimensionless | `≥ 0` | Lower is better |
| `diffuse_midtone_signed` | `ln((generated nits + 1) / (reference nits + 1))`; dimensionless | Signed finite residual; negative means under-prediction, positive means over-prediction, zero means agreement | Diagnostic only; zero is neutral |
| `diffuse_midtone_positive_overshoot`, `negative_undershoot`, `mae` | One-sided magnitude or absolute value of the same log residual | Non-negative | Lower is better when used as a diagnostic |
| `referenceDiffuseWhiteNits`, `generatedDiffuseWhiteNits` | Absolute luminance in nits | Expected non-negative finite nits | Compare against the target, not simply maximize/minimize |
| ICtCp chroma/saturation errors | PQ-encoded ICtCp-derived differences; dimensionless | Non-negative; practical range depends on the encoded colors | Lower is better |
| Hue errors | Absolute hue delta normalized by π; dimensionless | `[0, 1]` when a chroma-bearing sample exists | Lower is better |
| Temporal and flicker errors | Differences of log luminance ratios across frames; dimensionless | Non-negative | Lower is better |
| Structure error | `1 - Pearson correlation`; dimensionless | `[0, 2]` when correlation is defined | Lower is better |
| Clipping, crush, lift, under/over-saturation ratios | Fraction of qualifying samples | `[0, 1]` | Lower is better |
| `nearBlackContrastLoss` | Relative loss of the p1→p10 range | `[0, 1]` | Lower is better |
| `highlightCompressionError`, specular under/over reach | Relative or absolute deviation from reference percentiles | Non-negative; finite accepted evidence | Lower is better |
| Source preparation grid | Metadata-aware relative linear BT.709 luminance, not nits | Expected `[0, 1]` after source clamp; sRGB/BT.709/gamma/linear policy is explicit | Used as a domain gate, not a quality score |

## Test evidence

The raw XCTest summary for the corrected scratch overlay is:

```text
Debug:   349 cases reported, 17 skipped, 0 failures
Release: 349 cases reported, 17 skipped, 0 failures
```

The prior `16 skipped / 333 executed` statement is arithmetically and
reproductively stale. The 17 explicit skips are:

* 5 calibration cases: missing `test.mp4`, large local data-test fixtures,
  LIVE paired media, and real `live_9` media;
* 3 external-media cases: `HDR_REAL_MEDIA_ROOT` and external manifest unset;
* 7 automatic/self-contained integration cases: the H.264, HEVC, Main10, and
  generated tiny-fixture environment variables are unset;
* 1 multi-flight real-media case: the regression fixture directory is unset;
* 1 compressed real-media regression case: the regression fixture directory is
  unset.

These are skips, not passes. The test runner's `Executed N tests, with K
skipped` wording is retained verbatim in the logs; this report does not turn
the skipped cases into executed evidence.

Additional self-contained checks:

* release build: PASS;
* generated compressed fixture contracts: PASS;
* self-contained AVFoundation/Metal integration: PASS for 8-bit NV12 and
  Main10 P010, with both nearest and siting-aware-bilinear reconstruction;
* automatic decode: PASS for H.264 8-bit→NV12, HEVC 8-bit→NV12, and HEVC
  Main10→P010;
* compressed regression: PASS for 12 generated fixtures, nearest and
  siting-aware-bilinear, in both debug and release (`failures=0`, `skipped=0`);
* multi-flight: PASS for 7 fixtures × 2 chroma modes × flight depth 2/3 = 28
  runs, including the optional native completion observer with
  `MTL_DEBUG_LAYER=1`;
* shell/cache regression: PASS;
* Frozen-access guard and its regression test: PASS;
* no Frozen objective evaluation: `0`;
* no Frozen/Virgin/holdout media was read by this review.

The external real-media quality matrix remains **NOT COMPLETED**. It must not
be represented as a zero-failure quality result when its corpus is absent.

## Performance

Fresh M2 4K release measurements use 30 warmup and 300 measured frames. They
are reported for reproducibility only; no improvement claim is made.

| Path | GPU p50 / p95 / p99 / worst (ms) |
|---|---|
| NV12 → EDR | 1.626 / 1.946 / 3.530 / 3.565 |
| P010 → EDR | 1.931 / 2.215 / 2.595 / 5.246 |
| P010 → PQ | 2.156 / 2.207 / 2.603 / 3.568 |
| Presentation-only | 0.588 / 0.801 / 1.118 / 1.195 |

CPU submission includes command creation, encoding, and commit, and excludes
`waitUntilCompleted`. These numbers must not be compared directly with PR #10
CPU values whose measurement definition differed. Fresh CPU p50/p95/p99 (ms)
were NV12 EDR `0.021/0.095/0.250`, P010 EDR `0.030/0.043/0.054`, P010 PQ
`0.062/0.216/0.710`, and presentation `0.017/0.048/0.087`.

Performance improvement claimed: **NO**. A before/after single-run tail
improvement is not sufficient evidence, and the correctness rebase is not a
performance PR.

## Residual risks and deferred work

* **HIGH — SDR transfer/input interpretation policy.** BT.709 scene-linear,
  sRGB, and BT.1886 display-referred interpretations still need an explicit,
  versioned policy and a fresh calibration rebase. BT.1886 is intentionally
  deferred; this fixset does not choose between those policies.
* **HIGH — original PTS/VFR temporal fidelity.** The FFmpeg proxy still uses
  an `fps` resampling path and synthesized timestamps. Preserving source PTS,
  duplicate/drop provenance, and VFR semantics is a separate architecture PR.
* **HIGH — source↔built-binary/resource provenance.** Source and executable
  hashes are evidence fields, not proof of a causal, reproducible build.
* **MEDIUM — sparse temporal statistics and scheduling fidelity.** The 16×9,
  64-bin causal estimator and bounded multi-flight tests do not prove every
  production scheduling pattern.
* **MEDIUM — superwhite, negative, and mastering-model limits.** These remain
  policy/model questions outside this fixset.
* **UNMEASURED — physical display luminance/chromaticity.** No instrumented
  display measurement was performed.

Historical V4 scores, candidate rankings, and pre-Frozen readiness results are
`HISTORICAL_PRE_CORRECTION_EVIDENCE` and are not reusable quality evidence for
this implementation. Calibration must be rebased after the SDR input policy
is versioned.

## Final state

```text
FINAL VERDICT:                 ACCEPT_FIXSET
ENGINE STATUS:                 EXPERIMENTAL
CALIBRATION STATUS:            REBASE_REQUIRED
CORRECTNESS_REBASE_READY:      YES
PRODUCTION QUALITY APPROVED:   NO
Frozen accessed:               NO
Objective evaluations:         0
```
