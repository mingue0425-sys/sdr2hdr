import Foundation
import HDRCore

public enum V6MatcherComparisonRule: String, Codable, Hashable, Sendable {
    case greaterThan
    case greaterThanOrEqual

    func accepts(_ value: Double, threshold: Double) -> Bool {
        switch self {
        case .greaterThan: return value > threshold
        case .greaterThanOrEqual: return value >= threshold
        }
    }
}

public enum V6MatcherRoundingRule: String, Codable, Hashable, Sendable {
    case nearestInteger
}

public enum V6MatcherReductionRule: String, Codable, Hashable, Sendable {
    case arithmeticMean
}

/// Exact algorithmic choices used after the matcher inputs have been decoded.
/// These values are semantic: changing one can change the prepared plan even
/// when the public matcher weights and bounds remain unchanged.
public struct V6MatcherAlgorithmSemanticConfiguration: Codable, Hashable, Sendable {
    public let edgeMaskComparison: V6MatcherComparisonRule
    public let scaleHeightRoundingRule: V6MatcherRoundingRule
    public let scaleHeightMinimum: Int
    public let multiScaleReductionRule: V6MatcherReductionRule
    public let multiScaleEmptyValue: Double
    public let minimumCorrelationSampleCount: Int
    public let degenerateCorrelationValue: Double
    public let correlationDenominatorComparison: V6MatcherComparisonRule
    public let rankDenominatorMinimum: Int
    public let averageRankTieFactor: Double
    public let localContrastRadius: Int
    public let localContrastCountMinimum: Double
    public let gradientMinimumWidth: Int
    public let gradientMinimumHeight: Int
    public let gradientComponentsPerCell: Int
    public let medianSelectionRule: String
    public let rankSortTieBreakRule: String

    public init(
        edgeMaskComparison: V6MatcherComparisonRule = .greaterThanOrEqual,
        scaleHeightRoundingRule: V6MatcherRoundingRule = .nearestInteger,
        scaleHeightMinimum: Int = 1,
        multiScaleReductionRule: V6MatcherReductionRule = .arithmeticMean,
        multiScaleEmptyValue: Double = 0,
        minimumCorrelationSampleCount: Int = 2,
        degenerateCorrelationValue: Double = 0,
        correlationDenominatorComparison: V6MatcherComparisonRule = .greaterThan,
        rankDenominatorMinimum: Int = 1,
        averageRankTieFactor: Double = 0.5,
        localContrastRadius: Int = 1,
        localContrastCountMinimum: Double = 1,
        gradientMinimumWidth: Int = 2,
        gradientMinimumHeight: Int = 2,
        gradientComponentsPerCell: Int = 2,
        medianSelectionRule: String = "upper-middle-index-count-divided-by-two",
        rankSortTieBreakRule: String = "source-index-ascending"
    ) {
        self.edgeMaskComparison = edgeMaskComparison
        self.scaleHeightRoundingRule = scaleHeightRoundingRule
        self.scaleHeightMinimum = scaleHeightMinimum
        self.multiScaleReductionRule = multiScaleReductionRule
        self.multiScaleEmptyValue = multiScaleEmptyValue
        self.minimumCorrelationSampleCount = minimumCorrelationSampleCount
        self.degenerateCorrelationValue = degenerateCorrelationValue
        self.correlationDenominatorComparison = correlationDenominatorComparison
        self.rankDenominatorMinimum = rankDenominatorMinimum
        self.averageRankTieFactor = averageRankTieFactor
        self.localContrastRadius = localContrastRadius
        self.localContrastCountMinimum = localContrastCountMinimum
        self.gradientMinimumWidth = gradientMinimumWidth
        self.gradientMinimumHeight = gradientMinimumHeight
        self.gradientComponentsPerCell = gradientComponentsPerCell
        self.medianSelectionRule = medianSelectionRule
        self.rankSortTieBreakRule = rankSortTieBreakRule
    }

    public static let v6 = V6MatcherAlgorithmSemanticConfiguration()

    public var isValid: Bool {
        scaleHeightMinimum > 0 && multiScaleEmptyValue.isFinite &&
            minimumCorrelationSampleCount > 0 && degenerateCorrelationValue.isFinite &&
            rankDenominatorMinimum > 0 && averageRankTieFactor.isFinite &&
            averageRankTieFactor >= 0 && averageRankTieFactor <= 1 &&
            localContrastRadius >= 0 && localContrastCountMinimum.isFinite &&
            localContrastCountMinimum > 0 && gradientMinimumWidth > 1 &&
            gradientMinimumHeight > 1 && gradientComponentsPerCell > 0 &&
            medianSelectionRule == "upper-middle-index-count-divided-by-two" &&
            rankSortTieBreakRule == "source-index-ascending"
    }

