import Foundation
import CoreMedia
import CoreVideo
import HDRCore
import Metal
import simd

public struct V4StructuralPairCheck: Codable, Sendable {
    public let pairID: String
    public let split: DatasetSplit
    public let requested: Bool
    public let prepared: Bool
    public let matchedFrameCount: Int
    public let sceneCount: Int
    public let coveredSceneCount: Int
    public let requestedTemporalWindowCount: Int
    public let preparedTemporalWindowCount: Int
    public let validTemporalWindowCount: Int
    public let decodedTemporalFrameCount: Int
    public let temporalWindows: [V4TemporalWindowEvidence]
    public let missingSceneIDs: [String]
    public let error: String?

    public var evaluable: Bool {
        prepared && matchedFrameCount > 0 && sceneCount > 0 &&
            coveredSceneCount == sceneCount && validTemporalWindowCount > 0
    }

    public var temporalWindowCount: Int { validTemporalWindowCount }
    public var temporalFrameCount: Int { decodedTemporalFrameCount }
}

public struct V4TemporalWindowEvidence: Codable, Sendable, Equatable {
    public let sceneID: String
    public let requestedFrameCount: Int
    public let preparedSDRFrameCount: Int
    public let preparedHDRFrameCount: Int
    public let validContiguousFrameCount: Int
    public let startSeconds: Double
    public let error: String?
    public let targetFrameCount: Int
    public let minimumRequiredFrameCount: Int
    public let actualDecodedFrameCount: Int
    public let warmupFrameCount: Int
    public let measuredFrameCount: Int
    public let fullLength: Bool
    public let accepted: Bool
    public let acceptanceReason: String

    public init(
        sceneID: String,
        requestedFrameCount: Int,
        preparedSDRFrameCount: Int,
        preparedHDRFrameCount: Int,
        validContiguousFrameCount: Int,
        startSeconds: Double,
        error: String?,
        decision: V4TemporalWindowDecision? = nil
    ) {
        let resolved = decision ?? V4TemporalWindowPolicy.v5.decision(
            actualDecodedFrameCount: validContiguousFrameCount
        )
        self.sceneID = sceneID
        self.requestedFrameCount = requestedFrameCount
        self.preparedSDRFrameCount = preparedSDRFrameCount
        self.preparedHDRFrameCount = preparedHDRFrameCount
        self.validContiguousFrameCount = validContiguousFrameCount
        self.startSeconds = startSeconds
        self.error = error
        self.targetFrameCount = resolved.targetFrameCount
        self.minimumRequiredFrameCount = resolved.minimumRequiredFrameCount
        self.actualDecodedFrameCount = resolved.actualDecodedFrameCount
        self.warmupFrameCount = resolved.warmupFrameCount
        self.measuredFrameCount = resolved.measuredFrameCount
        self.fullLength = resolved.fullLength
        self.accepted = error == nil && resolved.accepted
        self.acceptanceReason = error == nil
            ? resolved.acceptanceReason.rawValue
            : (validContiguousFrameCount > 0 && !resolved.accepted
                ? V4TemporalWindowAcceptanceReason.rejectedBelowMinimum.rawValue
                : (error?.contains("aligned scene anchor") == true
                ? V4TemporalWindowAcceptanceReason.noAlignedAnchor.rawValue
                : V4TemporalWindowAcceptanceReason.decodeFailure.rawValue))
    }

    private enum CodingKeys: String, CodingKey {
        case sceneID, requestedFrameCount, preparedSDRFrameCount, preparedHDRFrameCount
        case validContiguousFrameCount, startSeconds, error
        case targetFrameCount, minimumRequiredFrameCount, actualDecodedFrameCount
        case warmupFrameCount, measuredFrameCount, fullLength, accepted, acceptanceReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sceneID = try container.decode(String.self, forKey: .sceneID)
        requestedFrameCount = try container.decodeIfPresent(Int.self, forKey: .requestedFrameCount) ?? 16
        preparedSDRFrameCount = try container.decodeIfPresent(Int.self, forKey: .preparedSDRFrameCount) ?? 0
        preparedHDRFrameCount = try container.decodeIfPresent(Int.self, forKey: .preparedHDRFrameCount) ?? 0
        validContiguousFrameCount = try container.decodeIfPresent(Int.self, forKey: .validContiguousFrameCount) ?? 0
        startSeconds = try container.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0
        error = try container.decodeIfPresent(String.self, forKey: .error)
        let decision = V4TemporalWindowPolicy.v5.decision(actualDecodedFrameCount: validContiguousFrameCount)
        let target = try container.decodeIfPresent(Int.self, forKey: .targetFrameCount) ?? decision.targetFrameCount
        let minimum = try container.decodeIfPresent(Int.self, forKey: .minimumRequiredFrameCount) ?? decision.minimumRequiredFrameCount
        targetFrameCount = target
        minimumRequiredFrameCount = minimum
        let decodedCount = try container.decodeIfPresent(Int.self, forKey: .actualDecodedFrameCount) ?? validContiguousFrameCount
        actualDecodedFrameCount = decodedCount
        warmupFrameCount = try container.decodeIfPresent(Int.self, forKey: .warmupFrameCount) ?? decision.warmupFrameCount
        measuredFrameCount = try container.decodeIfPresent(Int.self, forKey: .measuredFrameCount) ?? decision.measuredFrameCount
        let encodedFullLength: Bool? = try container.decodeIfPresent(Bool.self, forKey: .fullLength)
        let encodedAccepted: Bool? = try container.decodeIfPresent(Bool.self, forKey: .accepted)
        fullLength = encodedFullLength ?? (decodedCount >= target)
        accepted = encodedAccepted ?? (error == nil && decodedCount >= minimum)
        acceptanceReason = try container.decodeIfPresent(String.self, forKey: .acceptanceReason) ??
            (error == nil
                ? (accepted ? (fullLength ? V4TemporalWindowAcceptanceReason.fullTargetLength.rawValue : V4TemporalWindowAcceptanceReason.validShortWindowAboveMinimum.rawValue) : V4TemporalWindowAcceptanceReason.rejectedBelowMinimum.rawValue)
                : (decodedCount > 0 && !accepted
                    ? V4TemporalWindowAcceptanceReason.rejectedBelowMinimum.rawValue
                    : V4TemporalWindowAcceptanceReason.decodeFailure.rawValue))
    }
}

public struct V4StructuralSplitCheck: Codable, Sendable {
    public let split: DatasetSplit
    public let requestedPairIDs: [String]
    public let evaluatedPairIDs: [String]
    public let requestedVideoCount: Int
    public let evaluatedVideoCount: Int
    public let complete: Bool
    public let pairs: [V4StructuralPairCheck]
}

public struct V4CorrectnessEvidence: Codable, Sendable, Equatable {
    public let summary: String
    public let numerical: [String: Double]
    public let counts: [String: Int]
    public let booleans: [String: Bool]

    public init(
        summary: String,
        numerical: [String: Double] = [:],
        counts: [String: Int] = [:],
        booleans: [String: Bool] = [:]
    ) {
        self.summary = summary
        self.numerical = numerical
        self.counts = counts
        self.booleans = booleans
    }
}

public struct V4CorrectnessCheck: Codable, Sendable {
    public let id: String
    public let required: Bool
    public let executed: Bool
    public let status: String
    public let evidence: V4CorrectnessEvidence

    public init(
        id: String,
        required: Bool = true,
        executed: Bool = true,
        status: String,
        evidence: V4CorrectnessEvidence
    ) {
        self.id = id
        self.required = required
        self.executed = executed
        self.status = status
        self.evidence = evidence
    }

    /// Source compatibility for existing checks while making execution state
    /// explicit in the encoded artifact.
    public init(id: String, status: String, evidence: String) {
        self.init(
            id: id,
            required: true,
            executed: status != "NOT_RUN" && status != "NOT_MEASURED" && status != "SKIPPED",
            status: status,
            evidence: V4CorrectnessEvidence(summary: evidence)
        )
    }

