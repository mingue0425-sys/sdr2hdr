import CryptoKit
import Foundation

/// V6 freezes preparation decisions separately from objective metrics.  The
/// plan is deliberately metadata-only: it records which already decoded frame
/// identities are accepted, while pixel buffers remain in the in-process
/// preparation session.  A later evaluator may materialize only these explicit
/// identities; it may not run alignment, scene selection, or representative
/// frame selection again.
public struct V6PreparationConfiguration: Codable, Hashable, Sendable {
    public let version: String
    public let maxFramesPerScene: Int
    public let maxDecodedFrames: Int
    public let proxyWidth: Int
    public let alignmentConfidenceThreshold: Double
    public let acceptedConfidenceThreshold: Double
    public let temporalFramesPerSecond: Double
    public let temporalTargetFrameCount: Int
    public let temporalMinimumFrameCount: Int
    public let temporalWarmupFrameCount: Int
    public let referenceTargetPeakNits: Float
    public let allowHLGModel: Bool
    public let sdrPixelFormat: UInt32
    public let hdrPixelFormat: UInt32
    public let frameDecoderPolicy: String
    public let referenceDecoderPolicy: String
    public let pathResolutionPolicy: String
    public let sceneSelectionPolicy: String
    public let temporalSelectionPolicy: String
    public let preparationAlgorithmVersion: String
    public let matcherVersion: String
    public let matcherConfiguration: V6MatcherConfiguration
    public let matcherConfigurationHash: String

    public init(
        version: String = "v6-prepared-evaluation-plan-v3",
        maxFramesPerScene: Int = 8,
        maxDecodedFrames: Int = 128,
        proxyWidth: Int = 320,
        alignmentConfidenceThreshold: Double = 0,
        acceptedConfidenceThreshold: Double = 0.60,
        temporalFramesPerSecond: Double = 30,
        temporalTargetFrameCount: Int = 16,
        temporalMinimumFrameCount: Int = 8,
        temporalWarmupFrameCount: Int = 1,
        referenceTargetPeakNits: Float = 1_000,
        allowHLGModel: Bool = true,
        sdrPixelFormat: UInt32 = CalibrationPixelFormat.sdrNV12,
        hdrPixelFormat: UInt32 = CalibrationPixelFormat.hdrP010,
        frameDecoderPolicy: String = "FrameReader.auto(avfoundation;ffmpeg-fallback)",
        referenceDecoderPolicy: String = "HDRReferenceDecoder.linear-reference-v1",
        pathResolutionPolicy: String = "manifest-resolved-once;repository-relative-plan-paths",
        sceneSelectionPolicy: String = "SceneDetector.v6;sequencePosition-domain",
        temporalSelectionPolicy: String = "anchor=max-confidence;start=anchorTime-0.05;paired-contiguous-window",
        matcherConfiguration: V6MatcherConfiguration = .v6
    ) {
        self.version = version
        self.maxFramesPerScene = maxFramesPerScene
        self.maxDecodedFrames = maxDecodedFrames
        self.proxyWidth = proxyWidth
        self.alignmentConfidenceThreshold = alignmentConfidenceThreshold
        self.acceptedConfidenceThreshold = acceptedConfidenceThreshold
        self.temporalFramesPerSecond = temporalFramesPerSecond
        self.temporalTargetFrameCount = temporalTargetFrameCount
        self.temporalMinimumFrameCount = temporalMinimumFrameCount
        self.temporalWarmupFrameCount = temporalWarmupFrameCount
        self.referenceTargetPeakNits = referenceTargetPeakNits
        self.allowHLGModel = allowHLGModel
        self.sdrPixelFormat = sdrPixelFormat
        self.hdrPixelFormat = hdrPixelFormat
        self.frameDecoderPolicy = frameDecoderPolicy
        self.referenceDecoderPolicy = referenceDecoderPolicy
        self.pathResolutionPolicy = pathResolutionPolicy
        self.sceneSelectionPolicy = sceneSelectionPolicy
        self.temporalSelectionPolicy = temporalSelectionPolicy
        self.preparationAlgorithmVersion = matcherConfiguration.preparationAlgorithmVersion
        self.matcherVersion = matcherConfiguration.matcherVersion
        self.matcherConfiguration = matcherConfiguration
        self.matcherConfigurationHash = (try? matcherConfiguration.canonicalSHA256()) ?? "INVALID"
    }

    public static let v6 = V6PreparationConfiguration()
}

public struct V6InputHashes: Codable, Hashable, Sendable {
    public let sdrSHA256: String
    public let hdrSHA256: String

    public init(sdrSHA256: String, hdrSHA256: String) {
        self.sdrSHA256 = sdrSHA256.lowercased()
        self.hdrSHA256 = hdrSHA256.lowercased()
    }
}

public struct V6PreparedFrameIdentity: Codable, Hashable, Sendable {
    public let sdrSourceFrameIndex: Int
    public let sdrSequencePosition: Int
    public let sdrTimestampSeconds: Double
    public let hdrSourceFrameIndex: Int
    public let hdrSequencePosition: Int
    public let hdrTimestampSeconds: Double
    public let confidence: Double

