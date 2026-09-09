@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// The precision that is actually requested from AVFoundation after the
/// source has been inspected. `HDRDecodePrecision` remains the user-facing
/// request; this type deliberately contains no automatic or preferred state.
public enum HDRResolvedDecodePrecision: String, Codable, Equatable, Sendable {
    case eightBit = "8-bit"
    case tenBit = "10-bit"

    public var bitDepth: Int {
        switch self {
        case .eightBit: return 8
        case .tenBit: return 10
        }
    }
}

public enum HDRSourceBitDepthEvidence: String, Codable, Equatable, Sendable {
    case bitsPerComponent
    case codecConfiguration
    case unresolved
    case conflicting
    case unsupported
}

/// Evidence extracted once from the video track before an output object is
/// created. It intentionally contains no HDR reference or fixture metadata.
public struct HDRSourcePrecisionEvidence: Equatable, Sendable {
    public let codec: String?
    public let bitDepth: Int?
    public let evidence: HDRSourceBitDepthEvidence
    public let formatDescriptionCount: Int

    public init(
        codec: String?,
        bitDepth: Int?,
        evidence: HDRSourceBitDepthEvidence,
        formatDescriptionCount: Int = 1
    ) {
        self.codec = codec
        self.bitDepth = bitDepth
        self.evidence = evidence
        self.formatDescriptionCount = formatDescriptionCount
    }
}

public enum HDRDecodePrecisionDecisionReason: String, Codable, Equatable, Sendable {
    case explicitEightBitOverride
    case explicitTenBitOverride
    case sourceReportedEightBit
    case sourceReportedTenBit
    case sourceCodecConfigurationEightBit
    case sourceCodecConfigurationTenBit
    case sourcePrecisionUnresolved
    case sourcePrecisionConflicted
    case unsupportedSourceBitDepth
    case sourceInspectionFailed
}

public struct HDRDecodePrecisionDecision: Equatable, Sendable {
    public let requested: HDRDecodePrecision
    public let resolved: HDRResolvedDecodePrecision
    public let sourceBitDepth: Int?
    public let sourceCodec: String?
    public let reason: HDRDecodePrecisionDecisionReason
    public let fallbackUsed: Bool
    public let detail: String?

    public init(
        requested: HDRDecodePrecision,
        resolved: HDRResolvedDecodePrecision,
        sourceBitDepth: Int?,
        sourceCodec: String?,
        reason: HDRDecodePrecisionDecisionReason,
        fallbackUsed: Bool,
        detail: String? = nil
    ) {
        self.requested = requested
        self.resolved = resolved
        self.sourceBitDepth = sourceBitDepth
        self.sourceCodec = sourceCodec
        self.reason = reason
        self.fallbackUsed = fallbackUsed
        self.detail = detail
    }

    public var diagnosticDescription: String {
        let sourceDepth = sourceBitDepth.map(String.init) ?? "unknown"
        let codec = sourceCodec ?? "unknown"
        let detail = detail.map { " detail=\($0)" } ?? ""
        return "requested=\(requested.rawValue) resolved=\(resolved.rawValue) " +
            "sourceCodec=\(codec) sourceBitDepth=\(sourceDepth) " +
            "reason=\(reason.rawValue) fallback=\(fallbackUsed) " +
            "requestedPixelFormat=\(resolved == .tenBit ? "P010" : "NV12")\(detail)"
    }
}

/// Resolves the output precision from AVFoundation's source format
/// descriptions. Runtime callers use only the asset overload; the pure
/// overload is also used by tests so malformed codec configuration can be
/// checked without opening media.
public enum HDRDecodePrecisionResolver {
    public static func fallbackDecision(
        for requested: HDRDecodePrecision,
        sourceCodec: String? = nil,
        detail: String? = nil
    ) -> HDRDecodePrecisionDecision {
        switch requested {
        case .automatic:
            return HDRDecodePrecisionDecision(
                requested: requested,
                resolved: .eightBit,
                sourceBitDepth: nil,
                sourceCodec: sourceCodec,
                reason: detail == nil ? .sourcePrecisionUnresolved : .sourceInspectionFailed,
                fallbackUsed: true,
                detail: detail
            )
        case .eightBit:
            return HDRDecodePrecisionDecision(
                requested: requested,
                resolved: .eightBit,
                sourceBitDepth: nil,
                sourceCodec: sourceCodec,
                reason: .explicitEightBitOverride,
                fallbackUsed: false,
                detail: detail
            )
        case .tenBitPreferred:
            return HDRDecodePrecisionDecision(
                requested: requested,
                resolved: .tenBit,
                sourceBitDepth: nil,
                sourceCodec: sourceCodec,
                reason: .explicitTenBitOverride,
                fallbackUsed: false,
                detail: detail
            )
        }
    }

