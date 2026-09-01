import CryptoKit
import Foundation

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

    public init(
        preparationAlgorithmVersion: String = "v6-prepared-evaluation-v3",
        matcherVersion: String = "v6-transfer-invariant-matcher-v1",
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
        multiScaleWidths: [Int] = [64, 32, 16]
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
    }

    public static let v6 = V6MatcherConfiguration()

    public func canonicalSHA256() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .throw
        return SHA256.hash(data: try encoder.encode(self))
            .map { String(format: "%02x", $0) }.joined()
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

    /// A flat proxy frame has no spatial ordering signal.  Keep this
    /// explicit so the shared matcher can use the descriptor-only fallback
    /// for synthetic/degenerate fixtures without changing the acceptance
    /// threshold or the normal transfer-invariant path.
    var isSpatiallyDegenerate: Bool {
        guard !luma.isEmpty else { return true }
        let mean = luma.reduce(0, +) / Float(luma.count)
        let variance = luma.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(luma.count)
        // Float accumulation on constant values can leave a small residual
        // (up to roughly 1e-10 for values near one); treat that numerical
        // residue as flat rather than discarding the descriptor fallback.
        return variance <= 1e-8
    }
}

enum V6TransferInvariantMatcher {
    static func features(
        _ luma: [Float], configuration: V6MatcherConfiguration
    ) -> V6MatcherFeatures {
        let gradient = gradients(
            luma, width: configuration.gridWidth, height: configuration.gridHeight
        )
        let threshold = medianAbsolute(gradient)
        let edgeMask = gradient.map { abs($0) >= threshold ? Float(1) : 0 }
        let scales = configuration.multiScaleWidths.map { width -> [Float] in
            let height = max(1, Int((Double(width) * Double(configuration.gridHeight) /
                Double(max(configuration.gridWidth, 1))).rounded()))
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
            rank: ranks(luma),
            gradient: gradient,
            edgeMask: edgeMask,
            localContrast: localContrast(
                luma, width: configuration.gridWidth, height: configuration.gridHeight
            ),
            scales: scales
        )
    }

    static func compare(
        _ lhs: V6MatcherFeatures,
        _ rhs: V6MatcherFeatures,
        configuration: V6MatcherConfiguration,
        descriptorFallback: (FrameDescriptor, FrameDescriptor)? = nil
    ) -> V6MatcherComponentMetrics {
        let luma = correlation(lhs.luma, rhs.luma)
        let rank = correlation(lhs.rank, rhs.rank)
        let gradient = correlation(lhs.gradient, rhs.gradient)
        let edge = correlation(lhs.edgeMask, rhs.edgeMask)
        let local = correlation(lhs.localContrast, rhs.localContrast)
        let multi = zip(lhs.scales, rhs.scales).map { correlation($0.0, $0.1) }
            .reduce(0, +) / Double(max(lhs.scales.count, 1))
        func positive(_ value: Double) -> Double { max(0, min(1, value)) }
        var confidence = positive(rank) * configuration.rankWeight +
            positive(gradient) * configuration.signedGradientWeight +
            positive(multi) * configuration.multiScaleNCCWeight +
            positive(edge) * configuration.edgeMaskWeight +
            positive(local) * configuration.localContrastWeight
        if lhs.isSpatiallyDegenerate && rhs.isSpatiallyDegenerate,
           let (lhsDescriptor, rhsDescriptor) = descriptorFallback {
            // Constant synthetic fixtures (and only those fixtures) do not
            // contain a spatial signal.  The pre-existing descriptor
            // distance still provides an exact temporal identity signal;
            // using it here keeps the common preflight/evaluator matcher
            // deterministic while retaining the fixed 0.60 gate.
            let distance = FrameDescriptorBuilder.alignmentDistance(lhsDescriptor, rhsDescriptor)
            confidence = positive(exp(-distance * 4))
        }
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

    private static func correlation(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.count > 1 else { return 0 }
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
        return denominator > 1e-12 ? max(-1, min(1, numerator / denominator)) : 0
    }

    private static func ranks(_ values: [Float]) -> [Float] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var result = Array(repeating: Float(0), count: values.count)
        for (rank, index) in order.enumerated() {
            result[index] = Float(rank) / Float(max(values.count - 1, 1))
        }
        return result
    }

    private static func gradients(_ values: [Float], width: Int, height: Int) -> [Float] {
        guard values.count == width * height, width > 1, height > 1 else { return [] }
        var result: [Float] = []
        result.reserveCapacity((width - 1) * (height - 1) * 2)
        for row in 0..<(height - 1) {
            for column in 0..<(width - 1) {
                let index = row * width + column
                result.append(values[index + 1] - values[index])
                result.append(values[index + width] - values[index])
            }
        }
        return result
    }

    private static func medianAbsolute(_ values: [Float]) -> Float {
        let sorted = values.map { abs($0) }.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private static func localContrast(_ values: [Float], width: Int, height: Int) -> [Float] {
        guard values.count == width * height else { return [] }
        var result = Array(repeating: Float(0), count: values.count)
        for row in 0..<height {
            for column in 0..<width {
                var total: Float = 0
                var count: Float = 0
                for y in max(0, row - 1)...min(height - 1, row + 1) {
                    for x in max(0, column - 1)...min(width - 1, column + 1) {
                        total += values[y * width + x]
                        count += 1
                    }
                }
                let index = row * width + column
                result[index] = values[index] - total / max(count, 1)
            }
        }
        return result
    }
}