    public init(
        sdrSourceFrameIndex: Int,
        sdrSequencePosition: Int,
        sdrTimestampSeconds: Double,
        hdrSourceFrameIndex: Int,
        hdrSequencePosition: Int,
        hdrTimestampSeconds: Double,
        confidence: Double
    ) {
        self.sdrSourceFrameIndex = sdrSourceFrameIndex
        self.sdrSequencePosition = sdrSequencePosition
        self.sdrTimestampSeconds = sdrTimestampSeconds
        self.hdrSourceFrameIndex = hdrSourceFrameIndex
        self.hdrSequencePosition = hdrSequencePosition
        self.hdrTimestampSeconds = hdrTimestampSeconds
        self.confidence = confidence
    }

    public var sequenceKey: String {
        "\(sdrSequencePosition):\(hdrSequencePosition)"
    }
}

public struct V6ScenePlan: Codable, Hashable, Sendable {
    public let id: String
    public let startSequencePosition: Int
    public let endSequencePosition: Int
    public let tags: [String]
    public let acceptedSequencePositions: [Int]

    public init(
        id: String,
        startSequencePosition: Int,
        endSequencePosition: Int,
        tags: [String],
        acceptedSequencePositions: [Int]
    ) {
        self.id = id
        self.startSequencePosition = startSequencePosition
        self.endSequencePosition = endSequencePosition
        self.tags = tags
        self.acceptedSequencePositions = acceptedSequencePositions
    }
}

public struct V6TemporalWindowPlan: Codable, Hashable, Sendable {
    public let sceneID: String
    public let startSeconds: Double
    public let offsetSeconds: Double
    public let decision: V4TemporalWindowDecision
    /// The legacy objective gate additionally required the anchor confidence
    /// to satisfy the configured 0.60 threshold.  Seal that decision once so
    /// evaluator entry cannot weaken or recompute it.
    public let evaluationAccepted: Bool
    public let frames: [V6PreparedFrameIdentity]

    public init(
        sceneID: String,
        startSeconds: Double,
        offsetSeconds: Double,
        decision: V4TemporalWindowDecision,
        evaluationAccepted: Bool,
        frames: [V6PreparedFrameIdentity]
    ) {
        self.sceneID = sceneID
        self.startSeconds = startSeconds
        self.offsetSeconds = offsetSeconds
        self.decision = decision
        self.evaluationAccepted = evaluationAccepted
        self.frames = frames
    }
}

public struct V6DecodeMetadata: Codable, Hashable, Sendable {
    public let sdrWidth: Int
    public let sdrHeight: Int
    public let sdrNominalFrameRate: Double
    public let sdrDurationSeconds: Double
    public let hdrWidth: Int
    public let hdrHeight: Int
    public let hdrDurationSeconds: Double
    public let decodedSDRFrameCount: Int
    public let decodedHDRFrameCount: Int
    public let referenceTransfer: ReferenceTransfer
    public let sdrPixelFormat: UInt32
    public let hdrPixelFormat: UInt32

    public init(
        sdrWidth: Int,
        sdrHeight: Int,
        sdrNominalFrameRate: Double,
        sdrDurationSeconds: Double,
        hdrWidth: Int,
        hdrHeight: Int,
        hdrDurationSeconds: Double,
        decodedSDRFrameCount: Int,
        decodedHDRFrameCount: Int,
        referenceTransfer: ReferenceTransfer,
        sdrPixelFormat: UInt32,
        hdrPixelFormat: UInt32
    ) {
        self.sdrWidth = sdrWidth
        self.sdrHeight = sdrHeight
        self.sdrNominalFrameRate = sdrNominalFrameRate
        self.sdrDurationSeconds = sdrDurationSeconds
        self.hdrWidth = hdrWidth
        self.hdrHeight = hdrHeight
        self.hdrDurationSeconds = hdrDurationSeconds
        self.decodedSDRFrameCount = decodedSDRFrameCount
        self.decodedHDRFrameCount = decodedHDRFrameCount
        self.referenceTransfer = referenceTransfer
        self.sdrPixelFormat = sdrPixelFormat
        self.hdrPixelFormat = hdrPixelFormat
    }
}

public struct V6AlignmentPlan: Codable, Hashable, Sendable {
    public let matcherConfigurationHash: String
    public let status: String
    public let coarseOffsetSeconds: Double
    public let secondBestOffsetSeconds: Double
    public let bestVersusSecondMargin: Double
    public let perWindowOffsets: [Double]
    public let offsetDriftSeconds: Double
    public let matchedFrameCount: Int
    public let rawAcceptedFrameCount: Int
    public let rawAcceptanceRatio: Double
    public let rejectedFrameCount: Int
    public let medianConfidence: Double
    public let confidenceQuantiles: V6ConfidenceQuantiles
    public let acceptedFrameCount: Int
    /// Every raw alignment identity is sealed because alignment statistics and
    /// temporal anchoring depend on the complete match set, not only accepted
    /// spatial representatives.
    public let matchedFrames: [V6PreparedFrameIdentity]
    public let acceptedFrames: [V6PreparedFrameIdentity]

