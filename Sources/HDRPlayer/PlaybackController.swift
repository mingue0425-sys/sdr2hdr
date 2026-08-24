@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HDRCore
import Metal
@preconcurrency import QuartzCore

public enum HDRPlayerError: Error, LocalizedError {
    case fileNotFound(URL)
    case metalUnavailable
    case noVideoTrack(URL)
    case assetLoadFailed(String)
    case playerItemFailed(String)
    case processor(HDRProcessorError)
    case presentationShaderMissing
    case presentationShaderCompilationFailed(String)
    case presentationFunctionMissing
    case presentationPipelineCreationFailed(String)
    case presentationSamplerCreationFailed
    case displayLinkUnavailable
    case invalidPlaybackState(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url): return "video file not found: \(url.path)"
        case .metalUnavailable: return "Metal device unavailable"
        case .noVideoTrack(let url): return "no video track in \(url.path)"
        case .assetLoadFailed(let reason): return "asset load failed: \(reason)"
        case .playerItemFailed(let reason): return "AVPlayerItem failed: \(reason)"
        case .processor(let error): return "HDRProcessor: \(error.localizedDescription)"
        case .presentationShaderMissing: return "presentation Metal shader resource missing"
        case .presentationShaderCompilationFailed(let reason): return "presentation shader compilation failed: \(reason)"
        case .presentationFunctionMissing: return "presentation shader function missing"
        case .presentationPipelineCreationFailed(let reason): return "presentation pipeline creation failed: \(reason)"
        case .presentationSamplerCreationFailed: return "presentation sampler creation failed"
        case .displayLinkUnavailable: return "CAMetalDisplayLink could not be created"
        case .invalidPlaybackState(let reason): return "invalid playback state: \(reason)"
        }
    }
}

public struct PlaybackVideoInfo: Equatable, Sendable {
    public let encodedSize: CGSize
    public let displaySize: CGSize
    public let orientation: VideoOrientation
    public let duration: CMTime
    public let nominalFrameRate: Float
    public let hasAudioTrack: Bool

    public var durationSeconds: Double? {
        duration.isNumeric ? duration.seconds : nil
    }

    public init(
        encodedSize: CGSize,
        displaySize: CGSize,
        orientation: VideoOrientation,
        duration: CMTime,
        nominalFrameRate: Float,
        hasAudioTrack: Bool
    ) {
        self.encodedSize = encodedSize
        self.displaySize = displaySize
        self.orientation = orientation
        self.duration = duration
        self.nominalFrameRate = nominalFrameRate
        self.hasAudioTrack = hasAudioTrack
    }
}

@MainActor
public final class PlaybackController: NSObject, @preconcurrency AVPlayerItemOutputPullDelegate {
    public let processor: HDRProcessor
    public let player: AVPlayer
    public let metrics = PlayerMetrics()
    public let isTestPattern: Bool

    public private(set) var videoInfo: PlaybackVideoInfo?
    public private(set) var displayCapabilities = DisplayCapabilities.fallback
    public private(set) var isReady = false

    public var edrMappingDescription: String {
        let mastering = baseConfiguration.masteringHeadroom
        let current = displayCapabilities.displayState.usableHeadroom
        let compression = current < mastering ? "smooth direct-EDR compression" : "identity"
        let patchInputs: [Float] = [1, 1.1, 1.25, 1.5, 2, 3, 4]
        let patches = patchInputs.map {
            String(format: "%.2f→%.2f", $0, EDRDisplayMapper.mapLuminance(
                $0, masteringHeadroom: mastering, displayHeadroom: current
            ))
        }.joined(separator: ", ")
        return String(
            format: "mastering headroom: %.3f, potential EDR: %.3f, current EDR: %.3f, mapped EDR ceiling: %.3f, mapping mode: %@, patches: %@",
            mastering, displayCapabilities.potentialHeadroom, displayCapabilities.currentHeadroom,
            min(mastering, current), compression, patches
        )
    }

