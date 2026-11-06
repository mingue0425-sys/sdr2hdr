import CoreVideo
import Foundation
import simd

public enum HDRTransferFunction: Equatable, Sendable {
    /// Inverse BT.709 camera OETF (scene-linear convention).
    case bt709
    case sRGB
    case gamma(Float)
    case linear
    /// BT.1886 display EOTF with a zero black level (pure 2.4 power law).
    /// CoreVideo has no distinct tag for it; the metadata resolver never
    /// produces this value. It is selected only by
    /// `HDRSDRTransferInterpretation.bt1886DisplayReferred` for BT.709-tagged
    /// input.
    case bt1886
    /// Inverse BT.709 OETF below code 0.10, BT.1886 (Lb = 0) above 0.70, and
    /// a smoothstep mix in between. Shadows decode exactly as the historical
    /// convention; midtones move toward what a BT.1886 reference display shows.
    /// Selected only by `HDRSDRTransferInterpretation.bt709ToeBT1886MidBlend`.
    case bt709ToeBT1886Blend
    /// Inverse of YouTube's automatic SDR rendition of an HLG upload: the SDR
    /// code is mapped through a fitted 17-knot SDR→HLG code curve, then
    /// decoded with the BT.2100 HLG inverse OETF and a per-channel 1.2 system
    /// gamma, normalized so SDR code 1.0 is 1.0. Selected only by
    /// `HDRSDRTransferInterpretation.youtubeHLGDerivedInverse`.
    case youtubeHLGInverse

    /// Applies an SDR interpretation policy to a resolved transfer tag. Only
    /// the BT.709/BT.2020 SDR tag is ambiguous between scene-linear and
    /// display-referred decoding; sRGB, explicit gamma and linear tags are
    /// unambiguous and are never rewritten.
    public func interpreted(by policy: HDRSDRTransferInterpretation) -> HDRTransferFunction {
        switch (self, policy) {
        case (.bt709, .bt1886DisplayReferred):
            return .bt1886
        case (.bt709, .bt709ToeBT1886MidBlend):
            return .bt709ToeBT1886Blend
        case (.bt709, .youtubeHLGDerivedInverse):
            return .youtubeHLGInverse
        default:
            return self
        }
    }
}

/// Versioned policy for linearizing BT.709-tagged SDR input.
///
/// The raw values are stable identifiers intended for reports, manifests and
/// calibration records. A new convention must add a new case with a new
/// identifier; an existing identifier must never change meaning.
public enum HDRSDRTransferInterpretation: String, CaseIterable, Codable, Sendable {
    /// Historical behavior: inverse BT.709 camera OETF. Every shipped and
    /// calibrated preset was produced under this convention.
    case bt709InverseOETFSceneLinear = "bt709-inverse-oetf-scene-linear-v1"

    /// Display-referred decoding through the BT.1886 reference EOTF with
    /// Lb = 0 (L = V^2.4, normalized to reference white). This reproduces the
    /// SDR picture as seen on a reference display. No calibrated preset uses
    /// it yet; selecting it requires a separate calibration rebase.
    case bt1886DisplayReferred = "bt1886-display-eotf-gamma2.4-lb0-v1"

    /// Historical inverse OETF in shadows (code < 0.10, so no new black
    /// crush), blending to the BT.1886 display EOTF by code 0.70. The blend
    /// range keeps the minimum slope at 73% of the inverse OETF's.
    case bt709ToeBT1886MidBlend = "bt709-toe-bt1886-mid-blend-0.10-0.70-v1"

    /// Source-declared policy for SDR that YouTube derived automatically from
    /// an HLG upload. The SDR→HLG code curve was fitted on the open-content-v2
    /// Tune broadcast pairs only (`dataset/analysis/youtube-hlg-curve-v1.json`).
    /// It is meant to be selected by a user who knows the source, not inferred.
    case youtubeHLGDerivedInverse = "youtube-hlg-sdr-inverse-17knot-v1"

    /// The default intentionally preserves historical output.
    public static let `default`: HDRSDRTransferInterpretation = .bt709InverseOETFSceneLinear

    /// Short command-line spelling.
    public var cliName: String {
        switch self {
        case .bt709InverseOETFSceneLinear: return "bt709-oetf"
        case .bt1886DisplayReferred: return "bt1886"
        case .bt709ToeBT1886MidBlend: return "bt709-1886-blend"
        case .youtubeHLGDerivedInverse: return "youtube-hlg"
        }
    }

    public init?(cliName: String) {
        guard let match = Self.allCases.first(where: {
            $0.cliName == cliName.lowercased() || $0.rawValue == cliName
        }) else { return nil }
        self = match
    }
}

