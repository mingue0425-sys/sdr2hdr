import Foundation
import HDRCore
import Metal

/// V3 preparation definition. The typed V6 configuration is the same value
/// consumed by the preparation runner; prose fields are documentation only.
public struct SDRPreparationDefinitionV3: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-preparation-definition-v3"

    public var semanticVersion: String
    public var configuration: V6PreparationConfiguration
    /// Policy-specific configurations are generated from `configuration`,
    /// never hand-copied.  Preparation reads source-grid luminance, so the
    /// two policy candidates require two exact derived preparation plans.
    public var policyConfigurations: [String: V6PreparationConfiguration]
    public var preparationConfigurationCanonical: String
    public var matcherConfigurationCanonical: String
    public var humanReadableDescription: String
    public var failurePolicy: [String]

    public static let canonicalFieldNames: Set<String> = [
        "semanticVersion", "configuration", "policyConfigurations",
        "preparationConfigurationCanonical", "matcherConfigurationCanonical",
        "humanReadableDescription", "failurePolicy"
    ]

    public init(
        configuration: V6PreparationConfiguration,
        policyCandidates: [SDRInputInterpretationPolicy] = [
            .bt709SourceLinear, .bt1886ReferenceDisplay
        ],
        humanReadableDescription: String = "V6 preparation uses the sealed typed configuration and matcher object",
        failurePolicy: [String] = [
            "decode, alignment, scene, temporal, path, or hash failure rejects the plan",
            "no implicit frame selection or policy fallback at evaluator entry",
            "non-finite preparation values reject before plan sealing"
        ],
        semanticVersion: String = SDRPreparationDefinitionV3.semanticVersion
    ) throws {
        guard configuration.validationFailure() == nil else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        guard policyCandidates == [.bt709SourceLinear, .bt1886ReferenceDisplay] else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        self.semanticVersion = semanticVersion
        self.configuration = configuration
        self.policyConfigurations = Dictionary(uniqueKeysWithValues: policyCandidates.map { policy in
            (policy.rawValue, configuration.forInterpretationPolicy(policy))
        })
        self.preparationConfigurationCanonical = try configuration.canonicalSHA256()
        self.matcherConfigurationCanonical = try configuration.matcherConfiguration.canonicalSHA256()
        self.humanReadableDescription = humanReadableDescription
        self.failurePolicy = failurePolicy
    }

    public static func current() throws -> SDRPreparationDefinitionV3 {
        try SDRPreparationDefinitionV3(configuration: .v6)
    }

    public func validate() throws {
        let policies: [SDRInputInterpretationPolicy] = [
            .bt709SourceLinear, .bt1886ReferenceDisplay
        ]
        let data = try HDRCanonicalIdentity.data(self)
        guard let object = try JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        ) as? [String: Any], Set(object.keys) == Self.canonicalFieldNames,
              configuration.validationFailure() == nil,
              preparationConfigurationCanonical == (try configuration.canonicalSHA256()),
              matcherConfigurationCanonical == (try configuration.matcherConfiguration.canonicalSHA256()),
              Set(policyConfigurations.keys) == Set(policies.map(\.rawValue)),
              policies.allSatisfy({ policy in
                  guard let derived = policyConfigurations[policy.rawValue] else { return false }
                  return derived == configuration.forInterpretationPolicy(policy) &&
                      derived.validationFailure() == nil
              }) else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func configuration(
        for policy: SDRInputInterpretationPolicy
    ) throws -> V6PreparationConfiguration {
        try validate()
        guard let value = policyConfigurations[policy.rawValue],
              value == configuration.forInterpretationPolicy(policy) else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        return value
    }

    public func sha256() throws -> String {
        return try HDRCanonicalIdentity.sha256(self)
    }
}

/// V3 metric definition. Every numeric threshold and equation control used
/// by V2MetricsEvaluator lives in `configuration` and is passed directly to
/// the evaluator by the preregistered execution path.
public struct SDRMetricDefinitionV3: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-metric-definition-v3"

    public var semanticVersion: String
    public var configuration: V2MetricSemanticConfiguration
    public var metricConfigurationCanonical: String
    public var humanReadableDescription: String

    public static let canonicalFieldNames: Set<String> = [
        "semanticVersion", "configuration", "metricConfigurationCanonical",
        "humanReadableDescription"
    ]

    public init(
        configuration: V2MetricSemanticConfiguration,
        humanReadableDescription: String = "V2 objective evaluator consumes the sealed typed metric configuration",
        semanticVersion: String = SDRMetricDefinitionV3.semanticVersion
    ) throws {
        try configuration.validate()
        self.semanticVersion = semanticVersion
        self.configuration = configuration
        self.metricConfigurationCanonical = try configuration.canonicalSHA256()
        self.humanReadableDescription = humanReadableDescription
    }

    public static func current() throws -> SDRMetricDefinitionV3 {
        try SDRMetricDefinitionV3(configuration: .current)
    }

    public func validate() throws {
        let data = try HDRCanonicalIdentity.data(self)
        guard let object = try JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        ) as? [String: Any], Set(object.keys) == Self.canonicalFieldNames else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        try configuration.validate()
        guard metricConfigurationCanonical == (try configuration.canonicalSHA256()) else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func sha256() throws -> String {
        return try HDRCanonicalIdentity.sha256(self)
    }
}

