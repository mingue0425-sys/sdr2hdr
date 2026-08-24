import Foundation

public struct V4ManifestMetadataSummary: Codable, Hashable, Sendable {
    public struct Endpoint: Codable, Hashable, Sendable {
        public var codec: String?
        public var width: Int
        public var height: Int
        public var frameRate: Double
        public var pixelFormat: String?
        public var bitDepth: Int?
        public var colorPrimaries: String?
        public var transfer: String?
        public var matrix: String?
        public var colorRange: String?

        public init(metadata: V4StreamMetadata) {
            codec = metadata.codec
            width = metadata.width
            height = metadata.height
            frameRate = metadata.frameRate
            pixelFormat = metadata.pixelFormat
            bitDepth = metadata.bitDepth
            colorPrimaries = metadata.colorPrimaries
            transfer = metadata.transfer
            matrix = metadata.matrix
            colorRange = metadata.colorRange
        }
    }

    public var sdr: Endpoint
    public var hdr: Endpoint

    public init(sdr: V4StreamMetadata, hdr: V4StreamMetadata) {
        self.sdr = Endpoint(metadata: sdr)
        self.hdr = Endpoint(metadata: hdr)
    }
}

public struct V4LiveDecodeSummary: Codable, Sendable {
    public var firstFrame: Bool
    public var quarterFrame: Bool
    public var middleFrame: Bool
    public var threeQuarterFrame: Bool
    public var lastFrame: Bool
    public var decodedSampleCount: Int
    public var allFinite: Bool
    public var error: String?

    public init(
        firstFrame: Bool = false,
        quarterFrame: Bool = false,
        middleFrame: Bool = false,
        threeQuarterFrame: Bool = false,
        lastFrame: Bool = false,
        decodedSampleCount: Int = 0,
        allFinite: Bool = false,
        error: String? = nil
    ) {
        self.firstFrame = firstFrame
        self.quarterFrame = quarterFrame
        self.middleFrame = middleFrame
        self.threeQuarterFrame = threeQuarterFrame
        self.lastFrame = lastFrame
        self.decodedSampleCount = decodedSampleCount
        self.allFinite = allFinite
        self.error = error
    }

    public var passed: Bool {
        firstFrame && quarterFrame && middleFrame && threeQuarterFrame && lastFrame &&
            decodedSampleCount > 0 && allFinite && error == nil
    }
}

public struct V4LiveContentFeatures: Codable, Sendable {
    public var meanLuminance: Double
    public var p10Luminance: Double
    public var p50Luminance: Double
    public var p90Luminance: Double
    public var p95Luminance: Double
    public var p99Luminance: Double
    public var dynamicRange: Double
    public var highlightRatio: Double
    public var shadowRatio: Double
    public var contrast: Double
    public var motionProxy: Double
    public var tags: [String]

    public init(
        meanLuminance: Double,
        p10Luminance: Double,
        p50Luminance: Double,
        p90Luminance: Double,
        p95Luminance: Double,
        p99Luminance: Double,
        dynamicRange: Double,
        highlightRatio: Double,
        shadowRatio: Double,
        contrast: Double,
        motionProxy: Double,
        tags: [String]
    ) {
        self.meanLuminance = meanLuminance
        self.p10Luminance = p10Luminance
        self.p50Luminance = p50Luminance
        self.p90Luminance = p90Luminance
        self.p95Luminance = p95Luminance
        self.p99Luminance = p99Luminance
        self.dynamicRange = dynamicRange
        self.highlightRatio = highlightRatio
        self.shadowRatio = shadowRatio
        self.contrast = contrast
        self.motionProxy = motionProxy
        self.tags = tags
    }
}

public struct V4LiveCandidate: Codable, Sendable {
    public var id: String
    public var sourceID: String
    public var resolution: String
    public var bitrateKbps: Int
    public var sdrPath: String
    public var hdrPath: String
    public var status: String
    public var qualityGrade: String
    public var metadataSummary: V4ManifestMetadataSummary?
    public var durationDeltaSeconds: Double?
    public var frameRateDelta: Double?
    public var decode: V4LiveDecodeSummary?
    public var alignment: V4AlignmentSummary?
    public var features: V4LiveContentFeatures?
    public var contentCategory: [String]
    public var selected: Bool
    public var selectionScore: Double
    public var proposedSplit: DatasetSplit?
    public var virginFrozen: Bool
    public var reason: String?

    public init(
        id: String,
        sourceID: String,
        resolution: String,
        bitrateKbps: Int,
        sdrPath: String,
        hdrPath: String
    ) {
        self.id = id
        self.sourceID = sourceID
        self.resolution = resolution
        self.bitrateKbps = bitrateKbps
        self.sdrPath = sdrPath
        self.hdrPath = hdrPath
        self.status = "LIVE_PAIR_CANDIDATE"
        self.qualityGrade = "UNVERIFIED"
        self.metadataSummary = nil
        self.durationDeltaSeconds = nil
        self.frameRateDelta = nil
        self.decode = nil
        self.alignment = nil
        self.features = nil
        self.contentCategory = []
        self.selected = false
        self.selectionScore = 0
        self.proposedSplit = nil
        self.virginFrozen = false
        self.reason = nil
    }
}

