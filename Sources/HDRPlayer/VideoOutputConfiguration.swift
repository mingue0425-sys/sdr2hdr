@preconcurrency import AVFoundation
import CoreVideo

/// The pixel-buffer contract shared by HDRPlayer playback and self-contained
/// media integration tests. Keeping this in HDRPlayerKit prevents a test-only
/// copy from drifting away when the production output format changes.
public enum HDRVideoOutputConfiguration {
    public static var pixelBufferAttributes: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
        ]
    }

    public static func makeVideoOutput() -> AVPlayerItemVideoOutput {
        AVPlayerItemVideoOutput(outputSettings: pixelBufferAttributes)
    }
}
