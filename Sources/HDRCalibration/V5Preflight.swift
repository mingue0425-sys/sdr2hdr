import Foundation

/// The temporal-window contract is fixed before any V5 search.  A window may
/// be shorter than the target only when it has at least the preregistered
/// minimum paired frames; zero-frame and below-minimum windows are rejected.
public enum V4TemporalWindowAcceptanceReason: String, Codable, Sendable {
    case fullTargetLength = "FULL_TARGET_LENGTH"
    case validShortWindowAboveMinimum = "VALID_SHORT_WINDOW_ABOVE_MINIMUM"
    case rejectedBelowMinimum = "REJECTED_BELOW_MINIMUM"
    case decodeFailure = "DECODE_FAILURE"
    case noAlignedAnchor = "NO_ALIGNED_ANCHOR"
}

public struct V4TemporalWindowDecision: Codable, Sendable, Equatable, Hashable {
    public let targetFrameCount: Int
    public let minimumRequiredFrameCount: Int
    public let actualDecodedFrameCount: Int
    public let warmupFrameCount: Int
    public let measuredFrameCount: Int
    public let fullLength: Bool
    public let accepted: Bool
    public let acceptanceReason: V4TemporalWindowAcceptanceReason

    public init(
        targetFrameCount: Int,
        minimumRequiredFrameCount: Int,
        actualDecodedFrameCount: Int,
        warmupFrameCount: Int,
        measuredFrameCount: Int,
        fullLength: Bool,
        accepted: Bool,
        acceptanceReason: V4TemporalWindowAcceptanceReason
    ) {
        self.targetFrameCount = targetFrameCount
        self.minimumRequiredFrameCount = minimumRequiredFrameCount
        self.actualDecodedFrameCount = actualDecodedFrameCount
        self.warmupFrameCount = warmupFrameCount
        self.measuredFrameCount = measuredFrameCount
        self.fullLength = fullLength
        self.accepted = accepted
        self.acceptanceReason = acceptanceReason
    }
}

public struct V4TemporalWindowPolicy: Codable, Sendable, Equatable {
    public let targetFrameCount: Int
    public let minimumRequiredFrameCount: Int
    public let warmupFrameCount: Int
    /// Windows are equally weighted at the scene/window level.  Frames only
    /// contribute within their own window, so a 16-frame window cannot drown
    /// out an 11-frame window merely by having more samples.
    public let weightingPolicy: String

    public init(
        targetFrameCount: Int = 16,
        minimumRequiredFrameCount: Int = 8,
        warmupFrameCount: Int = 1,
        weightingPolicy: String = "EQUAL_SCENE_WINDOW_WEIGHT;FRAMES_WITHIN_WINDOW_ONLY"
    ) {
        self.targetFrameCount = targetFrameCount
        self.minimumRequiredFrameCount = minimumRequiredFrameCount
        self.warmupFrameCount = warmupFrameCount
        self.weightingPolicy = weightingPolicy
        precondition(targetFrameCount > 0)
        precondition(minimumRequiredFrameCount > 0 && minimumRequiredFrameCount <= targetFrameCount)
        precondition(warmupFrameCount >= 0 && warmupFrameCount < targetFrameCount)
    }

    public static let v5 = V4TemporalWindowPolicy()

    public func decision(actualDecodedFrameCount: Int) -> V4TemporalWindowDecision {
        let actual = max(actualDecodedFrameCount, 0)
        let full = actual >= targetFrameCount
        let accepted = actual >= minimumRequiredFrameCount
        let reason: V4TemporalWindowAcceptanceReason
        if full {
            reason = .fullTargetLength
        } else if accepted {
            reason = .validShortWindowAboveMinimum
        } else {
            reason = .rejectedBelowMinimum
        }
        return V4TemporalWindowDecision(
            targetFrameCount: targetFrameCount,
            minimumRequiredFrameCount: minimumRequiredFrameCount,
            actualDecodedFrameCount: actual,
            warmupFrameCount: min(warmupFrameCount, actual),
            measuredFrameCount: max(actual - warmupFrameCount, 0),
            fullLength: full,
            accepted: accepted,
            acceptanceReason: reason
        )
    }

    public func failureDecision(reason: V4TemporalWindowAcceptanceReason) -> V4TemporalWindowDecision {
        V4TemporalWindowDecision(
            targetFrameCount: targetFrameCount,
            minimumRequiredFrameCount: minimumRequiredFrameCount,
            actualDecodedFrameCount: 0,
            warmupFrameCount: 0,
            measuredFrameCount: 0,
            fullLength: false,
            accepted: false,
            acceptanceReason: reason
        )
    }
}

public enum V4CoverageAuditEligibility {
    public static func isEligible(_ pair: V4PairAudit) -> Bool {
        pair.status == .accepted &&
            pair.suitability == .mainCalibration &&
            pair.sdrReferenceValid == true &&
            pair.hdrReferenceValid == true &&
            pair.sdrDecode.passed &&
            pair.hdrDecode.passed &&
            V4AlignmentPolicy.supportsMainCalibration(pair.alignment)
    }
}

public struct V4FrozenCoveragePolicy: Codable, Sendable, Equatable {
    public let version: String
    public let requiredTransfers: Set<String>
    /// Kept empty deliberately: family names are not hard-coded into the V5
    /// gate.  Generalisation is preregistered as a diversity requirement.
    public let requiredFamilies: Set<String>
    public let minimumVirginFrozenPairs: Int
    public let minimumDistinctVirginFrozenFamilies: Int
    public let rationale: [String]

    public init(
        version: String = "pre-v6-frozen-coverage-v1",
        requiredTransfers: Set<String> = ["HLG", "PQ"],
        requiredFamilies: Set<String> = [],
        minimumVirginFrozenPairs: Int = 3,
        minimumDistinctVirginFrozenFamilies: Int = 2,
        rationale: [String] = [
            "HLG and PQ are both production input/reference transfer families and must be represented in Virgin Frozen.",
            "Family diversity tests distributional generalisation; a legacy family name is not itself a scientific requirement.",
            "At least three virgin pairs and two distinct virgin families provide a preregistered minimum holdout breadth."
        ]
    ) {
        self.version = version
        self.requiredTransfers = requiredTransfers
        self.requiredFamilies = requiredFamilies
        self.minimumVirginFrozenPairs = minimumVirginFrozenPairs
        self.minimumDistinctVirginFrozenFamilies = minimumDistinctVirginFrozenFamilies
        self.rationale = rationale
    }

    public static let v5 = V4FrozenCoveragePolicy()

    public func transferStatus(observed: Set<String>) -> V4GateStatus {
        guard !requiredTransfers.isEmpty else { return .notMeasured }
        return requiredTransfers.isSubset(of: observed) ? .pass : .fail
    }

    public func familyStatus(observed: Set<String>) -> V4GateStatus {
        guard minimumDistinctVirginFrozenFamilies > 0 else { return .notMeasured }
        return observed.count >= minimumDistinctVirginFrozenFamilies ? .pass : .fail
    }

    public func pairStatus(count: Int) -> V4GateStatus {
        count >= minimumVirginFrozenPairs ? .pass : .fail
    }
}



public struct V4HoldoutProvenanceAudit: Codable, Sendable, Equatable {
    public let version: String
    public let consumedPairIDs: [String]
    public let evidenceByPairID: [String: [String]]
    public let scannedArtifacts: [String]

    public init(
        version: String = "pre-v6-holdout-provenance-v1",
        consumedPairIDs: [String],
        evidenceByPairID: [String: [String]],
        scannedArtifacts: [String]
    ) {
        self.version = version
        self.consumedPairIDs = consumedPairIDs
        self.evidenceByPairID = evidenceByPairID
        self.scannedArtifacts = scannedArtifacts
    }

    public var consumedSet: Set<String> { Set(consumedPairIDs) }
    public func evidence(for pairID: String) -> [String] { evidenceByPairID[pairID] ?? [] }
}

/// V6 starts a new virgin boundary after the consumed V5 attempt.  These IDs
/// are recorded from the immutable attempt-1 ledger/result evidence and are
/// never eligible for a future Virgin Frozen set, even though their sealed
/// input manifests remain untouched.
public enum V6VirginHoldoutPolicy {
    public static let version = "v6-virgin-holdout-exclusion-v2"
    public static let attempt1State = "INCOMPLETE"
    public static let objectivePixelsRead = false
    public static let objectiveMetricsObserved = false
    public static let procedurallyConsumed = true
    public static let retryPermitted = false
    public static let consumedPairIDs: Set<String> = [
        "solemates_unh0400_0010",
        "dvb_live_linear_caminandes_hevc_uhd_sdr_hlg",
        "live_8_drawing_3840x2160_15000k"
    ]
    /// Attempt-1 exclusion is byte-bound as well as ID-bound.  Renaming or
    /// re-registering either consumed asset cannot make it virgin again.
    public static let consumedAssetPairs: [String: V6InputHashes] = [
        "solemates_unh0400_0010": V6InputHashes(
            sdrSHA256: "f61b6d19022e13aedd01fff9ef8b3b11a79550c62ed13fa1bd08e9f75c9c690c",
            hdrSHA256: "b02b96ec1f30076f8e167af213bee7745e876c4816cdb6e36c3e1f0a9d083136"
        ),
        "dvb_live_linear_caminandes_hevc_uhd_sdr_hlg": V6InputHashes(
            sdrSHA256: "45e2d38d3122af86f5f4e1f852ab7af5be88400cc9f151e97cf18409ed35ee90",
            hdrSHA256: "08bd66aa6dff1581749e7a4187ed2057d9b4812a033777f5c589d8aaf48fea01"
        ),
        "live_8_drawing_3840x2160_15000k": V6InputHashes(
            sdrSHA256: "ed8d37964618df3989c157018c2ecd5ac81924632510e7074e743fcdc54719ee",
            hdrSHA256: "79dd519125a1de4326ce953adf023eee4def02b238bf59ea141cd0a28e1d4f5c"
        )
    ]

    public static func isExcluded(_ pairID: String) -> Bool {
        consumedPairIDs.contains(pairID)
    }

    public static func isExcluded(
        pairID: String,
        sdrSHA256: String?,
        hdrSHA256: String?
    ) -> Bool {
        if isExcluded(pairID) { return true }
        let sdr = sdrSHA256?.lowercased()
        let hdr = hdrSHA256?.lowercased()
        return consumedAssetPairs.values.contains { consumed in
            (sdr != nil && sdr == consumed.sdrSHA256) ||
                (hdr != nil && hdr == consumed.hdrSHA256)
        }
    }
}

