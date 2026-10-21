import AppKit
import SwiftUI

/// "复制路径" and "新建文件" in Finder's right-click menu. The work is done by the bundled Finder extension;
/// this module only shows whether macOS has that extension switched on.
@MainActor
final class NewFileModule: Module {
    static let extensionBundleID = "com.jasper.UnifiedTools.NewFile"

    let id = "newFile"
    let title = "Finder 右键菜单"

    var requiredPermissions: [Permission] { [] }
    var actions: [ModuleAction] { [] }

    var settingsView: AnyView? {
        AnyView(NewFileSettings())
    }

    func start() {}
    func stop() {}
}

private struct NewFileSettings: View {
    private enum State {
        case unknown, enabled, disabled
    }

    @SwiftUI.State private var state = State.unknown

    var body: some View {
        LabeledContent("Finder 扩展") {
            switch state {
            case .enabled:
                Label("已开启", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .disabled:
                Label("未开启", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .unknown:
                Text("未检测到").foregroundStyle(.secondary)
            }
        }
        HStack {
            Button("打开扩展设置") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("重新检测") { refresh() }
        }
        Text("在 系统设置 → 通用 → 登录项与扩展 → Finder 扩展 里勾选“UnifiedTools 右键菜单”。之后在 Finder 里右键文件或文件夹可以“复制路径”,在空白处右键可以“新建文件”。要停用,取消勾选即可。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .onAppear(perform: refresh)
    }

    private func refresh() {
        state = Self.queryState()
    }

    /// `pluginkit` prints "+" for an enabled plug-in and "-" for a disabled one; a blank mark means
    /// macOS knows the extension but the user has not switched it on yet.
    private static func queryState() -> State {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-p", "com.apple.FinderSync", "-i", NewFileModule.extensionBundleID]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return .unknown }
        process.waitUntilExit()

        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = output.split(separator: "\n").first(where: { $0.contains(NewFileModule.extensionBundleID) }) else {
            return .unknown
        }
        switch line.first {
        case "+": return .enabled
        default: return .disabled
        }
    }
}
