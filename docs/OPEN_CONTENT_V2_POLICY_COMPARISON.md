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

# Round 3: 31 pairs and the declared YouTube-HLG source (2026-11-07)

Setup:
- Tune 17 and Validation 14 pairs. The 8 user-provided K-Choreo uploads joined (K-Choreo now has 19 pairs).
- Correctness review: Tune 17/17 and Validation 14/14 structurally complete.
- Six variants ran as one `v4-run-batch` with `--stop-before-frozen`, the same seed and the same `family-maximin-lofo-v1` protocol.
  - `-ythlg` variants declare K-Choreo and KBS Music Bank One-take as "YouTube SDR of an HLG upload" (`--declared-source-families`). On those pairs only, SDR is reconstructed with the fixed 17-knot curve (`youtube-hlg-sdr-inverse-17knot-v1`), the HLG inverse OETF and a 1000-nit system gamma. The candidate parameters do not touch those pairs.
  - The curve was fitted on the 11 Tune broadcast pairs only (`dataset/analysis/youtube-hlg-curve-v1.json`).
  - `-1886` variants decode SDR with BT.1886 instead of the inverse BT.709 OETF.
- Baselines (V2, default) are unchanged by the declaration.
- The Virgin Frozen holdout was **not opened**. Artifacts: `results/open-content-v2/round3/v4-*/`.

| run | selected | LOFO mean / worst held-out vs V2 | verdict |
|---|---|---|---|
| shape-oetf | `global_047` | +9.0% / +3.2% (Sol Levante) | every pre-Frozen gate PASS |
| **shape-oetf-ythlg** | **`local_020`** | **+27.6% / +5.9% (Sol Levante)** | **every pre-Frozen gate PASS** |
| abs-oetf | none | – | VALIDATION_FAIL |
| abs-oetf-ythlg | none | – | VALIDATION_FAIL |
| shape-1886 | none | – | VALIDATION_FAIL (no Tune-safe candidate) |
| shape-1886-ythlg | none | – | VALIDATION_FAIL (no Tune-safe candidate) |

## Family objective of the selected candidate, ratio to V2

| family | shape-oetf (`global_047`) | shape-oetf-ythlg (`local_020`) |
|---|---:|---:|
| ASC StEM2 | 0.850 | 0.837 |
| ASC StEM3 Warped Cybercity | 0.871 | 0.814 |
| K-Choreo | 0.907 | **0.423** |
| KBS Music Bank One-take | 0.916 | **0.394** |
| Netflix Sol Levante | 0.902 | 0.912 |
| Netflix Sparks | 0.943 | 0.917 |
| mean / worst | 0.898 / 0.943 | 0.716 / 0.917 |

## Findings

1. **The declared source cuts the broadcast error by more than half, also out of sample.** Mean per-pair ratio to V2 is shown by split; the Validation pairs never entered the curve fit.

   | | Tune (fit pairs) | Validation (not fitted) |
   |---|---|---|
   | K-Choreo | 0.385 (10 pairs, worst 0.491) | 0.488 (9 pairs, worst 0.746) |
   | KBS One-take | 0.403 (1) | 0.387 (1) |

2. **The cinema families also improve a little (StEM3 0.871 → 0.814).** The broadcast pairs no longer pull the shared candidate towards their highlight roll-off (research §2), so the search settles on a cinema-friendly local candidate.
3. **The per-pair outlier is gone.** Under `global_047`, `video3_newjeans_how_sweet` was 1.14× V2. Under `local_020` the worst pair is `aswf_stem2_t450` at 1.044× V2 (1.048× default); every other pair is ≤ 0.97.
4. **LOFO caveat, stronger here.** The curve was fitted on Tune broadcast pairs before folding. So the K-Choreo and KBS folds (+57.7%, +60.6%) are not held out for the curve; only the Validation column in finding 1 is. The four cinema folds (+5.9% to +18.6%) are unaffected by the curve.
5. **BT.1886 as a global SDR decode fails safety.** All 128 global candidates introduce black crush over V2 on Tune: the candidates' minimum crush ratio is 1.4e-4 against V2's 6.0e-5, and the gate has zero tolerance. The measured cinema toe (research §5) is real, but a full BT.1886 decode is too deep for the gate. A bounded toe is the open lead.
6. **Absolute scoring still fails** with or without the declaration.

## Not yet shown

- **Generality beyond one KBS pipeline.** Every broadcast pair is a KBS YouTube upload, so the declared policy is validated for that source only.
- **Frozen.** The Virgin Frozen set (Nocturne ×3, Sole Mates ×1) is cinema only. It would test the candidate's cinema behaviour, not the declaration.

# Round 4: 37 pairs, six found uploads (2026-11-07)

Setup:
- Tune 19 and Validation 18 pairs. The six K-Choreo uploads found by `find_kchoreo_hdr.py` joined: 4 in Validation, 2 in Tune.
- None of the six entered the YouTube-HLG curve fit, which still uses the 11 round-3 Tune pairs.
- Correctness review: Tune 19/19 and Validation 18/18 structurally complete.
- Same seed and protocol. Two variants ran: shape-oetf and shape-oetf-ythlg.
- Runtime: 31 min, peak footprint 1.96 GB.
- The Virgin Frozen holdout was **not opened**. Artifacts: `results/open-content-v2/round4/v4-*/`.

| run | selected | LOFO mean / worst held-out vs V2 | K-Choreo / V2 | mean / worst family / V2 |
|---|---|---|---:|---|
| shape-oetf | `global_047` | +9.2% / +3.2% | 0.897 | 0.897 / 0.943 |
| shape-oetf-ythlg | `local_020` | +27.5% / +5.9% | 0.430 | 0.717 / 0.917 |

The six new pairs, per-pair ratio to V2:

| pair | split | shape-oetf | shape-oetf-ythlg |
|---|---|---:|---:|
| kbs_ptNuFAIfykE | Validation | 0.843 | 0.389 |
| kbs_BQPWd1npLic | Validation | 0.850 | 0.374 |
| kbs_sQcbGTVzzVQ | Validation | 0.793 | 0.471 |
| kbs_HWOzx_hIGZs | Validation | 0.901 | 0.601 |
| kbs_uNMiKwHot0I | Tune | 0.919 | 0.443 |
| kbs_4I4X0VjUeOw | Tune | 0.914 | 0.336 |

Findings:
- **Selection is stable.** Both variants pick the same candidates as in round 3, and every cinema family's ratio is unchanged.
- **The declared policy holds on unseen uploads.** The 13 K-Choreo Validation pairs average 0.478× V2 (worst 0.740), against 0.865× under shape-oetf.
- **`pairGuardrail` is now in the report.** Under shape-oetf the worst pair is still `video3_newjeans_how_sweet` (1.141× V2). Under the declared policy it is `aswf_stem2_t450` (1.044×).

Open items:
- **Chroma model.** The declared reconstruction applies the luma-fitted curve and the 1.2 system gamma per channel. BT.2100's HLG OOTF uses one gain derived from luminance, as `HDRReferenceDecoder` does. A luminance-OOTF variant is the next comparison; colour terms are about 7% of the objective (research §1).
- **Generality beyond KBS**, and the Frozen evaluation, as in round 3.
