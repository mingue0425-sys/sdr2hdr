import CryptoKit
import Foundation
import HDRCore

public enum SDRCalibrationRebaseVerdict: String, Codable, Hashable, Sendable {
    case selectBT709SourceLinear = "SELECT_BT709_SOURCE_LINEAR"
    case selectBT1886ReferenceDisplay = "SELECT_BT1886_REFERENCE_DISPLAY"
    case noPolicyPromotable = "NO_POLICY_PROMOTABLE"
    case inconclusive = "INCONCLUSIVE"
    case blockedMissingData = "BLOCKED_MISSING_DATA"
}

public enum SDRCalibrationStageStatus: String, Codable, Hashable, Sendable {
    case preregistered = "PREREGISTERED"
    case blockedMissingData = "BLOCKED_MISSING_DATA"
    case complete = "COMPLETE"
    case invalidated = "INVALIDATED_FOR_SELECTION"
}

/// The search contract is serialized before any Validation result is read.
/// It is deliberately independent of the old V4 result artifacts.
public struct SDRCalibrationSearchDefinition: Codable, Hashable, Sendable {
    public let version: String
    public let policyVersion: String
    public let policyCandidates: [SDRInputInterpretationPolicy]
    public let tuneSplitIdentity: String
    public let validationSplitIdentity: String
    public let searchSpace: [String: String]
    public let searchBudgetPerPolicy: Int
    public let seed: UInt64
    public let objectiveDefinitions: [String]
    public let hardCorrectnessGates: [String]
    public let safetyGates: [String]
    public let shortlistSize: Int
    public let selectionRule: [String]
    public let tieBreakRule: [String]
    public let failurePolicy: [String]

    public init(
        version: String,
        policyVersion: String,
        policyCandidates: [SDRInputInterpretationPolicy],
        tuneSplitIdentity: String,
        validationSplitIdentity: String,
        searchSpace: [String: String],
        searchBudgetPerPolicy: Int,
        seed: UInt64,
        objectiveDefinitions: [String],
        hardCorrectnessGates: [String],
        safetyGates: [String],
        shortlistSize: Int,
        selectionRule: [String],
        tieBreakRule: [String],
        failurePolicy: [String]
    ) {
        self.version = version
        self.policyVersion = policyVersion
        self.policyCandidates = policyCandidates
        self.tuneSplitIdentity = tuneSplitIdentity
        self.validationSplitIdentity = validationSplitIdentity
        self.searchSpace = searchSpace
        self.searchBudgetPerPolicy = searchBudgetPerPolicy
        self.seed = seed
        self.objectiveDefinitions = objectiveDefinitions
        self.hardCorrectnessGates = hardCorrectnessGates
        self.safetyGates = safetyGates
        self.shortlistSize = shortlistSize
        self.selectionRule = selectionRule
        self.tieBreakRule = tieBreakRule
        self.failurePolicy = failurePolicy
    }

    public static let preregistered = SDRCalibrationSearchDefinition(
        version: "sdr-calibration-rebase-protocol-v1",
        policyVersion: "sdr-input-interpretation-policy-v1",
        policyCandidates: [.bt709SourceLinear, .bt1886ReferenceDisplay],
        tuneSplitIdentity: "approved-Tune-manifest-required;family-overlap-audit-before-selection",
        validationSplitIdentity: "approved-Validation-manifest-required;shortlist-sealed-before-access",
        searchSpace: [
            "paperWhiteNits": "190...245;configuration/reference mapping parameter",
            "peakNits": "900...1500;must exceed paperWhiteNits",
            "highlightStrength": "0.42...0.86",
            "contrastStrength": "0.50...0.95",
            "saturationCompensation": "0.10...0.50",
            "shadowProtection": "0.05...1.0",
            "temporalStability": "0.20...0.98",
            "toneCurve": "sceneRelativeV4;existing architecture retained"
        ],
        searchBudgetPerPolicy: 192,
        seed: 2_026_09_12,
        objectiveDefinitions: [
            "existing V2 objective and metric version; no new weighted score",
            "per-region luminance, highlight, shadow, color, temporal, structure",
            "signed diagnostic, clipping, near-black behavior recorded separately"
        ],
        hardCorrectnessGates: [
            "finite outputs and no GPU error",
            "transfer/range/metadata resolution matches policy",
            "required transform monotonicity and exact black/white anchors",
            "temporal sequence and precision checks pass"
        ],
        safetyGates: [
            "no unexpected fallback",
            "no range mismatch",
            "no clipping or near-black safety violation",
            "no invalid paired sample"
        ],
        shortlistSize: 3,
        selectionRule: [
            "all hard correctness gates pass",
            "all safety gates pass",
            "primary existing objective is minimized",
            "temporal stability, clipping, and near-black safety break ties"
        ],
        tieBreakRule: [
            "lower objective",
            "lower temporal error",
            "lower clipping ratio",
            "lower near-black contrast loss",
            "lexicographically smallest canonical parameter vector"
        ],
        failurePolicy: [
            "infrastructure failure before metric exposure may rerun the same sealed configuration",
            "metric exposure followed by failure invalidates this selection cycle",
            "no threshold, metric, policy, or search-space change after Validation exposure"
        ]
    )

