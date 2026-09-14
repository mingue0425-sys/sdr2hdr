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

    public var validationFailure: String? {
        guard blackLuminance.isFinite,
              whiteLuminance.isFinite,
              gamma.isFinite else {
            return "BT.1886 parameters must be finite"
        }
        guard blackLuminance >= 0 else {
            return "BT.1886 L_B must be non-negative"
        }
        guard whiteLuminance > blackLuminance else {
            return "BT.1886 L_W must be greater than L_B"
        }
        guard whiteLuminance <= 10_000 else {
            return "BT.1886 L_W exceeds 10,000"
        }
        guard gamma > 0, gamma <= 10 else {
            return "BT.1886 gamma must be in (0, 10]"
        }
        return nil
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
        bt1886Parameters: BT1886TransferParameters = .idealReference,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4
    ) throws -> HDRInputMetadata {
        try HDRColorMetadataResolver.resolve(
            pixelBuffer: pixelBuffer,
            fallbackPolicy: fallbackPolicy,
            interpretationPolicy: interpretationPolicy,
            untaggedFallback: untaggedFallback,
            bt1886Parameters: bt1886Parameters,
            colorScience: colorScience
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
    public static var bt709ToBT2020: simd_float3x3 {
        let values = HDRColorScienceSemanticDefinition.calibrationV4.bt709ToBT2020
        return simd_float3x3(columns: (
            SIMD3<Float>(Float(values[0]), Float(values[1]), Float(values[2])),
            SIMD3<Float>(Float(values[3]), Float(values[4]), Float(values[5])),
            SIMD3<Float>(Float(values[6]), Float(values[7]), Float(values[8]))
        ))
    }

    /// Compatibility accessors backed by the calibration color-science
    /// definition.  Production calibration code must not own a second copy
    /// of these coefficients.
    public static var bt709Luminance: SIMD3<Float> {
        let values = HDRColorScienceSemanticDefinition.calibrationV4.yCbCr.bt709Luminance
        return SIMD3(Float(values[0]), Float(values[1]), Float(values[2]))
    }

    public static var bt2020Luminance: SIMD3<Float> {
        let values = HDRColorScienceSemanticDefinition.calibrationV4.yCbCr.bt2020Luminance
        return SIMD3(Float(values[0]), Float(values[1]), Float(values[2]))
    }

    public static func inverseBT709(_ signal: Float) -> Float {
        inverseBT709(signal, colorScience: .calibrationV4)
    }

    public static func inverseBT709(
        _ signal: Float,
        colorScience: HDRColorScienceSemanticDefinition
    ) -> Float {
        let definition = colorScience.transfer
        let value = max(signal, 0)
        return value < Float(definition.bt709InverseBreakPoint)
            ? value / Float(definition.bt709InverseLinearScale)
            : pow(
                (value + Float(definition.bt709InverseOffset)) /
                    Float(definition.bt709InverseScale),
                Float(definition.bt709InverseExponent)
            )
    }

    public static func bt709(_ linear: Float) -> Float {
        bt709(linear, colorScience: .calibrationV4)
    }

    public static func bt709(
        _ linear: Float,
        colorScience: HDRColorScienceSemanticDefinition
    ) -> Float {
        let definition = colorScience.transfer
        let value = max(linear, 0)
        return value < Float(definition.bt709ForwardBreakPoint)
            ? value * Float(definition.bt709ForwardLinearScale)
            : Float(definition.bt709ForwardScale) * pow(value, Float(definition.bt709ForwardExponent)) -
                Float(definition.bt709ForwardOffset)
    }

    public static func inverseSRGB(_ signal: Float) -> Float {
        inverseSRGB(signal, colorScience: .calibrationV4)
    }

    public static func inverseSRGB(
        _ signal: Float,
        colorScience: HDRColorScienceSemanticDefinition
    ) -> Float {
        let definition = colorScience.transfer
        let value = max(signal, 0)
        return value <= Float(definition.srgbInverseBreakPoint)
            ? value / Float(definition.srgbInverseLinearScale)
            : pow(
                (value + Float(definition.srgbInverseOffset)) /
                    Float(definition.srgbInverseScale),
                Float(definition.srgbInverseExponent)
            )
    }

    public static func srgb(_ linear: Float) -> Float {
        srgb(linear, colorScience: .calibrationV4)
    }

    public static func srgb(
        _ linear: Float,
        colorScience: HDRColorScienceSemanticDefinition
    ) -> Float {
        let definition = colorScience.transfer
        let value = max(linear, 0)
        return value <= Float(definition.srgbForwardBreakPoint)
            ? value * Float(definition.srgbForwardLinearScale)
            : Float(definition.srgbForwardScale) * pow(value, Float(definition.srgbForwardExponent)) -
                Float(definition.srgbForwardOffset)
    }

    /// BT.1886 EOTF parameterized by black and white luminance. This is the
    /// normalized reference-display model used by the policy experiment.
    public static func inverseBT1886(
        _ signal: Float,
        parameters: BT1886TransferParameters = .idealReference
    ) -> Float {
        // Invalid parameters are rejected by HDRConfiguration and metadata
        // resolution before a production dispatch. Returning NaN here keeps
        // accidental direct scalar use visibly invalid instead of silently
        // turning an invalid parameterization into a black sample.
        guard parameters.isValid else { return .nan }
        return parameters.derivedA * pow(
            max(min(max(signal, 0), 1) + parameters.derivedB, 0),
            parameters.gamma
        )
    }

    public static func inverseTransfer(
        _ signal: Float,
        function: HDRTransferFunction,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4
    ) -> Float {
        switch function {
        case .bt709:
            return inverseBT709(signal, colorScience: colorScience)
        case .sRGB:
            return inverseSRGB(signal, colorScience: colorScience)
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
    ) throws -> String {
        let value = SDRPolicyDefinition(
            policyVersion: version,
            candidateList: [policy.rawValue],
            bt1886Parameters: bt1886Parameters,
            untaggedFallback: untaggedFallback
        )
        return try HDRCanonicalIdentity.sha256(value)
    }

    public static func pqEncode(
        normalizedAbsoluteLuminance: Float,
        definition: HDRPQSemanticDefinition = .st2084
    ) -> Float {
        // ST.2084 uses L normalized to 10,000 cd/m². The output is the
        // normalized PQ signal, not a display-relative EDR component value.
        let m1 = Float(definition.m1)
        let m2 = Float(definition.m2)
        let c1 = Float(definition.c1)
        let c2 = Float(definition.c2)
        let c3 = Float(definition.c3)
        let luminance = min(max(normalizedAbsoluteLuminance, 0), 1)
        let powered = pow(luminance, m1)
        return pow((c1 + c2 * powered) / (1 + c3 * powered), m2)
    }

    public static func pqDecode(
        normalizedSignal: Float,
        definition: HDRPQSemanticDefinition = .st2084
    ) -> Float {
        // Returns normalized absolute luminance, where 1.0 is 10,000 nits.
        let m1 = Float(definition.m1)
        let m2 = Float(definition.m2)
        let c1 = Float(definition.c1)
        let c2 = Float(definition.c2)
        let c3 = Float(definition.c3)
        let signal = min(max(normalizedSignal, 0), 1)
        let powered = pow(signal, 1 / m2)
        let numerator = max(powered - c1, 0)
        let denominator = max(c2 - c3 * powered, Float.leastNonzeroMagnitude)
        return pow(numerator / denominator, 1 / m1)
    }

    public static func pqEncode(
        nits: Float,
        definition: HDRPQSemanticDefinition = .st2084
    ) -> Float {
        pqEncode(
            normalizedAbsoluteLuminance: max(nits, 0) / Float(definition.absolutePeakNits),
            definition: definition
        )
    }

    public static func pqDecodeNits(
        signal: Float,
        definition: HDRPQSemanticDefinition = .st2084
    ) -> Float {
        pqDecode(normalizedSignal: signal, definition: definition) * Float(definition.absolutePeakNits)
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
        bt1886Parameters: BT1886TransferParameters = .idealReference,
        colorScience: HDRColorScienceSemanticDefinition = .calibrationV4
    ) throws -> ResolvedColorDescription {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let inputFormat = HDRInputPixelFormat(coreVideoFormat: pixelFormat)
        let chromaGeometry = HDRChromaSamplingGeometryResolver.resolve(pixelBuffer: pixelBuffer)
        let isYUV = inputFormat?.isYUV == true
        let isFullRange = inputFormat?.isFullRange == true
        let bitDepth = inputFormat?.bitDepth ?? 8
        let denominator = bitDepth == 10
            ? Float(colorScience.yCbCr.fullRange10Denominator)
            : Float(colorScience.yCbCr.fullRange8Denominator)
        let yVideoOffset = bitDepth == 10
            ? Float(colorScience.yCbCr.videoRange10LumaOffset) / denominator
            : Float(colorScience.yCbCr.videoRange8LumaOffset) / denominator
        let yVideoScale = bitDepth == 10
            ? denominator / Float(colorScience.yCbCr.videoRange10LumaDenominator)
            : denominator / Float(colorScience.yCbCr.videoRange8LumaDenominator)
        let chromaVideoOffset = bitDepth == 10
            ? Float(colorScience.yCbCr.videoRange10ChromaCenter) / denominator
            : Float(colorScience.yCbCr.videoRange8ChromaCenter) / denominator
        let chromaVideoScale = bitDepth == 10
            ? denominator / Float(colorScience.yCbCr.videoRange10ChromaDenominator)
            : denominator / Float(colorScience.yCbCr.videoRange8ChromaDenominator)

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
                yOffset: rangeIsFull ? 0 : yVideoOffset,
                yScale: rangeIsFull ? 1 : yVideoScale,
                chromaOffset: chromaVideoOffset,
                chromaScale: rangeIsFull ? 1 : chromaVideoScale
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
