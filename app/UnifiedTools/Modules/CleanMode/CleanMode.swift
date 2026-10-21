import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Lets the user wipe the screen and keyboard: a black screen, a dead keyboard, or both.
/// Every session ends on its own after the configured timeout.
@MainActor
@Observable
final class CleanMode: Module {
    enum Mode: CaseIterable {
        case blackout, keyboard, both

        var title: String {
            switch self {
            case .blackout: "仅黑屏"
            case .keyboard: "仅锁定键盘"
            case .both: "黑屏并锁定键盘"
            }
        }

        var locksKeyboard: Bool { self != .blackout }
        var blacksOut: Bool { self != .keyboard }
    }

    private static let defaultHotkey = HotkeyCenter.Hotkey(
        keyCode: kVK_ANSI_K,
        modifiers: controlKey | optionKey | cmdKey,
        label: "K"
    )

    let id = "cleanMode"
    let title = "清洁模式"

    private(set) var activeMode: Mode?
    private(set) var remaining = 0

    @ObservationIgnored private let blackout = BlackoutController()
    @ObservationIgnored private let blocker = KeyboardBlocker()
    @ObservationIgnored private var hud: LockHUD?
    @ObservationIgnored private var timer: Timer?

    var requiredPermissions: [Permission] { [.accessibility, .inputMonitoring] }

    var actions: [ModuleAction] {
        if activeMode != nil {
            return [ModuleAction(id: "cleanMode.end", title: "结束清洁模式") { [weak self] in self?.end() }]
        }
        return Mode.allCases.map { mode in
            let hint = mode == .both
                ? "  \(HotkeyCenter.shared.display(for: "cleanMode.both", default: Self.defaultHotkey))"
                : ""
            return ModuleAction(id: "cleanMode.\(mode)", title: mode.title + hint) { [weak self] in self?.begin(mode) }
        }
    }

    var settingsView: AnyView? {
        AnyView(CleanModeSettings())
    }

    func start() {
        // Starts the full wipe. It cannot also end the session: the keyboard is dead by then.
        HotkeyCenter.shared.register(id: "cleanMode.both", title: "黑屏并锁定键盘", defaultHotkey: Self.defaultHotkey) { [weak self] in
            self?.begin(.both)
        }
    }

    func stop() {
        HotkeyCenter.shared.unregister(id: "cleanMode.both")
        end()
    }

    func begin(_ mode: Mode) {
        guard activeMode == nil else { return }

        if mode.locksKeyboard {
            let missing = requiredPermissions.filter { !$0.isGranted }
            guard missing.isEmpty else {
                PermissionCenter.shared.promptForMissing(missing, title: "需要授权才能锁定键盘")
                return
            }
            guard blocker.start() else {
                PermissionCenter.shared.promptForMissing(requiredPermissions, title: "需要授权才能锁定键盘")
                return
            }
        }

        activeMode = mode
        remaining = Settings.cleanModeTimeout

        if mode.blacksOut {
            blackout.start { [weak self] in self?.end() }
        } else {
            // The screen stays visible, so offer an on-screen way out instead of the mouse hold.
            let hud = LockHUD(cleanMode: self)
            hud.show()
            self.hud = hud
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func end() {
        timer?.invalidate()
        timer = nil
        blocker.stop()
        blackout.stop()
        hud?.close()
        hud = nil
        activeMode = nil
        remaining = 0
    }

    private func tick() {
        remaining -= 1
        if remaining <= 0 {
            end()
        }
    }

}

private struct CleanModeSettings: View {
    @AppStorage(Settings.cleanModeTimeoutKey) private var timeout = Settings.cleanModeTimeoutDefault

    var body: some View {
        Stepper(value: $timeout, in: 30...600, step: 30) {
            Text("自动结束时间:\(timeout) 秒")
        }
        Text("黑屏时长按鼠标左键 3 秒可立即退出;仅锁定键盘时点屏幕顶部的“结束”按钮。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
