import CoreVideo
import Foundation
import XCTest
@testable import HDRCalibration

final class DecodeLaneTests: XCTestCase {
    func testOnlyVP9420SourcesMayUseTheSoftwareLane() {
        XCTAssertEqual(FFmpegDecodeLane.hardwareDownloadFormat(codecName: "vp9", pixelFormat: "yuv420p"), "nv12")
        XCTAssertEqual(FFmpegDecodeLane.hardwareDownloadFormat(codecName: "vp9", pixelFormat: "yuv420p10le"), "p010le")
        XCTAssertNil(FFmpegDecodeLane.hardwareDownloadFormat(codecName: "vp9", pixelFormat: "yuv444p"))
        XCTAssertNil(FFmpegDecodeLane.hardwareDownloadFormat(codecName: "h264", pixelFormat: "yuv420p"))
        XCTAssertNil(FFmpegDecodeLane.hardwareDownloadFormat(codecName: "prores", pixelFormat: "yuv422p10le"))
        XCTAssertNil(FFmpegDecodeLane.hardwareDownloadFormat(codecName: "av1", pixelFormat: "yuv420p10le"))
    }

    func testHardwareSlotsAreBoundedAndReleased() {
        let pool = FFmpegHardwareSlotPool(limit: 1)
        let first = FFmpegDecodeLane.acquire(sourceDownloadFormat: "p010le", pool: pool)
        XCTAssertEqual(first.mode, .hardware)
        XCTAssertEqual(first.inputArguments, ["-hwaccel", "videotoolbox"])
        XCTAssertNil(first.scalerInputFormat)

        let second = FFmpegDecodeLane.acquire(sourceDownloadFormat: "p010le", pool: pool)
        XCTAssertEqual(second.mode, .software)
        XCTAssertEqual(second.inputArguments, [])
        XCTAssertEqual(second.scalerInputFormat, "p010le")
        XCTAssertEqual(pool.activeCount, 1)

        second.release()
        XCTAssertEqual(pool.activeCount, 1, "a software lane holds no slot")
        first.release()
        XCTAssertEqual(pool.activeCount, 0)
        XCTAssertEqual(FFmpegDecodeLane.acquire(sourceDownloadFormat: "nv12", pool: pool).mode, .hardware)
    }

    func testIneligibleSourcesKeepHistoricalHardwareArgumentsWithoutASlot() {
        let pool = FFmpegHardwareSlotPool(limit: 0)
        let lane = FFmpegDecodeLane.acquire(sourceDownloadFormat: nil, pool: pool)
        XCTAssertEqual(lane.mode, .hardware)
        XCTAssertEqual(lane.inputArguments, ["-hwaccel", "videotoolbox"])
        XCTAssertNil(lane.scalerInputFormat)
        lane.release()
        XCTAssertEqual(pool.activeCount, 0)
    }

    func testTemporalAnchorOrderKeepsHistoricalFirstChoice() {
        func match(_ position: Int, _ confidence: Double) -> MatchedFrame {
            MatchedFrame(
                sdrIndex: position, hdrIndex: position,
                sdrSequencePosition: position, hdrSequencePosition: position,
                sdrTimeSeconds: Double(position), hdrTimeSeconds: Double(position),
                confidence: confidence
            )
        }
        let matches = [match(0, 0.90), match(1, 0.97), match(2, 0.95), match(3, 0.97), match(4, 0.91)]
        let ranked = V6TemporalAnchorOrder.ranked(matches)
        let historical = matches.max(by: { $0.confidence < $1.confidence })
        XCTAssertEqual(ranked.first, historical)
        XCTAssertEqual(ranked.map(\.sdrSequencePosition), [1, 3, 2, 4, 0])
        XCTAssertTrue(V6TemporalAnchorOrder.ranked([]).isEmpty)
    }

