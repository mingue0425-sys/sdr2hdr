@preconcurrency import AVFoundation
import CryptoKit
import Foundation

public enum V4MetadataProbe {
    public static func probe(url: URL) async throws -> V4StreamMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CalibrationError.metadataUnavailable("file does not exist: \(url.path)")
        }
        if let ffprobe = findExecutable(named: "ffprobe"),
           let root = runJSON(executable: ffprobe, arguments: [
               "-v", "error", "-show_streams", "-show_format", "-of", "json", url.path
           ]) {
            return parseFFProbe(root, url: url)
        }

        let metadata = try await MetadataProbe.probe(url: url)
        return V4StreamMetadata(
            path: url.path,
            durationSeconds: metadata.durationSeconds,
            frameRate: metadata.frameRate,
            timeBase: nil,
            codec: metadata.codec,
            width: metadata.width,
            height: metadata.height,
            pixelFormat: metadata.pixelFormat,
            bitDepth: metadata.color.bitDepth,
            colorRange: metadata.color.range,
            colorPrimaries: metadata.color.primaries,
            transfer: metadata.color.transfer,
            matrix: metadata.color.matrix,
            masteringMetadataPresent: metadata.color.masteringPeakNits != nil,
            maxCLL: metadata.color.maxCLL,
            maxFALL: metadata.color.maxFALL,
            audioTrackCount: metadata.audioTrackCount,
            probeTool: "AVFoundation"
        )
    }

    private static func parseFFProbe(_ root: [String: Any], url: URL) -> V4StreamMetadata {
        let streams = root["streams"] as? [[String: Any]] ?? []
        let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }) ?? [:]
        let audioCount = streams.filter { ($0["codec_type"] as? String) == "audio" }.count
        let format = root["format"] as? [String: Any] ?? [:]

        func string(_ key: String) -> String? {
            if let value = video[key] as? String { return value }
            if let value = video[key] as? NSNumber { return value.stringValue }
            return nil
        }
        func double(_ key: String) -> Double? {
            if let value = video[key] as? NSNumber { return value.doubleValue }
            if let value = video[key] as? String { return Double(value) }
            return nil
        }
        func rational(_ value: String?) -> Double {
            guard let value, let slash = value.firstIndex(of: "/") else { return Double(value ?? "") ?? 0 }
            let numerator = Double(value[..<slash]) ?? 0
            let denominator = Double(value[value.index(after: slash)...]) ?? 0
            return denominator > 0 ? numerator / denominator : 0
        }

        let pixelFormat = string("pix_fmt")
        let bitDepth = intValue(video["bits_per_raw_sample"])
            ?? intValue(video["bits_per_coded_sample"])
            ?? inferredBitDepth(from: pixelFormat)
        let sideData = video["side_data_list"] as? [[String: Any]] ?? []
        let metadataValues = sideData.reduce(into: [String: String]()) { result, entry in
            for (key, value) in entry {
                if let scalar = value as? String { result[key] = scalar }
                else if let scalar = value as? NSNumber { result[key] = scalar.stringValue }
            }
        }
        let maxCLL = firstFloat(in: metadataValues, keys: ["max_content", "max_cll", "maxCLL"])
        let maxFALL = firstFloat(in: metadataValues, keys: ["max_average", "max_fall", "maxFALL"])
        let duration = double("duration") ?? numberAsDouble(format["duration"]) ?? 0

        return V4StreamMetadata(
            path: url.path,
            durationSeconds: duration,
            frameRate: rational(string("avg_frame_rate") ?? string("r_frame_rate")),
            timeBase: string("time_base"),
            codec: string("codec_name"),
            width: intValue(video["width"]) ?? 0,
            height: intValue(video["height"]) ?? 0,
            pixelFormat: pixelFormat,
            bitDepth: bitDepth,
            colorRange: string("color_range"),
            colorPrimaries: string("color_primaries"),
            transfer: string("color_transfer"),
            matrix: string("color_space"),
            masteringMetadataPresent: sideData.contains { !$0.isEmpty },
            maxCLL: maxCLL,
            maxFALL: maxFALL,
            audioTrackCount: audioCount,
            probeTool: "ffprobe"
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func numberAsDouble(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func inferredBitDepth(from pixelFormat: String?) -> Int? {
        guard let pixelFormat else { return nil }
        if pixelFormat.contains("12") { return 12 }
        if pixelFormat.contains("10") { return 10 }
        if pixelFormat.contains("14") { return 14 }
        if pixelFormat.contains("16") { return 16 }
        if pixelFormat.contains("8") || pixelFormat.contains("yuv420p") { return 8 }
        return nil
    }

    private static func firstFloat(in values: [String: String], keys: [String]) -> Float? {
        for key in keys where values[key] != nil {
            if let number = Float(values[key] ?? ""), number.isFinite { return number }
        }
        return nil
    }

    private static func findExecutable(named name: String) -> String? {
        [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private static func runJSON(executable: String, arguments: [String]) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        // ffprobe is expected to be quiet, but an invalid or partially
        // downloaded asset can still emit enough diagnostics to block an
        // undrained stderr pipe.  Metadata probing must fail fast instead of
        // hanging the dataset audit.
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}

public enum V4DatasetIntegrity {
    public static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        var digest = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func digest(url: URL) throws -> V4FileDigest {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let repositoryRoot = try? V4SourceHasher.repositoryRoot(for: url)
        return V4FileDigest(
            path: repositoryRoot.map { url.portableRepositoryPath(relativeTo: $0) } ?? url.standardizedFileURL.path,
            sizeBytes: Int64(values.fileSize ?? 0),
            sha256: try sha256(url: url)
        )
    }

    public static func manifestSHA256(url: URL) throws -> String {
        try sha256(url: url)
    }

    /// Different paths do not establish independent content.  Keep identical
    /// media out of the dataset so transcodes cannot inflate split/category
    /// counts or create leakage between video-level groups.
    public static func duplicatePathGroups(_ files: [V4FileDigest]) -> [[String]] {
        Dictionary(grouping: files, by: \.sha256)
            .values
            .filter { $0.count > 1 }
            .map { $0.map(\.path).sorted() }
            .sorted { ($0.first ?? "") < ($1.first ?? "") }
    }
}

private extension URL {
    func portableRepositoryPath(relativeTo repositoryRoot: URL) -> String {
        V4EvidencePath.portable(self, repositoryRoot: repositoryRoot)
    }
}

/// V4 alignment must tolerate the intentionally different SDR/PQ grade of a
/// pair. The historical aligner is retained for V1/V2/V3 reproducibility; this
/// audit-only aligner uses spatial correlation and histogram CDF distance rather
/// than comparing encoded histogram bins directly.
public enum V4AuditTemporalAligner {
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
                    distances.append(distance(sample, nearest))
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
            let confidence = max(0, min(1, exp(-distance(sample, nearest) * 4)))
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
        let values = matches.map(\.confidence).sorted()
        let median = values.isEmpty ? 0 : values[values.count / 2]
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
            notes: ["V4 grade-robust alignment: spatial Pearson correlation + histogram CDF + normalized edge statistics"]
        )
    }

    private static func nearestSample(to timestamp: Double, in samples: [FrameSample]) -> FrameSample? {
        samples.min {
            abs($0.descriptor.timestampSeconds - timestamp) < abs($1.descriptor.timestampSeconds - timestamp)
        }
    }

    private static func distance(_ lhs: FrameSample, _ rhs: FrameSample) -> Double {
        let spatial = spatialDistance(lhs.lumaGrid, rhs.lumaGrid)
        let cdf = histogramCDFDistance(lhs.descriptor.histogram, rhs.descriptor.histogram)
        let mean = boundedLogDistance(lhs.descriptor.meanLuma, rhs.descriptor.meanLuma)
        let edge = boundedLogDistance(lhs.descriptor.edgeEnergy, rhs.descriptor.edgeEnergy)
        return spatial * 0.72 + cdf * 0.18 + mean * 0.04 + edge * 0.06
    }

    private static func histogramCDFDistance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 1 }
        var left = Float(0)
        var right = Float(0)
        var total = 0.0
        for index in lhs.indices {
            left += lhs[index]
            right += rhs[index]
            total += abs(Double(left - right))
        }
        return min(1, total / Double(lhs.count))
    }

    private static func spatialDistance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, lhs.count > 1 else { return 0.5 }
        let leftMean = lhs.reduce(0, +) / Float(lhs.count)
        let rightMean = rhs.reduce(0, +) / Float(rhs.count)
        var numerator = 0.0
        var leftVariance = 0.0
        var rightVariance = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index] - leftMean)
            let right = Double(rhs[index] - rightMean)
            numerator += left * right
            leftVariance += left * left
            rightVariance += right * right
        }
        let denominator = sqrt(leftVariance * rightVariance)
        guard denominator > 1e-9 else { return 0.5 }
        let correlation = max(-1, min(1, numerator / denominator))
        return (1 - correlation) * 0.5
    }

    private static func boundedLogDistance(_ lhs: Float, _ rhs: Float) -> Double {
        let left = max(Double(lhs), 1e-4)
        let right = max(Double(rhs), 1e-4)
        return min(abs(log(left / right)), 1)
    }
}