    public init(
        matcherConfigurationHash: String,
        status: String,
        coarseOffsetSeconds: Double,
        secondBestOffsetSeconds: Double,
        bestVersusSecondMargin: Double,
        perWindowOffsets: [Double],
        offsetDriftSeconds: Double,
        matchedFrameCount: Int,
        rawAcceptedFrameCount: Int,
        rawAcceptanceRatio: Double,
        rejectedFrameCount: Int,
        medianConfidence: Double,
        confidenceQuantiles: V6ConfidenceQuantiles,
        acceptedFrameCount: Int,
        matchedFrames: [V6PreparedFrameIdentity],
        acceptedFrames: [V6PreparedFrameIdentity]
    ) {
        self.matcherConfigurationHash = matcherConfigurationHash
        self.status = status
        self.coarseOffsetSeconds = coarseOffsetSeconds
        self.secondBestOffsetSeconds = secondBestOffsetSeconds
        self.bestVersusSecondMargin = bestVersusSecondMargin
        self.perWindowOffsets = perWindowOffsets
        self.offsetDriftSeconds = offsetDriftSeconds
        self.matchedFrameCount = matchedFrameCount
        self.rawAcceptedFrameCount = rawAcceptedFrameCount
        self.rawAcceptanceRatio = rawAcceptanceRatio
        self.rejectedFrameCount = rejectedFrameCount
        self.medianConfidence = medianConfidence
        self.confidenceQuantiles = confidenceQuantiles
        self.acceptedFrameCount = acceptedFrameCount
        self.matchedFrames = matchedFrames
        self.acceptedFrames = acceptedFrames
    }
}

public struct V6PreparedPairPlan: Codable, Hashable, Sendable {
    public let pairID: String
    public let split: DatasetSplit
    public let sdrPath: String
    public let hdrPath: String
    public let inputHashes: V6InputHashes
    public let decode: V6DecodeMetadata
    public let alignment: V6AlignmentPlan
    public let scenes: [V6ScenePlan]
    public let temporalWindows: [V6TemporalWindowPlan]

    public init(
        pairID: String,
        split: DatasetSplit,
        sdrPath: String,
        hdrPath: String,
        inputHashes: V6InputHashes,
        decode: V6DecodeMetadata,
        alignment: V6AlignmentPlan,
        scenes: [V6ScenePlan],
        temporalWindows: [V6TemporalWindowPlan]
    ) {
        self.pairID = pairID
        self.split = split
        self.sdrPath = sdrPath
        self.hdrPath = hdrPath
        self.inputHashes = inputHashes
        self.decode = decode
        self.alignment = alignment
        self.scenes = scenes
        self.temporalWindows = temporalWindows
    }
}

public struct PreparedEvaluationPlan: Codable, Hashable, Sendable {
    public let schemaVersion: String
    public let scope: String
    public let pairOrder: [String]
    public let preparation: V6PreparationConfiguration
    public let pairs: [V6PreparedPairPlan]

    public init(
        schemaVersion: String = "v6-prepared-evaluation-plan-v3",
        scope: String,
        pairOrder: [String],
        preparation: V6PreparationConfiguration,
        pairs: [V6PreparedPairPlan]
    ) {
        self.schemaVersion = schemaVersion
        self.scope = scope
        self.pairOrder = pairOrder
        self.preparation = preparation
        self.pairs = pairs
    }

    public func pairPlan(for pairID: String) -> V6PreparedPairPlan? {
        pairs.first { $0.pairID == pairID }
    }
}

public struct V6PreparedEvaluationPlanArtifact: Codable, Hashable, Sendable {
    public let plan: PreparedEvaluationPlan
    public let planSHA256: String

    public init(plan: PreparedEvaluationPlan) throws {
        self.plan = plan
        self.planSHA256 = try V6PreparedEvaluationPlanHasher.sha256(plan)
    }

    public static func load(from url: URL) throws -> V6PreparedEvaluationPlanArtifact {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func verified() throws -> Bool {
        try V6PreparedEvaluationPlanHasher.sha256(plan) == planSHA256
    }
}

public enum V6PreparedEvaluationPlanLoader {
    /// Load one explicit artifact and its adjacent `.sha256` sidecar.  There is
    /// deliberately no search path, output-directory fallback, or regeneration
    /// behavior here.
    public static func loadSealed(from url: URL) throws -> V6PreparedEvaluationPlanArtifact {
        let artifact = try V6PreparedEvaluationPlanArtifact.load(from: url)
        guard try artifact.verified() else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan artifact hash mismatch"
            )
        }
        let sidecarURL = url.deletingPathExtension().appendingPathExtension("sha256")
        let sidecarHash = try String(contentsOf: sidecarURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sidecarHash == artifact.planSHA256 else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan sidecar hash mismatch"
            )
        }
        return artifact
    }
}

