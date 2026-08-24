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
    public static func ictcp(rgbNits: SIMD3<Float>) -> SIMD3<Double> {
        let rgb = SIMD3<Double>(
            max(Double(rgbNits.x), 0),
            max(Double(rgbNits.y), 0),
            max(Double(rgbNits.z), 0)
        )
        let l = (1688.0 * rgb.x + 2146.0 * rgb.y + 262.0 * rgb.z) / 4096.0
        let m = (683.0 * rgb.x + 2951.0 * rgb.y + 462.0 * rgb.z) / 4096.0
        let s = (99.0 * rgb.x + 309.0 * rgb.y + 3688.0 * rgb.z) / 4096.0
        let lp = Double(HDRColorMath.pqEncode(nits: Float(min(max(l, 0), 10_000))))
        let mp = Double(HDRColorMath.pqEncode(nits: Float(min(max(m, 0), 10_000))))
        let sp = Double(HDRColorMath.pqEncode(nits: Float(min(max(s, 0), 10_000))))
        let i = (2048.0 * lp + 2048.0 * mp) / 4096.0
        let ct = (6610.0 * lp - 13613.0 * mp + 7003.0 * sp) / 4096.0
        let cp = (17933.0 * lp - 17390.0 * mp - 543.0 * sp) / 4096.0
        return SIMD3(i, ct, cp)
    }

    public static func hueError(reference: SIMD3<Float>, generated: SIMD3<Float>) -> Double {
        let ref = ictcp(rgbNits: reference)
        let gen = ictcp(rgbNits: generated)
        let refHue = atan2(ref.z, ref.y)
        let genHue = atan2(gen.z, gen.y)
        var delta = abs(refHue - genHue)
        if delta > .pi { delta = 2 * .pi - delta }
        return delta / .pi
    }
}

