import Foundation

public enum V6SemanticComparisonRule: String, Codable, Hashable, Sendable {
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
}

/// Numeric metadata interpretations used only when the fallback decoder has
/// to reconstruct a CoreMedia transfer attachment from authoritative stream
/// metadata. These values affect decoded preparation samples and are therefore
/// part of the preparation identity.
public struct V6DecoderMetadataSemanticConfiguration: Codable, Hashable, Sendable {
    public let gamma22: Double
    public let gamma28: Double
    public let semanticVersion: String

    public init(
        gamma22: Double = 2.2,
        gamma28: Double = 2.8,
        semanticVersion: String = "ffmpeg-metadata-transfer-mapping-v1"
    ) {
        self.gamma22 = gamma22
        self.gamma28 = gamma28
        self.semanticVersion = semanticVersion
    }

    public static let v6 = V6DecoderMetadataSemanticConfiguration()

    public var isValid: Bool {
        gamma22.isFinite && gamma28.isFinite && gamma22 > 0 && gamma28 > 0 &&
            !semanticVersion.isEmpty
    }
}

/// Exact frame-timeline and proxy-sampling rules used by FrameReader and its
/// FFmpeg fallback.  These are preparation semantics: changing rounding,
/// frame-rate selection, filter, or timestamp construction can change the
/// frames that enter alignment and therefore the prepared plan.
public struct V6FrameSamplingSemanticConfiguration: Codable, Hashable, Sendable {
    public let sourceRateSelectionRule: String
    public let sourcePositionRule: String
    public let sourceTimelineMaximum: Int64
    public let sourcePositionRoundingRule: String
    public let distributedFrameCountRule: String
    public let strideRoundingRule: String
    public let minimumStride: Int
    public let proxyHeightRoundingRule: String
    public let proxyHeightMinimum: Int
    public let ffmpegDistributedFPSRule: String
    public let ffmpegOutputFPSRule: String
    public let ffmpegFPSRoundingRule: String
    public let ffmpegScaleFilter: String
    public let timestampRule: String
    public let timestampTimescale: Int32

    public init(
        sourceRateSelectionRule: String = "max-source-and-output-rate",
        sourcePositionRule: String = "start-seconds-times-source-rate-plus-output-index-times-source-step",
        sourceTimelineMaximum: Int64 = Int64(Int32.max),
        sourcePositionRoundingRule: String = "nearest-integer-away-from-zero",
        distributedFrameCountRule: String = "duration-times-nominal-rate",
        strideRoundingRule: String = "ceil",
        minimumStride: Int = 1,
        proxyHeightRoundingRule: String = "nearest-integer-then-even-with-minimum",
        proxyHeightMinimum: Int = 2,
        ffmpegDistributedFPSRule: String = "max-minimum-fps-and-max-frames-divided-by-duration",
        ffmpegOutputFPSRule: String = "min-requested-and-nominal-when-positive",
        ffmpegFPSRoundingRule: String = "up",
        ffmpegScaleFilter: String = "bicubic",
        timestampRule: String = "start-seconds-plus-output-index-divided-by-output-fps",
        timestampTimescale: Int32 = 1_000
    ) {
        self.sourceRateSelectionRule = sourceRateSelectionRule
        self.sourcePositionRule = sourcePositionRule
        self.sourceTimelineMaximum = sourceTimelineMaximum
        self.sourcePositionRoundingRule = sourcePositionRoundingRule
        self.distributedFrameCountRule = distributedFrameCountRule
        self.strideRoundingRule = strideRoundingRule
        self.minimumStride = minimumStride
        self.proxyHeightRoundingRule = proxyHeightRoundingRule
        self.proxyHeightMinimum = proxyHeightMinimum
        self.ffmpegDistributedFPSRule = ffmpegDistributedFPSRule
        self.ffmpegOutputFPSRule = ffmpegOutputFPSRule
        self.ffmpegFPSRoundingRule = ffmpegFPSRoundingRule
        self.ffmpegScaleFilter = ffmpegScaleFilter
        self.timestampRule = timestampRule
        self.timestampTimescale = timestampTimescale
    }

    public static let v6 = V6FrameSamplingSemanticConfiguration()

    public var isValid: Bool {
        sourceTimelineMaximum > 0 && minimumStride > 0 && proxyHeightMinimum > 0 &&
            timestampTimescale > 0 &&
            sourceRateSelectionRule == "max-source-and-output-rate" &&
            sourcePositionRule == "start-seconds-times-source-rate-plus-output-index-times-source-step" &&
            sourcePositionRoundingRule == "nearest-integer-away-from-zero" &&
            distributedFrameCountRule == "duration-times-nominal-rate" &&
            strideRoundingRule == "ceil" &&
            proxyHeightRoundingRule == "nearest-integer-then-even-with-minimum" &&
            ffmpegDistributedFPSRule == "max-minimum-fps-and-max-frames-divided-by-duration" &&
            ffmpegOutputFPSRule == "min-requested-and-nominal-when-positive" &&
            ffmpegFPSRoundingRule == "up" && ffmpegScaleFilter == "bicubic" &&
            timestampRule == "start-seconds-plus-output-index-divided-by-output-fps"
    }

    public func sourceRate(sourceFramesPerSecond: Double, outputFramesPerSecond: Double) -> Double {
        max(sourceFramesPerSecond, outputFramesPerSecond)
    }

