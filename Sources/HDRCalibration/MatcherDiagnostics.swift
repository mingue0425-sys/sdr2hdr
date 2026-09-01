import Foundation

public struct V6MatcherEvidenceConfiguration: Codable, Hashable, Sendable {
    public let version: String
    public let offsetMinimumSeconds: Double
    public let offsetMaximumSeconds: Double
    public let offsetStepSeconds: Double
    public let secondBestExclusionSeconds: Double
    public let windowCount: Int
    public let proxyWidth: Int
    public let maxDecodedFrames: Int
    public let acceptanceThreshold: Double
    public let matcherVersion: String
    public let matcherConfigurationHash: String

    public init(
        version: String = "v6-matcher-evidence-v1",
        offsetMinimumSeconds: Double = -2,
        offsetMaximumSeconds: Double = 2,
        offsetStepSeconds: Double = 1.0 / 30.0,
        secondBestExclusionSeconds: Double = 0.10,
        windowCount: Int = 8,
        proxyWidth: Int = 320,
        maxDecodedFrames: Int = 128,
        acceptanceThreshold: Double = 0.60,
        matcherVersion: String = V6MatcherConfiguration.v6.matcherVersion,
        matcherConfigurationHash: String = (try? V6MatcherConfiguration.v6.canonicalSHA256()) ?? "INVALID"
    ) {
        self.version = version
        self.offsetMinimumSeconds = offsetMinimumSeconds
        self.offsetMaximumSeconds = offsetMaximumSeconds
        self.offsetStepSeconds = offsetStepSeconds
        self.secondBestExclusionSeconds = secondBestExclusionSeconds
        self.windowCount = windowCount
        self.proxyWidth = proxyWidth
        self.maxDecodedFrames = maxDecodedFrames
        self.acceptanceThreshold = acceptanceThreshold
        self.matcherVersion = matcherVersion
        self.matcherConfigurationHash = matcherConfigurationHash
    }
}

public struct V6ConfidenceQuantiles: Codable, Hashable, Sendable {
    public let minimum: Double
    public let p10: Double
    public let p25: Double
    public let p50: Double
    public let p75: Double
    public let p90: Double
    public let maximum: Double
}

public struct V6MatcherWindowEvidence: Codable, Sendable {
    public let windowIndex: Int
    public let startSequencePosition: Int
    public let endSequencePosition: Int
    public let bestOffsetSeconds: Double
    public let robustScore: Double
}

public struct V6MatcherPairEvidence: Codable, Sendable {
    public let pairID: String
    public let split: DatasetSplit
    public let rawMatchCount: Int
    public let acceptedMatchCount: Int
    public let acceptanceRatio: Double
    public let confidence: V6ConfidenceQuantiles
    public let legacyAcceptedMatchCount: Int
    public let legacyAcceptanceRatio: Double
    public let legacyConfidence: V6ConfidenceQuantiles
    public let bestTemporalOffsetSeconds: Double
    public let secondBestOffsetSeconds: Double
    public let bestVersusSecondMargin: Double
    public let perWindowOffsets: [V6MatcherWindowEvidence]
    public let offsetDriftSeconds: Double
    public let edgeCorrelation: Double
    public let normalizedLumaCorrelation: Double
    public let rankNormalizedLumaCorrelation: Double
    public let gradientCorrelation: Double
    public let localContrastCorrelation: Double
    public let multiScaleNCC: Double
    public let robustConfidence: Double
    public let sceneBoundaryConsistency: Double
    public let duplicatedHDRMatchCount: Int
    public let droppedFrameEvidenceCount: Int
    public let sdrFPS: Double
    public let hdrFPS: Double
    public let sdrDurationSeconds: Double
    public let hdrDurationSeconds: Double
    public let durationDeltaSeconds: Double
    public let sdrDimensions: String
    public let hdrDimensions: String
    public let aspectRatioDelta: Double
    public let cropOrEditMismatch: Bool
}

public struct V6MatcherDiagnosticReport: Codable, Sendable {
    public let schemaVersion: String
    public let generatedAtUTC: String
    public let manifestPath: String
    public let frozenFilesAccessed: Bool
    public let configuration: V6MatcherEvidenceConfiguration
    public let pairs: [V6MatcherPairEvidence]
}

public enum V6MatcherDiagnostics {
    private struct Metrics {
        let edge: Double
        let luma: Double
        let rank: Double
        let gradient: Double
        let localContrast: Double
        let multiScale: Double

        var robust: Double {
            positive(rank) * 0.30 + positive(gradient) * 0.25 +
                positive(multiScale) * 0.25 + positive(edge) * 0.10 +
                positive(localContrast) * 0.10
        }

        private func positive(_ value: Double) -> Double { max(0, min(1, value)) }
    }

