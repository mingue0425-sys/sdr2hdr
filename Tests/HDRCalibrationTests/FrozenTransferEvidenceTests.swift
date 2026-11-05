import Foundation
import XCTest
@testable import HDRCalibration

/// Before the holdout opens, v4-run must know each Virgin Frozen pair's HDR
/// transfer without opening it. correctness-review takes it from the
/// lock-bound dataset audit (container metadata probed by the audit tool);
/// v4-run must use the same evidence. The manifest `referenceTransfer` field
/// is overloaded (it also documents SDR fallbacks such as bt1886), so it is
/// only a fallback when the audit carries no transfer.
final class FrozenTransferEvidenceTests: XCTestCase {
    func testAuditedHDRTransferWinsOverOverloadedManifestField() {
        XCTAssertEqual(CalibrationV4Runner.frozenTransfer(audited: "PQ", declared: "bt1886"), "PQ")
        XCTAssertEqual(CalibrationV4Runner.frozenTransfer(audited: "HLG", declared: nil), "HLG")
    }

    func testManifestDeclarationIsOnlyAFallback() {
        XCTAssertEqual(CalibrationV4Runner.frozenTransfer(audited: nil, declared: "smpte2084"), "PQ")
        XCTAssertEqual(CalibrationV4Runner.frozenTransfer(audited: "UNKNOWN", declared: "arib-std-b67"), "HLG")
        XCTAssertEqual(CalibrationV4Runner.frozenTransfer(audited: nil, declared: "bt1886"), ReferenceTransfer.unknown.canonicalName)
        XCTAssertEqual(CalibrationV4Runner.frozenTransfer(audited: nil, declared: nil), ReferenceTransfer.unknown.canonicalName)
    }
}
