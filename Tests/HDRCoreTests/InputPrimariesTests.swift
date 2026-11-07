import CoreVideo
import Metal
import simd
import XCTest
@testable import HDRCore

final class InputPrimariesTests: XCTestCase {
    func testBT601PrimariesResolveAndOtherWideGamutsStillFail() throws {
        let cases: [(CFString, HDRInputPrimaries)] = [
            (kCVImageBufferColorPrimaries_ITU_R_709_2, .bt709),
            (kCVImageBufferColorPrimaries_SMPTE_C, .smpteC),
            (kCVImageBufferColorPrimaries_EBU_3213, .ebu3213),
        ]
        for (tag, expected) in cases {
            let buffer = try makeBuffer(bgr: (128, 128, 128), primaries: tag)
            let metadata = try HDRInputMetadata.resolve(pixelBuffer: buffer, fallbackPolicy: .requireMetadata)
            XCTAssertEqual(metadata.primaries, expected)
            XCTAssertEqual(metadata.primariesAreBT709, expected == .bt709)
        }
        let p3 = try makeBuffer(bgr: (128, 128, 128), primaries: kCVImageBufferColorPrimaries_P3_D65)
        XCTAssertThrowsError(try HDRInputMetadata.resolve(pixelBuffer: p3, fallbackPolicy: .requireMetadata)) {
            XCTAssertEqual($0 as? HDRColorMetadataError, .unsupportedPrimaries)
        }
    }

    func testConversionMatricesKeepWhiteAndMapPrimariesIntoBT709() throws {
        for primaries in [HDRInputPrimaries.smpteC, .ebu3213] {
            let matrix = try XCTUnwrap(HDRColorMath.toBT709(primaries))
            let white = matrix * SIMD3<Float>(repeating: 1)
            for channel in 0..<3 { XCTAssertEqual(white[channel], 1, accuracy: 1e-6) }
        }
        XCTAssertNil(HDRColorMath.toBT709(.bt709))
        // SMPTE C red is less saturated than BT.709 red: it carries some green in BT.709.
        let red = try XCTUnwrap(HDRColorMath.toBT709(.smpteC)) * SIMD3<Float>(1, 0, 0)
        XCTAssertEqual(red.x, 0.9395421, accuracy: 1e-6)
        XCTAssertGreaterThan(red.y, 0.01)
    }

    func testGPUAppliesThePrimariesConversionLikeTheCPUReference() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var configuration = HDRConfiguration.natural
        configuration.highlightStrength = 0
        configuration.shadowProtection = 0
        let bgr: (UInt8, UInt8, UInt8) = (40, 90, 210)
        let signal = SIMD3<Float>(Float(bgr.2), Float(bgr.1), Float(bgr.0)) / 255
        var outputs: [HDRInputPrimaries: SIMD4<Float>] = [:]
        for (tag, primaries) in [(kCVImageBufferColorPrimaries_ITU_R_709_2, HDRInputPrimaries.bt709),
                                 (kCVImageBufferColorPrimaries_SMPTE_C, .smpteC)] {
            let processor = try HDRProcessor(device: device, configuration: configuration)
            let command = try processor.makeCommandBuffer()
            let frame = try processor.process(pixelBuffer: try makeBuffer(bgr: bgr, primaries: tag), commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            let gpu = try readFirstRGBA16FloatPixel(from: frame.texture, device: device)
            let cpu = HDRReference.process(signalRGB: signal, configuration: configuration, inputPrimaries: primaries)
            for channel in 0..<3 {
                XCTAssertEqual(gpu[channel], cpu[channel], accuracy: max(abs(cpu[channel]) * 0.01, 2e-3),
                               "\(primaries) channel \(channel)")
            }
            outputs[primaries] = gpu
        }
        let bt709 = try XCTUnwrap(outputs[.bt709]), smpteC = try XCTUnwrap(outputs[.smpteC])
        XCTAssertGreaterThan(abs(bt709.x - smpteC.x) + abs(bt709.y - smpteC.y) + abs(bt709.z - smpteC.z), 1e-3,
                             "SMPTE C input must not be treated as BT.709")
    }

    private func makeBuffer(bgr: (UInt8, UInt8, UInt8), primaries: CFString) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey as String: true,
                          kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, attributes, &result),
                       kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        for y in 0..<2 {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<2 {
                row[4 * x] = bgr.0
                row[4 * x + 1] = bgr.1
                row[4 * x + 2] = bgr.2
                row[4 * x + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }
}
