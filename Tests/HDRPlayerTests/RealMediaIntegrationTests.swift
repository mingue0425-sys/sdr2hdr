@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import HDRCore
import Metal
import QuartzCore
import XCTest
@testable import HDRPlayerKit

@MainActor
final class RealMediaIntegrationTests: XCTestCase {
    private struct DecodedFrame {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
    }

    private struct OutputObservation {
        let finiteSampleCount: Int
        let nonZeroSampleCount: Int
        let maximumLuminance: Float
    }

    func testGeneratedFixtureRunsThroughProductionNearestPath() async throws {
        try await runH264RealMediaE2E(reconstructionMode: .nearest)
    }

    func testGeneratedFixtureRunsThroughSitingAwareCandidate() async throws {
        try await runH264RealMediaE2E(reconstructionMode: .sitingAwareBilinear)
    }

    private func runH264RealMediaE2E(
        reconstructionMode: HDRChromaReconstructionMode
    ) async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["HDR_SELF_CONTAINED_FIXTURE"] else {
            throw XCTSkip("set HDR_SELF_CONTAINED_FIXTURE to run the real-media integration test")
        }
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("self-contained fixture does not exist: \(fixtureURL.path)")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let asset = AVURLAsset(url: fixtureURL)
        let isPlayable = try await asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)

        let frames = try await decodeFrames(asset: asset, minimumCount: 3, maximumCount: 10)
        XCTAssertGreaterThanOrEqual(frames.count, 3)

        let firstPixelBuffer = try XCTUnwrap(frames.first?.pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(firstPixelBuffer)
        XCTAssertTrue(
            pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            "unsupported decoded pixel format: \(pixelFormatString(pixelFormat))"
        )
        XCTAssertNotNil(attachment(kCVImageBufferColorPrimariesKey, from: firstPixelBuffer))
        XCTAssertNotNil(attachment(kCVImageBufferTransferFunctionKey, from: firstPixelBuffer))
        XCTAssertNotNil(attachment(kCVImageBufferYCbCrMatrixKey, from: firstPixelBuffer))
        print(
            "REAL_MEDIA_CHROMA_METADATA codec=h264 top=\(chromaAttachmentName(attachment(kCVImageBufferChromaLocationTopFieldKey, from: firstPixelBuffer))) " +
                "bottom=\(chromaAttachmentName(attachment(kCVImageBufferChromaLocationBottomFieldKey, from: firstPixelBuffer)))"
        )

        let metadata = try HDRColorMetadataResolver.resolve(
            pixelBuffer: firstPixelBuffer,
            fallbackPolicy: .requireMetadata
        )
        XCTAssertEqual(metadata.metadata.transferFunction, .bt709)
        XCTAssertEqual(metadata.metadata.yCbCrMatrix, .bt709)
        XCTAssertFalse(metadata.metadata.isFullRange)
        XCTAssertNotEqual(metadata.chromaGeometry.resolvedSiting, .unspecified)

        var configuration = HDRConfiguration.calibratedV4
        configuration.chromaReconstructionMode = reconstructionMode
        let processor = try HDRProcessor(device: device, configuration: configuration)
        processor.temporalTraceEnabled = true
        let renderer = try HDRPresentationRenderer(device: device, colorPixelFormat: .rgba16Float)
        let width = CVPixelBufferGetWidth(firstPixelBuffer)
        let height = CVPixelBufferGetHeight(firstPixelBuffer)
        var observations: [OutputObservation] = []
        var previousTimestamp: Double?

        for (index, decoded) in frames.enumerated() {
            let timestamp = decoded.presentationTime.seconds
            XCTAssertTrue(timestamp.isFinite)
            if let previousTimestamp {
                XCTAssertGreaterThan(timestamp, previousTimestamp)
            }
            previousTimestamp = timestamp

            observations.append(try processAndPresent(
                decoded,
                index: index,
                width: width,
                height: height,
                device: device,
                processor: processor,
                renderer: renderer
            ))
        }

        XCTAssertEqual(processor.configuration, configuration)
        XCTAssertEqual(processor.configuration.sceneHistogramStrategy, .production)
        XCTAssertGreaterThanOrEqual(processor.lastGPUCompletedSequence, UInt64(frames.count))
        XCTAssertGreaterThanOrEqual(processor.lastAdaptiveCommittedSequence, UInt64(frames.count))
        XCTAssertGreaterThanOrEqual(processor.lastAdaptiveCommittedSequence, 1)
        XCTAssertTrue(processor.temporalCompletionTrace.allSatisfy {
            $0.gpuCompletionSequence == $0.adaptiveCommittedSequence &&
                $0.temporalStateVersionProduced == $0.adaptiveCommittedSequence &&
                $0.sceneStateVersionProduced == $0.adaptiveCommittedSequence
        })
        XCTAssertGreaterThanOrEqual(processor.temporalCompletionTrace.count, frames.count)
        let completionSequences = processor.temporalCompletionTrace.map(\.adaptiveCommittedSequence)
        XCTAssertEqual(completionSequences, completionSequences.sorted())
        XCTAssertLessThanOrEqual(processor.runtimeMetrics.outputTextureAllocations, 3)
        XCTAssertGreaterThan(observations.reduce(0) { $0 + $1.finiteSampleCount }, 0)
        XCTAssertGreaterThan(observations.reduce(0) { $0 + $1.nonZeroSampleCount }, 0)
        XCTAssertTrue(observations.allSatisfy { $0.maximumLuminance.isFinite })
        XCTAssertTrue(observations.allSatisfy { $0.maximumLuminance <= 1.5 + 0.01 })

        let firstTime = frames.first?.presentationTime.seconds ?? 0
        let lastTime = frames.last?.presentationTime.seconds ?? 0
        print(
            "REAL_MEDIA_E2E codec=h264 reconstruction=\(reconstructionMode) pixelFormat=\(pixelFormatString(pixelFormat)) " +
                "chromaSiting=\(metadata.chromaGeometry.resolvedSiting.rawValue) " +
                "resolution=\(width)x\(height) frames=\(frames.count) " +
                "timestamps=\(firstTime)...\(lastTime) " +
                "finiteSamples=\(observations.reduce(0) { $0 + $1.finiteSampleCount }) " +
                "nonZeroSamples=\(observations.reduce(0) { $0 + $1.nonZeroSampleCount }) " +
                "gpuSequence=\(processor.lastGPUCompletedSequence) " +
                "adaptiveSequence=\(processor.lastAdaptiveCommittedSequence)"
        )
    }

    func testGeneratedP010FixtureRunsThroughProductionNearestPath() async throws {
        try await runP010RealMediaE2E(reconstructionMode: .nearest)
    }

    func testGeneratedP010FixtureRunsThroughSitingAwareCandidate() async throws {
        try await runP010RealMediaE2E(reconstructionMode: .sitingAwareBilinear)
    }

    private func runP010RealMediaE2E(
        reconstructionMode: HDRChromaReconstructionMode
    ) async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["HDR_P010_SELF_CONTAINED_FIXTURE"] else {
            throw XCTSkip("set HDR_P010_SELF_CONTAINED_FIXTURE to run the P010 real-media integration test")
        }
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("P010 self-contained fixture does not exist: \(fixtureURL.path)")
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }

        let asset = AVURLAsset(url: fixtureURL)
        let isPlayable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(isPlayable)
        XCTAssertEqual(tracks.count, 1)

        let frames = try await decodeFrames(
            asset: asset,
            minimumCount: 3,
            maximumCount: 10,
            precision: .tenBitPreferred
        )
        XCTAssertGreaterThanOrEqual(frames.count, 3)

        let firstPixelBuffer = try XCTUnwrap(frames.first?.pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(firstPixelBuffer)
        XCTAssertTrue(
            pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            "10-bit source was downgraded to \(pixelFormatString(pixelFormat))"
        )
        XCTAssertNotNil(attachment(kCVImageBufferColorPrimariesKey, from: firstPixelBuffer))
        XCTAssertNotNil(attachment(kCVImageBufferTransferFunctionKey, from: firstPixelBuffer))
        XCTAssertNotNil(attachment(kCVImageBufferYCbCrMatrixKey, from: firstPixelBuffer))
        print(
            "REAL_MEDIA_CHROMA_METADATA codec=hevc-main10 top=\(chromaAttachmentName(attachment(kCVImageBufferChromaLocationTopFieldKey, from: firstPixelBuffer))) " +
                "bottom=\(chromaAttachmentName(attachment(kCVImageBufferChromaLocationBottomFieldKey, from: firstPixelBuffer)))"
        )

        let metadata = try HDRColorMetadataResolver.resolve(
            pixelBuffer: firstPixelBuffer,
            fallbackPolicy: .requireMetadata
        )
        XCTAssertEqual(metadata.pixelFormat, pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ? .p010FullRange : .p010VideoRange)
        XCTAssertEqual(metadata.metadata.transferFunction, .bt709)
        XCTAssertEqual(metadata.metadata.yCbCrMatrix, .bt709)
        XCTAssertFalse(metadata.metadata.isFullRange)
        XCTAssertEqual(metadata.yOffset, 64 / 1023, accuracy: 1e-6)
        XCTAssertEqual(metadata.yScale, 1023 / 876, accuracy: 1e-6)
        XCTAssertEqual(metadata.chromaOffset, 512 / 1023, accuracy: 1e-6)
        XCTAssertEqual(metadata.chromaScale, 1023 / 896, accuracy: 1e-6)
        XCTAssertNotEqual(metadata.chromaGeometry.resolvedSiting, .unspecified)
        let codeSummary = try p010LumaCodeSummary(frames)
        XCTAssertGreaterThan(codeSummary.uniqueCodeCount, 32)
        XCTAssertGreaterThanOrEqual(codeSummary.minimumCode, 64)
        XCTAssertLessThanOrEqual(codeSummary.maximumCode, 940)

        var configuration = HDRConfiguration.calibratedV4
        configuration.chromaReconstructionMode = reconstructionMode
        let processor = try HDRProcessor(device: device, configuration: configuration)
        processor.temporalTraceEnabled = true
        let renderer = try HDRPresentationRenderer(device: device, colorPixelFormat: .rgba16Float)
        let width = CVPixelBufferGetWidth(firstPixelBuffer)
        let height = CVPixelBufferGetHeight(firstPixelBuffer)
        var observations: [OutputObservation] = []
        var previousTimestamp: Double?

        for (index, decoded) in frames.enumerated() {
            let timestamp = decoded.presentationTime.seconds
            XCTAssertTrue(timestamp.isFinite)
            if let previousTimestamp {
                XCTAssertGreaterThan(timestamp, previousTimestamp)
            }
            previousTimestamp = timestamp
            observations.append(try processAndPresent(
                decoded,
                index: index,
                width: width,
                height: height,
                device: device,
                processor: processor,
                renderer: renderer
            ))
        }

        XCTAssertEqual(processor.configuration, configuration)
        XCTAssertEqual(processor.configuration.sceneHistogramStrategy, .production)
        XCTAssertGreaterThanOrEqual(processor.lastGPUCompletedSequence, UInt64(frames.count))
        XCTAssertGreaterThanOrEqual(processor.lastAdaptiveCommittedSequence, UInt64(frames.count))
        XCTAssertTrue(processor.temporalCompletionTrace.allSatisfy {
            $0.gpuCompletionSequence == $0.adaptiveCommittedSequence &&
                $0.temporalStateVersionProduced == $0.adaptiveCommittedSequence &&
                $0.sceneStateVersionProduced == $0.adaptiveCommittedSequence
        })
        XCTAssertGreaterThan(observations.reduce(0) { $0 + $1.finiteSampleCount }, 0)
        XCTAssertGreaterThan(observations.reduce(0) { $0 + $1.nonZeroSampleCount }, 0)
        XCTAssertTrue(observations.allSatisfy { $0.maximumLuminance.isFinite })
        XCTAssertTrue(observations.allSatisfy { $0.maximumLuminance <= 1.5 + 0.01 })

        let firstTime = frames.first?.presentationTime.seconds ?? 0
        let lastTime = frames.last?.presentationTime.seconds ?? 0
        print(
            "REAL_MEDIA_P010_E2E codec=hevc reconstruction=\(reconstructionMode) pixelFormat=\(pixelFormatString(pixelFormat)) " +
                "chromaSiting=\(metadata.chromaGeometry.resolvedSiting.rawValue) " +
                "resolution=\(width)x\(height) frames=\(frames.count) " +
                "uniqueYCodes=\(codeSummary.uniqueCodeCount) " +
                "YCodeRange=\(codeSummary.minimumCode)...\(codeSummary.maximumCode) " +
                "timestamps=\(firstTime)...\(lastTime) " +
                "finiteSamples=\(observations.reduce(0) { $0 + $1.finiteSampleCount }) " +
                "nonZeroSamples=\(observations.reduce(0) { $0 + $1.nonZeroSampleCount }) " +
                "gpuSequence=\(processor.lastGPUCompletedSequence) " +
                "adaptiveSequence=\(processor.lastAdaptiveCommittedSequence)"
        )
    }

    private func decodeFrames(
        asset: AVAsset,
        minimumCount: Int,
        maximumCount: Int,
        precision: HDRDecodePrecision = .automatic
    ) async throws -> [DecodedFrame] {
        let item = AVPlayerItem(asset: asset)
        let output = HDRVideoOutputConfiguration.makeVideoOutput(precision: precision)
        output.suppressesPlayerRendering = true
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true

        let readyDeadline = Date().addingTimeInterval(5)
        while item.status == .unknown && Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard item.status == .readyToPlay else {
            throw IntegrationError.playerItemNotReady(item.error?.localizedDescription ?? "unknown status")
        }

        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.01)
        player.play()

        var frames: [DecodedFrame] = []
        let deadline = Date().addingTimeInterval(8)
        while frames.count < maximumCount && Date() < deadline {
            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            if itemTime.isNumeric && output.hasNewPixelBuffer(forItemTime: itemTime) {
                var displayTime = CMTime.invalid
                if let pixelBuffer = output.copyPixelBuffer(
                    forItemTime: itemTime,
                    itemTimeForDisplay: &displayTime
                ), displayTime.isNumeric {
                    if frames.last?.presentationTime != displayTime {
                        frames.append(DecodedFrame(pixelBuffer: pixelBuffer, presentationTime: displayTime))
                    }
                }
            }
            if frames.count >= minimumCount && item.currentTime().isNumeric,
               item.currentTime().seconds > 0.9 {
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        player.pause()
        guard frames.count >= minimumCount else {
            throw IntegrationError.insufficientFrames(frames.count)
        }
        return frames
    }

    private func processAndPresent(
        _ decoded: DecodedFrame,
        index: Int,
        width: Int,
        height: Int,
        device: MTLDevice,
        processor: HDRProcessor,
        renderer: HDRPresentationRenderer
    ) throws -> OutputObservation {
        let commandBuffer = try processor.makeCommandBuffer()
        let frame = try processor.process(
            pixelBuffer: decoded.pixelBuffer,
            timestamp: decoded.presentationTime,
            commandBuffer: commandBuffer,
            diagnosticFrameIndex: UInt64(index + 1)
        )
        XCTAssertEqual(frame.texture.pixelFormat, .rgba16Float)
        XCTAssertEqual(frame.texture.width, width)
        XCTAssertEqual(frame.texture.height, height)

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        outputDescriptor.storageMode = .private
        let outputTexture = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))
        XCTAssertTrue(renderer.encodeOffscreen(
            texture: frame.texture,
            to: outputTexture,
            commandBuffer: commandBuffer,
            sourceSize: CGSize(width: width, height: height),
            drawableSize: CGSize(width: width, height: height),
            orientation: .identity,
            fallbackToSDR: false,
            masteringHeadroom: frame.metadata.masteringHeadroom,
            displayHeadroom: 1.5,
            diagnosticFrameIndex: UInt64(index + 1)
        ))

        let readbackLength = width * height * 4 * MemoryLayout<UInt16>.stride
        let readback = try XCTUnwrap(device.makeBuffer(
            length: readbackLength,
            options: .storageModeShared
        ))
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: outputTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: width * 4 * MemoryLayout<UInt16>.stride,
            destinationBytesPerImage: readbackLength
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(commandBuffer.status, .completed)
        XCTAssertNil(commandBuffer.error)

        let values = readback.contents().bindMemory(to: UInt16.self, capacity: width * height * 4)
        var finiteSampleCount = 0
        var nonZeroSampleCount = 0
        var maximumLuminance: Float = 0
        for pixel in 0..<(width * height) {
            let red = Float(Float16(bitPattern: values[pixel * 4]))
            let green = Float(Float16(bitPattern: values[pixel * 4 + 1]))
            let blue = Float(Float16(bitPattern: values[pixel * 4 + 2]))
            let alpha = Float(Float16(bitPattern: values[pixel * 4 + 3]))
            let components = [red, green, blue, alpha]
            let allFinite = components.allSatisfy { $0.isFinite }
            XCTAssertTrue(allFinite, "non-finite presentation output at pixel \(pixel)")
            if allFinite {
                finiteSampleCount += 4
            }
            if max(red, max(green, blue)) > 0.0001 {
                nonZeroSampleCount += 1
            }
            maximumLuminance = max(maximumLuminance, max(red, max(green, blue)))
            XCTAssertTrue(components.allSatisfy { $0 >= 0 })
            XCTAssertEqual(alpha, 1, accuracy: 0.01)
        }
        return OutputObservation(
            finiteSampleCount: finiteSampleCount,
            nonZeroSampleCount: nonZeroSampleCount,
            maximumLuminance: maximumLuminance
        )
    }

    private func attachment(_ key: CFString, from pixelBuffer: CVPixelBuffer) -> CFTypeRef? {
        CVBufferCopyAttachment(pixelBuffer, key, nil)
    }

    private func chromaAttachmentName(_ value: CFTypeRef?) -> String {
        guard let value else { return "nil" }
        if CFEqual(value, kCVImageBufferChromaLocation_Center) { return "center" }
        if CFEqual(value, kCVImageBufferChromaLocation_Left) { return "left" }
        if CFEqual(value, kCVImageBufferChromaLocation_TopLeft) { return "top-left" }
        if CFEqual(value, kCVImageBufferChromaLocation_Top) { return "top" }
        if CFEqual(value, kCVImageBufferChromaLocation_BottomLeft) { return "bottom-left" }
        if CFEqual(value, kCVImageBufferChromaLocation_Bottom) { return "bottom" }
        if CFEqual(value, kCVImageBufferChromaLocation_DV420) { return "dv420" }
        return String(describing: value)
    }

    private func p010LumaCodeSummary(
        _ frames: [DecodedFrame]
    ) throws -> (uniqueCodeCount: Int, minimumCode: UInt16, maximumCode: UInt16) {
        var codes = Set<UInt16>()
        var minimum = UInt16.max
        var maximum: UInt16 = 0
        for frame in frames {
            let pixelBuffer = frame.pixelBuffer
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0))
                .assumingMemoryBound(to: UInt16.self)
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes / MemoryLayout<UInt16>.stride)
                for x in 0..<width {
                    let code = row[x] >> 6
                    codes.insert(code)
                    minimum = min(minimum, code)
                    maximum = max(maximum, code)
                }
            }
        }
        return (codes.count, minimum, maximum)
    }

    private func pixelFormatString(_ format: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((format >> 24) & 0xff),
            UInt8((format >> 16) & 0xff),
            UInt8((format >> 8) & 0xff),
            UInt8(format & 0xff)
        ]
        return String(bytes: bytes.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, encoding: .ascii) ?? "unknown"
    }

    private enum IntegrationError: Error, LocalizedError {
        case playerItemNotReady(String)
        case insufficientFrames(Int)

        var errorDescription: String? {
            switch self {
            case .playerItemNotReady(let reason): return "AVPlayerItem did not become ready: \(reason)"
            case .insufficientFrames(let count): return "decoded only \(count) frames"
            }
        }
    }
}
