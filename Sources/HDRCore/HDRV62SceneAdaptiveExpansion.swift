import Foundation

/// Development-only scene-adaptive budget controllers.  These identifiers are
/// runtime algorithms, never reference-transfer labels.  A controller can
/// observe only source statistics that the causal runtime estimator exposes.
public enum HDRV62ExpansionController: UInt32, CaseIterable, Codable, Hashable, Sendable {
    case highlightDemand = 0
    case dynamicRangeDemand = 1
    case compactCombined = 2

    public var shortName: String {
        switch self {
        case .highlightDemand: return "ADAPTIVE_A_HIGHLIGHT"
        case .dynamicRangeDemand: return "ADAPTIVE_B_DYNAMIC_RANGE"
        case .compactCombined: return "ADAPTIVE_C_COMBINED"
        }
    }

    public var rawLabel: String {
        switch self {
        case .highlightDemand: return "v6.2-candidate-adaptive-highlight"
        case .dynamicRangeDemand: return "v6.2-candidate-adaptive-dynamic-range"
        case .compactCombined: return "v6.2-candidate-adaptive-combined"
        }
    }
}

/// Frozen-after-Tune controller parameters.  The values are development
/// defaults until the V6.2 runner fits a controller on Tune.  They are kept
/// as explicit configuration fields so a runtime experiment is reviewable
/// and reproducible without introducing a learned table or a content label.
public struct HDRV62ControllerParameters: Codable, Equatable, Sendable {
    public var minimumBudget: Float
    public var highlightLow: Float
    public var highlightHigh: Float
    public var dynamicRangeLow: Float
    public var dynamicRangeHigh: Float
    public var midtoneLow: Float
    public var midtoneHigh: Float
    public var combinedHighlightWeight: Float
    public var combinedDynamicRangeWeight: Float
    public var combinedMidtoneWeight: Float

    public init(
        minimumBudget: Float = 0.35,
        highlightLow: Float = 0.05,
        highlightHigh: Float = 0.35,
        dynamicRangeLow: Float = 1.0,
        dynamicRangeHigh: Float = 3.5,
        midtoneLow: Float = 0.15,
        midtoneHigh: Float = 0.55,
        combinedHighlightWeight: Float = 0.40,
        combinedDynamicRangeWeight: Float = 0.35,
        combinedMidtoneWeight: Float = 0.25
    ) {
        self.minimumBudget = minimumBudget
        self.highlightLow = highlightLow
        self.highlightHigh = highlightHigh
        self.dynamicRangeLow = dynamicRangeLow
        self.dynamicRangeHigh = dynamicRangeHigh
        self.midtoneLow = midtoneLow
        self.midtoneHigh = midtoneHigh
        self.combinedHighlightWeight = combinedHighlightWeight
        self.combinedDynamicRangeWeight = combinedDynamicRangeWeight
        self.combinedMidtoneWeight = combinedMidtoneWeight
    }

    public static let developmentDefault = HDRV62ControllerParameters()

    public var isFinite: Bool {
        [
            minimumBudget, highlightLow, highlightHigh,
            dynamicRangeLow, dynamicRangeHigh, midtoneLow, midtoneHigh,
            combinedHighlightWeight, combinedDynamicRangeWeight,
            combinedMidtoneWeight
        ].allSatisfy(\.isFinite)
    }

    public var weightsSum: Float {
        combinedHighlightWeight + combinedDynamicRangeWeight + combinedMidtoneWeight
    }

    public func applying(to base: HDRConfiguration = .calibratedV4) -> HDRConfiguration {
        var value = base
        value.toneCurveRevision = .sceneAdaptiveV62Candidate
        value.developmentExpansionMinimumBudget = minimumBudget
        value.developmentExpansionHighlightLow = highlightLow
        value.developmentExpansionHighlightHigh = highlightHigh
        value.developmentExpansionRangeLow = dynamicRangeLow
        value.developmentExpansionRangeHigh = dynamicRangeHigh
        value.developmentExpansionMidtoneLow = midtoneLow
        value.developmentExpansionMidtoneHigh = midtoneHigh
        value.developmentExpansionCombinedHighlightWeight = combinedHighlightWeight
        value.developmentExpansionCombinedRangeWeight = combinedDynamicRangeWeight
        value.developmentExpansionCombinedMidtoneWeight = combinedMidtoneWeight
        return value
    }
}

