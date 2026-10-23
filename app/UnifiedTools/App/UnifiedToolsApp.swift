import SwiftUI

@main
struct UnifiedToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var registry = ModuleRegistry.shared

    init() {
        ModuleRegistry.shared.register(CaptureModule())
        ModuleRegistry.shared.register(ClipboardModule())
        ModuleRegistry.shared.register(CleanMode())
        ModuleRegistry.shared.register(NewFileModule())
        ModuleRegistry.shared.register(AppManagerModule())
        ModuleRegistry.shared.startEnabled()
        // Slow background sampling, so memory growth over hours is on record when the page is opened.
        ProcessMonitor.shared.start()
    }

    var body: some Scene {
        MenuBarExtra("UnifiedTools", systemImage: "wrench.and.screwdriver") {
            MenuContent(registry: registry)
        }
        .menuBarExtraStyle(.menu)
    }
}