public struct V4LiveDiscoveryReport: Codable, Sendable {
    public var version: String
    public var generatedAt: String
    public var root: String
    public var sdrDirectory: String?
    public var hdrDirectory: String?
    public var totalFiles: Int
    public var sdrCandidates: Int
    public var hdrCandidates: Int
    public var uniqueSourceIDs: Int
    public var extensionCounts: [String: Int]
    public var unmatchedSDR: Int
    public var unmatchedHDR: Int
    public var pairCandidates: Int
    public var candidates: [V4LiveCandidate]

    public init(
        root: String,
        sdrDirectory: String?,
        hdrDirectory: String?,
        totalFiles: Int,
        sdrCandidates: Int,
        hdrCandidates: Int,
        uniqueSourceIDs: Int,
        extensionCounts: [String: Int],
        unmatchedSDR: Int,
        unmatchedHDR: Int,
        pairCandidates: Int,
        candidates: [V4LiveCandidate]
    ) {
        self.version = "dataset-v4-live-discovery"
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.root = root
        self.sdrDirectory = sdrDirectory
        self.hdrDirectory = hdrDirectory
        self.totalFiles = totalFiles
        self.sdrCandidates = sdrCandidates
        self.hdrCandidates = hdrCandidates
        self.uniqueSourceIDs = uniqueSourceIDs
        self.extensionCounts = extensionCounts
        self.unmatchedSDR = unmatchedSDR
        self.unmatchedHDR = unmatchedHDR
        self.pairCandidates = pairCandidates
        self.candidates = candidates
    }
}

public struct V4LiveSelectionEntry: Codable, Sendable {
    public var id: String
    public var sourceID: String
    public var qualityGrade: String
    public var score: Double
    public var categories: [String]
    public var split: DatasetSplit
    public var virginFrozen: Bool
    public var whySelected: String
    public var sdrPath: String
    public var hdrPath: String
}

public struct V4LiveSelectionReport: Codable, Sendable {
    public var version: String
    public var generatedAt: String
    public var requestedCount: Int
    public var selectedCount: Int
    public var selected: [V4LiveSelectionEntry]
    public var notSelected: [String: String]

    public init(
        requestedCount: Int,
        selected: [V4LiveSelectionEntry],
        notSelected: [String: String]
    ) {
        self.version = "dataset-v4-live-selection"
        self.generatedAt = ISO8601DateFormatter().string(from: Date())
        self.requestedCount = requestedCount
        self.selectedCount = selected.count
        self.selected = selected
        self.notSelected = notSelected
    }
}

public enum V4LiveImporter {
    private struct LiveFile {
        let url: URL
        let sourceID: String
        let resolution: String
        let bitrateKbps: Int
        let side: String

        var key: String {
            "\(sourceID.lowercased())|\(resolution)|\(bitrateKbps)"
        }
    }

    private struct DiscoveredFiles {
        let root: URL
        let sdrDirectory: URL?
        let hdrDirectory: URL?
        let sdr: [LiveFile]
        let hdr: [LiveFile]
        let extensionCounts: [String: Int]
    }

    private struct ValidatedCandidate {
        var candidate: V4LiveCandidate
        var sdrMetadata: V4StreamMetadata
        var hdrMetadata: V4StreamMetadata
    }

    private static let sourceCategoryHints: [String: [String]] = [
        "0_Balance_Forest": ["outdoor", "natural", "shadow-rich"],
        "1_Basketball_Afternoon": ["outdoor", "daylight", "high-key", "high-contrast"],
        "2_Basketball_Evening": ["outdoor", "low-key", "high-contrast"],
        "3_Cafe": ["indoor", "skin", "natural"],
        "4_Campfire": ["night", "low-key", "highlight-rich", "shadow-rich"],
        "5_Conversation_Bed": ["indoor", "skin", "low-key"],
        "6_Conversation_Standing": ["indoor", "skin", "natural"],
        "7_Dancing": ["indoor", "high-contrast", "saturated"],
        "8_Drawing": ["indoor", "low-saturation"],
        "9_Face_Close": ["indoor", "skin", "high-contrast"],
        "10_Fountain": ["outdoor", "daylight", "highlight-rich"],
        "11_Guitar_Handheld": ["indoor", "saturated", "high-contrast"],
        "12_Guitar_Tripod": ["indoor", "low-contrast"],
        "13_Interview": ["indoor", "skin", "low-contrast"],
        "14_Knitting_Close": ["indoor", "skin", "shadow-rich"],
        "15_Knitting_Total": ["indoor", "low-contrast"],
        "16_Night_Biking": ["night", "outdoor", "low-key", "shadow-rich", "high-contrast"],
        "17_Onion_1": ["indoor", "low-saturation"],
        "18_Onion_2": ["indoor", "low-saturation"],
        "19_Parcours": ["outdoor", "daylight", "high-contrast"],
        "20_Phone_Call": ["indoor", "skin", "low-key"],
        "21_Power_Pole_Sky": ["outdoor", "daylight", "high-key", "highlight-rich"],
        "22_Programming_Night": ["night", "indoor", "low-key", "shadow-rich"],
        "23_Reading_Bench": ["outdoor", "shadow-rich", "natural"],
        "24_Reading_Stairs": ["outdoor", "shadow-rich", "natural"],
        "25_River": ["outdoor", "daylight", "highlight-rich", "natural"],
        "26_Sitting": ["indoor", "skin", "low-contrast"],
        "27_Skateboarding": ["outdoor", "daylight", "high-contrast"],
        "28_Swan": ["outdoor", "natural", "shadow-rich"],
        "29_Walking_Forest": ["outdoor", "natural", "shadow-rich"],
        "30_Yoga": ["indoor", "skin", "low-contrast"]
    ]