    public func sourceFrameIndex(
        startSeconds: Double,
        outputIndex: Int,
        outputFramesPerSecond: Double,
        sourceFramesPerSecond: Double
    ) -> Int? {
        guard startSeconds.isFinite, startSeconds >= 0, outputIndex >= 0,
              outputFramesPerSecond.isFinite, outputFramesPerSecond > 0,
              sourceFramesPerSecond.isFinite, sourceFramesPerSecond > 0 else { return nil }
        let rate = sourceRate(
            sourceFramesPerSecond: sourceFramesPerSecond,
            outputFramesPerSecond: outputFramesPerSecond
        )
        let position = startSeconds * rate +
            Double(outputIndex) * rate / outputFramesPerSecond
        guard position.isFinite, position >= 0,
              position <= Double(sourceTimelineMaximum) else { return nil }
        return Int(position.rounded())
    }

    public func proxyHeight(proxyWidth: Int, sourceWidth: Int, sourceHeight: Int) -> Int {
        let scaled = Double(proxyWidth) * Double(sourceHeight) / Double(max(sourceWidth, 1))
        return max(proxyHeightMinimum, Int(scaled.rounded()) / 2 * 2)
    }

    public func distributedFPS(
        maxFrames: Int,
        durationSeconds: Double,
        nominalFrameRate: Double,
        minimumFPS: Double
    ) -> Double {
        durationSeconds > 0
            ? max(minimumFPS, Double(maxFrames) / durationSeconds)
            : max(nominalFrameRate, minimumFPS)
    }

    public func timestamp(startSeconds: Double, outputIndex: Int, outputFPS: Double) -> Double {
        startSeconds + Double(outputIndex) / outputFPS
    }

    public func stride(estimatedFrames: Double, maximumFrames: Int) -> Int {
        guard estimatedFrames.isFinite, estimatedFrames > 0, maximumFrames > 0 else {
            return minimumStride
        }
        switch strideRoundingRule {
        case "ceil":
            return max(minimumStride, Int(ceil(estimatedFrames / Double(maximumFrames))))
        default:
            return minimumStride
        }
    }
}

/// Exact descriptor arithmetic and boundary rules used by the preparation
/// matcher.  The public descriptor weights below are not sufficient by
/// themselves: these rules also affect alignment evidence and scene cuts.
public struct V6DescriptorAlgorithmSemanticConfiguration: Codable, Hashable, Sendable {
    public let emptyHistogramBinValue: Double
    public let histogramOutOfBoundsValue: Double
    public let histogramValueMinimum: Double
    public let histogramValueMaximum: Double
    public let edgeEnergyMinimumWidth: Int
    public let edgeEnergyMinimumHeight: Int
    public let edgeEnergyComponentsPerCell: Int
    public let minimumCorrelationSampleCount: Int
    public let correlationDistanceScale: Double
    public let histogramDistanceClampRule: String

    public init(
        emptyHistogramBinValue: Double = 0,
        histogramOutOfBoundsValue: Double = 0,
        histogramValueMinimum: Double = 0,
        histogramValueMaximum: Double = 1,
        edgeEnergyMinimumWidth: Int = 1,
        edgeEnergyMinimumHeight: Int = 1,
        edgeEnergyComponentsPerCell: Int = 2,
        minimumCorrelationSampleCount: Int = 2,
        correlationDistanceScale: Double = 0.5,
        histogramDistanceClampRule: String = "clamp-to-empty-histogram-distance"
    ) {
        self.emptyHistogramBinValue = emptyHistogramBinValue
        self.histogramOutOfBoundsValue = histogramOutOfBoundsValue
        self.histogramValueMinimum = histogramValueMinimum
        self.histogramValueMaximum = histogramValueMaximum
        self.edgeEnergyMinimumWidth = edgeEnergyMinimumWidth
        self.edgeEnergyMinimumHeight = edgeEnergyMinimumHeight
        self.edgeEnergyComponentsPerCell = edgeEnergyComponentsPerCell
        self.minimumCorrelationSampleCount = minimumCorrelationSampleCount
        self.correlationDistanceScale = correlationDistanceScale
        self.histogramDistanceClampRule = histogramDistanceClampRule
    }

    public static let v6 = V6DescriptorAlgorithmSemanticConfiguration()

    public var isValid: Bool {
        let values = [
            emptyHistogramBinValue, histogramOutOfBoundsValue,
            histogramValueMinimum, histogramValueMaximum, correlationDistanceScale
        ]
        return values.allSatisfy(\.isFinite) &&
            histogramValueMinimum <= histogramValueMaximum &&
            edgeEnergyMinimumWidth > 0 && edgeEnergyMinimumHeight > 0 &&
            edgeEnergyComponentsPerCell > 0 && minimumCorrelationSampleCount > 0 &&
            correlationDistanceScale >= 0 &&
            histogramDistanceClampRule == "clamp-to-empty-histogram-distance"
    }
}

