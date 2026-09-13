import Foundation
import HDRCore

/// The semantic policy contract is intentionally separate from the search
/// contract.  The corpus is not part of either identity; it receives its own
/// CorpusDefinitionHash only after media qualification.
public struct SDRPreparationDefinition: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-preparation-definition-v2"

    public var preparationVersion: String
    public var sceneFrameSelectionSemantics: String
    public var alignmentSemantics: String
    public var sourceGridLuminanceSemantics: String
    public var metadataInterpretationSemantics: String
    public var failurePolicy: [String]

    public init(
        preparationVersion: String,
        sceneFrameSelectionSemantics: String,
        alignmentSemantics: String,
        sourceGridLuminanceSemantics: String,
        metadataInterpretationSemantics: String,
        failurePolicy: [String]
    ) {
        self.preparationVersion = preparationVersion
        self.sceneFrameSelectionSemantics = sceneFrameSelectionSemantics
        self.alignmentSemantics = alignmentSemantics
        self.sourceGridLuminanceSemantics = sourceGridLuminanceSemantics
        self.metadataInterpretationSemantics = metadataInterpretationSemantics
        self.failurePolicy = failurePolicy
    }

    public static let current = SDRPreparationDefinition(
        preparationVersion: V6PreparationConfiguration.currentVersion,
        sceneFrameSelectionSemantics:
            "SceneDetector.v6; sequencePosition-domain; accepted representatives are sealed in V6ScenePlan",
        alignmentSemantics:
            "V6MatcherConfiguration.v6; bounded offset search; raw and accepted identities are sealed",
        sourceGridLuminanceSemantics:
            "OfflinePixelSampler.linearLumaGrid; source-grid luminance is computed before objective access",
        metadataInterpretationSemantics:
            "SDRInputInterpretationResolver.resolve; source transfer metadata and untagged fallback are explicit",
        failurePolicy: [
            "decode, alignment, scene, temporal, path, or hash failure rejects the plan",
            "no implicit frame selection or policy fallback at evaluator entry",
            "non-finite preparation values reject before plan sealing"
        ]
    )

    public func sha256() throws -> String {
        try HDRCanonicalIdentity.sha256(self)
    }
}

/// Exact objective semantics used by the calibration search.  This identity
/// deliberately names direction and signed/unsigned treatment so a diagnostic
/// revision cannot silently reuse a previous metric identity.
public struct SDRMetricDefinition: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-metric-definition-v2"

    public var metricVersion: String
    public var objectiveNames: [String]
    public var objectiveWeights: [String: Double]
    public var direction: String
    public var normalization: [String]
    public var aggregation: [String]
    public var signedSemantics: [String]
    public var regionalMetrics: [String]
    public var temporalMetrics: [String]
    public var failureHandling: [String]

    public init(
        metricVersion: String,
        objectiveNames: [String],
        objectiveWeights: [String: Double] = [:],
        direction: String,
        normalization: [String],
        aggregation: [String],
        signedSemantics: [String],
        regionalMetrics: [String],
        temporalMetrics: [String],
        failureHandling: [String]
    ) {
        self.metricVersion = metricVersion
        self.objectiveNames = objectiveNames
        self.objectiveWeights = objectiveWeights
        self.direction = direction
        self.normalization = normalization
        self.aggregation = aggregation
        self.signedSemantics = signedSemantics
        self.regionalMetrics = regionalMetrics
        self.temporalMetrics = temporalMetrics
        self.failureHandling = failureHandling
    }

    public static let current = SDRMetricDefinition(
        metricVersion: "v2-objective-with-v61-directional-diagnostics",
        objectiveNames: [
            "luminance",
            "absoluteNits",
            "midtone",
            "diffuseWhite",
            "highlight",
            "shadow",
            "chroma",
            "saturation",
            "hue",
            "temporal",
            "structure",
            "clippingPenalty",
            "blackCrushPenalty",
            "saturationPenalty",
            "invalidPenalty"
        ],
        objectiveWeights: [
            "luminance": 0.16,
            "absoluteNits": 0.03,
            "midtone": 0.08,
            "diffuseWhite": 0.12,
            "highlight": 0.18,
            "shadow": 0.10,
            "chroma": 0.07,
            "saturation": 0.04,
            "hue": 0.08,
            "temporal": 0.08,
            "structure": 0.06,
            "clippingPenalty": 0.30,
            "blackCrushPenalty": 0.20,
            "saturationPenalty": 0.10,
            "invalidPenalty": 10.0
        ],
        direction: "minimize",
        normalization: [
            "mean absolute log luminance error",
            "absolute error normalized by 1000 nits",
            "regional values are normalized by region population"
        ],
        aggregation: [
            "weighted sum using V2ObjectiveWeights",
            "video aggregates are the mean of scene metrics",
            "temporal aggregates are kept separate from spatial objective"
        ],
        signedSemantics: [
            "signed error = generated - reference",
            "positive overshoot and negative undershoot remain separate diagnostics",
            "primary objective uses declared absolute/log terms, not signed cancellation"
        ],
        regionalMetrics: [
            "shadow 0.00...0.10",
            "midtone 0.10...0.90",
            "diffuseWhite 0.75...0.95",
            "highlight 0.90...1.00"
        ],
        temporalMetrics: [
            "temporal flicker",
            "temporal stability",
            "contiguous prepared windows only"
        ],
        failureHandling: [
            "non-finite output, GPU error, invalid paired sample, or missing window rejects the evaluation",
            "failure after metric exposure invalidates the selection cycle",
            "no failure is converted into a numeric score"
        ]
    )

    public func sha256() throws -> String {
        try HDRCanonicalIdentity.sha256(self)
    }
}

