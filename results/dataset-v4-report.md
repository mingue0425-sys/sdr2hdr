# Dataset V4 audit

- Manifest: `repo:data_video/manifest-v4.json`
- Manifest SHA-256: `50fb0bc20f3f0d78b9d2d3ff6cf400fbb3d1c37aba48013aaf45b6e107f23243`
- Audit evidence version: `dataset-v4-audit-v3`
- Audit configuration SHA-256: `1b3162e53d632c26b4281deeb9e63b2ae1932657d8f7d3659d56ffd8336fe638`
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
| dvb_live_linear_caminandes_hevc_uhd_sdr_hlg | frozen | YES | HLG | ACCEPTED | MAIN_CALIBRATION | 0.996 | 100.0% | objective evaluation is forbidden in dataset-audit; HDR colour identity (HLG) verified from hash-bound decoded-keyframe Virgin evidence |
| live_8_drawing_3840x2160_15000k | frozen | YES | PQ | ACCEPTED | MAIN_CALIBRATION | 0.733 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_16_night_biking_3840x2160_15000k | frozen | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.901 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_22_programming_night_3840x2160_15000k | validation | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.922 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_4_campfire_3840x2160_15000k | validation | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.872 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_9_face_close_3840x2160_15000k | tune | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.813 | 100.0% | objective evaluation is forbidden in dataset-audit |
| live_13_interview_3840x2160_15000k | tune | NO | PQ | ACCEPTED | MAIN_CALIBRATION | 0.868 | 100.0% | objective evaluation is forbidden in dataset-audit |
| v6_kbs_dirty_work_hlg | frozen | YES | HLG | ACCEPTED | MAIN_CALIBRATION | 0.866 | 100.0% | objective evaluation is forbidden in dataset-audit; HDR colour identity (HLG) verified from hash-bound decoded-keyframe Virgin evidence |
| v6_live_2_basketball_evening_pq | frozen | YES | PQ | ACCEPTED | MAIN_CALIBRATION | 0.849 | 100.0% | objective evaluation is forbidden in dataset-audit; HDR colour identity (PQ) verified from hash-bound decoded-keyframe Virgin evidence |
| v6_live_3_cafe_pq | frozen | YES | PQ | ACCEPTED | MAIN_CALIBRATION | 0.839 | 100.0% | objective evaluation is forbidden in dataset-audit; HDR colour identity (PQ) verified from hash-bound decoded-keyframe Virgin evidence |

## Diversity

- Total: 16; main: 16; conditional: 0; rejected: 0
- Splits: tune=5, validation=3, frozen=8, virgin frozen=6
- HDR transfers: ["PQ": 9, "HLG": 7]
- Content families: ["DVB Live-Linear": 1, "K-Choreo": 6, "SoleMates": 1, "LIVE": 8]
- Categories: ["shadow-rich": 3, "indoor": 5, "saturated": 6, "night": 3, "cinematic": 2, "animation": 2, "high-key": 5, "low-key": 6, "low-saturation": 1, "skin": 8, "natural": 1, "high-contrast": 10, "dance": 6, "low-contrast": 6, "outdoor": 3, "highlight-rich": 2]

## Guardrails

- This command performs manifest, integrity, metadata, decode-smoke, spatial and temporal alignment checks only.
- No baseline, candidate, validation or frozen objective was evaluated.
- Virgin frozen media may be inspected for integrity/alignment but remains unavailable to calibration runners.