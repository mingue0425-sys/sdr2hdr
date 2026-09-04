import CoreMedia
import Foundation
import HDRCore

public enum DatasetSplit: String, Codable, CaseIterable, Sendable {
    case tune
    case validation
    case frozen
}

public enum ExpectedRelation: String, Codable, Sendable {
    case sameMaster = "same_master"
    case sameSource = "same_source"
    case sameContentDifferentGrade = "same_content_different_grade"
    case relatedContent = "related_content"
    case unknown
}

public struct PairManifest: Codable, Sendable {
    public var version: Int
    public var pairs: [PairRecord]

    public init(version: Int = 1, pairs: [PairRecord]) {
        self.version = version
        self.pairs = pairs
    }

    public static func load(from url: URL) throws -> PairManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PairManifest.self, from: data)
    }
}

public struct PairRecord: Codable, Hashable, Sendable {
    public var id: String
    public var sdr: String
    public var hdr: String
    public var license: String
    public var source: String
    public var expectedRelation: ExpectedRelation
    public var notes: String?
    public var split: DatasetSplit

    public init(
        id: String,
        sdr: String,
        hdr: String,
        license: String,
        source: String,
        expectedRelation: ExpectedRelation = .sameMaster,
        notes: String? = nil,
        split: DatasetSplit
    ) {
        self.id = id
        self.sdr = sdr
        self.hdr = hdr
        self.license = license
        self.source = source
        self.expectedRelation = expectedRelation
        self.notes = notes
        self.split = split
    }

    public func resolvedURLs(relativeTo manifestURL: URL) -> (sdr: URL, hdr: URL) {
        let base = manifestURL.deletingLastPathComponent().standardizedFileURL
        func resolve(_ path: String) -> URL {
            let variants = [
                path,
                path.precomposedStringWithCanonicalMapping,
                path.decomposedStringWithCanonicalMapping
            ]
            let urls = variants.map { variant -> URL in
                if variant.hasPrefix("/") {
                    return URL(fileURLWithPath: variant).standardizedFileURL
                }
                return base.appendingPathComponent(variant).standardizedFileURL
            }
            return urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) ?? urls[0]
        }
        return (resolve(sdr), resolve(hdr))
    }
}

public enum ReferenceTransfer: String, Codable, Hashable, Sendable {
    case pq
    case hlg
    case unknown

    /// Parse a raw transfer label into the one canonical HDR semantic
    /// category used by calibration, coverage, and metadata validation.
    ///
    /// The raw label is deliberately reduced only by case and benign
    /// separators.  Classification is then an exact-token match so a value
    /// such as `pqrst` or `foo2084bar` remains unknown.
    public static func parse(_ rawValue: String?) -> Self {
        let normalized = normalizedTransferToken(rawValue)
        switch normalized {
        case "pq", "st2084", "smpte2084", "smptest2084", "smptest2084pq", "itur2100pq":
            return .pq
        case "hlg", "aribstdb67", "b67", "itur2100hlg", "aribstdb67/hlg", "hlg/aribstdb67":
            return .hlg
        default:
            return .unknown
        }
    }

    /// Stable display/coverage spelling for the canonical semantic category.
    public var canonicalName: String {
        switch self {
        case .pq: return "PQ"
        case .hlg: return "HLG"
        case .unknown: return "UNKNOWN"
        }
    }

    private static func normalizedTransferToken(_ rawValue: String?) -> String {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "-_"))
        return (rawValue ?? "").lowercased().unicodeScalars
            .filter { !separators.contains($0) }
            .map(String.init)
            .joined()
    }
}

public struct ColorMetadataSummary: Codable, Equatable, Sendable {
    public var primaries: String?
    public var transfer: String?
    public var matrix: String?
    public var range: String?
    public var bitDepth: Int?
    public var masteringPeakNits: Float?
    public var maxCLL: Float?
    public var maxFALL: Float?