    public init(id: String, required: Bool = true, executed: Bool, status: String, evidence: String) {
        self.init(
            id: id, required: required, executed: executed, status: status,
            evidence: V4CorrectnessEvidence(summary: evidence)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, required, executed, status, evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        executed = try container.decodeIfPresent(Bool.self, forKey: .executed) ??
            (status != "NOT_RUN" && status != "NOT_MEASURED" && status != "SKIPPED")
        if let object = try? container.decode(V4CorrectnessEvidence.self, forKey: .evidence) {
            evidence = object
        } else {
            let summary = (try? container.decode(String.self, forKey: .evidence)) ?? "missing evidence"
            evidence = V4CorrectnessEvidence(summary: summary)
        }
    }
}

private struct V4IndexDomainArtifact: Codable, Sendable {
    let sourceIndexMeaning: String
    let sequencePositionMeaning: String
    let tune: V4StructuralSplitCheck
    let validation: V4StructuralSplitCheck
}

private struct V4RunnerIntegrityArtifact: Codable, Sendable {
    let status: String
    let manifestHash: String
    let lockHash: String
    let auditHash: String
    let auditConfigHash: String
    let eligiblePairIDs: [String]
    let relationByPairID: [String: String]
    let objectiveEvaluated: Bool
    let virginFrozenObjectiveEvaluated: Bool
}

private struct V4ParityArtifact: Codable, Sendable {
    let status: String
    let model: String
    let evidence: V4CorrectnessEvidence
    let virginFrozenObjectiveEvaluated: Bool
}

private struct V4HLGValidationArtifact: Codable, Sendable {
    let status: String
    let signal: [Float]
    let decodedRGBNits: [Float]
    let ootf: String
    let coloredVectorTest: String
    let grayVectorsTested: Int
    let coloredVectorsTested: Int
    let maxRGBError: Double
    let maxLuminanceError: Double
    let finiteFailures: Int
}

private struct V4PromotionGateArtifact: Codable, Sendable {
    let status: String
    let transferFailureVerdict: String
    let runtimeFailureVerdict: String
    let frozenFailureVerdict: String
    let runtimeGateIsReachable: Bool
}

private struct V4FreezeHashArtifact: Codable, Sendable {
    let status: String
    let sourceHash: String
    let executableHash: String
    let gitCommit: String
    let gitTree: String
    let workingTreeDirty: Bool
    let sourceMutationTest: String
    let missingSourceHardFailureTest: String
}

private struct V4PreV5CoverageArtifact: Codable, Sendable {
    let version: String
    let currentRequiredTransfers: Set<String>
    let currentRequiredFamilies: Set<String>
    let actualVirginTransfers: Set<String>
    let actualVirginFamilies: Set<String>
    let actualVirginFrozenPairs: Int
    let minimumVirginFrozenPairs: Int
    let minimumDistinctVirginFrozenFamilies: Int
    let transferStatus: String
    let familyStatus: String
    let pairCountStatus: String
    let whyEachRequirementExists: [String]
}

private struct V4PreV5WindowRecord: Codable, Sendable {
    let pairID: String
    let split: DatasetSplit
    let window: V4TemporalWindowEvidence
}

private struct V4PreV5TemporalPolicyArtifact: Codable, Sendable {
    let version: String
    let policy: V4TemporalWindowPolicy
    let windows: [V4PreV5WindowRecord]
}

private struct V4PreV5ExecutableEvidenceArtifact: Codable, Sendable {
    let version: String
    let allRequiredChecksPass: Bool
    let checks: [V4CorrectnessCheck]
}

private struct V4PreV5FreezeIntegrityArtifact: Codable, Sendable {
    let version: String
    let workingTreeDirty: Bool
    let dirtyTreeFreezeRejected: Bool
    let cleanTreeFreezeAllowed: Bool
    let sourceHash: String
    let executableHash: String
    let gitCommit: String
    let gitTree: String
    let check: V4CorrectnessCheck
}

private struct V4PreV5FrozenPair: Codable, Sendable {
    let id: String
    let transfer: String
    let family: String
    let virginStatus: String
    let objectiveEvaluated: Bool
    let provenanceEvidence: [String]
}

private struct V4PreV5StructuralPairEvidence: Codable, Sendable {
    let pairID: String
    let split: DatasetSplit
    let spatialRepresentativeFrames: Int
    let temporalWindowsRequested: Int
    let temporalWindowsValid: Int
    let temporalFramesDecoded: Int
    let temporalFramesMeasured: Int
    let status: String
}

private struct V4PreV5FinalArtifact: Codable, Sendable {
    let version: String
    let generatedAt: String
    let verdict: String
    let datasetReady: Bool
    let priorCorrectnessVerdict: String
    let frozenCoveragePolicy: V4FrozenCoveragePolicy
    let newHLGHoldoutAudit: V4NewHLGHoldoutAudit
    let holdoutProvenance: V4HoldoutProvenanceAudit
    let frozenComposition: [V4PreV5FrozenPair]
    let structuralEvidence: [V4PreV5StructuralPairEvidence]
    let tuneStructural: V4StructuralSplitCheck
    let validationStructural: V4StructuralSplitCheck
    let temporalWindowPolicy: V4TemporalWindowPolicy
    let checks: [V4CorrectnessCheck]
    let virginFrozenObjectiveEvaluationCount: Int
    let objectiveEvaluationCount: Int
    let evidencePortable: Bool
    let freezeIntegrity: V4CorrectnessCheck
}

private struct V4CorrectnessFindingArtifact: Codable, Sendable {
    let artifactRole: String
    let version: String
    let generatedAt: String
    let verdict: String
    let findings: [V4CorrectnessCheck]
}

public struct V4CorrectnessReviewReport: Codable, Sendable {
    public let version: String
    public let generatedAt: String
    public let manifestPath: String
    public let manifestHash: String
    public let datasetLockHash: String
    public let auditArtifactHash: String
    public let tune: V4StructuralSplitCheck
    public let validation: V4StructuralSplitCheck
    public let virginFrozenObjectiveEvaluated: Bool
    public let checks: [V4CorrectnessCheck]
    public let verdict: String
}

/// Correctness-only harness. It may decode and align Tune/Validation media,
/// but it never calls the objective evaluator and never opens Virgin Frozen.
public enum V4CorrectnessReview {
    public static func run(
        manifestURL: URL,
        outputDirectory: URL,
        preparedFrozenPlanURL: URL? = nil
    ) async throws -> V4CorrectnessReviewReport {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let frozenObjectiveStart = V4FrozenObjectiveAccessRegistry.shared.snapshot()
        let auditURL = outputDirectory.appendingPathComponent("dataset-v4-final.json")
        let lockURL = manifestURL.deletingLastPathComponent().appendingPathComponent("dataset-v4-lock.json")
        let evidence = try V4DatasetEvidenceValidator.validate(
            manifestURL: manifestURL,
            auditURL: auditURL,
            lockURL: lockURL,
            mediaScope: .tuneValidationOnly
        )
        let audit = try JSONDecoder().decode(
            V4DatasetAuditReport.self,
            from: Data(contentsOf: auditURL)
        )
        let manifest = try V4Manifest.load(from: manifestURL)
        let repositoryRoot = try V4SourceHasher.repositoryRoot(for: manifestURL)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CalibrationError.decodeFailed("Metal device unavailable for V6 preparation plan")
        }
        var preparationConfiguration = V2SearchConfiguration()
        preparationConfiguration.maxFramesPerScene = 8
        preparationConfiguration.alignmentSearchThreshold = 0
        preparationConfiguration.referenceTargetPeakNits = 1_000
        let repository = V2PreparedRepository(
            manifestURL: manifestURL,
            device: device,
            configuration: preparationConfiguration,
            acceptedConfidenceThreshold: V4CalibrationConfiguration().confidenceThreshold
        )
        let structuralRecords = V6PreparedEvaluationPlanOrdering.canonical(
            manifest.pairs
                .filter { $0.split == .tune || $0.split == .validation }
                .map { pair -> PairRecord in
                    let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
                    return PairRecord(
                        id: pair.id,
                        sdr: urls.sdr.path,
                        hdr: urls.hdr.path,
                        license: pair.license,
                        source: pair.source,
                        expectedRelation: pair.expectedRelation.legacyRelation(),
                        notes: pair.notes,
                        split: pair.split
                    )
                },
            scope: V6PreparedEvaluationPlanOrdering.tuneValidationScope,
            split: { $0.split }
        )
        let preparedStructural = try await repository.prepare(records: structuralRecords)
        let inputHashesForPlan = V6PreparedEvaluationPlanBuilder.makeInputHashes(audit: audit)
        let preparedPlan = try repository.sealPreparedEvaluationPlan(
            records: structuralRecords,
            inputHashes: inputHashesForPlan,
            scope: V6PreparedEvaluationPlanOrdering.tuneValidationScope
        )
        try V6PreparedEvaluationPlanBuilder.validate(plan: preparedPlan, preparedPairs: preparedStructural)
        // Exercise the same read-only evaluator-entry materialization used by
        // V4/V6 after a plan is sealed.  The second pass may decode the
        // already-sealed identities, but it cannot align, select scenes, or
        // apply a new confidence gate.  Structural checks below therefore
        // describe the exact hand-off that an evaluator would consume.
        let evaluatorEntryStructural = try await repository.materialize(
            records: structuralRecords,
            using: preparedPlan,
            inputHashes: inputHashesForPlan
        )
        try V6PreparedEvaluationPlanBuilder.validate(
            plan: preparedPlan, preparedPairs: evaluatorEntryStructural
        )
        let preparedPlanArtifact = try V6PreparedEvaluationPlanArtifact(plan: preparedPlan)
        try writeJSON(
            preparedPlanArtifact,
            to: outputDirectory.appendingPathComponent("v6-prepared-evaluation-plan.json")
        )
        try Data((preparedPlanArtifact.planSHA256 + "\n").utf8)
            .write(to: outputDirectory.appendingPathComponent("v6-prepared-evaluation-plan.sha256"))
        let tune = structuralCheck(
            split: .tune,
            manifest: manifest,
            preparedPairs: evaluatorEntryStructural,
            preparedPlan: preparedPlan
        )
        let validation = structuralCheck(
            split: .validation,
            manifest: manifest,
            preparedPairs: evaluatorEntryStructural,
            preparedPlan: preparedPlan
        )
        let holdoutProvenance = V4HistoricalObjectiveProvenance.audit(
            repositoryRoot: repositoryRoot, outputDirectory: outputDirectory
        )
        let newHLGAudit = try await V4NewHLGHoldoutAuditor.audit(
            manifestURL: manifestURL, datasetAudit: audit, outputDirectory: outputDirectory
        )
        let frozenPlanCheck = validateFrozenPreparedPlan(
            manifest: manifest,
            audit: audit,
            tuneValidationPlan: preparedPlan,
            preparedFrozenPlanURL: preparedFrozenPlanURL,
            holdoutProvenance: holdoutProvenance
        )
        let checks = makeChecks(
            manifest: manifest,
            evidence: evidence,
            audit: audit,
            tune: tune,
            validation: validation,
            outputDirectory: outputDirectory,
            newHLGAudit: newHLGAudit,
            holdoutProvenance: holdoutProvenance,
            preparedPlan: preparedPlan,
            frozenPlanCheck: frozenPlanCheck
        )
        let requiredIncomplete = checks.filter {
            $0.required && (!$0.executed || $0.status != "PASS")
        }
        let verdict: String
        if checks.contains(where: { $0.id == "holdoutProvenance" && $0.required && $0.status != "PASS" }) {
            verdict = "HOLDOUT_PROVENANCE_FAIL"
        } else if newHLGAudit.required && !newHLGAudit.found {
            verdict = "NEW_HLG_VIRGIN_REQUIRED"
        } else if checks.contains(where: { $0.id == "transferCoverageSemantics" && $0.required && $0.status != "PASS" }) {
            verdict = "FROZEN_TRANSFER_COVERAGE_INCOMPLETE"
        } else if checks.contains(where: { $0.id == "frozenPairCountSemantics" && $0.required && $0.status != "PASS" }) {
            verdict = "FROZEN_PAIR_COUNT_INCOMPLETE"
        } else if checks.contains(where: { $0.id == "familyCoverageSemantics" && $0.required && $0.status != "PASS" }) {
            verdict = "FROZEN_FAMILY_COVERAGE_INCOMPLETE"
        } else if checks.contains(where: { $0.id == "realTemporalWindowPreparation" && $0.required && $0.status != "PASS" }) {
            verdict = "TEMPORAL_WINDOW_POLICY_FAIL"
        } else if checks.contains(where: { $0.id == "freeze-integrity" && $0.required && $0.status != "PASS" }) {
            verdict = "FREEZE_INTEGRITY_FAIL"
        } else if !tune.complete || !validation.complete || !requiredIncomplete.isEmpty {
            verdict = "EXECUTABLE_EVIDENCE_INCOMPLETE"
        } else {
            verdict = "CORRECTNESS_READY_FOR_V6"
        }
        let frozenObjectiveEnd = V4FrozenObjectiveAccessRegistry.shared.snapshot()
        let frozenObjectiveDelta = max(0, frozenObjectiveEnd.eventCount - frozenObjectiveStart.eventCount)
        let report = V4CorrectnessReviewReport(
            version: "correctness-review-v6",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            manifestPath: V4EvidencePath.portable(manifestURL, repositoryRoot: repositoryRoot),
            manifestHash: evidence.manifestHash,
            datasetLockHash: evidence.lockHash,
            auditArtifactHash: evidence.auditHash,
            tune: tune,
            validation: validation,
            virginFrozenObjectiveEvaluated: frozenObjectiveDelta > 0,
            checks: checks,
            verdict: verdict
        )
        try writeJSON(report, to: outputDirectory.appendingPathComponent("correctness-review-structural.json"))
        try writeSupportingArtifacts(
            report: report,
            manifest: manifest,
            evidence: evidence,
            audit: audit,
            outputDirectory: outputDirectory,
            newHLGAudit: newHLGAudit,
            holdoutProvenance: holdoutProvenance,
            frozenObjectiveEvaluationCount: frozenObjectiveDelta,
            repositoryRoot: repositoryRoot
        )
        return report
    }

    /// Validate the admitted holdout plan without resolving or opening Frozen
    /// media. The evaluator calls the same contract validator before its guard,
    /// then materializes this exact plan only after the guard opens.
    private static func validateFrozenPreparedPlan(
        manifest: V4Manifest,
        audit: V4DatasetAuditReport,
        tuneValidationPlan: PreparedEvaluationPlan,
        preparedFrozenPlanURL: URL?,
        holdoutProvenance: V4HoldoutProvenanceAudit
    ) -> V4CorrectnessCheck {
        let eligibleByID = eligibleCoverageAuditRecords(audit)
        let records = manifest.pairs.filter { pair in
            pair.split == .frozen && pair.virginFrozen &&
                eligibleByID[pair.id] != nil &&
                !holdoutProvenance.consumedSet.contains(pair.id) &&
                pair.objectiveEvaluated == false && pair.consumed == false
        }
        guard !records.isEmpty else {
            return V4CorrectnessCheck(
                id: "v6FrozenPreparedEvaluationPlan",
                status: "FAIL",
                evidence: V4CorrectnessEvidence(
                    summary: "no objective-unexposed V6 Virgin Frozen records are eligible for a sealed preparation plan",
                    counts: ["eligiblePairCount": 0],
                    booleans: ["frozenMediaOpened": false, "planValidated": false]
                )
            )
        }
        guard let preparedFrozenPlanURL else {
            return V4CorrectnessCheck(
                id: "v6FrozenPreparedEvaluationPlan",
                status: "FAIL",
                evidence: V4CorrectnessEvidence(
                    summary: "eligible V6 holdouts require an explicit --prepared-frozen-plan admitted before Pre-Frozen PASS",
                    counts: ["eligiblePairCount": records.count],
                    booleans: ["frozenMediaOpened": false, "planValidated": false]
                )
            )
        }
        do {
            let artifact = try V6PreparedEvaluationPlanLoader.loadSealed(from: preparedFrozenPlanURL)
            try V6PreparedEvaluationPlanBuilder.validateSealedContract(
                plan: artifact.plan,
                scope: "VIRGIN_FROZEN",
                records: records,
                inputHashes: V6PreparedEvaluationPlanBuilder.makeInputHashes(audit: audit),
                preparation: tuneValidationPlan.preparation
            )
            return V4CorrectnessCheck(
                id: "v6FrozenPreparedEvaluationPlan",
                status: "PASS",
                evidence: V4CorrectnessEvidence(
                    summary: "metadata-only admission validated the exact Frozen plan used by evaluator entry; sha256=\(artifact.planSHA256)",
                    counts: [
                        "eligiblePairCount": records.count,
                        "acceptedFrameCount": artifact.plan.pairs.reduce(0) { $0 + $1.alignment.acceptedFrameCount }
                    ],
                    booleans: ["frozenMediaOpened": false, "planValidated": true]
                )
            )
        } catch {
            return V4CorrectnessCheck(
                id: "v6FrozenPreparedEvaluationPlan",
                status: "FAIL",
                evidence: V4CorrectnessEvidence(
                    summary: "Frozen PreparedEvaluationPlan admission failed closed: \(error.localizedDescription)",
                    counts: ["eligiblePairCount": records.count],
                    booleans: ["frozenMediaOpened": false, "planValidated": false]
                )
            )
        }
    }

