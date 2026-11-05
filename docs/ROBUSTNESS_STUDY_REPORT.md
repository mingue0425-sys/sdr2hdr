# Robustness on noisy and low-quality SDR input

Question: does calibrated V4 still help when the SDR input is noisy,
heavily compressed, upscaled or banded? If not, how can it be improved?

Command (Tune pairs only; Validation and Frozen are never opened):

```
HDRCalibrate robustness-study --manifest data_video/open-content/manifest.json \
  --output results/robustness-v1/robustness-study.json
```

Report: `results/robustness-v1/robustness-study.json` (schema `robustness-study-v3`; the v2 run is kept as `robustness-study-v2.json`).

## Design

- 5 Tune pairs (Sol Levante t030/t090/t150/t175, K-Choreo video3), 24 frames
  each, 960 px wide, full-resolution PQ-domain metrics against the HDR master.
- A clean 8-bit 4:2:0 working clip and 7 degradations of it: temporal noise
  (strength 6 and 14), H.264 CRF 32 and 42, 320 px downscale then upscale,
  6-bit luma banding, and noise followed by CRF 35.
- Configurations: `no-expansion` (V4 with every expansion strength at 0),
  `calibrated-v4`, and V4 with noise-gated gain guidance.
- **Benefit** is the PQ error of `no-expansion` minus that of the candidate.
  A positive value means the candidate is closer to the HDR master.
- **Artifact amplification** compares added high-pass energy in flat
  highlights (reference > 2× paper white).
  - Added energy is sqrt(HP²(variant) − HP²(clean)).
  - Amplification is the candidate's added energy divided by that of
    `no-expansion`, pooled over pairs.
  - A value of 1 means expansion does not stretch the injected artifact.

## Findings

Values below are means over 5 pairs, in units of 10⁻³ PQ.

| input | V4 benefit (all / highlight) | V4 amplification | guided r2 t0.12 benefit | guided amplification |
|---|---|---|---|---|
| clean | +16.8 / +95.3 | – | +16.2 / +89.5 | – |
| noise 6 | +16.5 / +93.3 | 4.14 | +16.0 / +88.4 | 1.08 |
| noise 14 | +16.1 / +88.6 | 4.03 | +15.7 / +86.7 | 1.20 |
| CRF 32 | +16.3 / +89.7 | 3.73 | +16.0 / +86.8 | 1.31 |
| CRF 42 | +15.4 / +81.7 | 3.20 | +15.3 / +80.3 | 2.15 |
| low-res upscale | +15.9 / +85.3 | 3.39 | +15.7 / +82.8 | 2.88 |
| 6-bit banding | +16.1 / +92.0 | 4.17 | +15.6 / +86.4 | 0.89 |
| noise 10 + CRF 35 | +15.8 / +85.9 | 3.20 | +15.6 / +83.7 | 1.31 |

1. **V4's benefit holds on degraded input.** The highlight benefit keeps
   86–98% of its clean value under every degradation; the worst case is CRF 42.
2. **The weakness is artifact amplification.** The expansion curve's log-slope
   exceeds 1 in highlights. The per-pixel gain therefore stretches grain,
   banding steps and codec blocking in flat bright areas to 3.2–4.2× what an
   unexpanded mapping shows.
3. **Noise-gated gain guidance largely removes that amplification.**
   - Mechanism: the gain is evaluated at a range-gated (bilateral) 5×5 local
     mean of luma and applied to the pixel. Fluctuations below the tolerance
     keep their source contrast; edges above it keep the per-pixel gain.
   - At radius 2 and tolerance 0.12, amplification drops to 0.9–1.3× for
     noise, banding and moderate compression.
   - Cost: about 6% of the highlight benefit and 4% of the overall benefit.
   - Residuals for CRF 42 and low-res upscale (2.2× and 2.9×) are about one
     10-bit PQ code in absolute terms: 0.91 and 0.68 × 10⁻³ PQ of added energy.
4. **Parameter sweep:**
   - Higher tolerance helps monotonically (0.05 → 0.08 → 0.12).
   - A wider radius (3 or 4) is no better than radius 2 at equal tolerance.

## Decision

- Gain guidance ships **opt-in** as `HDRGainGuidance.noiseGatedCandidate`
  (radius 2, tolerance 0.12):
  - `HDRPlayer <file> --gain-guidance noise-gated`
  - `HDRSample --input <file> --gain-guidance noise-gated`
