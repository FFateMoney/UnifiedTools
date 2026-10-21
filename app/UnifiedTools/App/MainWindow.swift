import AppKit
import Observation
import SwiftUI

enum MainPage: String, CaseIterable, Identifiable {
    case overview, operations, apps, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .operations: "操作"
        case .apps: "应用管理"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .operations: "bolt"
        case .apps: "trash.square"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class MainWindowModel {
    static let shared = MainWindowModel()

    var page = MainPage.overview
    /// Kept here so the app list and its sizes survive switching pages.
    let appManager = AppManagerModel()
}

/// The window that opens when you launch the app from Launchpad or click its Dock icon.
@MainActor
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?

    func show(page: MainPage? = nil) {
        if let page {
            MainWindowModel.shared.page = page
        }
        if window == nil {
            window = makeWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "UnifiedTools"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 520)
        window.titlebarSeparatorStyle = .line

        let hosting = NSHostingView(rootView: MainView(model: .shared, registry: .shared))
        hosting.sizingOptions = []
        window.contentView = hosting

        window.center()
        window.setFrameAutosaveName("UnifiedToolsMainWindow")
        return window
    }
}

struct MainView: View {
    @Bindable var model: MainWindowModel
    let registry: ModuleRegistry

    var body: some View {
        // A plain sidebar and detail instead of NavigationSplitView: that container adds its own
        // translucent toolbar strip across the top, which hid the first rows of every page.
        HStack(spacing: 0) {
            List(
                MainPage.allCases,
                selection: Binding<MainPage?>(
                    get: { model.page },
                    set: { if let page = $0 { model.page = page } }
                )
            ) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            Group {
                switch model.page {
                case .overview: SystemStatusView()
                case .operations: OperationsView(registry: registry)
                case .apps: AppManagerView(model: model.appManager)
                case .settings: SettingsView(registry: registry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// What used to be the overview: one-click actions for every module, and the permission check.
private struct OperationsView: View {
    let registry: ModuleRegistry
    @State private var permissions = PermissionCenter.shared

    var body: some View {
        Form {
            Section("快捷操作") {
                ForEach(registry.modules, id: \.id) { module in
                    if registry.isEnabled(module) {
                        ForEach(module.actions) { action in
                            Button(action.title) { action.perform() }
                        }
                    }
                }
            }

            Section("权限") {
                let missing = Permission.allCases.filter { !permissions.isGranted($0) }
                if missing.isEmpty {
                    Label("需要的权限都已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    ForEach(missing) { permission in
                        HStack {
                            Label("\(permission.title)未授权(\(permission.detail))", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("授权") { permissions.request(permission) }
                        }
                    }
                }
            }

            Section {
                Text("关闭窗口后应用继续在菜单栏里运行,截图、剪贴板历史和快捷键都照常可用。要彻底退出,用菜单栏里的“退出”或 ⌘Q。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            permissions.refresh()
            permissions.startPolling()
        }
        .onDisappear { permissions.stopPolling() }
    }
}
