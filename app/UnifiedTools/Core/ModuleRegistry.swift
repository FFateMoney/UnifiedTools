import Foundation
import Observation

@MainActor
@Observable
final class ModuleRegistry {
    static let shared = ModuleRegistry()

    private(set) var modules: [any Module] = []
    private(set) var disabled: Set<String> = Settings.disabledModules

    func register(_ module: any Module) {
        guard !modules.contains(where: { $0.id == module.id }) else { return }
        modules.append(module)
    }

    func isEnabled(_ module: any Module) -> Bool {
        !disabled.contains(module.id)
    }

    func setEnabled(_ module: any Module, _ enabled: Bool) {
        if enabled {
            disabled.remove(module.id)
            module.start()
        } else {
            disabled.insert(module.id)
            module.stop()
        }
        Settings.disabledModules = disabled
    }

    func startEnabled() {
        for module in modules where isEnabled(module) {
            module.start()
        }
    }
}
