# HDRCore

Reusable macOS/Apple Silicon SDR-to-HDR tone-expansion core.

Engineering status: **EXPERIMENTAL**. See the [September engineering audit](docs/ENGINEERING_AUDIT_2026_09_11.md)
for reproduced defects, fixes, verification, and remaining color/holdout limits.
The default preset name does not constitute a production-readiness claim.
The [SDR input policy and proxy PTS report](docs/SDR_INPUT_POLICY_AND_PTS_FIDELITY_REPORT.md)
records the versioned SDR transfer interpretation and source-PTS proxy changes.
The [open-content V4 calibration report](docs/OPEN_CONTENT_V4_CALIBRATION_REPORT.md)
records the one-use Virgin Frozen result (VIRGIN_FROZEN_FAIL: +3.48% over V2,
below the 5% gate). The [robustness study report](docs/ROBUSTNESS_STUDY_REPORT.md) measures V4 on
noisy, compressed, upscaled and banded SDR and documents the opt-in
noise-gated gain guidance (`--gain-guidance noise-gated`). Next steps and the
evidence behind them are in [improvement research notes](docs/IMPROVEMENT_RESEARCH_NOTES.md).
The [open-content v2 Frozen result](docs/OPEN_CONTENT_V2_FROZEN_RESULT.md) records the second
one-use Virgin Frozen evaluation (PROMOTE_CALIBRATED_V4: +23.07% over V2), which made
`calibrated-v5` the default preset.
The [open-content v2 dataset](docs/OPEN_CONTENT_V2_DATASET.md) adds a new,
unexposed Virgin Frozen holdout and rebalances Tune across grading styles.
The [development roadmap](docs/DEVELOPMENT_ROADMAP.md) orders the next steps:
the decision protocol first, then a shape-only objective, then algorithm candidates.
The [v2 policy comparison](docs/OPEN_CONTENT_V2_POLICY_COMPARISON.md) records why the new holdout
stays sealed: no variant passes the leave-one-family-out gate (broadcast HLG vs streaming highlight shape).

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

### SDR renditions of YouTube HDR uploads

When an upload is HLG HDR, YouTube also serves an SDR rendition. That SDR file
is YouTube's automatic conversion, not a separate grade.
`--sdr-transfer youtube-hlg-v2` inverts that conversion: a 17-knot curve back
to the HLG signal, then the HLG inverse OETF with a luminance OOTF.

Results against YouTube's own HLG rendition (open-content v2, round 7):

| family | error / V2, default decode | error / V2, `youtube-hlg-v2` |
|---|---:|---:|
| KBS uploads | 0.905 | 0.384 |
| other uploaders (fancam) | 0.824 | 0.430 |
| fancam, Validation pairs only | 0.900 | 0.545 |

- The fancam pairs are other uploaders and were never used to fit the curve.
- The absolute level is within about 6% of the HDR rendition (median level gain 0.93–0.95). The default decode is 20–30% too dark.
- Use the flag only for such renditions. An upload that is SDR at the source has no HDR original, and the curve does not apply to it.

YouTube serves VP9 or AV1, usually in WebM. AVFoundation cannot open WebM or
decode its VP9 (checked on an M2), and AV1 may fail too. `HDRPlayer` converts
such an input once with VideoToolbox HEVC, then plays it:
- colour tags are kept;
- 10-bit sources stay 10-bit (Main10) and keep their transfer (checked with HLG);
- the copy goes to `.build/converted/` beside the binary, or to `--convert-dir DIR`;
- the copy is reused while the source file is unchanged.

```bash
./.build/release/HDRPlayer "video.webm" --sdr-transfer youtube-hlg-v2
```

`--no-convert` turns this off. `HDRSample` and `--no-convert` print the
equivalent ffmpeg command instead.

**`HDRPlayer` decodes BT.709 SDR with `youtube-hlg-v2` by default.**
- Press **Y** (보기 menu, or the settings window) for a video that was SDR at the source. This switches to the plain BT.709 inverse OETF while the video keeps playing.
- The window title shows the active decode.
- `--sdr-transfer bt709-oetf` starts in that mode.
- The calibration presets and `HDRSample` keep the historical inverse OETF.

### Skin highlight protection

SDR has no way to tell bright diffuse skin from a specular highlight: both sit near the top of the code range. The expansion curve sends that range towards peak brightness.

On toon-shaded CG and anime (MMD renders, for example), large bright skin areas then glow white:
- with `calibrated-v5`, skin at (255, 232, 220) came out at 1032 nits;
- pure white comes out at 1323 nits.

`HDRPlayer` enables skin protection by default (`--skin-protection off|weak|on`, also in settings).

