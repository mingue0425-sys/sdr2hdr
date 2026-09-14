import Foundation
import HDRCore
import Metal

enum V4CanonicalOrdering {
    static func stringLess(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8))
    }
}

public enum V4ComparisonOperator: String, Codable, Hashable, Sendable {
    case lessThan
    case lessThanOrEqual
    case equal
    case greaterThan
    case greaterThanOrEqual

    func accepts(_ value: Double, threshold: Double) -> Bool {
        guard value.isFinite, threshold.isFinite else { return false }
        switch self {
        case .lessThan: return value < threshold
        case .lessThanOrEqual: return value <= threshold
        case .equal: return value == threshold
        case .greaterThan: return value > threshold
        case .greaterThanOrEqual: return value >= threshold
        }
    }
}

public enum V4FailureAction: String, Codable, Hashable, Sendable {
    case reject
    case abort
    case retrySameConfiguration
}

/// Names the objective value consumed by a gate.  The name is part of the
/// executable contract; it prevents a comparator from being silently reused
/// for a different metric while retaining the same threshold value.
public enum V4GateMetricIdentity: String, Codable, Hashable, Sendable {
    case invalidSampleCount
    case clippingRatio
    case blackCrushRatio
    case shadowError
    case shadowLiftRatio
    case temporalFlicker
    case objective
    case highlightError
    case midtoneError
    case hueP95Error
    case shadowDelta
    case shadowLiftDelta
    case temporalDelta
    case perVideoCatastrophicCount
    case perVideoRegressionCount
}

/// Thresholds are stored in `V4SafetyThresholds`; this typed source name is
/// the link between a comparator and the exact threshold expression used by
/// the runner.
public enum V4GateThresholdIdentity: String, Codable, Hashable, Sendable {
    case zeroTolerance
    case zeroInvalidSampleCount
    case zeroCount
    case candidateClippingRatio
    case candidateBlackCrushRatio
    case candidateShadowError
    case candidateShadowLiftRatio
    case candidateTemporalFlicker
    case baselineObjective
    case baselineShadowError
    case baselineShadowLiftRatio
    case baselineTemporalFlicker
    case baselineHighlightError
    case baselineMidtoneError
    case baselineHueP95Error
    case baselineClippingRatio
    case baselineBlackCrushRatio
    case catastrophicObjective
    case catastrophicShadowError
    case perVideoObjective
    case perVideoShadowError
    case groupedObjective
    case groupedShadowError
    case groupedTemporalFlicker
    case overallImprovement
    case frozenMinimumImprovement
    case sensitivityShadowDeltaMinimum
    case sensitivityShadowMonotonicTolerance
    case sensitivityTemporalDeltaMinimum
}

public struct V4ComparisonDefinition: Codable, Hashable, Sendable {
    public let metric: V4GateMetricIdentity
    public let threshold: V4GateThresholdIdentity
    public let operation: V4ComparisonOperator
    public let nonFiniteAction: V4FailureAction
    public let missingValueAction: V4FailureAction

    public init(
        operation: V4ComparisonOperator,
        metric: V4GateMetricIdentity = .objective,
        threshold: V4GateThresholdIdentity = .baselineObjective,
        nonFiniteAction: V4FailureAction = .reject,
        missingValueAction: V4FailureAction = .reject
    ) {
        self.metric = metric
        self.threshold = threshold
        self.operation = operation
        self.nonFiniteAction = nonFiniteAction
        self.missingValueAction = missingValueAction
    }

    public func accepts(_ value: Double, threshold: Double) -> Bool {
        guard value.isFinite, threshold.isFinite else {
            // The current sealed failure policy is reject.  Keeping the
            // action in the typed definition means a future policy change
            // cannot happen without changing the identity.
            return false
        }
        return operation.accepts(value, threshold: threshold)
    }

    public func accepts(_ value: Double?, threshold: Double) -> Bool {
        guard let value else { return false }
        return accepts(value, threshold: threshold)
    }
}

public enum V4GateEvaluationStep: String, Codable, Hashable, CaseIterable, Sendable {
    case finiteObjective = "finite-objective"
    case invalidSampleCount = "invalid-sample-count"
    case clipping
    case blackCrush = "black-crush"
    case shadowError = "shadow-error"
    case shadowLift = "shadow-lift"
    case temporalFlicker = "temporal-flicker"
    case perVideoCatastrophic = "per-video-catastrophic"
}

public enum V4PromotionGate: String, Codable, Hashable, CaseIterable, Sendable {
    case hardSafety
    case completeness
    case datasetIntegrity
    case identifiability
    case relativeShadow
    case overall
    case shadow
    case temporal
    case transfer
    case family
    case frozen
    case runtime
}

public enum V4RankingMetric: String, Codable, Hashable, Sendable {
    case objective
    case temporalFlicker
    case clippingRatio
    case nearBlackContrastLoss
}

public enum V4SortDirection: String, Codable, Hashable, Sendable {
    case ascending
    case descending
}

public struct V4RankingKeyDefinition: Codable, Hashable, Sendable {
    public let metric: V4RankingMetric
    public let direction: V4SortDirection

    public init(metric: V4RankingMetric, direction: V4SortDirection = .ascending) {
        self.metric = metric
        self.direction = direction
    }
}

public enum V4FinalTieBreak: String, Codable, Hashable, Sendable {
    case canonicalParameterVectorThenCandidateIDAscending
}

public struct V4CandidateOrderingDefinition: Codable, Hashable, Sendable {
    public let tuneKeys: [V4RankingKeyDefinition]
    public let validationKeys: [V4RankingKeyDefinition]
    public let finalTieBreak: V4FinalTieBreak

    public init(
        tuneKeys: [V4RankingKeyDefinition] = V4CandidateOrderingDefinition.defaultKeys,
        validationKeys: [V4RankingKeyDefinition] = V4CandidateOrderingDefinition.defaultKeys,
        finalTieBreak: V4FinalTieBreak = .canonicalParameterVectorThenCandidateIDAscending
    ) {
        self.tuneKeys = tuneKeys
        self.validationKeys = validationKeys
        self.finalTieBreak = finalTieBreak
    }

    public static let defaultKeys = [
        V4RankingKeyDefinition(metric: .objective),
        V4RankingKeyDefinition(metric: .temporalFlicker),
        V4RankingKeyDefinition(metric: .clippingRatio),
        V4RankingKeyDefinition(metric: .nearBlackContrastLoss)
    ]

    public static let current = V4CandidateOrderingDefinition()
}

public struct V4FailurePolicyDefinition: Codable, Hashable, Sendable {
    public let nonFiniteMetric: V4FailureAction
    public let missingMetric: V4FailureAction
    public let candidateEvaluationError: V4FailureAction
    public let preparationFailure: V4FailureAction
    public let partialPolicyFailure: V4FailureAction
    public let emptyShortlist: V4FailureAction

    public init(
        nonFiniteMetric: V4FailureAction = .reject,
        missingMetric: V4FailureAction = .reject,
        candidateEvaluationError: V4FailureAction = .abort,
        preparationFailure: V4FailureAction = .abort,
        partialPolicyFailure: V4FailureAction = .abort,
        emptyShortlist: V4FailureAction = .abort
    ) {
        self.nonFiniteMetric = nonFiniteMetric
        self.missingMetric = missingMetric
        self.candidateEvaluationError = candidateEvaluationError
        self.preparationFailure = preparationFailure
        self.partialPolicyFailure = partialPolicyFailure
        self.emptyShortlist = emptyShortlist
    }

    public static let current = V4FailurePolicyDefinition()
}