public struct V6DescriptorSemanticConfiguration: Codable, Hashable, Sendable {
    public let gridWidth: Int
    public let gridHeight: Int
    public let histogramBinCount: Int
    public let histogramShiftMinimum: Int
    public let histogramShiftMaximum: Int
    public let distanceWeights: [Double]
    public let alignmentDistanceWeights: [Double]
    public let spatialAlignmentDistanceWeights: [Double]
    public let boundedLogFloor: Double
    public let gridCorrelationEpsilon: Double
    public let emptyHistogramDistance: Double
    public let degenerateCorrelationDistance: Double
    public let correlationLowerBound: Double
    public let correlationUpperBound: Double
    public let minimumFFmpegSamplingFPS: Double
    public let algorithmSemantics: V6DescriptorAlgorithmSemanticConfiguration

    public init(
        gridWidth: Int = 64,
        gridHeight: Int = 36,
        histogramBinCount: Int = 16,
        histogramShiftMinimum: Int = -4,
        histogramShiftMaximum: Int = 4,
        distanceWeights: [Double] = [0.65, 0.20, 0.10, 0.05],
        alignmentDistanceWeights: [Double] = [0.72, 0.10, 0.10, 0.08],
        spatialAlignmentDistanceWeights: [Double] = [0.62, 0.20, 0.08, 0.05, 0.05],
        boundedLogFloor: Double = 1e-4,
        gridCorrelationEpsilon: Double = 1e-9,
        emptyHistogramDistance: Double = 1,
        degenerateCorrelationDistance: Double = 0.5,
        correlationLowerBound: Double = -1,
        correlationUpperBound: Double = 1,
        minimumFFmpegSamplingFPS: Double = 0.25,
        algorithmSemantics: V6DescriptorAlgorithmSemanticConfiguration = .v6
    ) {
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.histogramBinCount = histogramBinCount
        self.histogramShiftMinimum = histogramShiftMinimum
        self.histogramShiftMaximum = histogramShiftMaximum
        self.distanceWeights = distanceWeights
        self.alignmentDistanceWeights = alignmentDistanceWeights
        self.spatialAlignmentDistanceWeights = spatialAlignmentDistanceWeights
        self.boundedLogFloor = boundedLogFloor
        self.gridCorrelationEpsilon = gridCorrelationEpsilon
        self.emptyHistogramDistance = emptyHistogramDistance
        self.degenerateCorrelationDistance = degenerateCorrelationDistance
        self.correlationLowerBound = correlationLowerBound
        self.correlationUpperBound = correlationUpperBound
        self.minimumFFmpegSamplingFPS = minimumFFmpegSamplingFPS
        self.algorithmSemantics = algorithmSemantics
    }

    public static let v6 = V6DescriptorSemanticConfiguration()

    public var isValid: Bool {
        let weights = distanceWeights + alignmentDistanceWeights + spatialAlignmentDistanceWeights
        return gridWidth > 0 && gridHeight > 0 && histogramBinCount > 0 &&
            histogramShiftMinimum <= histogramShiftMaximum &&
            distanceWeights.count == 4 && alignmentDistanceWeights.count == 4 &&
            spatialAlignmentDistanceWeights.count == 5 &&
            weights.allSatisfy { $0.isFinite } &&
            abs(distanceWeights.reduce(0, +) - 1) <= 1e-12 &&
            abs(alignmentDistanceWeights.reduce(0, +) - 1) <= 1e-12 &&
            abs(spatialAlignmentDistanceWeights.reduce(0, +) - 1) <= 1e-12 &&
            boundedLogFloor.isFinite && boundedLogFloor > 0 &&
            gridCorrelationEpsilon.isFinite && gridCorrelationEpsilon > 0 &&
            emptyHistogramDistance.isFinite && emptyHistogramDistance >= 0 &&
            degenerateCorrelationDistance.isFinite && degenerateCorrelationDistance >= 0 &&
            correlationLowerBound.isFinite && correlationUpperBound.isFinite &&
            correlationLowerBound < correlationUpperBound &&
            minimumFFmpegSamplingFPS.isFinite && minimumFFmpegSamplingFPS > 0 &&
            algorithmSemantics.isValid
    }
}

/// The typed, immutable controls used by the V6 preparation path.  These are
/// deliberately value types: the same value is passed to production code and
/// encoded into the V4 semantic seal.
public struct V6SequenceValidationSemanticConfiguration: Codable, Hashable, Sendable {
    public let maximumSampleCount: Int
    public let histogramBinCount: Int
    public let maximumVariance: Double
    public let histogramTarget: Double
    public let histogramTolerance: Double
    public let timestampTolerance: Double
    public let signalMinimum: Double
    public let signalMaximum: Double
    public let maximumPairingWorkCells: Int

    public init(
        maximumSampleCount: Int = 512,
        histogramBinCount: Int = 16,
        maximumVariance: Double = 0.251,
        histogramTarget: Double = 1,
        histogramTolerance: Double = 0.001,
        timestampTolerance: Double = 1e-9,
        signalMinimum: Double = 0,
        signalMaximum: Double = 1,
        maximumPairingWorkCells: Int = 50_000_000
    ) {
        self.maximumSampleCount = maximumSampleCount
        self.histogramBinCount = histogramBinCount
        self.maximumVariance = maximumVariance
        self.histogramTarget = histogramTarget
        self.histogramTolerance = histogramTolerance
        self.timestampTolerance = timestampTolerance
        self.signalMinimum = signalMinimum
        self.signalMaximum = signalMaximum
        self.maximumPairingWorkCells = maximumPairingWorkCells
    }

