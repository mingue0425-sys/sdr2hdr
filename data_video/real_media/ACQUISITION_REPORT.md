# Independent real-media acquisition — 2026-09-06

Status: **16 source families / 17 playable sources acquired**. The count target is met; the special 10-bit and paired-reference targets are **not** met.

Local dataset: `/Volumes/game/sdr2hdr-v4-release/sdr2hdr-real-media` (`HDR_REAL_MEDIA_ROOT`). Actual videos and original excerpts are outside Git.
Family split: development **11/16 (68.75%)**, validation **5/16 (31.25%)**. Two cottonbro clips share one family and remain in development. Separate films remain separate families; no clips from one source master cross splits.

Virgin Frozen accessed: **NO**
Objective evaluations: **0**
This is a non-Frozen acquisition corpus. Runtime validity was exercised through the shared AVFoundation → HDRCore → Metal runner; no HDR quality scoring, tuning, promotion, or Frozen evaluation was performed.

| ID | Category | Codec | Bit depth | Range | FPS | Timing | SDR/HDR pair | Split |
| -- | -------- | ----- | --------: | ----- | --: | ------ | ------------ | ----- |
| pexels-16934543 | night-neon | H264 | 8 | video | 30.000 | CFR | No | development |
| pexels-3713695 | dark-film-like | H264 | 8 | video | 25.000 | CFR | No | development |
| pexels-13702779 | dark-film-like | H264 | 8 | video | 25.000 | CFR | No | validation |
| pexels-8729490 | skin-face | H264 | 8 | video | 23.976 | CFR | No | development |
| pexels-10141043 | skin-face | H264 | 8 | video | 25.000 | CFR | No | development |
| pexels-10297595 | night-neon | H264 | 8 | video | 29.970 | CFR | No | validation |
| pexels-3725901 | bright-outdoor | H264 | 8 | video | 24.000 | CFR | No | development |
| pexels-11114560 | bright-outdoor | H264 | 8 | video | 29.970 | CFR | No | validation |
| pexels-18326007 | fast-motion | H264 | 8 | video | 59.940 | CFR | No | development |
| pexels-12955565 | fast-motion | H264 | 8 | video | 25.000 | CFR | No | development |
| pexels-3615892 | smoke-fog | H264 | 8 | video | 25.000 | CFR | No | development |
| pexels-1281654 | high-saturation | H264 | 8 | video | 30.000 | CFR | No | validation |
| pexels-854053 | screen-ui-text | H264 | 8 | video | 25.000 | CFR | No | development |
| blender-bbb | animation-cg | H264 | 8 | unknown | 60.000 | CFR | No | development |
| blender-elephants-dream-hevc8 | animation-cg | HEVC (local) | 8 | full | 24.000 | CFR | No | validation; metadata-only runtime policy |
| netflix-chimera-bar | dark-film-like | HEVC (local) | 10 | video | 60.000 | CFR | No | development |
| netflix-elfuente-narrator | skin-face | HEVC (local) | 10 | video | 60.000 | CFR | No | development |

Coverage counts below are independent families, with playable-file counts in parentheses.

```text
total source families: 16 (17 files)
8-bit: 14 (15 files)
10-bit: 2 (2 files), genuine published 10-bit source excerpts
H.264: 13 (14 files)
HEVC: 3 (3 files), ALL locally derived
CFR: 16 (17 files)
VFR: 0
development: 11 (12 files)
validation: 5 (5 files)
matched SDR/HDR pairs: 0
```

Important limits:

- Genuine 10-bit SDR: **2/3 minimum**. Chimera and El Fuente are grouped by original production, not by scene. Each acquired original excerpt contains 180 frames / 3 seconds, so long temporal stress coverage remains limited. Both original Y4M excerpts are retained with their own SHA-256.
- The Netflix copyright documents state 10-bit 4:2:0 BT.709 and 59.94fps; the delivered Y4M says F60:1. The 60fps file clock is preserved and the conflict is recorded. Y4M range and siting are unspecified. The HEVC derivatives explicitly signal video range and left siting; those are derivative assumptions, not verified original mastering facts.
- All three HEVC files are local adaptations. They do **not** demonstrate independent external HEVC encoder diversity. Two preserve genuine original 10-bit input; the third is a lossless 8-bit adaptation of the full-range MPEG-4 Part 2 Elephants Dream teaser. Its decoded-frame hashes are compared in local provenance.
- The BBB source omits colorimetry and range tags. These stay null. Elephants Dream original colorimetry is incomplete; its derivative inherits decoder SMPTE170M metadata. Neither is claimed as confirmed BT.709 mastering.
- No genuine VFR source. No dedicated genuine 10-bit dusk/studio/animation gradient. No matched pair acquired.
- NV12/P010 are decoder output formats, not the compressed file pixel-format labels. The configured runtime runner decoded the external 8-bit sources as NV12 and the two genuine 10-bit sources as P010 through the production HDRCore/Metal path. This is runtime validity evidence, not an HDR quality objective.
- Stock-footage camera models and capture-session independence are not disclosed. Different creators and subject matter give conservative family diversity, but do not prove different cameras. Content was inspected from representative decoded frames; screen-text material includes optical focus softness.
- Netflix material is CC BY-NC-ND 4.0 and is a restricted local noncommercial subset. Pexels and Blender usage terms are recorded per source. No media was added to Git.

Access-dependent candidate: [LIVE Paired Comparison HDR vs. SDR Database](https://live.ece.utexas.edu/research/Bowen_SDRHDR/sdr-hdr-bowen.html). Official page describes 31 publicly releasable source videos with matched SDR/HDR variants. Its access form requests name, email, affiliation and title. **No form was submitted, and no pair is counted**. No subjective scores or HDR references were used.

Validation performed: local file existence, ffprobe streams, whole-file presentation packet timestamps, SHA-256, representative visual inspection, family split disjointness, required metadata fields, source-entry/aggregate-manifest consistency, and the external runtime runner. These are runtime/acquisition checks, not engine quality objective evaluations.

Provenance: each `sources/*.json` entry records the verified page and download URL, permission, family grouping, exact original/derived identity, file metadata and hash. Detailed probes, acquisition scripts, raw excerpts and contact sheets live in the external dataset `provenance/` directory.
