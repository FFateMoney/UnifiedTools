import AppKit
import Carbon.HIToolbox
import Observation

/// Registers every global shortcut in one place, remembers the user's own choices,
/// and reports shortcuts that another app or macOS itself already uses.
@MainActor
@Observable
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    struct Hotkey: Codable, Equatable {
        /// Virtual key code, e.g. `kVK_ANSI_V`.
        let keyCode: Int
        /// Carbon modifier mask, e.g. `cmdKey | shiftKey`.
        let modifiers: Int
        /// The key as it should be shown, e.g. "V".
        let label: String

        var display: String {
            var text = ""
            if modifiers & controlKey != 0 { text += "⌃" }
            if modifiers & optionKey != 0 { text += "⌥" }
            if modifiers & shiftKey != 0 { text += "⇧" }
            if modifiers & cmdKey != 0 { text += "⌘" }
            return text + label
        }

        init(keyCode: Int, modifiers: Int, label: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.label = label
        }

        /// A key press captured while recording. Needs ⌘, ⌃ or ⌥, except for function keys,
        /// so a plain letter can never become a global shortcut.
        init?(event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var modifiers = 0
            if flags.contains(.command) { modifiers |= cmdKey }
            if flags.contains(.control) { modifiers |= controlKey }
            if flags.contains(.option) { modifiers |= optionKey }
            if flags.contains(.shift) { modifiers |= shiftKey }

            let keyCode = Int(event.keyCode)
            let isFunctionKey = Self.functionKeys[keyCode] != nil
            guard modifiers & (cmdKey | controlKey | optionKey) != 0 || isFunctionKey else { return nil }

            self.init(keyCode: keyCode, modifiers: modifiers, label: Self.label(for: event))
        }

        private static let functionKeys: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]

        private static let namedKeys: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        ]

        private static func label(for event: NSEvent) -> String {
            let code = Int(event.keyCode)
            if let name = functionKeys[code] ?? namedKeys[code] { return name }
            if let text = event.charactersIgnoringModifiers?.uppercased(), !text.isEmpty { return text }
            return "Key\(code)"
        }
    }

    enum Status: Equatable {
        case active
        /// Another app already registered this combination.
        case conflict
        /// macOS has this combination bound to one of its own shortcuts, so both would fire.
        case systemConflict
        case failed(Int)
    }

    struct Entry: Identifiable {
        let id: String
        let title: String
        let hotkey: Hotkey
        let defaultHotkey: Hotkey
        let status: Status
    }

    private struct Definition {
        let title: String
        let defaultHotkey: Hotkey
        let handler: () -> Void
    }

    private(set) var entries: [Entry] = []

    @ObservationIgnored private var definitions: [String: Definition] = [:]
    @ObservationIgnored private var refs: [String: EventHotKeyRef] = [:]
    @ObservationIgnored private var numericIDs: [String: UInt32] = [:]
    @ObservationIgnored private var handlers: [UInt32: () -> Void] = [:]
    @ObservationIgnored private var nextID: UInt32 = 1
    @ObservationIgnored private var eventHandler: EventHandlerRef?

    /// Registers a shortcut, using the user's saved choice if there is one.
    func register(id: String, title: String, defaultHotkey: Hotkey, handler: @escaping () -> Void) {
        definitions[id] = Definition(title: title, defaultHotkey: defaultHotkey, handler: handler)
        activate(id)
    }

    func unregister(id: String) {
        releaseCarbon(id)
        definitions.removeValue(forKey: id)
        entries.removeAll { $0.id == id }
    }

    /// The shortcut to show in menus, whether or not its module is currently running.
    func display(for id: String, default defaultHotkey: Hotkey) -> String {
        (entries.first { $0.id == id }?.hotkey ?? Self.saved(id) ?? defaultHotkey).display
    }

    func update(id: String, to hotkey: Hotkey) {
        guard definitions[id] != nil else { return }
        if let data = try? JSONEncoder().encode(hotkey) {
            UserDefaults.standard.set(data, forKey: Self.storageKey(id))
        }
        activate(id)
    }

    func reset(id: String) {
        UserDefaults.standard.removeObject(forKey: Self.storageKey(id))
        activate(id)
    }

    /// Lets the recorder see key presses that would otherwise trigger a shortcut.
    func suspend() {
        for id in Array(refs.keys) {
            releaseCarbon(id)
        }
    }

    func resume() {
        for id in definitions.keys {
            activate(id)
        }
    }

    // MARK: - Registration

    private func activate(_ id: String) {
        guard let definition = definitions[id] else { return }
        releaseCarbon(id)
        installEventHandlerIfNeeded()

        let hotkey = Self.saved(id) ?? definition.defaultHotkey
        let numeric = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let result = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            UInt32(hotkey.modifiers),
            EventHotKeyID(signature: OSType(0x5554_4B59), id: numeric),
            GetApplicationEventTarget(),
            0,
            &ref
        )

        let status: Status
        if result == noErr, let ref {
            refs[id] = ref
            numericIDs[id] = numeric
            handlers[numeric] = definition.handler
            status = SystemShortcuts.isTaken(hotkey) ? .systemConflict : .active
        } else if result == OSStatus(eventHotKeyExistsErr) {
            status = .conflict
        } else {
            status = .failed(Int(result))
        }

        let entry = Entry(
            id: id,
            title: definition.title,
            hotkey: hotkey,
            defaultHotkey: definition.defaultHotkey,
            status: status
        )
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    private func releaseCarbon(_ id: String) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        if let numeric = numericIDs.removeValue(forKey: id) {
            handlers.removeValue(forKey: numeric)
        }
    }

    private static func storageKey(_ id: String) -> String { "hotkey.\(id)" }

    private static func saved(_ id: String) -> Hotkey? {
        guard let data = UserDefaults.standard.data(forKey: storageKey(id)) else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }

    fileprivate func fire(_ numeric: UInt32) {
        handlers[numeric]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(0x686B_6964), // 'hkid' (typeEventHotKey)
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                MainActor.assumeIsolated { HotkeyCenter.shared.fire(hotKeyID.id) }
                return noErr
            },
            1,
            &spec,
            nil,
            &eventHandler
        )
    }
}

/// macOS's own keyboard shortcuts (screenshots, Spotlight, Mission Control...), read from system preferences.
enum SystemShortcuts {
    // NSEvent modifier bits as stored in com.apple.symbolichotkeys.
    private static let shift = 0x20000
    private static let control = 0x40000
    private static let option = 0x80000
    private static let command = 0x100000

    static func isTaken(_ hotkey: HotkeyCenter.Hotkey) -> Bool {
        guard let all = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        ) as? [String: Any] else { return false }

        var wanted = 0
        if hotkey.modifiers & shiftKey != 0 { wanted |= shift }
        if hotkey.modifiers & controlKey != 0 { wanted |= control }
        if hotkey.modifiers & optionKey != 0 { wanted |= option }
        if hotkey.modifiers & cmdKey != 0 { wanted |= command }
        let mask = shift | control | option | command

        for case let item as [String: Any] in all.values {
            guard (item["enabled"] as? NSNumber)?.boolValue == true,
                  let value = item["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Int],
                  parameters.count >= 3
            else { continue }
            if parameters[1] == hotkey.keyCode && parameters[2] & mask == wanted {
                return true
            }
        }
        return false
    }
}