enum V2MetricsEvaluator {
    static func evaluateScene(
        pairID: String,
        scene: SceneRange,
        frames: [V2FrameData],
        configuration: CalibrationParameters,
        weights: V2ObjectiveWeights
    ) -> V2SceneEvaluation {
        let referenceLuma = frames.flatMap { $0.reference.lumaNits.map(Double.init) }.filter(\.isFinite)
        let generatedLuma = frames.flatMap { $0.generated.lumaNits.map(Double.init) }.filter(\.isFinite)
        let count = min(referenceLuma.count, generatedLuma.count)
        let pairedReference = Array(referenceLuma.prefix(count))
        let pairedGenerated = Array(generatedLuma.prefix(count))
        let refPercentiles = percentiles(pairedReference)
        let genPercentiles = percentiles(pairedGenerated)

        let luminanceError = logError(pairedReference, pairedGenerated)
        let absoluteNitError = meanZip(pairedReference, pairedGenerated) { abs($0 - $1) / 1_000 }
        let midtoneError = regionError(pairedReference, pairedGenerated, lower: 0.10, upper: 0.90)
        let diffuseWhiteError = regionError(pairedReference, pairedGenerated, lower: 0.75, upper: 0.95)
        let highlightError = regionError(pairedReference, pairedGenerated, lower: 0.90, upper: 1.0)
        let shadowError = regionError(pairedReference, pairedGenerated, lower: 0.0, upper: 0.10)
        let regionErrors = [
            "p0_p1": regionError(pairedReference, pairedGenerated, lower: 0, upper: 0.01),
            "p1_p10": regionError(pairedReference, pairedGenerated, lower: 0.01, upper: 0.10),
            "p10_p50": regionError(pairedReference, pairedGenerated, lower: 0.10, upper: 0.50),
            "p50_p90": regionError(pairedReference, pairedGenerated, lower: 0.50, upper: 0.90),
            "p90_p99": regionError(pairedReference, pairedGenerated, lower: 0.90, upper: 0.99),
            "p99_p100": regionError(pairedReference, pairedGenerated, lower: 0.99, upper: 1.0)
        ]

        let highlightThreshold = percentile(pairedReference, 0.90)
        let highlightPairs = zip(pairedReference, pairedGenerated).filter { $0.0 >= highlightThreshold }
        let highlightUnderReach = fraction(highlightPairs) { $0.1 < $0.0 * 0.80 }
        let highlightOvershoot = fraction(highlightPairs) { $0.1 > max($0.0 * 1.25, $0.0 + 20) }
        let specularReference = percentile(pairedReference, 0.999)
        let specularGenerated = percentile(pairedGenerated, 0.999)
        let specularUnder = max(specularReference - specularGenerated, 0) / max(specularReference, 1)
        let specularOver = max(specularGenerated - specularReference, 0) / max(specularReference, 1)
        let referenceSlope = max(percentile(pairedReference, 0.99) - percentile(pairedReference, 0.90), 1)
        let generatedSlope = max(percentile(pairedGenerated, 0.99) - percentile(pairedGenerated, 0.90), 0)
        let compressionError = abs(generatedSlope / referenceSlope - 1)
        let clipping = pairedGenerated.isEmpty ? 0 : Double(pairedGenerated.filter { $0 >= Double(configuration.peakNits) * 0.999 }.count) / Double(pairedGenerated.count)

        let shadowPairs = zip(pairedReference, pairedGenerated).filter { $0.0 <= percentile(pairedReference, 0.10) }
        let blackCrush = fraction(shadowPairs) { $0.0 > 1 && $0.1 < min(0.5, $0.0 * 0.25) }
        let shadowLift = fraction(shadowPairs) { $0.1 > max($0.0 * 1.5, $0.0 + 2) }
        let referenceNearBlackRange = max(percentile(pairedReference, 0.10) - percentile(pairedReference, 0.01), 1)
        let generatedNearBlackRange = max(percentile(pairedGenerated, 0.10) - percentile(pairedGenerated, 0.01), 0)
        let nearBlackContrastLoss = max(1 - generatedNearBlackRange / referenceNearBlackRange, 0)

        let color = colorMetrics(frames)
        let temporal = temporalMetrics(frames)
        let structure = structureError(frames)
        let invalidCount = frames.reduce(0) { total, frame in
            total + zip(frame.reference.rgbNits, frame.generated.rgbNits).filter { ref, gen in
                !(ref.x.isFinite && ref.y.isFinite && ref.z.isFinite && gen.x.isFinite && gen.y.isFinite && gen.z.isFinite)
            }.count
        }

        var contributions: [String: Double] = [
            "luminance": weights.luminance * finite(luminanceError),
            "absolute_nits": weights.absoluteNits * finite(absoluteNitError),
            "midtone": weights.midtone * finite(midtoneError),
            "diffuse_white": weights.diffuseWhite * finite(diffuseWhiteError),
            "highlight": weights.highlight * finite(highlightError),
            "shadow": weights.shadow * finite(shadowError),
            "chroma": weights.chroma * finite(color.chroma),
            "saturation": weights.saturation * finite(color.saturation),
            "hue": weights.hue * finite(color.hueMean * 0.65 + color.hueP95 * 0.35),
            "temporal": weights.temporal * finite(temporal.luminance * 0.45 + temporal.highlight * 0.35 + temporal.flicker * 0.20),
            "structure": weights.structure * finite(structure),
            "penalty_clipping": weights.clippingPenalty * clipping,
            "penalty_black_crush": weights.blackCrushPenalty * blackCrush,
            "penalty_saturation": weights.saturationPenalty * color.overSaturation,
            "penalty_invalid": weights.invalidPenalty * Double(invalidCount)
        ]
        contributions = contributions.mapValues(finite)
        let objective = contributions.values.reduce(0, +)
        let breakdown = V2MetricBreakdown(
            objective: objective,
            luminanceError: finite(luminanceError),
            absoluteNitError: finite(absoluteNitError),
            midtoneError: finite(midtoneError),
            diffuseWhiteError: finite(diffuseWhiteError),
            highlightError: finite(highlightError),
            shadowError: finite(shadowError),
            chromaError: finite(color.chroma),
            saturationError: finite(color.saturation),
            hueMeanError: finite(color.hueMean),
            hueP95Error: finite(color.hueP95),
            highChromaHueError: finite(color.highChromaHue),
            skinLikeHueError: finite(color.skinHue),
            temporalLuminanceError: finite(temporal.luminance),
            highlightPumping: finite(temporal.highlight),
            temporalFlicker: finite(temporal.flicker),
            sceneCutOvershoot: 0,
            sceneCutRecovery: 0,
            structureError: finite(structure),
            clippingRatio: clipping,
            blackCrushRatio: blackCrush,
            shadowLiftRatio: shadowLift,
            nearBlackContrastLoss: finite(nearBlackContrastLoss),
            highlightUnderReachRatio: highlightUnderReach,
            highlightOvershootRatio: highlightOvershoot,
            highlightCompressionError: finite(compressionError),
            specularPeakUnderReach: finite(specularUnder),
            specularPeakOvershoot: finite(specularOver),
            referenceDiffuseWhiteNits: finite(percentile(pairedReference, 0.90)),
            generatedDiffuseWhiteNits: finite(percentile(pairedGenerated, 0.90)),
            overSaturationRatio: color.overSaturation,
            underSaturationRatio: color.underSaturation,
            invalidSampleCount: invalidCount,
            luminanceRegionErrors: regionErrors.mapValues(finite),
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
            failures: failureTaxonomy(metrics: breakdown, confidence: confidence)
        )
    }

