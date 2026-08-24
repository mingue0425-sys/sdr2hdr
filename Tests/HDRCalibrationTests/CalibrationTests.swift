import CoreMedia
import CoreVideo
import HDRCalibration
import HDRCore
import Metal
import simd
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

    func testFrozenImprovementUsesRatioUnitsAtFivePercentBoundary() {
        XCTAssertFalse(V4PromotionMath.passesMinimumImprovement(baseline: 1.0, candidate: 0.999, minimumRatio: 0.05))
        XCTAssertFalse(V4PromotionMath.passesMinimumImprovement(baseline: 1.0, candidate: 0.96, minimumRatio: 0.05))
        XCTAssertTrue(V4PromotionMath.passesMinimumImprovement(baseline: 1.0, candidate: 0.95, minimumRatio: 0.05))
        XCTAssertTrue(V4PromotionMath.passesMinimumImprovement(baseline: 1.0, candidate: 0.94, minimumRatio: 0.05))
        XCTAssertEqual(V4PromotionMath.improvementPercent(baseline: 1.0, candidate: 0.95), 5.0, accuracy: 0.000_001)
    }

    func testSparseSceneRangeUsesSequencePositionNotSourceFrameIndex() {
        let sourceIndices = [0, 15, 30, 45, 60, 75]
        let selected = sourceIndices.enumerated().filter { position, _ in
            SceneRange(id: "scene", startSequencePosition: 2, endSequencePosition: 4, tags: [])
                .contains(sequencePosition: position)
        }.map(\.element)
        XCTAssertEqual(selected, [30, 45, 60])

        let irregular = [0, 3, 17, 22, 91]
        let irregularSelected = irregular.enumerated().filter { position, _ in
            SceneRange(id: "scene", startSequencePosition: 1, endSequencePosition: 3, tags: [])
                .contains(sequencePosition: position)
        }.map(\.element)
        XCTAssertEqual(irregularSelected, [3, 17, 22])
    }

    func testSceneMembershipIsCorrectForContiguousAndLargeSparseSequences() {
        let contiguous = [0, 1, 2, 3]
        let contiguousScene = SceneRange(
            id: "contiguous", startSequencePosition: 1, endSequencePosition: 2, tags: []
        )
        XCTAssertEqual(
            contiguous.enumerated().filter { contiguousScene.contains(sequencePosition: $0.offset) }.map(\.element),
            [1, 2]
        )

        let largeSparseSourceIndices = (0..<128).map { $0 * 15 }
        let largeSparseScene = SceneRange(
            id: "large-sparse", startSequencePosition: 60, endSequencePosition: 64, tags: []
        )
        let selected = largeSparseSourceIndices.enumerated()
            .filter { largeSparseScene.contains(sequencePosition: $0.offset) }
            .map(\.element)
        XCTAssertEqual(selected, [900, 915, 930, 945, 960])
    }

    func testProductionPercentileEstimatorMatchesOfflineQuantization() {
        let dark = Array(repeating: Float(0.01), count: 144)
        let runtimeDark = HDRSceneStatistics(productionLinearSamples: dark)
        let offlineDark = HDRSceneStatistics(histogram: [144] + Array(repeating: 0, count: 15))
        XCTAssertEqual(runtimeDark, offlineDark)
        XCTAssertEqual(runtimeDark.p05, 0.03125, accuracy: 0.000_001)

        let ramp = (0..<144).map { Float($0) / 143 }
        let runtimeRamp = HDRSceneStatistics(productionLinearSamples: ramp)
        let repeated = HDRSceneStatistics(productionLinearSamples: ramp)
        XCTAssertEqual(runtimeRamp, repeated)
        XCTAssertEqual(HDRSceneStatistics.productionSamplePositions(width: 3840, height: 2160).count, 144)
        XCTAssertEqual(HDRSceneStatistics.productionLinearAverage(linearSamples: dark), 0.01, accuracy: 0.000_01)
    }

    func testCausalTemporalStateIsDeterministicForV2AndV4Sequences() {
        let averages: [Float] = [0.05, 0.05, 0.80, 0.80, 0.05]
        let statistics = averages.map { value in
            HDRSceneStatistics(
                p01: max(value * 0.01, 0.001), p05: max(value * 0.05, 0.001),
                p10: max(value * 0.10, 0.002), p25: max(value * 0.35, 0.01),
                p50: value, p90: min(value + 0.15, 1), p99: 1
            )
        }
        var productionV2 = HDRTemporalControlState()
        var offlineV2 = HDRTemporalControlState()
        var productionV4 = HDRTemporalControlState()
        var offlineV4 = HDRTemporalControlState()
        for index in averages.indices {
            let sequence = UInt64(index + 1)
            _ = productionV2.updateAutomaticAverage(averageLuminance: averages[index], stability: 0.85, sequence: sequence)
            _ = offlineV2.updateAutomaticAverage(averageLuminance: averages[index], stability: 0.85, sequence: sequence)
            _ = productionV4.updateAutomaticAverage(averageLuminance: averages[index], stability: 0.85, sequence: sequence)
            _ = offlineV4.updateAutomaticAverage(averageLuminance: averages[index], stability: 0.85, sequence: sequence)
            _ = productionV4.updateAutomaticStatistics(statistics[index], averageLuminance: averages[index], stability: 0.85, sequence: sequence)
            _ = offlineV4.updateAutomaticStatistics(statistics[index], averageLuminance: averages[index], stability: 0.85, sequence: sequence)
            XCTAssertEqual(productionV2.adaptation, offlineV2.adaptation, accuracy: 0.000_001)
            XCTAssertEqual(productionV4.adaptation, offlineV4.adaptation, accuracy: 0.000_001)
            XCTAssertEqual(productionV4.shadowFloor, offlineV4.shadowFloor, accuracy: 0.000_001)
            XCTAssertEqual(productionV4.shadowTop, offlineV4.shadowTop, accuracy: 0.000_001)
        }
    }

    func testProductionAndOfflineProcessorTemporalParityForV2AndV4() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let values: [SIMD3<Float>] = [
            SIMD3(repeating: 0.05), SIMD3(repeating: 0.05), SIMD3(repeating: 0.80),
            SIMD3(repeating: 0.80), SIMD3(repeating: 0.05)
        ]
        for revision in [HDRToneCurveRevision.legacyV2, .sceneRelativeV4] {
            var configuration = HDRConfiguration.calibratedV2
            configuration.toneCurveRevision = revision
            let production = try HDRProcessor(device: device, configuration: configuration)
            let offline = try HDRCoreOfflineEvaluator(device: device, configuration: configuration)
            for (index, value) in values.enumerated() {
                let pixelBuffer = try makeCalibrationBGRA(width: 32, height: 18, rgb: value)
                let commandBuffer = try production.makeCommandBuffer()
                _ = try production.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                XCTAssertNil(commandBuffer.error)

                _ = try offline.evaluate(
                    pixelBuffer: pixelBuffer,
                    timestampSeconds: Double(index) / 30,
                    configuration: configuration
                )
                XCTAssertEqual(production.temporalAdaptation, offline.temporalAdaptation, accuracy: 0.000_001)
                let productionShadow = production.sceneShadowCoordinates
                XCTAssertEqual(productionShadow.floor, offline.sceneShadowCoordinates.floor, accuracy: 0.000_001)
                XCTAssertEqual(productionShadow.top, offline.sceneShadowCoordinates.top, accuracy: 0.000_001)
                XCTAssertEqual(productionShadow.valid, offline.sceneShadowCoordinates.valid)
            }
        }
    }

    func testHLGColoredVectorUsesOneBT2100OOTFGain() {
        let signal = SIMD3<Float>(0.75, 0.50, 0.25)
        let output = HDRReferenceTransferMath.hlgDisplayRGBNits(signal: signal, peakNits: 1_000)
        func inverseOETF(_ value: Float) -> Float {
            let a: Float = 0.17883277
            let b: Float = 1 - 4 * a
            let c: Float = 0.55991073
            return value <= 0.5 ? (value * value) / 3 : (exp((value - c) / a) + b) / 12
        }
        let scene = SIMD3(
            inverseOETF(signal.x), inverseOETF(signal.y), inverseOETF(signal.z)
        )
        let luminance = max(simd_dot(scene, HDRColorMath.bt2020Luminance), 0)
        let gamma: Float = 1.2
        let expected = scene * pow(luminance, gamma - 1) * 1_000
        XCTAssertEqual(output.x, expected.x, accuracy: 0.01)
        XCTAssertEqual(output.y, expected.y, accuracy: 0.01)
        XCTAssertEqual(output.z, expected.z, accuracy: 0.01)
        XCTAssertEqual(output.x / max(output.y, 1e-6), scene.x / max(scene.y, 1e-6), accuracy: 0.000_01)
        let oldChannelWise = SIMD3<Float>(
            pow(scene.x, gamma) * 1_000,
            pow(scene.y, gamma) * 1_000,
            pow(scene.z, gamma) * 1_000
        )
        XCTAssertGreaterThan(simd_distance(output, oldChannelWise), 1)
        let gray = HDRReferenceTransferMath.hlgDisplayRGBNits(signal: SIMD3(repeating: 0.5))
        XCTAssertEqual(gray.x, gray.y, accuracy: 0.000_001)
        XCTAssertEqual(gray.y, gray.z, accuracy: 0.000_001)
        XCTAssertEqual(HDRReferenceTransferMath.hlgDisplayNits(signal: 0.5), gray.x, accuracy: 0.000_001)
    }

    func testStrictSDRMetadataEligibilityRejectsMissingAndNon709Fields() {
        var valid = makeV4Metadata(primaries: "bt709", transfer: "bt709", bitDepth: 8)
        valid.matrix = "bt709"
        valid.colorRange = "tv"
        XCTAssertTrue(valid.isExplicitBT709SDR)

        var missingPrimaries = valid
        missingPrimaries.colorPrimaries = nil
        XCTAssertFalse(missingPrimaries.isExplicitBT709SDR)
        var missingTransfer = valid
        missingTransfer.transfer = nil
        XCTAssertFalse(missingTransfer.isExplicitBT709SDR)
        var missingMatrix = valid
        missingMatrix.matrix = nil
        XCTAssertFalse(missingMatrix.isExplicitBT709SDR)
        var missingRange = valid
        missingRange.colorRange = nil
        XCTAssertFalse(missingRange.isExplicitBT709SDR)
        let bt2020 = makeV4Metadata(primaries: "bt2020", transfer: "bt709", bitDepth: 10)
        XCTAssertFalse(bt2020.isExplicitBT709SDR)
        var unsupportedTransfer = valid
        unsupportedTransfer.transfer = "unknown-transfer"
        XCTAssertFalse(unsupportedTransfer.isExplicitBT709SDR)
    }

    func testDiversityReadinessCountsOnlyAcceptedMainCalibrationRecords() {
        let eligiblePair = V4PairRecord(
            id: "eligible", sdr: "eligible-sdr", hdr: "eligible-hdr", source: "test", license: "test",
            expectedRelation: .sameSource, contentCategory: ["family-a"], contentFamily: "family-a", split: .tune
        )
        let rejectedPair = V4PairRecord(
            id: "rejected", sdr: "rejected-sdr", hdr: "rejected-hdr", source: "test", license: "test",
            expectedRelation: .sameSource, contentCategory: ["family-b"], contentFamily: "family-b", split: .frozen, virginFrozen: true
        )
        let manifest = V4Manifest(pairs: [eligiblePair, rejectedPair])
        let metadata = makeV4Metadata(primaries: "bt2020", transfer: "smpte2084", bitDepth: 10)
        let smoke = V4DecodeSmoke(attempted: true, firstFrame: true, middleFrame: true, lastFrame: true, decodedSampleCount: 3)
        let aligned = V4AlignmentSummary(sampledFrames: 3, matchedFrames: 3, matchRatio: 1, medianConfidence: 0.9, p50Confidence: 0.9, confidenceAtLeast60: 1, confidenceAtLeast70: 1, confidenceAtLeast80: 1, status: "ALIGNED")
        let audits = [
            V4PairAudit(id: "eligible", source: "test", split: .tune, virginFrozen: false, expectedRelation: .sameSource, suitability: .mainCalibration, status: .accepted, sdrPath: "eligible-sdr", hdrPath: "eligible-hdr", hdrMetadata: metadata, sdrReferenceValid: true, hdrReferenceValid: true, sdrDecode: smoke, hdrDecode: smoke, alignment: aligned),
            V4PairAudit(id: "rejected", source: "test", split: .frozen, virginFrozen: true, expectedRelation: .sameSource, suitability: .reject, status: .invalidMetadata, sdrPath: "rejected-sdr", hdrPath: "rejected-hdr", hdrMetadata: metadata, sdrReferenceValid: false, hdrReferenceValid: true)
        ]
        let diversity = V4DatasetAuditor.diversityReport(manifest: manifest, audits: audits)
        XCTAssertEqual(diversity.mainCalibrationPairs, 1)
        XCTAssertEqual(diversity.hdrTransfers, ["PQ": 1])
        XCTAssertEqual(diversity.contentFamilies, ["family-a": 1])
        XCTAssertEqual(diversity.virginFrozenPairs, 0)
        XCTAssertEqual(diversity.tunePairs, 1)
        XCTAssertEqual(diversity.frozenPairs, 0)
    }

    func testV4EvidenceRequiresAuditAndRelationPolicyPreservesSourceRelation() throws {
        let manifestURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("data_video/manifest-v4.json")
        let missingAudit = FileManager.default.temporaryDirectory.appendingPathComponent("missing-audit-\(UUID().uuidString).json")
        let lockURL = FileManager.default.currentDirectoryPath.hasPrefix("/")
            ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("data_video/dataset-v4-lock.json")
            : URL(fileURLWithPath: "/tmp/missing-lock.json")
        XCTAssertThrowsError(try V4DatasetEvidenceValidator.validate(manifestURL: manifestURL, auditURL: missingAudit, lockURL: lockURL))
        let wrongLock = FileManager.default.temporaryDirectory.appendingPathComponent("wrong-lock-(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: wrongLock) }
        let invalidLock = V4DatasetLock(manifestSHA256: "wrong", files: [])
        try JSONEncoder().encode(invalidLock).write(to: wrongLock)
        let existingAudit = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("results/dataset-v4-final.json")
        XCTAssertThrowsError(try V4DatasetEvidenceValidator.validate(manifestURL: manifestURL, auditURL: existingAudit, lockURL: wrongLock))
        XCTAssertTrue(V4ExpectedRelation.sameSource.supportsMainCalibration)
        XCTAssertFalse(V4ExpectedRelation.sameContentDifferentGrade.supportsMainCalibration)
        XCTAssertEqual(V4ExpectedRelation.sameSource.legacyRelation(), .sameSource)
        XCTAssertEqual(V4ExpectedRelation.sameContentDifferentGrade.legacyRelation(), .sameContentDifferentGrade)
    }

    func testSourceFreezeHashDetectsSourceMutationAndMissingRequiredFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-v4-source-\(UUID().uuidString)")
        defer { do { try FileManager.default.removeItem(at: root) } catch {} }
        for directory in ["Sources/HDRCore", "Sources/HDRCalibration"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let required = [
            "Package.swift", "Sources/HDRCore/HDRConfiguration.swift", "Sources/HDRCore/HDRProcessor.swift",
            "Sources/HDRCore/HDRReference.swift", "Sources/HDRCalibration/V4Calibration.swift",
            "Sources/HDRCalibration/V4DatasetAudit.swift", "Sources/HDRCalibration/V4Models.swift",
            "Sources/HDRCalibration/Decode.swift", "Sources/HDRCalibration/Alignment.swift",
            "Sources/HDRCalibration/FrameIO.swift", "Sources/HDRCalibration/Evaluation.swift"
        ]
        for path in required { try Data(path.utf8).write(to: root.appendingPathComponent(path)) }
        let before = try V4SourceHasher.sourceHash(repositoryRoot: root)
        try Data("changed".utf8).write(to: root.appendingPathComponent("Sources/HDRCalibration/V4Calibration.swift"))
        let after = try V4SourceHasher.sourceHash(repositoryRoot: root)
        XCTAssertNotEqual(before, after)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/HDRCalibration/V4Calibration.swift"))
        XCTAssertThrowsError(try V4SourceHasher.sourceHash(repositoryRoot: root))
    }

    func testPromotionGateStateMachineMakesTransferFamilyRuntimeAndFrozenFailuresReachable() {
        var pass = V4PromotionGateResult(
            completeness: .pass, datasetIntegrity: .pass, identifiability: .pass, relativeShadow: .pass,
            overall: .pass, shadow: .pass, temporal: .pass, transfer: .pass, family: .pass,
            runtime: .pass, frozen: .pass, hardSafety: .pass
        )
        XCTAssertEqual(V4PromotionGateMachine.verdict(pass), .promote)
        pass.transfer = .fail
        XCTAssertEqual(V4PromotionGateMachine.verdict(pass), .transferGeneralizationFail)
        pass.transfer = .pass; pass.family = .fail
        XCTAssertEqual(V4PromotionGateMachine.verdict(pass), .validationFail)
        pass.family = .pass; pass.runtime = .fail
        XCTAssertEqual(V4PromotionGateMachine.verdict(pass), .runtimeRegression)
        pass.runtime = .pass; pass.frozen = .fail
        XCTAssertEqual(V4PromotionGateMachine.verdict(pass), .virginFrozenFail)
        pass.frozen = .pass; pass.shadow = .fail
        XCTAssertEqual(V4PromotionGateMachine.verdict(pass), .shadowGeneralizationFail)
        pass.shadow = .pass; pass.completeness = .fail
        XCTAssertEqual(V4PromotionGateMachine.verdict(pass), .validationFail)
        pass.completeness = .pass; pass.runtime = .notMeasured
        XCTAssertEqual(V4PromotionGateMachine.verdict(pass), .runtimeRegression)
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

    private func makeCalibrationBGRA(width: Int, height: Int, rgb: SIMD3<Float>) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "CalibrationTests", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw NSError(domain: "CalibrationTests", code: 10)
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let red = UInt8(min(max(Int(rgb.x * 255), 0), 255))
        let green = UInt8(min(max(Int(rgb.y * 255), 0), 255))
        let blue = UInt8(min(max(Int(rgb.z * 255), 0), 255))
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * rowBytes + column * 4
                base[offset] = blue
                base[offset + 1] = green
                base[offset + 2] = red
                base[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}