/// Every comparator used before shortlist/validation selection is executable
/// data.  Safety thresholds remain in `V4SafetyThresholds`; this value binds
/// the metric, comparator, and failure behavior applied to those thresholds.
public struct V4GateDefinition: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-gate-definition-v4"

    public let semanticVersion: String
    public let candidateObjectiveMustBeFinite: Bool
    public let candidateInvalidSampleCount: V4ComparisonDefinition
    public let candidateClippingRatio: V4ComparisonDefinition
    public let candidateBlackCrushRatio: V4ComparisonDefinition
    public let candidateShadowError: V4ComparisonDefinition
    public let candidateShadowLiftRatio: V4ComparisonDefinition
    public let candidateTemporalFlicker: V4ComparisonDefinition
    public let candidatePerVideoCatastrophicCount: V4ComparisonDefinition
    public let validationObjective: V4ComparisonDefinition
    public let validationShadowError: V4ComparisonDefinition
    public let validationShadowLiftRatio: V4ComparisonDefinition
    public let validationTemporalFlicker: V4ComparisonDefinition
    public let validationHighlightError: V4ComparisonDefinition
    public let validationMidtoneError: V4ComparisonDefinition
    public let validationHueP95Error: V4ComparisonDefinition
    public let validationClippingRatio: V4ComparisonDefinition
    public let validationBlackCrushRatio: V4ComparisonDefinition
    public let validationInvalidSampleCount: V4ComparisonDefinition
    public let validationPerVideoCatastrophicCount: V4ComparisonDefinition
    public let catastrophicObjective: V4ComparisonDefinition
    public let catastrophicShadowError: V4ComparisonDefinition
    public let perVideoObjective: V4ComparisonDefinition
    public let perVideoShadowError: V4ComparisonDefinition
    public let groupedObjective: V4ComparisonDefinition
    public let groupedShadowError: V4ComparisonDefinition
    public let groupedTemporalFlicker: V4ComparisonDefinition
    public let overallImprovement: V4ComparisonDefinition
    public let frozenImprovement: V4ComparisonDefinition
    public let frozenPerVideoRegressionCount: V4ComparisonDefinition
    public let sensitivityShadowDelta: V4ComparisonDefinition
    public let sensitivityShadowMonotonic: V4ComparisonDefinition
    public let sensitivityTemporalDelta: V4ComparisonDefinition
    public let gateEvaluationOrder: [V4GateEvaluationStep]
    public let promotionPrecedence: [V4PromotionGate]
    public let ordering: V4CandidateOrderingDefinition
    public let failurePolicy: V4FailurePolicyDefinition

    public init(
        semanticVersion: String = V4GateDefinition.semanticVersion,
        candidateObjectiveMustBeFinite: Bool = true,
        candidateInvalidSampleCount: V4ComparisonDefinition = .init(operation: .equal, metric: .invalidSampleCount, threshold: .zeroInvalidSampleCount),
        candidateClippingRatio: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .clippingRatio, threshold: .candidateClippingRatio),
        candidateBlackCrushRatio: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .blackCrushRatio, threshold: .candidateBlackCrushRatio),
        candidateShadowError: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .shadowError, threshold: .candidateShadowError),
        candidateShadowLiftRatio: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .shadowLiftRatio, threshold: .candidateShadowLiftRatio),
        candidateTemporalFlicker: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .temporalFlicker, threshold: .candidateTemporalFlicker),
        candidatePerVideoCatastrophicCount: V4ComparisonDefinition = .init(operation: .equal, metric: .perVideoCatastrophicCount, threshold: .zeroCount),
        validationObjective: V4ComparisonDefinition = .init(operation: .lessThan, metric: .objective, threshold: .baselineObjective),
        validationShadowError: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .shadowError, threshold: .baselineShadowError),
        validationShadowLiftRatio: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .shadowLiftRatio, threshold: .baselineShadowLiftRatio),
        validationTemporalFlicker: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .temporalFlicker, threshold: .baselineTemporalFlicker),
        validationHighlightError: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .highlightError, threshold: .baselineHighlightError),
        validationMidtoneError: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .midtoneError, threshold: .baselineMidtoneError),
        validationHueP95Error: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .hueP95Error, threshold: .baselineHueP95Error),
        validationClippingRatio: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .clippingRatio, threshold: .baselineClippingRatio),
        validationBlackCrushRatio: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .blackCrushRatio, threshold: .baselineBlackCrushRatio),
        validationInvalidSampleCount: V4ComparisonDefinition = .init(operation: .equal, metric: .invalidSampleCount, threshold: .zeroInvalidSampleCount),
        validationPerVideoCatastrophicCount: V4ComparisonDefinition = .init(operation: .equal, metric: .perVideoCatastrophicCount, threshold: .zeroCount),
        catastrophicObjective: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .objective, threshold: .catastrophicObjective),
        catastrophicShadowError: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .shadowError, threshold: .catastrophicShadowError),
        perVideoObjective: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .objective, threshold: .perVideoObjective),
        perVideoShadowError: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .shadowError, threshold: .perVideoShadowError),
        groupedObjective: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .objective, threshold: .groupedObjective),
        groupedShadowError: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .shadowError, threshold: .groupedShadowError),
        groupedTemporalFlicker: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .temporalFlicker, threshold: .groupedTemporalFlicker),
        overallImprovement: V4ComparisonDefinition = .init(operation: .greaterThan, metric: .objective, threshold: .overallImprovement),
        frozenImprovement: V4ComparisonDefinition = .init(operation: .greaterThanOrEqual, metric: .objective, threshold: .frozenMinimumImprovement),
        frozenPerVideoRegressionCount: V4ComparisonDefinition = .init(operation: .equal, metric: .perVideoRegressionCount, threshold: .zeroCount),
        sensitivityShadowDelta: V4ComparisonDefinition = .init(operation: .greaterThan, metric: .shadowDelta, threshold: .sensitivityShadowDeltaMinimum),
        sensitivityShadowMonotonic: V4ComparisonDefinition = .init(operation: .lessThanOrEqual, metric: .shadowLiftDelta, threshold: .sensitivityShadowMonotonicTolerance),
        sensitivityTemporalDelta: V4ComparisonDefinition = .init(operation: .greaterThan, metric: .temporalDelta, threshold: .sensitivityTemporalDeltaMinimum),
        gateEvaluationOrder: [V4GateEvaluationStep] = [
            .finiteObjective, .invalidSampleCount, .clipping, .blackCrush,
            .shadowError, .shadowLift, .temporalFlicker, .perVideoCatastrophic
        ],
        promotionPrecedence: [V4PromotionGate] = [
            .hardSafety, .completeness, .datasetIntegrity, .identifiability,
            .relativeShadow, .overall, .shadow, .temporal, .transfer,
            .family, .frozen, .runtime
        ],
        ordering: V4CandidateOrderingDefinition = .current,
        failurePolicy: V4FailurePolicyDefinition = .current
    ) {
        self.semanticVersion = semanticVersion
        self.candidateObjectiveMustBeFinite = candidateObjectiveMustBeFinite
        self.candidateInvalidSampleCount = candidateInvalidSampleCount
        self.candidateClippingRatio = candidateClippingRatio
        self.candidateBlackCrushRatio = candidateBlackCrushRatio
        self.candidateShadowError = candidateShadowError
        self.candidateShadowLiftRatio = candidateShadowLiftRatio
        self.candidateTemporalFlicker = candidateTemporalFlicker
        self.candidatePerVideoCatastrophicCount = candidatePerVideoCatastrophicCount
        self.validationObjective = validationObjective
        self.validationShadowError = validationShadowError
        self.validationShadowLiftRatio = validationShadowLiftRatio
        self.validationTemporalFlicker = validationTemporalFlicker
        self.validationHighlightError = validationHighlightError
        self.validationMidtoneError = validationMidtoneError
        self.validationHueP95Error = validationHueP95Error
        self.validationClippingRatio = validationClippingRatio
        self.validationBlackCrushRatio = validationBlackCrushRatio
        self.validationInvalidSampleCount = validationInvalidSampleCount
        self.validationPerVideoCatastrophicCount = validationPerVideoCatastrophicCount
        self.catastrophicObjective = catastrophicObjective
        self.catastrophicShadowError = catastrophicShadowError
        self.perVideoObjective = perVideoObjective
        self.perVideoShadowError = perVideoShadowError
        self.groupedObjective = groupedObjective
        self.groupedShadowError = groupedShadowError
        self.groupedTemporalFlicker = groupedTemporalFlicker
        self.overallImprovement = overallImprovement
        self.frozenImprovement = frozenImprovement
        self.frozenPerVideoRegressionCount = frozenPerVideoRegressionCount
        self.sensitivityShadowDelta = sensitivityShadowDelta
        self.sensitivityShadowMonotonic = sensitivityShadowMonotonic
        self.sensitivityTemporalDelta = sensitivityTemporalDelta
        self.gateEvaluationOrder = gateEvaluationOrder
        self.promotionPrecedence = promotionPrecedence
        self.ordering = ordering
        self.failurePolicy = failurePolicy
    }

    public static let current = V4GateDefinition()

    public func validate() throws {
        let definitions: [(V4ComparisonDefinition, V4GateMetricIdentity, V4GateThresholdIdentity)] = [
            (candidateInvalidSampleCount, .invalidSampleCount, .zeroInvalidSampleCount),
            (candidateClippingRatio, .clippingRatio, .candidateClippingRatio),
            (candidateBlackCrushRatio, .blackCrushRatio, .candidateBlackCrushRatio),
            (candidateShadowError, .shadowError, .candidateShadowError),
            (candidateShadowLiftRatio, .shadowLiftRatio, .candidateShadowLiftRatio),
            (candidateTemporalFlicker, .temporalFlicker, .candidateTemporalFlicker),
            (candidatePerVideoCatastrophicCount, .perVideoCatastrophicCount, .zeroCount),
            (validationObjective, .objective, .baselineObjective),
            (validationShadowError, .shadowError, .baselineShadowError),
            (validationShadowLiftRatio, .shadowLiftRatio, .baselineShadowLiftRatio),
            (validationTemporalFlicker, .temporalFlicker, .baselineTemporalFlicker),
            (validationHighlightError, .highlightError, .baselineHighlightError),
            (validationMidtoneError, .midtoneError, .baselineMidtoneError),
            (validationHueP95Error, .hueP95Error, .baselineHueP95Error),
            (validationClippingRatio, .clippingRatio, .baselineClippingRatio),
            (validationBlackCrushRatio, .blackCrushRatio, .baselineBlackCrushRatio),
            (validationInvalidSampleCount, .invalidSampleCount, .zeroInvalidSampleCount),
            (validationPerVideoCatastrophicCount, .perVideoCatastrophicCount, .zeroCount),
            (catastrophicObjective, .objective, .catastrophicObjective),
            (catastrophicShadowError, .shadowError, .catastrophicShadowError),
            (perVideoObjective, .objective, .perVideoObjective),
            (perVideoShadowError, .shadowError, .perVideoShadowError),
            (groupedObjective, .objective, .groupedObjective),
            (groupedShadowError, .shadowError, .groupedShadowError),
            (groupedTemporalFlicker, .temporalFlicker, .groupedTemporalFlicker),
            (overallImprovement, .objective, .overallImprovement),
            (frozenImprovement, .objective, .frozenMinimumImprovement),
            (frozenPerVideoRegressionCount, .perVideoRegressionCount, .zeroCount),
            (sensitivityShadowDelta, .shadowDelta, .sensitivityShadowDeltaMinimum),
            (sensitivityShadowMonotonic, .shadowLiftDelta, .sensitivityShadowMonotonicTolerance),
            (sensitivityTemporalDelta, .temporalDelta, .sensitivityTemporalDeltaMinimum)
        ]
        guard semanticVersion == Self.semanticVersion,
              definitions.allSatisfy({
                  $0.0.metric == $0.1 && $0.0.threshold == $0.2 &&
                  $0.0.nonFiniteAction == .reject && $0.0.missingValueAction == .reject
              }),
              gateEvaluationOrder.count == V4GateEvaluationStep.allCases.count,
              Set(gateEvaluationOrder) == Set(V4GateEvaluationStep.allCases),
              promotionPrecedence.count == V4PromotionGate.allCases.count,
              Set(promotionPrecedence) == Set(V4PromotionGate.allCases),
              !ordering.tuneKeys.isEmpty,
              !ordering.validationKeys.isEmpty,
              failurePolicy.nonFiniteMetric == .reject,
              failurePolicy.missingMetric == .reject,
              failurePolicy.candidateEvaluationError == .abort,
              failurePolicy.preparationFailure == .abort,
              failurePolicy.partialPolicyFailure == .abort,
              failurePolicy.emptyShortlist == .abort else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }

}