public enum V6PreparedEvaluationPlanHasher {
    public static func canonicalData(_ plan: PreparedEvaluationPlan) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .throw
        return try encoder.encode(plan)
    }

    public static func sha256(_ plan: PreparedEvaluationPlan) throws -> String {
        SHA256.hash(data: try canonicalData(plan))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func canonicalData(_ artifact: V6PreparedEvaluationPlanArtifact) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .throw
        return try encoder.encode(artifact)
    }
}

/// The plan builder is the only place that turns an in-memory `PreparedPair`
/// into a serialized preparation contract.  Both correctness review and the
/// V4/V6 runner use this builder, so accepted frame identities cannot drift
/// between preflight and evaluator entry.
enum V6PreparedEvaluationPlanBuilder {
    /// Validate the immutable contract without opening either media input.
    /// Holdout admission and evaluator entry both call this exact function so
    /// their pair/order/path/hash/config semantics cannot diverge.
    static func validateSealedContract(
        plan: PreparedEvaluationPlan,
        scope: String,
        records: [V4PairRecord],
        inputHashes: [String: V6InputHashes],
        preparation: V6PreparationConfiguration
    ) throws {
        guard plan.schemaVersion == "v6-prepared-evaluation-plan-v3",
              plan.scope == scope,
              plan.preparation == preparation,
              plan.preparation.matcherConfigurationHash ==
                (try plan.preparation.matcherConfiguration.canonicalSHA256()) else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan schema, scope, or preparation configuration mismatch"
            )
        }
        let expectedOrder = records.map(\.id)
        guard Set(plan.pairOrder).count == plan.pairOrder.count,
              plan.pairOrder == expectedOrder,
              plan.pairs.map(\.pairID) == expectedOrder else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan pair IDs or deterministic order mismatch"
            )
        }
        for record in records {
            guard let pair = plan.pairPlan(for: record.id),
                  pair.split == record.split,
                  pair.sdrPath == record.sdr,
                  pair.hdrPath == record.hdr,
                  pair.inputHashes == inputHashes[record.id] else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan manifest or input contract mismatch for \(record.id)"
                )
            }
            for path in [pair.sdrPath, pair.hdrPath] {
                guard !path.hasPrefix("/"),
                      !path.split(separator: "/").contains("..") else {
                    throw CalibrationError.incompleteEvaluation(
                        "PreparedEvaluationPlan contains a non-portable path for \(record.id)"
                    )
                }
            }
            guard validSHA256(pair.inputHashes.sdrSHA256),
                  validSHA256(pair.inputHashes.hdrSHA256),
                  pair.decode.sdrWidth > 0,
                  pair.decode.sdrHeight > 0,
                  pair.decode.hdrWidth > 0,
                  pair.decode.hdrHeight > 0,
                  pair.decode.decodedSDRFrameCount > 0,
                  pair.decode.decodedHDRFrameCount > 0,
                  pair.alignment.matcherConfigurationHash == plan.preparation.matcherConfigurationHash,
                  pair.alignment.matchedFrameCount == pair.alignment.matchedFrames.count,
                  pair.alignment.rawAcceptedFrameCount == pair.alignment.matchedFrames.filter({
                      $0.confidence >= plan.preparation.acceptedConfidenceThreshold
                  }).count,
                  abs(pair.alignment.rawAcceptanceRatio -
                      (pair.alignment.matchedFrames.isEmpty ? 0 :
                        Double(pair.alignment.rawAcceptedFrameCount) /
                            Double(pair.alignment.matchedFrames.count))) <= 1e-12,
                  pair.alignment.offsetDriftSeconds >= 0,
                  !pair.alignment.perWindowOffsets.isEmpty,
                  pair.alignment.acceptedFrameCount == pair.alignment.acceptedFrames.count,
                  pair.alignment.acceptedFrameCount > 0 else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan has invalid decode/alignment evidence for \(record.id)"
                )
            }
            let rawIdentities = Set(pair.alignment.matchedFrames)
            guard pair.alignment.acceptedFrames.allSatisfy(rawIdentities.contains) else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan accepted identities are not contained in raw alignment for \(record.id)"
                )
            }
        }
    }

    static func makePlan(
        preparedPairs: [PreparedPair],
        manifest: V4Manifest? = nil,
        repositoryRoot: URL,
        configuration: V6PreparationConfiguration = .v6,
        inputHashes: [String: V6InputHashes],
        scope: String = "TUNE_VALIDATION"
    ) throws -> PreparedEvaluationPlan {
        let ordered = preparedPairs
        let pairPlans = try ordered.map { prepared in
            try makePairPlan(
                prepared: prepared,
                manifest: manifest,
                repositoryRoot: repositoryRoot,
                configuration: configuration,
                inputHashes: try inputHashesForPair(
                    inputHashes,
                    pairID: prepared.record.id
                )
            )
        }
        return PreparedEvaluationPlan(
            scope: scope,
            pairOrder: ordered.map(\.record.id),
            preparation: configuration,
            pairs: pairPlans
        )
    }

    static func acceptedMatches(
        from prepared: PreparedPair,
        confidenceThreshold: Double
    ) -> [PreparedMatch] {
        prepared.matches
            .filter { $0.match.confidence >= confidenceThreshold }
            .sorted {
                ($0.match.sdrSequencePosition ?? .max) < ($1.match.sdrSequencePosition ?? .max)
            }
    }

    static func makeInputHashes(
        records: [PairRecord],
        manifestURL: URL
    ) throws -> [String: V6InputHashes] {
        var result: [String: V6InputHashes] = [:]
        for record in records {
            let urls = record.resolvedURLs(relativeTo: manifestURL)
            result[record.id] = V6InputHashes(
                sdrSHA256: try V4DatasetIntegrity.sha256(url: urls.sdr),
                hdrSHA256: try V4DatasetIntegrity.sha256(url: urls.hdr)
            )
        }
        return result
    }

    static func makeInputHashes(
        audit: V4DatasetAuditReport
    ) -> [String: V6InputHashes] {
        Dictionary(uniqueKeysWithValues: audit.pairs.compactMap { pair in
            guard let sdr = pair.sdrDigest?.sha256, let hdr = pair.hdrDigest?.sha256 else { return nil }
            return (pair.id, V6InputHashes(sdrSHA256: sdr, hdrSHA256: hdr))
        })
    }

    static func validate(
        plan: PreparedEvaluationPlan,
        preparedPairs: [PreparedPair]
    ) throws {
        let preparedIDs = preparedPairs.map(\.record.id)
        guard Set(plan.pairOrder).count == plan.pairOrder.count,
              plan.pairs.map(\.pairID) == plan.pairOrder,
              preparedIDs == plan.pairOrder else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan pair IDs or deterministic order differ from prepared material"
            )
        }
        for prepared in preparedPairs {
            guard let pairPlan = plan.pairPlan(for: prepared.record.id) else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan is missing \(prepared.record.id)"
                )
            }
            guard validSHA256(pairPlan.inputHashes.sdrSHA256),
                  validSHA256(pairPlan.inputHashes.hdrSHA256) else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan input hashes are not SHA-256 values for " + prepared.record.id
                )
            }
            let accepted = acceptedMatches(
                from: prepared,
                confidenceThreshold: plan.preparation.acceptedConfidenceThreshold
            )
            let expected = pairPlan.alignment.acceptedFrames
            let actual = accepted.map(frameIdentity)
            guard actual == expected else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan accepted frame identities differ for \(prepared.record.id)"
                )
            }
            try validatePairMaterial(
                pairPlan: pairPlan,
                prepared: prepared,
                acceptedIdentities: actual
            )
            guard pairPlan.alignment.acceptedFrameCount == expected.count else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan accepted-frame count is inconsistent for \(prepared.record.id)"
                )
            }
            guard pairPlan.alignment.matchedFrames == prepared.alignment.matches.map(frameIdentity),
                  pairPlan.alignment.matchedFrameCount == pairPlan.alignment.matchedFrames.count else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan raw alignment identities differ for \(prepared.record.id)"
                )
            }
            let actualWindows = prepared.temporalWindows
            guard actualWindows.count == pairPlan.temporalWindows.count else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan temporal-window count differs for \(prepared.record.id)"
                )
            }
            for (window, plannedWindow) in zip(actualWindows, pairPlan.temporalWindows) {
                guard window.sceneID == plannedWindow.sceneID,
                      window.startSeconds == plannedWindow.startSeconds,
                      window.offsetSeconds == plannedWindow.offsetSeconds,
                      window.decision == plannedWindow.decision,
                      plannedWindow.evaluationAccepted == (
                          window.decision.accepted &&
                              (window.frames.first.map {
                                  $0.confidence >= plan.preparation.acceptedConfidenceThreshold
                              } ?? false)
                      ),
                      window.frames.map(temporalFrameIdentity) == plannedWindow.frames else {
                    throw CalibrationError.incompleteEvaluation(
                        "PreparedEvaluationPlan temporal-window identities differ for \(prepared.record.id)"
                    )
                }
            }
        }
    }

    /// Validate the non-selection portion of the plan as well.  This keeps a
    /// caller from presenting the evaluator with a different scene detector,
    /// alignment result, or decode shape while reusing the same accepted
    /// identities.
    static func validatePairMaterial(
        pairPlan: V6PreparedPairPlan,
        prepared: PreparedPair,
        acceptedIdentities: [V6PreparedFrameIdentity]? = nil
    ) throws {
        guard pairPlan.split == prepared.record.split else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan split differs for \(prepared.record.id)"
            )
        }
        let raw = prepared.alignment.matches
        let expectedDecode = V6DecodeMetadata(
            sdrWidth: prepared.sdrSequence.width,
            sdrHeight: prepared.sdrSequence.height,
            sdrNominalFrameRate: prepared.sdrSequence.nominalFrameRate,
            sdrDurationSeconds: prepared.sdrSequence.durationSeconds,
            hdrWidth: prepared.hdrSequence.width,
            hdrHeight: prepared.hdrSequence.height,
            hdrDurationSeconds: prepared.hdrSequence.durationSeconds,
            decodedSDRFrameCount: prepared.sdrSequence.samples.count,
            decodedHDRFrameCount: prepared.hdrSequence.samples.count,
            referenceTransfer: prepared.referenceTransfer,
            sdrPixelFormat: prepared.sdrSequence.pixelFormat,
            hdrPixelFormat: prepared.hdrSequence.pixelFormat
        )
        guard pairPlan.decode == expectedDecode else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan decode metadata differs for \(prepared.record.id)"
            )
        }
        guard pairPlan.alignment.status == prepared.alignment.status,
              pairPlan.alignment.coarseOffsetSeconds == prepared.alignment.coarseOffsetSeconds,
              pairPlan.alignment.secondBestOffsetSeconds ==
                (prepared.alignment.secondBestOffsetSeconds ?? prepared.alignment.coarseOffsetSeconds),
              pairPlan.alignment.bestVersusSecondMargin ==
                (prepared.alignment.bestVersusSecondMargin ?? 0),
              pairPlan.alignment.perWindowOffsets ==
                (prepared.alignment.perWindowOffsets ?? [prepared.alignment.coarseOffsetSeconds]),
              pairPlan.alignment.offsetDriftSeconds ==
                (prepared.alignment.offsetDriftSeconds ?? 0),
              pairPlan.alignment.matcherConfigurationHash ==
                (prepared.alignment.matcherConfigurationHash ?? pairPlan.alignment.matcherConfigurationHash),
              pairPlan.alignment.matchedFrameCount == raw.count,
              pairPlan.alignment.rejectedFrameCount == prepared.alignment.rejectedFrames,
              pairPlan.alignment.medianConfidence == prepared.alignment.medianConfidence,
              pairPlan.alignment.matchedFrames == raw.map(frameIdentity) else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan alignment metadata differs for \(prepared.record.id)"
            )
        }
        let acceptedForScenes = acceptedIdentities ?? pairPlan.alignment.acceptedFrames
        let actualScenes = prepared.scenes.map { scene in
            V6ScenePlan(
                id: scene.id,
                startSequencePosition: scene.startSequencePosition,
                endSequencePosition: scene.endSequencePosition,
                tags: scene.tags,
                acceptedSequencePositions: acceptedForScenes.compactMap(\.sdrSequencePosition)
                    .filter { scene.contains(sequencePosition: $0) }
            )
        }
        guard actualScenes == pairPlan.scenes else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan scene metadata differs for \(prepared.record.id)"
            )
        }
    }

    static func frameIdentity(_ match: PreparedMatch) -> V6PreparedFrameIdentity {
        V6PreparedFrameIdentity(
            sdrSourceFrameIndex: match.match.sdrIndex,
            sdrSequencePosition: match.match.sdrSequencePosition ?? match.sdr.sequencePosition,
            sdrTimestampSeconds: match.match.sdrTimeSeconds,
            hdrSourceFrameIndex: match.match.hdrIndex,
            hdrSequencePosition: match.match.hdrSequencePosition ?? match.hdr.sequencePosition,
            hdrTimestampSeconds: match.match.hdrTimeSeconds,
            confidence: match.match.confidence
        )
    }

    static func frameIdentity(_ match: MatchedFrame) -> V6PreparedFrameIdentity {
        V6PreparedFrameIdentity(
            sdrSourceFrameIndex: match.sdrIndex,
            sdrSequencePosition: match.sdrSequencePosition ?? -1,
            sdrTimestampSeconds: match.sdrTimeSeconds,
            hdrSourceFrameIndex: match.hdrIndex,
            hdrSequencePosition: match.hdrSequencePosition ?? -1,
            hdrTimestampSeconds: match.hdrTimeSeconds,
            confidence: match.confidence
        )
    }

    static func temporalFrameIdentity(_ frame: PreparedTemporalFrame) -> V6PreparedFrameIdentity {
        V6PreparedFrameIdentity(
            sdrSourceFrameIndex: frame.sdr.index,
            sdrSequencePosition: frame.sdr.sequencePosition,
            sdrTimestampSeconds: frame.sdr.descriptor.timestampSeconds,
            hdrSourceFrameIndex: frame.hdrIndex ?? -1,
            hdrSequencePosition: frame.hdrSequencePosition ?? -1,
            hdrTimestampSeconds: frame.hdrTimestampSeconds ?? frame.reference.timestampSeconds,
            confidence: frame.confidence
        )
    }

    private static func makePairPlan(
        prepared: PreparedPair,
        manifest: V4Manifest?,
        repositoryRoot: URL,
        configuration: V6PreparationConfiguration,
        inputHashes: V6InputHashes
    ) throws -> V6PreparedPairPlan {
        let manifestPair = manifest?.pairs.first { $0.id == prepared.record.id }
        // A plan is a repository-portable contract, not a snapshot of the
        // machine that produced it.  Manifest paths are therefore validated
        // before they enter the canonical serialization.  `repo:` aliases
        // are already portable and relative manifest paths remain unchanged.
        let sdrPath = try portableManifestPath(
            manifestPair?.sdr ?? portablePath(prepared.record.sdr, repositoryRoot: repositoryRoot),
            pairID: prepared.record.id,
            role: "SDR"
        )
        let hdrPath = try portableManifestPath(
            manifestPair?.hdr ?? portablePath(prepared.record.hdr, repositoryRoot: repositoryRoot),
            pairID: prepared.record.id,
            role: "HDR"
        )
        let accepted = acceptedMatches(from: prepared, confidenceThreshold: configuration.acceptedConfidenceThreshold)
        let acceptedIdentities = accepted.map(frameIdentity)
        let raw = prepared.alignment.matches
        let rawAcceptedCount = raw.filter {
            $0.confidence >= configuration.acceptedConfidenceThreshold
        }.count
        let rawQuantiles = confidenceQuantiles(raw.map(\.confidence))
        let decode = V6DecodeMetadata(
            sdrWidth: prepared.sdrSequence.width,
            sdrHeight: prepared.sdrSequence.height,
            sdrNominalFrameRate: prepared.sdrSequence.nominalFrameRate,
            sdrDurationSeconds: prepared.sdrSequence.durationSeconds,
            hdrWidth: prepared.hdrSequence.width,
            hdrHeight: prepared.hdrSequence.height,
            hdrDurationSeconds: prepared.hdrSequence.durationSeconds,
            decodedSDRFrameCount: prepared.sdrSequence.samples.count,
            decodedHDRFrameCount: prepared.hdrSequence.samples.count,
            referenceTransfer: prepared.referenceTransfer,
            sdrPixelFormat: prepared.sdrSequence.pixelFormat,
            hdrPixelFormat: prepared.hdrSequence.pixelFormat
        )
        let scenes = prepared.scenes.map { scene in
            V6ScenePlan(
                id: scene.id,
                startSequencePosition: scene.startSequencePosition,
                endSequencePosition: scene.endSequencePosition,
                tags: scene.tags,
                acceptedSequencePositions: accepted.compactMap(\.match.sdrSequencePosition)
                    .filter { scene.contains(sequencePosition: $0) }
            )
        }
        let temporalWindows = prepared.temporalWindows.map { window in
            V6TemporalWindowPlan(
                sceneID: window.sceneID,
                startSeconds: window.startSeconds,
                offsetSeconds: window.offsetSeconds,
                decision: window.decision,
                evaluationAccepted: window.decision.accepted &&
                    (window.frames.first.map {
                        $0.confidence >= configuration.acceptedConfidenceThreshold
                    } ?? false),
                frames: window.frames.map(temporalFrameIdentity)
            )
        }
        return V6PreparedPairPlan(
            pairID: prepared.record.id,
            split: prepared.record.split,
            sdrPath: sdrPath,
            hdrPath: hdrPath,
            inputHashes: inputHashes,
            decode: decode,
            alignment: V6AlignmentPlan(
                matcherConfigurationHash: configuration.matcherConfigurationHash,
                status: prepared.alignment.status,
                coarseOffsetSeconds: prepared.alignment.coarseOffsetSeconds,
                secondBestOffsetSeconds: prepared.alignment.secondBestOffsetSeconds ??
                    prepared.alignment.coarseOffsetSeconds,
                bestVersusSecondMargin: prepared.alignment.bestVersusSecondMargin ?? 0,
                perWindowOffsets: prepared.alignment.perWindowOffsets ??
                    [prepared.alignment.coarseOffsetSeconds],
                offsetDriftSeconds: prepared.alignment.offsetDriftSeconds ?? 0,
                matchedFrameCount: prepared.alignment.matches.count,
                rawAcceptedFrameCount: rawAcceptedCount,
                rawAcceptanceRatio: raw.isEmpty ? 0 : Double(rawAcceptedCount) / Double(raw.count),
                rejectedFrameCount: prepared.alignment.rejectedFrames,
                medianConfidence: prepared.alignment.medianConfidence,
                confidenceQuantiles: prepared.alignment.confidenceQuantiles ?? rawQuantiles,
                acceptedFrameCount: acceptedIdentities.count,
                matchedFrames: raw.map(frameIdentity),
                acceptedFrames: acceptedIdentities
            ),
            scenes: scenes,
            temporalWindows: temporalWindows
        )
    }

    private static func inputHashesForPair(
        _ inputHashes: [String: V6InputHashes],
        pairID: String
    ) throws -> V6InputHashes {
        guard let hashes = inputHashes[pairID] else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan is missing input hashes for " + pairID
            )
        }
        return hashes
    }

    private static func confidenceQuantiles(_ values: [Double]) -> V6ConfidenceQuantiles {
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

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102: return true
            default: return false
            }
        }
    }

    private static func portablePath(_ path: String, repositoryRoot: URL) -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.hasPrefix("/"), !normalized.hasPrefix("~"), !normalized.contains("\\") {
            return normalized
        }
        return V4EvidencePath.portable(URL(fileURLWithPath: path), repositoryRoot: repositoryRoot)
    }

    private static func portableManifestPath(
        _ path: String,
        pairID: String,
        role: String
    ) throws -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw CalibrationError.invalidManifest(
                "PreparedEvaluationPlan " + role + " path is empty for " + pairID
            )
        }
        guard !normalized.hasPrefix("/"),
              !normalized.hasPrefix("~"),
              !normalized.contains("\\") else {
            throw CalibrationError.invalidManifest(
                "PreparedEvaluationPlan " + role + " path is not portable for " + pairID
            )
        }
        let relative = normalized.hasPrefix("repo:") ? String(normalized.dropFirst(5)) : normalized
        guard !relative.split(separator: "/", omittingEmptySubsequences: true).contains("..") else {
            throw CalibrationError.invalidManifest(
                "PreparedEvaluationPlan " + role + " path escapes repository for " + pairID
            )
        }
        return normalized
    }
}

