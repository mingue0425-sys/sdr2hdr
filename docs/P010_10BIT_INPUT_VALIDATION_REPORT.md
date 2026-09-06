# P010 10-bit Input Validation Report

## Baseline

- production baseline: `main@570d763f5f763748b9b87d82a8974286ffafdb39`
- development branch: `p010-10bit-development`
- calibrated V4 parameters: unchanged
- `toneExpand()` arithmetic: unchanged
- temporal model: unchanged
- production histogram strategy: unchanged

No V4/V6 tuning, Frozen/Virgin access, or objective evaluation was performed.

## P010 E2E path

```text
10-bit lossless HEVC Main10 SDR MP4
→ AVURLAsset
→ AVPlayerItem
→ AVPlayerItemVideoOutput (.tenBitPreferred)
→ x420/P010 CVPixelBuffer
→ BT.709/range metadata resolution
→ CVMetalTextureCache r16Unorm + rg16Unorm
→ P010 input decoding in Metal
→ HDRProcessor calibratedV4
→ RGBA16Float HDRFrame
→ offscreen HDRPresentationRenderer
→ finite readback
```

The generated fixture contains dark, mid-gray, white, colored, gradient, and
frame-varying patches. Its raw P010 samples use the verified 10-bit
MSB-aligned representation and are encoded as lossless HEVC Main10.

## Pixel format

```text
source codec: HEVC Main10 (lossless fixture)
decoded CVPixelBuffer: x420 / kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
source bit depth: 10
Y Metal format: r16Unorm
UV Metal format: rg16Unorm
range: video-range
```

The integration test reads decoded plane samples and verifies the valid code
values are recovered from the 16-bit container. The observed end-to-end run
reported `uniqueYCodes=435` over `YCodeRange=64...940` across ten decoded
frames.

## Precision evidence

The scalar and Metal tests cover the legal video-range code points, full-range
normalization, exact 8-bit-representable signals, and near-black code steps.
P010 retains adjacent 10-bit near-black codes that collapse to the same 8-bit
NV12 code. Exactly representable 8-bit and P010 signals stayed within the
tested Metal readback tolerance (`max channel delta <= 0.002`).

The synthetic benchmark on Apple M2 at 640x360, 10 measured frames after two
warmups, reported:

```text
NV12 8-bit GPU p50/p95/p99: 0.150 / 0.150 / 0.150 ms
NV12 8-bit CPU p50/p95/p99: 0.012 / 0.014 / 0.014 ms
P010 10-bit GPU p50/p95/p99: 0.174 / 0.174 / 0.174 ms
P010 10-bit CPU p50/p95/p99: 0.010 / 0.016 / 0.016 ms
```

The small benchmark is a measurement, not a performance gate; its GPU median
was approximately 16% higher for P010, consistent with the wider input
textures and additional code-value reconstruction.

## Runtime policy and diagnostics

The existing production default remains the established 8-bit NV12 output
contract. P010 is an explicit opt-in through
`HDRDecodePrecision.tenBitPreferred` or `--decode-precision 10bit`; this avoids
claiming source precision that an 8-bit source does not contain. Diagnostics
report input format, bit depth, range, and the selected Y/UV Metal formats.

The shared video-output configuration is used by playback, sample, benchmark,
and real-media tests, so pixel-buffer attributes do not drift between runtime
and verification paths.

## Validation commands and results

```text
swift test -c debug --disable-index-store: PASS (230 tests, 6 skipped)
swift test -c release --disable-index-store: PASS (230 tests, 6 skipped)
swift build -c release: PASS
bash Tests/verify_script_cache_test.sh: PASS
./RUN_MACOS_VERIFY.sh self-contained: PASS
git diff --check: PASS
```

The self-contained run passed both the existing 8-bit path and the new P010
path. The P010 path decoded and processed ten frames, completed Metal command
buffers, produced finite non-zero output, and kept GPU/adaptive sequences at
10.

## Production invariants

```text
calibratedV4 parameter changes: NO
toneExpand arithmetic changes: NO
production histogram strategy changes: NO
temporal parameter changes: NO
```

P010 adds input-format dispatch and input code-range normalization before the
existing linearization and V4 processing. The existing NV12 and BGRA paths
remain available and are covered by the pre-existing regression tests.

## CI and dataset isolation

The macOS workflow runs the self-contained verification mode, which now
exercises both compressed 8-bit and compressed P010 media. PR #3 macOS CI
passed on commit `bd41a71`. The first runner attempt stopped before P010
fixture generation because that runner did not provide `rg`; the capability
check was changed to use FFmpeg's encoder help command and the rerun passed.

```text
K-Choreo accessed: NO
Virgin Frozen accessed: NO
Objective evaluations: 0
```

## Remaining limitations

- P010 decoder availability and pixel-format negotiation remain platform and
  codec dependent; an explicit ten-bit request reports a failure rather than
  silently accepting an 8-bit result.
- Broader real-media coverage, chroma siting validation, and 10-bit source
  diversity remain follow-up work.
