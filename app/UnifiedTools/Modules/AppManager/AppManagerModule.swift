import Foundation

/// Lists installed apps and removes them with their leftovers. The window itself is a page of the main window.
@MainActor
final class AppManagerModule: Module {
    let id = "appManager"
    let title = "应用管理"

    var requiredPermissions: [Permission] { [] }

    var actions: [ModuleAction] {
        [ModuleAction(id: "appManager.open", title: "应用管理…") {
            MainWindowController.shared.show(page: .apps)
        }]
    }

    func start() {}
    func stop() {}
}
