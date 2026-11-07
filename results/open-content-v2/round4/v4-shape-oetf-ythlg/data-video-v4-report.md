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
| Tune | 0.287309 | 0.191323 | 0.494307 | 0.210702 | 0.215577 | 0.117322 |
| Validation | 0.380272 | 0.276396 | 0.949099 | 0.547635 | 0.485356 | 0.393321 |
| Virgin Frozen | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED | NOT MEASURED |

## Selected parameters

CalibrationParameters(paperWhiteNits: 203.30556, peakNits: 1408.8245, highlightStrength: 0.86, contrastStrength: 0.8019736, saturationCompensation: 0.4161492, shadowProtection: 0.7381159, temporalStability: 0.48427606, displayHeadroom: 6.9295917, toneCurveRevision: Optional(2), v6LowMidFadePosition: nil, v6LowMidStrength: nil, sdrTransferInterpretation: nil, declaredSourceSDRTransferInterpretation: Optional("youtube-hlg-sdr-inverse-17knot-v1"))

## Decision

- stopped before Virgin Frozen on request (--stop-before-frozen): Tune search and Validation selection only; every pre-Frozen gate passed; Virgin Frozen stays sealed

## Worst pairs (reported, not gating)

| Pair | Split | Candidate / V2 | Candidate / default |
|---|---|---:|---:|
| aswf_stem2_t450 | validation | 1.044 | 1.048 |
| netflix_sollevante_t090 | tune | 0.964 | 0.886 |
| netflix_sollevante_t030 | tune | 0.957 | 0.916 |
| netflix_sparks_f02067 | validation | 0.921 | 0.921 |
| netflix_sparks_f06200 | validation | 0.914 | 0.914 |

## Limitations

- Virgin Frozen remained sealed because V4 preconditions were not satisfied.