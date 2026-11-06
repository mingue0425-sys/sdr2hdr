# How to do better: research notes (2026-11-06)

This note uses only Tune and Validation evidence plus published work. No Frozen media was opened for it.

## 1. Per-scene adaptation is worth more than a better global curve

For each Tune pair, the oracle is the best of the 192 V4 candidates searched for that pair alone. It is compared with the single globally selected candidate (`local_057`).

| pair | SDR mean luma (normalized) | selected | per-pair oracle | headroom | oracle paper white / highlight / peak |
|---|---:|---:|---:|---:|---|
| Sol Levante t030 | 0.29 | 0.2964 | 0.2952 | 0.4% | 190 / 0.61 / 1108 |
| Sol Levante t090 | 0.38 | 0.4333 | 0.3834 | 11.5% | 242 / 0.67 / 1352 |
| Sol Levante t150 | 0.41 | 0.3674 | 0.2798 | 23.8% | 223 / 0.82 / 1436 |
| Sol Levante t175 | 0.71 | 0.3236 | 0.2726 | 15.8% | 223 / 0.82 / 1436 |
| K-Choreo video3 | 0.54 | 0.1258 | 0.1167 | 7.2% | 243 / 0.56 / 977 |

Observations:
- Even inside one title, the best parameters change from scene to scene, and the gap to the single global choice reaches 24%.
- In Sol Levante, the brighter the SDR scene, the more expansion the HDR grade asks for: higher paper white, highlight strength and peak.
- This runs opposite to Bist et al. (2017), whose expansion gamma grows for dark scenes. Their rule is perceptual; the Netflix colourists apparently spent HDR headroom on bright scenes.
- With one title and four scenes, the direction is a hypothesis, not a result.

The repository already has a scene-adaptive branch (`sceneAdaptiveV62Candidate`). What it is missing is a predictor that maps SDR scene statistics to curve parameters.

## 2. The masters disagree on absolute brightness

Diffuse white in the HDR masters varies widely:
- Netflix and K-Choreo: 224–450 nits.
- ASC StEM2: 3.6–87 nits.

Every configuration under-reaches the first group and overshoots the second. The details are in `OPEN_CONTENT_V4_CALIBRATION_REPORT.md`.

- BT.2408 anchors HDR reference white at 203 cd/m², and BT.2446 Method C follows the BT.2408 reference levels.
- An analysis cited with BT.2446 also finds a large spread of diffuse white across content sources.
- A single absolute target is therefore ill-posed across studios.

## 3. Cheap structured-artifact detection does not survive real codecs

Robustness study v4 (Tune only) tried two detectors.
- **Luma histogram gaps:** they read 0 even for 6-bit luma, because the lossy intermediate (ProRes) refills the empty codes.
- **8×8 boundary/interior step ratio ("blockiness"):** the ranges overlap.
  - clean: 1.09–1.10
  - light noise: 1.11–1.17
  - CRF 32: 1.04–1.30
  - CRF 42: 1.12–1.58

  x264's deblocking filter removes most of the block-edge signal.

The fixed `noise-gated` tolerance stays the robust choice. Noise-adaptive tolerance only helps clean and grainy sources that are not heavily compressed.

## Recommended next steps, in order

1. **Data before parameters.**
   - Acquire new, unexposed holdout pairs, since the current Frozen set is consumed.
   - Rebalance Tune across grading styles (bright-graded streaming masters vs SDR-matched cinema masters), not only across content families.
2. **Relative objective as a preregistered variant.** Score luminance errors after normalizing each master by its own diffuse white, so the curve shape is calibrated separately from studio brightness intent. Absolute brightness can then be a separate user or display setting.
3. **Scene-statistics predictor for the scene-adaptive branch.**
   - Learn on Tune a small monotone map from SDR scene statistics (mean, 10% and 90% luma, highlight fraction) to paper white, highlight strength and peak.
   - Regularize it heavily: N is tiny.
   - Judge it on Validation before any new Frozen.
4. **Guidance:** keep the fixed `noise-gated` setting. A learned artifact classifier is the only realistic upgrade, and it is out of scope for an opt-in feature.

## Sources

- ITU-R BT.2446-0 (2019), conversion methods between SDR and HDR, Method C §5.2: https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2446-2019-PDF-E.pdf
- Report TOC: https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2446-2019-TOC-HTM-E.htm
- Content-adaptive inverse tone mapping survey (statistics-controlled gamma: Masia 2017, Bist 2017, Luzardo 2018), as summarized in "Towards Efficient SDRTV-to-HDRTV by Learning from Image Formation": https://arxiv.org/abs/2309.04084
- HDRTVNet / "A New Journey from SDRTV to HDRTV" (global-statistics colour mapping): https://ar5iv.arxiv.org/html/2108.07978
- Luzardo et al., fully automatic content-adaptive iTMO: https://core.ac.uk/download/160492101.pdf
