import CoreMedia
import CoreVideo
@testable import HDRCalibration
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

        let shared = PairEvaluator.align(sdr: sdr, hdr: hdr, confidenceThreshold: 0.60)
        let direct = TemporalAligner.align(sdr: sdr, hdr: hdr, confidenceThreshold: 0.60)
        XCTAssertEqual(shared.status, direct.status)
        XCTAssertEqual(shared.matches, direct.matches)
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

    func testV6TransferInvariantMatcherSurvivesMonotonicToneCurve() {
        let base: [Float] = (0..<(64 * 36)).map { index in
            let x = Double(index % 64) / 63.0
            let y = Double(index / 64) / 35.0
            return Float(min(1, max(0, 0.08 + 0.72 * x + 0.14 * sin(y * 12.0) + 0.06 * cos(x * 17.0))))
        }
        let toneMapped = base.map { Float(pow(Double($0), 0.58)) }
        let lhs = V6TransferInvariantMatcher.features(base, configuration: .v6)
        let rhs = V6TransferInvariantMatcher.features(toneMapped, configuration: .v6)
        let metrics = V6TransferInvariantMatcher.compare(lhs, rhs, configuration: .v6)
        XCTAssertGreaterThan(metrics.rankNormalizedLumaCorrelation, 0.98)
        XCTAssertGreaterThan(metrics.gradientCorrelation, 0.80)
        XCTAssertGreaterThan(metrics.confidence, 0.60)
    }

    func testV6PreparedPlanCanonicalHashAndExactIdentityValidation() throws {
        let prepared = try makePreparedDiagnosticPair(values: [0.10, 0.30, 0.70, 0.90])
        let configuration = V6PreparationConfiguration(
            maxFramesPerScene: 8,
            maxDecodedFrames: 64,
            acceptedConfidenceThreshold: 0.60
        )
        let plan = try V6PreparedEvaluationPlanBuilder.makePlan(
            preparedPairs: [prepared],
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            configuration: configuration,
            inputHashes: [prepared.record.id: V6InputHashes(sdrSHA256: String(repeating: "a", count: 64), hdrSHA256: String(repeating: "b", count: 64))]
        )
        let firstHash = try V6PreparedEvaluationPlanHasher.sha256(plan)
        let secondHash = try V6PreparedEvaluationPlanHasher.sha256(plan)
        XCTAssertEqual(firstHash, secondHash)
        XCTAssertEqual(plan.pairs.first?.alignment.acceptedFrameCount, 4)
        XCTAssertEqual(plan.pairs.first?.alignment.matchedFrames.count, prepared.alignment.matches.count)
        XCTAssertEqual(plan.pairs.first?.decode.decodedHDRFrameCount, prepared.hdrSequence.samples.count)
        XCTAssertEqual(plan.pairs.first?.decode.referenceTransfer, .pq)
        XCTAssertEqual(plan.preparation.referenceTargetPeakNits, 1_000)
        XCTAssertNoThrow(try V6PreparedEvaluationPlanBuilder.validate(plan: plan, preparedPairs: [prepared]))
        let record = V4PairRecord(
            id: prepared.record.id,
            sdr: prepared.record.sdr,
            hdr: prepared.record.hdr,
            source: "test",
            license: "test",
            expectedRelation: .sameSource,
            split: .tune
        )
        let hashes = V6InputHashes(
            sdrSHA256: String(repeating: "a", count: 64),
            hdrSHA256: String(repeating: "b", count: 64)
        )
        XCTAssertNoThrow(try V6PreparedEvaluationPlanBuilder.validateSealedContract(
            plan: plan,
            scope: "TUNE_VALIDATION",
            records: [record],
            inputHashes: [record.id: hashes],
            preparation: configuration
        ))
        XCTAssertThrowsError(try V6PreparedEvaluationPlanBuilder.validateSealedContract(
            plan: plan,
            scope: "VIRGIN_FROZEN",
            records: [record],
            inputHashes: [record.id: hashes],
            preparation: configuration
        ))

        let driftedMatches = prepared.matches.enumerated().map { index, item in
            guard index == 0 else { return item }
            let match = MatchedFrame(
                sdrIndex: item.match.sdrIndex,
                hdrIndex: item.match.hdrIndex,
                sdrSequencePosition: item.match.sdrSequencePosition,
                hdrSequencePosition: item.match.hdrSequencePosition,
                sdrTimeSeconds: item.match.sdrTimeSeconds,
                hdrTimeSeconds: item.match.hdrTimeSeconds,
                confidence: 0.59
            )
            return PreparedMatch(
                match: match,
                sdr: item.sdr,
                hdr: item.hdr,
                reference: item.reference,
                sourceLuma: item.sourceLuma
            )
        }
        let drifted = PreparedPair(
            record: prepared.record,
            sdrSequence: prepared.sdrSequence,
            hdrSequence: prepared.hdrSequence,
            referenceTransfer: prepared.referenceTransfer,
            alignment: prepared.alignment,
            scenes: prepared.scenes,
            matches: driftedMatches,
            temporalWindows: prepared.temporalWindows
        )
        XCTAssertThrowsError(try V6PreparedEvaluationPlanBuilder.validate(plan: plan, preparedPairs: [drifted]))
    }

    func testV6MatcherConfigurationHashIsCanonicalAndEvaluatorBound() throws {
        let prepared = try makePreparedDiagnosticPair(values: [0.10, 0.30, 0.70, 0.90])
        let configuration = V6PreparationConfiguration(
            maxFramesPerScene: 8,
            maxDecodedFrames: 64,
            acceptedConfidenceThreshold: 0.60,
            matcherConfiguration: V6MatcherConfiguration(matcherVersion: "v6-test-matcher")
        )
        let record = V4PairRecord(
            id: prepared.record.id,
            sdr: prepared.record.sdr,
            hdr: prepared.record.hdr,
            source: "test",
            license: "test",
            expectedRelation: .sameSource,
            split: .tune
        )
        let hashes = [record.id: V6InputHashes(
            sdrSHA256: String(repeating: "a", count: 64),
            hdrSHA256: String(repeating: "b", count: 64)
        )]
        let plan = try V6PreparedEvaluationPlanBuilder.makePlan(
            preparedPairs: [prepared],
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            configuration: configuration,
            inputHashes: hashes
        )
        XCTAssertEqual(
            plan.preparation.matcherConfigurationHash,
            try plan.preparation.matcherConfiguration.canonicalSHA256()
        )
        let changedConfiguration = V6PreparationConfiguration(
            maxFramesPerScene: 8,
            maxDecodedFrames: 64,
            acceptedConfidenceThreshold: 0.60,
            matcherConfiguration: V6MatcherConfiguration(matcherVersion: "v6-tampered-matcher")
        )
        XCTAssertNotEqual(
            configuration.matcherConfigurationHash,
            changedConfiguration.matcherConfigurationHash
        )
        XCTAssertThrowsError(try V6PreparedEvaluationPlanBuilder.validateSealedContract(
            plan: plan,
            scope: "TUNE_VALIDATION",
            records: [record],
            inputHashes: hashes,
            preparation: changedConfiguration
        ))
    }

    func testV6EvaluatorEntryRejectsPlanWithNoAcceptedMatches() throws {
        let prepared = try makePreparedDiagnosticPair(values: [0.10, 0.30, 0.70, 0.90])
        let lowConfidenceMatches = prepared.matches.map { item in
            let match = MatchedFrame(
                sdrIndex: item.match.sdrIndex,
                hdrIndex: item.match.hdrIndex,
                sdrSequencePosition: item.match.sdrSequencePosition,
                hdrSequencePosition: item.match.hdrSequencePosition,
                sdrTimeSeconds: item.match.sdrTimeSeconds,
                hdrTimeSeconds: item.match.hdrTimeSeconds,
                confidence: 0.20
            )
            return PreparedMatch(
                match: match,
                sdr: item.sdr,
                hdr: item.hdr,
                reference: item.reference,
                sourceLuma: item.sourceLuma
            )
        }
        let lowConfidence = PreparedPair(
            record: prepared.record,
            sdrSequence: prepared.sdrSequence,
            hdrSequence: prepared.hdrSequence,
            referenceTransfer: prepared.referenceTransfer,
            alignment: prepared.alignment,
            scenes: prepared.scenes,
            matches: lowConfidenceMatches,
            temporalWindows: prepared.temporalWindows
        )
        let plan = try V6PreparedEvaluationPlanBuilder.makePlan(
            preparedPairs: [lowConfidence],
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            inputHashes: [lowConfidence.record.id: V6InputHashes(
                sdrSHA256: String(repeating: "c", count: 64),
                hdrSHA256: String(repeating: "d", count: 64)
            )]
        )
        XCTAssertEqual(plan.pairs.first?.alignment.acceptedFrameCount, 0)
        XCTAssertThrowsError(try V6PreparedEvaluationEntry.acceptedMatches(prepared: lowConfidence, plan: plan))
        XCTAssertTrue(V6VirginHoldoutPolicy.consumedPairIDs.contains("dvb_live_linear_caminandes_hevc_uhd_sdr_hlg"))
        XCTAssertFalse(V6VirginHoldoutPolicy.objectivePixelsRead)
        XCTAssertFalse(V6VirginHoldoutPolicy.objectiveMetricsObserved)
        XCTAssertTrue(V6VirginHoldoutPolicy.procedurallyConsumed)
        XCTAssertFalse(V6VirginHoldoutPolicy.retryPermitted)
    }

    func testV6Live9PreflightAndEvaluatorEntryUseExactSameAcceptedFrameSet() throws {
        // This is the minimal reproduction of the V5 failure: the old
        // preflight counted raw matches while evaluator entry applied the
        // 0.60 acceptance gate.  The V6 plan makes the decision once and
        // exposes the same identity array to both callers.
        let prepared = try makePreparedDiagnosticPair(
            values: [0.10, 0.30, 0.70, 0.90],
            id: "live_9_face_close_3840x2160_15000k"
        )
        let plan = try V6PreparedEvaluationPlanBuilder.makePlan(
            preparedPairs: [prepared],
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            inputHashes: [prepared.record.id: V6InputHashes(
                sdrSHA256: String(repeating: "a", count: 64),
                hdrSHA256: String(repeating: "b", count: 64)
            )]
        )
        let preflight = V6PreparedEvaluationPlanBuilder.acceptedMatches(
            from: prepared,
            confidenceThreshold: plan.preparation.acceptedConfidenceThreshold
        ).map(V6PreparedEvaluationPlanBuilder.frameIdentity)
        let evaluator = try V6PreparedEvaluationEntry.acceptedMatches(
            prepared: prepared,
            plan: plan
        ).map(V6PreparedEvaluationPlanBuilder.frameIdentity)
        XCTAssertEqual(preflight, evaluator)
        XCTAssertFalse(preflight.isEmpty)

        // If the preparation material changes at evaluator entry, the plan
        // fails closed instead of producing a second, divergent selection.
        let driftedMatch = prepared.matches[0]
        let changed = MatchedFrame(
            sdrIndex: driftedMatch.match.sdrIndex,
            hdrIndex: driftedMatch.match.hdrIndex,
            sdrSequencePosition: driftedMatch.match.sdrSequencePosition,
            hdrSequencePosition: driftedMatch.match.hdrSequencePosition,
            sdrTimeSeconds: driftedMatch.match.sdrTimeSeconds,
            hdrTimeSeconds: driftedMatch.match.hdrTimeSeconds,
            confidence: 0.59
        )
        let changedPair = PreparedPair(
            record: prepared.record,
            sdrSequence: prepared.sdrSequence,
            hdrSequence: prepared.hdrSequence,
            referenceTransfer: prepared.referenceTransfer,
            alignment: prepared.alignment,
            scenes: prepared.scenes,
            matches: [PreparedMatch(
                match: changed,
                sdr: driftedMatch.sdr,
                hdr: driftedMatch.hdr,
                reference: driftedMatch.reference,
                sourceLuma: driftedMatch.sourceLuma
            )] + Array(prepared.matches.dropFirst()),
            temporalWindows: prepared.temporalWindows
        )
        XCTAssertThrowsError(try V6PreparedEvaluationEntry.acceptedMatches(prepared: changedPair, plan: plan))
    }

    func testV6MatcherDiagnosticProductionEvidenceEqualsPreparedPlanExactly() throws {
        let prepared = try makePreparedDiagnosticPair(
            values: [0.10, 0.30, 0.70, 0.90], id: "diagnostic-production"
        )
        let plan = try V6PreparedEvaluationPlanBuilder.makePlan(
            preparedPairs: [prepared],
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            inputHashes: [prepared.record.id: V6InputHashes(
                sdrSHA256: String(repeating: "a", count: 64),
                hdrSHA256: String(repeating: "b", count: 64)
            )]
        )
        guard let pairPlan = plan.pairPlan(for: prepared.record.id) else {
            return XCTFail("prepared plan pair is missing")
        }
        let structural = V6StructuralDiagnosticEvidence(
            robustBestOffset: 1.0,
            secondBestOffset: -1.0,
            bestVsSecondMargin: 0.25,
            normalizedLumaCorrelation: 0.99,
            rankNormalizedLumaCorrelation: 0.99,
            gradientCorrelation: 0.98,
            multiScaleNCC: 0.97,
            edgeCorrelation: 0.96,
            localContrastCorrelation: 0.95,
            robustConfidence: 0.98,
            sceneBoundaryConsistency: 0.94,
            perWindowOffsets: [],
            offsetDrift: 2.0
        )
        let source = V6SourceIntegrityEvidence(
            duplicatedHDRMatchCount: 0,
            droppedFrameEvidenceCount: 0,
            sdrFPS: 30,
            hdrFPS: 30,
            sdrDurationSeconds: 4.0,
            hdrDurationSeconds: 4.0,
            durationDeltaSeconds: 0,
            sdrDimensions: "32x18",
            hdrDimensions: "32x18",
            aspectRatioDelta: 0,
            aspectRatioMismatchEvidence: false,
            durationMismatchEvidence: false
        )
        let evidence = V6MatcherDiagnostics.makePairEvidence(
            pairPlan: pairPlan, structural: structural, sourceIntegrity: source
        )
        let production = evidence.productionMatcher
        XCTAssertEqual(production.bestOffset, pairPlan.alignment.coarseOffsetSeconds)
        XCTAssertEqual(production.rawMatchCount, pairPlan.alignment.matchedFrameCount)
        XCTAssertEqual(production.acceptedMatchCount, pairPlan.alignment.acceptedFrameCount)
        XCTAssertEqual(
            production.acceptanceRatio,
            Double(pairPlan.alignment.acceptedFrameCount) /
                Double(pairPlan.alignment.matchedFrameCount)
        )
        XCTAssertEqual(production.rawAcceptedMatchCount, pairPlan.alignment.rawAcceptedFrameCount)
        XCTAssertEqual(production.rawAcceptanceRatio, pairPlan.alignment.rawAcceptanceRatio)
        XCTAssertEqual(production.confidenceQuantiles, pairPlan.alignment.confidenceQuantiles)
        XCTAssertEqual(production.acceptedFrameIdentities, pairPlan.alignment.acceptedFrames)
        XCTAssertEqual(
            production.alignmentConfigurationHash,
            pairPlan.alignment.matcherConfigurationHash
        )
        // The experimental robust offset differs deliberately; production
        // identities remain the sealed plan identities and do not move.
        XCTAssertNotEqual(structural.robustBestOffset, production.bestOffset)
        XCTAssertEqual(evidence.structuralDiagnostic.robustBestOffset, 1.0)
        XCTAssertEqual(evidence.productionMatcher.acceptedFrameIdentities, pairPlan.alignment.acceptedFrames)

        // Exercise the real experimental scorer with a degenerate synthetic
        // sequence.  Its tie-breaking offset is intentionally unrelated to
        // the sealed production offset, yet the production identity array is
        // still byte-for-byte unchanged.
        let computedStructural = try V6MatcherDiagnostics.structuralEvidence(
            sdr: prepared.sdrSequence, hdr: prepared.hdrSequence
        )
        XCTAssertNotEqual(computedStructural.robustBestOffset, production.bestOffset)
        XCTAssertEqual(production.acceptedFrameIdentities, pairPlan.alignment.acceptedFrames)
    }

    func testV6MatcherDiagnosticsRejectConsumedHashBeforeMediaOpen() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = root.appendingPathComponent("data_video/manifest-v4.json")
        let manifest = try V4Manifest.load(from: manifestURL)
        let auditURL = root.appendingPathComponent("results/dataset-v4-final.json")
        let audit = try JSONDecoder().decode(
            V4DatasetAuditReport.self, from: Data(contentsOf: auditURL)
        )
        guard let index = manifest.pairs.firstIndex(where: {
            $0.id == "live_9_face_close_3840x2160_15000k"
        }), let auditIndex = audit.pairs.firstIndex(where: {
            $0.id == "live_9_face_close_3840x2160_15000k"
        }), let consumed = V6VirginHoldoutPolicy.consumedAssetPairs["live_8_drawing_3840x2160_15000k"] else {
            throw XCTSkip("V6 manifest/audit fixture unavailable")
        }
        var aliasManifest = manifest
        aliasManifest.pairs[index].id = "fresh-alias"
        var aliasAudit = audit
        aliasAudit.pairs[auditIndex].id = "fresh-alias"
        aliasAudit.pairs[auditIndex].sdrDigest?.sha256 = consumed.sdrSHA256
        aliasAudit.pairs[auditIndex].hdrDigest?.sha256 = consumed.hdrSHA256
        XCTAssertThrowsError(try V6MatcherDiagnostics.validateRecordsBeforeDecode(
            manifest: aliasManifest,
            audit: aliasAudit,
            repositoryRoot: root,
            manifestURL: manifestURL
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("consumed V6 holdout"))
        }
    }

    func testV6MatcherDiagnosticsRejectFrozenScopeBeforeMediaOpen() throws {
        let pair = V4PairRecord(
            id: "frozen-only",
            sdr: "frozen.sdr.mp4",
            hdr: "frozen.hdr.mp4",
            source: "fixture",
            license: "fixture",
            expectedRelation: .sameSource,
            split: .frozen,
            virginFrozen: true
        )
        let auditPair = V4PairAudit(
            id: pair.id,
            source: pair.source,
            split: .frozen,
            virginFrozen: true,
            expectedRelation: pair.expectedRelation,
            suitability: .reject,
            status: .invalidMetadata,
            sdrPath: pair.sdr,
            hdrPath: pair.hdr,
            sdrDigest: V4FileDigest(path: pair.sdr, sizeBytes: 1, sha256: String(repeating: "a", count: 64)),
            hdrDigest: V4FileDigest(path: pair.hdr, sizeBytes: 1, sha256: String(repeating: "b", count: 64))
        )
        let audit = V4DatasetAuditReport(
            manifestPath: "repo:data_video/manifest-v4.json",
            manifestSHA256: String(repeating: "c", count: 64),
            pairs: [auditPair],
            diversity: V4DiversityReport(),
            notes: []
        )
        XCTAssertThrowsError(try V6MatcherDiagnostics.validateRecordsBeforeDecode(
            manifest: V4Manifest(pairs: [pair]),
            audit: audit,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository")
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("require Tune/Validation records"))
        }
    }

    func testV6MatcherAccessTelemetryIsDerivedFromOpenedPaths() {
        let frozenPath = "repo:data_video/frozen.sdr.mp4"
        let opened = V6MatcherAccessTelemetry(
            openedMediaPaths: [frozenPath],
            rejectedMediaPaths: [],
            frozenInputPaths: [frozenPath]
        )
        XCTAssertTrue(opened.frozenFilesAccessed)
        let clean = V6MatcherAccessTelemetry(
            openedMediaPaths: ["repo:data_video/tune.sdr.mp4"],
            rejectedMediaPaths: [frozenPath],
            frozenInputPaths: [frozenPath]
        )
        XCTAssertFalse(clean.frozenFilesAccessed)
        XCTAssertEqual(clean.rejectedMediaPaths, [frozenPath])
    }

    func testV6RealLive9PlanMaterializationMatchesPreflightExactly() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = root.appendingPathComponent("data_video/manifest-v4.json")
        let manifest = try V4Manifest.load(from: manifestURL)
        guard let pair = manifest.pairs.first(where: {
            $0.id == "live_9_face_close_3840x2160_15000k" && $0.split == .tune
        }) else {
            return XCTFail("real Tune live_9 pair is missing")
        }
        let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
        let record = PairRecord(
            id: pair.id,
            sdr: urls.sdr.path,
            hdr: urls.hdr.path,
            license: pair.license,
            source: pair.source,
            expectedRelation: pair.expectedRelation.legacyRelation(),
            notes: pair.notes,
            split: pair.split
        )
        var configuration = V2SearchConfiguration()
        configuration.searchSeed = V4CalibrationConfiguration().searchSeed
        configuration.maxFramesPerScene = V4CalibrationConfiguration().maxFramesPerScene
        configuration.referenceTargetPeakNits = V4CalibrationConfiguration().referenceTargetPeakNits
        configuration.alignmentSearchThreshold = 0
        let hashes = try V6PreparedEvaluationPlanBuilder.makeInputHashes(
            records: [record], manifestURL: manifestURL
        )

        let preflightRepository = V2PreparedRepository(
            manifestURL: manifestURL,
            device: device,
            configuration: configuration,
            acceptedConfidenceThreshold: V4CalibrationConfiguration().confidenceThreshold
        )
        _ = try await preflightRepository.prepare(records: [record])
        let plan = try preflightRepository.sealPreparedEvaluationPlan(
            records: [record], inputHashes: hashes, scope: "TUNE_VALIDATION"
        )
        let preflightIdentities = plan.pairPlan(for: record.id)?.alignment.acceptedFrames ?? []

        let entryRepository = V2PreparedRepository(
            manifestURL: manifestURL,
            device: device,
            configuration: configuration,
            acceptedConfidenceThreshold: V4CalibrationConfiguration().confidenceThreshold
        )
        let entry = try await entryRepository.materialize(
            records: [record], using: plan, inputHashes: hashes
        )
        let entryIdentities = entry.first?.matches.map(
            V6PreparedEvaluationPlanBuilder.frameIdentity
        ) ?? []
        XCTAssertEqual(preflightIdentities, entryIdentities)
        XCTAssertGreaterThan(preflightIdentities.count, 0)
    }

    func testV6PreparedPlanRejectsNonPortableManifestPaths() throws {
        let prepared = try makePreparedDiagnosticPair(values: [0.20, 0.80])
        let manifest = V4Manifest(pairs: [V4PairRecord(
            id: prepared.record.id,
            sdr: "/tmp/sdr.mp4",
            hdr: "tune/hdr.mp4",
            source: "test",
            license: "test",
            expectedRelation: .sameSource,
            split: .tune
        )])
        XCTAssertThrowsError(try V6PreparedEvaluationPlanBuilder.makePlan(
            preparedPairs: [prepared],
            manifest: manifest,
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            inputHashes: [prepared.record.id: V6InputHashes(
                sdrSHA256: String(repeating: "e", count: 64),
                hdrSHA256: String(repeating: "f", count: 64)
            )]
        ))
    }

    func testV6PreparedPlanLoaderRequiresMatchingExplicitSidecar() throws {
        let prepared = try makePreparedDiagnosticPair(values: [0.20, 0.80])
        let plan = try V6PreparedEvaluationPlanBuilder.makePlan(
            preparedPairs: [prepared],
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            inputHashes: [prepared.record.id: V6InputHashes(
                sdrSHA256: String(repeating: "1", count: 64),
                hdrSHA256: String(repeating: "2", count: 64)
            )]
        )
        let artifact = try V6PreparedEvaluationPlanArtifact(plan: plan)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v6-plan-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifactURL = directory.appendingPathComponent("prepared.json")
        let sidecarURL = directory.appendingPathComponent("prepared.sha256")
        try V6PreparedEvaluationPlanHasher.canonicalData(artifact).write(to: artifactURL)
        try Data((String(repeating: "0", count: 64) + "\n").utf8).write(to: sidecarURL)
        XCTAssertThrowsError(try V6PreparedEvaluationPlanLoader.loadSealed(from: artifactURL))
        try Data((artifact.planSHA256 + "\n").utf8).write(to: sidecarURL)
        XCTAssertEqual(
            try V6PreparedEvaluationPlanLoader.loadSealed(from: artifactURL).planSHA256,
            artifact.planSHA256
        )
    }

    func testV6TemporalPlanPreservesLegacyConfidenceGate() throws {
        let base = try makePreparedDiagnosticPair(values: Array(repeating: 0.50, count: 16))
        let temporalFrames = base.matches.map { item in
            PreparedTemporalFrame(
                sdr: item.sdr,
                reference: item.reference,
                sourceLuma: item.sourceLuma,
                confidence: 0.59,
                hdrIndex: item.hdr.index,
                hdrSequencePosition: item.hdr.sequencePosition,
                hdrTimestampSeconds: item.hdr.descriptor.timestampSeconds
            )
        }
        let window = PreparedTemporalWindow(
            sceneID: "scene-0",
            frames: temporalFrames,
            decision: V4TemporalWindowPolicy.v5.decision(actualDecodedFrameCount: temporalFrames.count),
            startSeconds: 0,
            offsetSeconds: 0
        )
        let prepared = PreparedPair(
            record: base.record,
            sdrSequence: base.sdrSequence,
            hdrSequence: base.hdrSequence,
            referenceTransfer: base.referenceTransfer,
            alignment: base.alignment,
            scenes: base.scenes,
            matches: base.matches,
            temporalWindows: [window]
        )
        let plan = try V6PreparedEvaluationPlanBuilder.makePlan(
            preparedPairs: [prepared],
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            inputHashes: [prepared.record.id: V6InputHashes(
                sdrSHA256: String(repeating: "3", count: 64),
                hdrSHA256: String(repeating: "4", count: 64)
            )]
        )
        XCTAssertEqual(plan.pairs.first?.temporalWindows.first?.decision.accepted, true)
        XCTAssertEqual(plan.pairs.first?.temporalWindows.first?.evaluationAccepted, false)
        XCTAssertEqual(
            try V6PreparedEvaluationEntry.temporalWindows(prepared: prepared, plan: plan).count,
            0
        )
    }

    func testV6InstalledPlanPreventsIndependentPreparation() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let prepared = try makePreparedDiagnosticPair(values: [0.20, 0.80])
        let hashes = V6InputHashes(
            sdrSHA256: String(repeating: "5", count: 64),
            hdrSHA256: String(repeating: "6", count: 64)
        )
        let plan = try V6PreparedEvaluationPlanBuilder.makePlan(
            preparedPairs: [prepared],
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            inputHashes: [prepared.record.id: hashes]
        )
        let repository = V2PreparedRepository(
            manifestURL: URL(fileURLWithPath: "/tmp/not-opened.json"),
            device: device,
            configuration: V2SearchConfiguration()
        )
        _ = try repository.installPreparedEvaluationPlan(
            plan,
            records: [prepared.record],
            inputHashes: [prepared.record.id: hashes]
        )
        do {
            _ = try await repository.prepare(records: [prepared.record])
            XCTFail("independent preparation unexpectedly ran after plan installation")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cannot prepare a new pair"))
        }
    }

    func testV6RepositoryAcceptsVirginFrozenPlanScopeReadOnly() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let prepared = try makePreparedDiagnosticPair(values: [0.20, 0.80])
        let hashes = V6InputHashes(
            sdrSHA256: String(repeating: "7", count: 64),
            hdrSHA256: String(repeating: "8", count: 64)
        )
        let plan = try V6PreparedEvaluationPlanBuilder.makePlan(
            preparedPairs: [prepared],
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository"),
            inputHashes: [prepared.record.id: hashes],
            scope: "VIRGIN_FROZEN"
        )
        let repository = V2PreparedRepository(
            manifestURL: URL(fileURLWithPath: "/tmp/not-opened.json"),
            device: device,
            configuration: V2SearchConfiguration(),
            acceptedConfidenceThreshold: 0.60
        )
        XCTAssertNoThrow(try repository.installPreparedEvaluationPlan(
            plan,
            records: [prepared.record],
            inputHashes: [prepared.record.id: hashes]
        ))
    }

    func testV6ConsumedHoldoutsAreAssetHashBound() {
        let consumed = V6VirginHoldoutPolicy.consumedAssetPairs["live_8_drawing_3840x2160_15000k"]
        XCTAssertNotNil(consumed)
        XCTAssertTrue(V6VirginHoldoutPolicy.isExcluded(
            pairID: "renamed-pair",
            sdrSHA256: consumed?.sdrSHA256,
            hdrSHA256: String(repeating: "f", count: 64)
        ))
        XCTAssertTrue(V6VirginHoldoutPolicy.isExcluded(
            pairID: "another-name",
            sdrSHA256: String(repeating: "e", count: 64),
            hdrSHA256: consumed?.hdrSHA256
        ))
        XCTAssertFalse(V6VirginHoldoutPolicy.isExcluded(
            pairID: "new-v6-holdout",
            sdrSHA256: String(repeating: "a", count: 64),
            hdrSHA256: String(repeating: "b", count: 64)
        ))
    }

    func testV4RunRequiresExplicitPreparedPlanBeforeManifestAccess() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let runner = try CalibrationV4Runner(
            manifestURL: URL(fileURLWithPath: "/tmp/manifest-must-not-be-read.json"),
            outputDirectory: FileManager.default.temporaryDirectory,
            device: device
        )
        do {
            _ = try await runner.run()
            XCTFail("v4-run unexpectedly accepted a missing PreparedEvaluationPlan")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("--prepared-plan"))
        }
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

    func testProductionAndOfflineProcessorBurstTemporalParity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        var configuration = HDRConfiguration.calibratedV2
        configuration.toneCurveRevision = .sceneRelativeV4
        let production = try HDRProcessor(device: device, configuration: configuration)
        let offline = try HDRCoreOfflineEvaluator(device: device, configuration: configuration)
        production.clearTemporalHistory()
        offline.clearTemporalHistory()
        production.temporalTraceEnabled = true
        production.clearTemporalTrace()
        let values: [SIMD3<Float>] = [
            SIMD3(repeating: 0.04), SIMD3(repeating: 0.72), SIMD3(repeating: 0.11)
        ]
        var commandBuffers: [MTLCommandBuffer] = []
        for (index, value) in values.enumerated() {
            let pixelBuffer = try makeCalibrationBGRA(width: 32, height: 18, rgb: value)
            let commandBuffer = try production.makeCommandBuffer()
            _ = try production.process(
                pixelBuffer: pixelBuffer,
                timestamp: CMTime(seconds: Double(index) / 30, preferredTimescale: 600),
                commandBuffer: commandBuffer
            )
            commandBuffer.commit()
            commandBuffers.append(commandBuffer)
        }
        for commandBuffer in commandBuffers {
            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error)
        }

        let submissions = production.temporalSubmissionTrace
        let completions = production.temporalCompletionTrace
        XCTAssertEqual(submissions.count, values.count)
        XCTAssertEqual(completions.count, values.count)
        XCTAssertEqual(production.temporalSubmissionSequence, UInt64(values.count))
        XCTAssertEqual(production.lastCompletedTemporalSequence, UInt64(values.count))

        let neutralShadow = offline.sceneShadowCoordinates
        var temporalByVersion: [UInt64: Float] = [0: offline.temporalAdaptation]
        var shadowByVersion: [UInt64: (Float, Float, Bool)] = [0: (neutralShadow.floor, neutralShadow.top, neutralShadow.valid)]
        for (index, value) in values.enumerated() {
            let pixelBuffer = try makeCalibrationBGRA(width: 32, height: 18, rgb: value)
            _ = try offline.evaluate(
                pixelBuffer: pixelBuffer,
                timestampSeconds: Double(index) / 30,
                configuration: configuration
            )
            let version = UInt64(index + 1)
            temporalByVersion[version] = offline.temporalAdaptation
            let shadow = offline.sceneShadowCoordinates
            shadowByVersion[version] = (shadow.floor, shadow.top, shadow.valid)
        }

        var previousTemporalVersion: UInt64 = 0
        var previousSceneVersion: UInt64 = 0
        for trace in submissions {
            XCTAssertLessThan(trace.temporalStateVersionConsumed, trace.submissionSequence)
            XCTAssertLessThan(trace.sceneStateVersionConsumed, trace.submissionSequence)
            XCTAssertGreaterThanOrEqual(trace.temporalStateVersionConsumed, previousTemporalVersion)
            XCTAssertGreaterThanOrEqual(trace.sceneStateVersionConsumed, previousSceneVersion)
            previousTemporalVersion = trace.temporalStateVersionConsumed
            previousSceneVersion = trace.sceneStateVersionConsumed
            let expectedTemporal = try XCTUnwrap(temporalByVersion[trace.temporalStateVersionConsumed])
            let expectedShadow = try XCTUnwrap(shadowByVersion[trace.sceneStateVersionConsumed])
            XCTAssertEqual(trace.temporalAdaptationUsed, expectedTemporal, accuracy: 0.000_001)
            XCTAssertEqual(trace.sceneShadowFloorUsed, expectedShadow.0, accuracy: 0.000_001)
            XCTAssertEqual(trace.sceneShadowTopUsed, expectedShadow.1, accuracy: 0.000_001)
            XCTAssertEqual(trace.sceneStatisticsValidUsed, expectedShadow.2)
        }

        var lastSequence: UInt64 = 0
        var lastTemporalVersion: UInt64 = 0
        var lastSceneVersion: UInt64 = 0
        for trace in completions {
            XCTAssertGreaterThan(trace.submissionSequence, lastSequence)
            XCTAssertGreaterThanOrEqual(trace.temporalStateVersionProduced, lastTemporalVersion)
            XCTAssertGreaterThanOrEqual(trace.sceneStateVersionProduced, lastSceneVersion)
            lastSequence = trace.submissionSequence
            lastTemporalVersion = trace.temporalStateVersionProduced
            lastSceneVersion = trace.sceneStateVersionProduced
        }
    }

    func testOfflineEvaluatorReportsStateAppliedToCurrentFrameBeforeCompletionUpdate() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        var configuration = HDRConfiguration.calibratedV2
        configuration.temporalStability = 0.8
        let evaluator = try HDRCoreOfflineEvaluator(device: device, configuration: configuration)
        evaluator.clearTemporalHistory()

        let dark = try makeCalibrationBGRA(width: 32, height: 18, rgb: SIMD3(repeating: 0.03))
        let first = try evaluator.evaluate(pixelBuffer: dark, timestampSeconds: 0, configuration: configuration)
        let nextFrameState = evaluator.temporalAdaptation
        XCTAssertEqual(first.temporalAdaptationUsed, 1, accuracy: 0.000_001)
        XCTAssertGreaterThan(abs(nextFrameState - first.temporalAdaptationUsed), 0.000_001)

        let bright = try makeCalibrationBGRA(width: 32, height: 18, rgb: SIMD3(repeating: 0.80))
        let second = try evaluator.evaluate(pixelBuffer: bright, timestampSeconds: 1.0 / 30, configuration: configuration)
        XCTAssertEqual(second.temporalAdaptationUsed, nextFrameState, accuracy: 0.000_001)
    }

    func testSparseSpatialEvaluationNeverCarriesTemporalStateBetweenSamples() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let configuration = HDRConfiguration.calibratedV2
        let evaluator = try HDRCoreOfflineEvaluator(device: device, configuration: configuration)
        let dark = try makeCalibrationBGRA(width: 32, height: 18, rgb: SIMD3(repeating: 0.03))
        let bright = try makeCalibrationBGRA(width: 32, height: 18, rgb: SIMD3(repeating: 0.80))

        let first = try evaluator.evaluateSpatiallyIndependent(
            pixelBuffer: dark, timestampSeconds: 0, configuration: configuration
        )
        let second = try evaluator.evaluateSpatiallyIndependent(
            pixelBuffer: bright, timestampSeconds: 10, configuration: configuration
        )
        XCTAssertEqual(first.temporalAdaptationUsed, 1, accuracy: 0.000_001)
        XCTAssertEqual(second.temporalAdaptationUsed, 1, accuracy: 0.000_001)
        XCTAssertEqual(evaluator.temporalAdaptation, 1, accuracy: 0.000_001)
    }

    func testDiagnosticsKeepEqualConfigurationsOnIndependentTemporalHistories() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let prepared = try makePreparedDiagnosticPair(values: [0.03, 0.80, 0.10, 0.65])
        let parameters = CalibrationParameters(configuration: .calibratedV2)
        let engine = V2EvaluationEngine(device: device, weights: V2ObjectiveWeights())
        let diagnostics = try engine.diagnostics(
            preparedPairs: [prepared],
            defaultParameters: parameters,
            v1Parameters: parameters,
            candidateParameters: parameters,
            confidenceThreshold: 0.60
        )
        let curves = [
            diagnostics.luminanceMapping, diagnostics.percentileCurves,
            diagnostics.hueErrorByLuminance, diagnostics.chromaErrorByLuminance,
            diagnostics.saturationRatioByLuminance
        ]
        XCTAssertFalse(curves.flatMap { $0 }.isEmpty)
        for point in curves.flatMap({ $0 }) {
            XCTAssertEqual(point.defaultBaseline, point.calibratedV1, accuracy: 0.000_001)
            XCTAssertEqual(point.defaultBaseline, point.candidateV2, accuracy: 0.000_001)
        }
    }

    func testFileDigestSupportsPortableRepositoryPathsAndLegacyAbsolutePaths() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdr2hdr-digest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let fileURL = temporaryDirectory.appendingPathComponent("media.bin")
        try Data([1, 2, 3]).write(to: fileURL)
        let digest = try V4DatasetIntegrity.digest(url: fileURL)

        if digest.path.hasPrefix("repo:") {
            XCTAssertTrue(digest.path.hasPrefix("repo:tmp"))
            XCTAssertFalse(digest.path.contains("/Volumes/game/sdr2hdr"))
        } else {
            XCTAssertTrue(digest.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        }
        _ = device
    }

    func testCommittedV4EvidenceUsesPortablePathsAndCurrentManifestHash() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = root.appendingPathComponent("data_video/manifest-v4.json")
        let lockURL = root.appendingPathComponent("data_video/dataset-v4-lock.json")
        let auditURL = root.appendingPathComponent("results/dataset-v4-final.json")
        let lock = try JSONDecoder().decode(V4DatasetLock.self, from: Data(contentsOf: lockURL))
        let audit = try JSONDecoder().decode(V4DatasetAuditReport.self, from: Data(contentsOf: auditURL))

        XCTAssertEqual(lock.manifestSHA256, try V4DatasetIntegrity.manifestSHA256(url: manifestURL))
        XCTAssertTrue(lock.files.allSatisfy { $0.path.hasPrefix("repo:") })
        XCTAssertTrue(audit.manifestPath.hasPrefix("repo:"))
        XCTAssertTrue(audit.pairs.allSatisfy { pair in
            pair.sdrPath.hasPrefix("repo:") && pair.hdrPath.hasPrefix("repo:") &&
                pair.sdrDigest?.path.hasPrefix("repo:") == true &&
                pair.hdrDigest?.path.hasPrefix("repo:") == true &&
                pair.sdrMetadata?.path.hasPrefix("repo:") == true &&
                pair.hdrMetadata?.path.hasPrefix("repo:") == true
        })
    }

    func testPreFrozenGatesBlockHoldoutForFailuresAndNotMeasuredStates() {
        var runtimeFailure = V4PreFrozenGateResult(runtime: .pass)
        runtimeFailure.runtime = .fail
        XCTAssertFalse(runtimeFailure.canOpenVirginFrozen)

        var notMeasuredCoverage = V4PreFrozenGateResult(transferCoverage: .pass)
        notMeasuredCoverage.transferCoverage = .notMeasured
        XCTAssertFalse(notMeasuredCoverage.canOpenVirginFrozen)

        let allPass = V4PreFrozenGateResult(
            datasetIntegrity: .pass, identifiability: .pass, validationOverall: .pass,
            validationShadow: .pass, validationTemporal: .pass,
            transferCoverage: .pass, pairCoverage: .pass, familyCoverage: .pass, runtime: .pass
        )
        XCTAssertTrue(allPass.canOpenVirginFrozen)
    }

    func testPreFrozenGateDecodesLegacyArtifactsWithoutPairCoverageFailClosed() throws {
        let legacy = """
        {
          "datasetIntegrity":"PASS",
          "identifiability":"PASS",
          "validationOverall":"PASS",
          "validationShadow":"PASS",
          "validationTemporal":"PASS",
          "transferCoverage":"PASS",
          "familyCoverage":"PASS",
          "runtime":"PASS"
        }
        """
        let decoded = try JSONDecoder().decode(V4PreFrozenGateResult.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.pairCoverage, .notMeasured)
        XCTAssertFalse(decoded.canOpenVirginFrozen)
    }

    func testCoveragePolicyRejectsMissingOrUnregisteredSubgroups() {
        XCTAssertEqual(
            V4CoveragePolicy.status(observed: ["PQ"], required: ["PQ", "HLG"]),
            .fail
        )
        XCTAssertEqual(V4CoveragePolicy.status(observed: ["PQ"], required: []), .notMeasured)
        let configuration = V4CalibrationConfiguration()
        XCTAssertEqual(configuration.requiredTransfersBySplit[.frozen], ["HLG", "PQ"])
        XCTAssertEqual(configuration.requiredFrozenTransfers, ["HLG", "PQ"])
        XCTAssertTrue(configuration.requiredFrozenFamilies.isEmpty)
        XCTAssertEqual(configuration.minimumVirginFrozenPairs, 3)
        XCTAssertEqual(configuration.minimumDistinctFrozenFamilies, 2)
        XCTAssertFalse(configuration.frozenCoveragePolicy.familyStatus(observed: ["K-Choreo"]).rawValue == "PASS")
        XCTAssertEqual(configuration.frozenCoveragePolicy.familyStatus(observed: ["LIVE", "SoleMates"]), .pass)
        XCTAssertEqual(configuration.frozenCoveragePolicy.pairStatus(count: 2), .fail)
        XCTAssertEqual(configuration.frozenCoveragePolicy.pairStatus(count: 3), .pass)

        let twoFamiliesButTwoPairs = V4PreFrozenGateResult(
            datasetIntegrity: .pass, identifiability: .pass, validationOverall: .pass,
            validationShadow: .pass, validationTemporal: .pass, transferCoverage: .pass,
            pairCoverage: .fail, familyCoverage: .pass, runtime: .pass
        )
        XCTAssertFalse(twoFamiliesButTwoPairs.canOpenVirginFrozen)
        XCTAssertEqual(twoFamiliesButTwoPairs.familyCoverage, .pass)
        XCTAssertEqual(twoFamiliesButTwoPairs.pairCoverage, .fail)
    }

    func testHistoricalFrozenObjectiveProvenanceConsumesOnlyEvaluatedPairIDs() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdr2hdr-provenance-\(UUID().uuidString)")
        let results = base.appendingPathComponent("results")
        let dataset = base.appendingPathComponent("dataset")
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let frozen: [String: Any] = [
            "calibratedV2": ["videos": [["pairID": "night-biking"]]],
            "calibratedV4": ["videos": [["pairID": "night-biking"]]]
        ]
        let frozenData = try JSONSerialization.data(withJSONObject: frozen)
        try frozenData.write(to: results.appendingPathComponent("data-video-v4-frozen.json"))
        let ledger = """
        {"version":"test","entries":[
          {"pairID":"manual-consumed","status":"CONSUMED_HOLDOUT","evidence":"prior exposed metric"},
          {"pairID":"still-virgin","status":"VIRGIN_FROZEN","evidence":"no objective"}
        ]}
        """
        try Data(ledger.utf8).write(to: dataset.appendingPathComponent("holdout-provenance-v5.json"))

        let audit = V4HistoricalObjectiveProvenance.audit(
            repositoryRoot: base, outputDirectory: results
        )
        XCTAssertTrue(audit.consumedSet.contains("night-biking"))
        XCTAssertTrue(audit.consumedSet.contains("manual-consumed"))
        XCTAssertFalse(audit.consumedSet.contains("still-virgin"))
        XCTAssertFalse(audit.evidence(for: "night-biking").isEmpty)
    }

    func testNewHLGHoldoutDiscoveryUsesMetadataAndNormalizedSourceIdentity() {
        let sdrURL = URL(fileURLWithPath: "/tmp/My_Scene_SDR_BT709_2160p.mp4")
        let hdrURL = URL(fileURLWithPath: "/tmp/My-Scene-HLG-BT2100-10bit.mov")
        XCTAssertEqual(
            V4NewHLGHoldoutAuditor.normalizedSourceKey(sdrURL),
            V4NewHLGHoldoutAuditor.normalizedSourceKey(hdrURL)
        )

        var hlg = makeV4Metadata(primaries: "bt2020", transfer: "arib-std-b67", bitDepth: 10)
        hlg.matrix = "bt2020nc"
        hlg.colorRange = "tv"
        XCTAssertTrue(V4NewHLGHoldoutAuditor.isHLGReference(hlg))
        hlg.bitDepth = 8
        XCTAssertFalse(V4NewHLGHoldoutAuditor.isHLGReference(hlg))
        hlg.bitDepth = 10
        hlg.colorPrimaries = "bt709"
        XCTAssertFalse(V4NewHLGHoldoutAuditor.isHLGReference(hlg))
    }

    func testRegisteredVirginHLGAuditorValidatesHashBoundEvidenceFailClosed() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdr2hdr-registered-virgin-\(UUID().uuidString)")
        let candidate = base.appendingPathComponent("candidate")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let manifestURL = base.appendingPathComponent("manifest-v4.json")
        let sdrURL = candidate.appendingPathComponent("sdr.mp4")
        let hdrURL = candidate.appendingPathComponent("hdr.mp4")
        try Data("synthetic-sdr".utf8).write(to: sdrURL)
        try Data("synthetic-hdr".utf8).write(to: hdrURL)
        let sdrDigest = try V4DatasetIntegrity.digest(url: sdrURL)
        let hdrDigest = try V4DatasetIntegrity.digest(url: hdrURL)
        let identities = (100..<114).map { "n:\($0)" }
        let decodedFrames = 2_688
        let evidence: [String: Any] = [
            "verdict": "PAIR_VALID_VIRGIN",
            "temporalReadiness": "CONTIGUOUS_TEMPORAL_READY",
            "objectiveUse": ["consumed": false, "consumedAtUTC": NSNull(), "consumptionPurpose": NSNull()],
            "pair": ["provider": "DVB Project", "family": "DVB Live-Linear"],
            "assets": [
                "sdr": ["path": sdrURL.path, "sha256": sdrDigest.sha256, "bytes": 13],
                "hdr": ["path": hdrURL.path, "sha256": hdrDigest.sha256, "bytes": 13]
            ],
            "contiguousRun": [
                "startSegment": 100, "endSegment": 113, "segmentCount": 14,
                "durationSeconds": 53.76, "noGaps": true
            ],
            "directDashCaptureEvidence": [
                "sdr": ["segment_identities": identities],
                "hdr": ["segment_identities": identities]
            ],
            "fullDecodeEvidence": [
                "sdr_decoded_frames": decodedFrames,
                "hdr_decoded_frames": decodedFrames,
                "expected_frames_from_contiguous_run": decodedFrames,
                "decoded_frame_counts_exactly_equal": true,
                "segment_identity_arrays_exactly_equal": true,
                "errors": []
            ],
            "streamEvidence": [
                "sdr_fps": 50,
                "hdr_fps": 50,
                "decoded_keyframe_vui": [
                    "sdr": [
                        "keyframe_count": 14,
                        "values": [
                            "color_primaries": ["bt709"],
                            "color_transfer": ["bt709"],
                            "color_space": ["bt709"]
                        ]
                    ],
                    "hdr": [
                        "keyframe_count": 14,
                        "values": [
                            "color_primaries": ["bt2020"],
                            "color_transfer": ["arib-std-b67"],
                            "color_space": ["bt2020nc"]
                        ]
                    ]
                ]
            ],
            "alignmentEvidence": [
                "best_offset_frames": 0,
                "drift_frames": 0,
                "aligned_overlap_frames": decodedFrames,
                "temporal": ["mean_rho": 0.99, "edge_rho": 0.99, "std_rho": 0.99],
                "spatial": ["median": 0.99, "p10": 0.98],
                "thresholds": [
                    "mean_spearman_min": 0.94,
                    "edge_spearman_min": 0.88,
                    "std_spearman_min": 0.78,
                    "spatial_median_min": 0.72,
                    "spatial_p10_min": 0.25,
                    "max_drift_frames": 2,
                    "min_aligned_frames": 2_500
                ],
                "errors": []
            ]
        ]
        let evidenceURL = candidate.appendingPathComponent("VIRGIN_PAIR_VALID.json")
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]).write(to: evidenceURL)
        let evidenceHash = try V4DatasetIntegrity.sha256(url: evidenceURL)

        let pair = V4PairRecord(
            id: "dvb-test", sdr: "candidate/sdr.mp4", hdr: "candidate/hdr.mp4",
            source: "DVB Project", license: "test", expectedRelation: .sameMaster,
            contentCategory: ["animation"], contentFamily: "DVB Live-Linear",
            referenceTransfer: "arib-std-b67", referencePrimaries: "bt2020",
            split: .frozen, virginFrozen: true, group: "dvb-test",
            objectiveEvaluated: false, consumed: false,
            virginEvidence: V4VirginEvidenceReference(
                validationManifest: "candidate/VIRGIN_PAIR_VALID.json",
                validationManifestSHA256: evidenceHash,
                sdrSHA256: sdrDigest.sha256,
                hdrSHA256: hdrDigest.sha256
            )
        )
        try V4Manifest(pairs: [pair]).validate(relativeTo: manifestURL)
        let smoke = V4DecodeSmoke(
            attempted: true, firstFrame: true, middleFrame: true, lastFrame: true, decodedSampleCount: 3
        )
        let alignment = V4AlignmentSummary(
            sampledFrames: 40, matchedFrames: 40, rejectedFrames: 0, matchRatio: 1,
            meanConfidence: 0.99, medianConfidence: 0.99, p10Confidence: 0.98,
            p50Confidence: 0.99, p90Confidence: 1, confidenceAtLeast60: 1,
            confidenceAtLeast70: 1, confidenceAtLeast80: 1,
            estimatedTimeOffsetSeconds: 0, offsetVariance: 0,
            spatialChecks: ["synthetic"], status: "ALIGNED"
        )
        let audited = V4PairAudit(
            id: pair.id, source: pair.source, split: .frozen, virginFrozen: true,
            expectedRelation: .sameMaster, suitability: .mainCalibration, status: .accepted,
            sdrPath: pair.sdr, hdrPath: pair.hdr, sdrDigest: sdrDigest, hdrDigest: hdrDigest,
            sdrMetadata: makeV4Metadata(primaries: "bt709", transfer: "bt709", bitDepth: 8),
            hdrMetadata: makeV4Metadata(primaries: "bt2020", transfer: "arib-std-b67", bitDepth: 10),
            sdrTransferFamily: "SDR", hdrTransferFamily: "HLG",
            sdrReferenceValid: true, hdrReferenceValid: true,
            sdrDecode: smoke, hdrDecode: smoke, alignment: alignment
        )

        let accepted = V4NewHLGHoldoutAuditor.auditRegisteredManifestPair(
            manifestPair: pair, datasetPair: audited, manifestURL: manifestURL, objectivelyConsumed: false
        )
        XCTAssertTrue(accepted.accepted)
        XCTAssertEqual(accepted.objectiveHistory, "NO_PRIOR_FROZEN_OBJECTIVE_EVIDENCE")
        XCTAssertTrue(accepted.provenanceStatus.contains("ASSET_SHA_MATCH"))

        var consumed = pair
        consumed.consumed = true
        XCTAssertThrowsError(try V4Manifest(pairs: [consumed]).validate(relativeTo: manifestURL))
        let rejected = V4NewHLGHoldoutAuditor.auditRegisteredManifestPair(
            manifestPair: consumed, datasetPair: audited, manifestURL: manifestURL, objectivelyConsumed: false
        )
        XCTAssertFalse(rejected.accepted)
        XCTAssertFalse(rejected.rejectionReasons.isEmpty)
    }

    func testFrozenCoverageEligibilityRejectsNonAcceptedAuditEvidence() {
        let smoke = V4DecodeSmoke(
            attempted: true, firstFrame: true, middleFrame: true, lastFrame: true, decodedSampleCount: 3
        )
        let aligned = V4AlignmentSummary(
            sampledFrames: 8, matchedFrames: 8, rejectedFrames: 0, matchRatio: 1,
            meanConfidence: 0.9, medianConfidence: 0.9, p10Confidence: 0.8,
            p50Confidence: 0.9, p90Confidence: 0.95,
            confidenceAtLeast60: 1, confidenceAtLeast70: 1, confidenceAtLeast80: 1,
            status: "ALIGNED"
        )
        let eligible = V4PairAudit(
            id: "eligible-hlg", source: "test", split: .frozen, virginFrozen: true,
            expectedRelation: .sameSource, suitability: .mainCalibration, status: .accepted,
            sdrPath: "repo:sdr", hdrPath: "repo:hdr", sdrReferenceValid: true, hdrReferenceValid: true,
            sdrDecode: smoke, hdrDecode: smoke, alignment: aligned
        )
        XCTAssertTrue(V4CoverageAuditEligibility.isEligible(eligible))

        var rejected = eligible
        rejected.status = .alignmentUnreliable
        XCTAssertFalse(V4CoverageAuditEligibility.isEligible(rejected))
        rejected = eligible
        rejected.suitability = .conditional
        XCTAssertFalse(V4CoverageAuditEligibility.isEligible(rejected))
        rejected = eligible
        rejected.hdrDecode = V4DecodeSmoke(attempted: true)
        XCTAssertFalse(V4CoverageAuditEligibility.isEligible(rejected))
    }

    func testTemporalWindowPolicyHasExplicitBoundaryReasonsAndSupport() {
        let policy = V4TemporalWindowPolicy.v5
        let full = policy.decision(actualDecodedFrameCount: 16)
        XCTAssertTrue(full.accepted)
        XCTAssertTrue(full.fullLength)
        XCTAssertEqual(full.acceptanceReason, .fullTargetLength)
        XCTAssertEqual(full.measuredFrameCount, 15)

        let short15 = policy.decision(actualDecodedFrameCount: 15)
        XCTAssertTrue(short15.accepted)
        XCTAssertFalse(short15.fullLength)
        XCTAssertEqual(short15.acceptanceReason, .validShortWindowAboveMinimum)

        let short11 = policy.decision(actualDecodedFrameCount: 11)
        XCTAssertTrue(short11.accepted)
        XCTAssertEqual(short11.acceptanceReason, .validShortWindowAboveMinimum)

        let minimum = policy.decision(actualDecodedFrameCount: 8)
        XCTAssertTrue(minimum.accepted)
        XCTAssertEqual(minimum.measuredFrameCount, 7)

        let below = policy.decision(actualDecodedFrameCount: 7)
        XCTAssertFalse(below.accepted)
        XCTAssertEqual(below.acceptanceReason, .rejectedBelowMinimum)
        XCTAssertFalse(policy.decision(actualDecodedFrameCount: 0).accepted)
    }

    func testTemporalWindowEvidenceCarriesDecisionAndReason() throws {
        let evidence = V4TemporalWindowEvidence(
            sceneID: "interview-scene",
            requestedFrameCount: 16,
            preparedSDRFrameCount: 11,
            preparedHDRFrameCount: 11,
            validContiguousFrameCount: 11,
            startSeconds: 0,
            error: nil
        )
        XCTAssertEqual(evidence.targetFrameCount, 16)
        XCTAssertEqual(evidence.minimumRequiredFrameCount, 8)
        XCTAssertEqual(evidence.actualDecodedFrameCount, 11)
        XCTAssertEqual(evidence.warmupFrameCount, 1)
        XCTAssertEqual(evidence.measuredFrameCount, 10)
        XCTAssertTrue(evidence.accepted)
        XCTAssertEqual(evidence.acceptanceReason, "VALID_SHORT_WINDOW_ABOVE_MINIMUM")
        let decoded = try JSONDecoder().decode(
            V4TemporalWindowEvidence.self,
            from: JSONEncoder().encode(evidence)
        )
        XCTAssertEqual(decoded, evidence)
    }

    func testCorrectnessPassRequiresRequiredExecutedCheck() throws {
        let pass = V4CorrectnessCheck(
            id: "required", required: true, executed: true, status: "PASS",
            evidence: V4CorrectnessEvidence(summary: "measured", numerical: ["maxAbsoluteError": 0])
        )
        XCTAssertTrue(pass.required && pass.executed && pass.status == "PASS")
        let notRun = V4CorrectnessCheck(
            id: "not-run", required: true, executed: false, status: "PASS",
            evidence: V4CorrectnessEvidence(summary: "not actually measured")
        )
        XCTAssertFalse(notRun.executed && notRun.status == "PASS")
        let encoded = try JSONEncoder().encode(notRun)
        let decoded = try JSONDecoder().decode(V4CorrectnessCheck.self, from: encoded)
        XCTAssertFalse(decoded.executed)
        XCTAssertEqual(decoded.status, "PASS")
    }

    func testCandidateFreezeGuardRejectsDirtyTreeAndAllowsCleanTree() {
        XCTAssertThrowsError(try V4CandidateFreezeGuard.requireClean(workingTreeDirty: true))
        XCTAssertNoThrow(try V4CandidateFreezeGuard.requireClean(workingTreeDirty: false))
        XCTAssertEqual(V4CandidateFreezeGuard.status(workingTreeDirty: true), .fail)
        XCTAssertEqual(V4CandidateFreezeGuard.status(workingTreeDirty: false), .pass)
        let experimentGuard = V4FrozenExperimentGuard()
        XCTAssertThrowsError(try experimentGuard.finalizeCandidate(workingTreeDirty: true))
        XCTAssertNoThrow(try experimentGuard.finalizeCandidate(workingTreeDirty: false))
        XCTAssertNoThrow(try experimentGuard.openVirginFrozenOnce())
    }

    func testTemporalStateIsolationResetsOnlyWhenConfigurationChanges() {
        XCTAssertTrue(V2TemporalStateIsolation.requiresReset(previousConfigurationKey: nil, currentConfigurationKey: "v2"))
        XCTAssertFalse(V2TemporalStateIsolation.requiresReset(previousConfigurationKey: "v2", currentConfigurationKey: "v2"))
        XCTAssertTrue(V2TemporalStateIsolation.requiresReset(previousConfigurationKey: "v2", currentConfigurationKey: "v4"))
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
            "Sources/HDRCalibration/FrameIO.swift", "Sources/HDRCalibration/Evaluation.swift",
            "Sources/HDRCalibration/CorrectnessReview.swift", "Sources/HDRCalibration/V2Runner.swift",
            "Sources/HDRCalibration/V5Preflight.swift", "Sources/HDRCalibration/PreparedEvaluationPlan.swift"
        ]
        for path in required { try Data(path.utf8).write(to: root.appendingPathComponent(path)) }
        let before = try V4SourceHasher.sourceHash(repositoryRoot: root)
        try Data("changed".utf8).write(to: root.appendingPathComponent("Sources/HDRCalibration/V4Calibration.swift"))
        let after = try V4SourceHasher.sourceHash(repositoryRoot: root)
        XCTAssertNotEqual(before, after)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/HDRCalibration/V4Calibration.swift"))
        XCTAssertThrowsError(try V4SourceHasher.sourceHash(repositoryRoot: root))

        let executable = root.appendingPathComponent("calibrator.bin")
        try Data("binary-v1".utf8).write(to: executable)
        let executableBefore = try V4SourceHasher.executableHash(url: executable)
        try Data("binary-v2".utf8).write(to: executable)
        let executableAfter = try V4SourceHasher.executableHash(url: executable)
        XCTAssertNotEqual(executableBefore, executableAfter)
        XCTAssertEqual(
            V4CodeIdentityPolicy.status(executableHash: executableAfter, workingTreeDirty: false),
            .pass
        )
        XCTAssertEqual(
            V4CodeIdentityPolicy.status(executableHash: executableAfter, workingTreeDirty: true),
            .fail
        )
        XCTAssertEqual(
            V4CodeIdentityPolicy.status(executableHash: nil, workingTreeDirty: false),
            .notMeasured
        )
    }

    func testV4AlignmentPolicyRejectsSparseHighConfidenceSurvivor() {
        let sparse = V4AlignmentSummary(
            sampledFrames: 40, matchedFrames: 1, rejectedFrames: 39,
            matchRatio: 0.025, meanConfidence: 0.99, medianConfidence: 0.99,
            p10Confidence: 0.99, p50Confidence: 0.99, p90Confidence: 0.99,
            confidenceAtLeast60: 0.025, confidenceAtLeast70: 0.025,
            confidenceAtLeast80: 0.025, status: "ALIGNED"
        )
        XCTAssertEqual(
            V4AlignmentPolicy.status(
                sampledFrames: sparse.sampledFrames,
                matchedFrames: sparse.matchedFrames,
                medianConfidence: sparse.medianConfidence,
                p10Confidence: sparse.p10Confidence
            ),
            "REJECT"
        )
        XCTAssertFalse(V4AlignmentPolicy.supportsMainCalibration(sparse))

        let complete = V4AlignmentSummary(
            sampledFrames: 40, matchedFrames: 36, rejectedFrames: 4,
            matchRatio: 0.9, meanConfidence: 0.86, medianConfidence: 0.88,
            p10Confidence: 0.74, p50Confidence: 0.88, p90Confidence: 0.96,
            confidenceAtLeast60: 0.9, confidenceAtLeast70: 0.85,
            confidenceAtLeast80: 0.7, status: "ALIGNED"
        )
        XCTAssertTrue(V4AlignmentPolicy.supportsMainCalibration(complete))
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
        XCTAssertEqual(V4PromotionGateMachine.verdict(pass), .incompleteEvaluation)
        pass.hardSafety = .fail
        XCTAssertEqual(V4PromotionGateMachine.verdict(pass), .keepV2)
        pass.hardSafety = .pass; pass.frozen = .fail; pass.runtime = .fail
        XCTAssertEqual(V4PromotionGateMachine.verdict(pass), .virginFrozenFail)
    }

    func testV4RuntimeGateUsesMeasuredLatencyAndRejectsInvalidEvidence() {
        var thresholds = V4RuntimeThresholds()
        thresholds.measuredFrames = 120
        thresholds.absoluteToleranceMilliseconds = 0
        thresholds.gpuP50RelativeTolerance = 0.10
        thresholds.gpuP95RelativeTolerance = 0.10
        thresholds.cpuP95RelativeTolerance = 0.20
        let baseline = V4RuntimeMeasurement(
            gpuP50Milliseconds: 2.0, gpuP95Milliseconds: 2.5, gpuP99Milliseconds: 3.0,
            cpuSubmissionP50Milliseconds: 0.20, cpuSubmissionP95Milliseconds: 0.30, cpuSubmissionP99Milliseconds: 0.40
        )
        let passing = V4RuntimeMeasurement(
            gpuP50Milliseconds: 2.1, gpuP95Milliseconds: 2.7, gpuP99Milliseconds: 3.5,
            cpuSubmissionP50Milliseconds: 0.21, cpuSubmissionP95Milliseconds: 0.35, cpuSubmissionP99Milliseconds: 0.50
        )
        XCTAssertEqual(V4RuntimeGate.status(baseline: baseline, candidate: passing, thresholds: thresholds).0, .pass)

        var regressing = passing
        regressing.gpuP95Milliseconds = 3.0
        XCTAssertEqual(V4RuntimeGate.status(baseline: baseline, candidate: regressing, thresholds: thresholds).0, .fail)

        var invalid = passing
        invalid.gpuP50Milliseconds = .nan
        XCTAssertEqual(V4RuntimeGate.status(baseline: baseline, candidate: invalid, thresholds: thresholds).0, .notMeasured)

        var unordered = passing
        unordered.gpuP95Milliseconds = unordered.gpuP50Milliseconds - 0.1
        XCTAssertEqual(V4RuntimeGate.status(baseline: baseline, candidate: unordered, thresholds: thresholds).0, .notMeasured)

        var invalidThresholds = thresholds
        invalidThresholds.gpuP95RelativeTolerance = -0.01
        XCTAssertEqual(V4RuntimeGate.status(baseline: baseline, candidate: passing, thresholds: invalidThresholds).0, .notMeasured)
    }

    func testV4RuntimeBenchmarkCollectsRealGPUAndCPUSamples() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        var configuration = V4CalibrationConfiguration()
        var thresholds = V4RuntimeThresholds()
        thresholds.width = 32
        thresholds.height = 18
        thresholds.warmupFrames = 1
        thresholds.measuredFrames = 4
        thresholds.gpuP50RelativeTolerance = 10
        thresholds.gpuP95RelativeTolerance = 10
        thresholds.cpuP95RelativeTolerance = 10
        thresholds.absoluteToleranceMilliseconds = 10
        configuration.safety.runtime = thresholds
        let runner = try CalibrationV4Runner(
            manifestURL: URL(fileURLWithPath: "/tmp/not-read-by-runtime-test.json"),
            outputDirectory: FileManager.default.temporaryDirectory,
            configuration: configuration,
            device: device
        )
        let parameters = CalibrationParameters(configuration: .calibratedV2)
        let result = try runner.benchmarkRuntime(baseline: parameters, candidate: parameters)
        XCTAssertEqual(result.status, .pass)
        XCTAssertEqual(result.measuredFrames, thresholds.measuredFrames)
        XCTAssertTrue(result.baseline?.isValid == true)
        XCTAssertTrue(result.candidate?.isValid == true)
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

    private func makePreparedDiagnosticPair(
        values: [Float],
        id: String = "diagnostic"
    ) throws -> PreparedPair {
        var samples: [FrameSample] = []
        var matches: [PreparedMatch] = []
        for (index, value) in values.enumerated() {
            let time = Double(index) / 30
            let pixelBuffer = try makeCalibrationBGRA(
                width: 32, height: 18, rgb: SIMD3(repeating: value)
            )
            let descriptorGrid = Array(repeating: value, count: 64 * 36)
            let descriptor = FrameDescriptorBuilder.make(
                timestamp: CMTime(seconds: time, preferredTimescale: 600),
                lumaGrid: descriptorGrid
            )
            let sample = FrameSample(
                index: index, sequencePosition: index,
                timestamp: CMTime(seconds: time, preferredTimescale: 600),
                pixelBuffer: pixelBuffer, descriptor: descriptor,
                lumaGrid: descriptorGrid
            )
            samples.append(sample)
            let match = MatchedFrame(
                sdrIndex: index, hdrIndex: index,
                sdrSequencePosition: index, hdrSequencePosition: index,
                sdrTimeSeconds: time, hdrTimeSeconds: time, confidence: 1
            )
            matches.append(PreparedMatch(
                match: match, sdr: sample, hdr: sample,
                reference: ReferenceFrame(
                    timestampSeconds: time, width: 32, height: 18,
                    rgbNits: Array(repeating: SIMD3(repeating: value * 1_000), count: 32 * 18)
                ),
                sourceLuma: Array(repeating: value, count: 32 * 18)
            ))
        }
        let sequence = FrameSequence(
            url: URL(fileURLWithPath: "/tmp/diagnostic.mp4"),
            pixelFormat: kCVPixelFormatType_32BGRA,
            width: 32, height: 18, nominalFrameRate: 30,
            durationSeconds: Double(values.count) / 30, samples: samples
        )
        return PreparedPair(
            record: PairRecord(
                id: id, sdr: "sdr", hdr: "hdr",
                license: "test", source: "test", split: .tune
            ),
            sdrSequence: sequence,
            hdrSequence: sequence,
            referenceTransfer: .pq,
            alignment: AlignmentResult(
                status: "ALIGNED", coarseOffsetSeconds: 0,
                matches: matches.map(\.match), rejectedFrames: 0,
                medianConfidence: 1
            ),
            scenes: [SceneRange(
                id: "scene-0", startSequencePosition: 0,
                endSequencePosition: max(values.count - 1, 0), tags: []
            )],
            matches: matches,
            temporalWindows: []
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
