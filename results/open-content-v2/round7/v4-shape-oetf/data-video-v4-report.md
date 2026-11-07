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
| Tune | 0.298268 | 0.261327 | 0.577199 | 0.450583 | 0.217171 | 0.135076 |
| Validation | 0.358607 | 0.323051 | 0.899488 | 0.748514 | 0.462963 | 0.408995 |
| Virgin Frozen | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED |

## Selected parameters

CalibrationParameters(paperWhiteNits: 201.39113, peakNits: 1404.5332, highlightStrength: 0.5947088, contrastStrength: 0.788389, saturationCompensation: 0.33940622, shadowProtection: 0.9187138, temporalStability: 0.80602646, displayHeadroom: 6.9741564, toneCurveRevision: Optional(2), v6LowMidFadePosition: nil, v6LowMidStrength: nil, sdrTransferInterpretation: nil, declaredSourceSDRTransferInterpretation: nil)

## Decision

- stopped before Virgin Frozen on request (--stop-before-frozen): Tune search and Validation selection only; every pre-Frozen gate passed; Virgin Frozen stays sealed

## Worst pairs (reported, not gating)

| Pair | Split | Candidate / V2 | Candidate / default |
|---|---|---:|---:|
| video3_newjeans_how_sweet | tune | 1.146 | 1.420 |
| kbs_ivDC7Kh8l4g | validation | 1.001 | 1.011 |
| kbs_9AUdaAiXoXA | tune | 0.982 | 1.002 |
| kbs_fPWoqFuf6OI | tune | 0.980 | 1.029 |
| kbs_yFTAYXDTjqI | validation | 0.969 | 0.942 |

## Limitations

- Virgin Frozen remained sealed because V4 preconditions were not satisfied.