/// Reconstructs objective-consumption history from prior frozen objective artifacts.
/// A pair is considered consumed only when it actually appears as a `pairID` inside
/// a frozen dataset evaluation. Merely being listed in a historical manifest or
/// frozen split does not consume the holdout.
public enum V4HistoricalObjectiveProvenance {
    private static let frozenArtifactNames = [
        "data-video-v2-frozen.json",
        "data-video-v3-frozen.json",
        "data-video-v4-frozen.json"
    ]
    private static let finalArtifactNames = [
        "data-video-v2-final.json",
        "data-video-v3-final.json",
        "data-video-v4-final.json"
    ]
    private struct Ledger: Decodable {
        struct Entry: Decodable {
            let pairID: String
            let status: String
            let evidence: String?
        }
        let entries: [Entry]
    }


    public static func audit(repositoryRoot: URL, outputDirectory: URL) -> V4HoldoutProvenanceAudit {
        let fm = FileManager.default
        var roots: [URL] = []
        for candidate in [outputDirectory, repositoryRoot.appendingPathComponent("results")] {
            let standardized = candidate.standardizedFileURL
            if !roots.contains(where: { $0.path == standardized.path }) {
                roots.append(standardized)
            }
        }
        var evidence: [String: Set<String>] = [:]
        var scanned = Set<String>()

        func record(_ ids: Set<String>, artifact: URL) {
            guard !ids.isEmpty else { return }
            let portable = V4EvidencePath.portable(artifact, repositoryRoot: repositoryRoot)
            scanned.insert(portable)
            for id in ids {
                evidence[id, default: []].insert(portable)
            }
        }

        for root in roots where fm.fileExists(atPath: root.path) {
            for name in frozenArtifactNames {
                let url = root.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) else { continue }
                record(pairIDs(in: object), artifact: url)
            }
            for name in finalArtifactNames {
                let url = root.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let rootObject = object as? [String: Any],
                      let frozen = rootObject["frozen"] else { continue }
                record(pairIDs(in: frozen), artifact: url)
            }
        }

        let ledgerURLs = [
            repositoryRoot.appendingPathComponent("data_video/holdout-provenance-v5.json"),
            repositoryRoot.appendingPathComponent("dataset/holdout-provenance-v5.json")
        ]
        for ledgerURL in ledgerURLs where fm.fileExists(atPath: ledgerURL.path) {
            guard let data = try? Data(contentsOf: ledgerURL),
                  let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { continue }
            let portable = V4EvidencePath.portable(ledgerURL, repositoryRoot: repositoryRoot)
            scanned.insert(portable)
            for entry in ledger.entries where entry.status.uppercased() == "CONSUMED_HOLDOUT" {
                var proof = portable
                if let detail = entry.evidence, !detail.isEmpty { proof += "#" + detail }
                evidence[entry.pairID, default: []].insert(proof)
            }
        }

        // The V5 attempt-1 ledger is immutable and lives outside the source
        // tree.  Carry its procedural-consumption boundary into every new V6
        // provenance result so a future holdout cannot silently reuse one of
        // the three attempted pairs.
        for pairID in V6VirginHoldoutPolicy.consumedPairIDs {
            evidence[pairID, default: []].insert(
                "external:v5-attempt-1:" + V6VirginHoldoutPolicy.attempt1State
            )
        }
        let normalized = evidence.mapValues { Array($0).sorted() }
        return V4HoldoutProvenanceAudit(
            consumedPairIDs: normalized.keys.sorted(),
            evidenceByPairID: normalized,
            scannedArtifacts: Array(scanned).sorted()
        )
    }

    /// Internal JSON extractor intentionally keys on `pairID`, which appears in
    /// actual V2/V3/V4 video/scene evaluations. Split membership arrays use plain
    /// strings and therefore do not falsely consume a pair.
    public static func pairIDs(in object: Any) -> Set<String> {
        var result = Set<String>()
        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let id = dictionary["pairID"] as? String, !id.isEmpty {
                    result.insert(id)
                }
                for nested in dictionary.values { visit(nested) }
            } else if let array = value as? [Any] {
                for nested in array { visit(nested) }
            }
        }
        visit(object)
        return result
    }
}

public struct V4VirginPairEvidenceValidation: Sendable, Equatable {
    /// The normalized validator schema. Legacy numeric/omitted schema values
    /// are reported as the explicit v1 name without changing their on-disk
    /// representation.
    public let schemaVersion: String
    /// Transfer family proven by the evidence-bound HDR metadata. Legacy v1
    /// evidence is always HLG; generic v2 may prove HLG or PQ.
    public let hdrTransferFamily: String
    public let validationManifestSHA256: String
    public let sdrSHA256: String
    public let hdrSHA256: String
    /// Kept for callers that report the legacy DASH evidence. Generic v2 file
    /// evidence leaves these empty/zero; callers must branch on schemaVersion.
    public let segmentIdentities: [String]
    public let segmentCount: Int
    public let durationSeconds: Double
    public let decodedHDRFrameCount: Int
    public let decodedFrameCount: Int

    public var isLegacyDASHEvidence: Bool {
        schemaVersion == V4VirginPairEvidenceValidator.legacySchemaVersion
    }

    public init(
        schemaVersion: String = V4VirginPairEvidenceValidator.legacySchemaVersion,
        hdrTransferFamily: String = "UNKNOWN",
        validationManifestSHA256: String,
        sdrSHA256: String,
        hdrSHA256: String,
        segmentIdentities: [String] = [],
        segmentCount: Int = 0,
        durationSeconds: Double,
        decodedFrameCount: Int,
        decodedHDRFrameCount: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.hdrTransferFamily = hdrTransferFamily
        self.validationManifestSHA256 = validationManifestSHA256
        self.sdrSHA256 = sdrSHA256
        self.hdrSHA256 = hdrSHA256
        self.segmentIdentities = segmentIdentities
        self.segmentCount = segmentCount
        self.durationSeconds = durationSeconds
        self.decodedHDRFrameCount = decodedHDRFrameCount ?? decodedFrameCount
        self.decodedFrameCount = decodedFrameCount
    }
}

/// Validates an evidence-bound Virgin Frozen addition without invoking an
/// objective evaluator. Every admission condition is fail-closed and the
/// media digests come from the current dataset audit, not from filenames.
public enum V4VirginPairEvidenceValidator {
    public static let legacySchemaVersion = "v4-virgin-pair-evidence-v1"
    public static let genericSchemaVersion = "v4-virgin-pair-evidence-v2"

    private struct JSONView {
        let root: [String: Any]

        func value(_ path: [String]) -> Any? {
            var current: Any = root
            for key in path {
                guard let object = current as? [String: Any], let next = object[key] else { return nil }
                current = next
            }
            return current
        }

        func string(_ path: [String]) -> String? { value(path) as? String }
        func bool(_ path: [String]) -> Bool? { value(path) as? Bool }
        func strictBool(_ path: [String]) -> Bool? {
            guard let raw = value(path), let number = raw as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        func int(_ path: [String]) -> Int? { (value(path) as? NSNumber)?.intValue }
        func double(_ path: [String]) -> Double? { (value(path) as? NSNumber)?.doubleValue }
        func strings(_ path: [String]) -> [String]? { value(path) as? [String] }
        func array(_ path: [String]) -> [Any]? { value(path) as? [Any] }

        func stringsOrSingle(_ path: [String]) -> [String]? {
            if let value = value(path) as? String { return [value] }
            return value(path) as? [String]
        }

        func strictInt(_ path: [String]) -> Int? {
            guard let raw = value(path), let number = raw as? NSNumber,
                  !Self.isBoolean(number) else { return nil }
            let value = number.doubleValue
            guard value.isFinite,
                  value.rounded(.towardZero) == value,
                  value >= Double(Int.min), value <= Double(Int.max) else { return nil }
            return Int(value)
        }

        func strictDouble(_ path: [String]) -> Double? {
            guard let raw = value(path), let number = raw as? NSNumber,
                  !Self.isBoolean(number) else { return nil }
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }

        func finiteNumbersOnly() -> Bool {
            Self.finiteNumbersOnly(root)
        }

        func finiteNumbersOnly(_ path: [String]) -> Bool {
            guard let value = value(path) else { return false }
            return Self.finiteNumbersOnly(value)
        }

        private static func finiteNumbersOnly(_ value: Any) -> Bool {
            if let number = value as? NSNumber {
                return isBoolean(number) || number.doubleValue.isFinite
            }
            if value is Bool { return true }
            if let object = value as? [String: Any] {
                return object.values.allSatisfy { finiteNumbersOnly($0) }
            }
            if let array = value as? [Any] {
                return array.allSatisfy { finiteNumbersOnly($0) }
            }
            return true
        }

        private static func isBoolean(_ number: NSNumber) -> Bool {
            CFGetTypeID(number) == CFBooleanGetTypeID()
        }
    }

    private struct CommonEvidence {
        let reference: V4VirginEvidenceReference
        let evidenceHash: String
        let json: JSONView
        let schemaVersion: String
    }

    public static func validate(
        pair: V4PairRecord,
        manifestURL: URL,
        auditedSDRSHA256: String,
        auditedHDRSHA256: String
    ) throws -> V4VirginPairEvidenceValidation {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw CalibrationError.invalidManifest("Virgin evidence rejected for \(pair.id): \(message)")
            }
        }

