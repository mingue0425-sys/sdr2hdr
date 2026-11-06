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

# Round 2: with 11 KBS broadcast-HLG pairs (2026-11-07)

The same four variants ran again on the extended dataset:

- Tune 13 and Validation 10 pairs, in six families. KBS Music Bank One-take is now its own family, and K-Choreo has 11 pairs.
- Same seed, search and preregistered `family-maximin-lofo-v1` protocol, run as one `v4-run-batch` with `--stop-before-frozen`.
- Correctness review: Tune 13/13 and Validation 10/10 structurally complete. The verdict is `EXECUTABLE_EVIDENCE_INCOMPLETE`, as expected while no Frozen plan is admitted.
- The Virgin Frozen holdout was **not opened**.
- Artifacts: `results/open-content-v2/round2/v4-*/`.

| run | Tune/Validation-safe | selected | LOFO mean / worst held-out vs V2 | pre-Frozen verdict |
|---|---:|---|---|---|
| **shape-oetf** | 105 / 112 | **`global_047`** | **+8.4% / +3.2% (Sol Levante)** | **every pre-Frozen gate PASS**; stopped before Frozen |
| abs-oetf | 86 / 87 | none | – | VALIDATION_FAIL |
| shape-blend | 19 / 103 | none | −3.1% / −4.2% | VALIDATION_FAIL |
| abs-blend | 6 | none | – | VALIDATION_FAIL |

## shape-oetf folds (held-out family, improvement vs V2 / vs default)

| held-out family | fold candidate | vs V2 | vs default |
|---|---|---:|---:|
| ASC StEM2 | global_047 | +15.0% | +15.5% |
| ASC StEM3 Warped Cybercity | global_047 | +12.9% | +12.9% |
| K-Choreo | global_047 | +6.0% | +3.9% |
| KBS Music Bank One-take | global_047 | +8.4% | +5.0% |
| Netflix Sol Levante | global_113 | +3.2% | +11.0% |
| Netflix Sparks | global_019 | +4.9% | +4.9% |

## Findings

1. **The K-Choreo fold flipped from −4.8% to +6.0%.**
   - In round 1, holding out K-Choreo left no broadcast-HLG family in training, so the other families selected stronger highlight expansion.
   - The KBS Music Bank One-take sibling family now carries the broadcast roll-off into that fold.
   - Caveat: all 13 KBS pairs share one broadcaster pipeline. This fold measures generalisation within KBS, not across broadcasters.
2. **Sol Levante is now the binding fold, at +3.2%.**
3. **Family maximin hides some per-pair regressions.** `global_047` vs V2 by pair:
   - `video3_newjeans_how_sweet` 1.14 (vs default 1.41);
   - `kbs_zWpnFNYlggE` 0.98 (vs default 1.10);
   - every other pair ≤ 0.98.
   - Under the shape-only objective each family is one gain-normalized unit. These pairs are within-family outliers, not a gate failure.
4. **Absolute scoring still fails, and the blend still does not help.**
   - Absolute: the best maximin candidate beats V2 on every family. It is still 8.1% worse than the default on StEM2.
   - Blend: it keeps at most 19 safe candidates, and its LOFO is negative.
5. **LOFO caveat (unchanged).** The candidate pool is fixed before folding, and local-refinement centres used all Tune families.

## Consistency

- **Absolute variants:** all 24 old-pair baseline objectives (V2 and default, Tune and Validation) equal round 1 exactly. This covers the parallel decode, mixed VideoToolbox/software VP9 decode, sequence release and hash streaming changes.
- **Shape variants:** only video3/video4 move, because the K-Choreo family gain now includes the KBS pairs.

## Runtime and memory (8 GB M2)

| step | before | after |
|---|---|---|
| correctness-review | 84 min, peak footprint 22.2 GB (mostly swap) | 30 min, peak 1.22 GB |
| 4-variant batch, 23 pairs | – | 31 min, peak 1.25 GB, one materialization reused 3× |

## Next step

The preregistered readiness gate passed for shape-oetf. The next steps would expose the Virgin Frozen holdout (Nocturne ×3, Sole Mates ×1), so they wait for explicit approval:

1. build the Frozen prepared plan;
2. run correctness-review with `--prepared-frozen-plan`;
3. run the one-shot Frozen evaluation of `global_047`.
