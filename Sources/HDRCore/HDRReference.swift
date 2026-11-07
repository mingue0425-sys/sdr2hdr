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
        if configuration.toneCurveRevision == .sceneRelativeV6Candidate {
            return HDRV6ToneCurveMath.toneExpand(
                y,
                configuration: configuration,
                temporalAdaptation: temporalAdaptation,
                sceneStatistics: sceneStatistics
            )
        }
        if configuration.toneCurveRevision == .sceneAdaptiveV62Candidate {
            return HDRV62ToneCurveMath.toneExpand(
                y,
                configuration: configuration,
                temporalAdaptation: temporalAdaptation,
                sceneStatistics: sceneStatistics
            )
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
        inputPrimaries: HDRInputPrimaries = .bt709,
        temporalAdaptation: Float = 1,
        sceneStatistics: HDRSceneStatistics? = nil
    ) -> SIMD4<Float> {
        let signal = SIMD3<Float>(
            min(max(signalRGB.x, 0), 1),
            min(max(signalRGB.y, 0), 1),
            min(max(signalRGB.z, 0), 1)
        )
        let decode = transferFunction.interpreted(by: configuration.sdrTransferInterpretation)
        var linear = SIMD3<Float>(
            HDRColorMath.inverseTransfer(signal.x, function: decode),
            HDRColorMath.inverseTransfer(signal.y, function: decode),
            HDRColorMath.inverseTransfer(signal.z, function: decode)
        )
        if decode == .youtubeHLGInverseLuminanceGain {
            linear = HDRColorMath.youtubeHLGLuminanceGain(linear)
        }
        if let toBT709 = HDRColorMath.toBT709(inputPrimaries) {
            linear = simd_max(toBT709 * linear, SIMD3<Float>(repeating: 0))
        }
        let luminance = max(simd_dot(linear, HDRColorMath.bt709Luminance), 0)
        var expandedLuminance = toneExpand(
            luminance,
            configuration: configuration,
            temporalAdaptation: temporalAdaptation,
            sceneStatistics: sceneStatistics
        )
        // A fixed denominator floor attenuates valid near-black light twice.
        // Positive RGB has positive luminance, so only exact black needs a guard.
        var gain = luminance > 0 ? expandedLuminance / luminance : 0
        let ceiling = HDRConfiguration.skinHighlightCeiling
        if configuration.skinHighlightProtection > 0, expandedLuminance > ceiling {
            let weight = skinHighlightWeight(signal) * configuration.skinHighlightProtection
            if weight > 0 {
                let rolled = skinRolledLuminance(expandedLuminance, ceiling: ceiling)
                let protectedLuminance = expandedLuminance + (rolled - expandedLuminance) * weight
                gain *= protectedLuminance / expandedLuminance
                expandedLuminance = protectedLuminance
            }
        }
        var expanded = linear * gain
        let chromaReduction = highlightChromaReduction(
            expandedLuminance: expandedLuminance,
            configuration: configuration
        )
        expanded = simd_mix(expanded, SIMD3(repeating: expandedLuminance), SIMD3(repeating: min(max(chromaReduction, 0), 1)))

        var bt2020 = HDRColorMath.bt709ToBT2020 * expanded
        let outputPeakRatio = configuration.effectiveOutputHeadroom
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

    /// Compresses luminance above `ceiling` with a slope easing from 1 to
    /// 0.15. Mirrors the Metal `skinRolledLuminance`.
    static func skinRolledLuminance(_ y: Float, ceiling: Float) -> Float {
        let over = y - ceiling
        return over <= 0 ? y : ceiling + over * (0.15 + 0.85 * 0.15 / (0.15 + over))
    }

    /// How skin-like a signal RGB is (0...1). Mirrors the Metal
    /// `skinHighlightWeight`.
    static func skinHighlightWeight(_ s: SIMD3<Float>) -> Float {
        guard s.x >= s.y, s.y >= s.z else { return 0 }
        let range = s.x - s.z
        guard range > 1e-5, s.x > 1e-5 else { return 0 }
        let hue = 60 * (s.y - s.z) / range
        let saturation = range / s.x
        let hueWeight = smoothstep(3, 10, hue) * (1 - smoothstep(45, 55, hue))
        let saturationWeight = smoothstep(0.05, 0.12, saturation) * (1 - smoothstep(0.40, 0.55, saturation))
        return hueWeight * saturationWeight
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

    /// Highlight-only chroma compression in the fixed tone-output domain.
    /// Internal visibility lets tests assert continuity independently of the
    /// GPU/reference pixel-parity checks.
    static func highlightChromaReduction(
        expandedLuminance: Float,
        configuration: HDRConfiguration
    ) -> Float {
        let peakRatio = configuration.peakNits / configuration.paperWhiteNits
        return configuration.saturationCompensation *
            smoothstep(1, max(1.001, peakRatio), expandedLuminance) * 0.35
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        let denominator = max(edge1 - edge0, 1e-6)
        let t = min(max((value - edge0) / denominator, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
