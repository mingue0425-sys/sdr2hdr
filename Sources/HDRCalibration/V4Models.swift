import Foundation

/// V4 deliberately uses a separate manifest model.  The V1/V2/V3 manifest is
/// kept source-compatible so historical experiments remain reproducible.
public enum V4ExpectedRelation: String, Codable, CaseIterable, Sendable {
    case sameMaster = "same-master"
    case sameSource = "same-source"
    case sameContentDifferentGrade = "same-content-different-grade"
    case relatedContent = "related-content"
    case unknown

    public var supportsMainCalibration: Bool {
        self == .sameMaster || self == .sameSource
    }

    public func legacyRelation() -> ExpectedRelation {
        switch self {
        case .sameMaster: return .sameMaster
        case .sameSource: return .sameSource
        case .sameContentDifferentGrade: return .sameContentDifferentGrade
        case .relatedContent: return .relatedContent
        case .unknown: return .unknown
        }
    }
}

public struct V4PairRecord: Codable, Hashable, Sendable {
    public var id: String
    public var sdr: String
    public var hdr: String
    public var source: String
    public var sourceURL: String?
    public var license: String
    public var licenseURL: String?
    public var expectedRelation: V4ExpectedRelation
    public var contentCategory: [String]
    public var contentFamily: String?
    /// Explicit source-documented fallback only when the container omits a
    /// transfer/primary tag. It is never inferred from a filename.
    public var referenceTransfer: String?
    public var referencePrimaries: String?
    public var split: DatasetSplit
    public var virginFrozen: Bool
    public var group: String?
    public var notes: String?
    public var metadataSummary: V4ManifestMetadataSummary?

    public init(
        id: String,
        sdr: String,
        hdr: String,
        source: String,
        sourceURL: String? = nil,
        license: String,
        licenseURL: String? = nil,
        expectedRelation: V4ExpectedRelation,
        contentCategory: [String] = [],
        contentFamily: String? = nil,
        referenceTransfer: String? = nil,
        referencePrimaries: String? = nil,
        split: DatasetSplit,
        virginFrozen: Bool = false,
        group: String? = nil,
        notes: String? = nil,
        metadataSummary: V4ManifestMetadataSummary? = nil
    ) {
        self.id = id
        self.sdr = sdr
        self.hdr = hdr
        self.source = source
        self.sourceURL = sourceURL
        self.license = license
        self.licenseURL = licenseURL
        self.expectedRelation = expectedRelation
        self.contentCategory = contentCategory
        self.contentFamily = contentFamily
        self.referenceTransfer = referenceTransfer
        self.referencePrimaries = referencePrimaries
        self.split = split
        self.virginFrozen = virginFrozen
        self.group = group
        self.notes = notes
        self.metadataSummary = metadataSummary
    }

    public func resolvedURLs(
        relativeTo manifestURL: URL,
        roots: [String: String] = [:]
    ) -> (sdr: URL, hdr: URL) {
        let base = manifestURL.deletingLastPathComponent().standardizedFileURL
        func resolve(_ path: String) -> URL {
            let variants = [
                path,
                path.precomposedStringWithCanonicalMapping,
                path.decomposedStringWithCanonicalMapping
            ]
            let urls = variants.map { variant -> URL in
                if let separator = variant.firstIndex(of: ":") {
                    let alias = String(variant[..<separator])
                    if let root = roots[alias], !root.isEmpty {
                        let relative = String(variant[variant.index(after: separator)...])
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        let rootURL = root.hasPrefix("/")
                            ? URL(fileURLWithPath: root)
                            : base.appendingPathComponent(root)
                        return rootURL.appendingPathComponent(relative).standardizedFileURL
                    }
                }
                if variant.hasPrefix("/") {
                    return URL(fileURLWithPath: variant).standardizedFileURL
                }
                return base.appendingPathComponent(variant).standardizedFileURL
            }
            return urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) ?? urls[0]
        }
        return (resolve(sdr), resolve(hdr))
    }
}

public struct V4Manifest: Codable, Sendable {
    public var version: Int
    public var pairs: [V4PairRecord]
    public var roots: [String: String]

