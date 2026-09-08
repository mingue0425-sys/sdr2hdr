import CoreVideo
import Foundation
import XCTest

@testable import HDRCore
@testable import HDRPlayerKit

@MainActor
final class RealMediaRegressionCorrectnessTests: XCTestCase {
    func testRegressionInputReaderUsesActualNV12Format() throws {
        let yCodes: [UInt8] = [16, 32, 64, 128, 235, 240, 8, 200]
        let pixelBuffer = try makeNV12(yCodes: yCodes)
        let actualFormat = try RealMediaRegressionRunner.actualInputFormat(for: pixelBuffer)

        XCTAssertEqual(actualFormat, .nv12VideoRange)
        let samples = try RegressionInputLuminanceReader.samples(
            from: pixelBuffer,
            inputFormat: actualFormat,
            region: nil
        )

        XCTAssertEqual(samples.count, yCodes.count)
        for (sample, code) in zip(samples, yCodes) {
            XCTAssertEqual(sample, Float(code) / 255.0, accuracy: 1e-7)
        }
    }

    func testRegressionInputReaderUsesActualP010Format() throws {
        let yCodes: [UInt16] = [64, 65, 512, 940, 128, 256, 768, 939]
        let pixelBuffer = try makeP010(yCodes: yCodes)
        let actualFormat = try RealMediaRegressionRunner.actualInputFormat(for: pixelBuffer)

        XCTAssertEqual(actualFormat, .p010VideoRange)
        let samples = try RegressionInputLuminanceReader.samples(
            from: pixelBuffer,
            inputFormat: actualFormat,
            region: nil
        )

        XCTAssertEqual(samples.count, yCodes.count)
        for (sample, code) in zip(samples, yCodes) {
            XCTAssertEqual(sample, Float(code) / 1023.0, accuracy: 1e-7)
        }
    }

    func testPrecisionMismatchDoesNotReinterpretNV12AsUInt16() throws {
        let yCodes: [UInt8] = [16, 32, 64, 128, 235, 240, 8, 200]
        let pixelBuffer = try makeNV12(yCodes: yCodes)
        let actualFormat = try RealMediaRegressionRunner.actualInputFormat(for: pixelBuffer)

        XCTAssertEqual(
            RealMediaRegressionRunner.precisionMismatchMessage(
                expectedDecodeBitDepth: 10,
                actualInputFormat: actualFormat
            ),
            "PRECISION_DOWNGRADE expected=10 actual=8"
        )

        let safeSamples = try RegressionInputLuminanceReader.samples(
            from: pixelBuffer,
            inputFormat: actualFormat,
            region: nil
        )
        XCTAssertEqual(safeSamples.count, yCodes.count)
        XCTAssertEqual(safeSamples[0], Float(yCodes[0]) / 255.0, accuracy: 1e-7)

        XCTAssertThrowsError(
            try RegressionInputLuminanceReader.samples(
                from: pixelBuffer,
                inputFormat: .p010VideoRange,
                region: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? RegressionInputLuminanceReader.ReaderError,
                .formatMismatch(
                    expected: "P010 10-bit video-range",
                    actual: "NV12 8-bit video-range"
                )
            )
        }
    }

    func testRequiredChromaMetadataRejectsFallbackCenter() {
        let failures = RegressionChromaMetadataGate.failures(
            required: true,
            metadataWasExplicit: false,
            resolvedSiting: .center,
            allowed: [.center]
        )

        XCTAssertEqual(failures, ["explicit chroma metadata required"])
    }

    func testRequiredChromaMetadataAcceptsExplicitLeft() {
        let failures = RegressionChromaMetadataGate.failures(
            required: true,
            metadataWasExplicit: true,
            resolvedSiting: .left,
            allowed: [.left]
        )

        XCTAssertTrue(failures.isEmpty)
    }

    func testMandatoryRegressionRejectsUnsupportedMarker() throws {
        let manifestURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/RealMediaRegression/manifest.json")
        let fixture = try XCTUnwrap(
            RealMediaRegressionManifest.load(from: manifestURL).fixtures.first
        )
        let result = RealMediaRegressionFixtureResult(
            manifest: fixture,
            id: fixture.id,
            status: "skipped",
            skipReason: "UNSUPPORTED_GENERATOR_CAPABILITY: encoder unavailable",
            nearest: nil,
            candidate: nil,
            comparison: nil
        )

        let failures = MandatoryRegressionMatrixGate.failures(for: [result])
        XCTAssertTrue(failures.contains { $0.contains("mandatory fixtures skipped") })
    }

    private func makeNV12(yCodes: [UInt8]) throws -> CVPixelBuffer {
        let width = 4
        let height = 2
        guard yCodes.count == width * height else {
            throw NSError(domain: "RealMediaRegressionCorrectnessTests", code: 1)
        }
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: width,
            height: height
        )
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw NSError(domain: "RealMediaRegressionCorrectnessTests", code: Int(lockStatus))
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes)
            for x in 0..<width {
                row[x] = yCodes[y * width + x]
            }
        }

        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        for y in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) {
            let row = uvBase.advanced(by: y * uvRowBytes)
            for x in 0..<CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) {
                row[x * 2] = 128
                row[x * 2 + 1] = 128
            }
        }
        return pixelBuffer
    }

    private func makeP010(yCodes: [UInt16]) throws -> CVPixelBuffer {
        let width = 4
        let height = 2
        guard yCodes.count == width * height else {
            throw NSError(domain: "RealMediaRegressionCorrectnessTests", code: 2)
        }
        let pixelBuffer = try makePixelBuffer(
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            width: width,
            height: height
        )
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw NSError(domain: "RealMediaRegressionCorrectnessTests", code: Int(lockStatus))
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
            .assumingMemoryBound(to: UInt16.self)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes / MemoryLayout<UInt16>.stride)
            for x in 0..<width {
                row[x] = yCodes[y * width + x] << 6
            }
        }

        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
            .assumingMemoryBound(to: UInt16.self)
        for y in 0..<CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) {
            let row = uvBase.advanced(by: y * uvRowBytes / MemoryLayout<UInt16>.stride)
            for x in 0..<CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) {
                row[x * 2] = 512 << 6
                row[x * 2 + 1] = 512 << 6
            }
        }
        return pixelBuffer
    }

    private func makePixelBuffer(format: OSType, width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "RealMediaRegressionCorrectnessTests", code: Int(status))
        }
        return pixelBuffer
    }
}
