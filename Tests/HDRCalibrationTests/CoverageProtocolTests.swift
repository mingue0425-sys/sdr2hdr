import Foundation
import XCTest
@testable import HDRCalibration

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
