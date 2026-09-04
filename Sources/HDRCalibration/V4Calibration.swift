import CoreVideo
import CryptoKit
import Foundation
import HDRCore
import Metal

public enum CalibrationV4Verdict: String, Codable, Sendable {
    case promote = "PROMOTE_CALIBRATED_V4"
    case keepV2 = "KEEP_CALIBRATED_V2"
    case relativeShadowInsufficient = "RELATIVE_SHADOW_MODEL_INSUFFICIENT"
    case validationFail = "VALIDATION_FAIL"
    case transferGeneralizationFail = "TRANSFER_GENERALIZATION_FAIL"
    case virginFrozenFail = "VIRGIN_FROZEN_FAIL"
    case shadowGeneralizationFail = "SHADOW_GENERALIZATION_FAIL"
    case runtimeRegression = "RUNTIME_REGRESSION"
    case identifiabilityFail = "IDENTIFIABILITY_FAIL"
    case incompleteEvaluation = "INCOMPLETE_EVALUATION"
}

public struct V4RuntimeThresholds: Codable, Sendable {
    public var width: Int = 1_920
    public var height: Int = 1_080
    public var warmupFrames: Int = 30
    public var measuredFrames: Int = 300
    public var gpuP50RelativeTolerance: Double = 0.08
    public var gpuP95RelativeTolerance: Double = 0.10
    public var cpuP95RelativeTolerance: Double = 0.15
    public var absoluteToleranceMilliseconds: Double = 0.10

    public var isValid: Bool {
        width > 0 && height > 0 && warmupFrames >= 0 && measuredFrames > 0 &&
            gpuP50RelativeTolerance.isFinite && gpuP50RelativeTolerance >= 0 &&
            gpuP95RelativeTolerance.isFinite && gpuP95RelativeTolerance >= 0 &&
            cpuP95RelativeTolerance.isFinite && cpuP95RelativeTolerance >= 0 &&
            absoluteToleranceMilliseconds.isFinite && absoluteToleranceMilliseconds >= 0
    }

    public init() {}
}

public struct V4SafetyThresholds: Codable, Sendable {
    public var shadowErrorTolerance: Double = 0.01
    public var shadowLiftTolerance: Double = 0.005
    public var temporalFlickerRelativeTolerance: Double = 0.05
    public var temporalFlickerAbsoluteTolerance: Double = 0.002
    public var highlightRelativeTolerance: Double = 0.05
    public var midtoneRelativeTolerance: Double = 0.05
    public var hueRelativeTolerance: Double = 0.05
    public var catastrophicSceneRegression: Double = 0.20
    public var frozenMinimumImprovement: Double = 0.05
    public var frozenPerVideoRegressionTolerance: Double = 0.02
    public var zeroTolerance: Double = 0.000001
    public var runtime: V4RuntimeThresholds? = V4RuntimeThresholds()

    public var runtimeThresholds: V4RuntimeThresholds { runtime ?? V4RuntimeThresholds() }

    public init() {}
}

public enum V4GateStatus: String, Codable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case notMeasured = "NOT_MEASURED"
}

public enum V4PromotionMath {
    /// Internal promotion values are ratios: 0.05 means 5 percent.
    public static func improvementRatio(baseline: Double, candidate: Double) -> Double {
        guard baseline.isFinite, candidate.isFinite, baseline > 0 else { return -.infinity }
        return (baseline - candidate) / baseline
    }

    public static func improvementPercent(baseline: Double, candidate: Double) -> Double {
        improvementRatio(baseline: baseline, candidate: candidate) * 100
    }

    public static func passesMinimumImprovement(baseline: Double, candidate: Double, minimumRatio: Double) -> Bool {
        improvementRatio(baseline: baseline, candidate: candidate) >= minimumRatio
    }
}

public struct V4PromotionGateResult: Codable, Sendable {
    public var completeness: V4GateStatus
    public var datasetIntegrity: V4GateStatus
    public var identifiability: V4GateStatus
    public var relativeShadow: V4GateStatus
    public var overall: V4GateStatus
    public var shadow: V4GateStatus
    public var temporal: V4GateStatus
    public var transfer: V4GateStatus
    public var family: V4GateStatus
    public var runtime: V4GateStatus
    public var frozen: V4GateStatus
    public var hardSafety: V4GateStatus

    public init(
        completeness: V4GateStatus = .notMeasured,
        datasetIntegrity: V4GateStatus = .notMeasured,
        identifiability: V4GateStatus = .notMeasured,
        relativeShadow: V4GateStatus = .notMeasured,
        overall: V4GateStatus = .notMeasured,
        shadow: V4GateStatus = .notMeasured,
        temporal: V4GateStatus = .notMeasured,
        transfer: V4GateStatus = .notMeasured,
        family: V4GateStatus = .notMeasured,
        runtime: V4GateStatus = .notMeasured,
        frozen: V4GateStatus = .notMeasured,
        hardSafety: V4GateStatus = .notMeasured
    ) {
        self.completeness = completeness
        self.datasetIntegrity = datasetIntegrity
        self.identifiability = identifiability
        self.relativeShadow = relativeShadow
        self.overall = overall
        self.shadow = shadow
        self.temporal = temporal
        self.transfer = transfer
        self.family = family
        self.runtime = runtime
        self.frozen = frozen
        self.hardSafety = hardSafety
    }
}

public enum V4FrozenStatus: String, Codable, Sendable {
    case notOpened = "NOT_OPENED"
    case openedAndEvaluated = "OPENED_AND_EVALUATED"
    case notEvaluatedDuePrecondition = "NOT_EVALUATED_DUE_PRECONDITION"
}

public struct V4PreFrozenGateResult: Codable, Sendable {
    public var datasetIntegrity: V4GateStatus
    public var identifiability: V4GateStatus
    public var validationOverall: V4GateStatus
    public var validationShadow: V4GateStatus
    public var validationTemporal: V4GateStatus
    public var transferCoverage: V4GateStatus
    /// Minimum Virgin Frozen pair-count gate. Kept separate from family
    /// diversity so a 2-family/2-pair holdout reports family=PASS while still
    /// remaining ineligible to open Frozen until the preregistered count is met.
    public var pairCoverage: V4GateStatus
    public var familyCoverage: V4GateStatus
    public var runtime: V4GateStatus

    public init(
        datasetIntegrity: V4GateStatus = .notMeasured,
        identifiability: V4GateStatus = .notMeasured,
        validationOverall: V4GateStatus = .notMeasured,
        validationShadow: V4GateStatus = .notMeasured,
        validationTemporal: V4GateStatus = .notMeasured,
        transferCoverage: V4GateStatus = .notMeasured,
        pairCoverage: V4GateStatus = .notMeasured,
        familyCoverage: V4GateStatus = .notMeasured,
        runtime: V4GateStatus = .notMeasured
    ) {
        self.datasetIntegrity = datasetIntegrity
        self.identifiability = identifiability
        self.validationOverall = validationOverall
        self.validationShadow = validationShadow
        self.validationTemporal = validationTemporal
        self.transferCoverage = transferCoverage
        self.pairCoverage = pairCoverage
        self.familyCoverage = familyCoverage
        self.runtime = runtime
    }

    private enum CodingKeys: String, CodingKey {
        case datasetIntegrity, identifiability, validationOverall, validationShadow, validationTemporal
        case transferCoverage, pairCoverage, familyCoverage, runtime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        datasetIntegrity = try container.decode(V4GateStatus.self, forKey: .datasetIntegrity)
        identifiability = try container.decode(V4GateStatus.self, forKey: .identifiability)
        validationOverall = try container.decode(V4GateStatus.self, forKey: .validationOverall)
        validationShadow = try container.decode(V4GateStatus.self, forKey: .validationShadow)
        validationTemporal = try container.decode(V4GateStatus.self, forKey: .validationTemporal)
        transferCoverage = try container.decode(V4GateStatus.self, forKey: .transferCoverage)
        // Older pre-v5 artifacts predate the independent pair-count gate.
        // Decode them fail-closed rather than treating family coverage as a
        // proxy for pair-count completeness.
        pairCoverage = try container.decodeIfPresent(V4GateStatus.self, forKey: .pairCoverage) ?? .notMeasured
        familyCoverage = try container.decode(V4GateStatus.self, forKey: .familyCoverage)
        runtime = try container.decode(V4GateStatus.self, forKey: .runtime)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(datasetIntegrity, forKey: .datasetIntegrity)
        try container.encode(identifiability, forKey: .identifiability)
        try container.encode(validationOverall, forKey: .validationOverall)
        try container.encode(validationShadow, forKey: .validationShadow)
        try container.encode(validationTemporal, forKey: .validationTemporal)
        try container.encode(transferCoverage, forKey: .transferCoverage)
        try container.encode(pairCoverage, forKey: .pairCoverage)
        try container.encode(familyCoverage, forKey: .familyCoverage)
        try container.encode(runtime, forKey: .runtime)
    }

    public var failures: [String] {
        [
            ("datasetIntegrity", datasetIntegrity),
            ("identifiability", identifiability),
            ("validationOverall", validationOverall),
            ("validationShadow", validationShadow),
            ("validationTemporal", validationTemporal),
            ("transferCoverage", transferCoverage),
            ("pairCoverage", pairCoverage),
            ("familyCoverage", familyCoverage),
            ("runtime", runtime)
        ].compactMap { name, status in
            status == .pass ? nil : "\(name)=\(status.rawValue)"
        }
    }

    public var canOpenVirginFrozen: Bool { failures.isEmpty }
}

public enum V4PromotionGateMachine {
    public static func verdict(_ gates: V4PromotionGateResult) -> CalibrationV4Verdict {
        // Hard-safety and frozen-holdout failures are more informative than a
        // runtime failure and must never be masked by an unmeasured runtime.
        if gates.hardSafety == .fail { return .keepV2 }
        if gates.completeness == .fail || gates.datasetIntegrity == .fail { return .validationFail }
        if gates.identifiability == .fail { return .identifiabilityFail }
        if gates.relativeShadow == .fail { return .relativeShadowInsufficient }
        if gates.overall == .fail { return .validationFail }
        if gates.shadow == .fail { return .shadowGeneralizationFail }
        if gates.temporal == .fail { return .validationFail }
        if gates.transfer == .fail { return .transferGeneralizationFail }
        if gates.family == .fail { return .validationFail }
        if gates.frozen == .fail { return .virginFrozenFail }
        if gates.runtime == .fail { return .runtimeRegression }

        let statuses = [
            gates.completeness, gates.datasetIntegrity, gates.identifiability,
            gates.relativeShadow, gates.overall, gates.shadow, gates.temporal,
            gates.transfer, gates.family, gates.runtime, gates.frozen, gates.hardSafety
        ]
        if statuses.contains(.notMeasured) { return .incompleteEvaluation }
        return .promote
    }
}

public struct V4RuntimeMeasurement: Codable, Sendable {
    public var gpuP50Milliseconds: Double
    public var gpuP95Milliseconds: Double
    public var gpuP99Milliseconds: Double
    public var cpuSubmissionP50Milliseconds: Double
    public var cpuSubmissionP95Milliseconds: Double
    public var cpuSubmissionP99Milliseconds: Double

    public init(
        gpuP50Milliseconds: Double,
        gpuP95Milliseconds: Double,
        gpuP99Milliseconds: Double,
        cpuSubmissionP50Milliseconds: Double,
        cpuSubmissionP95Milliseconds: Double,
        cpuSubmissionP99Milliseconds: Double
    ) {
        self.gpuP50Milliseconds = gpuP50Milliseconds
        self.gpuP95Milliseconds = gpuP95Milliseconds
        self.gpuP99Milliseconds = gpuP99Milliseconds
        self.cpuSubmissionP50Milliseconds = cpuSubmissionP50Milliseconds
        self.cpuSubmissionP95Milliseconds = cpuSubmissionP95Milliseconds
        self.cpuSubmissionP99Milliseconds = cpuSubmissionP99Milliseconds
    }

    public var isValid: Bool {
        let finite = [gpuP50Milliseconds, gpuP95Milliseconds, gpuP99Milliseconds,
                      cpuSubmissionP50Milliseconds, cpuSubmissionP95Milliseconds,
                      cpuSubmissionP99Milliseconds].allSatisfy { $0.isFinite }
        return finite &&
            gpuP50Milliseconds > 0 && gpuP50Milliseconds <= gpuP95Milliseconds && gpuP95Milliseconds <= gpuP99Milliseconds &&
            cpuSubmissionP50Milliseconds >= 0 && cpuSubmissionP50Milliseconds <= cpuSubmissionP95Milliseconds &&
            cpuSubmissionP95Milliseconds <= cpuSubmissionP99Milliseconds
    }
}