    func scaleHeight(width: Int, gridHeight: Int, gridWidth: Int) -> Int {
        guard gridWidth > 0 else { return scaleHeightMinimum }
        let raw = Double(width) * Double(gridHeight) / Double(gridWidth)
        switch scaleHeightRoundingRule {
        case .nearestInteger: return max(scaleHeightMinimum, Int(raw.rounded()))
        }
    }

    func reduce(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return multiScaleEmptyValue }
        switch multiScaleReductionRule {
        case .arithmeticMean: return values.reduce(0, +) / Double(values.count)
        }
    }
}

/// Safety validation is part of matcher semantics: changing an accepted
/// domain can change whether a preparation plan is produced.  Keep these
/// bounds in the same immutable object consumed by the matcher instead of
/// leaving them as executable-only literals.
public struct V6MatcherValidationSemanticConfiguration: Codable, Hashable, Sendable {
    public let minimumGridWidth: Int
    public let maximumGridWidth: Int
    public let maximumGridCellCount: Int
    public let minimumOffsetSeconds: Double
    public let maximumOffsetSeconds: Double
    public let maximumMultiScaleWidthCount: Int
    public let minimumMultiScaleWidth: Int
    public let maximumScaleCellCountMultiplier: Int
    public let weightSumTolerance: Double

    public init(
        minimumGridWidth: Int = 2,
        maximumGridWidth: Int = 512,
        maximumGridCellCount: Int = 4_096,
        minimumOffsetSeconds: Double = -60,
        maximumOffsetSeconds: Double = 60,
        maximumMultiScaleWidthCount: Int = 16,
        minimumMultiScaleWidth: Int = 2,
        maximumScaleCellCountMultiplier: Int = 2,
        weightSumTolerance: Double = 1e-9
    ) {
        self.minimumGridWidth = minimumGridWidth
        self.maximumGridWidth = maximumGridWidth
        self.maximumGridCellCount = maximumGridCellCount
        self.minimumOffsetSeconds = minimumOffsetSeconds
        self.maximumOffsetSeconds = maximumOffsetSeconds
        self.maximumMultiScaleWidthCount = maximumMultiScaleWidthCount
        self.minimumMultiScaleWidth = minimumMultiScaleWidth
        self.maximumScaleCellCountMultiplier = maximumScaleCellCountMultiplier
        self.weightSumTolerance = weightSumTolerance
    }

    public static let v6 = V6MatcherValidationSemanticConfiguration()

    public var isValid: Bool {
        minimumGridWidth > 0 && maximumGridWidth >= minimumGridWidth &&
            maximumGridCellCount > 0 && minimumOffsetSeconds.isFinite &&
            maximumOffsetSeconds.isFinite && minimumOffsetSeconds <= maximumOffsetSeconds &&
            maximumMultiScaleWidthCount > 0 && minimumMultiScaleWidth > 0 &&
            maximumScaleCellCountMultiplier > 0 && weightSumTolerance.isFinite &&
            weightSumTolerance >= 0
    }
}

public struct V6MatcherConfiguration: Codable, Hashable, Sendable {
    public let preparationAlgorithmVersion: String
    public let matcherVersion: String
    public let gridWidth: Int
    public let gridHeight: Int
    public let offsetMinimumSeconds: Double
    public let offsetMaximumSeconds: Double
    public let offsetStepSeconds: Double
    public let acceptedConfidenceThreshold: Double
    public let rankWeight: Double
    public let signedGradientWeight: Double
    public let multiScaleNCCWeight: Double
    public let edgeMaskWeight: Double
    public let localContrastWeight: Double
    public let multiScaleWidths: [Int]
    /// These controls are part of matcher semantics, not implementation
    /// tolerances.  Keeping them in the same value consumed by the matcher
    /// prevents a fallback or numerical clamp from escaping the seal.
    public let spatialDegeneracyVarianceThreshold: Double
    public let descriptorFallbackExponentScale: Double
    public let confidenceLowerBound: Double
    public let confidenceUpperBound: Double
    public let correlationEpsilon: Double
    public let correlationLowerBound: Double
    public let correlationUpperBound: Double
    public let minimumOffsetStepSeconds: Double
    public let maximumOffsetStepSeconds: Double
    public let maximumOffsetCandidateCount: Int
    public let algorithmSemantics: V6MatcherAlgorithmSemanticConfiguration
    public let validationSemantics: V6MatcherValidationSemanticConfiguration

