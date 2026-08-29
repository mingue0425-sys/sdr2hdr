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

public struct V4TemporalWindowDecision: Codable, Sendable, Equatable {
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
        version: String = "pre-v5-frozen-coverage-v1",
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
        version: String = "pre-v5-holdout-provenance-v1",
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
        version: String = "pre-v5-new-hlg-holdout-audit-v1",
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
        let currentManifestByID = Dictionary(uniqueKeysWithValues: currentManifest.pairs.map { ($0.id, $0) })
        var existingVirginCandidates: [V4NewHLGCandidateAudit] = []
        for pair in datasetAudit.pairs where pair.hdrTransferFamily?.uppercased() == "HLG" {
            consumedHLGIDs.insert(pair.id)
            guard let manifestPair = currentManifestByID[pair.id], manifestPair.virginFrozen,
                  V4CoverageAuditEligibility.isEligible(pair),
                  !objectivelyConsumed.contains(pair.id) else { continue }
            existingVirginCandidates.append(V4NewHLGCandidateAudit(
                id: pair.id, source: "manifest-v4-virgin",
                sdrPath: pair.sdrPath, hdrPath: pair.hdrPath,
                objectiveHistory: "NO_PRIOR_FROZEN_OBJECTIVE_EVIDENCE",
                metadataStatus: "PASS_FROM_DATASET_AUDIT",
                alignmentStatus: String(format: "PASS;median=%.4f;matchRatio=%.4f", pair.alignment.medianConfidence, pair.alignment.matchRatio),
                decodeStatus: "PASS_FROM_DATASET_AUDIT",
                provenanceStatus: manifestPair.expectedRelation.rawValue,
                accepted: true
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
            version: "pre-v5-new-hlg-holdout-audit-v3",
            status: status, found: found,
            searchedRoots: searchRoots.map { portableSearchRoot($0, repositoryRoot: root) },
            consumedHLGPairIDs: consumedHLGIDs.sorted(), candidates: candidates, reason: reason
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
