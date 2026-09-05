# HDRCore

Reusable macOS/Apple Silicon SDR-to-HDR tone-expansion core.

The core deliberately stops at a GPU HDR frame:

```text
AVFoundation / VideoToolbox / ScreenCaptureKit
        -> CVPixelBuffer
        -> CVMetalTextureCache
        -> Metal transform + sparse temporal proxy dispatches
        -> RGBA16Float BT.2020 HDR texture
```

It does not decode, display, encode, or save video.

## API

```swift
let processor = try HDRProcessor(
    device: MTLCreateSystemDefaultDevice()!,
    configuration: .hdr
)

try processor.prepare(width: 1920, height: 1080)

let frame = try processor.process(
    pixelBuffer: pixelBuffer,
    timestamp: presentationTime,
    commandBuffer: commandBuffer
)
// Encode/commit commandBuffer in the caller's GPU schedule.
// frame.texture is RGBA16Float and remains exclusively leased while `frame`
// (or a copy) is retained, and at least through command completion.
```

`HDRProcessor.update(configuration:)` changes only constants. Metal libraries and pipeline
states remain persistent. The output pool has three reusable textures per
stream size so up to three command buffers can be in flight without a new
texture allocation.

## Color behavior

NV12 `420v` and `420f`, plus `32BGRA`, are supported. CoreVideo attachments for
primaries, transfer function, and YCbCr matrix are inspected independently.
Incomplete metadata is rejected; a fallback is used only when all applicable
attachments are absent.

The GPU path performs:

```text
NV12 Y'CbCr -> BT.709/601/2020 RGB signal
             -> SDR inverse transfer (BT.709, sRGB, gamma, or linear)
             -> linear-light luminance tone expansion
             -> luminance-preserving gain and shadow protection
             -> saturation compensation
             -> BT.709 linear RGB to BT.2020 linear RGB
             -> gamut/range compression
             -> EDR linear encoding or ST.2084 PQ encoding
```

EDR output uses linear extended RGB where `1.0` is `paperWhiteNits` and
`masteringHeadroom = peakNits / paperWhiteNits` describes the content signal.
This mastering-domain limit is deliberately independent of the current
physical display headroom. PQ output uses absolute luminance normalized to the
ST.2084 10,000-nit reference.

## Commands

```bash
swift build -c release
swift test
python3 -m unittest discover -s Tests/VerificationTests -p 'test_*.py'
swift run -c release HDRBenchmark --width 1920 --height 1080 --frames 300 --warmup 30
swift run -c release HDRBenchmark --width 3840 --height 2160 --frames 300 --warmup 30
swift run -c release HDRBenchmark --presentation-only --width 3840 --height 2160 --frames 300 --warmup 30
swift run -c release HDRSample --input /path/to/video.mov --frames 3 --mode EDR
swift run -c release HDRPlayer test.mp4 --debug --play-for 10
swift run -c release HDRPlayer --edr-test-pattern --play-for 5
# after `swift build -c release`:
./.build/release/HDRPlayer test.mp4
```

`HDRSample` demonstrates `AVAssetReader -> CVPixelBuffer -> HDRProcessor` and
waits only because it is a command-line validation tool. The realtime API does
not wait, read texture bytes, or perform CPU frame conversion.

The scalar `HDRReference` implementation is test-only in intent and is not
called by `HDRProcessor`.

## HDRPlayer presentation policy

`HDRPlayer` keeps AVPlayer as the audio and media-clock master. It suppresses
AVPlayer's default video presentation, pulls the current PTS-matched frame from
`AVPlayerItemVideoOutput`, sends it through `HDRProcessor`, and encodes the
presentation draw into the same command buffer as the transform.

The layer uses `RGBA16Float` and requests extended dynamic range on capable
screens. Its color space is `extendedLinearITUR_2020` only while current EDR
headroom is active; the SDR fallback is tagged `extendedLinearSRGB`. The player uses Direct EDR policy and
intentionally leaves `CAMetalLayer.edrMetadata` nil; attaching CAEDRMetadata
here would introduce a second system tone-mapping stage. HDRCore emits its
mastering-domain signal, then the fused presentation shader smoothly compresses
only values above reference white from `masteringHeadroom` into the current
physical EDR range. Values at or below 1.0 are unchanged. The mapping is
monotonic and luminance-preserving, and the current/potential display values are
rechecked while the window is on screen and when it moves between screens.