    public init(
        preparationAlgorithmVersion: String = "v6-prepared-evaluation-v6",
        matcherVersion: String = "v6-transfer-invariant-matcher-v3",
        gridWidth: Int = 64,
        gridHeight: Int = 36,
        offsetMinimumSeconds: Double = -2,
        offsetMaximumSeconds: Double = 2,
        offsetStepSeconds: Double = 1.0 / 30.0,
        acceptedConfidenceThreshold: Double = 0.60,
        rankWeight: Double = 0.30,
        signedGradientWeight: Double = 0.25,
        multiScaleNCCWeight: Double = 0.25,
        edgeMaskWeight: Double = 0.10,
        localContrastWeight: Double = 0.10,
        multiScaleWidths: [Int] = [64, 32, 16],
        spatialDegeneracyVarianceThreshold: Double = 1e-8,
        descriptorFallbackExponentScale: Double = 4,
        confidenceLowerBound: Double = 0,
        confidenceUpperBound: Double = 1,
        correlationEpsilon: Double = 1e-12,
        correlationLowerBound: Double = -1,
        correlationUpperBound: Double = 1,
        minimumOffsetStepSeconds: Double = 1e-6,
        maximumOffsetStepSeconds: Double = 10,
        maximumOffsetCandidateCount: Int = 10_000,
        algorithmSemantics: V6MatcherAlgorithmSemanticConfiguration = .v6,
        validationSemantics: V6MatcherValidationSemanticConfiguration = .v6
    ) {
        self.preparationAlgorithmVersion = preparationAlgorithmVersion
        self.matcherVersion = matcherVersion
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.offsetMinimumSeconds = offsetMinimumSeconds
        self.offsetMaximumSeconds = offsetMaximumSeconds
        self.offsetStepSeconds = offsetStepSeconds
        self.acceptedConfidenceThreshold = acceptedConfidenceThreshold
        self.rankWeight = rankWeight
        self.signedGradientWeight = signedGradientWeight
        self.multiScaleNCCWeight = multiScaleNCCWeight
        self.edgeMaskWeight = edgeMaskWeight
        self.localContrastWeight = localContrastWeight
        self.multiScaleWidths = multiScaleWidths
        self.spatialDegeneracyVarianceThreshold = spatialDegeneracyVarianceThreshold
        self.descriptorFallbackExponentScale = descriptorFallbackExponentScale
        self.confidenceLowerBound = confidenceLowerBound
        self.confidenceUpperBound = confidenceUpperBound
        self.correlationEpsilon = correlationEpsilon
        self.correlationLowerBound = correlationLowerBound
        self.correlationUpperBound = correlationUpperBound
        self.minimumOffsetStepSeconds = minimumOffsetStepSeconds
        self.maximumOffsetStepSeconds = maximumOffsetStepSeconds
        self.maximumOffsetCandidateCount = maximumOffsetCandidateCount
        self.algorithmSemantics = algorithmSemantics
        self.validationSemantics = validationSemantics
    }

    public static let v6 = V6MatcherConfiguration()

    public static let canonicalFieldNames: Set<String> = [
        "preparationAlgorithmVersion", "matcherVersion", "gridWidth", "gridHeight",
        "offsetMinimumSeconds", "offsetMaximumSeconds", "offsetStepSeconds",
        "acceptedConfidenceThreshold", "rankWeight", "signedGradientWeight",
        "multiScaleNCCWeight", "edgeMaskWeight", "localContrastWeight",
        "multiScaleWidths", "spatialDegeneracyVarianceThreshold",
        "descriptorFallbackExponentScale", "confidenceLowerBound",
        "confidenceUpperBound", "correlationEpsilon", "correlationLowerBound",
        "correlationUpperBound", "minimumOffsetStepSeconds",
        "maximumOffsetStepSeconds", "maximumOffsetCandidateCount", "algorithmSemantics",
        "validationSemantics"
    ]

