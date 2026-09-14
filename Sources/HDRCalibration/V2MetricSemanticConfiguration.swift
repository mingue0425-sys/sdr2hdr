import Foundation
import HDRCore

/// A named interval in the reference percentile domain.  Keeping the
/// boundaries as numbers, rather than prose, makes every region decision
/// part of the metric identity.
public struct V2MetricRegionDefinition: Codable, Hashable, Sendable {
    public let lowerPercentile: Double
    public let upperPercentile: Double

    public init(lowerPercentile: Double, upperPercentile: Double) {
        self.lowerPercentile = lowerPercentile
        self.upperPercentile = upperPercentile
    }
}

public enum V2MetricComparisonRule: String, Codable, Hashable, Sendable {
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual

    func accepts(_ value: Double, threshold: Double) -> Bool {
        switch self {
        case .lessThan: return value < threshold
        case .lessThanOrEqual: return value <= threshold
        case .greaterThan: return value > threshold
        case .greaterThanOrEqual: return value >= threshold
        }
    }
}

public enum V2TemporalHistoryResetRule: String, Codable, Hashable, Sendable {
    case beforeEachWindow
}

public enum V2TemporalSceneCutInputRule: String, Codable, Hashable, Sendable {
    case alwaysFalse
}

public enum V2MetricAggregationOrderingRule: String, Codable, Hashable, Sendable {
    case callerSuppliedCanonicalPairOrder = "caller-supplied-canonical-pair-order"
}

public enum V2MetricFrameOrderingRule: String, Codable, Hashable, Sendable {
    case generatedTimestampAscendingThenInputPositionAscending = "generated-timestamp-ascending-then-input-position-ascending"
}

public enum V2MetricTemporalWindowOrderingRule: String, Codable, Hashable, Sendable {
    case sceneIDUTF8AscendingThenStartSecondsThenOffsetSeconds = "scene-id-UTF8-ascending-then-start-seconds-ascending-then-offset-seconds-ascending"
}

/// Complete semantic input to the V2 objective evaluator.  This is the
/// single source of truth for thresholds, normalizers, regional boundaries,
/// category/failure gates, and objective weights.  The evaluator receives
/// this object directly; the preregistration seals its canonical encoding.
public struct V2MetricSemanticConfiguration: Codable, Hashable, Sendable {
    public static let semanticVersion = "v2-metric-semantics-v3"

    public let semanticVersion: String
    public let metricVersion: String
    public let objectiveWeights: V2ObjectiveWeights
    public let objectiveNames: [String]
    public let objectiveDirection: String
    public let normalizationRules: [String]
    public let aggregationRules: [String]
    public let signedSemantics: [String]
    public let regionalMetricNames: [String]
    public let temporalMetricNames: [String]
    public let failureHandling: [String]
    public let perceptualColorTransformVersion: String
    /// The evaluator and HDRCore use this exact value for ICtCp/PQ math.
    public let colorScience: HDRColorScienceSemanticDefinition
    /// The fixed reference/readback sampling grid used by the objective
    /// evaluator. It is semantic because changing it changes score inputs.
    public let referenceGridWidth: Int
    public let referenceGridHeight: Int
    public let perceptualColorInputMinimumNits: Double
    public let perceptualColorInputMaximumNits: Double
    public let percentileInterpolation: String
    public let nonFiniteHandling: String
    public let nonNegativeClampPolicy: String
    public let nonNegativeClampFloor: Double
    public let correlationLowerBound: Double
    public let correlationUpperBound: Double
    public let correlationMinimumSampleCount: Int
    public let correlationDenominatorComparison: V2MetricComparisonRule
    public let hueWrapRule: String
    public let hueNormalization: Double
    public let hueFullTurnMultiplier: Double
    public let stableAggregationOrder: V2MetricAggregationOrderingRule
    public let stableFrameOrderingRule: V2MetricFrameOrderingRule
    public let stableTemporalWindowOrderingRule: V2MetricTemporalWindowOrderingRule
    public let ratioIdentity: Double
    public let emptyPercentileValue: Double
    public let emptyFractionValue: Double
    public let emptyAverageValue: Double
    public let insufficientTemporalMetricValue: Double
    public let comparisonRules: [String: V2MetricComparisonRule]
    public let temporalMinimumFrameCount: Int
    public let temporalSecondDifferenceMinimumFrameCount: Int
    /// Temporal cut diagnostics are computed by the same evaluator used by
    /// the V4 runner.  These values are semantic even though they are not
    /// primary objective weights: changing them changes gate inputs and
    /// therefore candidate ordering or acceptance.
    public let temporalSettledSampleCount: Int
    public let temporalRecoveryRelativeTolerance: Double
    public let temporalRecoveryAbsoluteTolerance: Double
    /// Temporal evaluator state transitions are metric semantics: changing
    /// either rule changes the generated samples that enter temporal scores.
    public let temporalAutomaticEstimationEnabled: Bool
    public let temporalHistoryResetRule: V2TemporalHistoryResetRule
    public let temporalSceneCutInputRule: V2TemporalSceneCutInputRule

