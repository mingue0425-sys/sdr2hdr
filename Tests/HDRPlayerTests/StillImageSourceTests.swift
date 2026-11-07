import CoreGraphics
import CoreVideo
import Foundation
import HDRCore
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import HDRPlayerKit

final class StillImageSourceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-still-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A width×height sRGB image: left half `left`, right half `right` (RGBA 0...255).
    private func makeImage(width: Int, height: Int, left: [UInt8], right: [UInt8]) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let colour = x < width / 2 ? left : right
                let a = Int(colour[3])
                for c in 0..<3 { bytes[(y * width + x) * 4 + c] = UInt8(Int(colour[c]) * a / 255) }
                bytes[(y * width + x) * 4 + 3] = colour[3]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
    }

    private func write(_ image: CGImage, name: String, type: UTType, orientation: Int? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// BGRA bytes at (x, y).
    private func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let row = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: UInt8.self)
        return (row[x * 4], row[x * 4 + 1], row[x * 4 + 2])
    }

    func testImageTypesAreRecognizedByExtension() {
        for name in ["a.jpg", "a.JPEG", "a.png", "a.heic", "a.tiff", "a.webp", "a.gif"] {
            XCTAssertTrue(StillImageSource.isImage(URL(fileURLWithPath: name)), name)
        }
        for name in ["a.mp4", "a.mov", "a.webm", "a.mkv", "a.txt", "a"] {
            XCTAssertFalse(StillImageSource.isImage(URL(fileURLWithPath: name)), name)
        }
    }

    func testLoadedImageIsAnSRGBTaggedBGRABuffer() throws {
        let url = try write(makeImage(width: 64, height: 32, left: [255, 0, 0, 255], right: [0, 0, 255, 255]),
                            name: "halves.png", type: .png)
        let buffer = try StillImageSource.load(url)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 32)
        XCTAssertNotNil(CVPixelBufferGetIOSurface(buffer), "Metal needs an IOSurface-backed buffer")
        XCTAssertEqual(CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String,
                       kCVImageBufferTransferFunction_sRGB as String)
        XCTAssertEqual(CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String,
                       kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        let left = pixel(buffer, 4, 16), right = pixel(buffer, 60, 16)
        XCTAssertEqual([left.r, left.g, left.b], [255, 0, 0])
        XCTAssertEqual([right.r, right.g, right.b], [0, 0, 255])
    }

    func testEXIFOrientationIsAppliedAndLargeImagesAreDownscaled() throws {
        // Orientation 6: the stored 64x32 image is shown rotated 90° clockwise, 32x64.
        let rotated = try write(makeImage(width: 64, height: 32, left: [255, 0, 0, 255], right: [0, 255, 0, 255]),
                                name: "rotated.jpg", type: .jpeg, orientation: 6)
        let buffer = try StillImageSource.load(rotated)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 32)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 64)
        // Rotated clockwise, the stored left (red) half ends up on top.
        XCTAssertGreaterThan(pixel(buffer, 16, 8).r, 200)
        XCTAssertGreaterThan(pixel(buffer, 16, 56).g, 200)

        let large = try write(makeImage(width: 400, height: 200, left: [255, 255, 255, 255], right: [0, 0, 0, 255]),
                              name: "large.png", type: .png)
        let scaled = try StillImageSource.load(large, maxPixelSize: 100)
        XCTAssertEqual(CVPixelBufferGetWidth(scaled), 100)
        XCTAssertEqual(CVPixelBufferGetHeight(scaled), 50)
    }

    func testTransparencyIsCompositedOverBlack() throws {
        let url = try write(makeImage(width: 32, height: 16, left: [255, 255, 255, 0], right: [255, 255, 255, 128]),
                            name: "alpha.png", type: .png)
        let buffer = try StillImageSource.load(url)
        let clear = pixel(buffer, 4, 8), half = pixel(buffer, 28, 8)
        XCTAssertEqual([clear.r, clear.g, clear.b], [0, 0, 0])
        XCTAssertEqual(Int(half.g), 128, accuracy: 2)
    }

    func testUnreadableFileThrows() throws {
        let url = root.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try StillImageSource.load(url)) { error in
            XCTAssertEqual(error as? StillImageSource.LoadError, .unreadable("broken.png"))
        }
    }

    /// The engine expands the image like a video frame: white gains HDR
    /// headroom, mid grey stays near its SDR level.
    func testEngineProcessesTheImage() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let url = try write(makeImage(width: 64, height: 32, left: [255, 255, 255, 255], right: [128, 128, 128, 255]),
                            name: "grey.png", type: .png)
        let buffer = try StillImageSource.load(url)
        var options = PlayerOptions()
        options.preset = "calibrated-v5"
        let processor = try HDRProcessor(device: device, configuration: options.baseConfiguration())
        let command = try processor.makeCommandBuffer()
        let frame = try processor.process(pixelBuffer: buffer, commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 32, mipmapped: false)
        descriptor.storageMode = .shared
        let shared = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let copy = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let blit = try XCTUnwrap(copy.makeBlitCommandEncoder())
        blit.copy(from: frame.texture, to: shared)
        blit.endEncoding()
        copy.commit()
        copy.waitUntilCompleted()
        var pixels = [Float16](repeating: 0, count: 64 * 32 * 4)
        shared.getBytes(&pixels, bytesPerRow: 64 * 8, from: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0)
        let white = Float(pixels[(16 * 64 + 4) * 4 + 1]), grey = Float(pixels[(16 * 64 + 60) * 4 + 1])
        XCTAssertGreaterThan(white, 2, "white gains HDR headroom")
        XCTAssertEqual(grey, 0.216, accuracy: 0.12, "sRGB 128 decodes near linear 0.22")
    }

    @MainActor
    func testControllerShowsAnImageWithoutPlayback() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let url = try write(makeImage(width: 80, height: 40, left: [200, 150, 120, 255], right: [20, 20, 20, 255]),
                            name: "photo.jpg", type: .jpeg)
        var options = PlayerOptions()
        options.preset = "calibrated-v5"
        let controller = try await PlaybackController.make(url: url, configuration: options.baseConfiguration(), device: device)
        XCTAssertTrue(controller.isStillImage)
        XCTAssertFalse(controller.isTestPattern)
        var ready: PlaybackVideoInfo?
        controller.onReady = { ready = $0 }
        controller.prepare()
        XCTAssertEqual(ready?.displaySize, CGSize(width: 80, height: 40))
        XCTAssertNil(ready?.durationSeconds)
        controller.togglePlayPause()
        XCTAssertFalse(controller.isPlaying, "an image never starts the player")
    }

    func testConverterLeavesImagesToTheEngine() async throws {
        let url = try write(makeImage(width: 8, height: 8, left: [1, 2, 3, 255], right: [4, 5, 6, 255]),
                            name: "x.png", type: .png)
        let converter = try XCTUnwrap(PlayableInputConverter(cacheDirectory: root.appendingPathComponent("cache")))
        let outcome = try await converter.prepare(url)
        XCTAssertNil(outcome.url)
    }
}
