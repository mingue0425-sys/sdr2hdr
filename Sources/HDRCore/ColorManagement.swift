import CoreVideo
import CryptoKit
import Foundation
import simd

/// Parameters for the normalized ideal/reference form of the BT.1886 EOTF.
/// These are calibration-domain luminance values, not a physical panel claim.
public struct BT1886TransferParameters: Codable, Equatable, Hashable, Sendable {
    public let blackLuminance: Float
    public let whiteLuminance: Float
    public let gamma: Float

    public init(
        blackLuminance: Float = 0,
        whiteLuminance: Float = 1,
        gamma: Float = 2.4
    ) {
        self.blackLuminance = blackLuminance
        self.whiteLuminance = whiteLuminance
        self.gamma = gamma
    }

    public static let idealReference = BT1886TransferParameters()

    public var isValid: Bool {
        blackLuminance.isFinite && whiteLuminance.isFinite && gamma.isFinite &&
            blackLuminance >= 0 && whiteLuminance > blackLuminance &&
            whiteLuminance <= 10_000 && gamma > 0 && gamma <= 10
    }

    /// BT.1886 derived `a` and `b` terms for `L = a * (V + b)^gamma`.
    public var derivedA: Float {
        guard isValid else { return 0 }
        let span = pow(whiteLuminance, 1 / gamma) - pow(blackLuminance, 1 / gamma)
        return pow(span, gamma)
    }

    public var derivedB: Float {
        guard isValid else { return 0 }
        let blackRoot = pow(blackLuminance, 1 / gamma)
        let span = pow(whiteLuminance, 1 / gamma) - blackRoot
        return blackRoot / span
    }
}

/// The transfer characteristic advertised by the source. This metadata is
/// separate from the interpretation policy selected for BT.709 content.
public enum SDRSourceTransferTag: String, CaseIterable, Codable, Hashable, Sendable {
    case ituR709 = "ituR709"
    case sRGB = "sRGB"
    case explicitGamma = "explicitGamma"
    case linear
    case unsupportedHDR = "unsupportedHDR"
    case unknown
}

/// The rendering-domain interpretation selected for an SDR input.
public enum SDRInputInterpretationPolicy: String, CaseIterable, Codable, Hashable, Sendable {
    case bt709SourceLinear = "bt709SourceLinear"
    case bt1886ReferenceDisplay = "bt1886ReferenceDisplay"
    case sRGB = "sRGB"
    case explicitGamma = "explicitGamma"
    case linear
}

/// Explicit behavior for a source with no transfer metadata.
public enum SDRUntaggedFallbackPolicy: String, CaseIterable, Codable, Hashable, Sendable {
    case assumeBT709SourceLinear = "assumeBT709SourceLinear"
    case assumeBT1886ReferenceDisplay = "assumeBT1886ReferenceDisplay"
    case reject
}

public enum HDRTransferFunction: Equatable, Hashable, Codable, Sendable {
    case bt709
    case sRGB
    case gamma(Float)
    case linear
    case bt1886(BT1886TransferParameters)

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
        case parameters
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "bt709": self = .bt709
        case "sRGB": self = .sRGB
        case "gamma": self = .gamma(try container.decode(Float.self, forKey: .value))
        case "linear": self = .linear
        case "bt1886": self = .bt1886(try container.decode(BT1886TransferParameters.self, forKey: .parameters))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unsupported HDR transfer function"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bt709:
            try container.encode("bt709", forKey: .kind)
        case .sRGB:
            try container.encode("sRGB", forKey: .kind)
        case .gamma(let value):
            try container.encode("gamma", forKey: .kind)
            try container.encode(value, forKey: .value)
        case .linear:
            try container.encode("linear", forKey: .kind)
        case .bt1886(let parameters):
            try container.encode("bt1886", forKey: .kind)
            try container.encode(parameters, forKey: .parameters)
        }
    }
}

/// Complete source-to-effective-transfer resolution record.
public struct SDRInputInterpretationResolution: Codable, Equatable, Hashable, Sendable {
    public let sourceTransferTag: SDRSourceTransferTag
    public let requestedPolicy: SDRInputInterpretationPolicy
    public let selectedPolicy: SDRInputInterpretationPolicy
    public let effectiveTransfer: HDRTransferFunction
    public let fallbackUsed: Bool
    public let fallbackReason: String?