    public static let v6 = V6SequenceValidationSemanticConfiguration()

    public var isValid: Bool {
        maximumSampleCount > 0 && histogramBinCount > 0 &&
            maximumVariance.isFinite && maximumVariance >= 0 &&
            histogramTarget.isFinite && histogramTolerance.isFinite && histogramTolerance >= 0 &&
            timestampTolerance.isFinite && timestampTolerance >= 0 &&
            signalMinimum.isFinite && signalMaximum.isFinite && signalMinimum <= signalMaximum &&
            maximumPairingWorkCells > 0
    }
}

public struct V6AlignmentSemanticConfiguration: Codable, Hashable, Sendable {
    public let minimumMatchedFrames: Int
    public let minimumMatchRatio: Double
    public let minimumP10Confidence: Double
    public let alignedMedianConfidence: Double
    public let p10QuantileFraction: Double
    public let secondBestExclusionSeconds: Double
    public let perWindowSampleDivisor: Int
    public let statusOffsetToleranceSeconds: Double
    public let maximumPairingDistanceSeconds: Double
    public let fallbackFrameRate: Double
    public let frameIntervalDistanceFactor: Double
    public let offsetStepDistanceFactor: Double
    public let offsetCandidateEndpointTolerance: Double
    public let quantileFractions: [Double]
    public let workBudgetPassCount: Int
    public let matchDecisionPriority: Int
    public let skipHDRDecisionPriority: Int
    public let skipSDRDecisionPriority: Int
    public let endDecisionPriority: Int
    public let confidenceCoverageLowerBound: Double
    public let confidenceCoverageUpperBound: Double
    public let offsetTieBreakRule: String
    public let offsetEnumerationRule: String
    public let windowMinimumSize: Int
    public let minimumRateForDistance: Double
    public let acceptedConfidenceComparison: V6SemanticComparisonRule
    public let rejectionConfidenceComparison: V6SemanticComparisonRule
    public let statusOffsetComparison: V6SemanticComparisonRule

    public init(
        minimumMatchedFrames: Int = 8,
        minimumMatchRatio: Double = 0.60,
        minimumP10Confidence: Double = 0.60,
        alignedMedianConfidence: Double = 0.70,
        p10QuantileFraction: Double = 0.10,
        secondBestExclusionSeconds: Double = 0.10,
        perWindowSampleDivisor: Int = 8,
        statusOffsetToleranceSeconds: Double = 0.01,
        maximumPairingDistanceSeconds: Double = 0.25,
        fallbackFrameRate: Double = 24,
        frameIntervalDistanceFactor: Double = 0.75,
        offsetStepDistanceFactor: Double = 0.55,
        offsetCandidateEndpointTolerance: Double = 1e-12,
        quantileFractions: [Double] = [0, 0.10, 0.25, 0.50, 0.75, 0.90, 1],
        workBudgetPassCount: Int = 3,
        matchDecisionPriority: Int = 3,
        skipHDRDecisionPriority: Int = 2,
        skipSDRDecisionPriority: Int = 1,
        endDecisionPriority: Int = 0,
        confidenceCoverageLowerBound: Double = 0,
        confidenceCoverageUpperBound: Double = 1,
        offsetTieBreakRule: String = "score-descending;absolute-offset-ascending;signed-offset-ascending",
        offsetEnumerationRule: String = "floor-regular-grid;append-upper-endpoint-if-outside-tolerance",
        windowMinimumSize: Int = 1,
        minimumRateForDistance: Double = 1,
        acceptedConfidenceComparison: V6SemanticComparisonRule = .greaterThanOrEqual,
        rejectionConfidenceComparison: V6SemanticComparisonRule = .lessThan,
        statusOffsetComparison: V6SemanticComparisonRule = .greaterThan
    ) {
        self.minimumMatchedFrames = minimumMatchedFrames
        self.minimumMatchRatio = minimumMatchRatio
        self.minimumP10Confidence = minimumP10Confidence
        self.alignedMedianConfidence = alignedMedianConfidence
        self.p10QuantileFraction = p10QuantileFraction
        self.secondBestExclusionSeconds = secondBestExclusionSeconds
        self.perWindowSampleDivisor = perWindowSampleDivisor
        self.statusOffsetToleranceSeconds = statusOffsetToleranceSeconds
        self.maximumPairingDistanceSeconds = maximumPairingDistanceSeconds
        self.fallbackFrameRate = fallbackFrameRate
        self.frameIntervalDistanceFactor = frameIntervalDistanceFactor
        self.offsetStepDistanceFactor = offsetStepDistanceFactor
        self.offsetCandidateEndpointTolerance = offsetCandidateEndpointTolerance
        self.quantileFractions = quantileFractions
        self.workBudgetPassCount = workBudgetPassCount
        self.matchDecisionPriority = matchDecisionPriority
        self.skipHDRDecisionPriority = skipHDRDecisionPriority
        self.skipSDRDecisionPriority = skipSDRDecisionPriority
        self.endDecisionPriority = endDecisionPriority
        self.confidenceCoverageLowerBound = confidenceCoverageLowerBound
        self.confidenceCoverageUpperBound = confidenceCoverageUpperBound
        self.offsetTieBreakRule = offsetTieBreakRule
        self.offsetEnumerationRule = offsetEnumerationRule
        self.windowMinimumSize = windowMinimumSize
        self.minimumRateForDistance = minimumRateForDistance
        self.acceptedConfidenceComparison = acceptedConfidenceComparison
        self.rejectionConfidenceComparison = rejectionConfidenceComparison
        self.statusOffsetComparison = statusOffsetComparison
    }