public enum V4DatasetAuditor {
    /// Version and digest of the audit policy are part of the immutable
    /// evidence contract. A change to metadata, decode, alignment,
    /// eligibility, or diversity policy requires a fresh audit artifact.
    public static let auditEvidenceVersion = "dataset-v4-audit-v2"

    private static let auditConfigurationMaterial = """
    metadata:explicit-bt709-sdr-with-documented-fallback-v3
    hdr:explicit-pq-or-hlg-v2
    decode:first-middle-last-v2
    alignment:temporal-spatial-v4
    eligibility:main-calibration-only-v2
    diversity:eligible-records-only-v2
    """

    public static let auditConfigurationHash: String = {
        SHA256.hash(data: Data(auditConfigurationMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }()

    /// Readiness aggregation intentionally accepts the audit records as an
    /// explicit input so tests and import tooling can prove that rejected or
    /// conditional records never contribute to diversity gates.
    public static func diversityReport(manifest: V4Manifest, audits: [V4PairAudit]) -> V4DiversityReport {
        makeDiversityReport(manifest: manifest, audits: audits)
    }

    public static func audit(manifestURL: URL) async throws -> V4DatasetAuditReport {
        let manifest = try V4Manifest.load(from: manifestURL)
        let manifestHash = try V4DatasetIntegrity.manifestSHA256(url: manifestURL)
        let repositoryRoot = try V4SourceHasher.repositoryRoot(for: manifestURL)
        let guardrail = V4FrozenAccessGuard()
        var audits: [V4PairAudit] = []
        var digests: [V4FileDigest] = []
        audits.reserveCapacity(manifest.pairs.count)

        for pair in manifest.pairs {
            try guardrail.authorize(pair: pair, phase: .metadata)
            let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
            let base = V4PairAudit(
                id: pair.id,
                source: pair.source,
                split: pair.split,
                virginFrozen: pair.virginFrozen,
                expectedRelation: pair.expectedRelation,
                suitability: .reject,
                status: .missingFile,
                sdrPath: urls.sdr.portableRepositoryPath(relativeTo: repositoryRoot),
                hdrPath: urls.hdr.portableRepositoryPath(relativeTo: repositoryRoot),
                notes: ["objective evaluation is forbidden in dataset-audit"]
            )
            guard FileManager.default.fileExists(atPath: urls.sdr.path),
                  FileManager.default.fileExists(atPath: urls.hdr.path) else {
                audits.append(base)
                continue
            }

            var audit = base
            do {
                let sdrDigest = try V4DatasetIntegrity.digest(url: urls.sdr)
                let hdrDigest = try V4DatasetIntegrity.digest(url: urls.hdr)
                audit.sdrDigest = sdrDigest
                audit.hdrDigest = hdrDigest
                digests.append(contentsOf: [sdrDigest, hdrDigest])

                var sdr = try await V4MetadataProbe.probe(url: urls.sdr)
                var hdr = try await V4MetadataProbe.probe(url: urls.hdr)
                sdr.path = urls.sdr.portableRepositoryPath(relativeTo: repositoryRoot)
                hdr.path = urls.hdr.portableRepositoryPath(relativeTo: repositoryRoot)
                var notes: [String] = audit.notes
                // SDR eligibility is strict for unannotated media. A pair may
                // use a fallback only when the manifest carries both BT.709
                // and a supported SDR transfer from the source documentation;
                // the audit records that provenance in notes. The model-level
                // `isExplicitBT709SDR` check still rejects an unannotated nil.
                applyDocumentedSDRFallback(&sdr, pair: pair, notes: &notes)
                if let hdrTransfer = pair.referenceTransfer, hdr.transfer == nil {
                    hdr.transfer = hdrTransfer
                    notes.append("HDR transfer supplied by manifest because container omitted it")
                }
                if let hdrPrimaries = pair.referencePrimaries, hdr.colorPrimaries == nil {
                    hdr.colorPrimaries = hdrPrimaries
                    notes.append("HDR primaries supplied by manifest because container omitted them")
                }
                audit.sdrMetadata = sdr
                audit.hdrMetadata = hdr
                audit.sdrTransferFamily = sdr.transferFamily
                audit.hdrTransferFamily = hdr.transferFamily
                audit.sdrReferenceValid = sdr.isSDRReference
                audit.hdrReferenceValid = hdr.isHDRReference

                let metadataIssues = metadataIssues(sdr: sdr, hdr: hdr)
                if metadataIssues.contains(where: { $0.hasPrefix("INVALID_HDR_REFERENCE") }) {
                    audit.status = .invalidHDRReference
                    audit.notes = notes + metadataIssues
                    audits.append(audit)
                    continue
                }
                if metadataIssues.contains(where: { $0.hasPrefix("INVALID") }) {
                    audit.status = .invalidMetadata
                    audit.notes = notes + metadataIssues
                    audits.append(audit)
                    continue
                }
                audit.notes = notes + metadataIssues

                let sdrSmoke = try await decodeSmoke(url: urls.sdr, pixelFormat: CalibrationPixelFormat.sdrNV12, metadata: sdr)
                let hdrSmoke = try await decodeSmoke(url: urls.hdr, pixelFormat: CalibrationPixelFormat.hdrP010, metadata: hdr)
                audit.sdrDecode = sdrSmoke
                audit.hdrDecode = hdrSmoke
                guard sdrSmoke.passed, hdrSmoke.passed else {
                    audit.status = .decodeFailed
                    audit.suitability = .reject
                    audit.notes.append("first/middle/last decode smoke did not pass")
                    audits.append(audit)
                    continue
                }

                let sampledSDR = try await sampleSequence(url: urls.sdr, pixelFormat: CalibrationPixelFormat.sdrNV12, metadata: sdr)
                let sampledHDR = try await sampleSequence(url: urls.hdr, pixelFormat: CalibrationPixelFormat.hdrP010, metadata: hdr)
                let alignment = makeAlignmentSummary(sdr: sampledSDR, hdr: sampledHDR, sdrMetadata: sdr, hdrMetadata: hdr)
                audit.alignment = alignment

                let durationDelta = abs(sdr.durationSeconds - hdr.durationSeconds)
                if durationDelta > 5 || alignment.status == "REJECT" {
                    audit.status = durationDelta > 5 ? .differentEdit : .alignmentUnreliable
                    audit.suitability = .reject
                    audits.append(audit)
                    continue
                }
                if pair.expectedRelation == .unknown || pair.expectedRelation == .relatedContent {
                    audit.status = .uncertainRelation
                    audit.suitability = .diagnosticOnly
                    audit.notes.append("relation is not strong enough for main calibration")
                    audits.append(audit)
                    continue
                }
                if alignment.medianConfidence < 0.60 {
                    audit.status = .alignmentUnreliable
                    audit.suitability = .reject
                    audits.append(audit)
                    continue
                }
                if pair.expectedRelation == .sameContentDifferentGrade {
                    audit.status = .conditional
                    audit.suitability = .conditional
                    audit.notes.append("creative-grade mismatch is expected; do not treat as pixel ground truth")
                } else {
                    audit.status = .accepted
                    audit.suitability = alignment.medianConfidence >= 0.70 ? .mainCalibration : .conditional
                    if audit.suitability == .conditional {
                        audit.status = .conditional
                        audit.notes.append("alignment median is usable but below the preferred 0.70 production gate")
                    }
                }
                audits.append(audit)
            } catch {
                audit.status = .decodeFailed
                audit.suitability = .reject
                audit.notes.append(error.localizedDescription)
                audits.append(audit)
            }
        }

        let lock = V4DatasetLock(version: 1, manifestSHA256: manifestHash, files: digests.sorted { $0.path < $1.path })
        let lockURL = manifestURL.deletingLastPathComponent().appendingPathComponent("dataset-v4-lock.json")
        try writeJSON(lock, to: lockURL)
        let duplicateGroups = V4DatasetIntegrity.duplicatePathGroups(digests)
        for group in duplicateGroups {
            for index in audits.indices {
                let paths = [audits[index].sdrPath, audits[index].hdrPath]
                guard paths.contains(where: { group.contains($0) }) else { continue }
                audits[index].status = .duplicateMedia
                audits[index].suitability = .reject
                let peers = group.filter { !paths.contains($0) }
                audits[index].notes.append("DUPLICATE_MEDIA_CONTENT: same SHA-256 as \(peers.joined(separator: ", "))")
            }
        }
        let diversity = makeDiversityReport(manifest: manifest, audits: audits)
        let verdict = makeVerdict(audits: audits, diversity: diversity)
        return V4DatasetAuditReport(
            manifestPath: V4EvidencePath.portable(manifestURL, repositoryRoot: repositoryRoot),
            manifestSHA256: manifestHash,
            pairs: audits,
            diversity: diversity,
            notes: [
                "This command performs manifest, integrity, metadata, decode-smoke, spatial and temporal alignment checks only.",
                "No baseline, candidate, validation or frozen objective was evaluated.",
                "Virgin frozen media may be inspected for integrity/alignment but remains unavailable to calibration runners."
            ],
            verdict: verdict.verdict,
            gateReasons: verdict.reasons,
            auditConfigHash: auditConfigurationHash
        )
    }

    private static func applyDocumentedSDRFallback(
        _ metadata: inout V4StreamMetadata,
        pair: V4PairRecord,
        notes: inout [String]
    ) {
        guard metadata.transfer == nil || metadata.colorPrimaries == nil else { return }
        guard let transfer = pair.referenceTransfer?.lowercased(),
              let primaries = pair.referencePrimaries?.lowercased(),
              primaries.contains("709"),
              ["bt709", "bt.709", "bt1886", "bt.1886", "gamma22", "gamma28", "srgb", "iec61966-2-1"].contains(transfer) else {
            return
        }
        if metadata.transfer == nil { metadata.transfer = transfer }
        if metadata.colorPrimaries == nil { metadata.colorPrimaries = primaries }
        notes.append("SDR BT.709 transfer/primaries supplied by source-documented manifest fallback")
    }

    private static func makeVerdict(
        audits: [V4PairAudit],
        diversity: V4DiversityReport
    ) -> (verdict: V4DatasetVerdict, reasons: [String]) {
        let legacyIDs: Set<String> = [
            "video1_ive_blackhole",
            "video2_newjeans_new_jeans",
            "video3_newjeans_how_sweet",
            "video4_aespa_lemonade",
            "video6_le_sserafim_hot"
        ]
        let newMain = audits.filter { !legacyIDs.contains($0.id) && $0.suitability == .mainCalibration }.count
        var reasons: [String] = []
        if diversity.mainCalibrationPairs < 8 {
            reasons.append("main calibration pairs \(diversity.mainCalibrationPairs) < required minimum 8")
        }
        if diversity.contentFamilies.count < 3 {
            reasons.append("content families \(diversity.contentFamilies.count) < target minimum 3")
        }
        if diversity.virginFrozenPairs < 2 {
            reasons.append("virgin frozen pairs \(diversity.virginFrozenPairs) < target minimum 2")
        }
        if diversity.hdrTransfers.count < 2 {
            reasons.append("HDR transfer families are not both represented")
        }
        if newMain == 0 {
            return (.noValidNewPairs, reasons + ["no newly added pair passed the main calibration gate"])
        }
        if diversity.mainCalibrationPairs >= 8,
           diversity.contentFamilies.count >= 3,
           diversity.virginFrozenPairs >= 2,
           diversity.hdrTransfers.count >= 2 {
            return (.ready, reasons)
        }
        return (.partial, reasons)
    }

    private static func metadataIssues(sdr: V4StreamMetadata, hdr: V4StreamMetadata) -> [String] {
        var issues: [String] = []
        guard sdr.durationSeconds.isFinite, sdr.durationSeconds > 0,
              hdr.durationSeconds.isFinite, hdr.durationSeconds > 0 else {
            issues.append("INVALID duration is missing or non-finite")
            return issues
        }
        guard sdr.width > 0, sdr.height > 0, hdr.width > 0, hdr.height > 0 else {
            issues.append("INVALID resolution is missing")
            return issues
        }
        guard hdr.isHDRReference else {
            issues.append("INVALID_HDR_REFERENCE transfer=\(hdr.transfer ?? "missing"), primaries=\(hdr.colorPrimaries ?? "missing")")
            return issues
        }
        if !sdr.isExplicitBT709SDR {
            issues.append(
                "INVALID_SDR_REFERENCE_METADATA primaries=\(sdr.colorPrimaries ?? "missing"), " +
                "transfer=\(sdr.transfer ?? "missing"), matrix=\(sdr.matrix ?? "missing"), " +
                "range=\(sdr.colorRange ?? "missing")"
            )
        }
        if let bitDepth = hdr.bitDepth, bitDepth < 10 {
            issues.append("HDR_BIT_DEPTH_WARNING=\(bitDepth)")
        }
        let durationDelta = abs(sdr.durationSeconds - hdr.durationSeconds)
        if durationDelta > 0.5 {
            issues.append(String(format: "duration delta %.3fs requires PTS alignment", durationDelta))
        }
        return issues
    }

    private static func decodeSmoke(
        url: URL,
        pixelFormat: OSType,
        metadata: V4StreamMetadata
    ) async throws -> V4DecodeSmoke {
        let centers = [0.0, 0.5, 0.98]
        var smoke = V4DecodeSmoke(attempted: true)
        var total = 0
        for (index, fraction) in centers.enumerated() {
            let sequence = try await FrameReader.readWindow(
                url: url,
                pixelFormat: pixelFormat,
                startSeconds: max(0, min(max(0, metadata.durationSeconds - 0.05), metadata.durationSeconds * fraction)),
                frameCount: 2,
                framesPerSecond: max(metadata.frameRate, 1),
                proxyWidth: 160
            )
            let decoded = !sequence.samples.isEmpty
            total += sequence.samples.count
            if index == 0 { smoke.firstFrame = decoded }
            if index == 1 { smoke.middleFrame = decoded }
            if index == 2 { smoke.lastFrame = decoded }
        }
        smoke.decodedSampleCount = total
        return smoke
    }

    private static func sampleSequence(
        url: URL,
        pixelFormat: OSType,
        metadata: V4StreamMetadata
    ) async throws -> FrameSequence {
        let fps = max(metadata.frameRate, 1)
        let centers = [0.0, 0.25, 0.50, 0.75, 0.98]
        let windowFrames = 8
        let windowSeconds = Double(windowFrames - 1) / fps
        var samples: [FrameSample] = []
        for fraction in centers {
            let center = metadata.durationSeconds * fraction
            let latestStart = max(0, metadata.durationSeconds - max(windowSeconds, 0.05))
            let start = max(0, min(latestStart, center - windowSeconds * 0.5))
            let sequence = try await FrameReader.readWindow(
                url: url,
                pixelFormat: pixelFormat,
                startSeconds: start,
                frameCount: windowFrames,
                framesPerSecond: min(max(fps, 1), 60),
                proxyWidth: 160
            )
            samples.append(contentsOf: sequence.samples)
        }
        let indexed = samples.enumerated().map { index, sample in
            FrameSample(
                index: sample.index,
                sequencePosition: index,
                timestamp: sample.timestamp,
                pixelBuffer: sample.pixelBuffer,
                descriptor: sample.descriptor,
                lumaGrid: sample.lumaGrid
            )
        }
        return FrameSequence(
            url: url,
            pixelFormat: pixelFormat,
            width: indexed.first.map { CVPixelBufferGetWidth($0.pixelBuffer) } ?? 160,
            height: indexed.first.map { CVPixelBufferGetHeight($0.pixelBuffer) } ?? 90,
            nominalFrameRate: metadata.frameRate,
            durationSeconds: metadata.durationSeconds,
            samples: indexed
        )
    }

    private static func makeAlignmentSummary(
        sdr: FrameSequence,
        hdr: FrameSequence,
        sdrMetadata: V4StreamMetadata,
        hdrMetadata: V4StreamMetadata
    ) -> V4AlignmentSummary {
        let result = V4AuditTemporalAligner.align(sdr: sdr, hdr: hdr, confidenceThreshold: 0.60)
        let confidenceValues = result.matches.map(\.confidence).filter(\.isFinite).sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !confidenceValues.isEmpty else { return 0 }
            let index = min(confidenceValues.count - 1, max(0, Int(Double(confidenceValues.count - 1) * fraction)))
            return confidenceValues[index]
        }
        let matched = confidenceValues.count
        let sampled = sdr.samples.count
        let mean = matched > 0 ? confidenceValues.reduce(0, +) / Double(matched) : 0
        let offsets = result.matches.map { $0.hdrTimeSeconds - $0.sdrTimeSeconds }.filter(\.isFinite)
        let meanOffset = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count)
        let variance = offsets.isEmpty
            ? 0
            : offsets.reduce(0) { $0 + ($1 - meanOffset) * ($1 - meanOffset) } / Double(offsets.count)
        let atLeast: (Double) -> Double = { threshold in
            guard sampled > 0 else { return 0 }
            return Double(confidenceValues.filter { $0 >= threshold }.count) / Double(sampled)
        }
        let aspectSDR = Double(sdrMetadata.width) / Double(max(sdrMetadata.height, 1))
        let aspectHDR = Double(hdrMetadata.width) / Double(max(hdrMetadata.height, 1))
        let aspectDelta = abs(aspectSDR - aspectHDR) / max(aspectSDR, aspectHDR)
        let spatial = aspectDelta < 0.02 ? ["same_aspect_uniform_scale"] : aspectDelta < 0.12 ? ["recoverable_crop_or_letterbox"] : ["large_geometry_difference"]
        let status = V4AlignmentPolicy.status(
            sampledFrames: sampled,
            matchedFrames: matched,
            medianConfidence: percentile(0.50),
            p10Confidence: percentile(0.10)
        )
        return V4AlignmentSummary(
            sampledFrames: sampled,
            matchedFrames: matched,
            rejectedFrames: max(result.rejectedFrames, sampled - matched),
            matchRatio: sampled > 0 ? Double(matched) / Double(sampled) : 0,
            meanConfidence: mean,
            medianConfidence: percentile(0.50),
            p10Confidence: percentile(0.10),
            p50Confidence: percentile(0.50),
            p90Confidence: percentile(0.90),
            confidenceAtLeast60: atLeast(0.60),
            confidenceAtLeast70: atLeast(0.70),
            confidenceAtLeast80: atLeast(0.80),
            estimatedTimeOffsetSeconds: result.coarseOffsetSeconds,
            offsetVariance: variance,
            spatialChecks: spatial,
            status: status
        )
    }

