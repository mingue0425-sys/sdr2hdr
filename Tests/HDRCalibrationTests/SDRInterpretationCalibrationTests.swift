import Foundation
import HDRCore
@testable import HDRCalibration
import XCTest

final class SDRInterpretationCalibrationTests: XCTestCase {
    func testSearchDefinitionIsPreregisteredForEqualBT709AndBT1886Budgets() throws {
        let definition = SDRCalibrationSearchDefinition.preregistered
        XCTAssertEqual(
            definition.policyCandidates,
            [.bt709SourceLinear, .bt1886ReferenceDisplay]
        )
        XCTAssertEqual(definition.searchBudgetPerPolicy, 192)
        XCTAssertEqual(definition.shortlistSize, 3)
        XCTAssertEqual(
            definition.tieBreakRule.first,
            "lower objective"
        )
        XCTAssertFalse(try definition.sha256().isEmpty)
    }

    func testPolicyIdentityParticipatesInPreparationAndPlanHashes() throws {
        let sourceLinear = V6PreparationConfiguration(
            sdrInterpretationPolicy: .bt709SourceLinear
        )
        let referenceDisplay = V6PreparationConfiguration(
            sdrInterpretationPolicy: .bt1886ReferenceDisplay
        )
        XCTAssertNotEqual(
            sourceLinear.sdrInterpretationPolicyHash,
            referenceDisplay.sdrInterpretationPolicyHash
        )

        let planA = PreparedEvaluationPlan(
            scope: "TUNE_VALIDATION",
            pairOrder: [],
            preparation: sourceLinear,
            pairs: []
        )
        let planB = PreparedEvaluationPlan(
            scope: "TUNE_VALIDATION",
            pairOrder: [],
            preparation: referenceDisplay,
            pairs: []
        )
        XCTAssertNotEqual(
            try V6PreparedEvaluationPlanHasher.sha256(planA),
            try V6PreparedEvaluationPlanHasher.sha256(planB)
        )
    }

    func testCalibrationParametersRoundTripTheNewPolicyIdentity() throws {
        var configuration = HDRConfiguration.calibratedV4
        configuration.sdrInterpretationPolicy = .bt1886ReferenceDisplay
        configuration.bt1886Parameters = BT1886TransferParameters(
            blackLuminance: 0.01,
            whiteLuminance: 1,
            gamma: 2.4
        )
        let parameters = CalibrationParameters(configuration: configuration)
        XCTAssertEqual(parameters.sdrInterpretationPolicy, .bt1886ReferenceDisplay)
        XCTAssertEqual(parameters.bt1886Parameters, configuration.bt1886Parameters)
        XCTAssertEqual(try parameters.configuration(), configuration)
    }

    func testMissingDataArtifactsRemainObjectiveFreeAndDoNotSelectCandidate() {
        let tune = SDRCalibrationRebaseProtocol.blockedTuneArtifact()
        let validation = SDRCalibrationRebaseProtocol.blockedValidationArtifact()
        let candidate = SDRCalibrationRebaseProtocol.blockedCandidateArtifact()
        let lineage = SDRCalibrationRebaseProtocol.blockedLineageArtifact()

        XCTAssertEqual(tune.status, .blockedMissingData)
        XCTAssertEqual(validation.status, .blockedMissingData)
        XCTAssertEqual(candidate.status, .blockedMissingData)
        XCTAssertNil(candidate.selectedPolicy)
        XCTAssertNil(candidate.selectedCandidate)
        XCTAssertFalse(lineage.frozenAccessed)
        XCTAssertEqual(lineage.objectiveEvaluations, 0)
        XCTAssertFalse(lineage.oldCalibrationReusable)
        XCTAssertFalse(lineage.productionDefaultChanged)
        XCTAssertEqual(lineage.verdict, .blockedMissingData)
    }

