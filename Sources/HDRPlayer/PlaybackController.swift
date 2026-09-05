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

public enum HDRABPreset: String, CaseIterable, Sendable {
    case calibratedV2 = "calibrated-v2"
    case calibratedV4 = "calibrated-v4"

    var configuration: HDRConfiguration {
        switch self {
        case .calibratedV2: return .calibratedV2
        case .calibratedV4: return .calibratedV4
        }
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
    public private(set) var activeABPreset: HDRABPreset = .calibratedV4
    public let controlledComparisonEnabled: Bool
    public let controlledV6ComparisonEnabled: Bool
    public private(set) var activeV6Candidate: HDRV6ToneCurveCandidate
    public private(set) var activeV6PresetIsOn: Bool
    public private(set) var activeV62Candidate: HDRV62ToneCurveCandidate
    public private(set) var activeV62PresetIsOn: Bool

    public var activePresetName: String {
        if controlledV6ComparisonEnabled || quickV6ModeActive {
            return activeV6PresetIsOn ? activeV6Candidate.rawValue : HDRABPreset.calibratedV4.rawValue
        }
        if quickV62ModeActive || activeV62PresetIsOn {
            return activeV62PresetIsOn ? activeV62Candidate.rawValue : HDRABPreset.calibratedV4.rawValue
        }
        return activeV6PresetIsOn ? activeV6Candidate.rawValue : activeABPreset.rawValue
    }

    public var diagnosticROI: HDRDiagnosticROI? {
        diagnosticROILock.withLock { diagnosticROIStorage }
    }

    public var latestFrameDiagnostic: HDRFrameDiagnosticSnapshot? {
        activeDiagnosticProcessor.lastFrameDiagnostic
    }

    public var controlledFrameDiagnostics: [String: HDRFrameDiagnosticSnapshot] {
        var result: [String: HDRFrameDiagnosticSnapshot] = [:]
        if let v2Processor, let diagnostic = v2Processor.lastFrameDiagnostic {
            result[HDRABPreset.calibratedV2.rawValue] = diagnostic
        }
        if let v4Processor, let diagnostic = v4Processor.lastFrameDiagnostic {
            result[HDRABPreset.calibratedV4.rawValue] = diagnostic
        }
        if let v6Processor, let diagnostic = v6Processor.lastFrameDiagnostic {
            result[activeV6Candidate.rawValue] = diagnostic
        }
        return result
    }

    private var activeDiagnosticProcessor: HDRProcessor {
        if controlledV6ComparisonEnabled {
            return activeV6PresetIsOn ? (v6Processor ?? processor) : (v4Processor ?? processor)
        }
        if controlledABComparisonEnabled {
            return activeABPreset == .calibratedV2 ? (v2Processor ?? processor) : (v4Processor ?? processor)
        }
        return processor
    }

    private var activeMasteringHeadroom: Float {
        activeDiagnosticProcessor.configuration.masteringHeadroom
    }

    public func diagnosticSnapshot(renderer: HDRPresentationRenderer) -> HDRFrameDiagnosticSnapshot? {
        guard let core = activeDiagnosticProcessor.lastFrameDiagnostic else { return nil }
        guard let presentation = renderer.lastPresentationDiagnostic,
              presentation.frameIndex == core.frameIndex else { return core }
        return core.withPresentation(presentation.fullFrame, roiPresentation: presentation.roi)
    }

    public func diagnosticDump(renderer: HDRPresentationRenderer) -> String {
        var lines = ["=== HDR FRAME DIAGNOSTIC ==="]
        if let snapshot = diagnosticSnapshot(renderer: renderer) {
            lines.append(snapshot.formattedText())
        } else {
            lines.append("diagnostic: NOT_MEASURED")
        }
        if controlledComparisonEnabled {
            for (preset, diagnostic) in controlledFrameDiagnostics.sorted(by: { $0.key < $1.key }) {
                lines.append("controlled \(preset): input P50=\(format(diagnostic.input.p50)), tone P50=\(format(diagnostic.toneExpanded.p50)), core P50=\(format(diagnostic.coreEDR.p50))")
            }
        }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    public func writeDiagnosticJSON(renderer: HDRPresentationRenderer) -> URL? {
        guard let directory = diagnosticJSONDirectory,
              let snapshot = diagnosticSnapshot(renderer: renderer) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            let timestamp = snapshot.timestampSeconds.map { String(format: "%.6f", $0) } ?? "frame-\(snapshot.frameIndex)"
            let url = directory.appendingPathComponent("\(timestamp)-\(snapshot.preset).json")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("diagnostic JSON write failed: \(error)")
            return nil
        }
    }

    private func format(_ value: Float) -> String { String(format: "%.6f", value) }

    public var edrMappingDescription: String {
        let mastering = activeMasteringHeadroom
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
    public var onNeedsDisplay: (() -> Void)?
    public var onPlaybackActivityChanged: ((Bool) -> Void)?
    public var diagnosticJSONDirectory: URL?

    private let baseConfiguration: HDRConfiguration
    private let diagnosticsEnabled: Bool
    private let v2Processor: HDRProcessor?
    private let v4Processor: HDRProcessor?
    private let v6Processor: HDRProcessor?
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
    private var lastPixelBuffer: CVPixelBuffer?
    private var needsFrameReprocessing = false
    private var diagnosticFrameIndexStorage: UInt64 = 0
    private let diagnosticROILock = NSLock()
    private var diagnosticROIStorage: HDRDiagnosticROI?
    private var lastFrameV2: HDRFrame?
    private var lastFrameV4: HDRFrame?
    private var lastFrameV6: HDRFrame?
    private var quickABModeActive = false
    private var quickV6ModeActive = false
    private var quickV62ModeActive = false
    private let controlledABComparisonEnabled: Bool

    public init(
        url: URL?,
        configuration: HDRConfiguration,
        device: MTLDevice,
        controlledAB: Bool = false,
        diagnosticsEnabled: Bool = false,
        controlledV6: Bool = false,
        v6Candidate: HDRV6ToneCurveCandidate = .bandLimited055,
        v62Candidate: HDRV62ToneCurveCandidate = .adaptiveCombined
    ) throws {
        self.baseConfiguration = configuration
        self.isTestPattern = url == nil
        let useControlledV6 = controlledV6 && !controlledAB
        self.controlledABComparisonEnabled = controlledAB
        self.controlledV6ComparisonEnabled = useControlledV6
        self.controlledComparisonEnabled = controlledAB || useControlledV6
        self.diagnosticsEnabled = diagnosticsEnabled
        self.activeV6Candidate = v6Candidate
        self.activeV6PresetIsOn = !controlledAB && configuration.toneCurveRevision == .sceneRelativeV6Candidate
        self.activeV62Candidate = v62Candidate
        self.activeV62PresetIsOn = !controlledAB && configuration.toneCurveRevision == .sceneAdaptiveV62Candidate

        if controlledAB {
            guard let sharedQueue = device.makeCommandQueue() else {
                throw HDRPlayerError.metalUnavailable
            }
            let v2 = try HDRProcessor(device: device, configuration: .calibratedV2, commandQueue: sharedQueue)
            let v4 = try HDRProcessor(device: device, configuration: .calibratedV4, commandQueue: sharedQueue)
            self.v2Processor = v2
            self.v4Processor = v4
            self.v6Processor = nil
            self.processor = v4
            self.activeABPreset = .calibratedV4
            v2.diagnosticPresetLabel = HDRABPreset.calibratedV2.rawValue
            v4.diagnosticPresetLabel = HDRABPreset.calibratedV4.rawValue
            v2.debugInstrumentationEnabled = diagnosticsEnabled
            v4.debugInstrumentationEnabled = diagnosticsEnabled
        } else if useControlledV6 {
            guard let sharedQueue = device.makeCommandQueue() else {
                throw HDRPlayerError.metalUnavailable
            }
            let v4 = try HDRProcessor(device: device, configuration: .calibratedV4, commandQueue: sharedQueue)
            let v6 = try HDRProcessor(
                device: device,
                configuration: v6Candidate.configuration(),
                commandQueue: sharedQueue
            )
            self.v2Processor = nil
            self.v4Processor = v4
            self.v6Processor = v6
            self.processor = v4
            self.activeABPreset = .calibratedV4
            self.activeV6PresetIsOn = false
            self.activeV62PresetIsOn = false
            v4.diagnosticPresetLabel = HDRABPreset.calibratedV4.rawValue
            v6.diagnosticPresetLabel = v6Candidate.rawValue
            v4.debugInstrumentationEnabled = diagnosticsEnabled
            v6.debugInstrumentationEnabled = diagnosticsEnabled
        } else {
            let primary = try HDRProcessor(device: device, configuration: configuration)
            self.v2Processor = nil
            self.v4Processor = nil
            self.v6Processor = nil
            self.processor = primary
            self.activeABPreset = configuration == HDRConfiguration.calibratedV2 ? .calibratedV2 : .calibratedV4
            primary.diagnosticPresetLabel = activeV62PresetIsOn
                ? v62Candidate.rawValue
                : (activeV6PresetIsOn ? v6Candidate.rawValue : activeABPreset.rawValue)
            primary.debugInstrumentationEnabled = diagnosticsEnabled
        }

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

        metrics.markAppLaunch()
        metrics.markPlayerCreated()
    }

    deinit {
        statusObservation?.invalidate()
        if let item {
            NotificationCenter.default.removeObserver(self, name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        }
    }

    public func prepare() {
        metrics.markPrepareCalled()
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
            metrics.markReadyToPlay()
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
            if controlledABComparisonEnabled {
                try v2Processor?.update(configuration: capabilities.configuration(for: HDRConfiguration.calibratedV2))
                try v4Processor?.update(configuration: capabilities.configuration(for: HDRConfiguration.calibratedV4))
            } else if controlledV6ComparisonEnabled {
                try v4Processor?.update(configuration: capabilities.configuration(for: HDRConfiguration.calibratedV4))
                try v6Processor?.update(configuration: capabilities.configuration(for: activeV6Candidate.configuration()))
            } else {
                let sourceConfiguration: HDRConfiguration
                if activeV62PresetIsOn {
                    sourceConfiguration = activeV62Candidate.configuration()
                } else if activeV6PresetIsOn {
                    sourceConfiguration = activeV6Candidate.configuration()
                } else if quickABModeActive {
                    sourceConfiguration = activeABPreset.configuration
                } else {
                    sourceConfiguration = baseConfiguration
                }
                try processor.update(configuration: capabilities.configuration(for: sourceConfiguration))
            }
            needsFrameReprocessing = true
            onNeedsDisplay?()
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
        lastFrameV2 = nil
        lastFrameV4 = nil
        lastFrameV6 = nil
        lastPixelBuffer = nil
        needsFrameReprocessing = false
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.selector.reset()
                self.lastFrame = nil
                self.lastFrameV2 = nil
                self.lastFrameV4 = nil
                self.lastFrameV6 = nil
                self.processor.clearTemporalHistory()
                self.v2Processor?.clearTemporalHistory()
                self.v4Processor?.clearTemporalHistory()
                self.v6Processor?.clearTemporalHistory()
                if self.playbackWasActiveBeforeSeek { self.play() }
            }
        }
    }

    public func setVolume(delta: Float) {
        player.volume = min(max(player.volume + delta, 0), 1)
    }

    /// Quick A/B changes only the live configuration on the single processor.
    /// It intentionally retains temporal and scene state for visual inspection;
    /// controlled comparison uses the two independent processors below.
    @discardableResult
    public func toggleABPreset() -> HDRABPreset {
        guard !controlledV6ComparisonEnabled else {
            print("V2/V4 A/B is unavailable while controlled V6 comparison is active")
            return activeABPreset
        }
        let target: HDRABPreset = activeABPreset == .calibratedV4 ? .calibratedV2 : .calibratedV4
        if controlledABComparisonEnabled {
            activeABPreset = target
            lastFrame = target == .calibratedV2 ? lastFrameV2 : lastFrameV4
            needsFrameReprocessing = lastFrame == nil && lastPixelBuffer != nil
        } else {
            do {
                try processor.update(configuration: target.configuration)
                processor.diagnosticPresetLabel = target.rawValue
                activeABPreset = target
                activeV6PresetIsOn = false
                activeV62PresetIsOn = false
                quickABModeActive = true
                quickV6ModeActive = false
                quickV62ModeActive = false
                needsFrameReprocessing = lastPixelBuffer != nil
            } catch {
                reportError(error)
                return activeABPreset
            }
        }
        print("A/B preset switched: \(target.rawValue)")
        onNeedsDisplay?()
        return target
    }

    /// V6 development A/B. In controlled mode only the presentation source
    /// changes; V4 and the selected candidate have already processed the same
    /// source/timestamp on independent temporal and scene state.
    @discardableResult
    public func toggleV6Preset() -> String {
        let enable = !activeV6PresetIsOn
        activeV6PresetIsOn = enable
        if enable { activeV62PresetIsOn = false }
        if controlledV6ComparisonEnabled {
            lastFrame = activeV6PresetIsOn ? lastFrameV6 : lastFrameV4
            needsFrameReprocessing = lastFrame == nil && lastPixelBuffer != nil
        } else {
            do {
                let target = activeV6PresetIsOn
                    ? activeV6Candidate.configuration()
                    : HDRConfiguration.calibratedV4
                try processor.update(configuration: target)
                processor.diagnosticPresetLabel = activeV6PresetIsOn
                    ? activeV6Candidate.rawValue
                    : HDRABPreset.calibratedV4.rawValue
                activeABPreset = .calibratedV4
                quickV6ModeActive = true
                quickABModeActive = false
                quickV62ModeActive = false
                needsFrameReprocessing = lastPixelBuffer != nil
            } catch {
            activeV6PresetIsOn.toggle()
                reportError(error)
                return activePresetName
            }
        }
        let name = activePresetName
        print("V6 candidate switched: \(name)")
        onNeedsDisplay?()
        return name
    }

    /// V6.2 development A/B. This quick path keeps one processor and therefore
    /// retains its temporal state, just like the existing quick V6 toggle. The
    /// controlled V2/V4 and V4/V6 paths remain the exact comparison modes.
    @discardableResult
    public func toggleV62Preset() -> String {
        guard !controlledComparisonEnabled else {
            print("V6.2 candidate toggle is unavailable while controlled comparison is active")
            return activePresetName
        }
        let enable = !activeV62PresetIsOn
        let target = enable ? activeV62Candidate.configuration() : HDRConfiguration.calibratedV4
        do {
            try processor.update(configuration: target)
            processor.diagnosticPresetLabel = enable
                ? activeV62Candidate.rawValue
                : HDRABPreset.calibratedV4.rawValue
            activeV62PresetIsOn = enable
            activeV6PresetIsOn = false
            activeABPreset = .calibratedV4
            quickV62ModeActive = true
            quickV6ModeActive = false
            quickABModeActive = false
            needsFrameReprocessing = lastPixelBuffer != nil
        } catch {
            reportError(error)
            return activePresetName
        }
        let name = activePresetName
        print("V6.2 candidate switched: \(name)")
        onNeedsDisplay?()
        return name
    }

    public func setDiagnosticROI(_ roi: HDRDiagnosticROI?) {
        diagnosticROILock.withLock { diagnosticROIStorage = roi }
        let debugEnabled = diagnosticsEnabled || roi != nil
        processor.debugInstrumentationEnabled = debugEnabled
        v2Processor?.debugInstrumentationEnabled = debugEnabled
        v4Processor?.debugInstrumentationEnabled = debugEnabled
        v6Processor?.debugInstrumentationEnabled = debugEnabled
        onNeedsDisplay?()
    }

    public func clearDiagnosticROI() {
        setDiagnosticROI(nil)
    }

    public func stop() {
        player.pause()
        metrics.markPlaybackEnded()
        videoOutput?.setDelegate(nil, queue: nil)
    }

    @discardableResult
    public func render(
        update: CAMetalDisplayLink.Update,
        renderer: HDRPresentationRenderer,
        drawableSize: CGSize
    ) -> Bool {
        let submissionStart = ProcessInfo.processInfo.systemUptime
        metrics.recordDisplayCallback()
        let performanceMode = currentPerformanceMode
        renderer.diagnosticsEnabled = diagnosticsEnabled || diagnosticROI != nil
        guard let commandBuffer = try? processor.makeCommandBuffer() else {
            metrics.recordInFlightSaturation()
            return false
        }

        var processedFrame: HDRFrame?
        var reused = false
        var sourceUnavailable = false
        var sourceUnavailableReason: PlayerSourceUnavailableReason?
        var didEncodePresentation = false
        let effectiveDisplayHeadroom = displayHeadroomSmoother.step(
            timestamp: ProcessInfo.processInfo.systemUptime
        )
        let displayROI = diagnosticROI

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
                masteringHeadroom: activeMasteringHeadroom,
                displayHeadroom: effectiveDisplayHeadroom,
                diagnosticFrameIndex: diagnosticFrameIndexStorage,
                diagnosticROI: displayROI
            )
        } else if let output = videoOutput, let info = videoInfo {
            let hostTime = update.targetPresentationTimestamp > 0
                ? update.targetPresentationTimestamp
                : update.targetTimestamp
            let targetItemTime = output.itemTime(forHostTime: hostTime)
            let hasNewPixelBuffer = targetItemTime.isNumeric && output.hasNewPixelBuffer(forItemTime: targetItemTime)
            if hasNewPixelBuffer {
                metrics.markFirstPixelBufferAvailable()
                if let acquired = acquireFrame(output: output, itemTime: targetItemTime) {
                    metrics.markFirstPixelBufferCopied()
                    switch selector.decide(frameTime: acquired.displayTime, targetTime: targetItemTime) {
                    case .process:
                        do {
                            let pixelBuffer = acquired.pixelBuffer
                            logPixelBufferIfNeeded(pixelBuffer)
                            let frameIndex = nextDiagnosticFrameIndex()
                            let frames = try processFrame(
                                pixelBuffer: pixelBuffer,
                                timestamp: acquired.displayTime,
                                commandBuffer: commandBuffer,
                                frameIndex: frameIndex,
                                roi: sourceROI(displayROI, orientation: info.orientation)
                            )
                            processedFrame = frames.active
                            lastFrameV2 = frames.v2
                            lastFrameV4 = frames.v4
                            lastFrameV6 = frames.v6
                            lastFrame = frames.active
                            lastPixelBuffer = pixelBuffer
                            needsFrameReprocessing = false
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
                    sourceUnavailableReason = .copyPixelBufferFailed
                }
            } else {
                sourceUnavailable = true
                sourceUnavailableReason = .noNewPixelBuffer
            }

            if processedFrame == nil, needsFrameReprocessing, let pixelBuffer = lastPixelBuffer {
                do {
                    let frameIndex = nextDiagnosticFrameIndex()
                    let frames = try processFrame(
                        pixelBuffer: pixelBuffer,
                        timestamp: lastFrame?.sourceTimestamp ?? .invalid,
                        commandBuffer: commandBuffer,
                        frameIndex: frameIndex,
                        roi: sourceROI(displayROI, orientation: info.orientation)
                    )
                    processedFrame = frames.active
                    lastFrameV2 = frames.v2
                    lastFrameV4 = frames.v4
                    lastFrameV6 = frames.v6
                    lastFrame = frames.active
                    needsFrameReprocessing = false
                    metrics.recordProcessedFrame()
                } catch HDRProcessorError.outputTexturePoolExhausted {
                    metrics.recordInFlightSaturation()
                } catch {
                    reportError(error)
                }
            }

            if processedFrame == nil {
                reused = lastFrame != nil
                if lastFrame == nil,
                   sourceUnavailableReason == nil || sourceUnavailableReason == .noNewPixelBuffer {
                    sourceUnavailable = true
                    sourceUnavailableReason = .noLastFrame
                }
            }
            let texture = processedFrame?.texture ?? lastFrame?.texture
            if texture == nil {
                sourceUnavailable = true
                if sourceUnavailableReason == nil { sourceUnavailableReason = .noTexture }
            }
            didEncodePresentation = renderer.encode(
                texture: texture,
                drawable: update.drawable,
                commandBuffer: commandBuffer,
                sourceSize: info.displaySize,
                drawableSize: drawableSize,
                orientation: info.orientation,
                fallbackToSDR: !displayCapabilities.isActivelyUsingEDR,
                testPattern: false,
                masteringHeadroom: activeMasteringHeadroom,
                displayHeadroom: effectiveDisplayHeadroom,
                diagnosticFrameIndex: diagnosticFrameIndexStorage,
                diagnosticROI: displayROI
            )
        } else {
            sourceUnavailable = true
            sourceUnavailableReason = .notReady
            didEncodePresentation = renderer.encode(
                texture: nil,
                drawable: update.drawable,
                commandBuffer: commandBuffer,
                sourceSize: CGSize(width: 16, height: 9),
                drawableSize: drawableSize,
                orientation: .identity,
                fallbackToSDR: true,
                testPattern: false,
                masteringHeadroom: activeMasteringHeadroom,
                displayHeadroom: 1,
                diagnosticFrameIndex: diagnosticFrameIndexStorage,
                diagnosticROI: displayROI
            )
        }

        if sourceUnavailable { metrics.recordSourceUnavailable(reason: sourceUnavailableReason ?? .other) }
        if reused { metrics.recordReusedFrame() }
        if didEncodePresentation { metrics.recordPresentedFrame() }
        else { metrics.recordDrawableMiss() }
        let didProcessHDRFrame = processedFrame != nil
        let didPresentSourceBackedFrame = didEncodePresentation &&
            (isTestPattern || processedFrame != nil || lastFrame != nil)
        let sourceBackedNonBlackProxy = didPresentSourceBackedFrame && !renderer.diagnosticsEnabled
        let submissionMilliseconds = (ProcessInfo.processInfo.systemUptime - submissionStart) * 1_000
        metrics.recordSubmission(cpuMilliseconds: submissionMilliseconds, mode: performanceMode)
        let metrics = self.metrics
        commandBuffer.addCompletedHandler { commandBuffer in
            guard commandBuffer.status == .completed else { return }
            if didProcessHDRFrame { metrics.markFirstHDRProcessedFrame() }
            if didPresentSourceBackedFrame { metrics.markFirstDrawablePresented() }
            if sourceBackedNonBlackProxy { metrics.markFirstNonBlackPresentedFrame() }
            guard commandBuffer.gpuEndTime >= commandBuffer.gpuStartTime,
                  commandBuffer.gpuStartTime > 0 else { return }
            metrics.recordGPU(
                milliseconds: (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000,
                mode: performanceMode
            )
        }
        commandBuffer.commit()
        return didEncodePresentation && (isTestPattern || processedFrame != nil || lastFrame != nil)
    }

    private func nextDiagnosticFrameIndex() -> UInt64 {
        diagnosticFrameIndexStorage &+= 1
        return diagnosticFrameIndexStorage
    }

    private var currentPerformanceMode: PlayerPerformanceMode {
        if controlledV6ComparisonEnabled { return .controlledV6 }
        if controlledABComparisonEnabled { return .controlledAB }
        if activeV6PresetIsOn || quickV6ModeActive { return .v6Candidate }
        if diagnosticsEnabled || diagnosticROI != nil { return .debugDiagnostics }
        if quickABModeActive || activeABPreset != .calibratedV4 { return .quickAB }
        return .normalV4
    }

    private func processFrame(
        pixelBuffer: CVPixelBuffer,
        timestamp: CMTime,
        commandBuffer: MTLCommandBuffer,
        frameIndex: UInt64,
        roi: HDRDiagnosticROI?
    ) throws -> (active: HDRFrame, v2: HDRFrame?, v4: HDRFrame?, v6: HDRFrame?) {
        if controlledABComparisonEnabled, let v2Processor, let v4Processor {
            let v2 = try v2Processor.process(
                pixelBuffer: pixelBuffer,
                timestamp: timestamp,
                commandBuffer: commandBuffer,
                diagnosticFrameIndex: frameIndex,
                diagnosticROI: roi
            )
            let v4 = try v4Processor.process(
                pixelBuffer: pixelBuffer,
                timestamp: timestamp,
                commandBuffer: commandBuffer,
                diagnosticFrameIndex: frameIndex,
                diagnosticROI: roi
            )
            return (activeABPreset == .calibratedV2 ? v2 : v4, v2, v4, nil)
        }
        if controlledV6ComparisonEnabled, let v4Processor, let v6Processor {
            let v4 = try v4Processor.process(
                pixelBuffer: pixelBuffer,
                timestamp: timestamp,
                commandBuffer: commandBuffer,
                diagnosticFrameIndex: frameIndex,
                diagnosticROI: roi
            )
            let v6 = try v6Processor.process(
                pixelBuffer: pixelBuffer,
                timestamp: timestamp,
                commandBuffer: commandBuffer,
                diagnosticFrameIndex: frameIndex,
                diagnosticROI: roi
            )
            return (activeV6PresetIsOn ? v6 : v4, nil, v4, v6)
        }
        let frame = try processor.process(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp,
            commandBuffer: commandBuffer,
            diagnosticFrameIndex: frameIndex,
            diagnosticROI: roi
        )
        return (frame, nil, nil, nil)
    }

    private func sourceROI(_ roi: HDRDiagnosticROI?, orientation: VideoOrientation) -> HDRDiagnosticROI? {
        guard let roi, !roi.isEmpty else { return roi }
        switch orientation {
        case .identity:
            return roi
        case .rotate90:
            return HDRDiagnosticROI(x: 1 - roi.y - roi.height, y: roi.x, width: roi.height, height: roi.width)
        case .rotate180:
            return HDRDiagnosticROI(x: 1 - roi.x - roi.width, y: 1 - roi.y - roi.height, width: roi.width, height: roi.height)
        case .rotate270:
            return HDRDiagnosticROI(x: roi.y, y: 1 - roi.x - roi.width, width: roi.height, height: roi.width)
        }
    }

    private func finishPreparationIfReady() {
        guard let item, item.status == .readyToPlay, let info = videoInfo, !didNotifyReady else { return }
        didNotifyReady = true
        isReady = true
        metrics.markReadyToPlay()
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
        var displayTime = CMTime.invalid
        guard let pixelBuffer = output.copyPixelBuffer(
            forItemTime: itemTime,
            itemTimeForDisplay: &displayTime
        ) else {
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
        let attributes: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable]()
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
        lastFrameV2 = nil
        lastFrameV4 = nil
        lastFrameV6 = nil
        lastPixelBuffer = nil
        needsFrameReprocessing = false
        processor.clearTemporalHistory()
        v2Processor?.clearTemporalHistory()
        v4Processor?.clearTemporalHistory()
        v6Processor?.clearTemporalHistory()
        if isReady { onNeedsDisplay?() }
    }
}
