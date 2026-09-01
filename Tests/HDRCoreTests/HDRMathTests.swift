import CoreVideo
import XCTest
@testable import HDRCore
import Metal
import simd

final class HDRMathTests: XCTestCase {
    func testBT709TransferEndpointsAndReferenceGray() {
        XCTAssertEqual(HDRColorMath.inverseBT709(0), 0, accuracy: 1e-7)
        XCTAssertEqual(HDRColorMath.inverseBT709(1), 1, accuracy: 1e-6)
        XCTAssertEqual(HDRColorMath.bt709(0), 0, accuracy: 1e-7)
        XCTAssertEqual(HDRColorMath.bt709(1), 1, accuracy: 1e-6)

        let linearGray = HDRColorMath.inverseBT709(0.5)
        XCTAssertEqual(linearGray, 0.2595894, accuracy: 2e-5)
    }

    func testPQRoundTrip() {
        for nits in [0.0, 0.1, 1.0, 100.0, 203.0, 600.0, 1_000.0, 4_000.0, 10_000.0] {
            let signal = HDRColorMath.pqEncode(nits: Float(nits))
            let roundTrip = HDRColorMath.pqDecodeNits(signal: signal)
            XCTAssertEqual(roundTrip, Float(nits), accuracy: max(0.02, Float(nits) * 0.0005))
            XCTAssertTrue(signal.isFinite)
        }
    }

    func testToneCurveIsMonotonicAndAnchorsBlack() throws {
        let configuration = try HDRConfiguration.hdr.validated()
        XCTAssertEqual(HDRReference.toneExpand(0, configuration: configuration), 0, accuracy: 1e-7)
        var previous: Float = 0
        for step in 0...1_000 {
            let x = Float(step) / 1_000
            let value = HDRReference.toneExpand(x, configuration: configuration)
            XCTAssertGreaterThanOrEqual(value, previous - 1e-6)
            XCTAssertTrue(value.isFinite)
            previous = value
        }
        XCTAssertLessThanOrEqual(previous, configuration.peakNits / configuration.paperWhiteNits + 1e-6)
        XCTAssertGreaterThan(HDRReference.toneExpand(1, configuration: configuration), 1)
        XCTAssertLessThan(HDRReference.toneExpand(1, configuration: configuration), configuration.peakNits / configuration.paperWhiteNits)
    }

    func testHighlightChromaReductionUsesContinuousFixedOutputDomain() {
        var configuration = HDRConfiguration.hdr
        configuration.saturationCompensation = 1
        let peakRatio = configuration.peakNits / configuration.paperWhiteNits
        var previous: Float = -1
        var maximumStep: Float = 0
        for index in 0...1_000 {
            let luminance = 1 + (peakRatio - 1) * Float(index) / 1_000
            let reduction = HDRReference.highlightChromaReduction(
                expandedLuminance: luminance,
                configuration: configuration
            )
            XCTAssertGreaterThanOrEqual(reduction, previous)
            if previous >= 0 { maximumStep = max(maximumStep, reduction - previous) }
            previous = reduction
        }
        XCTAssertEqual(
            HDRReference.highlightChromaReduction(
                expandedLuminance: 1,
                configuration: configuration
            ),
            0,
            accuracy: 1e-7
        )
        XCTAssertLessThan(
            HDRReference.highlightChromaReduction(
                expandedLuminance: 1.001,
                configuration: configuration
            ),
            0.000_01
        )
        XCTAssertEqual(previous, 0.35, accuracy: 1e-6)
        XCTAssertLessThan(maximumStep, 0.001)
    }

    func testBT709ToBT2020MatrixPreservesNeutral() {
        let white = HDRColorMath.bt709ToBT2020 * SIMD3<Float>(repeating: 1)
        XCTAssertEqual(white.x, 1, accuracy: 2e-5)
        XCTAssertEqual(white.y, 1, accuracy: 2e-5)
        XCTAssertEqual(white.z, 1, accuracy: 2e-5)

        let red = HDRColorMath.bt709ToBT2020 * SIMD3<Float>(1, 0, 0)
        XCTAssertTrue(red.x > 0)
        XCTAssertTrue(red.y >= 0)
        XCTAssertTrue(red.z >= 0)
    }

