import AppKit

/// A short message that fades away on its own, shown without taking focus.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func hide() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    static func show(_ message: String, duration: TimeInterval = 1.6) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()

        let size = NSSize(width: label.frame.width + 40, height: 40)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = size.height / 2
        label.frame.origin = NSPoint(x: 20, y: (size.height - label.frame.height) / 2)
        background.addSubview(label)

        let toast = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        toast.contentView = background
        toast.level = .statusBar
        toast.backgroundColor = .clear
        toast.isOpaque = false
        toast.hasShadow = true
        toast.ignoresMouseEvents = true
        toast.isReleasedWhenClosed = false
        toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let mouse = NSEvent.mouseLocation
        if let frame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            toast.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.12))
        }
        toast.orderFrontRegardless()
        panel = toast

        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            toast.orderOut(nil)
            if panel === toast { panel = nil }
        }
    }
}
