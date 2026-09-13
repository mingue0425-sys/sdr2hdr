import Foundation
import HDRCore
import simd

struct V2FrameData {
    let reference: ReferenceFrame
    let generated: GeneratedFrame
    let sourceLuma: [Float]
    let confidence: Double
}

public enum PerceptualColorV2 {
    public static func ictcp(
        rgbNits: SIMD3<Float>,
        configuration: V2MetricSemanticConfiguration = .current
    ) -> SIMD3<Double> {
        let rgb = SIMD3<Double>(
            max(Double(rgbNits.x), configuration.perceptualColorInputMinimumNits),
            max(Double(rgbNits.y), configuration.perceptualColorInputMinimumNits),
            max(Double(rgbNits.z), configuration.perceptualColorInputMinimumNits)
        )
        let l = (1688.0 * rgb.x + 2146.0 * rgb.y + 262.0 * rgb.z) / 4096.0
        let m = (683.0 * rgb.x + 2951.0 * rgb.y + 462.0 * rgb.z) / 4096.0
        let s = (99.0 * rgb.x + 309.0 * rgb.y + 3688.0 * rgb.z) / 4096.0
        let lp = Double(HDRColorMath.pqEncode(nits: Float(min(max(l, configuration.perceptualColorInputMinimumNits), configuration.perceptualColorInputMaximumNits))))
        let mp = Double(HDRColorMath.pqEncode(nits: Float(min(max(m, configuration.perceptualColorInputMinimumNits), configuration.perceptualColorInputMaximumNits))))
        let sp = Double(HDRColorMath.pqEncode(nits: Float(min(max(s, configuration.perceptualColorInputMinimumNits), configuration.perceptualColorInputMaximumNits))))
        let i = (2048.0 * lp + 2048.0 * mp) / 4096.0
        let ct = (6610.0 * lp - 13613.0 * mp + 7003.0 * sp) / 4096.0
        let cp = (17933.0 * lp - 17390.0 * mp - 543.0 * sp) / 4096.0
        return SIMD3(i, ct, cp)
    }

    public static func hueError(
        reference: SIMD3<Float>,
        generated: SIMD3<Float>,
        configuration: V2MetricSemanticConfiguration = .current
    ) -> Double {
        let ref = ictcp(rgbNits: reference, configuration: configuration)
        let gen = ictcp(rgbNits: generated, configuration: configuration)
        let refHue = atan2(ref.z, ref.y)
        let genHue = atan2(gen.z, gen.y)
        var delta = abs(refHue - genHue)
        if delta > .pi { delta = 2 * .pi - delta }
        return delta / .pi
    }
}

enum V2MetricsEvaluator {
    /// Generic linear SDR source range used by the V6 development diagnostic.
    /// It starts above the observed scene-relative shadow anchors and ends
    /// below the calibrated V4 shoulder start, leaving margin on both sides.
    /// The range is signal-defined and contains no face/skin classification.
    static var diffuseMidtoneSourceRange: ClosedRange<Double> {
        let range = V2MetricSemanticConfiguration.current.diffuseMidtoneSourceRange
        return range.lowerPercentile...range.upperPercentile
    }

