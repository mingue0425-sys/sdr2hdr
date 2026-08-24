# Dataset V4 audit

- Manifest: `/Volumes/game/sdr2hdr/data_video/manifest-v4.json`
- Manifest SHA-256: `95309c20d38b1ec0e292409c095f7ca62d5fe45e46c0fe05b2618d3b0b173474`
- Audit evidence version: `dataset-v4-audit-v2`
- Audit configuration SHA-256: `18a10e54889115cef739af5f129fe0467ae9b298353187bfea5599ee2da61b23`
- Objective evaluation: `NO`
- Frozen objective IDs: `NONE`
- Verdict: `DATASET_V4_READY`

## Pair summary

| ID | Split | Virgin frozen | HDR transfer | Status | Suitability | Median confidence | ≥0.70 | Notes |
|---|---|---:|---|---|---|---:|---:|---|
| video1_ive_blackhole | tune | NO | HLG | ACCEPTED | MAIN_CALIBRATION | 0.891 | 100.0% | objective evaluation is forbidden in dataset-audit |
| video2_newjeans_new_jeans | tune | NO | HLG | ACCEPTED | MAIN_CALIBRATION | 0.870 | 100.0% | objective evaluation is forbidden in dataset-audit |
| video3_newjeans_how_sweet | tune | NO | HLG | ACCEPTED | MAIN_CALIBRATION | 0.876 | 100.0% | objective evaluation is forbidden in dataset-audit |
| video4_aespa_lemonade | validation | NO | HLG | ACCEPTED | MAIN_CALIBRATION | 0.908 | 100.0% | objective evaluation is forbidden in dataset-audit |
| video6_le_sserafim_hot | frozen | NO | HLG | ACCEPTED | MAIN_CALIBRATION | 0.909 | 100.0% | objective evaluation is forbidden in dataset-audit |
| solemates_unh0400_0010 | frozen | YES | PQ | ACCEPTED | MAIN_CALIBRATION | 0.828 | 100.0% | objective evaluation is forbidden in dataset-audit; SDR BT.709 transfer/primaries supplied by source-documented manifest fallback |
| live_8_drawing_3840x2160_15000k | frozen | YES | PQ | ACCEPTED | MAIN_CALIBRATION | 0.733 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_16_night_biking_3840x2160_15000k | frozen | YES | PQ | ACCEPTED | MAIN_CALIBRATION | 0.901 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_22_programming_night_3840x2160_15000k | validation | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.923 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_4_campfire_3840x2160_15000k | validation | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.872 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_9_face_close_3840x2160_15000k | tune | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.813 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_13_interview_3840x2160_15000k | tune | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.868 | 100.0% | objective evaluation is forbidden in dataset-audit |

## Diversity

- Total: 12; main: 12; conditional: 0; rejected: 0
- Splits: tune=5, validation=3, frozen=4, virgin frozen=3
- HDR transfers: ["PQ": 7, "HLG": 5]
- Content families: ["SoleMates": 1, "LIVE": 6, "K-Choreo": 5]
- Categories: ["low-contrast": 6, "low-key": 5, "high-key": 5, "low-saturation": 1, "cinematic": 1, "outdoor": 1, "shadow-rich": 3, "highlight-rich": 2, "animation": 1, "night": 3, "high-contrast": 8, "dance": 5, "indoor": 4, "skin": 7, "saturated": 5]

## Guardrails

- This command performs manifest, integrity, metadata, decode-smoke, spatial and temporal alignment checks only.
- No baseline, candidate, validation or frozen objective was evaluated.
- Virgin frozen media may be inspected for integrity/alignment but remains unavailable to calibration runners.