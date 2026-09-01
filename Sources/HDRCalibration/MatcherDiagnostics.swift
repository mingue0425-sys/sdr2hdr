import Foundation
import Metal

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

public struct V6MatcherWindowEvidence: Codable, Hashable, Sendable {
    public let windowIndex: Int
    public let startSequencePosition: Int
    public let endSequencePosition: Int
    public let bestOffsetSeconds: Double
    public let robustScore: Double
}

/// Evidence copied from the immutable production preparation plan.  These
/// values describe the matcher/alignment result that the evaluator will
/// consume; they are never recomputed from the experimental structural score.
/// `acceptedMatchCount` and `acceptanceRatio` refer to the plan's final
/// accepted representative identity set.  The raw alignment acceptance values
/// are retained separately as `rawAcceptedMatchCount` and
/// `rawAcceptanceRatio`.
public struct V6ProductionMatcherEvidence: Codable, Hashable, Sendable {
    public let bestOffset: Double
    public let rawMatchCount: Int
    public let acceptedMatchCount: Int
    public let acceptanceRatio: Double
    public let rawAcceptedMatchCount: Int
    public let rawAcceptanceRatio: Double
    public let confidenceQuantiles: V6ConfidenceQuantiles
    public let acceptedFrameIdentities: [V6PreparedFrameIdentity]
    public let alignmentConfigurationHash: String

    public init(
        bestOffset: Double,
        rawMatchCount: Int,
        acceptedMatchCount: Int,
        acceptanceRatio: Double,
        rawAcceptedMatchCount: Int = 0,
        rawAcceptanceRatio: Double = 0,
        confidenceQuantiles: V6ConfidenceQuantiles,
        acceptedFrameIdentities: [V6PreparedFrameIdentity],
        alignmentConfigurationHash: String
    ) {
        self.bestOffset = bestOffset
        self.rawMatchCount = rawMatchCount
        self.acceptedMatchCount = acceptedMatchCount
        self.acceptanceRatio = acceptanceRatio
        self.rawAcceptedMatchCount = rawAcceptedMatchCount
        self.rawAcceptanceRatio = rawAcceptanceRatio
        self.confidenceQuantiles = confidenceQuantiles
        self.acceptedFrameIdentities = acceptedFrameIdentities
        self.alignmentConfigurationHash = alignmentConfigurationHash
    }
}

/// Experimental structural evidence.  It is intentionally a different type
/// from `V6ProductionMatcherEvidence`: robust scores can explain a production
/// false negative, but can never alter production acceptance or identity.
public struct V6StructuralDiagnosticEvidence: Codable, Hashable, Sendable {
    public let robustBestOffset: Double
    public let secondBestOffset: Double
    public let bestVsSecondMargin: Double
    public let normalizedLumaCorrelation: Double
    public let rankNormalizedLumaCorrelation: Double
    public let gradientCorrelation: Double
    public let multiScaleNCC: Double
    public let edgeCorrelation: Double
    public let localContrastCorrelation: Double
    public let robustConfidence: Double
    public let sceneBoundaryConsistency: Double
    public let perWindowOffsets: [V6MatcherWindowEvidence]
    public let offsetDrift: Double

    public init(
        robustBestOffset: Double,
        secondBestOffset: Double,
        bestVsSecondMargin: Double,
        normalizedLumaCorrelation: Double,
        rankNormalizedLumaCorrelation: Double,
        gradientCorrelation: Double,
        multiScaleNCC: Double,
        edgeCorrelation: Double,
        localContrastCorrelation: Double,
        robustConfidence: Double,
        sceneBoundaryConsistency: Double,
        perWindowOffsets: [V6MatcherWindowEvidence],
        offsetDrift: Double
    ) {
        self.robustBestOffset = robustBestOffset
        self.secondBestOffset = secondBestOffset
        self.bestVsSecondMargin = bestVsSecondMargin
        self.normalizedLumaCorrelation = normalizedLumaCorrelation
        self.rankNormalizedLumaCorrelation = rankNormalizedLumaCorrelation
        self.gradientCorrelation = gradientCorrelation
        self.multiScaleNCC = multiScaleNCC
        self.edgeCorrelation = edgeCorrelation
        self.localContrastCorrelation = localContrastCorrelation
        self.robustConfidence = robustConfidence
        self.sceneBoundaryConsistency = sceneBoundaryConsistency
        self.perWindowOffsets = perWindowOffsets
        self.offsetDrift = offsetDrift
    }
}