    func testV2SemanticSealBindsEveryExperimentDefiningMutation() throws {
        let seal = try SDRCalibrationSemanticSealV2.current()
        let policyHash = try seal.policyDefinition.sha256()
        let preparationHash = try seal.preparationDefinition.sha256()
        let metricHash = try seal.metricDefinition.sha256()
        let searchHash = try seal.searchDefinition.sha256()

        XCTAssertEqual(policyHash, seal.policyDefinitionHash)
        XCTAssertEqual(preparationHash, seal.preparationDefinitionHash)
        XCTAssertEqual(metricHash, seal.metricDefinitionHash)
        XCTAssertEqual(searchHash, seal.searchDefinitionHashV2)
        XCTAssertNotEqual(seal.searchDefinitionHashV2, "7cdb4cebb6298245e5967f4b81add827831bd0942dc7477498b09e497cf92608")

        func changedPolicy(
            parameters: BT1886TransferParameters = seal.policyDefinition.bt1886Parameters,
            candidates: [String] = seal.policyDefinition.candidateList
        ) -> SDRPolicyDefinition {
            SDRPolicyDefinition(
                policyVersion: seal.policyDefinition.policyVersion,
                candidateList: candidates,
                bt1886Parameters: parameters,
                untaggedFallback: seal.policyDefinition.untaggedFallback,
                semanticVersion: seal.policyDefinition.semanticVersion,
                bt709SourceLinearSemanticVersion: seal.policyDefinition.bt709SourceLinearSemanticVersion,
                bt1886ReferenceDisplaySemanticVersion: seal.policyDefinition.bt1886ReferenceDisplaySemanticVersion,
                sRGBSemanticVersion: seal.policyDefinition.sRGBSemanticVersion,
                explicitGammaSemanticVersion: seal.policyDefinition.explicitGammaSemanticVersion,
                linearSemanticVersion: seal.policyDefinition.linearSemanticVersion,
                bt1886ParameterValidationDomain: seal.policyDefinition.bt1886ParameterValidationDomain,
                sRGBBehavior: seal.policyDefinition.sRGBBehavior,
                explicitGammaBehavior: seal.policyDefinition.explicitGammaBehavior,
                linearBehavior: seal.policyDefinition.linearBehavior,
                untaggedFallbackSemantics: seal.policyDefinition.untaggedFallbackSemantics
            )
        }

        XCTAssertNotEqual(
            try changedPolicy(parameters: BT1886TransferParameters(
                blackLuminance: 0.001, whiteLuminance: 1, gamma: 2.4
            )).sha256(),
            policyHash
        )
        XCTAssertNotEqual(
            try changedPolicy(parameters: BT1886TransferParameters(
                blackLuminance: 0, whiteLuminance: 2, gamma: 2.4
            )).sha256(),
            policyHash
        )
        XCTAssertNotEqual(
            try changedPolicy(parameters: BT1886TransferParameters(
                blackLuminance: 0, whiteLuminance: 1, gamma: 2.2
            )).sha256(),
            policyHash
        )
        XCTAssertNotEqual(
            try changedPolicy(candidates: seal.policyDefinition.candidateList + [SDRInputInterpretationPolicy.sRGB.rawValue]).sha256(),
            policyHash
        )

        var changedPreparation = seal.preparationDefinition
        changedPreparation.preparationVersion += "-mutated"
        XCTAssertNotEqual(try changedPreparation.sha256(), preparationHash)

        var changedMetric = seal.metricDefinition
        changedMetric.metricVersion += "-mutated"
        XCTAssertNotEqual(try changedMetric.sha256(), metricHash)
        changedMetric = seal.metricDefinition
        changedMetric.direction = "maximize"
        XCTAssertNotEqual(try changedMetric.sha256(), metricHash)

        func assertSearchMutation(
            _ mutate: (inout SDRCalibrationSearchDefinitionV2) -> Void
        ) throws {
            var changed = seal.searchDefinition
            mutate(&changed)
            XCTAssertNotEqual(try changed.sha256(), searchHash)
        }

        try assertSearchMutation { $0.searchBudgetPerPolicy += 1 }
        try assertSearchMutation { $0.seed += 1 }
        try assertSearchMutation {
            $0.parameterBounds["paperWhiteNits"]?.lower += 1
        }
        try assertSearchMutation {
            $0.parameterBounds["paperWhiteNits"]?.upper += 1
        }
        try assertSearchMutation { $0.hardGates.append("new gate") }
        try assertSearchMutation { $0.safetyGates.append("new safety gate") }
        try assertSearchMutation { $0.shortlistSize += 1 }
        try assertSearchMutation { $0.tieBreakRule.append("new tie break") }
        try assertSearchMutation { $0.failurePolicy.append("new failure") }
        try assertSearchMutation { $0.policyCandidates.append(SDRInputInterpretationPolicy.sRGB.rawValue) }

        XCTAssertEqual(
            try HDRCanonicalIdentity.data(["b": 2, "a": 1]),
            try HDRCanonicalIdentity.data(["a": 1, "b": 2])
        )
        XCTAssertEqual(
            try HDRCanonicalIdentity.data(["value": 0]),
            Data("{\"value\":0}".utf8)
        )
        XCTAssertEqual(
            try HDRCanonicalIdentity.data(["value": true]),
            Data("{\"value\":true}".utf8)
        )
        XCTAssertEqual(try HDRCanonicalIdentity.number(-0.0), "0")
    }