    public let absoluteNitsNormalizer: Double
    public let additiveLuminanceOffsetNits: Double
    public let percentileFractions: [String: Double]
    public let regionPercentiles: [String: V2MetricRegionDefinition]
    public let diffuseMidtoneSourceRange: V2MetricRegionDefinition

    public let highlightUnderreachRatio: Double
    public let highlightOvershootRatio: Double
    public let highlightOvershootAbsoluteNits: Double
    public let specularPercentile: Double
    public let clippingPeakRatio: Double
    public let slopeFloorNits: Double

    public let blackCrushReferenceThresholdNits: Double
    public let blackCrushGeneratedAbsoluteNits: Double
    public let blackCrushGeneratedRatio: Double
    public let shadowLiftRatio: Double
    public let shadowLiftAbsoluteNits: Double
    public let nearBlackReferenceRangeFloorNits: Double

    public let hueMeanWeight: Double
    public let hueP95Weight: Double
    public let temporalLuminanceWeight: Double
    public let temporalHighlightWeight: Double
    public let temporalFlickerWeight: Double

    public let minimumReferenceChroma: Double
    public let minimumGeneratedChroma: Double
    public let highChromaThreshold: Double
    public let saturationDenominatorFloor: Double
    public let saturationOvershootRatio: Double
    public let saturationOvershootAbsolute: Double
    public let saturationUndershootRatio: Double
    public let saturationUndershootAbsolute: Double
    public let skinMinimumPeakNits: Double
    public let skinRedBlueSeparation: Double

    public let categoryHighKeyThresholdNits: Double
    public let categoryLowKeyThresholdNits: Double
    public let categoryHighSaturationChromaThreshold: Double
    public let categoryHighSaturationRatio: Double
    public let categoryHighlightRichUnderreachRatio: Double

    public let failureHighlightUnderreachRatio: Double
    public let failureHighlightOvershootRatio: Double
    public let failureDiffuseWhiteLowRatio: Double
    public let failureDiffuseWhiteHighRatio: Double
    public let failureMidtoneError: Double
    public let failureBlackCrushRatio: Double
    public let failureShadowLiftRatio: Double
    public let failureSaturationRatio: Double
    public let failureHueP95Error: Double
    public let failureTemporalFlicker: Double
    public let failureAlignmentConfidence: Double
    public let failureReferenceMismatchHue: Double
    public let failureReferenceMismatchLuminance: Double

    public let correlationEpsilon: Double
    public let invalidMetricScore: Double
    public let emptyAggregateObjective: Double
    public let emptyAggregateInvalidSampleCount: Int

