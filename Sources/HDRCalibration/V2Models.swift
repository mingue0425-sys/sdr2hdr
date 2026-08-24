import Foundation

public enum CalibrationV2Verdict: String, Codable, Sendable {
    case promote = "PROMOTE_CALIBRATED_V2"
    case keepV1 = "KEEP_CALIBRATED_V1"
    case reject = "REJECT_CALIBRATED_V2"
    case insufficientData = "INSUFFICIENT_DATA"
    case alignmentNotReliable = "ALIGNMENT_NOT_RELIABLE"
}

public struct V2ParameterBounds: Codable, Sendable {
    public var paperWhiteNits: ClosedRange<Float> = 180...230
    public var peakNits: ClosedRange<Float> = 800...1_400
    public var highlightStrength: ClosedRange<Float> = 0.55...0.90
    public var contrastStrength: ClosedRange<Float> = 0.45...0.85
    public var saturationCompensation: ClosedRange<Float> = 0.20...0.60
    public var shadowProtection: ClosedRange<Float> = 0.82...0.98
    public var temporalStability: ClosedRange<Float> = 0.82...0.96

    public init() {}
}

public struct V2ObjectiveWeights: Codable, Sendable {
    public var luminance = 0.16
    public var absoluteNits = 0.03
    public var midtone = 0.08
    public var diffuseWhite = 0.12
    public var highlight = 0.18
    public var shadow = 0.10
    public var chroma = 0.07
    public var saturation = 0.04
    public var hue = 0.08
    public var temporal = 0.08
    public var structure = 0.06
    public var clippingPenalty = 0.30
    public var blackCrushPenalty = 0.20
    public var saturationPenalty = 0.10
    public var invalidPenalty = 10.0

    public init() {}
}

public struct V2SearchConfiguration: Codable, Sendable {
    public var version = "calibration-v2"
    public var splitSeed: UInt64 = 92
    public var searchSeed: UInt64 = 20_260_823
    public var globalCandidates = 128
    public var localCandidates = 64
    public var validationTopCount = 8
    public var maxFramesPerScene = 8
    public var alignmentSearchThreshold = 0.60
    public var alignmentSensitivityThresholds: [Double] = [0, 0.60, 0.70, 0.80, 0.90]
    public var referenceTargetPeakNits: Float = 1_000
    public var bootstrapSamples = 1_000
    public var bounds = V2ParameterBounds()
    public var weights = V2ObjectiveWeights()

    public init() {}
}

public struct V2Percentiles: Codable, Sendable {
    public var p1: Double
    public var p10: Double
    public var p25: Double
    public var p50: Double
    public var p75: Double
    public var p90: Double
    public var p95: Double
    public var p99: Double
    public var p999: Double
}

public struct V2MetricBreakdown: Codable, Sendable {
    public var objective: Double
    public var luminanceError: Double
    public var absoluteNitError: Double
    public var midtoneError: Double
    public var diffuseWhiteError: Double
    public var highlightError: Double
    public var shadowError: Double
    public var chromaError: Double
    public var saturationError: Double
    public var hueMeanError: Double
    public var hueP95Error: Double
    public var highChromaHueError: Double
    public var skinLikeHueError: Double
    public var temporalLuminanceError: Double
    public var highlightPumping: Double
    public var temporalFlicker: Double
    public var sceneCutOvershoot: Double
    public var sceneCutRecovery: Double
    public var structureError: Double
    public var clippingRatio: Double
    public var blackCrushRatio: Double
    public var shadowLiftRatio: Double
    public var nearBlackContrastLoss: Double
    public var highlightUnderReachRatio: Double
    public var highlightOvershootRatio: Double
    public var highlightCompressionError: Double
    public var specularPeakUnderReach: Double
    public var specularPeakOvershoot: Double
    public var referenceDiffuseWhiteNits: Double
    public var generatedDiffuseWhiteNits: Double
    public var overSaturationRatio: Double
    public var underSaturationRatio: Double
    public var invalidSampleCount: Int
    public var luminanceRegionErrors: [String: Double]
    public var weightedContributions: [String: Double]
}