/// Exact search algorithm semantics. Counts, phase order, sampling bases,
/// PRNG identity, duplicate handling, and parent selection are all typed
/// seal inputs rather than inferred from a runner's defaults.
public struct SDRSearchAlgorithmDefinitionV3: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-search-algorithm-definition-v3"

    public var semanticVersion: String
    public var globalCandidateCount: Int
    public var localCandidateCount: Int
    public var totalCandidatesPerPolicy: Int
    public var globalParentCount: Int
    public var phaseOrdering: [String]
    public var sensitivityProbeValues: [Double]
    public var globalSamplingDistribution: String
    public var localSamplingDistribution: String
    public var globalHaltonBases: [Int]
    public var localHaltonBases: [Int]
    public var localNeighborhoodRadius: Double
    public var seedIndexModulus: Int
    public var prngImplementationVersion: String
    public var seedDerivation: String
    public var candidateOrdering: String
    public var duplicateHandling: String
    public var localRefinementParentSelection: String

    public init(
        globalCandidateCount: Int = 128,
        localCandidateCount: Int = 64,
        totalCandidatesPerPolicy: Int = 192,
        globalParentCount: Int = 8,
        phaseOrdering: [String] = ["sensitivity", "global", "local"],
        sensitivityProbeValues: [Double] = [0, 0.25, 0.5, 0.75, 1],
        globalSamplingDistribution: String = "Halton; one point per index; affine map into each parameter bound",
        localSamplingDistribution: String = "Halton neighborhood around selected global parent; affine clamp into each bound",
        globalHaltonBases: [Int] = [2, 3, 5, 7, 11, 13, 17],
        localHaltonBases: [Int] = [19, 23, 29, 31, 37, 41, 43],
        localNeighborhoodRadius: Double = 0.10,
        seedIndexModulus: Int = 104_729,
        prngImplementationVersion: String = "none; deterministic Halton only",
        seedDerivation: String = "Halton index = candidate index + 1 + (search seed modulo seedIndexModulus)",
        candidateOrdering: String = "global then local; within phase ascending candidate index; selection sorts by sealed objective/tie-break",
        duplicateHandling: String = "retain generated records; deterministic sort and lexicographic parameter vector resolve ties",
        localRefinementParentSelection: String = "top 8 gate-passing global candidates, cyclic by local candidate index",
        semanticVersion: String = SDRSearchAlgorithmDefinitionV3.semanticVersion
    ) {
        self.semanticVersion = semanticVersion
        self.globalCandidateCount = globalCandidateCount
        self.localCandidateCount = localCandidateCount
        self.totalCandidatesPerPolicy = totalCandidatesPerPolicy
        self.globalParentCount = globalParentCount
        self.phaseOrdering = phaseOrdering
        self.sensitivityProbeValues = sensitivityProbeValues
        self.globalSamplingDistribution = globalSamplingDistribution
        self.localSamplingDistribution = localSamplingDistribution
        self.globalHaltonBases = globalHaltonBases
        self.localHaltonBases = localHaltonBases
        self.localNeighborhoodRadius = localNeighborhoodRadius
        self.seedIndexModulus = seedIndexModulus
        self.prngImplementationVersion = prngImplementationVersion
        self.seedDerivation = seedDerivation
        self.candidateOrdering = candidateOrdering
        self.duplicateHandling = duplicateHandling
        self.localRefinementParentSelection = localRefinementParentSelection
    }

    public static let current = SDRSearchAlgorithmDefinitionV3()

    public static let canonicalFieldNames: Set<String> = [
        "semanticVersion", "globalCandidateCount", "localCandidateCount",
        "totalCandidatesPerPolicy", "globalParentCount", "phaseOrdering",
        "sensitivityProbeValues", "globalSamplingDistribution",
        "localSamplingDistribution", "globalHaltonBases", "localHaltonBases",
        "localNeighborhoodRadius", "seedIndexModulus", "prngImplementationVersion",
        "seedDerivation", "candidateOrdering", "duplicateHandling",
        "localRefinementParentSelection"
    ]

    public func validate() throws {
        let data = try HDRCanonicalIdentity.data(self)
        guard let object = try JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        ) as? [String: Any], Set(object.keys) == Self.canonicalFieldNames else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        guard globalCandidateCount > 0,
              localCandidateCount > 0,
              totalCandidatesPerPolicy == globalCandidateCount + localCandidateCount,
              globalParentCount > 0,
              globalParentCount <= globalCandidateCount,
              phaseOrdering == ["sensitivity", "global", "local"],
              sensitivityProbeValues.count == 5,
              sensitivityProbeValues.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              sensitivityProbeValues == sensitivityProbeValues.sorted(),
              sensitivityProbeValues.first == 0,
              sensitivityProbeValues.last == 1,
              globalHaltonBases.count == 7,
              localHaltonBases.count == 7,
              globalHaltonBases.allSatisfy({ $0 > 1 }),
              localHaltonBases.allSatisfy({ $0 > 1 }),
              localNeighborhoodRadius.isFinite,
              localNeighborhoodRadius > 0,
              localNeighborhoodRadius <= 1,
              seedIndexModulus > 0,
              !semanticVersion.isEmpty else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func sha256() throws -> String {
        return try HDRCanonicalIdentity.sha256(self)
    }
}

