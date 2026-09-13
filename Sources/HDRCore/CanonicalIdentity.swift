import CryptoKit
import Foundation

/// Errors raised while constructing an experiment or semantic identity.
/// Identity generation is deliberately fail-closed: an invalid value never
/// becomes a digest of an empty or substituted payload.
public enum HDRCanonicalIdentityError: Error, LocalizedError, Equatable, Sendable {
    case encodingFailed
    case invalidUTF8
    case unsupportedValue
    case nonFiniteNumber

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "canonical identity encoding failed"
        case .invalidUTF8:
            return "canonical identity is not valid UTF-8"
        case .unsupportedValue:
            return "canonical identity contains an unsupported value"
        case .nonFiniteNumber:
            return "canonical identity contains a non-finite number"
        }
    }
}

/// A small deterministic JSON canonicalizer used for semantic identities.
///
/// Representation contract:
/// - UTF-8 output;
/// - object keys sorted by their UTF-8 bytes;
/// - arrays retain declared order;
/// - nil is represented as JSON `null` by the encodable value;
/// - only finite numbers are accepted;
/// - numbers use a locale-independent decimal representation and `-0` is `0`;
/// - no Foundation dictionary iteration order is used.
public enum HDRCanonicalIdentity {
    public static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .throw
        let encoded: Data
        do {
            encoded = try encoder.encode(value)
        } catch {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        guard String(data: encoded, encoding: .utf8) != nil else {
            throw HDRCanonicalIdentityError.invalidUTF8
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(
                with: encoded,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw HDRCanonicalIdentityError.encodingFailed
        }
        return try render(object)
    }

    public static func sha256<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try data(value))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Canonical decimal text for semantic identity models that choose to
    /// represent a number as a string. This is useful when an identity must
    /// distinguish an explicit numeric field from an omitted optional field.
    public static func number(_ value: Double) throws -> String {
        guard value.isFinite else { throw HDRCanonicalIdentityError.nonFiniteNumber }
        if value == 0 { return "0" }
        return String(format: "%.17g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func number(_ value: Float) throws -> String {
        guard value.isFinite else { throw HDRCanonicalIdentityError.nonFiniteNumber }
        if value == 0 { return "0" }
        return String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func render(_ value: Any) throws -> Data {
        if value is NSNull {
            return Data("null".utf8)
        }
        if let value = value as? String {
            let encoded = try JSONEncoder().encode(value)
            guard String(data: encoded, encoding: .utf8) != nil else {
                throw HDRCanonicalIdentityError.invalidUTF8
            }
            return encoded
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return Data((value.boolValue ? "true" : "false").utf8)
            }
            return try renderNumber(value)
        }
        if let value = value as? Bool {
            return Data((value ? "true" : "false").utf8)
        }
        if let value = value as? [Any] {
            var result = Data("[".utf8)
            for (index, element) in value.enumerated() {
                if index > 0 { result.append(Data(",".utf8)) }
                result.append(try render(element))
            }
            result.append(Data("]".utf8))
            return result
        }
        if let value = value as? [String: Any] {
            let keys = value.keys.sorted {
                Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8))
            }
            var result = Data("{".utf8)
            for (index, key) in keys.enumerated() {
                if index > 0 { result.append(Data(",".utf8)) }
                result.append(try render(key))
                result.append(Data(":".utf8))
                guard let element = value[key] else {
                    throw HDRCanonicalIdentityError.unsupportedValue
                }
                result.append(try render(element))
            }
            result.append(Data("}".utf8))
            return result
        }
        throw HDRCanonicalIdentityError.unsupportedValue
    }

    private static func renderNumber(_ value: NSNumber) throws -> Data {
        let type = String(cString: value.objCType)
        switch type {
        case "c", "i", "s", "l", "q":
            return Data(String(value.int64Value).utf8)
        case "C", "I", "S", "L", "Q":
            return Data(String(value.uint64Value).utf8)
        case "f", "d":
            return Data(try number(value.doubleValue).utf8)
        default:
            throw HDRCanonicalIdentityError.unsupportedValue
        }
    }
}