public struct SDRSearchParameterBound: Codable, Hashable, Sendable {
    public var lower: Double
    public var upper: Double

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }
}

/// V2 search identity.  It binds the three upstream semantic identities and
/// every search decision, while intentionally excluding the not-yet-qualified
/// Tune/Validation corpus.
public struct SDRCalibrationSearchDefinitionV2: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-search-definition-v2"

    public var semanticVersion: String
    public var policyDefinitionHash: String
    public var preparationDefinitionHash: String
    public var metricDefinitionHash: String
    public var policyCandidates: [String]
    public var searchBudgetPerPolicy: Int
    public var seed: UInt64
    public var parameterBounds: [String: SDRSearchParameterBound]
    public var parameterRepresentation: String
    public var hardGates: [String]
    public var safetyGates: [String]
    public var shortlistSize: Int
    public var selectionOrdering: [String]
    public var tieBreakRule: [String]
    public var failurePolicy: [String]

    public init(
        policyDefinitionHash: String,
        preparationDefinitionHash: String,
        metricDefinitionHash: String,
        policyCandidates: [String],
        searchBudgetPerPolicy: Int,
        seed: UInt64,
        parameterBounds: [String: SDRSearchParameterBound],
        parameterRepresentation: String,
        hardGates: [String],
        safetyGates: [String],
        shortlistSize: Int,
        selectionOrdering: [String],
        tieBreakRule: [String],
        failurePolicy: [String],
        semanticVersion: String = SDRCalibrationSearchDefinitionV2.semanticVersion
    ) {
        self.semanticVersion = semanticVersion
        self.policyDefinitionHash = policyDefinitionHash
        self.preparationDefinitionHash = preparationDefinitionHash
        self.metricDefinitionHash = metricDefinitionHash
        self.policyCandidates = policyCandidates
        self.searchBudgetPerPolicy = searchBudgetPerPolicy
        self.seed = seed
        self.parameterBounds = parameterBounds
        self.parameterRepresentation = parameterRepresentation
        self.hardGates = hardGates
        self.safetyGates = safetyGates
        self.shortlistSize = shortlistSize
        self.selectionOrdering = selectionOrdering
        self.tieBreakRule = tieBreakRule
        self.failurePolicy = failurePolicy
    }

    public static func current(
        policyDefinitionHash: String,
        preparationDefinitionHash: String,
        metricDefinitionHash: String
    ) -> SDRCalibrationSearchDefinitionV2 {
        SDRCalibrationSearchDefinitionV2(
            policyDefinitionHash: policyDefinitionHash,
            preparationDefinitionHash: preparationDefinitionHash,
            metricDefinitionHash: metricDefinitionHash,
            policyCandidates: [
                SDRInputInterpretationPolicy.bt709SourceLinear.rawValue,
                SDRInputInterpretationPolicy.bt1886ReferenceDisplay.rawValue
            ],
            searchBudgetPerPolicy: 192,
            seed: 2_026_09_12,
            parameterBounds: [
                "paperWhiteNits": SDRSearchParameterBound(lower: 190, upper: 245),
                "peakNits": SDRSearchParameterBound(lower: 900, upper: 1_500),
                "highlightStrength": SDRSearchParameterBound(lower: 0.42, upper: 0.86),
                "contrastStrength": SDRSearchParameterBound(lower: 0.50, upper: 0.95),
                "saturationCompensation": SDRSearchParameterBound(lower: 0.10, upper: 0.50),
                "shadowProtection": SDRSearchParameterBound(lower: 0.05, upper: 1.0),
                "temporalStability": SDRSearchParameterBound(lower: 0.20, upper: 0.98)
            ],
            parameterRepresentation:
                "finite IEEE-754 values; canonical decimal JSON; lexicographic parameter-name order",
            hardGates: [
                "finite outputs and no GPU error",
                "transfer, range, and metadata resolution match the selected policy",
                "transform monotonicity and exact black/white anchors",
                "temporal sequence and precision checks pass"
            ],
            safetyGates: [
                "no unexpected fallback",
                "no range mismatch",
                "no clipping or near-black safety violation",
                "no invalid paired sample"
            ],
            shortlistSize: 3,
            selectionOrdering: [
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
    }

    public func sha256() throws -> String {
        try HDRCanonicalIdentity.sha256(self)
    }
}

/// The complete pre-corpus semantic seal.  This is what the final
/// preregistration artifact records.  `CorpusDefinitionHash` and
/// `ExperimentBindingHash` are intentionally absent until corpus qualification.
public struct SDRCalibrationSemanticSealV2: Codable, Hashable, Sendable {
    public let policyDefinition: SDRPolicyDefinition
    public let preparationDefinition: SDRPreparationDefinition
    public let metricDefinition: SDRMetricDefinition
    public let searchDefinition: SDRCalibrationSearchDefinitionV2
    public let policyDefinitionHash: String
    public let preparationDefinitionHash: String
    public let metricDefinitionHash: String
    public let searchDefinitionHashV2: String

    public init(
        policyDefinition: SDRPolicyDefinition,
        preparationDefinition: SDRPreparationDefinition,
        metricDefinition: SDRMetricDefinition,
        searchDefinition: SDRCalibrationSearchDefinitionV2
    ) throws {
        let policyHash = try policyDefinition.sha256()
        let preparationHash = try preparationDefinition.sha256()
        let metricHash = try metricDefinition.sha256()
        guard searchDefinition.policyDefinitionHash == policyHash,
              searchDefinition.preparationDefinitionHash == preparationHash,
              searchDefinition.metricDefinitionHash == metricHash else {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        self.policyDefinition = policyDefinition
        self.preparationDefinition = preparationDefinition
        self.metricDefinition = metricDefinition
        self.searchDefinition = searchDefinition
        self.policyDefinitionHash = policyHash
        self.preparationDefinitionHash = preparationHash
        self.metricDefinitionHash = metricHash
        self.searchDefinitionHashV2 = try searchDefinition.sha256()
    }

    public static func current() throws -> SDRCalibrationSemanticSealV2 {
        let policy = SDRPolicyDefinition.current
        let preparation = SDRPreparationDefinition.current
        let metric = SDRMetricDefinition.current
        return try SDRCalibrationSemanticSealV2(
            policyDefinition: policy,
            preparationDefinition: preparation,
            metricDefinition: metric,
            searchDefinition: SDRCalibrationSearchDefinitionV2.current(
                policyDefinitionHash: try policy.sha256(),
                preparationDefinitionHash: try preparation.sha256(),
                metricDefinitionHash: try metric.sha256()
            )
        )
    }
}

/// Pre-corpus preregistration artifact. It is deliberately explicit that the
/// corpus and complete experiment binding do not exist yet.
public struct SDRCalibrationPreregistrationV2: Codable, Hashable, Sendable {
    public let artifactVersion: Int
    public let status: String
    public let preregistrationInvalidated: Bool
    public let correctnessBaseline: String
    public let policyDefinition: SDRPolicyDefinition
    public let preparationDefinition: SDRPreparationDefinition
    public let metricDefinition: SDRMetricDefinition
    public let searchDefinition: SDRCalibrationSearchDefinitionV2
    public let policyDefinitionHash: String
    public let preparationDefinitionHash: String
    public let metricDefinitionHash: String
    public let searchDefinitionHashV2: String
    public let oldSearchDefinitionHash: String
    public let oldHashEligibleForCalibration: Bool
    public let oldHashStatus: String
    public let corpusDefinitionHash: String
    public let experimentBindingHash: String
    public let mediaQualification: String
    public let tune: String
    public let validation: String
    public let objectiveEvaluations: Int

    public init(
        seal: SDRCalibrationSemanticSealV2,
        correctnessBaseline: String = SDRCalibrationRebaseProtocol.correctnessBaseline,
        oldSearchDefinitionHash: String = SDRCalibrationRebaseProtocol.oldSearchDefinitionHash
    ) {
        self.artifactVersion = 2
        self.status = "PREREGISTERED_V2_SEMANTIC_ONLY"
        self.preregistrationInvalidated = false
        self.correctnessBaseline = correctnessBaseline
        self.policyDefinition = seal.policyDefinition
        self.preparationDefinition = seal.preparationDefinition
        self.metricDefinition = seal.metricDefinition
        self.searchDefinition = seal.searchDefinition
        self.policyDefinitionHash = seal.policyDefinitionHash
        self.preparationDefinitionHash = seal.preparationDefinitionHash
        self.metricDefinitionHash = seal.metricDefinitionHash
        self.searchDefinitionHashV2 = seal.searchDefinitionHashV2
        self.oldSearchDefinitionHash = oldSearchDefinitionHash
        self.oldHashEligibleForCalibration = false
        self.oldHashStatus = "RETIRED_INVALIDATED"
        self.corpusDefinitionHash = "NOT_YET_CREATED"
        self.experimentBindingHash = "NOT_YET_CREATED"
        self.mediaQualification = "NOT_RUN"
        self.tune = "NOT_RUN"
        self.validation = "NOT_RUN"
        self.objectiveEvaluations = 0
    }
}
