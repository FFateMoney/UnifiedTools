import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Four-character codes from the Apple Event headers: 'prdt' and 'lgit'.
    private static let keyPropData: AEKeyword = 0x7072_6474
    private static let launchedAsLoginItem: OSType = 0x6C67_6974

    private var openedByLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        openedByLoginItem = event?.paramDescriptor(forKeyword: Self.keyPropData)?.enumCodeValue == Self.launchedAsLoginItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Starting at login should leave only the menu bar item, not pop a window at you.
        if !openedByLoginItem {
            MainWindowController.shared.show()
        }
    }

    /// Clicking the Dock icon or opening the app again from Launchpad while it is already running.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
