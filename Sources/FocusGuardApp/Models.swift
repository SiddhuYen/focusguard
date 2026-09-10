import AppKit
import Foundation

/// AppKit's view of a running app. Everything below the UI layer uses AppIdentity.
struct RunningApp: Identifiable, Equatable {
    var id: String { "\(bundleIdentifier)-\(processIdentifier)" }

    let name: String
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let icon: NSImage?

    init?(runningApplication: NSRunningApplication) {
        guard let bundleIdentifier = runningApplication.bundleIdentifier else { return nil }
        self.name = runningApplication.localizedName ?? bundleIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = runningApplication.processIdentifier
        self.icon = runningApplication.icon
    }

    var identity: AppIdentity {
        AppIdentity(bundleID: bundleIdentifier, name: name)
    }
}

enum StopReason: String {
    case user
    case quit
}
