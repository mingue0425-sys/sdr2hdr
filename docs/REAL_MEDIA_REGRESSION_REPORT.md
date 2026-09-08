# Real Media Regression Report

## Baseline and scope

- Baseline: `main@0a980d9`
- Development branch: `real-media-regression-development`
- Matrix: 12 generated compressed fixtures
- Existing tiny H.264/P010 smoke tests: preserved unchanged
- Production chroma default: `.nearest`
- Siting-aware reconstruction: evaluated as a candidate beside production
- Frozen/Virgin data: not accessed
- Objective evaluations: `0`

This change adds a manifest-driven runtime correctness matrix. It does not tune
V4, change tone expansion, change temporal parameters, change the production
histogram, or promote the siting-aware candidate.

## Runtime path

Every available fixture is exercised through:

```text
generated compressed MP4
→ AVURLAsset
→ AVPlayerItem
→ AVPlayerItemVideoOutput
→ decoded CVPixelBuffer
→ HDRColorMetadataResolver
→ HDRProcessor calibratedV4
→ Metal HDRFrame RGBA16Float
→ HDRPresentationRenderer offscreen RGBA16Float target
→ shared-buffer readback and validity gates
```

The runner executes both `.nearest` and `.sitingAwareBilinear` for each
manifest fixture. The result artifact contains decoded format/range/metadata,
timestamps, GPU and CPU samples, sequence state, output validity statistics,
and nearest-to-candidate deltas.

## Manifest matrix

| Fixture group | Codec / source | Range | Timing | Content |
|---|---|---|---|---|
| H264 dark | H.264 8-bit | video | 24 CFR | dark gradient and near-black steps |
| H264 neutral | H.264 8-bit | video | 30 CFR | neutral and saturated patches |
| H264 motion | H.264 8-bit | video | 60 CFR | moving colored rectangles |
| H264 full | H.264 8-bit | full | 30 CFR | neutral and saturated patches |
| HEVC 8-bit | HEVC Main | video | 30 CFR | chroma edges |
| Main10 dark | HEVC Main 10 | video | 24 CFR | dark gradient and near-black steps |
| Main10 chroma | HEVC Main 10 | video | 30 CFR | saturated vertical/horizontal edges |
| Main10 motion | HEVC Main 10 | video | 60 CFR | moving colored rectangles |
| H264 VFR | H.264 8-bit | video | VFR | moving colored rectangles |
| Main10 VFR | HEVC Main 10 | video | VFR | moving colored rectangles |
| Main10 near-black | HEVC Main 10 | video | 24 CFR | 10-bit near-black code steps |
| H264 chroma | H.264 8-bit | video | 24 CFR | red/blue/neutral edges |

The fixture generator uses raw YUV/P010 planes followed by compressed encoding.
H.264 is forced to a decodable High 4:2:0 profile, HEVC 8-bit uses Main, and
Main10 uses `yuv420p10le` with the Main 10 profile. `setparams` and
`write_colr` make the BT.709 transfer/primaries/matrix metadata explicit.
VFR fixtures contain two distinct timestamp deltas, verified by both ffprobe
and decoded AVFoundation presentation timestamps.

If an encoder is missing, the generator creates an explicit `.UNSUPPORTED`
marker and exits nonzero. The fixture verifier and mandatory regression gate
treat that marker as a failure; a capability skip can never make the mandatory
matrix pass. The generator never substitutes another codec or silently treats
a precision downgrade as a pass.

## Gates and measurements

The preregistered gates are in
`Tests/RealMediaRegression/gates.json` and cover:

- minimum decoded frames;
- decoded pixel-format family and bit depth;
- video/full range and BT.709 metadata;
- strictly increasing timestamps and CFR/VFR timing diversity;
- input/output finite, nonnegative, nonzero samples;
- unexpected clipping fraction;
- static fixture frame-to-frame luminance flicker;
- P010 input and output distinguishable luminance levels;
- the Main10 near-black precision ROI at `(0, 0, 32, 36)`, including
  Float16-aware output level clustering and monotonic ordering violations;
- content-aware clipping profiles (`dark-static`, `neutral-static`, and
  `motion`);
- GPU/adaptive completion sequence consistency.

Every deterministic generated fixture preregisters its expected decoded
chroma siting as `left`. A siting attachment outside that allow-list fails the
fixture contract instead of silently becoming an informational result. The
near-black fixture currently records 16 input levels, 20 output levels, and
zero ordering violations in the configured ROI for both reconstruction modes.
The current local run observed zero clipping in all three content profiles.

The report artifact is written to the ignored `results/` directory as
`real-media-regression.json`; release mode writes a separate
`real-media-regression-release.json`. The fixture probe artifact is kept in the
temporary fixture directory.

For high-resolution external media, CPU readback validity and percentile
diagnostics use a deterministic grid capped at 65,536 pixels per frame. GPU
processing and presentation still run at the source resolution. The
deterministic generated matrix retains its full-pixel diagnostic behavior.

## Local results

On the Apple Silicon macOS development machine, the 12-fixture matrix passed
in both debug and release configurations:

```text
debug:   fixtures=12 failures=0 skipped=0
release: fixtures=12 failures=0 skipped=0
```

All 12 fixtures decoded with the expected family. The decoded AVFoundation
formats were NV12 for 8-bit fixtures and P010 for Main10 fixtures. The full
range fixture decoded as NV12 full-range. Both VFR fixtures reported two
distinct decoded frame-duration classes. All processed frames reached matching
GPU and adaptive committed sequences; the matrix run processed eight frames per
mode and the sequence reached `8` in both modes.