    static func aggregate(_ values: [V2MetricBreakdown]) -> V2MetricBreakdown {
        guard !values.isEmpty else { return zeroMetric(invalid: 1) }
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

    static func alignmentStatistics(prepared: PreparedPair) -> V2AlignmentStatistics {
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
            medianConfidence: percentile(confidences, 0.50),
            p10Confidence: percentile(confidences, 0.10),
            p50Confidence: percentile(confidences, 0.50),
            p90Confidence: percentile(confidences, 0.90),
            estimatedTimeOffset: prepared.alignment.coarseOffsetSeconds,
            offsetVariance: variance
        )
    }

    static func categories(scenes: [V2SceneEvaluation]) -> [String] {
        guard !scenes.isEmpty else { return ["UNCLASSIFIED_CONTENT"] }
        var result = Set(scenes.flatMap(\.tags))
        let metrics = aggregate(scenes.map(\.metrics))
        if metrics.referenceDiffuseWhiteNits > 150 { result.insert("HIGH_KEY") }
        if metrics.referenceDiffuseWhiteNits < 60 { result.insert("LOW_KEY") }
        if metrics.chromaError > 0.08 || metrics.overSaturationRatio > 0.1 { result.insert("HIGH_SATURATION") }
        if metrics.highlightUnderReachRatio > 0.2 { result.insert("HIGHLIGHT_RICH") }
        if result.isEmpty { result.insert("UNCLASSIFIED_CONTENT") }
        return result.sorted()
    }

    static func percentiles(_ values: [Double]) -> V2Percentiles {
        V2Percentiles(
            p1: percentile(values, 0.01), p10: percentile(values, 0.10),
            p25: percentile(values, 0.25), p50: percentile(values, 0.50),
            p75: percentile(values, 0.75), p90: percentile(values, 0.90),
            p95: percentile(values, 0.95), p99: percentile(values, 0.99),
            p999: percentile(values, 0.999)
        )
    }

    static func failureTaxonomy(metrics: V2MetricBreakdown, confidence: Double) -> [String] {
        var result: [String] = []
        if metrics.highlightUnderReachRatio > 0.20 { result.append("HIGHLIGHT_UNDERREACH") }
        if metrics.highlightOvershootRatio > 0.10 { result.append("HIGHLIGHT_OVERSHOOT") }
        if metrics.generatedDiffuseWhiteNits < metrics.referenceDiffuseWhiteNits * 0.8 { result.append("DIFFUSE_WHITE_LOW") }
        if metrics.generatedDiffuseWhiteNits > metrics.referenceDiffuseWhiteNits * 1.2 { result.append("DIFFUSE_WHITE_HIGH") }
        if metrics.midtoneError > 0.25 { result.append("MIDTONE_LOW") }
        if metrics.blackCrushRatio > 0.05 { result.append("BLACK_CRUSH") }
        if metrics.shadowLiftRatio > 0.10 { result.append("SHADOW_LIFT") }
        if metrics.underSaturationRatio > 0.15 { result.append("SATURATION_LOW") }
        if metrics.overSaturationRatio > 0.15 { result.append("SATURATION_HIGH") }
        if metrics.hueP95Error > 0.10 { result.append("HUE_SHIFT") }
        if metrics.temporalFlicker > 0.08 { result.append("TEMPORAL_FLICKER") }
        if confidence < 0.60 { result.append("ALIGNMENT_UNCERTAIN") }
        if metrics.hueP95Error > 0.2 && metrics.luminanceError > 0.4 { result.append("REFERENCE_MISMATCH") }
        return result.isEmpty ? ["UNKNOWN"] : result
    }

