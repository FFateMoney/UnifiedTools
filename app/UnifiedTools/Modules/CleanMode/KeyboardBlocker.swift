import CoreGraphics
import Foundation

/// Swallows keyboard events system-wide through a session event tap.
/// The tap lives and dies with the process, so a crash or quit always releases the keyboard.
@MainActor
final class KeyboardBlocker {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isActive: Bool { tap != nil }

    /// Returns false when the system refuses the tap, which means a permission is missing.
    func start() -> Bool {
        guard tap == nil else { return true }

        // NX_SYSDEFINED (14) carries media keys: volume, brightness, play/pause.
        let sysDefined: CGEventMask = 1 << 14
        let mask: CGEventMask = sysDefined
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // The system turns a slow tap off; without this the keyboard silently comes back.
                if let refcon {
                    MainActor.assumeIsolated {
                        Unmanaged<KeyboardBlocker>.fromOpaque(refcon).takeUnretainedValue().reenable()
                    }
                }
                return Unmanaged.passUnretained(event)
            }
            return nil
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            return false
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = runLoopSource
        return true
    }

    func stop() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(port)
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}
