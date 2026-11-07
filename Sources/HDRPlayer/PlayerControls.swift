@preconcurrency import AppKit
import HDRCore

/// The window content: the Metal view with a playback bar over its bottom
/// edge. The bar appears on mouse movement and hides after a few seconds of
/// playback; it stays while paused, hovered or dragged. Its controls never
/// take keyboard focus, so the player's keys keep working.
@MainActor
public final class PlayerContentView: NSView {
    public let metalView: HDRMetalView
    public let bar = PlaybackBarView()
    private var hideWorkItem: DispatchWorkItem?
    private var tracking: NSTrackingArea?

    public init(metalView: HDRMetalView) {
        self.metalView = metalView
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView)
        addSubview(bar)
        bar.alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        let width = min(bounds.width - 24, 760)
        bar.frame = NSRect(x: (bounds.width - width) / 2, y: 14, width: max(width, 200), height: 44)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseMoved(with event: NSEvent) { showBar() }
    public override func mouseEntered(with event: NSEvent) { showBar() }
    public override func mouseExited(with event: NSEvent) { scheduleHide(after: 0.8) }

    public func showBar() {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; bar.animator().alphaValue = 1 }
        NSCursor.setHiddenUntilMouseMoves(false)
        scheduleHide(after: 2.5)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mouse = self.convert(self.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            if self.bar.keepsVisible || self.bar.frame.contains(mouse) {
                self.scheduleHide(after: 1.5)
                return
            }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; self.bar.animator().alphaValue = 0 }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }
}

/// Play/pause, position, a seek slider, duration and a settings button.
@MainActor
public final class PlaybackBarView: NSVisualEffectView {
    public var onTogglePlay: (() -> Void)?
    /// Fraction of the duration, and whether this is the final position of a drag.
    public var onSeek: ((Double, Bool) -> Void)?
    public var onSettings: (() -> Void)?

    private let playButton = NSButton()
    private let settingsButton = NSButton()
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private var dragging = false
    private var playing = false

    /// True while paused or scrubbing.
    var keepsVisible: Bool { dragging || !playing }

    public init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        configure(playButton, symbol: "play.fill", label: "재생/일시정지", action: #selector(togglePlay))
        configure(settingsButton, symbol: "gearshape", label: "재생 설정", action: #selector(openSettings))
        slider.target = self
        slider.action = #selector(sliderMoved(_:))
        slider.isContinuous = true
        slider.refusesFirstResponder = true
        for label in [timeLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = .white
            label.alignment = .center
        }
        let stack = NSStackView(views: [playButton, timeLabel, slider, durationLabel, settingsButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52)
        ])
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.contentTintColor = .white
        button.toolTip = label
        button.target = self
        button.action = action
        button.refusesFirstResponder = true
    }

    /// Updates the position unless the user is dragging the slider.
    public func update(currentSeconds: Double, durationSeconds: Double?, isPlaying: Bool) {
        playing = isPlaying
        playButton.image = NSImage(systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
                                   accessibilityDescription: "재생/일시정지")
        let duration = durationSeconds ?? 0
        durationLabel.stringValue = Self.format(duration)
        guard !dragging else { return }
        timeLabel.stringValue = Self.format(currentSeconds)
        slider.doubleValue = duration > 0 ? min(max(currentSeconds / duration, 0), 1) : 0
        slider.isEnabled = duration > 0
    }

    @objc private func togglePlay() { onTogglePlay?() }
    @objc private func openSettings() { onSettings?() }

    @objc private func sliderMoved(_ sender: NSSlider) {
        let finished = NSApp.currentEvent?.type == .leftMouseUp
        dragging = !finished
        onSeek?(sender.doubleValue, finished)
    }

    /// m:ss, or h:mm:ss from one hour.
    public nonisolated static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// Preset, SDR decode and upscaling, applied while the video plays.
@MainActor
public final class PlayerSettingsPanel: NSObject {
    public var onPreset: ((String) -> Void)?
    public var onSDRTransfer: ((HDRSDRTransferInterpretation) -> Void)?
    public var onUpscale: ((HDRUpscaleMode) -> Void)?
    public var onSkinProtection: ((HDRSkinProtection) -> Void)?