/// V3 search definition. It binds all three semantic definitions and the
/// exact search phases. `V2ParameterBounds.preregistered` is the one typed
/// source of the intended parameter ranges; this object carries its value.
public struct SDRCalibrationSearchDefinitionV3: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-search-definition-v3"

    public var semanticVersion: String
    public var policyDefinitionHashV3: String
    public var preparationDefinitionHashV3: String
    public var metricDefinitionHashV3: String
    public var searchAlgorithmDefinition: SDRSearchAlgorithmDefinitionV3
    public var searchAlgorithmDefinitionHash: String
    public var policyCandidates: [SDRInputInterpretationPolicy]
    public var searchBudgetPerPolicy: Int
    public var seed: UInt64
    public var splitSeed: UInt64
    public var parameterBounds: V2ParameterBounds
    public var parameterRepresentation: String
    public var hardGates: [String]
    public var safetyGates: [String]
    public var safetyThresholds: V4SafetyThresholds
    public var shortlistSize: Int
    public var selectionOrdering: [String]
    public var tieBreakRule: [String]
    public var failurePolicy: [String]

    public static let canonicalFieldNames: Set<String> = [
        "semanticVersion", "policyDefinitionHashV3", "preparationDefinitionHashV3",
        "metricDefinitionHashV3", "searchAlgorithmDefinition",
        "searchAlgorithmDefinitionHash", "policyCandidates", "searchBudgetPerPolicy",
        "seed", "splitSeed", "parameterBounds", "parameterRepresentation", "hardGates",
        "safetyGates", "safetyThresholds", "shortlistSize", "selectionOrdering",
        "tieBreakRule", "failurePolicy"
    ]

    public init(
        policyDefinitionHashV3: String,
        preparationDefinitionHashV3: String,
        metricDefinitionHashV3: String,
        searchAlgorithmDefinition: SDRSearchAlgorithmDefinitionV3 = .current,
        policyCandidates: [SDRInputInterpretationPolicy] = [.bt709SourceLinear, .bt1886ReferenceDisplay],
        searchBudgetPerPolicy: Int = 192,
        seed: UInt64 = 2_026_09_12,
        splitSeed: UInt64 = 92,
        parameterBounds: V2ParameterBounds = .preregistered,
        parameterRepresentation: String = "finite Float32 runtime values; canonical decimal JSON; fixed parameter order",
        hardGates: [String] = [
            "finite outputs and no GPU error",
            "transfer, range, and metadata resolution match the selected policy",
            "transform monotonicity and exact black/white anchors",
            "temporal sequence and precision checks pass"
        ],
        safetyGates: [String] = [
            "no unexpected fallback",
            "no range mismatch",
            "no clipping or near-black safety violation",
            "no invalid paired sample"
        ],
        safetyThresholds: V4SafetyThresholds = V4SafetyThresholds(),
        shortlistSize: Int = 3,
        selectionOrdering: [String] = [
            "all hard correctness gates pass",
            "all safety gates pass",
            "primary existing objective is minimized",
            "temporal stability, clipping, and near-black safety break ties"
        ],
        tieBreakRule: [String] = [
            "lower objective",
            "lower temporal error",
            "lower clipping ratio",
            "lower near-black contrast loss",
            "lexicographically smallest canonical parameter vector"
        ],
        failurePolicy: [String] = [
            "infrastructure failure before metric exposure may rerun the same sealed configuration",
            "metric exposure followed by failure invalidates this selection cycle",
            "no threshold, metric, policy, or search-space change after Validation exposure"
        ],
        semanticVersion: String = SDRCalibrationSearchDefinitionV3.semanticVersion
    ) throws {
        try searchAlgorithmDefinition.validate()
        guard searchBudgetPerPolicy > 0,
              policyCandidates.count == 2,
              Set(policyCandidates).count == policyCandidates.count,
              shortlistSize > 0,
              !parameterBounds.paperWhiteNits.isEmpty,
              !parameterBounds.peakNits.isEmpty,
              !parameterBounds.highlightStrength.isEmpty,
              !parameterBounds.contrastStrength.isEmpty,
              !parameterBounds.saturationCompensation.isEmpty,
              !parameterBounds.shadowProtection.isEmpty,
              !parameterBounds.temporalStability.isEmpty else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        self.semanticVersion = semanticVersion
        self.policyDefinitionHashV3 = policyDefinitionHashV3
        self.preparationDefinitionHashV3 = preparationDefinitionHashV3
        self.metricDefinitionHashV3 = metricDefinitionHashV3
        self.searchAlgorithmDefinition = searchAlgorithmDefinition
        self.searchAlgorithmDefinitionHash = try searchAlgorithmDefinition.sha256()
        self.policyCandidates = policyCandidates
        self.searchBudgetPerPolicy = searchBudgetPerPolicy
        self.seed = seed
        self.splitSeed = splitSeed
        self.parameterBounds = parameterBounds
        self.parameterRepresentation = parameterRepresentation
        self.hardGates = hardGates
        self.safetyGates = safetyGates
        self.safetyThresholds = safetyThresholds
        self.shortlistSize = shortlistSize
        self.selectionOrdering = selectionOrdering
        self.tieBreakRule = tieBreakRule
        self.failurePolicy = failurePolicy
    }

    public func validate() throws {
        try searchAlgorithmDefinition.validate()
        let data = try HDRCanonicalIdentity.data(self)
        guard let object = try JSONSerialization.jsonObject(
            with: data, options: [.fragmentsAllowed]
        ) as? [String: Any], Set(object.keys) == Self.canonicalFieldNames else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        guard searchAlgorithmDefinitionHash == (try searchAlgorithmDefinition.sha256()),
              searchBudgetPerPolicy == searchAlgorithmDefinition.totalCandidatesPerPolicy,
              policyCandidates == [.bt709SourceLinear, .bt1886ReferenceDisplay],
              shortlistSize == 3,
              seed == 2_026_09_12,
              splitSeed == 92,
              !parameterRepresentation.isEmpty else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        let boundValues = [
            parameterBounds.paperWhiteNits.lowerBound, parameterBounds.paperWhiteNits.upperBound,
            parameterBounds.peakNits.lowerBound, parameterBounds.peakNits.upperBound,
            parameterBounds.highlightStrength.lowerBound, parameterBounds.highlightStrength.upperBound,
            parameterBounds.contrastStrength.lowerBound, parameterBounds.contrastStrength.upperBound,
            parameterBounds.saturationCompensation.lowerBound, parameterBounds.saturationCompensation.upperBound,
            parameterBounds.shadowProtection.lowerBound, parameterBounds.shadowProtection.upperBound,
            parameterBounds.temporalStability.lowerBound, parameterBounds.temporalStability.upperBound
        ]
        guard boundValues.allSatisfy(\.isFinite),
              boundValues.enumerated().allSatisfy({ index, value in
                  index % 2 == 0 || value >= boundValues[index - 1]
              }),
              safetyThresholds.isValid else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func sha256() throws -> String {
        return try HDRCanonicalIdentity.sha256(self)
    }
}

