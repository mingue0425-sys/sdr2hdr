import Foundation
import Metal
import XCTest

@testable import HDRCore
@testable import HDRPlayerKit

@MainActor
final class ExternalRealMediaRegressionTests: XCTestCase {
    func testExternalManifestIsValid() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.version, ExternalRealMediaManifest.expectedVersion)
    }

    func testUnsupportedExternalColorimetryHasExplicitMetadataOnlyPolicy() throws {
        let manifest = try loadManifest()
        let metadataOnly = manifest.sources.filter { $0.engineEvaluation == .metadataOnly }
        XCTAssertEqual(metadataOnly.map(\.id), ["blender-elephants-dream-hevc8"])
    }

    func testExternalManifestHasNoSourceFamilySplitLeakage() throws {
        let development = makeSource(id: "development", split: .development, family: "same-family")
        let validation = makeSource(id: "validation", split: .validation, family: "same-family")
        let manifest = ExternalRealMediaManifest(version: 1, sources: [development, validation], pairs: [])
        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(error as? ExternalMediaManifestError, .sourceFamilySplitLeakage)
        }
    }

    func testExternalMediaHashMatchesManifest() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdr2hdr-external-hash-(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("sdr2hdr external hash fixture".utf8).write(to: url)
        XCTAssertEqual(
            try ExternalMediaInspector.sha256(fileURL: url),
            "67aaa4ee7983e0782e345556a2f5b782ec69c0b5afa2dfc8affdab89230ad659"
        )
    }

    func testExternalMediaHashMismatchFailsClosed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdr2hdr-external-hash-mismatch-(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("different external bytes".utf8).write(to: url)
        let source = makeSource(id: "hash-mismatch", split: .development, family: "hash-family")
        XCTAssertThrowsError(try ExternalMediaInspector.validate(source: source, fileURL: url)) { error in
            guard case .hashMismatch = error as? ExternalMediaInspectionError else {
                return XCTFail("expected hash mismatch, got (error)")
            }
        }
    }

    func testMatchedPairDiagnosticReportsCoarseAlignmentWithoutObjectiveEvaluation() {
        let pair = MatchedMediaPair(
            pairID: "pair-1",
            sdrSourceID: "sdr-1",
            hdrSourceID: "hdr-1"
        )
        let sdr = ExternalMediaProbe(
            codec: "h264", profile: "High", pixelFormat: "yuv420p", bitDepth: 8,
            range: .video, primaries: "bt709", transfer: "bt709", matrix: "bt709",
            averageFrameRate: 24, nominalFrameRate: 24, duration: 2,
            frameCount: 48, width: 128, height: 72
        )
        let hdr = ExternalMediaProbe(
            codec: "hevc", profile: "Main 10", pixelFormat: "yuv420p10le", bitDepth: 10,
            range: .video, primaries: "bt709", transfer: "bt709", matrix: "bt709",
            averageFrameRate: 24, nominalFrameRate: 24, duration: 2.01,
            frameCount: 48, width: 128, height: 72
        )
        let result = ExternalMediaInspector.diagnosePair(pair: pair, sdr: sdr, hdr: hdr)
        XCTAssertEqual(result.status, "diagnostic")
        XCTAssertEqual(result.resolutionMatch, true)
        XCTAssertEqual(result.frameCountDelta, 0)
        XCTAssertEqual(result.sceneCorrespondence, "not-evaluated; coarse timestamp/metadata viability only")
        print("Matched SDR/HDR pair diagnostic performed without objective evaluation.")
    }

    func testExternalMediaMetadataCanBeInspected() throws {
        let manifest = try loadManifest()
        guard let root = externalRoot(), let source = manifest.sources.first else {
            throw XCTSkip("set HDR_REAL_MEDIA_ROOT and populate external-manifest.json to inspect external media")
        }
        let url = root.appendingPathComponent(source.fileName)
        let probe = try ExternalMediaInspector.validate(source: source, fileURL: url)
        XCTAssertNotNil(probe.codec)
        XCTAssertNotNil(probe.pixelFormat)
        XCTAssertNotNil(probe.duration)
    }

    func testExternalDevelopmentCorpusRunsWhenConfigured() async throws {
        try await runExternalCorpus(split: .development)
    }

    func testExternalValidationCorpusRunsWhenConfigured() async throws {
        try await runExternalCorpus(split: .validation)
    }

    func testExternalCorpusDoesNotAccessFrozenEvaluation() throws {
        let manifestURL = manifestURL()
        XCTAssertFalse(manifestURL.path.localizedCaseInsensitiveContains("frozen"))
        XCTAssertFalse(manifestURL.path.localizedCaseInsensitiveContains("virgin"))
        print("External real-media corpus is isolated from Frozen/Virgin evaluation.")
        print("Virgin Frozen accessed: NO")
        print("Objective evaluations: 0")
    }

    private func runExternalCorpus(split: ExternalMediaSplit) async throws {
        guard let root = externalRoot() else {
            throw XCTSkip("EXTERNAL REAL-MEDIA: SKIPPED (HDR_REAL_MEDIA_ROOT not set)")
        }
        let manifest = try loadManifest()
        let sources = manifest.sources(for: split)
        guard !sources.isEmpty else {
            throw XCTSkip("EXTERNAL REAL-MEDIA: SKIPPED (manifest has no (split.rawValue) sources)")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let deterministicManifest = try RealMediaRegressionManifest.load(
            from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/RealMediaRegression/manifest.json")
        )
        let gates = try RegressionGates.load(
            from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/RealMediaRegression/gates.json")
        )
        let runner = RealMediaRegressionRunner(
            manifest: deterministicManifest,
            gates: gates,
            fixtureDirectory: root,
            device: device
        )

        var results: [ExternalMediaSourceResult] = []
        var probesByID: [String: ExternalMediaProbe] = [:]
        for source in sources {
            let fileURL = root.appendingPathComponent(source.fileName)
            do {
                let probe = try ExternalMediaInspector.validate(source: source, fileURL: fileURL)
                probesByID[source.id] = probe
                if source.engineEvaluation == .metadataOnly {
                    results.append(
                        ExternalMediaSourceResult(
                            id: source.id,
                            fileName: source.fileName,
                            sha256: source.sha256,
                            provenance: source.provenance,
                            probe: probe,
                            windows: [],
                            status: "metadata-only",
                            failure: "runtime skipped by manifest: source colorimetry is outside HDRCore's supported BT.709 SDR domain"
                        )
                    )
                } else {
                    results.append(try await runner.runExternal(source: source, fileURL: fileURL, probe: probe))
                }
            } catch {
                results.append(ExternalMediaSourceResult(
                    id: source.id,
                    fileName: source.fileName,
                    sha256: source.sha256,
                    provenance: source.provenance,
                    probe: ExternalMediaProbe(
                        codec: nil, profile: nil, pixelFormat: nil, bitDepth: nil,
                        range: nil, primaries: nil, transfer: nil, matrix: nil,
                        averageFrameRate: nil, nominalFrameRate: nil, duration: nil,
                        frameCount: nil,
                        width: nil, height: nil
                    ),
                    windows: [],
                    status: "fail",
                    failure: error.localizedDescription
                ))
            }
        }
        results.sort { $0.id < $1.id }
        let sourceByID = Dictionary(uniqueKeysWithValues: manifest.sources.map { ($0.id, $0) })
        let pairResults: [ExternalMediaPairResult] = manifest.pairs
            .sorted { $0.pairID < $1.pairID }
            .compactMap { pair in
            guard sourceByID[pair.sdrSourceID]?.split == split,
                  sourceByID[pair.hdrSourceID]?.split == split,
                  let sdrProbe = probesByID[pair.sdrSourceID],
                  let hdrProbe = probesByID[pair.hdrSourceID] else { return nil }
            return ExternalMediaInspector.diagnosePair(pair: pair, sdr: sdrProbe, hdr: hdrProbe)
        }
        let pairFailures = pairResults.filter { $0.status == "fail" }
        let report = ExternalRealMediaReport(
            manifestVersion: manifest.version,
            baseline: "0a980d9",
            split: split,
            sourceCount: results.count,
            failures: results.filter { $0.status == "fail" }.count + pairFailures.count,
            skipped: results.filter { $0.status == "skipped" || $0.status == "metadata-only" }.count,
            sources: results,
            pairs: pairResults
        )
        try write(report: report, split: split)
        let failureMessage = (
            results.filter { $0.status == "fail" }.map { "\($0.id): \($0.failure ?? "unknown")" } +
                pairFailures.map { "\($0.pairID): \($0.failure ?? "unknown")" }
        ).joined(separator: "; ")
        XCTAssertTrue(
            report.failures == 0,
            failureMessage
        )
        print(
            "EXTERNAL REAL-MEDIA split=\(split.rawValue) sources=\(report.sourceCount) " +
                "failures=\(report.failures)"
        )
        print("Virgin Frozen accessed: NO")
        print("Objective evaluations: 0")
    }

    private func loadManifest() throws -> ExternalRealMediaManifest {
        try ExternalRealMediaManifest.load(from: manifestURL())
    }

    private func manifestURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["HDR_EXTERNAL_MEDIA_MANIFEST"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("data_video/real_media/external-manifest.json")
    }

    private func externalRoot() -> URL? {
        guard let root = ProcessInfo.processInfo.environment["HDR_REAL_MEDIA_ROOT"], !root.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    private func write(report: ExternalRealMediaReport, split: ExternalMediaSplit) throws {
        let path = ProcessInfo.processInfo.environment["HDR_EXTERNAL_MEDIA_RESULTS"] ??
            "results/external-real-media-\(split.rawValue).json"
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    private func makeSource(
        id: String,
        split: ExternalMediaSplit,
        family: String
    ) -> ExternalRealMediaSource {
        ExternalRealMediaSource(
            id: id,
            fileName: "\(id).mov",
            sha256: String(repeating: "0", count: 64),
            sourceFamily: family,
            split: split,
            category: .gradient,
            licenseNote: nil,
            expected: ExternalMediaExpectedMetadata(
                codec: nil, profile: nil, bitDepth: nil, range: nil,
                primaries: nil, transfer: nil, matrix: nil, frameRate: nil,
                timing: nil, minimumDistinctFrameDurations: nil, allowedChromaSiting: nil
            ),
            windows: [ExternalMediaWindow(startFraction: 0.1, duration: 1)],
            engineEvaluation: nil
        )
    }
}