    private static func colorMetrics(_ frames: [V2FrameData]) -> (
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
                let ref = PerceptualColorV2.ictcp(rgbNits: reference)
                let gen = PerceptualColorV2.ictcp(rgbNits: generated)
                let refChroma = hypot(ref.y, ref.z)
                let genChroma = hypot(gen.y, gen.z)
                let refSaturation = refChroma / max(ref.x, 0.01)
                let genSaturation = genChroma / max(gen.x, 0.01)
                chromaErrors.append(abs(genChroma - refChroma))
                saturationErrors.append(abs(genSaturation - refSaturation))
                if refChroma > 0.01 && genChroma > 0.005 {
                    let hue = PerceptualColorV2.hueError(reference: reference, generated: generated)
                    hueErrors.append(hue)
                    if refChroma > 0.08 { highChroma.append(hue) }
                    if isSkinLike(reference) { skin.append(hue) }
                }
                if genSaturation > refSaturation * 1.25 + 0.01 { over += 1 }
                if genSaturation < refSaturation * 0.75 - 0.01 { under += 1 }
                count += 1
            }
        }
        return (
            average(chromaErrors), average(saturationErrors), average(hueErrors), percentile(hueErrors, 0.95),
            average(highChroma), average(skin), count > 0 ? Double(over) / Double(count) : 0,
            count > 0 ? Double(under) / Double(count) : 0
        )
    }

    static func temporalMetrics(_ frames: [V2FrameData]) -> (luminance: Double, highlight: Double, flicker: Double) {
        let sorted = frames.sorted { $0.generated.timestampSeconds < $1.generated.timestampSeconds }
        guard sorted.count > 1 else { return (0, 0, 0) }
        let referenceMeans = sorted.map { average($0.reference.lumaNits.map(Double.init)) }
        let generatedMeans = sorted.map { average($0.generated.lumaNits.map(Double.init)) }
        let referenceHighlights = sorted.map { percentile($0.reference.lumaNits.map(Double.init), 0.95) }
        let generatedHighlights = sorted.map { percentile($0.generated.lumaNits.map(Double.init), 0.95) }
        let luma = deltaError(referenceMeans, generatedMeans)
        let highlight = deltaError(referenceHighlights, generatedHighlights)
        var second: [Double] = []
        if sorted.count > 2 {
            for index in 2..<sorted.count {
                let ref = logRatio(referenceMeans[index], referenceMeans[index - 1]) - logRatio(referenceMeans[index - 1], referenceMeans[index - 2])
                let gen = logRatio(generatedMeans[index], generatedMeans[index - 1]) - logRatio(generatedMeans[index - 1], generatedMeans[index - 2])
                second.append(abs(ref - gen))
            }
        }
        return (luma, highlight, average(second))
    }

    private static func structureError(_ frames: [V2FrameData]) -> Double {
        let errors = frames.compactMap { frame -> Double? in
            let source = frame.sourceLuma.map(Double.init)
            let generated = frame.generated.lumaNits.map(Double.init)
            guard source.count == generated.count, let correlation = correlation(source, generated) else { return nil }
            return 1 - correlation
        }
        return average(errors)
    }

    private static func isSkinLike(_ rgb: SIMD3<Float>) -> Bool {
        let maxValue = max(rgb.x, max(rgb.y, rgb.z))
        guard maxValue > 1 else { return false }
        let normalized = rgb / maxValue
        return normalized.x > normalized.y && normalized.y > normalized.z && normalized.x - normalized.z > 0.12
    }

    private static func regionError(_ reference: [Double], _ generated: [Double], lower: Double, upper: Double) -> Double {
        guard !reference.isEmpty, !generated.isEmpty else { return 1 }
        let low = percentile(reference, lower)
        let high = percentile(reference, upper)
        let pairs = zip(reference, generated).filter { $0.0 >= low && $0.0 <= high }
        return logError(pairs.map(\.0), pairs.map(\.1))
    }

    private static func logError(_ lhs: [Double], _ rhs: [Double]) -> Double {
        meanZip(lhs, rhs) { abs(log(($1 + 1) / ($0 + 1))) }
    }

    private static func deltaError(_ reference: [Double], _ generated: [Double]) -> Double {
        guard reference.count > 1, generated.count > 1 else { return 0 }
        var values: [Double] = []
        for index in 1..<min(reference.count, generated.count) {
            values.append(abs(logRatio(reference[index], reference[index - 1]) - logRatio(generated[index], generated[index - 1])))
        }
        return average(values)
    }

    private static func logRatio(_ lhs: Double, _ rhs: Double) -> Double {
        log((max(lhs, 0) + 1) / (max(rhs, 0) + 1))
    }

    private static func meanZip(_ lhs: [Double], _ rhs: [Double], transform: (Double, Double) -> Double) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 1 }
        return (0..<count).map { transform(lhs[$0], rhs[$0]) }.reduce(0, +) / Double(count)
    }

    private static func fraction(_ pairs: [(Double, Double)], predicate: ((Double, Double)) -> Bool) -> Double {
        guard !pairs.isEmpty else { return 0 }
        return Double(pairs.filter(predicate).count) / Double(pairs.count)
    }

    private static func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count, lhs.count > 1 else { return nil }
        let lm = average(lhs), rm = average(rhs)
        var numerator = 0.0, lv = 0.0, rv = 0.0
        for index in lhs.indices {
            let l = lhs[index] - lm, r = rhs[index] - rm
            numerator += l * r; lv += l * l; rv += r * r
        }
        let denominator = sqrt(lv * rv)
        return denominator > 1e-12 ? max(-1, min(1, numerator / denominator)) : nil
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

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 1
    }

    private static func zeroMetric(invalid: Int) -> V2MetricBreakdown {
        V2MetricBreakdown(
            objective: invalid > 0 ? 10 : 0, luminanceError: 0, absoluteNitError: 0, midtoneError: 0,
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