    func testReferencePrimaryColorsRemainFinite() throws {
        let configuration = try HDRConfiguration.vivid.validated()
        let samples: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1),
            SIMD3(repeating: 0.5), SIMD3(repeating: 1), SIMD3(0.01, 0.02, 0.03)
        ]
        for sample in samples {
            let output = HDRReference.process(signalRGB: sample, configuration: configuration)
            XCTAssertTrue(output.x.isFinite && output.y.isFinite && output.z.isFinite && output.w.isFinite)
            XCTAssertGreaterThanOrEqual(output.x, 0)
            XCTAssertGreaterThanOrEqual(output.y, 0)
            XCTAssertGreaterThanOrEqual(output.z, 0)
        }
    }

    func testSyntheticRampBarsAndNearBlackStayFiniteAndOrdered() throws {
        let configuration = try HDRConfiguration.hdr.validated()
        let grayRamp = (0...255).map { Float($0) / 255 }
        let rampOutput = grayRamp.map {
            HDRReference.process(signalRGB: SIMD3(repeating: $0), configuration: configuration).x
        }
        for index in 1..<rampOutput.count {
            XCTAssertGreaterThanOrEqual(rampOutput[index], rampOutput[index - 1] - 0.001)
            XCTAssertTrue(rampOutput[index].isFinite)
        }
        XCTAssertEqual(rampOutput[0], 0, accuracy: 1e-6)

        let colorBars: [SIMD3<Float>] = [
            SIMD3(1, 1, 1), SIMD3(1, 1, 0), SIMD3(0, 1, 1), SIMD3(0, 1, 0),
            SIMD3(1, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 0, 0)
        ]
        for color in colorBars {
            let output = HDRReference.process(signalRGB: color, configuration: configuration)
            XCTAssertTrue(output.x.isFinite && output.y.isFinite && output.z.isFinite)
            XCTAssertGreaterThanOrEqual(output.x, 0)
            XCTAssertGreaterThanOrEqual(output.y, 0)
            XCTAssertGreaterThanOrEqual(output.z, 0)
        }
    }

    func testV3ShadowProtectionIsIdentifiableMonotonicAndIsolated() throws {
        var configuration = HDRConfiguration.calibratedV2
        configuration.toneCurveRevision = .shadowProtectedV3
        let shadowSamples: [Float] = [0.005, 0.01, 0.025, 0.05, 0.10, 0.20]
        var priorAverage = Float.greatestFiniteMagnitude
        for protection: Float in [0, 0.25, 0.5, 0.75, 1] {
            configuration.shadowProtection = protection
            let outputs = shadowSamples.map { HDRReference.toneExpand($0, configuration: configuration) }
            XCTAssertTrue(outputs.allSatisfy(\.isFinite))
            let average = outputs.reduce(0, +) / Float(outputs.count)
            XCTAssertLessThanOrEqual(average, priorAverage + 0.000_001)
            priorAverage = average
        }
        configuration.shadowProtection = 0
        let unprotectedHighlight = HDRReference.toneExpand(0.9, configuration: configuration)
        configuration.shadowProtection = 1
        let protectedHighlight = HDRReference.toneExpand(0.9, configuration: configuration)
        XCTAssertEqual(protectedHighlight, unprotectedHighlight, accuracy: 0.000_001)
        XCTAssertEqual(HDRReference.toneExpand(0, configuration: configuration), 0, accuracy: 0)
    }

    func testV3NearBlackRampRemainsMonotonic() {
        var configuration = HDRConfiguration.calibratedV2
        configuration.toneCurveRevision = .shadowProtectedV3
        configuration.shadowProtection = 1
        let values = (0...500).map { Float($0) * 0.0001 }
        let output = values.map { HDRReference.toneExpand($0, configuration: configuration) }
        for index in 1..<output.count {
            XCTAssertGreaterThanOrEqual(output[index], output[index - 1] - 0.000_001)
        }
        XCTAssertEqual(output[0], 0, accuracy: 0)
    }

    func testV4SceneRelativeShadowProtectionIsIdentifiableAndHighlightIndependent() {
        var configuration = HDRConfiguration.calibratedV2
        configuration.toneCurveRevision = .sceneRelativeV4
        let statistics = HDRSceneStatistics(
            p01: 0.001, p05: 0.008, p10: 0.025, p25: 0.18,
            p50: 0.42, p90: 0.88, p99: 1.0
        )
        let shadowSamples: [Float] = [0.001, 0.005, 0.01, 0.02, 0.05, 0.10]
        var previousAverage = Float.greatestFiniteMagnitude
        var sensitivity: Float = 0
        var firstOutputs: [Float] = []
        for protection: Float in [0, 0.25, 0.5, 0.75, 1] {
            configuration.shadowProtection = protection
            let outputs = shadowSamples.map {
                HDRReference.toneExpand($0, configuration: configuration, sceneStatistics: statistics)
            }
            XCTAssertTrue(outputs.allSatisfy(\.isFinite))
            for index in 1..<outputs.count {
                XCTAssertGreaterThanOrEqual(outputs[index], outputs[index - 1] - 0.000_001)
            }
            let average = outputs.reduce(0, +) / Float(outputs.count)
            XCTAssertLessThanOrEqual(average, previousAverage + 0.000_001)
            previousAverage = average
            if firstOutputs.isEmpty {
                firstOutputs = outputs
            } else {
                sensitivity = max(sensitivity, zip(firstOutputs, outputs).map { abs($0 - $1) }.max() ?? 0)
            }
        }
        XCTAssertGreaterThan(sensitivity, 0.001)

        configuration.shadowProtection = 0
        let unprotectedHighlight = HDRReference.toneExpand(0.9, configuration: configuration, sceneStatistics: statistics)
        configuration.shadowProtection = 1
        let protectedHighlight = HDRReference.toneExpand(0.9, configuration: configuration, sceneStatistics: statistics)
        XCTAssertEqual(protectedHighlight, unprotectedHighlight, accuracy: 0.000_001)
        XCTAssertEqual(HDRReference.toneExpand(0, configuration: configuration, sceneStatistics: statistics), 0, accuracy: 0)
    }

    func testV4SceneStatisticsPercentilesAndCausalState() throws {
        let statistics = HDRSceneStatistics(samples: [0, 0.01, 0.05, 0.2, 0.5, 0.9, 1])
        XCTAssertTrue(statistics.isFinite)
        XCTAssertLessThanOrEqual(statistics.p01, statistics.p05)
        XCTAssertLessThanOrEqual(statistics.p05, statistics.p10)
        XCTAssertLessThanOrEqual(statistics.p10, statistics.p25)
        XCTAssertLessThanOrEqual(statistics.p25, statistics.p50)
        XCTAssertLessThanOrEqual(statistics.shadowFloor, statistics.shadowTop)

        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        var configuration = HDRConfiguration.calibratedV2
        configuration.toneCurveRevision = .sceneRelativeV4
        let processor = try HDRProcessor(device: device, configuration: configuration)
        XCTAssertFalse(processor.sceneShadowCoordinates.valid)
        processor.updateSceneStatistics(statistics, sceneCut: true)
        let coordinates = processor.sceneShadowCoordinates
        XCTAssertTrue(coordinates.valid)
        XCTAssertEqual(coordinates.floor, statistics.shadowFloor, accuracy: 0.000_001)
        XCTAssertEqual(coordinates.top, statistics.shadowTop, accuracy: 0.000_001)
        processor.clearTemporalHistory()
        XCTAssertFalse(processor.sceneShadowCoordinates.valid)
    }

    func testTemporalStabilityHasSequentialSensitivityAndSceneCutResets() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        var responsiveConfiguration = HDRConfiguration.calibratedV2
        responsiveConfiguration.temporalStability = 0
        let responsive = try HDRProcessor(device: device, configuration: responsiveConfiguration)
        responsive.resetTemporalState(averageLuminance: 0.5)
        for value: Float in [0.1, 0.9, 0.1, 0.9] {
            responsive.updateTemporalEstimate(averageLuminance: value)
        }

        var stableConfiguration = responsiveConfiguration
        stableConfiguration.temporalStability = 1
        let stable = try HDRProcessor(device: device, configuration: stableConfiguration)
        stable.resetTemporalState(averageLuminance: 0.5)
        for value: Float in [0.1, 0.9, 0.1, 0.9] {
            stable.updateTemporalEstimate(averageLuminance: value)
        }
        XCTAssertGreaterThan(abs(responsive.temporalAdaptation - stable.temporalAdaptation), 0.01)

        stable.updateTemporalEstimate(averageLuminance: 0.9, sceneCut: true)
        let expected: Float = min(max(0.94 + 0.12 * (0.5 - 0.9), 0.90), 1.06)
        XCTAssertEqual(stable.temporalAdaptation, expected, accuracy: 0.000_001)
    }

    func testInvalidConfigurationIsRejected() {
        XCTAssertThrowsError(try HDRConfiguration(peakNits: .nan).validated())
        XCTAssertThrowsError(try HDRConfiguration(paperWhiteNits: -1).validated())
        XCTAssertThrowsError(try HDRConfiguration(paperWhiteNits: 500, peakNits: 400).validated())
        XCTAssertThrowsError(try HDRConfiguration(highlightStrength: 2).validated())
    }
}

