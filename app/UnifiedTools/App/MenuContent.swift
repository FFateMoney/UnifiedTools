import AppKit
import SwiftUI

struct MenuContent: View {
    let registry: ModuleRegistry

    var body: some View {
        ForEach(registry.modules, id: \.id) { module in
            if registry.isEnabled(module) {
                ForEach(module.actions) { action in
                    Button(action.title) { action.perform() }
                }
            }
        }

        if !registry.modules.isEmpty {
            Divider()
        }

        Button("打开主窗口") {
            MainWindowController.shared.show()
        }

        Button("设置…") {
            MainWindowController.shared.show(page: .settings)
        }
        .keyboardShortcut(",")

        Button("退出 UnifiedTools") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