/// A read-only entry point used by the objective evaluator after the Frozen
/// guard.  It validates that the in-memory decoded material is exactly the
/// material described by the preflight plan; it never reruns selection.
enum V6PreparedEvaluationEntry {
    private static func validateMatcherConfiguration(
        plan: PreparedEvaluationPlan,
        pairPlan: V6PreparedPairPlan? = nil
    ) throws {
        guard plan.preparation.matcherConfigurationHash ==
                (try plan.preparation.matcherConfiguration.canonicalSHA256()) else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan matcher configuration hash mismatch at evaluator entry"
            )
        }
        if let pairPlan {
            guard pairPlan.alignment.matcherConfigurationHash ==
                    plan.preparation.matcherConfigurationHash else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan pair matcher configuration hash mismatch at evaluator entry"
                )
            }
        }
    }

    static func validatePairOrder(
        preparedPairs: [PreparedPair],
        plan: PreparedEvaluationPlan
    ) throws {
        try validateMatcherConfiguration(plan: plan)
        let requested = preparedPairs.map(\.record.id)
        let expectedSubset = plan.pairOrder.filter { requested.contains($0) }
        guard requested == expectedSubset else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan pair order differs at evaluator entry"
            )
        }
    }

    static func acceptedMatches(
        prepared: PreparedPair,
        plan: PreparedEvaluationPlan
    ) throws -> [PreparedMatch] {
        guard let pairPlan = plan.pairPlan(for: prepared.record.id) else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan is missing \(prepared.record.id)"
            )
        }
        try validateMatcherConfiguration(plan: plan, pairPlan: pairPlan)
        // Materialize only the identities already sealed by the plan.  This
        // deliberately does not filter, sort, select representatives, or
        // apply a second confidence threshold at evaluator entry.
        let accepted = try pairPlan.alignment.acceptedFrames.map { identity in
            guard let item = prepared.matches.first(where: {
                V6PreparedEvaluationPlanBuilder.frameIdentity($0) == identity
            }) else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan hash/material mismatch for \(prepared.record.id)"
                )
            }
            return item
        }
        guard pairPlan.alignment.acceptedFrameCount == accepted.count,
              !accepted.isEmpty else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan has no accepted matched frames for \(prepared.record.id)"
            )
        }
        try V6PreparedEvaluationPlanBuilder.validatePairMaterial(
            pairPlan: pairPlan,
            prepared: prepared,
            acceptedIdentities: pairPlan.alignment.acceptedFrames
        )
        return accepted
    }

    static func temporalWindows(
        prepared: PreparedPair,
        plan: PreparedEvaluationPlan
    ) throws -> [PreparedTemporalWindow] {
        guard let pairPlan = plan.pairPlan(for: prepared.record.id) else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan is missing \(prepared.record.id)"
            )
        }
        guard prepared.temporalWindows.count == pairPlan.temporalWindows.count else {
            throw CalibrationError.incompleteEvaluation(
                "PreparedEvaluationPlan temporal-window count mismatch for \(prepared.record.id)"
            )
        }
        var result: [PreparedTemporalWindow] = []
        for (window, plannedWindow) in zip(prepared.temporalWindows, pairPlan.temporalWindows) {
            guard window.sceneID == plannedWindow.sceneID,
                  window.startSeconds == plannedWindow.startSeconds,
                  window.offsetSeconds == plannedWindow.offsetSeconds,
                  window.decision == plannedWindow.decision,
                  plannedWindow.evaluationAccepted == (
                      window.decision.accepted &&
                          (window.frames.first.map {
                              $0.confidence >= plan.preparation.acceptedConfidenceThreshold
                          } ?? false)
                  ),
                  window.frames.map(V6PreparedEvaluationPlanBuilder.temporalFrameIdentity) == plannedWindow.frames else {
                throw CalibrationError.incompleteEvaluation(
                    "PreparedEvaluationPlan temporal-window material mismatch for \(prepared.record.id)"
                )
            }
            if plannedWindow.evaluationAccepted {
                result.append(window)
            }
        }
        return result
    }
}