    /// Returns a deterministic failure reason for configurations that could
    /// hang, over-allocate, or produce confidence values outside [0, 1].
    /// Production plan validators and the runtime aligner share this check.
    func validationFailure() -> String? {
        let storedFieldNames = Set(Mirror(reflecting: self).children.compactMap(\.label))
        guard storedFieldNames == Self.canonicalFieldNames else {
            return "matcher semantic field coverage is incomplete"
        }
        guard validationSemantics.isValid else {
            return "matcher validation semantic bounds are invalid"
        }
        let scalarValues = [
            offsetMinimumSeconds, offsetMaximumSeconds, offsetStepSeconds,
            acceptedConfidenceThreshold, rankWeight, signedGradientWeight,
            multiScaleNCCWeight, edgeMaskWeight, localContrastWeight,
            spatialDegeneracyVarianceThreshold, descriptorFallbackExponentScale,
            confidenceLowerBound, confidenceUpperBound, correlationEpsilon,
            correlationLowerBound, correlationUpperBound, minimumOffsetStepSeconds,
            maximumOffsetStepSeconds,
        ]
        guard scalarValues.allSatisfy(\.isFinite) else {
            return "matcher configuration contains a non-finite value"
        }
        guard !preparationAlgorithmVersion.isEmpty, !matcherVersion.isEmpty else {
            return "matcher configuration versions must be non-empty"
        }
        guard (validationSemantics.minimumGridWidth...validationSemantics.maximumGridWidth).contains(gridWidth),
              (validationSemantics.minimumGridWidth...validationSemantics.maximumGridWidth).contains(gridHeight) else {
            return "matcher grid dimensions are outside safe bounds"
        }
        let gridCellCount = gridWidth * gridHeight
        guard gridCellCount <= validationSemantics.maximumGridCellCount else {
            return "matcher grid dimensions are outside safe bounds"
        }
        guard offsetMinimumSeconds >= validationSemantics.minimumOffsetSeconds,
              offsetMaximumSeconds <= validationSemantics.maximumOffsetSeconds,
              offsetMinimumSeconds <= offsetMaximumSeconds,
              offsetStepSeconds >= minimumOffsetStepSeconds,
              offsetStepSeconds <= maximumOffsetStepSeconds,
              minimumOffsetStepSeconds > 0,
              maximumOffsetStepSeconds >= minimumOffsetStepSeconds,
              maximumOffsetCandidateCount > 0 else {
            return "matcher offset grid is outside safe bounds"
        }
        let offsetCandidateCount = Int(
            ceil((offsetMaximumSeconds - offsetMinimumSeconds) / offsetStepSeconds)
        ) + 1
        guard offsetCandidateCount <= maximumOffsetCandidateCount else {
            return "matcher offset grid exceeds configured candidate limit"
        }
        guard (confidenceLowerBound...confidenceUpperBound).contains(acceptedConfidenceThreshold) else {
            return "matcher confidence threshold is outside [0, 1]"
        }
        let weights = [
            rankWeight, signedGradientWeight, multiScaleNCCWeight,
            edgeMaskWeight, localContrastWeight,
        ]
        guard weights.allSatisfy({ $0 >= 0 }),
              abs(weights.reduce(0, +) - 1) <= validationSemantics.weightSumTolerance else {
            return "matcher weights must be non-negative and sum to one"
        }
        guard !multiScaleWidths.isEmpty,
              multiScaleWidths.count <= validationSemantics.maximumMultiScaleWidthCount,
              multiScaleWidths.allSatisfy({ (validationSemantics.minimumMultiScaleWidth...gridWidth).contains($0) }),
              Set(multiScaleWidths).count == multiScaleWidths.count,
              zip(multiScaleWidths, multiScaleWidths.dropFirst()).allSatisfy({
                  $0.0 > $0.1
              }) else {
            return "matcher multi-scale widths are outside the configured grid"
        }
        let scaleCellCount = multiScaleWidths.reduce(0) { total, width in
            let height = algorithmSemantics.scaleHeight(
                width: width, gridHeight: gridHeight, gridWidth: gridWidth
            )
            return total + width * height
        }
        guard scaleCellCount <= gridCellCount * validationSemantics.maximumScaleCellCountMultiplier else {
            return "matcher multi-scale proxy allocation exceeds safe bounds"
        }
        guard confidenceLowerBound.isFinite,
              confidenceUpperBound.isFinite,
              confidenceLowerBound <= confidenceUpperBound,
              confidenceLowerBound >= 0,
              confidenceUpperBound <= 1,
              correlationEpsilon > 0,
              correlationLowerBound < correlationUpperBound,
              correlationLowerBound >= -1,
              correlationUpperBound <= 1,
              spatialDegeneracyVarianceThreshold >= 0,
              descriptorFallbackExponentScale >= 0,
              algorithmSemantics.isValid else {
            return "matcher numerical fallback bounds are invalid"
        }
        return nil
    }

