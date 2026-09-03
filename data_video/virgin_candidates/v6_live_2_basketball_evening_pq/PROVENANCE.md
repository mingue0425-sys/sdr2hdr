# V6 Virgin Frozen PQ candidate provenance: LIVE source 2

- Provider: LIVE Paired Comparison HDR vs. SDR Database (local)
- Content family: LIVE
- Source ID: `2_Basketball_Evening`
- Expected relation: `same-source`
- Candidate directory: `data_video/virgin_candidates/v6_live_2_basketball_evening_pq/`
- Media is referenced from the existing LIVE root; it is not duplicated here.

## Source-level historical exposure audit

The audit covered the current and historical `manifest.json`, `manifest-v2.json`,
and `manifest-v4.json`; dataset-v4 locks; V6 consumed IDs and hashes; holdout
provenance ledgers; and JSON/MD/TXT result artifacts, including the LIVE
discovery, pair, selection, and preregistered PQ screening artifacts.

The source ID is absent from all manifests, locks, consumed-hash ledgers, and
objective/tune/validation/frozen result outputs. The historical LIVE discovery
and pair artifacts contain source-level variants as `LIVE_PAIR_CANDIDATE` /
structurally screened `PAIR_VALID` records only. The LIVE selection artifact
did not select this source for a dataset split. The canonical 3840x2160 /
15000k variant was selected only by the sealed V6 PQ structural preselection;
that artifact states `PRESELECTED_ONLY`, `NOT_REGISTERED`, and
`NOT_OBJECTIVE_EVALUATED`.

This is a source-identity audit: alternate bitrate or filename variants do not
create a prior consumption event. No provenance conflict was found.

## Sealed media and metadata

| Asset | SHA-256 | ffprobe result |
| --- | --- | --- |
| `live:open-sourced_SDR/2_Basketball_Evening_SDR_3840x2160_15000k.mp4` | `489fa3813d1ef9fbae3dedc9c161f438e0b294a4ce4a683c5d8ddc015b6b96be` | HEVC Main, 3840x2160, `yuv420p`, BT.709 / BT.709 / BT.709, 8-bit, 60000/1001, 8.008 s |
| `live:open-sourced_HDR10/2_Basketball_Evening_HDR10_3840x2160_15000k.mp4` | `177b54d2fa2925d2e747c491ac4d9af9bd4f107651d0277f7a6c8f2efc854a1b` | HEVC Main 10, 3840x2160, `yuv420p10le`, BT.2020 / SMPTE 2084 / BT.2020nc, 10-bit, 60000/1001, 8.008 s |

The independent full-file `ffmpeg -xerror` decodes exited 0 with empty
stderr. `ffprobe -count_frames` reported 480 SDR frames and 480 HDR frames;
both counts are positive and exactly equal.

## Structural alignment

The sealed 5x8 / 40-frame transfer-invariant structural screen is reproduced
as follows: sampled 40, matched 40, ratio 1.000000, p10
0.8468490610158574, median 0.8496432559167626, status `ALIGNED`, maximum
absolute offset 0.000000 seconds, and offset spread/drift 0.000000 seconds.
The preregistered ranking artifact's separate `drift` field is retained as a
ranking diagnostic; it is not the alignment offset-spread measure.

## Selection and objective boundary

- `frameInspectionBeforeSelection=false`
- `sourceIdentityPreregistered=true`
- `objectiveUse.consumed=false`
- `objectiveUse.evaluationCount=0`
- Verdict: `PAIR_VALID_VIRGIN`
- Evidence file: `VIRGIN_PAIR_VALID.json`
- Evidence SHA-256: `79a1640512967afc760648975a1ca8d8a0f3b67f2588583f24af3ce3b5d351d0`
- Real `V4VirginPairEvidenceValidator`: `PASS` (dataset-audit)

No objective metric or frozen objective pixel was opened for this pair.

The post-registration V4 dataset audit independently reported 40/40,
ratio 1.000000, p10 `0.8468490610158574`, median
`0.8494829085030641`, zero offset and zero offset variance, `ALIGNED`.
The small median presentation difference from the sealed preselection value
is non-material and does not affect any V4 threshold or verdict; the evidence
file retains the sealed value `0.8496432559167626`.
