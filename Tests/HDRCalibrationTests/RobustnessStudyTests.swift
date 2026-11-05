import Foundation
import XCTest
@testable import HDRCalibration
import HDRCore

/// The robustness study's verdict rests on a few pure helpers: the high-pass
/// used for artifact energy, the flat-pixel percentile gate, the metric
/// aggregation and the derived benefit/amplification ratios. These pin their
/// arithmetic so a refactor cannot silently change what the report claims.
final class RobustnessStudyTests: XCTestCase {
    private func metrics(error: Double, highlight: Double, flatHighlightHP: Double) -> RobustnessStudy.Metrics {
        RobustnessStudy.Metrics(
            errorAll: error, errorHighlight: highlight, flatHighPass: 0,
            flatHighlightHighPass: flatHighlightHP, temporalErrorStd: 0
        )
    }

    func testHighPassIsZeroOnConstantAndRampFields() {
        let constant = [Float](repeating: 0.4, count: 25)
        XCTAssertTrue(RobustnessStudy.highPass(constant, width: 5, height: 5).allSatisfy { abs($0) < 1e-6 })
        // Interior of a linear ramp equals its 3x3 mean.
        let ramp = (0..<25).map { Float($0 % 5) * 0.1 }
        let hp = RobustnessStudy.highPass(ramp, width: 5, height: 5)
        for y in 1..<4 { for x in 1..<4 { XCTAssertEqual(hp[y * 5 + x], 0, accuracy: 1e-6) } }
    }

    func testHighPassIsolatesAnImpulse() {
        var field = [Float](repeating: 0, count: 9)
        field[4] = 9
        let hp = RobustnessStudy.highPass(field, width: 3, height: 3)
        XCTAssertEqual(hp[4], 8, accuracy: 1e-6)
        XCTAssertEqual(hp[0], -1, accuracy: 1e-6)
    }

    func testPercentileUsesSortedIndexAndHandlesEmpty() {
        XCTAssertEqual(RobustnessStudy.percentile([], 0.3), 0)
        let values: [Float] = [9, 1, 5, 3, 7, 0, 2, 4, 6, 8, 10]
        XCTAssertEqual(RobustnessStudy.percentile(values, 0.30), 3)
        XCTAssertEqual(RobustnessStudy.percentile(values, 1.0), 10)
    }

    func testMeasureIsZeroForPerfectOutputAndFlagsHighlights() {
        let frame = [Float](repeating: 1_000, count: 16)
        let perfect = RobustnessStudy.measure(output: [frame, frame], reference: [frame, frame], width: 4, height: 4, paperWhite: 203)
        XCTAssertEqual(perfect.errorAll, 0, accuracy: 1e-9)
        XCTAssertEqual(perfect.errorHighlight, 0, accuracy: 1e-9)
        XCTAssertEqual(perfect.temporalErrorStd, 0, accuracy: 1e-9)

        let darker = [Float](repeating: 500, count: 16)
        let biased = RobustnessStudy.measure(output: [darker], reference: [frame], width: 4, height: 4, paperWhite: 203)
        let expected = Double(HDRColorMath.pqEncode(nits: 1_000) - HDRColorMath.pqEncode(nits: 500))
        XCTAssertEqual(biased.errorAll, expected, accuracy: 1e-6)
        // 1000 nits > 2 x 203, so every pixel is a highlight.
        XCTAssertEqual(biased.errorHighlight, expected, accuracy: 1e-6)
    }

