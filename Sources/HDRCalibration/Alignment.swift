import CoreMedia
import Foundation

public struct SceneRange: Codable, Sendable {
    public let id: String
    /// Scene bounds are positions in `FrameSequence.samples`, not source
    /// frame indices. The explicit name prevents sparse-index mixing.
    public let startSequencePosition: Int
    public let endSequencePosition: Int
    public let tags: [String]

    public init(id: String, startSequencePosition: Int, endSequencePosition: Int, tags: [String]) {
        self.id = id
        self.startSequencePosition = startSequencePosition
        self.endSequencePosition = endSequencePosition
        self.tags = tags
    }

    /// Compatibility initializer for historical callers. The old names were
    /// ambiguous, but their values were always sequence positions.
    public init(id: String, startSample: Int, endSample: Int, tags: [String]) {
        self.init(id: id, startSequencePosition: startSample, endSequencePosition: endSample, tags: tags)
    }

    public var startSample: Int { startSequencePosition }
    public var endSample: Int { endSequencePosition }

    public func contains(sequencePosition: Int) -> Bool {
        sequencePosition >= startSequencePosition && sequencePosition <= endSequencePosition
    }

    private enum CodingKeys: String, CodingKey {
        case id, startSequencePosition, endSequencePosition, startSample, endSample, tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        startSequencePosition = try container.decodeIfPresent(Int.self, forKey: .startSequencePosition)
            ?? container.decode(Int.self, forKey: .startSample)
        endSequencePosition = try container.decodeIfPresent(Int.self, forKey: .endSequencePosition)
            ?? container.decode(Int.self, forKey: .endSample)
        tags = try container.decode([String].self, forKey: .tags)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startSequencePosition, forKey: .startSequencePosition)
        try container.encode(endSequencePosition, forKey: .endSequencePosition)
        try container.encode(tags, forKey: .tags)
    }
}

/// Produces a deterministic, one-to-one timestamp pairing without allowing
/// either source timeline to run backwards. The objective is lexicographic:
/// preserve the maximum number of usable pairs first, then minimize total
/// timestamp error among solutions with the same cardinality.
enum MonotonicTimestampPairer {
    private static let maximumWorkCells = 50_000_000

    private struct Score {
        let pairCount: Int
        let totalDistance: Double
    }

    private enum Decision: UInt8 {
        case end
        case skipSDR
        case skipHDR
        case match

        var tieBreakPriority: Int {
            switch self {
            case .match: return 3
            case .skipHDR: return 2
            case .skipSDR: return 1
            case .end: return 0
            }
        }
    }

    static func pairs(
        sdr: [FrameSample],
        hdr: [FrameSample],
        offset: Double,
        maximumDistance: Double
    ) -> [(FrameSample, FrameSample)] {
        guard !sdr.isEmpty, !hdr.isEmpty,
              sdr.count <= 512, hdr.count <= 512,
              offset.isFinite, maximumDistance.isFinite,
              maximumDistance >= 0 else { return [] }

        let columnCount = hdr.count + 1
        func cell(_ sdrIndex: Int, _ hdrIndex: Int) -> Int {
            sdrIndex * columnCount + hdrIndex
        }

        let cellCount = (sdr.count + 1) * columnCount
        var scores = Array(
            repeating: Score(pairCount: 0, totalDistance: 0),
            count: cellCount
        )
        var decisions = Array(repeating: Decision.end, count: cellCount)

        func preferred(
            _ candidate: Score,
            candidateDecision: Decision,
            over current: Score,
            currentDecision: Decision
        ) -> Bool {
            if candidate.pairCount != current.pairCount {
                return candidate.pairCount > current.pairCount
            }
            if candidate.totalDistance != current.totalDistance {
                return candidate.totalDistance < current.totalDistance
            }
            return candidateDecision.tieBreakPriority > currentDecision.tieBreakPriority
        }

        for sdrIndex in stride(from: sdr.count - 1, through: 0, by: -1) {
            for hdrIndex in stride(from: hdr.count - 1, through: 0, by: -1) {
                var best = scores[cell(sdrIndex + 1, hdrIndex)]
                var decision = Decision.skipSDR

                let skipHDR = scores[cell(sdrIndex, hdrIndex + 1)]
                if preferred(
                    skipHDR, candidateDecision: .skipHDR,
                    over: best, currentDecision: decision
                ) {
                    best = skipHDR
                    decision = .skipHDR
                }

                let distance = abs(
                    hdr[hdrIndex].descriptor.timestampSeconds -
                        (sdr[sdrIndex].descriptor.timestampSeconds + offset)
                )
                if distance <= maximumDistance {
                    let suffix = scores[cell(sdrIndex + 1, hdrIndex + 1)]
                    let matched = Score(
                        pairCount: suffix.pairCount + 1,
                        totalDistance: suffix.totalDistance + distance
                    )
                    if preferred(
                        matched, candidateDecision: .match,
                        over: best, currentDecision: decision
                    ) {
                        best = matched
                        decision = .match
                    }
                }

                scores[cell(sdrIndex, hdrIndex)] = best
                decisions[cell(sdrIndex, hdrIndex)] = decision
            }
        }

        var result: [(FrameSample, FrameSample)] = []
        result.reserveCapacity(scores[cell(0, 0)].pairCount)
        var sdrIndex = 0
        var hdrIndex = 0
        while sdrIndex < sdr.count, hdrIndex < hdr.count {
            switch decisions[cell(sdrIndex, hdrIndex)] {
            case .match:
                result.append((sdr[sdrIndex], hdr[hdrIndex]))
                sdrIndex += 1
                hdrIndex += 1
            case .skipSDR:
                sdrIndex += 1
            case .skipHDR:
                hdrIndex += 1
            case .end:
                sdrIndex = sdr.count
                hdrIndex = hdr.count
            }
        }
        return result
    }

