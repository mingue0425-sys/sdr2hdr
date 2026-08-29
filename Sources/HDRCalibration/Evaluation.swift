import Foundation
import HDRCore
import Metal
import simd

public struct FrameAnalysis {
    public let reference: ReferenceFrame
    public let generated: GeneratedFrame
    public let sourceLuma: [Float]
    public let confidence: Double
}

public enum ErrorMetrics {
    public static func evaluateScene(
        pairID: String,
        scene: SceneRange,
        analyses: [FrameAnalysis],
        parameters: CalibrationParameters
    ) -> SceneMetrics {
        let referenceLuma = analyses.flatMap(\.reference.lumaNits).map(Double.init)
        let generatedLuma = analyses.flatMap(\.generated.lumaNits).map(Double.init)
        let generatedValues = Array(generatedLuma)
        let lumaError = meanLogRatio(referenceLuma, generatedLuma)
        let referenceP90 = percentile(referenceLuma, 0.90)
        let referenceP50 = percentile(referenceLuma, 0.50)
        let highlightPairs = zip(referenceLuma, generatedValues).filter { $0.0 >= referenceP90 }
        let highlightReference = highlightPairs.map(\.0)
        let highlightGenerated = highlightPairs.map(\.1)
        let highlightError = meanLogRatio(highlightReference, Array(highlightGenerated))
        let diffuseWhiteError = relativeError(percentile(generatedLuma, 0.50), referenceP50)
        let shadowThreshold = percentile(referenceLuma, 0.25)
        let shadowPairs = zip(referenceLuma, generatedValues).filter { $0.0 <= shadowThreshold }
        let shadowReference = shadowPairs.map(\.0)
        let shadowGenerated = shadowPairs.map(\.1)
        let shadowError = meanNormalizedDifference(shadowReference, Array(shadowGenerated), floor: Double(parameters.paperWhiteNits) * 0.05)
        let colorError = meanColorError(analyses)
        let temporalError = temporalErrorFor(analyses)
        let structureError = structureErrorFor(analyses)
        let clipped = generatedLuma.filter { $0 >= Double(parameters.peakNits) * 0.999 }.count
        let clippedRatio = generatedLuma.isEmpty ? 0 : Double(clipped) / Double(generatedLuma.count)
        let families = classify(
            referenceP99: percentile(referenceLuma, 0.99),
            generatedP99: percentile(generatedLuma, 0.99),
            referenceP50: referenceP50,
            generatedP50: percentile(generatedLuma, 0.50),
            highlightError: highlightError,
            diffuseWhiteError: diffuseWhiteError,
            shadowError: shadowError,
            colorError: colorError,
            temporalError: temporalError,
            clippedRatio: clippedRatio,
            structureError: structureError
        )
        let confidence = analyses.isEmpty ? 0 : analyses.map(\.confidence).reduce(0, +) / Double(analyses.count)
        return SceneMetrics(
            pairID: pairID,
            sceneID: scene.id,
            tags: scene.tags,
            alignmentConfidence: confidence,
            frameCount: analyses.count,
            referenceLuminance: MetricVector(values: referenceLuma),
            generatedLuminance: MetricVector(values: generatedLuma),
            luminanceError: finiteOrLarge(lumaError),
            highlightError: finiteOrLarge(highlightError),
            diffuseWhiteError: finiteOrLarge(diffuseWhiteError),
            shadowError: finiteOrLarge(shadowError),
            colorError: finiteOrLarge(colorError),
            temporalError: finiteOrLarge(temporalError),
            structureError: finiteOrLarge(structureError),
            clippedRatio: clippedRatio,
            errorFamilies: families
        )
    }

