import Foundation
import HDRCore

/// A named interval in the reference percentile domain.  Keeping the
/// boundaries as numbers, rather than prose, makes every region decision
/// part of the metric identity.
public struct V2MetricRegionDefinition: Codable, Hashable, Sendable {
    public var lowerPercentile: Double
    public var upperPercentile: Double

    public init(lowerPercentile: Double, upperPercentile: Double) {
        self.lowerPercentile = lowerPercentile
        self.upperPercentile = upperPercentile
    }
}

/// Complete semantic input to the V2 objective evaluator.  This is the
/// single source of truth for thresholds, normalizers, regional boundaries,
/// category/failure gates, and objective weights.  The evaluator receives
/// this object directly; the preregistration seals its canonical encoding.
public struct V2MetricSemanticConfiguration: Codable, Hashable, Sendable {
    public static let semanticVersion = "v2-metric-semantics-v3"

    public var semanticVersion: String
    public var metricVersion: String
    public var objectiveWeights: V2ObjectiveWeights
    public var objectiveNames: [String]
    public var objectiveDirection: String
    public var normalizationRules: [String]
    public var aggregationRules: [String]
    public var signedSemantics: [String]
    public var regionalMetricNames: [String]
    public var temporalMetricNames: [String]
    public var failureHandling: [String]
    public var perceptualColorTransformVersion: String
    public var perceptualColorInputMinimumNits: Double
    public var perceptualColorInputMaximumNits: Double
    public var percentileInterpolation: String
    public var nonFiniteHandling: String
    public var nonNegativeClampPolicy: String
    public var nonNegativeClampFloor: Double
    public var correlationLowerBound: Double
    public var correlationUpperBound: Double

    public var absoluteNitsNormalizer: Double
    public var additiveLuminanceOffsetNits: Double
    public var percentileFractions: [String: Double]
    public var regionPercentiles: [String: V2MetricRegionDefinition]
    public var diffuseMidtoneSourceRange: V2MetricRegionDefinition

    public var highlightUnderreachRatio: Double
    public var highlightOvershootRatio: Double
    public var highlightOvershootAbsoluteNits: Double
    public var specularPercentile: Double
    public var clippingPeakRatio: Double
    public var slopeFloorNits: Double

    public var blackCrushReferenceThresholdNits: Double
    public var blackCrushGeneratedAbsoluteNits: Double
    public var blackCrushGeneratedRatio: Double
    public var shadowLiftRatio: Double
    public var shadowLiftAbsoluteNits: Double
    public var nearBlackReferenceRangeFloorNits: Double

    public var hueMeanWeight: Double
    public var hueP95Weight: Double
    public var temporalLuminanceWeight: Double
    public var temporalHighlightWeight: Double
    public var temporalFlickerWeight: Double

    public var minimumReferenceChroma: Double
    public var minimumGeneratedChroma: Double
    public var highChromaThreshold: Double
    public var saturationDenominatorFloor: Double
    public var saturationOvershootRatio: Double
    public var saturationOvershootAbsolute: Double
    public var saturationUndershootRatio: Double
    public var saturationUndershootAbsolute: Double
    public var skinMinimumPeakNits: Double
    public var skinRedBlueSeparation: Double

    public var categoryHighKeyThresholdNits: Double
    public var categoryLowKeyThresholdNits: Double
    public var categoryHighSaturationChromaThreshold: Double
    public var categoryHighSaturationRatio: Double
    public var categoryHighlightRichUnderreachRatio: Double

    public var failureHighlightUnderreachRatio: Double
    public var failureHighlightOvershootRatio: Double
    public var failureDiffuseWhiteLowRatio: Double
    public var failureDiffuseWhiteHighRatio: Double
    public var failureMidtoneError: Double
    public var failureBlackCrushRatio: Double
    public var failureShadowLiftRatio: Double
    public var failureSaturationRatio: Double
    public var failureHueP95Error: Double
    public var failureTemporalFlicker: Double
    public var failureAlignmentConfidence: Double
    public var failureReferenceMismatchHue: Double
    public var failureReferenceMismatchLuminance: Double

    public var correlationEpsilon: Double
    public var invalidMetricScore: Double
    public var emptyAggregateObjective: Double
    public var emptyAggregateInvalidSampleCount: Int

    public init() {
        self.semanticVersion = Self.semanticVersion
        self.metricVersion = "v2-objective-with-v61-directional-diagnostics"
        // V4's historical production evaluator gives the shadow and temporal
        // terms their explicit calibrated weights.  Keep those semantics in
        // this one object so the preregistered evaluator and legacy V4
        // compatibility path cannot silently use different numbers.
        var objectiveWeights = V2ObjectiveWeights()
        objectiveWeights.shadow = 0.15
        objectiveWeights.temporal = 0.10
        self.objectiveWeights = objectiveWeights
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
        self.perceptualColorTransformVersion = "ICTCP-PQ-v1; coefficients fixed in PerceptualColorV2"
        self.perceptualColorInputMinimumNits = 0
        self.perceptualColorInputMaximumNits = 10_000
        self.percentileInterpolation = "nearest lower order statistic: floor((count - 1) * fraction)"
        self.nonFiniteHandling = "filter only for percentile ordering; paired samples increment invalid count"
        self.nonNegativeClampPolicy = "ratios, correlations, and penalty metrics clamp at their documented lower bound"
        self.nonNegativeClampFloor = 0
        self.correlationLowerBound = -1
        self.correlationUpperBound = 1
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
        "perceptualColorTransformVersion", "perceptualColorInputMinimumNits",
        "perceptualColorInputMaximumNits", "percentileInterpolation", "nonFiniteHandling",
        "nonNegativeClampPolicy", "nonNegativeClampFloor", "correlationLowerBound",
        "correlationUpperBound",
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

    public func canonicalSHA256() throws -> String {
        try HDRCanonicalIdentity.sha256(self)
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
            correlationLowerBound, correlationUpperBound
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
              objectiveDirection == "minimize",
              !objectiveNames.isEmpty,
              !normalizationRules.isEmpty,
              !aggregationRules.isEmpty,
              !signedSemantics.isEmpty,
              !regionalMetricNames.isEmpty,
              !temporalMetricNames.isEmpty,
              !failureHandling.isEmpty,
              !perceptualColorTransformVersion.isEmpty,
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
