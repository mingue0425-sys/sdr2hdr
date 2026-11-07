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

    /// The YouTube HLG-derived decode renders skin more saturated, so its
    /// skin settles lower than with the BT.709 decode; white is unaffected.
    func testYouTubeDecodeHoldsSkinLower() {
        var youtube = configuration(protection: 1)
        youtube.sdrTransferInterpretation = .youtubeHLGDerivedInverseLuminanceGain
        var youtubeOff = youtube
        youtubeOff.skinHighlightProtection = 0
        XCTAssertEqual(HDRConfiguration.skinHighlightCeiling(for: .youtubeHLGInverseLuminanceGain),
                       HDRConfiguration.youtubeSkinHighlightCeiling)
        XCTAssertEqual(HDRConfiguration.skinHighlightCeiling(for: .bt709), HDRConfiguration.skinHighlightCeiling)
        for skin: SIMD3<Float> in [SIMD3(255, 232, 220) / 255, SIMD3(255, 238, 238) / 255, SIMD3(252, 244, 200) / 255] {
            let y = luminance(HDRReference.process(signalRGB: skin, configuration: youtube))
            XCTAssertLessThan(y, HDRConfiguration.youtubeSkinHighlightCeiling + 0.2, "\(skin)")
            XCTAssertLessThan(y, luminance(HDRReference.process(signalRGB: skin, configuration: configuration(protection: 1))), "\(skin)")
        }
        XCTAssertEqual(HDRReference.process(signalRGB: SIMD3(repeating: 1), configuration: youtube),
                       HDRReference.process(signalRGB: SIMD3(repeating: 1), configuration: youtubeOff))
    }

    /// Bright toon-shaded skin (MMD) no longer reaches specular brightness,
    /// keeps its colour and shading order; nothing else changes.
    func testBrightSkinIsCompressedAndOtherHighlightsAreUntouched() {
        let off = configuration(protection: 0), on = configuration(protection: 1)
        let skinRamp: [SIMD3<Float>] = [
            SIMD3(225, 180, 160), SIMD3(240, 200, 180), SIMD3(250, 220, 205), SIMD3(255, 232, 220)
        ].map { $0 / 255 }
        // Pale pink toon skin, which colour-only detection missed.
        for pale: SIMD3<Float> in [SIMD3(255, 238, 238) / 255, SIMD3(250, 230, 232) / 255, SIMD3(255, 245, 240) / 255] {
            XCTAssertLessThan(luminance(HDRReference.process(signalRGB: pale, configuration: on)), 1.15, "\(pale)")
            XCTAssertGreaterThan(luminance(HDRReference.process(signalRGB: pale, configuration: off)), 4.0, "\(pale)")
        }
        var previous: Float = 0
        for skin in skinRamp {
            let before = HDRReference.process(signalRGB: skin, configuration: off)
            let after = HDRReference.process(signalRGB: skin, configuration: on)
            let y = luminance(after)
            XCTAssertLessThanOrEqual(y, luminance(before) + 1e-6)
            XCTAssertLessThan(y, 1.15, "skin \(skin) stays at about SDR white")
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
            SIMD3(repeating: 1), SIMD3(255, 180, 100) / 255,
            SIMD3(200, 225, 255) / 255, SIMD3(repeating: 0.5), SIMD3(0.9, 0.2, 0.1)
        ] {
            XCTAssertEqual(HDRReference.process(signalRGB: untouched, configuration: on),
                           HDRReference.process(signalRGB: untouched, configuration: off), "\(untouched)")
        }
        // A small specular (darker surroundings) keeps its expansion even in skin colours.
        let speculars: [SIMD3<Float>] = skinRamp + [SIMD3<Float>(255, 238, 238) / 255]
        for specular in speculars {
            XCTAssertEqual(HDRReference.process(signalRGB: specular, configuration: on, skinRegion: SIMD2(0.05, 0)),
                           HDRReference.process(signalRGB: specular, configuration: off), "\(specular)")
        }
    }

    func testSkinWeightAndRollOff() {
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(255, 232, 220) / 255), 1, accuracy: 1e-6)
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(repeating: 1)), 0)
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(0.2, 0.5, 0.9)), 0, "cool colours are not skin")
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(255, 180, 100) / 255), 0, "saturated orange is not skin")
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(255, 238, 238) / 255), 1, accuracy: 1e-6, "pale pink skin")
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(252, 244, 200) / 255), 1, accuracy: 1e-6, "cream-lit skin (MMD)")
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(255, 255, 0) / 255), 0, "saturated yellow is not skin")
        // MMD close-up forehead: green a hair above red, flipping with noise.
        for cream: SIMD3<Float> in [SIMD3(246, 252, 218) / 255, SIMD3(249, 250, 211) / 255, SIMD3(243, 251, 219) / 255] {
            XCTAssertGreaterThan(HDRReference.skinHighlightWeight(cream), 0.9, "pale cream with green above red \(cream * 255)")
        }
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(200, 255, 100) / 255), 0, "vivid yellow-green is not skin")
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(225, 255, 200) / 255), 0, "pale green is not skin")
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(180, 255, 180) / 255), 0, "green is not skin")
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(255, 253, 253) / 255), 0, "near-neutral white")
        XCTAssertEqual(HDRReference.skinHighlightWeight(SIMD3(0.9, 0.4, 0.9)), 0, "magenta is not skin")
        let ceiling = HDRConfiguration.skinHighlightCeiling
        XCTAssertEqual(HDRReference.skinRolledLuminance(ceiling - 0.1, ceiling: ceiling), ceiling - 0.1)
        var last = ceiling
        for y in stride(from: ceiling + 0.05, through: 8, by: 0.25) as StrideThrough<Float> {
            let rolled = HDRReference.skinRolledLuminance(y, ceiling: ceiling)
            XCTAssertGreaterThan(rolled, last)
            XCTAssertLessThan(rolled, y)
            XCTAssertLessThan(rolled, 1.15, "skin settles at about SDR white even from \(y)")
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
        for decode: HDRSDRTransferInterpretation in [.bt709InverseOETFSceneLinear, .youtubeHLGDerivedInverseLuminanceGain] {
        configuration.sdrTransferInterpretation = decode
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
                XCTAssertEqual(gpu[channel], cpu[channel], accuracy: max(abs(cpu[channel]) * 0.01, 2e-3), "\(decode) \(bgr) channel \(channel)")
            }
        }
        }
    }

    /// On a real frame, a broad pale skin area is compressed while a small dot
    /// of the same colour on darker skin (an eye highlight or glint) keeps
    /// its expansion.
    func testGPUCompressesBroadSkinButNotSmallSpeculars() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let width = 320, height = 180
        var configuration = HDRConfiguration.calibratedV5
        configuration.toneCurveRevision = .legacyV2
        configuration.skinHighlightProtection = 1
        var result: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey as String: true,
                          kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        for y in 0..<height {
            let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                // Left half: broad pale skin. Right half: darker skin with a 3x3 glint at (240, 90).
                let broad = x < 160
                let glint = abs(x - 240) <= 1 && abs(y - 90) <= 1
                // White 3x3 spots: a toon highlight inside the broad skin, and a glint on the darker skin.
                let toonHighlight = abs(x - 80) <= 1 && abs(y - 40) <= 1
                let whiteGlint = abs(x - 240) <= 1 && abs(y - 40) <= 1
                let rgb: (UInt8, UInt8, UInt8) = toonHighlight || whiteGlint ? (255, 255, 255)
                    : broad || glint ? (255, 238, 238) : (190, 140, 130)
                row[4 * x] = rgb.2; row[4 * x + 1] = rgb.1; row[4 * x + 2] = rgb.0; row[4 * x + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let processor = try HDRProcessor(device: device, configuration: configuration)
        let command = try processor.makeCommandBuffer()
        let frame = try processor.process(pixelBuffer: buffer, commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let pixels = try readRGBA16Float(frame.texture, device: device)
        func y(_ x: Int, _ yy: Int) -> Float {
            let i = (yy * width + x) * 4
            return luminance(SIMD4(pixels[i], pixels[i + 1], pixels[i + 2], 1))
        }
        let broadSkin = y(80, 90), glint = y(240, 90)
        let unprotected = luminance(HDRReference.process(signalRGB: SIMD3(255, 238, 238) / 255, configuration: {
            var c = configuration; c.skinHighlightProtection = 0; return c }()))
        XCTAssertLessThan(broadSkin, 1.15, "broad skin no longer glows")
        XCTAssertEqual(glint, unprotected, accuracy: unprotected * 0.02, "the glint keeps its full expansion")
        XCTAssertGreaterThan(glint, broadSkin * 2)
        let white = luminance(HDRReference.process(signalRGB: SIMD3(repeating: 1), configuration: configuration))
        XCTAssertLessThan(y(80, 40), 1.15, "a white toon highlight inside bright skin is part of the skin")
        XCTAssertEqual(y(240, 40), white, accuracy: white * 0.02, "a white glint on darker skin keeps its expansion")
    }

    private func readRGBA16Float(_ texture: MTLTexture, device: MTLDevice) throws -> [Float] {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: texture.width, height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        let shared = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: texture, to: shared)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        var halves = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        shared.getBytes(&halves, bytesPerRow: texture.width * 8, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return halves.map(Float.init)
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
