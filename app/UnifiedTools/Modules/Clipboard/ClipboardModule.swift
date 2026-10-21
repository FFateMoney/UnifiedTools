import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Clipboard history: records text and file copies, and pastes any of them back from a panel.
@MainActor
@Observable
final class ClipboardModule: Module {
    private static let defaultHotkey = HotkeyCenter.Hotkey(
        keyCode: kVK_ANSI_V,
        modifiers: cmdKey | shiftKey,
        label: "V"
    )

    let id = "clipboard"
    let title = "剪贴板历史"

    private(set) var isPaused = false

    @ObservationIgnored private var store: ClipboardStore?
    @ObservationIgnored private var monitor: ClipboardMonitor?
    @ObservationIgnored private var panel: ClipboardPanelController?

    // Pasting is a simulated Cmd+V, which needs Accessibility.
    var requiredPermissions: [Permission] { [.accessibility] }

    var actions: [ModuleAction] {
        [
            ModuleAction(id: "clipboard.open", title: "剪贴板历史  \(HotkeyCenter.shared.display(for: "clipboard.open", default: Self.defaultHotkey))") { [weak self] in
                self?.panel?.toggle()
            },
            ModuleAction(id: "clipboard.pause", title: isPaused ? "恢复记录剪贴板" : "暂停记录剪贴板") { [weak self] in
                self?.togglePause()
            },
            ModuleAction(id: "clipboard.clear", title: "清空剪贴板历史…") { [weak self] in
                self?.confirmClear()
            },
        ]
    }

    var settingsView: AnyView? {
        AnyView(ClipboardSettings())
    }

    func start() {
        guard monitor == nil, let store = ClipboardStore() else { return }
        let monitor = ClipboardMonitor(store: store)
        monitor.isPaused = isPaused
        monitor.start()

        self.store = store
        self.monitor = monitor
        panel = ClipboardPanelController(store: store) { [weak self] item in
            self?.paste(item)
        }

        HotkeyCenter.shared.register(id: "clipboard.open", title: "剪贴板历史", defaultHotkey: Self.defaultHotkey) { [weak self] in
            self?.panel?.toggle()
        }
    }

    func stop() {
        HotkeyCenter.shared.unregister(id: "clipboard.open")
        panel?.close()
        monitor?.stop()
        panel = nil
        monitor = nil
        store = nil
    }

    private func togglePause() {
        isPaused.toggle()
        monitor?.isPaused = isPaused
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "清空剪贴板历史?"
        alert.informativeText = "所有已记录的内容都会被删除,无法恢复。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store?.clear()
        }
    }

    private func paste(_ item: ClipItem) {
        store?.touch(item.id)
        monitor?.write(item)
        // Without Accessibility the item is only put on the pasteboard; the user pastes by hand.
        guard Permission.accessibility.isGranted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            Self.sendPasteShortcut()
        }
    }

    private nonisolated static func sendPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
