# Automatic Decode Precision Report

## Baseline

```text
baseline: main@db01ba7051a046d2c08e1be5ff6f4c0c165259e1
branch: automatic-decode-precision-development
validation implementation head: 6df88db
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
   component-depth extension is absent.
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
Debug tests: PASS (283 tests, 15 environment/data-dependent skips)
Release tests: PASS (283 tests, 15 environment/data-dependent skips)
Release build: PASS
verify_script_cache_test.sh: PASS
self-contained: PASS
p010: PASS
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
