import Foundation
import HDRCore
import Metal

/// Transient, process-local derivation cache.  It is not serialized and does
/// not participate in any identity.  It only lets artifact construction and
/// the immediately following execution binding share the same typed V4
/// runtime values instead of reconstructing the large adapter repeatedly.
private final class V6RuntimeRegistry: @unchecked Sendable {
    static let shared = V6RuntimeRegistry()

    private let lock = NSLock()
    private var values: [String: [SDRInputInterpretationPolicy: V4PreregisteredCalibrationRuntimeConfiguration]] = [:]

    func store(
        _ runtimes: [SDRInputInterpretationPolicy: V4PreregisteredCalibrationRuntimeConfiguration],
        for searchDefinitionHash: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        values[searchDefinitionHash] = runtimes
    }

    func runtime(
        for searchDefinitionHash: String,
        policy: SDRInputInterpretationPolicy
    ) -> V4PreregisteredCalibrationRuntimeConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return values[searchDefinitionHash]?[policy]
    }
}

/// V6 makes corpus requirements executable semantics.  The same immutable
/// value is serialized into the preregistration identity and installed on the
/// production runner before it can inspect a manifest or evaluate a candidate.
public enum V6CorpusCardinalityOperator: String, Codable, Hashable, Sendable {
    case atLeast = "AT_LEAST"

    public func accepts(_ actual: Int, minimum: Int) -> Bool {
        switch self {
        case .atLeast:
            return actual >= minimum
        }
    }
}

public enum V6CoverageDimension: String, Codable, Hashable, Sendable {
    case familyLabel = "FAMILY_LABEL"
}

public enum V6CorpusFailurePolicy: String, Codable, Hashable, Sendable {
    case reject = "REJECT_BEFORE_OBJECTIVE_EVALUATION"
}

public struct V6CoverageRule: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-corpus-coverage-rule-v6"

    public let semanticVersion: String
    public let requiredDimensions: [V6CoverageDimension]
    public let missingCategoryPolicy: V6CorpusFailurePolicy

    public init(
        semanticVersion: String = V6CoverageRule.semanticVersion,
        requiredDimensions: [V6CoverageDimension] = [.familyLabel],
        missingCategoryPolicy: V6CorpusFailurePolicy = .reject
    ) {
        self.semanticVersion = semanticVersion
        self.requiredDimensions = requiredDimensions
        self.missingCategoryPolicy = missingCategoryPolicy
    }

    public static let current = V6CoverageRule()

    public func validate() throws {
        guard semanticVersion == Self.semanticVersion,
              requiredDimensions == [.familyLabel],
              missingCategoryPolicy == .reject else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }
}

public struct V6CorpusPairIdentity: Codable, Hashable, Sendable {
    public let sourceMasterId: String
    public let familyLabel: String

    public init(sourceMasterId: String, familyLabel: String) {
        self.sourceMasterId = sourceMasterId
        self.familyLabel = familyLabel
    }

    public func validate() throws {
        guard !sourceMasterId.isEmpty, !familyLabel.isEmpty else {
            throw PreregisteredCalibrationExecutionError.corpusContractMismatch
        }
    }
}

/// Runtime evidence supplied by the corpus loader.  It deliberately contains
/// only structural corpus identity, not pixels or objective values.
public struct V6CorpusExecutionInput: Codable, Hashable, Sendable {
    public let tunePairs: [V6CorpusPairIdentity]
    public let validationPairs: [V6CorpusPairIdentity]

    public init(
        tunePairs: [V6CorpusPairIdentity],
        validationPairs: [V6CorpusPairIdentity]
    ) {
        self.tunePairs = tunePairs
        self.validationPairs = validationPairs
    }

    public func validateStructure() throws {
        try tunePairs.forEach { try $0.validate() }
        try validationPairs.forEach { try $0.validate() }
        guard Set(tunePairs.map(\.sourceMasterId)).count == tunePairs.count,
              Set(validationPairs.map(\.sourceMasterId)).count == validationPairs.count else {
            throw PreregisteredCalibrationExecutionError.corpusContractMismatch
        }
    }
}

