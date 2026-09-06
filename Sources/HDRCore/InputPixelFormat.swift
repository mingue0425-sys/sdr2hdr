import CoreVideo

/// Pixel formats accepted by the zero-copy HDRCore input path.
///
/// The format is kept separate from the shader pipeline choice so every
/// consumer (metadata resolution, texture creation, diagnostics, and the
/// temporal estimator) makes the same bit-depth/range decision.
internal enum HDRInputPixelFormat: Equatable, Sendable {
    case nv12VideoRange
    case nv12FullRange
    case p010VideoRange
    case p010FullRange
    case bgra8

    init?(coreVideoFormat: OSType) {
        switch coreVideoFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            self = .nv12VideoRange
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            self = .nv12FullRange
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            self = .p010VideoRange
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            self = .p010FullRange
        case kCVPixelFormatType_32BGRA:
            self = .bgra8
        default:
            return nil
        }
    }

    var isYUV: Bool {
        switch self {
        case .nv12VideoRange, .nv12FullRange, .p010VideoRange, .p010FullRange:
            return true
        case .bgra8:
            return false
        }
    }

    var isP010: Bool {
        switch self {
        case .p010VideoRange, .p010FullRange:
            return true
        case .nv12VideoRange, .nv12FullRange, .bgra8:
            return false
        }
    }

    var bitDepth: Int {
        isP010 ? 10 : 8
    }

    var isFullRange: Bool {
        switch self {
        case .nv12FullRange, .p010FullRange:
            return true
        case .nv12VideoRange, .p010VideoRange, .bgra8:
            return false
        }
    }

    var diagnosticName: String {
        switch self {
        case .nv12VideoRange: return "NV12 8-bit video-range"
        case .nv12FullRange: return "NV12 8-bit full-range"
        case .p010VideoRange: return "P010 10-bit video-range"
        case .p010FullRange: return "P010 10-bit full-range"
        case .bgra8: return "BGRA 8-bit"
        }
    }

    var diagnosticRangeName: String {
        isYUV ? (isFullRange ? "full" : "video") : "rgb"
    }
}