    public static let v6 = V6AlignmentSemanticConfiguration()

    public var isValid: Bool {
        let values = [
            minimumMatchRatio, minimumP10Confidence, alignedMedianConfidence,
            p10QuantileFraction, secondBestExclusionSeconds,
            statusOffsetToleranceSeconds, maximumPairingDistanceSeconds,
            fallbackFrameRate, frameIntervalDistanceFactor, offsetStepDistanceFactor,
            offsetCandidateEndpointTolerance, confidenceCoverageLowerBound,
            confidenceCoverageUpperBound, minimumRateForDistance
        ]
        return minimumMatchedFrames > 0 &&
            values.allSatisfy(\.isFinite) &&
            (0...1).contains(minimumMatchRatio) &&
            (0...1).contains(minimumP10Confidence) &&
            (0...1).contains(alignedMedianConfidence) &&
            (0...1).contains(p10QuantileFraction) &&
            secondBestExclusionSeconds >= 0 &&
            perWindowSampleDivisor > 0 &&
            maximumPairingDistanceSeconds >= 0 && fallbackFrameRate > 0 &&
            frameIntervalDistanceFactor >= 0 &&
            offsetStepDistanceFactor >= 0 &&
            offsetCandidateEndpointTolerance >= 0 &&
            quantileFractions.allSatisfy({ $0.isFinite && (0...1).contains($0) }) &&
            quantileFractions == quantileFractions.sorted() &&
            quantileFractions.first == 0 && quantileFractions.last == 1 &&
            workBudgetPassCount > 0 &&
            Set([matchDecisionPriority, skipHDRDecisionPriority, skipSDRDecisionPriority, endDecisionPriority]).count == 4 &&
            confidenceCoverageLowerBound >= 0 && confidenceCoverageUpperBound <= 1 &&
            confidenceCoverageLowerBound <= confidenceCoverageUpperBound &&
            offsetTieBreakRule == "score-descending;absolute-offset-ascending;signed-offset-ascending" &&
            offsetEnumerationRule == "floor-regular-grid;append-upper-endpoint-if-outside-tolerance" &&
            windowMinimumSize > 0 && minimumRateForDistance > 0
    }

    public func decisionPriority(_ name: String) -> Int {
        switch name {
        case "match": return matchDecisionPriority
        case "skipHDR": return skipHDRDecisionPriority
        case "skipSDR": return skipSDRDecisionPriority
        default: return endDecisionPriority
        }
    }

    public func acceptsConfidence(_ value: Double, threshold: Double) -> Bool {
        switch acceptedConfidenceComparison {
        case .greaterThan: return value > threshold
        case .greaterThanOrEqual: return value >= threshold
        case .lessThan, .lessThanOrEqual: return false
        }
    }

    public func rejectsMedian(_ value: Double, threshold: Double) -> Bool {
        switch rejectionConfidenceComparison {
        case .lessThan: return value < threshold
        case .lessThanOrEqual: return value <= threshold
        case .greaterThan, .greaterThanOrEqual: return false
        }
    }

    public func hasStatusOffset(_ value: Double, tolerance: Double) -> Bool {
        switch statusOffsetComparison {
        case .greaterThan: return value > tolerance
        case .greaterThanOrEqual: return value >= tolerance
        case .lessThan, .lessThanOrEqual: return false
        }
    }

    func prefersOffset(
        candidate: (offset: Double, score: Double),
        over current: (offset: Double, score: Double)
    ) -> Bool {
        guard offsetTieBreakRule ==
                "score-descending;absolute-offset-ascending;signed-offset-ascending" else {
            return false
        }
        if candidate.score != current.score {
            return candidate.score > current.score
        }
        if abs(candidate.offset) != abs(current.offset) {
            return abs(candidate.offset) < abs(current.offset)
        }
        return candidate.offset < current.offset
    }
}

public struct V6SceneSegmentationSemanticConfiguration: Codable, Hashable, Sendable {
    public let boundaryDescriptorDistanceThreshold: Double
    public let boundaryEdgeEnergyDeltaThreshold: Double
    public let classificationP90Fraction: Double
    public let classificationP99Fraction: Double
    public let lowKeyMeanThreshold: Double
    public let highKeyMeanThreshold: Double
    public let highlightP99Threshold: Double
    public let highlightP99MeanDelta: Double
    public let lowContrastP90MinimumDelta: Double
    public let boundaryDescriptorComparison: V6SemanticComparisonRule
    public let boundaryEdgeComparison: V6SemanticComparisonRule
    public let lowKeyComparison: V6SemanticComparisonRule
    public let highKeyComparison: V6SemanticComparisonRule
    public let highlightP99Comparison: V6SemanticComparisonRule
    public let highlightDeltaComparison: V6SemanticComparisonRule
    public let lowContrastComparison: V6SemanticComparisonRule
    public let sceneBoundaryRule: String
    public let sceneIdentifierRule: String
    public let emptySceneTag: String
    public let defaultSceneTag: String
    public let lowKeyTag: String
    public let highKeyTag: String
    public let highlightRichTag: String
    public let lowContrastTag: String

