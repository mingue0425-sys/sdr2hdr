import Foundation

/// Observation-only scalar sweep for the production V2/V4 tone curves.
///
/// This mirrors the arithmetic in `SDRToHDR.metal` so a report can show the
/// contribution of each V4 term at selected input luminances. It is never
/// called by HDRProcessor's realtime path and it does not alter a
/// configuration or a shader parameter.
public struct HDRToneCurveSweepRow: Codable, Equatable, Sendable {
    public let inputLuminance: Float
    public let v2OutputLuminance: Float
    public let v4OutputLuminance: Float
    public let v4LowMidContribution: Float
    public let v4ShoulderContribution: Float
    public let v4TotalGain: Float
    public let v4ToV2Ratio: Float
    public let lowMidTransition: Float
    public let shoulder: Float

    public init(
        inputLuminance: Float,
        v2OutputLuminance: Float,
        v4OutputLuminance: Float,
        v4LowMidContribution: Float,
        v4ShoulderContribution: Float,
        v4TotalGain: Float,
        v4ToV2Ratio: Float,
        lowMidTransition: Float,
        shoulder: Float
    ) {
        self.inputLuminance = inputLuminance
        self.v2OutputLuminance = v2OutputLuminance
        self.v4OutputLuminance = v4OutputLuminance
        self.v4LowMidContribution = v4LowMidContribution
        self.v4ShoulderContribution = v4ShoulderContribution
        self.v4TotalGain = v4TotalGain
        self.v4ToV2Ratio = v4ToV2Ratio
        self.lowMidTransition = lowMidTransition
        self.shoulder = shoulder
    }
}

public struct HDRSceneAnchorSweepRow: Codable, Equatable, Sendable {
    public let inputLuminance: Float
    public let lowMidTransition: Float

    public init(inputLuminance: Float, lowMidTransition: Float) {
        self.inputLuminance = inputLuminance
        self.lowMidTransition = lowMidTransition
    }
}

public enum HDRDiagnosticToneSweep {
    public static let luminanceGrid: [Float] = [
        0.02, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40,
        0.45, 0.50, 0.55, 0.60, 0.70, 0.80, 0.90, 1.00
    ]

    public static let sceneAnchorGrid: [Float] = [
        0.02, 0.03, 0.04, 0.05, 0.06, 0.08, 0.10, 0.20, 0.30, 0.40, 0.50
    ]

    public static func rows(
        temporalAdaptationV2: Float = 0.965,
        temporalAdaptationV4: Float = 0.965,
        sceneShadowFloor: Float = 0.03125,
        sceneShadowTop: Float = 0.05625,
        sceneStatisticsValid: Bool = true,
        luminances: [Float] = luminanceGrid
    ) -> [HDRToneCurveSweepRow] {
        let v2 = HDRConfiguration.calibratedV2
        let v4 = HDRConfiguration.calibratedV4
        let v4Statistics = HDRSceneStatistics(
            p01: sceneShadowFloor,
            p05: sceneShadowFloor,
            p10: sceneShadowFloor,
            // HDRSceneStatistics.shadowTop = p10 + 0.5 * (p25 - p10).
            // Choose p25 so the reference implementation has the exact
            // runtime anchor supplied to this diagnostic sweep.
            p25: 2 * sceneShadowTop - sceneShadowFloor,
            p50: 0.42,
            p90: 0.88,
            p99: 1.0
        )

        return luminances.map { y in
            let v2Output = HDRReference.toneExpand(
                y,
                configuration: v2,
                temporalAdaptation: temporalAdaptationV2
            )
            let v4Breakdown = v4Breakdown(
                luminance: y,
                configuration: v4,
                temporalAdaptation: temporalAdaptationV4,
                sceneShadowFloor: sceneShadowFloor,
                sceneShadowTop: sceneShadowTop,
                sceneStatisticsValid: sceneStatisticsValid,
                lowMidCoefficient: 0.08
            )
            let v4Output = HDRReference.toneExpand(
                y,
                configuration: v4,
                temporalAdaptation: temporalAdaptationV4,
                sceneStatistics: sceneStatisticsValid ? v4Statistics : nil
            )
            return HDRToneCurveSweepRow(
                inputLuminance: y,
                v2OutputLuminance: v2Output,
                v4OutputLuminance: v4Output,
                v4LowMidContribution: v4Breakdown.lowMidContribution,
                v4ShoulderContribution: v4Breakdown.shoulderContribution,
                v4TotalGain: v4Output / max(y, 1e-6),
                v4ToV2Ratio: v4Output / max(v2Output, 1e-6),
                lowMidTransition: v4Breakdown.lowMidRise,
                shoulder: v4Breakdown.shoulder
            )
        }
    }