    public init(
        primaries: String? = nil,
        transfer: String? = nil,
        matrix: String? = nil,
        range: String? = nil,
        bitDepth: Int? = nil,
        masteringPeakNits: Float? = nil,
        maxCLL: Float? = nil,
        maxFALL: Float? = nil
    ) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.range = range
        self.bitDepth = bitDepth
        self.masteringPeakNits = masteringPeakNits
        self.maxCLL = maxCLL
        self.maxFALL = maxFALL
    }

    public var referenceTransfer: ReferenceTransfer {
        ReferenceTransfer.parse(transfer)
    }

    public var isHDRLike: Bool {
        (primaries ?? "").contains("2020") && referenceTransfer != .unknown
    }
}

public struct VideoMetadata: Codable, Equatable, Sendable {
    public var path: String
    public var durationSeconds: Double
    public var frameRate: Double
    public var frameCount: Int?
    public var width: Int
    public var height: Int
    public var codec: String?
    public var pixelFormat: String?
    public var audioTrackCount: Int
    public var color: ColorMetadataSummary

    public init(
        path: String,
        durationSeconds: Double,
        frameRate: Double,
        frameCount: Int?,
        width: Int,
        height: Int,
        codec: String?,
        pixelFormat: String?,
        audioTrackCount: Int,
        color: ColorMetadataSummary
    ) {
        self.path = path
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.width = width
        self.height = height
        self.codec = codec
        self.pixelFormat = pixelFormat
        self.audioTrackCount = audioTrackCount
        self.color = color
    }
}

public enum PairStatus: String, Codable, Sendable {
    case pairValid = "PAIR_VALID"
    case pairNeedsAlignment = "PAIR_NEEDS_ALIGNMENT"
    case pairDifferentEdit = "PAIR_DIFFERENT_EDIT"
    case pairInvalidHDR = "PAIR_INVALID_HDR"
    case pairUncertain = "PAIR_UNCERTAIN"
    case missingFile = "MISSING_FILE"
}

public struct AlignmentQuality: Codable, Equatable, Sendable {
    public var status: String
    public var medianConfidence: Double
    public var coarseOffsetSeconds: Double
    public var matchedFrames: Int
    public var rejectedFrames: Int
    public var notes: [String]

    public init(
        status: String = "UNALIGNED",
        medianConfidence: Double = 0,
        coarseOffsetSeconds: Double = 0,
        matchedFrames: Int = 0,
        rejectedFrames: Int = 0,
        notes: [String] = []
    ) {
        self.status = status
        self.medianConfidence = medianConfidence
        self.coarseOffsetSeconds = coarseOffsetSeconds
        self.matchedFrames = matchedFrames
        self.rejectedFrames = rejectedFrames
        self.notes = notes
    }
}

public struct PairValidation: Codable, Sendable {
    public var pair: PairRecord
    public var sdrMetadata: VideoMetadata?
    public var hdrMetadata: VideoMetadata?
    public var status: PairStatus
    public var alignment: AlignmentQuality?
    public var notes: [String]

    public init(
        pair: PairRecord,
        sdrMetadata: VideoMetadata? = nil,
        hdrMetadata: VideoMetadata? = nil,
        status: PairStatus,
        alignment: AlignmentQuality? = nil,
        notes: [String] = []
    ) {
        self.pair = pair
        self.sdrMetadata = sdrMetadata
        self.hdrMetadata = hdrMetadata
        self.status = status
        self.alignment = alignment
        self.notes = notes
    }
}

public struct DatasetReport: Codable, Sendable {
    public var manifestPath: String
    public var generatedAt: String
    public var pairs: [PairValidation]

    public init(manifestPath: String, pairs: [PairValidation]) {
        self.manifestPath = manifestPath
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.pairs = pairs
    }

    public var validPairs: [PairValidation] {
        pairs.filter { $0.status == .pairValid || $0.status == .pairNeedsAlignment }
    }

    public var counts: [String: Int] {
        Dictionary(grouping: pairs, by: { $0.status.rawValue }).mapValues(\.count)
    }
}

public struct FrameDescriptor: Codable, Equatable, Sendable {
    public var timestampSeconds: Double
    public var meanLuma: Float
    public var variance: Float
    public var histogram: [Float]
    public var edgeEnergy: Float

