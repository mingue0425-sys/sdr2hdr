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
marker and the runner reports a capability skip. It never substitutes another
codec or silently treats a precision downgrade as a pass.

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
- GPU/adaptive completion sequence consistency.

The report artifact is written to the ignored `results/` directory as
`real-media-regression.json`; release mode writes a separate
`real-media-regression-release.json`. The fixture probe artifact is kept in the
temporary fixture directory.

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
git diff --check
```

The CI workflow now syntax-checks the generator, verifier, manifest, and gates,
then runs `./RUN_MACOS_VERIFY.sh regression` before the broader Swift/Metal
tests. The local full Swift test suite passed in both configurations with 247
tests, 0 failures, and 9 environment/data-dependent skips. Remote CI status is
reported by the pull request for the branch.

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

## Next step

Use the deterministic matrix as the mandatory correctness gate while adding
independent local real-media source families. Keep any HDR-reference quality
assessment separate from this decode, timing, chroma, and runtime-validity
regression layer. Do not promote siting-aware reconstruction from these smoke
and matrix results alone.
