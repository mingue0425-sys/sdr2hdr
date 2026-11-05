# SDR input policy and proxy PTS fidelity

Date: 2026-11-05

This change resolves two HIGH items from the
[Astra fixset review](ASTRA_FIXSET_INDEPENDENT_REVIEW.md#residual-risks-and-deferred-work):
the unversioned SDR transfer interpretation and the FFmpeg proxy's
synthesized timeline. It is not a calibration, quality approval, or Frozen
evaluation.

## Boundary

No Frozen, Virgin Frozen, holdout, or `data_video` media was enumerated,
opened, decoded, or hashed. All media used in tests was generated
synthetically with `ffmpeg` (`lavfi` sources) in a temporary directory. No
preset was retuned and no candidate was promoted. Objective evaluations: 0.

## 1. Versioned SDR transfer interpretation

`HDRSDRTransferInterpretation` names the convention used to linearize
BT.709-tagged SDR:

| Case | Identifier | Decode |
|---|---|---|
| `bt709InverseOETFSceneLinear` (default) | `bt709-inverse-oetf-scene-linear-v1` | inverse BT.709 OETF |
| `bt1886DisplayReferred` | `bt1886-display-eotf-gamma2.4-lb0-v1` | `V^2.4` (BT.1886, Lb = 0) |

* Only the `.bt709` tag is rewritten (to the new `.bt1886` decode). sRGB,
  explicit gamma, and linear tags are unambiguous and never change.
* The choice reaches the Metal shader (`transferFunction == 4`),
  `HDRReference`, `HDRFrameMetadata`, debug diagnostic snapshots, the offline
  `linearLumaGrid` sampler, and `--sdr-transfer` in `HDRPlayer`/`HDRSample`.
* `HDRProcessor.update(configuration:)` switches the policy as a constant
  change; no pipeline is rebuilt.
* Every preset keeps the historical default, so production output is
  unchanged. Adopting BT.1886 in a preset requires a calibration rebase that
  records the identifier. A non-zero black level (Lb > 0) is not modelled;
  it would need a new identifier.

Regression coverage: `SDRTransferInterpretationTests` (independent `pow`
anchors, GPU/reference parity for both policies, preset defaults, constant
update), `AuditIntegrityTests.testSourceLinearLuminanceFollowsSDRTransferInterpretation`,
and `PlayerLogicTests.testSDRTransferInterpretationOptionReachesConfiguration`.
A deliberate shader mutation (case 4 decoding as inverse BT.709) produced 10
assertion failures and was then reverted.

## 2. FFmpeg proxy source PTS / VFR fidelity

Previously, the proxy used `fps=N:round=up` and assigned each frame
`start + index / N`. For VFR input this duplicated frames across gaps and
replaced real presentation times with a uniform grid. Source ordinals were
inferred from the nominal rate.

The proxy now uses `ffmpeg-proxy-copyts-slot-select-source-pts-v1`:

* `-copyts` and `-fps_mode passthrough`: source timestamps are kept, and
  frames are never duplicated or re-timed.
* At or above the native rate, every source frame passes. Below it, a
  slot-based `select` passes the first frame of each `1/fps` slot measured
  from the first decoded frame, and empty VFR slots stay empty.
* `showinfo` supplies each frame's integer PTS and filter time base. The
  rounded `pts_time` text is never used.
* An ffprobe packet table (demux only, no decode) maps each PTS to its
  presentation-order source ordinal. Edit-list pre-roll before the stream
  start is excluded.
* The read fails closed if a frame time is not in the source table, if a frame
  is duplicated, if ordinals or timestamps are non-monotone, or if a source
  packet has no PTS.
* `FrameSequence.temporalProvenance` records the policy, source timestamps,
  ordinals, skipped-frame counts, duplicate count (always 0), and VFR status.
  The AVAssetReader path records `avassetreader-presentation-order-stride-v1`,
  with VFR status `nil` because it does not observe the full timeline.

Because decoder semantics are part of a prepared plan, the identifiers
changed. The preparation version is now
`v6-prepared-evaluation-plan-v6-source-pts-proxy`, and
`frameDecoderPolicy` is now
`FrameReader.auto(avfoundation-pts;ffmpeg-fallback-copyts-slot-select-source-pts-v1)`.
The checked-in `results/v6-prepared-*.json` plans were already at
the older `v6-prepared-evaluation-plan-v4` identifier and were already
rejected. No current-version evidence is invalidated.

Regression coverage: `ProxyTemporalFidelityTests` covers the showinfo parser,
packet-table mapping, drop provenance, fail-closed duplicates and synthesized
times, edit-list pre-roll, and the selection rule. It also runs two ffmpeg
integration cases:

* A VFR clip (same construction as `h264-8-video-vfr-motion`) is read at its
  native rate. Timestamps match ffprobe packet times, ordinals are `0..<12`,
  and VFR gaps are preserved.
* A 24 fps CFR clip is read from 0.25 s at 12 fps. Ordinals are
  `[6, 8, 10, 12]`, one frame is skipped between samples, and timestamps are
  `ordinal / 24`.

## Verification

Run on Apple Silicon with Swift 6.4.2. The Metal Toolchain component is not
installed here, so all commands used `--build-system native` (runtime shader
compilation).

| Check | Result |
|---|---|
| `swift test` (unit + GPU) | 366 tests, 0 failures, 17 fixture-gated skips |
| Real-media integration (self-contained 8-bit, P010, automatic decode) | 7 tests, 0 failures |
| Manifest-driven regression matrix | 12 fixtures, 0 failures, 0 skipped |
| Real-media multi-flight | pass |
| `Tests/verify_no_frozen_access.py --scope config/pre-frozen-seal-scope.json` | PASS |
| `HDRSample --sdr-transfer bt709-oetf/bt1886/<invalid>` | both policies run; invalid value rejected |

## Remaining

* **Calibration rebase.** This still requires authorized SDR/HDR pairs. The
  rebase must pick an SDR interpretation identifier, pass it to
  `linearLumaGrid` for source metrics, and regenerate Tune/Validation plans
  under the new preparation identifier.
* **SDR/HDR temporal pairing.** Window frames are still paired by sequence
  position. Real PTS and provenance now make a PTS-based pairing check
  possible, but it is not yet enforced.
* The other residual items from the Astra review are unchanged: build
  provenance, sparse temporal statistics and scheduling, superwhite/negative
  values, and physical display measurement.

```text
ENGINE STATUS:                 EXPERIMENTAL
CALIBRATION STATUS:            REBASE_REQUIRED
PRODUCTION QUALITY APPROVED:   NO
Frozen accessed:               NO
Objective evaluations:         0
```