public struct V2AlignmentStatistics: Codable, Sendable {
    public var sampledFrames: Int
    public var matchedFrames: Int
    public var rejectedFrames: Int
    public var matchRatio: Double
    public var meanConfidence: Double
    public var medianConfidence: Double
    public var p10Confidence: Double
    public var p50Confidence: Double
    public var p90Confidence: Double
    public var estimatedTimeOffset: Double
    public var offsetVariance: Double
}

public struct V2SceneEvaluation: Codable, Sendable {
    public var pairID: String
    public var sceneID: String
    public var tags: [String]
    public var frameCount: Int
    public var alignmentConfidence: Double
    public var referenceLuminance: V2Percentiles
    public var generatedLuminance: V2Percentiles
    public var metrics: V2MetricBreakdown
    public var failures: [String]
}

public struct V2VideoEvaluation: Codable, Sendable {
    public var pairID: String
    public var split: DatasetSplit
    public var frameCount: Int
    public var sceneCount: Int
    public var alignment: V2AlignmentStatistics
    public var categories: [String]
    public var metrics: V2MetricBreakdown
    public var scenes: [V2SceneEvaluation]
}

public struct V2DatasetEvaluation: Codable, Sendable {
    public var label: String
    public var split: DatasetSplit
    public var videoCount: Int
    public var frameCount: Int
    public var sceneCount: Int
    public var metrics: V2MetricBreakdown
    public var videos: [V2VideoEvaluation]
}

public struct V2CandidateEvaluation: Codable, Sendable {
    public var id: String
    public var stage: String
    public var parameters: CalibrationParameters
    public var tune: V2DatasetEvaluation?
    public var validation: V2DatasetEvaluation?
    public var constraintsPassed: Bool
    public var stabilityScore: Double?
    public var notes: [String]

    public init(
        id: String,
        stage: String,
        parameters: CalibrationParameters,
        tune: V2DatasetEvaluation?,
        validation: V2DatasetEvaluation?,
        constraintsPassed: Bool,
        stabilityScore: Double?,
        notes: [String]
    ) {
        self.id = id
        self.stage = stage
        self.parameters = parameters
        self.tune = tune
        self.validation = validation
        self.constraintsPassed = constraintsPassed
        self.stabilityScore = stabilityScore
        self.notes = notes
    }
}

public struct V2AlignmentSensitivityPoint: Codable, Sendable {
    public var threshold: Double
    public var baselineObjective: Double?
    public var v1Objective: Double?
    public var candidateObjective: Double?
    public var candidateVsV1ImprovementPercent: Double?
    public var evaluatedFrames: Int
}

public struct V2AlignmentSensitivityReport: Codable, Sendable {
    public var split: DatasetSplit
    public var points: [V2AlignmentSensitivityPoint]
    public var robust: Bool
    public var notes: [String]
}

public struct V2BootstrapComparison: Codable, Sendable {
    public var comparison: String
    public var videoCount: Int
    public var resamples: Int
    public var meanImprovementPercent: Double
    public var medianImprovementPercent: Double
    public var lower95Percent: Double
    public var upper95Percent: Double
    public var probabilityCandidateBetter: Double
    public var statisticallyLimited: Bool
}

public struct V2BootstrapReport: Codable, Sendable {
    public var comparisons: [V2BootstrapComparison]
    public var notes: [String]
}

public struct V2SensitivityPoint: Codable, Sendable {
    public var parameter: String
    public var perturbationPercent: Double
    public var objective: Double
    public var deltaPercent: Double
}

public struct V2SensitivityReport: Codable, Sendable {
    public var baselineObjective: Double
    public var points: [V2SensitivityPoint]
    public var maximumAbsoluteDeltaPercent: Double
    public var plateauLike: Bool
}