        let common = try commonEvidence(
            pair: pair,
            manifestURL: manifestURL,
            auditedSDRSHA256: auditedSDRSHA256,
            auditedHDRSHA256: auditedHDRSHA256
        )
        switch common.schemaVersion {
        case legacySchemaVersion:
            return try validateLegacyV1(
                pair: pair,
                common: common
            )
        case genericSchemaVersion:
            return try validateGenericV2(
                pair: pair,
                common: common
            )
        default:
            // commonEvidence exhausts schema selection; keep this guard for
            // future edits so the validator cannot silently accept a new form.
            try require(false, "unsupported Virgin evidence schema")
            fatalError("unreachable")
        }
    }

    private static func commonEvidence(
        pair: V4PairRecord,
        manifestURL: URL,
        auditedSDRSHA256: String,
        auditedHDRSHA256: String
    ) throws -> CommonEvidence {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw CalibrationError.invalidManifest("Virgin evidence rejected for \(pair.id): \(message)")
            }
        }

        guard let reference = pair.virginEvidence else {
            throw CalibrationError.invalidManifest("Virgin evidence rejected for \(pair.id): missing virginEvidence reference")
        }
        try require(pair.split == .frozen && pair.virginFrozen, "pair is not declared Virgin Frozen")
        try require(pair.objectiveEvaluated == false, "objectiveEvaluated must be explicitly false")
        try require(pair.consumed == false, "consumed must be explicitly false")
        try require(!pair.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "provider is empty")
        try require(
            pair.contentFamily.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false,
            "content family is empty"
        )
        try require(!pair.sdr.isEmpty && !pair.hdr.isEmpty, "media paths must not be empty")
        try require(!isEscapingMediaPath(pair.sdr) && !isEscapingMediaPath(pair.hdr), "media paths must be portable relative paths")

        let manifestBase = manifestURL.deletingLastPathComponent().standardizedFileURL
        try require(!isEscapingRelativePath(reference.validationManifest), "validation manifest path is not portable")
        let evidenceURL = manifestBase.appendingPathComponent(reference.validationManifest).standardizedFileURL
        try require(
            evidenceURL.path.hasPrefix(manifestBase.path + "/"),
            "validation manifest resolves outside the manifest directory"
        )
        try require(FileManager.default.isReadableFile(atPath: evidenceURL.path), "validation manifest is missing or unreadable")
        let evidenceHash = try V4DatasetIntegrity.sha256(url: evidenceURL)
        try require(evidenceHash == reference.validationManifestSHA256.lowercased(), "validation manifest SHA-256 mismatch")
        try require(auditedSDRSHA256 == reference.sdrSHA256.lowercased(), "audited SDR SHA-256 mismatch")
        try require(auditedHDRSHA256 == reference.hdrSHA256.lowercased(), "audited HDR SHA-256 mismatch")

        let data = try Data(contentsOf: evidenceURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CalibrationError.invalidManifest("Virgin evidence rejected for \(pair.id): validation manifest root is not an object")
        }
        let json = JSONView(root: root)
        try require(json.finiteNumbersOnly(), "evidence contains a non-finite numeric value")
        let schemaVersion = try schemaVersion(json: json, pairID: pair.id)

        try require(json.string(["verdict"]) == "PAIR_VALID_VIRGIN", "verdict is not PAIR_VALID_VIRGIN")
        try require(json.strictBool(["objectiveUse", "consumed"]) == false, "objectiveUse.consumed is not false")
        let objectiveCountPaths = [
            ["objectiveUse", "evaluationCount"],
            ["objectiveUse", "evaluation_count"]
        ]
        let objectiveCountPresent = objectiveCountPaths.contains { json.value($0) != nil }
        let objectiveCountValues = presentIntValues(json, paths: objectiveCountPaths)
        if schemaVersion == genericSchemaVersion {
            try require(
                singleIntValue(objectiveCountValues, satisfying: { $0 == 0 }),
                "objectiveUse.evaluationCount must be explicitly 0"
            )
        } else if objectiveCountPresent {
            // The committed v1 evidence predates this field. When it is
            // present, however, it must still be a real integer zero.
            try require(
                singleIntValue(objectiveCountValues, satisfying: { $0 == 0 }),
                "objectiveUse.evaluationCount is not 0"
            )
        }

        guard let family = pair.contentFamily else {
            throw CalibrationError.invalidManifest("Virgin evidence rejected for \(pair.id): content family is empty")
        }
        try require(json.string(["pair", "provider"]) == pair.source, "evidence provider mismatch")
        try require(json.string(["pair", "family"]) == family, "evidence family mismatch")

        let urls = pair.resolvedURLs(relativeTo: manifestURL)
        let evidenceSDRHash = json.string(["assets", "sdr", "sha256"])?.lowercased()
        let evidenceHDRHash = json.string(["assets", "hdr", "sha256"])?.lowercased()
        try require(evidenceSDRHash == reference.sdrSHA256.lowercased(), "evidence SDR SHA-256 mismatch")
        try require(evidenceHDRHash == reference.hdrSHA256.lowercased(), "evidence HDR SHA-256 mismatch")
        if let evidenceSDRPath = json.string(["assets", "sdr", "path"]) {
            try require(filename(evidenceSDRPath) == urls.sdr.lastPathComponent, "evidence SDR asset path mismatch")
        } else {
            try require(false, "evidence SDR asset path missing")
        }
        if let evidenceHDRPath = json.string(["assets", "hdr", "path"]) {
            try require(filename(evidenceHDRPath) == urls.hdr.lastPathComponent, "evidence HDR asset path mismatch")
        } else {
            try require(false, "evidence HDR asset path missing")
        }

        return CommonEvidence(
            reference: reference,
            evidenceHash: evidenceHash,
            json: json,
            schemaVersion: schemaVersion
        )
    }

    private static func schemaVersion(json: JSONView, pairID: String) throws -> String {
        guard let raw = json.value(["schemaVersion"]) else {
            // The first v1 synthetic evidence and some early committed
            // artifacts omitted the discriminator; their shape is legacy v1.
            return legacySchemaVersion
        }
        if let string = raw as? String, string == genericSchemaVersion {
            return genericSchemaVersion
        }
        if let string = raw as? String, string == legacySchemaVersion {
            return legacySchemaVersion
        }
        if let number = raw as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue == 1, number.doubleValue.isFinite {
            return legacySchemaVersion
        }
        throw CalibrationError.invalidManifest(
            "Virgin evidence rejected for \(pairID): unsupported evidence schemaVersion"
        )
    }

    private static func isEscapingRelativePath(_ path: String) -> Bool {
        path.isEmpty || path.hasPrefix("/") || path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains("..")
    }

    private static func isEscapingMediaPath(_ path: String) -> Bool {
        isEscapingRelativePath(path) || path.contains("\0")
    }

    private static func filename(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last.map(String.init) ?? ""
    }

    private static func validateLegacyV1(
        pair: V4PairRecord,
        common: CommonEvidence
    ) throws -> V4VirginPairEvidenceValidation {
        let json = common.json
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw CalibrationError.invalidManifest("Virgin evidence rejected for \(pair.id): \(message)")
            }
        }

        let declaredTransfer = (pair.referenceTransfer ?? "").lowercased()
        try require(
            declaredTransfer == "arib-std-b67" || declaredTransfer == "hlg",
            "declared HDR transfer is not HLG/ARIB STD-B67"
        )
        try require((pair.referencePrimaries ?? "").lowercased() == "bt2020", "declared HDR primaries are not BT.2020")
        try require(pair.contentFamily == "DVB Live-Linear", "content family is not DVB Live-Linear")
        try require(pair.source == "DVB Project", "provider is not DVB Project")
        try require(
            json.string(["temporalReadiness"]) == "CONTIGUOUS_TEMPORAL_READY",
            "temporal readiness is not CONTIGUOUS_TEMPORAL_READY"
        )
        try require(json.string(["pair", "provider"]) == "DVB Project", "evidence provider mismatch")
        try require(json.string(["pair", "family"]) == "DVB Live-Linear", "evidence family mismatch")

        let segmentCount = json.int(["contiguousRun", "segmentCount"]) ?? -1
        let duration = json.double(["contiguousRun", "durationSeconds"]) ?? -.infinity
        let startSegment = json.int(["contiguousRun", "startSegment"]) ?? -1
        let endSegment = json.int(["contiguousRun", "endSegment"]) ?? -1
        try require(segmentCount >= 14, "contiguous segment count is below 14")
        try require(duration.isFinite && duration >= 50, "contiguous duration is below 50 seconds")
        try require(json.bool(["contiguousRun", "noGaps"]) == true, "contiguousRun.noGaps is not true")
        try require(endSegment >= startSegment && endSegment - startSegment + 1 == segmentCount, "contiguous segment bounds/count mismatch")

        let sdrSegments = json.strings(["directDashCaptureEvidence", "sdr", "segment_identities"]) ?? []
        let hdrSegments = json.strings(["directDashCaptureEvidence", "hdr", "segment_identities"]) ?? []
        try require(!sdrSegments.isEmpty && sdrSegments == hdrSegments, "SDR/HDR segment identity arrays differ")
        try require(sdrSegments.count == segmentCount, "segment identity count does not match contiguous run")
        let segmentNumbers = sdrSegments.compactMap { identity -> Int? in
            guard identity.hasPrefix("n:") else { return nil }
            return Int(identity.dropFirst(2))
        }
        try require(segmentNumbers.count == segmentCount, "segment identity is not SegmentTemplate number format")
        try require(segmentNumbers.first == startSegment && segmentNumbers.last == endSegment, "segment identities do not match run bounds")
        try require(zip(segmentNumbers, segmentNumbers.dropFirst()).allSatisfy { $1 == $0 + 1 }, "segment identity array contains a gap")
        try require(
            json.bool(["fullDecodeEvidence", "segment_identity_arrays_exactly_equal"]) == true,
            "full-decode identity equality evidence is not true"
        )

        let decodeErrors = json.array(["fullDecodeEvidence", "errors"]) ?? ["missing"]
        let sdrFrames = json.int(["fullDecodeEvidence", "sdr_decoded_frames"]) ?? -1
        let hdrFrames = json.int(["fullDecodeEvidence", "hdr_decoded_frames"]) ?? -1
        let expectedFrames = json.int(["fullDecodeEvidence", "expected_frames_from_contiguous_run"]) ?? -1
        try require(decodeErrors.isEmpty, "full decode recorded errors")
        try require(json.bool(["fullDecodeEvidence", "decoded_frame_counts_exactly_equal"]) == true, "decoded frame equality evidence is not true")
        try require(sdrFrames > 0 && sdrFrames == hdrFrames && sdrFrames == expectedFrames, "decoded frame counts are missing or unequal")

        let sdrPrimaries = json.strings(["streamEvidence", "decoded_keyframe_vui", "sdr", "values", "color_primaries"]) ?? []
        let sdrTransfer = json.strings(["streamEvidence", "decoded_keyframe_vui", "sdr", "values", "color_transfer"]) ?? []
        let sdrMatrix = json.strings(["streamEvidence", "decoded_keyframe_vui", "sdr", "values", "color_space"]) ?? []
        let hdrPrimaries = json.strings(["streamEvidence", "decoded_keyframe_vui", "hdr", "values", "color_primaries"]) ?? []
        let hdrTransfer = json.strings(["streamEvidence", "decoded_keyframe_vui", "hdr", "values", "color_transfer"]) ?? []
        let hdrMatrix = json.strings(["streamEvidence", "decoded_keyframe_vui", "hdr", "values", "color_space"]) ?? []
        try require(Set(sdrPrimaries) == ["bt709"] && Set(sdrTransfer) == ["bt709"] && Set(sdrMatrix) == ["bt709"], "decoded SDR keyframe VUI is not BT.709")
        try require(Set(hdrPrimaries) == ["bt2020"] && Set(hdrTransfer) == ["arib-std-b67"] && Set(hdrMatrix) == ["bt2020nc"], "decoded HDR keyframe VUI is not BT.2020/ARIB STD-B67/BT.2020nc")
        try require((json.int(["streamEvidence", "decoded_keyframe_vui", "sdr", "keyframe_count"]) ?? 0) > 0, "SDR keyframe VUI evidence is empty")
        try require((json.int(["streamEvidence", "decoded_keyframe_vui", "hdr", "keyframe_count"]) ?? 0) > 0, "HDR keyframe VUI evidence is empty")
        try require(abs((json.double(["streamEvidence", "sdr_fps"]) ?? 0) - 50) < 1e-9, "SDR frame rate is not 50 fps")
        try require(abs((json.double(["streamEvidence", "hdr_fps"]) ?? 0) - 50) < 1e-9, "HDR frame rate is not 50 fps")

        let alignmentErrors = json.array(["alignmentEvidence", "errors"]) ?? ["missing"]
        let mean = json.double(["alignmentEvidence", "temporal", "mean_rho"]) ?? -.infinity
        let edge = json.double(["alignmentEvidence", "temporal", "edge_rho"]) ?? -.infinity
        let standardDeviation = json.double(["alignmentEvidence", "temporal", "std_rho"]) ?? -.infinity
        let spatialMedian = json.double(["alignmentEvidence", "spatial", "median"]) ?? -.infinity
        let spatialP10 = json.double(["alignmentEvidence", "spatial", "p10"]) ?? -.infinity
        let meanMinimum = json.double(["alignmentEvidence", "thresholds", "mean_spearman_min"]) ?? .infinity
        let edgeMinimum = json.double(["alignmentEvidence", "thresholds", "edge_spearman_min"]) ?? .infinity
        let standardDeviationMinimum = json.double(["alignmentEvidence", "thresholds", "std_spearman_min"]) ?? .infinity
        let spatialMedianMinimum = json.double(["alignmentEvidence", "thresholds", "spatial_median_min"]) ?? .infinity
        let spatialP10Minimum = json.double(["alignmentEvidence", "thresholds", "spatial_p10_min"]) ?? .infinity
        let drift = abs(json.int(["alignmentEvidence", "drift_frames"]) ?? .max)
        let maximumDrift = json.int(["alignmentEvidence", "thresholds", "max_drift_frames"]) ?? -1
        let alignedFrames = json.int(["alignmentEvidence", "aligned_overlap_frames"]) ?? -1
        let minimumAlignedFrames = json.int(["alignmentEvidence", "thresholds", "min_aligned_frames"]) ?? .max
        try require(alignmentErrors.isEmpty, "alignment recorded errors")
        try require(json.int(["alignmentEvidence", "best_offset_frames"]) == 0, "best alignment offset is not zero")
        try require(drift <= maximumDrift, "alignment drift exceeds its frozen threshold")
        try require(alignedFrames >= minimumAlignedFrames, "aligned frame count is below its frozen threshold")
        try require(mean >= meanMinimum && edge >= edgeMinimum && standardDeviation >= standardDeviationMinimum, "temporal alignment is below its frozen thresholds")
        try require(spatialMedian >= spatialMedianMinimum && spatialP10 >= spatialP10Minimum, "spatial alignment is below its frozen thresholds")

        return V4VirginPairEvidenceValidation(
            schemaVersion: legacySchemaVersion,
            hdrTransferFamily: "HLG",
            validationManifestSHA256: common.evidenceHash,
            sdrSHA256: common.reference.sdrSHA256,
            hdrSHA256: common.reference.hdrSHA256,
            segmentIdentities: sdrSegments,
            segmentCount: segmentCount,
            durationSeconds: duration,
            decodedFrameCount: sdrFrames,
            decodedHDRFrameCount: hdrFrames
        )
    }

    private static func validateGenericV2(
        pair: V4PairRecord,
        common: CommonEvidence
    ) throws -> V4VirginPairEvidenceValidation {
        let json = common.json
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw CalibrationError.invalidManifest("Virgin evidence rejected for \(pair.id): \(message)")
            }
        }

        let declaredTransferFamily = normalizedMetadataValue(pair.referenceTransfer ?? "")
        try require(
            declaredTransferFamily == "hlg" || declaredTransferFamily == "pq",
            "declared HDR transfer is not ARIB STD-B67/HLG or SMPTE ST 2084/PQ"
        )
        try require(normalizedMetadataValue(pair.referencePrimaries ?? "") == "bt2020", "declared HDR primaries are not BT.2020")

        try require(json.finiteNumbersOnly(["fullDecodeEvidence"]), "full-decode evidence is missing or contains a non-finite numeric value")
        try require(json.finiteNumbersOnly(["alignmentEvidence"]), "alignment evidence is missing or contains a non-finite numeric value")

        let decodeErrorLists = presentArrays(
            json,
            paths: [
                ["fullDecodeEvidence", "errors"],
                ["fullDecodeEvidence", "decodeErrors"],
                ["fullDecodeEvidence", "sdrErrors"],
                ["fullDecodeEvidence", "hdrErrors"],
                ["fullDecodeEvidence", "sdr_errors"],
                ["fullDecodeEvidence", "hdr_errors"],
                ["fullDecodeEvidence", "sdr", "errors"],
                ["fullDecodeEvidence", "hdr", "errors"]
            ]
        )
        try require(decodeErrorLists?.allSatisfy { $0.isEmpty } == true, "full decode recorded errors or omitted its error list")

        let sdrFrameValues = presentIntValues(
            json,
            paths: [
                ["fullDecodeEvidence", "sdrDecodedFrames"],
                ["fullDecodeEvidence", "sdrDecodedFrameCount"],
                ["fullDecodeEvidence", "sdr_decoded_frames"],
                ["fullDecodeEvidence", "sdr_decoded_frame_count"],
                ["fullDecodeEvidence", "sdr", "decodedFrames"],
                ["fullDecodeEvidence", "sdr", "decoded_frames"],
                ["fullDecodeEvidence", "sdr", "decodedFrameCount"],
                ["fullDecodeEvidence", "sdr", "decoded_frame_count"],
                ["fullDecodeEvidence", "sdrFrames"]
            ]
        )
        let hdrFrameValues = presentIntValues(
            json,
            paths: [
                ["fullDecodeEvidence", "hdrDecodedFrames"],
                ["fullDecodeEvidence", "hdrDecodedFrameCount"],
                ["fullDecodeEvidence", "hdr_decoded_frames"],
                ["fullDecodeEvidence", "hdr_decoded_frame_count"],
                ["fullDecodeEvidence", "hdr", "decodedFrames"],
                ["fullDecodeEvidence", "hdr", "decoded_frames"],
                ["fullDecodeEvidence", "hdr", "decodedFrameCount"],
                ["fullDecodeEvidence", "hdr", "decoded_frame_count"],
                ["fullDecodeEvidence", "hdrFrames"]
            ]
        )
        try require(singleIntValue(sdrFrameValues, satisfying: { $0 > 0 }), "full-file SDR decoded frame count is missing, non-integral, or not positive")
        try require(singleIntValue(hdrFrameValues, satisfying: { $0 > 0 }), "full-file HDR decoded frame count is missing, non-integral, or not positive")
        guard let sdrFrames = sdrFrameValues?.first, let hdrFrames = hdrFrameValues?.first else {
            throw CalibrationError.invalidManifest("Virgin evidence rejected for \(pair.id): full-file decoded frame counts are missing")
        }
        try require(sdrFrames == hdrFrames, "full-file decoded frame counts are unequal")

        for path in [
            ["fullDecodeEvidence", "decodedFrameCountsExactlyEqual"],
            ["fullDecodeEvidence", "decoded_frame_counts_exactly_equal"]
        ] where json.value(path) != nil {
            try require(json.strictBool(path) == true, "full-decode evidence does not assert equal frame counts")
        }

        for path in [
            ["fullDecodeEvidence", "fullFile"],
            ["fullDecodeEvidence", "full_file"],
            ["fullDecodeEvidence", "isFullFile"]
        ] where json.value(path) != nil {
            try require(json.strictBool(path) == true, "full-decode evidence does not assert full-file coverage")
        }

        let sdrPrimaries = presentStrings(
            json,
            paths: metadataPaths(role: "sdr", camel: "colorPrimaries", snake: "color_primaries", short: "primaries")
        )
        let sdrTransfer = presentStrings(
            json,
            paths: metadataPaths(role: "sdr", camel: "colorTransfer", snake: "color_transfer", short: "transfer")
        )
        let sdrMatrix = presentStrings(
            json,
            paths: metadataPaths(role: "sdr", camel: "colorSpace", snake: "color_space", short: "matrix")
        )
        let hdrPrimaries = presentStrings(
            json,
            paths: metadataPaths(role: "hdr", camel: "colorPrimaries", snake: "color_primaries", short: "primaries")
        )
        let hdrTransfer = presentStrings(
            json,
            paths: metadataPaths(role: "hdr", camel: "colorTransfer", snake: "color_transfer", short: "transfer")
        )
        let hdrMatrix = presentStrings(
            json,
            paths: metadataPaths(role: "hdr", camel: "colorSpace", snake: "color_space", short: "matrix")
        )
        try require(metadataMatches(sdrPrimaries, expected: ["bt709"]), "v2 SDR primaries are not BT.709")
        try require(metadataMatches(sdrTransfer, expected: ["bt709"]), "v2 SDR transfer is not BT.709")
        try require(metadataMatches(sdrMatrix, expected: ["bt709"]), "v2 SDR matrix is not BT.709")
        try require(metadataMatches(hdrPrimaries, expected: ["bt2020"]), "v2 HDR primaries are not BT.2020")
        let expectedHDRTransferDescription = declaredTransferFamily == "pq"
            ? "SMPTE ST 2084/PQ"
            : "ARIB STD-B67/HLG"
        try require(
            metadataMatches(hdrTransfer, expected: [declaredTransferFamily]),
            "v2 HDR transfer is not \(expectedHDRTransferDescription)"
        )
        try require(metadataMatches(hdrMatrix, expected: ["bt2020nc"]), "v2 HDR matrix is not BT.2020nc")

        let hdrBitDepthPaths = metadataPaths(role: "hdr", camel: "bitDepth", snake: "bit_depth", short: "bits_per_raw_sample")
        let hdrBitDepth = presentIntValues(json, paths: hdrBitDepthPaths)
        if hdrBitDepthPaths.contains(where: { json.value($0) != nil }) {
            try require(singleIntValue(hdrBitDepth, satisfying: { $0 >= 10 }), "v2 HDR bit depth is missing or below 10 bits")
        } else {
            let hdrPixelFormats = presentStrings(
                json,
                paths: pixelFormatPaths(role: "hdr")
            )
            try require(pixelFormatsIndicateAtLeast10Bits(hdrPixelFormats), "v2 HDR bit depth is missing or below 10 bits")
        }

        let sdrRates = presentFrameRateValues(json, role: "sdr")
        let hdrRates = presentFrameRateValues(json, role: "hdr")
        try require(positiveFiniteFrameRates(sdrRates), "v2 SDR frame rate is missing or not positive")
        try require(positiveFiniteFrameRates(hdrRates), "v2 HDR frame rate is missing or not positive")
        try require(frameRatesAgree(sdrRates, hdrRates), "v2 SDR/HDR frame rates differ")

        let status = json.string(["alignmentEvidence", "status"])
        let sampledFrames = presentIntValues(
            json,
            paths: [
                ["alignmentEvidence", "sampledFrames"],
                ["alignmentEvidence", "sampled_frames"]
            ]
        )
        let matchedFrames = presentIntValues(
            json,
            paths: [
                ["alignmentEvidence", "matchedFrames"],
                ["alignmentEvidence", "matched_frames"]
            ]
        )
        let matchRatio = presentDoubleValues(
            json,
            paths: [
                ["alignmentEvidence", "matchRatio"],
                ["alignmentEvidence", "match_ratio"]
            ]
        )
        let p10Confidence = presentDoubleValues(
            json,
            paths: [
                ["alignmentEvidence", "p10Confidence"],
                ["alignmentEvidence", "p10_confidence"]
            ]
        )
        let medianConfidence = presentDoubleValues(
            json,
            paths: [
                ["alignmentEvidence", "medianConfidence"],
                ["alignmentEvidence", "median_confidence"]
            ]
        )
        let windowCount = presentIntValues(
            json,
            paths: [
                ["alignmentEvidence", "windowCount"],
                ["alignmentEvidence", "window_count"]
            ]
        )
        let framesPerWindow = presentIntValues(
            json,
            paths: [
                ["alignmentEvidence", "framesPerWindow"],
                ["alignmentEvidence", "frames_per_window"]
            ]
        )
        let maxAbsoluteOffsetSeconds = presentDoubleValues(
            json,
            paths: [
                ["alignmentEvidence", "maxAbsoluteOffsetSeconds"],
                ["alignmentEvidence", "max_absolute_offset_seconds"]
            ]
        )
        let offsetSpreadSeconds = presentDoubleValues(
            json,
            paths: [
                ["alignmentEvidence", "offsetSpreadSeconds"],
                ["alignmentEvidence", "offset_spread_seconds"]
            ]
        )
        let durationSeconds = presentDoubleValues(
            json,
            paths: [
                ["alignmentEvidence", "durationSeconds"],
                ["alignmentEvidence", "duration_seconds"]
            ]
        )

        try require(status == "ALIGNED", "v2 structural alignment status is not ALIGNED")
        try require(singleIntValue(sampledFrames, satisfying: { $0 >= 40 }), "v2 sampled frame count is below 40")
        try require(singleIntValue(matchedFrames, satisfying: { $0 >= V4AlignmentPolicy.minimumMatchedFrames }), "v2 matched frame count is below the V4 minimum")
        try require(singleDoubleValue(matchRatio, satisfying: { $0 >= V4AlignmentPolicy.minimumMatchRatio }), "v2 match ratio is below the V4 minimum")
        try require(singleDoubleValue(p10Confidence, satisfying: { $0 >= V4AlignmentPolicy.minimumP10Confidence }), "v2 p10 confidence is below the V4 minimum")
        try require(singleDoubleValue(medianConfidence, satisfying: { $0 >= V4AlignmentPolicy.alignedMedianConfidence }), "v2 median confidence is below the V4 minimum")
        try require(singleIntValue(windowCount, satisfying: { $0 >= 5 }), "v2 alignment window count is below 5")
        try require(singleIntValue(framesPerWindow, satisfying: { $0 >= 8 }), "v2 frames per alignment window is below 8")
        try require(singleDoubleValue(maxAbsoluteOffsetSeconds, satisfying: { $0 >= 0 && $0 <= 0.05 }), "v2 absolute offset exceeds 0.05 seconds")
        try require(singleDoubleValue(offsetSpreadSeconds, satisfying: { $0 >= 0 && $0 <= 0.05 }), "v2 offset spread exceeds 0.05 seconds")
        // The original generic v2 contract was introduced for the 201-second
        // HLG candidate and required a 50-second run. PQ LIVE clips are
        // intentionally short (8.008 seconds), so keep the HLG duration gate
        // while requiring every PQ evidence duration to be finite and
        // positive. The 5x8/40-frame V4 alignment gates remain unchanged for
        // both transfer families.
        let durationIsValid: (Double) -> Bool = { duration in
            duration > 0 && (declaredTransferFamily == "pq" || duration >= 50)
        }
        try require(singleDoubleValue(durationSeconds, satisfying: durationIsValid), "v2 evidence duration is invalid for the declared HDR transfer")

        if json.value(["alignmentEvidence", "errors"]) != nil {
            try require(json.array(["alignmentEvidence", "errors"])?.isEmpty == true, "v2 alignment recorded errors")
        }

        guard let selectionRoot = firstObject(
            json,
            paths: [
                ["selectionEvidence"],
                ["selectionProvenanceEvidence"],
                ["selectionProvenance"],
                ["provenanceEvidence"],
                ["selection"],
                ["provenance"]
            ]
        ) else {
            throw CalibrationError.invalidManifest("Virgin evidence rejected for \(pair.id): v2 selection/provenance evidence is missing")
        }
        let selection = JSONView(root: selectionRoot)
        try require(selection.finiteNumbersOnly(), "v2 selection/provenance evidence contains a non-finite numeric value")
        try require(
            singleIntValue(
                presentIntValues(
                    selection,
                    paths: [["objectiveEvaluationCount"], ["objective_evaluation_count"]]
                ),
                satisfying: { $0 == 0 }
            ),
            "v2 selection objectiveEvaluationCount must be explicitly 0"
        )
        try require(
            singleBoolValue(
                presentBoolValues(
                    selection,
                    paths: [["frameInspectionBeforeSelection"], ["frame_inspection_before_selection"]]
                ),
                satisfying: { !$0 }
            ),
            "v2 frameInspectionBeforeSelection must be explicitly false"
        )
        try require(isPreregisteredSourceIdentity(selection), "v2 source identity was not explicitly preregistered")
        try require(hasSingleNonEmptySourceID(selection), "v2 sourceID is missing or empty")

        return V4VirginPairEvidenceValidation(
            schemaVersion: genericSchemaVersion,
            hdrTransferFamily: declaredTransferFamily.uppercased(),
            validationManifestSHA256: common.evidenceHash,
            sdrSHA256: common.reference.sdrSHA256,
            hdrSHA256: common.reference.hdrSHA256,
            durationSeconds: durationSeconds?.first ?? 0,
            decodedFrameCount: sdrFrames,
            decodedHDRFrameCount: hdrFrames
        )
    }

    private static func firstObject(_ json: JSONView, paths: [[String]]) -> [String: Any]? {
        for path in paths where json.value(path) != nil {
            return json.value(path) as? [String: Any]
        }
        return nil
    }

    private static func presentArrays(_ json: JSONView, paths: [[String]]) -> [[Any]]? {
        var result: [[Any]] = []
        for path in paths where json.value(path) != nil {
            guard let values = json.array(path) else { return nil }
            result.append(values)
        }
        return result.isEmpty ? nil : result
    }

    private static func presentStrings(_ json: JSONView, paths: [[String]]) -> [[String]]? {
        var result: [[String]] = []
        for path in paths where json.value(path) != nil {
            guard let values = json.stringsOrSingle(path) else { return nil }
            result.append(values)
        }
        return result.isEmpty ? nil : result
    }

    private static func presentIntValues(_ json: JSONView, paths: [[String]]) -> [Int]? {
        var result: [Int] = []
        for path in paths where json.value(path) != nil {
            guard let value = json.strictInt(path) else { return nil }
            result.append(value)
        }
        return result.isEmpty ? nil : result
    }

    private static func presentDoubleValues(_ json: JSONView, paths: [[String]]) -> [Double]? {
        var result: [Double] = []
        for path in paths where json.value(path) != nil {
            guard let value = json.strictDouble(path) else { return nil }
            result.append(value)
        }
        return result.isEmpty ? nil : result
    }

    private static func presentBoolValues(_ json: JSONView, paths: [[String]]) -> [Bool]? {
        var result: [Bool] = []
        for path in paths where json.value(path) != nil {
            guard let value = json.strictBool(path) else { return nil }
            result.append(value)
        }
        return result.isEmpty ? nil : result
    }

    private static func frameRateValue(_ json: JSONView, path: [String]) -> Double? {
        if let value = json.strictDouble(path) { return value }
        guard let raw = json.value(path) as? String else { return nil }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              numerator.isFinite, denominator.isFinite,
              numerator > 0, denominator > 0 else { return nil }
        let value = numerator / denominator
        return value.isFinite ? value : nil
    }

    private static func presentFrameRateValues(_ json: JSONView, role: String) -> [Double]? {
        var result: [Double] = []
        for path in frameRatePaths(role: role) where json.value(path) != nil {
            guard let value = frameRateValue(json, path: path) else { return nil }
            result.append(value)
        }
        return result.isEmpty ? nil : result
    }

    private static func singleIntValue(_ values: [Int]?, satisfying predicate: (Int) -> Bool) -> Bool {
        guard let values, !values.isEmpty, Set(values).count == 1 else { return false }
        return values.allSatisfy(predicate)
    }

    private static func singleBoolValue(_ values: [Bool]?, satisfying predicate: (Bool) -> Bool) -> Bool {
        guard let values, !values.isEmpty, Set(values).count == 1 else { return false }
        return values.allSatisfy(predicate)
    }

    private static func singleDoubleValue(_ values: [Double]?, satisfying predicate: (Double) -> Bool) -> Bool {
        guard let values, !values.isEmpty, values.allSatisfy(\.isFinite) else { return false }
        guard let first = values.first else { return false }
        let tolerance = v2NumericTolerance
        guard values.allSatisfy({ abs($0 - first) <= tolerance * max(1, abs($0), abs(first)) }) else { return false }
        return values.allSatisfy(predicate)
    }

    private static func positiveFiniteFrameRates(_ values: [Double]?) -> Bool {
        guard let values, !values.isEmpty else { return false }
        return values.allSatisfy { $0.isFinite && $0 > 0 }
    }

    private static func frameRatesAgree(_ lhs: [Double]?, _ rhs: [Double]?) -> Bool {
        guard positiveFiniteFrameRates(lhs), positiveFiniteFrameRates(rhs),
              let lhs = lhs, let rhs = rhs,
              let left = lhs.first, let right = rhs.first else { return false }
        let tolerance = v2NumericTolerance
        return lhs.allSatisfy { abs($0 - left) <= tolerance * max(1, abs($0), abs(left)) } &&
            rhs.allSatisfy { abs($0 - right) <= tolerance * max(1, abs($0), abs(right)) } &&
            abs(left - right) <= tolerance * max(1, abs(left), abs(right))
    }

    private static func metadataMatches(_ groups: [[String]]?, expected: Set<String>) -> Bool {
        guard let groups else { return false }
        let values = groups.flatMap { $0 }
        guard !values.isEmpty else { return false }
        return Set(values.map(normalizedMetadataValue)) == expected
    }

    private static func normalizedMetadataValue(_ value: String) -> String {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let compact = lower.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
        switch compact {
        case "bt709", "bt-709": return "bt709"
        case "bt2020", "bt-2020": return "bt2020"
        case "bt2020nc", "bt2020-nc", "bt-2020nc", "bt-2020-nc": return "bt2020nc"
        case "hlg", "arib-stdb67", "aribstd-b67", "aribstdb67", "arib-std-b67", "aribstd-b67/hlg", "arib-std-b67/hlg", "hlg/aribstd-b67", "hlg/arib-std-b67": return "hlg"
        case "smpte2084", "smpte-2084", "smpte-st2084", "smpte-st-2084", "smptest2084", "smptest-2084": return "pq"
        default: return lower
        }
    }

    private static func metadataPaths(
        role: String,
        camel: String,
        snake: String,
        short: String
    ) -> [[String]] {
        var paths: [[String]] = []
        for root in ["metadataEvidence", "metadata", "streamEvidence"] {
            paths.append([root, role, camel])
            paths.append([root, role, snake])
            paths.append([root, role, short])
        }
        for root in ["metadataEvidence", "metadata", "streamEvidence"] {
            for vui in ["decoded_keyframe_vui", "decodedKeyframeVUI"] {
                paths.append([root, vui, role, "values", snake])
                paths.append([root, vui, role, "values", camel])
                paths.append([root, vui, role, "values", short])
            }
        }
        return paths
    }

    private static func frameRatePaths(role: String) -> [[String]] {
        let prefix = role == "sdr" ? "sdr" : "hdr"
        let upperPrefix = prefix == "sdr" ? "SDR" : "HDR"
        var paths: [[String]] = [
            ["streamEvidence", "\(prefix)_fps"],
            ["streamEvidence", "\(prefix)FPS"],
            ["streamEvidence", "\(prefix)FrameRate"],
            ["metadataEvidence", "\(prefix)FPS"],
            ["metadataEvidence", "\(prefix)_fps"],
            ["metadataEvidence", "\(prefix)FrameRate"]
        ]
        for root in ["metadataEvidence", "metadata", "streamEvidence"] {
            for key in ["frameRate", "frame_rate", "fps", "avgFrameRate", "avg_frame_rate", "rFrameRate", "r_frame_rate"] {
                paths.append([root, role, key])
            }
        }
        paths.append(["metadataEvidence", "\(upperPrefix)FrameRate"])
        paths.append(["streamEvidence", "\(upperPrefix)FrameRate"])
        return paths
    }

    private static func pixelFormatPaths(role: String) -> [[String]] {
        var paths: [[String]] = []
        for root in ["metadataEvidence", "metadata", "streamEvidence"] {
            for key in ["pixelFormat", "pixel_format", "pixFmt", "pix_fmt"] {
                paths.append([root, role, key])
            }
        }
        return paths
    }

    private static func pixelFormatsIndicateAtLeast10Bits(_ groups: [[String]]?) -> Bool {
        guard let groups else { return false }
        let values = groups.flatMap { $0 }
        guard !values.isEmpty else { return false }
        return values.allSatisfy { value in
            let lower = value.lowercased()
            return [16, 12, 10].contains { lower.contains(String($0)) }
        }
    }

    private static func isPreregisteredSourceIdentity(_ json: JSONView) -> Bool {
        var assertions: [Bool] = []
        for path in [
            ["sourceIdentityWasPreregistered"],
            ["sourceIdentityPreregistered"],
            ["sourceIdentityPreRegistered"],
            ["source_identity_preregistered"],
            ["sourceIdentity", "preregistered"],
            ["sourceIdentity", "wasPreregistered"],
            ["sourceIdentity", "preRegistered"],
            ["sourceIdentity", "pre_registered"],
            ["sourceIdentity", "statusPreregistered"],
            ["preregistered"],
            ["sourceIdentity"]
        ] where json.value(path) != nil {
            guard let value = json.strictBool(path) else { continue }
            assertions.append(value)
        }
        for path in [["sourceIdentity"], ["sourceIdentityStatus"], ["sourceIdentity", "status"]] where json.value(path) != nil {
            guard let value = json.string(path) else { continue }
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: " ", with: "")
            assertions.append(normalized == "preregistered")
        }
        return !assertions.isEmpty && assertions.allSatisfy { $0 }
    }

    private static func hasSingleNonEmptySourceID(_ json: JSONView) -> Bool {
        var values: [String] = []
        for path in [
            ["sourceID"], ["sourceId"], ["source_id"],
            ["sourceIdentity", "sourceID"], ["sourceIdentity", "sourceId"], ["sourceIdentity", "source_id"]
        ]
            where json.value(path) != nil {
            guard let value = json.string(path) else { return false }
            values.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return !values.isEmpty && values.allSatisfy { !$0.isEmpty } && Set(values).count == 1
    }

    private static let v2NumericTolerance = 1e-9
}