    public func canonicalSHA256() throws -> String {
        if validationFailure() != nil {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        return try HDRCanonicalIdentity.sha256(self)
    }
}

public struct V6MatcherComponentMetrics: Codable, Hashable, Sendable {
    public let edgeCorrelation: Double
    public let normalizedLumaCorrelation: Double
    public let rankNormalizedLumaCorrelation: Double
    public let gradientCorrelation: Double
    public let localContrastCorrelation: Double
    public let multiScaleNCC: Double
    public let confidence: Double
}

struct V6MatcherFeatures {
    let luma: [Float]
    let rank: [Float]
    let gradient: [Float]
    let edgeMask: [Float]
    let localContrast: [Float]
    let scales: [[Float]]

    func isSpatiallyDegenerate(configuration: V6MatcherConfiguration) -> Bool {
        guard !luma.isEmpty else { return true }
        let mean = luma.reduce(0, +) / Float(luma.count)
        let variance = luma.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(luma.count)
        return variance <= Float(configuration.spatialDegeneracyVarianceThreshold)
    }
}

enum V6TransferInvariantMatcher {
    static func features(
        _ luma: [Float], configuration: V6MatcherConfiguration
    ) -> V6MatcherFeatures {
        let algorithm = configuration.algorithmSemantics
        let gradient = gradients(
            luma, width: configuration.gridWidth, height: configuration.gridHeight,
            algorithm: algorithm
        )
        let threshold = medianAbsolute(gradient, algorithm: algorithm)
        let edgeMask = gradient.map {
            algorithm.edgeMaskComparison.accepts(Double(abs($0)), threshold: Double(threshold))
                ? Float(1) : 0
        }
        let scales = configuration.multiScaleWidths.map { width -> [Float] in
            let height = algorithm.scaleHeight(
                width: width, gridHeight: configuration.gridHeight, gridWidth: configuration.gridWidth
            )
            return FrameDescriptorBuilder.downsample(
                luma,
                sourceWidth: configuration.gridWidth,
                sourceHeight: configuration.gridHeight,
                width: width,
                height: height
            )
        }
        return V6MatcherFeatures(
            luma: luma,
            rank: averageRanks(luma, algorithm: algorithm),
            gradient: gradient,
            edgeMask: edgeMask,
            localContrast: localContrast(
                luma, width: configuration.gridWidth, height: configuration.gridHeight,
                algorithm: algorithm
            ),
            scales: scales
        )
    }

    static func compare(
        _ lhs: V6MatcherFeatures,
        _ rhs: V6MatcherFeatures,
        configuration: V6MatcherConfiguration,
        descriptorFallback: (FrameDescriptor, FrameDescriptor)? = nil,
        descriptorConfiguration: V6DescriptorSemanticConfiguration = .v6
    ) -> V6MatcherComponentMetrics {
        let algorithm = configuration.algorithmSemantics
        let luma = correlation(lhs.luma, rhs.luma, configuration: configuration)
        let rank = correlation(lhs.rank, rhs.rank, configuration: configuration)
        let gradient = correlation(lhs.gradient, rhs.gradient, configuration: configuration)
        let edge = correlation(lhs.edgeMask, rhs.edgeMask, configuration: configuration)
        let local = correlation(lhs.localContrast, rhs.localContrast, configuration: configuration)
        let multi = algorithm.reduce(zip(lhs.scales, rhs.scales).map {
            correlation($0.0, $0.1, configuration: configuration)
        })
        func positive(_ value: Double) -> Double {
            max(configuration.confidenceLowerBound,
                min(configuration.confidenceUpperBound, value))
        }
        var confidence = positive(rank) * configuration.rankWeight +
            positive(gradient) * configuration.signedGradientWeight +
            positive(multi) * configuration.multiScaleNCCWeight +
            positive(edge) * configuration.edgeMaskWeight +
            positive(local) * configuration.localContrastWeight
        if lhs.isSpatiallyDegenerate(configuration: configuration) &&
           rhs.isSpatiallyDegenerate(configuration: configuration),
           let (lhsDescriptor, rhsDescriptor) = descriptorFallback {
            // Constant synthetic fixtures (and only those fixtures) do not
            // contain a spatial signal.  The pre-existing descriptor
            // distance still provides an exact temporal identity signal;
            // using it here keeps the common preflight/evaluator matcher
            // deterministic while retaining the sealed confidence gate.
            let distance = FrameDescriptorBuilder.alignmentDistance(
                lhsDescriptor,
                rhsDescriptor,
                configuration: descriptorConfiguration
            )
            confidence = positive(exp(-distance * configuration.descriptorFallbackExponentScale))
        }
        confidence = positive(confidence)
        return V6MatcherComponentMetrics(
            edgeCorrelation: edge,
            normalizedLumaCorrelation: luma,
            rankNormalizedLumaCorrelation: rank,
            gradientCorrelation: gradient,
            localContrastCorrelation: local,
            multiScaleNCC: multi,
            confidence: confidence
        )
    }