If the display has no current EDR headroom, the player temporarily gives
HDRCore a neutral SDR-safe expansion configuration; the presentation shader
then converts linear BT.2020 to linear sRGB and clamps only in that explicit SDR
fallback branch. The content preset remains unchanged and is restored when EDR
becomes active. The EDR presentation branch never clamps to 1.0. Dynamic EDR
changes use a short time-based smoother that is independent of scene adaptation.
`--edr-test-pattern` renders 1.0, 1.1, 1.25, 1.5, 2.0, 3.0, and 4.0 mastering
patches and logs their mapped values for the current screen.

Controls: Space play/pause, Left/Right seek five seconds, F fullscreen, Esc
exit fullscreen, Up/Down volume, Command-Q quit. `--play-for` is intended for
repeatable wall-clock validation and exits cleanly after the requested time.

## Offline HDR calibration

`HDRCalibrate` is separate from the realtime player. It requires an explicit
authorized SDR/HDR same-content manifest and never treats filenames as proof of
pairing. PQ is decoded to absolute nits; HLG is kept distinct and analyzed with
the documented scene-referred system-gamma model.

```bash
swift run -c release HDRCalibrate validate-dataset \
  --manifest dataset/manifest.json \
  --output results/dataset-report.json

swift run -c release HDRCalibrate run \
  --manifest dataset/manifest.json \
  --seed 42 \
  --output results/calibration.json
```

The tool validates metadata, rejects unknown HDR references, aligns
brightness-invariant structure/PTS descriptors, decodes P010 PQ or modelled HLG,
evaluates the existing HDRCore GPU path offline, records scene-level
luminance/highlight/shadow/color/temporal errors, and keeps
TUNE/VALIDATION/FROZEN splits separate. It emits JSON, CSV, and HTML reports.

The local `data_video/manifest.json` experiment can be rerun with:

```bash
./.build/release/HDRCalibrate validate-dataset \
  --manifest data_video/manifest.json \
  --output results/data-video-dataset-final.json
HDR_CALIBRATION_DEBUG=1 ./.build/debug/HDRCalibrate search \
  --manifest data_video/manifest.json \
  --output results/data-video-calibration-final.json \
  --seed 42
```

The resulting promoted candidate is exported as `results/calibrated-v1.json` and
is selectable without replacing the existing presets:

```bash
./.build/release/HDRPlayer test.mp4 --preset calibrated-v1
```

The larger V2 workflow audits every `data_video` group, holds out whole videos,
uses Tune-only low-discrepancy/global and local search, selects on Validation,
then opens Frozen exactly once. Reproduce the recorded experiment with:

```bash
./.build/release/HDRCalibrate v2-audit \
  --root data_video \
  --output results/data-video-v2-dataset-audit.json
./.build/release/HDRCalibrate v2-run \
  --manifest data_video/manifest-v2.json \
  --seed 20260823 \
  --output results/data-video-v2-final.json
```

The promoted V2 preset remains A/B selectable alongside V1:

```bash
./.build/release/HDRPlayer test.mp4 --preset calibrated-v2
```

The V3 structural audit separates mastering and display headroom, repairs the
previously dead `shadowProtection` control, and evaluates `temporalStability`
with sequential scene windows. Reproduce it with:

```bash
./.build/release/HDRCalibrate v3-run \
  --manifest data_video/manifest-v2.json \
  --seed 20260824 \
  --output results/data-video-v3-final.json
```

V3 improved the aggregate Tune and Validation objectives but regressed the
legacy Frozen video's shadow error and shadow-lift occupancy. It therefore was
not promoted. `calibrated-v2` remains the latest production preset; the rejected
candidate is retained for diagnostics only:

```bash
./.build/release/HDRPlayer test.mp4 --preset calibrated-v3-candidate
```

The repository's example manifest remains intentionally empty and returns
`DATASET_INSUFFICIENT` rather than fitting against a fabricated HDR target.

## V4/V6 correctness workflow

V4/V6 separates Tune/Validation diagnostics from a one-use Virgin Frozen
evaluation. `correctness-review` may prepare and seal the Tune/Validation plan,
but it must report zero objective Frozen evaluations. A V6 Frozen plan is
accepted only when it was explicitly admitted before objective decoding and
its canonical plan hash, sidecar, pair order, media identities, and preparation
configuration all match.

```bash
./RUN_MACOS_VERIFY.sh fast
./RUN_MACOS_VERIFY.sh full
./.build/debug/HDRCalibrate verify-prepared-plan \
  --prepared-plan results/v6-prepared-evaluation-plan.json
```

Fast mode caches expensive media work, but every `data_video` JSON control
file and every cached output artifact is byte-bound to the cache entry. Both
fast and full modes re-run semantic gates and the Swift canonical plan-hash
validator. Missing, stale, incomplete, or consumed holdout evidence fails
closed; it is never converted into a passing verdict.
