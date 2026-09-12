import CoreVideo
import Metal
import XCTest
@testable import HDRCore

final class SDRInterpretationPolicyTests: XCTestCase {
    func testIndependentTransferAnchors() {
        XCTAssertEqual(HDRColorMath.inverseBT709(0), 0, accuracy: 1e-7)
        XCTAssertEqual(HDRColorMath.inverseBT709(0.5), 0.2595894, accuracy: 2e-5)
        XCTAssertEqual(HDRColorMath.inverseBT709(1), 1, accuracy: 1e-6)

        XCTAssertEqual(
            HDRColorMath.inverseBT1886(0.5, parameters: .idealReference),
            0.1894646,
            accuracy: 2e-5
        )
        XCTAssertEqual(HDRColorMath.inverseBT1886(0, parameters: .idealReference), 0, accuracy: 1e-7)
        XCTAssertEqual(HDRColorMath.inverseBT1886(1, parameters: .idealReference), 1, accuracy: 1e-6)

        let sRGB128 = HDRColorMath.inverseSRGB(128 / 255)
        XCTAssertEqual(sRGB128, 0.2158605, accuracy: 2e-5)
    }

    func testBT1886NonZeroBlackUsesIndependentRootDomainEquation() {
        let parameters = BT1886TransferParameters(
            blackLuminance: 0.01,
            whiteLuminance: 1,
            gamma: 2.4
        )
        let signal: Float = 0.5
        let blackRoot = pow(parameters.blackLuminance, 1 / parameters.gamma)
        let whiteRoot = pow(parameters.whiteLuminance, 1 / parameters.gamma)
        let expected = pow(
            blackRoot + (whiteRoot - blackRoot) * signal,
            parameters.gamma
        )
        XCTAssertEqual(
            HDRColorMath.inverseBT1886(signal, parameters: parameters),
            expected,
            accuracy: 2e-5
        )
        XCTAssertEqual(
            HDRColorMath.inverseBT1886(0, parameters: parameters),
            parameters.blackLuminance,
            accuracy: 2e-5
        )
        XCTAssertEqual(
            HDRColorMath.inverseBT1886(1, parameters: parameters),
            parameters.whiteLuminance,
            accuracy: 2e-5
        )
    }

    func testPiecewiseTransfersAreFiniteMonotonicContinuousAndExactAtEndpoints() {
        let bt709Breakpoint: Float = 0.081
        let sRGBBreakpoint: Float = 0.04045
        for (name, function, breakpoint) in [
            ("BT.709", HDRColorMath.inverseBT709 as (Float) -> Float, bt709Breakpoint),
            ("sRGB", HDRColorMath.inverseSRGB as (Float) -> Float, sRGBBreakpoint)
        ] {
            let below = function(breakpoint.nextDown)
            let at = function(breakpoint)
            let above = function(breakpoint.nextUp)
            XCTAssertTrue(below.isFinite, name)
            XCTAssertTrue(at.isFinite, name)
            XCTAssertTrue(above.isFinite, name)
            XCTAssertLessThanOrEqual(below, at + 1e-4, name)
            XCTAssertLessThanOrEqual(at, above + 1e-4, name)
            XCTAssertLessThan(abs(above - below), 2e-4, name)
            XCTAssertEqual(function(0), 0, accuracy: 1e-7, name)
            XCTAssertEqual(function(1), 1, accuracy: 1e-6, name)

            var previous: Float = 0
            for step in 0...1_000 {
                let value = function(Float(step) / 1_000)
                XCTAssertTrue(value.isFinite, name)
                XCTAssertGreaterThanOrEqual(value, previous - 1e-6, name)
                previous = value
            }
        }
    }

    func testResolverSeparatesSourceMetadataFromSelectedPolicy() throws {
        let sourceLinear = try SDRInputInterpretationResolver.resolve(
            sourceTransferTag: .ituR709,
            metadataTransfer: .bt709,
            requestedPolicy: .bt709SourceLinear
        )
        XCTAssertEqual(sourceLinear.sourceTransferTag, .ituR709)
        XCTAssertEqual(sourceLinear.selectedPolicy, .bt709SourceLinear)
        XCTAssertEqual(sourceLinear.effectiveTransfer, .bt709)
        XCTAssertFalse(sourceLinear.fallbackUsed)

        let display = try SDRInputInterpretationResolver.resolve(
            sourceTransferTag: .ituR709,
            metadataTransfer: .bt709,
            requestedPolicy: .bt1886ReferenceDisplay
        )
        XCTAssertEqual(display.sourceTransferTag, .ituR709)
        XCTAssertEqual(display.selectedPolicy, .bt1886ReferenceDisplay)
        XCTAssertEqual(
            display.effectiveTransfer,
            .bt1886(.idealReference)
        )

        let sRGB = try SDRInputInterpretationResolver.resolve(
            sourceTransferTag: .sRGB,
            metadataTransfer: .sRGB,
            requestedPolicy: .bt1886ReferenceDisplay
        )
        XCTAssertEqual(sRGB.sourceTransferTag, .sRGB)
        XCTAssertEqual(sRGB.selectedPolicy, .sRGB)
        XCTAssertEqual(sRGB.effectiveTransfer, .sRGB)

        let gamma = try SDRInputInterpretationResolver.resolve(
            sourceTransferTag: .explicitGamma,
            metadataTransfer: .gamma(2.2),
            requestedPolicy: .bt1886ReferenceDisplay
        )
        XCTAssertEqual(gamma.selectedPolicy, .explicitGamma)
        XCTAssertEqual(gamma.effectiveTransfer, .gamma(2.2))

        let linear = try SDRInputInterpretationResolver.resolve(
            sourceTransferTag: .linear,
            metadataTransfer: .linear,
            requestedPolicy: .bt1886ReferenceDisplay
        )
        XCTAssertEqual(linear.selectedPolicy, .linear)
        XCTAssertEqual(linear.effectiveTransfer, .linear)
    }

