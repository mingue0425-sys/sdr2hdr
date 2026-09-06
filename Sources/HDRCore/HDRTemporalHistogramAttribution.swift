import Foundation
import simd

public enum HDRTemporalEstimatorVariant: String, CaseIterable, Codable, Sendable {
    /// The pre-8395ee4 frame-duration behavior. Passing no media timestamp to
    /// HDRTemporalControlState reproduces the calibrated 60 Hz alpha.
    case frameBased
    /// The current content-timestamp behavior.
    case timestampBased
}

public struct HDRSyntheticAttributionSequence: Sendable {
    public let name: String
    public let luminance: [Float]
    public let timestamps: [Double]
    public let histogramSamples: [[Float]]

    public init(
        name: String,
        luminance: [Float],
        timestamps: [Double],
        histogramSamples: [[Float]]
    ) {
        precondition(luminance.count == timestamps.count)
        precondition(luminance.count == histogramSamples.count)
        self.name = name
        self.luminance = luminance
        self.timestamps = timestamps
        self.histogramSamples = histogramSamples
    }

    public static func deterministicSet() -> [HDRSyntheticAttributionSequence] {
        func make(
            _ name: String,
            _ values: [Float],
            timestamps: [Double]? = nil
        ) -> HDRSyntheticAttributionSequence {
            let times = timestamps ?? values.indices.map { Double($0) / 60 }
            let samples = values.map { value in Array(repeating: value, count: 144) }
            return HDRSyntheticAttributionSequence(
                name: name,
                luminance: values,
                timestamps: times,
                histogramSamples: samples
            )
        }

        let ramp = stride(from: Float(0.02), through: 0.80, by: 0.02).map { $0 }
        let slow = stride(from: Float(0.08), through: 0.40, by: 0.01).map { $0 }
        return [
            make("static-gray", Array(repeating: 0.25, count: 24)),
            make("near-black-ramp", stride(from: Float(0.001), through: 0.05, by: 0.002).map { $0 }),
            make("static-gray-ramp", ramp),
            make("alternating-dark-bright", (0..<24).map { $0.isMultiple(of: 2) ? 0.04 : 0.85 }),
            make("slow-luminance-ramp", slow),
            make("abrupt-scene-cut", Array(repeating: 0.06, count: 12) + Array(repeating: 0.80, count: 12)),
            make(
                "vfr-ramp",
                [0.03, 0.05, 0.08, 0.12, 0.20, 0.35, 0.55, 0.80],
                timestamps: [0, 0.010, 0.050, 0.083, 0.250, 0.266, 0.500, 0.900]
            )
        ]
    }
}

public struct HDRSyntheticOutputSummary: Codable, Equatable, Sendable {
    public let meanAbsoluteRGBDelta: Float
    public let p95RGBDelta: Float
    public let p99RGBDelta: Float
    public let maxRGBDelta: Float
    public let meanAbsoluteLuminanceDelta: Float
    public let shadowLuminanceDelta: Float
    public let highlightLuminanceDelta: Float
    public let temporalFlicker: Float

    public init(
        meanAbsoluteRGBDelta: Float,
        p95RGBDelta: Float,
        p99RGBDelta: Float,
        maxRGBDelta: Float,
        meanAbsoluteLuminanceDelta: Float,
        shadowLuminanceDelta: Float,
        highlightLuminanceDelta: Float,
        temporalFlicker: Float
    ) {
        self.meanAbsoluteRGBDelta = meanAbsoluteRGBDelta
        self.p95RGBDelta = p95RGBDelta
        self.p99RGBDelta = p99RGBDelta
        self.maxRGBDelta = maxRGBDelta
        self.meanAbsoluteLuminanceDelta = meanAbsoluteLuminanceDelta
        self.shadowLuminanceDelta = shadowLuminanceDelta
        self.highlightLuminanceDelta = highlightLuminanceDelta
        self.temporalFlicker = temporalFlicker
    }

