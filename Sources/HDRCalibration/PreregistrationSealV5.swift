import Foundation
import HDRCore

/// V5 is the first preregistration version created after V4 was
/// audit-invalidated.  It reuses the reviewed typed semantic definitions as
/// inputs, but adds an execution-bound identity for the final policy adapter.
public struct V5ValidationCorpusRequirement: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-validation-corpus-requirement-v5"

    public let semanticVersion: String
    public let minimumValidationPairCount: Int
    public let requiredFamilyLabels: [String]
    public let familyDisjointRoles: Bool
    public let coverageRule: String

    public init(
        semanticVersion: String = V5ValidationCorpusRequirement.semanticVersion,
        minimumValidationPairCount: Int = 6,
        requiredFamilyLabels: [String] = ["LIVE"],
        familyDisjointRoles: Bool = true,
        coverageRule: String = "minimum-cardinality-plus-preregistered-structural-coverage"
    ) {
        self.semanticVersion = semanticVersion
        self.minimumValidationPairCount = minimumValidationPairCount
        self.requiredFamilyLabels = requiredFamilyLabels.sorted(by: V4CanonicalOrdering.stringLess)
        self.familyDisjointRoles = familyDisjointRoles
        self.coverageRule = coverageRule
    }

    public static let current = V5ValidationCorpusRequirement()

    public func validate() throws {
        guard semanticVersion == Self.semanticVersion,
              minimumValidationPairCount > 0,
              !requiredFamilyLabels.isEmpty,
              requiredFamilyLabels == requiredFamilyLabels.sorted(by: V4CanonicalOrdering.stringLess),
              familyDisjointRoles,
              !coverageRule.isEmpty else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }
}

/// A V5 component identity is deliberately derived from the exact V4 typed
/// component identity plus a new version domain.  Historical V4 bytes remain
/// visible, but cannot be mistaken for the current executable identity.
public struct V5ComponentIdentity: Codable, Hashable, Sendable {
    public let component: String
    public let semanticVersion: String
    public let sourceV4Identity: String

    public init(component: String, sourceV4Identity: String) {
        self.component = component
        self.semanticVersion = "sdr-(component)-definition-v5"
        self.sourceV4Identity = sourceV4Identity
    }

    public func canonicalSHA256() throws -> String {
        guard !component.isEmpty,
              sourceV4Identity.count == 64,
              sourceV4Identity.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 97...102: return true
                  default: return false
                  }
              }) else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        return try HDRCanonicalIdentity.sha256(self)
    }
}

/// Exact output of the production V4 adapter, bound to the new V5 domain.
/// `validationCorpusRequirement` is intentionally separate from
/// `productionAdapterConfiguration.shortlistSize`: the former describes the
/// validation corpus, while the latter controls candidate handoff.
public struct V5FinalRunnerSemanticConfiguration: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-final-runner-definition-v5"

    public let semanticVersion: String
    public let policy: SDRInputInterpretationPolicy
    public let productionAdapterConfiguration: V4FinalRunnerSemanticConfiguration
    public let candidateShortlistSize: Int
    public let validationCorpusRequirement: V5ValidationCorpusRequirement

    public init(
        policy: SDRInputInterpretationPolicy,
        productionAdapterConfiguration: V4FinalRunnerSemanticConfiguration,
        validationCorpusRequirement: V5ValidationCorpusRequirement
    ) throws {
        self.semanticVersion = Self.semanticVersion
        self.policy = policy
        self.productionAdapterConfiguration = productionAdapterConfiguration
        self.candidateShortlistSize = productionAdapterConfiguration.shortlistSize
        self.validationCorpusRequirement = validationCorpusRequirement
        try validate()
    }

    public func validate() throws {
        _ = try productionAdapterConfiguration.canonicalSHA256()
        try validationCorpusRequirement.validate()
        guard semanticVersion == Self.semanticVersion,
              productionAdapterConfiguration.policy == policy,
              candidateShortlistSize == productionAdapterConfiguration.shortlistSize,
              candidateShortlistSize > 0,
              validationCorpusRequirement.minimumValidationPairCount >= candidateShortlistSize else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }
}

