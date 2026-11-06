import XCTest
@testable import HDRCalibration

final class V4FamilyDecisionTests: XCTestCase {
    private let decision = V4DecisionProtocol.familyMaximinLOFOV1
    private let v2: [String: Double] = ["A": 1.0, "B": 1.0, "C": 1.0]
    private let defaults: [String: Double] = ["A": 1.0, "B": 1.0, "C": 1.0]

    private func candidate(_ id: String, _ a: Double, _ b: Double, _ c: Double, safe: Bool = true) -> V4FamilyScores {
        V4FamilyScores(id: id, objectiveByFamily: ["A": a, "B": b, "C": c], safe: safe)
    }

    func testSelectsBestWorstFamilyNotBestMean() throws {
        // "spiky" has the best mean but hurts C; "even" improves every family.
        let pool = [candidate("spiky", 0.70, 0.70, 1.01), candidate("even", 0.92, 0.92, 0.92)]
        let selection = try XCTUnwrap(V4FamilyDecision.select(candidates: pool, v2: v2, defaults: defaults, protocol: decision))
        XCTAssertEqual(selection.candidateID, "even")
        XCTAssertEqual(selection.worstRatio, 0.92, accuracy: 1e-12)
    }

    func testRejectsFamilyRegressionAgainstDefaultEvenWhenV2IsBeaten() {
        // Beats V2 everywhere, but the default is much better on C (as on StEM3).
        let defaults = ["A": 1.0, "B": 1.0, "C": 0.80]
        let pool = [candidate("x", 0.9, 0.9, 0.9)]
        XCTAssertNil(V4FamilyDecision.select(candidates: pool, v2: v2, defaults: defaults, protocol: decision))
    }

    func testUnsafeOrIncompleteCandidatesAreIneligible() {
        let unsafe = candidate("unsafe", 0.5, 0.5, 0.5, safe: false)
        let missing = V4FamilyScores(id: "missing", objectiveByFamily: ["A": 0.5, "B": 0.5], safe: true)
        let nonFinite = candidate("nan", 0.5, .nan, 0.5)
        XCTAssertNil(V4FamilyDecision.select(candidates: [unsafe, missing, nonFinite], v2: v2, defaults: defaults, protocol: decision))
    }

    func testLeaveOneFamilyOutDetectsOverfitToTrainingFamilies() {
        // Each specialist wins on two families and loses on the third; LOFO picks
        // the specialist for the held-out family's complement and exposes the loss.
        let pool = [
            candidate("ab", 0.80, 0.80, 1.015),
            candidate("bc", 1.015, 0.80, 0.80),
            candidate("ac", 0.80, 1.015, 0.80)
        ]
        let report = V4FamilyDecision.leaveOneFamilyOut(candidates: pool, v2: v2, defaults: defaults, protocol: decision)
        XCTAssertEqual(report.folds.map(\.heldOutFamily), ["A", "B", "C"])
        XCTAssertEqual(report.folds.map(\.selectedCandidateID), ["bc", "ac", "ab"])
        XCTAssertEqual(report.worstHeldOutImprovement ?? 0, -0.015, accuracy: 1e-12)
        XCTAssertEqual(report.status, .fail)
    }

    func testLeaveOneFamilyOutPassesForBroadImprovement() {
        let pool = [candidate("broad", 0.90, 0.92, 0.91), candidate("worse", 0.97, 0.97, 0.97)]
        let report = V4FamilyDecision.leaveOneFamilyOut(candidates: pool, v2: v2, defaults: defaults, protocol: decision)
        XCTAssertEqual(report.status, .pass)
        XCTAssertEqual(report.meanHeldOutImprovement ?? 0, (0.10 + 0.08 + 0.09) / 3, accuracy: 1e-12)
    }

    func testLeaveOneFamilyOutFailsBelowMeanGate() {
        // Positive everywhere but only ~3%: the honest estimate predicts a Frozen fail.
        let pool = [candidate("small", 0.97, 0.97, 0.97)]
        let report = V4FamilyDecision.leaveOneFamilyOut(candidates: pool, v2: v2, defaults: defaults, protocol: decision)
        XCTAssertEqual(report.status, .fail)
        XCTAssertTrue(report.reasons.contains { $0.contains("mean held-out improvement") })
    }

    func testLeaveOneFamilyOutFailsWithoutEligibleCandidate() {
        let report = V4FamilyDecision.leaveOneFamilyOut(
            candidates: [candidate("u", 0.5, 0.5, 0.5, safe: false)], v2: v2, defaults: defaults, protocol: decision
        )
        XCTAssertEqual(report.status, .fail)
        XCTAssertTrue(report.folds.allSatisfy { $0.selectedCandidateID == nil })
    }

    func testFrozenFamilyGateNeedsMatchingFamiliesAndTolerance() {
        let ok = ["N": 0.95, "S": 1.01]
        XCTAssertTrue(V4FamilyDecision.frozenFamiliesWithinTolerance(
            candidate: ok, v2: ["N": 1, "S": 1], defaults: ["N": 1, "S": 1], protocol: decision
        ))
        XCTAssertFalse(V4FamilyDecision.frozenFamiliesWithinTolerance(
            candidate: ["N": 0.95, "S": 1.03], v2: ["N": 1, "S": 1], defaults: ["N": 1, "S": 1], protocol: decision
        ))
        XCTAssertFalse(V4FamilyDecision.frozenFamiliesWithinTolerance(
            candidate: ["N": 0.95], v2: ["N": 1, "S": 1], defaults: ["N": 1, "S": 1], protocol: decision
        ))
    }

    func testManifestSelectsProtocolAndRejectsUnknown() throws {
        var manifest = V4Manifest(pairs: [], coverageProtocol: "open-content-coverage-v1", decisionProtocol: "family-maximin-lofo-v1")
        XCTAssertEqual(try V4CalibrationConfiguration(manifest: manifest).decisionProtocol, .familyMaximinLOFOV1)
        manifest.decisionProtocol = nil
        XCTAssertNil(try V4CalibrationConfiguration(manifest: manifest).decisionProtocol)
        manifest.decisionProtocol = "best-on-frozen"
        XCTAssertThrowsError(try V4CalibrationConfiguration(manifest: manifest))
    }

    func testLegacyConfigurationEncodingIsUnchanged() throws {
        // The objective hash of historical runs must not move.
        let data = try JSONEncoder().encode(V4CalibrationConfiguration())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("decisionProtocol"))
    }

    func testPreFrozenGateBlocksOnLeaveOneFamilyOutOnlyWhenPresent() throws {
        var gates = V4PreFrozenGateResult(
            datasetIntegrity: .pass, identifiability: .pass, validationOverall: .pass,
            validationShadow: .pass, validationTemporal: .pass, transferCoverage: .pass,
            pairCoverage: .pass, familyCoverage: .pass, runtime: .pass
        )
        XCTAssertTrue(gates.canOpenVirginFrozen)
        gates.leaveOneFamilyOut = .fail
        XCTAssertFalse(gates.canOpenVirginFrozen)
        XCTAssertTrue(gates.failures.contains("leaveOneFamilyOut=FAIL"))
        let decoded = try JSONDecoder().decode(V4PreFrozenGateResult.self, from: JSONEncoder().encode(gates))
        XCTAssertEqual(decoded.leaveOneFamilyOut, .fail)
    }
}