    func testSemanticIdentityFailsClosedForInvalidAndUnsupportedValues() throws {
        XCTAssertThrowsError(try HDRCanonicalIdentity.sha256(BT1886TransferParameters(
            blackLuminance: .nan, whiteLuminance: 1, gamma: 2.4
        )))
        XCTAssertThrowsError(try HDRCanonicalIdentity.sha256(BT1886TransferParameters(
            blackLuminance: 0, whiteLuminance: .infinity, gamma: 2.4
        )))

        var invalidBounds = try SDRCalibrationSemanticSealV2.current().searchDefinition
        invalidBounds.parameterBounds["paperWhiteNits"] = SDRSearchParameterBound(
            lower: .nan, upper: 245
        )
        XCTAssertThrowsError(try invalidBounds.sha256())

        struct FailingEncodable: Encodable {
            func encode(to encoder: Encoder) throws {
                throw NSError(domain: "semantic-test", code: 1)
            }
        }
        XCTAssertThrowsError(try HDRCanonicalIdentity.sha256(FailingEncodable()))
    }

    func testV3ExecutionIsDerivedFromOneSealAndRejectsRuntimeDivergence() throws {
        let experiment = try PreregisteredCalibrationExperiment.current()
        let runner = try PreregisteredCalibrationRunner(experiment: experiment)
        let runtimes = try runner.verifyOnly()

        XCTAssertEqual(runtimes.map(\.policy), [.bt709SourceLinear, .bt1886ReferenceDisplay])
        XCTAssertEqual(runtimes.map(\.globalCandidates), [128, 128])
        XCTAssertEqual(runtimes.map(\.localCandidates), [64, 64])
        XCTAssertEqual(runtimes.map(\.totalCandidatesPerPolicy), [192, 192])
        XCTAssertEqual(runtimes.map(\.shortlistSize), [3, 3])
        XCTAssertEqual(runtimes.map(\.searchSeed), [20_260_912, 20_260_912])
        XCTAssertEqual(
            runtimes.map { $0.preparation.sdrInterpretationPolicy },
            [.bt709SourceLinear, .bt1886ReferenceDisplay]
        )
        XCTAssertNotEqual(
            runtimes[0].preparation.sdrInterpretationPolicyHash,
            runtimes[1].preparation.sdrInterpretationPolicyHash
        )

        for original in runtimes {
            var changedSeed = original
            changedSeed.searchSeed += 1
            XCTAssertThrowsError(try experiment.verifyRuntimeConfiguration(changedSeed))

            var changedShortlist = original
            changedShortlist.shortlistSize = 8
            XCTAssertThrowsError(try experiment.verifyRuntimeConfiguration(changedShortlist))

            var changedRange = original
            changedRange.parameterBounds = V2ParameterBounds(
                paperWhiteNits: 180...245,
                peakNits: original.parameterBounds.peakNits,
                highlightStrength: original.parameterBounds.highlightStrength,
                contrastStrength: original.parameterBounds.contrastStrength,
                saturationCompensation: original.parameterBounds.saturationCompensation,
                shadowProtection: original.parameterBounds.shadowProtection,
                temporalStability: original.parameterBounds.temporalStability
            )
            XCTAssertThrowsError(try experiment.verifyRuntimeConfiguration(changedRange))

            var changedAlgorithm = original
            changedAlgorithm.searchAlgorithmDefinition.globalParentCount += 1
            XCTAssertThrowsError(try experiment.verifyRuntimeConfiguration(changedAlgorithm))
        }
    }

