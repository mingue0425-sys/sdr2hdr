import XCTest
@testable import HDRCalibration

final class V4PairGuardrailTests: XCTestCase {
    func testRanksPairsWorstRatioToV2FirstAgainstBothBaselines() {
        let records = V4PairGuardrail.rank(
            candidate: ["a": 0.9, "b": 1.14, "c": 0.5],
            v2: ["a": 1.0, "b": 1.0, "c": 1.0],
            defaults: ["a": 1.0, "b": 0.8, "c": 0.25],
            split: ["a": .tune, "b": .validation, "c": .tune]
        )
        XCTAssertEqual(records.map(\.pairID), ["b", "a", "c"])
        XCTAssertEqual(records[0].ratioToV2, 1.14, accuracy: 1e-12)
        XCTAssertEqual(records[0].ratioToDefault, 1.425, accuracy: 1e-12)
        XCTAssertEqual(records[0].split, .validation)
        XCTAssertEqual(records[2].ratioToDefault, 2.0, accuracy: 1e-12)
    }

    func testSkipsPairsWithoutBothBaselinesOrWithNonPositiveBaselines() {
        let records = V4PairGuardrail.rank(
            candidate: ["a": 0.9, "b": 0.5, "c": 0.5],
            v2: ["a": 1.0, "c": 0.0],
            defaults: ["a": 1.0, "b": 1.0, "c": 1.0],
            split: ["a": .tune, "b": .tune, "c": .tune]
        )
        XCTAssertEqual(records.map(\.pairID), ["a"])
    }

    func testTiesKeepPairIDOrder() {
        let records = V4PairGuardrail.rank(
            candidate: ["z": 1.0, "m": 1.0], v2: ["z": 1.0, "m": 1.0], defaults: ["z": 1.0, "m": 1.0],
            split: ["z": .tune, "m": .tune]
        )
        XCTAssertEqual(records.map(\.pairID), ["m", "z"])
    }
}
