# Where the remaining error is, and what could reduce it (2026-11-07)

Inputs: round-2 shape-oetf run (`results/open-content-v2/round2/v4-shape-oetf/`). This covers 23 Tune/Validation pairs in 6 families and 105 Tune/Validation-safe candidates, all already scored. No Frozen media was touched. Nothing below required new rendering, except §3, which decodes Tune/Validation luma only.

## 1. Error budget of the selected candidate (`global_047`)

The table gives each weighted objective component's share of the family-balanced total.

| component | share |
|---|---:|
| shadow | 28% |
| luminance | 23% |
| highlight | 19% |
| diffuse white | 13% |
| midtone | 11% |
| colour (hue, chroma, saturation), structure, temporal | ≈ 7% together |

- **Tone mapping dominates.** Nearly all remaining error is in tone mapping (luminance level and shape); colour and temporal terms are small.
- **Sparks has the largest error.** Its total is 0.71. Its shadow term is 0.25, with `shadowLiftRatio` 1.0: every shadow sample is brighter than the master's.
- **K-Choreo and KBS One-take overshoot the highlights.**
  - Overshoot ratio is 0.48–0.58.
  - Generated diffuse white is 360–378 nits against 290–307 nits in the reference.
- **Sol Levante under-reaches the highlights.**
  - Under-reach ratio is 0.48.
  - Generated diffuse white is 274 nits against 332.

## 2. The conflict is structural: broadcast and cinema want opposite highlight expansion

The table gives the Spearman correlation between each candidate parameter and the family objective, across the 105 safe candidates. A negative value means a larger parameter is better.

| family | highlightStrength | displayHeadroom | peakNits |
|---|---:|---:|---:|
| ASC StEM2 | −0.64 | −0.56 | −0.51 |
| ASC StEM3 | −0.62 | −0.57 | −0.51 |
| Sol Levante | −0.54 | −0.36 | −0.32 |
| Sparks | −0.62 | −0.57 | −0.51 |
| **K-Choreo** | **+0.59** | **+0.60** | **+0.56** |
| **KBS One-take** | **+0.61** | **+0.58** | **+0.54** |

Within the existing candidate pool, the best candidate per family gives the following objectives.

| family | `global_047` | own best |
|---|---:|---:|
| K-Choreo | 0.248 | 0.214 (`local_032`, −14%) |
| KBS One-take | 0.247 | 0.216 (`local_032`, −12%) |
| every cinema family | – | within 1% of `global_047` |

- **Per-family selection:** the mean family ratio to V2 would move from 0.904 to 0.861.
- **Per-pair selection:** the mean ratio would be 0.835.
- **The global parametric curve is close to its limit for cinema content.** The remaining headroom is almost all in the broadcast families.

## 3. Broadcast SDR follows one deterministic curve

- **Data:** 13 KBS pairs plus video3/video4. The SDR is YouTube's automatic conversion of the HLG upload.
- **Method:**
  - Sample BT.709 SDR and HLG HDR luma codes at matching pixels: 10 frames per pair at 128×68.
  - Fit a 48-bin median curve (SDR code → HLG code) on the 7 Tune pairs.
  - Test it on the Validation pairs.

| Validation pair | code MAE, shared curve | code MAE, own-pair floor | mean \|log nits ratio\|, shared curve | `global_047` luminanceError |
|---|---:|---:|---:|---:|
| video4_aespa_lemonade | 0.021 | 0.015 | 0.114 | 0.334 |
| kbs_yFTAYXDTjqI | 0.014 | 0.011 | 0.085 | 0.113 |
| kbs_d7s-2eLvT8Q | 0.017 | 0.014 | 0.102 | 0.294 |
| kbs_ivDC7Kh8l4g | 0.033 | 0.016 | 0.208 | 0.380 |
| kbs_72EnmzVeOOw | 0.022 | 0.018 | 0.142 | 0.174 |
| kbs_BVf-pipXhN8 | 0.013 | 0.012 | 0.078 | 0.209 |

- **One curve fits held-out pairs nearly as well as each pair's own curve.** Only `ivDC7Kh8l4g` (black level) is an exception.
- **Its luminance error is roughly half of the current algorithm's** on the same pairs.
- **Caveat:** the comparison is indicative, not like-for-like.
  - The curve measure uses luma codes with a 1000-nit HLG OOTF luminance approximation, all frames, and no family gain.
  - `luminanceError` uses linear luminance on matched 32×18 frames.
