import Metal
import XCTest
@testable import HDRPlayerKit

final class PresentationUpscalerTests: XCTestCase {
    func testOutputSizesNeverExceedTheScreenAndSkipUselessUpscales() {
        let input = CGSize(width: 1920, height: 1080)
        XCTAssertNil(HDRUpscaleMode.off.outputSize(input: input, target: CGSize(width: 3840, height: 2160)))
        XCTAssertEqual(HDRUpscaleMode.x2.outputSize(input: input, target: CGSize(width: 3840, height: 2160)),
                       CGSize(width: 3840, height: 2160))
        XCTAssertEqual(HDRUpscaleMode.x1_5.outputSize(input: input, target: CGSize(width: 3840, height: 2160)),
                       CGSize(width: 2880, height: 1620))
        // 2x on a 2560-wide window is capped at the window.
        let capped = HDRUpscaleMode.x2.outputSize(input: input, target: CGSize(width: 2560, height: 1440))
        XCTAssertEqual(capped, CGSize(width: 2560, height: 1440))
        // Auto follows the screen size, quantised to 32 px.
        let auto = HDRUpscaleMode.auto.outputSize(input: input, target: CGSize(width: 3000, height: 1700))
        XCTAssertEqual(auto, CGSize(width: 2976, height: 1664))
        // A window no larger than the video: nothing to add.
        XCTAssertNil(HDRUpscaleMode.auto.outputSize(input: input, target: CGSize(width: 1920, height: 1080)))
        XCTAssertNil(HDRUpscaleMode.x2.outputSize(input: input, target: CGSize(width: 1280, height: 720)))
        XCTAssertEqual(HDRUpscaleMode(cliName: "1.5X"), .x1_5)
        XCTAssertEqual(HDRUpscaleMode(cliName: "auto"), .auto)
    }

    /// MetalFX upscaling of a flat EDR field keeps its HDR value (above 1) and
    /// the presentation path still maps it like the bilinear path.
    func testMetalFXUpscaleKeepsEDRValues() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        guard PresentationUpscaler.isSupported(on: device) else { throw XCTSkip("MetalFX spatial scaling unsupported") }
        let renderer = try HDRPresentationRenderer(device: device)
        let source = try texture(device, width: 64, height: 36, usage: [.shaderRead, .shaderWrite])
        var pixels = [Float16](repeating: 0, count: 64 * 36 * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 2.0; pixels[index + 1] = 1.0; pixels[index + 2] = 0.5; pixels[index + 3] = 1
        }
        source.replace(region: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 64 * 8)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var centres: [HDRUpscaleMode: [Float]] = [:]
        for mode in [HDRUpscaleMode.off, .x2] {
            renderer.upscaleMode = mode
            let target = try texture(device, width: 128, height: 72, usage: [.renderTarget, .shaderRead])
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(renderer.encodeOffscreen(
                texture: source, to: target, commandBuffer: command,
                sourceSize: CGSize(width: 64, height: 36), drawableSize: CGSize(width: 128, height: 72),
                orientation: .identity, fallbackToSDR: false, masteringHeadroom: 5, displayHeadroom: 4))
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            var output = [Float16](repeating: 0, count: 4)
            target.getBytes(&output, bytesPerRow: 8, from: MTLRegionMake2D(64, 36, 1, 1), mipmapLevel: 0)
            centres[mode] = output.prefix(3).map(Float.init)
            if mode == .x2 {
                XCTAssertTrue(renderer.upscaleDescription.contains("MetalFX spatial 64x36 to 128x72"), renderer.upscaleDescription)
            }
        }
        let plain = try XCTUnwrap(centres[.off]), upscaled = try XCTUnwrap(centres[.x2])
        XCTAssertGreaterThan(plain[0], 1, "the fixture must exercise EDR values")
        for channel in 0..<3 {
            XCTAssertEqual(upscaled[channel], plain[channel], accuracy: plain[channel] * 0.02, "channel \(channel)")
        }
    }

    /// On a hard edge, MetalFX is no blurrier than bilinear presentation.
    func testMetalFXEdgeIsAtLeastAsSharpAsBilinear() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        guard PresentationUpscaler.isSupported(on: device) else { throw XCTSkip("MetalFX spatial scaling unsupported") }
        let renderer = try HDRPresentationRenderer(device: device)
        let source = try texture(device, width: 64, height: 36, usage: [.shaderRead, .shaderWrite])
        var pixels = [Float16](repeating: 1, count: 64 * 36 * 4)
        for y in 0..<36 {
            for x in 0..<64 {
                let value: Float16 = x < 32 ? 0.2 : 2.0
                let index = (y * 64 + x) * 4
                pixels[index] = value; pixels[index + 1] = value; pixels[index + 2] = value
            }
        }
        source.replace(region: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 64 * 8)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var widths: [HDRUpscaleMode: Int] = [:]
        var overshoots: [HDRUpscaleMode: Float] = [:], undershoots: [HDRUpscaleMode: Float] = [:]
        for mode in [HDRUpscaleMode.off, .x2] {
            renderer.upscaleMode = mode
            let target = try texture(device, width: 256, height: 144, usage: [.renderTarget, .shaderRead])
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(renderer.encodeOffscreen(
                texture: source, to: target, commandBuffer: command,
                sourceSize: CGSize(width: 64, height: 36), drawableSize: CGSize(width: 256, height: 144),
                orientation: .identity, fallbackToSDR: false, masteringHeadroom: 5, displayHeadroom: 4))
            command.commit()
            command.waitUntilCompleted()
            var row = [Float16](repeating: 0, count: 256 * 4)
            target.getBytes(&row, bytesPerRow: 256 * 8, from: MTLRegionMake2D(0, 72, 256, 1), mipmapLevel: 0)
            let luma = stride(from: 0, to: row.count, by: 4).map { Float(row[$0]) }
            let low = luma[20], high = luma[236]
            let lo = low + (high - low) * 0.1, hi = low + (high - low) * 0.9
            widths[mode] = luma.filter { $0 > lo && $0 < hi }.count
            overshoots[mode] = ((luma.max() ?? high) - high) / (high - low)
            undershoots[mode] = (low - (luma.min() ?? low)) / (high - low)
        }
        print("edge overshoot/undershoot: bilinear \(overshoots[.off]!)/\(undershoots[.off]!), MetalFX \(overshoots[.x2]!)/\(undershoots[.x2]!)")
        // Halos are visible in HDR; keep them small.
        XCTAssertLessThan(overshoots[.x2]!, 0.05)
        XCTAssertLessThan(undershoots[.x2]!, 0.05)
        let bilinear = try XCTUnwrap(widths[.off]), metalFX = try XCTUnwrap(widths[.x2])
        print("edge 10-90% width at 4x display: bilinear \(bilinear) px, MetalFX 2x \(metalFX) px")
        XCTAssertLessThanOrEqual(metalFX, bilinear)
    }

    private func texture(_ device: MTLDevice, width: Int, height: Int, usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = usage
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }
}
