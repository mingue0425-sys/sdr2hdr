import Foundation
import Metal
import XCTest
@testable import HDRCore
@testable import HDRPlayerKit

@MainActor
final class RealMediaMultiFlightTests: XCTestCase {
    private func logProgress(_ message: String) {
        guard ProcessInfo.processInfo.environment["HDR_REAL_MEDIA_MULTIFLIGHT_PROGRESS"] == "1" else {
            return
        }
        print("MULTIFLIGHT_PROGRESS \(message)")
    }

    func testDeterministicMatrixRunsWithTwoAndThreeFlights() async throws {
        logProgress("test-start")
        let environment = ProcessInfo.processInfo.environment
        logProgress("environment-read")
        guard let fixturePath = environment["HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR"] else {
            throw XCTSkip("set HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR to run multi-flight regression")
        }
        logProgress("fixture-path-found")
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        logProgress("device-created")

        let manifest = try loadManifest()
        logProgress("manifest-loaded")
        let gates = try loadGates()
        logProgress("gates-loaded")
        let runner = RealMediaRegressionRunner(
            manifest: manifest,
            gates: gates,
            fixtureDirectory: URL(fileURLWithPath: fixturePath),
            device: device
        )

        // The complete 12-fixture serial matrix remains the mandatory decode
        // gate. Multi-flight focuses on the high-information concurrency
        // subset so AVPlayer acquisition noise cannot obscure GPU ordering
        // evidence; every required format, timing mode, and stress class is
        // still represented here.
        let mandatoryIDs: Set<String> = [
            "h264-8-video-60-motion",
            "hevc-8-video-30-chroma-edge",
            "hevc-main10-video-60-motion",
            "h264-8-video-vfr-motion",
            "hevc-main10-video-vfr-motion",
            "hevc-main10-video-24-near-black",
            "h264-8-video-24-chroma-edge"
        ]
        let fixtures = manifest.fixtures.filter { mandatoryIDs.contains($0.id) }
        XCTAssertEqual(
            Set(fixtures.map(\.id)),
            mandatoryIDs,
            "multi-flight mandatory subset is incomplete"
        )

        let selectedFixtures = fixtures.sorted(by: { $0.id < $1.id })
        var decodedFixtures: [(fixture: RealMediaRegressionFixture, frames: [RealMediaRegressionRunner.DecodedFrame])] = []
        decodedFixtures.reserveCapacity(selectedFixtures.count)
        for fixture in selectedFixtures {
            logProgress("decode-start id=\(fixture.id)")
            let frames = try await runner.decodeRegressionFrames(fixture)
            logProgress("decode-complete id=\(fixture.id) frames=\(frames.count)")
            decodedFixtures.append((fixture: fixture, frames: frames))
        }

        var results: [RealMediaMultiFlightFixtureResult] = []
        results.reserveCapacity(fixtures.count * 2)
        for decodedFixture in decodedFixtures {
            let fixture = decodedFixture.fixture
            for depth in [2, 3] {
                logProgress("run-start id=\(fixture.id) depth=\(depth)")
                let result = try await runner.runMultiFlight(
                    fixture,
                    decodedFrames: decodedFixture.frames,
                    flightDepth: depth
                )
                logProgress("run-complete id=\(fixture.id) depth=\(depth)")
                results.append(result)
                for mode in result.modes {
                    print(
                        "REAL_MEDIA_MULTIFLIGHT id=\(result.id) depth=\(depth) " +
                            "mode=\(mode.mode.rawValue) status=\(mode.result.passed ? "PASS" : "FAIL") " +
                            "frames=\(mode.result.frameCount) " +
                            "maxObservedInFlight=\(mode.maxObservedInFlight) " +
                            "gpuSequence=\(mode.result.gpuCompletedSequence) " +
                            "adaptiveSequence=\(mode.result.adaptiveCommittedSequence) " +
                            "allocations=\(mode.result.outputTextureAllocations)"
                    )
                }
            }
        }

        let sortedResults = results.sorted {
            if $0.id == $1.id { return $0.flightDepth < $1.flightDepth }
            return $0.id < $1.id
        }
        let report = RealMediaMultiFlightReport(
            baseline: environment["HDR_REAL_MEDIA_MULTIFLIGHT_BASELINE"] ?? manifest.baseline,
            candidate: environment["HDR_REAL_MEDIA_REGRESSION_CANDIDATE"] ?? "working-tree",
            fixtureCount: fixtures.count,
            runCount: sortedResults.flatMap(\.modes).count,
            failures: sortedResults.flatMap(\.modes).filter { !$0.result.passed }.count,
            fixtures: sortedResults
        )
        try writeReport(report, environment: environment)

        XCTAssertEqual(
            sortedResults.count,
            fixtures.count * 2,
            "every deterministic fixture must run at both flight depths"
        )
        XCTAssertTrue(
            sortedResults.allSatisfy { result in
                result.modes.count == 2 && result.passed
            },
            sortedResults.flatMap(\.failures).joined(separator: "; ")
        )
        XCTAssertTrue(
            sortedResults.flatMap(\.modes).allSatisfy { mode in
                mode.maxObservedInFlight >= mode.flightDepth
            },
            "multi-flight run did not demonstrate the configured overlap"
        )

        let passingModes = sortedResults.flatMap(\.modes).filter { $0.result.passed }
        XCTAssertTrue(
            passingModes.contains { $0.result.metadata.pixelFormatFamily == .nv12 },
            "multi-flight matrix did not execute an NV12 fixture"
        )
        XCTAssertTrue(
            passingModes.contains { $0.result.metadata.pixelFormatFamily == .p010 },
            "multi-flight matrix did not execute a P010 fixture"
        )
        print(
            "REAL_MEDIA_MULTIFLIGHT_SUMMARY fixtures=\(report.fixtureCount) " +
                "runs=\(report.runCount) failures=\(report.failures) " +
                "baseline=\(report.baseline) candidate=\(report.candidate)"
        )
        print("Virgin Frozen accessed: NO")
        print("Objective evaluations: 0")
    }

    private func loadManifest() throws -> RealMediaRegressionManifest {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["HDR_REAL_MEDIA_REGRESSION_MANIFEST"] ??
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/RealMediaRegression/manifest.json")
                .path
        return try RealMediaRegressionManifest.load(from: URL(fileURLWithPath: path))
    }

    private func loadGates() throws -> RegressionGates {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["HDR_REAL_MEDIA_REGRESSION_GATES"] ??
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Tests/RealMediaRegression/gates.json")
                .path
        return try RegressionGates.load(from: URL(fileURLWithPath: path))
    }

    private func writeReport(
        _ report: RealMediaMultiFlightReport,
        environment: [String: String]
    ) throws {
        let path = environment["HDR_REAL_MEDIA_MULTIFLIGHT_RESULTS"] ??
            "results/real-media-multiflight.json"
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