public struct V4RuntimeBenchmarkResult: Codable, Sendable {
    public var status: V4GateStatus
    public var deviceName: String
    public var width: Int
    public var height: Int
    public var warmupFrames: Int
    public var measuredFrames: Int
    public var thresholds: V4RuntimeThresholds
    public var baseline: V4RuntimeMeasurement?
    public var candidate: V4RuntimeMeasurement?
    public var reasons: [String]

    public init(
        status: V4GateStatus,
        deviceName: String,
        width: Int,
        height: Int,
        warmupFrames: Int,
        measuredFrames: Int,
        thresholds: V4RuntimeThresholds,
        baseline: V4RuntimeMeasurement?,
        candidate: V4RuntimeMeasurement?,
        reasons: [String]
    ) {
        self.status = status
        self.deviceName = deviceName
        self.width = width
        self.height = height
        self.warmupFrames = warmupFrames
        self.measuredFrames = measuredFrames
        self.thresholds = thresholds
        self.baseline = baseline
        self.candidate = candidate
        self.reasons = reasons
    }
}

public enum V4RuntimeGate {
    public static func status(
        baseline: V4RuntimeMeasurement,
        candidate: V4RuntimeMeasurement,
        thresholds: V4RuntimeThresholds
    ) -> (V4GateStatus, [String]) {
        guard baseline.isValid, candidate.isValid, thresholds.isValid else {
            return (.notMeasured, ["runtime measurement or benchmark configuration is invalid"])
        }
        func allowed(_ baselineValue: Double, _ relative: Double) -> Double {
            baselineValue * (1 + relative) + thresholds.absoluteToleranceMilliseconds
        }
        var reasons: [String] = []
        if candidate.gpuP50Milliseconds > allowed(baseline.gpuP50Milliseconds, thresholds.gpuP50RelativeTolerance) {
            reasons.append(String(format: "GPU p50 regression: V2 %.3f ms, V4 %.3f ms", baseline.gpuP50Milliseconds, candidate.gpuP50Milliseconds))
        }
        if candidate.gpuP95Milliseconds > allowed(baseline.gpuP95Milliseconds, thresholds.gpuP95RelativeTolerance) {
            reasons.append(String(format: "GPU p95 regression: V2 %.3f ms, V4 %.3f ms", baseline.gpuP95Milliseconds, candidate.gpuP95Milliseconds))
        }
        if candidate.cpuSubmissionP95Milliseconds > allowed(baseline.cpuSubmissionP95Milliseconds, thresholds.cpuP95RelativeTolerance) {
            reasons.append(String(format: "CPU submission p95 regression: V2 %.3f ms, V4 %.3f ms", baseline.cpuSubmissionP95Milliseconds, candidate.cpuSubmissionP95Milliseconds))
        }
        if reasons.isEmpty {
            reasons.append(String(format: "runtime within tolerance: GPU p50 %.3f→%.3f ms, GPU p95 %.3f→%.3f ms, CPU p95 %.3f→%.3f ms", baseline.gpuP50Milliseconds, candidate.gpuP50Milliseconds, baseline.gpuP95Milliseconds, candidate.gpuP95Milliseconds, baseline.cpuSubmissionP95Milliseconds, candidate.cpuSubmissionP95Milliseconds))
            return (.pass, reasons)
        }
        return (.fail, reasons)
    }
}

public struct V4ParameterBounds: Codable, Sendable {
    public var paperWhiteNits: ClosedRange<Float> = 190...245
    public var peakNits: ClosedRange<Float> = 900...1_500
    public var highlightStrength: ClosedRange<Float> = 0.42...0.86
    public var contrastStrength: ClosedRange<Float> = 0.50...0.95
    public var saturationCompensation: ClosedRange<Float> = 0.10...0.50
    public var shadowProtection: ClosedRange<Float> = 0.05...1.0
    public var temporalStability: ClosedRange<Float> = 0.20...0.98

    public init() {}
}

public struct V4CalibrationConfiguration: Codable, Sendable {
    public var version = "calibration-v4-scene-relative-shadow"
    public var splitSeed: UInt64 = 92
    public var searchSeed: UInt64 = 20_260_824
    public var globalCandidates: Int = 128
    public var localCandidates: Int = 64
    public var validationTopCount: Int = 8
    public var maxFramesPerScene: Int = 8
    public var confidenceThreshold: Double = 0.60
    public var referenceTargetPeakNits: Float = 1_000
    public var bounds = V4ParameterBounds()
    public var weights: V2ObjectiveWeights = {
        var value = V2ObjectiveWeights()
        value.shadow = 0.15
        value.temporal = 0.10
        return value
    }()
    /// Frozen before any Virgin Frozen access. This is part of the promotion
    /// protocol rather than an after-the-fact tuning knob.
    public var safety = V4SafetyThresholds()
    /// Preregistered before any Virgin Frozen objective access. Tune and
    /// Validation retain their explicit source-family requirements. Frozen
    /// family generalisation is deliberately expressed by diversity below,
    /// rather than by requiring the legacy `K-Choreo` label.
    public var requiredTransfersBySplit: [DatasetSplit: Set<String>] = [
        .tune: ["HLG", "PQ"],
        .validation: ["HLG", "PQ"],
        .frozen: ["HLG", "PQ"]
    ]
    public var requiredFamiliesBySplit: [DatasetSplit: Set<String>] = [
        .tune: ["K-Choreo", "LIVE"],
        .validation: ["K-Choreo", "LIVE"],
        .frozen: []
    ]

    public init() {}

    /// V5 holdout policy is exposed as named values so callers cannot infer a
    /// requirement from an evaluation result or silently omit a subgroup.
    public var frozenCoveragePolicy: V4FrozenCoveragePolicy {
        V4FrozenCoveragePolicy(
            requiredTransfers: requiredTransfersBySplit[.frozen] ?? V4FrozenCoveragePolicy.v5.requiredTransfers,
            requiredFamilies: requiredFamiliesBySplit[.frozen] ?? [],
            minimumVirginFrozenPairs: V4FrozenCoveragePolicy.v5.minimumVirginFrozenPairs,
            minimumDistinctVirginFrozenFamilies: V4FrozenCoveragePolicy.v5.minimumDistinctVirginFrozenFamilies,
            rationale: V4FrozenCoveragePolicy.v5.rationale
        )
    }

    public var requiredFrozenTransfers: Set<String> { frozenCoveragePolicy.requiredTransfers }
    public var requiredFrozenFamilies: Set<String> { frozenCoveragePolicy.requiredFamilies }
    public var minimumVirginFrozenPairs: Int { frozenCoveragePolicy.minimumVirginFrozenPairs }
    public var minimumDistinctFrozenFamilies: Int { frozenCoveragePolicy.minimumDistinctVirginFrozenFamilies }
    public var temporalWindowPolicy: V4TemporalWindowPolicy { .v5 }
}

public enum V4CoveragePolicy {
    public static func status(observed: Set<String>, required: Set<String>?) -> V4GateStatus {
        guard let required, !required.isEmpty else { return .notMeasured }
        return required.isSubset(of: observed) ? .pass : .fail
    }
}

public struct V4SensitivityRecord: Codable, Sendable {
    public var parameter: String
    public var value: Float
    public var objective: Double
    public var shadowError: Double
    public var shadowLiftRatio: Double
    public var midtoneError: Double
    public var highlightError: Double
    public var temporalFlicker: Double
    public var highlightPumping: Double
    public var sceneCutRecovery: Double
}

public struct V4CandidateRecord: Codable, Sendable {
    public var id: String
    public var stage: String
    public var parameters: CalibrationParameters
    public var tune: V2DatasetEvaluation
    public var validation: V2DatasetEvaluation?
    public var constraintsPassed: Bool
    public var rejectionReasons: [String]
}

public struct V4FreezeArtifact: Codable, Sendable {
    public var version: String
    public var candidateID: String
    public var parameters: CalibrationParameters
    public var parameterHash: String
    public var codeHash: String
    public var manifestHash: String
    public var objectiveHash: String
    public var sourceHash: String?
    public var executableHash: String?
    public var datasetLockHash: String?
    public var auditArtifactHash: String?
    public var evaluationConfigHash: String?
    public var gitCommit: String?
    public var gitTree: String?
    public var workingTreeDirty: Bool?
    public var finalCandidateFrozen: Bool
    public var frozenOpened: Bool

    public init(
        version: String = "calibration-v4-freeze",
        candidateID: String,
        parameters: CalibrationParameters,
        parameterHash: String,
        codeHash: String,
        manifestHash: String,
        objectiveHash: String,
        finalCandidateFrozen: Bool,
        frozenOpened: Bool,
        sourceHash: String? = nil,
        executableHash: String? = nil,
        datasetLockHash: String? = nil,
        auditArtifactHash: String? = nil,
        evaluationConfigHash: String? = nil,
        gitCommit: String? = nil,
        gitTree: String? = nil,
        workingTreeDirty: Bool? = nil
    ) {
        self.version = version
        self.candidateID = candidateID
        self.parameters = parameters
        self.parameterHash = parameterHash
        self.codeHash = codeHash
        self.manifestHash = manifestHash
        self.objectiveHash = objectiveHash
        self.sourceHash = sourceHash
        self.executableHash = executableHash
        self.datasetLockHash = datasetLockHash
        self.auditArtifactHash = auditArtifactHash
        self.evaluationConfigHash = evaluationConfigHash
        self.gitCommit = gitCommit
        self.gitTree = gitTree
        self.workingTreeDirty = workingTreeDirty
        self.finalCandidateFrozen = finalCandidateFrozen
        self.frozenOpened = frozenOpened
    }
}

public struct V4DatasetEvidence: Codable, Sendable {
    public let manifestHash: String
    public let lockHash: String
    public let auditHash: String
    public let auditConfigHash: String
    public let eligiblePairIDs: [String]

    public init(
        manifestHash: String,
        lockHash: String,
        auditHash: String,
        auditConfigHash: String,
        eligiblePairIDs: [String]
    ) {
        self.manifestHash = manifestHash
        self.lockHash = lockHash
        self.auditHash = auditHash
        self.auditConfigHash = auditConfigHash
        self.eligiblePairIDs = eligiblePairIDs.sorted()
    }
}

/// Validates the immutable dataset evidence required before a calibration
/// runner may decode any candidate frames. A READY string alone is not proof
/// of pair eligibility or media identity.
public enum V4EvidenceMediaScope: Sendable, Equatable {
    /// Verify the current media bytes for every manifest record.  This is the
    /// historical dataset-audit mode.
    case all
    /// Verify manifest/audit/lock evidence for Frozen records without opening
    /// their media.  Correctness review uses this mode so Frozen inputs remain
    /// sealed until the explicit objective guard.
    case tuneValidationOnly
}

