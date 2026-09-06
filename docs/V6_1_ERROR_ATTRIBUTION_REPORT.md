# V6.1 Error Attribution Report

## 1. Why V6 Candidate Selection Failed

The V6 structural search did not produce a development winner. The candidates were NO_LOWMID, BL035, BL045, BL055, BL065, and BL075; BL045 was the best structurally valid band-limited candidate, but its Validation objective was +0.023884086 relative to V4 and its aggregate diffuse improvement was reported as none. The signed analysis below explains why that result cannot be reduced to a single global low-mid-strength error.

The paired-reference run used final production base d97c3d3 and eight non-Frozen Tune/Validation pairs, producing 41 scenes and 120,960 aligned samples. test6.mp4 was unavailable, so no face-specific attribution was attempted. The generic algorithm conclusion is separate from the unverified face attribution.

The calibrated V4 invariant used by the run is: paperWhiteNits 190, peakNits 1008.6863, highlightStrength 0.6208221, contrastStrength 0.90542316, saturationCompensation 0.43140942, shadowProtection 0.4755874, temporalStability 0.7308984, masteringHeadroom 5.308875, toneCurveRevision sceneRelativeV4, outputMode EDR. The V4 production branch and these values remained unchanged.

## 2. Signed Error Method

For every aligned sample, the primary signed error is:

    signedError = candidate HDR luminance - paired HDR reference luminance

Positive values mean over-prediction; negative values mean under-prediction. The report stores raw HDR-nit summaries (mean, median, P05/P50/P95, positive and negative means, over/under ratios, MAE, RMSE, and P95 absolute error) plus a signed log1p companion. The V2 output is a comparison baseline, never the reference target.

Source bins use exact linear BT.709 SDR luminance. The attribution path uses the observation-only OfflinePixelSampler.linearLumaGrid conversion that matches the shader's YUV/BGRA linearization domain; the existing official V2EvaluationEngine objective code was not changed. Samples are paired on the same aligned 32x18 grid. The generic diffuse diagnostic interval is 0.15 <= Y <= 0.45: it excludes deep-shadow bands and ends below the V4 shoulderStart, while containing the ordinary diffuse region being investigated. It is not a skin mask and is not a replacement production objective.

## 3. Luminance-Bin Results

The entries below are mean signed error / MAE / overprediction ratio, in HDR nits. V4-V2 is the signed mean luminance difference between the two candidates.

| Source linear Y bin | Samples | V2 | V4 | NO_LOWMID | BL045 | V4-V2 |
|---|---:|---:|---:|---:|---:|---:|
| [0.00, 0.01) | 3585 | 0.84 / 0.98 / 0.950 | 0.67 / 0.81 / 0.943 | 0.67 / 0.81 / 0.943 | 0.67 / 0.81 / 0.943 | -0.17 |
| [0.01, 0.02) | 10985 | 2.37 / 2.43 / 0.999 | 1.90 / 1.97 / 0.996 | 1.89 / 1.96 / 0.996 | 1.90 / 1.97 / 0.996 | -0.47 |
| [0.02, 0.05) | 13363 | 2.60 / 2.76 / 0.976 | 1.73 / 2.00 / 0.902 | 1.61 / 1.94 / 0.867 | 1.73 / 2.00 / 0.902 | -0.87 |
| [0.05, 0.10) | 8627 | 0.60 / 3.60 / 0.441 | 0.07 / 3.58 / 0.316 | -1.73 / 4.53 / 0.251 | 0.07 / 3.58 / 0.316 | -0.52 |
| [0.10, 0.15) | 7133 | -5.32 / 8.74 / 0.169 | -4.26 / 8.04 / 0.177 | -9.34 / 11.52 / 0.151 | -4.26 / 8.04 / 0.177 | 1.06 |
| [0.15, 0.20) | 7677 | -11.88 / 15.29 / 0.137 | -10.37 / 14.19 / 0.142 | -17.49 / 19.42 / 0.129 | -10.37 / 14.19 / 0.142 | 1.51 |
| [0.20, 0.30) | 13753 | -24.43 / 26.96 / 0.082 | -22.28 / 25.17 / 0.084 | -32.39 / 33.65 / 0.080 | -22.29 / 25.17 / 0.084 | 2.15 |
| [0.30, 0.40) | 11097 | -42.18 / 44.29 / 0.076 | -39.17 / 41.75 / 0.080 | -53.34 / 53.95 / 0.055 | -42.60 / 44.67 / 0.073 | 3.01 |
| [0.40, 0.50) | 8141 | -65.28 / 66.53 / 0.054 | -61.42 / 63.11 / 0.060 | -79.59 / 79.76 / 0.017 | -76.49 / 76.88 / 0.029 | 3.86 |
| [0.50, 0.60) | 5589 | -100.33 / 100.68 / 0.013 | -94.66 / 95.17 / 0.017 | -116.88 / 117.01 / 0.002 | -116.88 / 117.01 / 0.002 | 5.67 |
| [0.60, 0.75) | 7318 | -116.99 / 117.84 / 0.010 | -98.22 / 99.49 / 0.014 | -126.00 / 126.69 / 0.008 | -126.00 / 126.69 / 0.008 | 18.77 |
| [0.75, 1.00] | 23692 | -12.90 / 19.21 / 0.316 | 5.07 / 21.73 / 0.836 | -28.11 / 30.25 / 0.026 | -28.11 / 30.25 / 0.026 | 17.97 |