- **Shape of the curve:**
  - SDR 0.26 → HLG 0.36;
  - SDR 0.51 → HLG 0.62;
  - SDR 0.76 → HLG 0.80;
  - SDR 0.93 → HLG 0.92.
- **The shape suggests a scene-light conversion.** It looks like an HLG→SDR conversion with a gain of about 1.9 in the midtones and a highlight knee (BT.2408-style).
- **Exact identification of YouTube's LUT is open.**

**Out-of-sample check on the round-3 uploads.**
- The same curve, fitted only on the 7 round-2 Tune pairs, was tested on the 8 round-3 uploads. These were never seen, and they span 2023–2026.
- Code MAE was 0.012–0.032, within 0.002–0.008 of each upload's own-fit floor.
- Mean |log nits ratio| was 0.084–0.194.
- So the conversion is stable across KBS uploads and years.

## 4. Proposals, in order of expected value

1. **Source-type policy "YouTube SDR of an HLG upload".**
   - Invert the fitted curve: SDR code → HLG signal → BT.2100 HLG decode.
   - Expose it as an explicit input policy, like `--sdr-transfer`. Do not classify automatically.
   - **Why explicit:** V6.2 showed that SDR statistics expose family and transfer confounds, so an automatic switch would be learning "is this KBS". The user usually knows the source.
   - **Expected effect:** about −12 to −14% on the broadcast families (§2 upper bound), possibly more because the curve is not limited to the parametric family (§3).
   - **Evaluation:** fit only on Tune broadcast pairs, then judge on Validation and LOFO. The round-3 KBS pairs add 8 more broadcast pairs.
2. **A toe/black-depth term for graded cinema masters.**
   - Sparks' shadows are uniformly lifted.
   - `shadowProtection` has almost no rank correlation with any family's objective (|ρ| ≤ 0.29), so the current curve has no effective control over black depth.
   - Candidate: a toe exponent on the SDR→linear step below about 0.1 SDR code. Sweep it on Tune only.
3. **Per-pair guardrail.**
   - The family maximin hides `video3_newjeans_how_sweet`: 1.14× V2 and 1.41× default under `global_047`.
   - Add a reported, not gating, per-pair worst ratio to the decision report, so within-family outliers are visible before Frozen.
4. **More independent broadcasters.**
   - All broadcast HDR is from one KBS pipeline.
   - The round-3 links add 8 more KBS uploads (2023–2026). The only non-KBS link (M2) has no HDR rendition.
   - Proposal 1's generality beyond KBS/YouTube is untested until another broadcaster's HLG upload is included.

## 5. Shadows of graded cinema masters follow BT.1886 (Tune/Validation luma)

- The reference HDR's linear light at SDR code 0.10, relative to the inverse BT.709 OETF prediction, is 0.22–0.39 on the cinema families. BT.1886 (gamma 2.4) predicts 0.24.
- So the cinema SDR masters were graded for a BT.1886 display, and the inverse OETF lifts their shadows. That matches Sparks' `shadowLiftRatio` of 1.0 (§1).
- The broadcast (YouTube HLG) toe sits between the two curves. It is captured by the §3 curve rather than by either transfer.

## 6. Outcome (round 3, `docs/OPEN_CONTENT_V2_POLICY_COMPARISON.md`)

- **Proposal 1** is implemented as `--declared-source youtube-hlg` / `--declared-source-families`, with the curve fitted on the 11 Tune broadcast pairs.
  - The shape-oetf variant with the declaration passes every pre-Frozen gate. The broadcast families drop to 0.39–0.42× V2 (Validation pairs alone: 0.39–0.49×).
  - LOFO mean is +27.6%, worst +5.9%.
  - It beats the §2 per-family upper bound (−12 to −14%) by a wide margin, because the curve is not limited to the parametric family.
- **Proposal 2:** a full BT.1886 decode is too deep. Every candidate fails the zero-tolerance black-crush gate on Tune. The next try is a bounded toe, for example a blend between the inverse OETF and BT.1886 below code 0.1, swept on Tune.
- **Proposal 3** is implemented as `pairGuardrail` in the v4 final report (top five in the markdown), reported and not gating. Under the declared policy the worst pair is `aswf_stem2_t450`, at 1.044× V2.
- **Proposal 4** is still open. Six more K-Choreo uploads were found by `find_kchoreo_hdr.py` and added (4 to Validation), but they come from the same KBS pipeline.

## Not pursued

- **Colour, temporal and structure terms:** together about 7% of the error.
- **Automatic HLG/PQ or broadcast detection:** confounded with content family on this data (V6.2 §2).
