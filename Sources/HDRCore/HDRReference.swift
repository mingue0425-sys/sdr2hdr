import Foundation
import simd

/// Small scalar implementation used by mathematical and GPU correctness
/// tests. It is intentionally not used by HDRProcessor's realtime path.
public enum HDRReference {
    public static func toneExpand(
        _ luminance: Float,
        configuration: HDRConfiguration,
        temporalAdaptation: Float = 1,
        sceneStatistics: HDRSceneStatistics? = nil
    ) -> Float {
        let peakRatio = configuration.peakNits / configuration.paperWhiteNits
        let y = min(max(luminance, 0), 1)
        let shoulderStart = 0.68 - 0.20 * configuration.contrastStrength
        let t = smoothstep(shoulderStart, 1, y)
        let shoulder = t * t * (3 - 2 * t)
        let strength = min(max(configuration.highlightStrength * temporalAdaptation, 0), 1)
        if configuration.toneCurveRevision == .legacyV2 {
            let shadowGate = smoothstep(0.035, 0.48, y)
            let protection = 1 - configuration.shadowProtection * (1 - shadowGate)
            let expansion = (peakRatio - 1) * strength * shoulder * y * protection
            return min(max(y + expansion, y), peakRatio)
        }
        if configuration.toneCurveRevision == .sceneRelativeV4 {
            let statistics = sceneStatistics ?? .neutral
            let shadowFloor = statistics.shadowFloor
            let shadowTop = statistics.shadowTop
            let shadowWeight = 1 - smoothstep(shadowFloor, shadowTop, y)

            // A small broad expansion gives shadowProtection a real, isolated
            // control axis. It is zero at black, grows through the
            // scene-relative shadow band, and is independent of the
            // highlight shoulder. The shoulder itself remains unchanged.
            let lowMidTransition = smoothstep(shadowFloor, shadowTop, y)
            let lowMidExpansion = (peakRatio - 1) * strength * 0.08 * lowMidTransition * y
            let shoulderExpansion = (peakRatio - 1) * strength * shoulder * y
            let protection = 1 - 0.90 * configuration.shadowProtection * shadowWeight
            let expanded = y + (lowMidExpansion + shoulderExpansion) * protection
            return min(max(expanded, y), peakRatio)
        }

        let shadowPresence = smoothstep(0.002, 0.025, y) * (1 - smoothstep(0.12, 0.48, y))
        let shadowAttenuation = 0.18 * configuration.shadowProtection * shadowPresence
        let protectedBase = y * (1 - shadowAttenuation)
        let expansion = (peakRatio - 1) * strength * shoulder * y
        return min(max(protectedBase + expansion, 0), peakRatio)
    }

    public static func process(
        signalRGB: SIMD3<Float>,
        configuration: HDRConfiguration,
        transferFunction: HDRTransferFunction = .bt709,
        temporalAdaptation: Float = 1,
        sceneStatistics: HDRSceneStatistics? = nil
    ) -> SIMD4<Float> {
        let signal = SIMD3<Float>(
            min(max(signalRGB.x, 0), 1),
            min(max(signalRGB.y, 0), 1),
            min(max(signalRGB.z, 0), 1)
        )
        let linear = SIMD3<Float>(
            HDRColorMath.inverseTransfer(signal.x, function: transferFunction),
            HDRColorMath.inverseTransfer(signal.y, function: transferFunction),
            HDRColorMath.inverseTransfer(signal.z, function: transferFunction)
        )
        let luminance = max(simd_dot(linear, HDRColorMath.bt709Luminance), 0)
        let expandedLuminance = toneExpand(
            luminance,
            configuration: configuration,
            temporalAdaptation: temporalAdaptation,
            sceneStatistics: sceneStatistics
        )
        let gain = expandedLuminance / max(luminance, 1e-6)
        var expanded = linear * gain
        let chromaReduction = configuration.saturationCompensation *
            smoothstep(1, max(1.001, expandedLuminance), expandedLuminance) * 0.35
        expanded = simd_mix(expanded, SIMD3(repeating: expandedLuminance), SIMD3(repeating: min(max(chromaReduction, 0), 1)))

        var bt2020 = HDRColorMath.bt709ToBT2020 * expanded
        let outputPeakRatio = configuration.outputMode == .edr
            ? min(configuration.peakNits / configuration.paperWhiteNits, configuration.masteringHeadroom)
            : configuration.peakNits / configuration.paperWhiteNits
        bt2020 = gamutCompress(bt2020, luminance: simd_dot(bt2020, HDRColorMath.bt2020Luminance), peakRatio: outputPeakRatio)
        bt2020 = SIMD3<Float>(
            min(max(bt2020.x, 0), outputPeakRatio),
            min(max(bt2020.y, 0), outputPeakRatio),
            min(max(bt2020.z, 0), outputPeakRatio)
        )

        switch configuration.outputMode {
        case .edr:
            return SIMD4(bt2020.x, bt2020.y, bt2020.z, 1)
        case .pq:
            return SIMD4(
                HDRColorMath.pqEncode(nits: bt2020.x * configuration.paperWhiteNits),
                HDRColorMath.pqEncode(nits: bt2020.y * configuration.paperWhiteNits),
                HDRColorMath.pqEncode(nits: bt2020.z * configuration.paperWhiteNits),
                1
            )
        }
    }

    private static func gamutCompress(_ rgb: SIMD3<Float>, luminance: Float, peakRatio: Float) -> SIMD3<Float> {
        let safeLuminance = max(luminance, 0)
        let minimum = min(rgb.x, min(rgb.y, rgb.z))
        let maximum = max(rgb.x, max(rgb.y, rgb.z))
        var chromaScale: Float = 1
        if minimum < 0, safeLuminance > 0 {
            chromaScale = min(chromaScale, safeLuminance / max(safeLuminance - minimum, 1e-6))
        }
        if maximum > peakRatio, maximum > safeLuminance {
            chromaScale = min(chromaScale, max(peakRatio - safeLuminance, 0) / max(maximum - safeLuminance, 1e-6))
        }
        return SIMD3(repeating: safeLuminance) + (rgb - SIMD3(repeating: safeLuminance)) * min(max(chromaScale, 0), 1)
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let denominator = max(edge1 - edge0, 1e-6)
        let t = min(max((value - edge0) / denominator, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