public struct V5SearchDefinition: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-search-definition-v5"

    public let semanticVersion: String
    public let invalidatedV4SearchDefinitionHash: String
    public let policyDefinitionHashV5: String
    public let preparationDefinitionHashV5: String
    public let metricDefinitionHashV5: String
    public let colorScienceDefinitionHashV5: String
    public let gateDefinitionHashV5: String
    public let searchAlgorithmDefinitionHashV5: String
    public let runnerDefinitionHashV5: String
    public let bt709FinalRunnerSemanticHash: String
    public let bt1886FinalRunnerSemanticHash: String
    public let baseV4SearchDefinition: SDRCalibrationSearchDefinitionV4
    public let candidatePolicies: [SDRInputInterpretationPolicy]
    public let searchBudgetPerPolicy: Int
    public let seed: UInt64
    public let splitSeed: UInt64
    public let candidateShortlistSize: Int
    public let validationCorpusRequirement: V5ValidationCorpusRequirement

    public init(
        invalidatedV4SearchDefinitionHash: String,
        policyDefinitionHashV5: String,
        preparationDefinitionHashV5: String,
        metricDefinitionHashV5: String,
        colorScienceDefinitionHashV5: String,
        gateDefinitionHashV5: String,
        searchAlgorithmDefinitionHashV5: String,
        runnerDefinitionHashV5: String,
        bt709FinalRunnerSemanticHash: String,
        bt1886FinalRunnerSemanticHash: String,
        baseV4SearchDefinition: SDRCalibrationSearchDefinitionV4,
        validationCorpusRequirement: V5ValidationCorpusRequirement
    ) {
        self.semanticVersion = Self.semanticVersion
        self.invalidatedV4SearchDefinitionHash = invalidatedV4SearchDefinitionHash
        self.policyDefinitionHashV5 = policyDefinitionHashV5
        self.preparationDefinitionHashV5 = preparationDefinitionHashV5
        self.metricDefinitionHashV5 = metricDefinitionHashV5
        self.colorScienceDefinitionHashV5 = colorScienceDefinitionHashV5
        self.gateDefinitionHashV5 = gateDefinitionHashV5
        self.searchAlgorithmDefinitionHashV5 = searchAlgorithmDefinitionHashV5
        self.runnerDefinitionHashV5 = runnerDefinitionHashV5
        self.bt709FinalRunnerSemanticHash = bt709FinalRunnerSemanticHash
        self.bt1886FinalRunnerSemanticHash = bt1886FinalRunnerSemanticHash
        self.baseV4SearchDefinition = baseV4SearchDefinition
        self.candidatePolicies = baseV4SearchDefinition.policyCandidates
        self.searchBudgetPerPolicy = baseV4SearchDefinition.searchBudgetPerPolicy
        self.seed = baseV4SearchDefinition.seed
        self.splitSeed = baseV4SearchDefinition.splitSeed
        self.candidateShortlistSize = baseV4SearchDefinition.shortlistSize
        self.validationCorpusRequirement = validationCorpusRequirement
    }

    public func validate() throws {
        try baseV4SearchDefinition.validate()
        try validationCorpusRequirement.validate()
        let identities = [
            policyDefinitionHashV5,
            preparationDefinitionHashV5,
            metricDefinitionHashV5,
            colorScienceDefinitionHashV5,
            gateDefinitionHashV5,
            searchAlgorithmDefinitionHashV5,
            runnerDefinitionHashV5,
            bt709FinalRunnerSemanticHash,
            bt1886FinalRunnerSemanticHash
        ]
        guard semanticVersion == Self.semanticVersion,
              invalidatedV4SearchDefinitionHash == PreregisteredCalibrationExperimentV5.invalidatedV4SearchDefinitionHash,
              candidatePolicies == [.bt709SourceLinear, .bt1886ReferenceDisplay],
              searchBudgetPerPolicy == 192,
              seed == 2_026_09_12,
              candidateShortlistSize == 3,
              identities.allSatisfy({ $0.count == 64 && $0.unicodeScalars.allSatisfy { scalar in
                  switch scalar.value {
                  case 48...57, 97...102: return true
                  default: return false
                  }
              } }) else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }
}