    /// Bounds the aggregate DP work across offset search, window search, and
    /// final materialization. Callers validate actual sequence sizes first, so
    /// this calculation can stay exact without trusting configured maxima.
    static func workIsWithinBudget(
        sdrCount: Int,
        hdrCount: Int,
        candidateCount: Int,
        passCount: Int = 3
    ) -> Bool {
        guard sdrCount > 0, hdrCount > 0,
              candidateCount > 0, passCount > 0,
              sdrCount <= 512, hdrCount <= 512 else { return false }
        let cellCount = (sdrCount + 1) * (hdrCount + 1)
        return candidateCount <= maximumWorkCells / cellCount / passCount
    }
}

enum FrameSequenceValidator {
    static func failure(
        _ sequence: FrameSequence,
        expectedGridCount: Int
    ) -> String? {
        guard sequence.width > 0, sequence.height > 0,
              sequence.nominalFrameRate.isFinite,
              sequence.nominalFrameRate >= 0,
              sequence.durationSeconds.isFinite,
              sequence.durationSeconds >= 0 else {
            return "sequence metadata contains invalid dimensions, rate, or duration"
        }
        guard !sequence.samples.isEmpty else { return "sequence has no samples" }
        guard sequence.samples.count <= 512 else {
            return "sequence exceeds the 512-sample alignment safety bound"
        }
        guard Set(sequence.samples.map(\.sequencePosition)).count ==
                sequence.samples.count else {
            return "duplicate sequence positions"
        }
        for (index, sample) in sequence.samples.enumerated() {
            let descriptor = sample.descriptor
            guard descriptor.histogram.count == 16,
                  sample.lumaGrid.count == expectedGridCount else {
                return "sample \(index) has an invalid descriptor or proxy shape"
            }
            let histogramSum = descriptor.histogram.reduce(0, +)
            let sampleTimestamp = sample.timestamp.isNumeric ? sample.timestamp.seconds : .nan
            guard sample.index >= 0,
                  sample.sequencePosition == index,
                  sampleTimestamp.isFinite,
                  descriptor.timestampSeconds.isFinite,
                  abs(sampleTimestamp - descriptor.timestampSeconds) <= 1e-9,
                  descriptor.meanLuma.isFinite,
                  descriptor.variance.isFinite,
                  descriptor.edgeEnergy.isFinite,
                  (0...1).contains(descriptor.meanLuma),
                  (0...0.251).contains(descriptor.variance),
                  (0...1).contains(descriptor.edgeEnergy),
                  descriptor.histogram.allSatisfy({
                    $0.isFinite && (0...1).contains($0)
                  }),
                  abs(histogramSum - 1) <= 0.001,
                  sample.lumaGrid.allSatisfy({
                    $0.isFinite && (0...1).contains($0)
                  }) else {
                return "sample \(index) contains invalid descriptor or proxy data"
            }
            if index > 0 {
                let previous = sequence.samples[index - 1]
                guard sample.index > previous.index,
                      descriptor.timestampSeconds >
                        previous.descriptor.timestampSeconds else {
                    return "samples are not in monotonic sequence/timestamp order"
                }
            }
        }
        return nil
    }
}