public enum V4SearchPhase: String, Codable, Hashable, Sendable {
    case sensitivity
    case global
    case local
}

public enum V4SamplingDistribution: String, Codable, Hashable, Sendable {
    case haltonAffineBounds
    case haltonNeighborhoodAffineClamp
}

public enum V4DuplicateHandling: String, Codable, Hashable, Sendable {
    case retainAndStableRank
}

public enum V4LocalParentSelection: String, Codable, Hashable, Sendable {
    case topGatePassingGlobalThenCyclic
}

public enum V4SearchParameterDimension: String, Codable, Hashable, Sendable, CaseIterable {
    case paperWhiteNits
    case peakNits
    case highlightStrength
    case contrastStrength
    case saturationCompensation
    case shadowProtection
    case temporalStability
}

public enum V4SensitivityMeasure: String, Codable, Hashable, Sendable {
    case shadowLiftRatio
    case temporalFlickerPlusHighlightPumping
}

public enum V4SensitivityProbeOrdering: String, Codable, Hashable, Sendable {
    case ascendingProbeValue
}

public enum V4SensitivityMonotonicRule: String, Codable, Hashable, Sendable {
    /// Preserve the current identifiability gate: each successive measured
    /// shadow-lift delta must not exceed the sealed tolerance.  The rule is
    /// named because the arithmetic and its direction are experiment
    /// semantics, not a report-format detail.
    case consecutiveDeltaLessThanOrEqualTolerance
    case notApplicable
}

/// Sensitivity probes are part of the search phase.  The runner must consume
/// these axes rather than embedding parameter names or metric combinations in
/// its implementation.
public struct V4SensitivityAxisDefinition: Codable, Hashable, Sendable {
    public let parameter: V4SearchParameterDimension
    public let measure: V4SensitivityMeasure
    public let probeOrdering: V4SensitivityProbeOrdering
    public let monotonicRule: V4SensitivityMonotonicRule

    public init(
        parameter: V4SearchParameterDimension,
        measure: V4SensitivityMeasure,
        probeOrdering: V4SensitivityProbeOrdering = .ascendingProbeValue,
        monotonicRule: V4SensitivityMonotonicRule = .notApplicable
    ) {
        self.parameter = parameter
        self.measure = measure
        self.probeOrdering = probeOrdering
        self.monotonicRule = monotonicRule
    }

    public static let current: [V4SensitivityAxisDefinition] = [
        V4SensitivityAxisDefinition(
            parameter: .shadowProtection,
            measure: .shadowLiftRatio,
            monotonicRule: .consecutiveDeltaLessThanOrEqualTolerance
        ),
        V4SensitivityAxisDefinition(
            parameter: .temporalStability,
            measure: .temporalFlickerPlusHighlightPumping
        )
    ]

    public var isValid: Bool {
        probeOrdering == .ascendingProbeValue && {
            switch (parameter, measure, monotonicRule) {
            case (.shadowProtection, .shadowLiftRatio, .consecutiveDeltaLessThanOrEqualTolerance):
                return true
            case (.temporalStability, .temporalFlickerPlusHighlightPumping, .notApplicable):
                return true
            default:
                return false
            }
        }()
    }
}

public enum V4StableOrderingRule: String, Codable, Hashable, Sendable {
    case canonicalUTF8AscendingBeforeFloatingPointReduction = "family-key-ascending-UTF8-before-floating-point-reduction"
}

public enum V4ParameterNumericType: String, Codable, Hashable, Sendable {
    case float32Runtime
}

public enum V4ParameterSamplingRule: String, Codable, Hashable, Sendable {
    case affineClosedRangeThenFloat32Cast
    case neighborhoodAffineClampThenFloat32Cast
}

/// Typed representation of the parameter vector consumed by the search
/// runner.  The dimension order is the single source used by candidate
/// generation and by the final tie-break identity.
public struct V4ParameterRepresentationDefinition: Codable, Hashable, Sendable {
    public let numericType: V4ParameterNumericType
    public let finiteOnly: Bool
    public let dimensionOrder: [V4SearchParameterDimension]
    public let globalSamplingRule: V4ParameterSamplingRule
    public let localSamplingRule: V4ParameterSamplingRule

    public init(
        numericType: V4ParameterNumericType = .float32Runtime,
        finiteOnly: Bool = true,
        dimensionOrder: [V4SearchParameterDimension] = V4SearchParameterDimension.allCases,
        globalSamplingRule: V4ParameterSamplingRule = .affineClosedRangeThenFloat32Cast,
        localSamplingRule: V4ParameterSamplingRule = .neighborhoodAffineClampThenFloat32Cast
    ) {
        self.numericType = numericType
        self.finiteOnly = finiteOnly
        self.dimensionOrder = dimensionOrder
        self.globalSamplingRule = globalSamplingRule
        self.localSamplingRule = localSamplingRule
    }

    public static let current = V4ParameterRepresentationDefinition()

    public var isValid: Bool {
        numericType == .float32Runtime && finiteOnly &&
            dimensionOrder == V4SearchParameterDimension.allCases &&
            globalSamplingRule == .affineClosedRangeThenFloat32Cast &&
            localSamplingRule == .neighborhoodAffineClampThenFloat32Cast
    }
}

public enum V4SeedDerivation: String, Codable, Hashable, Sendable {
    case candidateIndexPlusOnePlusSeedModuloIndexModulus
}