    public func sha256() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SDRCalibrationCandidateEvidence: Codable, Hashable, Sendable {
    public let id: String
    public let policy: SDRInputInterpretationPolicy
    public let parameterVector: [String: Double]
    public let objective: Double?
    public let perRegionDiagnostics: [String: Double]
    public let hardGatesPassed: Bool
    public let failureCount: Int
    public let fallbackCount: Int

    public init(
        id: String,
        policy: SDRInputInterpretationPolicy,
        parameterVector: [String: Double] = [:],
        objective: Double? = nil,
        perRegionDiagnostics: [String: Double] = [:],
        hardGatesPassed: Bool = false,
        failureCount: Int = 0,
        fallbackCount: Int = 0
    ) {
        self.id = id
        self.policy = policy
        self.parameterVector = parameterVector
        self.objective = objective
        self.perRegionDiagnostics = perRegionDiagnostics
        self.hardGatesPassed = hardGatesPassed
        self.failureCount = failureCount
        self.fallbackCount = fallbackCount
    }
}

public struct SDRCalibrationStageArtifact: Codable, Hashable, Sendable {
    public let lineageID: String
    public let stage: String
    public let status: SDRCalibrationStageStatus
    public let approvedManifestConfigured: Bool
    public let reason: String
    public let policyCandidates: [SDRInputInterpretationPolicy]
    public let candidateEvidence: [SDRCalibrationCandidateEvidence]
    public let objectiveEvaluations: Int

    public init(
        lineageID: String,
        stage: String,
        status: SDRCalibrationStageStatus,
        approvedManifestConfigured: Bool,
        reason: String,
        policyCandidates: [SDRInputInterpretationPolicy],
        candidateEvidence: [SDRCalibrationCandidateEvidence] = [],
        objectiveEvaluations: Int = 0
    ) {
        self.lineageID = lineageID
        self.stage = stage
        self.status = status
        self.approvedManifestConfigured = approvedManifestConfigured
        self.reason = reason
        self.policyCandidates = policyCandidates
        self.candidateEvidence = candidateEvidence
        self.objectiveEvaluations = objectiveEvaluations
    }
}

public struct SDRCalibrationCandidateArtifact: Codable, Hashable, Sendable {
    public let lineageID: String
    public let status: SDRCalibrationRebaseVerdict
    public let selectedPolicy: SDRInputInterpretationPolicy?
    public let selectedCandidate: String?
    public let candidateConfigurationHash: String?
    public let configurationFreezeIsLocalOnly: Bool
    public let productionDefaultChanged: Bool
    public let reason: String

    public init(
        lineageID: String,
        status: SDRCalibrationRebaseVerdict,
        selectedPolicy: SDRInputInterpretationPolicy? = nil,
        selectedCandidate: String? = nil,
        candidateConfigurationHash: String? = nil,
        configurationFreezeIsLocalOnly: Bool = true,
        productionDefaultChanged: Bool = false,
        reason: String
    ) {
        self.lineageID = lineageID
        self.status = status
        self.selectedPolicy = selectedPolicy
        self.selectedCandidate = selectedCandidate
        self.candidateConfigurationHash = candidateConfigurationHash
        self.configurationFreezeIsLocalOnly = configurationFreezeIsLocalOnly
        self.productionDefaultChanged = productionDefaultChanged
        self.reason = reason
    }
}

public struct SDRCalibrationLineageArtifact: Codable, Hashable, Sendable {
    public let lineageID: String
    public let correctnessBaseline: String
    public let sdrPolicyVersion: String
    public let preparationVersion: String
    public let metricVersion: String
    public let tuneIdentity: String
    public let validationIdentity: String
    public let searchDefinitionHash: String
    public let selectedPolicy: SDRInputInterpretationPolicy?
    public let selectedCandidate: String?
    public let candidateConfigurationHash: String?
    public let frozenAccessed: Bool
    public let objectiveEvaluations: Int
    public let oldCalibrationReusable: Bool
    public let productionDefaultChanged: Bool
    public let verdict: SDRCalibrationRebaseVerdict
    public let reason: String