    private struct OffsetEvidence {
        let offset: Double
        let metrics: [Metrics]
        let pairs: [(FrameSample, FrameSample)]
        var score: Double { metrics.isEmpty ? 0 : metrics.map(\.robust).reduce(0, +) / Double(metrics.count) }
    }

    private typealias Features = V6MatcherFeatures

    public static func run(
        manifestURL: URL,
        outputURL: URL,
        configuration: V6MatcherEvidenceConfiguration = V6MatcherEvidenceConfiguration()
    ) async throws -> V6MatcherDiagnosticReport {
        let manifest = try V4Manifest.load(from: manifestURL)
        let records = manifest.pairs.filter { $0.split == .tune || $0.split == .validation }
        guard records.allSatisfy({ !$0.virginFrozen && $0.split != .frozen }) else {
            throw CalibrationError.incompleteEvaluation("matcher diagnostics may only open Tune/Validation media")
        }
        var evidence: [V6MatcherPairEvidence] = []
        for record in records {
            let urls = record.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
            async let sdr = FrameReader.read(
                url: urls.sdr, pixelFormat: CalibrationPixelFormat.sdrNV12,
                maxFrames: configuration.maxDecodedFrames, proxyWidth: configuration.proxyWidth
            )
            async let hdr = FrameReader.read(
                url: urls.hdr, pixelFormat: CalibrationPixelFormat.hdrP010,
                maxFrames: configuration.maxDecodedFrames, proxyWidth: configuration.proxyWidth
            )
            evidence.append(try analyze(
                pairID: record.id, split: record.split,
                sdr: await sdr, hdr: await hdr, configuration: configuration
            ))
        }
        let report = V6MatcherDiagnosticReport(
            schemaVersion: "v6-matcher-diagnostic-v2",
            generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            manifestPath: "repo:data_video/manifest-v4.json",
            frozenFilesAccessed: false,
            configuration: configuration,
            pairs: evidence
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try encoder.encode(report).write(to: outputURL)
        return report
    }

    private static func analyze(
        pairID: String,
        split: DatasetSplit,
        sdr: FrameSequence,
        hdr: FrameSequence,
        configuration: V6MatcherEvidenceConfiguration
    ) throws -> V6MatcherPairEvidence {
        let offsets = offsetCandidates(configuration)
        var metricCache: [UInt64: Metrics] = [:]
        let sdrFeatures = Dictionary(uniqueKeysWithValues: sdr.samples.map {
            ($0.sequencePosition, features($0.lumaGrid))
        })
        let hdrFeatures = Dictionary(uniqueKeysWithValues: hdr.samples.map {
            ($0.sequencePosition, features($0.lumaGrid))
        })
        var candidates: [OffsetEvidence] = []
        candidates.reserveCapacity(offsets.count)
        for offset in offsets {
            candidates.append(offsetEvidence(
                offset: offset, sdr: sdr.samples, hdr: hdr.samples,
                sdrFeatures: sdrFeatures, hdrFeatures: hdrFeatures,
                metricCache: &metricCache
            ))
        }
        guard let best = candidates.max(by: { $0.score < $1.score }) else {
            throw CalibrationError.alignmentFailed("\(pairID): no diagnostic offset candidates")
        }
        let second = candidates
            .filter { abs($0.offset - best.offset) >= configuration.secondBestExclusionSeconds }
            .max(by: { $0.score < $1.score }) ?? best
        let legacyConfidence = best.pairs.map { pair in
            let distance = FrameDescriptorBuilder.alignmentDistance(
                pair.0.descriptor, pair.1.descriptor,
                lhsGrid: pair.0.lumaGrid, rhsGrid: pair.1.lumaGrid
            )
            return max(0, min(1, exp(-distance * 4)))
        }
        let robustConfidences = best.metrics.map(\.robust)
        let accepted = robustConfidences.filter { $0 >= configuration.acceptanceThreshold }.count
        let legacyAccepted = legacyConfidence.filter { $0 >= configuration.acceptanceThreshold }.count
        let windows = windowEvidence(
            sdr: sdr.samples, hdr: hdr.samples,
            configuration: configuration,
            sdrFeatures: sdrFeatures, hdrFeatures: hdrFeatures,
            metricCache: &metricCache
        )
        let offsetsByWindow = windows.map(\.bestOffsetSeconds)
        let drift = (offsetsByWindow.max() ?? best.offset) - (offsetsByWindow.min() ?? best.offset)
        let aggregate = aggregateMetrics(best.metrics)
        let hdrPositions = best.pairs.map { $0.1.sequencePosition }
        let duplicateCount = hdrPositions.count - Set(hdrPositions).count
        var dropped = 0
        for index in 1..<best.pairs.count {
            let sdrDelta = best.pairs[index].0.sequencePosition - best.pairs[index - 1].0.sequencePosition
            let hdrDelta = best.pairs[index].1.sequencePosition - best.pairs[index - 1].1.sequencePosition
            if sdrDelta != hdrDelta { dropped += 1 }
        }
        let sceneConsistency = temporalChangeCorrelation(best.pairs)
        let sdrAspect = Double(sdr.width) / Double(max(sdr.height, 1))
        let hdrAspect = Double(hdr.width) / Double(max(hdr.height, 1))
        let aspectDelta = abs(sdrAspect - hdrAspect) / max(sdrAspect, hdrAspect)
        return V6MatcherPairEvidence(
            pairID: pairID, split: split,
            rawMatchCount: best.pairs.count,
            acceptedMatchCount: accepted,
            acceptanceRatio: robustConfidences.isEmpty ? 0 : Double(accepted) / Double(robustConfidences.count),
            confidence: quantiles(robustConfidences),
            legacyAcceptedMatchCount: legacyAccepted,
            legacyAcceptanceRatio: legacyConfidence.isEmpty ? 0 : Double(legacyAccepted) / Double(legacyConfidence.count),
            legacyConfidence: quantiles(legacyConfidence),
            bestTemporalOffsetSeconds: best.offset,
            secondBestOffsetSeconds: second.offset,
            bestVersusSecondMargin: best.score - second.score,
            perWindowOffsets: windows,
            offsetDriftSeconds: drift,
            edgeCorrelation: aggregate.edge,
            normalizedLumaCorrelation: aggregate.luma,
            rankNormalizedLumaCorrelation: aggregate.rank,
            gradientCorrelation: aggregate.gradient,
            localContrastCorrelation: aggregate.localContrast,
            multiScaleNCC: aggregate.multiScale,
            robustConfidence: aggregate.robust,
            sceneBoundaryConsistency: sceneConsistency,
            duplicatedHDRMatchCount: duplicateCount,
            droppedFrameEvidenceCount: dropped,
            sdrFPS: sdr.nominalFrameRate, hdrFPS: hdr.nominalFrameRate,
            sdrDurationSeconds: sdr.durationSeconds, hdrDurationSeconds: hdr.durationSeconds,
            durationDeltaSeconds: abs(sdr.durationSeconds - hdr.durationSeconds),
            sdrDimensions: "\(sdr.width)x\(sdr.height)",
            hdrDimensions: "\(hdr.width)x\(hdr.height)",
            aspectRatioDelta: aspectDelta,
            cropOrEditMismatch: aspectDelta > 0.02 || abs(sdr.durationSeconds - hdr.durationSeconds) > 0.25
        )
    }

    private static func offsetCandidates(_ configuration: V6MatcherEvidenceConfiguration) -> [Double] {
        var result: [Double] = []
        var value = configuration.offsetMinimumSeconds
        while value <= configuration.offsetMaximumSeconds + configuration.offsetStepSeconds * 0.5 {
            result.append(value)
            value += configuration.offsetStepSeconds
        }
        return result
    }

    private static func offsetEvidence(
        offset: Double,
        sdr: [FrameSample],
        hdr: [FrameSample],
        sdrFeatures: [Int: Features],
        hdrFeatures: [Int: Features],
        metricCache: inout [UInt64: Metrics]
    ) -> OffsetEvidence {
        var pairs: [(FrameSample, FrameSample)] = []
        var metrics: [Metrics] = []
        for sample in sdr {
            let target = sample.descriptor.timestampSeconds + offset
            guard let nearest = hdr.min(by: {
                abs($0.descriptor.timestampSeconds - target) < abs($1.descriptor.timestampSeconds - target)
            }) else { continue }
            pairs.append((sample, nearest))
            let key = UInt64(UInt32(truncatingIfNeeded: sample.sequencePosition)) << 32 |
                UInt64(UInt32(truncatingIfNeeded: nearest.sequencePosition))
            if let cached = metricCache[key] {
                metrics.append(cached)
            } else {
                guard let left = sdrFeatures[sample.sequencePosition],
                      let right = hdrFeatures[nearest.sequencePosition] else { continue }
                let measured = compare(left, right)
                metricCache[key] = measured
                metrics.append(measured)
            }
        }
        return OffsetEvidence(offset: offset, metrics: metrics, pairs: pairs)
    }

    private static func windowEvidence(
        sdr: [FrameSample],
        hdr: [FrameSample],
        configuration: V6MatcherEvidenceConfiguration,
        sdrFeatures: [Int: Features],
        hdrFeatures: [Int: Features],
        metricCache: inout [UInt64: Metrics]
    ) -> [V6MatcherWindowEvidence] {
        guard !sdr.isEmpty else { return [] }
        let size = max(1, Int(ceil(Double(sdr.count) / Double(max(configuration.windowCount, 1)))))
        var result: [V6MatcherWindowEvidence] = []
        for (windowIndex, start) in stride(from: 0, to: sdr.count, by: size).enumerated() {
            let end = min(start + size, sdr.count)
            let samples = Array(sdr[start..<end])
            var candidates: [OffsetEvidence] = []
            for offset in offsetCandidates(configuration) {
                candidates.append(offsetEvidence(
                    offset: offset, sdr: samples, hdr: hdr,
                    sdrFeatures: sdrFeatures, hdrFeatures: hdrFeatures,
                    metricCache: &metricCache
                ))
            }
            let best = candidates.max(by: { $0.score < $1.score })!
            result.append(V6MatcherWindowEvidence(
                windowIndex: windowIndex,
                startSequencePosition: samples.first?.sequencePosition ?? start,
                endSequencePosition: samples.last?.sequencePosition ?? end - 1,
                bestOffsetSeconds: best.offset,
                robustScore: best.score
            ))
        }
        return result
    }

    private static func features(_ luma: [Float]) -> Features {
        V6TransferInvariantMatcher.features(luma, configuration: .v6)
    }

    private static func compare(_ lhs: Features, _ rhs: Features) -> Metrics {
        let measured = V6TransferInvariantMatcher.compare(lhs, rhs, configuration: .v6)
        return Metrics(
            edge: measured.edgeCorrelation,
            luma: measured.normalizedLumaCorrelation,
            rank: measured.rankNormalizedLumaCorrelation,
            gradient: measured.gradientCorrelation,
            localContrast: measured.localContrastCorrelation,
            multiScale: measured.multiScaleNCC
        )
    }

    private static func aggregateMetrics(_ metrics: [Metrics]) -> Metrics {
        guard !metrics.isEmpty else {
            return Metrics(edge: 0, luma: 0, rank: 0, gradient: 0, localContrast: 0, multiScale: 0)
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return Metrics(
            edge: median(metrics.map(\.edge)), luma: median(metrics.map(\.luma)),
            rank: median(metrics.map(\.rank)), gradient: median(metrics.map(\.gradient)),
            localContrast: median(metrics.map(\.localContrast)),
            multiScale: median(metrics.map(\.multiScale))
        )
    }

    private static func correlation(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.count > 1 else { return 0 }
        let leftMean = Double(lhs.reduce(0, +)) / Double(lhs.count)
        let rightMean = Double(rhs.reduce(0, +)) / Double(rhs.count)
        var numerator = 0.0
        var leftVariance = 0.0
        var rightVariance = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index]) - leftMean
            let right = Double(rhs[index]) - rightMean
            numerator += left * right
            leftVariance += left * left
            rightVariance += right * right
        }
        let denominator = sqrt(leftVariance * rightVariance)
        return denominator > 1e-12 ? max(-1, min(1, numerator / denominator)) : 0
    }

    private static func ranks(_ values: [Float]) -> [Float] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var result = Array(repeating: Float(0), count: values.count)
        for (rank, index) in order.enumerated() { result[index] = Float(rank) / Float(max(values.count - 1, 1)) }
        return result
    }

    private static func gradients(_ values: [Float], width: Int, height: Int) -> [Float] {
        guard values.count == width * height else { return [] }
        var result: [Float] = []
        result.reserveCapacity((width - 1) * (height - 1) * 2)
        for row in 0..<(height - 1) {
            for column in 0..<(width - 1) {
                let index = row * width + column
                result.append(values[index + 1] - values[index])
                result.append(values[index + width] - values[index])
            }
        }
        return result
    }

    private static func medianAbsolute(_ values: [Float]) -> Float {
        let sorted = values.map { abs($0) }.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private static func localContrast(_ values: [Float], width: Int, height: Int) -> [Float] {
        guard values.count == width * height else { return [] }
        var result = Array(repeating: Float(0), count: values.count)
        for row in 0..<height {
            for column in 0..<width {
                var total: Float = 0
                var count: Float = 0
                for y in max(0, row - 1)...min(height - 1, row + 1) {
                    for x in max(0, column - 1)...min(width - 1, column + 1) {
                        total += values[y * width + x]
                        count += 1
                    }
                }
                let index = row * width + column
                result[index] = values[index] - total / max(count, 1)
            }
        }
        return result
    }

    private static func temporalChangeCorrelation(_ pairs: [(FrameSample, FrameSample)]) -> Double {
        guard pairs.count > 2 else { return 0 }
        var sdr: [Float] = []
        var hdr: [Float] = []
        for index in 1..<pairs.count {
            sdr.append(Float(FrameDescriptorBuilder.distance(pairs[index - 1].0.descriptor, pairs[index].0.descriptor)))
            hdr.append(Float(FrameDescriptorBuilder.distance(pairs[index - 1].1.descriptor, pairs[index].1.descriptor)))
        }
        return correlation(sdr, hdr)
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
