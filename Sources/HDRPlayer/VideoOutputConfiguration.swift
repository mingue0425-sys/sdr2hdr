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

/// The pixel-buffer contract shared by HDRPlayer playback and self-contained
/// media integration tests. Keeping this in HDRPlayerKit prevents a test-only
/// copy from drifting away when the production output format changes.
public enum HDRVideoOutputConfiguration {
    public static var pixelBufferAttributes: [String: any Sendable] {
        pixelBufferAttributes(for: .automatic)
    }

    public static func makeVideoOutput() -> AVPlayerItemVideoOutput {
        makeVideoOutput(precision: .automatic)
    }

    public static func pixelBufferAttributes(
        for precision: HDRDecodePrecision
    ) -> [String: any Sendable] {
        let pixelFormat: OSType = precision == .tenBitPreferred
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
        ]
    }

    public static func makeVideoOutput(
        precision: HDRDecodePrecision
    ) -> AVPlayerItemVideoOutput {
        AVPlayerItemVideoOutput(outputSettings: pixelBufferAttributes(for: precision))
    }
}