    public init(
        timestampSeconds: Double,
        meanLuma: Float,
        variance: Float,
        histogram: [Float],
        edgeEnergy: Float
    ) {
        self.timestampSeconds = timestampSeconds
        self.meanLuma = meanLuma
        self.variance = variance
        self.histogram = histogram
        self.edgeEnergy = edgeEnergy
    }
}

public struct MatchedFrame: Codable, Equatable, Sendable {
    public var sdrIndex: Int
    public var hdrIndex: Int
    /// Sequence positions are the only domain valid for scene membership and
    /// temporal ordering. The source indices remain for PTS/source tracing.
    public var sdrSequencePosition: Int?
    public var hdrSequencePosition: Int?
    public var sdrTimeSeconds: Double
    public var hdrTimeSeconds: Double
    public var confidence: Double

    public init(
        sdrIndex: Int,
        hdrIndex: Int,
        sdrSequencePosition: Int? = nil,
        hdrSequencePosition: Int? = nil,
        sdrTimeSeconds: Double,
        hdrTimeSeconds: Double,
        confidence: Double
    ) {
        self.sdrIndex = sdrIndex
        self.hdrIndex = hdrIndex
        self.sdrSequencePosition = sdrSequencePosition
        self.hdrSequencePosition = hdrSequencePosition
        self.sdrTimeSeconds = sdrTimeSeconds
        self.hdrTimeSeconds = hdrTimeSeconds
        self.confidence = confidence
    }
}

public struct AlignmentResult: Codable, Sendable {
    public var status: String
    public var coarseOffsetSeconds: Double
    public var matches: [MatchedFrame]
    public var rejectedFrames: Int
    public var medianConfidence: Double
    public var notes: [String]
    public var secondBestOffsetSeconds: Double?
    public var bestVersusSecondMargin: Double?
    public var perWindowOffsets: [Double]?
    public var offsetDriftSeconds: Double?
    public var confidenceQuantiles: V6ConfidenceQuantiles?
    public var matcherConfigurationHash: String?

    public init(
        status: String,
        coarseOffsetSeconds: Double,
        matches: [MatchedFrame],
        rejectedFrames: Int,
        medianConfidence: Double,
        notes: [String] = [],
        secondBestOffsetSeconds: Double? = nil,
        bestVersusSecondMargin: Double? = nil,
        perWindowOffsets: [Double]? = nil,
        offsetDriftSeconds: Double? = nil,
        confidenceQuantiles: V6ConfidenceQuantiles? = nil,
        matcherConfigurationHash: String? = nil
    ) {
        self.status = status
        self.coarseOffsetSeconds = coarseOffsetSeconds
        self.matches = matches
        self.rejectedFrames = rejectedFrames
        self.medianConfidence = medianConfidence
        self.notes = notes
        self.secondBestOffsetSeconds = secondBestOffsetSeconds
        self.bestVersusSecondMargin = bestVersusSecondMargin
        self.perWindowOffsets = perWindowOffsets
        self.offsetDriftSeconds = offsetDriftSeconds
        self.confidenceQuantiles = confidenceQuantiles
        self.matcherConfigurationHash = matcherConfigurationHash
    }
}

public struct PairAlignmentReport: Codable, Sendable {
    public var pairID: String
    public var result: AlignmentResult

    public init(pairID: String, result: AlignmentResult) {
        self.pairID = pairID
        self.result = result
    }
}

public struct AlignmentReportDocument: Codable, Sendable {
    public var manifestPath: String
    public var pairs: [PairAlignmentReport]

    public init(manifestPath: String, pairs: [PairAlignmentReport]) {
        self.manifestPath = manifestPath
        self.pairs = pairs
    }
}

