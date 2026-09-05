import CoreVideo
import Metal
import XCTest
@testable import HDRCore

final class HDRV62SceneAdaptiveTests: XCTestCase {
    private let statistics = HDRSceneStatistics(
        p01: 0.01,
        p05: 0.03125,
        p10: 0.04,
        p25: 0.0725,
        p50: 0.25,
        p90: 0.78,
        p99: 0.98
    )

    func testV4ProductionValuesRemainExactAndRevisionIsSeparate() {
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
        XCTAssertEqual(HDRV62ToneCurveCandidate.adaptiveCombined.configuration().toneCurveRevision, .sceneAdaptiveV62Candidate)
    }

    func testBudgetIsBoundedFiniteAndDoesNotUseTransferLabel() {
        let features = HDRV62SceneFeatures(statistics: statistics)
        for controller in HDRV62ExpansionController.allCases {
            let budget = HDRV62ExpansionBudgetMath.budget(
                features: features,
                controller: controller,
                parameters: .developmentDefault
            )
            XCTAssertTrue(budget.budget.isFinite)
            XCTAssertTrue((0...1).contains(budget.budget))
            XCTAssertTrue(budget.statisticsValid)
        }
        let same = HDRV62ExpansionBudgetMath.budget(
            features: features,
            controller: .compactCombined,
            parameters: .developmentDefault
        )
        XCTAssertEqual(same.budget, HDRV62ExpansionBudgetMath.budget(
            features: features,
            controller: .compactCombined,
            parameters: .developmentDefault
        ).budget, accuracy: 0)
    }

    func testInvalidFeatureOrParameterInputFailsSafeToV4Endpoint() {
        let invalidStatistics = HDRSceneStatistics(
            p01: .nan, p05: .nan, p10: .nan, p25: .nan,
            p50: .nan, p90: .nan, p99: .nan
        )
        let invalidFeatures = HDRV62SceneFeatures(statistics: invalidStatistics)
        XCTAssertFalse(invalidFeatures.isFinite)
        XCTAssertEqual(
            HDRV62ExpansionBudgetMath.budget(
                features: invalidFeatures,
                controller: .highlightDemand,
                parameters: .developmentDefault
            ).budget,
            1,
            accuracy: 0
        )

        var invalidParameters = HDRV62ControllerParameters.developmentDefault
        invalidParameters.minimumBudget = .nan
        XCTAssertEqual(
            HDRV62ExpansionBudgetMath.budget(
                features: HDRV62SceneFeatures(statistics: statistics),
                controller: .highlightDemand,
                parameters: invalidParameters
            ).budget,
            1,
            accuracy: 0
        )
    }

    func testBudgetOneIsExactV4Endpoint() {
        var candidate = HDRV62ToneCurveCandidate.adaptiveCombined.configuration()
        candidate.developmentExpansionMinimumBudget = 1
        for y in stride(from: Float(0), through: 1, by: 0.001) {
            let adaptive = HDRV62ToneCurveMath.toneExpand(
                y,
                configuration: candidate,
                temporalAdaptation: 0.965,
                sceneStatistics: statistics
            )
            let v4 = HDRReference.toneExpand(
                y,
                configuration: .calibratedV4,
                temporalAdaptation: 0.965,
                sceneStatistics: statistics
            )
            XCTAssertEqual(adaptive, v4, accuracy: 1e-6, "Y=\(y)")
        }
    }

    func testBudgetZeroRemovesOnlyLowMidTerm() {
        let candidate = HDRV62ToneCurveCandidate.adaptiveCombined.configuration()
        for y in stride(from: Float(0), through: 1, by: 0.001) {
            let adaptive = HDRV62ToneCurveMath.toneExpand(
                y,
                configuration: candidate,
                temporalAdaptation: 1,
                sceneStatistics: statistics,
                budgetOverride: 0
            )
            let expected = HDRDiagnosticToneSweep.v4Breakdown(
                luminance: y,
                configuration: .calibratedV4,
                temporalAdaptation: 1,
                sceneShadowFloor: statistics.shadowFloor,
                sceneShadowTop: statistics.shadowTop,
                sceneStatisticsValid: true,
                lowMidCoefficient: 0
            ).expandedLuminance
            XCTAssertEqual(adaptive, expected, accuracy: 1e-6, "Y=\(y)")
        }
    }