public struct SDRSearchAlgorithmDefinitionV4: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-search-algorithm-definition-v4"

    public let semanticVersion: String
    public let sensitivityProbeValues: [Double]
    public let sensitivityAxes: [V4SensitivityAxisDefinition]
    public let sensitivityIncludedInCandidateBudget: Bool
    public let globalCandidateCount: Int
    public let localCandidateCount: Int
    public let totalCandidatesPerPolicy: Int
    public let globalParentCount: Int
    public let phaseOrdering: [V4SearchPhase]
    public let globalSamplingDistribution: V4SamplingDistribution
    public let localSamplingDistribution: V4SamplingDistribution
    public let globalHaltonBases: [Int]
    public let localHaltonBases: [Int]
    public let parameterRepresentation: V4ParameterRepresentationDefinition
    public let localNeighborhoodRadius: Double
    public let seedIndexModulus: Int
    public let seedDerivation: V4SeedDerivation
    public let duplicateHandling: V4DuplicateHandling
    public let localRefinementParentSelection: V4LocalParentSelection

    public init(
        semanticVersion: String = SDRSearchAlgorithmDefinitionV4.semanticVersion,
        sensitivityProbeValues: [Double] = [0, 0.25, 0.5, 0.75, 1],
        sensitivityAxes: [V4SensitivityAxisDefinition] = V4SensitivityAxisDefinition.current,
        sensitivityIncludedInCandidateBudget: Bool = false,
        globalCandidateCount: Int = 128,
        localCandidateCount: Int = 64,
        totalCandidatesPerPolicy: Int = 192,
        globalParentCount: Int = 8,
        phaseOrdering: [V4SearchPhase] = [.sensitivity, .global, .local],
        globalSamplingDistribution: V4SamplingDistribution = .haltonAffineBounds,
        localSamplingDistribution: V4SamplingDistribution = .haltonNeighborhoodAffineClamp,
        globalHaltonBases: [Int] = [2, 3, 5, 7, 11, 13, 17],
        localHaltonBases: [Int] = [19, 23, 29, 31, 37, 41, 43],
        parameterRepresentation: V4ParameterRepresentationDefinition = .current,
        localNeighborhoodRadius: Double = 0.10,
        seedIndexModulus: Int = 104_729,
        seedDerivation: V4SeedDerivation = .candidateIndexPlusOnePlusSeedModuloIndexModulus,
        duplicateHandling: V4DuplicateHandling = .retainAndStableRank,
        localRefinementParentSelection: V4LocalParentSelection = .topGatePassingGlobalThenCyclic
    ) {
        self.semanticVersion = semanticVersion
        self.sensitivityProbeValues = sensitivityProbeValues
        self.sensitivityAxes = sensitivityAxes
        self.sensitivityIncludedInCandidateBudget = sensitivityIncludedInCandidateBudget
        self.globalCandidateCount = globalCandidateCount
        self.localCandidateCount = localCandidateCount
        self.totalCandidatesPerPolicy = totalCandidatesPerPolicy
        self.globalParentCount = globalParentCount
        self.phaseOrdering = phaseOrdering
        self.globalSamplingDistribution = globalSamplingDistribution
        self.localSamplingDistribution = localSamplingDistribution
        self.globalHaltonBases = globalHaltonBases
        self.localHaltonBases = localHaltonBases
        self.parameterRepresentation = parameterRepresentation
        self.localNeighborhoodRadius = localNeighborhoodRadius
        self.seedIndexModulus = seedIndexModulus
        self.seedDerivation = seedDerivation
        self.duplicateHandling = duplicateHandling
        self.localRefinementParentSelection = localRefinementParentSelection
    }

    public static let current = SDRSearchAlgorithmDefinitionV4()

    public func validate() throws {
        guard !semanticVersion.isEmpty,
              !sensitivityProbeValues.isEmpty,
              sensitivityProbeValues.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              !sensitivityAxes.isEmpty,
              sensitivityAxes.allSatisfy(\.isValid),
              Set(sensitivityAxes.map(\.parameter)).count == sensitivityAxes.count,
              sensitivityIncludedInCandidateBudget == false,
              globalCandidateCount > 0,
              localCandidateCount > 0,
              totalCandidatesPerPolicy == globalCandidateCount + localCandidateCount,
              globalParentCount > 0 && globalParentCount <= globalCandidateCount,
              phaseOrdering == [.sensitivity, .global, .local],
              globalSamplingDistribution == .haltonAffineBounds,
              localSamplingDistribution == .haltonNeighborhoodAffineClamp,
              globalHaltonBases.count == 7,
              localHaltonBases.count == 7,
              parameterRepresentation.isValid,
              globalHaltonBases.allSatisfy({ $0 > 1 }),
              localHaltonBases.allSatisfy({ $0 > 1 }),
              localNeighborhoodRadius.isFinite && localNeighborhoodRadius > 0 && localNeighborhoodRadius <= 1,
              seedIndexModulus > 0,
              seedDerivation == .candidateIndexPlusOnePlusSeedModuloIndexModulus,
              duplicateHandling == .retainAndStableRank,
              localRefinementParentSelection == .topGatePassingGlobalThenCyclic else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }

    public func samplingIndex(candidateIndex: Int, seed: UInt64) -> Int {
        candidateIndex + 1 + Int(seed % UInt64(seedIndexModulus))
    }
}

public struct V4SplitCoverageRequirement: Codable, Hashable, Sendable {
    public let split: DatasetSplit
    public let requiredTransfers: [String]
    public let requiredFamilies: [String]

    public init(split: DatasetSplit, requiredTransfers: [String], requiredFamilies: [String]) {
        self.split = split
        self.requiredTransfers = requiredTransfers.sorted(by: V4CanonicalOrdering.stringLess)
        self.requiredFamilies = requiredFamilies.sorted(by: V4CanonicalOrdering.stringLess)
    }
}

/// A fixed reference configuration used by the V4 runner's baseline and
/// sensitivity comparisons.  These values are derived from the immutable
/// HDRConfiguration presets, then carried in the runner definition.  The
/// runner never reaches back to a separate preset/default at execution time.
public struct V4CalibrationParameterPreset: Codable, Hashable, Sendable {
    public let identifier: String
    public let paperWhiteNits: Float
    public let peakNits: Float
    public let highlightStrength: Float
    public let contrastStrength: Float
    public let saturationCompensation: Float
    public let shadowProtection: Float
    public let temporalStability: Float
    public let toneCurveRevision: UInt32

    public init(
        identifier: String,
        source: HDRConfiguration,
        toneCurveRevision: HDRToneCurveRevision
    ) {
        self.identifier = identifier
        self.paperWhiteNits = source.paperWhiteNits
        self.peakNits = source.peakNits
        self.highlightStrength = source.highlightStrength
        self.contrastStrength = source.contrastStrength
        self.saturationCompensation = source.saturationCompensation
        self.shadowProtection = source.shadowProtection
        self.temporalStability = source.temporalStability
        self.toneCurveRevision = toneCurveRevision.rawValue
    }

    public var isValid: Bool {
        !identifier.isEmpty &&
            paperWhiteNits.isFinite && paperWhiteNits > 0 &&
            peakNits.isFinite && peakNits > paperWhiteNits &&
            highlightStrength.isFinite && (0...1).contains(highlightStrength) &&
            contrastStrength.isFinite && (0...1).contains(contrastStrength) &&
            saturationCompensation.isFinite && (0...1).contains(saturationCompensation) &&
            shadowProtection.isFinite && (0...1).contains(shadowProtection) &&
            temporalStability.isFinite && (0...1).contains(temporalStability) &&
            HDRToneCurveRevision(rawValue: toneCurveRevision) != nil
    }

    public func makeParameters(
        policy: SDRInputInterpretationPolicy,
        untaggedFallback: SDRUntaggedFallbackPolicy,
        bt1886Parameters: BT1886TransferParameters,
        colorScience: HDRColorScienceSemanticDefinition,
        toneMapping: HDRToneMappingSemanticDefinition
    ) -> CalibrationParameters {
        CalibrationParameters(
            paperWhiteNits: paperWhiteNits,
            peakNits: peakNits,
            highlightStrength: highlightStrength,
            contrastStrength: contrastStrength,
            saturationCompensation: saturationCompensation,
            shadowProtection: shadowProtection,
            temporalStability: temporalStability,
            displayHeadroom: peakNits / paperWhiteNits,
            toneCurveRevision: toneCurveRevision,
            sdrInterpretationPolicy: policy,
            untaggedSDRFallback: untaggedFallback,
            bt1886Parameters: bt1886Parameters,
            colorScience: colorScience,
            toneMapping: toneMapping
        )
    }
}

public struct V4BaselineEvaluationSemanticDefinition: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-v4-baseline-evaluation-definition-v1"

    public let semanticVersion: String
    public let defaultPreset: V4CalibrationParameterPreset
    public let calibratedV1Preset: V4CalibrationParameterPreset
    public let calibratedV2Preset: V4CalibrationParameterPreset
    public let absoluteV3Preset: V4CalibrationParameterPreset
    public let relativeV4Preset: V4CalibrationParameterPreset

    public init(
        semanticVersion: String = Self.semanticVersion,
        defaultPreset: V4CalibrationParameterPreset,
        calibratedV1Preset: V4CalibrationParameterPreset,
        calibratedV2Preset: V4CalibrationParameterPreset,
        absoluteV3Preset: V4CalibrationParameterPreset,
        relativeV4Preset: V4CalibrationParameterPreset
    ) {
        self.semanticVersion = semanticVersion
        self.defaultPreset = defaultPreset
        self.calibratedV1Preset = calibratedV1Preset
        self.calibratedV2Preset = calibratedV2Preset
        self.absoluteV3Preset = absoluteV3Preset
        self.relativeV4Preset = relativeV4Preset
    }

    public static let current = V4BaselineEvaluationSemanticDefinition(
        defaultPreset: V4CalibrationParameterPreset(
            identifier: "default", source: .hdr, toneCurveRevision: .legacyV2
        ),
        calibratedV1Preset: V4CalibrationParameterPreset(
            identifier: "calibratedV1", source: .calibratedV1, toneCurveRevision: .legacyV2
        ),
        calibratedV2Preset: V4CalibrationParameterPreset(
            identifier: "calibratedV2", source: .calibratedV2, toneCurveRevision: .legacyV2
        ),
        absoluteV3Preset: V4CalibrationParameterPreset(
            identifier: "v3Absolute", source: .calibratedV3Candidate, toneCurveRevision: .shadowProtectedV3
        ),
        relativeV4Preset: V4CalibrationParameterPreset(
            identifier: "v4RelativeCenter", source: .calibratedV2, toneCurveRevision: .sceneRelativeV4
        )
    )

    public var presets: [V4CalibrationParameterPreset] {
        [defaultPreset, calibratedV1Preset, calibratedV2Preset, absoluteV3Preset, relativeV4Preset]
    }

    public func validate() throws {
        guard semanticVersion == Self.semanticVersion,
              presets.allSatisfy(\.isValid),
              Set(presets.map(\.identifier)).count == presets.count else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }
}

/// The holdout boundary is an experiment semantic, not merely a preflight
/// label.  Keep the consumed IDs and byte identities in the same immutable
/// value that is carried by the preregistered runner.
public struct V4HoldoutSemanticDefinition: Codable, Hashable, Sendable {
    public let semanticVersion: String
    public let attempt1State: String
    public let objectivePixelsRead: Bool
    public let objectiveMetricsObserved: Bool
    public let procedurallyConsumed: Bool
    public let retryPermitted: Bool
    public let consumedPairIDs: [String]
    public let consumedAssetPairs: [String: V6InputHashes]