public struct V5PreregisteredCalibrationRuntimeConfiguration: Sendable {
    public let policy: SDRInputInterpretationPolicy
    public let baseV4Runtime: V4PreregisteredCalibrationRuntimeConfiguration
    public let finalRunnerConfiguration: V5FinalRunnerSemanticConfiguration
    public let sealedFinalRunnerSemanticHash: String
    public let actualFinalRunnerSemanticHash: String

    public var candidateShortlistSize: Int { finalRunnerConfiguration.candidateShortlistSize }

    public init(experiment: PreregisteredCalibrationExperimentV5, policy: SDRInputInterpretationPolicy) throws {
        try experiment.validate()
        guard experiment.searchDefinition.candidatePolicies.contains(policy) else {
            throw PreregisteredCalibrationExecutionError.policyNotPreregistered
        }
        let base = try V4PreregisteredCalibrationRuntimeConfiguration(
            seal: experiment.seal,
            experimentSearchDefinitionHashV4: experiment.invalidatedV4SearchDefinitionHash,
            policy: policy
        )
        let adapted = try V4CalibrationConfiguration(preregisteredRuntime: base)
        let finalBase = try adapted.finalRunnerSemanticConfiguration()
        let final = try V5FinalRunnerSemanticConfiguration(
            policy: policy,
            productionAdapterConfiguration: finalBase,
            validationCorpusRequirement: experiment.validationCorpusRequirement
        )
        let actual = try final.canonicalSHA256()
        let sealed = experiment.sealedFinalRunnerSemanticHash(for: policy)
        guard actual == sealed else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        self.policy = policy
        self.baseV4Runtime = base
        self.finalRunnerConfiguration = final
        self.sealedFinalRunnerSemanticHash = sealed
        self.actualFinalRunnerSemanticHash = actual
    }
}

public struct PreregisteredCalibrationExperimentV5: Codable, Hashable, Sendable {
    public static let artifactVersion = 5
    public static let currentStatus = "PREREGISTERED_V5_EXECUTION_BOUND_SEMANTIC_ONLY"
    public static let invalidatedV4SearchDefinitionHash = "bdbf705973fa43f92ab60435bfa04dc1656fdf52c4a8687070d1185b30c809fc"
    public static let retiredV1SearchDefinitionHash = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608"
    public static let invalidatedV2SearchDefinitionHash = "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41"
    public static let invalidatedV3SearchDefinitionHash = "7a2fcf82bb40b45f774d942dac62a57d5c75b7cba16b5415a295ed8a68db8889"

    public let artifactVersion: Int
    public let status: String
    public let preregistrationInvalidated: Bool
    public let correctnessBaseline: String
    public let seal: SDRCalibrationSemanticSealV4
    public let searchDefinition: V5SearchDefinition
    public let policyDefinitionHashV5: String
    public let preparationDefinitionHashV5: String
    public let metricDefinitionHashV5: String
    public let colorScienceDefinitionHashV5: String
    public let gateDefinitionHashV5: String
    public let searchAlgorithmDefinitionHashV5: String
    public let runnerDefinitionHashV5: String
    public let searchDefinitionHashV5: String
    public let bt709FinalRunnerSemanticHash: String
    public let bt1886FinalRunnerSemanticHash: String
    public let invalidatedV4SearchDefinitionHash: String
    public let retiredV1SearchDefinitionHash: String
    public let invalidatedV2SearchDefinitionHash: String
    public let invalidatedV3SearchDefinitionHash: String
    public let candidateShortlistSize: Int
    public let validationCorpusRequirement: V5ValidationCorpusRequirement
    public let corpusDefinitionHash: String
    public let experimentBindingHash: String
    public let mediaQualification: String
    public let tune: String
    public let validation: String
    public let objectiveEvaluations: Int

