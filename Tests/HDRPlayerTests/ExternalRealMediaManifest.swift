import Foundation
import HDRCore

enum ExternalMediaSplit: String, Codable, Sendable {
    case development
    case validation
}

enum ExternalMediaEngineEvaluation: String, Codable, Sendable {
    case runtime
    case metadataOnly = "metadata-only"
}

enum ExternalMediaCategory: String, Codable, Sendable {
    case darkFilmLike = "dark-film-like"
    case brightOutdoor = "bright-outdoor"
    case skinFace = "skin-face"
    case nightNeon = "night-neon"
    case animationCG = "animation-cg"
    case screenUIText = "screen-ui-text"
    case fastMotion = "fast-motion"
    case smokeFog = "smoke-fog"
    case highSaturation = "high-saturation"
    case lowSaturation = "low-saturation"
    case gradient
}

struct ExternalMediaWindow: Codable, Equatable, Sendable {
    let startFraction: Double
    let duration: Double

    func resolve(totalDuration: Double) throws -> (start: Double, duration: Double) {
        guard totalDuration.isFinite, totalDuration > 0,
              startFraction.isFinite, (0..<1).contains(startFraction),
              duration.isFinite, duration > 0 else {
            throw ExternalMediaManifestError.invalid("invalid representative media window")
        }
        let start = totalDuration * startFraction
        let resolvedDuration = min(duration, totalDuration - start)
        guard resolvedDuration > 0 else {
            throw ExternalMediaManifestError.invalid("representative window starts beyond media duration")
        }
        return (start, resolvedDuration)
    }
}

struct ExternalMediaExpectedMetadata: Codable, Equatable, Sendable {
    let codec: RegressionCodec?
    let profile: String?
    let bitDepth: Int?
    let range: RegressionRange?
    let primaries: String?
    let transfer: String?
    let matrix: String?
    let frameRate: Double?
    let timing: RegressionTimingMode?
    let minimumDistinctFrameDurations: Int?
    let allowedChromaSiting: [HDRChromaSiting]?
}

struct ExternalMediaProvenance: Codable, Equatable, Sendable {
    let sourceFamily: String
    let split: ExternalMediaSplit
    let category: ExternalMediaCategory
    let sha256: String
    let licenseNote: String?
}

struct ExternalRealMediaSource: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let fileName: String
    let sha256: String
    let sourceFamily: String
    let split: ExternalMediaSplit
    let category: ExternalMediaCategory
    let licenseNote: String?
    let expected: ExternalMediaExpectedMetadata
    let windows: [ExternalMediaWindow]
    let engineEvaluation: ExternalMediaEngineEvaluation?

    var provenance: ExternalMediaProvenance {
        ExternalMediaProvenance(
            sourceFamily: sourceFamily,
            split: split,
            category: category,
            sha256: sha256,
            licenseNote: licenseNote
        )
    }
}

struct MatchedMediaPair: Codable, Equatable, Sendable, Identifiable {
    let pairID: String
    let sdrSourceID: String
    let hdrSourceID: String

    var id: String { pairID }
}

struct ExternalRealMediaManifest: Codable, Equatable, Sendable {
    let version: Int
    let sources: [ExternalRealMediaSource]
    let pairs: [MatchedMediaPair]

    static let expectedVersion = 1

    func validate() throws {
        guard version == Self.expectedVersion else {
            throw ExternalMediaManifestError.invalid("unsupported external manifest version \(version)")
        }
        let sourceIDs = sources.map(\.id)
        guard Set(sourceIDs).count == sourceIDs.count else {
            throw ExternalMediaManifestError.invalid("external media source IDs are not unique")
        }
        var familySplits: [String: Set<ExternalMediaSplit>] = [:]
        for source in sources {
            guard !source.id.isEmpty, !source.sourceFamily.isEmpty else {
                throw ExternalMediaManifestError.invalid("external source identity is empty")
            }
            guard !source.fileName.isEmpty,
                  !source.fileName.hasPrefix("/"),
                  !source.fileName.split(separator: "/").contains("..") else {
                throw ExternalMediaManifestError.invalid("external source \(source.id) has an unsafe fileName")
            }
            guard source.sha256.count == 64,
                  source.sha256.unicodeScalars.allSatisfy({ scalar in
                      switch scalar.value {
                      case 48...57, 65...70, 97...102: return true
                      default: return false
                      }
                  }) else {
                throw ExternalMediaManifestError.invalid("external source \(source.id) has an invalid SHA-256")
            }
            guard !source.windows.isEmpty else {
                throw ExternalMediaManifestError.invalid("external source \(source.id) has no representative windows")
            }
            for window in source.windows {
                guard window.startFraction.isFinite, (0..<1).contains(window.startFraction),
                      window.duration.isFinite, window.duration > 0 else {
                    throw ExternalMediaManifestError.invalid("external source \(source.id) has an invalid window")
                }
            }
            if let bitDepth = source.expected.bitDepth {
                guard bitDepth == 8 || bitDepth == 10 else {
                    throw ExternalMediaManifestError.invalid("external source \(source.id) has unsupported bit depth")
                }
            }
            if let frameRate = source.expected.frameRate {
                guard frameRate.isFinite, frameRate > 0 else {
                    throw ExternalMediaManifestError.invalid("external source \(source.id) has invalid frame rate")
                }
            }
            if let minimum = source.expected.minimumDistinctFrameDurations {
                guard minimum > 0 else {
                    throw ExternalMediaManifestError.invalid("external source \(source.id) has invalid timing requirement")
                }
            }
            familySplits[source.sourceFamily, default: []].insert(source.split)
        }
        if familySplits.contains(where: { $0.value.count > 1 }) {
            throw ExternalMediaManifestError.sourceFamilySplitLeakage
        }
        let pairIDs = pairs.map(\.pairID)
        guard Set(pairIDs).count == pairIDs.count else {
            throw ExternalMediaManifestError.invalid("matched media pair IDs are not unique")
        }
        let sourceIDSet = Set(sourceIDs)
        for pair in pairs {
            guard sourceIDSet.contains(pair.sdrSourceID), sourceIDSet.contains(pair.hdrSourceID),
                  pair.sdrSourceID != pair.hdrSourceID else {
                throw ExternalMediaManifestError.invalid("matched media pair \(pair.pairID) references invalid sources")
            }
        }
    }

    func sources(for split: ExternalMediaSplit) -> [ExternalRealMediaSource] {
        sources.filter { $0.split == split }.sorted { $0.id < $1.id }
    }

    static func load(from url: URL) throws -> Self {
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try manifest.validate()
        return manifest
    }
}

enum ExternalMediaManifestError: Error, LocalizedError, Equatable {
    case invalid(String)
    case sourceFamilySplitLeakage

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .sourceFamilySplitLeakage: return "SOURCE_FAMILY_SPLIT_LEAKAGE"
        }
    }
}