    private static func makeDiversityReport(manifest: V4Manifest, audits: [V4PairAudit]) -> V4DiversityReport {
        var report = V4DiversityReport(totalPairs: manifest.pairs.count)
        for audit in audits {
            let eligible = audit.suitability == .mainCalibration && audit.status == .accepted
            switch audit.suitability {
            case .mainCalibration:
                if eligible {
                    report.mainCalibrationPairs += 1
                    report.acceptedPairs += 1
                } else {
                    report.rejectedPairs += 1
                }
            case .conditional: report.conditionalPairs += 1
            case .diagnosticOnly: report.conditionalPairs += 1
            case .reject: report.rejectedPairs += 1
            }
            if eligible {
                switch audit.split {
                case .tune: report.tunePairs += 1
                case .validation: report.validationPairs += 1
                case .frozen: report.frozenPairs += 1
                }
            }
            if eligible, audit.virginFrozen { report.virginFrozenPairs += 1 }
            if eligible, let metadata = audit.hdrMetadata {
                report.hdrTransfers[metadata.transferFamily, default: 0] += 1
                report.resolutions["\(metadata.width)x\(metadata.height)", default: 0] += 1
                let fps = String(format: "%.3f", metadata.frameRate)
                report.frameRates[fps, default: 0] += 1
            }
            if eligible, let pair = manifest.pairs.first(where: { $0.id == audit.id }) {
                report.contentFamilies[pair.contentFamily ?? "UNSPECIFIED", default: 0] += 1
                for category in pair.contentCategory { report.categories[category, default: 0] += 1 }
            }
        }
        return report
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url)
    }
}