    public static func aggregate(
        split: DatasetSplit,
        pairCount: Int,
        scenes: [SceneMetrics]
    ) -> DatasetMetrics {
        func average(_ value: (SceneMetrics) -> Double) -> Double {
            guard !scenes.isEmpty else { return .nan }
            return scenes.map(value).reduce(0, +) / Double(scenes.count)
        }
        let luma = average(\.luminanceError)
        let highlight = average(\.highlightError)
        let shadow = average(\.shadowError)
        let color = average(\.colorError)
        let temporal = average(\.temporalError)
        let diffuse = average(\.diffuseWhiteError)
        let structure = average(\.structureError)
        let objective = luma * 0.30 + highlight * 0.25 + diffuse * 0.15 + shadow * 0.10 + color * 0.10 + temporal * 0.05 + structure * 0.05
        return DatasetMetrics(
            split: split,
            pairCount: pairCount,
            sceneCount: scenes.count,
            frameCount: scenes.reduce(0) { $0 + $1.frameCount },
            objective: objective,
            luminanceError: luma,
            highlightError: highlight,
            shadowError: shadow,
            colorError: color,
            temporalError: temporal,
            sceneMetrics: scenes
        )
    }

    private static func classify(
        referenceP99: Double,
        generatedP99: Double,
        referenceP50: Double,
        generatedP50: Double,
        highlightError: Double,
        diffuseWhiteError: Double,
        shadowError: Double,
        colorError: Double,
        temporalError: Double,
        clippedRatio: Double,
        structureError: Double
    ) -> [ErrorFamily] {
        var result: [ErrorFamily] = []
        if highlightError > 0.15 {
            result.append(generatedP99 < referenceP99 ? .underExpandedHighlights : .overExpandedHighlights)
        }
        if diffuseWhiteError > 0.15 {
            result.append(generatedP50 < referenceP50 ? .diffuseWhiteTooLow : .diffuseWhiteTooHigh)
            result.append(generatedP50 < referenceP50 ? .midtonesTooDark : .midtonesTooBright)
        }
        if shadowError > 0.15 {
            result.append(generatedP50 < referenceP50 ? .shadowCrush : .shadowLift)
        }
        if colorError > 0.12 { result.append(.hueShift) }
        if clippedRatio > 0.01 { result.append(.gamutClip) }
        if temporalError > 0.10 { result.append(.temporalPumping) }
        if structureError > 0.20 { result.append(.referenceGradeMismatch) }
        if result.isEmpty,
           referenceP99.isFinite,
           generatedP99.isFinite,
           referenceP99 > 100,
           generatedP99 < referenceP99 * 0.5 {
            result.append(.unrecoverableFromSDR)
        }
        return result
    }

