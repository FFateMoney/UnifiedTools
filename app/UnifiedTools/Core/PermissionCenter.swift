import AppKit
import ApplicationServices
import CoreGraphics
import Observation

enum Permission: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility
    case inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "屏幕录制"
        case .accessibility: "辅助功能"
        case .inputMonitoring: "输入监控"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: "截图、录屏"
        case .accessibility: "模拟粘贴"
        case .inputMonitoring: "清洁模式拦截键盘"
        }
    }

    fileprivate var settingsAnchor: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        }
    }
}

/// Single place to check, request and explain the system permissions every module shares.
@MainActor
@Observable
final class PermissionCenter {
    static let shared = PermissionCenter()

    private(set) var granted: [Permission: Bool] = [:]
    private var timer: Timer?

    init() {
        refresh()
    }

    func isGranted(_ permission: Permission) -> Bool {
        granted[permission] ?? false
    }

    func refresh() {
        for permission in Permission.allCases {
            let value = permission.isGranted
            if granted[permission] != value {
                granted[permission] = value
            }
        }
    }

    /// Triggers the system prompt once, then falls back to opening System Settings.
    func request(_ permission: Permission) {
        switch permission {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
        openSystemSettings(permission)
    }

    /// Explains what is missing and offers to jump to the first permission that needs granting.
    func promptForMissing(_ missing: [Permission], title: String) {
        guard let first = missing.first else { return }
        let names = missing.map(\.title).joined(separator: "、")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "请在系统设置中为 UnifiedTools 开启:\(names)。授权后再试一次。"
        alert.addButton(withTitle: "去授权")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            request(first)
        }
    }

    func openSystemSettings(_ permission: Permission) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Grants happen outside the app, so poll while a window that shows them is open.
    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