public enum TemporalAligner {
    private struct MetricKey: Hashable {
        let sdrSequencePosition: Int
        let hdrSequencePosition: Int
    }

    public static func align(
        sdr: FrameSequence,
        hdr: FrameSequence,
        offsetRangeSeconds: ClosedRange<Double>? = nil,
        offsetStep: Double? = nil,
        confidenceThreshold: Double? = nil,
        matcherConfiguration: V6MatcherConfiguration = .v6
    ) -> AlignmentResult {
        if let failure = matcherConfiguration.validationFailure() {
            return rejection(
                "invalid matcher configuration: \(failure)",
                rejectedFrames: sdr.samples.count
            )
        }
        let resolvedRange = offsetRangeSeconds ?? (
            matcherConfiguration.offsetMinimumSeconds...matcherConfiguration.offsetMaximumSeconds
        )
        let resolvedStep = offsetStep ?? matcherConfiguration.offsetStepSeconds
        let resolvedThreshold = confidenceThreshold ??
            matcherConfiguration.acceptedConfidenceThreshold
        guard resolvedRange.lowerBound.isFinite,
              resolvedRange.upperBound.isFinite,
              resolvedRange.lowerBound >= -60,
              resolvedRange.upperBound <= 60,
              resolvedStep.isFinite,
              resolvedStep >= 1e-6,
              resolvedStep <= 10,
              resolvedThreshold.isFinite,
              (0...1).contains(resolvedThreshold) else {
            return rejection(
                "invalid alignment search bounds or confidence threshold",
                rejectedFrames: sdr.samples.count
            )
        }
        let offsetCount = Int(ceil(
            (resolvedRange.upperBound - resolvedRange.lowerBound) / resolvedStep
        )) + 1
        guard offsetCount <= 10_000 else {
            return rejection(
                "alignment offset grid exceeds 10000 candidates",
                rejectedFrames: sdr.samples.count
            )
        }
        guard !sdr.samples.isEmpty, !hdr.samples.isEmpty else {
            return rejection(
                "one sequence has no decoded samples",
                rejectedFrames: sdr.samples.count
            )
        }
        let expectedGridCount = matcherConfiguration.gridWidth * matcherConfiguration.gridHeight
        if let failure = FrameSequenceValidator.failure(
            sdr, expectedGridCount: expectedGridCount
        ) {
            return rejection("invalid SDR sequence: \(failure)", rejectedFrames: sdr.samples.count)
        }
        if let failure = FrameSequenceValidator.failure(
            hdr, expectedGridCount: expectedGridCount
        ) {
            return rejection("invalid HDR sequence: \(failure)", rejectedFrames: sdr.samples.count)
        }
        guard MonotonicTimestampPairer.workIsWithinBudget(
            sdrCount: sdr.samples.count,
            hdrCount: hdr.samples.count,
            candidateCount: offsetCount
        ) else {
            return rejection(
                "alignment search exceeds the bounded pairing work budget",
                rejectedFrames: sdr.samples.count
            )
        }
        let sdrFeatures = Dictionary(uniqueKeysWithValues: sdr.samples.map {
            ($0.sequencePosition, V6TransferInvariantMatcher.features(
                $0.lumaGrid, configuration: matcherConfiguration
            ))
        })
        let hdrFeatures = Dictionary(uniqueKeysWithValues: hdr.samples.map {
            ($0.sequencePosition, V6TransferInvariantMatcher.features(
                $0.lumaGrid, configuration: matcherConfiguration
            ))
        })
        var metricCache: [MetricKey: V6MatcherComponentMetrics] = [:]
        func metrics(_ lhs: FrameSample, _ rhs: FrameSample) -> V6MatcherComponentMetrics? {
            let key = MetricKey(
                sdrSequencePosition: lhs.sequencePosition,
                hdrSequencePosition: rhs.sequencePosition
            )
            if let cached = metricCache[key] { return cached }
            guard let lhsFeatures = sdrFeatures[lhs.sequencePosition],
                  let rhsFeatures = hdrFeatures[rhs.sequencePosition] else { return nil }
            let measured = V6TransferInvariantMatcher.compare(
                lhsFeatures, rhsFeatures,
                configuration: matcherConfiguration,
                descriptorFallback: (lhs.descriptor, rhs.descriptor)
            )
            metricCache[key] = measured
            return measured
        }
        let maximumPairingDistance = maximumPairingDistanceSeconds(
            sdrFPS: sdr.nominalFrameRate,
            hdrFPS: hdr.nominalFrameRate,
            offsetStep: resolvedStep
        )
        func score(_ samples: ArraySlice<FrameSample>, offset: Double) -> Double {
            let pairs = pairedSamples(
                sdr: samples,
                hdr: hdr.samples,
                offset: offset,
                maximumDistance: maximumPairingDistance
            )
            let confidences = pairs.compactMap { metrics($0.0, $0.1)?.confidence }
            guard !confidences.isEmpty, !samples.isEmpty else { return 0 }
            let mean = confidences.reduce(0, +) / Double(confidences.count)
            let coverage = Double(confidences.count) / Double(samples.count)
            return mean * min(max(coverage, 0), 1)
        }
        let offsets = offsetCandidates(range: resolvedRange, step: resolvedStep)
        var offsetScores: [(offset: Double, score: Double)] = []
        offsetScores.reserveCapacity(offsets.count)
        for offset in offsets {
            let candidateScore = score(sdr.samples[...], offset: offset)
            offsetScores.append((offset, candidateScore))
        }
        guard let best = preferredCandidate(offsetScores) else {
            return rejection("alignment produced no offset candidates", rejectedFrames: sdr.samples.count)
        }
        let bestOffset = best.offset
        let bestScore = best.score
        let second = offsetScores
            .filter { abs($0.offset - bestOffset) >= 0.10 }
        let secondBest = preferredCandidate(second) ?? best
        let windowSize = max(1, Int(ceil(Double(sdr.samples.count) / 8.0)))
        var perWindowOffsets: [Double] = []
        for start in stride(from: 0, to: sdr.samples.count, by: windowSize) {
            let end = min(start + windowSize, sdr.samples.count)
            let window = sdr.samples[start..<end]
            let candidates = offsets.map { candidate in
                (offset: candidate, score: score(window, offset: candidate))
            }
            perWindowOffsets.append(preferredCandidate(candidates)?.offset ?? bestOffset)
        }
        let offsetDrift = (perWindowOffsets.max() ?? bestOffset) -
            (perWindowOffsets.min() ?? bestOffset)

        var matches: [MatchedFrame] = []
        let finalPairs = pairedSamples(
            sdr: sdr.samples[...],
            hdr: hdr.samples,
            offset: bestOffset,
            maximumDistance: maximumPairingDistance
        )
        var rejected = sdr.samples.count - finalPairs.count
        var rawConfidences: [Double] = []
        for (sample, nearest) in finalPairs {
            guard let confidence = metrics(sample, nearest)?.confidence else {
                rejected += 1
                continue
            }
            rawConfidences.append(confidence)
            if confidence >= resolvedThreshold {
                matches.append(MatchedFrame(
                    sdrIndex: sample.index,
                    hdrIndex: nearest.index,
                    sdrSequencePosition: sample.sequencePosition,
                    hdrSequencePosition: nearest.sequencePosition,
                    sdrTimeSeconds: sample.descriptor.timestampSeconds,
                    hdrTimeSeconds: nearest.descriptor.timestampSeconds,
                    confidence: confidence
                ))
            } else {
                rejected += 1
            }
        }
        let confidences = matches.map(\.confidence).sorted()
        let median = confidences.isEmpty ? 0 : confidences[confidences.count / 2]
        let status: String
        if matches.isEmpty || median < resolvedThreshold {
            status = "REJECT"
        } else if abs(bestOffset) > 0.01 || rejected > 0 {
            status = "PAIR_NEEDS_ALIGNMENT"
        } else {
            status = "ALIGNED"
        }
        return AlignmentResult(
            status: status,
            coarseOffsetSeconds: bestOffset,
            matches: matches,
            rejectedFrames: rejected,
            medianConfidence: median,
            notes: [
                "matcher=\(matcherConfiguration.matcherVersion)",
                "transfer-invariant evidence: average-rank luma + signed gradients + multi-scale NCC + edge mask + local contrast",
                "one-to-one timestamp pairing tolerance=\(maximumPairingDistance)s"
            ],
            secondBestOffsetSeconds: secondBest.offset,
            bestVersusSecondMargin: bestScore - secondBest.score,
            perWindowOffsets: perWindowOffsets,
            offsetDriftSeconds: offsetDrift,
            confidenceQuantiles: quantiles(rawConfidences),
            matcherConfigurationHash: try? matcherConfiguration.canonicalSHA256()
        )
    }

