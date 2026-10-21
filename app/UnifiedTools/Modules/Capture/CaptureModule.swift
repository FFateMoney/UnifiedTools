import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Region screenshots: copy, save, pin to the screen, or recognise the text in them.
@MainActor
final class CaptureModule: Module {
    // ⌘⇧A is taken by macOS's own "copy selected area" screenshot shortcut on many setups.
    private static let defaultHotkey = HotkeyCenter.Hotkey(
        keyCode: kVK_ANSI_A,
        modifiers: controlKey | optionKey,
        label: "A"
    )

    let id = "capture"
    let title = "截图"

    private var overlay: SelectionOverlay?
    private var grabbing = false
    private var pins: [PinWindow] = []

    var requiredPermissions: [Permission] { [.screenRecording] }

    var actions: [ModuleAction] {
        [ModuleAction(id: "capture.start", title: "截图  \(HotkeyCenter.shared.display(for: "capture.start", default: Self.defaultHotkey))") { [weak self] in
            self?.toggleCapture()
        }]
    }

    var settingsView: AnyView? {
        AnyView(CaptureSettings())
    }

    func start() {
        HotkeyCenter.shared.register(id: "capture.start", title: "截图", defaultHotkey: Self.defaultHotkey) { [weak self] in
            self?.toggleCapture()
        }
    }

    func stop() {
        HotkeyCenter.shared.unregister(id: "capture.start")
        overlay?.cancel()
        for pin in pins {
            pin.orderOut(nil)
        }
        pins.removeAll()
    }

    private func toggleCapture() {
        if let overlay {
            overlay.cancel()
            return
        }
        guard !grabbing else { return }

        guard Permission.screenRecording.isGranted else {
            PermissionCenter.shared.promptForMissing([.screenRecording], title: "需要授权才能截图")
            return
        }

        grabbing = true
        Task { @MainActor in
            defer { grabbing = false }
            do {
                let shots = try await ScreenGrabber.grabAll()
                guard !shots.isEmpty else {
                    Toast.show("没有可截取的屏幕")
                    return
                }
                overlay = SelectionOverlay(
                    shots: shots,
                    onAction: { [weak self] action, selection in self?.handle(action, selection) },
                    onClose: { [weak self] in self?.overlay = nil }
                )
            } catch {
                Toast.show("截图失败:\(error.localizedDescription)")
            }
        }
    }

    private func handle(_ action: SelectionOverlay.Action, _ selection: SelectionOverlay.Selection) {
        let image = CaptureOutput.nsImage(selection)
        switch action {
        case .copy:
            CaptureOutput.copy(image)
        case .save:
            CaptureOutput.save(image)
        case .pin:
            let pin = PinWindow(image: image, at: selection.screenRect) { [weak self] closed in
                self?.pins.removeAll { $0 === closed }
            }
            pins.append(pin)
            pin.orderFrontRegardless()
        case .ocr:
            recognizeText(in: selection.image)
        }
    }

    private func recognizeText(in image: CGImage) {
        Toast.show("正在识别文字…", duration: 60)
        Task { @MainActor in
            let text = await TextRecognizer.recognize(image)
            Toast.hide()
            guard !text.isEmpty else {
                Toast.show("没有识别到文字")
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            OCRResultPanel.show(text: text)
        }
    }
}

private struct CaptureSettings: View {
    var body: some View {
        LabeledContent("保存位置") {
            Button("在访达中打开") {
                let directory = CaptureOutput.saveDirectory
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(directory)
            }
        }
        Text("截图保存在 图片/UnifiedTools。选区确定后按回车可直接复制,Esc 取消。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