    public init(
        semanticVersion: String,
        attempt1State: String,
        objectivePixelsRead: Bool,
        objectiveMetricsObserved: Bool,
        procedurallyConsumed: Bool,
        retryPermitted: Bool,
        consumedPairIDs: [String],
        consumedAssetPairs: [String: V6InputHashes]
    ) {
        self.semanticVersion = semanticVersion
        self.attempt1State = attempt1State
        self.objectivePixelsRead = objectivePixelsRead
        self.objectiveMetricsObserved = objectiveMetricsObserved
        self.procedurallyConsumed = procedurallyConsumed
        self.retryPermitted = retryPermitted
        self.consumedPairIDs = consumedPairIDs.sorted()
        self.consumedAssetPairs = consumedAssetPairs
    }

    public var consumedSet: Set<String> { Set(consumedPairIDs) }

    public var isValid: Bool {
        !semanticVersion.isEmpty && !attempt1State.isEmpty &&
            procedurallyConsumed && !retryPermitted &&
            !consumedPairIDs.isEmpty &&
            Set(consumedPairIDs).count == consumedPairIDs.count &&
            Set(consumedAssetPairs.keys) == consumedSet &&
            consumedAssetPairs.values.allSatisfy {
                $0.sdrSHA256.count == 64 && $0.hdrSHA256.count == 64 &&
                    $0.sdrSHA256.unicodeScalars.allSatisfy(Self.isHex) &&
                    $0.hdrSHA256.unicodeScalars.allSatisfy(Self.isHex)
            }
    }

    public func isExcluded(
        pairID: String,
        sdrSHA256: String? = nil,
        hdrSHA256: String? = nil
    ) -> Bool {
        if consumedSet.contains(pairID) { return true }
        let sdr = sdrSHA256?.lowercased()
        let hdr = hdrSHA256?.lowercased()
        return consumedAssetPairs.values.contains {
            (sdr != nil && sdr == $0.sdrSHA256) ||
                (hdr != nil && hdr == $0.hdrSHA256)
        }
    }

    private static func isHex(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102: return true
        default: return false
        }
    }
}

public struct V4RunnerSemanticConfiguration: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-runner-definition-v4"

    public let semanticVersion: String
    public let configurationVersion: String
    public let toneCurveRevision: UInt32
    public let toneMapping: HDRToneMappingSemanticDefinition
    public let outputMode: HDROutputMode
    public let inputFallbackPolicy: HDRInputFallbackPolicy
    public let temporalWindowPolicy: V4TemporalWindowPolicy
    public let holdoutDefinition: V4HoldoutSemanticDefinition
    public let baselineEvaluationDefinition: V4BaselineEvaluationSemanticDefinition
    public let requiredCoverage: [V4SplitCoverageRequirement]
    public let minimumVirginFrozenPairs: Int
    public let minimumDistinctVirginFrozenFamilies: Int
    public let requiredTunePairCount: Int
    public let requiredValidationPairCount: Int
    public let stableFamilyOrderingRule: V4StableOrderingRule
    public let unclassifiedFamilyKey: String

    public init(
        semanticVersion: String = V4RunnerSemanticConfiguration.semanticVersion,
        configurationVersion: String = "calibration-v4-preregistered-v4",
        toneCurveRevision: UInt32 = HDRToneCurveRevision.sceneRelativeV4.rawValue,
        toneMapping: HDRToneMappingSemanticDefinition = .calibrationV4,
        outputMode: HDROutputMode = .edr,
        inputFallbackPolicy: HDRInputFallbackPolicy = .bt709VideoRange,
        temporalWindowPolicy: V4TemporalWindowPolicy = .v5,
        holdoutDefinition: V4HoldoutSemanticDefinition = V6VirginHoldoutPolicy.semanticDefinition,
        baselineEvaluationDefinition: V4BaselineEvaluationSemanticDefinition = .current,
        requiredCoverage: [V4SplitCoverageRequirement] = [
            V4SplitCoverageRequirement(split: .tune, requiredTransfers: ["HLG", "PQ"], requiredFamilies: ["K-Choreo", "LIVE"]),
            V4SplitCoverageRequirement(split: .validation, requiredTransfers: ["HLG", "PQ"], requiredFamilies: ["K-Choreo", "LIVE"]),
            V4SplitCoverageRequirement(split: .frozen, requiredTransfers: ["HLG", "PQ"], requiredFamilies: [])
        ],
        minimumVirginFrozenPairs: Int = V4FrozenCoveragePolicy.v5.minimumVirginFrozenPairs,
        minimumDistinctVirginFrozenFamilies: Int = V4FrozenCoveragePolicy.v5.minimumDistinctVirginFrozenFamilies,
        requiredTunePairCount: Int = 5,
        requiredValidationPairCount: Int = 3,
        stableFamilyOrderingRule: V4StableOrderingRule = .canonicalUTF8AscendingBeforeFloatingPointReduction,
        unclassifiedFamilyKey: String = "UNCLASSIFIED"
    ) {
        self.semanticVersion = semanticVersion
        self.configurationVersion = configurationVersion
        self.toneCurveRevision = toneCurveRevision
        self.toneMapping = toneMapping
        self.outputMode = outputMode
        self.inputFallbackPolicy = inputFallbackPolicy
        self.temporalWindowPolicy = temporalWindowPolicy
        self.holdoutDefinition = holdoutDefinition
        self.baselineEvaluationDefinition = baselineEvaluationDefinition
        let canonicalSplitOrder: [DatasetSplit] = [.tune, .validation, .frozen]
        self.requiredCoverage = requiredCoverage.sorted {
            (canonicalSplitOrder.firstIndex(of: $0.split) ?? Int.max) <
                (canonicalSplitOrder.firstIndex(of: $1.split) ?? Int.max)
        }
        self.minimumVirginFrozenPairs = minimumVirginFrozenPairs
        self.minimumDistinctVirginFrozenFamilies = minimumDistinctVirginFrozenFamilies
        self.requiredTunePairCount = requiredTunePairCount
        self.requiredValidationPairCount = requiredValidationPairCount
        self.stableFamilyOrderingRule = stableFamilyOrderingRule
        self.unclassifiedFamilyKey = unclassifiedFamilyKey
    }

    public static let current = V4RunnerSemanticConfiguration()

    public var outputModeValue: HDROutputMode? { outputMode }
    public var inputFallbackPolicyValue: HDRInputFallbackPolicy? { inputFallbackPolicy }

    public func canonicalSHA256() throws -> String {
        try baselineEvaluationDefinition.validate()
        let requiredSplits: Set<DatasetSplit> = [.tune, .validation, .frozen]
        let coverageSplits = requiredCoverage.map(\.split)
        guard outputModeValue != nil, inputFallbackPolicyValue != nil,
              !semanticVersion.isEmpty, !configurationVersion.isEmpty,
              minimumVirginFrozenPairs > 0,
              minimumDistinctVirginFrozenFamilies > 0,
              requiredTunePairCount > 0,
              requiredValidationPairCount > 0,
              !unclassifiedFamilyKey.isEmpty,
              requiredCoverage.count == requiredSplits.count,
              Set(coverageSplits) == requiredSplits,
              Set(coverageSplits).count == coverageSplits.count,
              requiredCoverage.allSatisfy({ requirement in
                  !requirement.requiredTransfers.isEmpty &&
                      requirement.requiredTransfers == Array(Set(requirement.requiredTransfers)).sorted(by: V4CanonicalOrdering.stringLess) &&
                      requirement.requiredFamilies == Array(Set(requirement.requiredFamilies)).sorted(by: V4CanonicalOrdering.stringLess)
              }),
              toneMapping.isValid,
              holdoutDefinition.isValid,
              temporalWindowPolicy.targetFrameCount > 0,
              temporalWindowPolicy.minimumRequiredFrameCount > 0,
              temporalWindowPolicy.minimumRequiredFrameCount <= temporalWindowPolicy.targetFrameCount,
              temporalWindowPolicy.warmupFrameCount >= 0,
              temporalWindowPolicy.warmupFrameCount < temporalWindowPolicy.targetFrameCount,
              temporalWindowPolicy.weightingPolicy == .equalSceneWindowWeightFramesWithinWindowOnly else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        return try HDRCanonicalIdentity.sha256(self)
    }
}

public struct SDRPolicyDefinitionV4: Codable, Hashable, Sendable {
    public let semanticVersion: String
    public let definition: SDRPolicyDefinition

    public init(definition: SDRPolicyDefinition = .currentV3) {
        self.semanticVersion = "sdr-policy-definition-v4"
        self.definition = SDRPolicyDefinition(
            policyVersion: definition.policyVersion,
            candidateList: definition.candidateList,
            bt1886Parameters: definition.bt1886Parameters,
            untaggedFallback: definition.untaggedFallback,
            semanticVersion: semanticVersion,
            bt709SourceLinearSemanticVersion: "bt709-source-linear-v4",
            bt1886ReferenceDisplaySemanticVersion: "bt1886-reference-display-v4",
            sRGBSemanticVersion: "srgb-source-v4",
            explicitGammaSemanticVersion: "explicit-gamma-v4",
            linearSemanticVersion: "linear-source-v4",
            bt1886ParameterValidationDomain: definition.bt1886ParameterValidationDomain,
            sRGBBehavior: definition.sRGBBehavior,
            explicitGammaBehavior: definition.explicitGammaBehavior,
            linearBehavior: definition.linearBehavior,
            untaggedFallbackSemantics: definition.untaggedFallbackSemantics
        )
    }

    public static let current = SDRPolicyDefinitionV4()