    public init(objectiveWeights: V2ObjectiveWeights? = nil) {
        self.semanticVersion = Self.semanticVersion
        self.metricVersion = "v2-objective-with-v61-directional-diagnostics"
        // V4's historical production evaluator gives the shadow and temporal
        // terms their explicit calibrated weights.  Keep those semantics in
        // this one object so the preregistered evaluator and legacy V4
        // compatibility path cannot silently use different numbers.
        var defaultWeights = V2ObjectiveWeights()
        defaultWeights.shadow = 0.15
        defaultWeights.temporal = 0.10
        self.objectiveWeights = objectiveWeights ?? defaultWeights
        self.objectiveNames = [
            "luminance", "absoluteNits", "midtone", "diffuseWhite", "highlight",
            "shadow", "chroma", "saturation", "hue", "temporal", "structure",
            "clippingPenalty", "blackCrushPenalty", "saturationPenalty", "invalidPenalty"
        ]
        self.objectiveDirection = "minimize"
        self.normalizationRules = [
            "mean absolute log luminance error",
            "absolute error divided by absoluteNitsNormalizer",
            "regional values are normalized by region population"
        ]
        self.aggregationRules = [
            "weighted sum using objectiveWeights",
            "video aggregates are the mean of scene metrics",
            "temporal metrics replace the scene temporal contribution exactly once"
        ]
        self.signedSemantics = [
            "signed error is generated minus reference",
            "positive overshoot and negative undershoot remain separate diagnostics",
            "primary objective uses absolute/log terms and never signed cancellation"
        ]
        self.regionalMetricNames = [
            "shadow", "midtone", "diffuseWhite", "highlight", "p0_p1", "p1_p10",
            "p10_p50", "p50_p90", "p90_p99", "p99_p100"
        ]
        self.temporalMetricNames = [
            "temporal luminance", "highlight pumping", "temporal flicker",
            "contiguous prepared windows only"
        ]
        self.failureHandling = [
            "non-finite output and invalid paired samples remain observable",
            "invalid metric values use invalidMetricScore and fail the evaluation gate",
            "no failure is silently converted into an empty successful metric"
        ]
        self.perceptualColorTransformVersion = "ICTCP-PQ-v1"
        self.colorScience = .calibrationV4
        self.referenceGridWidth = 32
        self.referenceGridHeight = 18
        self.perceptualColorInputMinimumNits = 0
        self.perceptualColorInputMaximumNits = 10_000
        self.percentileInterpolation = "nearest lower order statistic: floor((count - 1) * fraction)"
        self.nonFiniteHandling = "filter only for percentile ordering; paired samples increment invalid count"
        self.nonNegativeClampPolicy = "ratios, correlations, and penalty metrics clamp at their documented lower bound"
        self.nonNegativeClampFloor = 0
        self.correlationLowerBound = -1
        self.correlationUpperBound = 1
        self.correlationMinimumSampleCount = 2
        self.correlationDenominatorComparison = .greaterThan
        self.hueWrapRule = "shortest-circular-distance"
        self.hueNormalization = .pi
        self.hueFullTurnMultiplier = 2
        self.stableAggregationOrder = .callerSuppliedCanonicalPairOrder
        self.stableFrameOrderingRule = .generatedTimestampAscendingThenInputPositionAscending
        self.stableTemporalWindowOrderingRule = .sceneIDUTF8AscendingThenStartSecondsThenOffsetSeconds
        self.ratioIdentity = 1
        self.emptyPercentileValue = 0
        self.emptyFractionValue = 0
        self.emptyAverageValue = 0
        self.insufficientTemporalMetricValue = 0
        self.comparisonRules = [
            "regionLower": .greaterThanOrEqual,
            "regionUpper": .lessThanOrEqual,
            "highlightRegionLower": .greaterThanOrEqual,
            "highlightUnderreach": .lessThan,
            "highlightOvershoot": .greaterThan,
            "clipping": .greaterThanOrEqual,
            "shadowRegionUpper": .lessThanOrEqual,
            "blackCrushReference": .greaterThan,
            "blackCrushGenerated": .lessThan,
            "shadowLift": .greaterThan,
            "categoryHighKey": .greaterThan,
            "categoryLowKey": .lessThan,
            "categoryHighSaturationChroma": .greaterThan,
            "categoryHighSaturationRatio": .greaterThan,
            "categoryHighlightRich": .greaterThan,
            "failureHighlightUnderreach": .greaterThan,
            "failureHighlightOvershoot": .greaterThan,
            "failureDiffuseWhiteLow": .lessThan,
            "failureDiffuseWhiteHigh": .greaterThan,
            "failureMidtone": .greaterThan,
            "failureBlackCrush": .greaterThan,
            "failureShadowLift": .greaterThan,
            "failureSaturationLow": .greaterThan,
            "failureSaturationHigh": .greaterThan,
            "failureHue": .greaterThan,
            "failureTemporal": .greaterThan,
            "failureAlignment": .lessThan,
            "failureReferenceHue": .greaterThan,
            "failureReferenceLuminance": .greaterThan,
            "referenceChromaEligibility": .greaterThan,
            "generatedChromaEligibility": .greaterThan,
            "highChroma": .greaterThan,
            "skinPeak": .greaterThan,
            "skinSeparation": .greaterThan,
            "skinRedGreaterThanGreen": .greaterThan,
            "skinGreenGreaterThanBlue": .greaterThan,
            "saturationOvershoot": .greaterThan,
            "saturationUndershoot": .lessThan
        ]
        self.temporalMinimumFrameCount = 2
        self.temporalSecondDifferenceMinimumFrameCount = 3
        self.temporalSettledSampleCount = 4
        self.temporalRecoveryRelativeTolerance = 0.005
        self.temporalRecoveryAbsoluteTolerance = 0.0005
        self.temporalAutomaticEstimationEnabled = true
        self.temporalHistoryResetRule = .beforeEachWindow
        self.temporalSceneCutInputRule = .alwaysFalse
        self.absoluteNitsNormalizer = 1_000
        self.additiveLuminanceOffsetNits = 1
        self.percentileFractions = [
            "p1": 0.01, "p10": 0.10, "p25": 0.25, "p50": 0.50,
            "p75": 0.75, "p90": 0.90, "p95": 0.95, "p99": 0.99,
            "p999": 0.999
        ]
        self.regionPercentiles = [
            "p0_p1": V2MetricRegionDefinition(lowerPercentile: 0, upperPercentile: 0.01),
            "p1_p10": V2MetricRegionDefinition(lowerPercentile: 0.01, upperPercentile: 0.10),
            "p10_p50": V2MetricRegionDefinition(lowerPercentile: 0.10, upperPercentile: 0.50),
            "p50_p90": V2MetricRegionDefinition(lowerPercentile: 0.50, upperPercentile: 0.90),
            "p90_p99": V2MetricRegionDefinition(lowerPercentile: 0.90, upperPercentile: 0.99),
            "p99_p100": V2MetricRegionDefinition(lowerPercentile: 0.99, upperPercentile: 1.0),
            "shadow": V2MetricRegionDefinition(lowerPercentile: 0, upperPercentile: 0.10),
            "midtone": V2MetricRegionDefinition(lowerPercentile: 0.10, upperPercentile: 0.90),
            "diffuseWhite": V2MetricRegionDefinition(lowerPercentile: 0.75, upperPercentile: 0.95),
            "highlight": V2MetricRegionDefinition(lowerPercentile: 0.90, upperPercentile: 1.0)
        ]
        self.diffuseMidtoneSourceRange = V2MetricRegionDefinition(
            lowerPercentile: 0.15, upperPercentile: 0.45
        )

        self.highlightUnderreachRatio = 0.80
        self.highlightOvershootRatio = 1.25
        self.highlightOvershootAbsoluteNits = 20
        self.specularPercentile = 0.999
        self.clippingPeakRatio = 0.999
        self.slopeFloorNits = 1

        self.blackCrushReferenceThresholdNits = 1
        self.blackCrushGeneratedAbsoluteNits = 0.5
        self.blackCrushGeneratedRatio = 0.25
        self.shadowLiftRatio = 1.5
        self.shadowLiftAbsoluteNits = 2
        self.nearBlackReferenceRangeFloorNits = 1

        self.hueMeanWeight = 0.65
        self.hueP95Weight = 0.35
        self.temporalLuminanceWeight = 0.45
        self.temporalHighlightWeight = 0.35
        self.temporalFlickerWeight = 0.20

        self.minimumReferenceChroma = 0.01
        self.minimumGeneratedChroma = 0.005
        self.highChromaThreshold = 0.08
        self.saturationDenominatorFloor = 0.01
        self.saturationOvershootRatio = 1.25
        self.saturationOvershootAbsolute = 0.01
        self.saturationUndershootRatio = 0.75
        self.saturationUndershootAbsolute = 0.01
        self.skinMinimumPeakNits = 1
        self.skinRedBlueSeparation = 0.12

        self.categoryHighKeyThresholdNits = 150
        self.categoryLowKeyThresholdNits = 60
        self.categoryHighSaturationChromaThreshold = 0.08
        self.categoryHighSaturationRatio = 0.10
        self.categoryHighlightRichUnderreachRatio = 0.20

        self.failureHighlightUnderreachRatio = 0.20
        self.failureHighlightOvershootRatio = 0.10
        self.failureDiffuseWhiteLowRatio = 0.80
        self.failureDiffuseWhiteHighRatio = 1.20
        self.failureMidtoneError = 0.25
        self.failureBlackCrushRatio = 0.05
        self.failureShadowLiftRatio = 0.10
        self.failureSaturationRatio = 0.15
        self.failureHueP95Error = 0.10
        self.failureTemporalFlicker = 0.08
        self.failureAlignmentConfidence = 0.60
        self.failureReferenceMismatchHue = 0.20
        self.failureReferenceMismatchLuminance = 0.40

        self.correlationEpsilon = 1e-12
        self.invalidMetricScore = 1
        self.emptyAggregateObjective = 10
        self.emptyAggregateInvalidSampleCount = 1
    }

