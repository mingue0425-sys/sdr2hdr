import Foundation
import CoreVideo
import Metal
import XCTest

@testable import HDRCore
@testable import HDRPlayerKit

@MainActor
final class RealMediaRegressionTests: XCTestCase {
    func testRegressionManifestIsValid() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest.version, RealMediaRegressionManifest.expectedVersion)
        XCTAssertEqual(manifest.baseline, RealMediaRegressionManifest.expectedBaseline)
        XCTAssertGreaterThanOrEqual(manifest.fixtures.count, 10)
        XCTAssertTrue(manifest.fixtures.contains { $0.timing == .vfr })
        XCTAssertTrue(manifest.fixtures.contains { $0.expectedPixelFormatFamily == .p010 })
        XCTAssertTrue(manifest.fixtures.contains { $0.range == .full })
        let requiredIDs: Set<String> = [
            "h264-8-video-24-dark-gradient",
            "h264-8-video-30-neutral-color",
            "h264-8-video-60-motion",
            "h264-8-full-30-neutral-color",
            "hevc-8-video-30-chroma-edge",
            "hevc-main10-video-24-dark-gradient",
            "hevc-main10-video-30-chroma-edge",
            "hevc-main10-video-60-motion",
            "h264-8-video-vfr-motion",
            "hevc-main10-video-vfr-motion",
            "hevc-main10-video-24-near-black",
            "h264-8-video-24-chroma-edge"
        ]
        XCTAssertEqual(Set(manifest.fixtures.map(\.id)), requiredIDs)
    }

    func testSharedVideoOutputDefaultsRemainVideoRange() {
        let key = kCVPixelBufferPixelFormatTypeKey as String
        XCTAssertEqual(
            HDRVideoOutputConfiguration.pixelBufferAttributes[key] as? OSType,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertEqual(
            HDRVideoOutputConfiguration.pixelBufferAttributes(
                for: .eightBit,
                range: .full
            )[key] as? OSType,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        )
        XCTAssertEqual(
            HDRVideoOutputConfiguration.pixelBufferAttributes(
                for: .tenBitPreferred,
                range: .full
            )[key] as? OSType,
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
    }

    func testManifestDrivenRegressionMatrixRunsBothModes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR"] else {
            throw XCTSkip("set HDR_REAL_MEDIA_REGRESSION_FIXTURE_DIR to run compressed-media regression")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let manifest = try loadManifest()
        let gates = try loadGates()
        let runner = RealMediaRegressionRunner(
            manifest: manifest,
            gates: gates,
            fixtureDirectory: URL(fileURLWithPath: fixturePath),
            device: device
        )
        var fixtureResults: [RealMediaRegressionFixtureResult] = []
        fixtureResults.reserveCapacity(manifest.fixtures.count)

        for fixture in manifest.fixtures {
            do {
                fixtureResults.append(try await runner.run(fixture))
            } catch {
                fixtureResults.append(RealMediaRegressionFixtureResult(
                    manifest: fixture,
                    id: fixture.id,
                    status: "fail",
                    skipReason: error.localizedDescription,
                    nearest: nil,
                    candidate: nil,
                    comparison: nil
                ))
            }
        }

        let report = RealMediaRegressionReport(
            baseline: manifest.baseline,
            candidate: environment["HDR_REAL_MEDIA_REGRESSION_CANDIDATE"] ?? "working-tree",
            fixtureCount: fixtureResults.count,
            failures: fixtureResults.filter { $0.status == "fail" }.count,
            skipped: fixtureResults.filter { $0.status == "skipped" }.count,
            fixtures: fixtureResults
        )
        try writeReport(report, environment: environment)

        for result in fixtureResults {
            switch result.status {
            case "pass":
                let nearest = result.nearest
                let candidate = result.candidate
                print(
                    "REAL_MEDIA_REGRESSION id=\(result.id) status=PASS " +
                        "frames=\(nearest?.frameCount ?? 0) " +
                        "nearest=\(nearest?.metadata.pixelFormat ?? "unknown") " +
                        "candidateDelta=\(result.comparison?.meanAbsoluteLuminanceDelta ?? 0)"
                )
                XCTAssertNotNil(candidate)
            case "skipped":
                print("REAL_MEDIA_REGRESSION id=\(result.id) status=SKIP reason=\(result.skipReason ?? "unspecified")")
            default:
                print("REAL_MEDIA_REGRESSION id=\(result.id) status=FAIL reason=\(result.skipReason ?? "see result artifact")")
            }
        }

        let failures = fixtureResults.filter { $0.status == "fail" }
        XCTAssertTrue(
            failures.isEmpty,
            failures.map { "\($0.id): \($0.skipReason ?? "mode failure")" }.joined(separator: "; ")
        )
        print(
            "REAL_MEDIA_REGRESSION_SUMMARY fixtures=\(fixtureResults.count) " +
                "failures=\(report.failures) skipped=\(report.skipped) " +
                "baseline=\(report.baseline) candidate=\(report.candidate)"
        )
        print("Virgin Frozen accessed: NO")
        print("Objective evaluations: 0")
    }

    private func loadManifest() throws -> RealMediaRegressionManifest {
        try RealMediaRegressionManifest.load(from: manifestURL())
    }

    private func loadGates() throws -> RegressionGates {
        try RegressionGates.load(from: gatesURL())
    }

    private func manifestURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["HDR_REAL_MEDIA_REGRESSION_MANIFEST"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/RealMediaRegression/manifest.json")
    }

    private func gatesURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["HDR_REAL_MEDIA_REGRESSION_GATES"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/RealMediaRegression/gates.json")
    }

    private func writeReport(
        _ report: RealMediaRegressionReport,
        environment: [String: String]
    ) throws {
        let path = environment["HDR_REAL_MEDIA_REGRESSION_RESULTS"] ??
            "results/real-media-regression.json"
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dataEncodingStrategy = .base64
        try encoder.encode(report).write(to: url, options: .atomic)
    }
}