public enum V4DatasetEvidenceValidator {
    public static func validate(
        manifestURL: URL,
        auditURL: URL,
        lockURL: URL,
        requiredPairIDs: Set<String>? = nil,
        mediaScope: V4EvidenceMediaScope = .all
    ) throws -> V4DatasetEvidence {
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(V4Manifest.self, from: manifestData)
        try manifest.validate(relativeTo: manifestURL)
        let manifestHash = try V4DatasetIntegrity.manifestSHA256(url: manifestURL)

        let lockData = try Data(contentsOf: lockURL)
        let lock = try JSONDecoder().decode(V4DatasetLock.self, from: lockData)
        guard lock.manifestSHA256 == manifestHash else {
            throw CalibrationError.invalidManifest("dataset lock manifest hash does not match current manifest")
        }

        let auditData = try Data(contentsOf: auditURL)
        let audit = try JSONDecoder().decode(V4DatasetAuditReport.self, from: auditData)
        guard audit.verdict == .ready else {
            throw CalibrationError.invalidManifest("dataset audit is not READY: \(audit.verdict.rawValue)")
        }
        guard audit.version == V4DatasetAuditor.auditEvidenceVersion,
              let auditConfigHash = audit.auditConfigHash,
              auditConfigHash == V4DatasetAuditor.auditConfigurationHash else {
            throw CalibrationError.invalidManifest("dataset audit evidence version/configuration is stale or missing")
        }
        guard audit.manifestSHA256 == manifestHash else {
            throw CalibrationError.invalidManifest("dataset audit manifest hash does not match current manifest")
        }
        guard !audit.objectiveEvaluated, audit.frozenObjectiveEvaluated.isEmpty else {
            throw CalibrationError.invalidCandidate("dataset audit evidence already contains objective evaluation")
        }

        var auditByID: [String: V4PairAudit] = [:]
        for record in audit.pairs {
            guard auditByID.updateValue(record, forKey: record.id) == nil else {
                throw CalibrationError.invalidManifest("dataset audit contains duplicate pair id: \(record.id)")
            }
        }
        let manifestIDs = Set(manifest.pairs.map(\.id))
        guard Set(auditByID.keys) == manifestIDs else {
            throw CalibrationError.invalidManifest("dataset audit pair IDs do not exactly match manifest")
        }
        if let requiredPairIDs, !requiredPairIDs.isSubset(of: manifestIDs) {
            throw CalibrationError.invalidManifest("requested calibration pair is absent from manifest")
        }

        var lockByPath: [String: V4FileDigest] = [:]
        for file in lock.files {
            guard lockByPath.updateValue(file, forKey: file.path) == nil else {
                throw CalibrationError.invalidManifest("dataset lock contains duplicate path: \(file.path)")
            }
        }
        let repositoryRoot = try V4SourceHasher.repositoryRoot(for: manifestURL)
        for pair in manifest.pairs {
            guard pair.expectedRelation.supportsMainCalibration else {
                throw CalibrationError.invalidManifest("pair \(pair.id) has relation \(pair.expectedRelation.rawValue), which is not eligible for main calibration")
            }
            guard let record = auditByID[pair.id],
                  record.expectedRelation == pair.expectedRelation,
                  record.suitability == .mainCalibration,
                  record.status == .accepted,
                  record.sdrReferenceValid == true,
                  record.hdrReferenceValid == true,
                  record.sdrDecode.passed,
                  record.hdrDecode.passed,
                  V4AlignmentPolicy.supportsMainCalibration(record.alignment) else {
                throw CalibrationError.invalidManifest("pair \(pair.id) is not an eligible, fully audited main-calibration record")
            }

            if mediaScope == .tuneValidationOnly && pair.split == .frozen {
                // Keep the hash-bound audit and lock checks, but do not resolve
                // or open a Frozen asset during preflight.  A later explicit
                // Virgin Frozen evaluator owns the only media access.
                for digest in [record.sdrDigest, record.hdrDigest] {
                    guard let digest,
                          let locked = lockByPath[digest.path] ?? lockByPath[digest.portablePath(repositoryRoot: repositoryRoot)],
                          locked.sha256 == digest.sha256,
                          locked.sizeBytes == digest.sizeBytes else {
                        throw CalibrationError.invalidManifest("dataset lock does not contain matching Frozen digest for pair \(pair.id)")
                    }
                }
                continue
            }
            let resolved = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
            let mediaByPortablePath = [
                record.sdrDigest?.portablePath(repositoryRoot: repositoryRoot): resolved.sdr,
                record.hdrDigest?.portablePath(repositoryRoot: repositoryRoot): resolved.hdr
            ].compactMapValues { $0 }
            for (digest, resolvedURL) in zip([record.sdrDigest, record.hdrDigest], [resolved.sdr, resolved.hdr]) {
                guard let digest else {
                    throw CalibrationError.invalidManifest("pair \(pair.id) is missing an audit media digest")
                }
                let portablePath = digest.portablePath(repositoryRoot: repositoryRoot)
                guard mediaByPortablePath[portablePath]?.standardizedFileURL.path == resolvedURL.standardizedFileURL.path else {
                    throw CalibrationError.invalidManifest("audit digest path is not the manifest media path: \(digest.path)")
                }
                guard let locked = lockByPath[digest.path] ?? lockByPath[portablePath],
                      locked.sha256 == digest.sha256,
                      locked.sizeBytes == digest.sizeBytes else {
                    throw CalibrationError.invalidManifest("dataset lock does not contain matching digest for \(digest.path)")
                }
                let current = try V4DatasetIntegrity.digest(url: resolvedURL)
                guard current.sha256 == digest.sha256, current.sizeBytes == digest.sizeBytes else {
                    throw CalibrationError.invalidManifest("media digest changed: \(digest.path)")
                }
            }
        }
        return V4DatasetEvidence(
            manifestHash: manifestHash,
            lockHash: try V4DatasetIntegrity.sha256(url: lockURL),
            auditHash: try V4DatasetIntegrity.sha256(url: auditURL),
            auditConfigHash: auditConfigHash,
            eligiblePairIDs: manifest.pairs.map(\.id)
        )
    }
}

public struct V4GitEvidence: Codable, Sendable {
    public let commit: String
    public let tree: String
    public let workingTreeDirty: Bool
}

public enum V4SourceHasher {
    public static func repositoryRoot(for manifestURL: URL) throws -> URL {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let startsAtDirectory = fileManager.fileExists(atPath: manifestURL.path, isDirectory: &isDirectory) &&
            isDirectory.boolValue
        var current = (startsAtDirectory ? manifestURL : manifestURL.deletingLastPathComponent()).standardizedFileURL
        while current.path != "/" {
            if fileManager.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        throw CalibrationError.invalidManifest("repository root with Package.swift was not found")
    }

    public static func sourceHash(repositoryRoot: URL) throws -> String {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sources.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CalibrationError.invalidManifest("Sources directory is missing from repository root")
        }
        let requiredFiles = [
            "Package.swift",
            "Sources/HDRCore/HDRConfiguration.swift",
            "Sources/HDRCore/HDRProcessor.swift",
            "Sources/HDRCore/HDRReference.swift",
            "Sources/HDRCalibration/V4Calibration.swift",
            "Sources/HDRCalibration/V4DatasetAudit.swift",
            "Sources/HDRCalibration/V4Models.swift",
            "Sources/HDRCalibration/Decode.swift",
            "Sources/HDRCalibration/Alignment.swift",
            "Sources/HDRCalibration/FrameIO.swift",
            "Sources/HDRCalibration/Evaluation.swift",
            "Sources/HDRCalibration/CorrectnessReview.swift",
            "Sources/HDRCalibration/V2Runner.swift",
            "Sources/HDRCalibration/V5Preflight.swift",
            "Sources/HDRCalibration/PreparedEvaluationPlan.swift"
        ]
        for relative in requiredFiles {
            guard FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(relative).path) else {
                throw CalibrationError.invalidManifest("required source for freeze hash is missing: \(relative)")
            }
        }
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: [.isRegularFileKey])
        var paths: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard ["swift", "metal"].contains(url.pathExtension.lowercased()) else { continue }
            paths.append(url)
        }
        paths.append(repositoryRoot.appendingPathComponent("Package.swift"))
        paths.sort { $0.path < $1.path }
        var data = Data()
        for url in paths {
            let relative = url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
            data.append(Data(relative.utf8))
            data.append(0)
            data.append(try Data(contentsOf: url))
            data.append(0)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes the executable that is performing the calibration. A source
    /// tree hash alone cannot identify a stale prebuilt binary.
    public static func executableHash(url: URL? = nil) throws -> String {
        let executableURL: URL
        if let url {
            executableURL = url.standardizedFileURL
        } else {
            guard let argument = CommandLine.arguments.first, !argument.isEmpty else {
                throw CalibrationError.invalidCandidate("executing binary path is unavailable")
            }
            executableURL = argument.hasPrefix("/")
                ? URL(fileURLWithPath: argument).standardizedFileURL
                : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(argument).standardizedFileURL
        }
        guard FileManager.default.isReadableFile(atPath: executableURL.path) else {
            throw CalibrationError.invalidCandidate("executing binary is not readable: \(executableURL.path)")
        }
        let handle = try FileHandle(forReadingFrom: executableURL)
        defer { handle.closeFile() }
        var digest = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func gitEvidence(repositoryRoot: URL) throws -> V4GitEvidence {
        func run(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repositoryRoot.path] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw CalibrationError.invalidCandidate("git command failed: git \(arguments.joined(separator: " "))")
            }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let commit = try run(["rev-parse", "HEAD"])
        let tree = try run(["rev-parse", "HEAD^{tree}"])
        // Include untracked source files: sourceHash includes every Swift and
        // Metal file under Sources, so the dirty bit must describe the same
        // working tree state rather than silently ignoring new source files.
        let status = try run(["status", "--porcelain"])
        return V4GitEvidence(commit: commit, tree: tree, workingTreeDirty: !status.isEmpty)
    }
}

public enum V4CodeIdentityPolicy {
    public static func status(executableHash: String?, workingTreeDirty: Bool) -> V4GateStatus {
        guard let executableHash, executableHash.count == 64 else { return .notMeasured }
        return workingTreeDirty ? .fail : .pass
    }
}

/// Candidate freeze is an executable boundary, not merely a hash diagnostic.
/// There is intentionally no unchecked/no-argument production entry point.
public enum V4CandidateFreezeGuard {
    public static func requireClean(workingTreeDirty: Bool) throws {
        guard !workingTreeDirty else {
            throw CalibrationError.invalidCandidate("candidate freeze rejected: working tree is dirty")
        }
    }

    public static func status(workingTreeDirty: Bool) -> V4GateStatus {
        workingTreeDirty ? .fail : .pass
    }
}

public final class V4FrozenObjectiveAccessRegistry: @unchecked Sendable {
    public static let shared = V4FrozenObjectiveAccessRegistry()
    private let lock = NSLock()
    private var eventCountStorage = 0
    private var pairIDsStorage = Set<String>()

    private init() {}

    public func record(pairIDs: [String]) {
        lock.withLock {
            eventCountStorage += 1
            pairIDsStorage.formUnion(pairIDs)
        }
    }

    public func snapshot() -> (eventCount: Int, pairIDs: [String]) {
        lock.withLock { (eventCountStorage, pairIDsStorage.sorted()) }
    }
}

public final class V4FrozenExperimentGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var finalCandidateFrozen = false
    private var opened = false

    public init() {}

    public func finalizeCandidate(workingTreeDirty: Bool) throws {
        try V4CandidateFreezeGuard.requireClean(workingTreeDirty: workingTreeDirty)
        lock.lock()
        finalCandidateFrozen = true
        lock.unlock()
    }

    public func openVirginFrozenOnce() throws {
        lock.lock()
        defer { lock.unlock() }
        guard finalCandidateFrozen else {
            throw CalibrationError.invalidCandidate("Virgin Frozen requested before V4 candidate freeze")
        }
        guard !opened else {
            throw CalibrationError.invalidCandidate("V4 Virgin Frozen was already opened")
        }
        opened = true
    }
}

public struct V4FinalReport: Codable, Sendable {
    public var version: String
    public var generatedAt: String
    public var manifestPath: String
    public var configuration: V4CalibrationConfiguration
    public var split: V2SplitDocument
    public var transferByPair: [String: String]
    public var baseline: [String: V2DatasetEvaluation]
    public var shadowAudit: [String: V2DatasetEvaluation]
    public var sensitivity: [V4SensitivityRecord]
    public var globalCandidates: [V4CandidateRecord]
    public var localCandidates: [V4CandidateRecord]
    public var validationCandidates: [V4CandidateRecord]
    public var selectedCandidate: V4CandidateRecord?
    public var freeze: V4FreezeArtifact?
    public var frozen: [String: V2DatasetEvaluation]
    public var transferAnalysis: [String: [String: V2MetricBreakdown]]
    public var familyAnalysis: [String: [String: V2MetricBreakdown]]
    public var verdict: CalibrationV4Verdict
    public var reasons: [String]
    public var limitations: [String]
    public var promotionGates: V4PromotionGateResult? = nil
    public var preFrozenGates: V4PreFrozenGateResult? = nil
    public var frozenStatus: V4FrozenStatus? = nil
    public var runtimeBenchmark: V4RuntimeBenchmarkResult? = nil
}

private struct V4FrozenComparison: Codable, Sendable {
    var defaultEvaluation: V2DatasetEvaluation
    var v1Evaluation: V2DatasetEvaluation
    var v2Evaluation: V2DatasetEvaluation
    var v4Evaluation: V2DatasetEvaluation
}

public final class CalibrationV4Runner {
    public let manifestURL: URL
    public let outputDirectory: URL
    public let configuration: V4CalibrationConfiguration
    public let preparedEvaluationPlanURL: URL?
    public let preparedFrozenPlanURL: URL?

    private let device: MTLDevice
    private let frozenGuard = V4FrozenExperimentGuard()
    private var coverageReasons: [String] = []

    public init(
        manifestURL: URL,
        outputDirectory: URL,
        configuration: V4CalibrationConfiguration = V4CalibrationConfiguration(),
        preparedEvaluationPlanURL: URL? = nil,
        preparedFrozenPlanURL: URL? = nil,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) throws {
        guard let device else { throw CalibrationError.decodeFailed("Metal device unavailable") }
        self.manifestURL = manifestURL
        self.outputDirectory = outputDirectory
        self.configuration = configuration
        self.preparedEvaluationPlanURL = preparedEvaluationPlanURL
        self.preparedFrozenPlanURL = preparedFrozenPlanURL
        self.device = device
    }

