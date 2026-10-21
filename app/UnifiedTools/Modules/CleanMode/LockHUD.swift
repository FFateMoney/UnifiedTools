import AppKit
import SwiftUI

/// Small always-on-top panel shown while only the keyboard is locked.
@MainActor
final class LockHUD {
    fileprivate static let size = NSSize(width: 380, height: 44)

    private let panel: NSPanel

    init(cleanMode: CleanMode) {
        let hosting = NSHostingView(rootView: LockHUDView(cleanMode: cleanMode))
        // The countdown text changes every second; letting SwiftUI resize the window from inside
        // the layout pass crashes AppKit, so the panel keeps a fixed size.
        hosting.sizingOptions = []

        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    func show() {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let origin = NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - panel.frame.height - 12
            )
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }
}

private struct LockHUDView: View {
    let cleanMode: CleanMode

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "keyboard.badge.ellipsis")
            Text("键盘已锁定 · \(cleanMode.remaining) 秒后自动解锁")
            Button("结束") { cleanMode.end() }
        }
        .frame(width: LockHUD.size.width, height: LockHUD.size.height)
        .background(.regularMaterial, in: Capsule())
    }
}