/// One canonical pre-corpus preregistration object. It is the only input
/// accepted by `PreregisteredCalibrationRunner`; legacy development runners
/// remain separate and are not preregistered calibration entry points.
public struct PreregisteredCalibrationExperiment: Codable, Hashable, Sendable {
    public static let artifactVersion = 3
    public static let currentStatus = "PREREGISTERED_V3_EXECUTION_BOUND_SEMANTIC_ONLY"

    public var artifactVersion: Int
    public var status: String
    public var preregistrationInvalidated: Bool
    public var correctnessBaseline: String
    public var policyDefinition: SDRPolicyDefinition
    public var preparationDefinition: SDRPreparationDefinitionV3
    public var metricDefinition: SDRMetricDefinitionV3
    public var searchDefinition: SDRCalibrationSearchDefinitionV3
    public var policyDefinitionHashV3: String
    public var preparationDefinitionHashV3: String
    public var metricDefinitionHashV3: String
    public var searchAlgorithmDefinitionHash: String
    public var searchDefinitionHashV3: String
    public var retiredV1SearchDefinitionHash: String
    public var invalidatedV2SearchDefinitionHash: String
    public var corpusDefinitionHash: String
    public var experimentBindingHash: String
    public var mediaQualification: String
    public var tune: String
    public var validation: String
    public var objectiveEvaluations: Int

