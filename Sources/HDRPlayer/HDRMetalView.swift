@preconcurrency import AppKit
import CoreGraphics
import Metal
@preconcurrency import QuartzCore

@MainActor
public final class HDRMetalView: NSView, @preconcurrency CAMetalDisplayLinkDelegate {
    public let metalLayer: CAMetalLayer
    public let renderer: HDRPresentationRenderer

    public weak var playbackController: PlaybackController?
    public private(set) var displayCapabilities = DisplayCapabilities.fallback

    private var displayLink: CAMetalDisplayLink?
    private var watchdogTimer: Timer?
    private var shouldRunDisplayLink = false
    private var lastDisplayCallbackUptime = ProcessInfo.processInfo.systemUptime

    public init(device: MTLDevice) throws {
        self.metalLayer = CAMetalLayer()
        self.renderer = try HDRPresentationRenderer(device: device)
        super.init(frame: .zero)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.displaySyncEnabled = true
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.presentsWithTransaction = false
        configureDrawableSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public override func makeBackingLayer() -> CALayer {
        metalLayer
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureDrawableSize()
        updateScreenCapabilities()
        if let window {
            createDisplayLinkIfNeeded()
            displayLink?.add(to: .main, forMode: .common)
            displayLink?.isPaused = playbackController?.isReady != true
            watchdogTimer?.invalidate()
            watchdogTimer = Timer.scheduledTimer(
                timeInterval: 0.5,
                target: self,
                selector: #selector(displayLinkWatchdog(_:)),
                userInfo: nil,
                repeats: true
            )
            _ = window
        } else {
            displayLink?.remove(from: .main, forMode: .common)
            displayLink?.isPaused = true
            watchdogTimer?.invalidate()
            watchdogTimer = nil
        }
    }

    public override func layout() {
        super.layout()
        configureDrawableSize()
    }

    private func configureDrawableSize() {
        let backingSize = convertToBacking(bounds).size
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(
            width: max(1, backingSize.width),
            height: max(1, backingSize.height)
        )
    }

    public func startDisplayLink() {
        shouldRunDisplayLink = true
        createDisplayLinkIfNeeded()
        displayLink?.add(to: .main, forMode: .common)
        lastDisplayCallbackUptime = ProcessInfo.processInfo.systemUptime
        displayLink?.isPaused = false
    }

    public func pauseDisplayLink() {
        shouldRunDisplayLink = false
        displayLink?.isPaused = true
    }

    public var presentationDescription: String {
        let metadataState = metalLayer.edrMetadata == nil ? "nil" : "set"
        return "CAMetalLayer pixelFormat=\(metalLayer.pixelFormat), colorspace=\(String(describing: metalLayer.colorspace?.name)), wantsExtendedDynamicRangeContent=\(metalLayer.wantsExtendedDynamicRangeContent), edrMetadata=\(metadataState)"
    }

    public func updateScreenCapabilities() {
        var capabilities = DisplayCapabilities.read(from: window?.screen ?? NSScreen.main)
        displayCapabilities = capabilities
        let enableEDR = capabilities.isEDRCapable
        metalLayer.wantsExtendedDynamicRangeContent = enableEDR
        metalLayer.colorspace = DisplayCapabilities.colorSpace(forEDR: enableEDR)
        // Direct EDR policy: HDRCore emits mastering-domain values. The
        // presentation shader maps only highlights into current physical EDR.
        // No CAEDRMetadata is attached, avoiding a second tone-mapping pass.
        metalLayer.edrMetadata = nil
        if enableEDR {
            let refreshed = DisplayCapabilities.read(from: window?.screen ?? NSScreen.main)
            if refreshed.currentHeadroom > 1.001 {
                capabilities = refreshed
            }
        }
        displayCapabilities = capabilities
        playbackController?.updateDisplayCapabilities(capabilities)
        if playbackController?.videoInfo?.nominalFrameRate == 0 {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: 1,
                maximum: Float(capabilities.refreshRate ?? 60),
                preferred: Float(capabilities.refreshRate ?? 60)
            )
        }
    }

    public func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        lastDisplayCallbackUptime = ProcessInfo.processInfo.systemUptime
        guard let playbackController else { return }
        let drawableSize = CGSize(width: update.drawable.texture.width, height: update.drawable.texture.height)
        playbackController.render(update: update, renderer: renderer, drawableSize: drawableSize)
        _ = link
    }

    private func createDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let link = CAMetalDisplayLink(metalLayer: metalLayer)
        link.delegate = self
        link.preferredFrameLatency = 1
        if let refresh = displayCapabilities.refreshRate, refresh > 0 {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 1,
                maximum: Float(refresh),
                preferred: Float(refresh)
            )
        }
        displayLink = link
    }

    @objc private func displayLinkWatchdog(_ timer: Timer) {
        guard shouldRunDisplayLink, window != nil else { return }
        // current EDR can change without a screen move (brightness, power,
        // competing HDR content). Polling at 2 Hz updates the mapper target;
        // the render path smooths the transition independently of scene state.
        let refreshed = DisplayCapabilities.read(from: window?.screen ?? NSScreen.main)
        if refreshed != displayCapabilities { updateScreenCapabilities() }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastDisplayCallbackUptime
        guard elapsed > 1.0 else { return }
        displayLink?.invalidate()
        displayLink = nil
        createDisplayLinkIfNeeded()
        displayLink?.add(to: .main, forMode: .common)
        displayLink?.isPaused = false
        lastDisplayCallbackUptime = ProcessInfo.processInfo.systemUptime
        playbackController?.metrics.recordDisplayLinkRestart()
    }

    public override func keyDown(with event: NSEvent) {
        guard let playbackController else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 49: // Space
            playbackController.togglePlayPause()
        case 123: // Left
            playbackController.seek(by: -5)
        case 124: // Right
            playbackController.seek(by: 5)
        case 126: // Up
            playbackController.setVolume(delta: 0.05)
        case 125: // Down
            playbackController.setVolume(delta: -0.05)
        case 3: // F
            window?.toggleFullScreen(nil)
        case 53: // Escape
            if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) }
        default:
            if event.modifierFlags.contains(.command), event.keyCode == 12 { NSApp.terminate(nil) }
            else { super.keyDown(with: event) }
        }
    }
}