    private static func meanLogRatio(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return .nan }
        let count = min(lhs.count, rhs.count)
        return (0..<count).reduce(0) { total, index in
            total + abs(log((rhs[index] + 1) / (lhs[index] + 1)))
        } / Double(count)
    }

    private static func meanNormalizedDifference(_ lhs: [Double], _ rhs: [Double], floor: Double) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return .nan }
        let count = min(lhs.count, rhs.count)
        return (0..<count).reduce(0) { total, index in
            total + abs(lhs[index] - rhs[index]) / max(abs(lhs[index]), floor)
        } / Double(count)
    }

    private static func relativeError(_ lhs: Double, _ rhs: Double) -> Double {
        guard lhs.isFinite, rhs.isFinite else { return .nan }
        return abs(lhs - rhs) / max(abs(rhs), 1)
    }

    private static func meanColorError(_ analyses: [FrameAnalysis]) -> Double {
        var total = 0.0
        var count = 0
        for analysis in analyses {
            for (reference, generated) in zip(analysis.reference.rgbNits, analysis.generated.rgbNits) {
                let referenceLuma = max(simd_dot(reference, HDRColorMath.bt2020Luminance), 1)
                let generatedLuma = max(simd_dot(generated, HDRColorMath.bt2020Luminance), 1)
                let referenceChroma = reference / referenceLuma
                let generatedChroma = generated / generatedLuma
                total += Double(simd_distance(referenceChroma, generatedChroma))
                count += 1
            }
        }
        return count == 0 ? .nan : total / Double(count)
    }

    private static func temporalErrorFor(_ analyses: [FrameAnalysis]) -> Double {
        guard analyses.count > 1 else { return 0 }
        var total = 0.0
        var count = 0
        for index in 1..<analyses.count {
            let previousReference = max(analyses[index - 1].reference.lumaNits.reduce(0, +) / Float(max(1, analyses[index - 1].reference.lumaNits.count)), 1)
            let currentReference = max(analyses[index].reference.lumaNits.reduce(0, +) / Float(max(1, analyses[index].reference.lumaNits.count)), 1)
            let previousGenerated = max(analyses[index - 1].generated.lumaNits.reduce(0, +) / Float(max(1, analyses[index - 1].generated.lumaNits.count)), 1)
            let currentGenerated = max(analyses[index].generated.lumaNits.reduce(0, +) / Float(max(1, analyses[index].generated.lumaNits.count)), 1)
            let referenceDelta = log(Double(currentReference / previousReference))
            let generatedDelta = log(Double(currentGenerated / previousGenerated))
            total += abs(referenceDelta - generatedDelta)
            count += 1
        }
        return count == 0 ? 0 : total / Double(count)
    }

    private static func structureErrorFor(_ analyses: [FrameAnalysis]) -> Double {
        var total = 0.0
        var count = 0
        for analysis in analyses {
            let source = analysis.sourceLuma.map(Double.init)
            let generated = analysis.generated.lumaNits.map(Double.init)
            guard source.count == generated.count, source.count > 1,
                  let correlation = correlation(source, generated) else { continue }
            total += 1 - correlation
            count += 1
        }
        return count == 0 ? .nan : total / Double(count)
    }

    private static func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count, lhs.count > 1 else { return nil }
        let lhsMean = lhs.reduce(0, +) / Double(lhs.count)
        let rhsMean = rhs.reduce(0, +) / Double(rhs.count)
        var numerator = 0.0
        var lhsVariance = 0.0
        var rhsVariance = 0.0
        for index in lhs.indices {
            let a = lhs[index] - lhsMean
            let b = rhs[index] - rhsMean
            numerator += a * b
            lhsVariance += a * a
            rhsVariance += b * b
        }
        let denominator = sqrt(lhsVariance * rhsVariance)
        return denominator > 0 ? numerator / denominator : nil
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)]
    }

    private static func finiteOrLarge(_ value: Double) -> Double {
        value.isFinite ? value : 1e6
    }
}

struct PreparedMatch {
    let match: MatchedFrame
    let sdr: FrameSample
    let hdr: FrameSample
    let reference: ReferenceFrame
    let sourceLuma: [Float]
}

struct PreparedTemporalFrame {
    let sdr: FrameSample
    let reference: ReferenceFrame
    let sourceLuma: [Float]
    let confidence: Double
}

struct PreparedTemporalWindow {
    let sceneID: String
    let frames: [PreparedTemporalFrame]
    let decision: V4TemporalWindowDecision

    init(
        sceneID: String,
        frames: [PreparedTemporalFrame],
        decision: V4TemporalWindowDecision? = nil
    ) {
        self.sceneID = sceneID
        self.frames = frames
        self.decision = decision ?? V4TemporalWindowPolicy.v5.decision(actualDecodedFrameCount: frames.count)
    }
}

struct PreparedPair {
    let record: PairRecord
    let sdrSequence: FrameSequence
    let alignment: AlignmentResult
    let scenes: [SceneRange]
    let matches: [PreparedMatch]
    let temporalWindows: [PreparedTemporalWindow]
}

public final class PairEvaluator {
    private let device: MTLDevice
    private let experiment: ExperimentConfig

    public init(device: MTLDevice, experiment: ExperimentConfig = ExperimentConfig()) {
        self.device = device
        self.experiment = experiment
    }

    /// Single alignment entry point shared by the production calibration
    /// preparation path and the structural correctness review.
    public static func align(
        sdr: FrameSequence,
        hdr: FrameSequence,
        confidenceThreshold: Double
    ) -> AlignmentResult {
        TemporalAligner.align(
            sdr: sdr,
            hdr: hdr,
            confidenceThreshold: confidenceThreshold
        )
    }