    public init(
        boundaryDescriptorDistanceThreshold: Double = 0.28,
        boundaryEdgeEnergyDeltaThreshold: Double = 0.18,
        classificationP90Fraction: Double = 0.90,
        classificationP99Fraction: Double = 0.99,
        lowKeyMeanThreshold: Double = 0.20,
        highKeyMeanThreshold: Double = 0.65,
        highlightP99Threshold: Double = 0.95,
        highlightP99MeanDelta: Double = 0.35,
        lowContrastP90MinimumDelta: Double = 0.25,
        boundaryDescriptorComparison: V6SemanticComparisonRule = .greaterThan,
        boundaryEdgeComparison: V6SemanticComparisonRule = .greaterThan,
        lowKeyComparison: V6SemanticComparisonRule = .lessThan,
        highKeyComparison: V6SemanticComparisonRule = .greaterThan,
        highlightP99Comparison: V6SemanticComparisonRule = .greaterThan,
        highlightDeltaComparison: V6SemanticComparisonRule = .greaterThan,
        lowContrastComparison: V6SemanticComparisonRule = .lessThan,
        sceneBoundaryRule: String = "start-at-boundary;end-at-boundary-minus-one",
        sceneIdentifierRule: String = "scene-prefix;one-based;zero-padded-4-decimal",
        emptySceneTag: String = "UNKNOWN",
        defaultSceneTag: String = "MID_KEY",
        lowKeyTag: String = "LOW_KEY",
        highKeyTag: String = "HIGH_KEY",
        highlightRichTag: String = "HIGHLIGHT_RICH",
        lowContrastTag: String = "LOW_CONTRAST"
    ) {
        self.boundaryDescriptorDistanceThreshold = boundaryDescriptorDistanceThreshold
        self.boundaryEdgeEnergyDeltaThreshold = boundaryEdgeEnergyDeltaThreshold
        self.classificationP90Fraction = classificationP90Fraction
        self.classificationP99Fraction = classificationP99Fraction
        self.lowKeyMeanThreshold = lowKeyMeanThreshold
        self.highKeyMeanThreshold = highKeyMeanThreshold
        self.highlightP99Threshold = highlightP99Threshold
        self.highlightP99MeanDelta = highlightP99MeanDelta
        self.lowContrastP90MinimumDelta = lowContrastP90MinimumDelta
        self.boundaryDescriptorComparison = boundaryDescriptorComparison
        self.boundaryEdgeComparison = boundaryEdgeComparison
        self.lowKeyComparison = lowKeyComparison
        self.highKeyComparison = highKeyComparison
        self.highlightP99Comparison = highlightP99Comparison
        self.highlightDeltaComparison = highlightDeltaComparison
        self.lowContrastComparison = lowContrastComparison
        self.sceneBoundaryRule = sceneBoundaryRule
        self.sceneIdentifierRule = sceneIdentifierRule
        self.emptySceneTag = emptySceneTag
        self.defaultSceneTag = defaultSceneTag
        self.lowKeyTag = lowKeyTag
        self.highKeyTag = highKeyTag
        self.highlightRichTag = highlightRichTag
        self.lowContrastTag = lowContrastTag
    }

    public static let v6 = V6SceneSegmentationSemanticConfiguration()

    public var isValid: Bool {
        let values = [
            boundaryDescriptorDistanceThreshold, boundaryEdgeEnergyDeltaThreshold,
            classificationP90Fraction, classificationP99Fraction,
            lowKeyMeanThreshold, highKeyMeanThreshold, highlightP99Threshold,
            highlightP99MeanDelta, lowContrastP90MinimumDelta
        ]
        return values.allSatisfy(\.isFinite) &&
            boundaryDescriptorDistanceThreshold >= 0 &&
            boundaryEdgeEnergyDeltaThreshold >= 0 &&
            (0...1).contains(classificationP90Fraction) &&
            (0...1).contains(classificationP99Fraction) &&
            classificationP90Fraction <= classificationP99Fraction &&
            (0...1).contains(lowKeyMeanThreshold) &&
            (0...1).contains(highKeyMeanThreshold) &&
            (0...1).contains(highlightP99Threshold) &&
            highlightP99MeanDelta >= 0 && lowContrastP90MinimumDelta >= 0 &&
            sceneBoundaryRule == "start-at-boundary;end-at-boundary-minus-one" &&
            sceneIdentifierRule == "scene-prefix;one-based;zero-padded-4-decimal" &&
            emptySceneTag == "UNKNOWN" && defaultSceneTag == "MID_KEY" &&
            lowKeyTag == "LOW_KEY" && highKeyTag == "HIGH_KEY" &&
            highlightRichTag == "HIGHLIGHT_RICH" && lowContrastTag == "LOW_CONTRAST"
    }

    func compare(_ lhs: Double, _ rhs: Double, using rule: V6SemanticComparisonRule) -> Bool {
        switch rule {
        case .lessThan: return lhs < rhs
        case .lessThanOrEqual: return lhs <= rhs
        case .greaterThan: return lhs > rhs
        case .greaterThanOrEqual: return lhs >= rhs
        }
    }

