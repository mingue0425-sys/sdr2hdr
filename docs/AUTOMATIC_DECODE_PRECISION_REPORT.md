# Automatic Decode Precision Report

## Baseline

```text
baseline: main@db01ba7051a046d2c08e1be5ff6f4c0c165259e1
branch: automatic-decode-precision-development
validated functional head: db861c4eacc08a1102458ae1c2691011d64dc7f9
```

This change makes `HDRDecodePrecision.automatic` source-aware for the actual
playback setup. It does not change calibrated V4 image processing. The
production app resolves the source before constructing
`AVPlayerItemVideoOutput`; source-less compatibility callers retain an
explicit, diagnostic NV12 fallback.

## Resolver implementation

`HDRDecodePrecisionResolver` is in
`Sources/HDRPlayer/HDRDecodePrecisionResolver.swift`. It loads the video
track's format descriptions once, before the output is created, and separates
the requested precision, source evidence, resolved precision, and decision
reason.

Evidence is accepted in this order:

1. `kCMFormatDescriptionExtension_BitsPerComponent` when it is a finite,
   integral 8- or 10-bit value.
2. Bounds-checked `avcC`/`hvcC` codec configuration evidence when the direct
   component-depth extension is absent. The fallback parses the actual SPS
   `bit_depth_luma_minus8` and `bit_depth_chroma_minus8` fields after removing
   emulation-prevention bytes; it does not infer coded depth from a profile ID.
   AVC High10 alone does not imply 10-bit, and HEVC Main10 alone does not
   imply 10-bit. Profile IDs are used only to select syntax and validate
   compatibility.
3. An unresolved or conflicting source fails closed to 8-bit with an explicit
   fallback reason.

The runtime does not use filenames, manifests, `ffprobe`, shell processes, or
per-frame source inspection. The shared `HDRInputPixelFormat` mapping is also
used for the first decoded `CVPixelBuffer`, so an output negotiation mismatch
is observable as `AUTOMATIC_DECODE_PRECISION_MISMATCH` rather than causing a
wrong plane interpretation.

The source-aware path is `await PlaybackController.make(...)`. The existing
synchronous initializer remains for test-pattern and source-less compatibility
callers; because it cannot await asset inspection, `.automatic` there is the
documented conservative fallback. `HDRVideoOutputConfiguration` accepts only
the resolved precision for the source-aware output construction path.

## Decisions

```text
H.264 8-bit avc1:       sourceBitDepth=8  -> NV12, no fallback
HEVC 8-bit hvc1:        sourceBitDepth=8  -> NV12, no fallback
HEVC Main10 hvc1:       sourceBitDepth=10 -> P010, no fallback
unresolved source:      unknown           -> NV12, fallback=true
```

Explicit requests remain overrides:

```text
eightBit        -> NV12, regardless of source evidence
tenBitPreferred -> P010, regardless of source evidence
```

Each decision carries `requested`, `resolved`, `sourceBitDepth`,
`sourceCodec`, `reason`, `fallbackUsed`, and an optional inspection detail.
The player reports the first actual decoded format and any mismatch in its
debug diagnostics.

The SPS parser is fail-closed and bounds-checked: truncated `avcC`/`hvcC`,
malformed SPS data, malformed Exp-Golomb codes, luma/chroma depth conflicts,
and unsupported depths resolve to `unknown` rather than reading out of bounds
or claiming 10-bit precision. The EBSP-to-RBSP boundary regression preserves
an actual `0x03` immediately after an inserted emulation-prevention byte:

```text
00 00 03 00 → 00 00 00
00 00 03 01 → 00 00 01
00 00 03 02 → 00 00 02
00 00 03 03 → 00 00 03
```

In particular, `00 00 03 03` removes only the inserted byte. The regression
test `testEmulationPreventionFollowedBy03IsNotDoubleRemoved` covers all four
mapping cases, while the codec fixtures continue to exercise actual SPS
parsing.

## Deterministic compressed-media E2E

`./RUN_MACOS_VERIFY.sh automatic-decode` generated the existing deterministic
fixtures, verified their codec contracts, then exercised:

```text
generated compressed MP4
→ AVURLAsset / AVPlayerItem
→ source format-description inspection
→ resolved AVPlayerItemVideoOutput
→ decoded CVPixelBuffer
→ HDRColorMetadataResolver
→ HDRProcessor calibratedV4
→ Metal HDRFrame RGBA16Float
→ HDRPresentationRenderer offscreen target
→ finite/nonzero readback
```

Observed automatic integration results:

| source | decision | decoded format | frames | GPU/adaptive sequence |
|---|---|---|---:|---:|
| H.264 High 8-bit | NV12 | `420v` | 6 | 6 / 6 |
| HEVC Main 8-bit | NV12 | `420v` | 6 | 6 / 6 |
| HEVC Main10 | P010 | `x420` | 6 | 6 / 6 |

The H.264 and Main10 paths also reported finite, nonzero offscreen
presentation samples and BT.709 metadata.