public enum ErrorFamily: String, Codable, CaseIterable, Sendable {
    case underExpandedHighlights = "UNDER_EXPANDED_HIGHLIGHTS"
    case overExpandedHighlights = "OVER_EXPANDED_HIGHLIGHTS"
    case midtonesTooDark = "MIDTONES_TOO_DARK"
    case midtonesTooBright = "MIDTONES_TOO_BRIGHT"
    case shadowLift = "SHADOW_LIFT"
    case shadowCrush = "SHADOW_CRUSH"
    case saturationExcess = "SATURATION_EXCESS"
    case saturationLoss = "SATURATION_LOSS"
    case hueShift = "HUE_SHIFT"
    case gamutClip = "GAMUT_CLIP"
    case temporalPumping = "TEMPORAL_PUMPING"
    case diffuseWhiteTooLow = "DIFFUSE_WHITE_TOO_LOW"
    case diffuseWhiteTooHigh = "DIFFUSE_WHITE_TOO_HIGH"
    case referenceGradeMismatch = "REFERENCE_GRADE_MISMATCH"
    case alignmentUncertain = "ALIGNMENT_UNCERTAIN"
    case unrecoverableFromSDR = "UNRECOVERABLE_FROM_SDR"
}

public struct MetricVector: Codable, Sendable {
    public var mean: Double
    public var median: Double
    public var p50: Double
    public var p75: Double
    public var p90: Double
    public var p95: Double
    public var p99: Double
    public var p995: Double
    public var p999: Double
    public var robustMax: Double

    public init(values: [Double]) {
        let finite = values.filter(\.isFinite).sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !finite.isEmpty else { return .nan }
            let index = min(max(Int(Double(finite.count - 1) * fraction), 0), finite.count - 1)
            return finite[index]
        }
        mean = finite.isEmpty ? .nan : finite.reduce(0, +) / Double(finite.count)
        median = percentile(0.5)
        p50 = percentile(0.5)
        p75 = percentile(0.75)
        p90 = percentile(0.90)
        p95 = percentile(0.95)
        p99 = percentile(0.99)
        p995 = percentile(0.995)
        p999 = percentile(0.999)
        robustMax = percentile(0.999)
    }
}

public struct SceneMetrics: Codable, Sendable {
    public var pairID: String
    public var sceneID: String
    public var tags: [String]
    public var alignmentConfidence: Double
    public var frameCount: Int
    public var referenceLuminance: MetricVector
    public var generatedLuminance: MetricVector
    public var luminanceError: Double
    public var highlightError: Double
    public var diffuseWhiteError: Double
    public var shadowError: Double
    public var colorError: Double
    public var temporalError: Double
    public var structureError: Double
    public var clippedRatio: Double
    public var errorFamilies: [ErrorFamily]

    public init(
        pairID: String,
        sceneID: String,
        tags: [String],
        alignmentConfidence: Double,
        frameCount: Int,
        referenceLuminance: MetricVector,
        generatedLuminance: MetricVector,
        luminanceError: Double,
        highlightError: Double,
        diffuseWhiteError: Double,
        shadowError: Double,
        colorError: Double,
        temporalError: Double,
        structureError: Double,
        clippedRatio: Double,
        errorFamilies: [ErrorFamily]
    ) {
        self.pairID = pairID
        self.sceneID = sceneID
        self.tags = tags
        self.alignmentConfidence = alignmentConfidence
        self.frameCount = frameCount
        self.referenceLuminance = referenceLuminance
        self.generatedLuminance = generatedLuminance
        self.luminanceError = luminanceError
        self.highlightError = highlightError
        self.diffuseWhiteError = diffuseWhiteError
        self.shadowError = shadowError
        self.colorError = colorError
        self.temporalError = temporalError
        self.structureError = structureError
        self.clippedRatio = clippedRatio
        self.errorFamilies = errorFamilies
    }
}

public struct DatasetMetrics: Codable, Sendable {
    public var split: DatasetSplit
    public var pairCount: Int
    public var sceneCount: Int
    public var frameCount: Int
    public var objective: Double
    public var luminanceError: Double
    public var highlightError: Double
    public var shadowError: Double
    public var colorError: Double
    public var temporalError: Double
    public var sceneMetrics: [SceneMetrics]