The pattern is not a global V4 over-brightening relative to the HDR reference:

- V4 is mildly positive below Y=0.10, especially in [0.01, 0.05).
- V4 is negative throughout [0.10, 0.75). In the diagnostic diffuse interval its mean signed error is negative in every sub-bin: -10.37, -22.28, -39.17, and -61.42 nits.
- V4 becomes positive again in [0.75, 1.00] with +5.07 nits and an overprediction ratio of 0.836; this is the high end where the shoulder, rather than the diffuse diagnostic band, is active.
- V4 is brighter than V2 in the ordinary midtone bins, but that brightness moves V4 toward the reference because V2 is even more under-predicted there.

The V4 low-mid contribution grows with source Y: approximately 0.0374, 0.0532, 0.0746, and 0.0956 normalized Y in [0.15,0.20), [0.20,0.30), [0.30,0.40), and [0.40,0.50). The associated V4 signed errors remain negative. BL045 matches V4 to rounding through [0.20,0.30) and becomes more under-predicted as it fades the term in the upper part of the diffuse-to-shoulder transition.

## 4. V2 vs V4 vs HDR Reference

The bin data classifies the important cases as follows:

- In 0.15 <= Y < 0.45, V2 and V4 are both below the reference, with V4 closer to it. This is not Case B (V2 approximately reference, V4 over).
- In [0.75,1.00], V2 is below the reference (-12.90 nits) while V4 is above it (+5.07 nits). This is Case C, but it is a highlight-region result and cannot be assigned to diffuse low-mid expansion alone.
- Across transfer functions and scenes, both directions occur. A single global coefficient therefore cannot be inferred from the visual relation V4 > V2.

The direct implication is that the original visual observation established a V4-versus-V2 difference, while the paired HDR reference establishes a transfer- and content-dependent signed error. Those are different claims.

## 5. lowMid Contribution Correlation

Correlation uses per-sample lowMidContribution against the raw signed reference error. Values are Pearson / Spearman:

| Split | Scope | Candidate | lowMid vs signed error | shoulder vs signed error | total expansion vs signed error |
|---|---|---|---:|---:|---:|
| tune | all | v4 | -0.139 / -0.021 | 0.288 / 0.304 | 0.252 / -0.021 |
| tune | diffuse-midtone-0.15-0.45 | v4 | -0.702 / -0.820 | not estimable | -0.702 / -0.820 |
| tune | diffuse-midtone-0.15-0.45 | no-lowmid | not estimable | not estimable | not estimable |
| tune | diffuse-midtone-0.15-0.45 | bl045 | 0.154 / -0.112 | not estimable | 0.154 / -0.112 |
| validation | all | v4 | -0.437 / -0.300 | -0.177 / -0.036 | -0.207 / -0.300 |
| validation | diffuse-midtone-0.15-0.45 | v4 | -0.589 / -0.640 | not estimable | -0.589 / -0.640 |
| validation | diffuse-midtone-0.15-0.45 | no-lowmid | not estimable | not estimable | not estimable |
| validation | diffuse-midtone-0.15-0.45 | bl045 | 0.167 / -0.068 | not estimable | 0.167 / -0.068 |

