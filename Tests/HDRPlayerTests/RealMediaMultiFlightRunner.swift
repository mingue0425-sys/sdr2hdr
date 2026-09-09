@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
@testable import HDRCore
import HDRPlayerKit

private enum RealMediaMultiFlightSchedulingWork {
    // This is test-only GPU work. It keeps the first flight batch observable
    // as in-flight without using a cross-queue event or changing production
    // resources. The buffer is retained by the pending frame until retirement.
    static let bytes = 32 * 1024 * 1024
    static let passes = 8
}

/// A frame whose HDR processing, offscreen presentation, and readback have
/// been encoded but not yet retired. Keeping the HDRFrame here is part of the
/// test: its lease must remain alive until the producing command completes.
struct RealMediaPendingFrame {
    let frameIndex: Int
    let presentationTime: CMTime
    let generation: UInt64
    let submissionSequence: UInt64
    let commandBuffer: MTLCommandBuffer
    let frame: HDRFrame
    let outputTexture: MTLTexture
    let readback: MTLBuffer
    let schedulingWorkBuffer: MTLBuffer?
    let completionSignal: DispatchSemaphore?
    let width: Int
    let height: Int
    let cpuStart: CFTimeInterval
}

struct RealMediaCompletedFrame {
    let frameIndex: Int
    let presentationTime: CMTime
    let output: RegressionFrameOutput
    let gpuMilliseconds: Double
    let cpuMilliseconds: Double
}

struct RealMediaMultiFlightCompletionEvidence: Codable, Sendable {
    let frameIndex: Int
    let generation: UInt64
    let submissionSequence: UInt64
    let completionOrdinal: Int
    let status: String
    let completed: Bool
    let error: String?
    let gpuStartTime: Double
    let gpuEndTime: Double
    let completionWallClock: Double
}

struct RealMediaMultiFlightSerialParity: Codable, Sendable {
    /// V4's estimator is causal. With multiple command buffers submitted
    /// before completion, later frames may legitimately consume an older
    /// adaptive snapshot than the serial control. The comparison is therefore
    /// diagnostic; final sequence convergence and validity remain hard gates.
    let contract: String
    let meanAbsoluteLuminanceDelta: Double
    let p95AbsoluteLuminanceDelta: Double
    let maximumAbsoluteLuminanceDelta: Double
    let finalAdaptiveSequenceMatches: Bool
}

struct RealMediaMultiFlightModeResult: Codable, Sendable {
    let mode: RegressionMode
    let flightDepth: Int
    let result: RegressionModeResult
    let submittedFrameIndices: [Int]
    let submittedSequences: [UInt64]
    let submissionGenerations: [UInt64]
    let completionSequences: [UInt64]
    let completionEvents: [RealMediaMultiFlightCompletionEvidence]
    let readbackFrameIndices: [Int]
    let maxObservedInFlight: Int
    let maxPending: Int
    let maxSimultaneousLeases: Int
    let textureAllocations: Int
    let temporalEstimateBufferAllocations: Int
    let serialParity: RealMediaMultiFlightSerialParity
}

struct RealMediaMultiFlightFixtureResult: Codable, Sendable {
    let manifest: RealMediaRegressionFixture
    let id: String
    let flightDepth: Int
    let modes: [RealMediaMultiFlightModeResult]
    let passed: Bool
    let failures: [String]
}

struct RealMediaMultiFlightReport: Codable, Sendable {
    let baseline: String
    let candidate: String
    let fixtureCount: Int
    let runCount: Int
    let failures: Int
    let fixtures: [RealMediaMultiFlightFixtureResult]
}

