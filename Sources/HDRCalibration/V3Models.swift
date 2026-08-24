import Foundation

public enum CalibrationV3Verdict: String, Codable, Sendable {
    case promote = "PROMOTE_CALIBRATED_V3"
    case keepV2 = "KEEP_CALIBRATED_V2"
    case identifiabilityFail = "IDENTIFIABILITY_FAIL"
    case edrMappingInvalid = "EDR_MAPPING_INVALID"
    case shadowInsufficient = "SHADOW_CONTROL_INSUFFICIENT"
    case temporalInsufficient = "TEMPORAL_MODEL_INSUFFICIENT"
    case validationFail = "VALIDATION_FAIL"
}

public struct V3ParameterBounds: Codable, Sendable {
    public var paperWhiteNits: ClosedRange<Float> = 200...235
    public var peakNits: ClosedRange<Float> = 900...1_250
    public var highlightStrength: ClosedRange<Float> = 0.50...0.76
    public var contrastStrength: ClosedRange<Float> = 0.72...0.92
    public var saturationCompensation: ClosedRange<Float> = 0.12...0.34
    public var shadowProtection: ClosedRange<Float> = 0.20...1.0
    public var temporalStability: ClosedRange<Float> = 0.20...0.98

    public init() {}
}

public struct V3SearchConfiguration: Codable, Sendable {
    public var version = "calibration-v3"
    public var splitSeed: UInt64 = 92
    public var searchSeed: UInt64 = 20_260_824
    public var globalCandidates = 128
    public var localCandidates = 64
    public var validationTopCount = 8
    public var maxFramesPerScene = 8
    public var confidenceThreshold = 0.60
    public var referenceTargetPeakNits: Float = 1_000
    public var bounds = V3ParameterBounds()
    public var weights: V2ObjectiveWeights = {
        var value = V2ObjectiveWeights()
        value.shadow = 0.15
        value.temporal = 0.10
        return value
    }()

    public init() {}
}

public struct V3HistoricalBaseline: Codable, Sendable {
    public var name: String
    public var tuneObjective: Double
    public var validationObjective: Double
    public var legacyFrozenObjective: Double
}

public struct V3SensitivitySample: Codable, Sendable {
    public var parameter: String
    public var value: Float
    public var objective: Double
    public var shadowError: Double
    public var shadowLiftRatio: Double
    public var temporalFlicker: Double
    public var highlightPumping: Double
    public var cutRecoveryFrames: Double
}

public struct V3ParameterIdentification: Codable, Sendable {
    public var parameter: String
    public var selected: Float?
    public var maximumMetricDelta: Double
    public var identified: Bool
    public var primaryMetric: String
}

public struct V3InfluenceRow: Codable, Sendable {
    public var parameter: String
    public var highlight: Double
    public var midtone: Double
    public var shadow: Double
    public var hue: Double
    public var temporal: Double
}

public struct V3CandidateSummary: Codable, Sendable {
    public var id: String
    public var stage: String
    public var parameters: CalibrationParameters
    public var tune: V2MetricBreakdown
    public var validation: V2MetricBreakdown?
    public var constraintsPassed: Bool
    public var rejectionReasons: [String]
}

public struct V3RuntimeReport: Codable, Sendable {
    public var masteringHeadroom: Float
    public var simulatedDisplayHeadrooms: [Float]
    public var mapperMonotonic: Bool
    public var referenceWhitePreserved: Bool
    public var hardClipPlateauAbsent: Bool
    public var benchmarkCommands: [String: String]
    public var playerSmoke: [String: String]

    public init(
        masteringHeadroom: Float,
        simulatedDisplayHeadrooms: [Float],
        mapperMonotonic: Bool,
        referenceWhitePreserved: Bool,
        hardClipPlateauAbsent: Bool,
        benchmarkCommands: [String: String] = [:],
        playerSmoke: [String: String] = [:]
    ) {
        self.masteringHeadroom = masteringHeadroom
        self.simulatedDisplayHeadrooms = simulatedDisplayHeadrooms
        self.mapperMonotonic = mapperMonotonic
        self.referenceWhitePreserved = referenceWhitePreserved
        self.hardClipPlateauAbsent = hardClipPlateauAbsent
        self.benchmarkCommands = benchmarkCommands
        self.playerSmoke = playerSmoke
    }
}

public struct V3FinalReport: Codable, Sendable {
    public var version: String
    public var generatedAt: String
    public var manifestPath: String
    public var splitSeed: UInt64
    public var searchSeed: UInt64
    public var split: V2SplitDocument
    public var historicalV2: V3HistoricalBaseline
    public var defaultTune: V2DatasetEvaluation
    public var v1Tune: V2DatasetEvaluation
    public var v2Tune: V2DatasetEvaluation
    public var v3Tune: V2DatasetEvaluation?
    public var defaultValidation: V2DatasetEvaluation
    public var v1Validation: V2DatasetEvaluation
    public var v2Validation: V2DatasetEvaluation
    public var v3Validation: V2DatasetEvaluation?
    public var defaultLegacyFrozen: V2DatasetEvaluation?
    public var v1LegacyFrozen: V2DatasetEvaluation?
    public var v2LegacyFrozen: V2DatasetEvaluation?
    public var v3LegacyFrozen: V2DatasetEvaluation?
    public var sensitivity: [V3SensitivitySample]
    public var influenceMatrix: [V3InfluenceRow]
    public var identification: [V3ParameterIdentification]
    public var globalCandidates: [V3CandidateSummary]
    public var localCandidates: [V3CandidateSummary]
    public var validationCandidates: [V3CandidateSummary]
    public var selectedParameters: CalibrationParameters?
    public var verdict: CalibrationV3Verdict
    public var reasons: [String]
    public var limitations: [String]
}