public struct V2CategoryResult: Codable, Sendable {
    public var category: String
    public var videoCount: Int
    public var defaultObjective: Double
    public var v1Objective: Double
    public var candidateObjective: Double
    public var candidateVsV1ImprovementPercent: Double
}

public struct V2DiagnosticPoint: Codable, Sendable {
    public var x: Double
    public var reference: Double
    public var defaultBaseline: Double
    public var calibratedV1: Double
    public var candidateV2: Double
}

public struct V2Diagnostics: Codable, Sendable {
    public var luminanceMapping: [V2DiagnosticPoint]
    public var percentileCurves: [V2DiagnosticPoint]
    public var hueErrorByLuminance: [V2DiagnosticPoint]
    public var chromaErrorByLuminance: [V2DiagnosticPoint]
    public var saturationRatioByLuminance: [V2DiagnosticPoint]
}

public struct V2AuditEntry: Codable, Sendable {
    public var group: String
    public var status: String
    public var pairID: String?
    public var sdrPath: String?
    public var hdrPath: String?
    public var sdrMetadata: [String: String]
    public var hdrMetadata: [String: String]
    public var warnings: [String]
}

public struct V2DatasetAudit: Codable, Sendable {
    public var rootPath: String
    public var generatedAt: String
    public var entries: [V2AuditEntry]
    public var validPairCount: Int
    public var rejectedGroupCount: Int
}

public struct V2SplitDocument: Codable, Sendable {
    public var splitSeed: UInt64
    public var algorithm: String
    public var tune: [String]
    public var validation: [String]
    public var frozen: [String]
    public var frozenAccessPolicy: String
}

public struct V2Reproducibility: Codable, Sendable {
    public var gitCommit: String
    public var buildMode: String
    public var hardware: String
    public var operatingSystem: String
    public var swiftVersion: String
    public var ffmpegVersion: String
    public var datasetManifestSHA256: String
    public var splitSeed: UInt64
    public var searchSeed: UInt64
    public var globalCandidates: Int
    public var localCandidates: Int
    public var bounds: V2ParameterBounds
    public var weights: V2ObjectiveWeights
    public var alignmentThresholds: [Double]
}

public struct V2FinalReport: Codable, Sendable {
    public var version: String
    public var generatedAt: String
    public var reproducibility: V2Reproducibility
    public var split: V2SplitDocument
    public var defaultTune: V2DatasetEvaluation
    public var v1Tune: V2DatasetEvaluation
    public var candidateTune: V2DatasetEvaluation?
    public var defaultValidation: V2DatasetEvaluation
    public var v1Validation: V2DatasetEvaluation
    public var candidateValidation: V2DatasetEvaluation?
    public var defaultFrozen: V2DatasetEvaluation?
    public var v1Frozen: V2DatasetEvaluation?
    public var candidateFrozen: V2DatasetEvaluation?
    public var globalCandidates: [V2CandidateEvaluation]
    public var localCandidates: [V2CandidateEvaluation]
    public var validationCandidates: [V2CandidateEvaluation]
    public var selectedParameters: CalibrationParameters?
    public var alignmentSensitivity: [V2AlignmentSensitivityReport]
    public var bootstrap: V2BootstrapReport?
    public var sensitivity: V2SensitivityReport?
    public var categories: [V2CategoryResult]
    public var diagnostics: V2Diagnostics?
    public var verdict: CalibrationV2Verdict
    public var promotionReasons: [String]
    public var limitations: [String]
}

public final class FrozenIsolationGuard {
    private var selectionFinalized = false
    private var frozenEvaluated = false

    public init() {}

    public func authorize(_ split: DatasetSplit) throws {
        if split == .frozen && !selectionFinalized {
            throw CalibrationError.invalidCandidate("frozen split access attempted before final selection")
        }
    }

    public func finalizeSelection() {
        selectionFinalized = true
    }

    public func markFrozenEvaluated() throws {
        guard selectionFinalized, !frozenEvaluated else {
            throw CalibrationError.invalidCandidate("frozen split evaluated more than once or before selection")
        }
        frozenEvaluated = true
    }
}
