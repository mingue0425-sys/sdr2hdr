@preconcurrency import AVFoundation
import CoreVideo

public enum HDRDecodePrecision: String, CaseIterable, Equatable, Sendable {
    /// Keeps the established 8-bit NV12 contract. This is the conservative
    /// default because AVPlayerItemVideoOutput cannot probe source bit depth
    /// after its output settings have been created.
    case automatic
    case eightBit
    case tenBitPreferred
}

/// Selects the CoreVideo range requested from AVPlayerItemVideoOutput. The
/// established playback API remains video-range by default; the explicit
/// full-range case is used by the manifest-driven regression harness so a
/// full-range source is not silently normalized through an 8-bit video-range
/// request.
public enum HDRDecodeRange: String, CaseIterable, Equatable, Sendable {
    case video
    case full
}

/// The pixel-buffer contract shared by HDRPlayer playback and self-contained
/// media integration tests. Keeping this in HDRPlayerKit prevents a test-only
/// copy from drifting away when the production output format changes.
public enum HDRVideoOutputConfiguration {
    public static var pixelBufferAttributes: [String: any Sendable] {
        pixelBufferAttributes(for: .automatic, range: .video)
    }

    public static func makeVideoOutput() -> AVPlayerItemVideoOutput {
        makeVideoOutput(precision: .automatic, range: .video)
    }

    public static func pixelBufferAttributes(
        for precision: HDRDecodePrecision,
        range: HDRDecodeRange = .video
    ) -> [String: any Sendable] {
        let pixelFormat: OSType
        switch (precision, range) {
        case (.tenBitPreferred, .video):
            pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (.tenBitPreferred, .full):
            pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case (_, .video):
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case (_, .full):
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        return [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
        ]
    }

    public static func makeVideoOutput(
        precision: HDRDecodePrecision,
        range: HDRDecodeRange = .video
    ) -> AVPlayerItemVideoOutput {
        AVPlayerItemVideoOutput(outputSettings: pixelBufferAttributes(for: precision, range: range))
    }
}