    public init(
        seal: SDRCalibrationSemanticSealV3,
        correctnessBaseline: String = "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9",
        retiredV1SearchDefinitionHash: String = "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608",
        invalidatedV2SearchDefinitionHash: String = "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41"
    ) {
        self.artifactVersion = Self.artifactVersion
        self.status = Self.currentStatus
        self.preregistrationInvalidated = false
        self.correctnessBaseline = correctnessBaseline
        self.policyDefinition = seal.policyDefinition
        self.preparationDefinition = seal.preparationDefinition
        self.metricDefinition = seal.metricDefinition
        self.searchDefinition = seal.searchDefinition
        self.policyDefinitionHashV3 = seal.policyDefinitionHashV3
        self.preparationDefinitionHashV3 = seal.preparationDefinitionHashV3
        self.metricDefinitionHashV3 = seal.metricDefinitionHashV3
        self.searchAlgorithmDefinitionHash = seal.searchAlgorithmDefinitionHash
        self.searchDefinitionHashV3 = seal.searchDefinitionHashV3
        self.retiredV1SearchDefinitionHash = retiredV1SearchDefinitionHash
        self.invalidatedV2SearchDefinitionHash = invalidatedV2SearchDefinitionHash
        self.corpusDefinitionHash = "NOT_YET_CREATED"
        self.experimentBindingHash = "NOT_YET_CREATED"
        self.mediaQualification = "NOT_RUN"
        self.tune = "NOT_RUN"
        self.validation = "NOT_RUN"
        self.objectiveEvaluations = 0
    }

    public static func current() throws -> PreregisteredCalibrationExperiment {
        try PreregisteredCalibrationExperiment(
            seal: SDRCalibrationSemanticSealV3.current()
        )
    }

    public func validate() throws {
        guard artifactVersion == Self.artifactVersion,
              status == Self.currentStatus,
              !preregistrationInvalidated,
              correctnessBaseline == "bcdb2d151d67bd8e828fb5f5893ff6e548dc32d9",
              retiredV1SearchDefinitionHash == "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608",
              invalidatedV2SearchDefinitionHash == "3ba6890fe50740809fd26269517852154b1f9998a5ed0636fee8a719fb024b41",
              corpusDefinitionHash == "NOT_YET_CREATED",
              experimentBindingHash == "NOT_YET_CREATED",
              mediaQualification == "NOT_RUN",
              tune == "NOT_RUN",
              validation == "NOT_RUN",
              objectiveEvaluations == 0 else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        let seal = try SDRCalibrationSemanticSealV3(
            policyDefinition: policyDefinition,
            preparationDefinition: preparationDefinition,
            metricDefinition: metricDefinition,
            searchDefinition: searchDefinition
        )
        guard policyDefinitionHashV3 == seal.policyDefinitionHashV3,
              preparationDefinitionHashV3 == seal.preparationDefinitionHashV3,
              metricDefinitionHashV3 == seal.metricDefinitionHashV3,
              searchAlgorithmDefinitionHash == seal.searchAlgorithmDefinitionHash,
              searchDefinitionHashV3 == seal.searchDefinitionHashV3 else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        let current = try PreregisteredCalibrationExperiment(
            seal: SDRCalibrationSemanticSealV3.current()
        )
        guard policyDefinition == current.policyDefinition,
              preparationDefinition == current.preparationDefinition,
              metricDefinition == current.metricDefinition,
              searchDefinition == current.searchDefinition,
              policyDefinitionHashV3 == current.policyDefinitionHashV3,
              preparationDefinitionHashV3 == current.preparationDefinitionHashV3,
              metricDefinitionHashV3 == current.metricDefinitionHashV3,
              searchAlgorithmDefinitionHash == current.searchAlgorithmDefinitionHash,
              searchDefinitionHashV3 == current.searchDefinitionHashV3 else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
    }

    public func canonicalSHA256() throws -> String {
        try validate()
        return try HDRCanonicalIdentity.sha256(self)
    }