    public static func resolve(
        requested: HDRDecodePrecision,
        source: HDRSourcePrecisionEvidence
    ) -> HDRDecodePrecisionDecision {
        switch requested {
        case .eightBit:
            return HDRDecodePrecisionDecision(
                requested: requested,
                resolved: .eightBit,
                sourceBitDepth: source.bitDepth,
                sourceCodec: source.codec,
                reason: .explicitEightBitOverride,
                fallbackUsed: false
            )
        case .tenBitPreferred:
            return HDRDecodePrecisionDecision(
                requested: requested,
                resolved: .tenBit,
                sourceBitDepth: source.bitDepth,
                sourceCodec: source.codec,
                reason: .explicitTenBitOverride,
                fallbackUsed: false
            )
        case .automatic:
            guard let bitDepth = source.bitDepth else {
                let reason: HDRDecodePrecisionDecisionReason
                switch source.evidence {
                case .conflicting:
                    reason = .sourcePrecisionConflicted
                case .unsupported:
                    reason = .unsupportedSourceBitDepth
                case .bitsPerComponent, .codecConfiguration, .unresolved:
                    reason = .sourcePrecisionUnresolved
                }
                return HDRDecodePrecisionDecision(
                    requested: requested,
                    resolved: .eightBit,
                    sourceBitDepth: source.bitDepth,
                    sourceCodec: source.codec,
                    reason: reason,
                    fallbackUsed: true
                )
            }

            switch (bitDepth, source.evidence) {
            case (8, .bitsPerComponent):
                return decision(
                    requested: requested,
                    resolved: .eightBit,
                    source: source,
                    reason: .sourceReportedEightBit
                )
            case (10, .bitsPerComponent):
                return decision(
                    requested: requested,
                    resolved: .tenBit,
                    source: source,
                    reason: .sourceReportedTenBit
                )
            case (8, .codecConfiguration):
                return decision(
                    requested: requested,
                    resolved: .eightBit,
                    source: source,
                    reason: .sourceCodecConfigurationEightBit
                )
            case (10, .codecConfiguration):
                return decision(
                    requested: requested,
                    resolved: .tenBit,
                    source: source,
                    reason: .sourceCodecConfigurationTenBit
                )
            case (_, .unsupported):
                return HDRDecodePrecisionDecision(
                    requested: requested,
                    resolved: .eightBit,
                    sourceBitDepth: bitDepth,
                    sourceCodec: source.codec,
                    reason: .unsupportedSourceBitDepth,
                    fallbackUsed: true
                )
            default:
                return HDRDecodePrecisionDecision(
                    requested: requested,
                    resolved: .eightBit,
                    sourceBitDepth: bitDepth,
                    sourceCodec: source.codec,
                    reason: .sourcePrecisionUnresolved,
                    fallbackUsed: true
                )
            }
        }
    }

    /// Resolve an asset before `AVPlayerItemVideoOutput` is constructed. A
    /// source-inspection failure is deliberately a visible conservative
    /// fallback rather than a claim that the source is 8-bit.
    @MainActor
    public static func resolve(
        asset: AVAsset,
        requested: HDRDecodePrecision
    ) async -> HDRDecodePrecisionDecision {
        do {
            let source = try await inspect(asset: asset)
            return resolve(requested: requested, source: source)
        } catch {
            return fallbackDecision(
                for: requested,
                detail: error.localizedDescription
            )
        }
    }

