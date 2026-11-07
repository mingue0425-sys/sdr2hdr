import CoreMedia
import Foundation
import XCTest
@testable import HDRCalibration

/// The FFmpeg proxy must report each frame's original presentation time and
/// source ordinal. It may decimate, but it must never duplicate a frame or
/// synthesize a uniform timeline for variable-frame-rate input.
final class ProxyTemporalFidelityTests: XCTestCase {
    func testShowinfoParserReadsIntegerPTSAndTimeBase() throws {
        let log = """
        Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mp4':
        [Parsed_showinfo_1 @ 0x78e903dd40] config in time_base: 1/12288, frame_rate: 24/1
        [Parsed_showinfo_1 @ 0x78e903dd40] config out time_base: 0/0, frame_rate: 0/0
        [Parsed_showinfo_1 @ 0x78e903dd40] n:   0 pts:   4096 pts_time:0.333333 duration: 512 fmt:yuv420p
        [Parsed_showinfo_1 @ 0x78e903dd40]   color_range:tv color_space:bt709
        [Parsed_showinfo_1 @ 0x78e903dd40] n:   1 pts:   4608 pts_time:0.375 duration: 512 fmt:yuv420p
        [Parsed_showinfo_1 @ 0x78e903dd40] n:   2 pts:   6144 pts_time:0.5 duration: 512 fmt:yuv420p
        """
        let frames = try FFmpegShowinfoParser.parse(log)
        XCTAssertEqual(frames.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(frames.map(\.pts), [4096, 4608, 6144])
        XCTAssertEqual(frames[0].seconds, 4096.0 / 12288.0, accuracy: 1e-12)
        XCTAssertEqual(frames[2].seconds, 0.5, accuracy: 1e-12)
    }

    func testShowinfoParserRejectsMissingTimeBaseAndOutOfOrderOrdinals() {
        XCTAssertThrowsError(try FFmpegShowinfoParser.parse(
            "[Parsed_showinfo_1 @ 0x1] n:   0 pts:   0 pts_time:0"
        ))
        XCTAssertThrowsError(try FFmpegShowinfoParser.parse("""
        [Parsed_showinfo_1 @ 0x1] config in time_base: 1/90000, frame_rate: 0/1
        [Parsed_showinfo_1 @ 0x1] n:   1 pts:   3000 pts_time:0.0333
        [Parsed_showinfo_1 @ 0x1] n:   0 pts:   0 pts_time:0
        """))
    }

    func testPacketTableMapsFramesToSourceOrdinalsWithDropProvenance() throws {
        // 24 fps base with every third frame delayed by one tick (VFR).
        let packets = [0.0, 1, 2, 4, 5, 6, 8, 9].map { $0 / 24 }
        let table = try SourcePresentationTable(
            presentationSeconds: packets.shuffled(),
            streamStartSeconds: 0
        )
        XCTAssertEqual(table.frameCount, 8)
        XCTAssertTrue(table.isVariableFrameRate)
        let provenance = try table.provenance(
            forFrameSeconds: [2.0 / 24, 5.0 / 24, 9.0 / 24],
            policy: FrameTemporalProvenance.ffmpegSourcePTSPolicy
        )
        XCTAssertEqual(provenance.sourceFrameIndices, [2, 4, 7])
        XCTAssertEqual(provenance.skippedSourceFramesBefore, [0, 1, 2])
        XCTAssertEqual(provenance.duplicatedFrameCount, 0)
        XCTAssertEqual(provenance.sourceIsVariableFrameRate, true)
        XCTAssertEqual(provenance.sourceTimestampsSeconds[1], 5.0 / 24, accuracy: 1e-12)
    }

    func testPacketTableFailsClosedOnUnknownOrDuplicatedFrames() throws {
        let table = try SourcePresentationTable(
            presentationSeconds: (0..<10).map { Double($0) / 30 },
            streamStartSeconds: 0
        )
        XCTAssertFalse(table.isVariableFrameRate)
        // A synthesized time that is not a source frame must not be mapped.
        XCTAssertThrowsError(try table.provenance(
            forFrameSeconds: [0, 0.5 / 30],
            policy: FrameTemporalProvenance.ffmpegSourcePTSPolicy
        ))
        // A duplicated frame (what the old fps filter produced) is rejected.
        XCTAssertThrowsError(try table.provenance(
            forFrameSeconds: [1.0 / 30, 1.0 / 30],
            policy: FrameTemporalProvenance.ffmpegSourcePTSPolicy
        ))
        XCTAssertThrowsError(try SourcePresentationTable(
            presentationSeconds: [],
            streamStartSeconds: 0
        ))
    }

    func testPacketTableDropsEditListPrerollBeforeStreamStart() throws {
        let table = try SourcePresentationTable(
            presentationSeconds: [-2.0 / 24, -1.0 / 24, 0, 1.0 / 24, 2.0 / 24],
            streamStartSeconds: 0
        )
        XCTAssertEqual(table.frameCount, 3)
        let provenance = try table.provenance(
            forFrameSeconds: [0, 2.0 / 24],
            policy: FrameTemporalProvenance.ffmpegSourcePTSPolicy
        )
        XCTAssertEqual(provenance.sourceFrameIndices, [0, 2])
    }

    func testSelectionDecimatesOnlyBelowNativeRate() {
        XCTAssertNil(FFmpegProxySelection.filter(requestedFPS: 30, nominalFrameRate: 24))
        XCTAssertNil(FFmpegProxySelection.filter(requestedFPS: 24, nominalFrameRate: 24))
        let decimated = FFmpegProxySelection.filter(requestedFPS: 12, nominalFrameRate: 24)
        XCTAssertEqual(
            decimated,
            "select='isnan(prev_selected_t)+gt(floor((t-start_t)*12.000000+1e-6)\\,floor((prev_selected_t-start_t)*12.000000+1e-6))'"
        )
        XCTAssertNotNil(FFmpegProxySelection.filter(requestedFPS: 5, nominalFrameRate: 0))
        XCTAssertFalse(decimated?.contains("fps=") ?? true)
    }

    func testVFRWindowPreservesSourcePTSWithoutDuplication() async throws {
        let tools = try requireFFmpegTools()
        try await withTemporaryDirectory { root in
            let url = root.appendingPathComponent("vfr.mp4")
            // Same VFR construction as the regression fixture generator:
            // every third frame is delayed by one 24 fps tick.
            try run(tools.ffmpeg, [
                "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=s=64x36:r=24:d=1",
                "-vf", "setpts='PTS+if(gt(N,0),floor(N/3)/24/TB,0)',format=yuv420p,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709",
                "-fps_mode", "vfr", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-color_range", "tv", "-color_primaries", "bt709",
                "-color_trc", "bt709", "-colorspace", "bt709", url.path
            ])
            let expected = try packetSeconds(tools.ffprobe, url)
            XCTAssertGreaterThanOrEqual(expected.count, 16)

            let sequence = try await FrameReader.readWindow(
                url: url, pixelFormat: CalibrationPixelFormat.sdrNV12,
                startSeconds: 0, frameCount: 12, framesPerSecond: 30, proxyWidth: 32
            )
            let provenance = try XCTUnwrap(sequence.temporalProvenance)
            XCTAssertEqual(provenance.policy, FrameTemporalProvenance.ffmpegSourcePTSPolicy)
            XCTAssertEqual(sequence.samples.count, 12)
            XCTAssertEqual(provenance.sourceIsVariableFrameRate, true)
            XCTAssertEqual(provenance.duplicatedFrameCount, 0)
            XCTAssertEqual(sequence.samples.map(\.index), Array(0..<12))
            XCTAssertEqual(provenance.skippedSourceFramesBefore, Array(repeating: 0, count: 12))
            for (sample, seconds) in zip(sequence.samples, expected) {
                XCTAssertEqual(sample.timestamp.seconds, seconds, accuracy: 1e-3)
                XCTAssertEqual(sample.descriptor.timestampSeconds, sample.timestamp.seconds, accuracy: 1e-9)
            }
            let deltas = zip(sequence.samples.dropFirst(), sequence.samples).map {
                $0.timestamp.seconds - $1.timestamp.seconds
            }
            XCTAssertTrue(deltas.allSatisfy { $0 > 0 }, "timestamps must be strictly increasing")
            XCTAssertGreaterThan(deltas.max()! - deltas.min()!, 0.03, "VFR gaps were flattened")
        }
    }

    func testDecimatedCFRWindowKeepsRealTimestampsAndReportsDrops() async throws {
        let tools = try requireFFmpegTools()
        try await withTemporaryDirectory { root in
            let url = root.appendingPathComponent("cfr.mp4")
            try run(tools.ffmpeg, [
                "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                "-f", "lavfi", "-i", "testsrc2=s=64x36:r=24:d=1",
                "-vf", "format=yuv420p,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709",
                "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-color_range", "tv", "-color_primaries", "bt709",
                "-color_trc", "bt709", "-colorspace", "bt709", url.path
            ])
            let sequence = try await FrameReader.readWindow(
                url: url, pixelFormat: CalibrationPixelFormat.sdrNV12,
                startSeconds: 0.25, frameCount: 4, framesPerSecond: 12, proxyWidth: 32
            )
            let provenance = try XCTUnwrap(sequence.temporalProvenance)
            XCTAssertEqual(provenance.sourceIsVariableFrameRate, false)
            XCTAssertEqual(sequence.samples.map(\.index), [6, 8, 10, 12])
            XCTAssertEqual(provenance.skippedSourceFramesBefore, [0, 1, 1, 1])
            XCTAssertEqual(sequence.samples.map(\.sequencePosition), [0, 1, 2, 3])
            for (sample, index) in zip(sequence.samples, [6, 8, 10, 12]) {
                XCTAssertEqual(sample.timestamp.seconds, Double(index) / 24, accuracy: 1e-3)
            }
        }
    }

    // MARK: - Fixture helpers

    private struct Tools {
        let ffmpeg: String
        let ffprobe: String
    }

    private func requireFFmpegTools() throws -> Tools {
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        guard let directory = directories.first(where: {
            FileManager.default.isExecutableFile(atPath: $0 + "/ffmpeg") &&
                FileManager.default.isExecutableFile(atPath: $0 + "/ffprobe")
        }) else {
            throw XCTSkip("ffmpeg and ffprobe are required for synthetic proxy PTS integration")
        }
        return Tools(ffmpeg: directory + "/ffmpeg", ffprobe: directory + "/ffprobe")
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdr-proxy-pts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments.joined(separator: " "))")
        return data
    }

    private func packetSeconds(_ ffprobe: String, _ url: URL) throws -> [Double] {
        let data = try run(ffprobe, [
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "packet=pts_time", "-of", "csv=p=0", url.path
        ])
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .sorted()
    }
}