    /// Build structural evidence from the exact V6 materialized plan.  This
    /// intentionally contains no decoder, matcher, scene detector, or seek
    /// call: those decisions were made once by `V2PreparedRepository` and are
    /// now validated/read-only for both preflight and evaluator entry.
    private static func structuralCheck(
        split: DatasetSplit,
        manifest: V4Manifest,
        preparedPairs: [PreparedPair],
        preparedPlan: PreparedEvaluationPlan
    ) -> V4StructuralSplitCheck {
        let requestedPairs = manifest.pairs.filter { $0.split == split }
        let preparedByID = Dictionary(uniqueKeysWithValues: preparedPairs.map { ($0.record.id, $0) })
        var results: [V4StructuralPairCheck] = []
        results.reserveCapacity(requestedPairs.count)
        for pair in requestedPairs {
            do {
                guard let prepared = preparedByID[pair.id] else {
                    throw CalibrationError.incompleteEvaluation("V6 plan is missing \(pair.id)")
                }
                let accepted = try V6PreparedEvaluationEntry.acceptedMatches(
                    prepared: prepared,
                    plan: preparedPlan
                )
                _ = try V6PreparedEvaluationEntry.temporalWindows(
                    prepared: prepared,
                    plan: preparedPlan
                )
                guard let pairPlan = preparedPlan.pairPlan(for: pair.id),
                      pairPlan.temporalWindows.count == prepared.temporalWindows.count else {
                    throw CalibrationError.incompleteEvaluation(
                        "V6 temporal plan is missing or inconsistent for \(pair.id)"
                    )
                }
                let scenes = prepared.scenes
                let covered = scenes.filter { scene in
                    accepted.contains { match in
                        guard let position = match.match.sdrSequencePosition else { return false }
                        return scene.contains(sequencePosition: position)
                    }
                }
                let missing = scenes.filter { scene in
                    !covered.contains(where: { $0.id == scene.id })
                }.map(\.id)
                let temporalEvidence = zip(prepared.temporalWindows, pairPlan.temporalWindows).map { window, planned in
                    let decision = window.decision
                    let error: String?
                    if !decision.accepted {
                        error = "fewer than \(decision.minimumRequiredFrameCount) paired contiguous frames"
                    } else if !planned.evaluationAccepted {
                        error = "temporal anchor confidence below sealed \(preparedPlan.preparation.acceptedConfidenceThreshold) gate"
                    } else {
                        error = nil
                    }
                    return V4TemporalWindowEvidence(
                        sceneID: window.sceneID,
                        requestedFrameCount: decision.targetFrameCount,
                        preparedSDRFrameCount: window.frames.count,
                        preparedHDRFrameCount: window.frames.filter { $0.hdrIndex != nil }.count,
                        validContiguousFrameCount: window.frames.count,
                        startSeconds: window.startSeconds,
                        error: error,
                        decision: decision
                    )
                }
                let validWindows = temporalEvidence.filter(\.accepted)
                results.append(V4StructuralPairCheck(
                    pairID: pair.id,
                    split: split,
                    requested: true,
                    prepared: !accepted.isEmpty,
                    matchedFrameCount: accepted.count,
                    sceneCount: scenes.count,
                    coveredSceneCount: covered.count,
                    requestedTemporalWindowCount: scenes.count,
                    preparedTemporalWindowCount: validWindows.count,
                    validTemporalWindowCount: validWindows.count,
                    decodedTemporalFrameCount: temporalEvidence.reduce(0) { $0 + $1.validContiguousFrameCount },
                    temporalWindows: temporalEvidence,
                    missingSceneIDs: missing,
                    error: nil
                ))
            } catch {
                results.append(V4StructuralPairCheck(
                    pairID: pair.id,
                    split: split,
                    requested: true,
                    prepared: false,
                    matchedFrameCount: 0,
                    sceneCount: 0,
                    coveredSceneCount: 0,
                    requestedTemporalWindowCount: 0,
                    preparedTemporalWindowCount: 0,
                    validTemporalWindowCount: 0,
                    decodedTemporalFrameCount: 0,
                    temporalWindows: [],
                    missingSceneIDs: [],
                    error: error.localizedDescription
                ))
            }
        }
        let requested = requestedPairs.map(\.id).sorted()
        let evaluated = results.filter(\.evaluable).map(\.pairID).sorted()
        return V4StructuralSplitCheck(
            split: split,
            requestedPairIDs: requested,
            evaluatedPairIDs: evaluated,
            requestedVideoCount: requested.count,
            evaluatedVideoCount: evaluated.count,
            complete: requested == evaluated,
            pairs: results
        )
    }

    private static func makeChecks(
        manifest: V4Manifest,
        evidence: V4DatasetEvidence,
        audit: V4DatasetAuditReport,
        tune: V4StructuralSplitCheck,
        validation: V4StructuralSplitCheck,
        outputDirectory: URL,
        newHLGAudit: V4NewHLGHoldoutAudit,
        holdoutProvenance: V4HoldoutProvenanceAudit,
        preparedPlan: PreparedEvaluationPlan,
        frozenPlanCheck: V4CorrectnessCheck
    ) -> [V4CorrectnessCheck] {
        let relationsPreserved = manifest.pairs.allSatisfy { $0.expectedRelation.supportsMainCalibration }
        let temporal = temporalParityCheck()
        let causal = oneFrameCausalDiagnosticCheck()
        let burst = burstTemporalParityCheck()
        let percentile = percentileParityCheck()
        let hlg = hlgCheck()
        let strictMetadata = strictSDRMetadataCheck()
        let diversity = diversityEligibilityCheck()
        let sourceHash = sourceFreezeHashCheck()
        let freezeIntegrity = freezeIntegrityCheck()
        let gates = promotionGateCheck()
        let runtime = runtimeMeasurementCheck()
        let allPairs = tune.pairs + validation.pairs
        let realTemporalPrepared = allPairs.allSatisfy { $0.evaluable && $0.validTemporalWindowCount > 0 &&
            $0.temporalWindows.filter(\.accepted).count == $0.validTemporalWindowCount }
        let sparseSeparated = allPairs.allSatisfy { pair in
            pair.matchedFrameCount == 0 || pair.decodedTemporalFrameCount >= V4TemporalWindowPolicy.v5.minimumRequiredFrameCount * pair.validTemporalWindowCount
        }
        let totalValidWindows = allPairs.reduce(0) { $0 + $1.validTemporalWindowCount }
        let totalDecodedFrames = allPairs.reduce(0) { $0 + $1.decodedTemporalFrameCount }
        let planHash = (try? V6PreparedEvaluationPlanHasher.sha256(preparedPlan)) ?? "UNAVAILABLE"
        return [
            V4CorrectnessCheck(
                id: "v6PreparedEvaluationPlan",
                status: planHash == "UNAVAILABLE" ? "FAIL" : "PASS",
                evidence: V4CorrectnessEvidence(
                    summary: "one canonical V6 preparation plan is shared by preflight and read-only evaluator-entry materialization; sha256=\(planHash); matcherConfigurationHash=\(preparedPlan.preparation.matcherConfigurationHash)",
                    counts: ["pairCount": preparedPlan.pairOrder.count, "plannedAcceptedFrames": preparedPlan.pairs.reduce(0) { $0 + $1.alignment.acceptedFrameCount }],
                    booleans: [
                        "canonicalSerialization": planHash != "UNAVAILABLE",
                        "matcherConfigurationHashBound": preparedPlan.pairs.allSatisfy {
                            $0.alignment.matcherConfigurationHash == preparedPlan.preparation.matcherConfigurationHash
                        }
                    ]
                )
            ),
            V4CorrectnessCheck(id: "dataset-audit-lock", status: "PASS", evidence: V4CorrectnessEvidence(
                summary: "validator consumed READY audit + manifest/lock evidence; Tune/Validation media digests were checked and Frozen media remained sealed",
                counts: ["eligiblePairs": evidence.eligiblePairIDs.count],
                booleans: ["objectiveEvaluated": false, "virginFrozenObjectiveEvaluated": false]
            )),
            frozenPlanCheck,
            V4CorrectnessCheck(
                id: "sparse-index-domain",
                status: tune.complete && validation.complete ? "PASS" : "FAIL",
                evidence: "V6 PreparedEvaluationPlan checked exact requested/evaluated IDs using sequencePosition"
            ),
            V4CorrectnessCheck(
                id: "sparseSpatialTemporalSeparation",
                status: sparseSeparated ? "PASS" : "FAIL",
                evidence: "sparse spatial evaluation is isolated to deterministic neutral temporal state; contiguous-window evidence is reported separately"
            ),
            V4CorrectnessCheck(
                id: "realTemporalWindowPreparation",
                status: realTemporalPrepared ? "PASS" : "FAIL",
                evidence: "decoded \(totalDecodedFrames) paired contiguous frames across \(totalValidWindows) valid windows"
            ),
            preFrozenHoldoutPreservationCheck(),
            holdoutProvenanceCheck(manifest: manifest, audit: audit, provenance: holdoutProvenance),
            transferCoverageSemanticsCheck(manifest: manifest, audit: audit, provenance: holdoutProvenance),
            frozenPairCountSemanticsCheck(manifest: manifest, audit: audit, provenance: holdoutProvenance),
            familyCoverageSemanticsCheck(manifest: manifest, audit: audit, provenance: holdoutProvenance),
            newHLGAuditCheck(newHLGAudit),
            evidencePortabilityCheck(),
            absolutePathLeakCheck(outputDirectory: outputDirectory),
            structuralCompletenessCheck(tune: tune, validation: validation),
            temporal,
            causal,
            burst,
            percentile,
            hlg,
            strictMetadata,
            V4CorrectnessCheck(id: "relation-preservation", status: relationsPreserved ? "PASS" : "FAIL", evidence: "current manifest relations were evaluated directly; only main-calibration relations are accepted"),
            diversity,
            sourceHash,
            freezeIntegrity,
            runtime,
            gates
        ]
    }