    /// Load only the video track format descriptions. No player, output, or
    /// per-frame operation is involved in this inspection.
    @MainActor
    public static func inspect(asset: AVAsset) async throws -> HDRSourcePrecisionEvidence {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw InspectionError.noVideoTrack
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard !descriptions.isEmpty else {
            throw InspectionError.noFormatDescription
        }

        let parsed = descriptions.map(parse(formatDescription:))
        let codecs = Set(parsed.compactMap(\.codec))
        let codec = codecs.count == 1 ? codecs.first : parsed.first?.codec
        let knownDepths = Set(parsed.compactMap(\.bitDepth))

        if knownDepths.count > 1 {
            return HDRSourcePrecisionEvidence(
                codec: codec,
                bitDepth: nil,
                evidence: .conflicting,
                formatDescriptionCount: parsed.count
            )
        }

        if parsed.contains(where: { $0.evidence == .unsupported }) {
            return HDRSourcePrecisionEvidence(
                codec: codec,
                bitDepth: knownDepths.first,
                evidence: .unsupported,
                formatDescriptionCount: parsed.count
            )
        }

        guard let bitDepth = knownDepths.first,
              parsed.allSatisfy({ $0.bitDepth == bitDepth }) else {
            return HDRSourcePrecisionEvidence(
                codec: codec,
                bitDepth: nil,
                evidence: .unresolved,
                formatDescriptionCount: parsed.count
            )
        }

        let evidence: HDRSourceBitDepthEvidence = parsed.allSatisfy {
            $0.evidence == .bitsPerComponent
        } ? .bitsPerComponent : .codecConfiguration
        return HDRSourcePrecisionEvidence(
            codec: codec,
            bitDepth: bitDepth,
            evidence: evidence,
            formatDescriptionCount: parsed.count
        )
    }

    /// Testable parser seam for avcC/hvcC profile evidence. It never indexes
    /// past the supplied data and returns nil for unsupported or malformed
    /// configurations.
    static func bitDepthFromCodecConfiguration(codec: String, data: Data) -> Int? {
        switch codec {
        case "avc1", "avc3":
            // ISO/IEC 14496-15: configurationVersion, AVCProfileIndication,
            // profile_compatibility, AVCLevelIndication.
            guard data.count >= 4 else { return nil }
            switch data[data.startIndex + 1] {
            case 66, 77, 88, 100:
                return 8
            case 110:
                return 10
            default:
                return nil
            }

        case "hvc1", "hev1":
            // hvcC byte 1 contains general_profile_space (bits 7...6),
            // general_tier_flag (bit 5), and general_profile_idc (bits 4...0).
            guard data.count >= 2 else { return nil }
            let profileID = data[data.startIndex + 1] & 0x1f
            switch profileID {
            case 1: return 8 // Main
            case 2: return 10 // Main 10
            default: return nil
            }

        default:
            return nil
        }
    }

    private struct ParsedDescription {
        let codec: String?
        let bitDepth: Int?
        let evidence: HDRSourceBitDepthEvidence
    }

    private enum InspectionError: Error, LocalizedError {
        case noVideoTrack
        case noFormatDescription

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "source has no video track"
            case .noFormatDescription: return "source has no video format description"
            }
        }
    }

    private static func decision(
        requested: HDRDecodePrecision,
        resolved: HDRResolvedDecodePrecision,
        source: HDRSourcePrecisionEvidence,
        reason: HDRDecodePrecisionDecisionReason
    ) -> HDRDecodePrecisionDecision {
        HDRDecodePrecisionDecision(
            requested: requested,
            resolved: resolved,
            sourceBitDepth: source.bitDepth,
            sourceCodec: source.codec,
            reason: reason,
            fallbackUsed: false
        )
    }

    private static func parse(formatDescription: CMFormatDescription) -> ParsedDescription {
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(formatDescription))
        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [String: Any]

        if let bitDepth = bitsPerComponent(from: extensions) {
            return ParsedDescription(
                codec: codec,
                bitDepth: bitDepth,
                evidence: (bitDepth == 8 || bitDepth == 10) ? .bitsPerComponent : .unsupported
            )
        }

        let atomName: String?
        switch codec {
        case "avc1", "avc3": atomName = "avcC"
        case "hvc1", "hev1": atomName = "hvcC"
        default: atomName = nil
        }
        if let atomName,
           let data = codecConfigurationData(from: extensions, atomName: atomName),
           let bitDepth = bitDepthFromCodecConfiguration(codec: codec, data: data) {
            return ParsedDescription(codec: codec, bitDepth: bitDepth, evidence: .codecConfiguration)
        }
        return ParsedDescription(codec: codec, bitDepth: nil, evidence: .unresolved)
    }

    private static func bitsPerComponent(from extensions: [String: Any]?) -> Int? {
        guard let extensions,
              let number = extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite,
              value >= 1,
              value <= Double(Int.max),
              value.rounded() == value else { return nil }
        return Int(value)
    }

    private static func codecConfigurationData(
        from extensions: [String: Any]?,
        atomName: String
    ) -> Data? {
        guard let extensions,
              let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
              let data = atoms[atomName] as? Data else {
            return nil
        }
        return data
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, encoding: .ascii) ?? "unknown"
    }
}