public struct V6SourceIntegrityEvidence: Codable, Hashable, Sendable {
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
    public let aspectRatioMismatchEvidence: Bool
    public let durationMismatchEvidence: Bool

    public init(
        duplicatedHDRMatchCount: Int,
        droppedFrameEvidenceCount: Int,
        sdrFPS: Double,
        hdrFPS: Double,
        sdrDurationSeconds: Double,
        hdrDurationSeconds: Double,
        durationDeltaSeconds: Double,
        sdrDimensions: String,
        hdrDimensions: String,
        aspectRatioDelta: Double,
        aspectRatioMismatchEvidence: Bool,
        durationMismatchEvidence: Bool
    ) {
        self.duplicatedHDRMatchCount = duplicatedHDRMatchCount
        self.droppedFrameEvidenceCount = droppedFrameEvidenceCount
        self.sdrFPS = sdrFPS
        self.hdrFPS = hdrFPS
        self.sdrDurationSeconds = sdrDurationSeconds
        self.hdrDurationSeconds = hdrDurationSeconds
        self.durationDeltaSeconds = durationDeltaSeconds
        self.sdrDimensions = sdrDimensions
        self.hdrDimensions = hdrDimensions
        self.aspectRatioDelta = aspectRatioDelta
        self.aspectRatioMismatchEvidence = aspectRatioMismatchEvidence
        self.durationMismatchEvidence = durationMismatchEvidence
    }
}

/// The diagnostic's access record is produced from the paths that the
/// production preparation session actually opened and the paths rejected by
/// the pre-decode holdout guard.  There is no constant “false” escape hatch.
public struct V6MatcherAccessTelemetry: Codable, Hashable, Sendable {
    public let openedMediaPaths: [String]
    public let rejectedMediaPaths: [String]
    public let frozenInputPaths: [String]
    public let frozenFilesAccessed: Bool

    public init(
        openedMediaPaths: [String],
        rejectedMediaPaths: [String],
        frozenInputPaths: [String]
    ) {
        let opened = Array(Set(openedMediaPaths)).sorted()
        let rejected = Array(Set(rejectedMediaPaths)).sorted()
        let frozen = Array(Set(frozenInputPaths)).sorted()
        self.openedMediaPaths = opened
        self.rejectedMediaPaths = rejected
        self.frozenInputPaths = frozen
        self.frozenFilesAccessed = !Set(opened).intersection(frozen).isEmpty
    }
}

public struct V6MatcherPairEvidence: Codable, Hashable, Sendable {
    public let pairID: String
    public let split: DatasetSplit
    public let productionMatcher: V6ProductionMatcherEvidence
    public let structuralDiagnostic: V6StructuralDiagnosticEvidence
    public let sourceIntegrity: V6SourceIntegrityEvidence

    public init(
        pairID: String,
        split: DatasetSplit,
        productionMatcher: V6ProductionMatcherEvidence,
        structuralDiagnostic: V6StructuralDiagnosticEvidence,
        sourceIntegrity: V6SourceIntegrityEvidence
    ) {
        self.pairID = pairID
        self.split = split
        self.productionMatcher = productionMatcher
        self.structuralDiagnostic = structuralDiagnostic
        self.sourceIntegrity = sourceIntegrity
    }
}

public struct V6MatcherDiagnosticReport: Codable, Sendable {
    public let schemaVersion: String
    public let generatedAtUTC: String
    public let manifestPath: String
    public let frozenFilesAccessed: Bool
    public let accessTelemetry: V6MatcherAccessTelemetry
    public let preparedEvaluationPlanSHA256: String
    public let configuration: V6MatcherEvidenceConfiguration
    public let pairs: [V6MatcherPairEvidence]
}

public enum V6MatcherDiagnostics {
    private struct PreflightContext {
        let records: [V4PairRecord]
        let inputHashes: [String: V6InputHashes]
        let frozenInputPaths: [String]
    }

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

