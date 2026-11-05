import Foundation
import XCTest
@testable import HDRCalibration

/// The admitted Frozen plan must cover exactly the holdout set v4-run
/// validates it against, in manifest order, and must refuse pairs that were
/// already spent instead of dropping them.
final class FrozenPlanPreparationTests: XCTestCase {
    private func pair(_ id: String, _ split: DatasetSplit, virgin: Bool = false,
                      evaluated: Bool? = false, consumed: Bool? = false) -> V4PairRecord {
        V4PairRecord(id: id, sdr: "r:\(id)-sdr.mov", hdr: "r:\(id)-hdr.mov", source: "s", license: "l",
                     expectedRelation: .sameMaster, split: split, virginFrozen: virgin,
                     objectiveEvaluated: evaluated, consumed: consumed)
    }

    func testSelectsVirginFrozenPairsInManifestOrder() throws {
        let manifest = V4Manifest(pairs: [
            pair("f2", .frozen, virgin: true), pair("t1", .tune), pair("v1", .validation),
            pair("legacy-frozen", .frozen, virgin: false), pair("f1", .frozen, virgin: true)
        ])
        XCTAssertEqual(try V6FrozenPlanPreparation.virginRecords(manifest).map(\.id), ["f2", "f1"])
    }

    func testSpentOrUnmarkedHoldoutsFailClosed() {
        for spent in [pair("f", .frozen, virgin: true, evaluated: true),
                      pair("f", .frozen, virgin: true, consumed: true),
                      pair("f", .frozen, virgin: true, evaluated: nil)] {
            XCTAssertThrowsError(try V6FrozenPlanPreparation.virginRecords(V4Manifest(pairs: [spent])))
        }
        XCTAssertThrowsError(try V6FrozenPlanPreparation.virginRecords(V4Manifest(pairs: [pair("t", .tune)])))
    }

    func testScopeMatchesTheSealedContract() {
        XCTAssertEqual(V6FrozenPlanPreparation.scope, "VIRGIN_FROZEN")
    }
}
