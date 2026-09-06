import Foundation

/// Observation-only measurements for comparing scene histogram layouts. This
/// type deliberately stays outside HDRProcessor's realtime path: production
/// continues to decode the strategy carried by HDRConfiguration, while these
/// measurements use the same finite sample array for every candidate.
public struct HDRSceneHistogramStrategyMeasurement: Codable, Equatable, Sendable {
    public let strategy: HDRSceneHistogramStrategy
    public let p01: Float
    public let p05: Float
    public let p10: Float
    public let p25: Float
    public let p50: Float
    public let shadowFloor: Float
    public let shadowTop: Float
    public let meanAbsolutePercentileError: Float
    public let maximumAbsolutePercentileError: Float
    public let oneSamplePerturbationDelta: Float

    public init(
        strategy: HDRSceneHistogramStrategy,
        p01: Float,
        p05: Float,
        p10: Float,
        p25: Float,
        p50: Float,
        shadowFloor: Float,
        shadowTop: Float,
        meanAbsolutePercentileError: Float,
        maximumAbsolutePercentileError: Float,
        oneSamplePerturbationDelta: Float
    ) {
        self.strategy = strategy
        self.p01 = p01
        self.p05 = p05
        self.p10 = p10
        self.p25 = p25
        self.p50 = p50
        self.shadowFloor = shadowFloor
        self.shadowTop = shadowTop
        self.meanAbsolutePercentileError = meanAbsolutePercentileError
        self.maximumAbsolutePercentileError = maximumAbsolutePercentileError
        self.oneSamplePerturbationDelta = oneSamplePerturbationDelta
    }
}

public struct HDRHistogramStrategySeparability: Codable, Equatable, Sendable {
    public let strategy: HDRSceneHistogramStrategy
    public let p50Distance: Float
    public let shadowFloorDistance: Float
    public let shadowTopDistance: Float

    public init(
        strategy: HDRSceneHistogramStrategy,
        p50Distance: Float,
        shadowFloorDistance: Float,
        shadowTopDistance: Float
    ) {
        self.strategy = strategy
        self.p50Distance = p50Distance
        self.shadowFloorDistance = shadowFloorDistance
        self.shadowTopDistance = shadowTopDistance
    }
}

public enum HDRSceneHistogramDiagnostics {
    public static let requiredPercentiles = [0.01, 0.05, 0.10, 0.25] as [Double]

    /// Builds the synthetic distributions used by correctness tests and the
    /// offline estimator report. Values are linear BT.709 luminance.
    public static func syntheticDistributions() -> [String: [Float]] {
        func repeated(_ value: Float, count: Int = 144) -> [Float] {
            Array(repeating: value, count: count)
        }
        let mixed = repeated(0.001, count: 24) +
            repeated(0.01, count: 24) +
            repeated(0.05, count: 24) +
            repeated(0.20, count: 24) +
            repeated(0.50, count: 24) +
            repeated(0.90, count: 24)
        let bimodal = repeated(0.003, count: 72) + repeated(0.95, count: 72)
        return [
            "A_near_black": repeated(0.001),
            "B_deep_shadow": repeated(0.005),
            "C_shadow": repeated(0.010),
            "D_lifted_shadow": repeated(0.025),
            "E_dark_mid": repeated(0.050),
            "F_mixed": mixed,
            "G_bimodal": bimodal
        ]
    }

    public static func measure(
        samples: [Float],
        strategy: HDRSceneHistogramStrategy,
        perturbationIndex: Int = 0,
        perturbationDelta: Float = 0.001
    ) -> HDRSceneHistogramStrategyMeasurement {
        let finite = samples.filter(\.isFinite)
        let exact = HDRSceneStatistics(samples: finite)
        let estimated = HDRSceneStatistics(linearSamples: finite, strategy: strategy)
        let exactValues = [exact.p01, exact.p05, exact.p10, exact.p25]
        let estimatedValues = [estimated.p01, estimated.p05, estimated.p10, estimated.p25]
        let errors = zip(exactValues, estimatedValues).map { abs($0 - $1) }

        var perturbed = finite
        if !perturbed.isEmpty {
            let index = min(max(perturbationIndex, 0), perturbed.count - 1)
            perturbed[index] = min(max(perturbed[index] + perturbationDelta, 0), 1)
        }
        let perturbedStatistics = HDRSceneStatistics(linearSamples: perturbed, strategy: strategy)
        let perturbationDelta = zip(
            [estimated.p01, estimated.p05, estimated.p10, estimated.p25],
            [perturbedStatistics.p01, perturbedStatistics.p05, perturbedStatistics.p10, perturbedStatistics.p25]
        ).map { abs($0 - $1) }.max() ?? 0

        return HDRSceneHistogramStrategyMeasurement(
            strategy: strategy,
            p01: estimated.p01,
            p05: estimated.p05,
            p10: estimated.p10,
            p25: estimated.p25,
            p50: estimated.p50,
            shadowFloor: estimated.shadowFloor,
            shadowTop: estimated.shadowTop,
            meanAbsolutePercentileError: errors.reduce(0, +) / Float(max(errors.count, 1)),
            maximumAbsolutePercentileError: errors.max() ?? 0,
            oneSamplePerturbationDelta: perturbationDelta
        )
    }

    public static func separability(
        lower: [Float],
        upper: [Float],
        strategy: HDRSceneHistogramStrategy
    ) -> HDRHistogramStrategySeparability {
        let a = HDRSceneStatistics(linearSamples: lower, strategy: strategy)
        let b = HDRSceneStatistics(linearSamples: upper, strategy: strategy)
        return HDRHistogramStrategySeparability(
            strategy: strategy,
            p50Distance: abs(a.p50 - b.p50),
            shadowFloorDistance: abs(a.shadowFloor - b.shadowFloor),
            shadowTopDistance: abs(a.shadowTop - b.shadowTop)
        )
    }
}