    func testMeasureReportsTemporalInstability() {
        let reference = [Float](repeating: 100, count: 16)
        let up = [Float](repeating: 120, count: 16)
        let down = [Float](repeating: 80, count: 16)
        let stable = RobustnessStudy.measure(output: [up, up], reference: [reference, reference], width: 4, height: 4, paperWhite: 203)
        let flicker = RobustnessStudy.measure(output: [up, down], reference: [reference, reference], width: 4, height: 4, paperWhite: 203)
        XCTAssertEqual(stable.temporalErrorStd, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(flicker.temporalErrorStd, 0.01)
    }

    func testDeriveComputesBenefitAndAddedEnergyAmplification() throws {
        let rows = [
            RobustnessStudy.Row(pairID: "p", variant: "clean", configuration: "no-expansion",
                                metrics: metrics(error: 0.10, highlight: 0.20, flatHighlightHP: 0.003)),
            RobustnessStudy.Row(pairID: "p", variant: "clean", configuration: "v4",
                                metrics: metrics(error: 0.08, highlight: 0.12, flatHighlightHP: 0.004)),
            RobustnessStudy.Row(pairID: "p", variant: "noise", configuration: "no-expansion",
                                metrics: metrics(error: 0.11, highlight: 0.21, flatHighlightHP: 0.005)),
            RobustnessStudy.Row(pairID: "p", variant: "noise", configuration: "v4",
                                metrics: metrics(error: 0.09, highlight: 0.14, flatHighlightHP: sqrt(0.004 * 0.004 + 0.008 * 0.008)))
        ]
        let derived = RobustnessStudy.derive(rows)
        XCTAssertEqual(derived.count, 2, "no-expansion rows are the baseline, not candidates")
        let noise = try XCTUnwrap(derived.first { $0.variant == "noise" })
        XCTAssertEqual(noise.benefitAll, 0.02, accuracy: 1e-9)
        XCTAssertEqual(noise.benefitHighlight, 0.07, accuracy: 1e-9)
        // Added energy: candidate sqrt(hp² - clean²) = 0.008, baseline sqrt(0.005² - 0.003²) = 0.004.
        XCTAssertEqual(noise.addedArtifactPQ, 0.008, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(noise.artifactAmplification), 2.0, accuracy: 1e-6)
        let clean = try XCTUnwrap(derived.first { $0.variant == "clean" })
        XCTAssertNil(clean.artifactAmplification, "clean adds no artifact energy to normalise by")
    }

    func testDefaultCandidatesAreGuidedAndDistinct() {
        let names = RobustnessStudy.defaultGuidanceCandidates.map(\.0)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(RobustnessStudy.defaultGuidanceCandidates.allSatisfy { $0.1.radius > 0 && $0.1.tolerance > 0 })
        XCTAssertEqual(RobustnessStudy.variants.first?.id, "clean", "derive() normalises by the clean variant")
    }

    /// A seek that lands between source frames leaves the cut clip starting
    /// at a small positive PTS. QuickTime stores that as an empty edit and
    /// AVAssetReader then emits a synthetic black frame at t=0, shifting
    /// every frame by one. Re-encoded variants start at 0 and do not get that
    /// frame, so they were silently compared one frame off the reference.
    func testPreparedClipsStartAtZeroWithoutSyntheticLeadingFrame() async throws {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("ffmpeg is required for the robustness clip preparation test")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-robustness-prep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func encode(_ name: String, _ arguments: [String]) throws -> URL {
            let url = root.appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                                 "-f", "lavfi", "-i", "testsrc2=size=64x36:rate=60:duration=1"] + arguments + [url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "fixture \(name) failed")
            return url
        }
        let sdr = try encode("sdr.mp4", ["-vf", "format=yuv420p,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709",
                                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-qp", "10",
                                        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"])
        let hdr = try encode("hdr.mp4", ["-vf", "format=yuv420p10le,setparams=range=tv:color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc",
                                        "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-x265-params", "log-level=error",
                                        "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"])
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // 0.5083 s falls between the 60 fps frames at 0.5000 and 0.5167.
        let prepared = try RobustnessStudy.prepare(sdr: sdr, hdr: hdr, start: 0.5083, frames: 6, width: 32, directory: work)
        let identity = try RobustnessStudy.makeVariant(
            RobustnessStudy.Variant(id: "identity", description: "control", filter: "null", x264CRF: nil),
            clean: prepared.cleanSDR, directory: work, width: 32, height: 18
        )
        for (label, url, format) in [("clean", prepared.cleanSDR, CalibrationPixelFormat.sdrNV12),
                                     ("reference", prepared.reference, CalibrationPixelFormat.hdrP010),
                                     ("identity variant", identity, CalibrationPixelFormat.sdrNV12)] {
            let frames = try await RobustnessStudy.readFrames(url, pixelFormat: format, limit: 100)
            XCTAssertEqual(frames.count, 6, "\(label): synthetic leading frame or dropped frame")
            XCTAssertEqual(frames.first?.seconds ?? -1, 0, accuracy: 1e-6, "\(label) must start at PTS 0")
        }
    }

    func testWindowStartStaysInsideShortClips() {
        XCTAssertEqual(RobustnessStudy.windowStart(durationSeconds: 10), 0)
        XCTAssertEqual(RobustnessStudy.windowStart(durationSeconds: 25), 0, "a 30 s seek would pass the end")
        XCTAssertEqual(RobustnessStudy.windowStart(durationSeconds: 31), 0)
        XCTAssertEqual(RobustnessStudy.windowStart(durationSeconds: 32), 30)
        XCTAssertEqual(RobustnessStudy.windowStart(durationSeconds: 300), 30)
    }

    func testAdaptiveToleranceScalesWithNoiseAndIsClamped() {
        let candidate = RobustnessStudy.AdaptiveGuidance(id: "a", radius: 2, k: 3, minimumTolerance: 0.02, maximumTolerance: 0.15)
        XCTAssertEqual(candidate.tolerance(forSigma: 0), 0.02, "clean input keeps the floor")
        XCTAssertEqual(candidate.tolerance(forSigma: 0.02), 0.06, accuracy: 1e-6)
        XCTAssertEqual(candidate.tolerance(forSigma: 1), 0.15, "heavy noise is capped")
        let ids = RobustnessStudy.defaultAdaptiveCandidates.map(\.id) + RobustnessStudy.defaultGuidanceCandidates.map(\.0)
        XCTAssertEqual(Set(ids).count, ids.count, "configuration names must be unique in the report")
    }
}