    public init(version: Int = 4, pairs: [V4PairRecord], roots: [String: String] = [:]) {
        self.version = version
        self.pairs = pairs
        self.roots = roots
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case pairs
        case roots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        pairs = try container.decode([V4PairRecord].self, forKey: .pairs)
        roots = try container.decodeIfPresent([String: String].self, forKey: .roots) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(pairs, forKey: .pairs)
        if !roots.isEmpty {
            try container.encode(roots, forKey: .roots)
        }
    }

    public static func load(from url: URL) throws -> V4Manifest {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(V4Manifest.self, from: data)
        try manifest.validate(relativeTo: url)
        return manifest
    }

    public func validate(relativeTo manifestURL: URL) throws {
        guard version == 4 else {
            throw CalibrationError.invalidManifest("V4 manifest version must be 4, got \(version)")
        }
        var ids = Set<String>()
        var mediaPaths = Set<String>()
        var groupSplits: [String: DatasetSplit] = [:]
        for pair in pairs {
            guard !pair.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CalibrationError.invalidManifest("V4 pair id must not be empty")
            }
            guard ids.insert(pair.id).inserted else {
                throw CalibrationError.invalidManifest("duplicate V4 pair id: \(pair.id)")
            }
            guard !pair.sdr.isEmpty, !pair.hdr.isEmpty else {
                throw CalibrationError.invalidManifest("pair \(pair.id) has an empty SDR/HDR path")
            }
            guard !pair.source.isEmpty, !pair.license.isEmpty else {
                throw CalibrationError.invalidManifest("pair \(pair.id) must record source and license")
            }
            guard !pair.contentCategory.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw CalibrationError.invalidManifest("pair \(pair.id) contains an empty content category")
            }
            if pair.virginFrozen && pair.split != .frozen {
                throw CalibrationError.invalidManifest("virginFrozen pair \(pair.id) must be in frozen split")
            }
            if let group = pair.group, !group.isEmpty {
                if let previous = groupSplits[group], previous != pair.split {
                    throw CalibrationError.invalidManifest("source group \(group) crosses video splits")
                }
                groupSplits[group] = pair.split
            }
            let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: roots)
            for url in [urls.sdr, urls.hdr] {
                guard mediaPaths.insert(url.standardizedFileURL.path).inserted else {
                    throw CalibrationError.invalidManifest("same physical media path appears more than once: \(url.path)")
                }
            }
        }
    }
}

public struct V4FileDigest: Codable, Hashable, Sendable {
    public var path: String
    public var sizeBytes: Int64
    public var sha256: String

    public init(path: String, sizeBytes: Int64, sha256: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }

    /// Portable identity for repository-backed evidence. Existing absolute-path
    /// artifacts remain decodable and can still be resolved locally.
    public func portablePath(repositoryRoot: URL) -> String {
        if path.hasPrefix("repo:") { return path }
        return V4EvidencePath.portable(URL(fileURLWithPath: path), repositoryRoot: repositoryRoot)
    }

    public func localURL(repositoryRoot: URL, expectedURL: URL? = nil) -> URL {
        if path.hasPrefix("repo:") {
            return repositoryRoot.appendingPathComponent(String(path.dropFirst(5)))
        }
        if let expectedURL {
            return expectedURL
        }
        return URL(fileURLWithPath: path)
    }
}

public enum V4EvidencePath {
    public static func portable(_ url: URL, repositoryRoot: URL) -> String {
        let standardizedPath = url.standardizedFileURL.path
        let rootPath = repositoryRoot.standardizedFileURL.path
        guard standardizedPath.hasPrefix(rootPath + "/") else { return standardizedPath }
        return "repo:\(standardizedPath.dropFirst(rootPath.count + 1))"
    }
}

public struct V4DatasetLock: Codable, Sendable {
    public var version: Int
    public var manifestSHA256: String
    public var generatedAt: String
    public var files: [V4FileDigest]

    public init(version: Int = 1, manifestSHA256: String, files: [V4FileDigest]) {
        self.version = version
        self.manifestSHA256 = manifestSHA256
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.files = files
    }
}