public enum HDRYCbCrMatrix: String, Sendable {
    case bt709
    case bt601
    case bt2020
}

public enum HDRColorMetadataError: Error, LocalizedError, Equatable, Sendable {
    case missingMetadata
    case incompleteMetadata
    case unsupportedPrimaries
    case unsupportedTransferFunction
    case unsupportedMatrix
    case invalidGamma

    public var errorDescription: String? {
        switch self {
        case .missingMetadata:
            return "Input CVPixelBuffer has no color metadata and the fallback policy requires it"
        case .incompleteMetadata:
            return "Input CVPixelBuffer has incomplete color metadata; refusing to guess"
        case .unsupportedPrimaries:
            return "Only BT.709 SDR RGB primaries are supported by this core"
        case .unsupportedTransferFunction:
            return "Input transfer function is not a supported SDR transfer function"
        case .unsupportedMatrix:
            return "Input YCbCr matrix is not supported"
        case .invalidGamma:
            return "Input gamma metadata is invalid"
        }
    }
}

public struct HDRInputMetadata: Equatable, Sendable {
    public let primariesAreBT709: Bool
    public let transferFunction: HDRTransferFunction
    public let yCbCrMatrix: HDRYCbCrMatrix
    public let isFullRange: Bool
    public let metadataWasExplicit: Bool

    /// The metadata contract shared by realtime processing and offline source
    /// diagnostics. Resolves attachments without reading any pixel data.
    public static func resolve(
        pixelBuffer: CVPixelBuffer,
        fallbackPolicy: HDRInputFallbackPolicy = .bt709VideoRange
    ) throws -> HDRInputMetadata {
        try HDRColorMetadataResolver.resolve(pixelBuffer: pixelBuffer, fallbackPolicy: fallbackPolicy).metadata
    }

    public init(
        primariesAreBT709: Bool = true,
        transferFunction: HDRTransferFunction = .bt709,
        yCbCrMatrix: HDRYCbCrMatrix = .bt709,
        isFullRange: Bool = false,
        metadataWasExplicit: Bool = false
    ) {
        self.primariesAreBT709 = primariesAreBT709
        self.transferFunction = transferFunction
        self.yCbCrMatrix = yCbCrMatrix
        self.isFullRange = isFullRange
        self.metadataWasExplicit = metadataWasExplicit
    }
}

public enum HDRColorMath {
    public static let bt709ToBT2020 = simd_float3x3(columns: (
        SIMD3<Float>(0.6274040, 0.0690970, 0.0163916),
        SIMD3<Float>(0.3292820, 0.9195400, 0.0880132),
        SIMD3<Float>(0.0433136, 0.0113623, 0.8955950)
    ))

    public static let bt709Luminance = SIMD3<Float>(0.2126, 0.7152, 0.0722)
    public static let bt2020Luminance = SIMD3<Float>(0.2627, 0.6780, 0.0593)

    public static func inverseBT709(_ signal: Float) -> Float {
        let value = max(signal, 0)
        return value < 0.081 ? value / 4.5 : pow((value + 0.099) / 1.099, 1 / 0.45)
    }

    public static func bt709(_ linear: Float) -> Float {
        let value = max(linear, 0)
        return value < 0.018 ? value * 4.5 : 1.099 * pow(value, 0.45) - 0.099
    }

    /// BT.1886 reference EOTF with Lb = 0, normalized so 1.0 is white.
    public static func inverseBT1886(_ signal: Float) -> Float {
        pow(max(signal, 0), 2.4)
    }

    public static let toeBlendRange: ClosedRange<Float> = 0.10...0.70