    public func canonicalSHA256() throws -> String {
        guard !definition.definitionCandidateListIsEmpty else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        return try HDRCanonicalIdentity.sha256(self)
    }
}

private extension SDRPolicyDefinition {
    var definitionCandidateListIsEmpty: Bool { candidateList.isEmpty }
}

public struct SDRPreparationDefinitionV4: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-preparation-definition-v4"
    public let semanticVersion: String
    public let configuration: V6PreparationSemanticConfiguration
    public let policyCandidates: [SDRInputInterpretationPolicy]
    public let failureAction: V4FailureAction

    public init(
        configuration: V6PreparationSemanticConfiguration = .v6,
        policyCandidates: [SDRInputInterpretationPolicy] = [.bt709SourceLinear, .bt1886ReferenceDisplay],
        failureAction: V4FailureAction = .abort
    ) {
        self.semanticVersion = Self.semanticVersion
        self.configuration = configuration
        self.policyCandidates = policyCandidates
        self.failureAction = failureAction
    }

    public static let current = SDRPreparationDefinitionV4()

    public func validate() throws {
        guard Set(policyCandidates) == Set([.bt709SourceLinear, .bt1886ReferenceDisplay]),
              policyCandidates.count == 2,
              failureAction == .abort,
              configuration.validationFailure() == nil else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }
}

public struct SDRMetricDefinitionV4: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-metric-definition-v4"
    public let semanticVersion: String
    public let configuration: V2MetricSemanticConfiguration

    public init(configuration: V2MetricSemanticConfiguration = .current) {
        self.semanticVersion = Self.semanticVersion
        self.configuration = configuration
    }

    public static let current = SDRMetricDefinitionV4()

    public func validate() throws {
        try configuration.validate()
        guard configuration.colorScience.isValid else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }
}

public struct SDRCalibrationSearchDefinitionV4: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-search-definition-v4"

    public let semanticVersion: String
    public let policyDefinitionHashV4: String
    public let preparationDefinitionHashV4: String
    public let metricDefinitionHashV4: String
    public let colorScienceDefinitionHash: String
    public let gateDefinition: V4GateDefinition
    public let gateDefinitionHash: String
    public let searchAlgorithmDefinition: SDRSearchAlgorithmDefinitionV4
    public let searchAlgorithmDefinitionHashV4: String
    public let runnerDefinition: V4RunnerSemanticConfiguration
    public let runnerDefinitionHash: String
    public let policyCandidates: [SDRInputInterpretationPolicy]
    public let searchBudgetPerPolicy: Int
    public let seed: UInt64
    public let splitSeed: UInt64
    public let parameterBounds: V2ParameterBounds
    public let safetyThresholds: V4SafetyThresholds
    public let shortlistSize: Int

    public init(
        policyDefinitionHashV4: String,
        preparationDefinitionHashV4: String,
        metricDefinitionHashV4: String,
        colorScienceDefinitionHash: String,
        gateDefinition: V4GateDefinition = .current,
        searchAlgorithmDefinition: SDRSearchAlgorithmDefinitionV4 = .current,
        runnerDefinition: V4RunnerSemanticConfiguration = .current,
        policyCandidates: [SDRInputInterpretationPolicy] = [.bt709SourceLinear, .bt1886ReferenceDisplay],
        searchBudgetPerPolicy: Int = 192,
        seed: UInt64 = 2_026_09_12,
        splitSeed: UInt64 = 92,
        parameterBounds: V2ParameterBounds = .preregistered,
        safetyThresholds: V4SafetyThresholds = V4SafetyThresholds(),
        shortlistSize: Int = 3
    ) throws {
        try searchAlgorithmDefinition.validate()
        self.semanticVersion = Self.semanticVersion
        self.policyDefinitionHashV4 = policyDefinitionHashV4
        self.preparationDefinitionHashV4 = preparationDefinitionHashV4
        self.metricDefinitionHashV4 = metricDefinitionHashV4
        self.colorScienceDefinitionHash = colorScienceDefinitionHash
        self.gateDefinition = gateDefinition
        self.gateDefinitionHash = try gateDefinition.canonicalSHA256()
        self.searchAlgorithmDefinition = searchAlgorithmDefinition
        self.searchAlgorithmDefinitionHashV4 = try searchAlgorithmDefinition.canonicalSHA256()
        self.runnerDefinition = runnerDefinition
        self.runnerDefinitionHash = try runnerDefinition.canonicalSHA256()
        self.policyCandidates = policyCandidates
        self.searchBudgetPerPolicy = searchBudgetPerPolicy
        self.seed = seed
        self.splitSeed = splitSeed
        self.parameterBounds = parameterBounds
        self.safetyThresholds = safetyThresholds
        self.shortlistSize = shortlistSize
    }

    public func validate() throws {
        try searchAlgorithmDefinition.validate()
        try gateDefinition.validate()
        _ = try runnerDefinition.canonicalSHA256()
        guard Set(policyCandidates) == Set([.bt709SourceLinear, .bt1886ReferenceDisplay]),
              policyCandidates.count == 2,
              searchBudgetPerPolicy == searchAlgorithmDefinition.totalCandidatesPerPolicy,
              searchBudgetPerPolicy == searchAlgorithmDefinition.globalCandidateCount + searchAlgorithmDefinition.localCandidateCount,
              searchBudgetPerPolicy > 0,
              shortlistSize > 0 && shortlistSize <= searchBudgetPerPolicy,
              parameterBounds.isValid,
              safetyThresholds.isValid,
              gateDefinitionHash == (try gateDefinition.canonicalSHA256()),
              searchAlgorithmDefinitionHashV4 == (try searchAlgorithmDefinition.canonicalSHA256()),
              runnerDefinitionHash == (try runnerDefinition.canonicalSHA256()),
              !policyDefinitionHashV4.isEmpty,
              !preparationDefinitionHashV4.isEmpty,
              !metricDefinitionHashV4.isEmpty,
              !colorScienceDefinitionHash.isEmpty else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }
}

public struct SDRCalibrationSemanticSealV4: Codable, Hashable, Sendable {
    public let policyDefinition: SDRPolicyDefinitionV4
    public let preparationDefinition: SDRPreparationDefinitionV4
    public let metricDefinition: SDRMetricDefinitionV4
    public let gateDefinition: V4GateDefinition
    public let searchDefinition: SDRCalibrationSearchDefinitionV4
    public let colorScienceDefinitionHash: String
    public let policyDefinitionHashV4: String
    public let preparationDefinitionHashV4: String
    public let metricDefinitionHashV4: String
    public let gateDefinitionHash: String
    public let searchAlgorithmDefinitionHashV4: String
    public let runnerDefinitionHash: String
    public let searchDefinitionHashV4: String

    public init(
        policyDefinition: SDRPolicyDefinitionV4,
        preparationDefinition: SDRPreparationDefinitionV4,
        metricDefinition: SDRMetricDefinitionV4,
        gateDefinition: V4GateDefinition,
        searchDefinition: SDRCalibrationSearchDefinitionV4
    ) throws {
        try preparationDefinition.validate()
        try metricDefinition.validate()
        let policyHash = try policyDefinition.canonicalSHA256()
        let preparationHash = try preparationDefinition.canonicalSHA256()
        let metricHash = try metricDefinition.canonicalSHA256()
        let colorHash = try metricDefinition.configuration.colorScience.canonicalSHA256()
        let gateHash = try gateDefinition.canonicalSHA256()
        let algorithmHash = try searchDefinition.searchAlgorithmDefinition.canonicalSHA256()
        let runnerHash = try searchDefinition.runnerDefinition.canonicalSHA256()
        try searchDefinition.validate()
        guard preparationDefinition.configuration.colorScience == metricDefinition.configuration.colorScience,
              searchDefinition.policyDefinitionHashV4 == policyHash,
              searchDefinition.preparationDefinitionHashV4 == preparationHash,
              searchDefinition.metricDefinitionHashV4 == metricHash,
              searchDefinition.colorScienceDefinitionHash == colorHash,
              searchDefinition.gateDefinitionHash == gateHash,
              searchDefinition.searchAlgorithmDefinitionHashV4 == algorithmHash,
              searchDefinition.runnerDefinitionHash == runnerHash else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        self.policyDefinition = policyDefinition
        self.preparationDefinition = preparationDefinition
        self.metricDefinition = metricDefinition
        self.gateDefinition = gateDefinition
        self.searchDefinition = searchDefinition
        self.colorScienceDefinitionHash = colorHash
        self.policyDefinitionHashV4 = policyHash
        self.preparationDefinitionHashV4 = preparationHash
        self.metricDefinitionHashV4 = metricHash
        self.gateDefinitionHash = gateHash
        self.searchAlgorithmDefinitionHashV4 = algorithmHash
        self.runnerDefinitionHash = runnerHash
        self.searchDefinitionHashV4 = try searchDefinition.canonicalSHA256()
    }

    public static func current() throws -> SDRCalibrationSemanticSealV4 {
        let policy = SDRPolicyDefinitionV4.current
        let preparation = SDRPreparationDefinitionV4.current
        let metric = SDRMetricDefinitionV4.current
        let gate = V4GateDefinition.current
        let policyHash = try policy.canonicalSHA256()
        let preparationHash = try preparation.canonicalSHA256()
        let metricHash = try metric.canonicalSHA256()
        let colorHash = try metric.configuration.colorScience.canonicalSHA256()
        return try SDRCalibrationSemanticSealV4(
            policyDefinition: policy,
            preparationDefinition: preparation,
            metricDefinition: metric,
            gateDefinition: gate,
            searchDefinition: try SDRCalibrationSearchDefinitionV4(
                policyDefinitionHashV4: policyHash,
                preparationDefinitionHashV4: preparationHash,
                metricDefinitionHashV4: metricHash,
                colorScienceDefinitionHash: colorHash,
                gateDefinition: gate
            )
        )
    }
}

