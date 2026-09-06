import XCTest
@testable import HDRCore

final class HDRDiagnosticTests: XCTestCase {
    func testCalibratedV4ProductionValuesRemainExact() {
        let configuration = HDRConfiguration.calibratedV4
        XCTAssertEqual(configuration.paperWhiteNits, 190)
        XCTAssertEqual(configuration.peakNits, 1008.6863)
        XCTAssertEqual(configuration.highlightStrength, 0.6208221)
        XCTAssertEqual(configuration.contrastStrength, 0.90542316)
        XCTAssertEqual(configuration.saturationCompensation, 0.43140942)
        XCTAssertEqual(configuration.shadowProtection, 0.4755874)
        XCTAssertEqual(configuration.temporalStability, 0.7308984)
        XCTAssertEqual(configuration.masteringHeadroom, 5.308875)
        XCTAssertEqual(configuration.toneCurveRevision, .sceneRelativeV4)
        XCTAssertEqual(configuration.outputMode, .edr)
    }

    func testDiagnosticSweepShowsBroadLowMidContributionAndShoulderOverlap() {
        let rows = HDRDiagnosticToneSweep.rows(
            temporalAdaptationV2: 0.965,
            temporalAdaptationV4: 0.965,
            sceneShadowFloor: 0.03125,
            sceneShadowTop: 0.05625,
            sceneStatisticsValid: true
        )
        let rowAtPointFive = try! XCTUnwrap(rows.first { abs($0.inputLuminance - 0.50) < 0.0001 })
        XCTAssertGreaterThan(rowAtPointFive.lowMidTransition, 0.99)
        XCTAssertGreaterThan(rowAtPointFive.v4LowMidContribution, 0.02)
        XCTAssertGreaterThan(rowAtPointFive.v4ShoulderContribution, 0)
        XCTAssertGreaterThan(rowAtPointFive.v4OutputLuminance, rowAtPointFive.v2OutputLuminance)
        XCTAssertGreaterThan(rowAtPointFive.v4ToV2Ratio, 1.05)

        let expectedGain = HDRDiagnosticToneSweep.lowMidAsymptoticGain(
            temporalAdaptation: 0.965
        )
        XCTAssertEqual(expectedGain, 1.206, accuracy: 0.01)
        XCTAssertEqual(
            HDRDiagnosticToneSweep.shoulderStart(),
            0.49891537,
            accuracy: 0.000001
        )
    }

    func testDiagnosticPercentileOrderAndSceneAnchorRows() {
        let values = [
            HDRLuminanceStatistics(
                p01: 0.01, p05: 0.05, p50: 0.50, p90: 0.90,
                p95: 0.95, p99: 0.99, average: 0.4, max: 1
            )
        ]
        for value in values {
            XCTAssertLessThanOrEqual(value.p01, value.p05)
            XCTAssertLessThanOrEqual(value.p05, value.p50)
            XCTAssertLessThanOrEqual(value.p50, value.p90)
            XCTAssertLessThanOrEqual(value.p90, value.p95)
            XCTAssertLessThanOrEqual(value.p95, value.p99)
        }

        let anchors = HDRDiagnosticToneSweep.sceneAnchorRows()
        XCTAssertEqual(anchors.count, HDRDiagnosticToneSweep.sceneAnchorGrid.count)
        XCTAssertEqual(anchors.first?.lowMidTransition ?? -1, 0, accuracy: 0.000001)
        XCTAssertEqual(anchors.last?.lowMidTransition ?? -1, 1, accuracy: 0.000001)
        for index in 1..<anchors.count {
            XCTAssertGreaterThanOrEqual(anchors[index].lowMidTransition, anchors[index - 1].lowMidTransition)
        }
    }
}