    static func evaluateScene(
        pairID: String,
        scene: SceneRange,
        frames: [V2FrameData],
        configuration: CalibrationParameters,
        metricConfiguration: V2MetricSemanticConfiguration
    ) -> V2SceneEvaluation {
        // The preregistered execution path supplies this exact object from
        // its sealed semantic definition. Legacy callers use the overload
        // below and remain visibly separate from that path.
        let weights = metricConfiguration.objectiveWeights
        let lumaPairs = pairedFiniteLuminance(frames)
        let pairedReference = lumaPairs.reference
        let pairedGenerated = lumaPairs.generated
        let refPercentiles = percentiles(pairedReference, configuration: metricConfiguration)
        let genPercentiles = percentiles(pairedGenerated, configuration: metricConfiguration)

        let luminanceError = logError(
            pairedReference, pairedGenerated,
            offset: metricConfiguration.additiveLuminanceOffsetNits,
            invalidValue: metricConfiguration.invalidMetricScore
        )
        let absoluteNitError = meanZip(
            pairedReference, pairedGenerated,
            emptyValue: metricConfiguration.invalidMetricScore
        ) { abs($0 - $1) / metricConfiguration.absoluteNitsNormalizer }
        let midtoneError = regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["midtone"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore)
        let diffuseWhiteError = regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["diffuseWhite"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore)
        let highlightError = regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["highlight"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore)
        let shadowError = regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["shadow"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore)
        let diffuseMidtone = diffuseMidtoneMetrics(frames, configuration: metricConfiguration)
        let regionErrors = [
            "p0_p1": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p0_p1"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore),
            "p1_p10": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p1_p10"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore),
            "p10_p50": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p10_p50"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore),
            "p50_p90": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p50_p90"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore),
            "p90_p99": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p90_p99"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore),
            "p99_p100": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p99_p100"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore),
            "diffuse_midtone": diffuseMidtone.error,
            "diffuse_midtone_signed": diffuseMidtone.signed,
            "diffuse_midtone_positive_overshoot": diffuseMidtone.positive,
            "diffuse_midtone_negative_undershoot": diffuseMidtone.negative,
            "diffuse_midtone_mae": diffuseMidtone.mae,
            "diffuse_midtone_overshoot": diffuseMidtone.overshoot,
            "diffuse_midtone_overshoot_p95": diffuseMidtone.overshootP95,
            "diffuse_midtone_sample_count": Double(diffuseMidtone.sampleCount)
        ]

        // Reuse the scene percentiles computed above.  In particular, do not
        // calculate a percentile from inside a per-pixel filter: that turns a
        // diagnostic-only observation into an accidental O(n^2 log n) path.
        let highlightThreshold = refPercentiles.p90
        let highlightPairs = zip(pairedReference, pairedGenerated).filter { $0.0 >= highlightThreshold }
        let highlightUnderReach = fraction(highlightPairs) { $0.1 < $0.0 * metricConfiguration.highlightUnderreachRatio }
        let highlightOvershoot = fraction(highlightPairs) {
            $0.1 > max(
                $0.0 * metricConfiguration.highlightOvershootRatio,
                $0.0 + metricConfiguration.highlightOvershootAbsoluteNits
            )
        }
        let specularReference = percentile(pairedReference, metricConfiguration.specularPercentile)
        let specularGenerated = percentile(pairedGenerated, metricConfiguration.specularPercentile)
        let specularUnder = max(specularReference - specularGenerated, metricConfiguration.nonNegativeClampFloor) /
            max(specularReference, metricConfiguration.slopeFloorNits)
        let specularOver = max(specularGenerated - specularReference, metricConfiguration.nonNegativeClampFloor) /
            max(specularReference, metricConfiguration.slopeFloorNits)
        let referenceSlope = max(refPercentiles.p99 - refPercentiles.p90, metricConfiguration.slopeFloorNits)
        let generatedSlope = max(genPercentiles.p99 - genPercentiles.p90, metricConfiguration.nonNegativeClampFloor)
        let compressionError = abs(generatedSlope / referenceSlope - 1)
        let clipping = pairedGenerated.isEmpty ? 0 : Double(pairedGenerated.filter {
            $0 >= Double(configuration.peakNits) * metricConfiguration.clippingPeakRatio
        }.count) / Double(pairedGenerated.count)

        let shadowPairs = zip(pairedReference, pairedGenerated).filter { $0.0 <= refPercentiles.p10 }
        let blackCrush = fraction(shadowPairs) {
            $0.0 > metricConfiguration.blackCrushReferenceThresholdNits &&
            $0.1 < min(
                metricConfiguration.blackCrushGeneratedAbsoluteNits,
                $0.0 * metricConfiguration.blackCrushGeneratedRatio
            )
        }
        let shadowLift = fraction(shadowPairs) {
            $0.1 > max(
                $0.0 * metricConfiguration.shadowLiftRatio,
                $0.0 + metricConfiguration.shadowLiftAbsoluteNits
            )
        }
        let referenceNearBlackRange = max(
            refPercentiles.p10 - refPercentiles.p1,
            metricConfiguration.nearBlackReferenceRangeFloorNits
        )
        let generatedNearBlackRange = max(genPercentiles.p10 - genPercentiles.p1, metricConfiguration.nonNegativeClampFloor)
        let nearBlackContrastLoss = max(1 - generatedNearBlackRange / referenceNearBlackRange, metricConfiguration.nonNegativeClampFloor)

        let color = colorMetrics(frames, configuration: metricConfiguration)
        let temporal = temporalMetrics(frames, configuration: metricConfiguration)
        let structure = structureError(
            frames,
            epsilon: metricConfiguration.correlationEpsilon,
            lowerBound: metricConfiguration.correlationLowerBound,
            upperBound: metricConfiguration.correlationUpperBound
        )
        let invalidCount = invalidPairedPixelCount(frames)

        var contributions: [String: Double] = [
            "luminance": weights.luminance * finite(luminanceError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "absolute_nits": weights.absoluteNits * finite(absoluteNitError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "midtone": weights.midtone * finite(midtoneError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "diffuse_white": weights.diffuseWhite * finite(diffuseWhiteError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "highlight": weights.highlight * finite(highlightError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "shadow": weights.shadow * finite(shadowError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "chroma": weights.chroma * finite(color.chroma, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "saturation": weights.saturation * finite(color.saturation, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "hue": weights.hue * finite(color.hueMean * metricConfiguration.hueMeanWeight + color.hueP95 * metricConfiguration.hueP95Weight, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "temporal": weights.temporal * finite(temporal.luminance * metricConfiguration.temporalLuminanceWeight + temporal.highlight * metricConfiguration.temporalHighlightWeight + temporal.flicker * metricConfiguration.temporalFlickerWeight, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "structure": weights.structure * finite(structure, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "penalty_clipping": weights.clippingPenalty * clipping,
            "penalty_black_crush": weights.blackCrushPenalty * blackCrush,
            "penalty_saturation": weights.saturationPenalty * color.overSaturation,
            "penalty_invalid": weights.invalidPenalty * Double(invalidCount)
        ]
        contributions = contributions.mapValues {
            finite($0, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration)
        }
        let objective = contributions.values.reduce(0, +)
        let breakdown = V2MetricBreakdown(
            objective: objective,
            luminanceError: finite(luminanceError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            absoluteNitError: finite(absoluteNitError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            midtoneError: finite(midtoneError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            diffuseWhiteError: finite(diffuseWhiteError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            highlightError: finite(highlightError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            shadowError: finite(shadowError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            chromaError: finite(color.chroma, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            saturationError: finite(color.saturation, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            hueMeanError: finite(color.hueMean, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            hueP95Error: finite(color.hueP95, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            highChromaHueError: finite(color.highChromaHue, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            skinLikeHueError: finite(color.skinHue, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            temporalLuminanceError: finite(temporal.luminance, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            highlightPumping: finite(temporal.highlight, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            temporalFlicker: finite(temporal.flicker, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            sceneCutOvershoot: 0,
            sceneCutRecovery: 0,
            structureError: finite(structure, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            clippingRatio: clipping,
            blackCrushRatio: blackCrush,
            shadowLiftRatio: shadowLift,
            nearBlackContrastLoss: finite(nearBlackContrastLoss, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            highlightUnderReachRatio: highlightUnderReach,
            highlightOvershootRatio: highlightOvershoot,
            highlightCompressionError: finite(compressionError, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            specularPeakUnderReach: finite(specularUnder, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            specularPeakOvershoot: finite(specularOver, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            referenceDiffuseWhiteNits: finite(percentile(pairedReference, metricConfiguration.percentileFractions["p90"]!), invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            generatedDiffuseWhiteNits: finite(percentile(pairedGenerated, metricConfiguration.percentileFractions["p90"]!), invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            overSaturationRatio: color.overSaturation,
            underSaturationRatio: color.underSaturation,
            invalidSampleCount: invalidCount,
            // Region diagnostics include a signed log residual. Clamping that
            // value to zero erases under-prediction without changing the score.
            luminanceRegionErrors: regionErrors.mapValues {
                $0.isFinite ? $0 : metricConfiguration.invalidMetricScore
            },
            weightedContributions: contributions
        )
        let confidence = frames.isEmpty ? 0 : frames.map(\.confidence).reduce(0, +) / Double(frames.count)
        return V2SceneEvaluation(
            pairID: pairID,
            sceneID: scene.id,
            tags: scene.tags,
            frameCount: frames.count,
            alignmentConfidence: confidence,
            referenceLuminance: refPercentiles,
            generatedLuminance: genPercentiles,
            metrics: breakdown,
            failures: failureTaxonomy(metrics: breakdown, confidence: confidence, configuration: metricConfiguration)
        )
    }

    static func evaluateScene(
        pairID: String,
        scene: SceneRange,
        frames: [V2FrameData],
        configuration: CalibrationParameters,
        weights: V2ObjectiveWeights
    ) -> V2SceneEvaluation {
        var metricConfiguration = V2MetricSemanticConfiguration.current
        metricConfiguration.objectiveWeights = weights
        return evaluateScene(
            pairID: pairID,
            scene: scene,
            frames: frames,
            configuration: configuration,
            metricConfiguration: metricConfiguration
        )
    }

    static func aggregate(
        _ values: [V2MetricBreakdown],
        configuration: V2MetricSemanticConfiguration = .current
    ) -> V2MetricBreakdown {
        guard !values.isEmpty else {
            return zeroMetric(
                invalid: configuration.emptyAggregateInvalidSampleCount,
                configuration: configuration
            )
        }
        func average(_ key: (V2MetricBreakdown) -> Double) -> Double {
            values.map(key).reduce(0, +) / Double(values.count)
        }
        let contributionKeys = Set(values.flatMap { $0.weightedContributions.keys })
        let regionKeys = Set(values.flatMap { $0.luminanceRegionErrors.keys })
        return V2MetricBreakdown(
            objective: average(\.objective),
            luminanceError: average(\.luminanceError),
            absoluteNitError: average(\.absoluteNitError),
            midtoneError: average(\.midtoneError),
            diffuseWhiteError: average(\.diffuseWhiteError),
            highlightError: average(\.highlightError),
            shadowError: average(\.shadowError),
            chromaError: average(\.chromaError),
            saturationError: average(\.saturationError),
            hueMeanError: average(\.hueMeanError),
            hueP95Error: average(\.hueP95Error),
            highChromaHueError: average(\.highChromaHueError),
            skinLikeHueError: average(\.skinLikeHueError),
            temporalLuminanceError: average(\.temporalLuminanceError),
            highlightPumping: average(\.highlightPumping),
            temporalFlicker: average(\.temporalFlicker),
            sceneCutOvershoot: average(\.sceneCutOvershoot),
            sceneCutRecovery: average(\.sceneCutRecovery),
            structureError: average(\.structureError),
            clippingRatio: average(\.clippingRatio),
            blackCrushRatio: average(\.blackCrushRatio),
            shadowLiftRatio: average(\.shadowLiftRatio),
            nearBlackContrastLoss: average(\.nearBlackContrastLoss),
            highlightUnderReachRatio: average(\.highlightUnderReachRatio),
            highlightOvershootRatio: average(\.highlightOvershootRatio),
            highlightCompressionError: average(\.highlightCompressionError),
            specularPeakUnderReach: average(\.specularPeakUnderReach),
            specularPeakOvershoot: average(\.specularPeakOvershoot),
            referenceDiffuseWhiteNits: average(\.referenceDiffuseWhiteNits),
            generatedDiffuseWhiteNits: average(\.generatedDiffuseWhiteNits),
            overSaturationRatio: average(\.overSaturationRatio),
            underSaturationRatio: average(\.underSaturationRatio),
            invalidSampleCount: values.map(\.invalidSampleCount).reduce(0, +),
            luminanceRegionErrors: Dictionary(uniqueKeysWithValues: regionKeys.map { key in
                (key, values.map { $0.luminanceRegionErrors[key] ?? 0 }.reduce(0, +) / Double(values.count))
            }),
            weightedContributions: Dictionary(uniqueKeysWithValues: contributionKeys.map { key in
                (key, values.map { $0.weightedContributions[key] ?? 0 }.reduce(0, +) / Double(values.count))
            })
        )
    }

    static func alignmentStatistics(
        prepared: PreparedPair,
        configuration: V2MetricSemanticConfiguration = .current
    ) -> V2AlignmentStatistics {
        let confidences = prepared.alignment.matches.map(\.confidence).sorted()
        let offsets = prepared.alignment.matches.map { $0.hdrTimeSeconds - $0.sdrTimeSeconds }
        let meanOffset = average(offsets)
        let variance = offsets.isEmpty ? 0 : offsets.map { ($0 - meanOffset) * ($0 - meanOffset) }.reduce(0, +) / Double(offsets.count)
        let sampled = prepared.sdrSequence.samples.count
        return V2AlignmentStatistics(
            sampledFrames: sampled,
            matchedFrames: prepared.alignment.matches.count,
            rejectedFrames: prepared.alignment.rejectedFrames,
            matchRatio: sampled > 0 ? Double(prepared.alignment.matches.count) / Double(sampled) : 0,
            meanConfidence: average(confidences),
            medianConfidence: percentile(confidences, configuration.percentileFractions["p50"]!),
            p10Confidence: percentile(confidences, configuration.percentileFractions["p10"]!),
            p50Confidence: percentile(confidences, configuration.percentileFractions["p50"]!),
            p90Confidence: percentile(confidences, configuration.percentileFractions["p90"]!),
            estimatedTimeOffset: prepared.alignment.coarseOffsetSeconds,
            offsetVariance: variance
        )
    }

    static func categories(
        scenes: [V2SceneEvaluation],
        configuration: V2MetricSemanticConfiguration = .current
    ) -> [String] {
        guard !scenes.isEmpty else { return ["UNCLASSIFIED_CONTENT"] }
        var result = Set(scenes.flatMap(\.tags))
        let metrics = aggregate(scenes.map(\.metrics), configuration: configuration)
        if metrics.referenceDiffuseWhiteNits > configuration.categoryHighKeyThresholdNits { result.insert("HIGH_KEY") }
        if metrics.referenceDiffuseWhiteNits < configuration.categoryLowKeyThresholdNits { result.insert("LOW_KEY") }
        if metrics.chromaError > configuration.categoryHighSaturationChromaThreshold ||
            metrics.overSaturationRatio > configuration.categoryHighSaturationRatio {
            result.insert("HIGH_SATURATION")
        }
        if metrics.highlightUnderReachRatio > configuration.categoryHighlightRichUnderreachRatio { result.insert("HIGHLIGHT_RICH") }
        if result.isEmpty { result.insert("UNCLASSIFIED_CONTENT") }
        return result.sorted()
    }

    static func percentiles(
        _ values: [Double],
        configuration: V2MetricSemanticConfiguration = .current
    ) -> V2Percentiles {
        V2Percentiles(
            p1: percentile(values, configuration.percentileFractions["p1"]!),
            p10: percentile(values, configuration.percentileFractions["p10"]!),
            p25: percentile(values, configuration.percentileFractions["p25"]!),
            p50: percentile(values, configuration.percentileFractions["p50"]!),
            p75: percentile(values, configuration.percentileFractions["p75"]!),
            p90: percentile(values, configuration.percentileFractions["p90"]!),
            p95: percentile(values, configuration.percentileFractions["p95"]!),
            p99: percentile(values, configuration.percentileFractions["p99"]!),
            p999: percentile(values, configuration.percentileFractions["p999"]!)
        )
    }

    static func failureTaxonomy(
        metrics: V2MetricBreakdown,
        confidence: Double,
        configuration: V2MetricSemanticConfiguration = .current
    ) -> [String] {
        var result: [String] = []
        if metrics.highlightUnderReachRatio > configuration.failureHighlightUnderreachRatio { result.append("HIGHLIGHT_UNDERREACH") }
        if metrics.highlightOvershootRatio > configuration.failureHighlightOvershootRatio { result.append("HIGHLIGHT_OVERSHOOT") }
        if metrics.generatedDiffuseWhiteNits < metrics.referenceDiffuseWhiteNits * configuration.failureDiffuseWhiteLowRatio { result.append("DIFFUSE_WHITE_LOW") }
        if metrics.generatedDiffuseWhiteNits > metrics.referenceDiffuseWhiteNits * configuration.failureDiffuseWhiteHighRatio { result.append("DIFFUSE_WHITE_HIGH") }
        if metrics.midtoneError > configuration.failureMidtoneError { result.append("MIDTONE_LOW") }
        if metrics.blackCrushRatio > configuration.failureBlackCrushRatio { result.append("BLACK_CRUSH") }
        if metrics.shadowLiftRatio > configuration.failureShadowLiftRatio { result.append("SHADOW_LIFT") }
        if metrics.underSaturationRatio > configuration.failureSaturationRatio { result.append("SATURATION_LOW") }
        if metrics.overSaturationRatio > configuration.failureSaturationRatio { result.append("SATURATION_HIGH") }
        if metrics.hueP95Error > configuration.failureHueP95Error { result.append("HUE_SHIFT") }
        if metrics.temporalFlicker > configuration.failureTemporalFlicker { result.append("TEMPORAL_FLICKER") }
        if confidence < configuration.failureAlignmentConfidence { result.append("ALIGNMENT_UNCERTAIN") }
        if metrics.hueP95Error > configuration.failureReferenceMismatchHue &&
            metrics.luminanceError > configuration.failureReferenceMismatchLuminance {
            result.append("REFERENCE_MISMATCH")
        }
        return result.isEmpty ? ["UNKNOWN"] : result
    }

    private static func colorMetrics(
        _ frames: [V2FrameData],
        configuration: V2MetricSemanticConfiguration
    ) -> (
        chroma: Double, saturation: Double, hueMean: Double, hueP95: Double,
        highChromaHue: Double, skinHue: Double, overSaturation: Double, underSaturation: Double
    ) {
        var chromaErrors: [Double] = []
        var saturationErrors: [Double] = []
        var hueErrors: [Double] = []
        var highChroma: [Double] = []
        var skin: [Double] = []
        var over = 0
        var under = 0
        var count = 0
        for frame in frames {
            for (reference, generated) in zip(frame.reference.rgbNits, frame.generated.rgbNits) {
                guard reference.x.isFinite, reference.y.isFinite, reference.z.isFinite,
                      generated.x.isFinite, generated.y.isFinite, generated.z.isFinite else {
                    continue
                }
                let ref = PerceptualColorV2.ictcp(
                    rgbNits: reference, configuration: configuration
                )
                let gen = PerceptualColorV2.ictcp(
                    rgbNits: generated, configuration: configuration
                )
                let refChroma = hypot(ref.y, ref.z)
                let genChroma = hypot(gen.y, gen.z)
                let refSaturation = refChroma / max(ref.x, configuration.saturationDenominatorFloor)
                let genSaturation = genChroma / max(gen.x, configuration.saturationDenominatorFloor)
                chromaErrors.append(abs(genChroma - refChroma))
                saturationErrors.append(abs(genSaturation - refSaturation))
                if refChroma > configuration.minimumReferenceChroma &&
                    genChroma > configuration.minimumGeneratedChroma {
                    let hue = PerceptualColorV2.hueError(
                        reference: reference,
                        generated: generated,
                        configuration: configuration
                    )
                    hueErrors.append(hue)
                    if refChroma > configuration.highChromaThreshold { highChroma.append(hue) }
                    if isSkinLike(reference, configuration: configuration) { skin.append(hue) }
                }
                if genSaturation > refSaturation * configuration.saturationOvershootRatio + configuration.saturationOvershootAbsolute { over += 1 }
                if genSaturation < refSaturation * configuration.saturationUndershootRatio - configuration.saturationUndershootAbsolute { under += 1 }
                count += 1
            }
        }
        return (
            average(chromaErrors), average(saturationErrors), average(hueErrors), percentile(
                hueErrors, configuration.percentileFractions["p95"]!
            ),
            average(highChroma), average(skin), count > 0 ? Double(over) / Double(count) : 0,
            count > 0 ? Double(under) / Double(count) : 0
        )
    }

    static func temporalMetrics(
        _ frames: [V2FrameData],
        configuration: V2MetricSemanticConfiguration = .current
    ) -> (luminance: Double, highlight: Double, flicker: Double) {
        let sorted = frames.sorted { $0.generated.timestampSeconds < $1.generated.timestampSeconds }
        guard sorted.count > 1 else { return (0, 0, 0) }
        let framePairs = sorted.compactMap { frame -> (reference: [Double], generated: [Double])? in
            let pairs = pairedFiniteLuminance([frame])
            guard !pairs.reference.isEmpty else { return nil }
            return (pairs.reference, pairs.generated)
        }
        guard framePairs.count > 1 else { return (0, 0, 0) }
        let referenceMeans = framePairs.map { average($0.reference) }
        let generatedMeans = framePairs.map { average($0.generated) }
        let p95 = configuration.percentileFractions["p95"]!
        let referenceHighlights = framePairs.map { percentile($0.reference, p95) }
        let generatedHighlights = framePairs.map { percentile($0.generated, p95) }
        let luma = deltaError(
            referenceMeans,
            generatedMeans,
            offset: configuration.additiveLuminanceOffsetNits,
            clampFloor: configuration.nonNegativeClampFloor
        )
        let highlight = deltaError(
            referenceHighlights,
            generatedHighlights,
            offset: configuration.additiveLuminanceOffsetNits,
            clampFloor: configuration.nonNegativeClampFloor
        )
        var second: [Double] = []
        if sorted.count > 2 {
            for index in 2..<sorted.count {
                let ref = logRatio(referenceMeans[index], referenceMeans[index - 1], offset: configuration.additiveLuminanceOffsetNits, clampFloor: configuration.nonNegativeClampFloor) - logRatio(referenceMeans[index - 1], referenceMeans[index - 2], offset: configuration.additiveLuminanceOffsetNits, clampFloor: configuration.nonNegativeClampFloor)
                let gen = logRatio(generatedMeans[index], generatedMeans[index - 1], offset: configuration.additiveLuminanceOffsetNits, clampFloor: configuration.nonNegativeClampFloor) - logRatio(generatedMeans[index - 1], generatedMeans[index - 2], offset: configuration.additiveLuminanceOffsetNits, clampFloor: configuration.nonNegativeClampFloor)
                second.append(abs(ref - gen))
            }
        }
        return (luma, highlight, average(second))
    }

    private static func structureError(
        _ frames: [V2FrameData],
        epsilon: Double,
        lowerBound: Double,
        upperBound: Double
    ) -> Double {
        let errors = frames.compactMap { frame -> Double? in
            let count = min(frame.sourceLuma.count, frame.generated.lumaNits.count)
            var source: [Double] = []
            var generated: [Double] = []
            for index in 0..<count {
                let lhs = Double(frame.sourceLuma[index])
                let rhs = Double(frame.generated.lumaNits[index])
                guard lhs.isFinite, rhs.isFinite else { continue }
                source.append(lhs)
                generated.append(rhs)
            }
            guard let correlation = correlation(
                source,
                generated,
                epsilon: epsilon,
                lowerBound: lowerBound,
                upperBound: upperBound
            ) else { return nil }
            return 1 - correlation
        }
        return average(errors)
    }

    /// Builds paired luminance vectors without independently compacting either
    /// side.  Removing invalid values from each array separately changes pixel
    /// correspondence and can compare two different pixels.
    private static func pairedFiniteLuminance(_ frames: [V2FrameData]) -> (
        reference: [Double], generated: [Double], invalid: Int
    ) {
        var reference: [Double] = []
        var generated: [Double] = []
        var invalid = 0
        for frame in frames {
            let count = max(frame.reference.lumaNits.count, frame.generated.lumaNits.count)
            for index in 0..<count {
                guard index < frame.reference.lumaNits.count,
                      index < frame.generated.lumaNits.count else {
                    invalid += 1
                    continue
                }
                let lhs = Double(frame.reference.lumaNits[index])
                let rhs = Double(frame.generated.lumaNits[index])
                guard lhs.isFinite, rhs.isFinite else {
                    invalid += 1
                    continue
                }
                reference.append(lhs)
                generated.append(rhs)
            }
        }
        return (reference, generated, invalid)
    }

    private static func invalidPairedPixelCount(_ frames: [V2FrameData]) -> Int {
        frames.reduce(0) { total, frame in
            let count = max(
                max(frame.reference.lumaNits.count, frame.generated.lumaNits.count),
                max(frame.reference.rgbNits.count, frame.generated.rgbNits.count)
            )
            let invalid = (0..<count).reduce(0) { count, index in
                guard index < frame.reference.lumaNits.count,
                      index < frame.generated.lumaNits.count,
                      index < frame.reference.rgbNits.count,
                      index < frame.generated.rgbNits.count else {
                    return count + 1
                }
                let referenceLuma = frame.reference.lumaNits[index]
                let generatedLuma = frame.generated.lumaNits[index]
                let reference = frame.reference.rgbNits[index]
                let generated = frame.generated.rgbNits[index]
                let vectorFinite = reference.x.isFinite && reference.y.isFinite && reference.z.isFinite &&
                    generated.x.isFinite && generated.y.isFinite && generated.z.isFinite
                return count + (referenceLuma.isFinite && generatedLuma.isFinite && vectorFinite ? 0 : 1)
            }
            return total + invalid
        }
    }

    private static func isSkinLike(
        _ rgb: SIMD3<Float>,
        configuration: V2MetricSemanticConfiguration
    ) -> Bool {
        let maxValue = max(rgb.x, max(rgb.y, rgb.z))
        guard maxValue > Float(configuration.skinMinimumPeakNits) else { return false }
        let normalized = rgb / maxValue
        return normalized.x > normalized.y && normalized.y > normalized.z &&
            normalized.x - normalized.z > Float(configuration.skinRedBlueSeparation)
    }

    private static func diffuseMidtoneMetrics(
        _ frames: [V2FrameData],
        configuration: V2MetricSemanticConfiguration = .current
    ) -> (
        error: Double,
        signed: Double,
        positive: Double,
        negative: Double,
        mae: Double,
        overshoot: Double,
        overshootP95: Double,
        sampleCount: Int
    ) {
        var absoluteErrors: [Double] = []
        var signedErrors: [Double] = []
        var positiveOvershoots: [Double] = []
        var negativeUndershoots: [Double] = []
        for frame in frames {
            let count = min(frame.sourceLuma.count, frame.reference.lumaNits.count, frame.generated.lumaNits.count)
            guard count > 0 else { continue }
            for index in 0..<count {
                let source = Double(frame.sourceLuma[index])
                let reference = Double(frame.reference.lumaNits[index])
                let generated = Double(frame.generated.lumaNits[index])
                guard source.isFinite,
                      configuration.diffuseMidtoneSourceRange.lowerPercentile...configuration.diffuseMidtoneSourceRange.upperPercentile ~= source,
                      reference.isFinite, generated.isFinite else { continue }
                let signedError = log((generated + configuration.additiveLuminanceOffsetNits) /
                    (reference + configuration.additiveLuminanceOffsetNits))
                guard signedError.isFinite else { continue }
                absoluteErrors.append(abs(signedError))
                signedErrors.append(signedError)
                positiveOvershoots.append(max(signedError, 0))
                negativeUndershoots.append(max(-signedError, 0))
            }
        }
        guard !absoluteErrors.isEmpty else {
            return (
                configuration.invalidMetricScore, 0, 0, 0,
                configuration.invalidMetricScore, 0, 0, 0
            )
        }
        let error = absoluteErrors.reduce(0, +) / Double(absoluteErrors.count)
        let signed = signedErrors.reduce(0, +) / Double(signedErrors.count)
        let positive = positiveOvershoots.reduce(0, +) / Double(positiveOvershoots.count)
        let negative = negativeUndershoots.reduce(0, +) / Double(negativeUndershoots.count)
        let overshoot = positiveOvershoots.reduce(0, +) / Double(positiveOvershoots.count)
        return (
            error,
            signed,
            positive,
            negative,
            error,
            overshoot,
            percentile(positiveOvershoots, configuration.percentileFractions["p95"]!),
            absoluteErrors.count
        )
    }

    private static func regionError(
        _ reference: [Double],
        _ generated: [Double],
        region: V2MetricRegionDefinition,
        offset: Double = V2MetricSemanticConfiguration.current.additiveLuminanceOffsetNits,
        invalidValue: Double = V2MetricSemanticConfiguration.current.invalidMetricScore
    ) -> Double {
        guard !reference.isEmpty, !generated.isEmpty else { return invalidValue }
        let low = percentile(reference, region.lowerPercentile)
        let high = percentile(reference, region.upperPercentile)
        let pairs = zip(reference, generated).filter { $0.0 >= low && $0.0 <= high }
        return logError(pairs.map(\.0), pairs.map(\.1), offset: offset, invalidValue: invalidValue)
    }

    private static func logError(
        _ lhs: [Double],
        _ rhs: [Double],
        offset: Double = V2MetricSemanticConfiguration.current.additiveLuminanceOffsetNits,
        invalidValue: Double = V2MetricSemanticConfiguration.current.invalidMetricScore
    ) -> Double {
        meanZip(lhs, rhs, emptyValue: invalidValue) { abs(log(($1 + offset) / ($0 + offset))) }
    }

    private static func deltaError(
        _ reference: [Double],
        _ generated: [Double],
        offset: Double = V2MetricSemanticConfiguration.current.additiveLuminanceOffsetNits,
        clampFloor: Double = V2MetricSemanticConfiguration.current.nonNegativeClampFloor
    ) -> Double {
        guard reference.count > 1, generated.count > 1 else { return 0 }
        var values: [Double] = []
        for index in 1..<min(reference.count, generated.count) {
            values.append(abs(logRatio(reference[index], reference[index - 1], offset: offset, clampFloor: clampFloor) - logRatio(generated[index], generated[index - 1], offset: offset, clampFloor: clampFloor)))
        }
        return average(values)
    }

    private static func logRatio(
        _ lhs: Double,
        _ rhs: Double,
        offset: Double = V2MetricSemanticConfiguration.current.additiveLuminanceOffsetNits,
        clampFloor: Double = V2MetricSemanticConfiguration.current.nonNegativeClampFloor
    ) -> Double {
        log((max(lhs, clampFloor) + offset) / (max(rhs, clampFloor) + offset))
    }

    private static func meanZip(
        _ lhs: [Double],
        _ rhs: [Double],
        emptyValue: Double = V2MetricSemanticConfiguration.current.invalidMetricScore,
        transform: (Double, Double) -> Double
    ) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return emptyValue }
        return (0..<count).map { transform(lhs[$0], rhs[$0]) }.reduce(0, +) / Double(count)
    }

    private static func fraction(_ pairs: [(Double, Double)], predicate: ((Double, Double)) -> Bool) -> Double {
        guard !pairs.isEmpty else { return 0 }
        return Double(pairs.filter(predicate).count) / Double(pairs.count)
    }

    private static func correlation(
        _ lhs: [Double],
        _ rhs: [Double],
        epsilon: Double = V2MetricSemanticConfiguration.current.correlationEpsilon,
        lowerBound: Double = V2MetricSemanticConfiguration.current.correlationLowerBound,
        upperBound: Double = V2MetricSemanticConfiguration.current.correlationUpperBound
    ) -> Double? {
        guard lhs.count == rhs.count, lhs.count > 1 else { return nil }
        let lm = average(lhs), rm = average(rhs)
        var numerator = 0.0, lv = 0.0, rv = 0.0
        for index in lhs.indices {
            let l = lhs[index] - lm, r = rhs[index] - rm
            numerator += l * r; lv += l * l; rv += r * r
        }
        let denominator = sqrt(lv * rv)
        return denominator > epsilon ? max(lowerBound, min(upperBound, numerator / denominator)) : nil
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)]
    }

    private static func average(_ values: [Double]) -> Double {
        let finiteValues = values.filter(\.isFinite)
        return finiteValues.isEmpty ? 0 : finiteValues.reduce(0, +) / Double(finiteValues.count)
    }

    private static func finite(
        _ value: Double,
        invalidValue: Double = V2MetricSemanticConfiguration.current.invalidMetricScore,
        configuration: V2MetricSemanticConfiguration = .current
    ) -> Double {
        value.isFinite ? max(value, configuration.nonNegativeClampFloor) : invalidValue
    }

    private static func zeroMetric(
        invalid: Int,
        configuration: V2MetricSemanticConfiguration
    ) -> V2MetricBreakdown {
        V2MetricBreakdown(
            objective: invalid > 0 ? configuration.emptyAggregateObjective : 0, luminanceError: 0, absoluteNitError: 0, midtoneError: 0,
            diffuseWhiteError: 0, highlightError: 0, shadowError: 0, chromaError: 0, saturationError: 0,
            hueMeanError: 0, hueP95Error: 0, highChromaHueError: 0, skinLikeHueError: 0,
            temporalLuminanceError: 0, highlightPumping: 0, temporalFlicker: 0, sceneCutOvershoot: 0,
            sceneCutRecovery: 0, structureError: 0, clippingRatio: 0, blackCrushRatio: 0, shadowLiftRatio: 0,
            nearBlackContrastLoss: 0, highlightUnderReachRatio: 0, highlightOvershootRatio: 0,
            highlightCompressionError: 0, specularPeakUnderReach: 0, specularPeakOvershoot: 0,
            referenceDiffuseWhiteNits: 0, generatedDiffuseWhiteNits: 0, overSaturationRatio: 0,
            underSaturationRatio: 0, invalidSampleCount: invalid, luminanceRegionErrors: [:], weightedContributions: [:]
        )
    }
}

public enum V2MetricTestProbe {
    public static func compare(reference: [SIMD3<Float>], generated: [SIMD3<Float>]) -> V2MetricBreakdown {
        compareSequence(reference: [reference], generated: [generated])
    }

    public static func compareSequence(reference: [[SIMD3<Float>]], generated: [[SIMD3<Float>]]) -> V2MetricBreakdown {
        let count = min(reference.count, generated.count)
        let frames = (0..<count).map { index -> V2FrameData in
            let referenceFrame = ReferenceFrame(timestampSeconds: Double(index), width: reference[index].count, height: 1, rgbNits: reference[index])
            let generatedFrame = GeneratedFrame(timestampSeconds: Double(index), width: generated[index].count, height: 1, rgbNits: generated[index])
            return V2FrameData(reference: referenceFrame, generated: generatedFrame, sourceLuma: referenceFrame.lumaNits, confidence: 1)
        }
        let scene = SceneRange(id: "test", startSample: 0, endSample: 0, tags: [])
        let parameters = CalibrationParameters(configuration: .hdr)
        return V2MetricsEvaluator.evaluateScene(pairID: "test", scene: scene, frames: frames, configuration: parameters, weights: V2ObjectiveWeights()).metrics
    }
}
