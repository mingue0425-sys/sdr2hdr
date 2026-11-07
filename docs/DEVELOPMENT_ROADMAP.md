# Development roadmap after open-content V4 (2026-11-06)

This roadmap combines three independent read-only reviews:
1. objective and evaluation science
2. the expansion algorithm
3. data, process and product

No media was opened for any of them. Claims checked against the code are marked ✔.

## Where all three agree

**Calibrate the curve shape, and make absolute brightness a setting.**
- The masters disagree on diffuse white (224–450 nits against 3.6–87). Every review independently concluded that a single absolute target is ill-posed.
- In EDR mode, 1.0 is the OS SDR white anyway, so the user's display, not the master, decides absolute level.

## Findings that change the plan

1. **The winner's curse dominates.** The gain shrinks from Tune to Validation to Frozen: 10.4% → 5.25% → 3.48%. Offline reselection on Tune-only search results shows:
   - Choosing the candidate on Sol Levante alone gives −13% on K-Choreo, whose own best candidate would give +16%.
   - Holding out Sol Levante t030 gives 3.0% on that pair, against 11.1% in-sample.

   Larger searches make this worse, not better.
2. **Pair weighting: claim corrected.** One review read `V2MetricsEvaluator.aggregate` (a plain pair mean) as the Frozen rule. ✘ In fact the V4 runner already family-balances every split (`familyBalanced`), so each v2 Frozen family carries half of the verdict. The effective N is still 2 families.
3. **The objective is not gain-invariant.** ✔ The objective uses `log((x+1)/(r+1))`. The +1 makes it brightness-dependent on dark masters.
4. **The "diffuse white" reported per pair is the reference p90.** That is scene brightness, not grading level.
   - StEM2 t300's 3.6 nits is a dark scene.
   - Any normalization must therefore be per family, not per scene.
5. **The gate compares against V2 only.** On StEM3 the default beat the whole V2 family by 6–8%, so a "pass" could still regress against what ships.

## Ordered plan

### 1. Preregistered decision protocol, before anything touches the v2 Frozen
Cost: none.

- **Aggregation:** average within each family first, then across families.
- **Gain margin:** family-mean improvement of at least the preregistered margin (+2–5%).
- **No regression:** no family worse than −2% against **both** V2 and the shipping default.
- **Safety:** hard-safety gates unchanged.
- **Readiness before opening:** leave-one-family-out over the 4 non-Frozen families (Sol Levante, K-Choreo, StEM3, StEM2).
  - The worst held-out family must reach at least 2× the margin.
  - No held-out family may be negative.
  - Otherwise Frozen is not opened.
- **Reported only, never gating:** bootstrap CIs (pair, then family), ΔE ITP, and the absolute objective.
- **After a fail:** no metric swap and no reopening.

The new protocol identifier goes into the manifest, and its hash is committed before plan admission. `objectiveHash` already covers new configuration fields.

### 2. Shape-only objective plus a brightness knob
About 2–3 days.

- **Objective:** in `V2Metrics.evaluateScene`, fit one log-gain `k` per family over source midtones (0.15–0.45), clamped to [0.25, 4].
  - Score luminance, midtone, diffuse white, highlight and shadow on `k·gen`.
  - Clipping and black crush stay on the unscaled output.
  - Use `log(max(x, ε))` instead of `log(x+1)`.
- **Renderer:** replace the hidden low-mid gain (about ×1.21, tied to `peak/paperWhite`) in `toneExpand` with:
  - an explicit `midtoneExposure`
  - a `referenceWhite` setting, default 203 nits (BT.2408)

  Peak headroom then affects only the shoulder.
- **Product:**
  - One user control, "HDR intensity" (Subtle / Standard / Vivid).
  - At most two presets: Faithful (BT.2408) and Vivid.
  - Add SDR passthrough to the player's A/B toggle.

### 3. Algorithm candidates, each searched under protocol 1
| proposal | mechanism | cost | target |
|---|---|---|---|
| Display-referred midtones | `mix(OETF⁻¹(V), V^2.4, smoothstep(0.10, 0.30, V))`. Shadows are identical to V2, so it adds no crush. | 0 | StEM3 midtone gap |
| Stable scene anchors | Own time constant (0.5–1 s) for shadow anchors, hysteresis, snap on cut, denser bins | <0.02 ms | dark-midtone flicker (~15% gain swing at y=0.08) |
| Area-aware shoulder | Bright-area mask at 1/16 resolution. Specular spots get full expansion; large bright areas stay near diffuse white. | 0.3–0.5 ms | highlight/diffuse terms, grain amplification in flat highlights |
| Faster guidance | Early-out below the shoulder, polynomial weight, half accumulation | 4.9 → ~2.5–3 ms | makes `noise-gated` affordable as the player default |
| Constant-hue desaturation | Chroma reduction in ICtCp | ~0.1 ms | only if the hue terms matter |

### 4. Data
- **Sparks in Validation.**
  - Use new windows away from the consumed f04133/f08266.
  - CC BY 4.0, Netflix bucket. It is the first bright Dolby-Vision-graded Validation family outside K-Choreo.
  - The download needs approval.
- **Cosmos Laundromat.**
  - SDR PNG (2015) and HDR P3PQ EXR (2017) renders.
  - Same source, not the same master. Admit it only if the alignment audit passes.
- **Self-generated ACES 2.0 renders** of open EXRs or own footage.
  - An unlimited, hash-sealed holdout supply.
  - It is an algorithmic grade, so it forms a separate stratum and never enters the headline metric.
- **Rolling ladder.**
  - A family enters as sealed Frozen and is opened at most once.
  - It then moves down to Validation, and later to Tune.
  - Never take a second window of a Frozen title.
- **Margins from viewers.** A small blind pairwise study (5–10 viewers) to set the margins, instead of the arbitrary 5%.

## Not worth doing
- An SDR-statistics → parameter predictor, or automatic grading-style detection. Correlations flip sign across families.
- Larger or finer searches. They feed the winner's curse.
- HDR-VDP or ColorVideoVDP as the objective. The cost is high, and they measure visibility, not fidelity to a grade.
- Gamut expansion beyond BT.709. The masters stay inside 709.
- Learned ITM networks (HDRTVNet-type). They break the realtime budget and N is tiny.
- New cheap codec-artifact detectors. They already failed.
- Temporal denoising.
- Meridian (no SDR deliverable) and HDRTV1K/4K (synthetic SDR, unclear license).
- Reweighting Tune toward guesses about the Frozen content.