    private static func rejection(_ note: String, rejectedFrames: Int) -> AlignmentResult {
        AlignmentResult(
            status: "REJECT",
            coarseOffsetSeconds: 0,
            matches: [],
            rejectedFrames: max(rejectedFrames, 0),
            medianConfidence: 0,
            notes: [note]
        )
    }

    private static func offsetCandidates(
        range: ClosedRange<Double>,
        step: Double
    ) -> [Double] {
        let span = range.upperBound - range.lowerBound
        let regularCount = Int(floor(span / step)) + 1
        var result = (0..<regularCount).map { range.lowerBound + Double($0) * step }
        if let last = result.last, range.upperBound - last > 1e-12 {
            result.append(range.upperBound)
        }
        return result
    }

    private static func preferredCandidate(
        _ candidates: [(offset: Double, score: Double)]
    ) -> (offset: Double, score: Double)? {
        var best: (offset: Double, score: Double)?
        for candidate in candidates {
            guard let current = best else {
                best = candidate
                continue
            }
            if candidate.score != current.score {
                if candidate.score > current.score { best = candidate }
                continue
            }
            if abs(candidate.offset) != abs(current.offset) {
                if abs(candidate.offset) < abs(current.offset) { best = candidate }
                continue
            }
            if candidate.offset < current.offset { best = candidate }
        }
        return best
    }