    public init(
        sourceTransferTag: SDRSourceTransferTag,
        requestedPolicy: SDRInputInterpretationPolicy,
        selectedPolicy: SDRInputInterpretationPolicy,
        effectiveTransfer: HDRTransferFunction,
        fallbackUsed: Bool,
        fallbackReason: String?
    ) {
        self.sourceTransferTag = sourceTransferTag
        self.requestedPolicy = requestedPolicy
        self.selectedPolicy = selectedPolicy
        self.effectiveTransfer = effectiveTransfer
        self.fallbackUsed = fallbackUsed
        self.fallbackReason = fallbackReason
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
    case invalidBT1886Parameters
    case untaggedSourceRejected
    case policyMismatch

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
        case .invalidBT1886Parameters:
            return "BT.1886 parameters are invalid"
        case .untaggedSourceRejected:
            return "Input has no transfer metadata and the SDR fallback policy rejects it"
        case .policyMismatch:
            return "The selected SDR interpretation policy is incompatible with source metadata"
        }
    }
}

/// Resolves source metadata into an explicit SDR interpretation. The A/B
/// policy applies to ITU-R BT.709 tagged SDR only. sRGB, explicit gamma, and
/// linear metadata remain authoritative.
public enum SDRInputInterpretationResolver {
    public static func resolve(
        sourceTransferTag: SDRSourceTransferTag,
        metadataTransfer: HDRTransferFunction?,
        requestedPolicy: SDRInputInterpretationPolicy,
        untaggedFallback: SDRUntaggedFallbackPolicy = .assumeBT709SourceLinear,
        bt1886Parameters: BT1886TransferParameters = .idealReference
    ) throws -> SDRInputInterpretationResolution {
        guard bt1886Parameters.isValid else {
            throw HDRColorMetadataError.invalidBT1886Parameters
        }

        switch sourceTransferTag {
        case .ituR709:
            let effective: HDRTransferFunction
            switch requestedPolicy {
            case .bt709SourceLinear:
                effective = .bt709
            case .bt1886ReferenceDisplay:
                effective = .bt1886(bt1886Parameters)
            case .sRGB, .explicitGamma, .linear:
                throw HDRColorMetadataError.policyMismatch
            }
            return SDRInputInterpretationResolution(
                sourceTransferTag: sourceTransferTag,
                requestedPolicy: requestedPolicy,
                selectedPolicy: requestedPolicy,
                effectiveTransfer: effective,
                fallbackUsed: false,
                fallbackReason: nil
            )

        case .sRGB:
            return SDRInputInterpretationResolution(
                sourceTransferTag: sourceTransferTag,
                requestedPolicy: requestedPolicy,
                selectedPolicy: .sRGB,
                effectiveTransfer: .sRGB,
                fallbackUsed: false,
                fallbackReason: nil
            )

        case .explicitGamma:
            guard case .gamma(let gamma) = metadataTransfer,
                  gamma.isFinite, gamma > 0 else {
                throw HDRColorMetadataError.invalidGamma
            }
            return SDRInputInterpretationResolution(
                sourceTransferTag: sourceTransferTag,
                requestedPolicy: requestedPolicy,
                selectedPolicy: .explicitGamma,
                effectiveTransfer: .gamma(gamma),
                fallbackUsed: false,
                fallbackReason: nil
            )

        case .linear:
            return SDRInputInterpretationResolution(
                sourceTransferTag: sourceTransferTag,
                requestedPolicy: requestedPolicy,
                selectedPolicy: .linear,
                effectiveTransfer: .linear,
                fallbackUsed: false,
                fallbackReason: nil
            )

        case .unsupportedHDR:
            throw HDRColorMetadataError.unsupportedTransferFunction

        case .unknown:
            let selectedPolicy: SDRInputInterpretationPolicy
            let effective: HDRTransferFunction
            switch untaggedFallback {
            case .assumeBT709SourceLinear:
                selectedPolicy = .bt709SourceLinear
                effective = .bt709
            case .assumeBT1886ReferenceDisplay:
                selectedPolicy = .bt1886ReferenceDisplay
                effective = .bt1886(bt1886Parameters)
            case .reject:
                throw HDRColorMetadataError.untaggedSourceRejected
            }
            return SDRInputInterpretationResolution(
                sourceTransferTag: sourceTransferTag,
                requestedPolicy: requestedPolicy,
                selectedPolicy: selectedPolicy,
                effectiveTransfer: effective,
                fallbackUsed: true,
                fallbackReason: "source transfer metadata absent; \(untaggedFallback.rawValue)"
            )
        }
    }
}