In the diffuse interval, V4 low-mid contribution has a strong negative association with signed error: Tune -0.702 / -0.820, Validation -0.589 / -0.640. Higher contribution occurs where the candidate is more under the reference, not where it is more over it. This is not proof that the term is beneficial—the contribution and source luminance are coupled—but it is direct evidence against the proposed global statement that the V4 low-mid term is the source of paired-reference diffuse overshoot.

For BL045, the diffuse correlation is weak (+0.154 / -0.112 Tune and +0.167 / -0.068 Validation), while the candidate has already lost useful lift in parts of the diffuse region. This explains why band limiting did not improve the aggregate objective.

## 6. Shoulder Contribution Correlation

shoulderStart = 0.68 - 0.20 * contrastStrength = 0.498915 for calibrated V4. The shoulder contribution is zero throughout the selected diffuse interval, so its diffuse correlation is mathematically unestimable. V4 low-mid and shoulder overlap structurally in approximately Y >= 0.50, but the signed error in [0.50,0.75) remains strongly negative (-94.66 and -98.22 nits). The positive [0.75,1.00] result is therefore a high-end shoulder result, not evidence that overlap is the diffuse root cause.

Whole-range correlations are content dependent: V4 shoulder versus signed error is +0.288 / +0.304 on Tune and -0.177 / -0.036 on Validation. That sign change prevents a stable shoulder attribution from this dataset.

## 7. Scene Breakdown

The following table contains every one of the 41 paired scenes. Each candidate cell is spatial objective / diffuse mean signed error in HDR nits. The spatial objective is the existing per-scene diagnostic metric; the official split objective and its component decomposition are reported separately below.

