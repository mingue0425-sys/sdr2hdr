@preconcurrency import AppKit

@MainActor
public final class HDRPlayerWindow: NSWindow, NSWindowDelegate {
    public let metalView: HDRMetalView

    public init(metalView: HDRMetalView, initialSize: CGSize = CGSize(width: 1280, height: 720)) {
        self.metalView = metalView
        let rect = NSRect(origin: .zero, size: initialSize)
        super.init(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        delegate = self
        title = "HDRPlayer"
        isReleasedWhenClosed = false
        contentView = metalView
        initialFirstResponder = metalView
        makeFirstResponder(metalView)
        center()
        setFrameAutosaveName("HDRPlayerWindow")
    }

    public func resizeToVideo(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let screenFrame = (screen ?? NSScreen.main)?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
        let maxSize = CGSize(
            width: (screenFrame?.width ?? 1280) * 0.85,
            height: (screenFrame?.height ?? 720) * 0.85
        )
        let scale = min(maxSize.width / size.width, maxSize.height / size.height, 1)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let frame = frameRect(forContentRect: NSRect(origin: .zero, size: targetSize))
        setFrame(frame, display: true, animate: false)
        center()
    }

    public func windowDidChangeScreen(_ notification: Notification) {
        metalView.updateScreenCapabilities()
    }

    public func windowDidChangeBackingProperties(_ notification: Notification) {
        metalView.updateScreenCapabilities()
        metalView.needsLayout = true
    }

    public func windowWillClose(_ notification: Notification) {
        metalView.playbackController?.stop()
        NSApp.terminate(nil)
    }
}