/// Runtime-observable features derived from the causal scene percentile
/// state.  The occupancy values are explicitly proxies because the current
/// production state carries percentiles rather than a full histogram.
public struct HDRV62SceneFeatures: Codable, Equatable, Sendable {
    public let p01: Float
    public let p05: Float
    public let p50: Float
    public let p90: Float
    public let p99: Float
    public let shadowFloor: Float
    public let shadowTop: Float
    public let dynamicRangeStops: Float
    public let highlightOccupancyProxy: Float
    public let midtoneOccupancyProxy: Float
    public let nearBlackOccupancyProxy: Float
    public let statisticsValid: Bool

    public init(statistics: HDRSceneStatistics, statisticsValid: Bool = true) {
        let p01 = Self.clamp(statistics.p01)
        let p05 = Self.clamp(statistics.p05)
        let p50 = Self.clamp(statistics.p50)
        let p90 = Self.clamp(statistics.p90)
        let p99 = Self.clamp(statistics.p99)
        let span = max(p99 - p01, 0.0001)
        self.p01 = p01
        self.p05 = p05
        self.p50 = p50
        self.p90 = p90
        self.p99 = p99
        self.shadowFloor = statistics.shadowFloor
        self.shadowTop = statistics.shadowTop
        self.dynamicRangeStops = log2((p99 + 0.005) / (p50 + 0.005))
        self.highlightOccupancyProxy = Self.clamp((p99 - p90) / max(1 - p90, 0.05))
        self.midtoneOccupancyProxy = Self.clamp(
            (min(p90, 0.75) - max(p50, 0.10)) / span
        )
        self.nearBlackOccupancyProxy = Self.clamp((0.05 - p05) / 0.05)
        self.statisticsValid = statisticsValid
    }

    public static let neutral = HDRV62SceneFeatures(
        statistics: .neutral,
        statisticsValid: false
    )

    public var isFinite: Bool {
        [
            p01, p05, p50, p90, p99, shadowFloor, shadowTop,
            dynamicRangeStops, highlightOccupancyProxy,
            midtoneOccupancyProxy, nearBlackOccupancyProxy
        ].allSatisfy(\.isFinite)
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value.isFinite ? value : 0, 0), 1)
    }
}

public struct HDRV62ExpansionBudgetDiagnostic: Codable, Equatable, Sendable {
    public let controller: HDRV62ExpansionController
    public let budget: Float
    public let highlightDemand: Float
    public let dynamicRangeDemand: Float
    public let midtoneDemand: Float
    public let statisticsValid: Bool

    public init(
        controller: HDRV62ExpansionController,
        budget: Float,
        highlightDemand: Float,
        dynamicRangeDemand: Float,
        midtoneDemand: Float,
        statisticsValid: Bool
    ) {
        self.controller = controller
        self.budget = budget
        self.highlightDemand = highlightDemand
        self.dynamicRangeDemand = dynamicRangeDemand
        self.midtoneDemand = midtoneDemand
        self.statisticsValid = statisticsValid
    }
}

/// Pure budget math mirrored by the Metal revision-4 development branch.
/// `budget == 1` is the V4 endpoint and `budget == 0` removes only the V4
/// low-mid contribution; the shoulder and protection arithmetic remain V4.
public enum HDRV62ExpansionBudgetMath {
    public static func smoothStep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let denominator = max(edge1 - edge0, 0.000001)
        let t = min(max((value - edge0) / denominator, 0), 1)
        return t * t * (3 - 2 * t)
    }

    public static func budget(
        features: HDRV62SceneFeatures,
        controller: HDRV62ExpansionController,
        parameters: HDRV62ControllerParameters
    ) -> HDRV62ExpansionBudgetDiagnostic {
        guard features.statisticsValid, features.isFinite, parameters.isFinite else {
            return HDRV62ExpansionBudgetDiagnostic(
                controller: controller,
                budget: 1,
                highlightDemand: 1,
                dynamicRangeDemand: 1,
                midtoneDemand: 1,
                statisticsValid: false
            )
        }

        let highlight = smoothStep(
            parameters.highlightLow,
            parameters.highlightHigh,
            features.highlightOccupancyProxy
        )
        let dynamicRange = smoothStep(
            parameters.dynamicRangeLow,
            parameters.dynamicRangeHigh,
            features.dynamicRangeStops
        )
        let midtoneDemand = 1 - smoothStep(
            parameters.midtoneLow,
            parameters.midtoneHigh,
            features.midtoneOccupancyProxy
        )
        let signal: Float
        switch controller {
        case .highlightDemand:
            signal = highlight
        case .dynamicRangeDemand:
            signal = dynamicRange
        case .compactCombined:
            let sum = max(parameters.weightsSum, 0.000001)
            signal = (
                parameters.combinedHighlightWeight * highlight +
                parameters.combinedDynamicRangeWeight * dynamicRange +
                parameters.combinedMidtoneWeight * midtoneDemand
            ) / sum
        }
        let minimum = min(max(parameters.minimumBudget, 0), 1)
        let value = min(max(minimum + (1 - minimum) * signal, 0), 1)
        return HDRV62ExpansionBudgetDiagnostic(
            controller: controller,
            budget: value,
            highlightDemand: highlight,
            dynamicRangeDemand: dynamicRange,
            midtoneDemand: midtoneDemand,
            statisticsValid: true
        )
    }
}

