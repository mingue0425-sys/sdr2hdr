import Foundation
import simd

/// Small scalar implementation used by mathematical and GPU correctness
/// tests. It is intentionally not used by HDRProcessor's realtime path.
public enum HDRReference {
    /// Processes an encoded source using the same metadata-to-policy resolver
    /// as HDRProcessor. This overload is the scalar/reference entry point for
    /// policy parity tests.
    public static func process(
        signalRGB: SIMD3<Float>,
        configuration: HDRConfiguration,
        sourceTransferTag: SDRSourceTransferTag,
        metadataTransfer: HDRTransferFunction? = nil,
        temporalAdaptation: Float = 1,
        sceneStatistics: HDRSceneStatistics? = nil
    ) throws -> SIMD4<Float> {
        let resolution = try SDRInputInterpretationResolver.resolve(
            sourceTransferTag: sourceTransferTag,
            metadataTransfer: metadataTransfer,
            requestedPolicy: configuration.sdrInterpretationPolicy,
            untaggedFallback: configuration.untaggedSDRFallback,
            bt1886Parameters: configuration.bt1886Parameters
        )
        return process(
            signalRGB: signalRGB,
            configuration: configuration,
            transferFunction: resolution.effectiveTransfer,
            temporalAdaptation: temporalAdaptation,
            sceneStatistics: sceneStatistics
        )
    }

    public static func toneExpand(
        _ luminance: Float,
        configuration: HDRConfiguration,
        temporalAdaptation: Float = 1,
        sceneStatistics: HDRSceneStatistics? = nil
    ) -> Float {
        let peakRatio = configuration.peakNits / configuration.paperWhiteNits
        let tone = configuration.toneMapping
        let y = min(
            max(luminance, Float(tone.inputLuminanceMinimum)),
            Float(tone.inputLuminanceMaximum)
        )
        let shoulderStart = Float(tone.shoulderStartBase) -
            Float(tone.shoulderContrastCoefficient) * configuration.contrastStrength
        let shoulderT = smoothstep(
            shoulderStart,
            Float(tone.inputLuminanceMaximum),
            y,
            tone: tone
        )
        // The production V4 curve intentionally applies the cubic easing
        // twice: once to normalize the shoulder interval and once to ease
        // the normalized shoulder response. Keep this separate from the
        // single cubic used by scene-anchor transitions.
        let shoulder = smoothstep(shoulderT, tone: tone)
        let strength = min(max(configuration.highlightStrength * temporalAdaptation, 0), 1)
        if configuration.toneCurveRevision == .legacyV2 {
            let shadowGate = smoothstep(
                Float(tone.legacyShadowGateLower),
                Float(tone.legacyShadowGateUpper),
                y,
                tone: tone
            )
            let protection = 1 - configuration.shadowProtection * (1 - shadowGate)
            let expansion = (peakRatio - 1) * strength * shoulder * y * protection
            return min(max(y + expansion, y), peakRatio)
        }
        if configuration.toneCurveRevision == .sceneRelativeV4 {
            let statistics = sceneStatistics ?? .neutral(using: tone.sceneStatistics)
            let shadowFloor = statistics.shadowFloor(using: tone.sceneStatistics)
            let shadowTop = statistics.shadowTop(using: tone.sceneStatistics)
            let shadowWeight = 1 - smoothstep(shadowFloor, shadowTop, y, tone: tone)

            // A small broad expansion gives shadowProtection a real, isolated
            // control axis. It is zero at black, grows through the
            // scene-relative shadow band, and is independent of the
            // highlight shoulder. The shoulder itself remains unchanged.
            let lowMidTransition = smoothstep(shadowFloor, shadowTop, y, tone: tone)
            let lowMidExpansion = (peakRatio - 1) * strength * Float(tone.sceneLowMidExpansionCoefficient) * lowMidTransition * y
            let shoulderExpansion = (peakRatio - 1) * strength * shoulder * y
            let protection = 1 - Float(tone.sceneShadowProtectionCoefficient) * configuration.shadowProtection * shadowWeight
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

        let shadowPresence = smoothstep(
            Float(tone.defaultShadowPresenceLower),
            Float(tone.defaultShadowPresenceUpper),
            y,
            tone: tone
        ) * (1 - smoothstep(
            Float(tone.defaultShadowFadeLower),
            Float(tone.defaultShadowFadeUpper),
            y,
            tone: tone
        ))
        let shadowAttenuation = Float(tone.defaultShadowAttenuationCoefficient) * configuration.shadowProtection * shadowPresence
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
            HDRColorMath.inverseTransfer(signal.x, function: transferFunction, colorScience: configuration.colorScience),
            HDRColorMath.inverseTransfer(signal.y, function: transferFunction, colorScience: configuration.colorScience),
            HDRColorMath.inverseTransfer(signal.z, function: transferFunction, colorScience: configuration.colorScience)
        )
        let luminance = max(simd_dot(linear, configuration.colorScience.bt709LuminanceVector), 0)
        let expandedLuminance = toneExpand(
            luminance,
            configuration: configuration,
            temporalAdaptation: temporalAdaptation,
            sceneStatistics: sceneStatistics
        )
        // A fixed denominator floor attenuates valid near-black light twice.
        // Positive RGB has positive luminance, so only exact black needs a guard.
        let gain = luminance > 0 ? expandedLuminance / luminance : 0
        var expanded = linear * gain
        let chromaReduction = highlightChromaReduction(
            expandedLuminance: expandedLuminance,
            configuration: configuration
        )
        expanded = simd_mix(expanded, SIMD3(repeating: expandedLuminance), SIMD3(repeating: min(max(chromaReduction, 0), 1)))

        var bt2020 = configuration.colorScience.bt709ToBT2020Matrix * expanded
        let outputPeakRatio = configuration.effectiveOutputHeadroom
        bt2020 = gamutCompress(
            bt2020,
            luminance: simd_dot(bt2020, configuration.colorScience.bt2020LuminanceVector),
            peakRatio: outputPeakRatio,
            tone: configuration.toneMapping
        )
        bt2020 = SIMD3<Float>(
            min(max(bt2020.x, Float(configuration.toneMapping.outputLuminanceMinimum)), outputPeakRatio),
            min(max(bt2020.y, Float(configuration.toneMapping.outputLuminanceMinimum)), outputPeakRatio),
            min(max(bt2020.z, Float(configuration.toneMapping.outputLuminanceMinimum)), outputPeakRatio)
        )

        switch configuration.outputMode {
        case .edr:
            return SIMD4(bt2020.x, bt2020.y, bt2020.z, 1)
        case .pq:
            return SIMD4(
                HDRColorMath.pqEncode(
                    nits: bt2020.x * configuration.paperWhiteNits,
                    definition: configuration.colorScience.pq
                ),
                HDRColorMath.pqEncode(
                    nits: bt2020.y * configuration.paperWhiteNits,
                    definition: configuration.colorScience.pq
                ),
                HDRColorMath.pqEncode(
                    nits: bt2020.z * configuration.paperWhiteNits,
                    definition: configuration.colorScience.pq
                ),
                1
            )
        }
    }

