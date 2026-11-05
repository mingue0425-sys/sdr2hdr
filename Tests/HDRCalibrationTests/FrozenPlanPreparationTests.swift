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

    func testInputBytesMustMatchAuditedDigestsBeforeDecode() throws {
        let sdr = URL(fileURLWithPath: "/x/f-sdr.mov"), hdr = URL(fileURLWithPath: "/x/f-hdr.mov")
        let digests = [sdr: "aa", hdr: "bb"]
        let hash: (URL) throws -> String = { digests[$0] ?? "" }
        let expected = ["f": V6InputHashes(sdrSHA256: "aa", hdrSHA256: "bb")]
        XCTAssertNoThrow(try V6FrozenPlanPreparation.verifyInputHashes([(id: "f", sdr: sdr, hdr: hdr)], expected: expected, sha256: hash))
        XCTAssertThrowsError(try V6FrozenPlanPreparation.verifyInputHashes(
            [(id: "f", sdr: sdr, hdr: hdr)], expected: ["f": V6InputHashes(sdrSHA256: "aa", hdrSHA256: "changed")], sha256: hash))
        XCTAssertThrowsError(try V6FrozenPlanPreparation.verifyInputHashes(
            [(id: "missing", sdr: sdr, hdr: hdr)], expected: expected, sha256: hash))
    }

    func testAnExistingPlanIsNeverOverwritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("frozen-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("plan.json")
        try Data("admitted".utf8).write(to: existing)
        do {
            _ = try await V6FrozenPlanPreparation.run(
                manifestURL: directory.appendingPathComponent("manifest.json"),
                auditURL: directory.appendingPathComponent("audit.json"),
                tuneValidationPlanURL: directory.appendingPathComponent("tv.json"),
                outputURL: existing
            )
            XCTFail("an existing plan was not protected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("never overwritten"), String(describing: error))
        }
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "admitted")
    }
}