public struct PreregisteredCalibrationExperimentV4: Codable, Hashable, Sendable {
    public static let artifactVersion = 4
    /// V4 is retained only as a reproducible historical audit artifact.  It
    /// is never an executable/current preregistration again.
    public static let currentStatus = "AUDIT_INVALIDATED"

    public let artifactVersion: Int
    public let status: String
    public let preregistrationInvalidated: Bool
    public let correctnessBaseline: String
    public let seal: SDRCalibrationSemanticSealV4
    public let policyDefinitionHashV4: String
    public let preparationDefinitionHashV4: String
    public let metricDefinitionHashV4: String
    public let colorScienceDefinitionHash: String
    public let gateDefinitionHash: String
    public let searchAlgorithmDefinitionHashV4: String
    public let runnerDefinitionHash: String
    public let searchDefinitionHashV4: String
    public let retiredV1SearchDefinitionHash: String
    public let invalidatedV2SearchDefinitionHash: String
    public let invalidatedV3SearchDefinitionHash: String
    public let corpusDefinitionHash: String
    public let experimentBindingHash: String
    public let mediaQualification: String
    public let tune: String
    public let validation: String
    public let objectiveEvaluations: Int

    public init(
        seal: SDRCalibrationSemanticSealV4,
        correctnessBaseline: String = "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9",
        retiredV1SearchDefinitionHash: String = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608",
        invalidatedV2SearchDefinitionHash: String = "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41",
        invalidatedV3SearchDefinitionHash: String = "7a2fcf82bb40b45f774d942dac62a57d5c75b7cba16b5415a295ed8a68db8889"
    ) {
        self.artifactVersion = Self.artifactVersion
        self.status = Self.currentStatus
        self.preregistrationInvalidated = true
        self.correctnessBaseline = correctnessBaseline
        self.seal = seal
        self.policyDefinitionHashV4 = seal.policyDefinitionHashV4
        self.preparationDefinitionHashV4 = seal.preparationDefinitionHashV4
        self.metricDefinitionHashV4 = seal.metricDefinitionHashV4
        self.colorScienceDefinitionHash = seal.colorScienceDefinitionHash
        self.gateDefinitionHash = seal.gateDefinitionHash
        self.searchAlgorithmDefinitionHashV4 = seal.searchAlgorithmDefinitionHashV4
        self.runnerDefinitionHash = seal.runnerDefinitionHash
        self.searchDefinitionHashV4 = seal.searchDefinitionHashV4
        self.retiredV1SearchDefinitionHash = retiredV1SearchDefinitionHash
        self.invalidatedV2SearchDefinitionHash = invalidatedV2SearchDefinitionHash
        self.invalidatedV3SearchDefinitionHash = invalidatedV3SearchDefinitionHash
        self.corpusDefinitionHash = "NOT_YET_CREATED"
        self.experimentBindingHash = "NOT_YET_CREATED"
        self.mediaQualification = "NOT_RUN"
        self.tune = "NOT_RUN"
        self.validation = "NOT_RUN"
        self.objectiveEvaluations = 0
    }

    public static func current() throws -> PreregisteredCalibrationExperimentV4 {
        try PreregisteredCalibrationExperimentV4(seal: SDRCalibrationSemanticSealV4.current())
    }

