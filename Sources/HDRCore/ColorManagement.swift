import CoreVideo
import Foundation
import simd

public enum HDRTransferFunction: Equatable, Sendable {
    case bt709
    case sRGB
    case gamma(Float)
    case linear
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
        let isYUV = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let isFullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

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
                    yOffset: 16 / 255,
                    yScale: 255 / 219,
                    chromaOffset: 128 / 255,
                    chromaScale: 255 / 224
                )
            case .bt709FullRange:
                return ResolvedColorDescription(
                    metadata: HDRInputMetadata(isFullRange: true),
                    yOffset: 0,
                    yScale: 1,
                    chromaOffset: 128 / 255,
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
            transferFunction = .gamma(Float(gamma.doubleValue))
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
            yOffset: rangeIsFull ? 0 : 16 / 255,
            yScale: rangeIsFull ? 1 : 255 / 219,
            chromaOffset: 128 / 255,
            chromaScale: rangeIsFull ? 1 : 255 / 224
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