    func sceneIdentifier(oneBasedIndex: Int) -> String? {
        guard sceneIdentifierRule == "scene-prefix;one-based;zero-padded-4-decimal",
              oneBasedIndex > 0 else { return nil }
        let number = String(oneBasedIndex)
        return "scene_" + String(repeating: "0", count: max(0, 4 - number.count)) + number
    }
}

public enum V6RepresentativeAnchorRule: String, Codable, Hashable, Sendable {
    case first
    case middle
    case last
}

public enum V6RepresentativeMaximumRule: String, Codable, Hashable, Sendable {
    case meanLuma
    case variance
    case edgeEnergy
    case lumaP95
    case chromaMagnitude
}

public struct V6RepresentativeFrameSemanticConfiguration: Codable, Hashable, Sendable {
    public let anchorRules: [V6RepresentativeAnchorRule]
    public let maximumRules: [V6RepresentativeMaximumRule]
    public let lumaP95Fraction: Double
    /// Chroma is sampled from the decoded 4:2:0 plane while selecting the
    /// representative frames.  The sampling grid is therefore preparation
    /// semantics, not an implementation detail.
    public let chromaSampleGridWidth: Int
    public let chromaSampleGridHeight: Int
    public let fallbackSamplingRule: String
    public let outputOrderingRule: String
    public let maximumRuleTieBreakRule: String

    public init(
        anchorRules: [V6RepresentativeAnchorRule] = [.first, .middle, .last],
        maximumRules: [V6RepresentativeMaximumRule] = [.meanLuma, .variance, .edgeEnergy, .lumaP95, .chromaMagnitude],
        lumaP95Fraction: Double = 0.95,
        chromaSampleGridWidth: Int = 16,
        chromaSampleGridHeight: Int = 9,
        fallbackSamplingRule: String = "nearest-rounded-normalized-sequence-position",
        outputOrderingRule: String = "ascending-sequence-position",
        maximumRuleTieBreakRule: String = "descending-value-then-ascending-sequence-position"
    ) {
        self.anchorRules = anchorRules
        self.maximumRules = maximumRules
        self.lumaP95Fraction = lumaP95Fraction
        self.chromaSampleGridWidth = chromaSampleGridWidth
        self.chromaSampleGridHeight = chromaSampleGridHeight
        self.fallbackSamplingRule = fallbackSamplingRule
        self.outputOrderingRule = outputOrderingRule
        self.maximumRuleTieBreakRule = maximumRuleTieBreakRule
    }

    public static let v6 = V6RepresentativeFrameSemanticConfiguration()

    public var isValid: Bool {
        !anchorRules.isEmpty && !maximumRules.isEmpty &&
            Set(anchorRules).count == anchorRules.count &&
            Set(maximumRules).count == maximumRules.count &&
            lumaP95Fraction.isFinite && (0...1).contains(lumaP95Fraction) &&
            chromaSampleGridWidth > 0 && chromaSampleGridHeight > 0 &&
            fallbackSamplingRule == "nearest-rounded-normalized-sequence-position" &&
            outputOrderingRule == "ascending-sequence-position" &&
            maximumRuleTieBreakRule == "descending-value-then-ascending-sequence-position"
    }

    public func fallbackFraction(index: Int, count: Int) -> Double {
        count == 1 ? 0.5 : Double(index) / Double(max(count - 1, 1))
    }

    public func fallbackSourceIndex(index: Int, count: Int) -> Int {
        min(count - 1, max(0, Int((fallbackFraction(index: index, count: count) * Double(count - 1)).rounded())))
    }

    public func prefersMaximum(
        value: Double,
        sequencePosition: Int,
        over otherValue: Double,
        otherSequencePosition: Int
    ) -> Bool {
        value > otherValue || (value == otherValue && sequencePosition < otherSequencePosition)
    }
}

public enum V6TemporalAnchorRule: String, Codable, Hashable, Sendable {
    case maximumConfidence
}

public struct V6TemporalSelectionSemanticConfiguration: Codable, Hashable, Sendable {
    public let anchorRule: V6TemporalAnchorRule
    public let anchorTieBreakRule: String
    public let startOffsetSeconds: Double
    public let minimumStartSeconds: Double
    public let windowPairingRule: String
    public let confidenceCarryRule: String

    public init(
        anchorRule: V6TemporalAnchorRule = .maximumConfidence,
        anchorTieBreakRule: String = "descending-confidence-then-ascending-sequence-position",
        startOffsetSeconds: Double = 0.05,
        minimumStartSeconds: Double = 0,
        windowPairingRule: String = "hdr-start=max(sdr-start+anchor-offset,minimum-start)",
        confidenceCarryRule: String = "anchor-confidence-for-window-frames"
    ) {
        self.anchorRule = anchorRule
        self.anchorTieBreakRule = anchorTieBreakRule
        self.startOffsetSeconds = startOffsetSeconds
        self.minimumStartSeconds = minimumStartSeconds
        self.windowPairingRule = windowPairingRule
        self.confidenceCarryRule = confidenceCarryRule
    }

    public static let v6 = V6TemporalSelectionSemanticConfiguration()

    public var isValid: Bool {
        startOffsetSeconds.isFinite && startOffsetSeconds >= 0 &&
            minimumStartSeconds.isFinite && minimumStartSeconds >= 0 &&
            anchorTieBreakRule == "descending-confidence-then-ascending-sequence-position" &&
            windowPairingRule == "hdr-start=max(sdr-start+anchor-offset,minimum-start)" &&
            confidenceCarryRule == "anchor-confidence-for-window-frames"
    }

