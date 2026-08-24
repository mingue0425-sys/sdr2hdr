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

public enum TemporalAligner {
    public static func align(
        sdr: FrameSequence,
        hdr: FrameSequence,
        offsetRangeSeconds: ClosedRange<Double> = -2...2,
        offsetStep: Double = 1.0 / 30.0,
        confidenceThreshold: Double = 0.60
    ) -> AlignmentResult {
        guard !sdr.samples.isEmpty, !hdr.samples.isEmpty else {
            return AlignmentResult(status: "REJECT", coarseOffsetSeconds: 0, matches: [], rejectedFrames: 0, medianConfidence: 0, notes: ["one sequence has no decoded samples"])
        }
        var bestOffset = 0.0
        var bestScore = Double.greatestFiniteMagnitude
        var offset = offsetRangeSeconds.lowerBound
        while offset <= offsetRangeSeconds.upperBound + offsetStep * 0.5 {
            var distances: [Double] = []
            for sample in sdr.samples {
                let target = sample.descriptor.timestampSeconds + offset
                if let nearest = nearestSample(to: target, in: hdr.samples) {
                    distances.append(FrameDescriptorBuilder.alignmentDistance(
                        sample.descriptor,
                        nearest.descriptor,
                        lhsGrid: sample.lumaGrid,
                        rhsGrid: nearest.lumaGrid
                    ))
                }
            }
            if !distances.isEmpty {
                let score = distances.reduce(0, +) / Double(distances.count)
                if score < bestScore {
                    bestScore = score
                    bestOffset = offset
                }
            }
            offset += offsetStep
        }

        var matches: [MatchedFrame] = []
        var rejected = 0
        for sample in sdr.samples {
            let target = sample.descriptor.timestampSeconds + bestOffset
            guard let nearest = nearestSample(to: target, in: hdr.samples) else {
                rejected += 1
                continue
            }
            let distance = FrameDescriptorBuilder.alignmentDistance(
                sample.descriptor,
                nearest.descriptor,
                lhsGrid: sample.lumaGrid,
                rhsGrid: nearest.lumaGrid
            )
            let confidence = max(0, min(1, exp(-distance * 4)))
            if confidence >= confidenceThreshold {
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
        if matches.isEmpty || median < confidenceThreshold {
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
            notes: ["brightness-invariant alignment descriptor: spatial correlation + shifted histogram + normalized statistics"]
        )
    }

    private static func nearestSample(to timestamp: Double, in samples: [FrameSample]) -> FrameSample? {
        samples.min {
            abs($0.descriptor.timestampSeconds - timestamp) < abs($1.descriptor.timestampSeconds - timestamp)
        }
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