    public init(
        split: DatasetSplit,
        pairCount: Int,
        sceneCount: Int,
        frameCount: Int,
        objective: Double,
        luminanceError: Double,
        highlightError: Double,
        shadowError: Double,
        colorError: Double,
        temporalError: Double,
        sceneMetrics: [SceneMetrics]
    ) {
        self.split = split
        self.pairCount = pairCount
        self.sceneCount = sceneCount
        self.frameCount = frameCount
        self.objective = objective
        self.luminanceError = luminanceError
        self.highlightError = highlightError
        self.shadowError = shadowError
        self.colorError = colorError
        self.temporalError = temporalError
        self.sceneMetrics = sceneMetrics
    }
}

public struct CalibrationParameters: Codable, Equatable, Sendable {
    public var paperWhiteNits: Float
    public var peakNits: Float
    public var highlightStrength: Float
    public var contrastStrength: Float
    public var saturationCompensation: Float
    public var shadowProtection: Float
    public var temporalStability: Float
    public var displayHeadroom: Float
    /// nil/0 preserves the frozen V2 analytical curve; 1 selects the repaired
    /// V3 shadow architecture. Optional keeps V1/V2 JSON artifacts decodable.
    public var toneCurveRevision: UInt32?

    public init(
        paperWhiteNits: Float,
        peakNits: Float,
        highlightStrength: Float,
        contrastStrength: Float,
        saturationCompensation: Float,
        shadowProtection: Float,
        temporalStability: Float,
        displayHeadroom: Float,
        toneCurveRevision: UInt32? = nil
    ) {
        self.paperWhiteNits = paperWhiteNits
        self.peakNits = peakNits
        self.highlightStrength = highlightStrength
        self.contrastStrength = contrastStrength
        self.saturationCompensation = saturationCompensation
        self.shadowProtection = shadowProtection
        self.temporalStability = temporalStability
        self.displayHeadroom = displayHeadroom
        self.toneCurveRevision = toneCurveRevision
    }

    public init(configuration: HDRConfiguration) {
        paperWhiteNits = configuration.paperWhiteNits
        peakNits = configuration.peakNits
        highlightStrength = configuration.highlightStrength
        contrastStrength = configuration.contrastStrength
        saturationCompensation = configuration.saturationCompensation
        shadowProtection = configuration.shadowProtection
        temporalStability = configuration.temporalStability
        displayHeadroom = configuration.masteringHeadroom
        toneCurveRevision = configuration.toneCurveRevision.rawValue
    }

    public func configuration() throws -> HDRConfiguration {
        var value = HDRConfiguration(
            paperWhiteNits: paperWhiteNits,
            peakNits: peakNits,
            highlightStrength: highlightStrength,
            contrastStrength: contrastStrength,
            saturationCompensation: saturationCompensation,
            shadowProtection: shadowProtection,
            temporalStability: temporalStability,
            outputMode: .edr,
            displayHeadroom: displayHeadroom,
            inputFallbackPolicy: .bt709VideoRange
        )
        value.toneCurveRevision = HDRToneCurveRevision(rawValue: toneCurveRevision ?? 0) ?? .legacyV2
        value.masteringHeadroom = displayHeadroom
        return try value.validated()
    }
}

public struct ExperimentConfig: Codable, Sendable {
    public var seed: UInt64
    public var candidateCount: Int
    public var maxFramesPerScene: Int
    public var alignmentConfidenceThreshold: Double
    public var referenceTargetPeakNits: Float
    public var allowHLGModel: Bool

    public init(
        seed: UInt64 = 42,
        candidateCount: Int = 16,
        maxFramesPerScene: Int = 8,
        alignmentConfidenceThreshold: Double = 0.60,
        referenceTargetPeakNits: Float = 1_000,
        allowHLGModel: Bool = true
    ) {
        self.seed = seed
        self.candidateCount = candidateCount
        self.maxFramesPerScene = maxFramesPerScene
        self.alignmentConfidenceThreshold = alignmentConfidenceThreshold
        self.referenceTargetPeakNits = referenceTargetPeakNits
        self.allowHLGModel = allowHLGModel
    }
}

