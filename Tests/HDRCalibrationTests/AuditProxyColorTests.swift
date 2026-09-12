import CoreVideo
import CoreMedia
import Foundation
import HDRCore
import XCTest
@testable import HDRCalibration

final class AuditProxyColorTests: XCTestCase {
    func testProxyRejectsMissingColorMetadata() throws {
        XCTAssertThrowsError(try FFmpegProxyColorMetadata(
            formatDescription: nil, pixelFormat: CalibrationPixelFormat.sdrNV12))
        let description = try makeDescription(
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transfer: kCVImageBufferTransferFunction_sRGB,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            includeRange: false
        )
        XCTAssertThrowsError(try FFmpegProxyColorMetadata(
            formatDescription: description, pixelFormat: CalibrationPixelFormat.sdrNV12)) { error in
            XCTAssertTrue(String(describing: error).contains("explicit source color range"))
        }
    }

    func testProxyReferenceRejectsSDRTransferInsteadOfInventingHLG() throws {
        let description = try makeDescription(primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                             transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                                             matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        XCTAssertThrowsError(try FFmpegProxyColorMetadata(
            formatDescription: description, pixelFormat: CalibrationPixelFormat.hdrP010))
    }

    func testProxyPreservesIndependent601MatrixFor709Primaries() throws {
        let description = try makeDescription(primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                                             transfer: kCVImageBufferTransferFunction_sRGB,
                                             matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let color = try FFmpegProxyColorMetadata(formatDescription: description, pixelFormat: CalibrationPixelFormat.sdrNV12)
        XCTAssertTrue(color.scaleOptions.contains("in_color_matrix=bt601:out_color_matrix=bt601"))
        var created: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, CalibrationPixelFormat.sdrNV12, nil, &created), kCVReturnSuccess)
        let buffer = try XCTUnwrap(created)
        try color.apply(to: buffer)
        let metadata = try HDRInputMetadata.resolve(pixelBuffer: buffer, fallbackPolicy: .requireMetadata)
        XCTAssertEqual(metadata.yCbCrMatrix, .bt601)
        XCTAssertEqual(metadata.transferFunction, .sRGB)
    }

    func testOddProxyWidthFailsBeforeOpeningMedia() async {
        let nonexistent = URL(fileURLWithPath: "/does-not-exist/hdr-audit.mp4")
        do {
            _ = try await FrameReader.read(url: nonexistent, pixelFormat: CalibrationPixelFormat.sdrNV12, proxyWidth: 17)
            XCTFail("odd proxy width was accepted")
        } catch { XCTAssertTrue(String(describing: error).contains("invalid or unsafe bounds")) }
        do {
            _ = try await FrameReader.readWindow(url: nonexistent, pixelFormat: CalibrationPixelFormat.hdrP010,
                                                startSeconds: 0, proxyWidth: 17)
            XCTFail("odd window proxy width was accepted")
        } catch { XCTAssertTrue(String(describing: error).contains("invalid or unsafe bounds")) }
    }

    func testTemporalProxyPreservesSourceColorAndNormalizesRange() async throws {
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("ffmpeg is required for synthetic calibration proxy integration")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-proxy-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, String, String, String, OSType, CFString)] = [
            ("srgb", "bt709", "iec61966-2-1", "bt709", CalibrationPixelFormat.sdrNV12, kCVImageBufferTransferFunction_sRGB),
            ("pq", "bt2020", "smpte2084", "bt2020nc", CalibrationPixelFormat.hdrP010, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ),
            ("hlg", "bt2020", "arib-std-b67", "bt2020nc", CalibrationPixelFormat.hdrP010, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        ]
        for (name, primaries, transfer, matrix, pixelFormat, expectedTransfer) in cases {
            let url = root.appendingPathComponent(name + ".mp4")
            let isHDR = pixelFormat == CalibrationPixelFormat.hdrP010
            let sourceFormat = isHDR ? "yuv420p10le" : "yuv420p"
            let midpointCode = isHDR ? "512" : "128"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            // Constant full-range midpoint (128/255 or 512/1023), not an HDR
            // objective asset. HDR cases are encoded as genuine 10-bit
            // yuv420p10le/Main10 sources before the P010 proxy conversion.
            var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error",
                "-f", "lavfi", "-i", "nullsrc=s=32x32:r=24:d=0.25,format=\(sourceFormat),geq=lum=\(midpointCode):cb=\(midpointCode):cr=\(midpointCode),setparams=range=full:color_primaries=\(primaries):color_trc=\(transfer):colorspace=\(matrix)"]
            if isHDR {
                arguments += ["-c:v", "libx265", "-profile:v", "main10", "-pix_fmt", "yuv420p10le", "-x265-params", "log-level=error"]
            } else {
                arguments += ["-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p"]
            }
            arguments += ["-qp", "18", "-frames:v", "6", "-color_range", "pc",
                          "-color_primaries", primaries, "-color_trc", transfer, "-colorspace", matrix, url.path]
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let sourceMetadata = try await V4MetadataProbe.probe(url: url)
            XCTAssertEqual(sourceMetadata.colorPrimaries, primaries, "invalid synthetic fixture")
            XCTAssertEqual(sourceMetadata.transfer, transfer, "invalid synthetic fixture")
            XCTAssertEqual(sourceMetadata.colorRange, "pc", "invalid synthetic fixture")
            if isHDR {
                XCTAssertEqual(sourceMetadata.pixelFormat, "yuv420p10le", "fixture precision drifted")
            } else {
                XCTAssertTrue(sourceMetadata.pixelFormat == "yuv420p" || sourceMetadata.pixelFormat == "yuvj420p",
                              "fixture precision drifted: \(sourceMetadata.pixelFormat ?? "nil")")
            }
            XCTAssertEqual(sourceMetadata.bitDepth, isHDR ? 10 : 8, "fixture bit depth drifted")
            let sequence = try await FrameReader.readWindow(
                url: url, pixelFormat: pixelFormat, startSeconds: 0,
                frameCount: 2, framesPerSecond: 24, proxyWidth: 32)
            let buffer = try XCTUnwrap(sequence.samples.first?.pixelBuffer)
            let actual = try XCTUnwrap(CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil))
            XCTAssertEqual(actual as? String, expectedTransfer as String, "\(name) was relabelled as \(actual)")
            let signal = try OfflinePixelSampler.lumaGrid(pixelBuffer: buffer, width: 1, height: 1)[0]
            XCTAssertEqual(signal, 128 / 255, accuracy: 1.0 / 219, "\(name) full-range raw bytes were tagged video-range")
            if name == "srgb" {
                let metadata = try HDRInputMetadata.resolve(pixelBuffer: buffer, fallbackPolicy: .requireMetadata)
                XCTAssertEqual(metadata.transferFunction, .sRGB)
            }
        }
    }

    private func makeDescription(
        primaries: CFString,
        transfer: CFString,
        matrix: CFString,
        includeRange: Bool = true
    ) throws -> CMFormatDescription {
        var description: CMVideoFormatDescription?
        var extensions: [String: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries as String: primaries,
            kCMFormatDescriptionExtension_TransferFunction as String: transfer,
            kCMFormatDescriptionExtension_YCbCrMatrix as String: matrix
        ]
        if includeRange {
            extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] = NSNumber(value: false)
        }
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264,
            width: 32, height: 32, extensions: extensions as CFDictionary, formatDescriptionOut: &description), noErr)
        return try XCTUnwrap(description)
    }
}