public enum V4Suitability: String, Codable, Sendable {
    case mainCalibration = "MAIN_CALIBRATION"
    case conditional = "CONDITIONAL"
    case diagnosticOnly = "DIAGNOSTIC_ONLY"
    case reject = "REJECT"
}

public enum V4PairAuditStatus: String, Codable, Sendable {
    case accepted = "ACCEPTED"
    case conditional = "CONDITIONAL"
    case missingFile = "MISSING_FILE"
    case invalidMetadata = "INVALID_METADATA"
    case invalidHDRReference = "INVALID_HDR_REFERENCE"
    case duplicateMedia = "DUPLICATE_MEDIA_CONTENT"
    case decodeFailed = "DECODE_FAILED"
    case alignmentUnreliable = "ALIGNMENT_UNRELIABLE"
    case differentEdit = "DIFFERENT_EDIT"
    case uncertainRelation = "UNCERTAIN_RELATION"
}

public enum V4DatasetVerdict: String, Codable, Sendable {
    case ready = "DATASET_V4_READY"
    case partial = "DATASET_V4_PARTIAL"
    case insufficient = "DATASET_INSUFFICIENT"
    case noValidNewPairs = "NO_VALID_NEW_PAIRS"
    case licenseBlocked = "LICENSE_BLOCKED"
    case alignmentUnreliable = "ALIGNMENT_UNRELIABLE"
}

public struct V4StreamMetadata: Codable, Sendable {
    public var path: String
    public var durationSeconds: Double
    public var frameRate: Double
    public var timeBase: String?
    public var codec: String?
    public var width: Int
    public var height: Int
    public var pixelFormat: String?
    public var bitDepth: Int?
    public var colorRange: String?
    public var colorPrimaries: String?
    public var transfer: String?
    public var matrix: String?
    public var masteringMetadataPresent: Bool
    public var maxCLL: Float?
    public var maxFALL: Float?
    public var audioTrackCount: Int
    public var probeTool: String

    public init(
        path: String,
        durationSeconds: Double,
        frameRate: Double,
        timeBase: String?,
        codec: String?,
        width: Int,
        height: Int,
        pixelFormat: String?,
        bitDepth: Int?,
        colorRange: String?,
        colorPrimaries: String?,
        transfer: String?,
        matrix: String?,
        masteringMetadataPresent: Bool,
        maxCLL: Float? = nil,
        maxFALL: Float? = nil,
        audioTrackCount: Int,
        probeTool: String
    ) {
        self.path = path
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
        self.timeBase = timeBase
        self.codec = codec
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.bitDepth = bitDepth
        self.colorRange = colorRange
        self.colorPrimaries = colorPrimaries
        self.transfer = transfer
        self.matrix = matrix
        self.masteringMetadataPresent = masteringMetadataPresent
        self.maxCLL = maxCLL
        self.maxFALL = maxFALL
        self.audioTrackCount = audioTrackCount
        self.probeTool = probeTool
    }

    public var transferFamily: String {
        let value = (transfer ?? "").lowercased()
        if value.contains("2084") || value.contains("pq") { return "PQ" }
        if value.contains("hlg") || value.contains("2100") || value.contains("arib") { return "HLG" }
        if value.contains("709") || value.contains("1886") || value.contains("srgb") || value.contains("gamma") {
            return "SDR"
        }
        return "UNKNOWN"
    }

    public var isHDRReference: Bool {
        let primaries = (colorPrimaries ?? "").lowercased()
        return (transferFamily == "PQ" || transferFamily == "HLG") && primaries.contains("2020")
    }

    /// Main calibration accepts only explicitly tagged BT.709 SDR. Missing
    /// colorimetry is not a safe inference point because the reference loss
    /// function would otherwise mix unknown transfer/matrix semantics.
    public var isExplicitBT709SDR: Bool {
        let primaries = (colorPrimaries ?? "").lowercased()
        let matrix = (matrix ?? "").lowercased()
        let range = (colorRange ?? "").lowercased()
        let supportedRange = ["tv", "mpeg", "limited", "pc", "jpeg", "full"].contains(range)
        let transferValue = (transfer ?? "").lowercased()
        let supportedTransferValues = [
            "bt709", "bt.709", "bt1886", "bt.1886", "gamma22", "gamma28",
            "srgb", "iec61966-2-1"
        ]
        let supportedTransfer = supportedTransferValues.contains(transferValue)
        return supportedTransfer && primaries.contains("709") && matrix.contains("709") && supportedRange
    }

