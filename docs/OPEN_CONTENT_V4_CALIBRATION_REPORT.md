# Open-content V4 calibration: result

Verdict: **VIRGIN_FROZEN_FAIL**. The calibrated V4 candidate is not promoted.

The one-use Virgin Frozen holdout is consumed:
- 4 pairs: ASC StEM3 Warped ×2 and Netflix Sparks ×2.
- The consumption is recorded by byte hash in `.hdr-frozen-consumption/`.
- A new promotion attempt needs new, unexposed holdout pairs.

## Run

- Dataset: `data_video/open-content/manifest.json`. 12 pairs, coverage protocol `open-content-coverage-v1`.
- Correctness: `CORRECTNESS_READY_FOR_V6`, with the admitted Frozen plan `668e9b66…`.
- Command: `v4-run --sdr-transfer bt709-oetf --seed 20260824`. Commit `725b0bc`, clean working tree.
- Search: 128 global and 64 local candidates. Selected `local_057`.
- Artifacts: `results/open-content-v1/v4-final/`.

| Split | V2 | V4 `local_057` | Improvement |
|---|---:|---:|---:|
| Tune | 0.2684 | 0.2405 | 10.4% |
| Validation | 0.4065 | 0.3851 | 5.25% |
| Virgin Frozen | 0.5712 | 0.5514 | **3.48%** (gate: ≥ 5%) |

Every other promotion gate passed:
- completeness, transfer, family, black crush, and no per-video regression
- runtime: GPU p95 0.704 → 0.674 ms

Virgin Frozen objective per video:

| pair | default | V1 | V2 | V4 |
|---|---:|---:|---:|---:|
| aswf_stem3_warped_t118 | 0.4551 | 0.4560 | 0.4916 | 0.4831 |
| aswf_stem3_warped_t197 | 0.5124 | 0.5127 | 0.5515 | 0.5441 |
| netflix_sparks_f04133 | 0.6731 | 0.6731 | 0.6848 | 0.6524 |
| netflix_sparks_f08266 | 0.5627 | 0.5627 | 0.5570 | 0.5258 |

### Reading

- **Against V2.** V4 improves on V2 for all four holdout videos and reduces shadow error (0.693 → 0.647). V4 does generalize against V2, just by less than the 5% gate requires.
- **On Sparks.** V4 is the best configuration, 3–7% better than the default.
- **On StEM3.** The whole V2 family (V2 and V4) is 6–8% worse than the default. Midtone error is the gap: 0.889 for V4 against 0.866 for the default.
- **Next step.** The next calibration round should address the V2-family midtone mapping on display-referred (BT.1886) grades like StEM3.

### Why the gain was small: the masters disagree in direction

The Tune and Validation evidence (no Frozen media was used here) shows that the HDR masters were graded in opposite directions relative to their SDR versions.

| pair | split | master diffuse white | default / V2 / V4 output | error direction |
|---|---|---:|---:|---|
| Sol Levante t030–t175 | Tune | 224–450 nits | 106–317 | every configuration is too dark |
| K-Choreo video3 / video4 | Tune / Validation | 285–430 | 181–404 | every configuration is too dark |
| ASC StEM2 t300 / t450 | Validation | 3.6 / 87 | 12–172 | every configuration is too bright |

Consequences:
- Four of the five Tune pairs come from bright-graded Netflix masters. The search therefore learned a brighter mapping, which helps Netflix and K-Choreo.
- The same brighter mapping overshoots the darker ASC grades: StEM2 in Validation and StEM3 in Frozen.
- No single global curve can follow a 450-nit and an 87-nit diffuse white at the same time.
- The next round needs one of two changes:
  1. Balance Tune across grading styles, not only across content families.
  2. Score the objective relative to each master's diffuse white, so a mapping is judged on its shape rather than on matching one master's absolute brightness.

## Decisions made on the way (all before Frozen access)

1. **SDR transfer policy: bt709-oetf.** Both policies were compared with `--stop-before-frozen`, so Frozen was opened only once.
   - BT.1886 lowers Tune shadow error: candidate median 0.35, best 0.27, against 0.45 for V2.
   - But under BT.1886, every one of the 128 global candidates crushes blacks beyond V2, and 121 of them also regress catastrophically per video. None of them passes Tune.
   - bt709-oetf: 7 of 8 Validation candidates pass, with the best 5.3% better than V2.
2. **Black-crush gate counts only crush a candidate adds over V2.**
   - Before the change, every configuration had the identical crush ratio 0.00012, so the gate rejected all 128 global candidates.
   - The cause was `netflix_sollevante_t175`: its SDR grade sits at code black where the HDR master keeps more than 1 nit of detail.
   - The new policy is `black-crush-introduced-over-v2-v1`, still at zero tolerance. Historical configurations keep the absolute gate.
3. **Frozen transfer coverage now reads the lock-bound audit, as correctness-review already did.**
   - The manifest `referenceTransfer` field also documents SDR fallbacks: StEM3 records `bt1886`, its SDR deliverable.
   - Reading that field made `v4-run` see "unknown" HDR transfers for all four Frozen pairs. The audit records PQ for all four.
4. **HLG virgin holdout is not required by `open-content-coverage-v1`.** The protocol preregisters Frozen as PQ-only, so HLG generalization is evidenced only by Validation.
5. **The runtime gate failure in the preflight run was noise.**
   - The preflight measured V4 GPU p95 at 1.78 ms against 0.75 ms for V2, while p50 was lower for V4.
   - Ten repeated measurements of the same gate all passed, with V4 never slower than V2.
   - The final run passed on its own measurement.
