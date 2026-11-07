import CoreVideo
import Metal
import simd
import XCTest
@testable import HDRCore

final class YouTubeHLGLuminanceGainTests: XCTestCase {
    func testNeutralIsUnchangedAndColourKeepsChromaticityAtTheOOTFLuminance() {
        let grey = SIMD3<Float>(repeating: HDRColorMath.inverseYouTubeHLGDerived(0.5))
        let mappedGrey = HDRColorMath.youtubeHLGLuminanceGain(grey)
        for channel in 0..<3 { XCTAssertEqual(mappedGrey[channel], grey[channel], accuracy: 1e-6) }

        let signal = SIMD3<Float>(0.85, 0.35, 0.15)
        let perChannel = SIMD3<Float>(
            HDRColorMath.inverseYouTubeHLGDerived(signal.x),
            HDRColorMath.inverseYouTubeHLGDerived(signal.y),
            HDRColorMath.inverseYouTubeHLGDerived(signal.z)
        )
        let mapped = HDRColorMath.youtubeHLGLuminanceGain(perChannel)
        // Same chromaticity: a uniform scale of the per-channel result.
        let ratio = mapped.x / perChannel.x
        XCTAssertEqual(mapped.y / perChannel.y, ratio, accuracy: 1e-5)
        XCTAssertEqual(mapped.z / perChannel.z, ratio, accuracy: 1e-5)
        // Luminance of the BT.2100 luminance OOTF: Y(scene)^1.2.
        let scene = SIMD3<Float>(
            HDRColorMath.inverseHLGOETF(HDRColorMath.youtubeSDRToHLGCode(signal.x)),
            HDRColorMath.inverseHLGOETF(HDRColorMath.youtubeSDRToHLGCode(signal.y)),
            HDRColorMath.inverseHLGOETF(HDRColorMath.youtubeSDRToHLGCode(signal.z))
        )
        XCTAssertEqual(simd_dot(mapped, HDRColorMath.bt709Luminance),
                       pow(simd_dot(scene, HDRColorMath.bt709Luminance), 1.2), accuracy: 1e-5)
        // x^1.2 is convex, so per-channel 1.2 gamma over-brightens saturated colour
        // (sum w*E^1.2 >= (sum w*E)^1.2); the luminance OOTF pulls it back down.
        XCTAssertLessThan(ratio, 1)
        XCTAssertEqual(HDRSDRTransferInterpretation(cliName: "youtube-hlg-v2"), .youtubeHLGDerivedInverseLuminanceGain)
        XCTAssertEqual(HDRTransferFunction.bt709.interpreted(by: .youtubeHLGDerivedInverseLuminanceGain),
                       .youtubeHLGInverseLuminanceGain)
    }

    func testGPUMatchesTheCPUReferenceOnAColouredPixel() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var configuration = HDRConfiguration.natural
        configuration.highlightStrength = 0
        configuration.shadowProtection = 0
        configuration.sdrTransferInterpretation = .youtubeHLGDerivedInverseLuminanceGain
        let bgr: (UInt8, UInt8, UInt8) = (40, 90, 210)
        let signal = SIMD3<Float>(Float(bgr.2), Float(bgr.1), Float(bgr.0)) / 255
        let processor = try HDRProcessor(device: device, configuration: configuration)
        let command = try processor.makeCommandBuffer()
        let frame = try processor.process(pixelBuffer: try makeBuffer(bgr: bgr), commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let gpu = try readFirstRGBA16FloatPixel(from: frame.texture, device: device)
        let cpu = HDRReference.process(signalRGB: signal, configuration: configuration)
        var v1 = configuration
        v1.sdrTransferInterpretation = .youtubeHLGDerivedInverse
        let cpuV1 = HDRReference.process(signalRGB: signal, configuration: v1)
        for channel in 0..<3 {
            XCTAssertEqual(gpu[channel], cpu[channel], accuracy: max(abs(cpu[channel]) * 0.01, 2e-3), "channel \(channel)")
        }
        XCTAssertGreaterThan(abs(cpu.x - cpuV1.x) + abs(cpu.y - cpuV1.y) + abs(cpu.z - cpuV1.z), 1e-3)
    }

    private func makeBuffer(bgr: (UInt8, UInt8, UInt8)) throws -> CVPixelBuffer {
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
                row[4 * x] = bgr.0; row[4 * x + 1] = bgr.1; row[4 * x + 2] = bgr.2; row[4 * x + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }
}
