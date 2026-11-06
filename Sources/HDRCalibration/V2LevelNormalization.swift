import Foundation
import HDRCore

/// Shape-only scoring.
///
/// HDR masters disagree on absolute brightness: diffuse white in Tune and
/// Validation masters ranges from about 4 to 450 nits. A single absolute
/// target therefore rewards matching one studio's level, not the mapping
/// shape. In EDR presentation the display's SDR white sets the absolute level.
///
/// Before scoring, each content family's generated output is scaled by one
/// gain fitted on source midtones. Every scene of every pair in the family
/// shares that gain, so differences between scenes still count.
///
/// Hard-safety observations (clipping, black crush, shadow lift and their
/// penalties) are always taken from the unscaled output.
public enum V2LevelNormalization: String, Codable, Sendable, CaseIterable {
    case familyMidtoneGainV1 = "family-midtone-gain-v1"

    /// Linear SDR source range whose pixels determine the gain (signal-defined).
    public static let fitSourceRange: ClosedRange<Double> = V2MetricsEvaluator.diffuseMidtoneSourceRange
    public static let gainRange: ClosedRange<Double> = 0.25...4.0
    /// Pixels darker than this in either image do not enter the fit.
    public static let fitFloorNits: Double = 0.5

    public init?(cliName: String) {
        switch cliName {
        case "off": return nil
        case "family-midtone-gain": self = .familyMidtoneGainV1
        default: return nil
        }
    }

    /// exp(median(log ref − log gen)) over midtone-source pixels, clamped.
    /// Returns 1 when no pixel qualifies.
    static func fitGain(_ frames: [V2FrameData]) -> Double {
        var logRatios: [Double] = []
        for frame in frames {
            let count = min(frame.sourceLuma.count, frame.reference.lumaNits.count, frame.generated.lumaNits.count)
            for index in 0..<count {
                let source = Double(frame.sourceLuma[index])
                let reference = Double(frame.reference.lumaNits[index])
                let generated = Double(frame.generated.lumaNits[index])
                guard source.isFinite, fitSourceRange.contains(source),
                      reference.isFinite, generated.isFinite,
                      reference >= fitFloorNits, generated >= fitFloorNits else { continue }
                logRatios.append(log(reference) - log(generated))
            }
        }
        guard !logRatios.isEmpty else { return 1 }
        logRatios.sort()
        let middle = logRatios.count / 2
        let median = logRatios.count % 2 == 1
            ? logRatios[middle]
            : (logRatios[middle - 1] + logRatios[middle]) / 2
        return min(max(exp(median), gainRange.lowerBound), gainRange.upperBound)
    }

    static func scaled(_ frame: V2FrameData, gain: Double) -> V2FrameData {
        let factor = Float(gain)
        let generated = frame.generated
        return V2FrameData(
            reference: frame.reference,
            generated: GeneratedFrame(
                timestampSeconds: generated.timestampSeconds,
                width: generated.width,
                height: generated.height,
                rgbNits: generated.rgbNits.map { $0 * factor },
                temporalAdaptationUsed: generated.temporalAdaptationUsed,
                sceneShadowFloorUsed: generated.sceneShadowFloorUsed,
                sceneShadowTopUsed: generated.sceneShadowTopUsed,
                sceneStatisticsValidUsed: generated.sceneStatisticsValidUsed
            ),
            sourceLuma: frame.sourceLuma,
            confidence: frame.confidence
        )
    }

    /// Shape-only breakdown, with every hard-safety observation taken from
    /// the unscaled (`absolute`) evaluation of the same frames.
    static func merge(shape: V2MetricBreakdown, absolute: V2MetricBreakdown) -> V2MetricBreakdown {
        var merged = shape
        merged.clippingRatio = absolute.clippingRatio
        merged.blackCrushRatio = absolute.blackCrushRatio
        merged.shadowLiftRatio = absolute.shadowLiftRatio
        merged.invalidSampleCount = absolute.invalidSampleCount
        for key in ["penalty_clipping", "penalty_black_crush", "penalty_invalid"] {
            merged.weightedContributions[key] = absolute.weightedContributions[key] ?? 0
        }
        merged.objective = merged.weightedContributions.values.reduce(0, +)
        return merged
    }
}
