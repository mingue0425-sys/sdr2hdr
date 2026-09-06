import Foundation

/// Single source of truth for command-line and benchmark preset names. The
/// default remains the promoted calibrated V4 configuration.
public enum HDRPresetResolver {
    public static let productionDefault = "calibrated-v4"

    public static var supportedPresetNames: [String] {
        ["natural", "hdr", "vivid", "calibrated-v1", "calibrated-v2", "calibrated-v4", "calibrated-v3-candidate"] +
            HDRV6ToneCurveCandidate.allCases.map(\.rawValue) +
            HDRV62ToneCurveCandidate.allCases.map(\.rawValue)
    }

    public static func configuration(for name: String) -> HDRConfiguration? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let candidate = HDRV62ToneCurveCandidate(rawValue: normalized) {
            return candidate.configuration()
        }
        if let candidate = HDRV6ToneCurveCandidate(rawValue: normalized) {
            return candidate.configuration()
        }
        switch normalized {
        case "natural": return .natural
        case "hdr": return .hdr
        case "vivid": return .vivid
        case "calibrated-v1": return .calibratedV1
        case "calibrated-v2": return .calibratedV2
        case "calibrated-v4": return .calibratedV4
        case "calibrated-v3-candidate": return .calibratedV3Candidate
        default: return nil
        }
    }
}