| Pair | Scene | Split | Transfer | Mean source Y | V4 obj / mid signed | NO obj / mid signed | BL045 obj / mid signed |
|---|---|---|---|---:|---:|---:|---:|
| live_13_interview | scene_0001 | tune | PQ | 0.1314 | 0.459845 / 17.41 | 0.459746 / 5.17 | 0.477792 / 14.06 |
| live_22_programming_night | scene_0001 | validation | PQ | 0.0791 | 0.467986 / 13.26 | 0.403517 / 3.31 | 0.461762 / 11.63 |
| live_4_campfire | scene_0001 | validation | PQ | 0.2551 | 0.477753 / 0.11 | 0.501100 / -12.32 | 0.509869 / -3.25 |
| live_9_face_close | scene_0001 | tune | PQ | 0.3226 | 0.378360 / 14.65 | 0.372517 / 3.22 | 0.386575 / 11.28 |
| video1_ive_blackhole | scene_0001 | tune | HLG | 0.0538 | 0.231268 / -33.96 | 0.297607 / -43.28 | 0.231713 / -34.51 |
| video1_ive_blackhole | scene_0002 | tune | HLG | 0.2153 | 0.315383 / -32.36 | 0.401078 / -43.82 | 0.368785 / -34.81 |
| video1_ive_blackhole | scene_0003 | tune | HLG | 0.2279 | 0.308796 / -31.66 | 0.395628 / -43.04 | 0.364918 / -33.93 |
| video1_ive_blackhole | scene_0004 | tune | HLG | 0.2527 | 0.333833 / -33.16 | 0.423399 / -44.85 | 0.391233 / -35.55 |
| video1_ive_blackhole | scene_0005 | tune | HLG | 0.2822 | 0.288272 / -40.05 | 0.380091 / -52.32 | 0.348000 / -42.96 |
| video1_ive_blackhole | scene_0006 | tune | HLG | 0.2421 | 0.333250 / -33.53 | 0.421379 / -45.14 | 0.391710 / -35.93 |
| video1_ive_blackhole | scene_0007 | tune | HLG | 0.1091 | 0.244377 / -27.81 | 0.322015 / -37.36 | 0.261025 / -28.74 |
| video1_ive_blackhole | scene_0008 | tune | HLG | 0.2506 | 0.320080 / -33.90 | 0.410266 / -45.47 | 0.379200 / -36.39 |
| video1_ive_blackhole | scene_0009 | tune | HLG | 0.2096 | 0.327375 / -31.83 | 0.414733 / -43.07 | 0.381248 / -34.16 |
| video1_ive_blackhole | scene_0010 | tune | HLG | 0.3301 | 0.268509 / -35.63 | 0.365610 / -47.93 | 0.337872 / -38.70 |
| video1_ive_blackhole | scene_0011 | tune | HLG | 0.2138 | 0.332569 / -32.08 | 0.415826 / -43.47 | 0.381336 / -34.38 |
| video1_ive_blackhole | scene_0012 | tune | HLG | 0.3615 | 0.250569 / -35.49 | 0.345185 / -47.87 | 0.312614 / -38.67 |
| video1_ive_blackhole | scene_0013 | tune | HLG | 0.2425 | 0.335833 / -35.11 | 0.422773 / -46.97 | 0.393211 / -37.93 |
| video1_ive_blackhole | scene_0014 | tune | HLG | 0.1674 | 0.287122 / -30.58 | 0.369317 / -41.54 | 0.332687 / -32.47 |
| video1_ive_blackhole | scene_0015 | tune | HLG | 0.1988 | 0.319404 / -28.74 | 0.404702 / -39.69 | 0.359267 / -30.68 |
| video1_ive_blackhole | scene_0016 | tune | HLG | 0.2603 | 0.322727 / -33.97 | 0.414123 / -45.70 | 0.381167 / -36.59 |
| video1_ive_blackhole | scene_0017 | tune | HLG | 0.1886 | 0.340081 / -30.48 | 0.422975 / -41.71 | 0.388014 / -32.50 |
| video1_ive_blackhole | scene_0018 | tune | HLG | 0.3606 | 0.265206 / -39.42 | 0.364978 / -52.62 | 0.334113 / -43.50 |
| video1_ive_blackhole | scene_0019 | tune | HLG | 0.2863 | 0.348054 / -35.03 | 0.432864 / -46.99 | 0.408602 / -37.81 |
| video1_ive_blackhole | scene_0020 | tune | HLG | 0.2370 | 0.321495 / -33.29 | 0.404395 / -45.02 | 0.378574 / -36.02 |
| video1_ive_blackhole | scene_0021 | tune | HLG | 0.7942 | 0.027272 / -45.89 | 0.050067 / -60.05 | 0.049300 / -49.77 |
| video1_ive_blackhole | scene_0022 | tune | HLG | 0.7513 | 0.116570 / -13.92 | 0.134783 / -26.81 | 0.133086 / -18.41 |
| video2_newjeans_new_jeans | scene_0001 | tune | HLG | 0.3030 | 0.304275 / -35.06 | 0.405228 / -46.54 | 0.363026 / -37.34 |
| video2_newjeans_new_jeans | scene_0002 | tune | HLG | 0.8470 | 0.032110 / -64.28 | 0.038120 / -80.33 | 0.037692 / -73.19 |
| video2_newjeans_new_jeans | scene_0003 | tune | HLG | 0.8223 | 0.070864 / -44.17 | 0.106886 / -57.41 | 0.105480 / -45.50 |
| video2_newjeans_new_jeans | scene_0004 | tune | HLG | 0.7810 | 0.109410 / -8.40 | 0.148684 / -21.85 | 0.148991 / -13.14 |
| video2_newjeans_new_jeans | scene_0005 | tune | HLG | 0.7497 | 0.113358 / -11.71 | 0.130850 / -24.53 | 0.129538 / -15.97 |
| video3_newjeans_how_sweet | scene_0001 | tune | HLG | 0.3562 | 0.255363 / -36.61 | 0.344277 / -48.61 | 0.313169 / -39.42 |
| video3_newjeans_how_sweet | scene_0002 | tune | HLG | 0.7946 | 0.026743 / -51.13 | 0.048313 / -65.61 | 0.047588 / -55.73 |
| video3_newjeans_how_sweet | scene_0003 | tune | HLG | 0.7510 | 0.112741 / -13.30 | 0.131078 / -26.33 | 0.129809 / -17.61 |
| video4_aespa_lemonade | scene_0001 | validation | HLG | 0.2237 | 0.307386 / -29.76 | 0.384316 / -40.88 | 0.357876 / -31.90 |
| video4_aespa_lemonade | scene_0002 | validation | HLG | 0.2033 | 0.307272 / -29.99 | 0.388534 / -41.20 | 0.358378 / -32.26 |
| video4_aespa_lemonade | scene_0003 | validation | HLG | 0.2771 | 0.244340 / -35.56 | 0.324486 / -47.84 | 0.303141 / -39.03 |
| video4_aespa_lemonade | scene_0004 | validation | HLG | 0.2381 | 0.290548 / -29.69 | 0.364972 / -40.83 | 0.339283 / -31.70 |
| video4_aespa_lemonade | scene_0005 | validation | HLG | 0.2749 | 0.240790 / -32.92 | 0.314817 / -44.88 | 0.293439 / -35.58 |
| video4_aespa_lemonade | scene_0006 | validation | HLG | 0.2317 | 0.306285 / -29.85 | 0.383686 / -40.99 | 0.356311 / -31.96 |
| video4_aespa_lemonade | scene_0007 | validation | HLG | 0.7608 | 0.090523 / -18.35 | 0.111323 / -31.86 | 0.110661 / -22.74 |

