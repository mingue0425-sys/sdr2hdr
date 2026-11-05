# HDRCore

Reusable macOS/Apple Silicon SDR-to-HDR tone-expansion core.

Engineering status: **EXPERIMENTAL**. See the [September engineering audit](docs/ENGINEERING_AUDIT_2026_09_11.md)
for reproduced defects, fixes, verification, and remaining color/holdout limits.
The default preset name does not constitute a production-readiness claim.
The [SDR input policy and proxy PTS report](docs/SDR_INPUT_POLICY_AND_PTS_FIDELITY_REPORT.md)
records the versioned SDR transfer interpretation and source-PTS proxy changes.
The [robustness study report](docs/ROBUSTNESS_STUDY_REPORT.md) measures V4 on
noisy, compressed, upscaled and banded SDR and documents the opt-in
noise-gated gain guidance (`--gain-guidance noise-gated`).

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

NV12 `420v` and `420f`, 10-bit bi-planar video/full-range P010, and `32BGRA` are supported. CoreVideo attachments for
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

### SDR input interpretation policy

BT.709-tagged SDR can be linearized two ways, and they are not
interchangeable. `HDRConfiguration.sdrTransferInterpretation` makes the choice
explicit and versioned:

| Policy | Stable identifier | Decode |
|---|---|---|
| `.bt709InverseOETFSceneLinear` (default) | `bt709-inverse-oetf-scene-linear-v1` | inverse BT.709 camera OETF (scene-linear) |
| `.bt1886DisplayReferred` | `bt1886-display-eotf-gamma2.4-lb0-v1` | BT.1886 reference EOTF, Lb = 0 (`V^2.4`) |

The policy rewrites only the BT.709/BT.2020 SDR transfer tag. sRGB, explicit
gamma, and linear tags are unambiguous and are decoded as tagged under either
policy. The same choice reaches the Metal shader, `HDRReference`,
`HDRFrame.metadata.sdrTransferInterpretation`, debug diagnostics, and
`OfflinePixelSampler.linearLumaGrid(..., sdrTransferInterpretation:)`.

Every preset, including the production default, keeps the historical
inverse-OETF convention, so existing output does not change. The default
inverse-OETF convention does not guarantee faithful reproduction of
display-mastered SDR, including the neutral SDR fallback. BT.1886 is an
explicit opt-in (`--sdr-transfer bt1886` in `HDRPlayer` and `HDRSample`). A
preset may adopt it only after a calibration rebase that records the policy
identifier.

## Commands

```bash
swift build -c release
swift test
python3 Tests/verify_no_frozen_access.py
python3 Tests/verify_no_frozen_access_test.py
bash Tests/verify_script_cache_test.sh
swift run -c release HDRBenchmark --width 1920 --height 1080 --frames 300 --warmup 30
swift run -c release HDRBenchmark --width 3840 --height 2160 --frames 300 --warmup 30
swift run -c release HDRBenchmark --presentation-only --width 3840 --height 2160 --frames 300 --warmup 30
swift run -c release HDRSample --input /path/to/video.mov --frames 3 --mode EDR
swift run -c release HDRSample --input /path/to/video.mov --frames 3 --sdr-transfer bt1886
swift run -c release HDRPlayer test.mp4 --debug --play-for 10
swift run -c release HDRPlayer test.mp4 --sdr-transfer bt1886
swift run -c release HDRPlayer test.mp4 --gain-guidance noise-gated
swift run -c release HDRPlayer --edr-test-pattern --play-for 5
# after `swift build -c release`:
./.build/release/HDRPlayer test.mp4
```

Shader libraries load from whichever layout the build produced, via
`HDRMetalLibraryLoader`. With the Metal Toolchain installed
(`xcodebuild -downloadComponent metaltoolchain`), the default build system
precompiles each target's shaders into `default.metallib`. Without the
toolchain, `swift build`/`swift test` need `--build-system native`; the
bundled `.metal` sources are then compiled at runtime. A precompiled library
is used only if it exposes every required kernel.

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

The historical V2 preset remains A/B selectable alongside V1 and the promoted
V4 preset:

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
not promoted. The validated V4 candidate is now the production default;
`calibrated-v2` remains available for A/B and historical reproduction, and the
rejected V3 candidate is retained for diagnostics only:

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

Fast mode caches expensive preparation/evaluation work. Explicit manifest/lock
control files, Swift/Metal sources and cached output artifacts are byte-bound
to the cache entry. Tune/Validation media bytes are validated against their
locked digests even on cache hits. Both
fast and full modes re-run semantic gates and the Swift canonical plan-hash
validator. Missing, stale, incomplete, or consumed holdout evidence fails
closed; it is never converted into a passing verdict.

The audit changed source metric grids from encoded Y' to metadata-aware linear
luminance, preserved source color metadata through FFmpeg proxy/window decoding,
and explicitly normalized raw proxy samples to video range. It advanced the preparation policy to
`v6-prepared-evaluation-plan-v5-linear-source-luminance`. Previous prepared
plans are rejected; old objective scores are historical evidence, not scores
for this implementation. Regenerate Tune/Validation evidence before promotion.

The FFmpeg proxy now keeps source timing (`ffmpeg-proxy-copyts-slot-select-source-pts-v1`).
It decodes with `-copyts` and `-fps_mode passthrough`. Below the native rate it
decimates with slot-based `select` and never duplicates frames, and it reads
each frame's integer PTS from `showinfo`. Each frame maps to its
presentation-order source ordinal through an ffprobe packet table. A
synthesized, duplicated, or non-monotone frame fails closed.
`FrameSequence.temporalProvenance` records source timestamps, ordinals, skipped
frames, and VFR status. The preparation identifier advanced to
`v6-prepared-evaluation-plan-v6-source-pts-proxy`. As a result, plans prepared
with the old `fps`-resampled proxy are rejected.

The V4/V6 evaluator now writes exclusive per-asset consumption receipts to
`.hdr-frozen-consumption/` before opening objective media. Preserve this directory
when cleaning results or moving the repository. A crash, partial receipt, or
failed evaluation does not permit retry. This local guard is independent of
output/candidate/plan names; it cannot prevent manual deletion, another checkout,
alternate encodes, or direct use of historical evaluators. Independent holdout
custody is still required for a strong one-use protocol.