## External corpus distribution

The existing local corpus was run through the shared external regression
runner with `.automatic`; no manifest precision value was used to select the
output format.

```text
development: 12 sources, NV12=10, P010=2, fallback=0, mismatch=0
validation:   4 runtime sources, NV12=4, P010=0, fallback=0, mismatch=0
metadata-only: 1 source (Elephants Dream; outside the supported BT.709 SDR
               runtime domain, so no runtime decision is claimed)
```

The source corpus contains 17 entries across 16 source families. Existing
family split and metadata-only policies were preserved. The external media
bytes remain outside the repository.

## External validation stability follow-up

An earlier local run observed intermittent insufficient-frame acquisition from
`AVPlayerItemVideoOutput` windows. The failing source varied between runs. No
gate, threshold, timeout, manifest, or runner change was made.

The controlled A/B rerun used the same corpus, windows, and command:

```text
baseline main@db01ba7: 5/5 PASS
PR6 db861c4:            5/5 PASS
```

All four runtime validation sources decoded 8/8 required frames in every run;
the fifth entry remained the documented metadata-only Elephants Dream source.
Previously observed failing sources were `pexels-13702779`,
`pexels-10297595`, and `pexels-11114560`; none reproduced in the ten A/B
runs. The result is `FLAKE_NOT_REPRODUCED`: this experiment found no evidence
that PR #6 caused the earlier one-frame acquisition failures, without proving
that the acquisition harness can never flake.

## Regression coverage

The deterministic 12-fixture matrix still passes with no skipped or failed
fixtures in both debug and release. It covers H.264, HEVC Main, HEVC Main10,
NV12, P010, video/full range, CFR/VFR, near-black, and chroma-edge content.
The source-aware external runner records its decision in the JSON result and
validates the actual decoded format against the expected source depth.

The resolver unit tests cover known H.264/HEVC 8-bit, HEVC Main10, unresolved
fallbacks, explicit overrides, malformed `avcC`/`hvcC`, truncation safety, and
resolved NV12/P010 output attributes. The compressed-media tests cover actual
AVFoundation decode and calibrated V4 Metal processing for all three source
classes.

## Verification

```text
Debug tests: PASS (293 tests, 15 conditional skips)
Release tests: PASS (293 tests, 15 conditional skips)
Release build: PASS
verify_script_cache_test.sh: PASS
self-contained: PASS
p010: PASS
automatic-decode: PASS (H.264 8-bit → NV12; HEVC 8-bit → NV12; HEVC Main10 → P010; mismatch=0)
regression: PASS (12/12, skipped=0, failures=0)
regression-full: PASS (debug and release, 12/12, skipped=0, failures=0)
real-media development: PASS (12 sources, failures=0)
real-media validation: PASS (4 runtime sources, failures=0; 1 metadata-only)
```

The automatic verification mode and the existing deterministic regression
mode remain separate. No Frozen, Virgin, holdout, or objective workflow was
invoked.

## Production invariants

```text
calibratedV4 parameters changed: NO
toneExpand arithmetic changed: NO
temporal changed: NO
histogram strategy changed: NO
P010 normalization changed: NO
EDR mapping changed: NO
production chroma default: nearest
```

The only production behavior change is source-aware selection when the caller
uses the playback factory with `.automatic`: known 8-bit sources request NV12,
known 10-bit sources request P010, and unresolved sources use a visible NV12
fallback.

## Dataset isolation

```text
K-Choreo accessed: NO
Virgin Frozen accessed: NO
Objective evaluations: 0
```

## Executed commands

```bash
swift test -c debug --disable-index-store
swift test -c release --disable-index-store
swift build -c release --disable-index-store
bash Tests/verify_script_cache_test.sh
./RUN_MACOS_VERIFY.sh self-contained
./RUN_MACOS_VERIFY.sh p010
./RUN_MACOS_VERIFY.sh automatic-decode
./RUN_MACOS_VERIFY.sh regression
./RUN_MACOS_VERIFY.sh regression-full
HDR_REAL_MEDIA_ROOT=/Volumes/game/sdr2hdr-v4-release/sdr2hdr-real-media ./RUN_MACOS_VERIFY.sh real-media
HDR_REAL_MEDIA_ROOT=/Volumes/game/sdr2hdr-v4-release/sdr2hdr-real-media ./RUN_MACOS_VERIFY.sh real-media-validation
baseline main@db01ba7: five repeated real-media-validation runs
PR6 db861c4: five repeated real-media-validation runs
git diff --check
```

The automatic source-precision mode was also executed during bring-up; its
final deterministic run passed. Tests without media environment variables
retain their existing explicit skips rather than claiming an E2E pass.

## Remaining limitation

The synchronous compatibility initializer cannot perform asynchronous
format-description inspection. File playback uses the async factory in
`HDRPlayerApplication`; external callers that need source-aware `.automatic`
selection should use the same factory. A source that cannot provide reliable
8/10-bit evidence is intentionally reported as unresolved and conservatively
uses NV12.