    func prepare(record: PairRecord, manifestURL: URL) async throws -> PreparedPair {
        let urls = record.resolvedURLs(relativeTo: manifestURL)
        let hdrMetadata = try await MetadataProbe.probe(url: urls.hdr)
        if hdrMetadata.color.referenceTransfer == .hlg && !experiment.allowHLGModel {
            throw CalibrationError.unsupportedReference("HLG model disabled for \(record.id)")
        }

        let maxFrames = max(64, experiment.maxFramesPerScene * 16)
        let sdrSequence = try await FrameReader.read(
            url: urls.sdr,
            pixelFormat: CalibrationPixelFormat.sdrNV12,
            maxFrames: maxFrames
        )
        let hdrSequence = try await FrameReader.read(
            url: urls.hdr,
            pixelFormat: CalibrationPixelFormat.hdrP010,
            maxFrames: maxFrames
        )
        let alignment = Self.align(
            sdr: sdrSequence,
            hdr: hdrSequence,
            confidenceThreshold: experiment.alignmentConfidenceThreshold
        )
        let sortedConfidence = alignment.matches.map(\.confidence).sorted()
        let p10Index = max(0, Int(Double(max(sortedConfidence.count - 1, 0)) * 0.10))
        let p10Confidence = sortedConfidence.isEmpty ? 0 : sortedConfidence[p10Index]
        let policyStatus = V4AlignmentPolicy.status(
            sampledFrames: sdrSequence.samples.count,
            matchedFrames: alignment.matches.count,
            medianConfidence: alignment.medianConfidence,
            p10Confidence: p10Confidence
        )
        guard alignment.status != "REJECT", policyStatus != "REJECT" else {
            throw CalibrationError.alignmentFailed(
                "\(record.id): aligner=\(alignment.status), policy=\(policyStatus), median confidence \(alignment.medianConfidence), p10 \(p10Confidence)"
            )
        }

        let scenes = SceneDetector.detect(sequence: sdrSequence)
        let selectedMatches = representativeMatches(
            alignment.matches,
            scenes: scenes,
            sdrSamples: sdrSequence.samples,
            maxPerScene: experiment.maxFramesPerScene
        )
        var preparedMatches: [PreparedMatch] = []
        preparedMatches.reserveCapacity(selectedMatches.count)
        for match in selectedMatches {
            guard let sdr = sample(for: match.sdrSequencePosition, sourceIndex: match.sdrIndex, in: sdrSequence),
                  let hdr = sample(for: match.hdrSequencePosition, sourceIndex: match.hdrIndex, in: hdrSequence) else {
                continue
            }
            let reference = try HDRReferenceDecoder.decode(
                pixelBuffer: hdr.pixelBuffer,
                timestampSeconds: match.hdrTimeSeconds,
                transfer: hdrMetadata.color.referenceTransfer,
                referencePeakNits: experiment.referenceTargetPeakNits
            )
            let sourceLuma = FrameDescriptorBuilder.downsample(
                sdr.lumaGrid,
                sourceWidth: 64,
                sourceHeight: 36,
                width: reference.width,
                height: reference.height
            )
            preparedMatches.append(PreparedMatch(
                match: match,
                sdr: sdr,
                hdr: hdr,
                reference: reference,
                sourceLuma: sourceLuma
            ))
        }
        guard !preparedMatches.isEmpty else {
            throw CalibrationError.alignmentFailed("\(record.id): no usable matched frames")
        }
        let temporalWindows = try await prepareTemporalWindows(
            scenes: scenes,
            alignment: alignment,
            sdrURL: urls.sdr,
            hdrURL: urls.hdr,
            hdrTransfer: hdrMetadata.color.referenceTransfer
        )
        return PreparedPair(
            record: record,
            sdrSequence: sdrSequence,
            alignment: alignment,
            scenes: scenes,
            matches: preparedMatches,
            temporalWindows: temporalWindows
        )
    }