    private static let categoryWeights: [String: Double] = [
        "night": 10, "outdoor": 8, "indoor": 8, "skin": 7, "neon": 10,
        "cinematic": 6, "shadow-rich": 9, "highlight-rich": 9, "low-key": 8,
        "high-key": 5, "daylight": 4, "natural": 4, "high-contrast": 4,
        "low-contrast": 4, "saturated": 4, "low-saturation": 4
    ]

    public static func importDataset(
        rootURL: URL,
        manifestURL: URL,
        outputDirectory: URL,
        selectionCount: Int = 6,
        dryRun: Bool = false
    ) async throws -> V4LiveSelectionReport {
        let discovered = try discoverFiles(rootURL: rootURL)
        var candidates = makeCandidates(discovered: discovered)
        let discovery = V4LiveDiscoveryReport(
            root: discovered.root.path,
            sdrDirectory: discovered.sdrDirectory?.path,
            hdrDirectory: discovered.hdrDirectory?.path,
            totalFiles: discovered.sdr.count + discovered.hdr.count,
            sdrCandidates: discovered.sdr.count,
            hdrCandidates: discovered.hdr.count,
            uniqueSourceIDs: Set(candidates.map(\.sourceID)).count,
            extensionCounts: discovered.extensionCounts,
            unmatchedSDR: max(0, discovered.sdr.count - candidates.count),
            unmatchedHDR: max(0, discovered.hdr.count - candidates.count),
            pairCandidates: candidates.count,
            candidates: candidates
        )

        try writeJSON(discovery, to: outputDirectory.appendingPathComponent("dataset-v4-live-discovery.json"))
        print("LIVE discovery: SDR=\(discovered.sdr.count), HDR=\(discovered.hdr.count), pairs=\(candidates.count), sourceIDs=\(Set(candidates.map(\.sourceID)).count)")

        var metadataValid: [ValidatedCandidate] = []
        metadataValid.reserveCapacity(candidates.count)
        for index in candidates.indices {
            if index % 25 == 0 || index == candidates.count - 1 {
                print("LIVE metadata: \(index + 1)/\(candidates.count)")
            }
            do {
                let sdr = try await V4MetadataProbe.probe(url: URL(fileURLWithPath: candidates[index].sdrPath))
                let hdr = try await V4MetadataProbe.probe(url: URL(fileURLWithPath: candidates[index].hdrPath))
                candidates[index].metadataSummary = V4ManifestMetadataSummary(sdr: sdr, hdr: hdr)
                candidates[index].durationDeltaSeconds = abs(sdr.durationSeconds - hdr.durationSeconds)
                candidates[index].frameRateDelta = abs(sdr.frameRate - hdr.frameRate)
                guard metadataGate(sdr: sdr, hdr: hdr) == nil else {
                    candidates[index].status = "PAIR_METADATA_UNCERTAIN"
                    candidates[index].qualityGrade = "REJECT"
                    candidates[index].reason = metadataGate(sdr: sdr, hdr: hdr)
                    continue
                }
                candidates[index].status = "METADATA_VALID"
                candidates[index].contentCategory = sourceCategoryHints[candidates[index].sourceID] ?? ["unknown"]
                metadataValid.append(ValidatedCandidate(candidate: candidates[index], sdrMetadata: sdr, hdrMetadata: hdr))
            } catch {
                candidates[index].status = "PAIR_METADATA_UNCERTAIN"
                candidates[index].qualityGrade = "REJECT"
                candidates[index].reason = error.localizedDescription
            }
        }

        let existingManifest = try V4Manifest.load(from: manifestURL)
        let existingCategories = Set(existingManifest.pairs.flatMap(\.contentCategory))
        var canonical = canonicalVariants(metadataValid)
        for index in canonical.indices {
            canonical[index].candidate.contentCategory = sourceCategoryHints[canonical[index].candidate.sourceID] ?? ["unknown"]
        }
        let validationIndices = validationTargetIndices(
            candidates: canonical.map(\.candidate),
            existingCategories: existingCategories,
            // Every source ID gets one canonical variant integrity check. The
            // remaining bitrate/resolution variants are metadata-checked and
            // retained as redundant variants, but decoding all nine copies
            // would spend time without adding independent content evidence.
            budget: canonical.count
        )
        for index in canonical.indices {
            guard validationIndices.contains(index) else {
                canonical[index].candidate.status = "METADATA_ONLY_NOT_SELECTED"
                canonical[index].candidate.qualityGrade = "UNVERIFIED"
                canonical[index].candidate.reason = "metadata valid; canonical source validation was not selected"
                continue
            }
            let result = await validate(canonical[index])
            canonical[index].candidate = result.candidate
            canonical[index].sdrMetadata = result.sdrMetadata
            canonical[index].hdrMetadata = result.hdrMetadata
        }

        let canonicalByID = Dictionary(uniqueKeysWithValues: canonical.map { ($0.candidate.sourceID, $0) })
        for index in candidates.indices {
            guard let source = canonicalByID[candidates[index].sourceID] else { continue }
            if candidates[index].id == source.candidate.id {
                candidates[index] = source.candidate
            } else if candidates[index].status == "METADATA_VALID" {
                candidates[index].status = "REDUNDANT_VARIANT"
                candidates[index].qualityGrade = "UNVERIFIED_VARIANT"
                candidates[index].reason = "same source ID; canonical variant \(source.candidate.id) selected for validation"
            }
        }

        let selectedCanonical = select(
            canonical.map(\.candidate).filter { $0.qualityGrade == "A" || $0.qualityGrade == "B" },
            existingCategories: existingCategories,
            count: max(1, selectionCount)
        )
        var selectedEntries: [V4LiveSelectionEntry] = []
        var selectedIDs = Set<String>()
        for (index, selected) in selectedCanonical.enumerated() {
            let split: DatasetSplit
            let virgin: Bool
            if index < min(2, selectedCanonical.count / 3) {
                split = .frozen
                virgin = true
            } else if index < min(4, selectedCanonical.count * 2 / 3) {
                split = .validation
                virgin = false
            } else {
                split = .tune
                virgin = false
            }
            selectedIDs.insert(selected.id)
            if let candidateIndex = candidates.firstIndex(where: { $0.id == selected.id }) {
                candidates[candidateIndex].selected = true
                candidates[candidateIndex].proposedSplit = split
                candidates[candidateIndex].virginFrozen = virgin
                candidates[candidateIndex].selectionScore = selected.selectionScore
            }
            selectedEntries.append(V4LiveSelectionEntry(
                id: selected.id,
                sourceID: selected.sourceID,
                qualityGrade: selected.qualityGrade,
                score: selected.selectionScore,
                categories: selected.contentCategory,
                split: split,
                virginFrozen: virgin,
                whySelected: selected.reason ?? "quality and diversity selection",
                sdrPath: selected.sdrPath,
                hdrPath: selected.hdrPath
            ))
        }

        var notSelected: [String: String] = [:]
        for candidate in candidates where !selectedIDs.contains(candidate.id) {
            if candidate.status == "REDUNDANT_VARIANT" {
                notSelected[candidate.id] = candidate.reason ?? "redundant encoding variant"
            } else if let canonical = canonicalByID[candidate.sourceID] {
                notSelected[candidate.id] = "source-level candidate not selected; canonical \(canonical.candidate.id) had higher marginal diversity"
            } else {
                notSelected[candidate.id] = candidate.reason ?? "failed metadata/decode/alignment gate"
            }
        }

        let selection = V4LiveSelectionReport(
            requestedCount: selectionCount,
            selected: selectedEntries,
            notSelected: notSelected
        )
        let pairReport = discoveryWithUpdatedCandidates(discovery, candidates: candidates)
        try writeJSON(pairReport, to: outputDirectory.appendingPathComponent("dataset-v4-live-pairs.json"))
        try writeJSON(selection, to: outputDirectory.appendingPathComponent("dataset-v4-live-selection.json"))

        if !dryRun {
            var updatedManifest = existingManifest
            updatedManifest.roots["live"] = rootURL.standardizedFileURL.path
            updatedManifest.pairs.removeAll { $0.source == "LIVE Paired Comparison HDR vs. SDR Database (local)" }
            for entry in selectedEntries {
                guard let candidate = candidates.first(where: { $0.id == entry.id }),
                      let metadata = candidate.metadataSummary else { continue }
                let group = "live_\(candidate.sourceID)"
                updatedManifest.pairs.append(V4PairRecord(
                    id: candidate.id,
                    sdr: "live:\(relativePath(candidate.sdrPath, root: rootURL))",
                    hdr: "live:\(relativePath(candidate.hdrPath, root: rootURL))",
                    source: "LIVE Paired Comparison HDR vs. SDR Database (local)",
                    sourceURL: "https://www.colorado.edu/lab/live/live-paired-comparison-hdr-vs-sdr-database",
                    license: "LICENSE_REVIEW_REQUIRED",
                    licenseURL: "https://www.colorado.edu/lab/live/live-paired-comparison-hdr-vs-sdr-database",
                    expectedRelation: .sameSource,
                    contentCategory: candidate.contentCategory,
                    contentFamily: "LIVE",
                    referenceTransfer: "smpte2084",
                    referencePrimaries: "bt2020",
                    split: entry.split,
                    virginFrozen: entry.virginFrozen,
                    group: group,
                    notes: "\(entry.whySelected). Local source was supplied by the user; redistribution/license status requires review. No objective evaluation is permitted for virgin frozen pairs.",
                    metadataSummary: metadata
                ))
            }
            try updatedManifest.validate(relativeTo: manifestURL)
            try writeJSON(updatedManifest, to: manifestURL)
            print("LIVE manifest updated: selected=\(selectedEntries.count), virginFrozen=\(selectedEntries.filter(\.virginFrozen).count)")
        } else {
            print("LIVE dry-run: manifest was not changed")
        }
        return selection
    }

