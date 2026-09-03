# Pre-V6 Final Correctness

## A. Starting State

- Dataset audit: DATASET_V4_READY
- Prior correctness verdict: CORRECTNESS_CHECK_FAIL
- Virgin Frozen objective evaluation count: 0

## B. Frozen Coverage Policy

- Required transfers: HLG, PQ
- Required family diversity: 2 distinct families; no K-Choreo name requirement
- Minimum virgin pairs: 3
- Rationale: HLG and PQ are both production input/reference transfer families and must be represented in Virgin Frozen. Family diversity tests distributional generalisation; a legacy family name is not itself a scientific requirement. At least three virgin pairs and two distinct virgin families provide a preregistered minimum holdout breadth.

## C. New HLG Virgin Search

- Status: FOUND
- Searched roots: repo:data_video, workspace-parent
- Candidate count: 2
- a metadata-verified, decoded, strongly aligned, objective-unexposed local HLG/BT.709 pair is available

## D. New HLG Audit

- Objective evaluation count: 0
- Accepted candidate: true
- Existing consumed HLG IDs: dvb_live_linear_caminandes_hevc_uhd_sdr_hlg, v6_kbs_dirty_work_hlg

## E. Final Virgin Frozen Composition

- solemates_unh0400_0010: UNKNOWN, SoleMates, CONSUMED_HOLDOUT, objectiveEvaluated=true, provenance=external:v5-attempt-1:INCOMPLETE
- dvb_live_linear_caminandes_hevc_uhd_sdr_hlg: UNKNOWN, DVB Live-Linear, CONSUMED_HOLDOUT, objectiveEvaluated=true, provenance=external:v5-attempt-1:INCOMPLETE
- live_8_drawing_3840x2160_15000k: UNKNOWN, LIVE, CONSUMED_HOLDOUT, objectiveEvaluated=true, provenance=external:v5-attempt-1:INCOMPLETE
- v6_kbs_dirty_work_hlg: HLG, K-Choreo, VIRGIN_FROZEN, objectiveEvaluated=false, provenance=
- v6_live_2_basketball_evening_pq: PQ, LIVE, VIRGIN_FROZEN, objectiveEvaluated=false, provenance=
- v6_live_3_cafe_pq: PQ, LIVE, VIRGIN_FROZEN, objectiveEvaluated=false, provenance=

## F. Transfer Coverage

- Required: HLG, PQ
- Actual: HLG, PQ
- Status: PASS

## G. Family Coverage

- Required distinct families: 2
- Actual: K-Choreo, LIVE
- Status: PASS

## H. Temporal Window Policy

- Target: 16
- Minimum: 8
- Short-window rules: full target passes; at/above minimum passes with VALID_SHORT_WINDOW_ABOVE_MINIMUM; below minimum fails
- Weighting: EQUAL_SCENE_WINDOW_WEIGHT;FRAMES_WITHIN_WINDOW_ONLY

## I. Real Window Results

- Interview: - live_13_interview_3840x2160_15000k scene_0001: 16/16, accepted=true, reason=FULL_TARGET_LENGTH
- Campfire: - live_4_campfire_3840x2160_15000k scene_0001: 16/16, accepted=true, reason=FULL_TARGET_LENGTH

## J. Executable Evidence