public struct V4NewHLGCandidateAudit: Codable, Sendable, Equatable {
    public let id: String
    public let source: String
    public let sdrPath: String?
    public let hdrPath: String?
    public let objectiveHistory: String
    public let metadataStatus: String
    public let alignmentStatus: String
    public let decodeStatus: String
    public let provenanceStatus: String
    public let accepted: Bool
    public let rejectionReasons: [String]

    public init(
        id: String,
        source: String,
        sdrPath: String? = nil,
        hdrPath: String? = nil,
        objectiveHistory: String,
        metadataStatus: String,
        alignmentStatus: String,
        decodeStatus: String,
        provenanceStatus: String,
        accepted: Bool,
        rejectionReasons: [String] = []
    ) {
        self.id = id
        self.source = source
        self.sdrPath = sdrPath
        self.hdrPath = hdrPath
        self.objectiveHistory = objectiveHistory
        self.metadataStatus = metadataStatus
        self.alignmentStatus = alignmentStatus
        self.decodeStatus = decodeStatus
        self.provenanceStatus = provenanceStatus
        self.accepted = accepted
        self.rejectionReasons = rejectionReasons
    }
}

public struct V4NewHLGHoldoutAudit: Codable, Sendable, Equatable {
    public let version: String
    public let required: Bool
    public let status: String
    public let found: Bool
    public let objectiveEvaluationCount: Int
    public let searchedRoots: [String]
    public let consumedHLGPairIDs: [String]
    public let candidates: [V4NewHLGCandidateAudit]
    public let reason: String