    public static func sceneAnchorRows(
        sceneShadowFloor: Float = 0.03125,
        sceneShadowTop: Float = 0.05625,
        sceneStatisticsValid: Bool = true,
        luminances: [Float] = sceneAnchorGrid
    ) -> [HDRSceneAnchorSweepRow] {
        let floor = sceneStatisticsValid ? min(max(sceneShadowFloor, 0.001), 0.20) : 0.01
        var top = sceneStatisticsValid ? max(sceneShadowTop, floor + 0.025) : 0.1125
        top = min(top, 0.60)
        return luminances.map { y in
            HDRSceneAnchorSweepRow(
                inputLuminance: y,
                lowMidTransition: smoothStep(floor, top, y)
            )
        }
    }

    public static func shoulderStart(configuration: HDRConfiguration = .calibratedV4) -> Float {
        0.68 - 0.20 * min(max(configuration.contrastStrength, 0), 1)
    }

    public static func lowMidAsymptoticGain(
        configuration: HDRConfiguration = .calibratedV4,
        temporalAdaptation: Float
    ) -> Float {
        let peakRatio = configuration.peakNits / configuration.paperWhiteNits
        let strength = min(max(configuration.highlightStrength * temporalAdaptation, 0), 1)
        return 1 + (peakRatio - 1) * strength * 0.08
    }

    /// Observation-only V4 scalar decomposition.  The optional coefficient
    /// override exists solely for V6.1 error-surface diagnostics; the
    /// production V4 shader and reference arithmetic continue to use 0.08.
    public static func v4Breakdown(
        luminance: Float,
        configuration: HDRConfiguration = .calibratedV4,
        temporalAdaptation: Float = 1,
        sceneShadowFloor: Float = 0.03125,
        sceneShadowTop: Float = 0.05625,
        sceneStatisticsValid: Bool = true,
        lowMidCoefficient: Float = 0.08
    ) -> HDRToneCurveScalarBreakdown {
        let y = min(max(luminance, 0), 1)
        let shoulderStart = shoulderStart(configuration: configuration)
        // SDRToHDR.metal first computes smoothStepSafe and then applies the
        // cubic remap to that result. Keep this observation-only mirror exact
        // so the V4 endpoint is comparable with HDRReference and Metal.
        let shoulderT = smoothStep(shoulderStart, 1, y)
        let shoulder = shoulderT * shoulderT * (3 - 2 * shoulderT)
        let floor = sceneStatisticsValid ? min(max(sceneShadowFloor, 0.001), 0.20) : 0.01
        var top = sceneStatisticsValid ? max(sceneShadowTop, floor + 0.025) : 0.1125
        top = min(top, 0.60)
        let lowMidTransition = smoothStep(floor, top, y)
        let peakRatio = configuration.peakNits / configuration.paperWhiteNits
        let strength = min(max(configuration.highlightStrength * temporalAdaptation, 0), 1)
        let shadowWeight = 1 - lowMidTransition
        let protection = 1 - 0.90 * min(max(configuration.shadowProtection, 0), 1) * shadowWeight
        let lowMid = max(
            (peakRatio - 1) * strength * max(lowMidCoefficient, 0) * lowMidTransition * y * protection,
            0
        )
        let shoulderTerm = max((peakRatio - 1) * strength * shoulder * y * protection, 0)
        let expanded = min(max(y + lowMid + shoulderTerm, y), peakRatio)
        return HDRToneCurveScalarBreakdown(
            inputLuminance: y,
            expandedLuminance: expanded,
            lowMidContribution: lowMid,
            shoulderContribution: shoulderTerm,
            shadowProtectionFactor: protection,
            effectiveStrength: strength,
            lowMidRise: lowMidTransition,
            lowMidFall: 1,
            lowMidBand: lowMidTransition,
            lowMidFadeStart: top,
            shadowFloor: floor,
            shadowTop: top,
            shoulderStart: shoulderStart,
            shoulder: shoulder
        )
    }

    private static func smoothStep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let denominator = max(edge1 - edge0, 1e-6)
        let t = min(max((value - edge0) / denominator, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
