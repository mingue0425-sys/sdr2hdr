# SDR to HDR Calibrated V4

Verdict: VIRGIN_FROZEN_FAIL

## Protocol

- Manifest: repo:data_video/open-content/manifest.json
- Split seed: 92
- Search seed: 20260824
- Global/local candidates: 128/64
- Aggregation: video to content-family balanced mean
- Virgin Frozen: sealed until candidate, code, manifest and objective hashes were frozen; opened once after selection.

## V2 vs V4

| Split | V2 objective | V4 objective | V2 shadow | V4 shadow | V2 shadow lift | V4 shadow lift |
|---|---:|---:|---:|---:|---:|---:|
| Tune | 0.268417 | 0.240496 | 0.450375 | 0.397697 | 0.231610 | 0.201045 |
| Validation | 0.406502 | 0.385148 | 0.565711 | 0.518226 | 0.409299 | 0.258173 |
| Virgin Frozen | 0.571233 | 0.551369 | 0.693492 | 0.647006 | 0.419740 | 0.353037 |

## Selected parameters

CalibrationParameters(paperWhiteNits: 195.91255, peakNits: 1228.9883, highlightStrength: 0.47476926, contrastStrength: 0.948058, saturationCompensation: 0.48893493, shadowProtection: 0.86584616, temporalStability: 0.55435765, displayHeadroom: 6.273147, toneCurveRevision: Optional(2), v6LowMidFadePosition: nil, v6LowMidStrength: nil, sdrTransferInterpretation: nil)

## Decision

- Tune V4 vs V2: 10.40%
- Validation V4 vs V2: 5.25%
- Virgin Frozen V4 vs V2: 3.48%
- Virgin Frozen shadow V2=0.693492 V4=0.647006
- Promotion gates: completeness=PASS, transfer=PASS, family=PASS, runtime=PASS
- runtime within tolerance: GPU p50 0.489→0.466 ms, GPU p95 0.704→0.674 ms, CPU p95 0.055→0.055 ms
- Final verdict gate: VIRGIN_FROZEN_FAIL

## Limitations

- Virgin Frozen metrics were opened once only after candidate, code, manifest and objective hashes were frozen.
- The three Virgin Frozen pairs are a small holdout; family/transfer confidence intervals are limited.
- Reference HDR creative grading and SDR information loss are not recoverable detail ground truth.
- Runtime scene statistics use a 16x9, 64-bin causal GPU estimator; offline uses the same one-frame-late state transition.