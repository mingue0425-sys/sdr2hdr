@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import HDRCore
import Metal
import QuartzCore
import HDRPlayerKit

@MainActor
struct RealMediaRegressionRunner {
    // External media may be 4K or larger. Keep diagnostic arrays bounded for
    // the external corpus while retaining the full deterministic fixture path.
    private static let externalDiagnosticSampleLimit = 65_536

    struct DecodedFrame {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
    }

    private struct FrameExecution {
        let output: RegressionFrameOutput
        let gpuMilliseconds: Double
        let cpuMilliseconds: Double
    }

    private struct ModeExecution {
        let result: RegressionModeResult
        let frames: [RegressionFrameOutput]
    }

    enum RunnerError: Error, LocalizedError {
        case playerItemNotReady(String)
        case insufficientFrames(id: String, count: Int, required: Int)
        case unsupportedPixelFormat(String)
        case missingDevice
        case missingTexture
        case commandBufferFailed(String)
        case invalidPrecisionRegion

        var errorDescription: String? {
            switch self {
            case .playerItemNotReady(let reason):
                return "AVPlayerItem did not become ready: \(reason)"
            case .insufficientFrames(let id, let count, let required):
                return "\(id) decoded \(count) frames; \(required) required"
            case .unsupportedPixelFormat(let format):
                return "unsupported decoded pixel format: \(format)"
            case .missingDevice:
                return "Metal device unavailable"
            case .missingTexture:
                return "Metal texture allocation failed"
            case .commandBufferFailed(let reason):
                return "Metal command buffer failed: \(reason)"
            case .invalidPrecisionRegion:
                return "precision region is outside the decoded luma plane"
            }
        }
    }

    private let manifest: RealMediaRegressionManifest
    private let gates: RegressionGates
    private let fixtureDirectory: URL
    private let device: MTLDevice

    init(
        manifest: RealMediaRegressionManifest,
        gates: RegressionGates,
        fixtureDirectory: URL,
        device: MTLDevice
    ) {
        self.manifest = manifest
        self.gates = gates
        self.fixtureDirectory = fixtureDirectory
        self.device = device
    }

    func run(_ fixture: RealMediaRegressionFixture) async throws -> RealMediaRegressionFixtureResult {
        let fixtureURL = fixtureDirectory.appendingPathComponent("\(fixture.id).mp4")
        let unsupportedMarker = fixtureDirectory.appendingPathComponent("\(fixture.id).UNSUPPORTED")
        if FileManager.default.fileExists(atPath: unsupportedMarker.path) {
            let reason = try? String(contentsOf: unsupportedMarker, encoding: .utf8)
            return RealMediaRegressionFixtureResult(
                manifest: fixture,
                id: fixture.id,
                status: "skipped",
                skipReason: reason?.trimmingCharacters(in: .whitespacesAndNewlines),
                nearest: nil,
                candidate: nil,
                comparison: nil
            )
        }
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw RunnerError.insufficientFrames(id: fixture.id, count: 0, required: fixture.minimumFrames)
        }

        let asset = AVURLAsset(url: fixtureURL)
        guard try await asset.load(.isPlayable) else {
            throw RunnerError.playerItemNotReady("asset is not playable")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1 else {
            throw RunnerError.playerItemNotReady("expected one video track, found \(tracks.count)")
        }
        let frames = try await decodeFrames(asset: asset, fixture: fixture)
        let inputLevels = try inputLuminanceLevelCount(frames: frames, bitDepth: fixture.sourceBitDepth)
        let nearBlackInputSamples: [Float]?
        if let region = fixture.precisionRegion {
            nearBlackInputSamples = try inputLuminanceSamples(
                frames: frames,
                bitDepth: fixture.sourceBitDepth,
                region: region
            )
        } else {
            nearBlackInputSamples = nil
        }

        let nearest = try await runMode(
            fixture: fixture,
            frames: frames,
            inputLevels: inputLevels,
            nearBlackInputSamples: nearBlackInputSamples,
            mode: .nearest
        )
        let candidate = try await runMode(
            fixture: fixture,
            frames: frames,
            inputLevels: inputLevels,
            nearBlackInputSamples: nearBlackInputSamples,
            mode: .sitingAwareBilinear
        )
        let comparison = compare(nearest: nearest, candidate: candidate)
        let failures = nearest.result.failures + candidate.result.failures
        return RealMediaRegressionFixtureResult(
            manifest: fixture,
            id: fixture.id,
            status: failures.isEmpty ? "pass" : "fail",
            skipReason: nil,
            nearest: nearest.result,
            candidate: candidate.result,
            comparison: comparison
        )
    }