    func testUntaggedFallbackIsExplicitAndRejectsWhenConfigured() throws {
        let bt709 = try SDRInputInterpretationResolver.resolve(
            sourceTransferTag: .unknown,
            metadataTransfer: nil,
            requestedPolicy: .bt1886ReferenceDisplay,
            untaggedFallback: .assumeBT709SourceLinear
        )
        XCTAssertTrue(bt709.fallbackUsed)
        XCTAssertEqual(bt709.selectedPolicy, .bt709SourceLinear)
        XCTAssertEqual(bt709.effectiveTransfer, .bt709)
        XCTAssertTrue(bt709.fallbackReason?.contains("assumeBT709SourceLinear") == true)

        let bt1886 = try SDRInputInterpretationResolver.resolve(
            sourceTransferTag: .unknown,
            metadataTransfer: nil,
            requestedPolicy: .bt709SourceLinear,
            untaggedFallback: .assumeBT1886ReferenceDisplay
        )
        XCTAssertTrue(bt1886.fallbackUsed)
        XCTAssertEqual(bt1886.selectedPolicy, .bt1886ReferenceDisplay)
        XCTAssertEqual(bt1886.effectiveTransfer, .bt1886(.idealReference))

        XCTAssertThrowsError(try SDRInputInterpretationResolver.resolve(
            sourceTransferTag: .unknown,
            metadataTransfer: nil,
            requestedPolicy: .bt709SourceLinear,
            untaggedFallback: .reject
        )) { error in
            XCTAssertEqual(error as? HDRColorMetadataError, .untaggedSourceRejected)
        }
        XCTAssertThrowsError(try SDRInputInterpretationResolver.resolve(
            sourceTransferTag: .unsupportedHDR,
            metadataTransfer: nil,
            requestedPolicy: .bt709SourceLinear
        )) { error in
            XCTAssertEqual(error as? HDRColorMetadataError, .unsupportedTransferFunction)
        }
    }

    func testCoreVideoMetadataResolvesSourceTagAndFallbackRecord() throws {
        let tagged = try makeBGRAForMetadataTest()
        CVBufferSetAttachment(
            tagged,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            tagged,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_sRGB,
            .shouldPropagate
        )
        let sRGB = try HDRInputMetadata.resolve(
            pixelBuffer: tagged,
            fallbackPolicy: .bt709FullRange,
            interpretationPolicy: .bt1886ReferenceDisplay
        )
        XCTAssertEqual(sRGB.sourceTransferTag, .sRGB)
        XCTAssertEqual(sRGB.interpretationPolicy, .sRGB)
        XCTAssertEqual(sRGB.effectiveTransfer, .sRGB)
        XCTAssertFalse(sRGB.fallbackUsed)

        let untagged = try makeBGRAForMetadataTest()
        let fallback = try HDRInputMetadata.resolve(
            pixelBuffer: untagged,
            fallbackPolicy: .bt709FullRange,
            interpretationPolicy: .bt709SourceLinear,
            untaggedFallback: .assumeBT1886ReferenceDisplay
        )
        XCTAssertEqual(fallback.sourceTransferTag, .unknown)
        XCTAssertEqual(fallback.interpretationPolicy, .bt1886ReferenceDisplay)
        XCTAssertEqual(fallback.effectiveTransfer, .bt1886(.idealReference))
        XCTAssertTrue(fallback.fallbackUsed)
        XCTAssertNotNil(fallback.fallbackReason)
    }

    func testNV12AndP010NormalizationShareTheSamePolicyDomain() {
        let signal: Float = 0.5
        let nv12Code = ((16 + signal * 219).rounded() - 16) / 219
        let p010Code = ((64 + signal * 876).rounded() - 64) / 876
        XCTAssertEqual(
            HDRColorMath.inverseTransfer(nv12Code, function: .bt1886(.idealReference)),
            HDRColorMath.inverseTransfer(p010Code, function: .bt1886(.idealReference)),
            accuracy: 0.003
        )
    }

    func testBT1886PolicyReachesGPUAndScalarReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
            for index in 0..<4 {
                base[index * 4] = 128
                base[index * 4 + 1] = 128
                base[index * 4 + 2] = 128
                base[index * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

        var configuration = HDRConfiguration.hdr
        configuration.outputMode = .edr
        configuration.sdrInterpretationPolicy = .bt1886ReferenceDisplay
        let processor = try HDRProcessor(device: device, configuration: configuration)
        let commandBuffer = try processor.makeCommandBuffer()
        let frame = try processor.process(pixelBuffer: buffer, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        let actual = try readFirstRGBA16FloatPixel(from: frame.texture, device: device)
        let signal = Float(128) / 255
        let expected = try HDRReference.process(
            signalRGB: SIMD3(repeating: signal),
            configuration: configuration,
            sourceTransferTag: .ituR709
        )
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.003)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.003)
        XCTAssertEqual(actual.z, expected.z, accuracy: 0.003)
    }

    private func makeBGRAForMetadataTest() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1,
            1,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "SDRInterpretationPolicyTests", code: Int(status))
        }
        return pixelBuffer
    }
}