/// One typed owner for the corpus cardinality, family and coverage semantics
/// consumed by the V6 runner.  There is intentionally no shortlist field here:
/// candidate handoff and dataset cardinality are independent semantics.
public struct V6CorpusContract: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-corpus-contract-v6"

    public let semanticVersion: String
    public let minimumTunePairCount: Int
    public let tuneCardinalityOperator: V6CorpusCardinalityOperator
    public let minimumValidationPairCount: Int
    public let validationCardinalityOperator: V6CorpusCardinalityOperator
    public let requiredFamilyLabels: [String]
    public let familyDisjointRoles: Bool
    public let coverageRule: V6CoverageRule
    public let failurePolicy: V6CorpusFailurePolicy

    public init(
        semanticVersion: String = V6CorpusContract.semanticVersion,
        minimumTunePairCount: Int = 5,
        tuneCardinalityOperator: V6CorpusCardinalityOperator = .atLeast,
        minimumValidationPairCount: Int = 6,
        validationCardinalityOperator: V6CorpusCardinalityOperator = .atLeast,
        requiredFamilyLabels: [String] = ["LIVE"],
        familyDisjointRoles: Bool = true,
        coverageRule: V6CoverageRule = .current,
        failurePolicy: V6CorpusFailurePolicy = .reject
    ) {
        self.semanticVersion = semanticVersion
        self.minimumTunePairCount = minimumTunePairCount
        self.tuneCardinalityOperator = tuneCardinalityOperator
        self.minimumValidationPairCount = minimumValidationPairCount
        self.validationCardinalityOperator = validationCardinalityOperator
        self.requiredFamilyLabels = requiredFamilyLabels.sorted(by: V4CanonicalOrdering.stringLess)
        self.familyDisjointRoles = familyDisjointRoles
        self.coverageRule = coverageRule
        self.failurePolicy = failurePolicy
    }

    public static let current = V6CorpusContract()

    public func validate() throws {
        try coverageRule.validate()
        let sortedLabels = requiredFamilyLabels.sorted(by: V4CanonicalOrdering.stringLess)
        guard semanticVersion == Self.semanticVersion,
              minimumTunePairCount > 0,
              minimumValidationPairCount > 0,
              tuneCardinalityOperator == .atLeast,
              validationCardinalityOperator == .atLeast,
              !requiredFamilyLabels.isEmpty,
              requiredFamilyLabels == sortedLabels,
              Set(requiredFamilyLabels).count == requiredFamilyLabels.count,
              familyDisjointRoles,
              failurePolicy == .reject else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    /// This is the execution gate.  Callers must invoke it before any
    /// candidate generation or objective evaluator is reachable.
    public func validate(_ corpus: V6CorpusExecutionInput) throws {
        do {
            try validate()
            try corpus.validateStructure()
        } catch {
            throw PreregisteredCalibrationExecutionError.corpusContractMismatch
        }

        guard tuneCardinalityOperator.accepts(corpus.tunePairs.count, minimum: minimumTunePairCount),
              validationCardinalityOperator.accepts(corpus.validationPairs.count, minimum: minimumValidationPairCount) else {
            throw PreregisteredCalibrationExecutionError.corpusContractMismatch
        }

        let tuneIDs = Set(corpus.tunePairs.map(\.sourceMasterId))
        let validationIDs = Set(corpus.validationPairs.map(\.sourceMasterId))
        guard !familyDisjointRoles || tuneIDs.isDisjoint(with: validationIDs) else {
            throw PreregisteredCalibrationExecutionError.corpusContractMismatch
        }

        if coverageRule.requiredDimensions.contains(.familyLabel) {
            let tuneLabels = Set(corpus.tunePairs.map(\.familyLabel))
            let validationLabels = Set(corpus.validationPairs.map(\.familyLabel))
            guard requiredFamilyLabels.allSatisfy(tuneLabels.contains),
                  requiredFamilyLabels.allSatisfy(validationLabels.contains) else {
                throw PreregisteredCalibrationExecutionError.corpusContractMismatch
            }
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }
}

/// Correctly versioned component identity.  V5's historical typo is retained
/// in its invalid artifact; V6 never emits the literal `"(component)"`.
public struct V6ComponentIdentity: Codable, Hashable, Sendable {
    public let component: String
    public let semanticVersion: String
    public let sourceV4Identity: String

    public init(component: String, sourceV4Identity: String) {
        self.component = component
        self.semanticVersion = "sdr-\(component)-definition-v6"
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

public struct V6FinalRunnerSemanticConfiguration: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-final-runner-definition-v6"

    public let semanticVersion: String
    public let policy: SDRInputInterpretationPolicy
    public let productionAdapterConfiguration: V4FinalRunnerSemanticConfiguration
    public let candidateShortlistSize: Int
    public let corpusContract: V6CorpusContract

    public init(
        policy: SDRInputInterpretationPolicy,
        productionAdapterConfiguration: V4FinalRunnerSemanticConfiguration,
        corpusContract: V6CorpusContract
    ) throws {
        self.semanticVersion = Self.semanticVersion
        self.policy = policy
        self.productionAdapterConfiguration = productionAdapterConfiguration
        self.candidateShortlistSize = productionAdapterConfiguration.shortlistSize
        self.corpusContract = corpusContract
        try validate()
    }

    public func validate() throws {
        _ = try productionAdapterConfiguration.canonicalSHA256()
        try corpusContract.validate()
        guard semanticVersion == Self.semanticVersion,
              productionAdapterConfiguration.policy == policy,
              candidateShortlistSize == productionAdapterConfiguration.shortlistSize,
              candidateShortlistSize == 3,
              candidateShortlistSize > 0 else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }
}

public struct V6SearchDefinition: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-search-definition-v6"

    public let semanticVersion: String
    public let invalidatedV5SearchDefinitionHash: String
    public let policyDefinitionHashV6: String
    public let preparationDefinitionHashV6: String
    public let metricDefinitionHashV6: String
    public let colorScienceDefinitionHashV6: String
    public let gateDefinitionHashV6: String
    public let searchAlgorithmDefinitionHashV6: String
    public let runnerDefinitionHashV6: String
    public let bt709FinalRunnerSemanticHashV6: String
    public let bt1886FinalRunnerSemanticHashV6: String
    public let baseV4SearchDefinition: SDRCalibrationSearchDefinitionV4
    public let candidatePolicies: [SDRInputInterpretationPolicy]
    public let searchBudgetPerPolicy: Int
    public let seed: UInt64
    public let splitSeed: UInt64
    public let candidateShortlistSize: Int
    public let corpusContract: V6CorpusContract

    public init(
        invalidatedV5SearchDefinitionHash: String,
        policyDefinitionHashV6: String,
        preparationDefinitionHashV6: String,
        metricDefinitionHashV6: String,
        colorScienceDefinitionHashV6: String,
        gateDefinitionHashV6: String,
        searchAlgorithmDefinitionHashV6: String,
        runnerDefinitionHashV6: String,
        bt709FinalRunnerSemanticHashV6: String,
        bt1886FinalRunnerSemanticHashV6: String,
        baseV4SearchDefinition: SDRCalibrationSearchDefinitionV4,
        corpusContract: V6CorpusContract
    ) {
        self.semanticVersion = Self.semanticVersion
        self.invalidatedV5SearchDefinitionHash = invalidatedV5SearchDefinitionHash
        self.policyDefinitionHashV6 = policyDefinitionHashV6
        self.preparationDefinitionHashV6 = preparationDefinitionHashV6
        self.metricDefinitionHashV6 = metricDefinitionHashV6
        self.colorScienceDefinitionHashV6 = colorScienceDefinitionHashV6
        self.gateDefinitionHashV6 = gateDefinitionHashV6
        self.searchAlgorithmDefinitionHashV6 = searchAlgorithmDefinitionHashV6
        self.runnerDefinitionHashV6 = runnerDefinitionHashV6
        self.bt709FinalRunnerSemanticHashV6 = bt709FinalRunnerSemanticHashV6
        self.bt1886FinalRunnerSemanticHashV6 = bt1886FinalRunnerSemanticHashV6
        self.baseV4SearchDefinition = baseV4SearchDefinition
        self.candidatePolicies = baseV4SearchDefinition.policyCandidates
        self.searchBudgetPerPolicy = baseV4SearchDefinition.searchBudgetPerPolicy
        self.seed = baseV4SearchDefinition.seed
        self.splitSeed = baseV4SearchDefinition.splitSeed
        self.candidateShortlistSize = baseV4SearchDefinition.shortlistSize
        self.corpusContract = corpusContract
    }

    public func validate() throws {
        try baseV4SearchDefinition.validate()
        try corpusContract.validate()
        let identities = [
            policyDefinitionHashV6,
            preparationDefinitionHashV6,
            metricDefinitionHashV6,
            colorScienceDefinitionHashV6,
            gateDefinitionHashV6,
            searchAlgorithmDefinitionHashV6,
            runnerDefinitionHashV6,
            bt709FinalRunnerSemanticHashV6,
            bt1886FinalRunnerSemanticHashV6
        ]
        guard semanticVersion == Self.semanticVersion,
              invalidatedV5SearchDefinitionHash == PreregisteredCalibrationExperimentV6.invalidatedV5SearchDefinitionHash,
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

public struct V6PreregisteredCalibrationRuntimeConfiguration: Sendable {
    public let policy: SDRInputInterpretationPolicy
    public let baseV4Runtime: V4PreregisteredCalibrationRuntimeConfiguration
    public let productionRunnerConfiguration: V4CalibrationConfiguration
    public let finalRunnerConfiguration: V6FinalRunnerSemanticConfiguration
    public let sealedFinalRunnerSemanticHashV6: String
    public let actualFinalRunnerSemanticHashV6: String

    public var candidateShortlistSize: Int { finalRunnerConfiguration.candidateShortlistSize }

    public init(experiment: PreregisteredCalibrationExperimentV6, policy: SDRInputInterpretationPolicy) throws {
        v6RuntimeVerificationTrace("before experiment validation")
        try experiment.validate()
        v6RuntimeVerificationTrace("after experiment validation")
        try self.init(validatedExperiment: experiment, policy: policy)
    }

    fileprivate init(validatedExperiment experiment: PreregisteredCalibrationExperimentV6, policy: SDRInputInterpretationPolicy) throws {
        guard experiment.searchDefinition.candidatePolicies.contains(policy) else {
            throw PreregisteredCalibrationExecutionError.policyNotPreregistered
        }
        v6RuntimeVerificationTrace("before V4 runtime adapter")
        guard let base = V6RuntimeRegistry.shared.runtime(
            for: experiment.searchDefinitionHashV6,
            policy: policy
        ) else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        v6RuntimeVerificationTrace("after V4 runtime adapter")
        var adapted = try V4CalibrationConfiguration(preregisteredRuntime: base)
        v6RuntimeVerificationTrace("after V4 configuration adapter")
        adapted.v6CorpusContract = experiment.corpusContract
        try adapted.validatePreregisteredExecutionBinding()
        v6RuntimeVerificationTrace("after V4 binding validation")
        let production = try adapted.finalRunnerSemanticConfiguration()
        v6RuntimeVerificationTrace("after production runner semantic configuration")
        let final = try V6FinalRunnerSemanticConfiguration(
            policy: policy,
            productionAdapterConfiguration: production,
            corpusContract: experiment.corpusContract
        )
        v6RuntimeVerificationTrace("after V6 final runner semantic configuration")
        let actual = try final.canonicalSHA256()
        v6RuntimeVerificationTrace("after V6 final runner hash")
        let sealed = experiment.sealedFinalRunnerSemanticHash(for: policy)
        guard actual == sealed else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        v6RuntimeVerificationTrace("after sealed identity comparison")
        self.policy = policy
        self.baseV4Runtime = base
        self.productionRunnerConfiguration = adapted
        self.finalRunnerConfiguration = final
        self.sealedFinalRunnerSemanticHashV6 = sealed
        self.actualFinalRunnerSemanticHashV6 = actual
    }
}

public struct PreregisteredCalibrationExperimentV6: Codable, Hashable, Sendable {
    public static let artifactVersion = 6
    public static let currentStatus = "PREREGISTERED_V6_CORPUS_CONTRACT_EXECUTION_BOUND"
    public static let invalidatedV4SearchDefinitionHash = "bdbf705973fa43f92ab60435bfa04dc1656fdf52c4a8687070d1185b30c809fc"
    public static let invalidatedV5SearchDefinitionHash = "6ae84a8a245858c2328bfe2c80811f12cdd1375e86109ec2f83d4bd3a6cdb43e"
    public static let retiredV1SearchDefinitionHash = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608"
    public static let invalidatedV2SearchDefinitionHash = "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41"
    public static let invalidatedV3SearchDefinitionHash = "7a2fcf82bb40b45f774d942dac62a57d5c75b7cba16b5415a295ed8a68db8889"

    public let artifactVersion: Int
    public let status: String
    public let preregistrationInvalidated: Bool
    public let correctnessBaseline: String
    public let seal: SDRCalibrationSemanticSealV4
    public let searchDefinition: V6SearchDefinition
    public let colorScienceDefinitionHashV6: String
    public let policyDefinitionHashV6: String
    public let preparationDefinitionHashV6: String
    public let metricDefinitionHashV6: String
    public let gateDefinitionHashV6: String
    public let searchAlgorithmDefinitionHashV6: String
    public let runnerDefinitionHashV6: String
    public let searchDefinitionHashV6: String
    public let bt709FinalRunnerSemanticHashV6: String
    public let bt1886FinalRunnerSemanticHashV6: String
    public let invalidatedV4SearchDefinitionHash: String
    public let invalidatedV5SearchDefinitionHash: String
    public let v1Status: String
    public let v2Status: String
    public let v3Status: String
    public let v4Status: String
    public let v5Status: String
    public let candidateShortlistSize: Int
    public let corpusContract: V6CorpusContract
    public let corpusDefinitionHash: String
    public let experimentBindingHash: String
    public let mediaQualification: String
    public let tune: String
    public let validation: String
    public let objectiveEvaluations: Int

    public init(
        seal: SDRCalibrationSemanticSealV4,
        correctnessBaseline: String = "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9",
        corpusContract: V6CorpusContract = .current
    ) throws {
        let policyHash = try V6ComponentIdentity(component: "policy", sourceV4Identity: seal.policyDefinitionHashV4).canonicalSHA256()
        let preparationHash = try V6ComponentIdentity(component: "preparation", sourceV4Identity: seal.preparationDefinitionHashV4).canonicalSHA256()
        let metricHash = try V6ComponentIdentity(component: "metric", sourceV4Identity: seal.metricDefinitionHashV4).canonicalSHA256()
        let colorHash = try V6ComponentIdentity(component: "color-science", sourceV4Identity: seal.colorScienceDefinitionHash).canonicalSHA256()
        let gateHash = try V6ComponentIdentity(component: "gate", sourceV4Identity: seal.gateDefinitionHash).canonicalSHA256()
        let algorithmHash = try V6ComponentIdentity(component: "search-algorithm", sourceV4Identity: seal.searchAlgorithmDefinitionHashV4).canonicalSHA256()
        let runnerHash = try V6ComponentIdentity(component: "runner", sourceV4Identity: seal.runnerDefinitionHash).canonicalSHA256()
        let baseBT709 = try V4PreregisteredCalibrationRuntimeConfiguration(
            seal: seal,
            experimentSearchDefinitionHashV4: seal.searchDefinitionHashV4,
            policy: .bt709SourceLinear
        )
        let baseBT1886 = try V4PreregisteredCalibrationRuntimeConfiguration(
            seal: seal,
            experimentSearchDefinitionHashV4: seal.searchDefinitionHashV4,
            policy: .bt1886ReferenceDisplay
        )
        let finalBT709 = try Self.deriveFinalRunner(
            base: baseBT709,
            policy: .bt709SourceLinear,
            corpusContract: corpusContract
        ).canonicalSHA256()
        let finalBT1886 = try Self.deriveFinalRunner(
            base: baseBT1886,
            policy: .bt1886ReferenceDisplay,
            corpusContract: corpusContract
        ).canonicalSHA256()
        let search = V6SearchDefinition(
            invalidatedV5SearchDefinitionHash: Self.invalidatedV5SearchDefinitionHash,
            policyDefinitionHashV6: policyHash,
            preparationDefinitionHashV6: preparationHash,
            metricDefinitionHashV6: metricHash,
            colorScienceDefinitionHashV6: colorHash,
            gateDefinitionHashV6: gateHash,
            searchAlgorithmDefinitionHashV6: algorithmHash,
            runnerDefinitionHashV6: runnerHash,
            bt709FinalRunnerSemanticHashV6: finalBT709,
            bt1886FinalRunnerSemanticHashV6: finalBT1886,
            baseV4SearchDefinition: seal.searchDefinition,
            corpusContract: corpusContract
        )
        let searchHash = try search.canonicalSHA256()
        self.artifactVersion = Self.artifactVersion
        self.status = Self.currentStatus
        self.preregistrationInvalidated = false
        self.correctnessBaseline = correctnessBaseline
        self.seal = seal
        self.searchDefinition = search
        self.colorScienceDefinitionHashV6 = colorHash
        self.policyDefinitionHashV6 = policyHash
        self.preparationDefinitionHashV6 = preparationHash
        self.metricDefinitionHashV6 = metricHash
        self.gateDefinitionHashV6 = gateHash
        self.searchAlgorithmDefinitionHashV6 = algorithmHash
        self.runnerDefinitionHashV6 = runnerHash
        self.searchDefinitionHashV6 = searchHash
        self.bt709FinalRunnerSemanticHashV6 = finalBT709
        self.bt1886FinalRunnerSemanticHashV6 = finalBT1886
        self.invalidatedV4SearchDefinitionHash = seal.searchDefinitionHashV4
        self.invalidatedV5SearchDefinitionHash = Self.invalidatedV5SearchDefinitionHash
        self.v1Status = "RETIRED_INVALIDATED"
        self.v2Status = "AUDIT_INVALIDATED"
        self.v3Status = "AUDIT_INVALIDATED"
        self.v4Status = "AUDIT_INVALIDATED"
        self.v5Status = "AUDIT_INVALIDATED_BY_REAUDIT"
        self.candidateShortlistSize = search.candidateShortlistSize
        self.corpusContract = corpusContract
        self.corpusDefinitionHash = "NOT_YET_CREATED"
        self.experimentBindingHash = "NOT_YET_CREATED"
        self.mediaQualification = "NOT_RUN"
        self.tune = "NOT_RUN"
        self.validation = "NOT_RUN"
        self.objectiveEvaluations = 0
        V6RuntimeRegistry.shared.store(
            [.bt709SourceLinear: baseBT709, .bt1886ReferenceDisplay: baseBT1886],
            for: searchHash
        )
    }

    public static func current() throws -> PreregisteredCalibrationExperimentV6 {
        try PreregisteredCalibrationExperimentV6(seal: SDRCalibrationSemanticSealV4.current())
    }

    public func sealedFinalRunnerSemanticHash(for policy: SDRInputInterpretationPolicy) -> String {
        switch policy {
        case .bt709SourceLinear: return bt709FinalRunnerSemanticHashV6
        case .bt1886ReferenceDisplay: return bt1886FinalRunnerSemanticHashV6
        default: return ""
        }
    }

    public func validate() throws {
        try seal.searchDefinition.validate()
        try searchDefinition.validate()
        try corpusContract.validate()
        let expectedHashes = [
            ("policy", seal.policyDefinitionHashV4, policyDefinitionHashV6),
            ("preparation", seal.preparationDefinitionHashV4, preparationDefinitionHashV6),
            ("metric", seal.metricDefinitionHashV4, metricDefinitionHashV6),
            ("color-science", seal.colorScienceDefinitionHash, colorScienceDefinitionHashV6),
            ("gate", seal.gateDefinitionHash, gateDefinitionHashV6),
            ("search-algorithm", seal.searchAlgorithmDefinitionHashV4, searchAlgorithmDefinitionHashV6),
            ("runner", seal.runnerDefinitionHash, runnerDefinitionHashV6)
        ]
        for (component, source, actual) in expectedHashes {
            guard try V6ComponentIdentity(component: component, sourceV4Identity: source).canonicalSHA256() == actual else {
                throw HDRCanonicalIdentityError.encodingFailed
            }
        }
        guard artifactVersion == Self.artifactVersion,
              status == Self.currentStatus,
              !preregistrationInvalidated,
              correctnessBaseline == "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9",
              invalidatedV4SearchDefinitionHash == Self.invalidatedV4SearchDefinitionHash,
              invalidatedV4SearchDefinitionHash == seal.searchDefinitionHashV4,
              invalidatedV5SearchDefinitionHash == Self.invalidatedV5SearchDefinitionHash,
              v1Status == "RETIRED_INVALIDATED",
              v2Status == "AUDIT_INVALIDATED",
              v3Status == "AUDIT_INVALIDATED",
              v4Status == "AUDIT_INVALIDATED",
              v5Status == "AUDIT_INVALIDATED_BY_REAUDIT",
              candidateShortlistSize == 3,
              candidateShortlistSize == searchDefinition.candidateShortlistSize,
              corpusContract == searchDefinition.corpusContract,
              corpusDefinitionHash == "NOT_YET_CREATED",
              experimentBindingHash == "NOT_YET_CREATED",
              mediaQualification == "NOT_RUN",
              tune == "NOT_RUN",
              validation == "NOT_RUN",
              objectiveEvaluations == 0,
              searchDefinition.invalidatedV5SearchDefinitionHash == invalidatedV5SearchDefinitionHash,
              searchDefinition.policyDefinitionHashV6 == policyDefinitionHashV6,
              searchDefinition.preparationDefinitionHashV6 == preparationDefinitionHashV6,
              searchDefinition.metricDefinitionHashV6 == metricDefinitionHashV6,
              searchDefinition.colorScienceDefinitionHashV6 == colorScienceDefinitionHashV6,
              searchDefinition.gateDefinitionHashV6 == gateDefinitionHashV6,
              searchDefinition.searchAlgorithmDefinitionHashV6 == searchAlgorithmDefinitionHashV6,
              searchDefinition.runnerDefinitionHashV6 == runnerDefinitionHashV6,
              searchDefinition.bt709FinalRunnerSemanticHashV6 == bt709FinalRunnerSemanticHashV6,
              searchDefinition.bt1886FinalRunnerSemanticHashV6 == bt1886FinalRunnerSemanticHashV6,
              searchDefinitionHashV6 == (try? searchDefinition.canonicalSHA256()) else {
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
        # PR #13 — V6 corpus-contract preregistration

        V1–V5 are historical and not execution eligible.  This V6 object binds
        the typed corpus contract to the final runner.  No media corpus hash,
        corpus split, objective evaluation, Tune, Validation, or Frozen
        evaluation is included.

        - status: `\(status)`
        - candidate shortlist: `\(candidateShortlistSize)`
        - minimum Tune pairs: `\(corpusContract.minimumTunePairCount)`
        - minimum Validation pairs: `\(corpusContract.minimumValidationPairCount)`
        - corpus identity: `\(corpusDefinitionHash)`
        - experiment binding: `\(experimentBindingHash)`

        ```json
        \(json)
        ```
        """
    }

    private static func deriveFinalRunner(
        base: V4PreregisteredCalibrationRuntimeConfiguration,
        policy: SDRInputInterpretationPolicy,
        corpusContract: V6CorpusContract
    ) throws -> V6FinalRunnerSemanticConfiguration {
        var adapted = try V4CalibrationConfiguration(preregisteredRuntime: base)
        adapted.v6CorpusContract = corpusContract
        try adapted.validatePreregisteredExecutionBinding()
        let production = try adapted.finalRunnerSemanticConfiguration()
        return try V6FinalRunnerSemanticConfiguration(
            policy: policy,
            productionAdapterConfiguration: production,
            corpusContract: corpusContract
        )
    }
}

public final class PreregisteredCalibrationRunnerV6 {
    public let experiment: PreregisteredCalibrationExperimentV6

    public init(experiment: PreregisteredCalibrationExperimentV6) throws {
        let current = try PreregisteredCalibrationExperimentV6.current()
        guard experiment == current else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        self.experiment = current
    }

    /// Verify the sealed runner identities without opening media or evaluating
    /// an objective.  Actual corpus execution must use the overload accepting
    /// V6CorpusExecutionInput below.
    public func verifyOnly() throws -> [V6PreregisteredCalibrationRuntimeConfiguration] {
        v6RuntimeVerificationTrace("before V6 runtime map")
        let runtimes = try experiment.searchDefinition.candidatePolicies.map {
            try V6PreregisteredCalibrationRuntimeConfiguration(validatedExperiment: experiment, policy: $0)
        }
        v6RuntimeVerificationTrace("after V6 runtime map")
        guard runtimes.map(\.policy) == [.bt709SourceLinear, .bt1886ReferenceDisplay],
              runtimes.allSatisfy({ $0.candidateShortlistSize == experiment.candidateShortlistSize }),
              runtimes.allSatisfy({ $0.productionRunnerConfiguration.v6CorpusContract == experiment.corpusContract }) else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        return runtimes
    }

    /// The execution gate used by the production path.  Corpus violations are
    /// rejected before any candidate generation or objective evaluator can be
    /// reached.
    public func verifyOnly(corpus: V6CorpusExecutionInput) throws -> [V6PreregisteredCalibrationRuntimeConfiguration] {
        let runtimes = try verifyOnly()
        try experiment.corpusContract.validate(corpus)
        return runtimes
    }

    /// Full execution API is intentionally present only as a contract-bound
    /// entry point.  This task never calls it; the corpus argument is required
    /// so no runner can fall back to an independent cardinality default.
    public func run(
        manifestURL: URL,
        outputDirectory: URL,
        corpus: V6CorpusExecutionInput,
        preparedEvaluationPlanURLs: [SDRInputInterpretationPolicy: URL],
        preparedFrozenPlanURLs: [SDRInputInterpretationPolicy: URL]? = nil,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) async throws -> [V4FinalReport] {
        let runtimes = try verifyOnly(corpus: corpus)
        guard let device else { throw CalibrationError.decodeFailed("Metal device unavailable") }
        guard Set(preparedEvaluationPlanURLs.keys) == Set(runtimes.map(\.policy)) else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        var reports: [V4FinalReport] = []
        for runtime in runtimes {
            var configuration = runtime.productionRunnerConfiguration
            configuration.v6CorpusContract = experiment.corpusContract
            configuration.v6CorpusExecutionInput = corpus
            let runner = try CalibrationV4Runner(
                manifestURL: manifestURL,
                outputDirectory: outputDirectory.appendingPathComponent(runtime.policy.rawValue),
                configuration: configuration,
                preparedEvaluationPlanURL: preparedEvaluationPlanURLs[runtime.policy],
                preparedFrozenPlanURL: preparedFrozenPlanURLs?[runtime.policy],
                preparationConfiguration: runtime.baseV4Runtime.preparation,
                metricConfiguration: runtime.baseV4Runtime.metric,
                device: device
            )
            reports.append(try await runner.run())
        }
        return reports
    }
}

private func v6RuntimeVerificationTrace(_ message: String) {
    guard ProcessInfo.processInfo.environment["HDR_V6_VERIFY_TRACE"] == "1" else { return }
    FileHandle.standardError.write(Data("V6_VERIFY_TRACE \(message)\n".utf8))
}