    func prefersAnchor(
        candidate: (confidence: Double, sequencePosition: Int),
        over current: (confidence: Double, sequencePosition: Int)
    ) -> Bool {
        guard anchorRule == .maximumConfidence,
              anchorTieBreakRule == "descending-confidence-then-ascending-sequence-position" else {
            return false
        }
        if candidate.confidence != current.confidence {
            return candidate.confidence > current.confidence
        }
        return candidate.sequencePosition < current.sequencePosition
    }
}

public struct V6SpatialGeometrySemanticConfiguration: Codable, Hashable, Sendable {
    public let sameAspectThreshold: Double
    public let recoverableAspectThreshold: Double

    public init(
        sameAspectThreshold: Double = 0.02,
        recoverableAspectThreshold: Double = 0.12
    ) {
        self.sameAspectThreshold = sameAspectThreshold
        self.recoverableAspectThreshold = recoverableAspectThreshold
    }

    public static let v6 = V6SpatialGeometrySemanticConfiguration()

    public var isValid: Bool {
        sameAspectThreshold.isFinite && recoverableAspectThreshold.isFinite &&
            sameAspectThreshold >= 0 && sameAspectThreshold <= recoverableAspectThreshold
    }
}

/// Bounds and tolerances used when accepting a serialized preparation plan.
/// These are semantic because changing them can change whether a candidate
/// plan reaches the evaluator.
public struct V6PreparationValidationSemanticConfiguration: Codable, Hashable, Sendable {
    public let maximumFramesPerScene: Int
    public let maximumDecodedFrames: Int
    public let minimumProxyWidth: Int
    public let maximumProxyWidth: Int
    public let minimumTemporalFPS: Double
    public let maximumTemporalFPS: Double
    public let minimumReferencePeakNits: Float
    public let maximumReferencePeakNits: Float
    public let maximumDecodedWidth: Int
    public let maximumDecodedHeight: Int
    public let maximumProxyHeight: Int
    public let maximumNominalFPS: Double
    public let maximumPerWindowOffsetCount: Int
    public let evidenceTolerance: Double
    public let alignmentConfidenceMustBeZero: Bool

    public init(
        maximumFramesPerScene: Int = 512,
        maximumDecodedFrames: Int = 512,
        minimumProxyWidth: Int = 16,
        maximumProxyWidth: Int = 512,
        minimumTemporalFPS: Double = 1,
        maximumTemporalFPS: Double = 240,
        minimumReferencePeakNits: Float = 1,
        maximumReferencePeakNits: Float = 10_000,
        maximumDecodedWidth: Int = 65_536,
        maximumDecodedHeight: Int = 65_536,
        maximumProxyHeight: Int = 4_096,
        maximumNominalFPS: Double = 1_000,
        maximumPerWindowOffsetCount: Int = 8,
        evidenceTolerance: Double = 1e-12,
        alignmentConfidenceMustBeZero: Bool = true
    ) {
        self.maximumFramesPerScene = maximumFramesPerScene
        self.maximumDecodedFrames = maximumDecodedFrames
        self.minimumProxyWidth = minimumProxyWidth
        self.maximumProxyWidth = maximumProxyWidth
        self.minimumTemporalFPS = minimumTemporalFPS
        self.maximumTemporalFPS = maximumTemporalFPS
        self.minimumReferencePeakNits = minimumReferencePeakNits
        self.maximumReferencePeakNits = maximumReferencePeakNits
        self.maximumDecodedWidth = maximumDecodedWidth
        self.maximumDecodedHeight = maximumDecodedHeight
        self.maximumProxyHeight = maximumProxyHeight
        self.maximumNominalFPS = maximumNominalFPS
        self.maximumPerWindowOffsetCount = maximumPerWindowOffsetCount
        self.evidenceTolerance = evidenceTolerance
        self.alignmentConfidenceMustBeZero = alignmentConfidenceMustBeZero
    }

    public static let v6 = V6PreparationValidationSemanticConfiguration()

    public var isValid: Bool {
        maximumFramesPerScene > 0 && maximumDecodedFrames > 0 &&
            minimumProxyWidth > 0 && maximumProxyWidth >= minimumProxyWidth &&
            minimumTemporalFPS.isFinite && maximumTemporalFPS.isFinite &&
            minimumTemporalFPS > 0 && maximumTemporalFPS >= minimumTemporalFPS &&
            minimumReferencePeakNits.isFinite && maximumReferencePeakNits.isFinite &&
            minimumReferencePeakNits >= 0 && maximumReferencePeakNits >= minimumReferencePeakNits &&
            maximumDecodedWidth > 0 && maximumDecodedHeight > 0 &&
            maximumProxyHeight > 0 &&
            maximumNominalFPS.isFinite && maximumNominalFPS > 0 &&
            maximumPerWindowOffsetCount > 0 && evidenceTolerance.isFinite && evidenceTolerance >= 0
    }
}

/// Compatibility name used by the V4 seal.  `V6PreparationConfiguration` is
/// the actual root object consumed by the preparation implementation.
public typealias V6PreparationSemanticConfiguration = V6PreparationConfiguration
