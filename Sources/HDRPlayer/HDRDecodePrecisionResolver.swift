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

        if parsed.contains(where: { $0.evidence == .conflicting }) || knownDepths.count > 1 {
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

    /// Testable parser seam for avcC/hvcC SPS evidence. Profile identifiers
    /// select syntax in the SPS, but never determine the coded bit depth by
    /// themselves. It never indexes past the supplied data and returns nil
    /// for unsupported, conflicting, or malformed configurations.
    static func bitDepthFromCodecConfiguration(codec: String, data: Data) -> Int? {
        switch codecConfigurationBitDepthResult(codec: codec, data: data) {
        case .resolved(let bitDepth):
            return bitDepth
        case .conflicting, .unsupported, .malformed:
            return nil
        }
    }

    private enum CodecConfigurationBitDepthResult {
        case resolved(Int)
        case conflicting
        case unsupported
        case malformed
    }

    private static func codecConfigurationBitDepthResult(
        codec: String,
        data: Data
    ) -> CodecConfigurationBitDepthResult {
        switch codec {
        case "avc1", "avc3":
            return avcConfigurationBitDepthResult(data: data)
        case "hvc1", "hev1":
            return hevcConfigurationBitDepthResult(data: data)
        default:
            return .unsupported
        }
    }

    private static func avcConfigurationBitDepthResult(data: Data) -> CodecConfigurationBitDepthResult {
        var cursor = ByteCursor(bytes: Array(data))
        guard cursor.readByte() == 1,
              cursor.readByte() != nil,
              cursor.readByte() != nil,
              cursor.readByte() != nil,
              let lengthAndReserved = cursor.readByte(),
              lengthAndReserved & 0xfc == 0xfc,
              let spsAndReserved = cursor.readByte(),
              spsAndReserved & 0xe0 == 0xe0 else {
            return .malformed
        }

        let sequenceParameterSetCount = Int(spsAndReserved & 0x1f)
        guard sequenceParameterSetCount > 0 else { return .malformed }
        var spsUnits: [[UInt8]] = []
        spsUnits.reserveCapacity(sequenceParameterSetCount)
        for _ in 0..<sequenceParameterSetCount {
            guard let length = cursor.readUInt16(), length > 0,
                  let unit = cursor.readBytes(count: length) else {
                return .malformed
            }
            guard unit.first.map({ $0 & 0x1f }) == 7 else { return .malformed }
            spsUnits.append(unit)
        }

        guard let pictureParameterSetCount = cursor.readByte(), pictureParameterSetCount > 0 else {
            return .malformed
        }
        for _ in 0..<pictureParameterSetCount {
            guard let length = cursor.readUInt16(), length > 0,
                  cursor.readBytes(count: length) != nil else {
                return .malformed
            }
        }

        return combineSPSResults(spsUnits.map(parseAVCSPS))
    }

    private static func hevcConfigurationBitDepthResult(data: Data) -> CodecConfigurationBitDepthResult {
        var cursor = ByteCursor(bytes: Array(data))
        // The fixed hvcC header ends with numOfArrays at byte 22.
        guard cursor.readByte() == 1,
              cursor.readBytes(count: 21) != nil,
              let arrayCount = cursor.readByte(),
              arrayCount > 0 else {
            return .malformed
        }

        var spsUnits: [[UInt8]] = []
        for _ in 0..<arrayCount {
            guard let arrayHeader = cursor.readByte(),
                  let nalUnitCount = cursor.readUInt16() else {
                return .malformed
            }
            let nalUnitType = arrayHeader & 0x3f
            for _ in 0..<nalUnitCount {
                guard let length = cursor.readUInt16(), length > 0,
                      let unit = cursor.readBytes(count: length) else {
                    return .malformed
                }
                if nalUnitType == 33 {
                    guard unit.count >= 3,
                          unit[0] & 0x80 == 0,
                          ((unit[0] & 0x7e) >> 1) == 33 else {
                        return .malformed
                    }
                    spsUnits.append(unit)
                }
            }
        }

        guard !spsUnits.isEmpty else { return .malformed }
        return combineSPSResults(spsUnits.map(parseHEVCSPS))
    }

    private static func combineSPSResults(
        _ results: [CodecConfigurationBitDepthResult]
    ) -> CodecConfigurationBitDepthResult {
        guard !results.isEmpty else { return .malformed }
        if results.contains(where: {
            if case .malformed = $0 { return true }
            return false
        }) {
            return .malformed
        }
        if results.contains(where: {
            if case .conflicting = $0 { return true }
            return false
        }) {
            return .conflicting
        }
        if results.contains(where: {
            if case .unsupported = $0 { return true }
            return false
        }) {
            return .unsupported
        }
        let depths = Set(results.compactMap { result -> Int? in
            if case .resolved(let bitDepth) = result { return bitDepth }
            return nil
        })
        guard depths.count == 1, let depth = depths.first else { return .conflicting }
        return .resolved(depth)
    }

    private static func parseAVCSPS(_ nalUnit: [UInt8]) -> CodecConfigurationBitDepthResult {
        guard nalUnit.count >= 2,
              nalUnit[0] & 0x80 == 0,
              nalUnit[0] & 0x1f == 7,
              let rbsp = removeEmulationPreventionBytes(Array(nalUnit.dropFirst())),
              var reader = RBSPBitReader(bytes: rbsp),
              let profileID = reader.readBits(8),
              reader.readBits(8) != nil,
              reader.readBits(8) != nil,
              reader.readUnsignedExpGolomb() != nil else {
            return .malformed
        }

        let profile = Int(profileID)
        guard let syntax = avcSPSProfileSyntax(for: profile) else {
            return .unsupported
        }
        if syntax == .implicitEightBit {
            // Baseline, Main, and Extended profiles have no explicit bit-depth
            // fields in this syntax. Their normative default is zero, which is
            // the 8-bit code depth; this is not a High10 profile inference.
            return bitDepthResult(lumaMinus8: 0, chromaMinus8: 0)
        }

        guard let chromaFormatID = reader.readUnsignedExpGolomb(), chromaFormatID <= 3 else {
            return .malformed
        }
        if chromaFormatID == 3, reader.readBits(1) == nil {
            return .malformed
        }
        guard let lumaMinus8 = reader.readUnsignedExpGolomb(),
              let chromaMinus8 = reader.readUnsignedExpGolomb() else {
            return .malformed
        }
        return bitDepthResult(lumaMinus8: lumaMinus8, chromaMinus8: chromaMinus8)
    }

    private static func parseHEVCSPS(_ nalUnit: [UInt8]) -> CodecConfigurationBitDepthResult {
        guard nalUnit.count >= 3,
              nalUnit[0] & 0x80 == 0,
              ((nalUnit[0] & 0x7e) >> 1) == 33,
              let rbsp = removeEmulationPreventionBytes(Array(nalUnit.dropFirst(2))),
              var reader = RBSPBitReader(bytes: rbsp),
              reader.readBits(4) != nil,
              let maxSubLayersMinus1Bits = reader.readBits(3),
              maxSubLayersMinus1Bits <= 6,
              reader.readBits(1) != nil else {
            return .malformed
        }

        let maxSubLayersMinus1 = Int(maxSubLayersMinus1Bits)
        guard skipHEVCProfileTierLevel(
            reader: &reader,
            maxSubLayersMinus1: maxSubLayersMinus1
        ),
        reader.readUnsignedExpGolomb() != nil,
        let chromaFormatID = reader.readUnsignedExpGolomb(),
        chromaFormatID <= 3 else {
            return .malformed
        }
        if chromaFormatID == 3, reader.readBits(1) == nil {
            return .malformed
        }
        guard reader.readUnsignedExpGolomb() != nil,
              reader.readUnsignedExpGolomb() != nil,
              let conformanceWindowFlag = reader.readBits(1) else {
            return .malformed
        }
        if conformanceWindowFlag == 1 {
            guard reader.readUnsignedExpGolomb() != nil,
                  reader.readUnsignedExpGolomb() != nil,
                  reader.readUnsignedExpGolomb() != nil,
                  reader.readUnsignedExpGolomb() != nil else {
                return .malformed
            }
        }
        guard let lumaMinus8 = reader.readUnsignedExpGolomb(),
              let chromaMinus8 = reader.readUnsignedExpGolomb() else {
            return .malformed
        }
        return bitDepthResult(lumaMinus8: lumaMinus8, chromaMinus8: chromaMinus8)
    }

    private static func skipHEVCProfileTierLevel(
        reader: inout RBSPBitReader,
        maxSubLayersMinus1: Int
    ) -> Bool {
        guard reader.readBits(2) != nil,
              reader.readBits(1) != nil,
              reader.readBits(5) != nil,
              reader.readBits(32) != nil,
              reader.readBits(48) != nil,
              reader.readBits(8) != nil else {
            return false
        }

        var profilePresent = Array(repeating: false, count: maxSubLayersMinus1)
        var levelPresent = Array(repeating: false, count: maxSubLayersMinus1)
        for index in 0..<maxSubLayersMinus1 {
            guard let profileFlag = reader.readBits(1),
                  let levelFlag = reader.readBits(1) else {
                return false
            }
            profilePresent[index] = profileFlag == 1
            levelPresent[index] = levelFlag == 1
        }
        if maxSubLayersMinus1 > 0 {
            for _ in maxSubLayersMinus1..<8 {
                guard reader.readBits(2) != nil else { return false }
            }
            for index in 0..<maxSubLayersMinus1 {
                if profilePresent[index] {
                    guard reader.readBits(2) != nil,
                          reader.readBits(1) != nil,
                          reader.readBits(5) != nil,
                          reader.readBits(32) != nil,
                          reader.readBits(48) != nil else {
                        return false
                    }
                }
                if levelPresent[index], reader.readBits(8) == nil {
                    return false
                }
            }
        }
        return true
    }

    private static func bitDepthResult(
        lumaMinus8: UInt64,
        chromaMinus8: UInt64
    ) -> CodecConfigurationBitDepthResult {
        guard lumaMinus8 == chromaMinus8 else { return .conflicting }
        switch lumaMinus8 {
        case 0: return .resolved(8)
        case 2: return .resolved(10)
        default: return .unsupported
        }
    }

    private enum AVCSPSProfileSyntax {
        case implicitEightBit
        case explicitBitDepth
    }

    private static func avcSPSProfileSyntax(for profile: Int) -> AVCSPSProfileSyntax? {
        switch profile {
        case 66, 77, 88:
            return .implicitEightBit
        case 44, 83, 86, 100, 110, 118, 122, 128, 134, 135, 138, 139, 244:
            return .explicitBitDepth
        default:
            return nil
        }
    }

    // Internal seam for validating EBSP/RBSP boundary semantics without
    // coupling tests to a particular codec configuration fixture.
    static func removeEmulationPreventionBytesForTesting(_ bytes: [UInt8]) -> [UInt8]? {
        removeEmulationPreventionBytes(bytes)
    }

    private static func removeEmulationPreventionBytes(_ bytes: [UInt8]) -> [UInt8]? {
        guard !bytes.isEmpty else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var zeroCount = 0
        for index in bytes.indices {
            let byte = bytes[index]
            if zeroCount >= 2, byte == 0x03 {
                guard index < bytes.count - 1, bytes[index + 1] <= 0x03 else {
                    return nil
                }
                zeroCount = 0
                continue
            }
            result.append(byte)
            if byte == 0 {
                zeroCount = min(zeroCount + 1, 2)
            } else {
                zeroCount = 0
            }
        }
        return result
    }

    private struct ByteCursor {
        let bytes: [UInt8]
        var offset: Int = 0

        mutating func readByte() -> UInt8? {
            guard offset < bytes.count else { return nil }
            let value = bytes[offset]
            offset += 1
            return value
        }

        mutating func readUInt16() -> Int? {
            guard let high = readByte(), let low = readByte() else { return nil }
            return (Int(high) << 8) | Int(low)
        }

        mutating func readBytes(count: Int) -> [UInt8]? {
            guard count > 0, count <= bytes.count - offset else { return nil }
            let end = offset + count
            let value = Array(bytes[offset..<end])
            offset = end
            return value
        }
    }

    private struct RBSPBitReader {
        let bytes: [UInt8]
        let bitCount: Int
        var bitOffset: Int = 0

        init?(bytes: [UInt8]) {
            guard bytes.count <= Int.max / 8 else { return nil }
            self.bytes = bytes
            self.bitCount = bytes.count * 8
        }

        mutating func readBits(_ count: Int) -> UInt64? {
            guard count >= 0, count <= 64,
                  bitOffset <= bitCount,
                  count <= bitCount - bitOffset else {
                return nil
            }
            guard count > 0 else { return 0 }
            var value: UInt64 = 0
            for _ in 0..<count {
                let byteIndex = bitOffset / 8
                let bitIndex = bitOffset % 8
                let bit = (bytes[byteIndex] >> (7 - bitIndex)) & 1
                value = (value << 1) | UInt64(bit)
                bitOffset += 1
            }
            return value
        }

        mutating func readUnsignedExpGolomb() -> UInt64? {
            var leadingZeroBits = 0
            while true {
                guard let bit = readBits(1) else { return nil }
                if bit == 1 { break }
                leadingZeroBits += 1
                guard leadingZeroBits < 63 else { return nil }
            }
            guard let suffix = readBits(leadingZeroBits) else { return nil }
            let prefix = (UInt64(1) << UInt64(leadingZeroBits)) - 1
            guard UInt64.max - prefix >= suffix else { return nil }
            return prefix + suffix
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
           let data = codecConfigurationData(from: extensions, atomName: atomName) {
            switch codecConfigurationBitDepthResult(codec: codec, data: data) {
            case .resolved(let bitDepth):
                return ParsedDescription(codec: codec, bitDepth: bitDepth, evidence: .codecConfiguration)
            case .conflicting:
                return ParsedDescription(codec: codec, bitDepth: nil, evidence: .conflicting)
            case .unsupported:
                return ParsedDescription(codec: codec, bitDepth: nil, evidence: .unsupported)
            case .malformed:
                return ParsedDescription(codec: codec, bitDepth: nil, evidence: .unresolved)
            }
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