    public static let zero = HDRSyntheticOutputSummary(
        meanAbsoluteRGBDelta: 0,
        p95RGBDelta: 0,
        p99RGBDelta: 0,
        maxRGBDelta: 0,
        meanAbsoluteLuminanceDelta: 0,
        shadowLuminanceDelta: 0,
        highlightLuminanceDelta: 0,
        temporalFlicker: 0
    )
}

public struct HDRTemporalHistogramAttributionRow: Codable, Equatable, Sendable {
    public let sequenceName: String
    public let oldTemporalOldHistogram: HDRSyntheticOutputSummary
    public let newTemporalOldHistogram: HDRSyntheticOutputSummary
    public let oldTemporalNewHistogram: HDRSyntheticOutputSummary
    public let newTemporalNewHistogram: HDRSyntheticOutputSummary
    public let temporalOnly: HDRSyntheticOutputSummary
    public let histogramOnly: HDRSyntheticOutputSummary
    public let interaction: HDRSyntheticOutputSummary

    public init(
        sequenceName: String,
        oldTemporalOldHistogram: HDRSyntheticOutputSummary,
        newTemporalOldHistogram: HDRSyntheticOutputSummary,
        oldTemporalNewHistogram: HDRSyntheticOutputSummary,
        newTemporalNewHistogram: HDRSyntheticOutputSummary,
        temporalOnly: HDRSyntheticOutputSummary,
        histogramOnly: HDRSyntheticOutputSummary,
        interaction: HDRSyntheticOutputSummary
    ) {
        self.sequenceName = sequenceName
        self.oldTemporalOldHistogram = oldTemporalOldHistogram
        self.newTemporalOldHistogram = newTemporalOldHistogram
        self.oldTemporalNewHistogram = oldTemporalNewHistogram
        self.newTemporalNewHistogram = newTemporalNewHistogram
        self.temporalOnly = temporalOnly
        self.histogramOnly = histogramOnly
        self.interaction = interaction
    }
}

public enum HDRTemporalHistogramAttribution {
    public static func evaluate(
        _ sequence: HDRSyntheticAttributionSequence,
        configuration: HDRConfiguration = .calibratedV4
    ) -> HDRTemporalHistogramAttributionRow {
        let oldOld = render(
            sequence,
            temporalVariant: .frameBased,
            histogramStrategy: .linear16,
            configuration: configuration
        )
        let newOld = render(
            sequence,
            temporalVariant: .timestampBased,
            histogramStrategy: .linear16,
            configuration: configuration
        )
        let oldNew = render(
            sequence,
            temporalVariant: .frameBased,
            histogramStrategy: .linear64,
            configuration: configuration
        )
        let newNew = render(
            sequence,
            temporalVariant: .timestampBased,
            histogramStrategy: .linear64,
            configuration: configuration
        )
        return HDRTemporalHistogramAttributionRow(
            sequenceName: sequence.name,
            oldTemporalOldHistogram: .zero,
            newTemporalOldHistogram: summarize(difference: newOld, from: oldOld),
            oldTemporalNewHistogram: summarize(difference: oldNew, from: oldOld),
            newTemporalNewHistogram: summarize(difference: newNew, from: oldOld),
            temporalOnly: summarize(difference: newOld, from: oldOld),
            histogramOnly: summarize(difference: oldNew, from: oldOld),
            interaction: summarize(
                interaction: newNew,
                newTemporalOld: newOld,
                oldTemporalNew: oldNew,
                oldTemporalOld: oldOld
            )
        )
    }

    private static func render(
        _ sequence: HDRSyntheticAttributionSequence,
        temporalVariant: HDRTemporalEstimatorVariant,
        histogramStrategy: HDRSceneHistogramStrategy,
        configuration: HDRConfiguration
    ) -> [SIMD3<Float>] {
        var temporal = HDRTemporalControlState()
        return sequence.luminance.indices.map { index in
            _ = temporal.updateAutomaticAverage(
                averageLuminance: sequence.luminance[index],
                stability: configuration.temporalStability,
                sequence: UInt64(index + 1),
                timestampSeconds: temporalVariant == .timestampBased ? sequence.timestamps[index] : nil
            )
            let statistics = HDRSceneStatistics(
                linearSamples: sequence.histogramSamples[index],
                strategy: histogramStrategy
            )
            let signal = HDRColorMath.bt709(sequence.luminance[index])
            let output = HDRReference.process(
                signalRGB: SIMD3(repeating: signal),
                configuration: configuration,
                temporalAdaptation: temporal.adaptation,
                sceneStatistics: statistics
            )
            return SIMD3(output.x, output.y, output.z)
        }
    }