Representative opposing responses are visible in the table: PQ live_13_interview has V4 diffuse signed error +17.41 nits and NO_LOWMID +5.17, while HLG video1_ive_blackhole/scene_0001 has V4 -33.96 and NO_LOWMID -43.28. Removing low-mid moves the PQ scene toward zero but moves the HLG scene farther below its reference.

## 8. PQ vs HLG

| Split | Transfer | Samples | Candidate | Official objective | Highlight error | Shadow error | Diffuse signed mean | Diffuse MAE | Over ratio |
|---|---|---:|---|---:|---:|---:|---:|---:|---:|
| tune | HLG | 78336 | V2 | 0.204242 | 0.252067 | 0.358655 | -36.40 | 36.51 | 0.004 |
| tune | HLG | 78336 | V4 | 0.183272 | 0.229792 | 0.297620 | -33.93 | 34.06 | 0.006 |
| tune | HLG | 78336 | NO_LOWMID | 0.237861 | 0.308370 | 0.343512 | -45.57 | 45.64 | 0.002 |
| tune | HLG | 78336 | BL045 | 0.220083 | 0.302987 | 0.330849 | -36.44 | 36.56 | 0.006 |
| tune | PQ | 9216 | V2 | 0.454137 | 0.174347 | 1.265408 | 13.13 | 15.92 | 0.932 |
| tune | PQ | 9216 | V4 | 0.422886 | 0.178496 | 1.152738 | 15.62 | 17.96 | 0.945 |
| tune | PQ | 9216 | NO_LOWMID | 0.419883 | 0.193715 | 1.152302 | 3.90 | 9.61 | 0.822 |
| tune | PQ | 9216 | BL045 | 0.435725 | 0.192997 | 1.152738 | 12.26 | 16.51 | 0.890 |
| validation | HLG | 24192 | V2 | 0.299579 | 0.336264 | 0.565351 | -32.43 | 32.45 | 0.003 |
| validation | HLG | 24192 | V4 | 0.258144 | 0.280631 | 0.462525 | -30.05 | 30.08 | 0.006 |
| validation | HLG | 24192 | NO_LOWMID | 0.327299 | 0.389573 | 0.471949 | -41.27 | 41.28 | 0.000 |
| validation | HLG | 24192 | BL045 | 0.304971 | 0.389549 | 0.474139 | -32.25 | 32.28 | 0.006 |
| validation | PQ | 9216 | V2 | 0.505617 | 0.248627 | 1.222472 | 2.52 | 17.39 | 0.794 |
| validation | PQ | 9216 | V4 | 0.476296 | 0.255669 | 1.112511 | 4.97 | 18.50 | 0.810 |
| validation | PQ | 9216 | NO_LOWMID | 0.456280 | 0.207874 | 1.112049 | -6.55 | 14.47 | 0.683 |
| validation | PQ | 9216 | BL045 | 0.488709 | 0.269517 | 1.112511 | 2.25 | 19.17 | 0.775 |

