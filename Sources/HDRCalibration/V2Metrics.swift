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
        let lms = configuration.colorScience.ictcp.rgbToLMSValues((rgb.x, rgb.y, rgb.z))
        let clamp: (Double) -> Float = { value in
            Float(min(max(value, configuration.perceptualColorInputMinimumNits),
                configuration.perceptualColorInputMaximumNits))
        }
        let lp = Double(HDRColorMath.pqEncode(
            nits: clamp(lms.0), definition: configuration.colorScience.pq
        ))
        let mp = Double(HDRColorMath.pqEncode(
            nits: clamp(lms.1), definition: configuration.colorScience.pq
        ))
        let sp = Double(HDRColorMath.pqEncode(
            nits: clamp(lms.2), definition: configuration.colorScience.pq
        ))
        let ictcp = configuration.colorScience.ictcp.lmsToICtCpValues((lp, mp, sp))
        let i = ictcp.0
        let ct = ictcp.1
        let cp = ictcp.2
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
        let normalization = configuration.hueNormalization
        if configuration.hueWrapRule == "shortest-circular-distance",
           delta > normalization {
            delta = configuration.hueFullTurnMultiplier * normalization - delta
        }
        return delta / normalization
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
        let midtoneError = regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["midtone"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration)
        let diffuseWhiteError = regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["diffuseWhite"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration)
        let highlightError = regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["highlight"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration)
        let shadowError = regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["shadow"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration)
        let diffuseMidtone = diffuseMidtoneMetrics(frames, configuration: metricConfiguration)
        let regionErrors = [
            "p0_p1": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p0_p1"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "p1_p10": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p1_p10"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "p10_p50": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p10_p50"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "p50_p90": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p50_p90"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "p90_p99": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p90_p99"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            "p99_p100": regionError(pairedReference, pairedGenerated, region: metricConfiguration.regionPercentiles["p99_p100"]!, offset: metricConfiguration.additiveLuminanceOffsetNits, invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
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
        let highlightPairs = zip(pairedReference, pairedGenerated).filter {
            compare("highlightRegionLower", $0.0, threshold: highlightThreshold, configuration: metricConfiguration)
        }
        let highlightUnderReach = fraction(highlightPairs, configuration: metricConfiguration) {
            compare("highlightUnderreach", $0.1, threshold: $0.0 * metricConfiguration.highlightUnderreachRatio, configuration: metricConfiguration)
        }
        let highlightOvershoot = fraction(highlightPairs, configuration: metricConfiguration) {
            compare("highlightOvershoot", $0.1, threshold: max(
                $0.0 * metricConfiguration.highlightOvershootRatio,
                $0.0 + metricConfiguration.highlightOvershootAbsoluteNits
            ), configuration: metricConfiguration)
        }
        let specularReference = percentile(
            pairedReference, metricConfiguration.specularPercentile, configuration: metricConfiguration
        )
        let specularGenerated = percentile(
            pairedGenerated, metricConfiguration.specularPercentile, configuration: metricConfiguration
        )
        let specularUnder = max(specularReference - specularGenerated, metricConfiguration.nonNegativeClampFloor) /
            max(specularReference, metricConfiguration.slopeFloorNits)
        let specularOver = max(specularGenerated - specularReference, metricConfiguration.nonNegativeClampFloor) /
            max(specularReference, metricConfiguration.slopeFloorNits)
        let referenceSlope = max(refPercentiles.p99 - refPercentiles.p90, metricConfiguration.slopeFloorNits)
        let generatedSlope = max(genPercentiles.p99 - genPercentiles.p90, metricConfiguration.nonNegativeClampFloor)
        let compressionError = abs(generatedSlope / referenceSlope - metricConfiguration.ratioIdentity)
        let clipping = pairedGenerated.isEmpty ? metricConfiguration.emptyFractionValue : Double(pairedGenerated.filter {
            compare("clipping", $0, threshold: Double(configuration.peakNits) * metricConfiguration.clippingPeakRatio, configuration: metricConfiguration)
        }.count) / Double(pairedGenerated.count)

        let shadowPairs = zip(pairedReference, pairedGenerated).filter {
            compare("shadowRegionUpper", $0.0, threshold: refPercentiles.p10, configuration: metricConfiguration)
        }
        let blackCrush = fraction(shadowPairs, configuration: metricConfiguration) {
            compare("blackCrushReference", $0.0, threshold: metricConfiguration.blackCrushReferenceThresholdNits, configuration: metricConfiguration) &&
            compare("blackCrushGenerated", $0.1, threshold: min(
                metricConfiguration.blackCrushGeneratedAbsoluteNits,
                $0.0 * metricConfiguration.blackCrushGeneratedRatio
            ), configuration: metricConfiguration)
        }
        let shadowLift = fraction(shadowPairs, configuration: metricConfiguration) {
            compare("shadowLift", $0.1, threshold: max(
                $0.0 * metricConfiguration.shadowLiftRatio,
                $0.0 + metricConfiguration.shadowLiftAbsoluteNits
            ), configuration: metricConfiguration)
        }
        let referenceNearBlackRange = max(
            refPercentiles.p10 - refPercentiles.p1,
            metricConfiguration.nearBlackReferenceRangeFloorNits
        )
        let generatedNearBlackRange = max(genPercentiles.p10 - genPercentiles.p1, metricConfiguration.nonNegativeClampFloor)
        let nearBlackContrastLoss = max(
            metricConfiguration.ratioIdentity - generatedNearBlackRange / referenceNearBlackRange,
            metricConfiguration.nonNegativeClampFloor
        )

        let color = colorMetrics(frames, configuration: metricConfiguration)
        let temporal = temporalMetrics(frames, configuration: metricConfiguration)
        let structure = structureError(
            frames,
            epsilon: metricConfiguration.correlationEpsilon,
            lowerBound: metricConfiguration.correlationLowerBound,
            upperBound: metricConfiguration.correlationUpperBound,
            minimumSampleCount: metricConfiguration.correlationMinimumSampleCount,
            denominatorComparison: metricConfiguration.correlationDenominatorComparison,
            ratioIdentity: metricConfiguration.ratioIdentity,
            emptyValue: metricConfiguration.emptyAverageValue
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
        let objective = stableSum(contributions, configuration: metricConfiguration)
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
            sceneCutOvershoot: metricConfiguration.emptyAverageValue,
            sceneCutRecovery: metricConfiguration.emptyAverageValue,
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
            referenceDiffuseWhiteNits: finite(percentile(pairedReference, metricConfiguration.percentileFractions["p90"]!, configuration: metricConfiguration), invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
            generatedDiffuseWhiteNits: finite(percentile(pairedGenerated, metricConfiguration.percentileFractions["p90"]!, configuration: metricConfiguration), invalidValue: metricConfiguration.invalidMetricScore, configuration: metricConfiguration),
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
        let confidence = frames.isEmpty
            ? metricConfiguration.emptyFractionValue
            : frames.map(\.confidence).reduce(0, +) / Double(frames.count)
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
        let metricConfiguration = V2MetricSemanticConfiguration(objectiveWeights: weights)
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
        // The evaluator is also used by the preregistered runner for dataset,
        // transfer, family, and temporal reductions.  Sort the complete
        // breakdowns before every floating-point reduction so a caller cannot
        // change a score by supplying the same values in a different order.
        let orderedValues = values.sorted {
            canonicalStringLess(stableMetricOrderKey($0), stableMetricOrderKey($1))
        }
        func average(_ key: (V2MetricBreakdown) -> Double) -> Double {
            orderedValues.map(key).reduce(0, +) / Double(orderedValues.count)
        }
        let contributionKeys = Set(orderedValues.flatMap { $0.weightedContributions.keys }).sorted(by: canonicalStringLess)
        let regionKeys = Set(orderedValues.flatMap { $0.luminanceRegionErrors.keys }).sorted(by: canonicalStringLess)
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
            invalidSampleCount: orderedValues.map(\.invalidSampleCount).reduce(0, +),
            luminanceRegionErrors: Dictionary(uniqueKeysWithValues: regionKeys.map { key in
                (key, orderedValues.map { $0.luminanceRegionErrors[key] ?? configuration.emptyAverageValue }.reduce(0, +) / Double(orderedValues.count))
            }),
            weightedContributions: Dictionary(uniqueKeysWithValues: contributionKeys.map { key in
                (key, orderedValues.map { $0.weightedContributions[key] ?? configuration.emptyAverageValue }.reduce(0, +) / Double(orderedValues.count))
            })
        )
    }

    /// A total-order key for metric breakdowns.  It uses only value fields and
    /// sorts nested diagnostic maps by canonical UTF-8 key order.  This is an
    /// ordering aid, not an identity; invalid metric values remain visible to
    /// the normal fail-closed metric policy.
    private static func stableMetricOrderKey(_ value: V2MetricBreakdown) -> String {
        let scalarValues: [String] = [
            value.objective, value.luminanceError, value.absoluteNitError,
            value.midtoneError, value.diffuseWhiteError, value.highlightError,
            value.shadowError, value.chromaError, value.saturationError,
            value.hueMeanError, value.hueP95Error, value.highChromaHueError,
            value.skinLikeHueError, value.temporalLuminanceError,
            value.highlightPumping, value.temporalFlicker, value.sceneCutOvershoot,
            value.sceneCutRecovery, value.structureError, value.clippingRatio,
            value.blackCrushRatio, value.shadowLiftRatio,
            value.nearBlackContrastLoss, value.highlightUnderReachRatio,
            value.highlightOvershootRatio, value.highlightCompressionError,
            value.specularPeakUnderReach, value.specularPeakOvershoot,
            value.referenceDiffuseWhiteNits, value.generatedDiffuseWhiteNits,
            value.overSaturationRatio, value.underSaturationRatio
        ].map { $0 == 0 ? "0" : String($0) }
        func mapKey(_ map: [String: Double]) -> String {
            map.keys.sorted(by: canonicalStringLess).map { key in
                "\(key)=\(map[key].map { $0 == 0 ? "0" : String($0) } ?? "<missing>")"
            }.joined(separator: ";")
        }
        return scalarValues.joined(separator: "|") + "|invalid=\(value.invalidSampleCount)|regions=" +
            mapKey(value.luminanceRegionErrors) + "|contributions=" + mapKey(value.weightedContributions)
    }

    private static func canonicalStringLess(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8))
    }

    /// Dictionary storage is useful for named diagnostics, but its iteration
    /// order is not an experiment semantic.  Objective reduction is therefore
    /// explicitly ordered by the canonical UTF-8 key order.
    static func stableSum(
        _ values: [String: Double],
        configuration: V2MetricSemanticConfiguration = .current
    ) -> Double {
        let orderedKeys: [String]
        switch configuration.stableAggregationOrder {
        case .callerSuppliedCanonicalPairOrder:
            orderedKeys = values.keys.sorted {
                Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8))
            }
        }
        return orderedKeys.reduce(0) { total, key in
            total + (values[key] ?? configuration.emptyAverageValue)
        }
    }

    /// Every threshold comparison used by the objective path is named in the
    /// sealed metric configuration.  Missing rules are a fail-closed coding
    /// error rather than an implicit production default.
    private static func compare(
        _ key: String,
        _ value: Double,
        threshold: Double,
        configuration: V2MetricSemanticConfiguration
    ) -> Bool {
        guard value.isFinite, threshold.isFinite,
              let rule = configuration.comparisonRules[key] else { return false }
        return rule.accepts(value, threshold: threshold)
    }

    static func alignmentStatistics(
        prepared: PreparedPair,
        configuration: V2MetricSemanticConfiguration = .current
    ) -> V2AlignmentStatistics {
        let confidences = prepared.alignment.matches.map(\.confidence).sorted()
        let offsets = prepared.alignment.matches.map { $0.hdrTimeSeconds - $0.sdrTimeSeconds }
        let meanOffset = average(offsets, emptyValue: configuration.emptyAverageValue)
        let variance = offsets.isEmpty ? configuration.emptyAverageValue : offsets.map { ($0 - meanOffset) * ($0 - meanOffset) }.reduce(0, +) / Double(offsets.count)
        let sampled = prepared.sdrSequence.samples.count
        return V2AlignmentStatistics(
            sampledFrames: sampled,
            matchedFrames: prepared.alignment.matches.count,
            rejectedFrames: prepared.alignment.rejectedFrames,
            matchRatio: sampled > 0 ? Double(prepared.alignment.matches.count) / Double(sampled) : configuration.emptyFractionValue,
            meanConfidence: average(confidences, emptyValue: configuration.emptyAverageValue),
            medianConfidence: percentile(confidences, configuration.percentileFractions["p50"]!, configuration: configuration),
            p10Confidence: percentile(confidences, configuration.percentileFractions["p10"]!, configuration: configuration),
            p50Confidence: percentile(confidences, configuration.percentileFractions["p50"]!, configuration: configuration),
            p90Confidence: percentile(confidences, configuration.percentileFractions["p90"]!, configuration: configuration),
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
        if compare("categoryHighKey", metrics.referenceDiffuseWhiteNits, threshold: configuration.categoryHighKeyThresholdNits, configuration: configuration) { result.insert("HIGH_KEY") }
        if compare("categoryLowKey", metrics.referenceDiffuseWhiteNits, threshold: configuration.categoryLowKeyThresholdNits, configuration: configuration) { result.insert("LOW_KEY") }
        if compare("categoryHighSaturationChroma", metrics.chromaError, threshold: configuration.categoryHighSaturationChromaThreshold, configuration: configuration) ||
            compare("categoryHighSaturationRatio", metrics.overSaturationRatio, threshold: configuration.categoryHighSaturationRatio, configuration: configuration) {
            result.insert("HIGH_SATURATION")
        }
        if compare("categoryHighlightRich", metrics.highlightUnderReachRatio, threshold: configuration.categoryHighlightRichUnderreachRatio, configuration: configuration) { result.insert("HIGHLIGHT_RICH") }
        if result.isEmpty { result.insert("UNCLASSIFIED_CONTENT") }
        return result.sorted()
    }

    static func percentiles(
        _ values: [Double],
        configuration: V2MetricSemanticConfiguration = .current
    ) -> V2Percentiles {
        V2Percentiles(
            p1: percentile(values, configuration.percentileFractions["p1"]!, configuration: configuration),
            p10: percentile(values, configuration.percentileFractions["p10"]!, configuration: configuration),
            p25: percentile(values, configuration.percentileFractions["p25"]!, configuration: configuration),
            p50: percentile(values, configuration.percentileFractions["p50"]!, configuration: configuration),
            p75: percentile(values, configuration.percentileFractions["p75"]!, configuration: configuration),
            p90: percentile(values, configuration.percentileFractions["p90"]!, configuration: configuration),
            p95: percentile(values, configuration.percentileFractions["p95"]!, configuration: configuration),
            p99: percentile(values, configuration.percentileFractions["p99"]!, configuration: configuration),
            p999: percentile(values, configuration.percentileFractions["p999"]!, configuration: configuration)
        )
    }

    static func failureTaxonomy(
        metrics: V2MetricBreakdown,
        confidence: Double,
        configuration: V2MetricSemanticConfiguration = .current
    ) -> [String] {
        var result: [String] = []
        if compare("failureHighlightUnderreach", metrics.highlightUnderReachRatio, threshold: configuration.failureHighlightUnderreachRatio, configuration: configuration) { result.append("HIGHLIGHT_UNDERREACH") }
        if compare("failureHighlightOvershoot", metrics.highlightOvershootRatio, threshold: configuration.failureHighlightOvershootRatio, configuration: configuration) { result.append("HIGHLIGHT_OVERSHOOT") }
        if compare("failureDiffuseWhiteLow", metrics.generatedDiffuseWhiteNits, threshold: metrics.referenceDiffuseWhiteNits * configuration.failureDiffuseWhiteLowRatio, configuration: configuration) { result.append("DIFFUSE_WHITE_LOW") }
        if compare("failureDiffuseWhiteHigh", metrics.generatedDiffuseWhiteNits, threshold: metrics.referenceDiffuseWhiteNits * configuration.failureDiffuseWhiteHighRatio, configuration: configuration) { result.append("DIFFUSE_WHITE_HIGH") }
        if compare("failureMidtone", metrics.midtoneError, threshold: configuration.failureMidtoneError, configuration: configuration) { result.append("MIDTONE_LOW") }
        if compare("failureBlackCrush", metrics.blackCrushRatio, threshold: configuration.failureBlackCrushRatio, configuration: configuration) { result.append("BLACK_CRUSH") }
        if compare("failureShadowLift", metrics.shadowLiftRatio, threshold: configuration.failureShadowLiftRatio, configuration: configuration) { result.append("SHADOW_LIFT") }
        if compare("failureSaturationLow", metrics.underSaturationRatio, threshold: configuration.failureSaturationRatio, configuration: configuration) { result.append("SATURATION_LOW") }
        if compare("failureSaturationHigh", metrics.overSaturationRatio, threshold: configuration.failureSaturationRatio, configuration: configuration) { result.append("SATURATION_HIGH") }
        if compare("failureHue", metrics.hueP95Error, threshold: configuration.failureHueP95Error, configuration: configuration) { result.append("HUE_SHIFT") }
        if compare("failureTemporal", metrics.temporalFlicker, threshold: configuration.failureTemporalFlicker, configuration: configuration) { result.append("TEMPORAL_FLICKER") }
        if compare("failureAlignment", confidence, threshold: configuration.failureAlignmentConfidence, configuration: configuration) { result.append("ALIGNMENT_UNCERTAIN") }
        if compare("failureReferenceHue", metrics.hueP95Error, threshold: configuration.failureReferenceMismatchHue, configuration: configuration) &&
            compare("failureReferenceLuminance", metrics.luminanceError, threshold: configuration.failureReferenceMismatchLuminance, configuration: configuration) {
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
                if compare("referenceChromaEligibility", refChroma, threshold: configuration.minimumReferenceChroma, configuration: configuration) &&
                    compare("generatedChromaEligibility", genChroma, threshold: configuration.minimumGeneratedChroma, configuration: configuration) {
                    let hue = PerceptualColorV2.hueError(
                        reference: reference,
                        generated: generated,
                        configuration: configuration
                    )
                    hueErrors.append(hue)
                    if compare("highChroma", refChroma, threshold: configuration.highChromaThreshold, configuration: configuration) { highChroma.append(hue) }
                    if isSkinLike(reference, configuration: configuration) { skin.append(hue) }
                }
                if compare("saturationOvershoot", genSaturation, threshold: refSaturation * configuration.saturationOvershootRatio + configuration.saturationOvershootAbsolute, configuration: configuration) { over += 1 }
                if compare("saturationUndershoot", genSaturation, threshold: refSaturation * configuration.saturationUndershootRatio - configuration.saturationUndershootAbsolute, configuration: configuration) { under += 1 }
                count += 1
            }
        }
        return (
            average(chromaErrors, emptyValue: configuration.emptyAverageValue),
            average(saturationErrors, emptyValue: configuration.emptyAverageValue),
            average(hueErrors, emptyValue: configuration.emptyAverageValue), percentile(
                hueErrors, configuration.percentileFractions["p95"]!, configuration: configuration
            ),
            average(highChroma, emptyValue: configuration.emptyAverageValue),
            average(skin, emptyValue: configuration.emptyAverageValue),
            count > 0 ? Double(over) / Double(count) : configuration.emptyFractionValue,
            count > 0 ? Double(under) / Double(count) : configuration.emptyFractionValue
        )
    }

    static func temporalMetrics(
        _ frames: [V2FrameData],
        configuration: V2MetricSemanticConfiguration = .current
    ) -> (luminance: Double, highlight: Double, flicker: Double) {
        let sorted: [V2FrameData]
        switch configuration.stableFrameOrderingRule {
        case .generatedTimestampAscendingThenInputPositionAscending:
            sorted = frames.enumerated().sorted { lhs, rhs in
                if lhs.element.generated.timestampSeconds != rhs.element.generated.timestampSeconds {
                    return lhs.element.generated.timestampSeconds < rhs.element.generated.timestampSeconds
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
        guard sorted.count >= configuration.temporalMinimumFrameCount else {
            return (
                configuration.insufficientTemporalMetricValue,
                configuration.insufficientTemporalMetricValue,
                configuration.insufficientTemporalMetricValue
            )
        }
        let framePairs = sorted.compactMap { frame -> (reference: [Double], generated: [Double])? in
            let pairs = pairedFiniteLuminance([frame])
            guard !pairs.reference.isEmpty else { return nil }
            return (pairs.reference, pairs.generated)
        }
        guard framePairs.count >= configuration.temporalMinimumFrameCount else {
            return (
                configuration.insufficientTemporalMetricValue,
                configuration.insufficientTemporalMetricValue,
                configuration.insufficientTemporalMetricValue
            )
        }
        let referenceMeans = framePairs.map { average($0.reference, emptyValue: configuration.emptyAverageValue) }
        let generatedMeans = framePairs.map { average($0.generated, emptyValue: configuration.emptyAverageValue) }
        let p95 = configuration.percentileFractions["p95"]!
        let referenceHighlights = framePairs.map { percentile($0.reference, p95, configuration: configuration) }
        let generatedHighlights = framePairs.map { percentile($0.generated, p95, configuration: configuration) }
        let luma = deltaError(
            referenceMeans,
            generatedMeans,
            offset: configuration.additiveLuminanceOffsetNits,
            clampFloor: configuration.nonNegativeClampFloor,
            emptyValue: configuration.insufficientTemporalMetricValue
        )
        let highlight = deltaError(
            referenceHighlights,
            generatedHighlights,
            offset: configuration.additiveLuminanceOffsetNits,
            clampFloor: configuration.nonNegativeClampFloor,
            emptyValue: configuration.insufficientTemporalMetricValue
        )
        var second: [Double] = []
        if sorted.count >= configuration.temporalSecondDifferenceMinimumFrameCount {
            for index in (configuration.temporalMinimumFrameCount)..<sorted.count {
                let ref = logRatio(referenceMeans[index], referenceMeans[index - 1], offset: configuration.additiveLuminanceOffsetNits, clampFloor: configuration.nonNegativeClampFloor) - logRatio(referenceMeans[index - 1], referenceMeans[index - 2], offset: configuration.additiveLuminanceOffsetNits, clampFloor: configuration.nonNegativeClampFloor)
                let gen = logRatio(generatedMeans[index], generatedMeans[index - 1], offset: configuration.additiveLuminanceOffsetNits, clampFloor: configuration.nonNegativeClampFloor) - logRatio(generatedMeans[index - 1], generatedMeans[index - 2], offset: configuration.additiveLuminanceOffsetNits, clampFloor: configuration.nonNegativeClampFloor)
                second.append(abs(ref - gen))
            }
        }
        return (luma, highlight, average(second, emptyValue: configuration.insufficientTemporalMetricValue))
    }

    private static func structureError(
        _ frames: [V2FrameData],
        epsilon: Double,
        lowerBound: Double,
        upperBound: Double,
        minimumSampleCount: Int,
        denominatorComparison: V2MetricComparisonRule,
        ratioIdentity: Double,
        emptyValue: Double
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
                upperBound: upperBound,
                minimumSampleCount: minimumSampleCount,
                denominatorComparison: denominatorComparison
            ) else { return nil }
            return ratioIdentity - correlation
        }
        return average(errors, emptyValue: emptyValue)
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
        guard compare("skinPeak", Double(maxValue), threshold: configuration.skinMinimumPeakNits, configuration: configuration) else { return false }
        let normalized = rgb / maxValue
        return compare("skinRedGreaterThanGreen", Double(normalized.x), threshold: Double(normalized.y), configuration: configuration) &&
            compare("skinGreenGreaterThanBlue", Double(normalized.y), threshold: Double(normalized.z), configuration: configuration) &&
            compare("skinSeparation", Double(normalized.x - normalized.z), threshold: configuration.skinRedBlueSeparation, configuration: configuration)
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
                      compare("regionLower", source, threshold: configuration.diffuseMidtoneSourceRange.lowerPercentile, configuration: configuration),
                      compare("regionUpper", source, threshold: configuration.diffuseMidtoneSourceRange.upperPercentile, configuration: configuration),
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
                configuration.invalidMetricScore,
                configuration.emptyAverageValue,
                configuration.emptyFractionValue,
                configuration.emptyFractionValue,
                configuration.invalidMetricScore,
                configuration.emptyFractionValue,
                configuration.emptyPercentileValue,
                0
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
            percentile(positiveOvershoots, configuration.percentileFractions["p95"]!, configuration: configuration),
            absoluteErrors.count
        )
    }

    private static func regionError(
        _ reference: [Double],
        _ generated: [Double],
        region: V2MetricRegionDefinition,
        offset: Double = V2MetricSemanticConfiguration.current.additiveLuminanceOffsetNits,
        invalidValue: Double = V2MetricSemanticConfiguration.current.invalidMetricScore,
        configuration: V2MetricSemanticConfiguration = .current
    ) -> Double {
        guard !reference.isEmpty, !generated.isEmpty else { return invalidValue }
        let low = percentile(reference, region.lowerPercentile, configuration: configuration)
        let high = percentile(reference, region.upperPercentile, configuration: configuration)
        let pairs = zip(reference, generated).filter {
            compare("regionLower", $0.0, threshold: low, configuration: configuration) &&
                compare("regionUpper", $0.0, threshold: high, configuration: configuration)
        }
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
        clampFloor: Double = V2MetricSemanticConfiguration.current.nonNegativeClampFloor,
        emptyValue: Double = V2MetricSemanticConfiguration.current.insufficientTemporalMetricValue
    ) -> Double {
        guard reference.count > 1, generated.count > 1 else { return emptyValue }
        var values: [Double] = []
        for index in 1..<min(reference.count, generated.count) {
            values.append(abs(logRatio(reference[index], reference[index - 1], offset: offset, clampFloor: clampFloor) - logRatio(generated[index], generated[index - 1], offset: offset, clampFloor: clampFloor)))
        }
        return average(values, emptyValue: emptyValue)
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

    private static func fraction(
        _ pairs: [(Double, Double)],
        configuration: V2MetricSemanticConfiguration,
        predicate: ((Double, Double)) -> Bool
    ) -> Double {
        guard !pairs.isEmpty else { return configuration.emptyFractionValue }
        return Double(pairs.filter(predicate).count) / Double(pairs.count)
    }

    private static func correlation(
        _ lhs: [Double],
        _ rhs: [Double],
        epsilon: Double = V2MetricSemanticConfiguration.current.correlationEpsilon,
        lowerBound: Double = V2MetricSemanticConfiguration.current.correlationLowerBound,
        upperBound: Double = V2MetricSemanticConfiguration.current.correlationUpperBound,
        minimumSampleCount: Int = V2MetricSemanticConfiguration.current.correlationMinimumSampleCount,
        denominatorComparison: V2MetricComparisonRule = .greaterThan
    ) -> Double? {
        guard lhs.count == rhs.count, lhs.count >= minimumSampleCount else { return nil }
        let lm = average(lhs), rm = average(rhs)
        var numerator = 0.0, lv = 0.0, rv = 0.0
        for index in lhs.indices {
            let l = lhs[index] - lm, r = rhs[index] - rm
            numerator += l * r; lv += l * l; rv += r * r
        }
        let denominator = sqrt(lv * rv)
        let denominatorAccepted: Bool
        switch denominatorComparison {
        case .greaterThan:
            denominatorAccepted = denominator > epsilon
        case .greaterThanOrEqual:
            denominatorAccepted = denominator >= epsilon
        case .lessThan, .lessThanOrEqual:
            denominatorAccepted = false
        }
        return denominatorAccepted ? max(lowerBound, min(upperBound, numerator / denominator)) : nil
    }

    static func percentile(
        _ values: [Double],
        _ fraction: Double,
        configuration: V2MetricSemanticConfiguration = .current
    ) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return configuration.emptyPercentileValue }
        return sorted[min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)]
    }

    private static func average(
        _ values: [Double],
        emptyValue: Double = V2MetricSemanticConfiguration.current.emptyAverageValue
    ) -> Double {
        let finiteValues = values.filter(\.isFinite)
        return finiteValues.isEmpty ? emptyValue : finiteValues.reduce(0, +) / Double(finiteValues.count)
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
        let empty = configuration.emptyAverageValue
        return V2MetricBreakdown(
            objective: invalid > 0 ? configuration.emptyAggregateObjective : empty, luminanceError: empty, absoluteNitError: empty, midtoneError: empty,
            diffuseWhiteError: empty, highlightError: empty, shadowError: empty, chromaError: empty, saturationError: empty,
            hueMeanError: empty, hueP95Error: empty, highChromaHueError: empty, skinLikeHueError: empty,
            temporalLuminanceError: empty, highlightPumping: empty, temporalFlicker: empty, sceneCutOvershoot: empty,
            sceneCutRecovery: empty, structureError: empty, clippingRatio: empty, blackCrushRatio: empty, shadowLiftRatio: empty,
            nearBlackContrastLoss: empty, highlightUnderReachRatio: empty, highlightOvershootRatio: empty,
            highlightCompressionError: empty, specularPeakUnderReach: empty, specularPeakOvershoot: empty,
            referenceDiffuseWhiteNits: empty, generatedDiffuseWhiteNits: empty, overSaturationRatio: empty,
            underSaturationRatio: empty, invalidSampleCount: invalid, luminanceRegionErrors: [:], weightedContributions: [:]
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
