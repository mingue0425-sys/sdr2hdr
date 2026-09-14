# Trusted Development Corpus Expansion

## 1. Baseline

This expansion starts from correctness baseline
`bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9` on PR #13 head
`34ad13612d284fd26117ea6ca383dab9c0640cfb`.

The historical paired manifest remains unchanged:

```text
path: data_video/visual-regression/v6-development-manifest.json
manifest version: 4
SHA-256: 26cab0df016dc1ed17f2b70fc8e1dc10cf7677907994c24937479fb423259c8c
records: 8
coarse families: K-Choreo, LIVE
```

Its roles and coarse family labels were not relabeled or split retroactively.
The earlier `preflight-v2` record remains preserved.

## 2. Expansion gate

The new manifest would use:

```text
datasetId: calibration-v6-development-expanded-2026a
manifestVersion: 5
provenanceVersion: 1
familyDefinitionVersion: source-master-v1
```

The minimum structural gate is four independent source-master families, with
at least two families in each family-disjoint split. The target is six or more
families, preferably at least three in Tune and three in Validation. Codec,
bitrate, resolution, transfer function, container, and encode variant never
create a new family.

No candidate was admitted because no authorized exact manifest, source-master
mapping, or paired asset bundle was available. Consequently, the v5 manifest
was not emitted.

## 3. Admission contract

`contentFamily` means an independent source-master or an explicitly documented
source-content lineage. Each admitted pair must provide a canonical
`sourceMasterId`, pair-specific source and reference asset IDs, exact locators,
documented `pairOrigin`, provenance/license reference, declared transfer and
range metadata, and current SHA-256 values for both bytes.

The following are forbidden as admission shortcuts:

```text
retroactive K-Choreo/LIVE subdivision
filename-based family invention
codec-variant family counting
old calibration score reuse
model-generated HDR references
unknown mirrors or scraped pairs
```

Structural admission is metadata/provenance-only. No media was downloaded,
hashed, decoded, or inspected during this cycle.

## 4. Candidate review

| candidate | paired relation | source identity | access / provenance result | decision |
| --- | --- | --- | --- | --- |
| [LIVE Paired Comparison HDR vs. SDR / HDRSDR-VQA](https://www.colorado.edu/lab/live/live-paired-comparison-hdr-vs-sdr-database) | Official page describes HDR10 and matched SDR reference/encoded material and 31 open-sourced contents | 31 contents are declared, but canonical source IDs were not received | Official [UT page](https://live.ece.utexas.edu/research/Bowen_SDRHDR/sdr-hdr-bowen.html) requires a Google Form; the Colorado page also offers Globus access | Candidate; awaiting authorized access |
| [LIVE HDR vs SDR Database](https://live.ece.utexas.edu/research/LIVE_HDRvsSDR/index.html) | Paired HDR/SDR database | Source-master mapping not received | Official page requires a Google Form | Candidate; awaiting authorized access |
| [AVT-VQDB-UHD-2-HDR](https://github.com/Telecommunication-Telemedia-Assessment/AVT-VQDB-UHD-2-HDR) | HDR source-only dataset; no SDR pair from this repository | 31 HDR sources declared; exact asset mapping unavailable | SHA-512 index is referenced, but download requires a Google Form; license is documented as CC BY-NC 4.0 for own contents | Not admitted as paired corpus |
| [DVB/EBU Z280 HDR test content](https://dvb.org/specifications/verification-validation/hdr-test-content/) | Page documents HLG-to-PQ10 conversion and HDR variants | One 2019 EBU Z280 source lineage; variants remain one family | CC BY 4.0 is documented; no corresponding SDR calibration pair is established | Not admitted; insufficient diversity |
| ICME challenge training Box link | Official challenge page declares paired HDR/SDR training data | Source IDs unavailable | The listed Box URL returned HTTP 404 on 2026-09-12; no binary was acquired | Not admitted |

The primary candidate is HDRSDR-VQA because its published structure could
supply enough source families. The official access path requires an authorized
Google Form or Globus account. No account creation, form submission, or access
bypass was attempted. Without the downloaded metadata and exact paired files,
the declared content count cannot be converted into trusted family identities.

The DVB/EBU material is useful as a possible single-family development
qualification source after a documented SDR counterpart is supplied. Its
codec and metadata variants cannot be counted as independent families.

## 5. Trusted identity status

The current cycle has no admitted external pair. Therefore:

```text
admitted records: 0
admitted source-master families: 0
source SHA-256 coverage: NOT_STARTED
reference SHA-256 coverage: NOT_STARTED
manifest SHA-256: NOT_CREATED
corpusDefinitionHash: NOT_CREATED
experimentBindingHash: NOT_CREATED
```

A new hash calculated from an unapproved or inaccessible bundle would not
establish historical approval, so no such hash was generated.

## 6. Split status

No Tune/Validation split was created. Since no source-master identity passed
admission, family overlap and source-master overlap are not evaluated for a
new corpus. The historical v4 split is not reused as promotion-grade evidence.

```text
Tune run: NO
Validation run: NO
candidate selection: NO
```

The historical v1 preregistration is preserved for lineage but was invalidated
by the Stage B audit and is not eligible for calibration. The repaired v2
semantic-only preregistration is a separate artifact; it does not seal this
future corpus:

```text
policyVersion: sdr-input-interpretation-policy-v1
preparationVersion: v6-prepared-evaluation-plan-v6-sdr-interpretation-policy
oldSearchDefinitionHash: 7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608
oldHashStatus: RETIRED_INVALIDATED
searchBudgetPerPolicy: 192
seed: 20260912
shortlistSize: 3
```

## 7. Frozen and objective boundaries

No Frozen, Virgin, holdout, or protected path was listed, probed, hashed,
decoded, or evaluated. No objective metric was run, and objective evaluations
remain zero. The development-corpus expansion is not a Frozen evaluation and
does not create a future Frozen set.

## 8. Required authorized handoff

To resume, the project needs an exact trusted manifest bundle for a paired
dataset such as HDRSDR-VQA, containing canonical source-master IDs, exact SDR
and HDR locators, pair origin, declared metadata, license/provenance evidence,
and publisher or ingest SHA-256 values where available. If access is provided
through Globus or a form, the account and submission must be performed through
the authorized user workflow; no credentials are inferred or bypassed here.

After receipt, the next order remains:

```text
structural admission
→ exact byte hashing
→ family-disjoint deterministic split
→ v5 manifest emission
→ preflight-v3
→ commit / push / remote CI
→ stop
```

Tune and Validation remain prohibited until that sequence completes.

## 9. Final status

```text
CORPUS_EXPANSION: BLOCKED_INSUFFICIENT_TRUSTED_CORPUS
ACCESS_STATUS: AWAITING_AUTHORIZED_DATASET_ACCESS
NEW_MANIFEST: NOT_EMITTED
FROZEN_ACCESSED: NO
OBJECTIVE_EVALUATIONS: 0
```

The complete machine-readable record is
[`results/calibration-corpus-preflight-v3.json`](../results/calibration-corpus-preflight-v3.json).