    public var isSDRReference: Bool {
        isExplicitBT709SDR
    }
}

public struct V4DecodeSmoke: Codable, Sendable {
    public var attempted: Bool
    public var firstFrame: Bool
    public var middleFrame: Bool
    public var lastFrame: Bool
    public var decodedSampleCount: Int
    public var error: String?

    public init(
        attempted: Bool = false,
        firstFrame: Bool = false,
        middleFrame: Bool = false,
        lastFrame: Bool = false,
        decodedSampleCount: Int = 0,
        error: String? = nil
    ) {
        self.attempted = attempted
        self.firstFrame = firstFrame
        self.middleFrame = middleFrame
        self.lastFrame = lastFrame
        self.decodedSampleCount = decodedSampleCount
        self.error = error
    }

    public var passed: Bool { attempted && firstFrame && middleFrame && lastFrame }
}

public struct V4AlignmentSummary: Codable, Sendable {
    public var sampledFrames: Int
    public var matchedFrames: Int
    public var rejectedFrames: Int
    public var matchRatio: Double
    public var meanConfidence: Double
    public var medianConfidence: Double
    public var p10Confidence: Double
    public var p50Confidence: Double
    public var p90Confidence: Double
    public var confidenceAtLeast60: Double
    public var confidenceAtLeast70: Double
    public var confidenceAtLeast80: Double
    public var estimatedTimeOffsetSeconds: Double
    public var offsetVariance: Double
    public var spatialChecks: [String]
    public var status: String

    public init(
        sampledFrames: Int = 0,
        matchedFrames: Int = 0,
        rejectedFrames: Int = 0,
        matchRatio: Double = 0,
        meanConfidence: Double = 0,
        medianConfidence: Double = 0,
        p10Confidence: Double = 0,
        p50Confidence: Double = 0,
        p90Confidence: Double = 0,
        confidenceAtLeast60: Double = 0,
        confidenceAtLeast70: Double = 0,
        confidenceAtLeast80: Double = 0,
        estimatedTimeOffsetSeconds: Double = 0,
        offsetVariance: Double = 0,
        spatialChecks: [String] = [],
        status: String = "UNALIGNED"
    ) {
        self.sampledFrames = sampledFrames
        self.matchedFrames = matchedFrames
        self.rejectedFrames = rejectedFrames
        self.matchRatio = matchRatio
        self.meanConfidence = meanConfidence
        self.medianConfidence = medianConfidence
        self.p10Confidence = p10Confidence
        self.p50Confidence = p50Confidence
        self.p90Confidence = p90Confidence
        self.confidenceAtLeast60 = confidenceAtLeast60
        self.confidenceAtLeast70 = confidenceAtLeast70
        self.confidenceAtLeast80 = confidenceAtLeast80
        self.estimatedTimeOffsetSeconds = estimatedTimeOffsetSeconds
        self.offsetVariance = offsetVariance
        self.spatialChecks = spatialChecks
        self.status = status
    }
}

public enum V4AlignmentPolicy {
    public static let minimumMatchedFrames = 8
    public static let minimumMatchRatio = 0.60
    public static let minimumP10Confidence = 0.60
    public static let alignedMedianConfidence = 0.70

    public static func status(
        sampledFrames: Int,
        matchedFrames: Int,
        medianConfidence: Double,
        p10Confidence: Double
    ) -> String {
        guard sampledFrames >= minimumMatchedFrames,
              matchedFrames >= minimumMatchedFrames else {
            return "REJECT"
        }
        let matchRatio = Double(matchedFrames) / Double(sampledFrames)
        guard matchRatio.isFinite,
              matchRatio >= minimumMatchRatio,
              medianConfidence.isFinite,
              p10Confidence.isFinite else {
            return "REJECT"
        }
        // A dense but lower-confidence sample remains usable for structural
        // preparation and is reported as CONDITIONAL.  Sparse survivors are
        // rejected above; the audit/main-calibration gate still requires the
        // stronger ALIGNED p10/median thresholds in supportsMainCalibration.
        return medianConfidence >= alignedMedianConfidence && p10Confidence >= minimumP10Confidence
            ? "ALIGNED" : "CONDITIONAL"
    }