    private static func gamutCompress(
        _ rgb: SIMD3<Float>,
        luminance: Float,
        peakRatio: Float,
        tone: HDRToneMappingSemanticDefinition
    ) -> SIMD3<Float> {
        let safeLuminance = max(luminance, Float(tone.gamutLuminanceFloor))
        let minimum = min(rgb.x, min(rgb.y, rgb.z))
        let maximum = max(rgb.x, max(rgb.y, rgb.z))
        var chromaScale: Float = 1
        if minimum < 0, safeLuminance > 0 {
            chromaScale = min(chromaScale, safeLuminance / max(safeLuminance - minimum, Float(tone.gamutDenominatorFloor)))
        }
        if maximum > peakRatio, maximum > safeLuminance {
            chromaScale = min(chromaScale, max(peakRatio - safeLuminance, 0) / max(maximum - safeLuminance, Float(tone.gamutDenominatorFloor)))
        }
        return SIMD3(repeating: safeLuminance) + (rgb - SIMD3(repeating: safeLuminance)) * min(
            max(chromaScale, Float(tone.chromaScaleMinimum)),
            Float(tone.chromaScaleMaximum)
        )
    }

    /// Highlight-only chroma compression in the fixed tone-output domain.
    /// Internal visibility lets tests assert continuity independently of the
    /// GPU/reference pixel-parity checks.
    static func highlightChromaReduction(
        expandedLuminance: Float,
        configuration: HDRConfiguration
    ) -> Float {
        let peakRatio = configuration.peakNits / configuration.paperWhiteNits
        let tone = configuration.toneMapping
        return configuration.saturationCompensation *
            smoothstep(
                Float(tone.chromaReductionLuminanceStart),
                max(Float(tone.chromaReductionPeakRatioMinimum), peakRatio),
                expandedLuminance,
                tone: tone
            ) * Float(tone.chromaReductionCoefficient)
    }

    private static func smoothstep(
        _ edge0: Float,
        _ edge1: Float,
        _ value: Float,
        tone: HDRToneMappingSemanticDefinition
    ) -> Float {
        let denominator = max(edge1 - edge0, Float(tone.smoothstepDenominatorFloor))
        let t = min(max((value - edge0) / denominator, 0), 1)
        return t * t * (
            Float(tone.smoothstepLinearCoefficient) -
                Float(tone.smoothstepQuadraticCoefficient) * t
        )
    }

    private static func smoothstep(
        _ value: Float,
        tone: HDRToneMappingSemanticDefinition
    ) -> Float {
        let t = min(max(value, 0), 1)
        return t * t * (
            Float(tone.smoothstepLinearCoefficient) -
                Float(tone.smoothstepQuadraticCoefficient) * t
        )
    }
}
