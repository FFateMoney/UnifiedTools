import AppKit

/// A screenshot floating above everything. Drag to move, scroll to zoom, double-click or right-click to close.
@MainActor
final class PinWindow: NSPanel {
    private let originalSize: NSSize
    private let pinnedImage: NSImage
    private let onClose: (PinWindow) -> Void

    init(image: NSImage, at rect: NSRect, onClose: @escaping (PinWindow) -> Void) {
        originalSize = rect.size
        pinnedImage = image
        self.onClose = onClose
        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinView(image: image, window: self)
    }

    override var canBecomeKey: Bool { true }

    fileprivate func closePin() {
        orderOut(nil)
        onClose(self)
    }

    fileprivate func zoom(by delta: CGFloat) {
        let factor = min(max(1 + delta * 0.02, 0.9), 1.1)
        let width = min(max(frame.width * factor, originalSize.width * 0.2), originalSize.width * 6)
        let height = width * originalSize.height / originalSize.width
        let center = NSPoint(x: frame.midX, y: frame.midY)
        setFrame(NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height), display: true)
    }

    fileprivate func copyImage() {
        CaptureOutput.copy(pinnedImage)
    }

    fileprivate func saveImage() {
        CaptureOutput.save(pinnedImage)
    }
}

private final class PinView: NSView {
    private let image: NSImage
    private weak var pinWindow: PinWindow?

    init(image: NSImage, window: PinWindow) {
        self.image = image
        pinWindow = window
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            pinWindow?.closePin()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        pinWindow?.zoom(by: event.scrollingDeltaY)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(item("复制", #selector(copyImage)))
        menu.addItem(item("保存", #selector(saveImage)))
        menu.addItem(.separator())
        menu.addItem(item("关闭", #selector(closePin)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func copyImage() { pinWindow?.copyImage() }
    @objc private func saveImage() { pinWindow?.saveImage() }
    @objc private func closePin() { pinWindow?.closePin() }
}