    public init(
        seal: SDRCalibrationSemanticSealV4,
        correctnessBaseline: String = "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9",
        validationCorpusRequirement: V5ValidationCorpusRequirement = .current
    ) throws {
        let policyHash = try V5ComponentIdentity(component: "policy", sourceV4Identity: seal.policyDefinitionHashV4).canonicalSHA256()
        let preparationHash = try V5ComponentIdentity(component: "preparation", sourceV4Identity: seal.preparationDefinitionHashV4).canonicalSHA256()
        let metricHash = try V5ComponentIdentity(component: "metric", sourceV4Identity: seal.metricDefinitionHashV4).canonicalSHA256()
        let colorHash = try V5ComponentIdentity(component: "color-science", sourceV4Identity: seal.colorScienceDefinitionHash).canonicalSHA256()
        let gateHash = try V5ComponentIdentity(component: "gate", sourceV4Identity: seal.gateDefinitionHash).canonicalSHA256()
        let algorithmHash = try V5ComponentIdentity(component: "search-algorithm", sourceV4Identity: seal.searchAlgorithmDefinitionHashV4).canonicalSHA256()
        let runnerHash = try V5ComponentIdentity(component: "runner", sourceV4Identity: seal.runnerDefinitionHash).canonicalSHA256()
        let finalBT709 = try Self.deriveFinalRunner(
            seal: seal,
            policy: .bt709SourceLinear,
            validationCorpusRequirement: validationCorpusRequirement
        ).canonicalSHA256()
        let finalBT1886 = try Self.deriveFinalRunner(
            seal: seal,
            policy: .bt1886ReferenceDisplay,
            validationCorpusRequirement: validationCorpusRequirement
        ).canonicalSHA256()
        let search = V5SearchDefinition(
            invalidatedV4SearchDefinitionHash: seal.searchDefinitionHashV4,
            policyDefinitionHashV5: policyHash,
            preparationDefinitionHashV5: preparationHash,
            metricDefinitionHashV5: metricHash,
            colorScienceDefinitionHashV5: colorHash,
            gateDefinitionHashV5: gateHash,
            searchAlgorithmDefinitionHashV5: algorithmHash,
            runnerDefinitionHashV5: runnerHash,
            bt709FinalRunnerSemanticHash: finalBT709,
            bt1886FinalRunnerSemanticHash: finalBT1886,
            baseV4SearchDefinition: seal.searchDefinition,
            validationCorpusRequirement: validationCorpusRequirement
        )
        let searchHash = try search.canonicalSHA256()
        self.artifactVersion = Self.artifactVersion
        self.status = Self.currentStatus
        self.preregistrationInvalidated = false
        self.correctnessBaseline = correctnessBaseline
        self.seal = seal
        self.searchDefinition = search
        self.policyDefinitionHashV5 = policyHash
        self.preparationDefinitionHashV5 = preparationHash
        self.metricDefinitionHashV5 = metricHash
        self.colorScienceDefinitionHashV5 = colorHash
        self.gateDefinitionHashV5 = gateHash
        self.searchAlgorithmDefinitionHashV5 = algorithmHash
        self.runnerDefinitionHashV5 = runnerHash
        self.searchDefinitionHashV5 = searchHash
        self.bt709FinalRunnerSemanticHash = finalBT709
        self.bt1886FinalRunnerSemanticHash = finalBT1886
        self.invalidatedV4SearchDefinitionHash = seal.searchDefinitionHashV4
        self.retiredV1SearchDefinitionHash = Self.retiredV1SearchDefinitionHash
        self.invalidatedV2SearchDefinitionHash = Self.invalidatedV2SearchDefinitionHash
        self.invalidatedV3SearchDefinitionHash = Self.invalidatedV3SearchDefinitionHash
        self.candidateShortlistSize = search.candidateShortlistSize
        self.validationCorpusRequirement = validationCorpusRequirement
        self.corpusDefinitionHash = "NOT_YET_CREATED"
        self.experimentBindingHash = "NOT_YET_CREATED"
        self.mediaQualification = "NOT_RUN"
        self.tune = "NOT_RUN"
        self.validation = "NOT_RUN"
        self.objectiveEvaluations = 0
    }

