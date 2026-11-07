@preconcurrency import AppKit
import Foundation
import HDRCore
import Metal

@MainActor
public final class HDRPlayerApplication: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var options: PlayerOptions
    /// Launched without a file (double-click, Finder "Open With"): files
    /// arrive as open events, errors are shown in alerts, and the YouTube
    /// decode choice is remembered.
    private let documentMode: Bool
    private var window: HDRPlayerWindow?
    private var controller: PlaybackController?
    private var metricsTimer: Timer?
    private var playForTimer: Timer?
    private var hasReportedError = false
    private var openedAnyFile = false
    private var conversionPanel: ConversionPanel?
    private var controlsTimer: Timer?
    private var settingsPanel: PlayerSettingsPanel?
    static let sdrTransferDefaultsKey = "HDRPlayerSDRTransfer"
    static let presetDefaultsKey = "HDRPlayerPreset"
    static let upscaleDefaultsKey = "HDRPlayerUpscale"
    static let skinDefaultsKey = "HDRPlayerSkinProtection"

    public init(options: PlayerOptions, documentMode: Bool = false) {
        var options = options
        if documentMode,
           let stored = UserDefaults.standard.string(forKey: Self.sdrTransferDefaultsKey),
           let policy = HDRSDRTransferInterpretation(cliName: stored) {
            options.sdrTransferInterpretation = policy
        }
        if documentMode {
            let defaults = UserDefaults.standard
            if let preset = defaults.string(forKey: Self.presetDefaultsKey),
               HDRPresetResolver.configuration(for: preset) != nil {
                options.preset = preset
            }
            if let stored = defaults.string(forKey: Self.upscaleDefaultsKey), let mode = HDRUpscaleMode(rawValue: stored) {
                options.upscale = mode
            }
            if let stored = defaults.string(forKey: Self.skinDefaultsKey), let level = HDRSkinProtection(rawValue: stored) {
                options.skinProtection = level
            }
        }
        self.options = options
        self.documentMode = documentMode
        super.init()
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        guard documentMode else {
            Task { @MainActor [weak self] in
                await self?.startPlayback(url: self?.options.inputURL)
            }
            return
        }
        if let url = options.inputURL {
            open(url)
            return
        }
        // Finder delivers the file as an open event around launch. Without
        // one (the app itself was double-clicked), ask for a file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, !self.openedAnyFile else { return }
            self.openDocument(nil)
        }
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        open(url)
    }

    @objc public func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audiovisualContent, .image]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        } else if controller == nil {
            NSApp.terminate(nil)
        }
    }

    /// Replaces whatever is playing with `url`.
    private func open(_ url: URL) {
        openedAnyFile = true
        hasReportedError = false
        if let window {
            window.onClose = {}
            window.close()
        }
        metricsTimer?.invalidate()
        playForTimer?.invalidate()
        controlsTimer?.invalidate()
        controller?.stop()
        controller = nil
        window = nil
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let playable = try await self.playableURL(for: url)
                await self.startPlayback(url: playable, displayName: url.lastPathComponent)
            } catch {
                self.handleError(error)
            }
        }
    }

    /// Converts inputs AVFoundation cannot decode, showing progress.
    private func playableURL(for url: URL) async throws -> URL {
        guard options.convertUndecodable,
              !StillImageSource.isImage(url),
              let converter = PlayableInputConverter(
                  cacheDirectory: options.convertDirectory ?? PlayableInputConverter.defaultCacheDirectory()
              ) else { return url }
        let panel = ConversionPanel(fileName: url.lastPathComponent)
        conversionPanel = panel
        defer {
            panel.close()
            conversionPanel = nil
        }
        let outcome = try await converter.prepare(url) { fraction in
            Task { @MainActor in panel.update(fraction) }
        }
        return outcome.url ?? url
    }

    private func startPlayback(url: URL?, displayName: String? = nil) async {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw HDRPlayerError.metalUnavailable
            }
            let configuration = try options.baseConfiguration()
            let controller = try await PlaybackController.make(
                url: url,
                configuration: configuration,
                device: device,
                controlledAB: options.controlledAB,
                diagnosticsEnabled: options.debug,
                controlledV6: options.controlledV6,
                v6Candidate: options.v6Candidate,
                v62Candidate: options.v62Candidate,
                decodePrecision: options.decodePrecision
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
            view.renderer.upscaleMode = options.upscale
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
            window.displayName = displayName ?? url?.lastPathComponent ?? "HDRPlayer"
            if documentMode {
                window.onClose = { NSApp.terminate(nil) }
            }
            self.window = window
            self.controller = controller
            updateTitle()
            let bar = window.content.bar
            bar.onTogglePlay = { [weak controller] in controller?.togglePlayPause() }
            bar.onSeek = { [weak controller] fraction, finished in
                guard let controller, let duration = controller.videoInfo?.durationSeconds else { return }
                controller.seek(toSeconds: fraction * duration, exact: finished)
            }
            bar.onSettings = { [weak self] in self?.showSettings(nil) }
            controlsTimer?.invalidate()
            controlsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let controller = self?.controller, let bar = self?.window?.content.bar else { return }
                    bar.update(currentSeconds: controller.currentSeconds,
                               durationSeconds: controller.videoInfo?.durationSeconds,
                               isPlaying: controller.isPlaying)
                }
            }
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
        window.content.bar.isStillImage = controller.isStillImage
        window.content.showBar()
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
            print("upscale mode: \(options.upscale.rawValue)")
            print("decode precision: \(controller.decodePrecisionDiagnosticDescription)")
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
        guard documentMode else {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "이 파일을 열 수 없습니다"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "다른 파일 열기…")
        alert.addButton(withTitle: "종료")
        NSApp.activate(ignoringOtherApps: true)
        if let window { window.onClose = {}; window.close() }
        controller?.stop()
        controller = nil
        window = nil
        if alert.runModal() == .alertFirstButtonReturn {
            openDocument(nil)
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: - YouTube HDR decode

    private var youTubeDecodeIsOn: Bool {
        (controller?.sdrTransferInterpretation ?? options.sdrTransferInterpretation) == .youtubeHLGDerivedInverseLuminanceGain
    }

    /// Y: switches between the YouTube HDR rendition decode and the plain
    /// BT.709 inverse OETF.
    @objc public func toggleYouTubeDecode(_ sender: Any?) {
        guard controller?.isStillImage != true else { NSSound.beep(); return }
        let next: HDRSDRTransferInterpretation = youTubeDecodeIsOn
            ? .bt709InverseOETFSceneLinear : .youtubeHLGDerivedInverseLuminanceGain
        options.sdrTransferInterpretation = next
        controller?.setSDRTransferInterpretation(next)
        if documentMode {
            UserDefaults.standard.set(next.cliName, forKey: Self.sdrTransferDefaultsKey)
        }
        updateTitle()
        if options.debug { print("sdr transfer interpretation: \(next.rawValue)") }
        refreshSettingsPanel()
    }

    // MARK: - Settings

    @objc public func showSettings(_ sender: Any?) {
        let panel = settingsPanel ?? makeSettingsPanel()
        settingsPanel = panel
        panel.show(preset: options.preset, sdrTransfer: options.sdrTransferInterpretation, upscale: options.upscale,
                   skinProtection: options.skinProtection, isStillImage: controller?.isStillImage == true)
    }

    private func refreshSettingsPanel() {
        guard let settingsPanel else { return }
        settingsPanel.show(preset: options.preset, sdrTransfer: options.sdrTransferInterpretation, upscale: options.upscale,
                           skinProtection: options.skinProtection, isStillImage: controller?.isStillImage == true)
    }

    private func makeSettingsPanel() -> PlayerSettingsPanel {
        let supported = MTLCreateSystemDefaultDevice().map(PresentationUpscaler.isSupported(on:)) ?? false
        let panel = PlayerSettingsPanel(upscaleSupported: supported)
        panel.onPreset = { [weak self] name in self?.applyPreset(name) }
        panel.onSDRTransfer = { [weak self] policy in
            guard let self, policy != self.options.sdrTransferInterpretation else { return }
            self.toggleYouTubeDecode(nil)
        }
        panel.onUpscale = { [weak self] mode in self?.applyUpscale(mode) }
        panel.onSkinProtection = { [weak self] level in self?.applySkinProtection(level) }
        return panel
    }

    private func applyPreset(_ name: String) {
        var next = options
        next.preset = name
        do {
            let configuration = try next.baseConfiguration()
            options = next
            controller?.setBaseConfiguration(configuration)
            if documentMode { UserDefaults.standard.set(name, forKey: Self.presetDefaultsKey) }
            if options.debug { print("preset: \(name)") }
        } catch {
            NSSound.beep()
        }
    }

    private func applySkinProtection(_ level: HDRSkinProtection) {
        var next = options
        next.skinProtection = level
        guard let configuration = try? next.baseConfiguration() else { NSSound.beep(); return }
        options = next
        controller?.setBaseConfiguration(configuration)
        if documentMode { UserDefaults.standard.set(level.rawValue, forKey: Self.skinDefaultsKey) }
        if options.debug { print("skin protection: \(level.rawValue)") }
    }

    private func applyUpscale(_ mode: HDRUpscaleMode) {
        options.upscale = mode
        window?.metalView.renderer.upscaleMode = mode
        window?.metalView.requestDisplayRefresh()
        if documentMode { UserDefaults.standard.set(mode.rawValue, forKey: Self.upscaleDefaultsKey) }
        if options.debug { print("upscale: \(mode.rawValue)") }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleYouTubeDecode(_:)) {
            menuItem.state = youTubeDecodeIsOn ? .on : .off
            return controller?.isStillImage != true
        }
        return true
    }

    private func updateTitle() {
        guard let window else { return }
        // Images are sRGB-tagged, so the YouTube decode (a BT.709-tag
        // reinterpretation) does not apply to them.
        let mode = controller?.isStillImage == true ? "이미지" : (youTubeDecodeIsOn ? "YouTube HDR 해석 (Y)" : "일반 SDR (Y)")
        window.title = "\(window.displayName) — \(mode)"
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "HDRPlayer에 관하여", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "설정…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "HDRPlayer 가리기", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "HDRPlayer 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "파일")
        fileMenu.addItem(withTitle: "열기…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "보기")
        let youtube = NSMenuItem(title: "YouTube HDR 영상의 SDR 버전으로 해석", action: #selector(toggleYouTubeDecode(_:)), keyEquivalent: "y")
        youtube.keyEquivalentModifierMask = []
        viewMenu.addItem(youtube)
        let fullScreen = NSMenuItem(title: "전체 화면", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreen)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        return main
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
        if let renderer = window?.metalView.renderer { print(renderer.upscaleDescription) }
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

/// A small window that shows conversion progress for undecodable inputs.
@MainActor
final class ConversionPanel {
    private let panel: NSPanel
    private let label: NSTextField
    private let bar: NSProgressIndicator
    private let fileName: String

    init(fileName: String) {
        self.fileName = fileName
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "HDRPlayer"
        label = NSTextField(labelWithString: "")
        bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack
        bar.widthAnchor.constraint(equalToConstant: 380).isActive = true
        update(0)
        // Only conversions take long enough to need a window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.bar.doubleValue < 1 else { return }
            self.panel.center()
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    func update(_ fraction: Double) {
        bar.doubleValue = fraction
        label.stringValue = "\(fileName) 재생용으로 변환 중… \(Int(fraction * 100))%"
    }

    func close() {
        bar.doubleValue = 1
        panel.close()
    }
}