- v6PreparedEvaluationPlan: required=true, executed=true, status=PASS, evidence=one canonical V6 preparation plan is shared by preflight and read-only evaluator-entry materialization; sha256=787030fc7ac64a3795881c5cf2e9fc2114d30f2c0a50078496def64427ad6ffd; matcherConfigurationHash=af4e7b3bc2aa24bc1cf178fea16cb8b6c0fc032a1fb9759dd6d0a28b3c426a52
- dataset-audit-lock: required=true, executed=true, status=PASS, evidence=validator consumed READY audit + manifest/lock evidence; Tune/Validation media digests were checked and Frozen media remained sealed
- v6FrozenPreparedEvaluationPlan: required=true, executed=true, status=PASS, evidence=metadata-only admission validated the exact Frozen plan used by evaluator entry; sha256=8ee1d463e7e108e54983b0252f10c5dec53c780beae69e08c8ecf451ae9fb10b
- sparse-index-domain: required=true, executed=true, status=PASS, evidence=V6 PreparedEvaluationPlan checked exact requested/evaluated IDs using sequencePosition
- sparseSpatialTemporalSeparation: required=true, executed=true, status=PASS, evidence=sparse spatial evaluation is isolated to deterministic neutral temporal state; contiguous-window evidence is reported separately
- realTemporalWindowPreparation: required=true, executed=true, status=PASS, evidence=decoded 656 paired contiguous frames across 41 valid windows
- preFrozenHoldoutPreservation: required=true, executed=true, status=PASS, evidence=pre-Frozen gate machine was executed with FAIL and NOT_MEASURED states; both block holdout access and produce incomplete/failure verdicts
- holdoutProvenance: required=true, executed=true, status=PASS, evidence=no eligible V6 Virgin Frozen pair appears in prior frozen objective artifacts; attempt-1 IDs/assets are explicitly excluded
- transferCoverageSemantics: required=true, executed=true, status=PASS, evidence=all preregistered transfer families are present using only fully accepted main-calibration audit records
- frozenPairCountSemantics: required=true, executed=true, status=PASS, evidence=preregistered minimum Virgin Frozen pair count is satisfied using only fully eligible, unconsumed holdouts
- familyCoverageSemantics: required=true, executed=true, status=PASS, evidence=preregistered family diversity is present using only fully accepted main-calibration audit records
- newHLGVirginHoldout: required=true, executed=true, status=PASS, evidence=a metadata-verified, decoded, strongly aligned, objective-unexposed local HLG/BT.709 pair is available
- evidencePortability: required=true, executed=true, status=PASS, evidence=copied identical source trees into two different checkout roots and verified identical source identity plus repository-relative evidence paths
- absolutePathLeakCheck: required=true, executed=true, status=PASS, evidence=existing V4 evidence artifacts contain no user- or volume-specific absolute paths
- structuralCompleteness: required=true, executed=true, status=PASS, evidence=all requested Tune/Validation pairs have aligned coverage and at least one genuinely prepared contiguous temporal window
- temporal-production-offline-parity: required=true, executed=true, status=PASS, evidence=production HDRProcessor and HDRCoreOfflineEvaluator were executed in this run for V2 and V4 causal sequences and matched within 1e-6
- one-frame-causal-diagnostic: required=true, executed=true, status=PASS, evidence=first-frame diagnostic records state applied to the current frame before the completion update
- temporalBurstParity: required=true, executed=true, status=PASS, evidence=frame-by-frame burst trace verifies each encoded frame against the serial reference state identified by its actual latest-completed state version
- percentile-production-offline-parity: required=true, executed=true, status=PASS, evidence=16x9/16-bin production quantization, bin-center percentile, sample count, and repeated ramp statistics were executed and matched in this run
- hlg-bt2100-ootf: required=true, executed=true, status=PASS, evidence=gray and colored HLG vectors were evaluated in this run and matched one BT.2020-luminance-derived OOTF gain
- strict-sdr-metadata: required=true, executed=true, status=PASS, evidence=explicit BT.709 SDR metadata was accepted and six missing/wrong primaries-transfer-matrix-range cases were rejected in this run
- relation-preservation: required=true, executed=true, status=PASS, evidence=current manifest relations were evaluated directly; only main-calibration relations are accepted
- eligible-only-diversity: required=true, executed=true, status=PASS, evidence=synthetic accepted+rejected audit records were aggregated in this run; rejected/Frozen record contributed to no diversity count
- source-freeze-hash: required=true, executed=true, status=PASS, evidence=source and executable mutations changed their independent hashes; removing a required source caused the required-source hard failure
- freeze-integrity: required=true, executed=true, status=PASS, evidence=candidate freeze guard was exercised with both dirty and clean working-tree states
- runtime-measurement: required=true, executed=true, status=PASS, evidence=runtime within tolerance: GPU p50 0.705→0.702 ms, GPU p95 1.981→1.839 ms, CPU p95 0.064→0.071 ms
- promotion-gate-wiring: required=true, executed=true, status=PASS, evidence=gate machine was executed in this run for pass, transfer fail, runtime fail, frozen fail, not-measured, and hard-safety precedence states

## K. Temporal Parity

- Serial: production HDRProcessor and HDRCoreOfflineEvaluator were executed in this run for V2 and V4 causal sequences and matched within 1e-6
- Burst: frame-by-frame burst trace verifies each encoded frame against the serial reference state identified by its actual latest-completed state version

## L. Evidence Portability

- Status: PASS

## M. Freeze Integrity

- Dirty candidate freeze rejected: true
- Clean candidate freeze allowed: true
- Current working tree dirty: true

## N. Virgin Frozen Preservation

- objectiveEvaluationCount: 0
- No Virgin Frozen pixels were read by correctness review.

## O. macOS Build/Test

- Recorded by the task runner after this review; correctness review itself does not synthesize build results.

## P. Remaining Risks

- No new HLG acquisition risk remains.
- Current worktree is dirty, so a real future candidate freeze remains blocked until a clean tree is supplied.

## Q. Verdict

CORRECTNESS_READY_FOR_V6