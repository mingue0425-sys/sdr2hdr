# SDR to HDR Calibrated V4

Verdict: VALIDATION_FAIL

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
| Tune | 0.286905 | NOT MEASURED | 0.492780 | NOT MEASURED | 0.211052 | NOT MEASURED |
| Validation | 0.376821 | NOT MEASURED | 0.937714 | NOT MEASURED | 0.489506 | NOT MEASURED |
| Virgin Frozen | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED |

## Selected parameters

NOT SELECTED

## Decision

- No global V4 candidate passed Tune safety gates

## Limitations

- Virgin Frozen remained sealed because V4 preconditions were not satisfied.