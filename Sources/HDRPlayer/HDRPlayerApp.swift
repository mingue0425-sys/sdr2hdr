@preconcurrency import AppKit
import Foundation
import HDRCore
import Metal

@MainActor
public final class HDRPlayerApplication: NSObject, NSApplicationDelegate {
    private let options: PlayerOptions
    private var window: HDRPlayerWindow?
    private var controller: PlaybackController?
    private var metricsTimer: Timer?
    private var playForTimer: Timer?
    private var hasReportedError = false

    public init(options: PlayerOptions) {
        self.options = options
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw HDRPlayerError.metalUnavailable
            }
            let configuration = try options.baseConfiguration()
            let controller = try PlaybackController(
                url: options.inputURL,
                configuration: configuration,
                device: device,
                controlledAB: options.controlledAB,
                diagnosticsEnabled: options.debug,
                controlledV6: options.controlledV6,
                v6Candidate: options.v6Candidate,
                v62Candidate: options.v62Candidate
            )
            if options.diagnosticJSON {
                controller.diagnosticJSONDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("results/visual-debug", isDirectory: true)
            }
            if let diagnosticROI = options.diagnosticROI {
                controller.setDiagnosticROI(diagnosticROI)
            }
            let view = try HDRMetalView(device: device)
            view.playbackController = controller
            view.renderer.onNonBlackPresented = { [weak controller] in
                Task { @MainActor [weak controller] in
                    controller?.metrics.markFirstNonBlackPresentedFrame()
                }
            }
            controller.onPlaybackActivityChanged = { [weak view] active in
                if active { view?.startDisplayLink() }
                else { view?.pauseDisplayLink() }
            }
            controller.onNeedsDisplay = { [weak view] in
                view?.requestDisplayRefresh()
            }
            controller.onError = { [weak self] error in
                self?.handleError(error)
            }
            controller.onEnded = { [weak self] in
                self?.handleEnded()
            }
            let window = HDRPlayerWindow(metalView: view)
            self.window = window
            self.controller = controller
            // Rebind the ready closure now that the window exists.
            controller.onReady = { [weak self, weak window] info in
                self?.handleReady(info, window: window)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if options.startFullscreen { window.toggleFullScreen(nil) }
            controller.prepare()
        } catch {
            handleError(error)
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        metricsTimer?.invalidate()
        playForTimer?.invalidate()
        controller?.stop()
        window?.metalView.pauseDisplayLink()
    }

    private func handleReady(_ info: PlaybackVideoInfo, window: HDRPlayerWindow?) {
        guard let controller, let window else { return }
        window.resizeToVideo(size: info.displaySize)
        controller.play()
        // Start consuming display-link frames only after playCalled has been
        // recorded. This keeps startup latency timestamps causal and avoids
        // classifying a pre-play frame as the first playback frame.
        window.metalView.updateScreenCapabilities()
        window.metalView.startDisplayLink()
        if options.debug {
            print("source resolution: \(Int(info.encodedSize.width))x\(Int(info.encodedSize.height)), display size: \(Int(info.displaySize.width))x\(Int(info.displaySize.height)), nominal fps: \(info.nominalFrameRate > 0 ? String(format: "%.3f", info.nominalFrameRate) : "VFR"), audio: \(info.hasAudioTrack ? "yes" : "no")")
            print(window.metalView.displayCapabilities.logDescription)
            print(window.metalView.presentationDescription)
            print(controller.edrMappingDescription)
            print("A/B mode: \(options.controlledAB ? "controlled dual-processor" : "quick single-processor")")
            metricsTimer = Timer.scheduledTimer(
                timeInterval: 1,
                target: self,
                selector: #selector(debugTimerFired(_:)),
                userInfo: nil,
                repeats: true
            )
        }
        if let playFor = options.playFor {
            playForTimer = Timer.scheduledTimer(
                timeInterval: playFor,
                target: self,
                selector: #selector(playForTimerFired(_:)),
                userInfo: nil,
                repeats: false
            )
        }
    }

    private func handleEnded() {
        // Last frame remains on screen. For --play-for validation, the timer
        // owns termination; natural EOF otherwise leaves a quiet final frame.
        if options.playFor == nil {
            window?.metalView.pauseDisplayLink()
        }
    }

    private func handleError(_ error: Error) {
        guard !hasReportedError else { return }
        hasReportedError = true
        fputs("HDRPlayer error: \(error.localizedDescription)\n", stderr)
        NSApp.terminate(nil)
    }