    public static func current() throws -> PreregisteredCalibrationExperimentV5 {
        try PreregisteredCalibrationExperimentV5(seal: SDRCalibrationSemanticSealV4.current())
    }

    public func sealedFinalRunnerSemanticHash(for policy: SDRInputInterpretationPolicy) -> String {
        switch policy {
        case .bt709SourceLinear: return bt709FinalRunnerSemanticHash
        case .bt1886ReferenceDisplay: return bt1886FinalRunnerSemanticHash
        default: return ""
        }
    }

    public func validate() throws {
        try seal.searchDefinition.validate()
        try searchDefinition.validate()
        try validationCorpusRequirement.validate()
        let expectedPolicyHash = try V5ComponentIdentity(component: "policy", sourceV4Identity: seal.policyDefinitionHashV4).canonicalSHA256()
        let expectedPreparationHash = try V5ComponentIdentity(component: "preparation", sourceV4Identity: seal.preparationDefinitionHashV4).canonicalSHA256()
        let expectedMetricHash = try V5ComponentIdentity(component: "metric", sourceV4Identity: seal.metricDefinitionHashV4).canonicalSHA256()
        let expectedColorHash = try V5ComponentIdentity(component: "color-science", sourceV4Identity: seal.colorScienceDefinitionHash).canonicalSHA256()
        let expectedGateHash = try V5ComponentIdentity(component: "gate", sourceV4Identity: seal.gateDefinitionHash).canonicalSHA256()
        let expectedAlgorithmHash = try V5ComponentIdentity(component: "search-algorithm", sourceV4Identity: seal.searchAlgorithmDefinitionHashV4).canonicalSHA256()
        let expectedRunnerHash = try V5ComponentIdentity(component: "runner", sourceV4Identity: seal.runnerDefinitionHash).canonicalSHA256()
        let expectedSearchHash = try searchDefinition.canonicalSHA256()
        guard artifactVersion == Self.artifactVersion,
              status == Self.currentStatus,
              !preregistrationInvalidated,
              correctnessBaseline == "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9",
              invalidatedV4SearchDefinitionHash == Self.invalidatedV4SearchDefinitionHash,
              invalidatedV4SearchDefinitionHash == seal.searchDefinitionHashV4,
              retiredV1SearchDefinitionHash == Self.retiredV1SearchDefinitionHash,
              invalidatedV2SearchDefinitionHash == Self.invalidatedV2SearchDefinitionHash,
              invalidatedV3SearchDefinitionHash == Self.invalidatedV3SearchDefinitionHash,
              candidateShortlistSize == 3,
              candidateShortlistSize == searchDefinition.candidateShortlistSize,
              corpusDefinitionHash == "NOT_YET_CREATED",
              experimentBindingHash == "NOT_YET_CREATED",
              mediaQualification == "NOT_RUN",
              tune == "NOT_RUN",
              validation == "NOT_RUN",
              objectiveEvaluations == 0,
              policyDefinitionHashV5 == expectedPolicyHash,
              preparationDefinitionHashV5 == expectedPreparationHash,
              metricDefinitionHashV5 == expectedMetricHash,
              colorScienceDefinitionHashV5 == expectedColorHash,
              gateDefinitionHashV5 == expectedGateHash,
              searchAlgorithmDefinitionHashV5 == expectedAlgorithmHash,
              runnerDefinitionHashV5 == expectedRunnerHash,
              searchDefinitionHashV5 == expectedSearchHash,
              searchDefinition.policyDefinitionHashV5 == policyDefinitionHashV5,
              searchDefinition.preparationDefinitionHashV5 == preparationDefinitionHashV5,
              searchDefinition.metricDefinitionHashV5 == metricDefinitionHashV5,
              searchDefinition.colorScienceDefinitionHashV5 == colorScienceDefinitionHashV5,
              searchDefinition.gateDefinitionHashV5 == gateDefinitionHashV5,
              searchDefinition.searchAlgorithmDefinitionHashV5 == searchAlgorithmDefinitionHashV5,
              searchDefinition.runnerDefinitionHashV5 == runnerDefinitionHashV5,
              searchDefinition.bt709FinalRunnerSemanticHash == bt709FinalRunnerSemanticHash,
              searchDefinition.bt1886FinalRunnerSemanticHash == bt1886FinalRunnerSemanticHash else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func validateAgainstCurrentSemantics() throws {
        try validate()
        let current = try Self.current()
        guard self == current else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }

    public func humanReadableDocumentation() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .throw
        let json = String(decoding: try encoder.encode(self), as: UTF8.self)
        return """
        # PR #13 — V5 execution-bound preregistration

        V4 is historical and audit-invalidated. This V5 object is the current
        semantic-only preregistration. No media corpus, objective evaluation,
        Tune, Validation, or Frozen evaluation is included.

        - status: `\(status)`
        - V4 source identity: `\(invalidatedV4SearchDefinitionHash)` (`AUDIT_INVALIDATED`)
        - candidate shortlist: `\(candidateShortlistSize)`
        - minimum validation corpus pairs: `\(validationCorpusRequirement.minimumValidationPairCount)`
        - corpus identity: `\(corpusDefinitionHash)`
        - experiment binding: `\(experimentBindingHash)`

        ```json
        \(json)
        ```
        """
    }