    public static let current = V2MetricSemanticConfiguration()

    /// These are the synthesized Codable keys that must remain covered by
    /// the canonical identity. A newly added semantic field makes the guard
    /// test fail until the field is consciously classified and tested.
    public static let canonicalFieldNames: Set<String> = [
        "semanticVersion", "metricVersion", "objectiveWeights", "objectiveNames",
        "objectiveDirection", "normalizationRules", "aggregationRules", "signedSemantics",
        "regionalMetricNames", "temporalMetricNames", "failureHandling",
        "perceptualColorTransformVersion", "colorScience", "referenceGridWidth", "referenceGridHeight",
        "perceptualColorInputMinimumNits",
        "perceptualColorInputMaximumNits", "percentileInterpolation", "nonFiniteHandling",
        "nonNegativeClampPolicy", "nonNegativeClampFloor", "correlationLowerBound",
        "correlationUpperBound", "correlationMinimumSampleCount", "correlationDenominatorComparison",
        "hueWrapRule", "hueNormalization", "hueFullTurnMultiplier", "stableAggregationOrder",
        "stableFrameOrderingRule", "stableTemporalWindowOrderingRule", "ratioIdentity", "emptyPercentileValue", "emptyFractionValue",
        "emptyAverageValue",
        "insufficientTemporalMetricValue", "comparisonRules",
        "temporalMinimumFrameCount", "temporalSecondDifferenceMinimumFrameCount",
        "temporalSettledSampleCount", "temporalRecoveryRelativeTolerance",
        "temporalRecoveryAbsoluteTolerance", "temporalAutomaticEstimationEnabled",
        "temporalHistoryResetRule", "temporalSceneCutInputRule",
        "absoluteNitsNormalizer", "additiveLuminanceOffsetNits",
        "percentileFractions", "regionPercentiles", "diffuseMidtoneSourceRange",
        "highlightUnderreachRatio", "highlightOvershootRatio", "highlightOvershootAbsoluteNits",
        "specularPercentile", "clippingPeakRatio", "slopeFloorNits",
        "blackCrushReferenceThresholdNits", "blackCrushGeneratedAbsoluteNits",
        "blackCrushGeneratedRatio", "shadowLiftRatio", "shadowLiftAbsoluteNits",
        "nearBlackReferenceRangeFloorNits", "hueMeanWeight", "hueP95Weight",
        "temporalLuminanceWeight", "temporalHighlightWeight", "temporalFlickerWeight",
        "minimumReferenceChroma", "minimumGeneratedChroma", "highChromaThreshold",
        "saturationDenominatorFloor", "saturationOvershootRatio", "saturationOvershootAbsolute",
        "saturationUndershootRatio", "saturationUndershootAbsolute", "skinMinimumPeakNits",
        "skinRedBlueSeparation", "categoryHighKeyThresholdNits", "categoryLowKeyThresholdNits",
        "categoryHighSaturationChromaThreshold", "categoryHighSaturationRatio",
        "categoryHighlightRichUnderreachRatio", "failureHighlightUnderreachRatio",
        "failureHighlightOvershootRatio", "failureDiffuseWhiteLowRatio",
        "failureDiffuseWhiteHighRatio", "failureMidtoneError", "failureBlackCrushRatio",
        "failureShadowLiftRatio", "failureSaturationRatio", "failureHueP95Error",
        "failureTemporalFlicker", "failureAlignmentConfidence", "failureReferenceMismatchHue",
        "failureReferenceMismatchLuminance", "correlationEpsilon", "invalidMetricScore",
        "emptyAggregateObjective", "emptyAggregateInvalidSampleCount"
    ]