    private static func summarize(
        difference newer: [SIMD3<Float>],
        from older: [SIMD3<Float>]
    ) -> HDRSyntheticOutputSummary {
        let rgbDeltas = zip(newer, older).map { lhs, rhs in
            max(abs(lhs.x - rhs.x), max(abs(lhs.y - rhs.y), abs(lhs.z - rhs.z)))
        }
        let luminanceDeltas = zip(newer, older).map { lhs, rhs in
            abs(simd_dot(lhs, HDRColorMath.bt2020Luminance) - simd_dot(rhs, HDRColorMath.bt2020Luminance))
        }
        return makeSummary(rgbDeltas: rgbDeltas, luminanceDeltas: luminanceDeltas, values: newer)
    }

    private static func summarize(
        interaction newerNew: [SIMD3<Float>],
        newTemporalOld: [SIMD3<Float>],
        oldTemporalNew: [SIMD3<Float>],
        oldTemporalOld: [SIMD3<Float>]
    ) -> HDRSyntheticOutputSummary {
        let rgbDeltas = zip(zip(newerNew, newTemporalOld), zip(oldTemporalNew, oldTemporalOld)).map {
            let interaction = $0.0 - $0.1 - $1.0 + $1.1
            return max(abs(interaction.x), max(abs(interaction.y), abs(interaction.z)))
        }
        let luminanceDeltas = zip(zip(newerNew, newTemporalOld), zip(oldTemporalNew, oldTemporalOld)).map {
            let interaction = $0.0 - $0.1 - $1.0 + $1.1
            return abs(simd_dot(interaction, HDRColorMath.bt2020Luminance))
        }
        return makeSummary(rgbDeltas: rgbDeltas, luminanceDeltas: luminanceDeltas, values: newerNew)
    }

    private static func makeSummary(
        rgbDeltas: [Float],
        luminanceDeltas: [Float],
        values: [SIMD3<Float>]
    ) -> HDRSyntheticOutputSummary {
        func percentile(_ values: [Float], _ fraction: Double) -> Float {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)
            return sorted[index]
        }
        let flicker = zip(values.dropFirst(), values).map { current, previous in
            abs(simd_dot(current, HDRColorMath.bt2020Luminance) - simd_dot(previous, HDRColorMath.bt2020Luminance))
        }
        let shadow = luminanceDeltas.enumerated().filter { index, _ in index < luminanceDeltas.count && index < values.count && simd_dot(values[index], HDRColorMath.bt2020Luminance) < 0.25 }.map(\.element)
        let highlight = luminanceDeltas.enumerated().filter { index, _ in index < luminanceDeltas.count && index < values.count && simd_dot(values[index], HDRColorMath.bt2020Luminance) >= 0.75 }.map(\.element)
        return HDRSyntheticOutputSummary(
            meanAbsoluteRGBDelta: rgbDeltas.reduce(0, +) / Float(max(rgbDeltas.count, 1)),
            p95RGBDelta: percentile(rgbDeltas, 0.95),
            p99RGBDelta: percentile(rgbDeltas, 0.99),
            maxRGBDelta: rgbDeltas.max() ?? 0,
            meanAbsoluteLuminanceDelta: luminanceDeltas.reduce(0, +) / Float(max(luminanceDeltas.count, 1)),
            shadowLuminanceDelta: shadow.reduce(0, +) / Float(max(shadow.count, 1)),
            highlightLuminanceDelta: highlight.reduce(0, +) / Float(max(highlight.count, 1)),
            temporalFlicker: flicker.reduce(0, +) / Float(max(flicker.count, 1))
        )
    }
}
