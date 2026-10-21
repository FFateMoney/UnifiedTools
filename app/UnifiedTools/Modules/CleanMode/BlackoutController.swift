import AppKit
import IOKit.pwr_mgt

/// Covers every screen with a black window and keeps the display awake.
/// Exit is a long press of the left mouse button anywhere, since the keyboard may be locked.
@MainActor
final class BlackoutController {
    private static let holdDuration: TimeInterval = 3

    private var windows: [NSWindow] = []
    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    private var cursorHidden = false
    private var screenObserver: NSObjectProtocol?
    private var holdTimer: Timer?
    private var holdStart: Date?
    private var onExit: (() -> Void)?

    var isActive: Bool { !windows.isEmpty }

    func start(onExit: @escaping () -> Void) {
        guard !isActive else { return }
        self.onExit = onExit

        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        buildWindows()

        NSCursor.hide()
        cursorHidden = true

        hasAssertion = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "UnifiedTools clean mode" as CFString,
            &assertionID
        ) == kIOReturnSuccess

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.buildWindows() }
        }
    }

    func stop() {
        cancelHold()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        if cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
            hasAssertion = false
        }
        NSApp.presentationOptions = []
        onExit = nil
    }

    // MARK: - Hold to exit

    fileprivate func beginHold() {
        guard holdTimer == nil else { return }
        holdStart = Date()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickHold() }
        }
    }

    fileprivate func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStart = nil
        updateViews(progress: nil)
    }

    private func tickHold() {
        guard let holdStart else { return }
        let progress = Date().timeIntervalSince(holdStart) / Self.holdDuration
        if progress >= 1 {
            let exit = onExit
            cancelHold()
            exit?()
        } else {
            updateViews(progress: progress)
        }
    }

    private func updateViews(progress: Double?) {
        for window in windows {
            (window.contentView as? BlackoutView)?.update(progress: progress)
        }
    }

    // MARK: - Windows

    private func buildWindows() {
        for window in windows {
            window.orderOut(nil)
        }
        windows = NSScreen.screens.map { screen in
            let window = BlackoutWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.contentView = BlackoutView(controller: self)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return window
        }
        windows.first?.makeKey()
    }
}

private final class BlackoutWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class BlackoutView: NSView {
    private weak var controller: BlackoutController?
    private let hint = NSTextField(labelWithString: "长按鼠标左键 3 秒退出清洁模式")
    private let bar = NSProgressIndicator()

    init(controller: BlackoutController) {
        self.controller = controller
        super.init(frame: .zero)

        hint.textColor = NSColor(white: 0.35, alpha: 1)
        hint.font = .systemFont(ofSize: 15)
        hint.translatesAutoresizingMaskIntoConstraints = false

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(hint)
        addSubview(bar)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16),
            bar.widthAnchor.constraint(equalToConstant: 200),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.beginHold() }
    }

    override func mouseUp(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.cancelHold() }
    }

    func update(progress: Double?) {
        if let progress {
            bar.isHidden = false
            bar.doubleValue = progress
        } else {
            bar.isHidden = true
            bar.doubleValue = 0
        }
    }
}