    private static func deriveFinalRunner(
        seal: SDRCalibrationSemanticSealV4,
        policy: SDRInputInterpretationPolicy,
        validationCorpusRequirement: V5ValidationCorpusRequirement
    ) throws -> V5FinalRunnerSemanticConfiguration {
        let baseRuntime = try V4PreregisteredCalibrationRuntimeConfiguration(
            seal: seal,
            experimentSearchDefinitionHashV4: seal.searchDefinitionHashV4,
            policy: policy
        )
        let adapted = try V4CalibrationConfiguration(preregisteredRuntime: baseRuntime)
        let production = try adapted.finalRunnerSemanticConfiguration()
        return try V5FinalRunnerSemanticConfiguration(
            policy: policy,
            productionAdapterConfiguration: production,
            validationCorpusRequirement: validationCorpusRequirement
        )
    }
}

public final class PreregisteredCalibrationRunnerV5 {
    public let experiment: PreregisteredCalibrationExperimentV5

    public init(experiment: PreregisteredCalibrationExperimentV5) throws {
        try experiment.validate()
        self.experiment = experiment
    }

    /// Verify-only is the only enabled V5 entry point in this no-data phase.
    /// It derives the actual production adapter configuration and checks both
    /// policy-specific sealed final identities before any candidate exists.
    public func verifyOnly() throws -> [V5PreregisteredCalibrationRuntimeConfiguration] {
        let runtimes = try experiment.searchDefinition.candidatePolicies.map {
            try V5PreregisteredCalibrationRuntimeConfiguration(experiment: experiment, policy: $0)
        }
        guard runtimes.map(\.policy) == [.bt709SourceLinear, .bt1886ReferenceDisplay],
              runtimes.allSatisfy({ $0.candidateShortlistSize == experiment.candidateShortlistSize }),
              experiment.validationCorpusRequirement.minimumValidationPairCount >= experiment.candidateShortlistSize else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        return runtimes
    }
}
