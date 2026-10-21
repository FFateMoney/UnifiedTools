import SwiftUI

struct SettingsView: View {
    let registry: ModuleRegistry
    @State private var permissions = PermissionCenter.shared
    @State private var hotkeys = HotkeyCenter.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("权限") {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, center: permissions)
                }
            }

            if !hotkeys.entries.isEmpty {
                Section("快捷键") {
                    ForEach(hotkeys.entries) { entry in
                        HotkeyRow(entry: entry, center: hotkeys)
                    }
                    Text("点按键组合后按下新的快捷键,Esc 取消。需包含 ⌘、⌃ 或 ⌥。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("通用") {
                Toggle("开机自启", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        do {
                            try LaunchAtLogin.set(newValue)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                        }
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                ))
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("模块") {
                if registry.modules.isEmpty {
                    Text("暂无模块").foregroundStyle(.secondary)
                }
                ForEach(registry.modules, id: \.id) { module in
                    Toggle(module.title, isOn: Binding(
                        get: { registry.isEnabled(module) },
                        set: { registry.setEnabled(module, $0) }
                    ))
                }
            }

            ForEach(registry.modules, id: \.id) { module in
                if registry.isEnabled(module), let moduleSettings = module.settingsView {
                    Section(module.title) { moduleSettings }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            permissions.refresh()
            permissions.startPolling()
            launchAtLogin = LaunchAtLogin.isEnabled
        }
        .onDisappear { permissions.stopPolling() }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let center: PermissionCenter

    var body: some View {
        let granted = center.isGranted(permission)
        HStack {
            VStack(alignment: .leading) {
                Text(permission.title)
                Text(permission.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("授权") { center.request(permission) }
            }
        }
    }
}