public struct HDRInputMetadata: Equatable, Sendable {
    public let primariesAreBT709: Bool
    public let transferFunction: HDRTransferFunction
    public let sourceTransferTag: SDRSourceTransferTag
    public let interpretationPolicy: SDRInputInterpretationPolicy
    public let requestedInterpretationPolicy: SDRInputInterpretationPolicy
    public let fallbackUsed: Bool
    public let fallbackReason: String?
    public let yCbCrMatrix: HDRYCbCrMatrix
    public let isFullRange: Bool
    public let metadataWasExplicit: Bool

    /// The metadata contract shared by realtime processing and offline source
    /// diagnostics. Resolves attachments without reading any pixel data.
    public static func resolve(
        pixelBuffer: CVPixelBuffer,
        fallbackPolicy: HDRInputFallbackPolicy = .bt709VideoRange,
        interpretationPolicy: SDRInputInterpretationPolicy = .bt709SourceLinear,
        untaggedFallback: SDRUntaggedFallbackPolicy = .assumeBT709SourceLinear,
        bt1886Parameters: BT1886TransferParameters = .idealReference
    ) throws -> HDRInputMetadata {
        try HDRColorMetadataResolver.resolve(
            pixelBuffer: pixelBuffer,
            fallbackPolicy: fallbackPolicy,
            interpretationPolicy: interpretationPolicy,
            untaggedFallback: untaggedFallback,
            bt1886Parameters: bt1886Parameters
        ).metadata
    }

    public var effectiveTransfer: HDRTransferFunction { transferFunction }

    public init(
        primariesAreBT709: Bool = true,
        transferFunction: HDRTransferFunction = .bt709,
        sourceTransferTag: SDRSourceTransferTag? = nil,
        interpretationPolicy: SDRInputInterpretationPolicy? = nil,
        requestedInterpretationPolicy: SDRInputInterpretationPolicy? = nil,
        fallbackUsed: Bool = false,
        fallbackReason: String? = nil,
        yCbCrMatrix: HDRYCbCrMatrix = .bt709,
        isFullRange: Bool = false,
        metadataWasExplicit: Bool = false
    ) {
        self.primariesAreBT709 = primariesAreBT709
        self.transferFunction = transferFunction
        self.sourceTransferTag = sourceTransferTag ?? Self.defaultSourceTransferTag(for: transferFunction)
        let resolvedPolicy = interpretationPolicy ?? Self.defaultPolicy(for: transferFunction)
        self.interpretationPolicy = resolvedPolicy
        self.requestedInterpretationPolicy = requestedInterpretationPolicy ?? resolvedPolicy
        self.fallbackUsed = fallbackUsed
        self.fallbackReason = fallbackReason
        self.yCbCrMatrix = yCbCrMatrix
        self.isFullRange = isFullRange
        self.metadataWasExplicit = metadataWasExplicit
    }

    private static func defaultSourceTransferTag(for transfer: HDRTransferFunction) -> SDRSourceTransferTag {
        switch transfer {
        case .bt709, .bt1886:
            return .ituR709
        case .sRGB:
            return .sRGB
        case .gamma:
            return .explicitGamma
        case .linear:
            return .linear
        }
    }

    private static func defaultPolicy(for transfer: HDRTransferFunction) -> SDRInputInterpretationPolicy {
        switch transfer {
        case .bt709:
            return .bt709SourceLinear
        case .bt1886:
            return .bt1886ReferenceDisplay
        case .sRGB:
            return .sRGB
        case .gamma:
            return .explicitGamma
        case .linear:
            return .linear
        }
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

    /// BT.1886 EOTF parameterized by black and white luminance. This is the
    /// normalized reference-display model used by the policy experiment.
    public static func inverseBT1886(
        _ signal: Float,
        parameters: BT1886TransferParameters = .idealReference
    ) -> Float {
        guard parameters.isValid else { return 0 }
        return parameters.derivedA * pow(
            max(min(max(signal, 0), 1) + parameters.derivedB, 0),
            parameters.gamma
        )
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
        case .bt1886(let parameters):
            return inverseBT1886(signal, parameters: parameters)
        }
    }