    public func run() async throws -> V4FinalReport {
        guard let preparedEvaluationPlanURL else {
            throw CalibrationError.incompleteEvaluation(
                "v4-run requires an explicit preflight --prepared-plan artifact"
            )
        }
        let manifest = try V4Manifest.load(from: manifestURL)
        try validateV4Split(manifest)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let evidence = try V4DatasetEvidenceValidator.validate(
            manifestURL: manifestURL,
            auditURL: outputDirectory.appendingPathComponent("dataset-v4-final.json"),
            lockURL: manifestURL.deletingLastPathComponent().appendingPathComponent("dataset-v4-lock.json"),
            mediaScope: .tuneValidationOnly
        )

        let transferByPair = try await probeTransfers(manifest, includeVirginFrozen: false)
        let records = makeLegacyRecords(manifest)
        let tuneValidationV4 = V6PreparedEvaluationPlanOrdering.canonical(
            records.filter { $0.split == .tune || $0.split == .validation },
            scope: V6PreparedEvaluationPlanOrdering.tuneValidationScope,
            split: { $0.split }
        )
        let tuneV4 = tuneValidationV4.filter { $0.split == .tune }
        let validationV4 = tuneValidationV4.filter { $0.split == .validation }
        let virginIDs = Set(manifest.pairs
            .filter { $0.virginFrozen && !V6VirginHoldoutPolicy.isExcluded($0.id) }
            .map(\.id))
        let virginV4 = records.filter { $0.split == .frozen && virginIDs.contains($0.id) }
        let virginManifestRecords = manifest.pairs.filter {
            $0.split == .frozen && virginIDs.contains($0.id)
        }

        let repository = V2PreparedRepository(
            manifestURL: manifestURL,
            device: device,
            configuration: preparationConfiguration(),
            acceptedConfidenceThreshold: configuration.confidenceThreshold
        )
        log(String(format: "materialize sealed Tune %d + Validation %d plan; Virgin Frozen remains sealed", tuneV4.count, validationV4.count))
        let auditForPlan = try JSONDecoder().decode(
            V4DatasetAuditReport.self,
            from: Data(contentsOf: outputDirectory.appendingPathComponent("dataset-v4-final.json"))
        )
        let consumedByteIDs = Set(auditForPlan.pairs.compactMap { pair -> String? in
            V6VirginHoldoutPolicy.isExcluded(
                pairID: pair.id,
                sdrSHA256: pair.sdrDigest?.sha256,
                hdrSHA256: pair.hdrDigest?.sha256
            ) ? pair.id : nil
        })
        guard consumedByteIDs.isDisjoint(with: Set(virginV4.map(\.id))) else {
            throw CalibrationError.invalidManifest(
                "V6 Virgin Frozen composition reuses V5 attempt-1 IDs or asset hashes: " +
                    consumedByteIDs.sorted().joined(separator: ",")
            )
        }
        let inputHashesForPlan = V6PreparedEvaluationPlanBuilder.makeInputHashes(audit: auditForPlan)
        let artifact = try V6PreparedEvaluationPlanLoader.loadSealed(
            from: preparedEvaluationPlanURL
        )
        let allPrepared = try await repository.materialize(
            records: tuneValidationV4,
            using: artifact.plan,
            inputHashes: inputHashesForPlan
        )
        let tuneIDs = Set(tuneV4.map(\.id))
        let validationIDs = Set(validationV4.map(\.id))
        let tunePrepared = allPrepared.filter { tuneIDs.contains($0.record.id) }
        let validationPrepared = allPrepared.filter { validationIDs.contains($0.record.id) }
        let tuneValidationPlan = artifact.plan
        log("installed immutable Tune/Validation PreparedEvaluationPlan \(artifact.planSHA256)")

        // A future V6 holdout is admitted with an objective-free preparation
        // artifact.  Preflight validates only this serialized contract; media
        // remains sealed until the Frozen guard opens.
        let frozenArtifact: V6PreparedEvaluationPlanArtifact?
        if virginV4.isEmpty {
            frozenArtifact = nil
        } else {
            guard let preparedFrozenPlanURL else {
                throw CalibrationError.incompleteEvaluation(
                    "v4-run requires an explicit admitted --prepared-frozen-plan artifact"
                )
            }
            let loaded = try V6PreparedEvaluationPlanLoader.loadSealed(
                from: preparedFrozenPlanURL
            )
            try V6PreparedEvaluationPlanBuilder.validateSealedContract(
                plan: loaded.plan,
                scope: "VIRGIN_FROZEN",
                records: virginManifestRecords,
                inputHashes: inputHashesForPlan,
                preparation: artifact.plan.preparation
            )
            frozenArtifact = loaded
        }
        let engine = V2EvaluationEngine(device: device, weights: configuration.weights)
        try engine.installPreparedEvaluationPlan(tuneValidationPlan)

        let defaults = parameters(.hdr, revision: .legacyV2)
        let v1 = parameters(.calibratedV1, revision: .legacyV2)
        let v2 = parameters(.calibratedV2, revision: .legacyV2)
        let v3Absolute = parameters(.calibratedV3Candidate, revision: .shadowProtectedV3)
        let v4Center = parameters(.calibratedV2, revision: .sceneRelativeV4)

        let defaultTune = try evaluate(engine, tunePrepared, defaults, "default-tune", .tune, manifest)
        let v1Tune = try evaluate(engine, tunePrepared, v1, "v1-tune", .tune, manifest)
        let v2Tune = try evaluate(engine, tunePrepared, v2, "v2-tune", .tune, manifest)
        let defaultValidation = try evaluate(engine, validationPrepared, defaults, "default-validation", .validation, manifest)
        let v1Validation = try evaluate(engine, validationPrepared, v1, "v1-validation", .validation, manifest)
        let v2Validation = try evaluate(engine, validationPrepared, v2, "v2-validation", .validation, manifest)

        // V3 reproduction and the fixed-parameter absolute-vs-relative A/B
        // happen only on Tune/Validation. No Virgin Frozen pixels are read.
        let v3Tune = try evaluate(engine, tunePrepared, v3Absolute, "v3-absolute-tune", .tune, manifest)
        let v3Validation = try evaluate(engine, validationPrepared, v3Absolute, "v3-absolute-validation", .validation, manifest)
        let relativeTune = try evaluate(engine, tunePrepared, v4Center, "v4-relative-center-tune", .tune, manifest)
        let relativeValidation = try evaluate(engine, validationPrepared, v4Center, "v4-relative-center-validation", .validation, manifest)

        let baseline = [
            "default-tune": defaultTune, "v1-tune": v1Tune, "v2-tune": v2Tune,
            "v3-absolute-tune": v3Tune, "v4-relative-center-tune": relativeTune,
            "default-validation": defaultValidation, "v1-validation": v1Validation,
            "v2-validation": v2Validation, "v3-absolute-validation": v3Validation,
            "v4-relative-center-validation": relativeValidation
        ]
        try writeJSON(baseline, name: "data-video-v4-baseline.json")

        let sensitivity = try sensitivitySweep(engine: engine, tune: tunePrepared, center: v4Center, manifest: manifest)
        let shadowAudit = [
            "v3-absolute-tune": v3Tune, "v3-absolute-validation": v3Validation,
            "v4-relative-tune": relativeTune, "v4-relative-validation": relativeValidation
        ]
        try writeJSON(shadowAudit, name: "data-video-v4-shadow-audit.json")
        try writeJSON(sensitivity, name: "data-video-v4-sensitivity.json")

        let sensitivityGate = validateSensitivity(sensitivity)
        guard sensitivityGate.passed else {
            let report = makeFailureReport(
                manifest: manifest, transferByPair: transferByPair, baseline: baseline,
                shadowAudit: shadowAudit, sensitivity: sensitivity,
                reason: sensitivityGate.reason, verdict: .identifiabilityFail
            )
            try writeArtifacts(report)
            return report
        }

        log(String(format: "scene-relative sensitivity passed; global Halton search %d", configuration.globalCandidates))
        var global: [V4CandidateRecord] = []
        for index in 0..<configuration.globalCandidates {
            let candidate = globalParameters(index: index)
            let metrics = try evaluate(engine, tunePrepared, candidate, "v4-global-" + String(index), .tune, manifest)
            global.append(candidateRecord(
                id: String(format: "global_%03d", index), stage: "global-halton",
                parameters: candidate, tune: metrics, baseline: v2Tune
            ))
            if (index + 1) % 16 == 0 { log(String(format: "global %d/%d", index + 1, configuration.globalCandidates)) }
        }
        let globalTop = Array(global.filter(\.constraintsPassed).sorted { $0.tune.metrics.objective < $1.tune.metrics.objective }.prefix(8))
        guard !globalTop.isEmpty else {
            let report = makeFailureReport(
                manifest: manifest, transferByPair: transferByPair, baseline: baseline,
                shadowAudit: shadowAudit, sensitivity: sensitivity,
                reason: "No global V4 candidate passed Tune safety gates", verdict: .validationFail,
                global: global
            )
            try writeArtifacts(report)
            return report
        }

        log(String(format: "local refinement %d", configuration.localCandidates))
        var local: [V4CandidateRecord] = []
        for index in 0..<configuration.localCandidates {
            let center = globalTop[index % globalTop.count].parameters
            let candidate = localParameters(center: center, index: index)
            let metrics = try evaluate(engine, tunePrepared, candidate, "v4-local-" + String(index), .tune, manifest)
            local.append(candidateRecord(
                id: String(format: "local_%03d", index), stage: "local-halton",
                parameters: candidate, tune: metrics, baseline: v2Tune
            ))
            if (index + 1) % 16 == 0 { log(String(format: "local %d/%d", index + 1, configuration.localCandidates)) }
        }
        try writeJSON(["global": global, "local": local], name: "data-video-v4-search.json")

        let tuneTop = Array((global + local).filter(\.constraintsPassed)
            .sorted { $0.tune.metrics.objective < $1.tune.metrics.objective }
            .prefix(configuration.validationTopCount))
        var validationCandidates: [V4CandidateRecord] = []
        for var candidate in tuneTop {
            let validation = try evaluate(engine, validationPrepared, candidate.parameters, candidate.id, .validation, manifest)
            candidate.validation = validation
            let reasons = validationRejections(validation, baseline: v2Validation)
            if !reasons.isEmpty {
                candidate.constraintsPassed = false
                candidate.rejectionReasons.append(contentsOf: reasons)
            }
            validationCandidates.append(candidate)
        }
        try writeJSON(validationCandidates, name: "data-video-v4-validation.json")

        guard let selected = validationCandidates.filter(\.constraintsPassed).min(by: {
            ($0.validation?.metrics.objective ?? .infinity) < ($1.validation?.metrics.objective ?? .infinity)
        }), let selectedValidation = selected.validation else {
            let report = makeFailureReport(
                manifest: manifest, transferByPair: transferByPair, baseline: baseline,
                shadowAudit: shadowAudit, sensitivity: sensitivity,
                reason: "No V4 candidate passed Validation safety and objective gates", verdict: .validationFail,
                global: global, local: local, validation: validationCandidates
            )
            try writeArtifacts(report)
            return report
        }

        let selectedTune = selected.tune
        let candidate = selected.parameters
        let requiredCoverage = try validateRequiredCoverage(manifest: manifest, transferByPair: transferByPair)
        guard requiredCoverage.canOpenVirginFrozen else {
            let report = makeFailureReport(
                manifest: manifest, transferByPair: transferByPair, baseline: baseline,
                shadowAudit: shadowAudit, sensitivity: sensitivity,
                reason: "required coverage preregistration failed before Virgin Frozen access: " +
                    requiredCoverage.failures.joined(separator: ", "),
                verdict: .validationFail,
                global: global, local: local, validation: validationCandidates,
                selected: selected, selectedValidation: selectedValidation,
                candidate: candidate, preFrozenGates: requiredCoverage,
                frozenStatus: .notEvaluatedDuePrecondition
            )
            try writeArtifacts(report)
            return report
        }
        let parameterHash = sha256(try encode(candidate))
        let manifestHash = evidence.manifestHash
        let objectiveHash = sha256(try encode(configuration))
        let repositoryRoot = try V4SourceHasher.repositoryRoot(for: manifestURL)
        let sourceHash = try V4SourceHasher.sourceHash(repositoryRoot: repositoryRoot)
        let executableHash = try V4SourceHasher.executableHash()
        let gitEvidence = try V4SourceHasher.gitEvidence(repositoryRoot: repositoryRoot)
        let codeIdentity = V4CodeIdentityPolicy.status(
            executableHash: executableHash,
            workingTreeDirty: gitEvidence.workingTreeDirty
        )
        guard codeIdentity == .pass else {
            let report = makeFailureReport(
                manifest: manifest, transferByPair: transferByPair, baseline: baseline,
                shadowAudit: shadowAudit, sensitivity: sensitivity,
                reason: "executing code identity is not reproducible: codeIdentity=\(codeIdentity.rawValue), workingTreeDirty=\(gitEvidence.workingTreeDirty)",
                verdict: .incompleteEvaluation,
                global: global, local: local, validation: validationCandidates,
                selected: selected, selectedValidation: selectedValidation,
                candidate: candidate, preFrozenGates: requiredCoverage,
                frozenStatus: .notEvaluatedDuePrecondition
            )
            try writeArtifacts(report)
            return report
        }
        let initialFreeze = V4FreezeArtifact(
            candidateID: selected.id, parameters: candidate,
            parameterHash: parameterHash, codeHash: executableHash,
            manifestHash: manifestHash, objectiveHash: objectiveHash,
            finalCandidateFrozen: true, frozenOpened: false,
            sourceHash: sourceHash, executableHash: executableHash,
            datasetLockHash: evidence.lockHash,
            auditArtifactHash: evidence.auditHash, evaluationConfigHash: objectiveHash,
            gitCommit: gitEvidence.commit, gitTree: gitEvidence.tree,
            workingTreeDirty: gitEvidence.workingTreeDirty
        )
        try frozenGuard.finalizeCandidate(workingTreeDirty: gitEvidence.workingTreeDirty)
        try writeJSON(selected, name: "calibrated-v4-candidate.json")
        try writeJSON(initialFreeze, name: "calibrated-v4-freeze.json")

        let runtimeBenchmark: V4RuntimeBenchmarkResult
        do {
            runtimeBenchmark = try benchmarkRuntime(baseline: v2, candidate: candidate)
        } catch {
            runtimeBenchmark = V4RuntimeBenchmarkResult(
                status: .notMeasured,
                deviceName: device.name,
                width: configuration.safety.runtimeThresholds.width,
                height: configuration.safety.runtimeThresholds.height,
                warmupFrames: configuration.safety.runtimeThresholds.warmupFrames,
                measuredFrames: 0,
                thresholds: configuration.safety.runtimeThresholds,
                baseline: nil,
                candidate: nil,
                reasons: ["runtime benchmark failed: \(error.localizedDescription)"]
            )
        }
        try writeJSON(runtimeBenchmark, name: "data-video-v4-runtime.json")

        let preFrozenGates = V4PreFrozenGateResult(
            datasetIntegrity: .pass,
            identifiability: .pass,
            validationOverall: selectedValidation.metrics.objective < v2Validation.metrics.objective ? .pass : .fail,
            validationShadow: shadowSafe(v2Validation.metrics, selectedValidation.metrics) ? .pass : .fail,
            validationTemporal: temporalSafe(v2Validation.metrics, selectedValidation.metrics) ? .pass : .fail,
            transferCoverage: requiredCoverage.transferCoverage,
            pairCoverage: requiredCoverage.pairCoverage,
            familyCoverage: requiredCoverage.familyCoverage,
            runtime: runtimeBenchmark.status
        )
        guard preFrozenGates.canOpenVirginFrozen else {
            let report = makeFailureReport(
                manifest: manifest, transferByPair: transferByPair, baseline: baseline,
                shadowAudit: shadowAudit, sensitivity: sensitivity,
                reason: "pre-Frozen gate failed before Virgin Frozen access: " +
                    (preFrozenGates.failures + coverageReasons).joined(separator: ", "),
                verdict: .incompleteEvaluation,
                global: global, local: local, validation: validationCandidates,
                selected: selected, selectedValidation: selectedValidation,
                candidate: candidate, preFrozenGates: preFrozenGates,
                frozenStatus: .notEvaluatedDuePrecondition
            )
            try writeArtifacts(report)
            return report
        }

        log("candidate \(selected.id) frozen; all pre-Frozen gates passed; opening exactly three Virgin Frozen pairs once")
        try frozenGuard.openVirginFrozenOnce()
        let frozenRecords = records.filter { record in
            virginV4.contains(where: { $0.id == record.id })
        }
        guard frozenRecords.count >= configuration.minimumVirginFrozenPairs else {
            throw CalibrationError.invalidManifest(
                "V4 requires at least " + String(configuration.minimumVirginFrozenPairs) +
                    " Virgin Frozen records, found " + String(frozenRecords.count)
            )
        }
        let frozenRepository = V2PreparedRepository(
            manifestURL: manifestURL,
            device: device,
            configuration: preparationConfiguration(),
            acceptedConfidenceThreshold: configuration.confidenceThreshold
        )
        guard let frozenArtifact else {
            throw CalibrationError.incompleteEvaluation(
                "no admitted V6 Virgin Frozen PreparedEvaluationPlan is available"
            )
        }
        let frozenPrepared = try await frozenRepository.materialize(
            records: frozenRecords,
            using: frozenArtifact.plan,
            inputHashes: inputHashesForPlan
        )
        let frozenPlan = frozenArtifact.plan
        let frozenEngine = V2EvaluationEngine(device: device, weights: configuration.weights)
        try frozenEngine.installPreparedEvaluationPlan(
            frozenPlan, expectedSHA256: frozenArtifact.planSHA256
        )
        V4FrozenObjectiveAccessRegistry.shared.record(pairIDs: frozenRecords.map(\.id))
        let frozenDefault = try evaluate(frozenEngine, frozenPrepared, defaults, "default-virgin-frozen", .frozen, manifest)
        let frozenV1 = try evaluate(frozenEngine, frozenPrepared, v1, "v1-virgin-frozen", .frozen, manifest)
        let frozenV2 = try evaluate(frozenEngine, frozenPrepared, v2, "v2-virgin-frozen", .frozen, manifest)
        let frozenV4 = try evaluate(frozenEngine, frozenPrepared, candidate, "v4-virgin-frozen", .frozen, manifest)
        let frozen = [
            "default": frozenDefault, "calibratedV1": frozenV1,
            "calibratedV2": frozenV2, "calibratedV4": frozenV4
        ]
        try writeJSON(frozen, name: "data-video-v4-frozen.json")

        let finalFreeze = V4FreezeArtifact(
            candidateID: initialFreeze.candidateID, parameters: initialFreeze.parameters,
            parameterHash: initialFreeze.parameterHash, codeHash: initialFreeze.codeHash,
            manifestHash: initialFreeze.manifestHash, objectiveHash: initialFreeze.objectiveHash,
            finalCandidateFrozen: true, frozenOpened: true,
            sourceHash: initialFreeze.sourceHash, executableHash: initialFreeze.executableHash,
            datasetLockHash: initialFreeze.datasetLockHash,
            auditArtifactHash: initialFreeze.auditArtifactHash,
            evaluationConfigHash: initialFreeze.evaluationConfigHash,
            gitCommit: initialFreeze.gitCommit, gitTree: initialFreeze.gitTree,
            workingTreeDirty: initialFreeze.workingTreeDirty
        )
        try writeJSON(finalFreeze, name: "calibrated-v4-freeze.json")

        let transferAnalysis = transferAnalysis(
            evaluations: ["v2": frozenV2, "v4": frozenV4], records: frozenRecords, transferByPair: transferByPair
        )
        let familyAnalysis = familyAnalysis(
            evaluations: ["v2": frozenV2, "v4": frozenV4], manifest: manifest
        )
        let decision = finalVerdict(
            tuneV2: v2Tune, tuneV4: selectedTune,
            validationV2: v2Validation, validationV4: selectedValidation,
            frozenV2: frozenV2, frozenV4: frozenV4,
            manifest: manifest, transferByPair: transferByPair,
            runtime: runtimeBenchmark
        )
        let report = V4FinalReport(
            version: configuration.version,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            manifestPath: portableManifestPath,
            configuration: configuration,
            split: splitDocument(manifest),
            transferByPair: transferByPair,
            baseline: baseline,
            shadowAudit: shadowAudit,
            sensitivity: sensitivity,
            globalCandidates: global,
            localCandidates: local,
            validationCandidates: validationCandidates,
            selectedCandidate: selected,
            freeze: finalFreeze,
            frozen: frozen,
            transferAnalysis: transferAnalysis,
            familyAnalysis: familyAnalysis,
            verdict: decision.0,
            reasons: decision.1,
            limitations: [
                "Virgin Frozen metrics were opened once only after candidate, code, manifest and objective hashes were frozen.",
                "The three Virgin Frozen pairs are a small holdout; family/transfer confidence intervals are limited.",
                "Reference HDR creative grading and SDR information loss are not recoverable detail ground truth.",
                "Runtime scene statistics use a 16x9, 16-bin causal GPU estimator; offline uses the same one-frame-late state transition."
            ],
            promotionGates: decision.2,
            preFrozenGates: preFrozenGates,
            frozenStatus: .openedAndEvaluated,
            runtimeBenchmark: runtimeBenchmark
        )
        try writeArtifacts(report)
        return report
    }

