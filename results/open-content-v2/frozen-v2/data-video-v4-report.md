# SDR to HDR Calibrated V4

Verdict: PROMOTE_CALIBRATED_V4

## Protocol

- Manifest: repo:data_video/open-content-v2/manifest.json
- Split seed: 92
- Search seed: 20260824
- Global/local candidates: 128/64
- Aggregation: video to content-family balanced mean
- Virgin Frozen: sealed until candidate, code, manifest and objective hashes were frozen; opened once after selection.

## V2 vs V4

| Split | V2 objective | V4 objective | V2 shadow | V4 shadow | V2 shadow lift | V4 shadow lift |
|---|---:|---:|---:|---:|---:|---:|
| Tune | 0.293262 | 0.194426 | 0.510650 | 0.224809 | 0.231225 | 0.134070 |
| Validation | 0.378600 | 0.275119 | 0.943596 | 0.543287 | 0.481029 | 0.391432 |
| Virgin Frozen | 0.368019 | 0.283117 | 0.614997 | 0.451890 | 0.994215 | 0.993854 |

## Selected parameters

CalibrationParameters(paperWhiteNits: 203.30556, peakNits: 1408.8245, highlightStrength: 0.86, contrastStrength: 0.8019736, saturationCompensation: 0.4161492, shadowProtection: 0.7381159, temporalStability: 0.48427606, displayHeadroom: 6.9295917, toneCurveRevision: Optional(2), v6LowMidFadePosition: nil, v6LowMidStrength: nil, sdrTransferInterpretation: nil, declaredSourceSDRTransferInterpretation: Optional("youtube-hlg-sdr-inverse-17knot-v1"))

## Decision

- Tune V4 vs V2: 33.70%
- Validation V4 vs V2: 27.33%
- Virgin Frozen V4 vs V2: 23.07%
- Virgin Frozen shadow V2=0.614997 V4=0.451890
- Promotion gates: completeness=PASS, transfer=PASS, family=PASS, runtime=PASS
- runtime within tolerance: GPU p50 0.521→0.497 ms, GPU p95 0.892→0.849 ms, CPU p95 0.053→0.052 ms
- Final verdict gate: PROMOTE_CALIBRATED_V4

## Worst pairs (reported, not gating)

| Pair | Split | Candidate / V2 | Candidate / default |
|---|---|---:|---:|
| aswf_stem2_t450 | validation | 1.044 | 1.048 |
| netflix_sollevante_t090 | tune | 0.964 | 0.886 |
| netflix_sollevante_t030 | tune | 0.957 | 0.916 |
| netflix_sparks_f02067 | validation | 0.921 | 0.921 |
| netflix_sparks_f06200 | validation | 0.914 | 0.914 |

## Limitations

- Virgin Frozen metrics were opened once only after candidate, code, manifest and objective hashes were frozen.
- The 4 Virgin Frozen pairs are a small holdout; family/transfer confidence intervals are limited.
- Reference HDR creative grading and SDR information loss are not recoverable detail ground truth.
- Runtime scene statistics use a 16x9, 64-bin causal GPU estimator; offline uses the same one-frame-late state transition.