    /// Documentation is emitted from this same typed object so the report
    /// cannot drift from the JSON artifact that the execution API verifies.
    public func humanReadableDocumentation() throws -> String {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .throw
        let json = try String(
            decoding: encoder.encode(self),
            as: UTF8.self
        )
        let policies = policyDefinition.candidateList.joined(separator: ", ")
        return """
        # PR #13 — execution-bound preregistration V3

        This report is generated from the typed `PreregisteredCalibrationExperiment` object. The execution API derives its runtime configuration from the same object and verifies the runtime semantic identity before candidate generation.

        - Status: `\(status)`
        - Correctness baseline: `\(correctnessBaseline)`
        - Candidate policies: `\(policies)`
        - Global/local candidates per policy: `\(searchDefinition.searchAlgorithmDefinition.globalCandidateCount)/\(searchDefinition.searchAlgorithmDefinition.localCandidateCount)`
        - Total candidates per policy: `\(searchDefinition.searchBudgetPerPolicy)`
        - Shortlist size: `\(searchDefinition.shortlistSize)`
        - Seed: `\(searchDefinition.seed)`
        - Tune: `\(tune)`; Validation: `\(validation)`; objective evaluations: `\(objectiveEvaluations)`

        ## Definition identities

        - PolicyDefinitionHashV3: `\(policyDefinitionHashV3)`
        - PreparationDefinitionHashV3: `\(preparationDefinitionHashV3)`
        - MetricDefinitionHashV3: `\(metricDefinitionHashV3)`
        - SearchAlgorithmDefinitionHash: `\(searchAlgorithmDefinitionHash)`
        - SearchDefinitionHashV3: `\(searchDefinitionHashV3)`
        - CorpusDefinitionHash: `\(corpusDefinitionHash)`
        - ExperimentBindingHash: `\(experimentBindingHash)`

        ## Canonical artifact

        ```json
        \(json)
        ```
        """
    }

    public func writeHumanReadableDocumentation(to url: URL) throws {
        try humanReadableDocumentation().write(to: url, atomically: true, encoding: .utf8)
    }

    public func deriveRuntimeConfiguration(
        for policy: SDRInputInterpretationPolicy
    ) throws -> PreregisteredCalibrationRuntimeConfiguration {
        try validate()
        guard searchDefinition.policyCandidates.contains(policy) else {
            throw PreregisteredCalibrationExecutionError.policyNotPreregistered
        }
        return try PreregisteredCalibrationRuntimeConfiguration(
            experiment: self,
            policy: policy,
            preparation: try preparationDefinition.configuration(for: policy),
            metric: metricDefinition.configuration,
            search: searchDefinition
        )
    }

    public func verifyRuntimeConfiguration(
        _ runtime: PreregisteredCalibrationRuntimeConfiguration
    ) throws {
        let expected = try deriveRuntimeConfiguration(for: runtime.policy)
        guard runtime == expected,
              runtime.semanticIdentity == expected.semanticIdentity else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
    }
}

public struct PreregisteredCalibrationRuntimeConfiguration: Codable, Hashable, Sendable {
    public var experimentSearchDefinitionHashV3: String
    public var policy: SDRInputInterpretationPolicy
    public var preparation: V6PreparationConfiguration
    public var metric: V2MetricSemanticConfiguration
    public var searchAlgorithmDefinition: SDRSearchAlgorithmDefinitionV3
    public var searchSeed: UInt64
    public var splitSeed: UInt64
    public var globalCandidates: Int
    public var localCandidates: Int
    public var totalCandidatesPerPolicy: Int
    public var shortlistSize: Int
    public var parameterBounds: V2ParameterBounds
    public var safetyThresholds: V4SafetyThresholds
    public let semanticIdentity: String

    public init(
        experiment: PreregisteredCalibrationExperiment,
        policy: SDRInputInterpretationPolicy,
        preparation: V6PreparationConfiguration,
        metric: V2MetricSemanticConfiguration,
        search: SDRCalibrationSearchDefinitionV3
    ) throws {
        self.experimentSearchDefinitionHashV3 = experiment.searchDefinitionHashV3
        self.policy = policy
        self.preparation = preparation
        self.metric = metric
        self.searchAlgorithmDefinition = search.searchAlgorithmDefinition
        self.searchSeed = search.seed
        self.splitSeed = search.splitSeed
        self.globalCandidates = search.searchAlgorithmDefinition.globalCandidateCount
        self.localCandidates = search.searchAlgorithmDefinition.localCandidateCount
        self.totalCandidatesPerPolicy = search.searchBudgetPerPolicy
        self.shortlistSize = search.shortlistSize
        self.parameterBounds = search.parameterBounds
        self.safetyThresholds = search.safetyThresholds
        self.semanticIdentity = try Self.identity(
            experimentSearchDefinitionHashV3: experiment.searchDefinitionHashV3,
            policy: policy,
            preparation: preparation,
            metric: metric,
            searchAlgorithmDefinition: search.searchAlgorithmDefinition,
            searchSeed: search.seed,
            splitSeed: search.splitSeed,
            globalCandidates: search.searchAlgorithmDefinition.globalCandidateCount,
            localCandidates: search.searchAlgorithmDefinition.localCandidateCount,
            totalCandidatesPerPolicy: search.searchBudgetPerPolicy,
            shortlistSize: search.shortlistSize,
            parameterBounds: search.parameterBounds,
            safetyThresholds: search.safetyThresholds
        )
    }