    private func finishAndTerminate() {
        controller?.stop()
        if (options.debug || options.playFor != nil), let controller {
            let snapshot = controller.metrics.snapshot()
            let mediaDuration = controller.videoInfo?.durationSeconds.map { String(format: "%.4f", $0) } ?? "NOT_MEASURED"
            let mediaTime = controller.player.currentTime().isNumeric
                ? String(format: "%.4f", controller.player.currentTime().seconds)
                : "NOT_MEASURED"
            let wallDuration = snapshot.wallPlaybackSeconds.map { String(format: "%.4f", $0) } ?? "NOT_MEASURED"
            let gpuP50 = snapshot.gpuRenderP50.map { String(format: "%.3f", $0) } ?? "NOT_MEASURED"
            let gpuP95 = snapshot.gpuRenderP95.map { String(format: "%.3f", $0) } ?? "NOT_MEASURED"
            let cpuP50 = snapshot.cpuSubmissionP50.map { String(format: "%.3f", $0) } ?? "NOT_MEASURED"
            let cpuP95 = snapshot.cpuSubmissionP95.map { String(format: "%.3f", $0) } ?? "NOT_MEASURED"
            print("media duration: \(mediaDuration) s")
            print("media time at stop: \(mediaTime) s")
            print("wall playback duration: \(wallDuration) s")
            print("processed HDR: \(snapshot.processedHDRFrames), presented: \(snapshot.presentedFrames), reused: \(snapshot.reusedFrames), late dropped: \(snapshot.lateDroppedFrames), drawable misses: \(snapshot.drawableMisses)")
            print("display callbacks: \(snapshot.displayCallbacks), source unavailable/duplicate: \(snapshot.sourceUnavailableFrames), pool busy: \(snapshot.inFlightSaturation), display-link restarts: \(snapshot.displayLinkRestarts)")
            print("GPU render p50/p95: \(gpuP50) / \(gpuP95) ms")
            print("CPU submission p50/p95: \(cpuP50) / \(cpuP95) ms")
            let startup = snapshot.startup
            func milliseconds(_ value: Double?) -> String {
                value.map { String(format: "%.3f", $0 * 1_000) } ?? "NOT_MEASURED"
            }
            func latencyMilliseconds(from start: Double?, to end: Double?) -> String {
                guard let start, let end else { return "NOT_MEASURED" }
                return String(format: "%.3f", max(0, end - start) * 1_000)
            }
            print("startup play→firstPixelBuffer=\(milliseconds(startup.playToFirstPixelBuffer)) ms, play→firstProcessed=\(milliseconds(startup.playToFirstProcessedFrame)) ms, play→firstPresented=\(milliseconds(startup.playToFirstPresentedFrame)) ms")
            print("startup ready→firstPixelBuffer=\(milliseconds(startup.readyToFirstPixelBuffer)) ms, ready→firstPresented=\(milliseconds(startup.readyToFirstPresentedFrame)) ms")
            let firstNonBlack = latencyMilliseconds(from: startup.playCalled, to: startup.firstNonBlackPresentedFrame)
            print("startup play→firstNonBlackPresented=\(firstNonBlack) ms, ordered=\(startup.timestampsAreOrdered)")
            let source = snapshot.sourceUnavailableBreakdown
            print("sourceUnavailable breakdown NO_NEW_PIXEL_BUFFER=\(source.noNewPixelBuffer), COPY_PIXEL_BUFFER_FAILED=\(source.copyPixelBufferFailed), NO_LAST_FRAME=\(source.noLastFrame), NO_TEXTURE=\(source.noTexture), NOT_READY=\(source.notReady), OTHER=\(source.other)")
            for performance in snapshot.performanceByMode {
                let gpu = performance.gpuP50.map { String(format: "%.3f", $0) } ?? "NOT_MEASURED"
                let gpu95 = performance.gpuP95.map { String(format: "%.3f", $0) } ?? "NOT_MEASURED"
                let cpu = performance.cpuP50.map { String(format: "%.3f", $0) } ?? "NOT_MEASURED"
                let cpu95 = performance.cpuP95.map { String(format: "%.3f", $0) } ?? "NOT_MEASURED"
                print("mode \(performance.mode.rawValue) GPU p50/p95 \(gpu)/\(gpu95) ms, CPU p50/p95 \(cpu)/\(cpu95) ms")
            }
            let startupRSS = snapshot.startupResidentBytes.map(String.init) ?? "NOT_MEASURED"
            let endRSS = snapshot.endResidentBytes.map(String.init) ?? "NOT_MEASURED"
            print("RSS startup/end: \(startupRSS) / \(endRSS) bytes")
        }
        NSApp.terminate(nil)
    }

    @objc private func debugTimerFired(_ timer: Timer) {
        guard let controller else { return }
        print(controller.metrics.snapshot().debugLine)
        if let renderer = window?.metalView.renderer,
           let diagnostic = controller.diagnosticSnapshot(renderer: renderer) {
            print(diagnostic.formattedText())
        }
        for (preset, diagnostic) in controller.controlledFrameDiagnostics.sorted(by: { $0.key < $1.key }) {
            print("controlled \(preset): input avg=\(String(format: "%.6f", diagnostic.input.average)), tone avg=\(String(format: "%.6f", diagnostic.toneExpanded.average)), core avg=\(String(format: "%.6f", diagnostic.coreEDR.average)), input P50=\(String(format: "%.6f", diagnostic.input.p50)), tone P50=\(String(format: "%.6f", diagnostic.toneExpanded.p50)), core P50=\(String(format: "%.6f", diagnostic.coreEDR.p50)), lowMid=\(String(format: "%.6f", diagnostic.toneCurve.lowMidExpansionContribution)), shoulder=\(String(format: "%.6f", diagnostic.toneCurve.shoulderExpansionContribution)), temporal=\(String(format: "%.6f", diagnostic.temporalAdaptation)), scene=\(String(format: "%.6f/%.6f/%@", diagnostic.sceneShadowFloor, diagnostic.sceneShadowTop, diagnostic.sceneStatisticsValid ? "valid" : "invalid"))")
        }
    }

    @objc private func playForTimerFired(_ timer: Timer) {
        finishAndTerminate()
    }
}