final class HDRMetalReferenceTests: XCTestCase {
    func testAutomaticTemporalEstimatorUpdatesWithoutCPUReadback() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        var configuration = HDRConfiguration.calibratedV2
        configuration.temporalStability = 0.5
        let processor = try HDRProcessor(device: device, configuration: configuration)
        let pixelBuffer = try makeBGRA(width: 32, height: 18, rgb: SIMD3(repeating: 0.95))
        let commandBuffer = try processor.makeCommandBuffer()
        _ = try processor.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertLessThan(processor.temporalAdaptation, 0.95)
        XCTAssertTrue(processor.temporalAdaptation.isFinite)
    }

    func testClearTemporalHistoryRejectsPriorUncommittedGeneration() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        var configuration = HDRConfiguration.calibratedV2
        configuration.temporalStability = 0
        let processor = try HDRProcessor(device: device, configuration: configuration)
        let pixelBuffer = try makeBGRA(width: 32, height: 18, rgb: SIMD3(repeating: 0.95))
        let commandBuffer = try processor.makeCommandBuffer()
        _ = try processor.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)

        // The completion belongs to the old generation even though it has not
        // been committed yet. It must not resurrect state after the reset.
        processor.clearTemporalHistory()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(processor.temporalAdaptation, 1, accuracy: 0.000_001)
        XCTAssertEqual(processor.lastCompletedTemporalSequence, 0)
    }

    func testRetainedFrameKeepsOutputTextureExclusivelyLeased() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let processor = try HDRProcessor(device: device, configuration: .natural)
        let pixelBuffer = try makeBGRA(width: 8, height: 8, rgb: SIMD3(repeating: 0.5))

        let firstCommandBuffer = try processor.makeCommandBuffer()
        let firstFrame = try processor.process(
            pixelBuffer: pixelBuffer,
            commandBuffer: firstCommandBuffer
        )
        firstCommandBuffer.commit()
        firstCommandBuffer.waitUntilCompleted()

        let secondCommandBuffer = try processor.makeCommandBuffer()
        let secondFrame = try processor.process(
            pixelBuffer: pixelBuffer,
            commandBuffer: secondCommandBuffer
        )
        XCTAssertFalse(firstFrame.texture === secondFrame.texture)
        secondCommandBuffer.commit()
        secondCommandBuffer.waitUntilCompleted()
    }

    func testNV12AndBGRATemporalEstimatorsAgreeForColoredInput() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        var configuration = HDRConfiguration.calibratedV2
        configuration.temporalStability = 0
        configuration.inputFallbackPolicy = .bt709FullRange

        let rgb = SIMD3<Float>(0.78, 0.32, 0.18)
        let signalLuma = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
        let cb = (rgb.z - signalLuma) / 1.8556
        let cr = (rgb.x - signalLuma) / 1.5748
        func byte(_ value: Float, lower: Int, upper: Int) -> UInt8 {
            UInt8(min(max(Int(value.rounded()), lower), upper))
        }
        let nv12 = try makeNV12(
            width: 32,
            height: 18,
            y: byte(16 + signalLuma * 219, lower: 16, upper: 235),
            cb: byte(128 + cb * 224, lower: 16, upper: 240),
            cr: byte(128 + cr * 224, lower: 16, upper: 240),
            attachMetadata: true
        )
        let bgra = try makeBGRA(width: 32, height: 18, rgb: rgb)
        let nv12Processor = try HDRProcessor(device: device, configuration: configuration)
        let bgraProcessor = try HDRProcessor(device: device, configuration: configuration)

        let nv12Command = try nv12Processor.makeCommandBuffer()
        _ = try nv12Processor.process(pixelBuffer: nv12, commandBuffer: nv12Command)
        nv12Command.commit()
        let bgraCommand = try bgraProcessor.makeCommandBuffer()
        _ = try bgraProcessor.process(pixelBuffer: bgra, commandBuffer: bgraCommand)
        bgraCommand.commit()
        nv12Command.waitUntilCompleted()
        bgraCommand.waitUntilCompleted()

        XCTAssertEqual(
            nv12Processor.temporalAdaptation,
            bgraProcessor.temporalAdaptation,
            accuracy: 0.005
        )
    }

    func testNV12MetalOutputMatchesScalarReferenceForNeutralGray() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let configuration = HDRConfiguration(
            paperWhiteNits: 203,
            peakNits: 1_000,
            highlightStrength: 0.55,
            contrastStrength: 0.5,
            saturationCompensation: 0.55,
            shadowProtection: 0.85,
            temporalStability: 0.9,
            outputMode: .pq,
            displayHeadroom: 4,
            inputFallbackPolicy: .bt709VideoRange
        )
        let pixelBuffer = try makeNV12(width: 2, height: 2, y: 128, cb: 128, cr: 128, attachMetadata: true)
        let processor = try HDRProcessor(device: device, configuration: configuration)
        guard let commandQueue = device.makeCommandQueue(), let commandBuffer = commandQueue.makeCommandBuffer() else {
            XCTFail("Unable to create command buffer")
            return
        }
        let frame = try processor.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        var output = [Float16](repeating: 0, count: 4)
        frame.texture.getBytes(
            &output,
            bytesPerRow: 2 * MemoryLayout<Float16>.size * 4,
            from: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0
        )
        let signal = (Float(128) - 16) / 219
        let normalizedSignal = min(max(signal, 0), 1)
        let expected = HDRReference.process(
            signalRGB: SIMD3(repeating: normalizedSignal),
            configuration: configuration
        )
        XCTAssertEqual(Float(output[0]), expected.x, accuracy: 0.002)
        XCTAssertEqual(Float(output[1]), expected.y, accuracy: 0.002)
        XCTAssertEqual(Float(output[2]), expected.z, accuracy: 0.002)
        XCTAssertEqual(Float(output[3]), 1, accuracy: 0.001)
    }

    func testMissingMetadataCanBeRejected() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        var configuration = HDRConfiguration.hdr
        configuration.inputFallbackPolicy = .requireMetadata
        let processor = try HDRProcessor(device: device, configuration: configuration)
        let pixelBuffer = try makeNV12(width: 2, height: 2, y: 128, cb: 128, cr: 128, attachMetadata: false)
        XCTAssertThrowsError(try processor.process(pixelBuffer: pixelBuffer)) { error in
            guard case HDRProcessorError.metadata(.missingMetadata) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testBGRAFallbackUsesZeroCopyTexturePathAndMatchesReference() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        var configuration = HDRConfiguration.natural
        configuration.outputMode = .edr
        configuration.inputFallbackPolicy = .bt709FullRange
        let processor = try HDRProcessor(device: device, configuration: configuration)
        let pixelBuffer = try makeBGRA(width: 2, height: 2, rgb: SIMD3(0.8, 0.2, 0.05))
        guard let commandQueue = device.makeCommandQueue(), let commandBuffer = commandQueue.makeCommandBuffer() else {
            XCTFail("Unable to create command buffer")
            return
        }
        let frame = try processor.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        var output = [Float16](repeating: 0, count: 4)
        frame.texture.getBytes(
            &output,
            bytesPerRow: 2 * MemoryLayout<Float16>.size * 4,
            from: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0
        )
        let expected = HDRReference.process(
            signalRGB: SIMD3(0.8, 0.2, 0.05),
            configuration: configuration
        )
        XCTAssertEqual(Float(output[0]), expected.x, accuracy: 0.003)
        XCTAssertEqual(Float(output[1]), expected.y, accuracy: 0.003)
        XCTAssertEqual(Float(output[2]), expected.z, accuracy: 0.003)
    }

    func testOptionalGPUDebugStatisticsAreProduced() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let processor = try HDRProcessor(device: device, configuration: .hdr)
        processor.debugInstrumentationEnabled = true
        let pixelBuffer = try makeBGRA(width: 2, height: 2, rgb: SIMD3(repeating: 0.9))
        guard let commandQueue = device.makeCommandQueue(), let commandBuffer = commandQueue.makeCommandBuffer() else {
            XCTFail("Unable to create command buffer")
            return
        }
        _ = try processor.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard let statistics = processor.lastDebugStatistics else {
            return XCTFail("Expected debug statistics after GPU completion")
        }
        XCTAssertTrue(statistics.inputAverageLuminance.isFinite)
        XCTAssertTrue(statistics.outputAverageLuminance.isFinite)
        XCTAssertEqual(statistics.highlightPixelRatio, 1, accuracy: 0.001)
        XCTAssertEqual(statistics.clippedPixelRatio, 0, accuracy: 0.001)
        XCTAssertNotNil(statistics.gpuDurationMilliseconds)
    }

    func testOutputPoolPrewarmsAndReusesThreeRGBA16FloatTextures() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let processor = try HDRProcessor(device: device, configuration: .natural)
        try processor.prepare(width: 2, height: 2)
        XCTAssertEqual(processor.runtimeMetrics.outputTextureAllocations, 3)
        XCTAssertEqual(processor.runtimeMetrics.outputTextureLogicalBytes, 3 * 2 * 2 * 8)
        let pixelBuffer = try makeBGRA(width: 2, height: 2, rgb: SIMD3(repeating: 0.5))
        guard let queue = device.makeCommandQueue(), let commandBuffer = queue.makeCommandBuffer() else {
            XCTFail("Unable to create command buffer")
            return
        }
        _ = try processor.process(pixelBuffer: pixelBuffer, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(processor.runtimeMetrics.outputTextureAllocations, 3)
    }

    private func makeNV12(
        width: Int,
        height: Int,
        y: UInt8,
        cb: UInt8,
        cr: UInt8,
        attachMetadata: Bool
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "HDRCoreTests", code: Int(status))
        }
        if attachMetadata {
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self) {
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            for row in 0..<height {
                for column in 0..<width {
                    yBase[row * rowBytes + column] = y
                }
            }
        }
        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) {
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            for row in 0..<uvHeight {
                for column in 0..<uvWidth {
                    uvBase[row * rowBytes + column * 2] = cb
                    uvBase[row * rowBytes + column * 2 + 1] = cr
                }
            }
        }
        return pixelBuffer
    }

    private func makeBGRA(width: Int, height: Int, rgb: SIMD3<Float>) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: CFDictionary = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "HDRCoreTests", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw NSError(domain: "HDRCoreTests", code: 10)
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let red = UInt8(min(max(Int(rgb.x * 255), 0), 255))
        let green = UInt8(min(max(Int(rgb.y * 255), 0), 255))
        let blue = UInt8(min(max(Int(rgb.z * 255), 0), 255))
        for row in 0..<height {
            for column in 0..<width {
                let offset = row * rowBytes + column * 4
                base[offset] = blue
                base[offset + 1] = green
                base[offset + 2] = red
                base[offset + 3] = 255
            }
        }
        return pixelBuffer
    }
}