    public static func supportsMainCalibration(_ summary: V4AlignmentSummary) -> Bool {
        summary.status == "ALIGNED" && status(
            sampledFrames: summary.sampledFrames,
            matchedFrames: summary.matchedFrames,
            medianConfidence: summary.medianConfidence,
            p10Confidence: summary.p10Confidence
        ) == "ALIGNED"
    }
}

public struct V4PairAudit: Codable, Sendable {
    public var id: String
    public var source: String
    public var split: DatasetSplit
    public var virginFrozen: Bool
    public var expectedRelation: V4ExpectedRelation
    public var suitability: V4Suitability
    public var status: V4PairAuditStatus
    public var sdrPath: String
    public var hdrPath: String
    public var sdrDigest: V4FileDigest?
    public var hdrDigest: V4FileDigest?
    public var sdrMetadata: V4StreamMetadata?
    public var hdrMetadata: V4StreamMetadata?
    public var sdrTransferFamily: String?
    public var hdrTransferFamily: String?
    public var sdrReferenceValid: Bool?
    public var hdrReferenceValid: Bool?
    public var sdrDecode: V4DecodeSmoke
    public var hdrDecode: V4DecodeSmoke
    public var alignment: V4AlignmentSummary
    public var notes: [String]

    public init(
        id: String,
        source: String,
        split: DatasetSplit,
        virginFrozen: Bool,
        expectedRelation: V4ExpectedRelation,
        suitability: V4Suitability,
        status: V4PairAuditStatus,
        sdrPath: String,
        hdrPath: String,
        sdrDigest: V4FileDigest? = nil,
        hdrDigest: V4FileDigest? = nil,
        sdrMetadata: V4StreamMetadata? = nil,
        hdrMetadata: V4StreamMetadata? = nil,
        sdrTransferFamily: String? = nil,
        hdrTransferFamily: String? = nil,
        sdrReferenceValid: Bool? = nil,
        hdrReferenceValid: Bool? = nil,
        sdrDecode: V4DecodeSmoke = V4DecodeSmoke(),
        hdrDecode: V4DecodeSmoke = V4DecodeSmoke(),
        alignment: V4AlignmentSummary = V4AlignmentSummary(),
        notes: [String] = []
    ) {
        self.id = id
        self.source = source
        self.split = split
        self.virginFrozen = virginFrozen
        self.expectedRelation = expectedRelation
        self.suitability = suitability
        self.status = status
        self.sdrPath = sdrPath
        self.hdrPath = hdrPath
        self.sdrDigest = sdrDigest
        self.hdrDigest = hdrDigest
        self.sdrMetadata = sdrMetadata
        self.hdrMetadata = hdrMetadata
        self.sdrTransferFamily = sdrTransferFamily
        self.hdrTransferFamily = hdrTransferFamily
        self.sdrReferenceValid = sdrReferenceValid
        self.hdrReferenceValid = hdrReferenceValid
        self.sdrDecode = sdrDecode
        self.hdrDecode = hdrDecode
        self.alignment = alignment
        self.notes = notes
    }
}

public struct V4DiversityReport: Codable, Sendable {
    public var totalPairs: Int
    public var acceptedPairs: Int
    public var conditionalPairs: Int
    public var rejectedPairs: Int
    public var mainCalibrationPairs: Int
    public var tunePairs: Int
    public var validationPairs: Int
    public var frozenPairs: Int
    public var virginFrozenPairs: Int
    public var contentFamilies: [String: Int]
    public var categories: [String: Int]
    public var hdrTransfers: [String: Int]
    public var resolutions: [String: Int]
    public var frameRates: [String: Int]

