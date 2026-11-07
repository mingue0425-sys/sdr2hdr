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
| Tune | 0.291556 | 0.268587 | 0.515665 | 0.413506 | 0.220201 | 0.099698 |
| Validation | 0.382102 | 0.348533 | 0.959874 | 0.823389 | 0.508790 | 0.401654 |
| Virgin Frozen | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED |

## Selected parameters

CalibrationParameters(paperWhiteNits: 192.57812, peakNits: 1018.5185, highlightStrength: 0.75792, contrastStrength: 0.9408163, saturationCompensation: 0.2586777, shadowProtection: 0.7245562, temporalStability: 0.8477509, displayHeadroom: 5.288859, toneCurveRevision: Optional(2), v6LowMidFadePosition: nil, v6LowMidStrength: nil, sdrTransferInterpretation: nil)

## Decision

- stopped before Virgin Frozen on request (--stop-before-frozen): Tune search and Validation selection only; every pre-Frozen gate passed; Virgin Frozen stays sealed

## Limitations

- Virgin Frozen remained sealed because V4 preconditions were not satisfied.