public enum V4ReportWriter {
    public static func write(_ report: V4DatasetAuditReport, to output: URL) throws {
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output)

        let metadataURL = directory.appendingPathComponent("dataset-v4-metadata.json")
        let alignmentURL = directory.appendingPathComponent("dataset-v4-alignment.json")
        let diversityURL = directory.appendingPathComponent("dataset-v4-diversity.json")
        try encoder.encode(report.pairs.map {
            V4MetadataArtifact(
                id: $0.id,
                sdr: $0.sdrMetadata,
                hdr: $0.hdrMetadata,
                sdrTransferFamily: $0.sdrTransferFamily,
                hdrTransferFamily: $0.hdrTransferFamily,
                sdrReferenceValid: $0.sdrReferenceValid,
                hdrReferenceValid: $0.hdrReferenceValid
            )
        }).write(to: metadataURL)
        try encoder.encode(report.pairs.map {
            V4AlignmentArtifact(
                id: $0.id,
                split: $0.split,
                virginFrozen: $0.virginFrozen,
                alignment: $0.alignment
            )
        }).write(to: alignmentURL)
        try encoder.encode(report.diversity).write(to: diversityURL)
        try writeMarkdown(report, to: directory.appendingPathComponent("dataset-v4-report.md"))
    }

    private static func writeMarkdown(_ report: V4DatasetAuditReport, to url: URL) throws {
        var lines: [String] = []
        lines.append("# Dataset V4 audit")
        lines.append("")
        lines.append("- Manifest: `\(report.manifestPath)`")
       lines.append("- Manifest SHA-256: `\(report.manifestSHA256)`")
       lines.append("- Audit evidence version: `\(report.version)`")
        let auditConfigHash = report.auditConfigHash ?? "MISSING"
        lines.append("- Audit configuration SHA-256: `\(auditConfigHash)`")
        lines.append("- Objective evaluation: `\(report.objectiveEvaluated ? "YES" : "NO")`")
        lines.append("- Frozen objective IDs: `\(report.frozenObjectiveEvaluated.isEmpty ? "NONE" : report.frozenObjectiveEvaluated.joined(separator: ", "))`")
        lines.append("- Structural dataset verdict: `\(report.verdict.rawValue)`")
        lines.append("- Readiness scope: `DATASET_INTEGRITY_ONLY`; Pre-V5 holdout readiness is evaluated separately by `correctness-review`.")
        for reason in report.gateReasons { lines.append("- Gate: \(reason)") }
        lines.append("")
        lines.append("## Pair summary")
        lines.append("")
        lines.append("| ID | Split | Virgin frozen | HDR transfer | Status | Suitability | Median confidence | ≥0.70 | Notes |")
        lines.append("|---|---|---:|---|---|---|---:|---:|---|")
        for pair in report.pairs {
            let transfer = pair.hdrMetadata?.transferFamily ?? "UNKNOWN"
            let notes = pair.notes.joined(separator: "; ").replacingOccurrences(of: "|", with: "/")
            lines.append("| \(pair.id) | \(pair.split.rawValue) | \(pair.virginFrozen ? "YES" : "NO") | \(transfer) | \(pair.status.rawValue) | \(pair.suitability.rawValue) | \(String(format: "%.3f", pair.alignment.medianConfidence)) | \(String(format: "%.1f%%", pair.alignment.confidenceAtLeast70 * 100)) | \(notes) |")
        }
        lines.append("")
        lines.append("## Diversity")
        lines.append("")
        lines.append("- Total: \(report.diversity.totalPairs); main: \(report.diversity.mainCalibrationPairs); conditional: \(report.diversity.conditionalPairs); rejected: \(report.diversity.rejectedPairs)")
        lines.append("- Splits: tune=\(report.diversity.tunePairs), validation=\(report.diversity.validationPairs), frozen=\(report.diversity.frozenPairs), virgin frozen=\(report.diversity.virginFrozenPairs)")
        lines.append("- HDR transfers: \(report.diversity.hdrTransfers)")
        lines.append("- Content families: \(report.diversity.contentFamilies)")
        lines.append("- Categories: \(report.diversity.categories)")
        lines.append("")
        lines.append("## Guardrails")
        lines.append("")
        for note in report.notes { lines.append("- \(note)") }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct V4MetadataArtifact: Codable {
    var id: String
    var sdr: V4StreamMetadata?
    var hdr: V4StreamMetadata?
    var sdrTransferFamily: String?
    var hdrTransferFamily: String?
    var sdrReferenceValid: Bool?
    var hdrReferenceValid: Bool?
}

private struct V4AlignmentArtifact: Codable {
    var id: String
    var split: DatasetSplit
    var virginFrozen: Bool
    var alignment: V4AlignmentSummary
}