    public init(
        totalPairs: Int = 0,
        acceptedPairs: Int = 0,
        conditionalPairs: Int = 0,
        rejectedPairs: Int = 0,
        mainCalibrationPairs: Int = 0,
        tunePairs: Int = 0,
        validationPairs: Int = 0,
        frozenPairs: Int = 0,
        virginFrozenPairs: Int = 0,
        contentFamilies: [String: Int] = [:],
        categories: [String: Int] = [:],
        hdrTransfers: [String: Int] = [:],
        resolutions: [String: Int] = [:],
        frameRates: [String: Int] = [:]
    ) {
        self.totalPairs = totalPairs
        self.acceptedPairs = acceptedPairs
        self.conditionalPairs = conditionalPairs
        self.rejectedPairs = rejectedPairs
        self.mainCalibrationPairs = mainCalibrationPairs
        self.tunePairs = tunePairs
        self.validationPairs = validationPairs
        self.frozenPairs = frozenPairs
        self.virginFrozenPairs = virginFrozenPairs
        self.contentFamilies = contentFamilies
        self.categories = categories
        self.hdrTransfers = hdrTransfers
        self.resolutions = resolutions
        self.frameRates = frameRates
    }
}

public struct V4DatasetAuditReport: Codable, Sendable {
    public var version: String
    /// Hash of the audit policy and implementation contract that produced
    /// this evidence. Older reports decode with nil and are rejected by the
    /// calibration evidence validator rather than silently reused.
    public var auditConfigHash: String?
    public var generatedAt: String
    public var manifestPath: String
    public var manifestSHA256: String
    public var objectiveEvaluated: Bool
    public var frozenObjectiveEvaluated: [String]
    public var verdict: V4DatasetVerdict
    public var gateReasons: [String]
    public var pairs: [V4PairAudit]
    public var diversity: V4DiversityReport
    public var notes: [String]

    public init(
        manifestPath: String,
        manifestSHA256: String,
        pairs: [V4PairAudit],
        diversity: V4DiversityReport,
        notes: [String],
        verdict: V4DatasetVerdict = .partial,
        gateReasons: [String] = [],
        auditConfigHash: String? = nil
    ) {
        self.version = V4DatasetAuditor.auditEvidenceVersion
        self.auditConfigHash = auditConfigHash ?? V4DatasetAuditor.auditConfigurationHash
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.manifestPath = manifestPath
        self.manifestSHA256 = manifestSHA256
        self.objectiveEvaluated = false
        self.frozenObjectiveEvaluated = []
        self.verdict = verdict
        self.gateReasons = gateReasons
        self.pairs = pairs
        self.diversity = diversity
        self.notes = notes
    }
}

public struct V4AcquisitionRecord: Codable, Sendable {
    public var candidate: String
    public var status: String
    public var sourceURL: String?
    public var license: String?
    public var reason: String
    public var localPaths: [String]

    public init(
        candidate: String,
        status: String,
        sourceURL: String? = nil,
        license: String? = nil,
        reason: String,
        localPaths: [String] = []
    ) {
        self.candidate = candidate
        self.status = status
        self.sourceURL = sourceURL
        self.license = license
        self.reason = reason
        self.localPaths = localPaths
    }
}

public struct V4AcquisitionReport: Codable, Sendable {
    public var generatedAt: String
    public var records: [V4AcquisitionRecord]

    public init(records: [V4AcquisitionRecord]) {
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.records = records
    }
}

public enum V4FrozenAccessPhase: String, Sendable {
    case metadata
    case decodeSmoke
    case alignment
    case objective
}

/// Dataset audit may inspect virgin frozen media, but it must never request an
/// objective score.  Keeping this guard separate from the V2/V3 guard makes
/// accidental reuse of a calibration runner impossible in the V4 audit path.
public struct V4FrozenAccessGuard: Sendable {
    public init() {}

    public func authorize(pair: V4PairRecord, phase: V4FrozenAccessPhase) throws {
        if pair.virginFrozen && phase == .objective {
            throw CalibrationError.invalidCandidate("virgin frozen objective access is forbidden during dataset audit: \(pair.id)")
        }
    }
}
