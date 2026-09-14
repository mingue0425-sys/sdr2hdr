# PR #13 — V4 semantic-source inventory

This is the bounded inventory for the V4 closure work. It covers only the
preregistered V4 execution path and the previously identified audit areas:
preparation, matcher, metric/color science, gates/ranking/failure, the final
runner adapter, deterministic ordering/reduction, and materialization-root
path safety.

This document is a review aid. It is not an exhaustive source scan and the
static inventory check must not be interpreted as proof that no unrelated
source file contains a semantic constant.

| Area | Runtime source | Semantic field(s) | Current owner | Sealed owner | Previously identified gap | V4 fix | Test evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Preparation | `Sources/HDRCalibration/Evaluation.swift`, `Alignment.swift`, `PreparedEvaluationPlan.swift` | frame limits and sampling, metadata interpretation, scene segmentation/classification thresholds, alignment thresholds, temporal anchor/selection, representative-frame rules, geometry, failure policy | `V6PreparationConfiguration` and its nested immutable semantic configurations | `SDRPreparationDefinitionV4` → canonical `V6PreparationConfiguration` identity | plan-affecting preparation values had escaped the prior V3 seal | production preparation receives the same typed configuration whose canonical representation produces `PreparationDefinitionHashV4` | `V4SemanticClosureTests.testV4PreparationMutationMatrix` |
| Matcher | `Sources/HDRCalibration/TransferInvariantMatcher.swift`, `Alignment.swift` | grid, offsets, scale widths, weights, confidence/fallback limits, matcher validation limits and ordering | `V6MatcherConfiguration` plus `V6MatcherValidationSemanticConfiguration` | nested matcher identity inside `V6PreparationConfiguration` → `PreparationDefinitionHashV4` | matcher fallback/validation values were not all structurally bound | matcher and alignment code consume the sealed matcher object directly; canonical field coverage is guarded | `V4SemanticClosureTests.testV4PreparationMutationMatrix`, `testV4SensitivityAxesAndRunnerOnlySemanticsAreSealedAndConsumed` |
| Metric / ICtCp / PQ | `Sources/HDRCalibration/V2Metrics.swift`, `V2Runner.swift`, `Sources/HDRCore/ColorManagement.swift`, `ColorScienceSemanticDefinition.swift` | objective thresholds, weights, percentiles, clamps, aggregation/reduction order, PQ constants, ICtCp matrices/co-efficients and normalization | `V2MetricSemanticConfiguration` containing the immutable `ColorScienceSemanticDefinition` | `MetricDefinitionHashV4` → `ColorScienceDefinitionHash` and metric canonical fields | production metric color math had independent ICtCp/PQ literals outside the V3 metric identity | metric/color code consumes the shared color-science definition; metric reductions use typed stable-order rules | `V4SemanticClosureTests.testV4MetricAndColorScienceMutationMatrix`, `testV4MetricReductionsIgnoreDictionaryInsertionOrder` |
| Gate / ranking / failure | `Sources/HDRCalibration/PreregistrationSealV4.swift`, `V4Calibration.swift` | metric identity, comparison operator, threshold, direction, NaN/missing/failure behavior, candidate ordering, tie-break keys, shortlist/failure policy | executable `V4GateDefinition`, `V4CandidateOrderingDefinition`, `V4FailurePolicyDefinition` | `GateDefinitionHash` and the final `RunnerDefinitionHash`/`SearchDefinitionHashV4` | V3 relied on descriptive strings and runner-local decisions | V4 definitions are typed, canonicalized, validated, and consumed by the production runner before search | `V4SemanticClosureTests.testV4GateRunnerAndSearchMutationMatrix`, `testV4RuntimeBindingRejectsSemanticOverrides` |
| Final runner adapter | `Sources/HDRCalibration/PreregistrationSealV4.swift`, `V4Calibration.swift`, `V4Models.swift` | adapted ranges, policies, phase budgets, gates, coverage requirements, output/fallback, scene-relative behavior and all final runner inputs | `V4FinalRunnerSemanticConfiguration` derived from the V4 runtime configuration | `RunnerDefinitionHash` and exact final runner semantic identity | post-seal adapter-only values could diverge from the sealed definitions | adaptation is followed by canonical identity calculation and exact equality verification before candidate generation | `V4SemanticClosureTests.testV4FinalRunnerIdentityMatchesSeal`, `testV4RuntimeBindingRejectsSemanticOverrides` |
| Deterministic ordering / reduction | `Sources/HDRCalibration/V2Metrics.swift`, `V2Runner.swift`, `V4Calibration.swift` | canonical family/frame/window ordering, floating-point reduction order, candidate tie-break order and stable identity fallback | typed ordering rules plus explicit UTF-8 canonical sorting at each calibration-critical reduction | metric, search-algorithm, gate and runner identities | unordered dictionary/set iteration could change scores, gates, or shortlist selection | collection values are sorted by explicit semantic keys before reduction/ranking; typed ordering rules are sealed | `V4SemanticClosureTests.testV4MetricReductionsIgnoreDictionaryInsertionOrder`, `testV4CanonicalizationAdversarialCases` |
| Materialization-root path safety | `Tests/inventory_development_corpus.py`, `Tests/test_inventory_development_corpus.py` | trusted anchor, component-wise no-follow checks, root/parent/intermediate symlink denial and lexical path denial | `_lstat_components` and `validate_no_symlink_components` | execution safety guard (not a media/corpus identity) | materialization-root parents were outside the previous trust check | every untrusted component from the trusted anchor is checked before traversal; synthetic fixtures fail closed | `test_inventory_development_corpus.py` symlink, chain, protected-root, parent, `..`, absolute-path and NUL matrix |

## Bounded closure invariant

For the seven areas above, every experiment-affecting value has one typed
semantic owner. The V4 production path consumes that owner and the V4 identity
is derived from the same object. The inventory deliberately does not claim
that unrelated development or legacy APIs are part of preregistered V4
execution; those entry points remain explicitly separated and are not
calibration evidence.

`CorpusDefinitionHash` and `ExperimentBindingHash` remain `NOT YET CREATED`.
No media bytes were accessed and objective evaluations remain `0`.
