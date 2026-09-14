import CoreVideo
import CoreMedia
import Foundation
import Metal
import XCTest
@testable import HDRCore

final class P010Tests: XCTestCase {
    func testP010VideoRangeNormalizationMatchesExpectedCodeValues() throws {
        let pixelBuffer = try makeP010(
            width: 4,
            height: 2,
            yCodes: [64, 65, 512, 940, 64, 65, 512, 940],
            cbCode: 512,
            crCode: 512,
            fullRange: false
        )
        let resolved = try HDRColorMetadataResolver.resolve(
            pixelBuffer: pixelBuffer,
            fallbackPolicy: .requireMetadata
        )

        XCTAssertEqual(resolved.pixelFormat, .p010VideoRange)
        XCTAssertEqual(resolved.metadata.isFullRange, false)
        XCTAssertEqual(resolved.yOffset, 64 / 1023, accuracy: 1e-6)
        XCTAssertEqual(resolved.yScale, 1023 / 876, accuracy: 1e-6)
        XCTAssertEqual(resolved.chromaOffset, 512 / 1023, accuracy: 1e-6)
        XCTAssertEqual(resolved.chromaScale, 1023 / 896, accuracy: 1e-6)

        let expected = [0, 1, 448, 876].map { Float($0) / 876 }
        let actual = [64, 65, 512, 940].map { (Float($0) - 64) / 876 }
        XCTAssertEqual(actual, expected)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let yRow = try XCTUnwrap(
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt16.self)
        )
        XCTAssertEqual(yRow[0] >> 6, 64)
        XCTAssertEqual(yRow[1] >> 6, 65)
        XCTAssertEqual(yRow[2] >> 6, 512)
        XCTAssertEqual(yRow[3] >> 6, 940)
    }

    func testP010FullRangeNormalization() throws {
        let pixelBuffer = try makeP010(
            width: 2,
            height: 2,
            yCodes: [0, 1023, 0, 1023],
            cbCode: 0,
            crCode: 1023,
            fullRange: true
        )
        let resolved = try HDRColorMetadataResolver.resolve(
            pixelBuffer: pixelBuffer,
            fallbackPolicy: .requireMetadata
        )

        XCTAssertEqual(resolved.pixelFormat, .p010FullRange)
        XCTAssertTrue(resolved.metadata.isFullRange)
        XCTAssertEqual(resolved.yOffset, 0)
        XCTAssertEqual(resolved.yScale, 1)
        XCTAssertEqual(resolved.chromaOffset, 512 / 1023, accuracy: 1e-6)
        XCTAssertEqual(resolved.chromaScale, 1)
    }

    func testP010MetalTexturesUse16BitPlaneFormats() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let pixelBuffer = try makeP010(
            width: 8,
            height: 4,
            yCodes: Array(repeating: 512, count: 32),
            cbCode: 512,
            crCode: 512,
            fullRange: false
        )
        let cache = try TextureCache(device: device)
        let textures = try cache.makeTextures(for: pixelBuffer)

        XCTAssertEqual(textures.pixelFormat, .p010VideoRange)
        XCTAssertEqual(textures.y?.pixelFormat, .r16Unorm)
        XCTAssertEqual(textures.uv?.pixelFormat, .rg16Unorm)
        XCTAssertEqual(textures.y?.width, 8)
        XCTAssertEqual(textures.y?.height, 4)
        XCTAssertEqual(textures.uv?.width, 4)
        XCTAssertEqual(textures.uv?.height, 2)
        XCTAssertEqual(textures.retainedMetalTextures.count, 2)
        XCTAssertNotNil(textures.retainedYTexture)
        XCTAssertNotNil(textures.retainedUVTexture)
        XCTAssertNil(textures.retainedBGRATexture)
    }

    func testP010ProcessesThroughCalibratedV4MetalPath() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let processor = try HDRProcessor(device: device, configuration: .calibratedV4)
        processor.temporalTraceEnabled = true
        let pixelBuffer = try makeP010(
            width: 8,
            height: 4,
            yCodes: Array(repeating: 512, count: 32),
            cbCode: 512,
            crCode: 512,
            fullRange: false
        )
        let commandBuffer = try processor.makeCommandBuffer()
        let frame = try processor.process(
            pixelBuffer: pixelBuffer,
            timestamp: CMTime(value: 0, timescale: 24),
            commandBuffer: commandBuffer,
            diagnosticFrameIndex: 1
        )
        XCTAssertEqual(frame.texture.pixelFormat, MTLPixelFormat.rgba16Float)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)
        let pixels = try readRGBA16FloatPixels(from: frame.texture, device: device)
        XCTAssertTrue(pixels.allSatisfy { Float($0).isFinite && Float($0) >= 0 })
        XCTAssertGreaterThan(pixels.filter { Float($0) > 0.0001 }.count, 0)
        XCTAssertEqual(processor.lastGPUCompletedSequence, 1)
        XCTAssertEqual(processor.lastAdaptiveCommittedSequence, 1)
        XCTAssertEqual(processor.temporalCompletionTrace.count, 1)
    }

    func testP010AndNV12MatchForExactlyRepresentableSignals() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let y8: [UInt8] = [16, 64, 128, 235, 16, 64, 128, 235]
        let y10 = y8.map { UInt16($0) * 4 }
        let nv12 = try makeNV12(width: 4, height: 2, yCodes: y8, cbCode: 128, crCode: 128)
        let p010 = try makeP010(width: 4, height: 2, yCodes: y10, cbCode: 512, crCode: 512, fullRange: false)

        let nv12Output = try process(pixelBuffer: nv12, device: device)
        let p010Output = try process(pixelBuffer: p010, device: device)
        let maximumDifference = zip(nv12Output, p010Output)
            .map { abs(Float($0.0) - Float($0.1)) }
            .max() ?? 0
        XCTAssertLessThanOrEqual(maximumDifference, 0.002)
    }

    func testProductionNV12P010PolicyMatrixUsesIndependentCPUOracle() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let nv12Codes: [UInt8] = [16, 17, 33, 34, 128, 200, 234, 235]
        let p010Codes: [UInt16] = [64, 65, 135, 136, 512, 800, 936, 940]
        let nv12 = try makeNV12(
            width: nv12Codes.count,
            height: 2,
            yCodes: nv12Codes + nv12Codes,
            cbCode: 128,
            crCode: 128
        )
        let p010 = try makeP010(
            width: p010Codes.count,
            height: 2,
            yCodes: p010Codes + p010Codes,
            cbCode: 512,
            crCode: 512,
            fullRange: false
        )

        let nonZeroBlack = BT1886TransferParameters(
            blackLuminance: 0.01,
            whiteLuminance: 1,
            gamma: 2.4
        )
        let cases: [(String, SDRInputInterpretationPolicy, BT1886TransferParameters)] = [
            ("BT709", .bt709SourceLinear, .idealReference),
            ("BT1886 ideal black", .bt1886ReferenceDisplay, .idealReference),
            ("BT1886 non-zero black", .bt1886ReferenceDisplay, nonZeroBlack)
        ]

        for (label, policy, parameters) in cases {
            var configuration = HDRConfiguration(
                paperWhiteNits: 100,
                peakNits: 101,
                highlightStrength: 0,
                contrastStrength: 0,
                saturationCompensation: 0,
                shadowProtection: 0,
                temporalStability: 0,
                outputMode: .edr,
                displayHeadroom: 1,
                toneCurveRevision: .legacyV2,
                inputFallbackPolicy: .requireMetadata,
                sdrInterpretationPolicy: policy,
                bt1886Parameters: parameters
            )
            configuration.untaggedSDRFallback = .reject

            let nv12Output = try process(
                pixelBuffer: nv12,
                device: device,
                configuration: configuration
            )
            let p010Output = try process(
                pixelBuffer: p010,
                device: device,
                configuration: configuration
            )

            for index in nv12Codes.indices {
                let nvSignal = (Float(nv12Codes[index]) - 16) / 219
                let p010Signal = (Float(p010Codes[index]) - 64) / 876
                let nvExpected = independentNeutralBT2020(
                    signal: nvSignal,
                    policy: policy,
                    parameters: parameters
                )
                let p010Expected = independentNeutralBT2020(
                    signal: p010Signal,
                    policy: policy,
                    parameters: parameters
                )
                let nvOffset = index * 4
                let p010Offset = index * 4
                for channel in 0..<3 {
                    XCTAssertEqual(
                        Float(nv12Output[nvOffset + channel]),
                        nvExpected[channel],
                        accuracy: 0.003,
                        "\(label) NV12 code \(nv12Codes[index]) channel \(channel)"
                    )
                    XCTAssertEqual(
                        Float(p010Output[p010Offset + channel]),
                        p010Expected[channel],
                        accuracy: 0.003,
                        "\(label) P010 code \(p010Codes[index]) channel \(channel)"
                    )
                }
            }
        }
    }

    func testP010PreservesMoreNearBlackLevelsThanNV12() throws {
        let tenBitCodes: [UInt16] = [64, 65, 66, 67, 68, 72, 80, 96]
        let eightBitCodes = tenBitCodes.map { UInt8($0 / 4) }
        let p010Signals = Set(tenBitCodes.map { Float($0 - 64) / 876 })
        let nv12Signals = Set(eightBitCodes.map { Float(Int($0) - 16) / 219 })

        XCTAssertGreaterThan(p010Signals.count, nv12Signals.count)
        XCTAssertEqual(p010Signals.count, tenBitCodes.count)
        XCTAssertLessThan(nv12Signals.count, eightBitCodes.count)
    }

    func testP010TemporalEstimatorUses10BitDecodedSamples() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let processor = try HDRProcessor(device: device, configuration: .calibratedV4)
        processor.debugInstrumentationEnabled = true
        processor.temporalTraceEnabled = true
        let pixelBuffer = try makeP010(
            width: 16,
            height: 9,
            yCodes: Array(repeating: 512, count: 144),
            cbCode: 512,
            crCode: 512,
            fullRange: false
        )
        let commandBuffer = try processor.makeCommandBuffer()
        _ = try processor.process(
            pixelBuffer: pixelBuffer,
            timestamp: CMTime(value: 0, timescale: 24),
            commandBuffer: commandBuffer,
            diagnosticFrameIndex: 1
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let expectedSignal = (Float(512) - 64) / 876
        let expectedLuminance = HDRColorMath.inverseBT709(expectedSignal)
        let diagnostic = try XCTUnwrap(processor.lastFrameDiagnostic)
        XCTAssertEqual(diagnostic.inputBitDepth, 10)
        XCTAssertEqual(diagnostic.inputPixelFormat, "P010 10-bit video-range")
        XCTAssertEqual(diagnostic.inputChromaLocation, "unspecified(default=center)")
        XCTAssertEqual(diagnostic.resolvedChromaSiting, "center")
        XCTAssertEqual(diagnostic.chromaReconstructionMode, "nearest")
        XCTAssertEqual(diagnostic.input.average, expectedLuminance, accuracy: 0.01)
        XCTAssertEqual(processor.temporalSubmissionTrace.count, 1)
        XCTAssertEqual(processor.temporalCompletionTrace.count, 1)
        XCTAssertEqual(processor.lastAdaptiveCommittedSequence, 1)
    }

    func testUnsupportedTenBitFormatFailsExplicitly() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            4,
            4,
            kCVPixelFormatType_422YpCbCr8,
            [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw XCTSkip("test pixel format is unavailable")
        }

        let cache = try TextureCache(device: device)
        XCTAssertThrowsError(try cache.makeTextures(for: pixelBuffer)) { error in
            guard case HDRProcessorError.unsupportedPixelFormat = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func process(pixelBuffer: CVPixelBuffer, device: MTLDevice) throws -> [Float16] {
        try process(
            pixelBuffer: pixelBuffer,
            device: device,
            configuration: .calibratedV4
        )
    }

    private func process(
        pixelBuffer: CVPixelBuffer,
        device: MTLDevice,
        configuration: HDRConfiguration
    ) throws -> [Float16] {
        let processor = try HDRProcessor(device: device, configuration: configuration)
        let commandBuffer = try processor.makeCommandBuffer()
        let frame = try processor.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)
        return try readRGBA16FloatPixels(from: frame.texture, device: device)
    }

    /// Independent neutral-pixel oracle. This intentionally duplicates the
    /// mathematical constants in test code instead of calling HDRColorMath or
    /// HDRReference, so production transfer helpers cannot define their own
    /// expected result.
    private func independentNeutralBT2020(
        signal: Float,
        policy: SDRInputInterpretationPolicy,
        parameters: BT1886TransferParameters
    ) -> [Float] {
        let encoded = min(max(signal, 0), 1)
        let linear: Float
        switch policy {
        case .bt709SourceLinear:
            linear = encoded < 0.081
                ? encoded / 4.5
                : pow((encoded + 0.099) / 1.099, 1 / 0.45)
        case .bt1886ReferenceDisplay:
            let blackRoot = pow(parameters.blackLuminance, 1 / parameters.gamma)
            let whiteRoot = pow(parameters.whiteLuminance, 1 / parameters.gamma)
            let span = whiteRoot - blackRoot
            let a = pow(span, parameters.gamma)
            let b = blackRoot / span
            linear = a * pow(max(encoded + b, 0), parameters.gamma)
        default:
            fatalError("test oracle only covers the two preregistered policies")
        }

        // Column-major BT.709 -> BT.2020 matrix, written out independently.
        return [
            0.6274040 * linear + 0.3292820 * linear + 0.0433136 * linear,
            0.0690970 * linear + 0.9195400 * linear + 0.0113623 * linear,
            0.0163916 * linear + 0.0880132 * linear + 0.8955950 * linear
        ].map { min(max($0, 0), 1) }
    }

    private func makeP010(
        width: Int,
        height: Int,
        yCodes: [UInt16],
        cbCode: UInt16,
        crCode: UInt16,
        fullRange: Bool
    ) throws -> CVPixelBuffer {
        guard yCodes.count == width * height else {
            throw NSError(domain: "P010Tests", code: 1)
        }
        let format = fullRange
            ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
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
            throw NSError(domain: "P010Tests", code: Int(status))
        }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
            .assumingMemoryBound(to: UInt16.self)
        for row in 0..<height {
            for column in 0..<width {
                yBase[(row * yRowBytes / MemoryLayout<UInt16>.stride) + column] = yCodes[row * width + column] << 6
            }
        }
        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
            .assumingMemoryBound(to: UInt16.self)
        for row in 0..<uvHeight {
            for column in 0..<uvWidth {
                let offset = row * uvRowBytes / MemoryLayout<UInt16>.stride + column * 2
                uvBase[offset] = cbCode << 6
                uvBase[offset + 1] = crCode << 6
            }
        }
        return pixelBuffer
    }

    private func makeNV12(
        width: Int,
        height: Int,
        yCodes: [UInt8],
        cbCode: UInt8,
        crCode: UInt8
    ) throws -> CVPixelBuffer {
        guard yCodes.count == width * height else {
            throw NSError(domain: "P010Tests", code: 2)
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ] as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "P010Tests", code: Int(status))
        }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width {
                yBase[row * yRowBytes + column] = yCodes[row * width + column]
            }
        }
        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        for row in 0..<uvHeight {
            for column in 0..<uvWidth {
                let offset = row * uvRowBytes + column * 2
                uvBase[offset] = cbCode
                uvBase[offset + 1] = crCode
            }
        }
        return pixelBuffer
    }
}