HLG benefits from retaining V4 low-mid lift: V4 improves the HLG Tune objective from 0.204242 to 0.183272 and the HLG Validation objective from 0.299579 to 0.258144, while NO_LOWMID worsens them to 0.237861 and 0.327299. PQ behaves differently: on PQ Validation, NO_LOWMID is best (0.456280), V4 is 0.476296, and BL045 is 0.488709; V4's diffuse signed mean is positive (+4.97 nits). This transfer conflict is the strongest evidence for GLOBAL_CURVE_LIMITATION.

## 9. Scene-Anchor Correlation

The paired attribution runner uses evaluateSpatiallyIndependent, which intentionally disables evolving causal state so each sample can be compared independently. Consequently all samples in this run use the neutral scene state: sceneShadowFloor = 0.0100, sceneShadowTop = 0.1125, and sceneStatisticsValid = false. shadowTop, shadowFloor, and temporal adaptation have zero variance; their correlations are therefore not estimable, rather than zero in the causal runtime.

This run does not establish or reject SCENE_CONDITIONING_ERROR. A follow-up must use a sequential runtime/replay path that records the actual scene statistics and frame-to-frame anchor changes. No production temporal or scene estimator was changed here.

## 10. LowMid Strength Response

This is an offline scalar diagnostic, not a new candidate or production preset. The coefficient scales are 0.00, 0.25, 0.50, 0.75, 1.00, corresponding to effective coefficients 0.000, 0.020, 0.040, 0.060, 0.080; all other V4 terms are held fixed.

| Split | Scale | Effective coefficient | Tone-only objective | Diffuse mean signed error | Highlight error | Shadow error |
|---|---:|---:|---:|---:|---:|---:|
| tune | 0.00 | 0.000 | 0.243374 | -42.82 | 0.119663 | 0.680694 |
| tune | 0.25 | 0.020 | 0.230754 | -39.90 | 0.102287 | 0.681056 |
| tune | 0.50 | 0.040 | 0.218692 | -36.99 | 0.085481 | 0.681416 |
| tune | 0.75 | 0.060 | 0.207160 | -34.08 | 0.069248 | 0.681774 |
| tune | 1.00 | 0.080 | 0.196095 | -31.17 | 0.053431 | 0.682130 |
| validation | 0.00 | 0.000 | 0.340371 | -33.13 | 0.158527 | 1.055101 |
| validation | 0.25 | 0.020 | 0.328875 | -30.31 | 0.140115 | 1.055211 |
| validation | 0.50 | 0.040 | 0.317863 | -27.49 | 0.122083 | 1.055321 |
| validation | 0.75 | 0.060 | 0.307292 | -24.66 | 0.104431 | 1.055432 |
| validation | 1.00 | 0.080 | 0.297129 | -21.84 | 0.087120 | 1.055542 |

On the aggregate Tune and Validation sets, increasing the coefficient monotonically lowers the scalar tone-only objective and moves the diffuse signed error upward from under-prediction toward the reference. This rejects LOWMID_STRENGTH_TOO_HIGH as a global classification. The scene response is contradictory: PQ live_22 prefers coefficient 0.000, PQ live_9 has a shallow minimum around 0.040, PQ live_13 prefers the low end, while PQ live_4_campfire improves toward 0.080; the HLG scenes predominantly improve as the coefficient increases. The right conclusion is transfer/content-conditioned response, not a single strength optimum.