    /// VideoToolbox and software decoding must yield identical proxy pixels,
    /// timestamps and source indices for 8-bit SDR and 10-bit HLG VP9.
    func testSoftwareLaneIsPixelIdenticalToVideoToolbox() async throws {
        let tools = try requireFFmpegTools()
        guard FFmpegHardwareSlotPool.shared.limit >= 1 else {
            throw XCTSkip("HDR_HW_DECODE_SLOTS=0 disables the hardware lane")
        }
        try await withTemporaryDirectory { root in
            let cases: [(name: String, pixelFormat: OSType, ffmpegFormat: String, color: (String, String, String))] = [
                ("sdr.mp4", CalibrationPixelFormat.sdrNV12, "yuv420p", ("bt709", "bt709", "bt709")),
                ("hlg.mp4", CalibrationPixelFormat.hdrP010, "yuv420p10le", ("bt2020", "arib-std-b67", "bt2020nc"))
            ]
            for item in cases {
                let url = root.appendingPathComponent(item.name)
                guard (try? run(tools.ffmpeg, [
                    "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc2=s=256x144:r=30:d=1",
                    "-vf", "format=\(item.ffmpegFormat),setparams=range=tv:color_primaries=\(item.color.0):color_trc=\(item.color.1):colorspace=\(item.color.2)",
                    "-c:v", "libvpx-vp9", "-pix_fmt", item.ffmpegFormat, "-b:v", "0", "-crf", "30",
                    "-deadline", "realtime", "-cpu-used", "8",
                    "-color_range", "tv", "-color_primaries", item.color.0,
                    "-color_trc", item.color.1, "-colorspace", item.color.2,
                    url.path
                ])) != nil else {
                    throw XCTSkip("libvpx-vp9 \(item.ffmpegFormat) encoding unavailable")
                }
                // Hold the only hardware slot so this read takes the software lane.
                let held = FFmpegHardwareSlotPool.shared.tryAcquire()
                let software: FrameSequence
                do {
                    software = try await FrameReader.readWindow(
                        url: url, pixelFormat: item.pixelFormat,
                        startSeconds: 0.2, frameCount: 8, framesPerSecond: 30, proxyWidth: 64
                    )
                } catch {
                    if held { FFmpegHardwareSlotPool.shared.release() }
                    throw error
                }
                if held { FFmpegHardwareSlotPool.shared.release() }
                let hardware = try await FrameReader.readWindow(
                    url: url, pixelFormat: item.pixelFormat,
                    startSeconds: 0.2, frameCount: 8, framesPerSecond: 30, proxyWidth: 64
                )
                XCTAssertEqual(software.samples.count, 8, item.name)
                XCTAssertEqual(software.samples.count, hardware.samples.count, item.name)
                XCTAssertEqual(software.samples.map(\.index), hardware.samples.map(\.index), item.name)
                XCTAssertEqual(
                    software.samples.map(\.timestamp.seconds),
                    hardware.samples.map(\.timestamp.seconds), item.name
                )
                for (lhs, rhs) in zip(software.samples, hardware.samples) {
                    XCTAssertEqual(planeBytes(lhs.pixelBuffer), planeBytes(rhs.pixelBuffer), "\(item.name) frame \(lhs.index)")
                }
            }
        }
    }

    /// A reader that stops early must not wait forever for an ffmpeg blocked
    /// on a full stdout pipe.
    func testStoppingAnFFmpegBlockedOnAFullPipeReturns() throws {
        let tools = try requireFFmpegTools()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tools.ffmpeg)
        process.arguments = [
            "-hide_banner", "-nostdin", "-nostats", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=s=640x360:r=30:d=600", "-pix_fmt", "yuv420p", "-f", "rawvideo", "pipe:1"
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read one frame, then stop reading, as a reader that hits an error does.
        _ = try stdout.fileHandleForReading.read(upToCount: 640 * 360 * 3 / 2)
        Thread.sleep(forTimeInterval: 0.5)
        let started = Date()
        FFmpegFrameReader.stop(process, stdout: stdout)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: - Helpers

    private func planeBytes(_ buffer: CVPixelBuffer) -> [[UInt8]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return (0..<CVPixelBufferGetPlaneCount(buffer)).map { plane in
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return [] }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            // Luma is one sample per pixel and chroma one interleaved CbCr
            // pair; P010 stores every sample in 16 bits.
            let isP010 = CVPixelBufferGetPixelFormatType(buffer) == CalibrationPixelFormat.hdrP010
            let used = width * (plane == 0 ? 1 : 2) * (isP010 ? 2 : 1)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(used * height)
            for row in 0..<height {
                let pointer = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt8.self)
                bytes.append(contentsOf: UnsafeBufferPointer(start: pointer, count: used))
            }
            return bytes
        }
    }

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
            throw XCTSkip("ffmpeg and ffprobe are required for decode lane integration")
        }
        return Tools(ffmpeg: directory + "/ffmpeg", ffprobe: directory + "/ffprobe")
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdr-decode-lane-\(UUID().uuidString)")
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
        guard process.terminationStatus == 0 else {
            throw CalibrationError.decodeFailed("\(executable) failed")
        }
    }
}