    public init(
        lineageID: String,
        correctnessBaseline: String,
        sdrPolicyVersion: String,
        preparationVersion: String,
        metricVersion: String,
        tuneIdentity: String,
        validationIdentity: String,
        searchDefinitionHash: String,
        selectedPolicy: SDRInputInterpretationPolicy? = nil,
        selectedCandidate: String? = nil,
        candidateConfigurationHash: String? = nil,
        frozenAccessed: Bool,
        objectiveEvaluations: Int,
        oldCalibrationReusable: Bool,
        productionDefaultChanged: Bool,
        verdict: SDRCalibrationRebaseVerdict,
        reason: String
    ) {
        self.lineageID = lineageID
        self.correctnessBaseline = correctnessBaseline
        self.sdrPolicyVersion = sdrPolicyVersion
        self.preparationVersion = preparationVersion
        self.metricVersion = metricVersion
        self.tuneIdentity = tuneIdentity
        self.validationIdentity = validationIdentity
        self.searchDefinitionHash = searchDefinitionHash
        self.selectedPolicy = selectedPolicy
        self.selectedCandidate = selectedCandidate
        self.candidateConfigurationHash = candidateConfigurationHash
        self.frozenAccessed = frozenAccessed
        self.objectiveEvaluations = objectiveEvaluations
        self.oldCalibrationReusable = oldCalibrationReusable
        self.productionDefaultChanged = productionDefaultChanged
        self.verdict = verdict
        self.reason = reason
    }
}

public enum SDRCalibrationRebaseProtocol {
    public static let lineageID = "calibration-rebase-2026-09-sdr-policy-v1"
    public static let correctnessBaseline = "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9"
    public static let metricVersion = "v2-objective-with-v61-directional-diagnostics"
    public static let missingDataReason =
        "approved Tune/Validation manifest is not configured; no calibration media was opened"

    public static func blockedTuneArtifact() -> SDRCalibrationStageArtifact {
        SDRCalibrationStageArtifact(
            lineageID: lineageID,
            stage: "Tune",
            status: .blockedMissingData,
            approvedManifestConfigured: false,
            reason: missingDataReason,
            policyCandidates: SDRCalibrationSearchDefinition.preregistered.policyCandidates
        )
    }

    public static func blockedValidationArtifact() -> SDRCalibrationStageArtifact {
        SDRCalibrationStageArtifact(
            lineageID: lineageID,
            stage: "Validation",
            status: .blockedMissingData,
            approvedManifestConfigured: false,
            reason: "Tune shortlist cannot be frozen until approved Tune/Validation data is configured",
            policyCandidates: SDRCalibrationSearchDefinition.preregistered.policyCandidates
        )
    }

    public static func blockedCandidateArtifact() -> SDRCalibrationCandidateArtifact {
        SDRCalibrationCandidateArtifact(
            lineageID: lineageID,
            status: .blockedMissingData,
            reason: "No candidate was selected because required Tune/Validation data is unavailable"
        )
    }

    public static func blockedLineageArtifact() -> SDRCalibrationLineageArtifact {
        SDRCalibrationLineageArtifact(
            lineageID: lineageID,
            correctnessBaseline: correctnessBaseline,
            sdrPolicyVersion: SDRCalibrationSearchDefinition.preregistered.policyVersion,
            preparationVersion: V6PreparationConfiguration.v6.version,
            metricVersion: metricVersion,
            tuneIdentity: "UNAVAILABLE",
            validationIdentity: "UNAVAILABLE",
            searchDefinitionHash: SDRCalibrationSearchDefinition.preregistered.sha256(),
            frozenAccessed: false,
            objectiveEvaluations: 0,
            oldCalibrationReusable: false,
            productionDefaultChanged: false,
            verdict: .blockedMissingData,
            reason: missingDataReason
        )
    }
}
