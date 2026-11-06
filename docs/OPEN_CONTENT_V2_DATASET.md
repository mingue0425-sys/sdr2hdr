# Open-content v2 dataset

Manifest: `data_video/open-content-v2/manifest.json`.
- Coverage protocol: `open-content-coverage-v1`, unchanged.
- Decision protocol: `family-maximin-lofo-v1` (`docs/DEVELOPMENT_ROADMAP.md`, `Sources/HDRCalibration/V4FamilyDecision.swift`).

The v1 Virgin Frozen holdout was consumed by the open-content V4 run (`OPEN_CONTENT_V4_CALIBRATION_REPORT.md`). v2 makes two changes:
- It replaces that holdout with new, unexposed pairs.
- It rebalances Tune across grading styles.

## Splits

| split | pairs | families | change from v1 |
|---|---|---|---|
| Tune | 17 | Sol Levante ×4, K-Choreo video3 + 9, Music Bank One-take ×1, ASC StEM3 t79/t158 | **+2 StEM3**, **+10 KBS HLG** |
| Validation | 14 | K-Choreo video4 + 8, Music Bank One-take ×1, ASC StEM2 t300/t450, Netflix Sparks f02067/f06200 | **+2 Sparks**, **+9 KBS HLG** |
| Virgin Frozen | 4 | Netflix Nocturne ×3, NAS Sole Mates ×1 | **all new**, never evaluated |

### Broadcast HLG pairs (KBS Kpop uploads, user-provided)

Eleven KBS HDR uploads join Tune and Validation:
- Families, by series: K-Choreo 8K ×9 and KBS Music Bank One-take 4K HDR ×2.
- HDR is the platform BT.2020 HLG rendition (itag 642). SDR is the platform BT.709 rendition (itag 628) of the same upload, which is YouTube's automatic conversion. The relation is therefore same-source.
- One 10 s window per upload is stream-copied, starting at the last keyframe the two renditions share at or before 40% of the duration.
  - For jIv-ebTYGrU and BVf-pipXhN8 the only shared keyframe is t=0, so their windows start at 0.
  - A first cut that let each rendition snap to its own keyframe failed the audit for those two (duration delta).
- Splits alternate in the user's list order. All 13 KBS pairs share one broadcaster pipeline.
- License: Standard YouTube License; the files are private research copies and are not redistributed. Provenance: `provenance-kbs-youtube.json`.

**Round 3 (2026-11-07).**
- Eight more user-provided K-Choreo 8K HDR uploads joined, added by `add_kchoreo_v3.py`. They are -cnGceAdbs4, xWyeg5qYL2I, BXa_OjjJIDY, rjQX-XKilF8, iSEvfuJO0hQ, 2IGhGkJIq0k, GXUlNQMZuzo and 7PMhlVxFfZg, uploaded 2023–2026.
- Five links from the same list had no HDR rendition and were dropped before download: Q63qAE6pr9Y, KwOgOTrTtKI (M2, the only non-KBS link), NuDgD4M9bcs, xqabEYkiEZ4 and NtT4mnLh-Y4. jIv-ebTYGrU was already present.
- Same window rule. 7PMhlVxFfZg's only shared keyframe at or before 40% is t=0.
- Splits alternate in list order, starting with Validation (K-Choreo was Tune 6 / Validation 5).
- dataset-audit: 35/35 main calibration.
- All 21 broadcast pairs still come from one KBS pipeline.

The four consumed v1 Frozen pairs (StEM3 t118/t197, Sparks f04133/f08266) are excluded.

The new Sparks Validation windows start at 15% and 45% of the title (frames 2067 and 6200). They were fixed a priori and kept away from the consumed windows. Their HDR was assembled from the HDR10 TIFF sequence exactly like v1 (`get_sparks_validation.sh`). Per-TIFF SHA-256 hashes are in `provenance-netflix-sparks-validation.json`.

The StEM3 Tune windows use the same title as two consumed holdout windows. This is allowed:
- they were never Validation;
- the consumed pairs are no longer in any split;
- their byte identities stay recorded in `.hdr-frozen-consumption/`.

## Why these pairs

- **StEM3 in Tune.** v1 Tune was 4/5 bright-graded Netflix masters, while the darker ASC masters appeared only in Validation and Frozen. The StEM3 windows give Tune an SDR-matched cinema grade.
- **Nocturne in Frozen.** A live-action colourist master with film grain, at 60 fps. It is a family that has never been tuned on.
- **Sole Mates in Frozen.** One CG shot rendered to SDR and HDR by ACES 2.0 output transforms from the same scene-referred composite. It is a third grading style: algorithmic, with no trim pass.
- Both Frozen families are Netflix-produced. They come from different studios and pipelines (live-action colourist versus animation ACES renders).

## Holdout custody

- Window starts were fixed before any decode: Nocturne at 30%, 50% and 70% of duration; StEM3 Tune at 20% and 40%. Sole Mates is the whole published shot.
- No Frozen frame was viewed. No statistic was computed except by `dataset-audit`, which checks integrity, metadata, decode and alignment, and evaluates no objective.
- No hash-bound virginEvidence workflow was run, so independent holdout custody is still required.
- Opening Frozen for an objective evaluation requires separate explicit approval.

## Conversions

- **SDR files.** ProRes frame headers retagged BT.709 with `prores_metadata` (stream copy, no pixel change).
- **Nocturne HDR.**
  - The master is P3-D65 ST.2084. It is converted per pixel in float64: PQ EOTF, then linear P3-D65 → BT.2020, then PQ OETF.
  - It is re-encoded as ProRes 4444 XQ 12-bit and retagged BT.2020 / ST.2084.
  - Round-trip error on a synthetic test is about 0.16 10-bit codes. A 33³ LUT was rejected because its error reached 40 codes near black.
- Scripts are in `dataset/acquisition/open-content-v2/`. Every file's SHA-256 is in `data_video/open-content-v2/provenance-*.json`. v1 provenance remains in `data_video/open-content/`.

## Audit

`results/open-content-v2/dataset-v4-final.json`:
- 14 of 14 pairs are main-calibration.
- Every new pair is detected as PQ.
- Verdict: `DATASET_V4_READY`.

## Licenses

- **Nocturne.** "'Nocturne' by Netflix", CC BY 4.0.
- **NAS Sole Mates.** "NAS Sole Mates - HDR Production Example Copyright 2025 Netflix, Inc. All rights reserved.", ASWF Digital Assets License v1.1.
- **StEM3.** "StEM3 Warped : Cybercity Copyright 2026 American Society of Cinematographers. All rights reserved.", ASWF Digital Assets License v1.1.
