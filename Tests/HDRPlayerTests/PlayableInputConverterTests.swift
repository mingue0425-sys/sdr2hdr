import AVFoundation
import Foundation
import XCTest
@testable import HDRPlayerKit

final class PlayableInputConverterTests: XCTestCase {
    func testVP9IsConvertedOnceKeepingTagsAndHEVCIsLeftAlone() async throws {
        try await withConverter { converter, root in
            let sdr = root.appendingPathComponent("sdr.webm")
            try encode(converter, sdr, codec: ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8"],
                       format: "yuv420p", color: ("bt709", "bt709", "bt709"))
            let fractions = FractionLog()
            let first = try await converter.prepare(sdr) { fractions.append($0) }
            guard case .converted(let output) = first else { return XCTFail("expected a conversion, got \(first)") }
            XCTAssertEqual(fractions.values.last, 1)
            XCTAssertEqual(try probe(converter, output), "hevc,yuv420p,tv,bt709,bt709,bt709")
            let isDecodable = try await PlayableInputConverter.isDecodable(output)
            XCTAssertEqual(isDecodable, true)
            let second = try await converter.prepare(sdr)
            XCTAssertEqual(second, .reused(output))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: converter.cacheDirectory.path), [output.lastPathComponent],
                           "no partial files are left behind")
            let decodable = try await converter.prepare(output)
            XCTAssertEqual(decodable, .decodable)

            // New bytes at the same path get a new conversion.
            try encode(converter, sdr, codec: ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8"],
                       format: "yuv420p", color: ("bt709", "bt709", "bt709"), pattern: "smptebars")
            let third = try await converter.prepare(sdr)
            guard case .converted(let changed) = third else { return XCTFail("expected a new conversion, got \(third)") }
            XCTAssertNotEqual(changed, output)
        }
    }

    func testTenBitHLGStaysTenBitHLG() async throws {
        try await withConverter { converter, root in
            let hlg = root.appendingPathComponent("hlg.webm")
            try encode(converter, hlg, codec: ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8"],
                       format: "yuv420p10le", color: ("bt2020", "arib-std-b67", "bt2020nc"))
            let outcome = try await converter.prepare(hlg)
            let output = try XCTUnwrap(outcome.url)
            XCTAssertEqual(try probe(converter, output), "hevc,yuv420p10le,tv,bt2020nc,arib-std-b67,bt2020")
        }
    }

    func testDefaultCacheDirectorySitsBesideTheBuildProducts() {
        let executable = URL(fileURLWithPath: "/repo/.build/release/HDRPlayer")
        XCTAssertEqual(PlayableInputConverter.defaultCacheDirectory(executable: executable).path, "/repo/.build/converted")
    }

    func testAppBundlesNeverConvertIntoTheirOwnBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("HDRPlayer.app/Contents/MacOS/HDRPlayer")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(PlayableInputConverter.defaultCacheDirectory(executable: executable).lastPathComponent, "HDRPlayer-converted")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".build"), withIntermediateDirectories: true)
        let inCheckout = PlayableInputConverter.defaultCacheDirectory(executable: executable)
        XCTAssertEqual(inCheckout.deletingLastPathComponent().lastPathComponent, ".build")
        XCTAssertEqual(inCheckout.lastPathComponent, "converted")
    }

    func testConversionOptionsParse() throws {
        let defaults = try PlayerOptions.parse(arguments: ["HDRPlayer", "/tmp/a.webm"])
        XCTAssertTrue(defaults.convertUndecodable)
        XCTAssertNil(defaults.convertDirectory)
        let off = try PlayerOptions.parse(arguments: ["HDRPlayer", "/tmp/a.webm", "--no-convert"])
        XCTAssertFalse(off.convertUndecodable)
        let directory = try PlayerOptions.parse(arguments: ["HDRPlayer", "/tmp/a.webm", "--convert-dir", "/tmp/conv"])
        XCTAssertEqual(directory.convertDirectory?.path, "/tmp/conv")
        XCTAssertTrue(PlayerOptions.usage.contains("--convert-dir"))
    }

    // MARK: - Helpers

    private func withConverter(_ body: (PlayableInputConverter, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let converter = PlayableInputConverter(cacheDirectory: root.appendingPathComponent("converted")) else {
            throw XCTSkip("ffmpeg and ffprobe are required")
        }
        try await body(converter, root)
    }

    private func encode(
        _ converter: PlayableInputConverter, _ url: URL, codec: [String], format: String,
        color: (String, String, String), pattern: String = "testsrc2"
    ) throws {
        let status = run(converter.ffmpeg, [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "\(pattern)=s=128x72:r=30:d=0.5",
            "-f", "lavfi", "-i", "sine=d=0.5",
            "-vf", "format=\(format),setparams=range=tv:color_primaries=\(color.0):color_trc=\(color.1):colorspace=\(color.2)",
        ] + codec + [
            "-pix_fmt", format, "-color_range", "tv", "-color_primaries", color.0,
            "-color_trc", color.1, "-colorspace", color.2, "-c:a", "libopus", "-shortest", url.path
        ]).status
        guard status == 0 else { throw XCTSkip("fixture encoding unavailable") }
    }

    private func probe(_ converter: PlayableInputConverter, _ url: URL) throws -> String {
        let result = run(converter.ffprobe, [
            "-v", "error", "-select_streams", "v:0", "-show_entries",
            "stream=codec_name,pix_fmt,color_range,color_space,color_transfer,color_primaries", "-of", "csv=p=0", url.path
        ])
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}

private final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func append(_ value: Double) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}
