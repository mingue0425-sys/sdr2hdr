# Dataset V4 audit

- Manifest: `repo:data_video/manifest-v4.json`
- Manifest SHA-256: `0dd4a9b84796effb10f708a572d400559523a0524b6407b45047aaa3767b39be`
- Audit evidence version: `dataset-v4-audit-v3`
- Audit configuration SHA-256: `234b727337d85cc4142d5ac6bc88648b7563b5d8b2ad68f6cfc611500d332ec6`
- Objective evaluation: `NO`
- Frozen objective IDs: `NONE`
- Structural dataset verdict: `DATASET_V4_READY`
- Readiness scope: `DATASET_INTEGRITY_ONLY`; Pre-V6 holdout readiness is evaluated separately by `correctness-review`.

## Pair summary

| ID | Split | Virgin frozen | HDR transfer | Status | Suitability | Median confidence | ≥0.70 | Notes |
|---|---|---:|---|---|---|---:|---:|---|
| video1_ive_blackhole | tune | NO | HLG | ACCEPTED | MAIN_CALIBRATION | 0.891 | 100.0% | objective evaluation is forbidden in dataset-audit |
| video2_newjeans_new_jeans | tune | NO | HLG | ACCEPTED | MAIN_CALIBRATION | 0.870 | 100.0% | objective evaluation is forbidden in dataset-audit |
| video3_newjeans_how_sweet | tune | NO | HLG | ACCEPTED | MAIN_CALIBRATION | 0.876 | 100.0% | objective evaluation is forbidden in dataset-audit |
| video4_aespa_lemonade | validation | NO | HLG | ACCEPTED | MAIN_CALIBRATION | 0.908 | 100.0% | objective evaluation is forbidden in dataset-audit |
| video6_le_sserafim_hot | frozen | NO | HLG | ACCEPTED | MAIN_CALIBRATION | 0.909 | 100.0% | objective evaluation is forbidden in dataset-audit |
| solemates_unh0400_0010 | frozen | YES | PQ | ACCEPTED | MAIN_CALIBRATION | 0.828 | 100.0% | objective evaluation is forbidden in dataset-audit; SDR BT.709 transfer/primaries supplied by source-documented manifest fallback |
| dvb_live_linear_caminandes_hevc_uhd_sdr_hlg | frozen | YES | HLG | ACCEPTED | MAIN_CALIBRATION | 0.996 | 100.0% | objective evaluation is forbidden in dataset-audit; HDR colour identity verified from hash-bound decoded-keyframe Virgin evidence |
| live_8_drawing_3840x2160_15000k | frozen | YES | PQ | ACCEPTED | MAIN_CALIBRATION | 0.733 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_16_night_biking_3840x2160_15000k | frozen | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.901 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_22_programming_night_3840x2160_15000k | validation | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.922 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_4_campfire_3840x2160_15000k | validation | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.872 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_9_face_close_3840x2160_15000k | tune | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.813 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_13_interview_3840x2160_15000k | tune | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.868 | 100.0% | objective evaluation is forbidden in dataset-audit |

## Diversity

- Total: 13; main: 13; conditional: 0; rejected: 0
- Splits: tune=5, validation=3, frozen=5, virgin frozen=3
- HDR transfers: ["HLG": 6, "PQ": 7]
- Content families: ["SoleMates": 1, "LIVE": 6, "K-Choreo": 5, "DVB Live-Linear": 1]
- Categories: ["low-contrast": 6, "high-key": 5, "skin": 7, "animation": 2, "low-key": 5, "outdoor": 2, "night": 3, "dance": 5, "shadow-rich": 3, "saturated": 5, "indoor": 4, "cinematic": 2, "high-contrast": 8, "highlight-rich": 2, "low-saturation": 1]

## Guardrails

- This command performs manifest, integrity, metadata, decode-smoke, spatial and temporal alignment checks only.
- No baseline, candidate, validation or frozen objective was evaluated.
- Virgin frozen media may be inspected for integrity/alignment but remains unavailable to calibration runners.