    public static func discover(rootURL: URL) throws -> V4LiveDiscoveryReport {
        let discovered = try discoverFiles(rootURL: rootURL)
        let candidates = makeCandidates(discovered: discovered)
        return V4LiveDiscoveryReport(
            root: discovered.root.path,
            sdrDirectory: discovered.sdrDirectory?.path,
            hdrDirectory: discovered.hdrDirectory?.path,
            totalFiles: discovered.sdr.count + discovered.hdr.count,
            sdrCandidates: discovered.sdr.count,
            hdrCandidates: discovered.hdr.count,
            uniqueSourceIDs: Set(candidates.map(\.sourceID)).count,
            extensionCounts: discovered.extensionCounts,
            unmatchedSDR: max(0, discovered.sdr.count - candidates.count),
            unmatchedHDR: max(0, discovered.hdr.count - candidates.count),
            pairCandidates: candidates.count,
            candidates: candidates
        )
    }

    private static func discoverFiles(rootURL: URL) throws -> DiscoveredFiles {
        let root = rootURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw CalibrationError.invalidManifest("LIVE root does not exist: \(root.path)")
        }
        let directories = try allDirectories(root: root)
        let sdrDirectory = directories.first(where: {
            let name = $0.lastPathComponent.lowercased()
            return name == "open-sourced_sdr" || (name.contains("sdr") && !name.contains("hdr"))
        })
        let hdrDirectory = directories.first(where: {
            let name = $0.lastPathComponent.lowercased()
            return name == "open-sourced_hdr10" || (name.contains("hdr") && name.contains("sdr") == false)
        })
        guard let sdrDirectory, let hdrDirectory else {
            throw CalibrationError.invalidManifest("could not find paired SDR/HDR directories below \(root.path)")
        }
        let sdr = try mediaFiles(directory: sdrDirectory).compactMap { parse($0, side: "SDR") }
        let hdr = try mediaFiles(directory: hdrDirectory).compactMap { parse($0, side: "HDR") }
        var extensionCounts: [String: Int] = [:]
        for url in try mediaFiles(directory: sdrDirectory) + mediaFiles(directory: hdrDirectory) {
            extensionCounts[url.pathExtension.lowercased(), default: 0] += 1
        }
        return DiscoveredFiles(root: root, sdrDirectory: sdrDirectory, hdrDirectory: hdrDirectory, sdr: sdr, hdr: hdr, extensionCounts: extensionCounts)
    }

    private static func allDirectories(root: URL) throws -> [URL] {
        var result = [root]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CalibrationError.invalidManifest("could not enumerate LIVE root: \(root.path)")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                result.append(url)
            }
        }
        return result.sorted { $0.path.count < $1.path.count }
    }

    private static func mediaFiles(directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CalibrationError.invalidManifest("could not enumerate LIVE media directory: \(directory.path)")
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true,
                  ["mp4", "mov", "mkv"].contains(url.pathExtension.lowercased()) else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func parse(_ url: URL, side: String) -> LiveFile? {
        let stem = url.deletingPathExtension().lastPathComponent
        let marker = side == "SDR" ? "_SDR_" : "_HDR10_"
        guard let range = stem.range(of: marker, options: .caseInsensitive) else { return nil }
        let sourceID = String(stem[..<range.lowerBound])
        let suffix = String(stem[range.upperBound...]).split(separator: "_")
        guard suffix.count == 2,
              let bitrate = Int(suffix[1].replacingOccurrences(of: "k", with: "")),
              suffix[0].contains("x") else { return nil }
        return LiveFile(
            url: url,
            sourceID: sourceID,
            resolution: String(suffix[0]),
            bitrateKbps: bitrate,
            side: side
        )
    }

    private static func makeCandidates(discovered: DiscoveredFiles) -> [V4LiveCandidate] {
        let sdrByKey = Dictionary(uniqueKeysWithValues: discovered.sdr.map { ($0.key, $0) })
        let hdrByKey = Dictionary(uniqueKeysWithValues: discovered.hdr.map { ($0.key, $0) })
        return sdrByKey.keys.compactMap { key in
            guard let sdr = sdrByKey[key], let hdr = hdrByKey[key] else { return nil }
            let id = "live_" + sdr.sourceID.lowercased().replacingOccurrences(of: " ", with: "_") +
                "_\(sdr.resolution)_\(sdr.bitrateKbps)k"
            return V4LiveCandidate(
                id: id,
                sourceID: sdr.sourceID,
                resolution: sdr.resolution,
                bitrateKbps: sdr.bitrateKbps,
                sdrPath: sdr.url.path,
                hdrPath: hdr.url.path
            )
        }.sorted { $0.id < $1.id }
    }

    private static func metadataGate(sdr: V4StreamMetadata, hdr: V4StreamMetadata) -> String? {
        guard sdr.isSDRReference, (sdr.colorPrimaries ?? "").lowercased().contains("709") else {
            return "PAIR_INVALID_SDR: expected BT.709 SDR metadata"
        }
        guard hdr.isHDRReference, hdr.transferFamily == "PQ" else {
            return "PAIR_INVALID_HDR: expected BT.2020 PQ HDR10 metadata"
        }
        guard (hdr.bitDepth ?? 0) >= 10 else {
            return "PAIR_INVALID_HDR: HDR bit depth is below 10"
        }
        guard sdr.width > 0, sdr.height > 0, hdr.width > 0, hdr.height > 0 else {
            return "PAIR_METADATA_UNCERTAIN: missing dimensions"
        }
        let aspectSDR = Double(sdr.width) / Double(sdr.height)
        let aspectHDR = Double(hdr.width) / Double(hdr.height)
        guard abs(aspectSDR - aspectHDR) / max(aspectSDR, aspectHDR) < 0.02 else {
            return "PAIR_SPATIAL_MISMATCH"
        }
        guard abs(sdr.durationSeconds - hdr.durationSeconds) <= 0.25 else {
            return "PAIR_DIFFERENT_EDIT: duration mismatch"
        }
        guard abs(sdr.frameRate - hdr.frameRate) <= 0.1 else {
            return "PAIR_DIFFERENT_EDIT: frame-rate mismatch"
        }
        return nil
    }

    private static func canonicalVariants(_ candidates: [ValidatedCandidate]) -> [ValidatedCandidate] {
        Dictionary(grouping: candidates, by: { $0.candidate.sourceID })
            .values
            .compactMap { variants in
                variants.max {
                    canonicalPreference($0.candidate) < canonicalPreference($1.candidate)
                }
            }
            .sorted { $0.candidate.sourceID < $1.candidate.sourceID }
    }

    private static func canonicalPreference(_ candidate: V4LiveCandidate) -> Int {
        let resolutionScore: Int
        switch candidate.resolution {
        case "3840x2160": resolutionScore = 3_000
        case "2560x1440": resolutionScore = 2_000
        case "1920x1080": resolutionScore = 1_000
        default: resolutionScore = 0
        }
        let bitrateScore = candidate.bitrateKbps == 15_000 ? 600 : candidate.bitrateKbps / 100
        return resolutionScore + bitrateScore
    }

    private static func validate(_ input: ValidatedCandidate) async -> ValidatedCandidate {
        var output = input
        do {
            let sdrSequence = try await FrameReader.read(
                url: URL(fileURLWithPath: input.candidate.sdrPath),
                pixelFormat: CalibrationPixelFormat.sdrNV12,
                maxFrames: 128,
                proxyWidth: 160
            )
            let hdrSequence = try await FrameReader.read(
                url: URL(fileURLWithPath: input.candidate.hdrPath),
                pixelFormat: CalibrationPixelFormat.hdrP010,
                maxFrames: 128,
                proxyWidth: 160
            )
            let sdrDecode = decodeSummary(sequence: sdrSequence)
            let hdrDecode = decodeSummary(sequence: hdrSequence)
            let alignmentResult = V4AuditTemporalAligner.align(
                sdr: sdrSequence,
                hdr: hdrSequence,
                offsetRangeSeconds: -0.5...0.5,
                offsetStep: 1.0 / 30.0,
                confidenceThreshold: 0.60
            )
            let alignment = alignmentSummary(
                result: alignmentResult,
                sampled: sdrSequence.samples.count,
                sdrMetadata: input.sdrMetadata,
                hdrMetadata: input.hdrMetadata
            )
            let features = contentFeatures(sequence: hdrSequence, sourceID: input.candidate.sourceID)
            output.candidate.decode = sdrDecode
            output.candidate.alignment = alignment
            output.candidate.features = features
            output.candidate.contentCategory = features.tags
            let passed = sdrDecode.passed && hdrDecode.passed && alignment.matchRatio >= 0.95 && alignment.medianConfidence >= 0.70
            let conditional = sdrDecode.passed && hdrDecode.passed && alignment.matchRatio >= 0.90 && alignment.medianConfidence >= 0.60
            output.candidate.status = passed ? "PAIR_VALID" : conditional ? "PAIR_CONDITIONAL" : "PAIR_ALIGNMENT_FAIL"
            output.candidate.qualityGrade = passed && alignment.medianConfidence >= 0.80
                ? "A"
                : passed
                    ? "B"
                    : conditional && alignment.medianConfidence >= 0.60
                        ? "C"
                        : "REJECT"
            output.candidate.reason = passed
                ? "metadata, decode, structural alignment and spatial gates passed"
                : conditional
                    ? "usable but below preferred alignment gate"
                    : "decode or alignment gate failed"
        } catch {
            output.candidate.status = "PAIR_DECODE_FAILED"
            output.candidate.qualityGrade = "REJECT"
            output.candidate.reason = errorDescription(error)
        }
        return output
    }

    private static func decodeSummary(sequence: FrameSequence) -> V4LiveDecodeSummary {
        let duration = max(sequence.durationSeconds, sequence.samples.last?.timestamp.seconds ?? 1)
        let times = sequence.samples.map { $0.timestamp.seconds }
        func present(_ fraction: Double) -> Bool {
            guard let nearest = times.min(by: { abs($0 - duration * fraction) < abs($1 - duration * fraction) }) else { return false }
            return abs(nearest - duration * fraction) <= max(0.25, duration * 0.08)
        }
        let finite = sequence.samples.allSatisfy { sample in
            sample.lumaGrid.allSatisfy(\.isFinite) && sample.descriptor.meanLuma.isFinite
        }
        return V4LiveDecodeSummary(
            firstFrame: present(0),
            quarterFrame: present(0.25),
            middleFrame: present(0.5),
            threeQuarterFrame: present(0.75),
            lastFrame: present(1),
            decodedSampleCount: sequence.samples.count,
            allFinite: finite
        )
    }

    private static func alignmentSummary(
        result: AlignmentResult,
        sampled: Int,
        sdrMetadata: V4StreamMetadata,
        hdrMetadata: V4StreamMetadata
    ) -> V4AlignmentSummary {
        let confidences = result.matches.map(\.confidence).filter(\.isFinite).sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !confidences.isEmpty else { return 0 }
            return confidences[min(confidences.count - 1, Int(Double(confidences.count - 1) * fraction))]
        }
        let offsets = result.matches.map { $0.hdrTimeSeconds - $0.sdrTimeSeconds }.filter(\.isFinite)
        let meanOffset = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count)
        let variance = offsets.isEmpty ? 0 : offsets.reduce(0) { $0 + ($1 - meanOffset) * ($1 - meanOffset) } / Double(offsets.count)
        let aspectSDR = Double(sdrMetadata.width) / Double(max(1, sdrMetadata.height))
        let aspectHDR = Double(hdrMetadata.width) / Double(max(1, hdrMetadata.height))
        let aspectDelta = abs(aspectSDR - aspectHDR) / max(aspectSDR, aspectHDR)
        let spatial = aspectDelta < 0.02 ? ["IDENTICAL_OR_UNIFORM_SCALE"] : ["SPATIAL_MISMATCH"]
        let matched = confidences.count
        let status = matched == 0 || percentile(0.5) < 0.60
            ? "REJECT"
            : matched < Int(Double(max(1, sampled)) * 0.95) || percentile(0.5) < 0.70
                ? "CONDITIONAL"
                : "ALIGNED"
        func coverage(_ threshold: Double) -> Double {
            sampled > 0 ? Double(confidences.filter { $0 >= threshold }.count) / Double(sampled) : 0
        }
        return V4AlignmentSummary(
            sampledFrames: sampled,
            matchedFrames: matched,
            rejectedFrames: max(result.rejectedFrames, sampled - matched),
            matchRatio: sampled > 0 ? Double(matched) / Double(sampled) : 0,
            meanConfidence: confidences.isEmpty ? 0 : confidences.reduce(0, +) / Double(confidences.count),
            medianConfidence: percentile(0.5),
            p10Confidence: percentile(0.1),
            p50Confidence: percentile(0.5),
            p90Confidence: percentile(0.9),
            confidenceAtLeast60: coverage(0.60),
            confidenceAtLeast70: coverage(0.70),
            confidenceAtLeast80: coverage(0.80),
            estimatedTimeOffsetSeconds: result.coarseOffsetSeconds,
            offsetVariance: variance,
            spatialChecks: spatial,
            status: status
        )
    }

    private static func contentFeatures(sequence: FrameSequence, sourceID: String) -> V4LiveContentFeatures {
        let values = sequence.samples.map { Double($0.descriptor.meanLuma) }.filter(\.isFinite).sorted()
        let p: (Double) -> Double = { fraction in
            guard !values.isEmpty else { return 0 }
            return values[min(values.count - 1, Int(Double(values.count - 1) * fraction))]
        }
        let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let highlight = values.isEmpty ? 0 : Double(values.filter { $0 >= 0.75 }.count) / Double(values.count)
        let shadow = values.isEmpty ? 0 : Double(values.filter { $0 <= 0.20 }.count) / Double(values.count)
        let motionValues = zip(sequence.samples.dropFirst(), sequence.samples).map {
            abs(Double($0.0.descriptor.meanLuma - $0.1.descriptor.meanLuma))
        }
        let motion = motionValues.isEmpty ? 0 : motionValues.reduce(0, +) / Double(motionValues.count)
        var tags = sourceCategoryHints[sourceID] ?? ["unknown"]
        if mean < 0.25 && !tags.contains("low-key") { tags.append("low-key") }
        if mean > 0.65 && !tags.contains("high-key") { tags.append("high-key") }
        if p(0.99) - p(0.50) > 0.30 && !tags.contains("highlight-rich") { tags.append("highlight-rich") }
        if shadow > 0.35 && !tags.contains("shadow-rich") { tags.append("shadow-rich") }
        if p(0.90) - p(0.10) < 0.20 && !tags.contains("low-contrast") { tags.append("low-contrast") }
        if p(0.90) - p(0.10) > 0.45 && !tags.contains("high-contrast") { tags.append("high-contrast") }
        return V4LiveContentFeatures(
            meanLuminance: mean,
            p10Luminance: p(0.10),
            p50Luminance: p(0.50),
            p90Luminance: p(0.90),
            p95Luminance: p(0.95),
            p99Luminance: p(0.99),
            dynamicRange: p(0.99) - p(0.01),
            highlightRatio: highlight,
            shadowRatio: shadow,
            contrast: p(0.90) - p(0.10),
            motionProxy: motion,
            tags: Array(Set(tags)).sorted()
        )
    }

    private static func validationTargetIndices(
        candidates: [V4LiveCandidate],
        existingCategories: Set<String>,
        budget: Int
    ) -> Set<Int> {
        var pool = Set(candidates.indices)
        var covered = existingCategories
        var selected = Set<Int>()
        while !pool.isEmpty && selected.count < budget {
            guard let winner = pool.max(by: { lhs, rhs in
                let left = validationCoverageScore(candidates[lhs], covered: covered)
                let right = validationCoverageScore(candidates[rhs], covered: covered)
                if left == right { return candidates[lhs].id > candidates[rhs].id }
                return left < right
            }) else { break }
            selected.insert(winner)
            covered.formUnion(candidates[winner].contentCategory)
            pool.remove(winner)
        }
        return selected
    }

    private static func validationCoverageScore(
        _ candidate: V4LiveCandidate,
        covered: Set<String>
    ) -> Double {
        candidate.contentCategory.reduce(0) { partial, tag in
            covered.contains(tag) ? partial : partial + categoryWeights[tag, default: 1]
        }
    }

    private static func select(
        _ candidates: [V4LiveCandidate],
        existingCategories: Set<String>,
        count: Int
    ) -> [V4LiveCandidate] {
        var pool = candidates
        var selected: [V4LiveCandidate] = []
        var covered = existingCategories
        while !pool.isEmpty && selected.count < count {
            let scored = pool.map { candidate -> (V4LiveCandidate, Double) in
                let tags = Set(candidate.contentCategory)
                let missing = tags.subtracting(covered)
                let coverageScore = missing.reduce(0) { $0 + categoryWeights[$1, default: 1] }
                let qualityScore = candidate.qualityGrade == "A" ? 4.0 : 2.0
                let novelty: Double
                if let features = candidate.features, !selected.isEmpty {
                    let mean = selected.compactMap(\.features?.meanLuminance).reduce(0, +) / Double(max(1, selected.compactMap(\.features?.meanLuminance).count))
                    let range = selected.compactMap(\.features?.dynamicRange).reduce(0, +) / Double(max(1, selected.compactMap(\.features?.dynamicRange).count))
                    novelty = abs(features.meanLuminance - mean) + abs(features.dynamicRange - range)
                } else {
                    novelty = 0
                }
                return (candidate, coverageScore * 10 + qualityScore + novelty * 2)
            }
            guard let winner = scored.max(by: {
                if $0.1 == $1.1 { return $0.0.id > $1.0.id }
                return $0.1 < $1.1
            }) else { break }
            var candidate = winner.0
            candidate.selectionScore = winner.1
            candidate.reason = "selected for \(candidate.contentCategory.joined(separator: ", ")), quality \(candidate.qualityGrade), alignment median \(String(format: "%.3f", candidate.alignment?.medianConfidence ?? 0))"
            selected.append(candidate)
            covered.formUnion(candidate.contentCategory)
            pool.removeAll { $0.id == candidate.id }
        }
        return selected
    }

    private static func discoveryWithUpdatedCandidates(
        _ report: V4LiveDiscoveryReport,
        candidates: [V4LiveCandidate]
    ) -> V4LiveDiscoveryReport {
        V4LiveDiscoveryReport(
            root: report.root,
            sdrDirectory: report.sdrDirectory,
            hdrDirectory: report.hdrDirectory,
            totalFiles: report.totalFiles,
            sdrCandidates: report.sdrCandidates,
            hdrCandidates: report.hdrCandidates,
            uniqueSourceIDs: report.uniqueSourceIDs,
            extensionCounts: report.extensionCounts,
            unmatchedSDR: report.unmatchedSDR,
            unmatchedHDR: report.unmatchedHDR,
            pairCandidates: report.pairCandidates,
            candidates: candidates
        )
    }

    private static func relativePath(_ path: String, root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url)
    }

    private static func errorDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