    private func prepareTemporalWindows(
        scenes: [SceneRange],
        alignment: AlignmentResult,
        sdrURL: URL,
        hdrURL: URL,
        hdrTransfer: ReferenceTransfer
    ) async throws -> [PreparedTemporalWindow] {
        var windows: [PreparedTemporalWindow] = []
        windows.reserveCapacity(scenes.count)
        for scene in scenes {
            let sceneMatches = alignment.matches.filter {
                guard let position = $0.sdrSequencePosition else { return false }
                return scene.contains(sequencePosition: position)
            }
            guard let anchor = sceneMatches.max(by: { $0.confidence < $1.confidence }) else { continue }
            // Start at the detected shot boundary so the first sample exercises
            // scene-cut reset, followed by 15 genuinely sequential frames.
            let start = max(anchor.sdrTimeSeconds - 0.05, 0)
            let offset = anchor.hdrTimeSeconds - anchor.sdrTimeSeconds
            let sdr = try await FrameReader.readWindow(
                url: sdrURL, pixelFormat: CalibrationPixelFormat.sdrNV12,
                startSeconds: start, frameCount: V4TemporalWindowPolicy.v5.targetFrameCount,
                framesPerSecond: 30
            )
            let hdr = try await FrameReader.readWindow(
                url: hdrURL, pixelFormat: CalibrationPixelFormat.hdrP010,
                startSeconds: max(start + offset, 0),
                frameCount: V4TemporalWindowPolicy.v5.targetFrameCount,
                framesPerSecond: 30
            )
            let count = min(sdr.samples.count, hdr.samples.count)
            let decision = V4TemporalWindowPolicy.v5.decision(actualDecodedFrameCount: count)
            guard decision.accepted else { continue }
            var frames: [PreparedTemporalFrame] = []
            frames.reserveCapacity(count)
            for index in 0..<count {
                let sdrFrame = sdr.samples[index]
                let reference = try HDRReferenceDecoder.decode(
                    pixelBuffer: hdr.samples[index].pixelBuffer,
                    timestampSeconds: hdr.samples[index].descriptor.timestampSeconds,
                    transfer: hdrTransfer,
                    referencePeakNits: experiment.referenceTargetPeakNits
                )
                let sourceLuma = FrameDescriptorBuilder.downsample(
                    sdrFrame.lumaGrid, sourceWidth: 64, sourceHeight: 36,
                    width: reference.width, height: reference.height
                )
                frames.append(PreparedTemporalFrame(
                    sdr: sdrFrame, reference: reference, sourceLuma: sourceLuma,
                    confidence: anchor.confidence
                ))
            }
            windows.append(PreparedTemporalWindow(sceneID: scene.id, frames: frames, decision: decision))
        }
        return windows
    }

    private func representativeMatches(
        _ matches: [MatchedFrame],
        scenes: [SceneRange],
        sdrSamples: [FrameSample],
        maxPerScene: Int
    ) -> [MatchedFrame] {
        guard !matches.isEmpty, maxPerScene > 0 else { return [] }
        var selected: [MatchedFrame] = []
        for scene in scenes {
            let sceneMatches = matches.filter {
                guard let position = $0.sdrSequencePosition else { return false }
                return scene.contains(sequencePosition: position)
            }
            guard !sceneMatches.isEmpty else { continue }
            let count = min(maxPerScene, sceneMatches.count)
            var candidates: [MatchedFrame] = []
            func appendUnique(_ match: MatchedFrame?) {
                guard let match,
                      !candidates.contains(where: {
                          ($0.sdrSequencePosition ?? $0.sdrIndex) ==
                              (match.sdrSequencePosition ?? match.sdrIndex)
                      }) else { return }
                candidates.append(match)
            }
            appendUnique(sceneMatches.first)
            appendUnique(sceneMatches[sceneMatches.count / 2])
            appendUnique(sceneMatches.last)

            let withSamples = sceneMatches.compactMap { match in
                sample(for: match.sdrSequencePosition, sourceIndex: match.sdrIndex, in: sdrSamples)
                    .map { (match, $0) }
            }
            appendUnique(withSamples.max { $0.1.descriptor.meanLuma < $1.1.descriptor.meanLuma }?.0)
            appendUnique(withSamples.max { $0.1.descriptor.variance < $1.1.descriptor.variance }?.0)
            appendUnique(withSamples.max { $0.1.descriptor.edgeEnergy < $1.1.descriptor.edgeEnergy }?.0)
            appendUnique(withSamples.max {
                Self.percentile($0.1.lumaGrid, 0.95) < Self.percentile($1.1.lumaGrid, 0.95)
            }?.0)
            appendUnique(withSamples.max {
                OfflinePixelSampler.chromaMagnitude(pixelBuffer: $0.1.pixelBuffer) <
                    OfflinePixelSampler.chromaMagnitude(pixelBuffer: $1.1.pixelBuffer)
            }?.0)

            if candidates.count < count {
                for index in 0..<count {
                    let normalized = count == 1 ? 0.5 : Double(index) / Double(count - 1)
                    let sourceIndex = min(
                        sceneMatches.count - 1,
                        max(0, Int((normalized * Double(sceneMatches.count - 1)).rounded()))
                    )
                    appendUnique(sceneMatches[sourceIndex])
                }
            }
            selected.append(contentsOf: candidates.prefix(count).sorted {
                ($0.sdrSequencePosition ?? $0.sdrIndex) < ($1.sdrSequencePosition ?? $1.sdrIndex)
            })
        }
        return selected.isEmpty ? Array(matches.prefix(maxPerScene)) : selected
    }