    private static func maximumPairingDistanceSeconds(
        sdrFPS: Double,
        hdrFPS: Double,
        offsetStep: Double
    ) -> Double {
        let rates = [sdrFPS, hdrFPS].filter { $0.isFinite && $0 > 0 }
        let slowestRate = rates.min() ?? 24
        return min(0.25, max(0.75 / max(slowestRate, 1), offsetStep * 0.55))
    }

    private static func pairedSamples(
        sdr: ArraySlice<FrameSample>,
        hdr: [FrameSample],
        offset: Double,
        maximumDistance: Double
    ) -> [(FrameSample, FrameSample)] {
        MonotonicTimestampPairer.pairs(
            sdr: Array(sdr), hdr: hdr,
            offset: offset, maximumDistance: maximumDistance
        )
    }

    private static func quantiles(_ values: [Double]) -> V6ConfidenceQuantiles {
        let sorted = values.sorted()
        func value(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        return V6ConfidenceQuantiles(
            minimum: value(0), p10: value(0.10), p25: value(0.25), p50: value(0.50),
            p75: value(0.75), p90: value(0.90), maximum: value(1)
        )
    }
}

public enum SceneDetector {
    public static func detect(sequence: FrameSequence) -> [SceneRange] {
        guard !sequence.samples.isEmpty else { return [] }
        var boundaries: [Int] = [0]
        for index in 1..<sequence.samples.count {
            let previous = sequence.samples[index - 1].descriptor
            let current = sequence.samples[index].descriptor
            let distance = FrameDescriptorBuilder.distance(previous, current)
            if distance > 0.28 || abs(previous.edgeEnergy - current.edgeEnergy) > 0.18 {
                boundaries.append(index)
            }
        }
        boundaries.append(sequence.samples.count)
        var scenes: [SceneRange] = []
        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = max(start, boundaries[index + 1] - 1)
            let values = Array(sequence.samples[start...end].map(\.descriptor.meanLuma))
            let tags = classify(values: values)
            scenes.append(SceneRange(id: String(format: "scene_%04d", index + 1), startSequencePosition: start, endSequencePosition: end, tags: tags))
        }
        return scenes
    }

    private static func classify(values: [Float]) -> [String] {
        guard !values.isEmpty else { return ["UNKNOWN"] }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Float(values.count)
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.90))]
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.99))]
        var tags: [String] = []
        if mean < 0.20 { tags.append("LOW_KEY") }
        if mean > 0.65 { tags.append("HIGH_KEY") }
        if p99 > 0.95 && p99 - mean > 0.35 { tags.append("HIGHLIGHT_RICH") }
        if p90 - sorted[0] < 0.25 { tags.append("LOW_CONTRAST") }
        if tags.isEmpty { tags.append("MID_KEY") }
        return tags
    }
}

public enum SpatialAligner {
    public static func inspect(sdr: VideoMetadata, hdr: VideoMetadata) -> [String] {
        let sdrAspect = Double(sdr.width) / Double(max(sdr.height, 1))
        let hdrAspect = Double(hdr.width) / Double(max(hdr.height, 1))
        let aspectDelta = abs(sdrAspect - hdrAspect) / max(sdrAspect, hdrAspect)
        if aspectDelta < 0.02 { return ["same_aspect_uniform_scale"] }
        if aspectDelta < 0.12 { return ["recoverable_crop_or_letterbox"] }
        return ["large_geometry_difference"]
    }
}
