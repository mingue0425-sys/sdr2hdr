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
| Tune | 0.313186 | 0.288820 | 0.385293 | 0.342961 | 0.154407 | 0.133141 |
| Validation | 0.413634 | 0.384870 | 0.949020 | 0.857487 | 0.606199 | 0.503344 |
| Virgin Frozen | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED |

## Selected parameters

CalibrationParameters(paperWhiteNits: 194.29688, peakNits: 1196.2963, highlightStrength: 0.47632, contrastStrength: 0.86734694, saturationCompensation: 0.3644628, shadowProtection: 0.13994083, temporalStability: 0.48069203, displayHeadroom: 6.1570535, toneCurveRevision: Optional(2), v6LowMidFadePosition: nil, v6LowMidStrength: nil, sdrTransferInterpretation: nil)

## Decision

- pre-Frozen gate failed before Virgin Frozen access: leaveOneFamilyOut=FAIL

## Limitations

- Virgin Frozen remained sealed because V4 preconditions were not satisfied.