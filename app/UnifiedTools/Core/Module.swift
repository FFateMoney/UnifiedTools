import Foundation
import SwiftUI

/// A menu entry a module contributes to the menu bar.
struct ModuleAction: Identifiable {
    let id: String
    let title: String
    let perform: @MainActor () -> Void
}

/// A self-contained feature (capture, clipboard, clean mode...).
/// Modules are registered once and started or stopped from the settings toggle.
@MainActor
protocol Module: AnyObject {
    var id: String { get }
    var title: String { get }
    var requiredPermissions: [Permission] { get }
    var actions: [ModuleAction] { get }
    /// Extra controls shown in the settings window while the module is enabled.
    var settingsView: AnyView? { get }

    func start()
    func stop()
}

extension Module {
    var settingsView: AnyView? { nil }
}