    /// Validate all manifest/audit identities before a media decoder can be
    /// called.  The V6 consumed-holdout policy is the single source of truth
    /// for ID and byte-hash exclusion; missing audit bytes fail closed.
    ///
    /// This internal entry point is intentionally useful to regression tests:
    /// tests can prove a consumed Tune/Validation alias is rejected without
    /// opening a media file.
    static func validateRecordsBeforeDecode(
        manifest: V4Manifest,
        audit: V4DatasetAuditReport,
        repositoryRoot: URL,
        manifestURL: URL? = nil
    ) throws -> [V4PairRecord] {
        let records = manifest.pairs.filter { $0.split == .tune || $0.split == .validation }
        guard !records.isEmpty else {
            throw CalibrationError.incompleteEvaluation("matcher diagnostics require Tune/Validation records")
        }
        let auditByID = try auditRecordsByID(audit)
        for record in records {
            guard record.split == .tune || record.split == .validation,
                  !record.virginFrozen,
                  record.consumed != true,
                  record.objectiveEvaluated != true else {
                throw CalibrationError.incompleteEvaluation(
                    "matcher diagnostics may only open unconsumed Tune/Validation media: \(record.id)"
                )
            }
            guard let audited = auditByID[record.id],
                  audited.split == record.split,
                  normalizedManifestPath(record.sdr, manifestURL: manifestURL,
                                         roots: manifest.roots,
                                         repositoryRoot: repositoryRoot) ==
                    normalizedManifestPath(audited.sdrPath, manifestURL: manifestURL,
                                           roots: manifest.roots,
                                           repositoryRoot: repositoryRoot),
                  normalizedManifestPath(record.hdr, manifestURL: manifestURL,
                                         roots: manifest.roots,
                                         repositoryRoot: repositoryRoot) ==
                    normalizedManifestPath(audited.hdrPath, manifestURL: manifestURL,
                                           roots: manifest.roots,
                                           repositoryRoot: repositoryRoot),
                  let sdrDigest = audited.sdrDigest?.sha256,
                  let hdrDigest = audited.hdrDigest?.sha256,
                  validSHA256(sdrDigest), validSHA256(hdrDigest) else {
                throw CalibrationError.incompleteEvaluation(
                    "matcher diagnostics require complete pre-decode audit hashes for \(record.id)"
                )
            }
            guard !V6VirginHoldoutPolicy.isExcluded(
                pairID: record.id, sdrSHA256: sdrDigest, hdrSHA256: hdrDigest
            ) else {
                throw CalibrationError.incompleteEvaluation(
                    "matcher diagnostics reject consumed V6 holdout identity before media open: \(record.id)"
                )
            }
        }
        return records
    }

    private static func preflight(
        manifest: V4Manifest,
        audit: V4DatasetAuditReport,
        repositoryRoot: URL,
        manifestURL: URL
    ) throws -> PreflightContext {
        let records = try validateRecordsBeforeDecode(
            manifest: manifest, audit: audit, repositoryRoot: repositoryRoot,
            manifestURL: manifestURL
        )
        let auditByID = try auditRecordsByID(audit)
        let inputHashes = Dictionary(uniqueKeysWithValues: records.map { record in
            let audited = auditByID[record.id]!
            return (record.id, V6InputHashes(
                sdrSHA256: audited.sdrDigest!.sha256,
                hdrSHA256: audited.hdrDigest!.sha256
            ))
        })
        let frozenInputPaths = manifest.pairs
            .filter { $0.split == .frozen || $0.virginFrozen }
            .flatMap { pair in
                [normalizedManifestPath(pair.sdr, manifestURL: manifestURL,
                                        roots: manifest.roots,
                                        repositoryRoot: repositoryRoot),
                 normalizedManifestPath(pair.hdr, manifestURL: manifestURL,
                                        roots: manifest.roots,
                                        repositoryRoot: repositoryRoot)]
            }
        return PreflightContext(
            records: records,
            inputHashes: inputHashes,
            frozenInputPaths: frozenInputPaths
        )
    }

