import CoreMedia
import CoreVideo
import HDRCalibration
import HDRCore
import Metal
import XCTest

final class CalibrationTests: XCTestCase {
    func testMetricVectorPercentilesAreFiniteAndOrdered() {
        let vector = MetricVector(values: [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(vector.p50, 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(vector.p50, vector.p75)
        XCTAssertLessThanOrEqual(vector.p75, vector.p99)
        XCTAssertTrue(vector.robustMax.isFinite)
    }

    func testPQAbsoluteLuminanceKnownValues() {
        XCTAssertEqual(HDRColorMath.pqDecodeNits(signal: HDRColorMath.pqEncode(nits: 100)), 100, accuracy: 0.2)
        XCTAssertEqual(HDRColorMath.pqDecodeNits(signal: HDRColorMath.pqEncode(nits: 1_000)), 1_000, accuracy: 1.0)
        XCTAssertEqual(HDRColorMath.pqDecodeNits(signal: 1), 10_000, accuracy: 1)
    }

    func testSyntheticCoarseAlignmentFindsKnownOffset() throws {
        let sdr = try makeSequence(times: [0, 1, 2], values: [0.1, 0.5, 0.9])
        let hdr = try makeSequence(times: [1, 2, 3], values: [0.1, 0.5, 0.9])
        let result = TemporalAligner.align(sdr: sdr, hdr: hdr, offsetRangeSeconds: -1...1, offsetStep: 1)
        XCTAssertEqual(result.coarseOffsetSeconds, 1, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(result.matches.count, 2)
    }

    func testSplitAssignmentDoesNotChangeDuringManifestRoundTrip() throws {
        let record = PairRecord(
            id: "pair",
            sdr: "sdr.mp4",
            hdr: "hdr.mp4",
            license: "user_owned",
            source: "local",
            split: .frozen
        )
        let data = try JSONEncoder().encode(PairManifest(pairs: [record]))
        let decoded = try JSONDecoder().decode(PairManifest.self, from: data)
        XCTAssertEqual(decoded.pairs.first?.split, .frozen)
    }

    func testActualLocalSDRFileIsNotAcceptedAsHDRReference() async throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("test.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("test.mp4 fixture unavailable")
        }
        let metadata = try await MetadataProbe.probe(url: url)
        XCTAssertNotEqual(metadata.color.referenceTransfer, .pq)
        let record = PairRecord(
            id: "invalid-local-sdr",
            sdr: "test.mp4",
            hdr: "test.mp4",
            license: "test_only",
            source: "local",
            split: .tune
        )
        let validation = MetadataProbe.validatePair(record: record, sdr: metadata, hdr: metadata)
        XCTAssertEqual(validation.status, .pairInvalidHDR)
    }

    func testFFmpegProxyNV12ReachesHDRCoreWithoutGPUFault() async throws {
        guard ProcessInfo.processInfo.environment["HDR_CALIBRATION_DATA_TESTS"] == "1" else {
            throw XCTSkip("set HDR_CALIBRATION_DATA_TESTS=1 for the large local fixture smoke")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = root.appendingPathComponent("data_video/manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("data_video fixture unavailable")
        }
        let manifest = try PairManifest.load(from: manifestURL)
        guard let pair = manifest.pairs.first else {
            throw XCTSkip("data_video manifest has no pairs")
        }
        let urls = pair.resolvedURLs(relativeTo: manifestURL)
        let sequence = try await FrameReader.read(
            url: urls.sdr,
            pixelFormat: CalibrationPixelFormat.sdrNV12,
            maxFrames: 16,
            proxyWidth: 320
        )
        guard sequence.samples.first != nil,
              let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal or decoded fixture unavailable")
        }
        var configuration = HDRConfiguration.hdr
        configuration.outputMode = .edr
        configuration.masteringHeadroom = configuration.peakNits / configuration.paperWhiteNits
        let evaluator = try HDRCoreOfflineEvaluator(device: device, configuration: configuration)
        for sample in sequence.samples.prefix(16) {
            _ = try evaluator.evaluate(
                pixelBuffer: sample.pixelBuffer,
                timestampSeconds: sample.timestamp.seconds,
                configuration: configuration
            )
        }
    }

    func testFFmpegHLGP010ReferenceDecodeIsFinite() async throws {
        guard ProcessInfo.processInfo.environment["HDR_CALIBRATION_DATA_TESTS"] == "1" else {
            throw XCTSkip("set HDR_CALIBRATION_DATA_TESTS=1 for the large local fixture smoke")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = root.appendingPathComponent("data_video/manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("data_video fixture unavailable")
        }
        let manifest = try PairManifest.load(from: manifestURL)
        guard let pair = manifest.pairs.first else {
            throw XCTSkip("data_video manifest has no pairs")
        }
        let urls = pair.resolvedURLs(relativeTo: manifestURL)
        let sequence = try await FrameReader.read(
            url: urls.hdr,
            pixelFormat: CalibrationPixelFormat.hdrP010,
            maxFrames: 8,
            proxyWidth: 320
        )
        for sample in sequence.samples {
            let frame = try HDRReferenceDecoder.decode(
                pixelBuffer: sample.pixelBuffer,
                timestampSeconds: sample.timestamp.seconds,
                transfer: .hlg,
                referencePeakNits: 1_000
            )
            XCTAssertTrue(frame.lumaNits.allSatisfy { $0.isFinite })
        }
    }

    func testHLGAndPQDecodeRemainDistinctAndFinite() {
        let hlgMid = HDRReferenceTransferMath.decodeNits(signal: 0.5, transfer: .hlg, targetPeakNits: 1_000)
        let pqMid = HDRReferenceTransferMath.decodeNits(signal: 0.5, transfer: .pq, targetPeakNits: 1_000)
        XCTAssertTrue(hlgMid.isFinite && pqMid.isFinite)
        XCTAssertEqual(HDRReferenceTransferMath.decodeNits(signal: 0, transfer: .hlg), 0, accuracy: 0.0001)
        XCTAssertEqual(HDRReferenceTransferMath.decodeNits(signal: 1, transfer: .pq), 10_000, accuracy: 1)
        XCTAssertNotEqual(hlgMid, pqMid, accuracy: 1)
    }

    func testFrozenIsolationGuardRejectsEarlyAndDuplicateAccess() throws {
        let guardrail = FrozenIsolationGuard()
        XCTAssertThrowsError(try guardrail.authorize(.frozen))
        XCTAssertNoThrow(try guardrail.authorize(.tune))
        XCTAssertNoThrow(try guardrail.authorize(.validation))
        guardrail.finalizeSelection()
        XCTAssertNoThrow(try guardrail.authorize(.frozen))
        XCTAssertNoThrow(try guardrail.markFrozenEvaluated())
        XCTAssertThrowsError(try guardrail.markFrozenEvaluated())
    }

    func testV2ObjectiveHueShadowDiffuseAndTemporalMetricsAreFinite() {
        let reference: [[SIMD3<Float>]] = [
            [SIMD3(repeating: 2), SIMD3(120, 80, 50), SIMD3(700, 650, 600)],
            [SIMD3(repeating: 3), SIMD3(150, 90, 55), SIMD3(850, 700, 620)],
            [SIMD3(repeating: 2), SIMD3(125, 82, 51), SIMD3(710, 655, 605)]
        ]
        let generated: [[SIMD3<Float>]] = [
            [SIMD3(repeating: 0.2), SIMD3(100, 95, 45), SIMD3(500, 450, 400)],
            [SIMD3(repeating: 8), SIMD3(210, 70, 90), SIMD3(980, 520, 760)],
            [SIMD3(repeating: 0.3), SIMD3(105, 100, 47), SIMD3(510, 455, 405)]
        ]
        let metrics = V2MetricTestProbe.compareSequence(reference: reference, generated: generated)
        XCTAssertTrue(metrics.objective.isFinite)
        XCTAssertTrue(metrics.hueMeanError.isFinite && metrics.hueP95Error.isFinite)
        XCTAssertTrue(metrics.shadowError.isFinite && metrics.blackCrushRatio.isFinite)
        XCTAssertTrue(metrics.diffuseWhiteError.isFinite)
        XCTAssertTrue(metrics.temporalLuminanceError.isFinite && metrics.temporalFlicker.isFinite)
        XCTAssertFalse(metrics.weightedContributions.isEmpty)
    }

    func testV2CandidateSerializationRoundTrip() throws {
        let candidate = V2CandidateEvaluation(
            id: "candidate", stage: "test", parameters: CalibrationParameters(configuration: .calibratedV1),
            tune: nil, validation: nil, constraintsPassed: true, stabilityScore: 0.01, notes: []
        )
        let data = try JSONEncoder().encode(candidate)
        let decoded = try JSONDecoder().decode(V2CandidateEvaluation.self, from: data)
        XCTAssertEqual(decoded.id, candidate.id)
        XCTAssertEqual(decoded.parameters, candidate.parameters)
    }

    func testVideoLevelSplitHasNoIDLeakage() throws {
        let manifestURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("data_video/manifest-v2.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw XCTSkip("manifest-v2 unavailable") }
        let manifest = try PairManifest.load(from: manifestURL)
        let split = DatasetV2Discovery.splitDocument(manifest: manifest, seed: 92)
        XCTAssertTrue(Set(split.tune).isDisjoint(with: split.validation))
        XCTAssertTrue(Set(split.tune).isDisjoint(with: split.frozen))
        XCTAssertTrue(Set(split.validation).isDisjoint(with: split.frozen))
        XCTAssertEqual(split.tune.count + split.validation.count + split.frozen.count, manifest.pairs.count)
    }

    func testAlignmentConfidenceThresholdFilteringIsMonotonic() throws {
        let sdr = try makeSequence(times: [0, 1, 2, 3], values: [0.1, 0.4, 0.7, 0.9])
        let hdr = try makeSequence(times: [0, 1, 2, 3], values: [0.1, 0.5, 0.65, 0.9])
        let result = TemporalAligner.align(sdr: sdr, hdr: hdr, offsetRangeSeconds: 0...0, offsetStep: 1, confidenceThreshold: 0)
        let counts = [0.0, 0.6, 0.7, 0.8, 0.9].map { threshold in
            result.matches.filter { $0.confidence >= threshold }.count
        }
        for index in 1..<counts.count { XCTAssertLessThanOrEqual(counts[index], counts[index - 1]) }
    }

    func testSplitManagerRejectsDuplicatePairIDs() {
        let pair = PairRecord(id: "duplicate", sdr: "a.mp4", hdr: "b.mp4", license: "test", source: "local", split: .tune)
        XCTAssertThrowsError(try SplitManager.validate(PairManifest(pairs: [pair, pair])))
    }

    func testV4ManifestRoundTripAndVirginFrozenGuard() throws {
        let pair = V4PairRecord(
            id: "virgin",
            sdr: "pair/sdr.mov",
            hdr: "pair/hdr.mov",
            source: "official",
            license: "test",
            expectedRelation: .sameMaster,
            contentCategory: ["animation"],
            contentFamily: "test-family",
            split: .frozen,
            virginFrozen: true,
            group: "test-group"
        )
        let manifest = V4Manifest(pairs: [pair])
        try manifest.validate(relativeTo: URL(fileURLWithPath: "/tmp/manifest-v4.json"))
        let roundTrip = try JSONDecoder().decode(V4Manifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(roundTrip.pairs.first?.virginFrozen, true)
        let guardrail = V4FrozenAccessGuard()
        XCTAssertNoThrow(try guardrail.authorize(pair: pair, phase: .metadata))
        XCTAssertNoThrow(try guardrail.authorize(pair: pair, phase: .alignment))
        XCTAssertThrowsError(try guardrail.authorize(pair: pair, phase: .objective))
    }

    func testV4ManifestRejectsDuplicatePhysicalMediaAndInvalidVirginSplit() {
        let first = V4PairRecord(
            id: "one", sdr: "same.mov", hdr: "one-hdr.mov", source: "test", license: "test",
            expectedRelation: .sameSource, split: .tune
        )
        let duplicatePath = V4PairRecord(
            id: "two", sdr: "same.mov", hdr: "two-hdr.mov", source: "test", license: "test",
            expectedRelation: .sameSource, split: .tune
        )
        XCTAssertThrowsError(try V4Manifest(pairs: [first, duplicatePath]).validate(relativeTo: URL(fileURLWithPath: "/tmp/manifest-v4.json")))

        let invalidVirgin = V4PairRecord(
            id: "invalid", sdr: "invalid-sdr.mov", hdr: "invalid-hdr.mov", source: "test", license: "test",
            expectedRelation: .sameMaster, split: .tune, virginFrozen: true
        )
        XCTAssertThrowsError(try V4Manifest(pairs: [invalidVirgin]).validate(relativeTo: URL(fileURLWithPath: "/tmp/manifest-v4.json")))
    }

    func testV4TransferRecognitionKeepsHLGAndPQSeparate() {
        let hlg = makeV4Metadata(primaries: "bt2020", transfer: "arib-std-b67", bitDepth: 10)
        let pq = makeV4Metadata(primaries: "bt2020", transfer: "smpte2084", bitDepth: 12)
        let sdr = makeV4Metadata(primaries: "bt709", transfer: "bt709", bitDepth: 10)
        XCTAssertEqual(hlg.transferFamily, "HLG")
        XCTAssertEqual(pq.transferFamily, "PQ")
        XCTAssertTrue(hlg.isHDRReference && pq.isHDRReference)
        XCTAssertTrue(sdr.isSDRReference)
        XCTAssertFalse(sdr.isHDRReference)
    }

    func testV4DigestChangesWhenMediaChanges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-v4-digest-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1, 2, 3, 4]).write(to: url)
        let first = try V4DatasetIntegrity.digest(url: url)
        try Data([1, 2, 3, 5]).write(to: url)
        let second = try V4DatasetIntegrity.digest(url: url)
        XCTAssertNotEqual(first.sha256, second.sha256)
        XCTAssertEqual(first.sizeBytes, second.sizeBytes)
    }

    func testV4DuplicateContentGroupsAreDetectedBySHA256() {
        let files = [
            V4FileDigest(path: "/tmp/a.mp4", sizeBytes: 3, sha256: "same"),
            V4FileDigest(path: "/tmp/b.mp4", sizeBytes: 3, sha256: "same"),
            V4FileDigest(path: "/tmp/c.mp4", sizeBytes: 4, sha256: "different")
        ]
        XCTAssertEqual(V4DatasetIntegrity.duplicatePathGroups(files), [["/tmp/a.mp4", "/tmp/b.mp4"]])
    }

    func testV4ExternalRootAliasResolvesWithoutCopyingMedia() throws {
        let manifestURL = URL(fileURLWithPath: "/tmp/manifest-v4.json")
        let pair = V4PairRecord(
            id: "live-test",
            sdr: "live:open-sourced_SDR/sample.mp4",
            hdr: "live:open-sourced_HDR10/sample.mp4",
            source: "LIVE",
            license: "test",
            expectedRelation: .sameSource,
            contentCategory: ["night"],
            contentFamily: "LIVE",
            split: .frozen,
            virginFrozen: true
        )
        let manifest = V4Manifest(
            pairs: [pair],
            roots: ["live": "/Volumes/example/LIVE"]
        )
        let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
        XCTAssertEqual(urls.sdr.path, "/Volumes/example/LIVE/open-sourced_SDR/sample.mp4")
        XCTAssertEqual(urls.hdr.path, "/Volumes/example/LIVE/open-sourced_HDR10/sample.mp4")
    }

    func testLocalLiveDiscoveryFindsBalancedHDR10Pairs() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("data_video/LIVE Paired Comparison HDR vs. SDR Database")
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw XCTSkip("local LIVE dataset is not present")
        }
        let report = try V4LiveImporter.discover(rootURL: root)
        XCTAssertEqual(report.sdrCandidates, report.hdrCandidates)
        XCTAssertGreaterThanOrEqual(report.pairCandidates, 1)
        XCTAssertGreaterThanOrEqual(report.uniqueSourceIDs, 1)
    }

    func testV4AuditReportHardCodesNoObjectiveEvaluation() {
        let report = V4DatasetAuditReport(
            manifestPath: "/tmp/manifest-v4.json",
            manifestSHA256: "test",
            pairs: [],
            diversity: V4DiversityReport(),
            notes: []
        )
        XCTAssertFalse(report.objectiveEvaluated)
        XCTAssertTrue(report.frozenObjectiveEvaluated.isEmpty)
    }

    private func makeV4Metadata(primaries: String, transfer: String, bitDepth: Int) -> V4StreamMetadata {
        V4StreamMetadata(
            path: "/tmp/test",
            durationSeconds: 1,
            frameRate: 24,
            timeBase: "1/24",
            codec: "test",
            width: 1920,
            height: 1080,
            pixelFormat: "yuv420p\(bitDepth)",
            bitDepth: bitDepth,
            colorRange: "tv",
            colorPrimaries: primaries,
            transfer: transfer,
            matrix: primaries,
            masteringMetadataPresent: bitDepth >= 10,
            audioTrackCount: 0,
            probeTool: "test"
        )
    }

    private func makeSequence(times: [Double], values: [Float]) throws -> FrameSequence {
        var samples: [FrameSample] = []
        for (index, time) in times.enumerated() {
            let grid = Array(repeating: values[index], count: 64 * 36)
            let descriptor = FrameDescriptorBuilder.make(
                timestamp: CMTime(seconds: time, preferredTimescale: 1_000),
                lumaGrid: grid
            )
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                1,
                1,
                kCVPixelFormatType_32BGRA,
                nil,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw NSError(domain: "CalibrationTests", code: Int(status))
            }
            samples.append(FrameSample(
                index: index,
                timestamp: CMTime(seconds: time, preferredTimescale: 1_000),
                pixelBuffer: pixelBuffer,
                descriptor: descriptor,
                lumaGrid: grid
            ))
        }
        return FrameSequence(
            url: URL(fileURLWithPath: "/tmp/test.mp4"),
            pixelFormat: kCVPixelFormatType_32BGRA,
            width: 1,
            height: 1,
            nominalFrameRate: 1,
            durationSeconds: 3,
            samples: samples
        )
    }
}