/// Completion handlers run on Metal-managed threads. This collector contains
/// no XCTest assertions; the main-actor runner inspects the immutable snapshot
/// after every pending command has been retired.
final class RealMediaMultiFlightCompletionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RealMediaMultiFlightCompletionEvidence] = []

    func record(
        frameIndex: Int,
        generation: UInt64,
        submissionSequence: UInt64,
        commandBuffer: MTLCommandBuffer
    ) {
        let event = RealMediaMultiFlightCompletionEvidence(
            frameIndex: frameIndex,
            generation: generation,
            submissionSequence: submissionSequence,
            completionOrdinal: 0,
            status: String(describing: commandBuffer.status),
            completed: commandBuffer.status == .completed,
            error: commandBuffer.error?.localizedDescription,
            gpuStartTime: commandBuffer.gpuStartTime,
            gpuEndTime: commandBuffer.gpuEndTime,
            completionWallClock: CACurrentMediaTime()
        )
        lock.lock()
        defer { lock.unlock() }
        storage.append(
            RealMediaMultiFlightCompletionEvidence(
                frameIndex: event.frameIndex,
                generation: event.generation,
                submissionSequence: event.submissionSequence,
                completionOrdinal: storage.count + 1,
                status: event.status,
                completed: event.completed,
                error: event.error,
                gpuStartTime: event.gpuStartTime,
                gpuEndTime: event.gpuEndTime,
                completionWallClock: event.completionWallClock
            )
        )
    }

    var events: [RealMediaMultiFlightCompletionEvidence] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}

extension RealMediaRegressionRunner {
    private func logMultiFlightProgress(_ message: String) {
        guard ProcessInfo.processInfo.environment["HDR_REAL_MEDIA_MULTIFLIGHT_PROGRESS"] == "1" else {
            return
        }
        FileHandle.standardError.write(Data("MULTIFLIGHT_PROGRESS \(message)\n".utf8))
    }

    /// Encodes the same production-equivalent processing and presentation
    /// chain used by the serial regression path, but leaves retirement to the
    /// caller. No CPU frame conversion is introduced.
    func makePendingFrame(
        _ decoded: DecodedFrame,
        index: Int,
        width: Int,
        height: Int,
        processor: HDRProcessor,
        renderer: HDRPresentationRenderer,
        schedulingWorkBytes: Int = 0,
        completionSignal: DispatchSemaphore? = nil
    ) throws -> RealMediaPendingFrame {
        let cpuStart = CACurrentMediaTime()
        let commandBuffer = try processor.makeCommandBuffer()
        let frame = try processor.process(
            pixelBuffer: decoded.pixelBuffer,
            timestamp: decoded.presentationTime,
            commandBuffer: commandBuffer,
            diagnosticFrameIndex: UInt64(index + 1)
        )
        guard frame.texture.pixelFormat == .rgba16Float,
              frame.texture.width == width,
              frame.texture.height == height else {
            throw RunnerError.missingTexture
        }

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        outputDescriptor.storageMode = .private
        guard let outputTexture = device.makeTexture(descriptor: outputDescriptor) else {
            throw RunnerError.missingTexture
        }
        guard renderer.encodeOffscreen(
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
        ) else {
            throw RunnerError.commandBufferFailed("offscreen presentation encoding failed")
        }

        let readbackLength = width * height * 4 * MemoryLayout<UInt16>.stride
        guard let readback = device.makeBuffer(
            length: readbackLength,
            options: .storageModeShared
        ), let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw RunnerError.missingTexture
        }
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
        let schedulingWorkBuffer: MTLBuffer?
        if schedulingWorkBytes > 0 {
            guard let buffer = device.makeBuffer(
                length: schedulingWorkBytes,
                options: .storageModeShared
            ) else {
                throw RunnerError.missingTexture
            }
            schedulingWorkBuffer = buffer
            let workRange = 0..<schedulingWorkBytes
            for pass in 0..<RealMediaMultiFlightSchedulingWork.passes {
                blit.fill(
                    buffer: buffer,
                    range: workRange,
                    value: UInt8(truncatingIfNeeded: pass)
                )
            }
        } else {
            schedulingWorkBuffer = nil
        }
        blit.endEncoding()