How it works:
- **Candidates:** bright warm or neutral pixels.
- **Skin colour:** red is the largest channel, hue runs from pale pink (−25°) to cream yellow (60°), and saturation is 0.025–0.55.
- **Ring test:** 16 samples on two rings around the pixel (radius 1.2% and 2.4% of the frame height). Each is checked for being at least 85% as bright as the pixel, and for being skin-coloured.
- **Compressed:**
  - skin-coloured pixels inside a broad bright area, including its edges next to dark hair;
  - highlights of any colour surrounded by equally bright skin, such as a white toon highlight on the nose.
- **How:** above 0.9× paper white, the slope eases from 1 to 0.02, so skin settles at about SDR white (at most about 1.1×) and its shading keeps its order.
  - The ceiling sits just under paper white because many displays have little EDR headroom: about 2× on a MacBook Air, less at high brightness.
  - The player squeezes everything above SDR white into that narrow range and desaturates the top of it. Skin even 1.3–1.5× paper white then ends up next to real whites and reads as glowing white.
  - The YouTube decodes use a lower ceiling, 0.75×. They render skin about 1.5× more saturated, and saturated bright colour looks brighter than its luminance.
- **Kept:** eye glints on the iris, glints on darker skin, neutral white, cool and strongly saturated colours.

| `calibrated-v5`, BT.709 decode | before | broad skin | small glint |
|---|---:|---:|---:|
| pale pink (255, 238, 238) | 1153 nits | 222 nits | 1153 nits |
| peach (255, 232, 220) | 1032 nits | 219 nits | 1032 nits |
| white (255, 255, 255) | 1323 nits | 1323 nits | 1323 nits |

Measured on a real MMD render (1080p60 H.264) through the player pipeline. Values are in multiples of paper white (1.0 = SDR white):

| `calibrated-v5`, bright skin | median | p90 | p99 | white |
|---|---:|---:|---:|---:|
| BT.709 decode, protection off (face close-up) | 3.07 | 5.12 | 5.77 | 6.27 |
| BT.709 decode, protection on | 1.04 | 1.08 | 1.10 | 6.27 |
| YouTube decode, protection off | 0.70 | 1.23 | 3.43 | 6.20 |
| YouTube decode, protection on | 0.70 | 0.84 | 0.90 | 6.20 |

Thin limbs count as broad skin as well. In a full-body shot with raised arms, BT.709 skin p90 went from 4.82 to 1.11.

Calibration presets keep it off (`HDRConfiguration.skinHighlightProtection = 0`).

### Upscaling, settings and the playback bar

`HDRPlayer` upscales the processed HDR frame with **MetalFX spatial scaling** before presentation:
- `--upscale off|1.5x|2x|auto`; the default `auto` goes up to the size the video occupies on screen.
- Factors never exceed the on-screen size, and a video already at least as large as its window is not upscaled.
- The scaler runs in its HDR mode on the linear EDR frame. The presentation shader then clamps each sample to the 2×2 source texels around it (anti-ringing), so sharpening adds no halo.
- On a hard HDR edge (0.2 → 2.0) at 4× display size:
  - 10–90% edge width: 2 px, against 4 px for bilinear;
  - overshoot: 0% with the clamp, against 15.5% without it.
- Cost: about 1 ms of GPU per frame for 360×640 → 704×1280 on an M2. GPU render p50 went from 1.9 to 3.0 ms.

The window has a playback bar: play/pause, position, a seek slider, duration and a settings button.
- It appears when the mouse moves and hides after a few seconds of playback.
- The settings window (⌘, or the gear) switches preset, SDR decode and upscaling while the video plays.
- The app remembers these choices.

### Opening videos from Finder

```bash
scripts/make-hdrplayer-app.sh   # builds HDRPlayer.app in this folder
```

Then, for any video:
- **Right-click → Open With → HDRPlayer**; or
- **Get Info → Open with: HDRPlayer → Change All…**, after which a double-click opens HDRPlayer.

How the app behaves:
- Double-clicking the app itself asks for a file.
- File → Open (⌘O) replaces the current video.
- WebM/VP9 is converted on first open into `.build/converted/`.
- The app remembers your last Y choice.
- The app is signed ad hoc and lives only in this folder.

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

`prepare-frozen-plan` builds that plan: it decodes and aligns only the Virgin
Frozen pairs with the Tune/Validation preparation settings and seals the
decisions, without evaluating any objective. Run-level policies (for example
`--sdr-transfer`) are compared with `v4-run --stop-before-frozen`, which stops
after Validation selection and the pre-Frozen gates, so the one-use holdout
is opened once, for the chosen policy only.

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
