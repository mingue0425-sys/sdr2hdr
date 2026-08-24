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
                device: device
            )
            let view = try HDRMetalView(device: device)
            view.playbackController = controller
            controller.onPlaybackActivityChanged = { [weak view] active in
                if active { view?.startDisplayLink() }
                else { view?.pauseDisplayLink() }
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
        window.metalView.updateScreenCapabilities()
        window.metalView.startDisplayLink()
        controller.play()
        if options.debug {
            print("source resolution: \(Int(info.encodedSize.width))x\(Int(info.encodedSize.height)), display size: \(Int(info.displaySize.width))x\(Int(info.displaySize.height)), nominal fps: \(info.nominalFrameRate > 0 ? String(format: "%.3f", info.nominalFrameRate) : "VFR"), audio: \(info.hasAudioTrack ? "yes" : "no")")
            print(window.metalView.displayCapabilities.logDescription)
            print(window.metalView.presentationDescription)
            print(controller.edrMappingDescription)
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
        if options.debug, let controller {
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
            let startupRSS = snapshot.startupResidentBytes.map(String.init) ?? "NOT_MEASURED"
            let endRSS = snapshot.endResidentBytes.map(String.init) ?? "NOT_MEASURED"
            print("RSS startup/end: \(startupRSS) / \(endRSS) bytes")
        }
        NSApp.terminate(nil)
    }

    @objc private func debugTimerFired(_ timer: Timer) {
        guard let controller else { return }
        print(controller.metrics.snapshot().debugLine)
    }

    @objc private func playForTimerFired(_ timer: Timer) {
        finishAndTerminate()
    }
}
