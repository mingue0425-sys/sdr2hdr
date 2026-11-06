# Open-content v2: policy comparison before Virgin Frozen (2026-11-06)

Four V4 runs on `data_video/open-content-v2/manifest.json` under the preregistered `family-maximin-lofo-v1` decision protocol.

- Every run used `--stop-before-frozen`. The new Virgin Frozen holdout (Nocturne ×3, Sole Mates ×1) stays sealed and unexposed.
- Dataset: Tune 7, Validation 5, 5 families. The fixed `seed 20260824` and the same 192-candidate search were used throughout.
- Artifacts: `results/open-content-v2/v4-{abs,shape}-{oetf,blend}/`.

| run | scoring | SDR decode | eligible candidates | LOFO mean / worst held-out vs V2 | pre-Frozen verdict |
|---|---|---|---:|---|---|
| abs-oetf | absolute | inverse BT.709 OETF | 0 | – | VALIDATION_FAIL |
| **shape-oetf** | **family gain-normalized** | inverse BT.709 OETF | selected `global_039` | **+3.3% / −4.8% (K-Choreo)** | LOFO FAIL, Frozen not opened |
| abs-blend | absolute | toe-BT.709 / BT.1886 blend | 0 | – | VALIDATION_FAIL |
| shape-blend | family gain-normalized | toe-BT.709 / BT.1886 blend | 0 | −2.2% / −5.2% | VALIDATION_FAIL |

"Eligible" means a candidate is Tune- and Validation-safe and within 2% of both V2 and the default preset on every family.

## Findings

1. **Under absolute scoring no candidate can serve both the bright and the dim masters.**
   - The best maximin candidate (`local_059`) beats V2 on all five families by at least 3.2%.
   - It is still 8.2% worse than the default on StEM2 and 3.5% worse on StEM3.
   - The default (dimmer) is closer to those masters' absolute level.
2. **Most of that gap is brightness level, not shape.**
   - With one gain fitted per family, V2 and the default tie on StEM2, StEM3 and Sparks.
   - The selected shape candidate improves them by 10%, 9% and 4%.
3. **The remaining conflict is the highlight shape, between K-Choreo and Sol Levante.**
   - The value is d log(reference) / d log(default output) over the upper percentiles (p75–p99), after level normalization. A value above 1 means the master wants more highlight expansion.
   - K-Choreo is **0.81**. Sol Levante is 1.01, StEM2 1.19, StEM3 1.57 and Sparks 2.47.
   - K-Choreo is the only HLG family. Its HDR is a broadcaster's (KBS) HLG upload, and its SDR is YouTube's automatic rendition: a broadcast roll-off with an algorithmic SDR.
   - When K-Choreo is held out, the other families select stronger highlight expansion, which is 4.8% worse than V2 on K-Choreo.
   - The HLG reference decode follows BT.2100 (system gamma 1.2 at 1000 nits) and correctness-review's HLG OOTF check passed, so a decode error is not the explanation.
4. **The display-referred midtone blend does not help.**
   - It improves the dim cinema masters (StEM2/StEM3 8–10% better than V2 under absolute scoring).
   - It costs K-Choreo (absolute) or Sol Levante (shape-only), and it leaves at most 20 Tune/Validation-safe candidates.
   - It stays an opt-in policy and is not proposed for promotion.

## Decision

- No variant passes the preregistered readiness gate, so the v2 Virgin Frozen holdout is **not opened**.
- The leading configuration is shape-only scoring with the historical SDR decode.
- Next data step: more broadcast-HLG pairs.
  - 11 user-provided KBS HDR uploads are being added to Tune/Validation as two series families: K-Choreo 8K and Music Bank One-take 4K HDR.
  - All of them share one broadcaster pipeline, so the K-Choreo fold measures within-broadcaster generalisation only.

## Limits

- Five families.
- Two of them, K-Choreo and Sol Levante, decide the result.
- The highlight-shape exponent is a percentile-level summary, not a per-pixel fit.

## Batch reuse check

`v4-run-batch` re-ran abs-oetf and shape-oetf from a single materialization (`results/open-content-v2/batchcheck/`).
- Verdicts, selections and LOFO folds match the separate runs.
- All numbers agree to at most 6e-16 relative. That is the last bit of a double; Swift dictionary iteration order changes the summation order between processes.
- The second variant took 5.4 min instead of 21 min.
