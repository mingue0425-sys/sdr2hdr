# Open-content v2: Virgin Frozen result (2026-11-07)

Verdict: **PROMOTE_CALIBRATED_V4**. The selected candidate `local_020` is promoted as the production preset `calibrated-v5`.

## Run

- Preregistration: `docs/OPEN_CONTENT_V2_FROZEN_PREREGISTRATION.md`, commit `6be5ffd`. It was committed before the Frozen plan existed.
- Dataset: `data_video/open-content-v2/manifest.json`, with Tune 21, Validation 20 and Virgin Frozen 4.
- Correctness: `CORRECTNESS_READY_FOR_V6`, with the admitted Frozen plan `37397ce2…` (50 accepted frames).
- Command: `v4-run --sdr-transfer bt709-oetf --level-normalization family-midtone-gain --declared-source youtube-hlg --declared-source-families "K-Choreo;KBS Music Bank One-take" --seed 20260824`. Commit `442c7c1`, clean tree.
- Search: 128 global and 64 local candidates. Selected `local_020`, the same candidate as rounds 3 and 4.
- LOFO: PASS, mean +27.5%, worst +5.9%.
- Artifacts: `results/open-content-v2/frozen-v2/`.

| split | V2 | V4 `local_020` | improvement |
|---|---:|---:|---:|
| Tune | 0.2933 | 0.1944 | 33.70% |
| Validation | 0.3786 | 0.2751 | 27.33% |
| Virgin Frozen | 0.3680 | 0.2831 | **23.07%** (gate ≥ 5%) |

Virgin Frozen objective per video:

| pair | default | V1 | V2 | V4 |
|---|---:|---:|---:|---:|
| netflix_nocturne_f11961 | 0.4096 | 0.3876 | 0.3932 | 0.3171 |
| netflix_nocturne_f19935 | 0.3304 | 0.3293 | 0.3284 | 0.2482 |
| netflix_nocturne_f27909 | 0.4494 | 0.3443 | 0.3907 | 0.2875 |
| nas_solemates_unh0400 | 0.3888 | 0.3408 | 0.3652 | 0.2820 |

Other results:
- Every promotion gate passed: completeness, transfer, family, shadow, relative shadow, temporal, hard safety, identifiability and runtime.
- Frozen shadow error went from 0.615 to 0.452.
- Runtime: GPU p50 0.521 → 0.497 ms, p95 0.892 → 0.849 ms.

## Reading

- **Every Frozen video beats every baseline**, by 19–26% against V2 and 23–36% against the default. Nocturne (live action, low key, grain) and Sole Mates (CG animation) are families the search never saw.
- **The Frozen gain is close to the Validation gain** (23% against 27%). In the v1 attempt it was 3.5% against 5.3%. The candidate generalises; it was not fitted to the Tune families.
- **What it does not show:**
  - The Frozen set has no broadcast pair, so it says nothing about the declared YouTube-HLG reconstruction. The evidence for that stays the Tune/Validation result (`OPEN_CONTENT_V2_POLICY_COMPARISON.md`).
  - Scoring is shape-only (`family-midtone-gain`): each family's overall level is normalised before scoring. The absolute brightness of the preset was not scored.
- The v2 Virgin Frozen holdout is now **consumed** (`.hdr-frozen-consumption/`). A further promotion needs new, unexposed pairs.

## Promotion

- `HDRConfiguration.calibratedV5` holds `local_020`'s parameters: paper white 203.3 nits, peak 1408.8 nits, highlight 0.86, contrast 0.802, saturation 0.416, shadow 0.738, temporal 0.484, headroom 6.93, tone curve scene-relative V4.
- `HDRPresetResolver.productionDefault` is now `calibrated-v5`. `calibrated-v4` and the older presets stay selectable with `--preset`.
- The robustness study stays pinned to `calibrated-v4`, which is what it was reported against.
