# Existing Local Development Corpus Inventory

This inventory uses only committed, explicitly approved non-Frozen development roots.
It records filesystem metadata and manifest relationships; it does not read media bytes, hash media, invoke ffprobe, decode frames, or run objective metrics.

## Scope

- Correctness baseline: `bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9`
- Scope status: `APPROVED_SCOPE_ONLY`
- Materialization root: `/Volumes/game/sdr2hdr` (exact known manifest base; not a production default)
- Approved roots scanned: 7
- Protected root enumeration: `NO`
- Objective evaluations: `0`

Approved roots:

- `data_video/LIVE Paired Comparison HDR vs. SDR Database/open-sourced_HDR10`
- `data_video/LIVE Paired Comparison HDR vs. SDR Database/open-sourced_SDR`
- `data_video/video1`
- `data_video/video2`
- `data_video/video4`
- `data_video/real_media/development`
- `data_video/real_media/validation`

Protected historical roots were excluded by path identity. `data_video/video3` is excluded because historical manifests mark it Frozen despite conflicting later metadata; `data_video/video6` is excluded because manifest-v2 marks it Frozen. Their directories were not accessed.

## Inventory summary

- Media candidate files: 564
- Explicit SDR/HDR pair groups: 7
- Strong pair groups: 0
- Heuristic pair groups: 275
- Unknown media files: 0
- SDR-only groups: 0
- HDR-only groups: 0
- Qualified SDR/HDR families: 0 (technical qualification not run)
- Metadata mismatches: `NOT_RUN` (ffprobe not run)
- Technical qualification: `NOT_RUN`

Pair confidence counts:

- EXPLICIT: 7
- STRONG: 0
- HEURISTIC: 275
- UNKNOWN: 0

## Source-master reconstruction

- Proven independent paired families: 0
- Likely independent paired families (inferred only): 34
- Unknown paired families: 0

The current manifests provide explicit pair relationships and per-pair group labels, but no authoritative `sourceMasterId`. Inferred groups remain development leads and are not promotion-grade evidence.

- K-Choreo candidate groups: 3
- LIVE candidate groups: 31
- Existing coarse family overlap: ["K-Choreo", "LIVE"]
- Candidate family overlap: `NOT_EVALUATED_NO_NEW_SPLIT`
- Source-master independence: `UNKNOWN_NO_AUTHORITATIVE_SOURCE_MASTER_ID`

## Pair and qualification limits

- Existing role assignments were recorded as evidence only; no new Tune/Validation split was created.
- Pair identity for additional LIVE files is filename-based and marked `HEURISTIC`.
- No current media SHA-256 was computed.
- No frame alignment, temporal compatibility, or pixel inspection was performed.
- Existing external-manifest media are SDR-only and do not create paired calibration families.

## Decision

- Existing local corpus status: `INSUFFICIENT`
- Inferred corpus status: `PROMISING_INFERRED_ONLY`
- Promotion-grade available: `False`
- External dataset required: `UNDECIDED`
- Tune: `NO`
- Validation: `NO`
- Frozen accessed: `NO`
- Objective evaluations: `0`

The inventory is a discovery and provenance screen only. It does not emit the v5 calibration manifest and does not authorize calibration search.