    public init(
        version: String = "pre-v6-new-hlg-holdout-audit-v1",
        required: Bool = true,
        status: String,
        found: Bool,
        objectiveEvaluationCount: Int = 0,
        searchedRoots: [String],
        consumedHLGPairIDs: [String],
        candidates: [V4NewHLGCandidateAudit],
        reason: String
    ) {
        self.version = version
        self.required = required
        self.status = status
        self.found = found
        self.objectiveEvaluationCount = objectiveEvaluationCount
        self.searchedRoots = searchedRoots
        self.consumedHLGPairIDs = consumedHLGPairIDs
        self.candidates = candidates
        self.reason = reason
    }
}

/// A metadata/provenance-only local search.  It intentionally does not invoke
/// PairEvaluator, any objective, or any candidate/reference comparison.
public enum V4NewHLGHoldoutAuditor {
    private struct ProbedMedia {
        let url: URL
        let metadata: V4StreamMetadata
        let sourceKey: String
    }

    public static func audit(
        manifestURL: URL,
        datasetAudit: V4DatasetAuditReport,
        outputDirectory: URL
    ) async throws -> V4NewHLGHoldoutAudit {
        let root = try V4SourceHasher.repositoryRoot(for: manifestURL)
        let objectiveProvenance = V4HistoricalObjectiveProvenance.audit(
            repositoryRoot: root, outputDirectory: outputDirectory
        )
        let objectivelyConsumed = objectiveProvenance.consumedSet
            .union(V6VirginHoldoutPolicy.consumedPairIDs)
        let historicalManifests = [
            root.appendingPathComponent("data_video/manifest.json"),
            root.appendingPathComponent("data_video/manifest-v2.json"),
            root.appendingPathComponent("data_video/manifest-v4.json")
        ]
        var consumedPaths = Set<String>()
        var consumedHLGIDs = Set<String>()
        for path in historicalManifests where FileManager.default.fileExists(atPath: path.path) {
            guard let data = try? Data(contentsOf: path) else { continue }
            if let historical = try? JSONDecoder().decode(V4Manifest.self, from: data) {
                for pair in historical.pairs {
                    let urls = pair.resolvedURLs(relativeTo: path, roots: historical.roots)
                    consumedPaths.insert(urls.sdr.standardizedFileURL.path)
                    consumedPaths.insert(urls.hdr.standardizedFileURL.path)
                    if pair.referenceTransfer?.uppercased() == "HLG" || pair.id.lowercased().contains("choreo") {
                        consumedHLGIDs.insert(pair.id)
                    }
                }
            } else if let legacy = try? JSONDecoder().decode(PairManifest.self, from: data) {
                let base = path.deletingLastPathComponent()
                for pair in legacy.pairs {
                    consumedPaths.insert(base.appendingPathComponent(pair.sdr).standardizedFileURL.path)
                    consumedPaths.insert(base.appendingPathComponent(pair.hdr).standardizedFileURL.path)
                    if pair.id.lowercased().contains("choreo") { consumedHLGIDs.insert(pair.id) }
                }
            }
        }
        let currentManifest = try V4Manifest.load(from: manifestURL)
        // Never rediscover currently registered Virgin Frozen media while
        // searching for a replacement V6 HLG holdout.  Path resolution reads
        // only manifest strings; no Frozen media is opened here.
        for pair in currentManifest.pairs where pair.split == .frozen && pair.virginFrozen {
            let urls = pair.resolvedURLs(relativeTo: manifestURL, roots: currentManifest.roots)
            consumedPaths.insert(urls.sdr.standardizedFileURL.path)
            consumedPaths.insert(urls.hdr.standardizedFileURL.path)
            if pair.referenceTransfer?.lowercased() == "hlg" || pair.referenceTransfer?.lowercased() == "arib-std-b67" {
                consumedHLGIDs.insert(pair.id)
            }
        }
        let datasetAuditByID = Dictionary(uniqueKeysWithValues: datasetAudit.pairs.map { ($0.id, $0) })
        var existingVirginCandidates: [V4NewHLGCandidateAudit] = []
        for manifestPair in currentManifest.pairs where manifestPair.virginFrozen && manifestPair.virginEvidence != nil {
            let declaredTransfer = (manifestPair.referenceTransfer ?? "").lowercased()
            guard declaredTransfer == "hlg" || declaredTransfer == "arib-std-b67" else { continue }
            consumedHLGIDs.insert(manifestPair.id)
            let auditedPair = datasetAuditByID[manifestPair.id]
            let consumedByIdentity = V6VirginHoldoutPolicy.isExcluded(
                pairID: manifestPair.id,
                sdrSHA256: auditedPair?.sdrDigest?.sha256,
                hdrSHA256: auditedPair?.hdrDigest?.sha256
            )
            existingVirginCandidates.append(auditRegisteredManifestPair(
                manifestPair: manifestPair,
                datasetPair: auditedPair,
                manifestURL: manifestURL,
                objectivelyConsumed: objectivelyConsumed.contains(manifestPair.id) || consumedByIdentity
            ))
        }

        for pair in datasetAudit.pairs where objectivelyConsumed.contains(pair.id) && pair.hdrTransferFamily?.uppercased() == "HLG" {
            consumedHLGIDs.insert(pair.id)
        }

        let searchRoots = discoverSearchRoots(repositoryRoot: root)
        let mediaURLs = discoverMedia(searchRoots: searchRoots, excluding: consumedPaths)
        var probed: [ProbedMedia] = []
        probed.reserveCapacity(mediaURLs.count)
        for url in mediaURLs {
            guard let metadata = try? await V4MetadataProbe.probe(url: url) else { continue }
            probed.append(ProbedMedia(url: url, metadata: metadata, sourceKey: normalizedSourceKey(url)))
        }

        let hlgMedia = probed.filter { isHLGReference($0.metadata) }
        let sdrMedia = probed.filter { $0.metadata.isExplicitBT709SDR }
        var candidates: [V4NewHLGCandidateAudit] = existingVirginCandidates
        candidates.reserveCapacity(existingVirginCandidates.count + hlgMedia.count)

        for hdr in hlgMedia {
            let compatible = sdrMedia
                .filter { metadataCompatible(sdr: $0.metadata, hdr: hdr.metadata) }
                .map { ($0, sourceIdentityScore($0, hdr)) }
                .filter { $0.1 >= 0.60 }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    return abs(lhs.0.metadata.durationSeconds - hdr.metadata.durationSeconds) <
                        abs(rhs.0.metadata.durationSeconds - hdr.metadata.durationSeconds)
                }

            guard !compatible.isEmpty else {
                candidates.append(V4NewHLGCandidateAudit(
                    id: "hlg-\(hdr.sourceKey)", source: "local-unmanifested",
                    hdrPath: portableCandidatePath(hdr.url, repositoryRoot: root),
                    objectiveHistory: "NONE_FOUND_IN_HISTORICAL_MANIFESTS",
                    metadataStatus: "PASS_HLG_BT2020_10BIT;NO_COMPATIBLE_BT709_SDR",
                    alignmentStatus: "NOT_RUN", decodeStatus: "NOT_RUN",
                    provenanceStatus: "UNPAIRED",
                    accepted: false,
                    rejectionReasons: ["no metadata-compatible BT.709 SDR candidate with matching source identity"]
                ))
                continue
            }

            var acceptedAudit: V4NewHLGCandidateAudit?
            var rejectedAudits: [V4NewHLGCandidateAudit] = []
            // Only inspect the strongest few structural candidates. This keeps
            // the preflight bounded even when a directory contains many transcodes.
            for (sdr, identityScore) in compatible.prefix(3) {
                let audited = await auditPair(
                    sdr: sdr, hdr: hdr, sourceIdentityScore: identityScore,
                    repositoryRoot: root
                )
                if audited.accepted {
                    acceptedAudit = audited
                    break
                }
                rejectedAudits.append(audited)
            }
            if let acceptedAudit {
                candidates.append(acceptedAudit)
            } else if let bestRejected = rejectedAudits.first {
                candidates.append(bestRejected)
            }
        }