public struct HDRV62ToneCurveBreakdown: Codable, Equatable, Sendable {
    public let inputLuminance: Float
    public let expandedLuminance: Float
    public let lowMidContribution: Float
    public let shoulderContribution: Float
    public let shadowProtectionFactor: Float
    public let effectiveStrength: Float
    public let lowMidTransition: Float
    public let budget: HDRV62ExpansionBudgetDiagnostic
    public let shadowFloor: Float
    public let shadowTop: Float
    public let shoulderStart: Float

    public init(
        inputLuminance: Float,
        expandedLuminance: Float,
        lowMidContribution: Float,
        shoulderContribution: Float,
        shadowProtectionFactor: Float,
        effectiveStrength: Float,
        lowMidTransition: Float,
        budget: HDRV62ExpansionBudgetDiagnostic,
        shadowFloor: Float,
        shadowTop: Float,
        shoulderStart: Float
    ) {
        self.inputLuminance = inputLuminance
        self.expandedLuminance = expandedLuminance
        self.lowMidContribution = lowMidContribution
        self.shoulderContribution = shoulderContribution
        self.shadowProtectionFactor = shadowProtectionFactor
        self.effectiveStrength = effectiveStrength
        self.lowMidTransition = lowMidTransition
        self.budget = budget
        self.shadowFloor = shadowFloor
        self.shadowTop = shadowTop
        self.shoulderStart = shoulderStart
    }
}

public enum HDRV62ToneCurveMath {
    public static let lowMidCoefficient: Float = 0.08
    public static let shoulderMargin: Float = 0.000001

    public static func breakdown(
        luminance: Float,
        configuration: HDRConfiguration,
        temporalAdaptation: Float = 1,
        sceneStatistics: HDRSceneStatistics? = nil,
        budgetOverride: Float? = nil
    ) -> HDRV62ToneCurveBreakdown {
        let peakRatio = configuration.peakNits / configuration.paperWhiteNits
        let y = min(max(luminance, 0), 1)
        let shoulderStart = 0.68 - 0.20 * min(max(configuration.contrastStrength, 0), 1)
        let shoulderT = HDRV62ExpansionBudgetMath.smoothStep(shoulderStart, 1, y)
        let shoulder = shoulderT * shoulderT * (3 - 2 * shoulderT)
        let strength = min(max(configuration.highlightStrength * temporalAdaptation, 0), 1)
        let statistics = sceneStatistics ?? .neutral
        let valid = sceneStatistics != nil
        let floor = valid ? min(max(statistics.shadowFloor, 0.001), 0.20) : 0.01
        var top = valid ? max(statistics.shadowTop, floor + 0.025) : 0.1125
        top = min(top, 0.60)
        let transition = HDRV62ExpansionBudgetMath.smoothStep(floor, top, y)
        let shadowWeight = 1 - transition
        let protection = 1 - 0.90 * min(max(configuration.shadowProtection, 0), 1) * shadowWeight
        let features = HDRV62SceneFeatures(statistics: statistics, statisticsValid: valid)
        let controller = HDRV62ExpansionController(rawValue: configuration.developmentExpansionController.rawValue) ?? .compactCombined
        let parameters = HDRV62ControllerParameters(
            minimumBudget: configuration.developmentExpansionMinimumBudget,
            highlightLow: configuration.developmentExpansionHighlightLow,
            highlightHigh: configuration.developmentExpansionHighlightHigh,
            dynamicRangeLow: configuration.developmentExpansionRangeLow,
            dynamicRangeHigh: configuration.developmentExpansionRangeHigh,
            midtoneLow: configuration.developmentExpansionMidtoneLow,
            midtoneHigh: configuration.developmentExpansionMidtoneHigh,
            combinedHighlightWeight: configuration.developmentExpansionCombinedHighlightWeight,
            combinedDynamicRangeWeight: configuration.developmentExpansionCombinedRangeWeight,
            combinedMidtoneWeight: configuration.developmentExpansionCombinedMidtoneWeight
        )
        let budget = budgetOverride.map { value in
            HDRV62ExpansionBudgetDiagnostic(
                controller: controller,
                budget: min(max(value.isFinite ? value : 0, 0), 1),
                highlightDemand: 0,
                dynamicRangeDemand: 0,
                midtoneDemand: 0,
                statisticsValid: valid
            )
        } ?? HDRV62ExpansionBudgetMath.budget(
            features: features,
            controller: controller,
            parameters: parameters
        )
        let lowMid = (peakRatio - 1) * strength * Self.lowMidCoefficient * transition * y * budget.budget
        let shoulderContribution = (peakRatio - 1) * strength * shoulder * y
        let lowMidContribution = max(lowMid * protection, 0)
        let protectedShoulder = max(shoulderContribution * protection, 0)
        let expanded = min(max(y + lowMidContribution + protectedShoulder, y), peakRatio)
        return HDRV62ToneCurveBreakdown(
            inputLuminance: y,
            expandedLuminance: expanded,
            lowMidContribution: lowMidContribution,
            shoulderContribution: protectedShoulder,
            shadowProtectionFactor: protection,
            effectiveStrength: strength,
            lowMidTransition: transition,
            budget: budget,
            shadowFloor: floor,
            shadowTop: top,
            shoulderStart: shoulderStart
        )
    }

