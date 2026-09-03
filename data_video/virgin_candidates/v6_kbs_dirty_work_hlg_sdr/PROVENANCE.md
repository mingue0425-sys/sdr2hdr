# V6 Virgin Frozen candidate provenance

- Provider: KBS Kpop
- Content family: K-Choreo
- Source/video ID: `iSEvfuJO0hQ`
- Expected relation: `same-master`
- Source formats: format 642 = HLG; format 628 = SDR
- Candidate directory: `data_video/virgin_candidates/v6_kbs_dirty_work_hlg_sdr/`

## Selection boundary

The pair was selected and preregistered from metadata only before frame inspection. The objective evaluation count remains **0**. No HDRCore objective evaluation was invoked, and the pair is marked unconsumed.

## Audited media

| Asset | SHA-256 | Full-file ffmpeg decode | Full-frame count |
| --- | --- | --- | ---: |
| `KBS_DirtyWork_HLG.mp4` | `c6ad60310e208f46e2fe4e520fadad5bfa0b0ba2af1108f1c425ef10d82028a8` | exit 0; stderr empty | 12,072 |
| `KBS_DirtyWork_SDR.mp4` | `8d86b7911463b60b4538b3a44ebc093f44aec534685091b1cbdd530d26a9de23` | exit 0; stderr empty | 12,072 |

The full-frame counts were obtained with `ffprobe -count_frames` over the complete video stream after the independent full-file ffmpeg decode. Counts are positive and exactly equal.

## Stream metadata

- SDR: VP9 Profile 0; 3840x2026; `yuv420p`; BT.709 primaries/transfer/matrix; nominal `60000/1001`; duration `201.400000` seconds.
- HLG: VP9 Profile 2; 3840x2026; `yuv420p10le`; BT.2020 primaries; ARIB STD-B67 transfer; BT.2020nc matrix; nominal `60000/1001`; duration `201.400000` seconds; 10-bit pixel format.

## Structural alignment

- Windows: 5 x 8 frames; sampled frames: 40; matched frames: 40
- Match ratio: `1.000000`
- p10 confidence: `0.974292`
- Median confidence: `0.977728`
- Maximum absolute offset: `0.000000` seconds
- Offset spread: `0.000000` seconds
- Status: `ALIGNED`

## Evidence and registration status

- Evidence manifest: `VIRGIN_PAIR_VALID.json`
- Evidence manifest SHA-256: `eeace152cef90e1452391ec3a23fbe4eb4d41967458d8013b128a2cfbe1203ce`
- Verdict: `PAIR_VALID_VIRGIN`
- Registered in `data_video/manifest-v4.json` as `v6_kbs_dirty_work_hlg` with
  `split=frozen`, `virginFrozen=true`, `objectiveEvaluated=false`, and
  `consumed=false`.
- Redistribution and license status must be reviewed separately before distribution.
