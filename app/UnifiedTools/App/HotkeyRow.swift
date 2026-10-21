import AppKit
import SwiftUI

/// One line of the shortcut list: click the key combination, press a new one to change it.
struct HotkeyRow: View {
    let entry: HotkeyCenter.Entry
    let center: HotkeyCenter

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()

            Button(recording ? "按下新的快捷键…" : entry.hotkey.display) {
                recording ? stopRecording() : startRecording()
            }
            .font(.body.monospaced())
            .frame(minWidth: 120)

            Button {
                center.reset(id: entry.id)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("恢复默认 \(entry.defaultHotkey.display)")
            .opacity(entry.hotkey == entry.defaultHotkey ? 0 : 1)
            .disabled(entry.hotkey == entry.defaultHotkey)
        }
        .onDisappear { stopRecording() }
    }

    private var warning: String? {
        switch entry.status {
        case .active: nil
        case .conflict: "已被其他应用占用,换一个组合"
        case .systemConflict: "与 macOS 系统快捷键冲突,按下时两边都会响应。请换一个组合,或在系统设置里关掉那一个"
        case .failed(let code): "注册失败 (\(code))"
        }
    }

    private func startRecording() {
        recording = true
        center.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        guard let hotkey = HotkeyCenter.Hotkey(event: event) else {
            // A bare letter would hijack normal typing everywhere.
            NSSound.beep()
            return
        }
        center.update(id: entry.id, to: hotkey)
        stopRecording()
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard recording else { return }
        recording = false
        center.resume()
    }
}
