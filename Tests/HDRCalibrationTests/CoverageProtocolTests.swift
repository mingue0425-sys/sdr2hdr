import Foundation
import XCTest
@testable import HDRCalibration
import HDRCore

/// Coverage requirements are preregistered per dataset through the manifest.
/// A manifest without `coverageProtocol` keeps the historical V5 policy; an
/// unknown identifier fails instead of silently relaxing requirements.
final class CoverageProtocolTests: XCTestCase {
    func testManifestWithoutProtocolKeepsHistoricalRequirements() throws {
        let manifest = try decode(#"{"version":4,"pairs":[],"roots":{}}"#)
        XCTAssertNil(manifest.coverageProtocol)
        let configuration = try V4CalibrationConfiguration(manifest: manifest)
        XCTAssertEqual(configuration.coverageProtocol, .preV6FrozenCoverageV1)
        XCTAssertEqual(configuration.requiredFrozenTransfers, ["HLG", "PQ"])
        XCTAssertEqual(configuration.requiredFamiliesBySplit[.tune], ["K-Choreo", "LIVE"])
        XCTAssertEqual(configuration.minimumVirginFrozenPairs, 3)
        XCTAssertEqual(configuration.minimumDistinctFrozenFamilies, 2)
        XCTAssertEqual(configuration.frozenCoveragePolicy.version, "pre-v6-frozen-coverage-v1")
        // The default initializer is unchanged.
        XCTAssertEqual(V4CalibrationConfiguration().requiredFrozenTransfers, ["HLG", "PQ"])
    }

    func testOpenContentProtocolRecordsItsRelaxationsExplicitly() throws {
        let manifest = try decode(#"{"version":4,"pairs":[],"roots":{},"coverageProtocol":"open-content-coverage-v1"}"#)
        let configuration = try V4CalibrationConfiguration(manifest: manifest)
        XCTAssertEqual(configuration.coverageProtocol, .openContentCoverageV1)
        XCTAssertEqual(configuration.requiredTransfersBySplit[.tune], ["HLG", "PQ"])
        XCTAssertEqual(configuration.requiredTransfersBySplit[.validation], ["HLG", "PQ"])
        XCTAssertEqual(configuration.requiredFrozenTransfers, ["PQ"])
        XCTAssertEqual(configuration.requiredFamiliesBySplit[.tune], ["Netflix Sol Levante", "K-Choreo"])
        XCTAssertEqual(configuration.requiredFamiliesBySplit[.validation], ["ASC StEM2", "K-Choreo"])
        // Holdout breadth is not relaxed.
        XCTAssertEqual(configuration.minimumVirginFrozenPairs, 3)
        XCTAssertEqual(configuration.minimumDistinctFrozenFamilies, 2)
        let policy = configuration.frozenCoveragePolicy
        XCTAssertEqual(policy.version, "open-content-coverage-v1")
        XCTAssertTrue(policy.rationale.contains { $0.contains("HLG") && $0.contains("not measured") })
    }

    func testUnknownProtocolFailsClosed() throws {
        let manifest = try decode(#"{"version":4,"pairs":[],"roots":{},"coverageProtocol":"anything-goes"}"#)
        XCTAssertThrowsError(try V4CalibrationConfiguration(manifest: manifest))
    }

    func testProtocolSurvivesManifestRoundTrip() throws {
        let manifest = try decode(#"{"version":4,"pairs":[],"roots":{},"coverageProtocol":"open-content-coverage-v1"}"#)
        let data = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(V4Manifest.self, from: data).coverageProtocol, "open-content-coverage-v1")
        let legacy = try JSONEncoder().encode(try decode(#"{"version":4,"pairs":[],"roots":{}}"#))
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("coverageProtocol"))
    }

    private func decode(_ json: String) throws -> V4Manifest {
        try JSONDecoder().decode(V4Manifest.self, from: Data(json.utf8))
    }
}

final class CalibrationParametersSDRPolicyTests: XCTestCase {
    private func base() -> CalibrationParameters {
        CalibrationParameters(
            paperWhiteNits: 203, peakNits: 1_000, highlightStrength: 0.5, contrastStrength: 0.5,
            saturationCompensation: 0.5, shadowProtection: 0.5, temporalStability: 0.9,
            displayHeadroom: 1_000 / 203, toneCurveRevision: 2
        )
    }

    func testDefaultParametersKeepHistoricalDecodeAndEncodeWithoutField() throws {
        let parameters = base()
        XCTAssertNil(parameters.sdrTransferInterpretation)
        XCTAssertEqual(try parameters.configuration().sdrTransferInterpretation, .bt709InverseOETFSceneLinear)
        let json = String(decoding: try JSONEncoder().encode(parameters), as: UTF8.self)
        XCTAssertFalse(json.contains("sdrTransferInterpretation"))
    }

    func testBT1886RoundTripsThroughParametersAndConfiguration() throws {
        var parameters = base()
        parameters.sdrTransferInterpretation = HDRSDRTransferInterpretation.bt1886DisplayReferred.rawValue
        let configuration = try parameters.configuration()
        XCTAssertEqual(configuration.sdrTransferInterpretation, .bt1886DisplayReferred)
        XCTAssertEqual(CalibrationParameters(configuration: configuration).sdrTransferInterpretation,
                       "bt1886-display-eotf-gamma2.4-lb0-v1")
        let decoded = try JSONDecoder().decode(
            CalibrationParameters.self, from: try JSONEncoder().encode(parameters)
        )
        XCTAssertEqual(decoded, parameters)
    }

    func testUnknownInterpretationFailsClosed() {
        var parameters = base()
        parameters.sdrTransferInterpretation = "gamma2.2"
        XCTAssertThrowsError(try parameters.configuration())
    }
}