        let found = candidates.contains(where: \.accepted)
        let status = found ? "FOUND" : "NEW_HLG_VIRGIN_REQUIRED"
        let reason = found
            ? "a metadata-verified, decoded, strongly aligned, objective-unexposed local HLG/BT.709 pair is available"
            : "no unconsumed local HLG/BT.2020 candidate passed metadata, same-source identity, decode, and alignment gates"
        return V4NewHLGHoldoutAudit(
            version: "pre-v6-new-hlg-holdout-audit-v1",
            status: status, found: found,
            searchedRoots: searchRoots.map { portableSearchRoot($0, repositoryRoot: root) },
            consumedHLGPairIDs: consumedHLGIDs.sorted(), candidates: candidates, reason: reason
        )
    }

    static func auditRegisteredManifestPair(
        manifestPair: V4PairRecord,
        datasetPair: V4PairAudit?,
        manifestURL: URL,
        objectivelyConsumed: Bool
    ) -> V4NewHLGCandidateAudit {
        let sdrPath = datasetPair?.sdrPath ?? manifestPair.sdr
        let hdrPath = datasetPair?.hdrPath ?? manifestPair.hdr
        var reasons: [String] = []

        if objectivelyConsumed { reasons.append("historical frozen objective evidence already consumed this pair") }
        guard let datasetPair else {
            reasons.append("registered pair is missing from the current dataset audit")
            return V4NewHLGCandidateAudit(
                id: manifestPair.id, source: "manifest-v4-virgin-evidence",
                sdrPath: sdrPath, hdrPath: hdrPath,
                objectiveHistory: objectivelyConsumed ? "PRIOR_OBJECTIVE_EVIDENCE_FOUND" : "NO_PRIOR_FROZEN_OBJECTIVE_EVIDENCE",
                metadataStatus: "NOT_AUDITED", alignmentStatus: "NOT_AUDITED", decodeStatus: "NOT_AUDITED",
                provenanceStatus: "EVIDENCE_REJECTED", accepted: false, rejectionReasons: reasons
            )
        }
        guard let sdrDigest = datasetPair.sdrDigest, let hdrDigest = datasetPair.hdrDigest else {
            reasons.append("dataset audit did not produce both media SHA-256 digests")
            return V4NewHLGCandidateAudit(
                id: manifestPair.id, source: "manifest-v4-virgin-evidence",
                sdrPath: sdrPath, hdrPath: hdrPath,
                objectiveHistory: objectivelyConsumed ? "PRIOR_OBJECTIVE_EVIDENCE_FOUND" : "NO_PRIOR_FROZEN_OBJECTIVE_EVIDENCE",
                metadataStatus: "DIGEST_MISSING", alignmentStatus: datasetPair.alignment.status,
                decodeStatus: "SDR=\(datasetPair.sdrDecode.passed);HDR=\(datasetPair.hdrDecode.passed)",
                provenanceStatus: "EVIDENCE_REJECTED", accepted: false, rejectionReasons: reasons
            )
        }

        let validation: V4VirginPairEvidenceValidation
        do {
            validation = try V4VirginPairEvidenceValidator.validate(
                pair: manifestPair,
                manifestURL: manifestURL,
                auditedSDRSHA256: sdrDigest.sha256,
                auditedHDRSHA256: hdrDigest.sha256
            )
        } catch {
            reasons.append(error.localizedDescription)
            return V4NewHLGCandidateAudit(
                id: manifestPair.id, source: "manifest-v4-virgin-evidence",
                sdrPath: sdrPath, hdrPath: hdrPath,
                objectiveHistory: objectivelyConsumed ? "PRIOR_OBJECTIVE_EVIDENCE_FOUND" : "NO_PRIOR_FROZEN_OBJECTIVE_EVIDENCE",
                metadataStatus: "EVIDENCE_REJECTED", alignmentStatus: datasetPair.alignment.status,
                decodeStatus: "SDR=\(datasetPair.sdrDecode.passed);HDR=\(datasetPair.hdrDecode.passed)",
                provenanceStatus: "EVIDENCE_REJECTED", accepted: false, rejectionReasons: reasons
            )
        }

        if !V4CoverageAuditEligibility.isEligible(datasetPair) {
            reasons.append(
                "dataset audit eligibility failed: status=\(datasetPair.status.rawValue);" +
                "suitability=\(datasetPair.suitability.rawValue);alignment=\(datasetPair.alignment.status);" +
                "sdrDecode=\(datasetPair.sdrDecode.passed);hdrDecode=\(datasetPair.hdrDecode.passed)"
            )
        }
        if datasetPair.hdrTransferFamily?.uppercased() != "HLG" { reasons.append("dataset audit HDR transfer is not HLG") }
        if datasetPair.sdrReferenceValid != true { reasons.append("dataset audit SDR reference is not explicit BT.709") }
        if datasetPair.hdrReferenceValid != true { reasons.append("dataset audit HDR reference is not BT.2020 HLG") }
        if objectivelyConsumed { reasons.append("objectiveUse is not virgin") }

        let accepted = reasons.isEmpty
        let decodeStatus: String
        let provenanceStatus: String
        if accepted {
            if validation.isLegacyDASHEvidence {
                decodeStatus = "PASS_SDR=\(datasetPair.sdrDecode.decodedSampleCount);HDR=\(datasetPair.hdrDecode.decodedSampleCount);FULL=\(validation.decodedFrameCount)"
                provenanceStatus = "PASS_MANIFEST_SHA=\(validation.validationManifestSHA256);ASSET_SHA_MATCH;CONTIGUOUS=\(validation.segmentCount);DURATION=\(String(format: "%.2f", validation.durationSeconds))"
            } else {
                decodeStatus = "PASS_SDR=\(datasetPair.sdrDecode.decodedSampleCount);HDR=\(datasetPair.hdrDecode.decodedSampleCount);FULL_FILE_SDR=\(validation.decodedFrameCount);FULL_FILE_HDR=\(validation.decodedHDRFrameCount)"
                provenanceStatus = "PASS_MANIFEST_SHA=\(validation.validationManifestSHA256);ASSET_SHA_MATCH;FULL_FILE_FRAMES=\(validation.decodedFrameCount);DURATION=\(String(format: "%.2f", validation.durationSeconds))"
            }
        } else {
            decodeStatus = "SDR=\(datasetPair.sdrDecode.passed);HDR=\(datasetPair.hdrDecode.passed)"
            provenanceStatus = "EVIDENCE_REJECTED"
        }
        return V4NewHLGCandidateAudit(
            id: manifestPair.id, source: "manifest-v4-virgin-evidence",
            sdrPath: sdrPath, hdrPath: hdrPath,
            objectiveHistory: objectivelyConsumed ? "PRIOR_OBJECTIVE_EVIDENCE_FOUND" : "NO_PRIOR_FROZEN_OBJECTIVE_EVIDENCE",
            metadataStatus: accepted ? "PASS_SDR_BT709_AND_HDR_BT2020_ARIB_STD_B67" : "REJECTED",
            alignmentStatus: String(
                format: "%@;median=%.4f;p10=%.4f;matchRatio=%.4f",
                datasetPair.alignment.status,
                datasetPair.alignment.medianConfidence,
                datasetPair.alignment.p10Confidence,
                datasetPair.alignment.matchRatio
            ),
            decodeStatus: decodeStatus,
            provenanceStatus: provenanceStatus,
            accepted: accepted,
            rejectionReasons: reasons
        )
    }

    static func normalizedSourceKey(_ url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent.lowercased()
        let separators = CharacterSet.alphanumerics.inverted
        let ignored: Set<String> = [
            "hdr", "hdr10", "hlg", "sdr", "pq", "bt2100", "rec2100", "bt2020", "bt709",
            "arib", "std", "b67", "hevc", "h265", "h264", "av1", "vp9",
            "8bit", "10bit", "12bit", "2160p", "1080p", "720p", "uhd", "fhd"
        ]
        let tokens = raw.components(separatedBy: separators).filter { token in
            guard !token.isEmpty, !ignored.contains(token) else { return false }
            if token.hasSuffix("kbps") || token.hasSuffix("mbps") || token.hasSuffix("fps") { return false }
            return true
        }
        return tokens.joined(separator: "-")
    }

    static func isHLGReference(_ metadata: V4StreamMetadata) -> Bool {
        let transfer = (metadata.transfer ?? "").lowercased()
        let primaries = (metadata.colorPrimaries ?? "").lowercased()
        let hlg = transfer.contains("arib") || transfer.contains("hlg") || transfer.contains("b67")
        return hlg && primaries.contains("2020") && (metadata.bitDepth ?? 0) >= 10
    }

    private static func discoverSearchRoots(repositoryRoot: URL) -> [URL] {
        var roots = [repositoryRoot.appendingPathComponent("data_video")]
        let parent = repositoryRoot.deletingLastPathComponent()
        if parent.standardizedFileURL.path != repositoryRoot.standardizedFileURL.path {
            roots.append(parent)
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func discoverMedia(searchRoots: [URL], excluding consumedPaths: Set<String>) -> [URL] {
        let extensions: Set<String> = ["mp4", "mov", "mkv", "m4v", "webm"]
        var result: [URL] = []
        var seen = Set<String>()
        // A bounded scan prevents a workspace-parent search from walking an
        // entire attached volume forever. data_video is visited first.
        let maximumFiles = 4_000
        outer: for searchRoot in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                let path = url.standardizedFileURL.path
                guard !path.contains("/.build/"), extensions.contains(url.pathExtension.lowercased()),
                      !consumedPaths.contains(path), seen.insert(path).inserted else { continue }
                result.append(url)
                if result.count >= maximumFiles { break outer }
            }
        }
        return result
    }

    private static func metadataCompatible(sdr: V4StreamMetadata, hdr: V4StreamMetadata) -> Bool {
        guard sdr.isExplicitBT709SDR, isHLGReference(hdr),
              sdr.durationSeconds > 0, hdr.durationSeconds > 0 else { return false }
        let durationTolerance = max(0.75, min(sdr.durationSeconds, hdr.durationSeconds) * 0.01)
        guard abs(sdr.durationSeconds - hdr.durationSeconds) <= durationTolerance else { return false }
        let sdrAspect = Double(sdr.width) / Double(max(sdr.height, 1))
        let hdrAspect = Double(hdr.width) / Double(max(hdr.height, 1))
        guard abs(sdrAspect - hdrAspect) / max(sdrAspect, hdrAspect) <= 0.02 else { return false }
        if sdr.frameRate > 0, hdr.frameRate > 0 {
            guard abs(sdr.frameRate - hdr.frameRate) / max(sdr.frameRate, hdr.frameRate) <= 0.02 else { return false }
        }
        return true
    }

    private static func sourceIdentityScore(_ sdr: ProbedMedia, _ hdr: ProbedMedia) -> Double {
        if !sdr.sourceKey.isEmpty, sdr.sourceKey == hdr.sourceKey { return 1 }
        let lhs = Set(sdr.sourceKey.split(separator: "-").map(String.init))
        let rhs = Set(hdr.sourceKey.split(separator: "-").map(String.init))
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    private static func auditPair(
        sdr: ProbedMedia,
        hdr: ProbedMedia,
        sourceIdentityScore: Double,
        repositoryRoot: URL
    ) async -> V4NewHLGCandidateAudit {
        let id = "hlg-\(hdr.sourceKey.isEmpty ? hdr.url.deletingPathExtension().lastPathComponent.lowercased() : hdr.sourceKey)"
        let sdrPath = portableCandidatePath(sdr.url, repositoryRoot: repositoryRoot)
        let hdrPath = portableCandidatePath(hdr.url, repositoryRoot: repositoryRoot)
        var reasons: [String] = []
        guard sdr.metadata.isExplicitBT709SDR else { reasons.append("SDR metadata is not explicit supported BT.709"); return rejected(id, sdrPath, hdrPath, reasons) }
        guard isHLGReference(hdr.metadata) else { reasons.append("HDR metadata is not BT.2020 HLG 10-bit+"); return rejected(id, sdrPath, hdrPath, reasons) }
        guard sourceIdentityScore >= 0.60 else { reasons.append("source identity score below 0.60"); return rejected(id, sdrPath, hdrPath, reasons) }

        do {
            let sdrSHA256 = try V4DatasetIntegrity.sha256(url: sdr.url)
            let hdrSHA256 = try V4DatasetIntegrity.sha256(url: hdr.url)
            if V6VirginHoldoutPolicy.isExcluded(
                pairID: id, sdrSHA256: sdrSHA256, hdrSHA256: hdrSHA256
            ) {
                reasons.append("asset SHA-256 was procedurally consumed by V5 Frozen attempt 1")
                return rejected(id, sdrPath, hdrPath, reasons)
            }
        } catch {
            reasons.append("asset SHA-256 verification failed: \(error.localizedDescription)")
            return rejected(id, sdrPath, hdrPath, reasons)
        }

        do {
            let sdrSequence = try await FrameReader.read(
                url: sdr.url, pixelFormat: CalibrationPixelFormat.sdrNV12, maxFrames: 40, proxyWidth: 320
            )
            let hdrSequence = try await FrameReader.read(
                url: hdr.url, pixelFormat: CalibrationPixelFormat.hdrP010, maxFrames: 40, proxyWidth: 320
            )
            guard !sdrSequence.samples.isEmpty, !hdrSequence.samples.isEmpty else {
                reasons.append("decode produced no structural samples")
                return rejected(id, sdrPath, hdrPath, reasons, decodeStatus: "FAIL")
            }
            let alignment = V4AuditTemporalAligner.align(sdr: sdrSequence, hdr: hdrSequence)
            let matchRatio = Double(alignment.matches.count) / Double(max(sdrSequence.samples.count, 1))
            let accepted = alignment.medianConfidence >= 0.70 && matchRatio >= 0.95 &&
                alignment.status != "REJECT"
            if !accepted {
                reasons.append(String(format: "alignment failed preferred holdout gate: median=%.3f matchRatio=%.3f", alignment.medianConfidence, matchRatio))
            }
            return V4NewHLGCandidateAudit(
                id: id, source: "local-unmanifested",
                sdrPath: sdrPath, hdrPath: hdrPath,
                objectiveHistory: "NONE_FOUND_IN_HISTORICAL_MANIFESTS",
                metadataStatus: "PASS_SDR_BT709_AND_HDR_BT2020_HLG_10BIT",
                alignmentStatus: String(format: "%@;median=%.4f;matchRatio=%.4f", alignment.status, alignment.medianConfidence, matchRatio),
                decodeStatus: "PASS_SDR=\(sdrSequence.samples.count);HDR=\(hdrSequence.samples.count)",
                provenanceStatus: sourceIdentityScore >= 0.999
                    ? "FILENAME_SOURCE_IDENTITY_PLUS_STRUCTURAL_ALIGNMENT"
                    : "TOKEN_SOURCE_IDENTITY_PLUS_STRUCTURAL_ALIGNMENT",
                accepted: accepted,
                rejectionReasons: reasons
            )
        } catch {
            reasons.append("decode/alignment error: \(error.localizedDescription)")
            return rejected(id, sdrPath, hdrPath, reasons, decodeStatus: "FAIL")
        }
    }

    private static func rejected(
        _ id: String,
        _ sdrPath: String?,
        _ hdrPath: String?,
        _ reasons: [String],
        decodeStatus: String = "NOT_RUN"
    ) -> V4NewHLGCandidateAudit {
        V4NewHLGCandidateAudit(
            id: id, source: "local-unmanifested", sdrPath: sdrPath, hdrPath: hdrPath,
            objectiveHistory: "NONE_FOUND_IN_HISTORICAL_MANIFESTS",
            metadataStatus: "REJECTED", alignmentStatus: "NOT_RUN", decodeStatus: decodeStatus,
            provenanceStatus: "UNVERIFIED", accepted: false, rejectionReasons: reasons
        )
    }

    private static func portableCandidatePath(_ url: URL, repositoryRoot: URL) -> String {
        let portable = V4EvidencePath.portable(url, repositoryRoot: repositoryRoot)
        return portable.hasPrefix("/") ? "external-media:\(url.lastPathComponent)" : portable
    }

    private static func portableSearchRoot(_ url: URL, repositoryRoot: URL) -> String {
        let portable = V4EvidencePath.portable(url, repositoryRoot: repositoryRoot)
        if !portable.hasPrefix("/") { return portable }
        return url.standardizedFileURL.path == repositoryRoot.deletingLastPathComponent().standardizedFileURL.path
            ? "workspace-parent" : "external-search-root"
    }
}