    /// Validate the committed audit/lock contract without opening any media
    /// bytes.  This preserves the existing dataset evidence semantics while
    /// keeping the consumed-holdout guard ahead of all decoder work.
    private static func validateAuditLockBeforeDecode(
        manifest: V4Manifest,
        audit: V4DatasetAuditReport,
        lock: V4DatasetLock,
        manifestURL: URL,
        repositoryRoot: URL,
        manifestHash: String
    ) throws {
        guard audit.verdict == .ready,
              audit.version == V4DatasetAuditor.auditEvidenceVersion,
              audit.auditConfigHash == V4DatasetAuditor.auditConfigurationHash,
              lock.manifestSHA256 == manifestHash else {
            throw CalibrationError.incompleteEvaluation(
                "matcher diagnostics require current READY audit and dataset lock evidence"
            )
        }
        let auditByID = try auditRecordsByID(audit)
        for pair in manifest.pairs where pair.split == .tune || pair.split == .validation {
            guard let audited = auditByID[pair.id],
                  let sdr = audited.sdrDigest,
                  let hdr = audited.hdrDigest else {
                throw CalibrationError.incompleteEvaluation(
                    "matcher diagnostics require locked digests before media open: \(pair.id)"
                )
            }
            for digest in [sdr, hdr] {
                let expectedPath = normalizedManifestPath(
                    digest.path, manifestURL: manifestURL,
                    roots: manifest.roots, repositoryRoot: repositoryRoot
                )
                guard let locked = lock.files.first(where: {
                    normalizedManifestPath(
                        $0.path, manifestURL: manifestURL,
                        roots: manifest.roots, repositoryRoot: repositoryRoot
                    ) == expectedPath
                }), locked.sha256.lowercased() == digest.sha256.lowercased(),
                locked.sizeBytes == digest.sizeBytes else {
                    throw CalibrationError.incompleteEvaluation(
                        "matcher diagnostics dataset lock digest mismatch before media open: \(pair.id)"
                    )
                }
            }
        }
    }

    /// Copy production evidence verbatim from the sealed plan.  In
    /// particular, this function never receives an experimental offset or
    /// confidence vector, preventing robust diagnostics from changing the
    /// production accepted set.
    static func productionEvidence(
        from pairPlan: V6PreparedPairPlan
    ) -> V6ProductionMatcherEvidence {
        let alignment = pairPlan.alignment
        return V6ProductionMatcherEvidence(
            bestOffset: alignment.coarseOffsetSeconds,
            rawMatchCount: alignment.matchedFrameCount,
            acceptedMatchCount: alignment.acceptedFrameCount,
            acceptanceRatio: alignment.matchedFrameCount == 0 ? 0 :
                Double(alignment.acceptedFrameCount) / Double(alignment.matchedFrameCount),
            rawAcceptedMatchCount: alignment.rawAcceptedFrameCount,
            rawAcceptanceRatio: alignment.rawAcceptanceRatio,
            confidenceQuantiles: alignment.confidenceQuantiles,
            acceptedFrameIdentities: alignment.acceptedFrames,
            alignmentConfigurationHash: alignment.matcherConfigurationHash
        )
    }

    static func makePairEvidence(
        pairPlan: V6PreparedPairPlan,
        structural: V6StructuralDiagnosticEvidence,
        sourceIntegrity: V6SourceIntegrityEvidence
    ) -> V6MatcherPairEvidence {
        V6MatcherPairEvidence(
            pairID: pairPlan.pairID,
            split: pairPlan.split,
            productionMatcher: productionEvidence(from: pairPlan),
            structuralDiagnostic: structural,
            sourceIntegrity: sourceIntegrity
        )
    }

    /// Run only the experimental structural scorer over already-decoded
    /// sequences.  This is exposed to synthetic tests, but it has no API that
    /// can feed a production acceptance decision.
    static func structuralEvidence(
        sdr: FrameSequence,
        hdr: FrameSequence,
        configuration: V6MatcherEvidenceConfiguration = V6MatcherEvidenceConfiguration()
    ) throws -> V6StructuralDiagnosticEvidence {
        try analyzeStructural(
            pairID: "synthetic-structural-diagnostic",
            sdr: sdr,
            hdr: hdr,
            configuration: configuration
        ).structural
    }

