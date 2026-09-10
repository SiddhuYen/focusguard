import AppKit
import Foundation
import ServiceManagement

/// Sleeping the Mac and launching at login. Both are small, both are easy to get wrong.
enum SystemControl {
    /// `pmset sleepnow` is the documented way for a logged-in user; the man page only
    /// requires root to *modify settings*, not to run an action.
    @discardableResult
    static func sleepNow() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return true }
        } catch {
            NSLog("FocusGuard: pmset failed: \(error.localizedDescription)")
        }
        return sleepViaSystemEvents()
    }

    private static func sleepViaSystemEvents() -> Bool {
        let script = NSAppleScript(source: "tell application \"System Events\" to sleep")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            NSLog("FocusGuard: System Events sleep failed: \(error)")
            return false
        }
        return true
    }

    /// Release builds register as a login item so the gate is there at login. Debug builds
    /// never do: a development build must not be able to wedge itself into every boot.
    static func syncLoginItem(enabled: Bool) {
        #if DEBUG
        return
        #else
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("FocusGuard: login item update failed: \(error.localizedDescription)")
        }
        #endif
    }

    static var loginItemStatus: String {
        #if DEBUG
        return "Disabled in debug builds"
        #else
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Needs approval in System Settings → Login Items"
        case .notRegistered: return "Not registered"
        case .notFound: return "Not found"
        @unknown default: return "Unknown"
        }
        #endif
    }
}