    public static func interpretationPolicySHA256(
        version: String,
        policy: SDRInputInterpretationPolicy,
        untaggedFallback: SDRUntaggedFallbackPolicy,
        bt1886Parameters: BT1886TransferParameters
    ) -> String {
        struct Identity: Codable {
            let version: String
            let policy: SDRInputInterpretationPolicy
            let untaggedFallback: SDRUntaggedFallbackPolicy
            let bt1886Parameters: BT1886TransferParameters
        }
        let value = Identity(
            version: version,
            policy: policy,
            untaggedFallback: untaggedFallback,
            bt1886Parameters: bt1886Parameters
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        fallbackPolicy: HDRInputFallbackPolicy,
        interpretationPolicy: SDRInputInterpretationPolicy = .bt709SourceLinear,
        untaggedFallback: SDRUntaggedFallbackPolicy = .assumeBT709SourceLinear,
        bt1886Parameters: BT1886TransferParameters = .idealReference
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
                let resolution = try SDRInputInterpretationResolver.resolve(
                    sourceTransferTag: .unknown,
                    metadataTransfer: nil,
                    requestedPolicy: interpretationPolicy,
                    untaggedFallback: untaggedFallback,
                    bt1886Parameters: bt1886Parameters
                )
                return ResolvedColorDescription(
                    metadata: HDRInputMetadata(
                        transferFunction: resolution.effectiveTransfer,
                        sourceTransferTag: resolution.sourceTransferTag,
                        interpretationPolicy: resolution.selectedPolicy,
                        requestedInterpretationPolicy: resolution.requestedPolicy,
                        fallbackUsed: resolution.fallbackUsed,
                        fallbackReason: resolution.fallbackReason,
                        isFullRange: false
                    ),
                    pixelFormat: inputFormat ?? .nv12VideoRange,
                    chromaGeometry: chromaGeometry,
                    yOffset: yVideoOffset,
                    yScale: yVideoScale,
                    chromaOffset: chromaVideoOffset,
                    chromaScale: chromaVideoScale
                )
            case .bt709FullRange:
                let resolution = try SDRInputInterpretationResolver.resolve(
                    sourceTransferTag: .unknown,
                    metadataTransfer: nil,
                    requestedPolicy: interpretationPolicy,
                    untaggedFallback: untaggedFallback,
                    bt1886Parameters: bt1886Parameters
                )
                return ResolvedColorDescription(
                    metadata: HDRInputMetadata(
                        transferFunction: resolution.effectiveTransfer,
                        sourceTransferTag: resolution.sourceTransferTag,
                        interpretationPolicy: resolution.selectedPolicy,
                        requestedInterpretationPolicy: resolution.requestedPolicy,
                        fallbackUsed: resolution.fallbackUsed,
                        fallbackReason: resolution.fallbackReason,
                        isFullRange: true
                    ),
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

        let sourceTransferTag: SDRSourceTransferTag
        let metadataTransfer: HDRTransferFunction?
        if equals(transfer, kCVImageBufferTransferFunction_ITU_R_709_2) {
            sourceTransferTag = .ituR709
            metadataTransfer = .bt709
        } else if equals(transfer, kCVImageBufferTransferFunction_sRGB) {
            sourceTransferTag = .sRGB
            metadataTransfer = .sRGB
        } else if equals(transfer, kCVImageBufferTransferFunction_Linear) {
            sourceTransferTag = .linear
            metadataTransfer = .linear
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
            sourceTransferTag = .explicitGamma
            metadataTransfer = .gamma(shaderGamma)
        } else if equals(transfer, kCVImageBufferTransferFunction_ITU_R_2020) ||
                    equals(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
                    equals(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG) {
            sourceTransferTag = .unsupportedHDR
            metadataTransfer = nil
        } else {
            throw HDRColorMetadataError.unsupportedTransferFunction
        }

        let resolution = try SDRInputInterpretationResolver.resolve(
            sourceTransferTag: sourceTransferTag,
            metadataTransfer: metadataTransfer,
            requestedPolicy: interpretationPolicy,
            untaggedFallback: untaggedFallback,
            bt1886Parameters: bt1886Parameters
        )

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
                transferFunction: resolution.effectiveTransfer,
                sourceTransferTag: resolution.sourceTransferTag,
                interpretationPolicy: resolution.selectedPolicy,
                requestedInterpretationPolicy: resolution.requestedPolicy,
                fallbackUsed: resolution.fallbackUsed,
                fallbackReason: resolution.fallbackReason,
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
