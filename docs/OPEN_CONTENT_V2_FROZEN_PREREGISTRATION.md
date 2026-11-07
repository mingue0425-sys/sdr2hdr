# Open-content v2: Virgin Frozen preregistration (2026-11-07)

The user approved opening the v2 Virgin Frozen holdout once (2026-11-07). This file is committed **before** the Frozen plan is built and before any Frozen objective exists.

## Holdout

| pair | family |
|---|---|
| Netflix Nocturne ×3 | Netflix Nocturne |
| NAS Sole Mates ×1 | NAS Sole Mates |

- Nocturne is live-action, low-key film with grain; Sole Mates is CG animation. None is broadcast HLG, so the declared YouTube-HLG reconstruction is never applied to a Frozen pair.
- They were never decoded for an objective. Opening them consumes them.

## The single configuration evaluated

- Variant: `shape-oetf-ythlg`.
- Command: `v4-run --sdr-transfer bt709-oetf --level-normalization family-midtone-gain --declared-source youtube-hlg --declared-source-families "K-Choreo;KBS Music Bank One-take" --seed 20260824`.
- Dataset: `data_video/open-content-v2/manifest.json` as of this commit, with Tune 21 and Validation 20.
- The candidate is selected again by `family-maximin-lofo-v1` on that Tune/Validation set. Rounds 3 and 4 selected `local_020`.
- **Why this variant:**
  - In round 4 it has the best Tune/Validation family maximin: worst family 0.917× V2, against 0.943× for shape-oetf.
  - It also has the better LOFO: +27.5% / +5.9%, against +9.2% / +3.2%.
- No other variant is evaluated on Frozen.

## Decision rule (unchanged code gates)

- `PROMOTE_CALIBRATED_V4` needs every promotion gate in `V4Calibration.swift`. That includes a Frozen objective improvement of at least 5% over V2 (`frozenMinimumImprovement = 0.05`), plus the black-crush, per-video regression, transfer, family and runtime gates.
- Any other verdict is reported as it is. There is no retry on this holdout.

## What the result can and cannot show

- It can show whether the selected candidate generalises to unseen graded masters (Nocturne and Sole Mates are new families).
- It cannot test the declared YouTube-HLG policy, because Frozen has no broadcast pair. That evidence stays the Tune/Validation result in `OPEN_CONTENT_V2_POLICY_COMPARISON.md`.