    private func validateV4Split(_ manifest: V4Manifest) throws {
        let tune = manifest.pairs.filter { $0.split == .tune }
        let validation = manifest.pairs.filter { $0.split == .validation }
        let virgin = manifest.pairs.filter {
            $0.split == .frozen && $0.virginFrozen && !V6VirginHoldoutPolicy.isExcluded($0.id)
        }
        guard tune.count == 5, validation.count == 3, virgin.count >= configuration.minimumVirginFrozenPairs else {
            throw CalibrationError.invalidManifest(
                String(format: "V6 expected Tune=5, Validation=3, and at least %d unconsumed Virgin Frozen records; got %d, %d, %d", configuration.minimumVirginFrozenPairs, tune.count, validation.count, virgin.count)
            )
        }
    }

    private func splitDocument(_ manifest: V4Manifest) -> V2SplitDocument {
        V2SplitDocument(
            splitSeed: configuration.splitSeed,
            algorithm: "manifest-video-group-fixed-v4-family-balanced",
            tune: manifest.pairs.filter { $0.split == .tune }.map(\.id),
            validation: manifest.pairs.filter { $0.split == .validation }.map(\.id),
            frozen: manifest.pairs.filter {
                $0.split == .frozen && !V6VirginHoldoutPolicy.isExcluded($0.id)
            }.map(\.id),
            frozenAccessPolicy: "V6 excludes every V5 attempt-1 pair/asset; a new plan-sealed Virgin Frozen set is required"
        )
    }

    private func preparationConfiguration() -> V2SearchConfiguration {
        var value = V2SearchConfiguration()
        value.searchSeed = configuration.searchSeed
        value.maxFramesPerScene = configuration.maxFramesPerScene
        value.referenceTargetPeakNits = configuration.referenceTargetPeakNits
        value.weights = configuration.weights
        value.alignmentSearchThreshold = 0
        return value
    }

    private func makeLegacyRecords(_ manifest: V4Manifest) -> [PairRecord] {
        manifest.pairs.map { pair in
            let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
            return PairRecord(
                id: pair.id,
                sdr: urls.sdr.path,
                hdr: urls.hdr.path,
                license: pair.license,
                source: pair.source,
                expectedRelation: legacyRelation(pair.expectedRelation),
                notes: pair.notes,
                split: pair.split
            )
        }
    }

    private func legacyRelation(_ relation: V4ExpectedRelation) -> ExpectedRelation {
        relation.legacyRelation()
    }