    private static func correlation(
        _ lhs: [Float], _ rhs: [Float], configuration: V6MatcherConfiguration
    ) -> Double {
        let algorithm = configuration.algorithmSemantics
        guard lhs.count == rhs.count,
              lhs.count >= algorithm.minimumCorrelationSampleCount else {
            return algorithm.degenerateCorrelationValue
        }
        let leftMean = Double(lhs.reduce(0, +)) / Double(lhs.count)
        let rightMean = Double(rhs.reduce(0, +)) / Double(rhs.count)
        var numerator = 0.0
        var leftVariance = 0.0
        var rightVariance = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index]) - leftMean
            let right = Double(rhs[index]) - rightMean
            numerator += left * right
            leftVariance += left * left
            rightVariance += right * right
        }
        let denominator = sqrt(leftVariance * rightVariance)
        return algorithm.correlationDenominatorComparison.accepts(
            denominator, threshold: configuration.correlationEpsilon
        )
            ? max(configuration.correlationLowerBound,
                min(configuration.correlationUpperBound, numerator / denominator))
            : algorithm.degenerateCorrelationValue
    }

    /// Normalized average ranks. Equal luminance samples must receive equal
    /// ranks; assigning ties by array index manufactures spatial correlation
    /// in flat or quantized images.
    static func averageRanks(
        _ values: [Float], algorithm: V6MatcherAlgorithmSemanticConfiguration = .v6
    ) -> [Float] {
        guard !values.isEmpty else { return [] }
        let order = values.indices.sorted {
            if values[$0] == values[$1] { return $0 < $1 }
            return values[$0] < values[$1]
        }
        var result = Array(repeating: Float(0), count: values.count)
        let denominator = Float(max(values.count - 1, algorithm.rankDenominatorMinimum))
        var start = 0
        while start < order.count {
            var end = start + 1
            while end < order.count, values[order[end]] == values[order[start]] {
                end += 1
            }
            let averageRank = Float(start + end - 1) * Float(algorithm.averageRankTieFactor) / denominator
            for position in start..<end {
                result[order[position]] = averageRank
            }
            start = end
        }
        return result
    }

    private static func gradients(
        _ values: [Float], width: Int, height: Int,
        algorithm: V6MatcherAlgorithmSemanticConfiguration
    ) -> [Float] {
        guard values.count == width * height,
              width >= algorithm.gradientMinimumWidth,
              height >= algorithm.gradientMinimumHeight else { return [] }
        var result: [Float] = []
        result.reserveCapacity((width - 1) * (height - 1) * algorithm.gradientComponentsPerCell)
        for row in 0..<(height - 1) {
            for column in 0..<(width - 1) {
                let index = row * width + column
                result.append(values[index + 1] - values[index])
                result.append(values[index + width] - values[index])
            }
        }
        return result
    }

    private static func medianAbsolute(
        _ values: [Float], algorithm: V6MatcherAlgorithmSemanticConfiguration
    ) -> Float {
        let sorted = values.map { abs($0) }.sorted()
        guard !sorted.isEmpty else { return Float(algorithm.multiScaleEmptyValue) }
        return sorted[sorted.count / 2]
    }

    private static func localContrast(
        _ values: [Float], width: Int, height: Int,
        algorithm: V6MatcherAlgorithmSemanticConfiguration
    ) -> [Float] {
        guard values.count == width * height else { return [] }
        var result = Array(repeating: Float(0), count: values.count)
        for row in 0..<height {
            for column in 0..<width {
                var total: Float = 0
                var count: Float = 0
                let radius = algorithm.localContrastRadius
                for y in max(0, row - radius)...min(height - 1, row + radius) {
                    for x in max(0, column - radius)...min(width - 1, column + radius) {
                        total += values[y * width + x]
                        count += 1
                    }
                }
                let index = row * width + column
                result[index] = values[index] - total / max(count, Float(algorithm.localContrastCountMinimum))
            }
        }
        return result
    }
}