    public var onReady: ((PlaybackVideoInfo) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onEnded: (() -> Void)?
    public var onPlaybackActivityChanged: ((Bool) -> Void)?

    private let baseConfiguration: HDRConfiguration
    private let asset: AVAsset?
    private let item: AVPlayerItem?
    private let videoOutput: AVPlayerItemVideoOutput?
    private var statusObservation: NSKeyValueObservation?
    private var lastFrame: HDRFrame?
    private var selector = FrameTimestampSelector()
    private var playbackWasActiveBeforeSeek = false
    private var didLogPixelFormat = false
    private var didNotifyReady = false
    private var didEnd = false
    private var displayHeadroomSmoother = EDRHeadroomSmoother()

    public init(url: URL?, configuration: HDRConfiguration, device: MTLDevice) throws {
        self.baseConfiguration = configuration
        self.isTestPattern = url == nil
        self.processor = try HDRProcessor(device: device, configuration: configuration)

        if let url {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw HDRPlayerError.fileNotFound(url)
            }
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let output = Self.makeVideoOutput()
            output.suppressesPlayerRendering = true
            self.asset = asset
            self.item = item
            self.videoOutput = output
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            player.automaticallyWaitsToMinimizeStalling = true
            self.player = player
            super.init()
            item.add(output)
            output.setDelegate(self, queue: .main)
            statusObservation = item.observe(\AVPlayerItem.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    self?.handleItemStatus(item.status)
                }
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerItemDidEnd(_:)),
                name: AVPlayerItem.didPlayToEndTimeNotification,
                object: item
            )
        } else {
            self.asset = nil
            self.item = nil
            self.videoOutput = nil
            self.player = AVPlayer()
            super.init()
        }
    }

    deinit {
        statusObservation?.invalidate()
        if let item {
            NotificationCenter.default.removeObserver(self, name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        }
    }

    public func prepare() {
        if isTestPattern {
            let info = PlaybackVideoInfo(
                encodedSize: CGSize(width: 1920, height: 1080),
                displaySize: CGSize(width: 1920, height: 1080),
                orientation: .identity,
                duration: .positiveInfinity,
                nominalFrameRate: 60,
                hasAudioTrack: false
            )
            videoInfo = info
            isReady = true
            didNotifyReady = true
            onReady?(info)
            return
        }

        guard let asset else {
            reportError(HDRPlayerError.invalidPlaybackState("asset missing"))
            return
        }
        Task { @MainActor [weak self] in
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    throw HDRPlayerError.assetLoadFailed("no video track")
                }
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let duration = try await asset.load(.duration)
                let nominalFrameRate = try await track.load(.nominalFrameRate)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let orientation = VideoTransformResolver.orientation(for: transform)
                let info = PlaybackVideoInfo(
                    encodedSize: naturalSize,
                    displaySize: orientation.displaySize(for: naturalSize),
                    orientation: orientation,
                    duration: duration,
                    nominalFrameRate: nominalFrameRate,
                    hasAudioTrack: !audioTracks.isEmpty
                )
                self?.videoInfo = info
                self?.finishPreparationIfReady()
            } catch {
                self?.reportError(error)
            }
        }
    }

    public func updateDisplayCapabilities(_ capabilities: DisplayCapabilities) {
        displayCapabilities = capabilities
        displayHeadroomSmoother.setTarget(capabilities.displayState.usableHeadroom)
        do {
            try processor.update(configuration: capabilities.configuration(for: baseConfiguration))
        } catch {
            reportError(error)
        }
    }

    public func play() {
        guard isReady else { return }
        player.play()
        metrics.markPlaybackStarted()
        onPlaybackActivityChanged?(true)
    }

    public func pause() {
        player.pause()
        onPlaybackActivityChanged?(false)
    }

    public func togglePlayPause() {
        if player.rate == 0 {
            play()
        } else {
            pause()
        }
    }

    public func seek(by seconds: Double) {
        guard let duration = videoInfo?.duration, duration.isNumeric else { return }
        let current = player.currentTime().isNumeric ? player.currentTime().seconds : 0
        let target = min(max(current + seconds, 0), max(duration.seconds, 0))
        playbackWasActiveBeforeSeek = player.rate != 0
        player.pause()
        selector.reset()
        lastFrame = nil
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.selector.reset()
                self.lastFrame = nil
                self.processor.clearTemporalHistory()
                if self.playbackWasActiveBeforeSeek { self.play() }
            }
        }
    }

    public func setVolume(delta: Float) {
        player.volume = min(max(player.volume + delta, 0), 1)
    }

    public func stop() {
        player.pause()
        metrics.markPlaybackEnded()
        videoOutput?.setDelegate(nil, queue: nil)
    }

    public func render(
        update: CAMetalDisplayLink.Update,
        renderer: HDRPresentationRenderer,
        drawableSize: CGSize
    ) {
        let submissionStart = ProcessInfo.processInfo.systemUptime
        metrics.recordDisplayCallback()
        guard let commandBuffer = try? processor.makeCommandBuffer() else {
            metrics.recordInFlightSaturation()
            return
        }

        var processedFrame: HDRFrame?
        var reused = false
        var sourceUnavailable = false
        var didEncodePresentation = false
        let effectiveDisplayHeadroom = displayHeadroomSmoother.step(
            timestamp: ProcessInfo.processInfo.systemUptime
        )

        if isTestPattern {
            didEncodePresentation = renderer.encode(
                texture: nil,
                drawable: update.drawable,
                commandBuffer: commandBuffer,
                sourceSize: videoInfo?.displaySize ?? CGSize(width: 16, height: 9),
                drawableSize: drawableSize,
                orientation: .identity,
                fallbackToSDR: !displayCapabilities.isActivelyUsingEDR,
                testPattern: true,
                masteringHeadroom: baseConfiguration.masteringHeadroom,
                displayHeadroom: effectiveDisplayHeadroom
            )
        } else if let output = videoOutput, let info = videoInfo {
            let hostTime = update.targetPresentationTimestamp > 0
                ? update.targetPresentationTimestamp
                : update.targetTimestamp
            let targetItemTime = output.itemTime(forHostTime: hostTime)
            if targetItemTime.isNumeric && output.hasNewPixelBuffer(forItemTime: targetItemTime) {
                if let acquired = acquireFrame(output: output, itemTime: targetItemTime) {
                    switch selector.decide(frameTime: acquired.displayTime, targetTime: targetItemTime) {
                    case .process:
                        do {
                            let pixelBuffer = acquired.pixelBuffer
                            logPixelBufferIfNeeded(pixelBuffer)
                            try processor.prepare(
                                width: CVPixelBufferGetWidth(pixelBuffer),
                                height: CVPixelBufferGetHeight(pixelBuffer)
                            )
                            let frame = try processor.process(
                                pixelBuffer: pixelBuffer,
                                timestamp: acquired.displayTime,
                                commandBuffer: commandBuffer
                            )
                            processedFrame = frame
                            lastFrame = frame
                            metrics.recordProcessedFrame()
                        } catch let error as HDRProcessorError {
                            if case .outputTexturePoolExhausted = error {
                                metrics.recordInFlightSaturation()
                            } else {
                                reportError(error)
                            }
                        } catch {
                            reportError(error)
                        }
                    case .reuse:
                        reused = true
                    case .lateDrop:
                        metrics.recordLateDrop()
                    }
                } else {
                    sourceUnavailable = true
                }
            } else {
                sourceUnavailable = true
            }

            if processedFrame == nil {
                reused = lastFrame != nil
            }
            let texture = processedFrame?.texture ?? lastFrame?.texture
            if texture == nil { sourceUnavailable = true }
            didEncodePresentation = renderer.encode(
                texture: texture,
                drawable: update.drawable,
                commandBuffer: commandBuffer,
                sourceSize: info.displaySize,
                drawableSize: drawableSize,
                orientation: info.orientation,
                fallbackToSDR: !displayCapabilities.isActivelyUsingEDR,
                testPattern: false,
                masteringHeadroom: baseConfiguration.masteringHeadroom,
                displayHeadroom: effectiveDisplayHeadroom
            )
        } else {
            sourceUnavailable = true
            didEncodePresentation = renderer.encode(
                texture: nil,
                drawable: update.drawable,
                commandBuffer: commandBuffer,
                sourceSize: CGSize(width: 16, height: 9),
                drawableSize: drawableSize,
                orientation: .identity,
                fallbackToSDR: true,
                testPattern: false,
                masteringHeadroom: baseConfiguration.masteringHeadroom,
                displayHeadroom: 1
            )
        }

        if sourceUnavailable { metrics.recordSourceUnavailable() }
        if reused { metrics.recordReusedFrame() }
        if didEncodePresentation { metrics.recordPresentedFrame() }
        else { metrics.recordDrawableMiss() }
        let submissionMilliseconds = (ProcessInfo.processInfo.systemUptime - submissionStart) * 1_000
        metrics.recordSubmission(cpuMilliseconds: submissionMilliseconds)
        let metrics = self.metrics
        commandBuffer.addCompletedHandler { commandBuffer in
            guard commandBuffer.status == .completed,
                  commandBuffer.gpuEndTime >= commandBuffer.gpuStartTime,
                  commandBuffer.gpuStartTime > 0 else { return }
            metrics.recordGPU(milliseconds: (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000)
        }
        commandBuffer.commit()
    }

    private func finishPreparationIfReady() {
        guard let item, item.status == .readyToPlay, let info = videoInfo, !didNotifyReady else { return }
        didNotifyReady = true
        isReady = true
        onReady?(info)
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            finishPreparationIfReady()
        case .failed:
            reportError(item?.error ?? HDRPlayerError.playerItemFailed("unknown error"))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private nonisolated func acquireFrame(
        output: AVPlayerItemVideoOutput,
        itemTime: CMTime
    ) -> (pixelBuffer: CVPixelBuffer, displayTime: CMTime)? {
        if #available(macOS 26.0, *) {
            let result = output.pixelBufferAndDisplayTime(forItemTime: itemTime)
            guard let pixelBuffer = result.pixelBuffer else { return nil }
            // `unsafeBuffer` unwraps the CoreVideo object without copying
            // pixels. It is the supported bridge from the macOS 26 read-only
            // Swift wrapper to the CVPixelBuffer-based HDRCore API.
            var coreBuffer: CVPixelBuffer?
            pixelBuffer.withUnsafeBuffer { unsafeBuffer in
                coreBuffer = unsafeBuffer
            }
            guard let coreBuffer else { return nil }
            return (coreBuffer, result.itemTimeForDisplay)
        }

        var displayTime = CMTime.invalid
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) else {
            return nil
        }
        return (pixelBuffer, displayTime)
    }

    private func logPixelBufferIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        guard !didLogPixelFormat else { return }
        didLogPixelFormat = true
        let format = pixelFormatString(CVPixelBufferGetPixelFormatType(pixelBuffer))
        print("video pixel format: \(format) \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
    }

    private func pixelFormatString(_ format: OSType) -> String {
        let chars: [UInt8] = [
            UInt8((format >> 24) & 0xff), UInt8((format >> 16) & 0xff),
            UInt8((format >> 8) & 0xff), UInt8(format & 0xff)
        ]
        return String(bytes: chars.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, encoding: .ascii) ?? "unknown"
    }

    private func reportError(_ error: Error) {
        onError?(error)
    }

    private static func makeVideoOutput() -> AVPlayerItemVideoOutput {
        if #available(macOS 26.0, *) {
            let attributes = CVPixelBufferAttributes(
                pixelFormatTypes: [
                    CVPixelFormatType(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                ],
                size: nil,
                compatibility: .metalTexture,
                bytesPerRowAlignment: nil,
                planeAlignment: nil,
                extendedPixels: nil
            )
            return AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        return AVPlayerItemVideoOutput(outputSettings: attributes)
    }

    @objc private func playerItemDidEnd(_ notification: Notification) {
        guard notification.object as AnyObject? === item else { return }
        didEnd = true
        metrics.markPlaybackEnded()
        onEnded?()
    }

    public func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {}

    public func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        selector.reset()
        lastFrame = nil
        processor.clearTemporalHistory()
    }
}