    private static func identity(
        experimentSearchDefinitionHashV3: String,
        policy: SDRInputInterpretationPolicy,
        preparation: V6PreparationConfiguration,
        metric: V2MetricSemanticConfiguration,
        searchAlgorithmDefinition: SDRSearchAlgorithmDefinitionV3,
        searchSeed: UInt64,
        splitSeed: UInt64,
        globalCandidates: Int,
        localCandidates: Int,
        totalCandidatesPerPolicy: Int,
        shortlistSize: Int,
        parameterBounds: V2ParameterBounds,
        safetyThresholds: V4SafetyThresholds
    ) throws -> String {
        struct Payload: Codable {
            let experimentSearchDefinitionHashV3: String
            let policy: SDRInputInterpretationPolicy
            let preparation: V6PreparationConfiguration
            let metric: V2MetricSemanticConfiguration
            let searchAlgorithmDefinition: SDRSearchAlgorithmDefinitionV3
            let searchSeed: UInt64
            let splitSeed: UInt64
            let globalCandidates: Int
            let localCandidates: Int
            let totalCandidatesPerPolicy: Int
            let shortlistSize: Int
            let parameterBounds: V2ParameterBounds
            let safetyThresholds: V4SafetyThresholds
        }
        return try HDRCanonicalIdentity.sha256(Payload(
            experimentSearchDefinitionHashV3: experimentSearchDefinitionHashV3,
            policy: policy,
            preparation: preparation,
            metric: metric,
            searchAlgorithmDefinition: searchAlgorithmDefinition,
            searchSeed: searchSeed,
            splitSeed: splitSeed,
            globalCandidates: globalCandidates,
            localCandidates: localCandidates,
            totalCandidatesPerPolicy: totalCandidatesPerPolicy,
            shortlistSize: shortlistSize,
            parameterBounds: parameterBounds,
            safetyThresholds: safetyThresholds
        ))
    }
}

public enum PreregisteredCalibrationExecutionError: Error, LocalizedError, Equatable, Sendable {
    case policyNotPreregistered
    case preregistrationMismatch
    case mediaExecutionDisabledForVerification

    public var errorDescription: String? {
        switch self {
        case .policyNotPreregistered:
            return "PREREGISTRATION_MISMATCH: policy is not in the sealed candidate list"
        case .preregistrationMismatch:
            return "PREREGISTRATION_MISMATCH: runtime semantics differ from the sealed experiment"
        case .mediaExecutionDisabledForVerification:
            return "media execution is disabled for this verify-only task"
        }
    }
}

public struct SDRCalibrationSemanticSealV3: Codable, Hashable, Sendable {
    public let policyDefinition: SDRPolicyDefinition
    public let preparationDefinition: SDRPreparationDefinitionV3
    public let metricDefinition: SDRMetricDefinitionV3
    public let searchDefinition: SDRCalibrationSearchDefinitionV3
    public let policyDefinitionHashV3: String
    public let preparationDefinitionHashV3: String
    public let metricDefinitionHashV3: String
    public let searchAlgorithmDefinitionHash: String
    public let searchDefinitionHashV3: String

    public init(
        policyDefinition: SDRPolicyDefinition,
        preparationDefinition: SDRPreparationDefinitionV3,
        metricDefinition: SDRMetricDefinitionV3,
        searchDefinition: SDRCalibrationSearchDefinitionV3
    ) throws {
        try preparationDefinition.validate()
        try metricDefinition.validate()
        let policyHash = try policyDefinition.sha256()
        let preparationHash = try preparationDefinition.sha256()
        let metricHash = try metricDefinition.sha256()
        let algorithmHash = try searchDefinition.searchAlgorithmDefinition.sha256()
        try searchDefinition.validate()
        guard searchDefinition.policyDefinitionHashV3 == policyHash,
              searchDefinition.preparationDefinitionHashV3 == preparationHash,
              searchDefinition.metricDefinitionHashV3 == metricHash,
              searchDefinition.searchAlgorithmDefinitionHash == algorithmHash else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        self.policyDefinition = policyDefinition
        self.preparationDefinition = preparationDefinition
        self.metricDefinition = metricDefinition
        self.searchDefinition = searchDefinition
        self.policyDefinitionHashV3 = policyHash
        self.preparationDefinitionHashV3 = preparationHash
        self.metricDefinitionHashV3 = metricHash
        self.searchAlgorithmDefinitionHash = algorithmHash
        self.searchDefinitionHashV3 = try searchDefinition.sha256()
    }

