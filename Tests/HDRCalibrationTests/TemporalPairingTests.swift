import Foundation
import XCTest
@testable import HDRCalibration

/// SDR and HDR window frames are paired by position. A pair is valid only if
/// both frames are the same distance in time from their window start, so a
/// cadence mismatch or a one-sided VFR gap cannot silently misalign them.
final class TemporalPairingTests: XCTestCase {
    private func grid(_ count: Int, fps: Double, start: Double = 0) -> [Double] {
        (0..<count).map { start + Double($0) / fps }
    }

    func testIdenticalCadenceWithConstantOffsetPairsEveryFrame() {
        let sdr = grid(16, fps: 24, start: 3.0)
        let hdr = grid(16, fps: 24, start: 3.0 + 0.512)
        XCTAssertEqual(V6TemporalPairing.pairedPrefixCount(sdrSeconds: sdr, hdrSeconds: hdr), 16)
    }

    func testUnequalLengthsPairOnlyTheCommonPrefix() {
        XCTAssertEqual(
            V6TemporalPairing.pairedPrefixCount(sdrSeconds: grid(16, fps: 30), hdrSeconds: grid(11, fps: 30)),
            11
        )
    }

    func testCadenceMismatchStopsBeforeFramesDriftHalfAFrameApart() {
        // 24 vs 30 fps: drift per frame is 1/24 - 1/30 = 1/120 s. With a
        // half-frame tolerance of 1/48 s, positions 0...2 stay paired.
        let count = V6TemporalPairing.pairedPrefixCount(
            sdrSeconds: grid(16, fps: 24), hdrSeconds: grid(16, fps: 30)
        )
        XCTAssertEqual(count, 3)
    }

    func testOneSidedVFRGapTruncatesAtTheGap() {
        let sdr = grid(16, fps: 24)
        var hdr = grid(16, fps: 24)
        for index in 6..<hdr.count { hdr[index] += 1.0 / 24 }
        XCTAssertEqual(V6TemporalPairing.pairedPrefixCount(sdrSeconds: sdr, hdrSeconds: hdr), 6)
    }

    func testSmallTimestampJitterIsTolerated() {
        let sdr = grid(16, fps: 30)
        let hdr = grid(16, fps: 30).enumerated().map { $0.element + ($0.offset.isMultiple(of: 2) ? 0.004 : -0.004) }
        XCTAssertEqual(V6TemporalPairing.pairedPrefixCount(sdrSeconds: sdr, hdrSeconds: hdr), 16)
    }

    func testDegenerateInputsPairNothingOrOneFrame() {
        XCTAssertEqual(V6TemporalPairing.pairedPrefixCount(sdrSeconds: [], hdrSeconds: [1]), 0)
        XCTAssertEqual(V6TemporalPairing.pairedPrefixCount(sdrSeconds: [2], hdrSeconds: [9]), 1)
        XCTAssertEqual(
            V6TemporalPairing.pairedPrefixCount(sdrSeconds: [0, .nan, 0.1], hdrSeconds: [0, 0.05, 0.1]),
            1
        )
    }

    func testPreparationPolicyNamesThePairingRule() {
        XCTAssertTrue(V6PreparationConfiguration.v6.temporalSelectionPolicy.contains(V6TemporalPairing.policy))
        XCTAssertNil(V6PreparationConfiguration.v6.validationFailure())
    }
}