    public func validate() throws {
        guard artifactVersion == Self.artifactVersion,
              status == Self.currentStatus,
              preregistrationInvalidated,
              correctnessBaseline == "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9",
              retiredV1SearchDefinitionHash == "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608",
              invalidatedV2SearchDefinitionHash == "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41",
              invalidatedV3SearchDefinitionHash == "7a2fcf82bb40b45f774d942dac62a57d5c75b7cba16b5415a295ed8a68db8889",
              corpusDefinitionHash == "NOT_YET_CREATED",
              experimentBindingHash == "NOT_YET_CREATED",
              mediaQualification == "NOT_RUN", tune == "NOT_RUN", validation == "NOT_RUN",
              objectiveEvaluations == 0 else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        guard policyDefinitionHashV4 == seal.policyDefinitionHashV4,
              preparationDefinitionHashV4 == seal.preparationDefinitionHashV4,
              metricDefinitionHashV4 == seal.metricDefinitionHashV4,
              colorScienceDefinitionHash == seal.colorScienceDefinitionHash,
              gateDefinitionHash == seal.gateDefinitionHash,
              searchAlgorithmDefinitionHashV4 == seal.searchAlgorithmDefinitionHashV4,
              runnerDefinitionHash == seal.runnerDefinitionHash,
              searchDefinitionHashV4 == seal.searchDefinitionHashV4 else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        do {
            guard try seal.searchDefinition.canonicalSHA256() == searchDefinitionHashV4 else {
                throw HDRCanonicalIdentityError.encodingFailed
            }
        } catch {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    /// Stronger authoring/CI check. Runtime loading validates the sealed
    /// artifact and derives its runner from that artifact; regeneration and
    /// this method prove that the artifact was produced by the current V4
    /// semantic definitions without making the async execution path encode a
    /// second copy of the large preparation object.
    public func validateAgainstCurrentSemantics() throws {
        try validate()
        let current = try Self.current()
        guard seal == current.seal else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }
    /// Human-readable V4 documentation is rendered from the exact typed seal
    /// object. It intentionally embeds the canonical definitions instead of
    /// maintaining a second hand-written table of experiment constants.
    public func humanReadableDocumentation() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .throw
        let sealJSON = String(decoding: try encoder.encode(seal), as: UTF8.self)
        return """
        # PR #13 — V4 execution-bound preregistration

        This document is generated from `PreregisteredCalibrationExperimentV4` and its typed semantic objects. It is a semantic-only rebase artifact; no corpus has been qualified and no objective evaluation has been performed.

        - artifact version: \(artifactVersion)
        - status: `\(status)`
        - correctness baseline: `\(correctnessBaseline)`
        - V1 status: `RETIRED_INVALIDATED` (`\(retiredV1SearchDefinitionHash)`)
        - V2 status: `AUDIT_INVALIDATED` (`\(invalidatedV2SearchDefinitionHash)`)
        - V3 status: `AUDIT_INVALIDATED` (`\(invalidatedV3SearchDefinitionHash)`)
        - media qualification: `\(mediaQualification)`
        - Tune: `\(tune)`
        - Validation: `\(validation)`
        - objective evaluations: \(objectiveEvaluations)
        - corpus identity: `\(corpusDefinitionHash)`
        - experiment binding: `\(experimentBindingHash)`

        ## Canonical typed seal

        ```json
        \(sealJSON)
        ```
        """
    }

    public func writeHumanReadableDocumentation(to url: URL) throws {
        let text = try humanReadableDocumentation()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// Canonical semantics of the final object handed to the production runner.
/// It intentionally includes the adapted values, not only the definitions
/// from which they were derived, so an adapter cannot add an unsealed default.
public struct V4FinalRunnerSemanticConfiguration: Codable, Hashable, Sendable {
    public let experimentSearchDefinitionHashV4: String
    public let policy: SDRInputInterpretationPolicy
    public let preparation: V6PreparationSemanticConfiguration
    public let metric: V2MetricSemanticConfiguration
    public let colorScience: HDRColorScienceSemanticDefinition
    public let toneMapping: HDRToneMappingSemanticDefinition
    public let gateDefinition: V4GateDefinition
    public let searchAlgorithmDefinition: SDRSearchAlgorithmDefinitionV4
    public let runnerDefinition: V4RunnerSemanticConfiguration
    public let searchSeed: UInt64
    public let splitSeed: UInt64
    public let globalCandidates: Int
    public let localCandidates: Int
    public let totalCandidatesPerPolicy: Int
    public let shortlistSize: Int
    public let parameterBounds: V2ParameterBounds
    public let safetyThresholds: V4SafetyThresholds

    public init(
        experimentSearchDefinitionHashV4: String,
        policy: SDRInputInterpretationPolicy,
        preparation: V6PreparationSemanticConfiguration,
        metric: V2MetricSemanticConfiguration,
        colorScience: HDRColorScienceSemanticDefinition,
        toneMapping: HDRToneMappingSemanticDefinition,
        gateDefinition: V4GateDefinition,
        searchAlgorithmDefinition: SDRSearchAlgorithmDefinitionV4,
        runnerDefinition: V4RunnerSemanticConfiguration,
        searchSeed: UInt64,
        splitSeed: UInt64,
        globalCandidates: Int,
        localCandidates: Int,
        totalCandidatesPerPolicy: Int,
        shortlistSize: Int,
        parameterBounds: V2ParameterBounds,
        safetyThresholds: V4SafetyThresholds
    ) {
        self.experimentSearchDefinitionHashV4 = experimentSearchDefinitionHashV4
        self.policy = policy
        self.preparation = preparation
        self.metric = metric
        self.colorScience = colorScience
        self.toneMapping = toneMapping
        self.gateDefinition = gateDefinition
        self.searchAlgorithmDefinition = searchAlgorithmDefinition
        self.runnerDefinition = runnerDefinition
        self.searchSeed = searchSeed
        self.splitSeed = splitSeed
        self.globalCandidates = globalCandidates
        self.localCandidates = localCandidates
        self.totalCandidatesPerPolicy = totalCandidatesPerPolicy
        self.shortlistSize = shortlistSize
        self.parameterBounds = parameterBounds
        self.safetyThresholds = safetyThresholds
    }

    public func canonicalSHA256() throws -> String {
        try metric.validate()
        guard !experimentSearchDefinitionHashV4.isEmpty,
              preparation.validationFailure() == nil,
              metric.colorScience == colorScience,
              colorScience.isValid,
              toneMapping.isValid,
              policy == preparation.sdrInterpretationPolicy,
              runnerDefinition.toneMapping == toneMapping,
              runnerDefinition.requiredTunePairCount > 0,
              runnerDefinition.requiredValidationPairCount == shortlistSize,
              totalCandidatesPerPolicy == globalCandidates + localCandidates,
              totalCandidatesPerPolicy == searchAlgorithmDefinition.totalCandidatesPerPolicy,
              shortlistSize > 0,
              shortlistSize <= totalCandidatesPerPolicy,
              parameterBounds.isValid else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        try gateDefinition.validate()
        try searchAlgorithmDefinition.validate()
        _ = try runnerDefinition.canonicalSHA256()
        return try HDRCanonicalIdentity.sha256(self)
    }
}

public struct V4PreregisteredCalibrationRuntimeConfiguration: Codable, Hashable, Sendable {
    public let experimentSearchDefinitionHashV4: String
    public let policy: SDRInputInterpretationPolicy
    public let preparation: V6PreparationSemanticConfiguration
    public let metric: V2MetricSemanticConfiguration
    public let colorScience: HDRColorScienceSemanticDefinition
    public let toneMapping: HDRToneMappingSemanticDefinition
    public let gateDefinition: V4GateDefinition
    public let searchAlgorithmDefinition: SDRSearchAlgorithmDefinitionV4
    public let runnerDefinition: V4RunnerSemanticConfiguration
    public let searchSeed: UInt64
    public let splitSeed: UInt64
    public let globalCandidates: Int
    public let localCandidates: Int
    public let totalCandidatesPerPolicy: Int
    public let shortlistSize: Int
    public let parameterBounds: V2ParameterBounds
    public let safetyThresholds: V4SafetyThresholds
    public let semanticIdentity: String

    public init(
        experiment: PreregisteredCalibrationExperimentV4,
        policy: SDRInputInterpretationPolicy
    ) throws {
        try experiment.validate()
        throw PreregisteredCalibrationExecutionError.historicalPreregistrationInvalidated
    }

    /// V5 migration boundary. It reuses the typed V4 semantic seal and the
    /// production adapter without making the invalidated V4 artifact
    /// executable.
    public init(
        seal: SDRCalibrationSemanticSealV4,
        experimentSearchDefinitionHashV4: String,
        policy: SDRInputInterpretationPolicy
    ) throws {
        guard seal.searchDefinition.policyCandidates.contains(policy) else {
            throw PreregisteredCalibrationExecutionError.policyNotPreregistered
        }
        let search = seal.searchDefinition
        self.experimentSearchDefinitionHashV4 = experimentSearchDefinitionHashV4
        self.policy = policy
        self.preparation = seal.preparationDefinition.configuration.forInterpretationPolicy(policy)
        self.metric = seal.metricDefinition.configuration
        self.colorScience = seal.metricDefinition.configuration.colorScience
        self.toneMapping = seal.searchDefinition.runnerDefinition.toneMapping
        self.gateDefinition = seal.gateDefinition
        self.searchAlgorithmDefinition = search.searchAlgorithmDefinition
        self.runnerDefinition = search.runnerDefinition
        self.searchSeed = search.seed
        self.splitSeed = search.splitSeed
        self.globalCandidates = search.searchAlgorithmDefinition.globalCandidateCount
        self.localCandidates = search.searchAlgorithmDefinition.localCandidateCount
        self.totalCandidatesPerPolicy = search.searchBudgetPerPolicy
        self.shortlistSize = search.shortlistSize
        self.parameterBounds = search.parameterBounds
        self.safetyThresholds = search.safetyThresholds
        self.semanticIdentity = try Self.identity(
            experimentSearchDefinitionHashV4: experimentSearchDefinitionHashV4,
            policy: policy,
            preparation: preparation,
            metric: metric,
            colorScience: colorScience,
            toneMapping: toneMapping,
            gateDefinition: gateDefinition,
            searchAlgorithmDefinition: searchAlgorithmDefinition,
            runnerDefinition: runnerDefinition,
            searchSeed: search.seed,
            splitSeed: search.splitSeed,
            globalCandidates: globalCandidates,
            localCandidates: localCandidates,
            totalCandidatesPerPolicy: totalCandidatesPerPolicy,
            shortlistSize: shortlistSize,
            parameterBounds: parameterBounds,
            safetyThresholds: safetyThresholds
        )
    }

    private static func identity(
        experimentSearchDefinitionHashV4: String,
        policy: SDRInputInterpretationPolicy,
        preparation: V6PreparationSemanticConfiguration,
        metric: V2MetricSemanticConfiguration,
        colorScience: HDRColorScienceSemanticDefinition,
        toneMapping: HDRToneMappingSemanticDefinition,
        gateDefinition: V4GateDefinition,
        searchAlgorithmDefinition: SDRSearchAlgorithmDefinitionV4,
        runnerDefinition: V4RunnerSemanticConfiguration,
        searchSeed: UInt64,
        splitSeed: UInt64,
        globalCandidates: Int,
        localCandidates: Int,
        totalCandidatesPerPolicy: Int,
        shortlistSize: Int,
        parameterBounds: V2ParameterBounds,
        safetyThresholds: V4SafetyThresholds
    ) throws -> String {
        return try V4FinalRunnerSemanticConfiguration(
            experimentSearchDefinitionHashV4: experimentSearchDefinitionHashV4,
            policy: policy,
            preparation: preparation,
            metric: metric,
            colorScience: colorScience,
            toneMapping: toneMapping,
            gateDefinition: gateDefinition,
            searchAlgorithmDefinition: searchAlgorithmDefinition,
            runnerDefinition: runnerDefinition,
            searchSeed: searchSeed,
            splitSeed: splitSeed,
            globalCandidates: globalCandidates,
            localCandidates: localCandidates,
            totalCandidatesPerPolicy: totalCandidatesPerPolicy,
            shortlistSize: shortlistSize,
            parameterBounds: parameterBounds,
            safetyThresholds: safetyThresholds
        ).canonicalSHA256()
    }
}

public final class PreregisteredCalibrationRunnerV4 {
    public let experiment: PreregisteredCalibrationExperimentV4

    public init(experiment: PreregisteredCalibrationExperimentV4) throws {
        try experiment.validate()
        throw PreregisteredCalibrationExecutionError.historicalPreregistrationInvalidated
    }

    public func verifyOnly() throws -> [V4PreregisteredCalibrationRuntimeConfiguration] {
        let runtimes = try experiment.seal.searchDefinition.policyCandidates.map {
            try V4PreregisteredCalibrationRuntimeConfiguration(experiment: experiment, policy: $0)
        }
        let search = experiment.seal.searchDefinition
        guard runtimes.count == search.policyCandidates.count,
              runtimes.map(\.policy) == [.bt709SourceLinear, .bt1886ReferenceDisplay],
              runtimes.allSatisfy({
                  $0.totalCandidatesPerPolicy == search.searchBudgetPerPolicy &&
                      $0.shortlistSize == search.shortlistSize
              }) else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        for runtime in runtimes {
            let adapted = try V4CalibrationConfiguration(preregisteredRuntime: runtime)
            guard try adapted.validatedRunnerSemanticIdentity() == runtime.semanticIdentity else {
                throw PreregisteredCalibrationExecutionError.preregistrationMismatch
            }
        }
        return runtimes
    }

    /// Full execution remains an explicit later-phase API.  It cannot be
    /// reached without the V4 verification above and is not called by this
    /// rebase task.
    public func run(
        manifestURL: URL,
        outputDirectory: URL,
        preparedEvaluationPlanURLs: [SDRInputInterpretationPolicy: URL],
        preparedFrozenPlanURLs: [SDRInputInterpretationPolicy: URL]? = nil,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) async throws -> [V4FinalReport] {
        let runtimes = try verifyOnly()
        guard let device else { throw CalibrationError.decodeFailed("Metal device unavailable") }
        guard Set(preparedEvaluationPlanURLs.keys) == Set(runtimes.map(\.policy)) else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        var reports: [V4FinalReport] = []
        for runtime in runtimes {
            let configuration = try V4CalibrationConfiguration(preregisteredRuntime: runtime)
            let runner = try CalibrationV4Runner(
                manifestURL: manifestURL,
                outputDirectory: outputDirectory.appendingPathComponent(runtime.policy.rawValue),
                configuration: configuration,
                preparedEvaluationPlanURL: preparedEvaluationPlanURLs[runtime.policy],
                preparedFrozenPlanURL: preparedFrozenPlanURLs?[runtime.policy],
                preparationConfiguration: runtime.preparation,
                metricConfiguration: runtime.metric,
                device: device
            )
            reports.append(try await runner.run())
        }
        return reports
    }
}
