import XCTest
@testable import HDRCalibration

final class V4PreparedPairCacheTests: XCTestCase {
    private func record(_ id: String, _ split: DatasetSplit) -> PairRecord {
        PairRecord(id: id, sdr: "s", hdr: "h", license: "l", source: "x", expectedRelation: .sameMaster, notes: nil, split: split)
    }

    func testKeyBindsPlanOrderSplitAndBytes() {
        let records = [record("a", .tune), record("b", .validation)]
        let hashes = ["a": V6InputHashes(sdrSHA256: "11", hdrSHA256: "22"), "b": V6InputHashes(sdrSHA256: "33", hdrSHA256: "44")]
        let base = V4PreparedPairCache.key(planSHA256: "p", records: records, inputHashes: hashes)
        XCTAssertNotEqual(base, V4PreparedPairCache.key(planSHA256: "q", records: records, inputHashes: hashes))
        XCTAssertNotEqual(base, V4PreparedPairCache.key(planSHA256: "p", records: records.reversed(), inputHashes: hashes))
        XCTAssertNotEqual(base, V4PreparedPairCache.key(planSHA256: "p", records: [record("a", .validation), record("b", .validation)], inputHashes: hashes))
        var changed = hashes
        changed["b"] = V6InputHashes(sdrSHA256: "33", hdrSHA256: "45")
        XCTAssertNotEqual(base, V4PreparedPairCache.key(planSHA256: "p", records: records, inputHashes: changed))
        XCTAssertEqual(base, V4PreparedPairCache.key(planSHA256: "p", records: records, inputHashes: hashes))
    }

    func testMissIsCounted() {
        let cache = V4PreparedPairCache()
        XCTAssertNil(cache.lookup("k"))
        XCTAssertEqual(cache.misses, 1)
        XCTAssertEqual(cache.hits, 0)
    }
}
