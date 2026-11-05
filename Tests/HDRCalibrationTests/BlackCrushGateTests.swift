import Foundation
import XCTest
@testable import HDRCalibration

/// Black crush counts shadow pixels whose reference is above 1 nit but whose
/// output is below 0.5 nit. When the SDR grade itself already sits at code
/// black there, every mapping (default, V1, V2, every candidate) crushes the
/// same pixels, so an absolute zero gate rejects the whole search without
/// discriminating anything. The current policy gates only crush a candidate
/// introduces over the V2 baseline on the same pixels, still at zero
/// tolerance; historical configurations (no policy field) stay absolute.
final class BlackCrushGateTests: XCTestCase {
    func testCurrentPolicyGatesOnlyCrushIntroducedOverBaseline() {
        let safety = V4SafetyThresholds()
        XCTAssertEqual(safety.blackCrushPolicy, V4SafetyThresholds.blackCrushIntroducedOverV2)
        // Source-crushed pixels shared with the baseline pass.
        XCTAssertFalse(safety.blackCrushFails(candidate: 0.000_120_25, baseline: 0.000_120_25))
        XCTAssertFalse(safety.blackCrushFails(candidate: 0, baseline: 0.000_120_25))
        // Any additional crush still fails at zero tolerance.
        XCTAssertTrue(safety.blackCrushFails(candidate: 0.000_122, baseline: 0.000_120_25))
        XCTAssertTrue(safety.blackCrushFails(candidate: 0.000_01, baseline: 0))
    }

    func testHistoricalConfigurationKeepsTheAbsoluteGate() throws {
        var legacy = V4SafetyThresholds()
        legacy.blackCrushPolicy = nil
        XCTAssertTrue(legacy.blackCrushFails(candidate: 0.000_120_25, baseline: 0.000_120_25))
        XCTAssertFalse(legacy.blackCrushFails(candidate: 0, baseline: 0.5))

        // An encoded historical configuration has no policy field and decodes as absolute.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(V4SafetyThresholds())) as! [String: Any]
        object.removeValue(forKey: "blackCrushPolicy")
        let decoded = try JSONDecoder().decode(V4SafetyThresholds.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.blackCrushPolicy)
        XCTAssertTrue(decoded.blackCrushFails(candidate: 0.000_120_25, baseline: 0.000_120_25))
    }

    func testUnknownPolicyFailsClosed() {
        var unknown = V4SafetyThresholds()
        unknown.blackCrushPolicy = "something-else"
        XCTAssertTrue(unknown.blackCrushFails(candidate: 0, baseline: 0))
    }
}
