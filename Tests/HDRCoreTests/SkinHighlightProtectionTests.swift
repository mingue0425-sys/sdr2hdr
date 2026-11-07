import CoreVideo
import Metal
import simd
import XCTest
@testable import HDRCore

final class SkinHighlightProtectionTests: XCTestCase {
    private func configuration(protection: Float) -> HDRConfiguration {
        var configuration = HDRConfiguration.calibratedV5
        configuration.skinHighlightProtection = protection
        return configuration
    }

    private func luminance(_ output: SIMD4<Float>) -> Float {
        simd_dot(simd_inverse(HDRColorMath.bt709ToBT2020) * SIMD3(output.x, output.y, output.z), HDRColorMath.bt709Luminance)
    }

    func testPresetsLeaveItOff() {
        for name in HDRPresetResolver.supportedPresetNames {
            XCTAssertEqual(HDRPresetResolver.configuration(for: name)?.skinHighlightProtection, 0, name)
        }
    }

    /// Bright toon-shaded skin (MMD) no longer reaches specular brightness,
    /// keeps its colour and shading order; nothing else changes.
    func testBrightSkinIsCompressedAndOtherHighlightsAreUntouched() {
        let off = configuration(protection: 0), on = configuration(protection: 1)
        let skinRamp: [SIMD3<Float>] = [
            SIMD3(225, 180, 160), SIMD3(240, 200, 180), SIMD3(250, 220, 205), SIMD3(255, 232, 220)
        ].map { $0 / 255 }
        var previous: Float = 0
        for skin in skinRamp {
            let before = HDRReference.process(signalRGB: skin, configuration: off)
            let after = HDRReference.process(signalRGB: skin, configuration: on)
            let y = luminance(after)
            XCTAssertLessThanOrEqual(y, luminance(before) + 1e-6)
            XCTAssertLessThan(y, 2.0, "skin \(skin) stays below 2x paper white")
            XCTAssertGreaterThan(y, previous, "skin shading keeps its order")
            previous = y
            // Same chromaticity: the protected value is a uniform scale of the
            // unprotected one before the highlight chroma step.
            let ratioBefore = SIMD3(before.x, before.y, before.z) / max(before.y, 1e-6)
            let ratioAfter = SIMD3(after.x, after.y, after.z) / max(after.y, 1e-6)
            XCTAssertLessThan(simd_length(ratioAfter - ratioBefore), 0.08, "skin \(skin) keeps its colour")
        }
        let lit = HDRReference.process(signalRGB: skinRamp[3], configuration: off)
        XCTAssertGreaterThan(luminance(lit), 4, "the fixture must exercise the problem")
        for untouched: SIMD3<Float> in [
            SIMD3(repeating: 1), SIMD3(255, 250, 245) / 255, SIMD3(255, 180, 100) / 255,
            SIMD3(200, 225, 255) / 255, SIMD3(repeating: 0.5), SIMD3(0.9, 0.2, 0.1)
        ] {
            XCTAssertEqual(HDRReference.process(signalRGB: untouched, configuration: on),
                           HDRReference.process(signalRGB: untouched, configuration: off), "\(untouched)")
        }
    }

    func testSkinWeightAndRollOff() {
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(255, 232, 220) / 255), 1, accuracy: 1e-6)
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(repeating: 1)), 0)
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(0.2, 0.5, 0.9)), 0, "cool colours are not skin")
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(255, 180, 100) / 255), 0, "saturated orange is not skin")
        let ceiling = HDRConfiguration.skinHighlightCeiling
        XCTAssertEqual(HDRReference.skinRolledLuminance(1.0, ceiling: ceiling), 1.0)
        var last = ceiling
        for y in stride(from: ceiling + 0.05, through: 8, by: 0.25) as StrideThrough<Float> {
            let rolled = HDRReference.skinRolledLuminance(y, ceiling: ceiling)
            XCTAssertGreaterThan(rolled, last)
            XCTAssertLessThan(rolled, y)
            last = rolled
        }
    }

    func testGPUMatchesTheCPUReference() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var configuration = HDRConfiguration.natural
        configuration.highlightStrength = 1
        configuration.peakNits = 1_400
        configuration.masteringHeadroom = 6.9
        configuration.shadowProtection = 0
        configuration.skinHighlightProtection = 1
        var unprotected = configuration
        unprotected.skinHighlightProtection = 0
        let lit = SIMD3<Float>(255, 232, 220) / 255
        XCTAssertLessThan(luminance(HDRReference.process(signalRGB: lit, configuration: configuration)),
                          luminance(HDRReference.process(signalRGB: lit, configuration: unprotected)) * 0.8,
                          "the GPU fixture must exercise the protection")
        for bgr: (UInt8, UInt8, UInt8) in [(220, 232, 255), (205, 220, 250), (255, 255, 255), (60, 120, 230)] {
            let signal = SIMD3<Float>(Float(bgr.2), Float(bgr.1), Float(bgr.0)) / 255
            let processor = try HDRProcessor(device: device, configuration: configuration)
            let command = try processor.makeCommandBuffer()
            let frame = try processor.process(pixelBuffer: try makeBuffer(bgr: bgr), commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            let gpu = try readFirstRGBA16FloatPixel(from: frame.texture, device: device)
            let cpu = HDRReference.process(signalRGB: signal, configuration: configuration)
            for channel in 0..<3 {
                XCTAssertEqual(gpu[channel], cpu[channel], accuracy: max(abs(cpu[channel]) * 0.01, 2e-3), "\(bgr) channel \(channel)")
            }
        }
    }

    private func makeBuffer(bgr: (UInt8, UInt8, UInt8)) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey as String: true,
                          kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, attributes, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        for y in 0..<2 {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<2 {
                row[4 * x] = bgr.0; row[4 * x + 1] = bgr.1; row[4 * x + 2] = bgr.2; row[4 * x + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }
}
