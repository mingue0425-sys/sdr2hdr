@preconcurrency import AVFoundation
import CoreVideo

public enum HDRDecodePrecision: String, CaseIterable, Codable, Equatable, Sendable {
    /// Inspects the source format description before the output is created.
    /// Callers that do not have an asset to inspect use the documented
    /// conservative NV12 fallback.
    case automatic
    case eightBit
    case tenBitPreferred
}

/// Selects the CoreVideo range requested from AVPlayerItemVideoOutput. The
/// established playback API remains video-range by default; the explicit
/// full-range case is used by the manifest-driven regression harness so a
/// full-range source is not silently normalized through an 8-bit video-range
/// request.
public enum HDRDecodeRange: String, CaseIterable, Codable, Equatable, Sendable {
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
        let resolved: HDRResolvedDecodePrecision = precision == .tenBitPreferred ? .tenBit : .eightBit
        return pixelBufferAttributes(forResolvedPrecision: resolved, range: range)
    }

    /// Creates output settings only from a resolved decision. Automatic
    /// source inspection belongs to `HDRDecodePrecisionResolver`; this API
    /// makes it impossible for an already-resolved ten-bit decision to be
    /// silently converted back to the automatic fallback.
    public static func pixelBufferAttributes(
        forResolvedPrecision resolvedPrecision: HDRResolvedDecodePrecision,
        range: HDRDecodeRange = .video
    ) -> [String: any Sendable] {
        let pixelFormat: OSType
        switch (resolvedPrecision, range) {
        case (.tenBit, .video):
            pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (.tenBit, .full):
            pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case (.eightBit, .video):
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case (.eightBit, .full):
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

    public static func makeVideoOutput(
        resolvedPrecision: HDRResolvedDecodePrecision,
        range: HDRDecodeRange = .video
    ) -> AVPlayerItemVideoOutput {
        AVPlayerItemVideoOutput(
            outputSettings: pixelBufferAttributes(
                forResolvedPrecision: resolvedPrecision,
                range: range
            )
        )
    }
}
