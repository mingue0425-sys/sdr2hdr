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

        let nearest = try await runMode(
            fixture: fixture,
            frames: frames,
            inputLevels: inputLevels,
            mode: .nearest
        )
        let candidate = try await runMode(
            fixture: fixture,
            frames: frames,
            inputLevels: inputLevels,
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
        fixture: RealMediaRegressionFixture
    ) async throws -> [DecodedFrame] {
        let item = AVPlayerItem(asset: asset)
        let output = HDRVideoOutputConfiguration.makeVideoOutput(
            precision: fixture.decodePrecision,
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
        mode: RegressionMode
    ) async throws -> ModeExecution {
        let firstPixelBuffer = try unwrapFirstPixelBuffer(frames)
        let resolvedColor = try HDRColorMetadataResolver.resolve(
            pixelBuffer: firstPixelBuffer,
            fallbackPolicy: .requireMetadata
        )
        var failures = validateMetadata(fixture: fixture, resolvedColor: resolvedColor)
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
                renderer: renderer
            ))
        }

        let timing = timingSummary(timestamps: timestamps, frameExecutions: frameExecutions)
        let output = outputSummary(
            inputLevels: inputLevels,
            frames: frameExecutions.map(\.output)
        )
        failures.append(contentsOf: validateRuntime(
            fixture: fixture,
            processor: processor,
            frameCount: frames.count,
            output: output,
            timing: timing
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
        renderer: HDRPresentationRenderer
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
        var luminance: [Float] = []
        luminance.reserveCapacity(width * height)
        var clippingPixels = 0
        var luminanceSum = 0.0

        for pixel in 0..<(width * height) {
            let red = Float(Float16(bitPattern: values[pixel * 4]))
            let green = Float(Float16(bitPattern: values[pixel * 4 + 1]))
            let blue = Float(Float16(bitPattern: values[pixel * 4 + 2]))
            let alpha = Float(Float16(bitPattern: values[pixel * 4 + 3]))
            let components = [red, green, blue, alpha]
            for component in components {
                if component.isNaN { nanCount += 1 }
                else if component.isInfinite { infinityCount += 1 }
                else {
                    finiteSampleCount += 1
                    if component < 0 { negativeCount += 1 }
                    minimumValue = min(minimumValue, Double(component))
                    maximumValue = max(maximumValue, Double(component))
                }
            }
            let pixelLuminance = 0.2627 * red + 0.6780 * green + 0.0593 * blue
            luminance.append(pixelLuminance)
            luminanceSum += Double(pixelLuminance)
            if max(red, max(green, blue)) > 0.0001 { nonZeroSampleCount += 1 }
            if max(red, max(green, blue)) >= 1.5 { clippingPixels += 1 }
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
            meanLuminance: luminanceSum / Double(max(luminance.count, 1)),
            minimumValue: minimumValue.isFinite ? minimumValue : 0,
            maximumValue: maximumValue.isFinite ? maximumValue : 0,
            clippingFraction: Double(clippingPixels) / Double(max(width * height, 1)),
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
        timing: RegressionTimingSummary
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
        if output.maximumClippingFraction > gates.maximumUnexpectedClippingFraction {
            failures.append("unexpected clipping fraction \(output.maximumClippingFraction) exceeds gate")
        }
        if fixture.staticContent {
            if output.staticFlickerP95 > gates.maximumStaticFlickerP95 {
                failures.append("static fixture flicker p95 \(output.staticFlickerP95) exceeds gate")
            }
            if output.staticFlickerMaximum > gates.maximumStaticFlickerMaximum {
                failures.append("static fixture flicker maximum \(output.staticFlickerMaximum) exceeds gate")
            }
        }
        if fixture.expectedPixelFormatFamily == .p010,
           output.inputDistinguishableLuminanceLevels < max(
               fixture.minimumInputLuminanceLevels,
               gates.minimumP010InputLuminanceLevels
           ) {
            failures.append("P010 input precision levels \(output.inputDistinguishableLuminanceLevels) below gate")
        }
        if fixture.expectedPixelFormatFamily == .p010,
           output.outputDistinguishableLuminanceLevels < gates.minimumP010OutputLuminanceLevels {
            failures.append("P010 output precision levels \(output.outputDistinguishableLuminanceLevels) below gate")
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
        frames: [RegressionFrameOutput]
    ) -> RegressionOutputSummary {
        let allLuminance = frames.flatMap(\.luminance)
        let outputLevels = clusterCount(allLuminance, tolerance: 1.0 / 4096.0)
        let frameDeltas = zip(frames, frames.dropFirst()).map { lhs, rhs in
            zip(lhs.luminance, rhs.luminance).map { abs(Double($1 - $0)) }
        }
        let allDeltas = frameDeltas.flatMap { $0 }
        let staticFlickerP95 = percentile(allDeltas, fraction: 0.95)
        let staticFlickerMaximum = allDeltas.max() ?? 0
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
        bitDepth: Int
    ) throws -> Int {
        var samples: [Float] = []
        for frame in frames {
            let pixelBuffer = frame.pixelBuffer
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { continue }
            if bitDepth == 10 {
                let pointer = base.assumingMemoryBound(to: UInt16.self)
                for y in 0..<height {
                    let row = pointer.advanced(by: y * rowBytes / MemoryLayout<UInt16>.stride)
                    for x in 0..<width { samples.append(Float(row[x] >> 6) / 1023) }
                }
            } else {
                let pointer = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    let row = pointer.advanced(by: y * rowBytes)
                    for x in 0..<width { samples.append(Float(row[x]) / 255) }
                }
            }
        }
        return clusterCount(samples, tolerance: bitDepth == 10 ? 0.5 / 1023 : 0.5 / 255)
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
}
