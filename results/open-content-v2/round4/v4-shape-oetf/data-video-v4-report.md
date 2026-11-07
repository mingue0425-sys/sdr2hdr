# SDR to HDR Calibrated V4

Verdict: INCOMPLETE_EVALUATION

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
| Tune | 0.287309 | 0.263292 | 0.494307 | 0.393088 | 0.215577 | 0.099393 |
| Validation | 0.380272 | 0.342988 | 0.949099 | 0.810815 | 0.485356 | 0.394919 |
| Virgin Frozen | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED |

## Selected parameters

CalibrationParameters(paperWhiteNits: 192.57812, peakNits: 1018.5185, highlightStrength: 0.75792, contrastStrength: 0.9408163, saturationCompensation: 0.2586777, shadowProtection: 0.7245562, temporalStability: 0.8477509, displayHeadroom: 5.288859, toneCurveRevision: Optional(2), v6LowMidFadePosition: nil, v6LowMidStrength: nil, sdrTransferInterpretation: nil, declaredSourceSDRTransferInterpretation: nil)

## Decision

- stopped before Virgin Frozen on request (--stop-before-frozen): Tune search and Validation selection only; every pre-Frozen gate passed; Virgin Frozen stays sealed

## Worst pairs (reported, not gating)

| Pair | Split | Candidate / V2 | Candidate / default |
|---|---|---:|---:|
| video3_newjeans_how_sweet | tune | 1.141 | 1.413 |
| kbs_zWpnFNYlggE | tune | 0.983 | 1.103 |
| kbs_fPWoqFuf6OI | tune | 0.982 | 1.030 |
| kbs_ivDC7Kh8l4g | validation | 0.978 | 0.988 |
| kbs_9AUdaAiXoXA | tune | 0.971 | 0.991 |

## Limitations

- Virgin Frozen remained sealed because V4 preconditions were not satisfied.