    public static func inverseBT709ToeBT1886Blend(_ signal: Float) -> Float {
        let range = toeBlendRange
        let t = min(max((signal - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
        let weight = t * t * (3 - 2 * t)
        return inverseBT709(signal) * (1 - weight) + inverseBT1886(signal) * weight
    }

    /// SDR→HLG code knots at SDR code k/16, k = 0...16 (normalized
    /// narrow-range luma codes), from `dataset/analysis/youtube-hlg-curve-v1.json`.
    public static let youtubeHLGCurveKnots: [Float] = [
        0.00000, 0.12609, 0.20355, 0.28179, 0.35523, 0.42496, 0.49100, 0.55358, 0.61006, 0.66057, 0.70648, 0.74818, 0.78920, 0.83003, 0.87738, 0.93165, 1.00000
    ]

    public static func youtubeSDRToHLGCode(_ signal: Float) -> Float {
        let knots = youtubeHLGCurveKnots
        let position = min(max(signal, 0), 1) * Float(knots.count - 1)
        let index = min(Int(position), knots.count - 2)
        let t = position - Float(index)
        return knots[index] + (knots[index + 1] - knots[index]) * t
    }

    /// BT.2100 HLG inverse OETF: signal → normalized scene light.
    public static func inverseHLGOETF(_ signal: Float) -> Float {
        let a: Float = 0.17883277
        let b: Float = 0.28466892
        let c: Float = 0.55991073
        let value = min(max(signal, 0), 1)
        return value <= 0.5 ? value * value / 3 : (exp((value - c) / a) + b) / 12
    }

    public static func inverseYouTubeHLGDerived(_ signal: Float) -> Float {
        pow(inverseHLGOETF(youtubeSDRToHLGCode(signal)), 1.2)
    }

    public static func inverseSRGB(_ signal: Float) -> Float {
        let value = max(signal, 0)
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    public static func srgb(_ linear: Float) -> Float {
        let value = max(linear, 0)
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    public static func inverseTransfer(_ signal: Float, function: HDRTransferFunction) -> Float {
        switch function {
        case .bt709:
            return inverseBT709(signal)
        case .sRGB:
            return inverseSRGB(signal)
        case .gamma(let gamma):
            guard gamma.isFinite, gamma > 0 else { return 0 }
            return pow(max(signal, 0), gamma)
        case .linear:
            return max(signal, 0)
        case .bt1886:
            return inverseBT1886(signal)
        case .bt709ToeBT1886Blend:
            return inverseBT709ToeBT1886Blend(signal)
        case .youtubeHLGInverse:
            return inverseYouTubeHLGDerived(signal)
        }
    }

    public static func pqEncode(normalizedAbsoluteLuminance: Float) -> Float {
        // ST.2084 uses L normalized to 10,000 cd/m². The output is the
        // normalized PQ signal, not a display-relative EDR component value.
        let m1: Float = 2610.0 / 16384.0
        let m2: Float = 2523.0 / 32.0
        let c1: Float = 3424.0 / 4096.0
        let c2: Float = 2413.0 / 128.0
        let c3: Float = 2392.0 / 128.0
        let luminance = min(max(normalizedAbsoluteLuminance, 0), 1)
        let powered = pow(luminance, m1)
        return pow((c1 + c2 * powered) / (1 + c3 * powered), m2)
    }

    public static func pqDecode(normalizedSignal: Float) -> Float {
        // Returns normalized absolute luminance, where 1.0 is 10,000 nits.
        let m1: Float = 2610.0 / 16384.0
        let m2: Float = 2523.0 / 32.0
        let c1: Float = 3424.0 / 4096.0
        let c2: Float = 2413.0 / 128.0
        let c3: Float = 2392.0 / 128.0
        let signal = min(max(normalizedSignal, 0), 1)
        let powered = pow(signal, 1 / m2)
        let numerator = max(powered - c1, 0)
        let denominator = max(c2 - c3 * powered, Float.leastNonzeroMagnitude)
        return pow(numerator / denominator, 1 / m1)
    }

    public static func pqEncode(nits: Float) -> Float {
        pqEncode(normalizedAbsoluteLuminance: max(nits, 0) / 10_000)
    }

    public static func pqDecodeNits(signal: Float) -> Float {
        pqDecode(normalizedSignal: signal) * 10_000
    }
}

internal struct ResolvedColorDescription: Equatable {
    let metadata: HDRInputMetadata
    let pixelFormat: HDRInputPixelFormat
    let chromaGeometry: HDRChromaSamplingGeometry
    let yOffset: Float
    let yScale: Float
    let chromaOffset: Float
    let chromaScale: Float
}

internal enum HDRColorMetadataResolver {
    static func resolve(
        pixelBuffer: CVPixelBuffer,
        fallbackPolicy: HDRInputFallbackPolicy
    ) throws -> ResolvedColorDescription {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let inputFormat = HDRInputPixelFormat(coreVideoFormat: pixelFormat)
        let chromaGeometry = HDRChromaSamplingGeometryResolver.resolve(pixelBuffer: pixelBuffer)
        let isYUV = inputFormat?.isYUV == true
        let isFullRange = inputFormat?.isFullRange == true
        let bitDepth = inputFormat?.bitDepth ?? 8
        let denominator = Float((1 << bitDepth) - 1)
        let yVideoOffset = bitDepth == 10 ? 64 / denominator : 16 / denominator
        let yVideoScale = bitDepth == 10 ? denominator / 876 : denominator / 219
        let chromaVideoOffset = bitDepth == 10 ? 512 / denominator : 128 / denominator
        let chromaVideoScale = bitDepth == 10 ? denominator / 896 : denominator / 224

        let primaries = attachment(kCVImageBufferColorPrimariesKey, from: pixelBuffer)
        let transfer = attachment(kCVImageBufferTransferFunctionKey, from: pixelBuffer)
        let matrix = attachment(kCVImageBufferYCbCrMatrixKey, from: pixelBuffer)
        let allMissing = primaries == nil && transfer == nil && (!isYUV || matrix == nil)

        if allMissing {
            switch fallbackPolicy {
            case .requireMetadata:
                throw HDRColorMetadataError.missingMetadata
            case .bt709VideoRange:
                return ResolvedColorDescription(
                    metadata: HDRInputMetadata(isFullRange: false),
                    pixelFormat: inputFormat ?? .nv12VideoRange,
                    chromaGeometry: chromaGeometry,
                    yOffset: yVideoOffset,
                    yScale: yVideoScale,
                    chromaOffset: chromaVideoOffset,
                    chromaScale: chromaVideoScale
                )
            case .bt709FullRange:
                return ResolvedColorDescription(
                    metadata: HDRInputMetadata(isFullRange: true),
                    pixelFormat: inputFormat ?? .nv12FullRange,
                    chromaGeometry: chromaGeometry,
                    yOffset: 0,
                    yScale: 1,
                    chromaOffset: chromaVideoOffset,
                    chromaScale: 1
                )
            }
        }

        if primaries == nil || transfer == nil || (isYUV && matrix == nil) {
            throw HDRColorMetadataError.incompleteMetadata
        }

        let primariesAreBT709 = equals(primaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        guard primariesAreBT709 else {
            throw HDRColorMetadataError.unsupportedPrimaries
        }

        let transferFunction: HDRTransferFunction
        if equals(transfer, kCVImageBufferTransferFunction_ITU_R_709_2) ||
            equals(transfer, kCVImageBufferTransferFunction_ITU_R_2020) {
            transferFunction = .bt709
        } else if equals(transfer, kCVImageBufferTransferFunction_sRGB) {
            transferFunction = .sRGB
        } else if equals(transfer, kCVImageBufferTransferFunction_Linear) {
            transferFunction = .linear
        } else if equals(transfer, kCVImageBufferTransferFunction_UseGamma) {
            guard let gammaValue = attachment(kCVImageBufferGammaLevelKey, from: pixelBuffer),
                  let gamma = gammaValue as? NSNumber,
                  gamma.doubleValue.isFinite,
                  gamma.doubleValue > 0 else {
                throw HDRColorMetadataError.invalidGamma
            }
            let shaderGamma = Float(gamma.doubleValue)
            guard shaderGamma.isFinite, shaderGamma > 0 else {
                throw HDRColorMetadataError.invalidGamma
            }
            transferFunction = .gamma(shaderGamma)
        } else {
            throw HDRColorMetadataError.unsupportedTransferFunction
        }

        let yCbCrMatrix: HDRYCbCrMatrix
        if equals(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
            yCbCrMatrix = .bt709
        } else if equals(matrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
            yCbCrMatrix = .bt601
        } else if equals(matrix, kCVImageBufferYCbCrMatrix_ITU_R_2020) {
            yCbCrMatrix = .bt2020
        } else if isYUV {
            throw HDRColorMetadataError.unsupportedMatrix
        } else {
            // BGRA has already been converted to RGB; its YCbCr matrix is
            // irrelevant, but a complete attachment set still remains valid.
            yCbCrMatrix = .bt709
        }

        let rangeIsFull = isYUV ? isFullRange : true
        return ResolvedColorDescription(
            metadata: HDRInputMetadata(
                primariesAreBT709: true,
                transferFunction: transferFunction,
                yCbCrMatrix: yCbCrMatrix,
                isFullRange: rangeIsFull,
                metadataWasExplicit: true
            ),
            pixelFormat: inputFormat ?? .bgra8,
            chromaGeometry: chromaGeometry,
            yOffset: rangeIsFull ? 0 : (bitDepth == 10 ? 64 / 1023 : 16 / 255),
            yScale: rangeIsFull ? 1 : (bitDepth == 10 ? 1023 / 876 : 255 / 219),
            chromaOffset: bitDepth == 10 ? 512 / 1023 : 128 / 255,
            chromaScale: rangeIsFull ? 1 : (bitDepth == 10 ? 1023 / 896 : 255 / 224)
        )
    }

    private static func attachment(_ key: CFString, from pixelBuffer: CVPixelBuffer) -> CFTypeRef? {
        CVBufferCopyAttachment(pixelBuffer, key, nil)
    }

    private static func equals(_ value: CFTypeRef?, _ constant: CFString) -> Bool {
        guard let value else { return false }
        return CFEqual(value, constant)
    }
}
