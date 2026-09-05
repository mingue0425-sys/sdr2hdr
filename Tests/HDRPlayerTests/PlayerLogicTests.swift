import CoreMedia
import CoreGraphics
import HDRCore
import XCTest
import Metal
@testable import HDRPlayerKit

final class PlayerLogicTests: XCTestCase {
    func testAspectFitPreservesAspectRatioAndCenters() {
        let geometry = AspectFitGeometry(
            sourceSize: CGSize(width: 1920, height: 1080),
            drawableSize: CGSize(width: 1000, height: 1000)
        )
        XCTAssertEqual(geometry.destinationRect.size.width, 1000, accuracy: 0.001)
        XCTAssertEqual(geometry.destinationRect.size.height, 562.5, accuracy: 0.001)
        XCTAssertEqual(geometry.destinationRect.origin.y, 218.75, accuracy: 0.001)
        XCTAssertEqual(geometry.normalizedRect.origin.y, 0.21875, accuracy: 0.001)
    }

    func testTrackTransformOrientationSwapsPortraitDimensions() {
        XCTAssertEqual(
            VideoTransformResolver.orientation(for: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)),
            .rotate90
        )
        XCTAssertEqual(
            VideoOrientation.rotate90.displaySize(for: CGSize(width: 1920, height: 1080)),
            CGSize(width: 1080, height: 1920)
        )
    }

    func testFrameSelectorSuppressesDuplicatesAndResetsAfterSeek() {
        var selector = FrameTimestampSelector()
        let target = CMTime(value: 0, timescale: 120)
        let first = CMTime(value: 0, timescale: 30)
        XCTAssertEqual(selector.decide(frameTime: first, targetTime: target), .process)
        XCTAssertEqual(selector.decide(frameTime: first, targetTime: CMTime(value: 1, timescale: 120)), .reuse)
        selector.reset()
        XCTAssertEqual(selector.decide(frameTime: first, targetTime: target), .process)
    }

    func testFrameSelectorDropsAnAlreadyLateVFRFrame() {
        var selector = FrameTimestampSelector(lateTolerance: CMTime(value: 1, timescale: 120))
        let target = CMTime(value: 120, timescale: 30)
        let late = CMTime(value: 0, timescale: 30)
        XCTAssertEqual(selector.decide(frameTime: late, targetTime: target, dropIfLate: true), .lateDrop)
    }

    func testTwentyFourFPSSourceIsNotProcessedAtOneHundTwentyHz() {
        var selector = FrameTimestampSelector()
        var processed = 0
        var reused = 0
        for tick in 0..<120 {
            let target = CMTime(value: Int64(tick), timescale: 120)
            let sourceFrame = Int(floor(Double(tick) * 24.0 / 120.0))
            let sourceTime = CMTime(value: Int64(sourceFrame), timescale: 24)
            switch selector.decide(frameTime: sourceTime, targetTime: target) {
            case .process: processed += 1
            case .reuse: reused += 1
            case .lateDrop: break
            }
        }
        XCTAssertEqual(processed, 24)
        XCTAssertEqual(reused, 96)
    }

    func testDisplayPolicyUsesHeadroomAndSafeSDRFallback() throws {
        let base = try HDRConfiguration.hdr.validated()
        let hdr = DisplayCapabilities(
            screenName: "HDR",
            potentialHeadroom: 4,
            currentHeadroom: 2,
            referenceHeadroom: 1,
            refreshRate: 120
        )
        let hdrConfig = hdr.configuration(for: base)
        XCTAssertEqual(hdrConfig.masteringHeadroom, base.masteringHeadroom, accuracy: 0.001)
        XCTAssertGreaterThan(hdrConfig.highlightStrength, 0)

        let sdr = DisplayCapabilities(
            screenName: "SDR",
            potentialHeadroom: 1,
            currentHeadroom: 1,
            referenceHeadroom: 1,
            refreshRate: 60
        )
        let sdrConfig = sdr.configuration(for: base)
        XCTAssertEqual(sdrConfig.masteringHeadroom, base.masteringHeadroom, accuracy: 0.001)
        XCTAssertEqual(sdrConfig.highlightStrength, 0, accuracy: 0.001)
        XCTAssertEqual(sdrConfig.shadowProtection, 0, accuracy: 0.001)
        XCTAssertFalse(sdr.isActivelyUsingEDR)

        let activation = DisplayCapabilities(
            screenName: "HDR activation",
            potentialHeadroom: 2,
            currentHeadroom: 1,
            referenceHeadroom: 1,
            refreshRate: 60
        )
        XCTAssertFalse(activation.isActivelyUsingEDR)
        XCTAssertEqual(activation.usableHeadroom, 1, accuracy: 0.001)
        XCTAssertFalse(activation.presentsExtendedBT2020)
        XCTAssertEqual(
            DisplayCapabilities.colorSpace(
                forEDR: activation.presentsExtendedBT2020
            )?.name as String?,
            CGColorSpace.extendedLinearSRGB as String
        )
        XCTAssertTrue(hdr.presentsExtendedBT2020)
        XCTAssertEqual(
            DisplayCapabilities.colorSpace(forEDR: hdr.presentsExtendedBT2020)?.name as String?,
            CGColorSpace.extendedLinearITUR_2020 as String
        )
    }

    func testCLIParserAcceptsUnicodeAndSpacesAndPattern() throws {
        let options = try PlayerOptions.parse(arguments: [
            "HDRPlayer", "/tmp/한국 영상.mp4", "--preset", "vivid", "--debug", "--play-for", "5"
        ])
        XCTAssertEqual(options.inputURL?.path, "/tmp/한국 영상.mp4")
        XCTAssertEqual(options.preset, "vivid")
        XCTAssertTrue(options.debug)
        XCTAssertEqual(options.playFor ?? 0, 5, accuracy: 0.001)

        let pattern = try PlayerOptions.parse(arguments: ["HDRPlayer", "--edr-test-pattern"])
        XCTAssertTrue(pattern.edrTestPattern)
        XCTAssertNil(pattern.inputURL)
    }

    func testCalibratedV1PresetIsSelectableAndValid() throws {
        let options = try PlayerOptions.parse(arguments: [
            "HDRPlayer", "/tmp/video.mp4", "--preset", "calibrated-v1"
        ])
        let configuration = try options.baseConfiguration()
        XCTAssertEqual(options.preset, "calibrated-v1")
        XCTAssertEqual(configuration.highlightStrength, 0.7680667, accuracy: 0.000001)
        XCTAssertEqual(configuration.contrastStrength, 0.72261286, accuracy: 0.000001)
        XCTAssertTrue(configuration.peakNits > configuration.paperWhiteNits)
    }

    func testCalibratedV2PresetIsSelectableAndValid() throws {
        let options = try PlayerOptions.parse(arguments: [
            "HDRPlayer", "/tmp/video.mp4", "--preset", "calibrated-v2"
        ])
        let configuration = try options.baseConfiguration()
        XCTAssertEqual(options.preset, "calibrated-v2")
        XCTAssertEqual(configuration, HDRConfiguration.calibratedV2)
        XCTAssertEqual(
            configuration.masteringHeadroom,
            configuration.peakNits / configuration.paperWhiteNits,
            accuracy: 0.000_01
        )
    }

    func testCalibratedV4PresetIsSelectableWithExactProductionValues() throws {
        let options = try PlayerOptions.parse(arguments: [
            "HDRPlayer", "/tmp/video.mp4", "--preset", "calibrated-v4"
        ])
        let configuration = try options.baseConfiguration()

        XCTAssertEqual(options.preset, "calibrated-v4")
        XCTAssertTrue(PlayerOptions.usage.contains("calibrated-v4"))
        XCTAssertEqual(configuration.paperWhiteNits, 190)
        XCTAssertEqual(configuration.peakNits, 1008.6863)
        XCTAssertEqual(configuration.highlightStrength, 0.6208221)
        XCTAssertEqual(configuration.contrastStrength, 0.90542316)
        XCTAssertEqual(configuration.saturationCompensation, 0.43140942)
        XCTAssertEqual(configuration.shadowProtection, 0.4755874)
        XCTAssertEqual(configuration.temporalStability, 0.7308984)
        XCTAssertEqual(configuration.outputMode, .edr)
        XCTAssertEqual(configuration.toneCurveRevision, .sceneRelativeV4)
        XCTAssertEqual(configuration.masteringHeadroom, 5.308875)
        XCTAssertEqual(configuration, HDRConfiguration.calibratedV4)
        XCTAssertEqual(try configuration.validated(), configuration)
    }

    func testPlayerOptionsDefaultsToCalibratedV4() throws {
        let options = PlayerOptions()
        XCTAssertEqual(options.preset, "calibrated-v4")

        let parsed = try PlayerOptions.parse(arguments: ["HDRPlayer", "/tmp/video.mp4"])
        XCTAssertEqual(parsed.preset, "calibrated-v4")
        XCTAssertEqual(try parsed.baseConfiguration(), HDRConfiguration.calibratedV4)
    }

    func testRejectedV3CandidateIsExplicitlySelectableButDoesNotReplaceV4() throws {
        let options = try PlayerOptions.parse(arguments: [
            "HDRPlayer", "/tmp/video.mp4", "--preset", "calibrated-v3-candidate"
        ])
        let configuration = try options.baseConfiguration()
        XCTAssertEqual(configuration, HDRConfiguration.calibratedV3Candidate)
        XCTAssertEqual(configuration.toneCurveRevision, .shadowProtectedV3)
        XCTAssertNotEqual(configuration, HDRConfiguration.calibratedV2)
        XCTAssertNotEqual(configuration, HDRConfiguration.calibratedV4)
    }

    func testMasteringAndPhysicalDisplayHeadroomStaySeparated() throws {
        let base = HDRConfiguration.calibratedV2
        let capabilities = DisplayCapabilities(
            screenName: "M2 panel", potentialHeadroom: 2, currentHeadroom: 1.44,
            referenceHeadroom: 1, refreshRate: 60
        )
        let runtime = capabilities.configuration(for: base)
        XCTAssertEqual(runtime.masteringHeadroom, 4.8668838, accuracy: 0.000_01)
        XCTAssertEqual(capabilities.displayState.usableHeadroom, 1.44, accuracy: 0.000_01)
    }

    func testEDRMapperIsFiniteMonotonicAndPreservesReferenceWhite() {
        let mastering: Float = 4.8668838
        let inputs: [Float] = [0.25, 0.5, 1, 1.5, 2, 3, 4, mastering]
        for display: Float in [1.1, 1.25, 1.5, 2] {
            let outputs = inputs.map {
                EDRDisplayMapper.mapLuminance($0, masteringHeadroom: mastering, displayHeadroom: display)
            }
            XCTAssertEqual(outputs[2], 1, accuracy: 0.000_001)
            XCTAssertTrue(outputs.allSatisfy { $0.isFinite && $0 <= display + 0.000_01 })
            for index in 1..<outputs.count {
                XCTAssertGreaterThan(outputs[index], outputs[index - 1])
            }
            XCTAssertGreaterThan(outputs[3], 1)
            XCTAssertEqual(outputs.last!, display, accuracy: 0.000_01)
        }
    }

    func testEDRHeadroomSmoothingAvoidsAbruptChanges() {
        var smoother = EDRHeadroomSmoother(initial: 1.1, timeConstantSeconds: 0.18)
        _ = smoother.step(timestamp: 0)
        smoother.setTarget(2)
        let first = smoother.step(timestamp: 1.0 / 60.0)
        XCTAssertGreaterThan(first, 1.1)
        XCTAssertLessThan(first, 1.3)
        var previous = first
        for frame in 2...120 {
            let current = smoother.step(timestamp: Double(frame) / 60)
            XCTAssertGreaterThanOrEqual(current, previous)
            previous = current
        }
        XCTAssertEqual(previous, 2, accuracy: 0.01)
    }

    func testPresentationPatternPreservesValuesAboveOneInEDRPath() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let renderer = try HDRPresentationRenderer(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 7,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer() else {
            XCTFail("Unable to create offscreen Metal target")
            return
        }
        renderer.encodeTestPattern(to: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var values = [Float16](repeating: 0, count: 7 * 4)
        target.getBytes(
            &values,
            bytesPerRow: 7 * 8,
            from: MTLRegionMake2D(0, 0, 7, 1),
            mipmapLevel: 0
        )
        XCTAssertEqual(Float(values[0]), 1.0, accuracy: 0.01)
        XCTAssertEqual(Float(values[24]), 4.0, accuracy: 0.02)
    }

    func testPresentationPatternMapsMasteringHighlightsWithoutHardClipPlateau() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let renderer = try HDRPresentationRenderer(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 7, height: 1, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer() else {
            return XCTFail("Unable to create Metal resources")
        }
        renderer.encodeTestPattern(
            to: target, commandBuffer: commandBuffer,
            masteringHeadroom: 4.8668838, displayHeadroom: 1.5
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var values = [Float16](repeating: 0, count: 28)
        target.getBytes(&values, bytesPerRow: 56, from: MTLRegionMake2D(0, 0, 7, 1), mipmapLevel: 0)
        let red = stride(from: 0, to: 28, by: 4).map { Float(values[$0]) }
        XCTAssertEqual(red[0], 1, accuracy: 0.01)
        XCTAssertTrue(red.allSatisfy { $0.isFinite && $0 <= 1.501 })
        for index in 1..<red.count { XCTAssertGreaterThan(red[index], red[index - 1]) }
        XCTAssertEqual(
            red.last!,
            EDRDisplayMapper.mapLuminance(4, masteringHeadroom: 4.8668838, displayHeadroom: 1.5),
            accuracy: 0.01
        )
    }
}
