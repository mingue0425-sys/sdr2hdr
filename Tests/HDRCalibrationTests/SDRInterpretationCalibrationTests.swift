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
}
