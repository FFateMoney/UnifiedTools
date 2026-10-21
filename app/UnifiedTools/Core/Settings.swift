import Foundation

/// Thin wrapper over UserDefaults so keys live in one place.
enum Settings {
    private static let disabledModulesKey = "disabledModules"

    /// Also read by `@AppStorage` in the settings window.
    static let cleanModeTimeoutKey = "cleanMode.timeoutSeconds"
    static let cleanModeTimeoutDefault = 120

    static let clipboardRecordImagesKey = "clipboard.recordImages"
    static let clipboardMaxItemsKey = "clipboard.maxItems"
    static let clipboardMaxItemsDefault = 500
    private static let clipboardBlacklistKey = "clipboard.blacklist"
    static let clipboardBlacklistDefault = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    static var disabledModules: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: disabledModulesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: disabledModulesKey) }
    }

    static var clipboardRecordImages: Bool {
        UserDefaults.standard.object(forKey: clipboardRecordImagesKey) as? Bool ?? true
    }

    static var clipboardMaxItems: Int {
        let stored = UserDefaults.standard.integer(forKey: clipboardMaxItemsKey)
        return stored > 0 ? stored : clipboardMaxItemsDefault
    }

    static var clipboardBlacklist: [String] {
        get { UserDefaults.standard.stringArray(forKey: clipboardBlacklistKey) ?? clipboardBlacklistDefault }
        set { UserDefaults.standard.set(newValue, forKey: clipboardBlacklistKey) }
    }

    static var cleanModeTimeout: Int {
        let stored = UserDefaults.standard.integer(forKey: cleanModeTimeoutKey)
        return stored > 0 ? stored : cleanModeTimeoutDefault
    }
}