    private func probeTransfers(
        _ manifest: V4Manifest,
        includeVirginFrozen: Bool
    ) async throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in manifest.pairs {
            if pair.split == .frozen && pair.virginFrozen && !includeVirginFrozen {
                // Preflight uses only manifest-declared source evidence for
                // Frozen coverage. No Frozen URL is resolved or opened until
                // the explicit guard has opened the holdout.
                result[pair.id] = ReferenceTransfer.parse(pair.referenceTransfer).canonicalName
                continue
            }
            let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: manifest.roots)
            let metadata = try await MetadataProbe.probe(url: urls.hdr)
            result[pair.id] = metadata.color.referenceTransfer.canonicalName
        }
        return result
    }

    private func parameters(_ source: HDRConfiguration, revision: HDRToneCurveRevision) -> CalibrationParameters {
        var value = CalibrationParameters(configuration: source)
        value.displayHeadroom = value.peakNits / value.paperWhiteNits
        value.toneCurveRevision = revision.rawValue
        return value
    }

    private func evaluate(
        _ engine: V2EvaluationEngine,
        _ prepared: [PreparedPair],
        _ parameters: CalibrationParameters,
        _ label: String,
        _ split: DatasetSplit,
        _ manifest: V4Manifest
    ) throws -> V2DatasetEvaluation {
        let raw = try engine.evaluate(
            preparedPairs: prepared, parameters: parameters, label: label,
            split: split, confidenceThreshold: configuration.confidenceThreshold
        )
        return familyBalanced(raw, manifest: manifest)
    }

    private func familyBalanced(_ evaluation: V2DatasetEvaluation, manifest: V4Manifest) -> V2DatasetEvaluation {
        let families = Dictionary(grouping: evaluation.videos) { video in
            manifest.pairs.first(where: { $0.id == video.pairID })?.contentFamily ?? "UNCLASSIFIED"
        }
        let familyMetrics = families.values.map { V2MetricsEvaluator.aggregate($0.map(\.metrics)) }
        var balanced = evaluation
        balanced.metrics = V2MetricsEvaluator.aggregate(familyMetrics)
        return balanced
    }

    private func sensitivitySweep(
        engine: V2EvaluationEngine,
        tune: [PreparedPair],
        center: CalibrationParameters,
        manifest: V4Manifest
    ) throws -> [V4SensitivityRecord] {
        var result: [V4SensitivityRecord] = []
        for value in [Float(0), 0.25, 0.5, 0.75, 1] {
            var parameters = center
            parameters.shadowProtection = value
            let metrics = try evaluate(engine, tune, parameters, "v4-sensitivity-shadow-(value)", .tune, manifest).metrics
            result.append(V4SensitivityRecord(
                parameter: "shadowProtection", value: value,
                objective: metrics.objective, shadowError: metrics.shadowError,
                shadowLiftRatio: metrics.shadowLiftRatio, midtoneError: metrics.midtoneError,
                highlightError: metrics.highlightError, temporalFlicker: metrics.temporalFlicker,
                highlightPumping: metrics.highlightPumping, sceneCutRecovery: metrics.sceneCutRecovery
            ))
        }
        for value in [Float(0), 0.25, 0.5, 0.75, 1] {
            var parameters = center
            parameters.temporalStability = value
            let metrics = try evaluate(engine, tune, parameters, "v4-sensitivity-temporal-(value)", .tune, manifest).metrics
            result.append(V4SensitivityRecord(
                parameter: "temporalStability", value: value,
                objective: metrics.objective, shadowError: metrics.shadowError,
                shadowLiftRatio: metrics.shadowLiftRatio, midtoneError: metrics.midtoneError,
                highlightError: metrics.highlightError, temporalFlicker: metrics.temporalFlicker,
                highlightPumping: metrics.highlightPumping, sceneCutRecovery: metrics.sceneCutRecovery
            ))
        }
        return result
    }

    private func validateSensitivity(_ values: [V4SensitivityRecord]) -> (passed: Bool, reason: String) {
        let shadows = values.filter { $0.parameter == "shadowProtection" }.sorted { $0.value < $1.value }
        let temporals = values.filter { $0.parameter == "temporalStability" }
        let shadowDelta = (shadows.map(\.shadowLiftRatio).max() ?? 0) - (shadows.map(\.shadowLiftRatio).min() ?? 0)
        let temporalDelta = (temporals.map { $0.temporalFlicker + $0.highlightPumping }.max() ?? 0) -
            (temporals.map { $0.temporalFlicker + $0.highlightPumping }.min() ?? 0)
        let monotonic = zip(shadows, shadows.dropFirst()).allSatisfy { $0.1.shadowLiftRatio <= $0.0.shadowLiftRatio + 0.01 }
        guard shadowDelta > 0.002, monotonic else {
            return (false, String(format: "scene-relative shadowProtection sensitivity is dead or non-monotonic (delta=%.6f)", shadowDelta))
        }
        guard temporalDelta > 0.00001 else {
            return (false, String(format: "temporalStability remains unidentified after causal sequential evaluation (delta=%.6f)", temporalDelta))
        }
        return (true, "scene-relative shadow and causal temporal controls are identifiable")
    }

    private func globalParameters(index: Int) -> CalibrationParameters {
        let bounds = configuration.bounds
        let ranges = [bounds.paperWhiteNits, bounds.peakNits, bounds.highlightStrength,
                      bounds.contrastStrength, bounds.saturationCompensation,
                      bounds.shadowProtection, bounds.temporalStability]
        let bases = [2, 3, 5, 7, 11, 13, 17]
        let values = ranges.enumerated().map { dimension, range in
            range.lowerBound + Float(halton(index + 1, base: bases[dimension])) * (range.upperBound - range.lowerBound)
        }
        return makeParameters(values)
    }

    private func localParameters(center: CalibrationParameters, index: Int) -> CalibrationParameters {
        let bounds = configuration.bounds
        let ranges = [bounds.paperWhiteNits, bounds.peakNits, bounds.highlightStrength,
                      bounds.contrastStrength, bounds.saturationCompensation,
                      bounds.shadowProtection, bounds.temporalStability]
        let centers = [center.paperWhiteNits, center.peakNits, center.highlightStrength,
                       center.contrastStrength, center.saturationCompensation,
                       center.shadowProtection, center.temporalStability]
        let bases = [19, 23, 29, 31, 37, 41, 43]
        let values = ranges.enumerated().map { dimension, range -> Float in
            let radius = (range.upperBound - range.lowerBound) * 0.10
            let offset = Float(halton(index + 1, base: bases[dimension]) - 0.5) * 2 * radius
            return min(max(centers[dimension] + offset, range.lowerBound), range.upperBound)
        }
        return makeParameters(values)
    }

    private func makeParameters(_ values: [Float]) -> CalibrationParameters {
        CalibrationParameters(
            paperWhiteNits: values[0], peakNits: values[1],
            highlightStrength: values[2], contrastStrength: values[3],
            saturationCompensation: values[4], shadowProtection: values[5],
            temporalStability: values[6], displayHeadroom: values[1] / values[0],
            toneCurveRevision: HDRToneCurveRevision.sceneRelativeV4.rawValue
        )
    }

    private func candidateRecord(
        id: String, stage: String, parameters: CalibrationParameters,
        tune: V2DatasetEvaluation, baseline: V2DatasetEvaluation
    ) -> V4CandidateRecord {
        var reasons: [String] = []
        let metrics = tune.metrics
        if !metrics.objective.isFinite || metrics.invalidSampleCount != 0 { reasons.append("invalid/non-finite") }
        if metrics.clippingRatio > configuration.safety.zeroTolerance { reasons.append("clipping") }
        if metrics.blackCrushRatio > configuration.safety.zeroTolerance { reasons.append("black crush") }
        if metrics.shadowError > baseline.metrics.shadowError + configuration.safety.shadowErrorTolerance { reasons.append("shadow safety") }
        if metrics.shadowLiftRatio > baseline.metrics.shadowLiftRatio + configuration.safety.shadowLiftTolerance { reasons.append("shadow lift safety") }
        if metrics.temporalFlicker > baseline.metrics.temporalFlicker * (1 + configuration.safety.temporalFlickerRelativeTolerance) + configuration.safety.temporalFlickerAbsoluteTolerance {
            reasons.append("temporal flicker")
        }
        if perVideoCatastrophic(candidate: tune, baseline: baseline) > 0 { reasons.append("catastrophic per-video regression") }
        return V4CandidateRecord(
            id: id, stage: stage, parameters: parameters, tune: tune,
            validation: nil, constraintsPassed: reasons.isEmpty, rejectionReasons: reasons
        )
    }

    private func validationRejections(_ candidate: V2DatasetEvaluation, baseline: V2DatasetEvaluation) -> [String] {
        var reasons: [String] = []
        let m = candidate.metrics
        let b = baseline.metrics
        if m.objective >= b.objective { reasons.append("Validation objective is not better than V2") }
        if m.shadowError > b.shadowError + configuration.safety.shadowErrorTolerance { reasons.append("shadow error regression") }
        if m.shadowLiftRatio > b.shadowLiftRatio + configuration.safety.shadowLiftTolerance { reasons.append("shadow lift regression") }
        if m.temporalFlicker > b.temporalFlicker * (1 + configuration.safety.temporalFlickerRelativeTolerance) + configuration.safety.temporalFlickerAbsoluteTolerance { reasons.append("temporal flicker regression") }
        if m.highlightError > b.highlightError * (1 + configuration.safety.highlightRelativeTolerance) + 0.005 { reasons.append("highlight regression") }
        if m.midtoneError > b.midtoneError * (1 + configuration.safety.midtoneRelativeTolerance) + 0.005 { reasons.append("midtone regression") }
        if m.hueP95Error > b.hueP95Error * (1 + configuration.safety.hueRelativeTolerance) + 0.002 { reasons.append("hue regression") }
        if m.clippingRatio > configuration.safety.zeroTolerance || m.blackCrushRatio > configuration.safety.zeroTolerance || m.invalidSampleCount != 0 { reasons.append("hard safety gate") }
        if perVideoCatastrophic(candidate: candidate, baseline: baseline) > 0 { reasons.append("catastrophic per-video regression") }
        return reasons
    }

    private func perVideoCatastrophic(candidate: V2DatasetEvaluation, baseline: V2DatasetEvaluation) -> Int {
        var count = 0
        for video in candidate.videos {
            guard let reference = baseline.videos.first(where: { $0.pairID == video.pairID }) else { continue }
            if video.metrics.objective > reference.metrics.objective * (1 + configuration.safety.catastrophicSceneRegression) ||
                video.metrics.shadowError > reference.metrics.shadowError * (1 + configuration.safety.catastrophicSceneRegression) + configuration.safety.shadowErrorTolerance {
                count += 1
            }
        }
        return count
    }

    private func finalVerdict(
        tuneV2: V2DatasetEvaluation, tuneV4: V2DatasetEvaluation,
        validationV2: V2DatasetEvaluation, validationV4: V2DatasetEvaluation,
        frozenV2: V2DatasetEvaluation, frozenV4: V2DatasetEvaluation,
        manifest: V4Manifest, transferByPair: [String: String],
        runtime: V4RuntimeBenchmarkResult
    ) -> (CalibrationV4Verdict, [String], V4PromotionGateResult) {
        let tuneImprovement = improvement(tuneV2.metrics.objective, tuneV4.metrics.objective)
        let validationImprovement = improvement(validationV2.metrics.objective, validationV4.metrics.objective)
        let frozenImprovement = improvement(frozenV2.metrics.objective, frozenV4.metrics.objective)
        let expectedTune = Set(manifest.pairs.filter { $0.split == .tune }.map(\.id))
        let expectedValidation = Set(manifest.pairs.filter { $0.split == .validation }.map(\.id))
        let expectedFrozen = Set(manifest.pairs.filter {
            $0.split == .frozen && $0.virginFrozen && !V6VirginHoldoutPolicy.isExcluded($0.id)
        }.map(\.id))
        let completeness = expectedTune == Set(tuneV2.videos.map(\.pairID)) &&
            expectedTune == Set(tuneV4.videos.map(\.pairID)) &&
            expectedValidation == Set(validationV2.videos.map(\.pairID)) &&
            expectedValidation == Set(validationV4.videos.map(\.pairID)) &&
            expectedFrozen == Set(frozenV2.videos.map(\.pairID)) &&
            expectedFrozen == Set(frozenV4.videos.map(\.pairID))
        let overall = tuneImprovement > 0 && validationImprovement > 0
        let shadow = shadowSafe(tuneV2.metrics, tuneV4.metrics) &&
            shadowSafe(validationV2.metrics, validationV4.metrics) &&
            shadowSafe(frozenV2.metrics, frozenV4.metrics)
        let temporal = temporalSafe(validationV2.metrics, validationV4.metrics) &&
            temporalSafe(frozenV2.metrics, frozenV4.metrics)
        let transfer = groupedSafetyGate(
            candidate: frozenV4, baseline: frozenV2,
            groupByID: transferByPair
        )
        let familyByID = Dictionary(uniqueKeysWithValues: manifest.pairs.compactMap { pair -> (String, String)? in
            guard let family = pair.contentFamily, !family.isEmpty else { return nil }
            return (pair.id, family)
        })
        let family = groupedSafetyGate(candidate: frozenV4, baseline: frozenV2, groupByID: familyByID)
        let hardSafety = frozenV4.metrics.clippingRatio <= configuration.safety.zeroTolerance &&
            frozenV4.metrics.blackCrushRatio <= configuration.safety.zeroTolerance &&
            frozenV4.metrics.invalidSampleCount == 0
        let frozenPerVideoRegression = perVideoRegressionCount(candidate: frozenV4, baseline: frozenV2) == 0
        let frozen = completeness && frozenImprovement >= configuration.safety.frozenMinimumImprovement && frozenPerVideoRegression
        let gates = V4PromotionGateResult(
            completeness: completeness ? .pass : .fail,
            datasetIntegrity: .pass,
            identifiability: .pass,
            relativeShadow: .pass,
            overall: overall ? .pass : .fail,
            shadow: shadow ? .pass : .fail,
            temporal: temporal ? .pass : .fail,
            transfer: transfer ? .pass : .fail,
            family: family ? .pass : .fail,
            runtime: runtime.status,
            frozen: frozen ? .pass : .fail,
            hardSafety: hardSafety ? .pass : .fail
        )
        var reasons = [
            String(format: "Tune V4 vs V2: %.2f%%", tuneImprovement * 100),
            String(format: "Validation V4 vs V2: %.2f%%", validationImprovement * 100),
            String(format: "Virgin Frozen V4 vs V2: %.2f%%", frozenImprovement * 100),
            String(format: "Virgin Frozen shadow V2=%.6f V4=%.6f", frozenV2.metrics.shadowError, frozenV4.metrics.shadowError),
            "Promotion gates: completeness=\(gates.completeness.rawValue), transfer=\(gates.transfer.rawValue), family=\(gates.family.rawValue), runtime=\(gates.runtime.rawValue)"
        ] + runtime.reasons
        let verdict = V4PromotionGateMachine.verdict(gates)
        reasons.append("Final verdict gate: \(verdict.rawValue)")
        return (verdict, reasons, gates)
    }

    private func shadowSafe(_ baseline: V2MetricBreakdown, _ candidate: V2MetricBreakdown) -> Bool {
        candidate.shadowError <= baseline.shadowError + configuration.safety.shadowErrorTolerance &&
            candidate.shadowLiftRatio <= baseline.shadowLiftRatio + configuration.safety.shadowLiftTolerance
    }

    private func temporalSafe(_ baseline: V2MetricBreakdown, _ candidate: V2MetricBreakdown) -> Bool {
        candidate.temporalFlicker <= baseline.temporalFlicker * (1 + configuration.safety.temporalFlickerRelativeTolerance) + configuration.safety.temporalFlickerAbsoluteTolerance
    }

    private func perVideoRegressionCount(candidate: V2DatasetEvaluation, baseline: V2DatasetEvaluation) -> Int {
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.videos.map { ($0.pairID, $0) })
        return candidate.videos.reduce(into: 0) { count, video in
            guard let reference = baselineByID[video.pairID] else { count += 1; return }
            if video.metrics.objective > reference.metrics.objective * (1 + configuration.safety.frozenPerVideoRegressionTolerance) {
                count += 1
            }
        }
    }

    private func groupedSafetyGate(
        candidate: V2DatasetEvaluation,
        baseline: V2DatasetEvaluation,
        groupByID: [String: String]
    ) -> Bool {
        let candidateGroups = Dictionary(grouping: candidate.videos) { groupByID[$0.pairID] ?? "UNKNOWN" }
        let baselineGroups = Dictionary(grouping: baseline.videos) { groupByID[$0.pairID] ?? "UNKNOWN" }
        guard !candidateGroups.isEmpty, Set(candidateGroups.keys) == Set(baselineGroups.keys) else { return false }
        for group in candidateGroups.keys {
            guard let candidateValues = candidateGroups[group], let baselineValues = baselineGroups[group] else { return false }
            let candidateMetric = V2MetricsEvaluator.aggregate(candidateValues.map(\.metrics))
            let baselineMetric = V2MetricsEvaluator.aggregate(baselineValues.map(\.metrics))
            if candidateMetric.objective > baselineMetric.objective * 1.05 ||
                candidateMetric.shadowError > baselineMetric.shadowError + configuration.safety.shadowErrorTolerance ||
                candidateMetric.temporalFlicker > baselineMetric.temporalFlicker * 1.05 + configuration.safety.temporalFlickerAbsoluteTolerance {
                return false
            }
        }
        return true
    }

    func benchmarkRuntime(
        baseline baselineParameters: CalibrationParameters,
        candidate candidateParameters: CalibrationParameters
    ) throws -> V4RuntimeBenchmarkResult {
        let thresholds = configuration.safety.runtimeThresholds
        guard thresholds.isValid else {
            return V4RuntimeBenchmarkResult(
                status: .notMeasured,
                deviceName: device.name,
                width: thresholds.width,
                height: thresholds.height,
                warmupFrames: thresholds.warmupFrames,
                measuredFrames: 0,
                thresholds: thresholds,
                baseline: nil,
                candidate: nil,
                reasons: ["runtime benchmark configuration is invalid"]
            )
        }
        guard let queue = device.makeCommandQueue() else {
            throw CalibrationError.decodeFailed("runtime benchmark command queue unavailable")
        }
        let pixelBuffer = try makeRuntimePixelBuffer(width: thresholds.width, height: thresholds.height)
        let baselineProcessor = try HDRProcessor(device: device, configuration: try baselineParameters.configuration())
        let candidateProcessor = try HDRProcessor(device: device, configuration: try candidateParameters.configuration())
        try baselineProcessor.prepare(width: thresholds.width, height: thresholds.height)
        try candidateProcessor.prepare(width: thresholds.width, height: thresholds.height)

        var baselineGPU: [Double] = []
        var baselineCPU: [Double] = []
        var candidateGPU: [Double] = []
        var candidateCPU: [Double] = []
        baselineGPU.reserveCapacity(thresholds.measuredFrames)
        baselineCPU.reserveCapacity(thresholds.measuredFrames)
        candidateGPU.reserveCapacity(thresholds.measuredFrames)
        candidateCPU.reserveCapacity(thresholds.measuredFrames)

        func measure(_ processor: HDRProcessor, collectGPU: inout [Double], collectCPU: inout [Double], collect: Bool) throws {
            guard let commandBuffer = queue.makeCommandBuffer() else {
                throw HDRProcessorError.commandBufferCreationFailed
            }
            let cpuStart = ProcessInfo.processInfo.systemUptime
            _ = try processor.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)
            let encodeEnd = ProcessInfo.processInfo.systemUptime
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if let error = commandBuffer.error { throw error }
            guard commandBuffer.gpuStartTime > 0,
                  commandBuffer.gpuEndTime > commandBuffer.gpuStartTime else {
                throw CalibrationError.incompleteEvaluation("Metal GPU timing unavailable for runtime benchmark")
            }
            if collect {
                collectGPU.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000)
                collectCPU.append((encodeEnd - cpuStart) * 1_000)
            }
        }

        let totalIterations = thresholds.warmupFrames + thresholds.measuredFrames
        for iteration in 0..<totalIterations {
            let collect = iteration >= thresholds.warmupFrames
            // Alternate order to avoid consistently favoring the first or
            // second processor through thermal/cache/queue ordering effects.
            if iteration.isMultiple(of: 2) {
                try measure(baselineProcessor, collectGPU: &baselineGPU, collectCPU: &baselineCPU, collect: collect)
                try measure(candidateProcessor, collectGPU: &candidateGPU, collectCPU: &candidateCPU, collect: collect)
            } else {
                try measure(candidateProcessor, collectGPU: &candidateGPU, collectCPU: &candidateCPU, collect: collect)
                try measure(baselineProcessor, collectGPU: &baselineGPU, collectCPU: &baselineCPU, collect: collect)
            }
        }
        guard baselineGPU.count == thresholds.measuredFrames,
              candidateGPU.count == thresholds.measuredFrames,
              baselineCPU.count == thresholds.measuredFrames,
              candidateCPU.count == thresholds.measuredFrames else {
            throw CalibrationError.incompleteEvaluation("runtime benchmark did not collect the requested frame count")
        }

        let baseline = V4RuntimeMeasurement(
            gpuP50Milliseconds: runtimePercentile(baselineGPU, 0.50),
            gpuP95Milliseconds: runtimePercentile(baselineGPU, 0.95),
            gpuP99Milliseconds: runtimePercentile(baselineGPU, 0.99),
            cpuSubmissionP50Milliseconds: runtimePercentile(baselineCPU, 0.50),
            cpuSubmissionP95Milliseconds: runtimePercentile(baselineCPU, 0.95),
            cpuSubmissionP99Milliseconds: runtimePercentile(baselineCPU, 0.99)
        )
        let candidate = V4RuntimeMeasurement(
            gpuP50Milliseconds: runtimePercentile(candidateGPU, 0.50),
            gpuP95Milliseconds: runtimePercentile(candidateGPU, 0.95),
            gpuP99Milliseconds: runtimePercentile(candidateGPU, 0.99),
            cpuSubmissionP50Milliseconds: runtimePercentile(candidateCPU, 0.50),
            cpuSubmissionP95Milliseconds: runtimePercentile(candidateCPU, 0.95),
            cpuSubmissionP99Milliseconds: runtimePercentile(candidateCPU, 0.99)
        )
        let gate = V4RuntimeGate.status(baseline: baseline, candidate: candidate, thresholds: thresholds)
        return V4RuntimeBenchmarkResult(
            status: gate.0,
            deviceName: device.name,
            width: thresholds.width,
            height: thresholds.height,
            warmupFrames: thresholds.warmupFrames,
            measuredFrames: thresholds.measuredFrames,
            thresholds: thresholds,
            baseline: baseline,
            candidate: candidate,
            reasons: gate.1
        )
    }

    private func runtimePercentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let index = min(max(Int(Double(sorted.count - 1) * fraction), 0), sorted.count - 1)
        return sorted[index]
    }

    private func makeRuntimePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CalibrationError.decodeFailed("runtime benchmark pixel buffer creation failed: \(status)")
        }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            throw CalibrationError.decodeFailed("runtime benchmark pixel buffer lock failed")
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
            throw CalibrationError.decodeFailed("runtime benchmark pixel buffer planes unavailable")
        }
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for y in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) {
            let row = yBase.advanced(by: y * yRowBytes)
            for x in 0..<CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) {
                let ramp = Float(x) / Float(max(width - 1, 1))
                row[x] = UInt8(min(max(16 + Int(ramp * 219), 16), 235))
            }
        }
        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        for y in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) {
            let row = uvBase.advanced(by: y * uvRowBytes)
            for x in 0..<uvWidth {
                row[2 * x] = 128
                row[2 * x + 1] = 128
            }
        }
        return pixelBuffer
    }

    private func makeFailureReport(
        manifest: V4Manifest,
        transferByPair: [String: String],
        baseline: [String: V2DatasetEvaluation],
        shadowAudit: [String: V2DatasetEvaluation],
        sensitivity: [V4SensitivityRecord],
        reason: String,
        verdict: CalibrationV4Verdict,
        global: [V4CandidateRecord] = [],
        local: [V4CandidateRecord] = [],
        validation: [V4CandidateRecord] = [],
        selected: V4CandidateRecord? = nil,
        selectedValidation: V2DatasetEvaluation? = nil,
        candidate: CalibrationParameters? = nil,
        preFrozenGates: V4PreFrozenGateResult? = nil,
        frozenStatus: V4FrozenStatus = .notEvaluatedDuePrecondition
    ) -> V4FinalReport {
        let initialFreeze = makeSealedCandidateFreeze(
            selected: selected, candidate: candidate, selectedValidation: selectedValidation
        )
        return V4FinalReport(
            version: configuration.version,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            manifestPath: portableManifestPath,
            configuration: configuration,
            split: splitDocument(manifest),
            transferByPair: transferByPair,
            baseline: baseline,
            shadowAudit: shadowAudit,
            sensitivity: sensitivity,
            globalCandidates: global, localCandidates: local,
            validationCandidates: validation,
            selectedCandidate: selected,
            freeze: initialFreeze,
            frozen: [:],
            transferAnalysis: [:],
            familyAnalysis: [:],
            verdict: verdict, reasons: [reason], limitations: [
                "Virgin Frozen remained sealed because V4 preconditions were not satisfied."
            ],
            preFrozenGates: preFrozenGates,
            frozenStatus: frozenStatus
        )
    }

    private func makeSealedCandidateFreeze(
        selected: V4CandidateRecord?,
        candidate: CalibrationParameters?,
        selectedValidation: V2DatasetEvaluation?
    ) -> V4FreezeArtifact? {
        guard let selected, let candidate else { return nil }
        do {
            let repositoryRoot = try V4SourceHasher.repositoryRoot(for: manifestURL)
            let sourceHash = try V4SourceHasher.sourceHash(repositoryRoot: repositoryRoot)
            let executableHash = try V4SourceHasher.executableHash()
            let gitEvidence = try V4SourceHasher.gitEvidence(repositoryRoot: repositoryRoot)
            try V4CandidateFreezeGuard.requireClean(workingTreeDirty: gitEvidence.workingTreeDirty)
            return V4FreezeArtifact(
                candidateID: selected.id,
                parameters: candidate,
                parameterHash: sha256(try encode(candidate)),
                codeHash: executableHash,
                manifestHash: "",
                objectiveHash: sha256(try encode(configuration)),
                finalCandidateFrozen: true,
                frozenOpened: false,
                sourceHash: sourceHash,
                executableHash: executableHash,
                evaluationConfigHash: sha256(try encode(configuration)),
                gitCommit: gitEvidence.commit,
                gitTree: gitEvidence.tree,
                workingTreeDirty: gitEvidence.workingTreeDirty
            )
        } catch {
            return nil
        }
    }

    private var portableManifestPath: String {
        guard let root = try? V4SourceHasher.repositoryRoot(for: manifestURL) else {
            return manifestURL.lastPathComponent
        }
        return V4EvidencePath.portable(manifestURL, repositoryRoot: root)
    }

    func validateRequiredCoverage(
        manifest: V4Manifest,
        transferByPair: [String: String]
    ) throws -> V4PreFrozenGateResult {
        var reasons: [String] = []
        var transfersPass = true
        var pairsPass = true
        var familiesPass = true

        func check(_ split: DatasetSplit) {
            let pairs = manifest.pairs.filter {
                $0.split == split &&
                    (split == .frozen
                        ? ($0.virginFrozen && !V6VirginHoldoutPolicy.isExcluded($0.id))
                        : !$0.virginFrozen)
            }
            let observedTransfers: Set<String> = Set(pairs.compactMap {
                let transfer = ReferenceTransfer.parse(transferByPair[$0.id])
                guard transfer != .unknown else { return nil }
                return transfer.canonicalName
            })
            let observedFamilies = Set(pairs.compactMap { $0.contentFamily })
            let requiredTransfers = split == .frozen
                ? configuration.frozenCoveragePolicy.requiredTransfers
                : (configuration.requiredTransfersBySplit[split] ?? [])
            let requiredFamilies = split == .frozen
                ? configuration.frozenCoveragePolicy.requiredFamilies
                : (configuration.requiredFamiliesBySplit[split] ?? [])
            let missingTransfers = requiredTransfers.subtracting(observedTransfers)
            let missingFamilies = requiredFamilies.subtracting(observedFamilies)
            let transferStatus = V4CoveragePolicy.status(observed: observedTransfers, required: requiredTransfers)
            let familyStatus: V4GateStatus
            let pairStatus: V4GateStatus
            if split == .frozen {
                let named = requiredFamilies.isEmpty ? .pass : V4CoveragePolicy.status(observed: observedFamilies, required: requiredFamilies)
                let policy = configuration.frozenCoveragePolicy
                familyStatus = named == .pass && policy.familyStatus(observed: observedFamilies) == .pass ? .pass : .fail
                pairStatus = policy.pairStatus(count: pairs.count)
            } else {
                familyStatus = V4CoveragePolicy.status(observed: observedFamilies, required: requiredFamilies)
                pairStatus = .pass
            }
            transfersPass = transfersPass && transferStatus == .pass
            pairsPass = pairsPass && pairStatus == .pass
            familiesPass = familiesPass && familyStatus == .pass
            let pairReason = split == .frozen
                ? "; virginPairs=\(pairs.count)/\(configuration.minimumVirginFrozenPairs), distinctFamilies=\(observedFamilies.count)/\(configuration.minimumDistinctFrozenFamilies)"
                : ""
            reasons.append("\(split.rawValue): missing transfers=[\(missingTransfers.sorted().joined(separator: ","))] families=[\(missingFamilies.sorted().joined(separator: ","))]\(pairReason)")
        }
        check(.tune)
        check(.validation)
        check(.frozen)
        if !transfersPass || !pairsPass || !familiesPass {
            coverageReasons.append(contentsOf: reasons)
        }
        return V4PreFrozenGateResult(
            transferCoverage: transfersPass ? .pass : .fail,
            pairCoverage: pairsPass ? .pass : .fail,
            familyCoverage: familiesPass ? .pass : .fail
        )
    }

    private func transferAnalysis(
        evaluations: [String: V2DatasetEvaluation], records: [PairRecord], transferByPair: [String: String]
    ) -> [String: [String: V2MetricBreakdown]] {
        var result: [String: [String: V2MetricBreakdown]] = [:]
        for (label, evaluation) in evaluations {
            var grouped: [String: [V2MetricBreakdown]] = [:]
            for video in evaluation.videos {
                grouped[transferByPair[video.pairID] ?? "UNKNOWN", default: []].append(video.metrics)
            }
            result[label] = grouped.mapValues { V2MetricsEvaluator.aggregate($0) }
        }
        _ = records
        return result
    }

    private func familyAnalysis(
        evaluations: [String: V2DatasetEvaluation], manifest: V4Manifest
    ) -> [String: [String: V2MetricBreakdown]] {
        let familyByID = Dictionary(uniqueKeysWithValues: manifest.pairs.compactMap { pair -> (String, String)? in
            guard let family = pair.contentFamily, !family.isEmpty else { return nil }
            return (pair.id, family)
        })
        return evaluations.mapValues { evaluation in
            var grouped: [String: [V2MetricBreakdown]] = [:]
            for video in evaluation.videos {
                grouped[familyByID[video.pairID] ?? "UNKNOWN", default: []].append(video.metrics)
            }
            return grouped.mapValues { V2MetricsEvaluator.aggregate($0) }
        }
    }

    private func writeArtifacts(_ report: V4FinalReport) throws {
        try writeJSON(report, name: "data-video-v4-final.json")
        let markdown = makeMarkdown(report)
        try markdown.write(to: outputDirectory.appendingPathComponent("data-video-v4-report.md"), atomically: true, encoding: .utf8)
    }

    /*
    private func makeMarkdown(_ report: V4FinalReport) -> String {
        func metric(_ key: String, _ value: V2DatasetEvaluation?) -> String {
            guard let value else { return "NOT MEASURED" }
            switch key {
            case "objective": return String(format: "%.6f", value.metrics.objective)
            case "shadow": return String(format: "%.6f", value.metrics.shadowError)
            case "shadowLift": return String(format: "%.6f", value.metrics.shadowLiftRatio)
            case "highlight": return String(format: "%.6f", value.metrics.highlightError)
            case "midtone": return String(format: "%.6f", value.metrics.midtoneError)
            default: return "NOT MEASURED"
            }
        }
        let selected = report.selectedCandidate?.parameters
        let reasons = report.reasons.map { "- ($0)" }.joined(separator: "\n")
        return """
        # SDR→HDR Calibrated V4

        Verdict: `(report.verdict.rawValue)`

        ## Protocol

        - Manifest: `(report.manifestPath)`
        - Split seed: (report.configuration.splitSeed)
        - Search seed: (report.configuration.searchSeed)
        - Global/local candidates: (report.configuration.globalCandidates)/(report.configuration.localCandidates)
        - Aggregation: video → content-family balanced mean
        - Virgin Frozen: sealed until candidate/code/objective hashes were frozen; opened once after selection.

        ## V2 vs V4

        | Split | V2 objective | V4 objective | V2 shadow | V4 shadow | V2 shadow lift | V4 shadow lift |
        |---|---:|---:|---:|---:|---:|---:|
        | Tune | (metric("objective", report.baseline["v2-tune"])) | (metric("objective", report.selectedCandidate?.tune)) | (metric("shadow", report.baseline["v2-tune"])) | (metric("shadow", report.selectedCandidate?.tune)) | (metric("shadowLift", report.baseline["v2-tune"])) | (metric("shadowLift", report.selectedCandidate?.tune)) |
        | Validation | (metric("objective", report.baseline["v2-validation"])) | (metric("objective", report.selectedCandidate?.validation)) | (metric("shadow", report.baseline["v2-validation"])) | (metric("shadow", report.selectedCandidate?.validation)) | (metric("shadowLift", report.baseline["v2-validation"])) | (metric("shadowLift", report.selectedCandidate?.validation)) |
        | Virgin Frozen | (metric("objective", report.frozen["calibratedV2"])) | (metric("objective", report.frozen["calibratedV4"])) | (metric("shadow", report.frozen["calibratedV2"])) | (metric("shadow", report.frozen["calibratedV4"])) | (metric("shadowLift", report.frozen["calibratedV2"])) | (metric("shadowLift", report.frozen["calibratedV4"])) |

        ## Selected parameters

        (selected.map { "`\(String(describing: $0))`" } ?? "NOT SELECTED")

        ## Decision

        (reasons)

        ## Limitations

        (report.limitations.map { "- ($0)" }.joined(separator: "\n"))
        """
    }

    */

    private func makeMarkdown(_ report: V4FinalReport) -> String {
        func metric(_ key: String, _ value: V2DatasetEvaluation?) -> String {
            guard let value else { return "NOT MEASURED" }
            switch key {
            case "objective": return String(format: "%.6f", value.metrics.objective)
            case "shadow": return String(format: "%.6f", value.metrics.shadowError)
            case "shadowLift": return String(format: "%.6f", value.metrics.shadowLiftRatio)
            case "highlight": return String(format: "%.6f", value.metrics.highlightError)
            case "midtone": return String(format: "%.6f", value.metrics.midtoneError)
            default: return "NOT MEASURED"
            }
        }
        let selected = report.selectedCandidate.map { String(describing: $0.parameters) } ?? "NOT SELECTED"
        let reasons = report.reasons.map { "- " + $0 }.joined(separator: "\n")
        let limitations = report.limitations.map { "- " + $0 }.joined(separator: "\n")
        let lines = [
            "# SDR to HDR Calibrated V4",
            "",
            "Verdict: " + report.verdict.rawValue,
            "",
            "## Protocol",
            "",
            "- Manifest: " + report.manifestPath,
            "- Split seed: " + String(report.configuration.splitSeed),
            "- Search seed: " + String(report.configuration.searchSeed),
            "- Global/local candidates: " + String(report.configuration.globalCandidates) + "/" + String(report.configuration.localCandidates),
            "- Aggregation: video to content-family balanced mean",
            "- Virgin Frozen: sealed until candidate, code, manifest and objective hashes were frozen; opened once after selection.",
            "",
            "## V2 vs V4",
            "",
            "| Split | V2 objective | V4 objective | V2 shadow | V4 shadow | V2 shadow lift | V4 shadow lift |",
            "|---|---:|---:|---:|---:|---:|---:|",
            "| Tune | " + metric("objective", report.baseline["v2-tune"]) + " | " + metric("objective", report.selectedCandidate?.tune) + " | " + metric("shadow", report.baseline["v2-tune"]) + " | " + metric("shadow", report.selectedCandidate?.tune) + " | " + metric("shadowLift", report.baseline["v2-tune"]) + " | " + metric("shadowLift", report.selectedCandidate?.tune) + " |",
            "| Validation | " + metric("objective", report.baseline["v2-validation"]) + " | " + metric("objective", report.selectedCandidate?.validation) + " | " + metric("shadow", report.baseline["v2-validation"]) + " | " + metric("shadow", report.selectedCandidate?.validation) + " | " + metric("shadowLift", report.baseline["v2-validation"]) + " | " + metric("shadowLift", report.selectedCandidate?.validation) + " |",
            "| Virgin Frozen | " + metric("objective", report.frozen["calibratedV2"]) + " | " + metric("objective", report.frozen["calibratedV4"]) + " | " + metric("shadow", report.frozen["calibratedV2"]) + " | " + metric("shadow", report.frozen["calibratedV4"]) + " | " + metric("shadowLift", report.frozen["calibratedV2"]) + " | " + metric("shadowLift", report.frozen["calibratedV4"]) + " |",
            "",
            "## Selected parameters",
            "",
            selected,
            "",
            "## Decision",
            "",
            reasons,
            "",
            "## Limitations",
            "",
            limitations
        ]
        return lines.joined(separator: "\n")
    }

    private func writeJSON<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        try encoder.encode(value).write(to: outputDirectory.appendingPathComponent(name))
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(value)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }


    private func halton(_ index: Int, base: Int) -> Double {
        var result = 0.0
        var fraction = 1.0
        var value = index
        while value > 0 {
            fraction /= Double(base)
            result += fraction * Double(value % base)
            value /= base
        }
        return result
    }

    private func improvement(_ baseline: Double, _ candidate: Double) -> Double {
        V4PromotionMath.improvementRatio(baseline: baseline, candidate: candidate)
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data(("[HDRCalibrate V4] " + message + "\n").utf8))
    }
}