    private func sample(
        for sequencePosition: Int?,
        sourceIndex: Int,
        in sequence: FrameSequence
    ) -> FrameSample? {
        if let sequencePosition {
            return sequence.samples.first { $0.sequencePosition == sequencePosition }
        }
        // Compatibility for historical alignment JSON that predates the
        // explicit sequence-position fields. New alignments always take the
        // sequence-position branch above, so sparse scene logic never mixes
        // the two domains.
        return sequence.samples.first { $0.index == sourceIndex }
    }

    private func sample(
        for sequencePosition: Int?,
        sourceIndex: Int,
        in samples: [FrameSample]
    ) -> FrameSample? {
        if let sequencePosition {
            return samples.first { $0.sequencePosition == sequencePosition }
        }
        return samples.first { $0.index == sourceIndex }
    }

    private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)]
    }

    func evaluate(
        prepared: PreparedPair,
        parameters: CalibrationParameters,
        split: DatasetSplit
    ) throws -> DatasetMetrics {
        let configuration = try parameters.configuration()
        let evaluator = try HDRCoreOfflineEvaluator(device: device, configuration: configuration)
        var analyses: [FrameAnalysis] = []
        analyses.reserveCapacity(prepared.matches.count)
        evaluator.clearTemporalHistory()
        evaluator.automaticTemporalEstimationEnabled = false
        for preparedMatch in prepared.matches {
            let generated = try evaluator.evaluate(
                pixelBuffer: preparedMatch.sdr.pixelBuffer,
                timestampSeconds: preparedMatch.match.sdrTimeSeconds,
                configuration: configuration
            )
            evaluator.clearTemporalHistory()
            analyses.append(FrameAnalysis(
                reference: preparedMatch.reference,
                generated: generated,
                sourceLuma: preparedMatch.sourceLuma,
                confidence: preparedMatch.match.confidence
            ))
        }
        evaluator.automaticTemporalEstimationEnabled = true

        let sceneMetrics = prepared.scenes.map { scene in
            let sceneAnalyses = analyses.filter { analysis in
                let time = analysis.generated.timestampSeconds
                guard let start = prepared.sdrSequence.samples.first(where: { scene.contains(sequencePosition: $0.sequencePosition) })?.descriptor.timestampSeconds,
                      let end = prepared.sdrSequence.samples.last(where: { scene.contains(sequencePosition: $0.sequencePosition) })?.descriptor.timestampSeconds else { return false }
                return time >= start && time <= end
            }
            return ErrorMetrics.evaluateScene(
                pairID: prepared.record.id,
                scene: scene,
                analyses: sceneAnalyses,
                parameters: parameters
            )
        }
        return ErrorMetrics.aggregate(split: split, pairCount: 1, scenes: sceneMetrics)
    }

    public func evaluate(
        record: PairRecord,
        manifestURL: URL,
        parameters: CalibrationParameters,
        split: DatasetSplit
    ) async throws -> DatasetMetrics {
        let prepared = try await prepare(record: record, manifestURL: manifestURL)
        return try evaluate(prepared: prepared, parameters: parameters, split: split)
    }
}