        return RealMediaPendingFrame(
            frameIndex: index,
            presentationTime: decoded.presentationTime,
            generation: processor.temporalGeneration,
            submissionSequence: processor.temporalSubmissionSequence,
            commandBuffer: commandBuffer,
            frame: frame,
            outputTexture: outputTexture,
            readback: readback,
            schedulingWorkBuffer: schedulingWorkBuffer,
            completionSignal: completionSignal,
            width: width,
            height: height,
            cpuStart: cpuStart
        )
    }

    /// Consumes readback only after the command buffer has completed. This is
    /// shared by serial and multi-flight paths so output validity has one
    /// implementation and one set of gates.
    func completePendingFrame(
        _ pending: RealMediaPendingFrame,
        luminanceSampleLimit: Int? = nil
    ) throws -> RealMediaCompletedFrame {
        guard pending.commandBuffer.status == .completed,
              pending.commandBuffer.error == nil else {
            throw RunnerError.commandBufferFailed(
                pending.commandBuffer.error?.localizedDescription ?? "unknown status"
            )
        }

        let width = pending.width
        let height = pending.height
        let values = pending.readback.contents().bindMemory(
            to: UInt16.self,
            capacity: width * height * 4
        )
        var finiteSampleCount = 0
        var nanCount = 0
        var infinityCount = 0
        var negativeCount = 0
        var nonZeroSampleCount = 0
        var minimumValue = Double.infinity
        var maximumValue = -Double.infinity
        let luminanceSampleStride = samplingStride(
            width: width,
            height: height,
            maxSamples: luminanceSampleLimit
        )
        let sampledWidth = (width + luminanceSampleStride - 1) / luminanceSampleStride
        let sampledHeight = (height + luminanceSampleStride - 1) / luminanceSampleStride
        let sampledPixelCount = max(sampledWidth * sampledHeight, 1)
        var luminance: [Float] = []
        luminance.reserveCapacity(sampledPixelCount)
        var clippingPixels = 0
        var luminanceSum = 0.0

        for y in stride(from: 0, to: height, by: luminanceSampleStride) {
            for x in stride(from: 0, to: width, by: luminanceSampleStride) {
                let pixel = y * width + x
                let red = Float(Float16(bitPattern: values[pixel * 4]))
                let green = Float(Float16(bitPattern: values[pixel * 4 + 1]))
                let blue = Float(Float16(bitPattern: values[pixel * 4 + 2]))
                let alpha = Float(Float16(bitPattern: values[pixel * 4 + 3]))

                for value in [red, green, blue, alpha] {
                    if value.isNaN {
                        nanCount += 1
                    } else if value.isInfinite {
                        infinityCount += 1
                    } else {
                        finiteSampleCount += 1
                        if value < 0 { negativeCount += 1 }
                        minimumValue = min(minimumValue, Double(value))
                        maximumValue = max(maximumValue, Double(value))
                    }
                }

                let pixelLuminance = 0.2627 * red + 0.6780 * green + 0.0593 * blue
                luminance.append(pixelLuminance)
                luminanceSum += Double(pixelLuminance)
                if max(red, max(green, blue)) > 0.0001 { nonZeroSampleCount += 1 }
                if max(red, max(green, blue)) >= 1.5 { clippingPixels += 1 }
            }
        }

        let gpuMilliseconds: Double
        if pending.commandBuffer.gpuStartTime > 0,
           pending.commandBuffer.gpuEndTime >= pending.commandBuffer.gpuStartTime {
            gpuMilliseconds = (
                pending.commandBuffer.gpuEndTime - pending.commandBuffer.gpuStartTime
            ) * 1000
        } else {
            gpuMilliseconds = 0
        }
        let output = RegressionFrameOutput(
            finiteSampleCount: finiteSampleCount,
            nanCount: nanCount,
            infinityCount: infinityCount,
            negativeCount: negativeCount,
            nonZeroSampleCount: nonZeroSampleCount,
            meanLuminance: luminanceSum / Double(sampledPixelCount),
            minimumValue: minimumValue.isFinite ? minimumValue : 0,
            maximumValue: maximumValue.isFinite ? maximumValue : 0,
            clippingFraction: Double(clippingPixels) / Double(sampledPixelCount),
            luminance: luminance
        )
        return RealMediaCompletedFrame(
            frameIndex: pending.frameIndex,
            presentationTime: pending.presentationTime,
            output: output,
            gpuMilliseconds: gpuMilliseconds,
            cpuMilliseconds: (CACurrentMediaTime() - pending.cpuStart) * 1000
        )
    }

    func runMultiFlight(
        _ fixture: RealMediaRegressionFixture,
        flightDepth: Int
    ) async throws -> RealMediaMultiFlightFixtureResult {
        let frames = try await decodeRegressionFrames(fixture)
        return try await runMultiFlight(
            fixture,
            decodedFrames: frames,
            flightDepth: flightDepth
        )
    }

    /// Decodes once so callers can separate AVPlayer acquisition from the GPU
    /// scheduling experiment. The multi-flight test retains this fixed array
    /// and runs serial, two-flight, and three-flight processing against
    /// exactly the same decoded frames.
    func decodeRegressionFrames(
        _ fixture: RealMediaRegressionFixture
    ) async throws -> [DecodedFrame] {
        let fixtureURL = fixtureDirectory.appendingPathComponent("\(fixture.id).mp4")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw RunnerError.insufficientFrames(
                id: fixture.id,
                count: 0,
                required: fixture.minimumFrames
            )
        }
        let asset = AVURLAsset(url: fixtureURL)
        guard try await asset.load(.isPlayable) else {
            throw RunnerError.playerItemNotReady("asset is not playable")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1 else {
            throw RunnerError.playerItemNotReady(
                "expected one video track, found \(tracks.count)"
            )
        }
        return try await decodeFrames(asset: asset, fixture: fixture)
    }

    func runMultiFlight(
        _ fixture: RealMediaRegressionFixture,
        decodedFrames frames: [DecodedFrame],
        flightDepth: Int
    ) async throws -> RealMediaMultiFlightFixtureResult {
        guard flightDepth == 2 || flightDepth == 3 else {
            throw RunnerError.commandBufferFailed("multi-flight depth must be 2 or 3")
        }
        guard frames.count >= flightDepth else {
            throw RunnerError.insufficientFrames(
                id: fixture.id,
                count: frames.count,
                required: flightDepth
            )
        }
        guard !frames.isEmpty else {
            throw RunnerError.insufficientFrames(
                id: fixture.id,
                count: 0,
                required: fixture.minimumFrames
            )
        }
        let firstPixelBuffer = try unwrapFirstPixelBuffer(frames)
        let inputFormat = try Self.actualInputFormat(for: firstPixelBuffer)
        let inputLevels = try inputLuminanceLevelCount(
            frames: frames,
            inputFormat: inputFormat
        )
        let nearBlackInputSamples: [Float]?
        if let region = fixture.precisionRegion {
            nearBlackInputSamples = try inputLuminanceSamples(
                frames: frames,
                inputFormat: inputFormat,
                region: region
            )
        } else {
            nearBlackInputSamples = nil
        }

        let serialNearest = try await runSerialModeForMultiFlight(
            fixture: fixture,
            frames: frames,
            inputFormat: inputFormat,
            inputLevels: inputLevels,
            nearBlackInputSamples: nearBlackInputSamples,
            mode: .nearest
        )
        let serialCandidate = try await runSerialModeForMultiFlight(
            fixture: fixture,
            frames: frames,
            inputFormat: inputFormat,
            inputLevels: inputLevels,
            nearBlackInputSamples: nearBlackInputSamples,
            mode: .sitingAwareBilinear
        )

        let nearest = try runMultiFlightMode(
            fixture: fixture,
            frames: frames,
            inputFormat: inputFormat,
            inputLevels: inputLevels,
            nearBlackInputSamples: nearBlackInputSamples,
            mode: .nearest,
            flightDepth: flightDepth,
            serial: serialNearest
        )
        let candidate = try runMultiFlightMode(
            fixture: fixture,
            frames: frames,
            inputFormat: inputFormat,
            inputLevels: inputLevels,
            nearBlackInputSamples: nearBlackInputSamples,
            mode: .sitingAwareBilinear,
            flightDepth: flightDepth,
            serial: serialCandidate
        )
        let modes = [nearest, candidate]
        let failures = modes.flatMap { $0.result.failures }
        return RealMediaMultiFlightFixtureResult(
            manifest: fixture,
            id: fixture.id,
            flightDepth: flightDepth,
            modes: modes,
            passed: failures.isEmpty,
            failures: failures
        )
    }

    private func runMultiFlightMode(
        fixture: RealMediaRegressionFixture,
        frames: [DecodedFrame],
        inputFormat: HDRInputPixelFormat,
        inputLevels: Int,
        nearBlackInputSamples: [Float]?,
        mode: RegressionMode,
        flightDepth: Int,
        serial: (result: RegressionModeResult, frames: [RegressionFrameOutput])
    ) throws -> RealMediaMultiFlightModeResult {
        let firstPixelBuffer = try unwrapFirstPixelBuffer(frames)
        let resolvedColor = try HDRColorMetadataResolver.resolve(
            pixelBuffer: firstPixelBuffer,
            fallbackPolicy: .requireMetadata
        )
        var failures = validateMetadata(
            fixture: fixture,
            resolvedColor: resolvedColor,
            actualInputFormat: inputFormat
        )
        let timestamps = frames.map { $0.presentationTime.seconds }
        failures.append(contentsOf: validateTimestamps(timestamps, fixture: fixture))

        var configuration = HDRConfiguration.calibratedV4
        configuration.chromaReconstructionMode = mode == .nearest
            ? .nearest
            : .sitingAwareBilinear
        let processor = try HDRProcessor(device: device, configuration: configuration)
        processor.temporalTraceEnabled = true
        let renderer = try HDRPresentationRenderer(device: device, colorPixelFormat: .rgba16Float)
        let width = CVPixelBufferGetWidth(firstPixelBuffer)
        let height = CVPixelBufferGetHeight(firstPixelBuffer)
        let collector = RealMediaMultiFlightCompletionCollector()
        logMultiFlightProgress("resources-ready id=\(fixture.id) depth=\(flightDepth)")
        var pending: [RealMediaPendingFrame] = []
        var completedFrames: [RealMediaCompletedFrame] = []
        var submittedFrameIndices: [Int] = []
        var submittedSequences: [UInt64] = []
        var submissionGenerations: [UInt64] = []
        var maxObservedInFlight = 0
        var maxPending = 0
        var submittedCount = 0

        func retireOldest() throws {
            guard !pending.isEmpty else { return }
            var retired: RealMediaPendingFrame? = pending.removeFirst()
            defer { retired = nil }
            guard let value = retired else { return }
            logMultiFlightProgress(
                "retire-start id=\(fixture.id) depth=\(flightDepth) frame=\(value.frameIndex)"
            )
            if let completionSignal = value.completionSignal {
                guard completionSignal.wait(timeout: .now() + 60) == .success else {
                    throw RunnerError.commandBufferFailed(
                        "timed out waiting for completion handler"
                    )
                }
            } else {
                value.commandBuffer.waitUntilCompleted()
            }
            logMultiFlightProgress(
                "retire-complete id=\(fixture.id) depth=\(flightDepth) frame=\(value.frameIndex)"
            )
            completedFrames.append(try completePendingFrame(value))
        }

        for (index, decoded) in frames.enumerated() {
            while pending.count >= flightDepth {
                try retireOldest()
            }

            let value = try makePendingFrame(
                decoded,
                index: index,
                width: width,
                height: height,
                processor: processor,
                renderer: renderer,
                schedulingWorkBytes: 0,
                completionSignal: DispatchSemaphore(value: 0)
            )
            logMultiFlightProgress("frame-encoded id=\(fixture.id) depth=\(flightDepth) frame=\(index)")
            let frameIndex = value.frameIndex
            let generation = value.generation
            let submissionSequence = value.submissionSequence
            let completionSignal = value.completionSignal
            value.commandBuffer.addCompletedHandler { commandBuffer in
                collector.record(
                    frameIndex: frameIndex,
                    generation: generation,
                    submissionSequence: submissionSequence,
                    commandBuffer: commandBuffer
                )
                completionSignal?.signal()
            }
            value.commandBuffer.commit()
            logMultiFlightProgress("frame-committed id=\(fixture.id) depth=\(flightDepth) frame=\(index)")
            pending.append(value)
            submittedCount += 1
            submittedFrameIndices.append(value.frameIndex)
            submittedSequences.append(value.submissionSequence)
            submissionGenerations.append(value.generation)
            maxPending = max(maxPending, pending.count)
            // The first batch carries test-only GPU work until every
            // configured flight has been committed. Therefore this count
            // represents command buffers that are genuinely submitted and
            // not yet complete, rather than only a software queue depth.
            maxObservedInFlight = max(
                maxObservedInFlight,
                submittedCount - collector.count
            )
        }
        while !pending.isEmpty {
            try retireOldest()
        }
        let completionEvents = collector.events
        let completedFramesByIndex = completedFrames.sorted { $0.frameIndex < $1.frameIndex }
        let frameExecutions = completedFramesByIndex.map {
            FrameExecution(
                output: $0.output,
                gpuMilliseconds: $0.gpuMilliseconds,
                cpuMilliseconds: $0.cpuMilliseconds
            )
        }
        let output = outputSummary(
            inputLevels: inputLevels,
            frames: frameExecutions.map(\.output),
            nearBlackInputSamples: nearBlackInputSamples,
            precisionRegion: fixture.precisionRegion,
            bitDepth: inputFormat.bitDepth,
            width: width,
            height: height
        )
        let timing = timingSummary(
            timestamps: timestamps,
            frameExecutions: frameExecutions
        )
        failures.append(contentsOf: validateRuntime(
            fixture: fixture,
            processor: processor,
            frameCount: frames.count,
            output: output,
            timing: timing
        ))
        failures.append(contentsOf: validateMultiFlightEvidence(
            fixture: fixture,
            frames: frames,
            processor: processor,
            flightDepth: flightDepth,
            submittedFrameIndices: submittedFrameIndices,
            submittedSequences: submittedSequences,
            submissionGenerations: submissionGenerations,
            completionEvents: completionEvents,
            readbackFrameIndices: completedFrames.map(\.frameIndex),
            maxObservedInFlight: maxObservedInFlight,
            maxPending: maxPending
        ))
        if !serial.result.failures.isEmpty {
            failures.append(
                "serial control \(mode.rawValue) failed: " +
                    serial.result.failures.joined(separator: "; ")
            )
        }

        let completedOutputs = completedFramesByIndex.map(\.output)
        let deltas = zip(serial.frames, completedOutputs).flatMap { lhs, rhs in
            zip(lhs.luminance, rhs.luminance).map { abs(Double($1 - $0)) }
        }
        let serialParity = RealMediaMultiFlightSerialParity(
            contract: "causal-latency-aware; final sequence is gated, pixel bit-exactness is not required",
            meanAbsoluteLuminanceDelta: deltas.isEmpty
                ? 0
                : deltas.reduce(0, +) / Double(deltas.count),
            p95AbsoluteLuminanceDelta: percentile(deltas, fraction: 0.95),
            maximumAbsoluteLuminanceDelta: deltas.max() ?? 0,
            finalAdaptiveSequenceMatches: serial.result.adaptiveCommittedSequence ==
                processor.lastAdaptiveCommittedSequence
        )
        if !serialParity.finalAdaptiveSequenceMatches {
            failures.append("serial and multi-flight final adaptive sequences differ")
        }

        let metadata = serial.result.metadata
        let result = RegressionModeResult(
            mode: mode,
            metadata: metadata,
            frameCount: frames.count,
            timestamps: timestamps,
            timing: timing,
            output: output,
            gpuCompletedSequence: processor.lastGPUCompletedSequence,
            adaptiveCommittedSequence: processor.lastAdaptiveCommittedSequence,
            traceCount: processor.temporalCompletionTrace.count,
            outputTextureAllocations: processor.runtimeMetrics.outputTextureAllocations,
            passed: failures.isEmpty,
            failures: failures
        )
        return RealMediaMultiFlightModeResult(
            mode: mode,
            flightDepth: flightDepth,
            result: result,
            submittedFrameIndices: submittedFrameIndices,
            submittedSequences: submittedSequences,
            submissionGenerations: submissionGenerations,
            completionSequences: completionEvents.map(\.submissionSequence),
            completionEvents: completionEvents,
            readbackFrameIndices: completedFrames.map(\.frameIndex),
            maxObservedInFlight: maxObservedInFlight,
            maxPending: maxPending,
            maxSimultaneousLeases: maxPending,
            textureAllocations: processor.runtimeMetrics.outputTextureAllocations,
            temporalEstimateBufferAllocations: processor.runtimeMetrics.temporalEstimateBufferAllocations,
            serialParity: serialParity
        )
    }

    private func validateMultiFlightEvidence(
        fixture: RealMediaRegressionFixture,
        frames: [DecodedFrame],
        processor: HDRProcessor,
        flightDepth: Int,
        submittedFrameIndices: [Int],
        submittedSequences: [UInt64],
        submissionGenerations: [UInt64],
        completionEvents: [RealMediaMultiFlightCompletionEvidence],
        readbackFrameIndices: [Int],
        maxObservedInFlight: Int,
        maxPending: Int
    ) -> [String] {
        var failures: [String] = []
        let expectedIndices = Array(0..<frames.count)
        let expectedSequences = Array(1...UInt64(frames.count))
        if submittedFrameIndices != expectedIndices {
            failures.append("submission frame identities are not ordered or complete")
        }
        if submittedSequences != expectedSequences {
            failures.append("submission sequences are not contiguous from one")
        }
        if submissionGenerations.contains(where: { $0 != submissionGenerations.first }) {
            failures.append("submission generations changed during uninterrupted run")
        }
        if maxPending > flightDepth {
            failures.append("pending queue exceeded configured depth")
        }
        if maxObservedInFlight < flightDepth {
            failures.append(
                "actual overlap reached \(maxObservedInFlight); \(flightDepth) required"
            )
        }
        if completionEvents.count != frames.count {
            failures.append(
                "completion evidence has \(completionEvents.count) events for \(frames.count) frames"
            )
        }
        let completionFrameIndices = completionEvents.map(\.frameIndex).sorted()
        if completionFrameIndices != expectedIndices {
            failures.append("completion frame identities are not complete")
        }
        let completionSequences = completionEvents.map(\.submissionSequence).sorted()
        if completionSequences != expectedSequences {
            failures.append("completion sequences are not complete")
        }
        if let expectedGeneration = submissionGenerations.first,
           completionEvents.contains(where: { $0.generation != expectedGeneration }) {
            failures.append("completion generation differs from submission generation")
        }
        if completionEvents.contains(where: { !$0.completed }) {
            failures.append("one or more multi-flight command buffers did not complete")
        }
        let identities = completionEvents.map { "\($0.generation):\($0.submissionSequence)" }
        if Set(identities).count != identities.count {
            failures.append("completion evidence contains duplicate frame identities")
        }
        if readbackFrameIndices != expectedIndices {
            failures.append("readback frame identities are not retired in submission order")
        }
        if processor.lastAdaptiveCommittedSequence > processor.lastGPUCompletedSequence {
            failures.append("adaptive sequence is ahead of GPU completion ledger")
        }
        if processor.lastAdaptiveCommittedSequence != UInt64(frames.count) {
            failures.append("final adaptive sequence did not converge to final submission")
        }
        let runtimeMetrics = processor.runtimeMetrics
        if runtimeMetrics.outputTextureAllocations > 3 {
            failures.append(
                "output texture allocations exceeded the three-slot pool: " +
                    "\(runtimeMetrics.outputTextureAllocations)"
            )
        }
        if runtimeMetrics.temporalEstimateBufferAllocations > 3 {
            failures.append(
                "temporal estimate allocations exceeded the three-slot pool: " +
                    "\(runtimeMetrics.temporalEstimateBufferAllocations)"
            )
        }

        let submissionTraces = processor.temporalSubmissionTrace
        for trace in submissionTraces {
            if trace.temporalStateVersionConsumed >= trace.submissionSequence {
                failures.append(
                    "submission \(trace.submissionSequence) consumed future temporal state"
                )
            }
            if trace.sceneStateVersionConsumed >= trace.submissionSequence {
                failures.append(
                    "submission \(trace.submissionSequence) consumed future scene state"
                )
            }
        }
        let completionTraces = processor.temporalCompletionTrace
        if completionTraces.contains(where: {
            $0.gpuCompletionSequence != $0.adaptiveCommittedSequence ||
                $0.temporalStateVersionProduced != $0.adaptiveCommittedSequence ||
                $0.sceneStateVersionProduced != $0.adaptiveCommittedSequence
        }) {
            failures.append("adaptive transaction invariant failed in completion trace")
        }
        return failures
    }
}