public enum CalibrationVerdict: String, Codable, Sendable {
    case promoteCalibratedV1 = "PROMOTE_CALIBRATED_V1"
    case validationOnly = "VALIDATION_ONLY"
    case globalTuningInsufficient = "GLOBAL_TUNING_INSUFFICIENT"
    case datasetInsufficient = "DATASET_INSUFFICIENT"
    case alignmentUnreliable = "ALIGNMENT_UNRELIABLE"
    case referenceDataUnusable = "REFERENCE_DATA_UNUSABLE"
}

public struct CalibrationReport: Codable, Sendable {
    public var experimentID: String
    public var experiment: ExperimentConfig
    public var parameterSpace: ParameterSpace
    public var baselineParameters: CalibrationParameters
    public var baseline: DatasetMetrics?
    public var baselineValidation: DatasetMetrics?
    public var baselineFrozenTest: DatasetMetrics?
    public var candidates: [CandidateResult]
    public var selectedCandidate: CandidateResult?
    public var validation: DatasetMetrics?
    public var frozenTest: DatasetMetrics?
    public var verdict: CalibrationVerdict
    public var notes: [String]

    public init(
        experimentID: String,
        experiment: ExperimentConfig = ExperimentConfig(),
        parameterSpace: ParameterSpace = ParameterSpace(),
        baselineParameters: CalibrationParameters,
        baseline: DatasetMetrics? = nil,
        baselineValidation: DatasetMetrics? = nil,
        baselineFrozenTest: DatasetMetrics? = nil,
        candidates: [CandidateResult] = [],
        selectedCandidate: CandidateResult? = nil,
        validation: DatasetMetrics? = nil,
        frozenTest: DatasetMetrics? = nil,
        verdict: CalibrationVerdict,
        notes: [String] = []
    ) {
        self.experimentID = experimentID
        self.experiment = experiment
        self.parameterSpace = parameterSpace
        self.baselineParameters = baselineParameters
        self.baseline = baseline
        self.baselineValidation = baselineValidation
        self.baselineFrozenTest = baselineFrozenTest
        self.candidates = candidates
        self.selectedCandidate = selectedCandidate
        self.validation = validation
        self.frozenTest = frozenTest
        self.verdict = verdict
        self.notes = notes
    }
}

public struct CandidateResult: Codable, Sendable {
    public var id: String
    public var parameters: CalibrationParameters
    public var tune: DatasetMetrics?
    public var validation: DatasetMetrics?
    public var frozen: DatasetMetrics?
    public var constraintsPassed: Bool
    public var notes: [String]

    public init(
        id: String,
        parameters: CalibrationParameters,
        tune: DatasetMetrics? = nil,
        validation: DatasetMetrics? = nil,
        frozen: DatasetMetrics? = nil,
        constraintsPassed: Bool = false,
        notes: [String] = []
    ) {
        self.id = id
        self.parameters = parameters
        self.tune = tune
        self.validation = validation
        self.frozen = frozen
        self.constraintsPassed = constraintsPassed
        self.notes = notes
    }
}

public enum CalibrationError: Error, LocalizedError {
    case invalidManifest(String)
    case noValidPairs
    case unsupportedReference(String)
    case metadataUnavailable(String)
    case alignmentFailed(String)
    case decodeFailed(String)
    case outputWriteFailed(String)
    case invalidCandidate(String)
    case incompleteEvaluation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): return "invalid manifest: \(reason)"
        case .noValidPairs: return "no valid SDR/HDR pairs available"
        case .unsupportedReference(let reason): return "unsupported HDR reference: \(reason)"
        case .metadataUnavailable(let reason): return "metadata unavailable: \(reason)"
        case .alignmentFailed(let reason): return "alignment failed: \(reason)"
        case .decodeFailed(let reason): return "decode failed: \(reason)"
        case .outputWriteFailed(let reason): return "output write failed: \(reason)"
        case .invalidCandidate(let reason): return "invalid candidate: \(reason)"
        case .incompleteEvaluation(let reason): return "incomplete evaluation: \(reason)"
    }
}
}