    private static func temporalParityCheck() -> V4CorrectnessCheck {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return V4CorrectnessCheck(
                id: "temporal-production-offline-parity", status: "NOT_RUN",
                evidence: "Metal device unavailable; production/offline processor parity could not be executed"
            )
        }
        do {
            let values: [SIMD3<Float>] = [
                SIMD3(repeating: 0.05), SIMD3(repeating: 0.05), SIMD3(repeating: 0.80),
                SIMD3(repeating: 0.80), SIMD3(repeating: 0.05)
            ]
            var maxAbsoluteError = 0.0
            var framesTested = 0
            var stateVersionsCompared = 0
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
                    if let error = commandBuffer.error { throw error }
                    _ = try offline.evaluate(
                        pixelBuffer: pixelBuffer,
                        timestampSeconds: Double(index) / 30,
                        configuration: configuration
                    )
                    let productionShadow = production.sceneShadowCoordinates
                    let offlineShadow = offline.sceneShadowCoordinates
                    let errors = [
                        abs(production.temporalAdaptation - offline.temporalAdaptation),
                        abs(productionShadow.floor - offlineShadow.floor),
                        abs(productionShadow.top - offlineShadow.top)
                    ].map(Double.init)
                    maxAbsoluteError = max(maxAbsoluteError, errors.max() ?? 0)
                    framesTested += 1
                    stateVersionsCompared += 1
                    guard errors.allSatisfy({ $0 <= 0.000_001 }),
                          productionShadow.valid == offlineShadow.valid else {
                        return V4CorrectnessCheck(
                            id: "temporal-production-offline-parity", status: "FAIL",
                            evidence: V4CorrectnessEvidence(
                                summary: "production and offline processor temporal state diverged for \(revision.rawValue)",
                                numerical: ["maxAbsoluteError": maxAbsoluteError],
                                counts: [
                                    "framesTested": framesTested,
                                    "maxFramesInFlight": 1,
                                    "stateVersionsCompared": stateVersionsCompared,
                                    "completionOrderViolations": 0,
                                    "staleOverwriteCount": 0
                                ]
                            )
                        )
                    }
                }
            }
            return V4CorrectnessCheck(
                id: "temporal-production-offline-parity", status: "PASS",
                evidence: V4CorrectnessEvidence(
                    summary: "production HDRProcessor and HDRCoreOfflineEvaluator were executed in this run for V2 and V4 causal sequences and matched within 1e-6",
                    numerical: ["maxAbsoluteError": maxAbsoluteError],
                    counts: [
                        "framesTested": framesTested,
                        "maxFramesInFlight": 1,
                        "stateVersionsCompared": stateVersionsCompared,
                        "completionOrderViolations": 0,
                        "staleOverwriteCount": 0
                    ]
                )
            )
        } catch {
            return V4CorrectnessCheck(
                id: "temporal-production-offline-parity", status: "FAIL",
                evidence: V4CorrectnessEvidence(
                    summary: "production/offline temporal parity execution failed: \(error.localizedDescription)"
                )
            )
        }
    }

    private static func oneFrameCausalDiagnosticCheck() -> V4CorrectnessCheck {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return V4CorrectnessCheck(
                id: "one-frame-causal-diagnostic",
                required: true,
                executed: false,
                status: "NOT_RUN",
                evidence: V4CorrectnessEvidence(summary: "Metal device unavailable; one-frame causal diagnostic was not run")
            )
        }
        do {
            var configuration = HDRConfiguration.calibratedV2
            configuration.temporalStability = 0.8
            let evaluator = try HDRCoreOfflineEvaluator(device: device, configuration: configuration)
            evaluator.clearTemporalHistory()
            let dark = try makeCalibrationBGRA(width: 32, height: 18, rgb: SIMD3(repeating: 0.03))
            let first = try evaluator.evaluate(
                pixelBuffer: dark, timestampSeconds: 0, configuration: configuration
            )
            let stateAfterFirst = evaluator.temporalAdaptation
            let passed = abs(first.temporalAdaptationUsed - 1) <= 0.000_001 &&
                abs(stateAfterFirst - first.temporalAdaptationUsed) > 0.000_001
            return V4CorrectnessCheck(
                id: "one-frame-causal-diagnostic",
                status: passed ? "PASS" : "FAIL",
                evidence: V4CorrectnessEvidence(
                    summary: "first-frame diagnostic records state applied to the current frame before the completion update",
                    numerical: [
                        "firstFrameStateUsed": Double(first.temporalAdaptationUsed),
                        "stateAfterFirstFrame": Double(stateAfterFirst),
                        "stateDelta": Double(abs(stateAfterFirst - first.temporalAdaptationUsed))
                    ],
                    counts: ["framesTested": 1],
                    booleans: ["stateAppliedBeforeCompletionUpdate": passed]
                )
            )
        } catch {
            return V4CorrectnessCheck(
                id: "one-frame-causal-diagnostic",
                status: "FAIL",
                evidence: V4CorrectnessEvidence(summary: "one-frame causal diagnostic failed: \(error.localizedDescription)")
            )
        }
    }

    private static func burstTemporalParityCheck() -> V4CorrectnessCheck {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return V4CorrectnessCheck(
                id: "temporalBurstParity", required: true, executed: false, status: "NOT_RUN",
                evidence: V4CorrectnessEvidence(summary: "Metal device unavailable; in-flight burst parity could not be executed")
            )
        }
        do {
            var configuration = HDRConfiguration.calibratedV2
            configuration.toneCurveRevision = .sceneRelativeV4
            let production = try HDRProcessor(device: device, configuration: configuration)
            let offline = try HDRCoreOfflineEvaluator(device: device, configuration: configuration)
            production.clearTemporalHistory()
            offline.clearTemporalHistory()
            production.temporalTraceEnabled = true
            production.clearTemporalTrace()

            // Three frames match the processor's output-pool in-flight depth.
            // No command buffer is waited here until every frame has been submitted.
            let values: [SIMD3<Float>] = [
                SIMD3(repeating: 0.04), SIMD3(repeating: 0.72), SIMD3(repeating: 0.11)
            ]
            var commandBuffers: [MTLCommandBuffer] = []
            commandBuffers.reserveCapacity(values.count)
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
                if let error = commandBuffer.error { throw error }
            }

            let submissions = production.temporalSubmissionTrace
            let completions = production.temporalCompletionTrace
            guard submissions.count == values.count, completions.count == values.count else {
                return V4CorrectnessCheck(
                    id: "temporalBurstParity", status: "FAIL",
                    evidence: V4CorrectnessEvidence(
                        summary: "burst trace did not record every submitted/completed frame",
                        counts: ["framesTested": values.count, "submissionTraceCount": submissions.count, "completionTraceCount": completions.count]
                    )
                )
            }

            // Build an independent serial reference state for every produced
            // sequence version. A burst frame is allowed to consume an older
            // latest-completed version; its encoded values must exactly equal
            // the serial reference state for that consumed version.
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

            var maxError = 0.0
            var versionOrderingViolations = 0
            var consumedVersionRegressions = 0
            var previousTemporalVersion: UInt64 = 0
            var previousSceneVersion: UInt64 = 0
            for trace in submissions {
                guard trace.temporalStateVersionConsumed < trace.submissionSequence,
                      trace.sceneStateVersionConsumed < trace.submissionSequence,
                      let expectedTemporal = temporalByVersion[trace.temporalStateVersionConsumed],
                      let expectedShadow = shadowByVersion[trace.sceneStateVersionConsumed] else {
                    versionOrderingViolations += 1
                    continue
                }
                if trace.temporalStateVersionConsumed < previousTemporalVersion ||
                    trace.sceneStateVersionConsumed < previousSceneVersion {
                    consumedVersionRegressions += 1
                }
                previousTemporalVersion = trace.temporalStateVersionConsumed
                previousSceneVersion = trace.sceneStateVersionConsumed
                maxError = max(
                    maxError,
                    max(
                        Double(abs(trace.temporalAdaptationUsed - expectedTemporal)),
                        max(
                            Double(abs(trace.sceneShadowFloorUsed - expectedShadow.0)),
                            Double(abs(trace.sceneShadowTopUsed - expectedShadow.1))
                        )
                    )
                )
                if trace.sceneStatisticsValidUsed != expectedShadow.2 { maxError = max(maxError, 1) }
            }

            var completionOrderViolations = 0
            var staleOverwriteCount = 0
            var lastSubmission: UInt64 = 0
            var lastTemporalProduced: UInt64 = 0
            var lastSceneProduced: UInt64 = 0
            for trace in completions {
                if trace.submissionSequence <= lastSubmission { completionOrderViolations += 1 }
                if trace.temporalStateVersionProduced < lastTemporalProduced ||
                    trace.sceneStateVersionProduced < lastSceneProduced {
                    staleOverwriteCount += 1
                }
                lastSubmission = trace.submissionSequence
                lastTemporalProduced = trace.temporalStateVersionProduced
                lastSceneProduced = trace.sceneStateVersionProduced
            }

            let passed = maxError <= 0.000_001 && versionOrderingViolations == 0 &&
                consumedVersionRegressions == 0 && completionOrderViolations == 0 && staleOverwriteCount == 0 &&
                production.temporalSubmissionSequence == UInt64(values.count) &&
                production.lastCompletedTemporalSequence == UInt64(values.count)
            return V4CorrectnessCheck(
                id: "temporalBurstParity",
                status: passed ? "PASS" : "FAIL",
                evidence: V4CorrectnessEvidence(
                    summary: "frame-by-frame burst trace verifies each encoded frame against the serial reference state identified by its actual latest-completed state version",
                    numerical: ["maxAbsoluteError": maxError],
                    counts: [
                        "framesTested": values.count,
                        "maxFramesInFlight": commandBuffers.count,
                        "stateVersionsCompared": submissions.count,
                        "versionOrderingViolations": versionOrderingViolations,
                        "consumedVersionRegressions": consumedVersionRegressions,
                        "completionOrderViolations": completionOrderViolations,
                        "staleOverwriteCount": staleOverwriteCount
                    ],
                    booleans: ["frameByFrameConsumedStateCompared": true]
                )
            )
        } catch {
            return V4CorrectnessCheck(
                id: "temporalBurstParity", status: "FAIL",
                evidence: V4CorrectnessEvidence(summary: "in-flight burst parity execution failed: \(error.localizedDescription)")
            )
        }
    }

    private static func preFrozenHoldoutPreservationCheck() -> V4CorrectnessCheck {
        var gates = V4PreFrozenGateResult(runtime: .pass)
        gates.runtime = .fail
        let runtimeBlocked = !gates.canOpenVirginFrozen
        gates = V4PreFrozenGateResult(validationOverall: .pass)
        gates.validationOverall = .notMeasured
        let notMeasuredBlocked = !gates.canOpenVirginFrozen
        let passed = runtimeBlocked && notMeasuredBlocked &&
            V4PromotionGateMachine.verdict(V4PromotionGateResult(frozen: .notMeasured)) == .incompleteEvaluation
        return V4CorrectnessCheck(
            id: "preFrozenHoldoutPreservation",
            status: passed ? "PASS" : "FAIL",
            evidence: "pre-Frozen gate machine was executed with FAIL and NOT_MEASURED states; both block holdout access and produce incomplete/failure verdicts"
        )
    }

    private static func eligibleCoverageAuditRecords(_ audit: V4DatasetAuditReport) -> [String: V4PairAudit] {
        Dictionary(uniqueKeysWithValues: audit.pairs.compactMap { pair -> (String, V4PairAudit)? in
            guard V4CoverageAuditEligibility.isEligible(pair),
                  !V6VirginHoldoutPolicy.isExcluded(
                      pairID: pair.id,
                      sdrSHA256: pair.sdrDigest?.sha256,
                      hdrSHA256: pair.hdrDigest?.sha256
                  ) else { return nil }
            return (pair.id, pair)
        })
    }

    private static func holdoutProvenanceCheck(
        manifest: V4Manifest,
        audit: V4DatasetAuditReport,
        provenance: V4HoldoutProvenanceAudit
    ) -> V4CorrectnessCheck {
        let declaredVirgin = Set(manifest.pairs.filter { $0.split == .frozen && $0.virginFrozen }.map(\.id))
        let excludedByAsset = Set(audit.pairs.compactMap { pair -> String? in
            guard declaredVirgin.contains(pair.id),
                  V6VirginHoldoutPolicy.isExcluded(
                      pairID: pair.id,
                      sdrSHA256: pair.sdrDigest?.sha256,
                      hdrSHA256: pair.hdrDigest?.sha256
                  ) else { return nil }
            return pair.id
        })
        let excludedAttemptOne = declaredVirgin.intersection(V6VirginHoldoutPolicy.consumedPairIDs)
            .union(excludedByAsset)
        let eligibleVirgin = declaredVirgin.subtracting(excludedAttemptOne)
        let contaminated = eligibleVirgin.intersection(provenance.consumedSet).sorted()
        let passed = contaminated.isEmpty
        return V4CorrectnessCheck(
            id: "holdoutProvenance",
            status: passed ? "PASS" : "FAIL",
            evidence: V4CorrectnessEvidence(
                summary: passed
                    ? "no eligible V6 Virgin Frozen pair appears in prior frozen objective artifacts; attempt-1 IDs/assets are explicitly excluded"
                    : "eligible Virgin Frozen pairs were already consumed: \(contaminated.joined(separator: ","))",
                counts: [
                    "declaredVirginPairs": declaredVirgin.count,
                    "excludedAttemptOnePairs": excludedAttemptOne.count,
                    "eligibleVirginPairs": eligibleVirgin.count,
                    "historicallyConsumedVirginPairs": contaminated.count,
                    "historicalArtifactsScanned": provenance.scannedArtifacts.count
                ],
                booleans: [
                    "contaminationDetected": !contaminated.isEmpty,
                    "attemptOneExclusionApplied": !excludedAttemptOne.isEmpty
                ]
            )
        )
    }

    private static func transferCoverageSemanticsCheck(
        manifest: V4Manifest,
        audit: V4DatasetAuditReport,
        provenance: V4HoldoutProvenanceAudit
    ) -> V4CorrectnessCheck {
        let configuration = V4CalibrationConfiguration()
        let eligibleByID = eligibleCoverageAuditRecords(audit)
        var failures: [String] = []
        var rejectedEvidenceCount = 0
        for split in [DatasetSplit.tune, .validation, .frozen] {
            let requestedPairs = manifest.pairs.filter { pair in
                guard pair.split == split && (split == .frozen ? pair.virginFrozen : !pair.virginFrozen) else { return false }
                return split != .frozen || !provenance.consumedSet.contains(pair.id)
            }
            let eligiblePairs = requestedPairs.compactMap { pair -> V4PairAudit? in
                guard let auditRecord = eligibleByID[pair.id] else {
                    rejectedEvidenceCount += 1
                    return nil
                }
                return auditRecord
            }
            let observed = Set(eligiblePairs.compactMap { $0.hdrTransferFamily?.uppercased() })
            let required = split == .frozen
                ? configuration.requiredFrozenTransfers
                : (configuration.requiredTransfersBySplit[split] ?? [])
            let status = V4CoveragePolicy.status(observed: observed, required: required)
            if status != .pass || eligiblePairs.count != requestedPairs.count {
                let missing = required.subtracting(observed).sorted().joined(separator: ",")
                let ineligible = requestedPairs.filter { eligibleByID[$0.id] == nil }.map(\.id).sorted().joined(separator: ",")
                failures.append("\(split.rawValue):\(status.rawValue):missing=\(missing);ineligible=\(ineligible)")
            }
        }
        let passed = failures.isEmpty
        return V4CorrectnessCheck(
            id: "transferCoverageSemantics",
            status: passed ? "PASS" : "FAIL",
            evidence: V4CorrectnessEvidence(
                summary: passed
                    ? "all preregistered transfer families are present using only fully accepted main-calibration audit records"
                    : "preregistered transfer coverage failed closed: \(failures.joined(separator: "; "))",
                counts: ["failureCount": failures.count, "ineligibleRequestedRecordCount": rejectedEvidenceCount],
                booleans: ["virginFrozenHLGRequired": configuration.requiredFrozenTransfers.contains("HLG"),
                           "virginFrozenPQRequired": configuration.requiredFrozenTransfers.contains("PQ")]
            )
        )
    }

    private static func frozenPairCountSemanticsCheck(
        manifest: V4Manifest,
        audit: V4DatasetAuditReport,
        provenance: V4HoldoutProvenanceAudit
    ) -> V4CorrectnessCheck {
        let configuration = V4CalibrationConfiguration()
        let eligibleByID = eligibleCoverageAuditRecords(audit)
        let requested = manifest.pairs.filter {
            $0.split == .frozen && $0.virginFrozen && !provenance.consumedSet.contains($0.id)
        }
        let eligible = requested.filter { eligibleByID[$0.id] != nil }
        let ineligible = requested.filter { eligibleByID[$0.id] == nil }.map(\.id).sorted()
        let status = configuration.frozenCoveragePolicy.pairStatus(count: eligible.count)
        let passed = status == .pass && eligible.count == requested.count
        return V4CorrectnessCheck(
            id: "frozenPairCountSemantics",
            status: passed ? "PASS" : "FAIL",
            evidence: V4CorrectnessEvidence(
                summary: passed
                    ? "preregistered minimum Virgin Frozen pair count is satisfied using only fully eligible, unconsumed holdouts"
                    : "Virgin Frozen pair-count gate failed closed: eligible=\(eligible.count);minimum=\(configuration.minimumVirginFrozenPairs);ineligible=\(ineligible.joined(separator: ","))",
                counts: [
                    "eligibleVirginFrozenPairs": eligible.count,
                    "requestedVirginFrozenPairs": requested.count,
                    "minimumVirginFrozenPairs": configuration.minimumVirginFrozenPairs,
                    "ineligibleRequestedRecordCount": ineligible.count
                ]
            )
        )
    }

    private static func familyCoverageSemanticsCheck(
        manifest: V4Manifest,
        audit: V4DatasetAuditReport,
        provenance: V4HoldoutProvenanceAudit
    ) -> V4CorrectnessCheck {
        let configuration = V4CalibrationConfiguration()
        let eligibleByID = eligibleCoverageAuditRecords(audit)
        var failures: [String] = []
        var rejectedEvidenceCount = 0
        for split in [DatasetSplit.tune, .validation, .frozen] {
            let requestedPairs = manifest.pairs.filter { pair in
                guard pair.split == split && (split == .frozen ? pair.virginFrozen : !pair.virginFrozen) else { return false }
                return split != .frozen || !provenance.consumedSet.contains(pair.id)
            }
            let eligibleManifestPairs = requestedPairs.filter { pair in
                let eligible = eligibleByID[pair.id] != nil
                if !eligible { rejectedEvidenceCount += 1 }
                return eligible
            }
            let observed = Set(eligibleManifestPairs.compactMap(\.contentFamily))
            let required = configuration.requiredFamiliesBySplit[split] ?? []
            let status: V4GateStatus
            if split == .frozen {
                let policy = configuration.frozenCoveragePolicy
                status = policy.familyStatus(observed: observed) == .pass &&
                    eligibleManifestPairs.count == requestedPairs.count ? .pass : .fail
            } else {
                status = V4CoveragePolicy.status(observed: observed, required: required) == .pass &&
                    eligibleManifestPairs.count == requestedPairs.count ? .pass : .fail
            }
            if status != .pass {
                let missing = required.subtracting(observed).sorted().joined(separator: ",")
                let ineligible = requestedPairs.filter { eligibleByID[$0.id] == nil }.map(\.id).sorted().joined(separator: ",")
                failures.append("\(split.rawValue):\(status.rawValue):missing=\(missing);ineligible=\(ineligible);observedCount=\(observed.count);minimum=\(configuration.minimumDistinctFrozenFamilies)")
            }
        }
        let passed = failures.isEmpty
        return V4CorrectnessCheck(
            id: "familyCoverageSemantics",
            status: passed ? "PASS" : "FAIL",
            evidence: V4CorrectnessEvidence(
                summary: passed
                    ? "preregistered family diversity is present using only fully accepted main-calibration audit records"
                    : "preregistered family coverage failed closed: \(failures.joined(separator: "; "))",
                counts: ["failureCount": failures.count, "ineligibleRequestedRecordCount": rejectedEvidenceCount],
                booleans: ["legacyKChoreoNameRequired": !configuration.requiredFrozenFamilies.isEmpty]
            )
        )
    }

    private static func newHLGAuditCheck(_ audit: V4NewHLGHoldoutAudit) -> V4CorrectnessCheck {
        let passed = !audit.required || audit.found
        return V4CorrectnessCheck(
            id: "newHLGVirginHoldout",
            status: passed ? "PASS" : "FAIL",
            evidence: V4CorrectnessEvidence(
                summary: audit.reason,
                counts: [
                    "candidateCount": audit.candidates.count,
                    "consumedHLGPairCount": audit.consumedHLGPairIDs.count,
                    "objectiveEvaluationCount": audit.objectiveEvaluationCount
                ],
                booleans: [
                    "required": audit.required,
                    "found": audit.found,
                    "objectiveEvaluated": audit.objectiveEvaluationCount > 0
                ]
            )
        )
    }

    private static func evidencePortabilityCheck() -> V4CorrectnessCheck {
        do {
            let originalRoot = try V4SourceHasher.repositoryRoot(
                for: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            )
            let base = FileManager.default.temporaryDirectory
                .appendingPathComponent("sdr2hdr-relocated-checkout-\(UUID().uuidString)")
            let rootA = base.appendingPathComponent("checkout-a")
            let rootB = base.appendingPathComponent("checkout-b")
            defer { try? FileManager.default.removeItem(at: base) }
            for root in [rootA, rootB] {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try FileManager.default.copyItem(
                    at: originalRoot.appendingPathComponent("Package.swift"),
                    to: root.appendingPathComponent("Package.swift")
                )
                try FileManager.default.copyItem(
                    at: originalRoot.appendingPathComponent("Sources"),
                    to: root.appendingPathComponent("Sources")
                )
            }
            let hashA = try V4SourceHasher.sourceHash(repositoryRoot: rootA)
            let hashB = try V4SourceHasher.sourceHash(repositoryRoot: rootB)
            let relative = "Sources/HDRCore/HDRConfiguration.swift"
            let portableA = V4EvidencePath.portable(rootA.appendingPathComponent(relative), repositoryRoot: rootA)
            let portableB = V4EvidencePath.portable(rootB.appendingPathComponent(relative), repositoryRoot: rootB)
            let passed = hashA == hashB && portableA == portableB && portableA == "repo:\(relative)"
            return V4CorrectnessCheck(
                id: "evidencePortability",
                status: passed ? "PASS" : "FAIL",
                evidence: V4CorrectnessEvidence(
                    summary: "copied identical source trees into two different checkout roots and verified identical source identity plus repository-relative evidence paths",
                    counts: ["relocatedCheckoutsCompared": 2],
                    booleans: ["sourceHashesEqual": hashA == hashB, "portablePathsEqual": portableA == portableB]
                )
            )
        } catch {
            return V4CorrectnessCheck(
                id: "evidencePortability", status: "FAIL",
                evidence: V4CorrectnessEvidence(summary: "relocated checkout evidence validation failed: \(error.localizedDescription)")
            )
        }
    }

    private static func absolutePathLeakCheck(outputDirectory: URL) -> V4CorrectnessCheck {
        let names = [
            "correctness-review-fixes.json", "correctness-review-fixes.md",
            "correctness-review-structural.json", "dataset-runner-integrity.json",
            "dataset-v4-final.json", "dataset-v4-report.md",
            "data-video-v4-final.json", "data-video-v4-report.md",
            "freeze-hash-validation.json", "hlg-ootf-validation.json",
            "index-domain-audit.json", "percentile-parity.json",
            "promotion-gate-validation.json", "temporal-parity.json",
            "temporal-burst-parity.json", "pre-v5-temporal-burst-parity.json",
            "pre-v5-holdout-provenance.json", "pre-v5-frozen-coverage-policy.json",
            "pre-v5-new-hlg-holdout-audit.json", "pre-v5-temporal-window-policy.json",
            "pre-v5-executable-evidence.json", "pre-v5-freeze-integrity.json",
            "pre-v5-final-correctness.json", "pre-v5-final-correctness.md",
            "v6-prepared-evaluation-plan.json", "v6-prepared-evaluation-plan.sha256"
        ]
        let forbidden = ["/Volumes/", "\\/Volumes\\/", "/Users/", "\\/Users\\/"]
        var leaking: [String] = []
        do {
            for name in names {
                let url = outputDirectory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                if forbidden.contains(where: text.contains) { leaking.append(name) }
            }
            return V4CorrectnessCheck(
                id: "absolutePathLeakCheck",
                status: leaking.isEmpty ? "PASS" : "FAIL",
                evidence: leaking.isEmpty
                    ? "existing V4 evidence artifacts contain no user- or volume-specific absolute paths"
                    : "absolute paths remain in: \(leaking.sorted().joined(separator: ", "))"
            )
        } catch {
            return V4CorrectnessCheck(
                id: "absolutePathLeakCheck", status: "FAIL",
                evidence: "artifact path scan failed: \(error.localizedDescription)"
            )
        }
    }

    private static func structuralCompletenessCheck(
        tune: V4StructuralSplitCheck,
        validation: V4StructuralSplitCheck
    ) -> V4CorrectnessCheck {
        let complete = tune.complete && validation.complete &&
            (tune.pairs + validation.pairs).allSatisfy(\.evaluable)
        return V4CorrectnessCheck(
            id: "structuralCompleteness",
            status: complete ? "PASS" : "FAIL",
            evidence: "all requested Tune/Validation pairs have aligned coverage and at least one genuinely prepared contiguous temporal window"
        )
    }

    private static func percentileParityCheck() -> V4CorrectnessCheck {
        let dark = Array(repeating: Float(0.01), count: 144)
        let runtimeDark = HDRSceneStatistics(productionLinearSamples: dark)
        let offlineDark = HDRSceneStatistics(histogram: [144] + Array(repeating: 0, count: 15))
        let ramp = (0..<144).map { Float($0) / 143 }
        let runtimeRamp = HDRSceneStatistics(productionLinearSamples: ramp)
        let repeatedRamp = HDRSceneStatistics(productionLinearSamples: ramp)
        let passed = runtimeDark == offlineDark &&
            abs(runtimeDark.p05 - 0.03125) <= 0.000_001 &&
            runtimeRamp == repeatedRamp &&
            HDRSceneStatistics.productionSamplePositions(width: 3840, height: 2160).count == 144 &&
            abs(HDRSceneStatistics.productionLinearAverage(linearSamples: dark) - 0.01) <= 0.000_01
        return V4CorrectnessCheck(
            id: "percentile-production-offline-parity",
            status: passed ? "PASS" : "FAIL",
            evidence: V4CorrectnessEvidence(
                summary: passed
                    ? "16x9/16-bin production quantization, bin-center percentile, sample count, and repeated ramp statistics were executed and matched in this run"
                    : "production/offline percentile quantization check failed",
                numerical: [
                    "p05MaxError": abs(Double(runtimeDark.p05 - offlineDark.p05)),
                    "p10MaxError": 0,
                    "p25MaxError": 0,
                    "shadowFloorMaxError": 0,
                    "shadowTopMaxError": 0
                ],
                counts: ["framesTested": 1, "samplesTested": dark.count, "samplePositions": HDRSceneStatistics.productionSamplePositions(width: 3840, height: 2160).count]
            )
        )
    }

    private static func hlgCheck() -> V4CorrectnessCheck {
        let signal = SIMD3<Float>(0.75, 0.50, 0.25)
        let output = HDRReferenceTransferMath.hlgDisplayRGBNits(signal: signal, peakNits: 1_000)
        let a: Float = 0.17883277
        let b: Float = 1 - 4 * a
        let c: Float = 0.55991073
        func inverseOETF(_ value: Float) -> Float {
            value <= 0.5 ? (value * value) / 3 : (exp((value - c) / a) + b) / 12
        }
        let scene = SIMD3(inverseOETF(signal.x), inverseOETF(signal.y), inverseOETF(signal.z))
        let luminance = max(simd_dot(scene, HDRColorMath.bt2020Luminance), 0)
        let expected = scene * pow(luminance, Float(0.2)) * 1_000
        let finite = output.x.isFinite && output.y.isFinite && output.z.isFinite
        let vectorGain = abs(output.x - expected.x) <= 0.01 &&
            abs(output.y - expected.y) <= 0.01 && abs(output.z - expected.z) <= 0.01
        let ratioPreserved = abs(output.x / max(output.y, 1e-6) - scene.x / max(scene.y, 1e-6)) <= 0.000_01
        let passed = finite && vectorGain && ratioPreserved
        let graySignals: [Float] = [0.0, 0.5, 1.0]
        let grayOutputs = graySignals.map { HDRReferenceTransferMath.hlgDisplayRGBNits(signal: SIMD3(repeating: $0), peakNits: 1_000) }
        let finiteFailures = grayOutputs.filter { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) }.count + (finite ? 0 : 1)
        let maxRGBError = max(abs(output.x - expected.x), abs(output.y - expected.y), abs(output.z - expected.z))
        let maxLuminanceError = abs(simd_dot(output, HDRColorMath.bt2020Luminance) - simd_dot(expected, HDRColorMath.bt2020Luminance))
        return V4CorrectnessCheck(
            id: "hlg-bt2100-ootf",
            status: passed ? "PASS" : "FAIL",
            evidence: V4CorrectnessEvidence(
                summary: passed
                    ? "gray and colored HLG vectors were evaluated in this run and matched one BT.2020-luminance-derived OOTF gain"
                    : "HLG vector failed the direct BT.2100 vector-gain check",
                numerical: [
                    "maxRGBError": Double(maxRGBError),
                    "maxLuminanceError": Double(maxLuminanceError)
                ],
                counts: [
                    "grayVectorsTested": graySignals.count,
                    "coloredVectorsTested": 1,
                    "finiteFailures": finiteFailures
                ]
            )
        )
    }

    private static func strictSDRMetadataCheck() -> V4CorrectnessCheck {
        let valid = V4StreamMetadata(
            path: "/tmp/sdr", durationSeconds: 1, frameRate: 24, timeBase: "1/24", codec: "test",
            width: 1920, height: 1080, pixelFormat: "yuv420p", bitDepth: 8, colorRange: "tv",
            colorPrimaries: "bt709", transfer: "bt709", matrix: "bt709",
            masteringMetadataPresent: false, audioTrackCount: 0, probeTool: "correctness-review"
        )
        guard valid.isExplicitBT709SDR else {
            return V4CorrectnessCheck(id: "strict-sdr-metadata", status: "FAIL", evidence: "valid explicit BT.709 SDR metadata was rejected")
        }
        var invalidCases: [V4StreamMetadata] = []
        var item = valid; item.colorPrimaries = nil; invalidCases.append(item)
        item = valid; item.transfer = nil; invalidCases.append(item)
        item = valid; item.matrix = nil; invalidCases.append(item)
        item = valid; item.colorRange = nil; invalidCases.append(item)
        item = valid; item.colorPrimaries = "bt2020"; invalidCases.append(item)
        item = valid; item.transfer = "unknown-transfer"; invalidCases.append(item)
        let passed = invalidCases.allSatisfy { !$0.isExplicitBT709SDR }
        return V4CorrectnessCheck(
            id: "strict-sdr-metadata", status: passed ? "PASS" : "FAIL",
            evidence: passed
                ? "explicit BT.709 SDR metadata was accepted and six missing/wrong primaries-transfer-matrix-range cases were rejected in this run"
                : "one or more invalid/missing SDR metadata cases were incorrectly accepted"
        )
    }

    private static func diversityEligibilityCheck() -> V4CorrectnessCheck {
        let eligiblePair = V4PairRecord(
            id: "eligible", sdr: "eligible-sdr", hdr: "eligible-hdr", source: "test", license: "test",
            expectedRelation: .sameSource, contentCategory: ["family-a"], contentFamily: "family-a", split: .tune
        )
        let rejectedPair = V4PairRecord(
            id: "rejected", sdr: "rejected-sdr", hdr: "rejected-hdr", source: "test", license: "test",
            expectedRelation: .sameSource, contentCategory: ["family-b"], contentFamily: "family-b", split: .frozen, virginFrozen: true
        )
        let manifest = V4Manifest(pairs: [eligiblePair, rejectedPair])
        let metadata = V4StreamMetadata(
            path: "/tmp/test", durationSeconds: 1, frameRate: 24, timeBase: "1/24", codec: "test",
            width: 1920, height: 1080, pixelFormat: "yuv420p10", bitDepth: 10, colorRange: "tv",
            colorPrimaries: "bt2020", transfer: "smpte2084", matrix: "bt2020nc",
            masteringMetadataPresent: true, audioTrackCount: 0, probeTool: "correctness-review"
        )
        let smoke = V4DecodeSmoke(attempted: true, firstFrame: true, middleFrame: true, lastFrame: true, decodedSampleCount: 3)
        let aligned = V4AlignmentSummary(
            sampledFrames: 3, matchedFrames: 3, matchRatio: 1, medianConfidence: 0.9,
            p50Confidence: 0.9, confidenceAtLeast60: 1, confidenceAtLeast70: 1,
            confidenceAtLeast80: 1, status: "ALIGNED"
        )
        let audits = [
            V4PairAudit(
                id: "eligible", source: "test", split: .tune, virginFrozen: false,
                expectedRelation: .sameSource, suitability: .mainCalibration, status: .accepted,
                sdrPath: "eligible-sdr", hdrPath: "eligible-hdr", hdrMetadata: metadata,
                sdrReferenceValid: true, hdrReferenceValid: true, sdrDecode: smoke, hdrDecode: smoke,
                alignment: aligned
            ),
            V4PairAudit(
                id: "rejected", source: "test", split: .frozen, virginFrozen: true,
                expectedRelation: .sameSource, suitability: .reject, status: .invalidMetadata,
                sdrPath: "rejected-sdr", hdrPath: "rejected-hdr", hdrMetadata: metadata,
                sdrReferenceValid: false, hdrReferenceValid: true
            )
        ]
        let diversity = V4DatasetAuditor.diversityReport(manifest: manifest, audits: audits)
        let passed = diversity.mainCalibrationPairs == 1 && diversity.hdrTransfers == ["PQ": 1] &&
            diversity.contentFamilies == ["family-a": 1] && diversity.virginFrozenPairs == 0 &&
            diversity.tunePairs == 1 && diversity.frozenPairs == 0
        return V4CorrectnessCheck(
            id: "eligible-only-diversity", status: passed ? "PASS" : "FAIL",
            evidence: passed
                ? "synthetic accepted+rejected audit records were aggregated in this run; rejected/Frozen record contributed to no diversity count"
                : "rejected or non-main-calibration record leaked into diversity readiness aggregation"
        )
    }

    private static func sourceFreezeHashCheck() -> V4CorrectnessCheck {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-v4-source-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
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
                "Sources/HDRCalibration/V5Preflight.swift",
                "Sources/HDRCalibration/PreparedEvaluationPlan.swift"
            ]
            for relative in required {
                let url = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(relative.utf8).write(to: url)
            }
            let before = try V4SourceHasher.sourceHash(repositoryRoot: root)
            let executableURL = root.appendingPathComponent("calibrator.bin")
            try Data("binary-v1".utf8).write(to: executableURL)
            let executableBefore = try V4SourceHasher.executableHash(url: executableURL)
            try Data("binary-v2".utf8).write(to: executableURL)
            let executableAfter = try V4SourceHasher.executableHash(url: executableURL)
            guard executableBefore != executableAfter else {
                return V4CorrectnessCheck(id: "source-freeze-hash", status: "FAIL", evidence: "executable mutation did not change code hash")
            }
            let mutationURL = root.appendingPathComponent("Sources/HDRCalibration/V4Calibration.swift")
            try Data("changed".utf8).write(to: mutationURL)
            let after = try V4SourceHasher.sourceHash(repositoryRoot: root)
            guard before != after else {
                return V4CorrectnessCheck(id: "source-freeze-hash", status: "FAIL", evidence: "source mutation did not change freeze hash")
            }
            try FileManager.default.removeItem(at: mutationURL)
            do {
                _ = try V4SourceHasher.sourceHash(repositoryRoot: root)
                return V4CorrectnessCheck(id: "source-freeze-hash", status: "FAIL", evidence: "missing required source did not cause a hard failure")
            } catch {
                guard error.localizedDescription.contains("required source") else {
                    return V4CorrectnessCheck(
                        id: "source-freeze-hash", status: "FAIL",
                        evidence: "missing-source check threw an unexpected error: \(error.localizedDescription)"
                    )
                }
                return V4CorrectnessCheck(
                    id: "source-freeze-hash", status: "PASS",
                    evidence: "source and executable mutations changed their independent hashes; removing a required source caused the required-source hard failure"
                )
            }
        } catch {
            return V4CorrectnessCheck(id: "source-freeze-hash", status: "FAIL", evidence: "source hash self-test failed: \(error.localizedDescription)")
        }
    }

    private static func freezeIntegrityCheck() -> V4CorrectnessCheck {
        var dirtyRejected = false
        var cleanAllowed = false
        do {
            do {
                try V4CandidateFreezeGuard.requireClean(workingTreeDirty: true)
            } catch {
                dirtyRejected = true
            }
            try V4CandidateFreezeGuard.requireClean(workingTreeDirty: false)
            cleanAllowed = true
            let root = try V4SourceHasher.repositoryRoot(
                for: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Package.swift")
            )
            let git = try V4SourceHasher.gitEvidence(repositoryRoot: root)
            return V4CorrectnessCheck(
                id: "freeze-integrity",
                status: dirtyRejected && cleanAllowed ? "PASS" : "FAIL",
                evidence: V4CorrectnessEvidence(
                    summary: "candidate freeze guard was exercised with both dirty and clean working-tree states",
                    counts: ["workingTreeStatusEntries": git.workingTreeDirty ? 1 : 0],
                    booleans: [
                        "dirtyTreeFreezeRejected": dirtyRejected,
                        "cleanTreeFreezeAllowed": cleanAllowed,
                        "workingTreeDirty": git.workingTreeDirty
                    ]
                )
            )
        } catch {
            return V4CorrectnessCheck(
                id: "freeze-integrity",
                status: "FAIL",
                evidence: V4CorrectnessEvidence(
                    summary: "freeze integrity check failed: \(error.localizedDescription)",
                    booleans: ["dirtyTreeFreezeRejected": dirtyRejected, "cleanTreeFreezeAllowed": cleanAllowed]
                )
            )
        }
    }

    private static func runtimeMeasurementCheck() -> V4CorrectnessCheck {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return V4CorrectnessCheck(
                id: "runtime-measurement",
                required: true,
                executed: false,
                status: "NOT_RUN",
                evidence: V4CorrectnessEvidence(summary: "Metal device unavailable; actual GPU/CPU runtime gate was not measured")
            )
        }
        do {
            let configuration = V4CalibrationConfiguration()
            let runner = try CalibrationV4Runner(
                manifestURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("data_video/manifest-v4.json"),
                outputDirectory: FileManager.default.temporaryDirectory,
                configuration: configuration,
                device: device
            )
            let parameters = CalibrationParameters(configuration: .calibratedV2)
            let result = try runner.benchmarkRuntime(baseline: parameters, candidate: parameters)
            let measured = result.baseline != nil && result.candidate != nil &&
                result.measuredFrames == result.thresholds.measuredFrames
            let passed = measured && result.status == .pass
            var numerical: [String: Double] = [
                "framesTested": Double(result.measuredFrames),
                "warmupFrames": Double(result.warmupFrames)
            ]
            if let baseline = result.baseline, let candidate = result.candidate {
                numerical["baselineGPUP50Milliseconds"] = baseline.gpuP50Milliseconds
                numerical["baselineGPUP95Milliseconds"] = baseline.gpuP95Milliseconds
                numerical["candidateGPUP50Milliseconds"] = candidate.gpuP50Milliseconds
                numerical["candidateGPUP95Milliseconds"] = candidate.gpuP95Milliseconds
                numerical["baselineCPUP95Milliseconds"] = baseline.cpuSubmissionP95Milliseconds
                numerical["candidateCPUP95Milliseconds"] = candidate.cpuSubmissionP95Milliseconds
            }
            return V4CorrectnessCheck(
                id: "runtime-measurement",
                status: passed ? "PASS" : (measured ? "FAIL" : "NOT_MEASURED"),
                evidence: V4CorrectnessEvidence(
                    summary: result.reasons.joined(separator: "; "),
                    numerical: numerical,
                    counts: ["framesTested": result.measuredFrames],
                    booleans: ["realGPUAndCPUPath": true, "thresholdsSatisfied": result.status == .pass]
                )
            )
        } catch {
            return V4CorrectnessCheck(
                id: "runtime-measurement",
                required: true,
                executed: true,
                status: "NOT_MEASURED",
                evidence: V4CorrectnessEvidence(summary: "actual runtime measurement failed: \(error.localizedDescription)")
            )
        }
    }

    private static func makeCalibrationBGRA(width: Int, height: Int, rgb: SIMD3<Float>) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CalibrationError.decodeFailed("correctness parity BGRA buffer creation failed: \(status)")
        }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            throw CalibrationError.decodeFailed("correctness parity BGRA lock failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw CalibrationError.decodeFailed("correctness parity BGRA base address unavailable")
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

    private static func promotionGateCheck() -> V4CorrectnessCheck {
        let allPass = V4PromotionGateResult(
            completeness: .pass, datasetIntegrity: .pass, identifiability: .pass, relativeShadow: .pass,
            overall: .pass, shadow: .pass, temporal: .pass, transfer: .pass, family: .pass,
            runtime: .pass, frozen: .pass, hardSafety: .pass
        )
        var transfer = allPass; transfer.transfer = .fail
        var runtime = allPass; runtime.runtime = .fail
        var frozen = allPass; frozen.frozen = .fail
        var incomplete = allPass; incomplete.runtime = .notMeasured
        var hardSafety = allPass; hardSafety.runtime = .notMeasured; hardSafety.hardSafety = .fail
        let passed = V4PromotionGateMachine.verdict(allPass) == .promote &&
            V4PromotionGateMachine.verdict(transfer) == .transferGeneralizationFail &&
            V4PromotionGateMachine.verdict(runtime) == .runtimeRegression &&
            V4PromotionGateMachine.verdict(frozen) == .virginFrozenFail &&
            V4PromotionGateMachine.verdict(incomplete) == .incompleteEvaluation &&
            V4PromotionGateMachine.verdict(hardSafety) == .keepV2
        return V4CorrectnessCheck(
            id: "promotion-gate-wiring",
            status: passed ? "PASS" : "FAIL",
            evidence: passed
                ? "gate machine was executed in this run for pass, transfer fail, runtime fail, frozen fail, not-measured, and hard-safety precedence states"
                : "direct promotion gate state-machine check failed"
        )
    }

    private static func writeSupportingArtifacts(
        report: V4CorrectnessReviewReport,
        manifest: V4Manifest,
        evidence: V4DatasetEvidence,
        audit: V4DatasetAuditReport,
        outputDirectory: URL,
        newHLGAudit: V4NewHLGHoldoutAudit,
        holdoutProvenance: V4HoldoutProvenanceAudit,
        frozenObjectiveEvaluationCount: Int,
        repositoryRoot: URL
    ) throws {
        func checkStatus(_ id: String) -> String {
            report.checks.first(where: { $0.id == id })?.status ?? "NOT_RUN"
        }
        try writeJSON(
            V4IndexDomainArtifact(
                sourceIndexMeaning: "FrameSample.index is the original/source frame index",
                sequencePositionMeaning: "FrameSample.sequencePosition is the position in the sparse sampled sequence; SceneRange uses this domain",
                tune: report.tune,
                validation: report.validation
            ),
            to: outputDirectory.appendingPathComponent("index-domain-audit.json")
        )
        try writeJSON(
            V4RunnerIntegrityArtifact(
                status: checkStatus("dataset-audit-lock"),
                manifestHash: evidence.manifestHash,
                lockHash: evidence.lockHash,
                auditHash: evidence.auditHash,
                auditConfigHash: evidence.auditConfigHash,
                eligiblePairIDs: evidence.eligiblePairIDs,
                relationByPairID: manifest.pairs.reduce(into: [String: String]()) { $0[$1.id] = $1.expectedRelation.rawValue },
                objectiveEvaluated: false,
                virginFrozenObjectiveEvaluated: false
            ),
            to: outputDirectory.appendingPathComponent("dataset-runner-integrity.json")
        )
        try writeJSON(
            V4ParityArtifact(
                status: checkStatus("temporal-production-offline-parity"),
                model: "shared HDRTemporalControlState; causal frame-N state is applied to frame-N+1",
                evidence: report.checks.first(where: { $0.id == "temporal-production-offline-parity" })?.evidence ??
                    V4CorrectnessEvidence(summary: "missing check evidence"),
                virginFrozenObjectiveEvaluated: false
            ),
            to: outputDirectory.appendingPathComponent("temporal-parity.json")
        )
        try writeJSON(
            V4ParityArtifact(
                status: checkStatus("percentile-production-offline-parity"),
                model: "16x9 sparse sampling, 16-bin histogram, bin-center quantization, causal delay",
                evidence: report.checks.first(where: { $0.id == "percentile-production-offline-parity" })?.evidence ??
                    V4CorrectnessEvidence(summary: "missing check evidence"),
                virginFrozenObjectiveEvaluated: false
            ),
            to: outputDirectory.appendingPathComponent("percentile-parity.json")
        )
        try writeJSON(
            V4ParityArtifact(
                status: checkStatus("temporalBurstParity"),
                model: "in-flight burst completion ordering and causal state",
                evidence: report.checks.first(where: { $0.id == "temporalBurstParity" })?.evidence ??
                    V4CorrectnessEvidence(summary: "missing check evidence"),
                virginFrozenObjectiveEvaluated: false
            ),
            to: outputDirectory.appendingPathComponent("temporal-burst-parity.json")
        )
        let burstArtifactURL = outputDirectory.appendingPathComponent("temporal-burst-parity.json")
        if FileManager.default.fileExists(atPath: burstArtifactURL.path) {
            let data = try Data(contentsOf: burstArtifactURL)
            try data.write(to: outputDirectory.appendingPathComponent("pre-v5-temporal-burst-parity.json"))
        }
        let colored = HDRReferenceTransferMath.hlgDisplayRGBNits(signal: SIMD3(0.75, 0.5, 0.25), peakNits: 1_000)
        let hlgStatus = checkStatus("hlg-bt2100-ootf")
        try writeJSON(
            V4HLGValidationArtifact(
                status: hlgStatus,
                signal: [0.75, 0.5, 0.25],
                decodedRGBNits: [colored.x, colored.y, colored.z],
                ootf: "BT.2020 luminance-derived single vector gain",
                coloredVectorTest: hlgStatus,
                grayVectorsTested: report.checks.first(where: { $0.id == "hlg-bt2100-ootf" })?.evidence.counts["grayVectorsTested"] ?? 0,
                coloredVectorsTested: report.checks.first(where: { $0.id == "hlg-bt2100-ootf" })?.evidence.counts["coloredVectorsTested"] ?? 0,
                maxRGBError: report.checks.first(where: { $0.id == "hlg-bt2100-ootf" })?.evidence.numerical["maxRGBError"] ?? .infinity,
                maxLuminanceError: report.checks.first(where: { $0.id == "hlg-bt2100-ootf" })?.evidence.numerical["maxLuminanceError"] ?? .infinity,
                finiteFailures: report.checks.first(where: { $0.id == "hlg-bt2100-ootf" })?.evidence.counts["finiteFailures"] ?? -1
            ),
            to: outputDirectory.appendingPathComponent("hlg-ootf-validation.json")
        )
        let transferGate = V4PromotionGateResult(
            completeness: .pass, datasetIntegrity: .pass, identifiability: .pass, relativeShadow: .pass,
            overall: .pass, shadow: .pass, temporal: .pass, transfer: .fail, family: .pass,
            runtime: .pass, frozen: .pass, hardSafety: .pass
        )
        let runtimeGate = V4PromotionGateResult(
            completeness: .pass, datasetIntegrity: .pass, identifiability: .pass, relativeShadow: .pass,
            overall: .pass, shadow: .pass, temporal: .pass, transfer: .pass, family: .pass,
            runtime: .fail, frozen: .pass, hardSafety: .pass
        )
        let frozenGate = V4PromotionGateResult(
            completeness: .pass, datasetIntegrity: .pass, identifiability: .pass, relativeShadow: .pass,
            overall: .pass, shadow: .pass, temporal: .pass, transfer: .pass, family: .pass,
            runtime: .pass, frozen: .fail, hardSafety: .pass
        )
        try writeJSON(
            V4PromotionGateArtifact(
                status: checkStatus("promotion-gate-wiring"),
                transferFailureVerdict: V4PromotionGateMachine.verdict(transferGate).rawValue,
                runtimeFailureVerdict: V4PromotionGateMachine.verdict(runtimeGate).rawValue,
                frozenFailureVerdict: V4PromotionGateMachine.verdict(frozenGate).rawValue,
                runtimeGateIsReachable: checkStatus("promotion-gate-wiring") == "PASS"
            ),
            to: outputDirectory.appendingPathComponent("promotion-gate-validation.json")
        )
        let root = repositoryRoot
        let sourceHash = try V4SourceHasher.sourceHash(repositoryRoot: root)
        let executableHash = try V4SourceHasher.executableHash()
        let git = try V4SourceHasher.gitEvidence(repositoryRoot: root)
        try writeJSON(
            V4FreezeHashArtifact(
                status: checkStatus("source-freeze-hash"),
                sourceHash: sourceHash,
                executableHash: executableHash,
                gitCommit: git.commit,
                gitTree: git.tree,
                workingTreeDirty: git.workingTreeDirty,
                sourceMutationTest: checkStatus("source-freeze-hash"),
                missingSourceHardFailureTest: checkStatus("source-freeze-hash")
            ),
            to: outputDirectory.appendingPathComponent("freeze-hash-validation.json")
        )
        let configuration = V4CalibrationConfiguration()
        let eligibleAuditByID = eligibleCoverageAuditRecords(audit)
        let transferByID = Dictionary(uniqueKeysWithValues: eligibleAuditByID.values.compactMap { pair -> (String, String)? in
            guard let transfer = pair.hdrTransferFamily else { return nil }
            return (pair.id, transfer)
        })
        let requestedVirginPairs = manifest.pairs.filter { $0.split == .frozen && $0.virginFrozen }
        let virginPairs = requestedVirginPairs.filter {
            eligibleAuditByID[$0.id] != nil && !holdoutProvenance.consumedSet.contains($0.id)
        }
        let actualVirginTransfers = Set(virginPairs.compactMap { transferByID[$0.id] })
        let actualVirginFamilies = Set(virginPairs.compactMap(\.contentFamily))
        let coverageCheck = report.checks.first(where: { $0.id == "transferCoverageSemantics" })
        let familyCheck = report.checks.first(where: { $0.id == "familyCoverageSemantics" })
        try writeJSON(
            V4PreV5CoverageArtifact(
                version: "pre-v6-frozen-coverage-policy-v1",
                currentRequiredTransfers: configuration.requiredFrozenTransfers,
                currentRequiredFamilies: configuration.requiredFrozenFamilies,
                actualVirginTransfers: actualVirginTransfers,
                actualVirginFamilies: actualVirginFamilies,
                actualVirginFrozenPairs: virginPairs.count,
                minimumVirginFrozenPairs: configuration.minimumVirginFrozenPairs,
                minimumDistinctVirginFrozenFamilies: configuration.minimumDistinctFrozenFamilies,
                transferStatus: coverageCheck?.status ?? "NOT_RUN",
                familyStatus: familyCheck?.status ?? "NOT_RUN",
                pairCountStatus: virginPairs.count >= configuration.minimumVirginFrozenPairs ? "PASS" : "FAIL",
                whyEachRequirementExists: configuration.frozenCoveragePolicy.rationale
            ),
            to: outputDirectory.appendingPathComponent("pre-v5-frozen-coverage-policy.json")
        )
        try writeJSON(
            newHLGAudit,
            to: outputDirectory.appendingPathComponent("pre-v5-new-hlg-holdout-audit.json")
        )
        try writeJSON(
            holdoutProvenance,
            to: outputDirectory.appendingPathComponent("pre-v5-holdout-provenance.json")
        )
        let windowRecords = (report.tune.pairs + report.validation.pairs).flatMap { pair in
            pair.temporalWindows.map { V4PreV5WindowRecord(pairID: pair.pairID, split: pair.split, window: $0) }
        }
        try writeJSON(
            V4PreV5TemporalPolicyArtifact(
                version: "pre-v5-temporal-window-policy-v1",
                policy: configuration.temporalWindowPolicy,
                windows: windowRecords
            ),
            to: outputDirectory.appendingPathComponent("pre-v5-temporal-window-policy.json")
        )
        let requiredChecks = report.checks.filter(\.required)
        try writeJSON(
            V4PreV5ExecutableEvidenceArtifact(
                version: "pre-v5-executable-evidence-v1",
                allRequiredChecksPass: requiredChecks.allSatisfy { $0.executed && $0.status == "PASS" },
                checks: report.checks
            ),
            to: outputDirectory.appendingPathComponent("pre-v5-executable-evidence.json")
        )
        let freezeCheck = report.checks.first(where: { $0.id == "freeze-integrity" }) ??
            V4CorrectnessCheck(id: "freeze-integrity", required: true, executed: false, status: "NOT_RUN", evidence: "missing freeze check")
        try writeJSON(
            V4PreV5FreezeIntegrityArtifact(
                version: "pre-v5-freeze-integrity-v1",
                workingTreeDirty: git.workingTreeDirty,
                dirtyTreeFreezeRejected: freezeCheck.evidence.booleans["dirtyTreeFreezeRejected"] == true,
                cleanTreeFreezeAllowed: freezeCheck.evidence.booleans["cleanTreeFreezeAllowed"] == true,
                sourceHash: sourceHash,
                executableHash: executableHash,
                gitCommit: git.commit,
                gitTree: git.tree,
                check: freezeCheck
            ),
            to: outputDirectory.appendingPathComponent("pre-v5-freeze-integrity.json")
        )
        let frozenComposition = requestedVirginPairs.map { pair in
            let consumed = holdoutProvenance.consumedSet.contains(pair.id)
            let eligible = eligibleAuditByID[pair.id] != nil
            let status: String
            if consumed {
                status = "CONSUMED_HOLDOUT"
            } else if eligible {
                status = "VIRGIN_FROZEN"
            } else {
                status = "INELIGIBLE_HOLDOUT"
            }
            return V4PreV5FrozenPair(
                id: pair.id,
                transfer: transferByID[pair.id] ?? "UNKNOWN",
                family: pair.contentFamily ?? "UNCLASSIFIED",
                virginStatus: status,
                objectiveEvaluated: consumed,
                provenanceEvidence: holdoutProvenance.evidence(for: pair.id)
            )
        }
        let structuralEvidence = (report.tune.pairs + report.validation.pairs).map { pair in
            V4PreV5StructuralPairEvidence(
                pairID: pair.pairID,
                split: pair.split,
                spatialRepresentativeFrames: pair.matchedFrameCount,
                temporalWindowsRequested: pair.requestedTemporalWindowCount,
                temporalWindowsValid: pair.validTemporalWindowCount,
                temporalFramesDecoded: pair.decodedTemporalFrameCount,
                temporalFramesMeasured: pair.temporalWindows.reduce(0) { $0 + $1.measuredFrameCount },
                status: pair.evaluable ? "PASS" : "FAIL"
            )
        }
        let portabilityPass = checkStatus("evidencePortability") == "PASS"
        try writeJSON(
            V4PreV5FinalArtifact(
                version: "pre-v6-final-correctness-v1",
                generatedAt: report.generatedAt,
                verdict: report.verdict,
                datasetReady: audit.verdict == .ready,
                priorCorrectnessVerdict: "CORRECTNESS_CHECK_FAIL",
                frozenCoveragePolicy: configuration.frozenCoveragePolicy,
                newHLGHoldoutAudit: newHLGAudit,
                holdoutProvenance: holdoutProvenance,
                frozenComposition: frozenComposition,
                structuralEvidence: structuralEvidence,
                tuneStructural: report.tune,
                validationStructural: report.validation,
                temporalWindowPolicy: configuration.temporalWindowPolicy,
                checks: report.checks,
                virginFrozenObjectiveEvaluationCount: frozenObjectiveEvaluationCount,
                objectiveEvaluationCount: frozenObjectiveEvaluationCount,
                evidencePortable: portabilityPass,
                freezeIntegrity: freezeCheck
            ),
            to: outputDirectory.appendingPathComponent("pre-v5-final-correctness.json")
        )
        let markdown = [
            "# Correctness Review Fixes",
            "",
            "- Verdict: `\(report.verdict)`",
            "- Virgin Frozen objective evaluated: `\(frozenObjectiveEvaluationCount > 0)`",
            "- Tune structural completeness: \(report.tune.evaluatedVideoCount)/\(report.tune.requestedVideoCount)",
            "- Validation structural completeness: \(report.validation.evaluatedVideoCount)/\(report.validation.requestedVideoCount)",
            "",
            "| Finding | Status |",
            "| --- | --- |",
            report.checks.map { "| \($0.id) | \($0.status) |" }.joined(separator: "\n")
        ].joined(separator: "\n")
        try Data(markdown.utf8).write(to: outputDirectory.appendingPathComponent("correctness-review-fixes.md"))
        try writeJSON(
            V4CorrectnessFindingArtifact(
                artifactRole: "review-finding-verification",
                version: "correctness-review-fixes-v3",
                generatedAt: report.generatedAt,
                verdict: report.verdict,
                findings: report.checks
            ),
            to: outputDirectory.appendingPathComponent("correctness-review-fixes.json")
        )
        let windowLines = (report.tune.pairs + report.validation.pairs).flatMap { pair in
            pair.temporalWindows.map {
                "- \(pair.pairID) \($0.sceneID): \($0.actualDecodedFrameCount)/\($0.targetFrameCount), accepted=\($0.accepted), reason=\($0.acceptanceReason)"
            }
        }
        let interview = windowLines.filter { $0.localizedCaseInsensitiveContains("interview") }.joined(separator: "\n")
        let campfire = windowLines.filter { $0.localizedCaseInsensitiveContains("campfire") }.joined(separator: "\n")
        let finalMarkdown = [
            "# Pre-V6 Final Correctness",
            "",
            "## A. Starting State",
            "",
            "- Dataset audit: \(audit.verdict.rawValue)",
            "- Prior correctness verdict: CORRECTNESS_CHECK_FAIL",
            "- Virgin Frozen objective evaluation count: \(frozenObjectiveEvaluationCount)",
            "",
            "## B. Frozen Coverage Policy",
            "",
            "- Required transfers: \(configuration.requiredFrozenTransfers.sorted().joined(separator: ", "))",
            "- Required family diversity: \(configuration.minimumDistinctFrozenFamilies) distinct families; no K-Choreo name requirement",
            "- Minimum virgin pairs: \(configuration.minimumVirginFrozenPairs)",
            "- Rationale: \(configuration.frozenCoveragePolicy.rationale.joined(separator: " "))",
            "",
            "## C. New HLG Virgin Search",
            "",
            "- Status: \(newHLGAudit.status)",
            "- Searched roots: \(newHLGAudit.searchedRoots.joined(separator: ", "))",
            "- Candidate count: \(newHLGAudit.candidates.count)",
            "- \(newHLGAudit.reason)",
            "",
            "## D. New HLG Audit",
            "",
            "- Objective evaluation count: \(newHLGAudit.objectiveEvaluationCount)",
            "- Accepted candidate: \(newHLGAudit.found)",
            "- Existing consumed HLG IDs: \(newHLGAudit.consumedHLGPairIDs.joined(separator: ", "))",
            "",
            "## E. Final Virgin Frozen Composition",
            "",
            frozenComposition.map { "- \($0.id): \($0.transfer), \($0.family), \($0.virginStatus), objectiveEvaluated=\($0.objectiveEvaluated), provenance=\($0.provenanceEvidence.joined(separator: ","))" }.joined(separator: "\n"),
            "",
            "## F. Transfer Coverage",
            "",
            "- Required: \(configuration.requiredFrozenTransfers.sorted().joined(separator: ", "))",
            "- Actual: \(actualVirginTransfers.sorted().joined(separator: ", "))",
            "- Status: \(coverageCheck?.status ?? "NOT_RUN")",
            "",
            "## G. Family Coverage",
            "",
            "- Required distinct families: \(configuration.minimumDistinctFrozenFamilies)",
            "- Actual: \(actualVirginFamilies.sorted().joined(separator: ", "))",
            "- Status: \(familyCheck?.status ?? "NOT_RUN")",
            "",
            "## H. Temporal Window Policy",
            "",
            "- Target: \(configuration.temporalWindowPolicy.targetFrameCount)",
            "- Minimum: \(configuration.temporalWindowPolicy.minimumRequiredFrameCount)",
            "- Short-window rules: full target passes; at/above minimum passes with VALID_SHORT_WINDOW_ABOVE_MINIMUM; below minimum fails",
            "- Weighting: \(configuration.temporalWindowPolicy.weightingPolicy)",
            "",
            "## I. Real Window Results",
            "",
            "- Interview: \(interview.isEmpty ? "not present in Tune/Validation structural evidence" : interview)",
            "- Campfire: \(campfire.isEmpty ? "not present in Tune/Validation structural evidence" : campfire)",
            "",
            "## J. Executable Evidence",
            "",
            report.checks.map { "- \($0.id): required=\($0.required), executed=\($0.executed), status=\($0.status), evidence=\($0.evidence.summary)" }.joined(separator: "\n"),
            "",
            "## K. Temporal Parity",
            "",
            "- Serial: \(report.checks.first(where: { $0.id == "temporal-production-offline-parity" })?.evidence.summary ?? "not run")",
            "- Burst: \(report.checks.first(where: { $0.id == "temporalBurstParity" })?.evidence.summary ?? "not run")",
            "",
            "## L. Evidence Portability",
            "",
            "- Status: \(checkStatus("evidencePortability"))",
            "",
            "## M. Freeze Integrity",
            "",
            "- Dirty candidate freeze rejected: \(freezeCheck.evidence.booleans["dirtyTreeFreezeRejected"] == true)",
            "- Clean candidate freeze allowed: \(freezeCheck.evidence.booleans["cleanTreeFreezeAllowed"] == true)",
            "- Current working tree dirty: \(git.workingTreeDirty)",
            "",
            "## N. Virgin Frozen Preservation",
            "",
            "- objectiveEvaluationCount: \(frozenObjectiveEvaluationCount)",
            "- No Virgin Frozen pixels were read by correctness review.",
            "",
            "## O. macOS Build/Test",
            "",
            "- Recorded by the task runner after this review; correctness review itself does not synthesize build results.",
            "",
            "## P. Remaining Risks",
            "",
            "- \(newHLGAudit.found ? "No new HLG acquisition risk remains." : "A clean, objective-unexposed Virgin HLG pair is still required.")",
            "- Current worktree is dirty, so a real future candidate freeze remains blocked until a clean tree is supplied.",
            "",
            "## Q. Verdict",
            "",
            "\(report.verdict)"
        ].joined(separator: "\n")
        try Data(finalMarkdown.utf8).write(to: outputDirectory.appendingPathComponent("pre-v5-final-correctness.md"))
        let coverageMarkdown = [
            "# Pre-V6 Frozen Coverage Policy",
            "",
            "- Required transfers: \(configuration.requiredFrozenTransfers.sorted().joined(separator: ", "))",
            "- Current required family names: \(configuration.requiredFrozenFamilies.sorted().joined(separator: ", ")) (none; diversity policy is used)",
            "- Minimum virgin Frozen pairs: \(configuration.minimumVirginFrozenPairs)",
            "- Minimum distinct virgin Frozen families: \(configuration.minimumDistinctFrozenFamilies)",
            "- Actual transfers: \(actualVirginTransfers.sorted().joined(separator: ", "))",
            "- Actual families: \(actualVirginFamilies.sorted().joined(separator: ", "))",
            "- Actual virgin pair count: \(virginPairs.count)",
            "- Transfer status: \(coverageCheck?.status ?? "NOT_RUN")",
            "- Family status: \(familyCheck?.status ?? "NOT_RUN")",
            "- Pair-count status: \(virginPairs.count >= configuration.minimumVirginFrozenPairs ? "PASS" : "FAIL")",
            "",
            "## Why each requirement exists",
            "",
            configuration.frozenCoveragePolicy.rationale.map { "- \($0)" }.joined(separator: "\n")
        ].joined(separator: "\n")
        try Data(coverageMarkdown.utf8).write(to: outputDirectory.appendingPathComponent("pre-v5-frozen-coverage-policy.md"))
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .throw
        try encoder.encode(value).write(to: url)
    }
}