    public static let requiredComparisonRuleNames: Set<String> = [
        "regionLower", "regionUpper", "highlightRegionLower", "highlightUnderreach",
        "highlightOvershoot", "clipping", "shadowRegionUpper", "blackCrushReference",
        "blackCrushGenerated", "shadowLift", "categoryHighKey", "categoryLowKey",
        "categoryHighSaturationChroma", "categoryHighSaturationRatio", "categoryHighlightRich",
        "failureHighlightUnderreach", "failureHighlightOvershoot", "failureDiffuseWhiteLow",
        "failureDiffuseWhiteHigh", "failureMidtone", "failureBlackCrush", "failureShadowLift",
        "failureSaturationLow", "failureSaturationHigh", "failureHue", "failureTemporal",
        "failureAlignment", "failureReferenceHue", "failureReferenceLuminance", "skinPeak",
        "referenceChromaEligibility", "generatedChromaEligibility", "highChroma", "skinSeparation",
        "skinRedGreaterThanGreen", "skinGreenGreaterThanBlue", "saturationOvershoot",
        "saturationUndershoot"
    ]

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }

    public func validate() throws {
        let data = try HDRCanonicalIdentity.data(self)
        guard let object = try JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        ) as? [String: Any], Set(object.keys) == Self.canonicalFieldNames else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        let scalarValues = [
            absoluteNitsNormalizer, additiveLuminanceOffsetNits,
            diffuseMidtoneSourceRange.lowerPercentile,
            diffuseMidtoneSourceRange.upperPercentile,
            highlightUnderreachRatio, highlightOvershootRatio,
            highlightOvershootAbsoluteNits, specularPercentile, clippingPeakRatio,
            slopeFloorNits, blackCrushReferenceThresholdNits,
            blackCrushGeneratedAbsoluteNits, blackCrushGeneratedRatio,
            shadowLiftRatio, shadowLiftAbsoluteNits, nearBlackReferenceRangeFloorNits,
            hueMeanWeight, hueP95Weight, temporalLuminanceWeight,
            temporalHighlightWeight, temporalFlickerWeight, minimumReferenceChroma,
            minimumGeneratedChroma, highChromaThreshold, saturationDenominatorFloor,
            saturationOvershootRatio, saturationOvershootAbsolute,
            saturationUndershootRatio, saturationUndershootAbsolute,
            skinMinimumPeakNits, skinRedBlueSeparation, categoryHighKeyThresholdNits,
            categoryLowKeyThresholdNits, categoryHighSaturationChromaThreshold,
            categoryHighSaturationRatio, categoryHighlightRichUnderreachRatio,
            failureHighlightUnderreachRatio, failureHighlightOvershootRatio,
            failureDiffuseWhiteLowRatio, failureDiffuseWhiteHighRatio,
            failureMidtoneError, failureBlackCrushRatio, failureShadowLiftRatio,
            failureSaturationRatio, failureHueP95Error, failureTemporalFlicker,
            failureAlignmentConfidence, failureReferenceMismatchHue,
            failureReferenceMismatchLuminance, correlationEpsilon, invalidMetricScore,
            emptyAggregateObjective, perceptualColorInputMinimumNits,
            perceptualColorInputMaximumNits, nonNegativeClampFloor,
            correlationLowerBound, correlationUpperBound, hueNormalization,
            hueFullTurnMultiplier, ratioIdentity, emptyPercentileValue,
            emptyFractionValue, emptyAverageValue, insufficientTemporalMetricValue,
            temporalRecoveryRelativeTolerance, temporalRecoveryAbsoluteTolerance
        ]
        let requiredPercentiles: Set<String> = [
            "p1", "p10", "p25", "p50", "p75", "p90", "p95", "p99", "p999"
        ]
        let requiredRegions: Set<String> = [
            "p0_p1", "p1_p10", "p10_p50", "p50_p90", "p90_p99", "p99_p100",
            "shadow", "midtone", "diffuseWhite", "highlight"
        ]
        guard requiredPercentiles.isSubset(of: Set(percentileFractions.keys)),
              requiredRegions.isSubset(of: Set(regionPercentiles.keys)),
              scalarValues.allSatisfy(\.isFinite),
              absoluteNitsNormalizer > 0,
              additiveLuminanceOffsetNits >= 0,
              correlationEpsilon > 0,
              correlationMinimumSampleCount > 0,
              correlationDenominatorComparison == .greaterThan ||
                  correlationDenominatorComparison == .greaterThanOrEqual,
              temporalMinimumFrameCount > 0,
              temporalSecondDifferenceMinimumFrameCount >= temporalMinimumFrameCount,
              temporalSettledSampleCount > 0,
              temporalRecoveryRelativeTolerance >= 0,
              temporalRecoveryAbsoluteTolerance >= 0,
              temporalAutomaticEstimationEnabled,
              temporalHistoryResetRule == .beforeEachWindow,
              temporalSceneCutInputRule == .alwaysFalse,
              hueWrapRule == "shortest-circular-distance",
              hueNormalization.isFinite && hueNormalization > 0,
              hueFullTurnMultiplier.isFinite && hueFullTurnMultiplier > 0,
              stableAggregationOrder == .callerSuppliedCanonicalPairOrder,
              stableFrameOrderingRule == .generatedTimestampAscendingThenInputPositionAscending,
              stableTemporalWindowOrderingRule == .sceneIDUTF8AscendingThenStartSecondsThenOffsetSeconds,
              ratioIdentity.isFinite,
              emptyPercentileValue.isFinite && emptyFractionValue.isFinite && emptyAverageValue.isFinite,
              insufficientTemporalMetricValue.isFinite,
              Set(comparisonRules.keys) == Self.requiredComparisonRuleNames,
              objectiveDirection == "minimize",
              !objectiveNames.isEmpty,
              !normalizationRules.isEmpty,
              !aggregationRules.isEmpty,
              !signedSemantics.isEmpty,
              !regionalMetricNames.isEmpty,
              !temporalMetricNames.isEmpty,
              !failureHandling.isEmpty,
              !perceptualColorTransformVersion.isEmpty,
              colorScience.isValid,
              referenceGridWidth > 0,
              referenceGridHeight > 0,
              !percentileInterpolation.isEmpty,
              !nonFiniteHandling.isEmpty,
              !nonNegativeClampPolicy.isEmpty,
              perceptualColorInputMinimumNits >= 0,
              perceptualColorInputMaximumNits > perceptualColorInputMinimumNits,
              nonNegativeClampFloor >= 0,
              correlationLowerBound < correlationUpperBound,
              invalidMetricScore >= 0,
              percentileFractions.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              regionPercentiles.values.allSatisfy({
                  $0.lowerPercentile.isFinite && $0.upperPercentile.isFinite &&
                  (0...1).contains($0.lowerPercentile) &&
                  (0...1).contains($0.upperPercentile) &&
                  $0.lowerPercentile <= $0.upperPercentile
              }),
              objectiveWeightsValuesAreFinite,
              objectiveWeightsValuesAreNonNegative else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        guard emptyAggregateInvalidSampleCount > 0 else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    private var objectiveWeightsValuesAreFinite: Bool {
        [
            objectiveWeights.luminance, objectiveWeights.absoluteNits,
            objectiveWeights.midtone, objectiveWeights.diffuseWhite,
            objectiveWeights.highlight, objectiveWeights.shadow, objectiveWeights.chroma,
            objectiveWeights.saturation, objectiveWeights.hue, objectiveWeights.temporal,
            objectiveWeights.structure, objectiveWeights.clippingPenalty,
            objectiveWeights.blackCrushPenalty, objectiveWeights.saturationPenalty,
            objectiveWeights.invalidPenalty
        ].allSatisfy(\.isFinite)
    }

    private var objectiveWeightsValuesAreNonNegative: Bool {
        [
            objectiveWeights.luminance, objectiveWeights.absoluteNits,
            objectiveWeights.midtone, objectiveWeights.diffuseWhite,
            objectiveWeights.highlight, objectiveWeights.shadow, objectiveWeights.chroma,
            objectiveWeights.saturation, objectiveWeights.hue, objectiveWeights.temporal,
            objectiveWeights.structure, objectiveWeights.clippingPenalty,
            objectiveWeights.blackCrushPenalty, objectiveWeights.saturationPenalty,
            objectiveWeights.invalidPenalty
        ].allSatisfy { $0 >= 0 }
    }
}
