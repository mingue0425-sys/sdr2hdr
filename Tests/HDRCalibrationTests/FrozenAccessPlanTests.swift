import Foundation
import XCTest
@testable import HDRCalibration

/// v4-run may stop after Validation selection so that a policy comparison
/// (e.g. SDR transfer interpretation) never spends the one-use Virgin Frozen
/// holdout. Without the stop request the historical fail-closed rule holds:
/// virgin holdouts require an admitted Frozen plan.
final class FrozenAccessPlanTests: XCTestCase {
    func testStopBeforeFrozenNeverOpensAndNeedsNoPlan() throws {
        XCTAssertEqual(try CalibrationV4Runner.frozenAccessPlan(virginCount: 4, hasAdmittedPlan: false, stopBeforeFrozen: true), .stopBeforeFrozen)
        XCTAssertEqual(try CalibrationV4Runner.frozenAccessPlan(virginCount: 4, hasAdmittedPlan: true, stopBeforeFrozen: true), .stopBeforeFrozen)
        XCTAssertEqual(try CalibrationV4Runner.frozenAccessPlan(virginCount: 0, hasAdmittedPlan: false, stopBeforeFrozen: true), .stopBeforeFrozen)
    }

    func testVirginHoldoutsStillRequireAnAdmittedPlanByDefault() throws {
        XCTAssertThrowsError(try CalibrationV4Runner.frozenAccessPlan(virginCount: 4, hasAdmittedPlan: false, stopBeforeFrozen: false)) { error in
            XCTAssertTrue(String(describing: error).contains("--prepared-frozen-plan"))
        }
        XCTAssertEqual(try CalibrationV4Runner.frozenAccessPlan(virginCount: 4, hasAdmittedPlan: true, stopBeforeFrozen: false), .openOnce)
        XCTAssertEqual(try CalibrationV4Runner.frozenAccessPlan(virginCount: 0, hasAdmittedPlan: false, stopBeforeFrozen: false), .noVirginHoldout)
    }

    func testStopRequestIsNotPartOfTheObjectiveConfiguration() throws {
        // The objective hash covers V4CalibrationConfiguration; a stop
        // request must not change it, so stopped and full runs stay comparable.
        let encoded = try JSONEncoder().encode(V4CalibrationConfiguration())
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("stopbefore"))
    }
}