## 11. Validation +0.023884 Decomposition

The official V2 objective engine reports V4 Validation objective 0.403578742, BL045 0.427462828, and delta +0.023884086. The component deltas sum exactly to the reported delta. The two largest positive terms, diffuse_white and highlight, account for 75.8% of the increase.

| Objective component | BL045 delta | NO_LOWMID delta |
|---|---:|---:|
| diffuse_white | +0.009902309 | +0.004595247 |
| highlight | +0.008196860 | +0.000801162 |
| luminance | +0.003262696 | +0.001451616 |
| midtone | +0.001551396 | +0.000839112 |
| shadow | +0.000580680 | +0.000425029 |
| structure | +0.000145509 | +0.001386698 |
| temporal | +0.000133806 | +0.000105778 |
| absolute_nits | +0.000122603 | +0.000122794 |
| chroma | +0.000019468 | +0.000099740 |
| saturation | -0.000030061 | -0.000132147 |
| hue | -0.000001178 | -0.000008751 |
| penalty_black_crush | +0.000000000 | +0.000000000 |
| penalty_clipping | +0.000000000 | +0.000000000 |
| penalty_invalid | +0.000000000 | +0.000000000 |
| penalty_saturation | +0.000000000 | +0.000021701 |
| **sum** | **+0.023884086** | **+0.009707980** |

NO_LOWMID's Validation delta is +0.009707980; its largest cost is diffuse_white (+0.004595247), followed by luminance (+0.001451616) and structure (+0.001386698). BL045's larger penalty comes primarily from diffuse_white (+0.009902309) and highlight (+0.008196860), with luminance (+0.003262696) and midtone (+0.001551396) next. Thus BL045 worsened is an objective-component statement, not evidence that it created a signed diffuse overshoot.

## 12. Diffuse Metric Audit

The existing diffuse metric remains in the official objective and uses a generic source-luminance region from the existing V2 metrics evaluator. It is a luminance-domain metric with existing absolute/log weighting and scene weighting; it contains no face or skin detector. It does not use V2 as ground truth.

The previous diffuse improvement = NONE result was insufficient for attribution because an absolute metric combines positive overshoot and negative undershoot. V6.1 retains that metric and adds a signed companion with separate positive and negative means, direction ratios, percentiles, MAE, RMSE, and signed log error. The signed data shows why: PQ diffuse samples are net positive while HLG diffuse samples are strongly negative, so a pooled absolute score cannot describe the direction of the error.

A source-domain defect was also corrected before this final run: the existing frame-matching lumaGrid is an encoded-Y proxy, while the V4 shader operates on linear luminance. V6.1 attribution bins and scalar response now use the observation-only exact linear conversion. No production estimator or official objective arithmetic was modified by that correction.

## 13. Root-Cause Classification

**Primary: GLOBAL_CURVE_LIMITATION.** PQ and HLG require opposite low-mid responses, and scene-level coefficient curves also oppose one another. A fixed global support/strength rule cannot satisfy both directions without additional conditioning or a different target formulation.

**Secondary: METRIC_MISMATCH.** The prior pooled absolute diffuse result did not preserve signed direction. It could identify magnitude but not distinguish V4 is still under reference from V4 is over reference. The signed companion resolves that ambiguity.

**Conditional only: LOWMID_STRENGTH_TOO_HIGH in PQ subsets.** PQ Validation and several PQ scenes improve when the coefficient is reduced. This is real but does not generalize to HLG or the aggregate Tune/Validation response, so it is not the global diagnosis.

**Not confirmed: LOWMID_SUPPORT_WRONG.** BL045 reduced the term but did not improve the paired objective and worsened HLG diffuse error. **Not primary: LOWMID_SHOULDER_OVERLAP.** Overlap exists above Y approximately 0.50, but the selected diffuse interval has zero shoulder contribution and remains under reference. **Not estimable here: SCENE_CONDITIONING_ERROR.** The independent spatial path has constant neutral anchors; sequential runtime evidence is still required.