/// Exact policy semantics that participate in the Stage B experiment seal.
/// This is intentionally broader than the selected runtime policy: the
/// candidate universe and the behavior of every supported interpretation are
/// part of the policy definition identity.
public struct SDRPolicyDefinition: Codable, Hashable, Sendable {
    public static let semanticVersion = "sdr-policy-definition-v2"

    public let semanticVersion: String
    public let policyVersion: String
    public let candidateList: [String]
    public let bt709SourceLinearSemanticVersion: String
    public let bt1886ReferenceDisplaySemanticVersion: String
    public let sRGBSemanticVersion: String
    public let explicitGammaSemanticVersion: String
    public let linearSemanticVersion: String
    public let bt1886Parameters: BT1886TransferParameters
    public let bt1886ParameterValidationDomain: [String]
    public let sRGBBehavior: String
    public let explicitGammaBehavior: String
    public let linearBehavior: String
    public let untaggedFallback: SDRUntaggedFallbackPolicy
    public let untaggedFallbackSemantics: [String]

    public init(
        policyVersion: String,
        candidateList: [String],
        bt1886Parameters: BT1886TransferParameters,
        untaggedFallback: SDRUntaggedFallbackPolicy,
        semanticVersion: String = SDRPolicyDefinition.semanticVersion,
        bt709SourceLinearSemanticVersion: String = "bt709-source-linear-v2",
        bt1886ReferenceDisplaySemanticVersion: String = "bt1886-reference-display-v2",
        sRGBSemanticVersion: String = "srgb-source-v2",
        explicitGammaSemanticVersion: String = "explicit-gamma-v2",
        linearSemanticVersion: String = "linear-source-v2",
        bt1886ParameterValidationDomain: [String] = [
            "L_B finite and >= 0",
            "L_W finite and > L_B",
            "L_W <= 10000",
            "gamma finite and in (0,10]"
        ],
        sRGBBehavior: String = "inverse IEC 61966-2-1 piecewise transfer; metadata authoritative",
        explicitGammaBehavior: String = "metadata gamma finite and > 0; metadata authoritative",
        linearBehavior: String = "encoded signal is already linear; metadata authoritative",
        untaggedFallbackSemantics: [String] = [
            SDRUntaggedFallbackPolicy.assumeBT709SourceLinear.rawValue,
            SDRUntaggedFallbackPolicy.assumeBT1886ReferenceDisplay.rawValue,
            SDRUntaggedFallbackPolicy.reject.rawValue
        ]
    ) {
        self.semanticVersion = semanticVersion
        self.policyVersion = policyVersion
        self.candidateList = candidateList
        self.bt709SourceLinearSemanticVersion = bt709SourceLinearSemanticVersion
        self.bt1886ReferenceDisplaySemanticVersion = bt1886ReferenceDisplaySemanticVersion
        self.sRGBSemanticVersion = sRGBSemanticVersion
        self.explicitGammaSemanticVersion = explicitGammaSemanticVersion
        self.linearSemanticVersion = linearSemanticVersion
        self.bt1886Parameters = bt1886Parameters
        self.bt1886ParameterValidationDomain = bt1886ParameterValidationDomain
        self.sRGBBehavior = sRGBBehavior
        self.explicitGammaBehavior = explicitGammaBehavior
        self.linearBehavior = linearBehavior
        self.untaggedFallback = untaggedFallback
        self.untaggedFallbackSemantics = untaggedFallbackSemantics
    }

    public static let current = SDRPolicyDefinition(
        policyVersion: "sdr-input-interpretation-policy-v1",
        candidateList: [
            SDRInputInterpretationPolicy.bt709SourceLinear.rawValue,
            SDRInputInterpretationPolicy.bt1886ReferenceDisplay.rawValue
        ],
        bt1886Parameters: .idealReference,
        untaggedFallback: .assumeBT709SourceLinear
    )

    public static func currentSHA256() throws -> String {
        try HDRCanonicalIdentity.sha256(current)
    }

    public func sha256() throws -> String {
        try HDRCanonicalIdentity.sha256(self)
    }
}
