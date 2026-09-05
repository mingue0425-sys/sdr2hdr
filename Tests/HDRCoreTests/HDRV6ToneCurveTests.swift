import CoreVideo
import Foundation
import CoreMedia
import HDRCore
import Metal
import XCTest

final class HDRV6ToneCurveTests: XCTestCase {
    func testCalibratedV4ProductionValuesAndRevisionRemainExact() throws {
        let configuration = HDRConfiguration.calibratedV4
        XCTAssertEqual(configuration.paperWhiteNits, 190, accuracy: 0)
        XCTAssertEqual(configuration.peakNits, 1008.6863, accuracy: 0.000_001)
        XCTAssertEqual(configuration.highlightStrength, 0.6208221, accuracy: 0.000_000_1)
        XCTAssertEqual(configuration.contrastStrength, 0.90542316, accuracy: 0.000_000_1)
        XCTAssertEqual(configuration.saturationCompensation, 0.43140942, accuracy: 0.000_000_1)
        XCTAssertEqual(configuration.shadowProtection, 0.4755874, accuracy: 0.000_000_1)
        XCTAssertEqual(configuration.temporalStability, 0.7308984, accuracy: 0.000_000_1)
        XCTAssertEqual(configuration.masteringHeadroom, 5.308875, accuracy: 0.000_001)
        XCTAssertEqual(configuration.toneCurveRevision, .sceneRelativeV4)
        XCTAssertTrue(try configuration.validated() == configuration)
    }

    func testCandidateFamilyIsDevelopmentOnlyAndKeepsV4Parameters() {
        XCTAssertEqual(HDRV6ToneCurveCandidate.allCases.count, 6)
        for candidate in HDRV6ToneCurveCandidate.allCases {
            let configuration = candidate.configuration()
            XCTAssertEqual(configuration.toneCurveRevision, .sceneRelativeV6Candidate)
            XCTAssertEqual(configuration.paperWhiteNits, HDRConfiguration.calibratedV4.paperWhiteNits)
            XCTAssertEqual(configuration.peakNits, HDRConfiguration.calibratedV4.peakNits)
            XCTAssertEqual(configuration.highlightStrength, HDRConfiguration.calibratedV4.highlightStrength)
            XCTAssertEqual(configuration.contrastStrength, HDRConfiguration.calibratedV4.contrastStrength)
            XCTAssertEqual(configuration.saturationCompensation, HDRConfiguration.calibratedV4.saturationCompensation)
            XCTAssertEqual(configuration.shadowProtection, HDRConfiguration.calibratedV4.shadowProtection)
            XCTAssertEqual(configuration.temporalStability, HDRConfiguration.calibratedV4.temporalStability)
            XCTAssertEqual(configuration.masteringHeadroom, HDRConfiguration.calibratedV4.masteringHeadroom)
        }
        XCTAssertEqual(HDRV6ToneCurveCandidate.noLowMid.lowMidStrength, 0, accuracy: 0)
        XCTAssertEqual(HDRV6ToneCurveCandidate.bandLimited055.lowMidStrength, 0.08, accuracy: 0)
    }

    func testDenseCurvesPassHardInvariantsAcrossAnchorFamilies() {
        for candidate in HDRV6ToneCurveCandidate.allCases {
            for anchor in HDRV6ToneCurveDevelopment.anchorFamilies {
                let report = HDRV6ToneCurveDevelopment.invariantReport(
                    candidate: candidate,
                    sceneShadowFloor: anchor.floor,
                    sceneShadowTop: anchor.top
                )
                XCTAssertEqual(report.sampleCount, 1_001, candidate.rawValue + " " + anchor.name)
                let knownInvariantReject =
                    (candidate == .bandLimited055 && anchor.name == "wide") ||
                    (candidate == .bandLimited065 && anchor.name == "wide") ||
                    (candidate == .bandLimited075)
                if knownInvariantReject {
                    XCTAssertFalse(report.allPassed, candidate.rawValue + " " + anchor.name)
                } else {
                    XCTAssertTrue(
                        report.allPassed,
                        candidate.rawValue + " " + anchor.name + ": monotonic=" + String(report.monotonic) +
                            " dark=" + String(report.noDarkInversion) + " black=" + String(report.exactBlack) +
                            " negative=" + String(report.noNegativeExpansion) + " finite=" + String(report.finite) +
                            " continuous=" + String(report.continuous) + " slope=" + String(report.slopeSanity) +
                            " minSlope=" + String(report.minSlope) + " maxSlope=" + String(report.maxSlope) +
                            " maxJump=" + String(report.maxSlopeJump)
                    )
                }
                XCTAssertLessThanOrEqual(report.lowMidAtOrAboveShoulderMax, 1e-6)
            }
        }
    }