    private func decodeFrames(
        asset: AVAsset,
        fixture: RealMediaRegressionFixture,
        startTime: Double = 0,
        duration: Double? = nil,
        precision: HDRDecodePrecision? = nil
    ) async throws -> [DecodedFrame] {
        let item = AVPlayerItem(asset: asset)
        let output = HDRVideoOutputConfiguration.makeVideoOutput(
            precision: precision ?? fixture.decodePrecision,
            range: fixture.range.decodeRange
        )
        output.suppressesPlayerRendering = true
        item.add(output)

        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true

        let readyDeadline = Date().addingTimeInterval(8)
        while item.status == .unknown && Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard item.status == .readyToPlay else {
            throw RunnerError.playerItemNotReady(item.error?.localizedDescription ?? "unknown status")
        }

        if startTime > 0 {
            let target = CMTime(seconds: startTime, preferredTimescale: 600)
            await withCheckedContinuation { continuation in
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    continuation.resume()
                }
            }
        }
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.01)
        player.play()

        var frames: [DecodedFrame] = []
        let deadline = Date().addingTimeInterval(15)
        while frames.count < max(fixture.minimumFrames, gates.minimumDecodedFrames) && Date() < deadline {
            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            if itemTime.isNumeric && output.hasNewPixelBuffer(forItemTime: itemTime) {
                var displayTime = CMTime.invalid
                if let pixelBuffer = output.copyPixelBuffer(
                    forItemTime: itemTime,
                    itemTimeForDisplay: &displayTime
                ), displayTime.isNumeric {
                    let isNew = frames.last.map {
                        CMTimeCompare($0.presentationTime, displayTime) != 0
                    } ?? true
                    if isNew {
                        frames.append(DecodedFrame(pixelBuffer: pixelBuffer, presentationTime: displayTime))
                    }
                }
            }
            if let duration, frames.count >= fixture.minimumFrames,
               itemTime.isNumeric, itemTime.seconds >= startTime + duration {
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        player.pause()
        guard frames.count >= fixture.minimumFrames else {
            throw RunnerError.insufficientFrames(
                id: fixture.id,
                count: frames.count,
                required: fixture.minimumFrames
            )
        }
        return frames
    }

    private func runMode(
        fixture: RealMediaRegressionFixture,
        frames: [DecodedFrame],
        inputLevels: Int,
        nearBlackInputSamples: [Float]?,
        mode: RegressionMode,
        validateFixtureMetadata: Bool = true,
        enforcePrecisionGates: Bool = true,
        diagnosticLuminanceSampleLimit: Int? = nil
    ) async throws -> ModeExecution {
        let firstPixelBuffer = try unwrapFirstPixelBuffer(frames)
        let resolvedColor = try HDRColorMetadataResolver.resolve(
            pixelBuffer: firstPixelBuffer,
            fallbackPolicy: .requireMetadata
        )
        var failures = validateFixtureMetadata ?
            validateMetadata(fixture: fixture, resolvedColor: resolvedColor) : []
        let timestamps = frames.map { $0.presentationTime.seconds }
        failures.append(contentsOf: validateTimestamps(timestamps, fixture: fixture))

        let inputFormat = resolvedColor.pixelFormat
        var configuration = HDRConfiguration.calibratedV4
        configuration.chromaReconstructionMode = mode == .nearest ? .nearest : .sitingAwareBilinear
        let processor = try HDRProcessor(device: device, configuration: configuration)
        processor.temporalTraceEnabled = true
        let renderer = try HDRPresentationRenderer(device: device, colorPixelFormat: .rgba16Float)
        let width = CVPixelBufferGetWidth(firstPixelBuffer)
        let height = CVPixelBufferGetHeight(firstPixelBuffer)

        var frameExecutions: [FrameExecution] = []
        frameExecutions.reserveCapacity(frames.count)
        for (index, frame) in frames.enumerated() {
            frameExecutions.append(try processAndPresent(
                frame,
                index: index,
                width: width,
                height: height,
                processor: processor,
                renderer: renderer,
                luminanceSampleLimit: diagnosticLuminanceSampleLimit
            ))
        }

        let timing = timingSummary(timestamps: timestamps, frameExecutions: frameExecutions)
        let output = outputSummary(
            inputLevels: inputLevels,
            frames: frameExecutions.map(\.output),
            nearBlackInputSamples: nearBlackInputSamples,
            precisionRegion: fixture.precisionRegion,
            bitDepth: fixture.sourceBitDepth,
            width: width,
            height: height
        )
        failures.append(contentsOf: validateRuntime(
            fixture: fixture,
            processor: processor,
            frameCount: frames.count,
            output: output,
            timing: timing,
            enforcePrecisionGates: enforcePrecisionGates
        ))

        let metadata = RegressionMetadataSummary(
            pixelFormat: inputFormat.diagnosticName,
            pixelFormatFamily: inputFormat.isP010 ? .p010 : .nv12,
            bitDepth: inputFormat.bitDepth,
            range: inputFormat.isFullRange ? .full : .video,
            transfer: transferName(resolvedColor.metadata.transferFunction),
            matrix: resolvedColor.metadata.yCbCrMatrix.rawValue,
            topChromaLocation: attachmentName(
                CVBufferCopyAttachment(firstPixelBuffer, kCVImageBufferChromaLocationTopFieldKey, nil)
            ),
            bottomChromaLocation: attachmentName(
                CVBufferCopyAttachment(firstPixelBuffer, kCVImageBufferChromaLocationBottomFieldKey, nil)
            ),
            resolvedChromaSiting: resolvedColor.chromaGeometry.resolvedSiting.rawValue
        )
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
        return ModeExecution(result: result, frames: frameExecutions.map(\.output))
    }

    private func processAndPresent(
        _ decoded: DecodedFrame,
        index: Int,
        width: Int,
        height: Int,
        processor: HDRProcessor,
        renderer: HDRPresentationRenderer,
        luminanceSampleLimit: Int? = nil
    ) throws -> FrameExecution {
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
        guard let readback = device.makeBuffer(length: readbackLength, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
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
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed, commandBuffer.error == nil else {
            throw RunnerError.commandBufferFailed(commandBuffer.error?.localizedDescription ?? "unknown status")
        }

        let values = readback.contents().bindMemory(to: UInt16.self, capacity: width * height * 4)
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
                if red.isNaN { nanCount += 1 }
                else if red.isInfinite { infinityCount += 1 }
                else {
                    finiteSampleCount += 1
                    if red < 0 { negativeCount += 1 }
                    minimumValue = min(minimumValue, Double(red))
                    maximumValue = max(maximumValue, Double(red))
                }
                if green.isNaN { nanCount += 1 }
                else if green.isInfinite { infinityCount += 1 }
                else {
                    finiteSampleCount += 1
                    if green < 0 { negativeCount += 1 }
                    minimumValue = min(minimumValue, Double(green))
                    maximumValue = max(maximumValue, Double(green))
                }
                if blue.isNaN { nanCount += 1 }
                else if blue.isInfinite { infinityCount += 1 }
                else {
                    finiteSampleCount += 1
                    if blue < 0 { negativeCount += 1 }
                    minimumValue = min(minimumValue, Double(blue))
                    maximumValue = max(maximumValue, Double(blue))
                }
                if alpha.isNaN { nanCount += 1 }
                else if alpha.isInfinite { infinityCount += 1 }
                else {
                    finiteSampleCount += 1
                    if alpha < 0 { negativeCount += 1 }
                    minimumValue = min(minimumValue, Double(alpha))
                    maximumValue = max(maximumValue, Double(alpha))
                }
                let pixelLuminance = 0.2627 * red + 0.6780 * green + 0.0593 * blue
                luminance.append(pixelLuminance)
                luminanceSum += Double(pixelLuminance)
                if max(red, max(green, blue)) > 0.0001 { nonZeroSampleCount += 1 }
                if max(red, max(green, blue)) >= 1.5 { clippingPixels += 1 }
            }
        }

        let gpuMilliseconds: Double
        if commandBuffer.gpuStartTime > 0, commandBuffer.gpuEndTime >= commandBuffer.gpuStartTime {
            gpuMilliseconds = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000
        } else {
            gpuMilliseconds = 0
        }
        let cpuMilliseconds = (CACurrentMediaTime() - cpuStart) * 1000
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
        return FrameExecution(output: output, gpuMilliseconds: gpuMilliseconds, cpuMilliseconds: cpuMilliseconds)
    }

    private func validateMetadata(
        fixture: RealMediaRegressionFixture,
        resolvedColor: ResolvedColorDescription
    ) -> [String] {
        var failures: [String] = []
        let inputFormat = resolvedColor.pixelFormat
        if inputFormat.bitDepth != fixture.expectedDecodeBitDepth {
            failures.append("PRECISION_DOWNGRADE expected=\(fixture.expectedDecodeBitDepth) actual=\(inputFormat.bitDepth)")
        }
        let family: RegressionPixelFormatFamily = inputFormat.isP010 ? .p010 : .nv12
        if family != fixture.expectedPixelFormatFamily {
            failures.append("pixel format family expected=\(fixture.expectedPixelFormatFamily.rawValue) actual=\(family.rawValue)")
        }
        let actualRange: RegressionRange = inputFormat.isFullRange ? .full : .video
        if actualRange != fixture.range {
            failures.append("range expected=\(fixture.range.rawValue) actual=\(actualRange.rawValue)")
        }
        let transferMatchesManifest: Bool
        switch fixture.expectedTransfer {
        case .bt709:
            transferMatchesManifest = resolvedColor.metadata.transferFunction == .bt709
        }
        if !transferMatchesManifest {
            failures.append("transfer metadata is not BT.709")
        }
        let matrixMatchesManifest: Bool
        switch fixture.expectedMatrix {
        case .bt709:
            matrixMatchesManifest = resolvedColor.metadata.yCbCrMatrix == .bt709
        }
        if !matrixMatchesManifest {
            failures.append("matrix metadata is not BT.709")
        }
        if fixture.chromaSiting.required && resolvedColor.chromaGeometry.resolvedSiting == .unspecified {
            failures.append("chroma metadata was required but resolved to unspecified")
        }
        if let allowed = fixture.chromaSiting.allowed,
           !allowed.contains(resolvedColor.chromaGeometry.resolvedSiting) {
            failures.append("chroma siting \(resolvedColor.chromaGeometry.resolvedSiting.rawValue) is outside the manifest allowed set")
        }
        return failures
    }

    private func validateTimestamps(
        _ timestamps: [Double],
        fixture: RealMediaRegressionFixture
    ) -> [String] {
        var failures: [String] = []
        guard timestamps.allSatisfy(\.isFinite) else {
            return ["timestamp contains non-finite value"]
        }
        let deltas = zip(timestamps, timestamps.dropFirst()).map { $1 - $0 }
        if deltas.contains(where: { $0 <= 0 }) {
            failures.append("decoded presentation timestamps are not strictly increasing")
        }
        if timestamps.contains(where: { $0 < -gates.maximumTimestampBackwardsSeconds }) {
            failures.append("decoded presentation timestamp is unexpectedly negative")
        }
        let distinct = distinctCount(deltas, tolerance: 0.0005)
        if distinct < fixture.minimumDistinctFrameDurations {
            failures.append("timing has \(distinct) distinct frame durations; \(fixture.minimumDistinctFrameDurations) required")
        }
        if fixture.timing == .cfr, let first = deltas.first {
            let variation = deltas.map { abs($0 - first) }.max() ?? 0
            if variation > gates.maximumExpectedCFRDeltaVariationSeconds {
                failures.append("CFR frame duration variation \(variation) exceeds gate")
            }
        }
        return failures
    }

    private func validateRuntime(
        fixture: RealMediaRegressionFixture,
        processor: HDRProcessor,
        frameCount: Int,
        output: RegressionOutputSummary,
        timing: RegressionTimingSummary,
        enforcePrecisionGates: Bool = true
    ) -> [String] {
        var failures: [String] = []
        if processor.lastGPUCompletedSequence < UInt64(frameCount) {
            failures.append("GPU completion sequence did not reach processed frame count")
        }
        if processor.lastAdaptiveCommittedSequence < UInt64(frameCount) {
            failures.append("adaptive committed sequence did not reach processed frame count")
        }
        if output.nanCount > 0 { failures.append("presentation output contains NaN") }
        if output.infinityCount > 0 { failures.append("presentation output contains infinity") }
        if output.negativeCount > 0 { failures.append("presentation output contains negative values") }
        if output.nonZeroSampleCount == 0 { failures.append("presentation output is entirely zero") }
        if let profile = gates.profiles[fixture.gateProfile],
           output.maximumClippingFraction > profile.maximumClippingFraction {
            failures.append(
                "unexpected clipping fraction \(output.maximumClippingFraction) exceeds " +
                    "\(fixture.gateProfile) gate \(profile.maximumClippingFraction)"
            )
        } else if gates.profiles[fixture.gateProfile] == nil {
            failures.append("missing clipping gate profile \(fixture.gateProfile)")
        }
        if enforcePrecisionGates && fixture.staticContent {
            if output.staticFlickerP95 > gates.maximumStaticFlickerP95 {
                failures.append("static fixture flicker p95 \(output.staticFlickerP95) exceeds gate")
            }
            if output.staticFlickerMaximum > gates.maximumStaticFlickerMaximum {
                failures.append("static fixture flicker maximum \(output.staticFlickerMaximum) exceeds gate")
            }
        }
        if enforcePrecisionGates && fixture.expectedPixelFormatFamily == .p010,
           output.inputDistinguishableLuminanceLevels < max(
               fixture.minimumInputLuminanceLevels,
               gates.minimumP010InputLuminanceLevels
           ) {
            failures.append("P010 input precision levels \(output.inputDistinguishableLuminanceLevels) below gate")
        }
        if enforcePrecisionGates && fixture.expectedPixelFormatFamily == .p010,
           output.outputDistinguishableLuminanceLevels < gates.minimumP010OutputLuminanceLevels {
            failures.append("P010 output precision levels \(output.outputDistinguishableLuminanceLevels) below gate")
        }
        if enforcePrecisionGates, let minimum = fixture.minimumNearBlackOutputLevels {
            guard let actual = output.nearBlackOutputLuminanceLevels else {
                failures.append("near-black precision region did not produce output samples")
                return failures
            }
            if actual < minimum {
                failures.append("near-black output levels \(actual) below gate \(minimum)")
            }
            let orderingViolations = output.nearBlackOrderingViolations ?? Int.max
            if orderingViolations > gates.maximumNearBlackOrderingViolations {
                failures.append(
                    "near-black output ordering violations \(orderingViolations) exceed gate " +
                        "\(gates.maximumNearBlackOrderingViolations)"
                )
            }
        }
        let traces = processor.temporalCompletionTrace
        if traces.count < frameCount {
            failures.append("adaptive completion trace has \(traces.count) entries for \(frameCount) frames")
        }
        let sequenceMismatchCount = traces.reduce(into: 0) { count, trace in
            if trace.gpuCompletionSequence != trace.adaptiveCommittedSequence ||
                trace.temporalStateVersionProduced != trace.adaptiveCommittedSequence ||
                trace.sceneStateVersionProduced != trace.adaptiveCommittedSequence {
                count += 1
            }
        }
        if sequenceMismatchCount > Int(gates.maximumSequenceMismatch) {
            failures.append("adaptive completion trace contains \(sequenceMismatchCount) sequence mismatches")
        }
        if timing.frameDeltas.contains(where: { $0 <= 0 }) {
            failures.append("timing summary contains a non-positive frame delta")
        }
        return failures
    }

    private func outputSummary(
        inputLevels: Int,
        frames: [RegressionFrameOutput],
        nearBlackInputSamples: [Float]?,
        precisionRegion: RegressionRegion?,
        bitDepth: Int,
        width: Int,
        height: Int
    ) -> RegressionOutputSummary {
        let allLuminance = frames.flatMap(\.luminance)
        let outputLevels = clusterCount(allLuminance, tolerance: 1.0 / 4096.0)
        let frameDeltas = zip(frames, frames.dropFirst()).map { lhs, rhs in
            zip(lhs.luminance, rhs.luminance).map { abs(Double($1 - $0)) }
        }
        let allDeltas = frameDeltas.flatMap { $0 }
        let staticFlickerP95 = percentile(allDeltas, fraction: 0.95)
        let staticFlickerMaximum = allDeltas.max() ?? 0
        let nearBlackOutputSamples: [Float]?
        if let precisionRegion {
            nearBlackOutputSamples = frames.flatMap {
                samples(
                    in: $0.luminance,
                    width: width,
                    height: height,
                    region: precisionRegion
                )
            }
        } else {
            nearBlackOutputSamples = nil
        }
        let nearBlackInputLevels = nearBlackInputSamples.map {
            clusterCount($0, tolerance: bitDepth == 10 ? 0.5 / 1023 : 0.5 / 255)
        }
        let nearBlackOutputLevels = nearBlackOutputSamples.map {
            clusterCount($0, tolerance: 1.0 / 4096.0)
        }
        let nearBlackOrderingViolations: Int?
        if let nearBlackInputSamples, let nearBlackOutputSamples {
            nearBlackOrderingViolations = orderingViolations(
                input: nearBlackInputSamples,
                output: nearBlackOutputSamples,
                tolerance: 1.0 / 4096.0
            )
        } else {
            nearBlackOrderingViolations = nil
        }
        return RegressionOutputSummary(
            finiteSampleCount: frames.reduce(0) { $0 + $1.finiteSampleCount },
            nanCount: frames.reduce(0) { $0 + $1.nanCount },
            infinityCount: frames.reduce(0) { $0 + $1.infinityCount },
            negativeCount: frames.reduce(0) { $0 + $1.negativeCount },
            nonZeroSampleCount: frames.reduce(0) { $0 + $1.nonZeroSampleCount },
            minimumValue: frames.map(\.minimumValue).min() ?? 0,
            maximumValue: frames.map(\.maximumValue).max() ?? 0,
            maximumClippingFraction: frames.map(\.clippingFraction).max() ?? 0,
            inputDistinguishableLuminanceLevels: inputLevels,
            outputDistinguishableLuminanceLevels: outputLevels,
            nearBlackInputLuminanceLevels: nearBlackInputLevels,
            nearBlackOutputLuminanceLevels: nearBlackOutputLevels,
            nearBlackOrderingViolations: nearBlackOrderingViolations,
            staticFlickerP95: staticFlickerP95,
            staticFlickerMaximum: staticFlickerMaximum
        )
    }

    private func timingSummary(
        timestamps: [Double],
        frameExecutions: [FrameExecution]
    ) -> RegressionTimingSummary {
        let deltas = zip(timestamps, timestamps.dropFirst()).map { $1 - $0 }
        return RegressionTimingSummary(
            timestampStart: timestamps.first ?? 0,
            timestampEnd: timestamps.last ?? 0,
            frameDeltas: deltas,
            distinctFrameDeltaCount: distinctCount(deltas, tolerance: 0.0005),
            gpuMilliseconds: frameExecutions.map(\.gpuMilliseconds),
            cpuMilliseconds: frameExecutions.map(\.cpuMilliseconds)
        )
    }

    private func compare(
        nearest: ModeExecution,
        candidate: ModeExecution
    ) -> RegressionModeComparison {
        let deltas = zip(nearest.frames, candidate.frames).flatMap { lhs, rhs in
            zip(lhs.luminance, rhs.luminance).map { abs(Double($1 - $0)) }
        }
        return RegressionModeComparison(
            meanAbsoluteLuminanceDelta: deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count),
            p95AbsoluteLuminanceDelta: percentile(deltas, fraction: 0.95),
            maximumAbsoluteLuminanceDelta: deltas.max() ?? 0,
            clippingFractionDelta: candidate.result.output.maximumClippingFraction -
                nearest.result.output.maximumClippingFraction,
            gpuP95MillisecondsDelta: percentile(candidate.result.timing.gpuMilliseconds, fraction: 0.95) -
                percentile(nearest.result.timing.gpuMilliseconds, fraction: 0.95)
        )
    }

    private func inputLuminanceLevelCount(
        frames: [DecodedFrame],
        bitDepth: Int,
        maxSamples: Int? = nil
    ) throws -> Int {
        let samples = try inputLuminanceSamples(
            frames: frames,
            bitDepth: bitDepth,
            region: nil,
            maxSamples: maxSamples
        )
        return clusterCount(samples, tolerance: bitDepth == 10 ? 0.5 / 1023 : 0.5 / 255)
    }

    private func inputLuminanceSamples(
        frames: [DecodedFrame],
        bitDepth: Int,
        region: RegressionRegion?,
        maxSamples: Int? = nil
    ) throws -> [Float] {
        var samples: [Float] = []
        for frame in frames {
            let pixelBuffer = frame.pixelBuffer
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let selectedRegion = region ?? RegressionRegion(x: 0, y: 0, width: width, height: height)
            guard selectedRegion.isValid,
                  selectedRegion.x + selectedRegion.width <= width,
                  selectedRegion.y + selectedRegion.height <= height else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                throw RunnerError.invalidPrecisionRegion
            }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                continue
            }
            let sampleStride = samplingStride(
                width: selectedRegion.width,
                height: selectedRegion.height,
                maxSamples: maxSamples
            )
            let xEnd = selectedRegion.x + selectedRegion.width
            let yEnd = selectedRegion.y + selectedRegion.height
            if bitDepth == 10 {
                let pointer = base.assumingMemoryBound(to: UInt16.self)
                for y in stride(from: selectedRegion.y, to: yEnd, by: sampleStride) {
                    let row = pointer.advanced(by: y * rowBytes / MemoryLayout<UInt16>.stride)
                    for x in stride(from: selectedRegion.x, to: xEnd, by: sampleStride) {
                        samples.append(Float(row[x] >> 6) / 1023)
                    }
                }
            } else {
                let pointer = base.assumingMemoryBound(to: UInt8.self)
                for y in stride(from: selectedRegion.y, to: yEnd, by: sampleStride) {
                    let row = pointer.advanced(by: y * rowBytes)
                    for x in stride(from: selectedRegion.x, to: xEnd, by: sampleStride) {
                        samples.append(Float(row[x]) / 255)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        return samples
    }

    private func samplingStride(width: Int, height: Int, maxSamples: Int?) -> Int {
        guard let maxSamples, maxSamples > 0 else { return 1 }
        let sampleCount = max(width, 1) * max(height, 1)
        guard sampleCount > maxSamples else { return 1 }
        return max(1, Int(ceil(sqrt(Double(sampleCount) / Double(maxSamples)))))
    }

    private func samples(
        in values: [Float],
        width: Int,
        height: Int,
        region: RegressionRegion
    ) -> [Float] {
        guard region.isValid,
              region.x + region.width <= width,
              region.y + region.height <= height else { return [] }
        var selected: [Float] = []
        selected.reserveCapacity(region.width * region.height)
        for y in region.y..<(region.y + region.height) {
            let start = y * width + region.x
            selected.append(contentsOf: values[start..<(start + region.width)])
        }
        return selected
    }

    private func orderingViolations(
        input: [Float],
        output: [Float],
        tolerance: Float
    ) -> Int {
        guard input.count == output.count else { return Int.max }
        let pairs = zip(input, output)
            .filter { $0.0.isFinite && $0.1.isFinite }
            .sorted { lhs, rhs in lhs.0 < rhs.0 }
        var violations = 0
        var maximumOutput = -Float.infinity
        for (_, value) in pairs {
            if value + tolerance < maximumOutput { violations += 1 }
            maximumOutput = max(maximumOutput, value)
        }
        return violations
    }

    private func unwrapFirstPixelBuffer(_ frames: [DecodedFrame]) throws -> CVPixelBuffer {
        guard let first = frames.first?.pixelBuffer else {
            throw RunnerError.insufficientFrames(id: "unknown", count: 0, required: 1)
        }
        return first
    }

    private func attachmentName(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if CFEqual(value, kCVImageBufferChromaLocation_Center) { return "center" }
        if CFEqual(value, kCVImageBufferChromaLocation_Left) { return "left" }
        if CFEqual(value, kCVImageBufferChromaLocation_TopLeft) { return "topLeft" }
        if CFEqual(value, kCVImageBufferChromaLocation_Top) { return "top" }
        if CFEqual(value, kCVImageBufferChromaLocation_BottomLeft) { return "bottomLeft" }
        if CFEqual(value, kCVImageBufferChromaLocation_Bottom) { return "bottom" }
        if CFEqual(value, kCVImageBufferChromaLocation_DV420) { return "dv420" }
        return String(describing: value)
    }

    private func transferName(_ transfer: HDRTransferFunction) -> String {
        switch transfer {
        case .bt709: return "bt709"
        case .sRGB: return "sRGB"
        case .gamma(let value): return "gamma(\(value))"
        case .linear: return "linear"
        }
    }

    private func distinctCount(_ values: [Double], tolerance: Double) -> Int {
        var representatives: [Double] = []
        for value in values where value.isFinite {
            if !representatives.contains(where: { abs($0 - value) <= tolerance }) {
                representatives.append(value)
            }
        }
        return representatives.count
    }

    private func clusterCount(_ values: [Float], tolerance: Float) -> Int {
        let sorted = values.filter(\.isFinite).sorted()
        guard let first = sorted.first else { return 0 }
        var count = 1
        var representative = first
        for value in sorted.dropFirst() where value - representative > tolerance {
            count += 1
            representative = value
        }
        return count
    }

    private func percentile(_ values: [Double], fraction: Double) -> Double {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }

    func runExternal(
        source: ExternalRealMediaSource,
        fileURL: URL,
        probe: ExternalMediaProbe
    ) async throws -> ExternalMediaSourceResult {
        let asset = AVURLAsset(url: fileURL)
        guard try await asset.load(.isPlayable) else {
            throw RunnerError.playerItemNotReady("external asset is not playable")
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1 else {
            throw RunnerError.playerItemNotReady("external asset expected one video track, found \(tracks.count)")
        }
        guard let totalDuration = probe.duration else {
            throw ExternalMediaInspectionError.invalidProbe("duration is missing")
        }

        var windowResults: [ExternalMediaWindowResult] = []
        for window in source.windows {
            let resolved = try window.resolve(totalDuration: totalDuration)
            let fixture = externalFixture(source: source, probe: probe)
            let frames = try await decodeFrames(
                asset: asset,
                fixture: fixture,
                startTime: resolved.start,
                duration: resolved.duration,
                precision: externalPrecision(source: source)
            )
            let firstPixelBuffer = try unwrapFirstPixelBuffer(frames)
            let resolvedColor = try HDRColorMetadataResolver.resolve(
                pixelBuffer: firstPixelBuffer,
                fallbackPolicy: .requireMetadata
            )
            let metadataFailures = validateExternalMetadata(
                source: source,
                resolvedColor: resolvedColor
            )
            let inputLevels = try inputLuminanceLevelCount(
                frames: frames,
                bitDepth: resolvedColor.pixelFormat.bitDepth,
                maxSamples: Self.externalDiagnosticSampleLimit
            )
            let nearest = try await runMode(
                fixture: fixture,
                frames: frames,
                inputLevels: inputLevels,
                nearBlackInputSamples: nil,
                mode: .nearest,
                validateFixtureMetadata: false,
                enforcePrecisionGates: false,
                diagnosticLuminanceSampleLimit: Self.externalDiagnosticSampleLimit
            )
            let candidate = try await runMode(
                fixture: fixture,
                frames: frames,
                inputLevels: inputLevels,
                nearBlackInputSamples: nil,
                mode: .sitingAwareBilinear,
                validateFixtureMetadata: false,
                enforcePrecisionGates: false,
                diagnosticLuminanceSampleLimit: Self.externalDiagnosticSampleLimit
            )
            let nearestResult = addingFailures(metadataFailures, to: nearest.result)
            let candidateResult = addingFailures(metadataFailures, to: candidate.result)
            windowResults.append(
                ExternalMediaWindowResult(
                    window: window,
                    resolvedStart: resolved.start,
                    resolvedDuration: resolved.duration,
                    nearest: nearestResult,
                    candidate: candidateResult,
                    comparison: compare(nearest: nearest, candidate: candidate)
                )
            )
        }

        let failures = windowResults.flatMap { $0.nearest.failures + $0.candidate.failures }
        return ExternalMediaSourceResult(
            id: source.id,
            fileName: source.fileName,
            sha256: source.sha256,
            provenance: source.provenance,
            probe: probe,
            windows: windowResults,
            status: failures.isEmpty ? "pass" : "fail",
            failure: failures.isEmpty ? nil : failures.joined(separator: "; ")
        )
    }

    private func externalFixture(
        source: ExternalRealMediaSource,
        probe: ExternalMediaProbe
    ) -> RealMediaRegressionFixture {
        let bitDepth = source.expected.bitDepth ?? probe.bitDepth ?? 8
        let range = source.expected.range ?? probe.range ?? .video
        let timing = source.expected.timing ?? .cfr
        let frameRate = source.expected.frameRate ?? probe.averageFrameRate ?? 24
        let allowedSiting = source.expected.allowedChromaSiting
        return RealMediaRegressionFixture(
            id: source.id,
            codec: source.expected.codec ?? .h264,
            sourceBitDepth: bitDepth,
            expectedDecodeBitDepth: bitDepth,
            expectedPixelFormatFamily: bitDepth == 10 ? .p010 : .nv12,
            range: range,
            frameRate: frameRate,
            timing: timing,
            contentClass: .motion,
            profile: "external",
            expectedTransfer: .bt709,
            expectedMatrix: .bt709,
            chromaSiting: RegressionChromaSitingExpectation(
                required: allowedSiting != nil,
                allowed: allowedSiting
            ),
            gateProfile: "motion",
            minimumFrames: gates.minimumDecodedFrames,
            minimumDistinctFrameDurations: source.expected.minimumDistinctFrameDurations ??
                (timing == .vfr ? 2 : 1),
            staticContent: false,
            minimumInputLuminanceLevels: 1,
            precisionRegion: nil,
            minimumNearBlackOutputLevels: nil
        )
    }

    private func externalPrecision(source: ExternalRealMediaSource) -> HDRDecodePrecision {
        switch source.expected.bitDepth {
        case 10: return .tenBitPreferred
        case 8: return .eightBit
        default: return .automatic
        }
    }

    private func validateExternalMetadata(
        source: ExternalRealMediaSource,
        resolvedColor: ResolvedColorDescription
    ) -> [String] {
        var failures: [String] = []
        if let bitDepth = source.expected.bitDepth, resolvedColor.pixelFormat.bitDepth != bitDepth {
            failures.append("PRECISION_DOWNGRADE expected=\(bitDepth) actual=\(resolvedColor.pixelFormat.bitDepth)")
        }
        if let range = source.expected.range {
            let actual: RegressionRange = resolvedColor.pixelFormat.isFullRange ? .full : .video
            if actual != range { failures.append("range expected=\(range.rawValue) actual=\(actual.rawValue)") }
        }
        if let allowed = source.expected.allowedChromaSiting,
           !allowed.contains(resolvedColor.chromaGeometry.resolvedSiting) {
            failures.append(
                "chroma siting \(resolvedColor.chromaGeometry.resolvedSiting.rawValue) is outside external allow-list"
            )
        }
        return failures
    }

    private func addingFailures(
        _ additional: [String],
        to result: RegressionModeResult
    ) -> RegressionModeResult {
        let failures = result.failures + additional
        return RegressionModeResult(
            mode: result.mode,
            metadata: result.metadata,
            frameCount: result.frameCount,
            timestamps: result.timestamps,
            timing: result.timing,
            output: result.output,
            gpuCompletedSequence: result.gpuCompletedSequence,
            adaptiveCommittedSequence: result.adaptiveCommittedSequence,
            traceCount: result.traceCount,
            outputTextureAllocations: result.outputTextureAllocations,
            passed: failures.isEmpty,
            failures: failures
        )
    }
}