    public static func toneExpand(
        _ luminance: Float,
        configuration: HDRConfiguration,
        temporalAdaptation: Float = 1,
        sceneStatistics: HDRSceneStatistics? = nil,
        budgetOverride: Float? = nil
    ) -> Float {
        breakdown(
            luminance: luminance,
            configuration: configuration,
            temporalAdaptation: temporalAdaptation,
            sceneStatistics: sceneStatistics,
            budgetOverride: budgetOverride
        ).expandedLuminance
    }
}

/// Names used by the player and offline report.  No value in this enum is a
/// production preset; it always selects the development-only revision 4.
public enum HDRV62ToneCurveCandidate: String, CaseIterable, Codable, Sendable {
    case adaptiveHighlight = "v6.2-candidate-adaptive-highlight"
    case adaptiveDynamicRange = "v6.2-candidate-adaptive-dynamic-range"
    case adaptiveCombined = "v6.2-candidate-adaptive-combined"

    public var controller: HDRV62ExpansionController {
        switch self {
        case .adaptiveHighlight: return .highlightDemand
        case .adaptiveDynamicRange: return .dynamicRangeDemand
        case .adaptiveCombined: return .compactCombined
        }
    }

    public var shortName: String { controller.shortName }

    /// Parameters selected by the current Tune-only V6.2 run.  This is a
    /// development parameter freeze, never a production preset.  The runner
    /// passes its fitted values explicitly; this fallback makes the same
    /// candidate reproducible from the player and benchmark entry points.
    public var tuneParameterFreeze: HDRV62ControllerParameters {
        switch self {
        case .adaptiveHighlight:
            var value = HDRV62ControllerParameters.developmentDefault
            value.minimumBudget = 0.65
            value.highlightLow = 0
            value.highlightHigh = 0.45
            return value
        case .adaptiveDynamicRange:
            var value = HDRV62ControllerParameters.developmentDefault
            value.minimumBudget = 0.65
            value.dynamicRangeLow = 0.25
            value.dynamicRangeHigh = 1.5
            return value
        case .adaptiveCombined:
            var value = HDRV62ControllerParameters.developmentDefault
            value.minimumBudget = 0.65
            value.combinedHighlightWeight = 0.50
            value.combinedDynamicRangeWeight = 0.30
            value.combinedMidtoneWeight = 0.20
            return value
        }
    }

    public func configuration(
        base: HDRConfiguration = .calibratedV4,
        parameters: HDRV62ControllerParameters? = nil
    ) -> HDRConfiguration {
        var value = (parameters ?? tuneParameterFreeze).applying(to: base)
        value.developmentExpansionController = controller
        return value
    }
}
