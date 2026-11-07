import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import XCTest
@testable import HDRCalibration

final class ProxyFrameCacheTests: XCTestCase {
    /// A replay must equal a fresh decode exactly, on the FFmpeg lane (VP9 SDR
    /// and HLG) and on the AVAssetReader lane (H.264), for full reads and
    /// windows.
    func testReplayIsIdenticalToAFreshDecode() async throws {
        let ffmpeg = try requireFFmpeg()
        try await withTemporaryDirectory { root in
            let cache = try ProxyFrameCache(directory: root.appendingPathComponent("cache"))
            let cases: [(name: String, codec: [String], pixelFormat: OSType, ffmpegFormat: String, color: (String, String, String))] = [
                ("sdr.mp4", ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "30", "-deadline", "realtime", "-cpu-used", "8"],
                 CalibrationPixelFormat.sdrNV12, "yuv420p", ("bt709", "bt709", "bt709")),
                ("hlg.mp4", ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "30", "-deadline", "realtime", "-cpu-used", "8"],
                 CalibrationPixelFormat.hdrP010, "yuv420p10le", ("bt2020", "arib-std-b67", "bt2020nc")),
                ("avc.mov", ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "20"],
                 CalibrationPixelFormat.sdrNV12, "yuv420p", ("bt709", "bt709", "bt709"))
            ]
            var expectedStores = 0
            for item in cases {
                let url = root.appendingPathComponent(item.name)
                guard (try? run(ffmpeg, [
                    "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc2=s=256x144:r=30:d=2",
                    "-vf", "format=\(item.ffmpegFormat),setparams=range=tv:color_primaries=\(item.color.0):color_trc=\(item.color.1):colorspace=\(item.color.2)",
                ] + item.codec + [
                    "-pix_fmt", item.ffmpegFormat,
                    "-color_range", "tv", "-color_primaries", item.color.0,
                    "-color_trc", item.color.1, "-colorspace", item.color.2,
                    url.path
                ])) != nil else {
                    throw XCTSkip("\(item.name) fixture encoding unavailable")
                }
                let reads: [(String, (ProxyFrameCache?) async throws -> FrameSequence)] = [
                    ("read", { try await FrameReader.read(url: url, pixelFormat: item.pixelFormat, maxFrames: 12, proxyWidth: 64, cache: $0) }),
                    ("window", { try await FrameReader.readWindow(
                        url: url, pixelFormat: item.pixelFormat, startSeconds: 0.4, frameCount: 8,
                        framesPerSecond: 30, proxyWidth: 64, cache: $0
                    ) })
                ]
                for (kind, read) in reads {
                    let fresh = try await read(nil)
                    let stored = try await read(cache)
                    let replayed = try await read(cache)
                    expectedStores += 1
                    XCTAssertEqual(cache.statistics.stores, expectedStores, "\(item.name) \(kind) was not cacheable")
                    XCTAssertEqual(cache.statistics.hits, expectedStores, "\(item.name) \(kind) was not replayed")
                    assertIdentical(fresh, stored, "\(item.name) \(kind) stored")
                    assertIdentical(fresh, replayed, "\(item.name) \(kind) replayed")
                }
            }
        }
    }

    func testChangedSourceOrDamagedEntryDecodesAgain() async throws {
        let ffmpeg = try requireFFmpeg()
        try await withTemporaryDirectory { root in
            let cache = try ProxyFrameCache(directory: root.appendingPathComponent("cache"))
            let url = root.appendingPathComponent("sdr.mp4")
            func encode(_ pattern: String) throws {
                try run(ffmpeg, [
                    "-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "\(pattern)=s=128x72:r=30:d=1",
                    "-vf", "format=yuv420p,setparams=range=tv:color_primaries=bt709:color_trc=bt709:colorspace=bt709",
                    "-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "30", "-deadline", "realtime", "-cpu-used", "8",
                    "-pix_fmt", "yuv420p", "-color_range", "tv", "-color_primaries", "bt709",
                    "-color_trc", "bt709", "-colorspace", "bt709", url.path
                ])
            }
            guard (try? encode("testsrc2")) != nil else { throw XCTSkip("libvpx-vp9 encoding unavailable") }
            func read() async throws -> FrameSequence {
                try await FrameReader.readWindow(
                    url: url, pixelFormat: CalibrationPixelFormat.sdrNV12, startSeconds: 0, frameCount: 4,
                    framesPerSecond: 30, proxyWidth: 64, cache: cache
                )
            }
            let first = try await read()
            XCTAssertEqual(cache.statistics.misses, 1)

            // Damage every entry: the next read is a miss and still correct.
            for file in try FileManager.default.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) {
                var data = try Data(contentsOf: file)
                data.removeLast(17)
                try data.write(to: file)
            }
            assertIdentical(first, try await read(), "after damage")
            XCTAssertEqual(cache.statistics.misses, 2)
            XCTAssertEqual(cache.statistics.hits, 0)
            _ = try await read()
            XCTAssertEqual(cache.statistics.hits, 1)

            // New bytes at the same path: a miss with the new pixels.
            try encode("smptebars")
            let changed = try await read()
            XCTAssertEqual(cache.statistics.misses, 3)
            XCTAssertNotEqual(planeBytes(first.samples[0].pixelBuffer), planeBytes(changed.samples[0].pixelBuffer))
        }
    }

    func testOnlyNonFrozenScopesUseTheCache() async throws {
        try await withTemporaryDirectory { root in
            let cache = try ProxyFrameCache(directory: root)
            XCTAssertNil(ProxyFrameCache.current, "readers outside a scope are uncached")
            for split in DatasetSplit.allCases {
                let active = await ProxyFrameCache.scope(for: split, cache: cache) { ProxyFrameCache.current }
                XCTAssertEqual(active === cache, split != .frozen, "\(split)")
            }
            let disabled = await ProxyFrameCache.scope(for: .tune, cache: nil) { ProxyFrameCache.current }
            XCTAssertNil(disabled)
            // A Frozen pair inside an active scope is still uncached.
            let nested = await ProxyFrameCache.scope(for: .tune, cache: cache) {
                await ProxyFrameCache.$current.withValue(nil) {
                    await ProxyFrameCache.scope(for: .frozen, cache: cache) { ProxyFrameCache.current }
                }
            }
            XCTAssertNil(nested)
        }
    }

    /// Editing the decoder must change the cache key: update
    /// `ProxyFrameCache.decoderSourceDigest` to the value printed here.
    func testDecoderSourceDigestPinsTheReaderSources() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/HDRCalibration")
        var material = Data()
        for name in ProxyFrameCache.decoderSources {
            material.append(Data(name.utf8))
            material.append(0)
            var bytes = try Data(contentsOf: sources.appendingPathComponent(name))
            if name == "ProxyFrameCache.swift" {
                // The constant cannot hash itself.
                let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n")
                bytes = Data(lines.filter { !$0.contains("static let decoderSourceDigest = ") }.joined(separator: "\n").utf8)
            }
            material.append(bytes)
            material.append(0)
        }
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ProxyFrameCache.decoderSourceDigest, digest,
                       "reader sources changed: set ProxyFrameCache.decoderSourceDigest to \(digest)")
    }

    // MARK: - Helpers

    private func assertIdentical(_ lhs: FrameSequence, _ rhs: FrameSequence, _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.url, rhs.url, label, file: file, line: line)
        XCTAssertEqual(lhs.pixelFormat, rhs.pixelFormat, label, file: file, line: line)
        XCTAssertEqual(lhs.width, rhs.width, label, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, label, file: file, line: line)
        XCTAssertEqual(lhs.nominalFrameRate.bitPattern, rhs.nominalFrameRate.bitPattern, label, file: file, line: line)
        XCTAssertEqual(lhs.durationSeconds.bitPattern, rhs.durationSeconds.bitPattern, label, file: file, line: line)
        XCTAssertEqual(lhs.temporalProvenance, rhs.temporalProvenance, label, file: file, line: line)
        XCTAssertEqual(lhs.samples.count, rhs.samples.count, label, file: file, line: line)
        XCTAssertFalse(lhs.samples.isEmpty, label, file: file, line: line)
        for (a, b) in zip(lhs.samples, rhs.samples) {
            let at = "\(label) frame \(a.sequencePosition)"
            XCTAssertEqual(a.index, b.index, at, file: file, line: line)
            XCTAssertEqual(a.sequencePosition, b.sequencePosition, at, file: file, line: line)
            XCTAssertEqual(a.timestamp.value, b.timestamp.value, at, file: file, line: line)
            XCTAssertEqual(a.timestamp.timescale, b.timestamp.timescale, at, file: file, line: line)
            XCTAssertEqual(a.timestamp.flags, b.timestamp.flags, at, file: file, line: line)
            XCTAssertEqual(a.timestamp.epoch, b.timestamp.epoch, at, file: file, line: line)
            XCTAssertEqual(a.lumaGrid.map(\.bitPattern), b.lumaGrid.map(\.bitPattern), at, file: file, line: line)
            XCTAssertEqual(a.descriptor, b.descriptor, at, file: file, line: line)
            XCTAssertEqual(CVPixelBufferGetWidth(a.pixelBuffer), CVPixelBufferGetWidth(b.pixelBuffer), at, file: file, line: line)
            XCTAssertEqual(CVPixelBufferGetHeight(a.pixelBuffer), CVPixelBufferGetHeight(b.pixelBuffer), at, file: file, line: line)
            XCTAssertEqual(planeBytes(a.pixelBuffer), planeBytes(b.pixelBuffer), at, file: file, line: line)
            for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
                let left = (CVBufferCopyAttachments(a.pixelBuffer, mode) as NSDictionary?) ?? [:]
                let right = (CVBufferCopyAttachments(b.pixelBuffer, mode) as NSDictionary?) ?? [:]
                XCTAssertEqual(left, right, "\(at) attachments", file: file, line: line)
            }
        }
    }

    private func planeBytes(_ buffer: CVPixelBuffer) -> [[UInt8]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let isP010 = CVPixelBufferGetPixelFormatType(buffer) == CalibrationPixelFormat.hdrP010
        return (0..<CVPixelBufferGetPlaneCount(buffer)).map { plane in
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return [] }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let used = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2) * (isP010 ? 2 : 1)
            var bytes: [UInt8] = []
            for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) {
                bytes.append(contentsOf: UnsafeBufferPointer(
                    start: base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self), count: used
                ))
            }
            return bytes
        }
    }

    private func requireFFmpeg() throws -> String {
        guard let directory = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0 + "/ffmpeg") &&
                FileManager.default.isExecutableFile(atPath: $0 + "/ffprobe")
        }) else {
            throw XCTSkip("ffmpeg and ffprobe are required for proxy cache integration")
        }
        return directory + "/ffmpeg"
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-proxy-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CalibrationError.decodeFailed("\(executable) failed") }
    }
}