Across the debug run, the nearest-to-candidate mean absolute output luminance
delta ranged from `0` to `0.0033902`. This is diagnostic evidence for the
candidate comparison only; it is not a promotion decision. The production
nearest path remains the default and is covered by the same matrix.

The local debug aggregate timing samples were:

```text
nearest GPU p50/p95/p99:   0.090 / 0.763 / 1.819 ms
candidate GPU p50/p95/p99: 0.129 / 0.774 / 1.445 ms
nearest CPU p50/p95:       3.081 / 4.705 ms
candidate CPU p50/p95:     2.251 / 3.379 ms
```

These are diagnostic samples from 64×36 fixtures, not a production
performance gate. A larger local performance tier remains separate from the
mandatory PR matrix.

The configured external corpus then passed the shared runtime path:

```text
development: 12 sources, failures=0, metadata-only=0, 61 seconds
validation:  5 sources, failures=0, metadata-only=1, 23 seconds
```

The validation metadata-only source is the local HEVC adaptation of Elephants
Dream. Its hash and ffprobe contract pass, but its SMPTE 170M colorimetry is
outside the current HDRCore BT.709 SDR runtime domain, so the manifest marks
it explicitly as `engineEvaluation: metadata-only`. It is not counted as a
runtime pass.

## Verification commands

Executed locally:

```bash
bash Tests/RealMediaRegression/generate_regression_fixtures.sh <temporary-dir>
bash Tests/RealMediaRegression/verify_regression_fixtures.sh <temporary-dir>
swift test -c debug --disable-index-store --filter RealMediaRegressionTests/testRegressionManifestIsValid
swift test -c debug --disable-index-store
swift test -c release --disable-index-store
swift build -c release
bash Tests/verify_script_cache_test.sh
./RUN_MACOS_VERIFY.sh self-contained
./RUN_MACOS_VERIFY.sh p010
./RUN_MACOS_VERIFY.sh regression
./RUN_MACOS_VERIFY.sh regression-full
./RUN_MACOS_VERIFY.sh real-media
./RUN_MACOS_VERIFY.sh real-media-validation
HDR_REAL_MEDIA_ROOT="$PWD/sdr2hdr-real-media" ./RUN_MACOS_VERIFY.sh real-media
HDR_REAL_MEDIA_ROOT="$PWD/sdr2hdr-real-media" ./RUN_MACOS_VERIFY.sh real-media-validation
git diff --check
```

The external modes were first run without `HDR_REAL_MEDIA_ROOT` and reported an
explicit skip. They were then run against the configured local corpus above.
The temporary generated H.264 smoke source used during runner bring-up remains
outside the repository and is not part of the corpus report.

The CI workflow now syntax-checks the generator, verifier, manifest, and gates,
then runs `./RUN_MACOS_VERIFY.sh regression` before the broader Swift/Metal
tests. The latest local full Swift test suite passed in both configurations with
268 tests, 0 failures, and 12 environment/data-dependent skips. Remote CI
status is reported by the pull request for the branch.

## Production invariants

```text
calibratedV4 parameters: unchanged
toneExpand arithmetic: unchanged
temporal tuning: unchanged
production histogram strategy: unchanged
production chroma default: nearest
```

The only production-side API addition is an optional range argument on the
shared AVPlayerItemVideoOutput configuration helper. Its default remains the
existing 8-bit/video-range contract; the explicit full-range option is used by
the regression harness to verify that range is not silently lost.

## External corpus path

External sources are intentionally separate from the deterministic CI
manifest. `data_video/real_media/external-manifest.json` stores source
identity, SHA-256, source-family provenance, split, category, strict metadata
expectations, and fixed duration-fraction windows; media bytes remain outside
the repository under `HDR_REAL_MEDIA_ROOT`.

`real-media` runs only the development split and
`real-media-validation` runs only the validation split. Both modes validate
the file hash and ffprobe metadata before reusing the common AVFoundation →
CVPixelBuffer → HDRProcessor → Metal → offscreen presentation runner. The
runner records nearest and siting-aware results and their deltas without
declaring a candidate better in the absence of an HDR reference. A source
family appearing in both splits is rejected as
`SOURCE_FAMILY_SPLIT_LEAKAGE`.

The manifest also carries optional `MatchedMediaPair` records. When both
members are present in the selected split, the report records coarse
resolution, duration, frame-count, frame-rate, and metadata compatibility.
Scene correspondence is explicitly marked not evaluated; this path never
turns a matched pair into an objective evaluation.

The local manifest contains 17 playable source entries across 16 source
families: 12 development sources and 5 validation sources. Development covers
8-bit NV12 plus two genuine 10-bit P010 sources. Validation has four runtime
sources and one explicit metadata-only source as described above. No source
family crosses the split boundary. The media bytes remain outside Git and are
not added to CI; deterministic 12-fixture regression remains the mandatory
CI gate.

## Next step

Keep the deterministic matrix as the mandatory correctness gate. The next
corpus work is to close the documented gaps: genuine VFR, more native HEVC
sources, at least one additional genuine 10-bit family, and matched SDR/HDR
pairs. Keep HDR-reference quality assessment separate from this decode, timing,
chroma, and runtime-validity regression layer. Do not promote siting-aware
reconstruction from these runtime results alone.