    func testV3PreparationSemanticMutationMatrixIncludesTypedV6AndMatcherInputs() throws {
        let definition = try SDRPreparationDefinitionV3.current()
        let baseHash = try definition.sha256()

        func mutated(_ key: String, _ value: Any) throws -> SDRPreparationDefinitionV3 {
            let data = try HDRCanonicalIdentity.data(definition.configuration)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
            )
            object[key] = value
            var changed = definition
            changed.configuration = try JSONDecoder().decode(
                V6PreparationConfiguration.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            return changed
        }

        let directMutations: [(String, Any)] = [
            ("version", "v6-mutated"),
            ("maxFramesPerScene", 9),
            ("maxDecodedFrames", 129),
            ("proxyWidth", 336),
            ("alignmentConfidenceThreshold", 0.01),
            ("acceptedConfidenceThreshold", 0.61),
            ("temporalFramesPerSecond", 24.0),
            ("temporalTargetFrameCount", 15),
            ("temporalMinimumFrameCount", 7),
            ("temporalWarmupFrameCount", 2),
            ("referenceTargetPeakNits", 900.0),
            ("allowHLGModel", false),
            ("sdrPixelFormat", UInt32(875704422)),
            ("hdrPixelFormat", UInt32(1752589105)),
            ("frameDecoderPolicy", "decoder-mutated"),
            ("referenceDecoderPolicy", "reference-mutated"),
            ("pathResolutionPolicy", "path-mutated"),
            ("sceneSelectionPolicy", "scene-mutated"),
            ("temporalSelectionPolicy", "temporal-mutated"),
            ("preparationAlgorithmVersion", "algorithm-mutated"),
            ("matcherVersion", "matcher-version-mutated"),
            ("matcherConfigurationHash", "hash-mutated"),
            ("sdrInterpretationPolicyVersion", "policy-version-mutated"),
            ("sdrInterpretationPolicy", "bt1886ReferenceDisplay"),
            ("untaggedSDRFallback", "reject"),
            ("bt1886Parameters", ["blackLuminance": 0.01, "whiteLuminance": 1.0, "gamma": 2.4]),
            ("sdrInterpretationPolicyHash", "policy-hash-mutated")
        ]
        for (key, value) in directMutations {
            XCTAssertNotEqual(
                try mutated(key, value).sha256(),
                baseHash,
                "preparation mutation did not change identity: \(key)"
            )
        }

        let matcherData = try HDRCanonicalIdentity.data(definition.configuration.matcherConfiguration)
        let matcherObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: matcherData, options: [.fragmentsAllowed]) as? [String: Any]
        )
        let matcherMutations: [(String, Any)] = [
            ("preparationAlgorithmVersion", "v6-preparation-mutated"),
            ("matcherVersion", "matcher-mutated"),
            ("gridWidth", 32),
            ("gridHeight", 18),
            ("offsetMinimumSeconds", -1.0),
            ("offsetMaximumSeconds", 1.0),
            ("offsetStepSeconds", 1.0 / 24.0),
            ("acceptedConfidenceThreshold", 0.61),
            ("rankWeight", 0.31),
            ("signedGradientWeight", 0.24),
            ("multiScaleNCCWeight", 0.24),
            ("edgeMaskWeight", 0.11),
            ("localContrastWeight", 0.09),
            ("multiScaleWidths", [64, 32, 8])
        ]
        for (key, value) in matcherMutations {
            var changedMatcherObject = matcherObject
            changedMatcherObject[key] = value
            var changedConfigurationObject = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: HDRCanonicalIdentity.data(definition.configuration),
                    options: [.fragmentsAllowed]
                ) as? [String: Any]
            )
            changedConfigurationObject["matcherConfiguration"] = changedMatcherObject
            var changed = definition
            changed.configuration = try JSONDecoder().decode(
                V6PreparationConfiguration.self,
                from: JSONSerialization.data(withJSONObject: changedConfigurationObject)
            )
            XCTAssertNotEqual(
                try changed.sha256(),
                baseHash,
                "matcher mutation did not change preparation identity: \(key)"
            )
        }

        let preparationObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: HDRCanonicalIdentity.data(definition.configuration),
            options: [.fragmentsAllowed]
        ) as? [String: Any])
        XCTAssertEqual(V6PreparationConfiguration.canonicalFieldNames, Set(preparationObject.keys))
        let matcherDecodedObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: matcherData,
            options: [.fragmentsAllowed]
        ) as? [String: Any])
        XCTAssertEqual(V6MatcherConfiguration.canonicalFieldNames, Set(matcherDecodedObject.keys))
    }

    func testV3MetricSemanticMutationMatrixIncludesObjectiveConstantsAndFailureRules() throws {
        let definition = try SDRMetricDefinitionV3.current()
        let baseHash = try definition.sha256()

        func mutated(_ key: String, _ value: Any) throws -> SDRMetricDefinitionV3 {
            let data = try HDRCanonicalIdentity.data(definition.configuration)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
            )
            object[key] = value
            var changed = definition
            changed.configuration = try JSONDecoder().decode(
                V2MetricSemanticConfiguration.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            return changed
        }

        let scalarMutations: [(String, Any)] = [
            ("metricVersion", "metric-mutated"),
            ("objectiveDirection", "maximize"),
            ("absoluteNitsNormalizer", 999.0),
            ("additiveLuminanceOffsetNits", 2.0),
            ("highlightUnderreachRatio", 0.85),
            ("highlightOvershootRatio", 1.30),
            ("highlightOvershootAbsoluteNits", 21.0),
            ("specularPercentile", 0.995),
            ("clippingPeakRatio", 0.995),
            ("slopeFloorNits", 2.0),
            ("blackCrushReferenceThresholdNits", 2.0),
            ("blackCrushGeneratedAbsoluteNits", 0.6),
            ("blackCrushGeneratedRatio", 0.30),
            ("shadowLiftRatio", 1.6),
            ("shadowLiftAbsoluteNits", 3.0),
            ("nearBlackReferenceRangeFloorNits", 2.0),
            ("hueMeanWeight", 0.50),
            ("hueP95Weight", 0.50),
            ("temporalLuminanceWeight", 0.50),
            ("temporalHighlightWeight", 0.30),
            ("temporalFlickerWeight", 0.21),
            ("minimumReferenceChroma", 0.02),
            ("minimumGeneratedChroma", 0.006),
            ("highChromaThreshold", 0.09),
            ("saturationDenominatorFloor", 0.02),
            ("saturationOvershootRatio", 1.30),
            ("saturationOvershootAbsolute", 0.02),
            ("saturationUndershootRatio", 0.70),
            ("saturationUndershootAbsolute", 0.02),
            ("skinMinimumPeakNits", 2.0),
            ("skinRedBlueSeparation", 0.13),
            ("categoryHighKeyThresholdNits", 151.0),
            ("categoryLowKeyThresholdNits", 59.0),
            ("categoryHighSaturationChromaThreshold", 0.09),
            ("categoryHighSaturationRatio", 0.11),
            ("categoryHighlightRichUnderreachRatio", 0.21),
            ("failureHighlightUnderreachRatio", 0.21),
            ("failureHighlightOvershootRatio", 0.11),
            ("failureDiffuseWhiteLowRatio", 0.81),
            ("failureDiffuseWhiteHighRatio", 1.21),
            ("failureMidtoneError", 0.26),
            ("failureBlackCrushRatio", 0.06),
            ("failureShadowLiftRatio", 0.11),
            ("failureSaturationRatio", 0.16),
            ("failureHueP95Error", 0.11),
            ("failureTemporalFlicker", 0.09),
            ("failureAlignmentConfidence", 0.61),
            ("failureReferenceMismatchHue", 0.21),
            ("failureReferenceMismatchLuminance", 0.41),
            ("perceptualColorInputMinimumNits", 0.1),
            ("perceptualColorInputMaximumNits", 9_999.0),
            ("nonNegativeClampFloor", 0.001),
            ("correlationLowerBound", -0.9),
            ("correlationUpperBound", 0.9),
            ("correlationEpsilon", 2e-12),
            ("invalidMetricScore", 2.0),
            ("emptyAggregateObjective", 11.0),
            ("emptyAggregateInvalidSampleCount", 2)
        ]
        for (key, value) in scalarMutations {
            XCTAssertNotEqual(
                try mutated(key, value).sha256(),
                baseHash,
                "metric mutation did not change identity: \(key)"
            )
        }

        for key in [
            "objectiveNames", "normalizationRules", "aggregationRules", "signedSemantics",
            "regionalMetricNames", "temporalMetricNames", "failureHandling"
        ] {
            let data = try HDRCanonicalIdentity.data(definition.configuration)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
            )
            object[key] = ["mutated semantic rule"]
            var changed = definition
            changed.configuration = try JSONDecoder().decode(
                V2MetricSemanticConfiguration.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            XCTAssertNotEqual(try changed.sha256(), baseHash, "metric rule mutation: \(key)")
        }

        var weights = definition.configuration.objectiveWeights
        weights.luminance += 0.01
        var changedWeights = definition
        var changedConfiguration = definition.configuration
        changedConfiguration.objectiveWeights = weights
        changedWeights.configuration = changedConfiguration
        XCTAssertNotEqual(try changedWeights.sha256(), baseHash)

        let metricObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: HDRCanonicalIdentity.data(definition.configuration),
            options: [.fragmentsAllowed]
        ) as? [String: Any])
        XCTAssertEqual(V2MetricSemanticConfiguration.canonicalFieldNames, Set(metricObject.keys))
    }

    func testV3SearchAndPolicyMutationMatrixAndCanonicalNormalization() throws {
        let seal = try SDRCalibrationSemanticSealV3.current()
        let searchHash = seal.searchDefinitionHashV3
        let policyHash = seal.policyDefinitionHashV3

        func assertSearchMutation(_ mutate: (inout SDRCalibrationSearchDefinitionV3) -> Void) throws {
            var changed = seal.searchDefinition
            mutate(&changed)
            XCTAssertNotEqual(try changed.sha256(), searchHash)
        }

        try assertSearchMutation { $0.searchAlgorithmDefinition.globalCandidateCount += 1 }
        try assertSearchMutation { $0.searchAlgorithmDefinition.localCandidateCount += 1 }
        try assertSearchMutation { $0.searchAlgorithmDefinition.globalParentCount += 1 }
        try assertSearchMutation { $0.searchAlgorithmDefinition.phaseOrdering.append("post") }
        try assertSearchMutation { $0.searchAlgorithmDefinition.sensitivityProbeValues[1] = 0.24 }
        try assertSearchMutation { $0.searchAlgorithmDefinition.globalHaltonBases[0] = 3 }
        try assertSearchMutation { $0.searchAlgorithmDefinition.localHaltonBases[0] = 47 }
        try assertSearchMutation { $0.searchAlgorithmDefinition.localNeighborhoodRadius = 0.11 }
        try assertSearchMutation { $0.searchAlgorithmDefinition.seedIndexModulus += 1 }
        try assertSearchMutation { $0.searchAlgorithmDefinition.candidateOrdering += " mutated" }
        try assertSearchMutation { $0.searchBudgetPerPolicy += 1 }
        try assertSearchMutation { $0.seed += 1 }
        try assertSearchMutation { $0.splitSeed += 1 }
        try assertSearchMutation { $0.parameterRepresentation += " mutated" }
        try assertSearchMutation { $0.hardGates.append("mutated gate") }
        try assertSearchMutation { $0.safetyGates.append("mutated safety") }
        try assertSearchMutation { $0.safetyThresholds.shadowErrorTolerance += 0.001 }
        try assertSearchMutation { $0.safetyThresholds.runtime?.p95Fraction = 0.94 }
        try assertSearchMutation { $0.shortlistSize += 1 }
        try assertSearchMutation { $0.selectionOrdering.append("mutated ordering") }
        try assertSearchMutation { $0.tieBreakRule.append("mutated tie break") }
        try assertSearchMutation { $0.failurePolicy.append("mutated failure") }
        try assertSearchMutation { $0.policyCandidates.reverse() }

        let algorithmObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: HDRCanonicalIdentity.data(seal.searchDefinition.searchAlgorithmDefinition),
            options: [.fragmentsAllowed]
        ) as? [String: Any])
        XCTAssertEqual(SDRSearchAlgorithmDefinitionV3.canonicalFieldNames, Set(algorithmObject.keys))
        let searchObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: HDRCanonicalIdentity.data(seal.searchDefinition),
            options: [.fragmentsAllowed]
        ) as? [String: Any])
        XCTAssertEqual(SDRCalibrationSearchDefinitionV3.canonicalFieldNames, Set(searchObject.keys))

        var changedBounds = seal.searchDefinition
        changedBounds.parameterBounds = V2ParameterBounds(
            paperWhiteNits: 191...245,
            peakNits: changedBounds.parameterBounds.peakNits,
            highlightStrength: changedBounds.parameterBounds.highlightStrength,
            contrastStrength: changedBounds.parameterBounds.contrastStrength,
            saturationCompensation: changedBounds.parameterBounds.saturationCompensation,
            shadowProtection: changedBounds.parameterBounds.shadowProtection,
            temporalStability: changedBounds.parameterBounds.temporalStability
        )
        XCTAssertNotEqual(try changedBounds.sha256(), searchHash)

        let basePolicy = seal.policyDefinition
        let changedPolicy = SDRPolicyDefinition(
            policyVersion: basePolicy.policyVersion,
            candidateList: basePolicy.candidateList,
            bt1886Parameters: BT1886TransferParameters(
                blackLuminance: 0.01,
                whiteLuminance: basePolicy.bt1886Parameters.whiteLuminance,
                gamma: basePolicy.bt1886Parameters.gamma
            ),
            untaggedFallback: basePolicy.untaggedFallback,
            semanticVersion: basePolicy.semanticVersion,
            bt709SourceLinearSemanticVersion: basePolicy.bt709SourceLinearSemanticVersion,
            bt1886ReferenceDisplaySemanticVersion: basePolicy.bt1886ReferenceDisplaySemanticVersion,
            sRGBSemanticVersion: basePolicy.sRGBSemanticVersion,
            explicitGammaSemanticVersion: basePolicy.explicitGammaSemanticVersion,
            linearSemanticVersion: basePolicy.linearSemanticVersion,
            bt1886ParameterValidationDomain: basePolicy.bt1886ParameterValidationDomain,
            sRGBBehavior: basePolicy.sRGBBehavior,
            explicitGammaBehavior: basePolicy.explicitGammaBehavior,
            linearBehavior: basePolicy.linearBehavior,
            untaggedFallbackSemantics: basePolicy.untaggedFallbackSemantics
        )
        XCTAssertNotEqual(try changedPolicy.sha256(), policyHash)
        XCTAssertEqual(
            try HDRCanonicalIdentity.data(["b": 2, "a": 1]),
            try HDRCanonicalIdentity.data(["a": 1, "b": 2])
        )
        XCTAssertEqual(try HDRCanonicalIdentity.number(-0.0), "0")
        XCTAssertThrowsError(try HDRCanonicalIdentity.sha256(["bad": Double.nan]))
    }
}