    public static func run(
        manifestURL: URL,
        outputURL: URL,
        configuration: V6MatcherEvidenceConfiguration = V6MatcherEvidenceConfiguration()
    ) async throws -> V6MatcherDiagnosticReport {
        let manifest = try V4Manifest.load(from: manifestURL)
        let repositoryRoot = try V4SourceHasher.repositoryRoot(for: manifestURL)
        let auditURL = repositoryRoot.appendingPathComponent("results/dataset-v4-final.json")
        guard FileManager.default.isReadableFile(atPath: auditURL.path) else {
            throw CalibrationError.incompleteEvaluation(
                "matcher diagnostics require the sealed Tune/Validation dataset audit"
            )
        }
        let audit = try JSONDecoder().decode(
            V4DatasetAuditReport.self, from: Data(contentsOf: auditURL)
        )
        guard !audit.objectiveEvaluated, audit.frozenObjectiveEvaluated.isEmpty else {
            throw CalibrationError.incompleteEvaluation(
                "matcher diagnostics require an objective-free Tune/Validation audit"
            )
        }
        let manifestHash = try V4DatasetIntegrity.sha256(url: manifestURL)
        guard audit.manifestSHA256 == manifestHash else {
            throw CalibrationError.incompleteEvaluation(
                "matcher diagnostics dataset audit manifest hash mismatch"
            )
        }
        let lockURL = manifestURL.deletingLastPathComponent()
            .appendingPathComponent("dataset-v4-lock.json")
        guard FileManager.default.isReadableFile(atPath: lockURL.path) else {
            throw CalibrationError.incompleteEvaluation(
                "matcher diagnostics require the sealed Tune/Validation dataset lock"
            )
        }
        let lock = try JSONDecoder().decode(
            V4DatasetLock.self, from: Data(contentsOf: lockURL)
        )
        try validateAuditLockBeforeDecode(
            manifest: manifest, audit: audit, lock: lock,
            manifestURL: manifestURL, repositoryRoot: repositoryRoot,
            manifestHash: manifestHash
        )
        let context = try preflight(
            manifest: manifest, audit: audit, repositoryRoot: repositoryRoot,
            manifestURL: manifestURL
        )
        let productionMatcherConfiguration = V6MatcherConfiguration(
            acceptedConfidenceThreshold: configuration.acceptanceThreshold
        )
        guard configuration.matcherConfigurationHash ==
                (try productionMatcherConfiguration.canonicalSHA256()),
              configuration.maxDecodedFrames == V6PreparationConfiguration.v6.maxDecodedFrames,
              configuration.proxyWidth == V6PreparationConfiguration.v6.proxyWidth else {
            throw CalibrationError.incompleteEvaluation(
                "matcher diagnostic configuration is not the sealed production V6 configuration"
            )
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CalibrationError.decodeFailed("Metal device unavailable for production preparation")
        }
        var searchConfiguration = V2SearchConfiguration()
        searchConfiguration.maxFramesPerScene = 8
        searchConfiguration.alignmentSearchThreshold = 0
        searchConfiguration.referenceTargetPeakNits = 1_000
        let repository = V2PreparedRepository(
            manifestURL: manifestURL,
            device: device,
            configuration: searchConfiguration,
            acceptedConfidenceThreshold: configuration.acceptanceThreshold
        )
        let productionRecords = context.records.map { pair -> PairRecord in
            let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
            return PairRecord(
                id: pair.id, sdr: urls.sdr.path, hdr: urls.hdr.path,
                license: pair.license, source: pair.source,
                expectedRelation: pair.expectedRelation.legacyRelation(),
                notes: pair.notes, split: pair.split
            )
        }
        var prepared: [PreparedPair] = []
        var openedPaths: [String] = []
        for record in productionRecords {
            // The V6 preflight above has already checked ID and byte identity.
            // Record paths only after a successful production preparation, so
            // the report describes actual opened media rather than assumptions.
            let value = try await repository.prepare(records: [record])
            guard let pair = value.first else {
                throw CalibrationError.incompleteEvaluation(
                    "production preparation returned no pair for \(record.id)"
                )
            }
            prepared.append(pair)
            openedPaths.append(V4EvidencePath.portable(
                pair.sdrSequence.url, repositoryRoot: repositoryRoot
            ))
            openedPaths.append(V4EvidencePath.portable(
                pair.hdrSequence.url, repositoryRoot: repositoryRoot
            ))
        }
        let preparedPlan = try repository.sealPreparedEvaluationPlan(
            records: productionRecords,
            inputHashes: context.inputHashes,
            scope: "TUNE_VALIDATION"
        )
        try V6PreparedEvaluationPlanBuilder.validate(
            plan: preparedPlan, preparedPairs: prepared
        )
        let preparedPlanHash = try V6PreparedEvaluationPlanHasher.sha256(preparedPlan)
        var evidence: [V6MatcherPairEvidence] = []
        for pair in prepared {
            guard let pairPlan = preparedPlan.pairPlan(for: pair.record.id) else {
                throw CalibrationError.incompleteEvaluation(
                    "production PreparedEvaluationPlan is missing \(pair.record.id)"
                )
            }
            let structural = try analyzeStructural(
                pairID: pair.record.id,
                sdr: pair.sdrSequence,
                hdr: pair.hdrSequence,
                configuration: configuration
            )
            evidence.append(makePairEvidence(
                pairPlan: pairPlan,
                structural: structural.structural,
                sourceIntegrity: structural.sourceIntegrity
            ))
        }
        let telemetry = V6MatcherAccessTelemetry(
            openedMediaPaths: openedPaths,
            rejectedMediaPaths: [],
            frozenInputPaths: context.frozenInputPaths
        )
        let portableManifest = V4EvidencePath.portable(
            manifestURL, repositoryRoot: repositoryRoot
        )
        let report = V6MatcherDiagnosticReport(
            schemaVersion: "v6-matcher-diagnostic-v3",
            generatedAtUTC: ISO8601DateFormatter().string(from: Date()),
            manifestPath: portableManifest,
            frozenFilesAccessed: telemetry.frozenFilesAccessed,
            accessTelemetry: telemetry,
            preparedEvaluationPlanSHA256: preparedPlanHash,
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

    private static func analyzeStructural(
        pairID: String,
        sdr: FrameSequence,
        hdr: FrameSequence,
        configuration: V6MatcherEvidenceConfiguration
    ) throws -> (structural: V6StructuralDiagnosticEvidence, sourceIntegrity: V6SourceIntegrityEvidence) {
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
        return (
            structural: V6StructuralDiagnosticEvidence(
                robustBestOffset: best.offset,
                secondBestOffset: second.offset,
                bestVsSecondMargin: best.score - second.score,
                normalizedLumaCorrelation: aggregate.luma,
                rankNormalizedLumaCorrelation: aggregate.rank,
                gradientCorrelation: aggregate.gradient,
                multiScaleNCC: aggregate.multiScale,
                edgeCorrelation: aggregate.edge,
                localContrastCorrelation: aggregate.localContrast,
                robustConfidence: aggregate.robust,
                sceneBoundaryConsistency: sceneConsistency,
                perWindowOffsets: windows,
                offsetDrift: drift
            ),
            sourceIntegrity: V6SourceIntegrityEvidence(
                duplicatedHDRMatchCount: duplicateCount,
                droppedFrameEvidenceCount: dropped,
                sdrFPS: sdr.nominalFrameRate,
                hdrFPS: hdr.nominalFrameRate,
                sdrDurationSeconds: sdr.durationSeconds,
                hdrDurationSeconds: hdr.durationSeconds,
                durationDeltaSeconds: abs(sdr.durationSeconds - hdr.durationSeconds),
                sdrDimensions: "\(sdr.width)x\(sdr.height)",
                hdrDimensions: "\(hdr.width)x\(hdr.height)",
                aspectRatioDelta: aspectDelta,
                aspectRatioMismatchEvidence: aspectDelta > 0.02,
                durationMismatchEvidence: abs(sdr.durationSeconds - hdr.durationSeconds) > 0.25
            )
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

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...70, 97...102: return true
            default: return false
            }
        }
    }

    private static func auditRecordsByID(
        _ audit: V4DatasetAuditReport
    ) throws -> [String: V4PairAudit] {
        var result: [String: V4PairAudit] = [:]
        for pair in audit.pairs {
            guard result.updateValue(pair, forKey: pair.id) == nil else {
                throw CalibrationError.incompleteEvaluation(
                    "matcher diagnostics audit contains duplicate pair id: \(pair.id)"
                )
            }
        }
        return result
    }

    /// Normalize a manifest or audit path for identity comparison without
    /// touching the referenced media.  Root aliases are resolved as pure path
    /// arithmetic, then converted to the repository's portable `repo:` form.
    private static func normalizedManifestPath(
        _ path: String,
        manifestURL: URL?,
        roots: [String: String],
        repositoryRoot: URL
    ) -> String {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("repo:") {
            return normalized
        }
        let base = (manifestURL?.deletingLastPathComponent() ?? repositoryRoot)
            .standardizedFileURL
        if let separator = normalized.firstIndex(of: ":") {
            let alias = String(normalized[..<separator])
            if let root = roots[alias] {
                let relative = String(normalized[normalized.index(after: separator)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let rootURL = root.hasPrefix("/")
                    ? URL(fileURLWithPath: root)
                    : base.appendingPathComponent(root)
                return V4EvidencePath.portable(
                    rootURL.appendingPathComponent(relative),
                    repositoryRoot: repositoryRoot
                )
            }
        }
        if normalized.hasPrefix("/") {
            return V4EvidencePath.portable(
                URL(fileURLWithPath: normalized), repositoryRoot: repositoryRoot
            )
        }
        return V4EvidencePath.portable(
            base.appendingPathComponent(normalized), repositoryRoot: repositoryRoot
        )
    }
}