Face-specific attribution remains **NOT CONFIRMED** because test6.mp4 is absent. The evidence supports a generic transfer/content-conditioned error conclusion and must not be presented as a skin-specific finding.

## 14. What NOT To Change

- Do not change calibrated V4 values, sceneRelativeV4, or existing V4 shader arithmetic.
- Do not add skin/face detection, a skin LUT, or a skin-specific heuristic.
- Do not change temporal stability, scene-cut behavior, shoulder arithmetic, or the production estimator in this attribution stage.
- Do not open Frozen, Virgin Frozen, or sealed holdout media; do not promote a V6 preset or change the default.
- Do not treat V2 as a target or substitute test6 with another clip for face attribution.

## 15. Recommended V6.2 Candidate Family

No V6.2 candidate was implemented. The next development family should be defined around the measured problem:

1. Use transfer-aware or reference-conditioned response evaluation, because PQ and HLG have opposite signed diffuse directions.
2. Preserve separate low-mid and highlight terms, and require a signed diffuse gate in addition to the existing absolute objective so a candidate cannot hide under/over errors through pooling.
3. Evaluate any support function against the full source distribution and per-scene response, rather than selecting a global support position from one clip or from V4-versus-V2 brightness.
4. Add a sequential replay for actual scene anchors and temporal adaptation before attributing any remaining pumping or anchor-conditioning error.
5. Keep near-black and highlight constraints as hard regression gates and leave production promotion for the separate holdout stage.

These are design preconditions only. No tone-curve formula, coefficient, strength, or production preset was changed in V6.1.

## 16. Frozen Status

- Frozen accessed: **NO**
- Virgin Frozen accessed: **NO**
- Sealed V6 holdout accessed: **NO**
- Protected objective evaluations: **0**
- Objective evaluations outside allowed Tune/Validation splits: **0**
- Tune/Validation diagnostic pairs: **8**
- Tune/Validation diagnostic scenes: **41**

## 17. Verification

- Final attribution command: HDRCalibrate v6-1-attribution with the visual-regression manifest and output /tmp/v6.1-error-attribution-linear.json.
- Final attribution result: completed; skippedPairs=[]; output commit field is d97c3d3c8fbf71447ff8b94a7fa7a77c5d25bebf.
- Verification: swift test -c debug --disable-index-store passed (185 executed, 0 failures, 5 fixture/environment skips); swift build -c release --disable-index-store passed; git diff --check passed.
- The report JSON records protectedMediaAccessed=false, frozenObjectiveEvaluations=0, and virginFrozenObjectiveEvaluations=0.
- Runtime production performance was not re-benchmarked in this offline-only stage. No V4 production arithmetic was changed in V6.1; the worktree still contains the pre-existing development-only sceneRelativeV6Candidate branch and observation instrumentation from the earlier V6 stage. Existing V6 development benchmarks remain the applicable runtime baseline.
- RUN_MACOS_VERIFY.sh fast was not run because its holdout/result workflow is outside this stage's allowed media scope.

## 18. Git State

The worktree retains the pre-existing V4.1/V6 development changes and the new V6.1 attribution/report changes. No destructive cleanup, reset, or stash operation was used. No checkpoint commit was created because the dirty set contains mixed pre-existing and current development files that cannot be separated safely without risking user work.

- HEAD: d97c3d3c8fbf71447ff8b94a7fa7a77c5d25bebf
- git diff --stat at completion: 21 tracked files, 2,672 insertions, 123 deletions; untracked files are not included in that stat.
- git log -3: d97c3d3 feat(hdr): promote calibrated V4 preset; c714704 Merge remote-tracking branch origin/main into v4-production-release; 4c710e1 feat(hdr): promote calibrated V4 preset.
- Final git diff --check: PASS.

Analysis source: /tmp/v6.1-error-attribution-linear.json (temporary diagnostic output; no video or protected artifact was copied into the repository).
