import Foundation
import HDRCore
@testable import HDRCalibration
import XCTest

final class SDRInterpretationCalibrationTests: XCTestCase {
    func testSearchDefinitionIsPreregisteredForEqualBT709AndBT1886Budgets() {
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
        XCTAssertFalse(definition.sha256().isEmpty)
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

    func testOldPreparationVersionAndSidecarCannotBeAcceptedAsCurrentPlan() throws {
        let oldConfiguration = V6PreparationConfiguration(
            version: "v6-prepared-evaluation-plan-v5-linear-source-luminance"
        )
        let oldPlan = PreparedEvaluationPlan(
            schemaVersion: "v6-prepared-evaluation-plan-v4",
            scope: "TUNE_VALIDATION",
            pairOrder: [],
            preparation: oldConfiguration,
            pairs: []
        )
        let artifact = try V6PreparedEvaluationPlanArtifact(plan: oldPlan)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("old-prepared-plan-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let sidecar = url.deletingPathExtension().appendingPathExtension("sha256")
        try JSONEncoder().encode(artifact).write(to: url)
        try Data(artifact.planSHA256.utf8).write(to: sidecar)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: sidecar)
        }

        XCTAssertThrowsError(try V6PreparedEvaluationPlanLoader.loadSealed(from: url))
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
}
