import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Still images (JPEG, PNG, HEIC, TIFF, WebP, ...) as engine input.
///
/// The image is decoded once with ImageIO, its EXIF orientation applied,
/// scaled so its longer side is at most `maxPixelSize`, and drawn into an
/// sRGB BGRA pixel buffer tagged BT.709 primaries with the sRGB transfer.
/// HDRProcessor then treats it exactly like one video frame. Colours outside
/// sRGB (Display P3 photos) are converted into sRGB by Core Graphics, because
/// the engine accepts only BT.709-family primaries. Transparent areas are
/// composited over black, the player's background.
public enum StillImageSource {
    public static let defaultMaxPixelSize = 4096

    public enum LoadError: LocalizedError, Equatable {
        case unreadable(String)
        case pixelBufferUnavailable

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "\(name)을(를) 이미지로 읽을 수 없습니다."
            case .pixelBufferUnavailable: return "이미지를 담을 픽셀 버퍼를 만들 수 없습니다."
            }
        }
    }

    /// True when the file's type, from its extension, is an image.
    public static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    /// Decodes off the main actor. The buffer is created here and handed
    /// over once, never shared while being written.
    public static func loadInBackground(_ url: URL, maxPixelSize: Int = defaultMaxPixelSize) async throws -> CVPixelBuffer {
        struct Handoff: @unchecked Sendable { let buffer: CVPixelBuffer }
        let handoff = try await Task.detached(priority: .userInitiated) {
            Handoff(buffer: try load(url, maxPixelSize: maxPixelSize))
        }.value
        return handoff.buffer
    }

    public static func load(_ url: URL, maxPixelSize: Int = defaultMaxPixelSize) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw LoadError.unreadable(url.lastPathComponent)
        }
        // The thumbnail API applies the EXIF orientation and downsamples in
        // one decode; "always" makes it decode the full image, not an
        // embedded preview.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LoadError.unreadable(url.lastPathComponent)
        }
        return try pixelBuffer(from: image)
    }

    public static func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        let width = image.width, height = image.height
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &created) == kCVReturnSuccess,
              let buffer = created,
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LoadError.pixelBufferUnavailable
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw LoadError.pixelBufferUnavailable
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        return buffer
    }
}