    func testAdaptiveCurveIsMonotonicBlackAnchoredContinuousAndFinite() {
        for controller in HDRV62ExpansionController.allCases {
            var configuration = HDRV62ToneCurveCandidate.adaptiveCombined.configuration()
            configuration.developmentExpansionController = controller
            var previous: Float = 0
            var previousSlope: Float?
            for index in 0...1_000 {
                let y = Float(index) / 1_000
                let value = HDRV62ToneCurveMath.toneExpand(
                    y,
                    configuration: configuration,
                    sceneStatistics: statistics
                )
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, y - 1e-6)
                XCTAssertGreaterThanOrEqual(value, previous - 1e-5)
                if index > 0, let previousSlope {
                    let slope = value - previous
                    XCTAssertLessThan(abs(slope - previousSlope), 0.02)
                    self.continueAfterFailure = true
                }
                if index > 0 { previousSlope = value - previous }
                previous = value
            }
            XCTAssertEqual(
                HDRV62ToneCurveMath.toneExpand(0, configuration: configuration, sceneStatistics: statistics),
                0,
                accuracy: 0
            )
        }
    }

    func testInvalidStatisticsPreserveV4AtStartup() {
        let candidate = HDRV62ToneCurveCandidate.adaptiveCombined.configuration()
        let features = HDRV62SceneFeatures(statistics: .neutral, statisticsValid: false)
        let budget = HDRV62ExpansionBudgetMath.budget(
            features: features,
            controller: .compactCombined,
            parameters: .developmentDefault
        )
        XCTAssertEqual(budget.budget, 1, accuracy: 0)
        XCTAssertFalse(budget.statisticsValid)
        XCTAssertEqual(
            HDRV62ToneCurveMath.toneExpand(0.35, configuration: candidate, sceneStatistics: nil),
            HDRReference.toneExpand(0.35, configuration: .calibratedV4, sceneStatistics: nil),
            accuracy: 1e-6
        )
    }

    func testCausalPercentileStateIsSmoothedForAdaptiveFeatures() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let processor = try HDRProcessor(device: device, configuration: .calibratedV4)
        let first = HDRSceneStatistics(
            p01: 0.005, p05: 0.01, p10: 0.02, p25: 0.08,
            p50: 0.20, p90: 0.60, p99: 0.80
        )
        let second = HDRSceneStatistics(
            p01: 0.10, p05: 0.20, p10: 0.30, p25: 0.45,
            p50: 0.70, p90: 0.90, p99: 1.0
        )

        processor.updateSceneStatistics(first, sceneCut: true)
        let snapped = processor.causalSceneStatistics
        XCTAssertEqual(snapped.p01, first.p01, accuracy: 1e-6)
        XCTAssertEqual(snapped.p50, first.p50, accuracy: 1e-6)
        XCTAssertEqual(snapped.p99, first.p99, accuracy: 1e-6)

        processor.updateSceneStatistics(second, sceneCut: false)
        let smoothed = processor.causalSceneStatistics
        XCTAssertGreaterThan(smoothed.p50, first.p50)
        XCTAssertLessThan(smoothed.p50, second.p50)
        XCTAssertGreaterThan(smoothed.p99, first.p99)
        XCTAssertLessThan(smoothed.p99, second.p99)
        XCTAssertTrue(smoothed.isFinite)
    }

    func testTuneParameterFreezeIsCandidateSpecificAndDevelopmentOnly() {
        let highlight = HDRV62ToneCurveCandidate.adaptiveHighlight.tuneParameterFreeze
        let range = HDRV62ToneCurveCandidate.adaptiveDynamicRange.tuneParameterFreeze
        let combined = HDRV62ToneCurveCandidate.adaptiveCombined.tuneParameterFreeze

        XCTAssertEqual(highlight.minimumBudget, 0.65, accuracy: 0)
        XCTAssertEqual(highlight.highlightLow, 0, accuracy: 0)
        XCTAssertEqual(highlight.highlightHigh, 0.45, accuracy: 0)
        XCTAssertEqual(range.dynamicRangeLow, 0.25, accuracy: 0)
        XCTAssertEqual(range.dynamicRangeHigh, 1.5, accuracy: 0)
        XCTAssertEqual(combined.combinedHighlightWeight, 0.50, accuracy: 0)
        XCTAssertEqual(combined.combinedDynamicRangeWeight, 0.30, accuracy: 0)
        XCTAssertEqual(combined.combinedMidtoneWeight, 0.20, accuracy: 0)
        XCTAssertEqual(
            HDRV62ToneCurveCandidate.adaptiveHighlight.configuration().toneCurveRevision,
            .sceneAdaptiveV62Candidate
        )
    }

    func testV62MetalOutputMatchesCPUReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        var configuration = HDRV62ToneCurveCandidate.adaptiveHighlight.configuration()
        configuration.inputFallbackPolicy = .bt709FullRange
        let statistics = HDRSceneStatistics(
            p01: 0.01, p05: 0.03125, p10: 0.04, p25: 0.08,
            p50: 0.25, p90: 0.78, p99: 0.98
        )
        let processor = try HDRProcessor(device: device, configuration: configuration)
        processor.updateSceneStatistics(statistics, sceneCut: true)
        let pixelBuffer = try makeBGRA(width: 2, height: 2, value: 0.65)
        let commandBuffer = try processor.makeCommandBuffer()
        let frame = try processor.process(
            pixelBuffer: pixelBuffer,
            timestamp: nil,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        var output = [Float16](repeating: 0, count: 4)
        frame.texture.getBytes(
            &output,
            bytesPerRow: 2 * MemoryLayout<Float16>.size * 4,
            from: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0
        )
        let encodedValue = Float(UInt8(min(max(0.65 * 255, 0), 255))) / 255
        let expected = HDRReference.process(
            signalRGB: SIMD3(repeating: encodedValue),
            configuration: configuration,
            temporalAdaptation: 1,
            sceneStatistics: statistics
        )
        XCTAssertEqual(Float(output[0]), expected.x, accuracy: 0.003)
        XCTAssertEqual(Float(output[1]), expected.y, accuracy: 0.003)
        XCTAssertEqual(Float(output[2]), expected.z, accuracy: 0.003)
    }

    private func makeBGRA(width: Int, height: Int, value: Float) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "HDRV62SceneAdaptiveTests", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let channel = UInt8(min(max(value * 255, 0), 255))
        for row in 0..<height {
            let base = bytes?.advanced(by: row * rowBytes)
            for column in 0..<width {
                let offset = column * 4
                base?[offset] = channel
                base?[offset + 1] = channel
                base?[offset + 2] = channel
                base?[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}