    func testRequiredGridAndDenseSweepExposeBoundedSupport() {
        XCTAssertEqual(HDRV6ToneCurveDevelopment.requiredLuminanceGrid.first, 0)
        XCTAssertEqual(HDRV6ToneCurveDevelopment.requiredLuminanceGrid.last, 1)
        XCTAssertEqual(HDRV6ToneCurveDevelopment.denseLuminanceGrid().count, 1_001)

        let rows = HDRV6ToneCurveDevelopment.scalarSweep(
            candidate: .bandLimited055,
            luminances: HDRV6ToneCurveDevelopment.requiredLuminanceGrid
        )
        let shoulderStart = HDRV6ToneCurveMath.shoulderStart()
        let shoulderRows = rows.filter { $0.inputLuminance + 1e-6 >= shoulderStart }
        XCTAssertFalse(shoulderRows.isEmpty)
        XCTAssertLessThanOrEqual(shoulderRows.map(\.candidateLowMidContribution).max() ?? 0, 1e-6)
        XCTAssertGreaterThan(rows.first(where: { abs($0.inputLuminance - 0.30) < 1e-6 })?.candidateLowMidContribution ?? 0, 0)
        XCTAssertGreaterThan(rows.first(where: { abs($0.inputLuminance - 0.30) < 1e-6 })?.v4LowMidContribution ?? 0, 0)
    }

    func testNoLowMidAblationRemovesOnlyLowMidTerm() {
        let statistics = HDRSceneStatistics(
            p01: 0.03125, p05: 0.03125, p10: 0.03125, p25: 0.08125,
            p50: 0.42, p90: 0.88, p99: 1
        )
        let v4 = HDRConfiguration.calibratedV4
        let noLowMid = HDRV6ToneCurveCandidate.noLowMid.configuration()
        let midY: Float = 0.35
        let v4Output = HDRReference.toneExpand(midY, configuration: v4, temporalAdaptation: 0.965, sceneStatistics: statistics)
        let noLowMidOutput = HDRReference.toneExpand(midY, configuration: noLowMid, temporalAdaptation: 0.965, sceneStatistics: statistics)
        let bandLimitedOutput = HDRReference.toneExpand(
            midY,
            configuration: HDRV6ToneCurveCandidate.bandLimited055.configuration(),
            temporalAdaptation: 0.965,
            sceneStatistics: statistics
        )
        XCTAssertGreaterThan(v4Output, noLowMidOutput)
        XCTAssertEqual(noLowMidOutput, midY, accuracy: 1e-6)
        XCTAssertGreaterThan(bandLimitedOutput, noLowMidOutput)
        XCTAssertGreaterThan(v4Output, bandLimitedOutput)

        let shoulder = HDRV6ToneCurveMath.shoulderStart(configuration: v4)
        for y in [shoulder, 0.70, 0.90, 1.0] {
            let bandLimitedValue = HDRReference.toneExpand(
                y,
                configuration: HDRV6ToneCurveCandidate.bandLimited055.configuration(),
                temporalAdaptation: 0.965,
                sceneStatistics: statistics
            )
            let noLowMidValue = HDRReference.toneExpand(y, configuration: noLowMid, temporalAdaptation: 0.965, sceneStatistics: statistics)
            XCTAssertEqual(bandLimitedValue, noLowMidValue, accuracy: 1e-5, "Y=" + String(y))
        }
    }

    func testCPUReferenceAndV6MathAgreeAcrossAnchorsAndTemporalStates() {
        for candidate in HDRV6ToneCurveCandidate.allCases {
            let configuration = candidate.configuration()
            for anchor in HDRV6ToneCurveDevelopment.anchorFamilies {
                let statistics = HDRSceneStatistics(
                    p01: anchor.floor, p05: anchor.floor, p10: anchor.floor,
                    p25: 2 * anchor.top - anchor.floor, p50: 0.42, p90: 0.88, p99: 1
                )
                for temporal: Float in [0.25, 0.965, 1.0] {
                    for y in HDRV6ToneCurveDevelopment.requiredLuminanceGrid {
                        let reference = HDRReference.toneExpand(
                            y,
                            configuration: configuration,
                            temporalAdaptation: temporal,
                            sceneStatistics: statistics
                        )
                        let math = HDRV6ToneCurveMath.toneExpand(
                            y,
                            configuration: configuration,
                            temporalAdaptation: temporal,
                            sceneStatistics: statistics
                        )
                        XCTAssertEqual(reference, math, accuracy: 1e-7, "(candidate.rawValue) (anchor.name) Y=(y)")
                    }
                }
            }
        }
    }

    func testV6MetalOutputMatchesScalarReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        var configuration = HDRV6ToneCurveCandidate.bandLimited055.configuration()
        configuration.inputFallbackPolicy = .bt709FullRange
        let processor = try HDRProcessor(device: device, configuration: configuration)
        let pixelBuffer = try makeBGRA(width: 2, height: 2, rgb: SIMD3(repeating: 0.65))
        let commandBuffer = try processor.makeCommandBuffer()
        let frame = try processor.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)
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
        let expected = HDRReference.process(
            signalRGB: SIMD3(repeating: 0.65),
            configuration: configuration,
            temporalAdaptation: 1,
            sceneStatistics: nil
        )
        XCTAssertEqual(Float(output[0]), expected.x, accuracy: 0.003)
        XCTAssertEqual(Float(output[1]), expected.y, accuracy: 0.003)
        XCTAssertEqual(Float(output[2]), expected.z, accuracy: 0.003)
    }

    func testV6ControlledProcessorsKeepIndependentTemporalState() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device or command queue unavailable")
        }
        let v4 = try HDRProcessor(device: device, configuration: .calibratedV4, commandQueue: commandQueue)
        let v6 = try HDRProcessor(
            device: device,
            configuration: HDRV6ToneCurveCandidate.bandLimited045.configuration(),
            commandQueue: commandQueue
        )
        v4.temporalTraceEnabled = true
        v6.temporalTraceEnabled = true
        let pixelBuffer = try makeBGRA(width: 8, height: 8, rgb: SIMD3(repeating: 0.5))

        guard let firstCommand = commandQueue.makeCommandBuffer() else {
            XCTFail("Unable to create first command buffer")
            return
        }
        _ = try v4.process(pixelBuffer: pixelBuffer, timestamp: CMTime(value: 0, timescale: 30), commandBuffer: firstCommand, diagnosticFrameIndex: 1)
        _ = try v6.process(pixelBuffer: pixelBuffer, timestamp: CMTime(value: 0, timescale: 30), commandBuffer: firstCommand, diagnosticFrameIndex: 1)
        firstCommand.commit()
        firstCommand.waitUntilCompleted()

        guard let secondCommand = commandQueue.makeCommandBuffer() else {
            XCTFail("Unable to create second command buffer")
            return
        }
        _ = try v6.process(pixelBuffer: pixelBuffer, timestamp: CMTime(value: 1, timescale: 30), commandBuffer: secondCommand, diagnosticFrameIndex: 2)
        secondCommand.commit()
        secondCommand.waitUntilCompleted()

        XCTAssertEqual(v4.temporalSubmissionTrace.map(\.submissionSequence), [1])
        XCTAssertEqual(v6.temporalSubmissionTrace.map(\.submissionSequence), [1, 2])
        XCTAssertEqual(v4.temporalSubmissionSequence, 1)
        XCTAssertEqual(v6.temporalSubmissionSequence, 2)
    }

    private func makeBGRA(width: Int, height: Int, rgb: SIMD3<Float>) throws -> CVPixelBuffer {
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
            throw NSError(domain: "HDRV6ToneCurveTests", code: 1)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw NSError(domain: "HDRV6ToneCurveTests", code: 2)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let red = UInt8(min(max(rgb.x, 0), 1) * 255 + 0.5)
        let green = UInt8(min(max(rgb.y, 0), 1) * 255 + 0.5)
        let blue = UInt8(min(max(rgb.z, 0), 1) * 255 + 0.5)
        for row in 0..<height {
            let rowBase = baseAddress.assumingMemoryBound(to: UInt8.self).advanced(by: row * bytesPerRow)
            for column in 0..<width {
                let offset = column * 4
                rowBase[offset] = blue
                rowBase[offset + 1] = green
                rowBase[offset + 2] = red
                rowBase[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}