- Every preset keeps `.off`, so production output stays bit-identical.
- Adopting it in a calibrated preset requires a V4 run that searches it and
  passes Validation, followed by the one-use Frozen evaluation.
- Recommended for grainy, heavily compressed or banded sources.

## Noise-adaptive tolerance (robustness-study-v3)

A fixed tolerance has to choose between two goals:
- preserving texture expansion on clean input
- suppressing artifacts on degraded input

The v3 study measures each clip's luma noise sigma with Immerkær's fast estimator (median over frames) and sets the tolerance to clamp(k·σ, min, 0.15).

The estimated σ in signal units was:
- clean 0.008
- noise 6: 0.013
- noise 14: 0.028
- every compressed or upscaled variant: 0.002–0.004

| input | V4 highlight benefit | fixed t0.12 | adaptive k3 (min 0.02) | adaptive k4 (min 0.05) |
|---|---:|---:|---:|---:|
| clean | 95.3 | 89.5 | **94.3** | 93.0 |

| amplification | V4 | fixed t0.12 | adaptive k3 | adaptive k4 |
|---|---:|---:|---:|---:|
| noise 6 | 4.14 | **1.08** | 1.48 | 1.33 |
| noise 14 | 4.03 | **1.20** | 1.36 | 1.21 |
| CRF 32 | 3.73 | **1.31** | 4.17 | 2.63 |
| CRF 42 | 3.20 | **2.15** | 3.28 | 2.82 |
| low-res upscale | 3.39 | **2.88** | 4.32 | 3.49 |
| 6-bit banding | 4.17 | **0.89** | 1.86 | 1.27 |

- **Clean and noisy input:** adaptive k3 keeps almost all of the clean benefit (−1% against −6% for the fixed tolerance) and still cuts noise amplification to 1.2–1.5×.
- **Compressed, upscaled and banded input:** blocking, ringing and banding are structured, not random. The noise estimator reports little noise, the tolerance falls to the floor, and the artifacts are not suppressed.
- **The opt-in default stays the fixed `noise-gated` setting** (radius 2, tolerance 0.12), because it is the only setting that is robust across every degradation.
- **Next step:** an artifact-aware floor, using 8×8 block-boundary energy and luma histogram gaps, with tolerance = max(noise term, artifact term).

## Cost

Measured at 4K on an Apple M2 (GPU p50, `HDRBenchmark --gain-guidance`):

| | before | after |
|---|---:|---:|
| guidance off | 1.78–1.82 ms (inline guidance code) | 1.68–1.73 ms (dedicated kernels, same as before guidance existed) |
| `noise-gated` | 6.2 ms | 4.9 ms |

How the cost came down:
- Guidance now runs in separate `sdr*ToHDRGuided` pipelines, so the realtime kernels carry no guidance code.
- At radius 1–2 the window uses 9 gathers instead of 25 reads.
- A test-only reference path checks the gather window against per-texel reads: at most 1 half-float ULP of difference, on at most 0.5% of values. A wrong-texel mutation fails that test.

## Measurement bug found and fixed

The first two runs were invalid for video3.

- **Cause:**
  1. A `-ss` seek that lands between source frames leaves the cut clip with a
     small positive start time (0.0167 s).
  2. QuickTime stores that offset as an empty edit.
  3. AVAssetReader then emits a synthetic black frame at t=0, so every frame
     moves back by one.
  4. The clean clip and the reference both had the offset, so they lined up
     with each other. Re-encoded variants started at 0 and were compared one
     frame off the reference.
- **Symptom:** temporal error std rose from 12.6 to 102.6 for every video3
  variant, including mild noise.
- **Fix:**
  - Prepared cuts are rebased with `setpts=PTS-STARTPTS`.
  - `RobustnessStudy.requireZeroStart` rejects any clip whose container
    start is not 0.
  - `RobustnessStudyTests.testPreparedClipsStartAtZeroWithoutSyntheticLeadingFrame`
    reproduces the bug with a 60 fps fixture.
- **Scope:** the main calibration pipeline reads original sources, not cut
  intermediates. Every Tune and Validation source starts at 0, verified from
  container headers only.
- The invalid runs are kept for audit as
  `results/robustness-v1/robustness-study-run{1,2}-*.json`.

## Limits

- Tune pairs only, 24 frames each. The study is diagnostic and is not a
  holdout evaluation.
- The degradations are synthetic. Real camera noise and real codec stacks
  may differ.
- High-pass energy in flat regions is a proxy for visible artifacts. It is
  not a perceptual metric.
