import AppKit
import ScreenCaptureKit

struct ScreenShot {
    let screen: NSScreen
    let image: CGImage
}

enum ScreenGrabber {
    /// One full-resolution frame per connected display, taken before any overlay appears.
    @MainActor
    static func grabAll() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [ScreenShot] = []

        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { continue }

            let configuration = SCStreamConfiguration()
            configuration.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
            configuration.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
            configuration.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            shots.append(ScreenShot(screen: screen, image: image))
        }
        return shots
    }
}