    public static func current() throws -> SDRCalibrationSemanticSealV3 {
        let policy = SDRPolicyDefinition.currentV3
        let preparation = try SDRPreparationDefinitionV3.current()
        let metric = try SDRMetricDefinitionV3.current()
        let algorithm = SDRSearchAlgorithmDefinitionV3.current
        let policyHash = try policy.sha256()
        let preparationHash = try preparation.sha256()
        let metricHash = try metric.sha256()
        return try SDRCalibrationSemanticSealV3(
            policyDefinition: policy,
            preparationDefinition: preparation,
            metricDefinition: metric,
            searchDefinition: SDRCalibrationSearchDefinitionV3(
                policyDefinitionHashV3: policyHash,
                preparationDefinitionHashV3: preparationHash,
                metricDefinitionHashV3: metricHash,
                searchAlgorithmDefinition: algorithm
            )
        )
    }
}

/// The only preregistered calibration runner entry point. It verifies the
/// complete execution binding before delegating to the existing V4 engine.
/// CLI verification uses `verifyOnly`; tests never provide a media manifest.
public final class PreregisteredCalibrationRunner {
    public let experiment: PreregisteredCalibrationExperiment

    public init(experiment: PreregisteredCalibrationExperiment) throws {
        try experiment.validate()
        self.experiment = experiment
    }

    public func verifyOnly() throws -> [PreregisteredCalibrationRuntimeConfiguration] {
        let runtimes = try experiment.searchDefinition.policyCandidates.map {
            try experiment.deriveRuntimeConfiguration(for: $0)
        }
        for runtime in runtimes {
            try experiment.verifyRuntimeConfiguration(runtime)
        }
        guard runtimes.count == 2,
              Set(runtimes.map(\.policy)).count == 2,
              Set(runtimes.map(\.totalCandidatesPerPolicy)) == [192],
              Set(runtimes.map(\.shortlistSize)) == [3] else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        return runtimes
    }

    /// Full media execution is intentionally not called by this task. When
    /// authorized in a later phase, this method still derives every V4
    /// runtime setting from the sealed object before the first candidate.
    public func run(
        manifestURL: URL,
        outputDirectory: URL,
        preparedEvaluationPlanURLs: [SDRInputInterpretationPolicy: URL],
        preparedFrozenPlanURLs: [SDRInputInterpretationPolicy: URL]? = nil,
        device: MTLDevice? = MTLCreateSystemDefaultDevice()
    ) async throws -> [V4FinalReport] {
        let runtimes = try verifyOnly()
        guard Set(preparedEvaluationPlanURLs.keys) == Set(runtimes.map(\.policy)),
              preparedFrozenPlanURLs == nil ||
                Set(preparedFrozenPlanURLs!.keys) == Set(runtimes.map(\.policy)) else {
            throw PreregisteredCalibrationExecutionError.preregistrationMismatch
        }
        // Keep the policy outer loop explicit and sequential.  MTLDevice is a
        // framework reference that is not Sendable on every supported macOS
        // SDK, and the experiment seal does not require policy concurrency.
        var reports: [V4FinalReport] = []
        for runtime in runtimes {
            guard let preparedEvaluationPlanURL = preparedEvaluationPlanURLs[runtime.policy] else {
                throw PreregisteredCalibrationExecutionError.preregistrationMismatch
            }
            let configuration = try V4CalibrationConfiguration(
                preregisteredRuntime: runtime
            )
            let policyOutput = outputDirectory.appendingPathComponent(runtime.policy.rawValue)
            let runner = try CalibrationV4Runner(
                manifestURL: manifestURL,
                outputDirectory: policyOutput,
                configuration: configuration,
                preparedEvaluationPlanURL: preparedEvaluationPlanURL,
                preparedFrozenPlanURL: preparedFrozenPlanURLs?[runtime.policy],
                preparationConfiguration: runtime.preparation,
                metricConfiguration: runtime.metric,
                device: device
            )
            reports.append(try await runner.run())
        }
        return reports.sorted { $0.configuration.sdrInterpretationPolicy.rawValue < $1.configuration.sdrInterpretationPolicy.rawValue }
    }
}
