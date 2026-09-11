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

    static let agentPlistName = "app.focusguard.mvp.agent.plist"

    /// Release builds register a KeepAlive LaunchAgent, so the gate is there at login and
    /// a killed Focus Guard comes back and resumes the session (3.10). Debug builds never
    /// register: a development build must not be able to wedge itself into every boot, or
    /// respawn itself while you are trying to stop it.
    static func syncLaunchAgent(enabled: Bool) {
        #if DEBUG
        return
        #else
        let service = SMAppService.agent(plistName: agentPlistName)
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("FocusGuard: launch agent update failed: \(error.localizedDescription)")
        }
        #endif
    }

    static var launchAtLoginStatusLine: String {
        "Status: \(launchAgentStatus). Turning this off is a loosening change, so it waits 24 hours."
    }

    static var launchAgentStatus: String {
        #if DEBUG
        return "Off in debug builds"
        #else
        switch SMAppService.agent(plistName: agentPlistName).status {
        case .enabled: return "Running as a login agent"
        case .requiresApproval: return "Needs approval in System Settings → General → Login Items"
        case .notRegistered: return "Not registered"
        case .notFound: return "Not found (is the app in /Applications?)"
        @unknown default: return "Unknown"
        }
        #endif
    }
}
