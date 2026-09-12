import CoreVideo
import Metal
import XCTest
@testable import HDRCore

final class AuditRegressionTests: XCTestCase {
    func testPQAbsoluteAnchorsIndependentOfRoundTrip() {
        // ST.2084 absolute anchors: a mutually wrong encode/decode pair cannot
        // pass by cancelling its scale error in a round trip.
        XCTAssertEqual(HDRColorMath.pqEncode(nits: 100), 0.50807842, accuracy: 1e-5)
        XCTAssertEqual(HDRColorMath.pqEncode(nits: 1_000), 0.75182710, accuracy: 1e-5)
        XCTAssertEqual(HDRColorMath.pqDecodeNits(signal: 0.50807842), 100, accuracy: 0.01)
        XCTAssertEqual(HDRColorMath.pqDecodeNits(signal: 0.75182710), 1_000, accuracy: 0.1)
    }

    func testGammaMetadataMustRemainFiniteAndPositiveInShaderPrecision() throws {
        // IOSurface stores gamma in a bounded representation; a plain CV buffer
        // lets the metadata resolver see the original double-precision value.
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_UseGamma, .shouldPropagate)
        for gamma in [Double.greatestFiniteMagnitude, Double.leastNonzeroMagnitude] {
            CVBufferSetAttachment(buffer, kCVImageBufferGammaLevelKey,
                                  NSNumber(value: gamma), .shouldPropagate)
            XCTAssertThrowsError(try HDRColorMetadataResolver.resolve(
                pixelBuffer: buffer, fallbackPolicy: .requireMetadata
            ), "gamma=\(gamma)") { error in
                XCTAssertEqual(error as? HDRColorMetadataError, .invalidGamma)
            }
        }
    }

    func testNeutralNearBlackPreservesLinearLightBeforeHalfQuantization() throws {
        // An independently evaluated power law, not HDRReference as an oracle.
        // Codes 1 and 2 are below the smallest positive binary16 value; codes
        // 4 and 8 are the first useful half-precision anchors.  Keeping all
        // five points here catches a denominator floor, a sign flip, and a
        // non-monotone quantization change in the same regression.
        let codes: [UInt8] = [0, 1, 2, 4, 8]
        var config = HDRConfiguration.natural
        config.highlightStrength = 0
        config.shadowProtection = 0

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var previous: Float = -Float.leastNonzeroMagnitude
        for code in codes {
            let signal = Float(code) / 255
            let expected = pow(signal, 4)
            let scalar = HDRReference.process(signalRGB: SIMD3(repeating: signal),
                                               configuration: config, transferFunction: .gamma(4))
            XCTAssertTrue(scalar.x.isFinite)
            XCTAssertGreaterThanOrEqual(scalar.x, 0)
            XCTAssertEqual(scalar.x, expected, accuracy: max(expected * 0.0001, 1e-12))

            let buffer = try makeBuffer(width: 2, code: code)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                                  kCVImageBufferTransferFunction_UseGamma, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferGammaLevelKey,
                                  NSNumber(value: 4.0), .shouldPropagate)
            let processor = try HDRProcessor(device: device, configuration: config)
            let command = try processor.makeCommandBuffer()
            let frame = try processor.process(pixelBuffer: buffer, commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            let pixel = try readFirstRGBA16FloatPixel(from: frame.texture, device: device)
            for channel in [pixel.x, pixel.y, pixel.z] {
                XCTAssertTrue(channel.isFinite, "code=\(code) produced non-finite output")
                XCTAssertGreaterThanOrEqual(channel, 0, "code=\(code) produced a sign flip")
            }
            XCTAssertGreaterThanOrEqual(pixel.x, previous, "near-black output is not monotone at code \(code)")
            XCTAssertEqual(pixel.x, Float(Float16(expected)), accuracy: 1e-9,
                           "unexpected half quantization at code \(code)")
            if code == 0 {
                XCTAssertEqual(pixel.x, 0, "exact black must remain exact black")
            }
            previous = pixel.x
        }
    }

    func testResolutionChangesRetireTemporalBuffersWithOutputSlots() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let processor = try HDRProcessor(device: device, configuration: .calibratedV4)
        for index in 1...20 {
            try autoreleasepool {
                let buffer = try makeBuffer(width: index * 2, code: 128)
                let command = try processor.makeCommandBuffer()
                _ = try processor.process(pixelBuffer: buffer, commandBuffer: command)
                command.commit()
                command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
            }
        }
        let metrics = processor.runtimeMetrics
        XCTAssertEqual(metrics.outputTextureAllocations, 3)
        XCTAssertLessThanOrEqual(metrics.temporalEstimateBufferAllocations, 3)
    }

    private func makeBuffer(width: Int, code: UInt8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey as String: true,
                          kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, 2,
                                         kCVPixelFormatType_32BGRA, attributes, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        for y in 0..<2 {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
                .assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[4 * x] = code
                row[4 * x + 1] = code
                row[4 * x + 2] = code
                row[4 * x + 3] = 255
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }
}