    private let panel: NSPanel
    private let presetPopup = NSPopUpButton()
    private let sdrPopup = NSPopUpButton()
    private let upscalePopup = NSPopUpButton()
    private let skinPopup = NSPopUpButton()
    private static let sdrChoices: [(HDRSDRTransferInterpretation, String)] = [
        (.youtubeHLGDerivedInverseLuminanceGain, "YouTube HDR 영상의 SDR 버전"),
        (.bt709InverseOETFSceneLinear, "일반 SDR")
    ]

    public init(upscaleSupported: Bool) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = "재생 설정"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true

        for name in HDRPresetResolver.supportedPresetNames {
            presetPopup.addItem(withTitle: name == HDRPresetResolver.productionDefault ? "\(name) (기본)" : name)
            presetPopup.lastItem?.representedObject = name
        }
        for (_, title) in Self.sdrChoices { sdrPopup.addItem(withTitle: title) }
        for mode in HDRUpscaleMode.allCases {
            upscalePopup.addItem(withTitle: mode.displayName)
            upscalePopup.lastItem?.representedObject = mode.rawValue
        }
        upscalePopup.isEnabled = upscaleSupported
        for level in HDRSkinProtection.allCases { skinPopup.addItem(withTitle: level.displayName) }
        for popup in [presetPopup, sdrPopup, upscalePopup, skinPopup] {
            popup.target = self
            popup.action = #selector(changed(_:))
        }

        let note = NSTextField(wrappingLabelWithString: upscaleSupported
            ? "YouTube 모드는 YouTube에 HDR로 올라온 영상의 SDR 버전용입니다. 처음부터 SDR인 영상(MMD 등)은 \"일반 SDR\"을 고르세요 (단축키 Y). 피부 보호는 밝은 피부가 하이라이트처럼 하얗게 빛나는 것을 막습니다. 업스케일은 MetalFX로 화면 크기까지 키웁니다."
            : "이 Mac은 MetalFX 업스케일을 지원하지 않습니다.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "프리셋"), presetPopup],
            [NSTextField(labelWithString: "SDR 해석"), sdrPopup],
            [NSTextField(labelWithString: "업스케일"), upscalePopup],
            [NSTextField(labelWithString: "피부 보호"), skinPopup]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        for popup in [presetPopup, sdrPopup, upscalePopup, skinPopup] {
            popup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        }
        let stack = NSStackView(views: [grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        note.preferredMaxLayoutWidth = 380
        note.widthAnchor.constraint(equalToConstant: 380).isActive = true
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
    }

    public func show(preset: String, sdrTransfer: HDRSDRTransferInterpretation, upscale: HDRUpscaleMode,
                     skinProtection: HDRSkinProtection) {
        if let index = HDRSkinProtection.allCases.firstIndex(of: skinProtection) { skinPopup.selectItem(at: index) }
        if let index = presetPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == preset }) {
            presetPopup.selectItem(at: index)
        }
        sdrPopup.selectItem(at: Self.sdrChoices.firstIndex(where: { $0.0 == sdrTransfer }) ?? 1)
        if let index = HDRUpscaleMode.allCases.firstIndex(of: upscale) { upscalePopup.selectItem(at: index) }
        if !panel.isVisible { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    public func close() { panel.close() }

    @objc private func changed(_ sender: NSPopUpButton) {
        switch sender {
        case presetPopup:
            if let name = sender.selectedItem?.representedObject as? String { onPreset?(name) }
        case sdrPopup:
            onSDRTransfer?(Self.sdrChoices[max(sender.indexOfSelectedItem, 0)].0)
        case skinPopup:
            onSkinProtection?(HDRSkinProtection.allCases[max(sender.indexOfSelectedItem, 0)])
        default:
            if let raw = sender.selectedItem?.representedObject as? String, let mode = HDRUpscaleMode(rawValue: raw) {
                onUpscale?(mode)
            }
        }
    }
}
