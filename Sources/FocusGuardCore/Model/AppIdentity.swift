import Foundation

/// An app, stripped of AppKit. The app layer maps NSRunningApplication onto this at the
/// boundary so everything below is testable without a window server.
struct AppIdentity: Codable, Equatable, Hashable, Sendable {
    let bundleID: String
    let name: String

    init(bundleID: String, name: String? = nil) {
        self.bundleID = bundleID
        self.name = name ?? bundleID
    }
}

/// Browsers whose active tab URL we can actually read. Anything not listed here is
/// unverifiable, and per the fail-closed rule it cannot be allowlisted in a session.
enum KnownBrowser: String, CaseIterable, Codable, Sendable {
    case safari = "com.apple.Safari"
    case chrome = "com.google.Chrome"
    case edge = "com.microsoft.edgemac"
    case brave = "com.brave.Browser"
    case firefox = "org.mozilla.firefox"
    case firefoxDeveloper = "org.mozilla.firefoxdeveloperedition"
    case firefoxNightly = "org.mozilla.nightly"

    init?(bundleID: String) {
        guard let match = KnownBrowser(rawValue: bundleID) else { return nil }
        self = match
    }

    /// Firefox has no AppleScript URL support; we read it out of the accessibility tree,
    /// which is best-effort. Fail-closed thresholds treat it differently.
    var readsURLViaAccessibility: Bool {
        switch self {
        case .firefox, .firefoxDeveloper, .firefoxNightly: return true
        case .safari, .chrome, .edge, .brave: return false
        }
    }

    static func isBrowser(bundleID: String) -> Bool {
        KnownBrowser(bundleID: bundleID) != nil
    }
}

/// Bundle IDs that are allowed in every session and never counted as a violation (3.4).
/// The system list is deliberately conservative: it is built from what actually becomes
/// frontmost, which the debug observer logs so it can be verified rather than guessed.
struct BaselineAllowlist: Codable, Equatable, Sendable {
    var systemBundleIDs: Set<String>
    var passwordManagerBundleIDs: Set<String>
    var extraBundleIDs: Set<String>
    var selfBundleID: String

    static let systemDefaults: Set<String> = [
        "com.apple.finder",
        "com.apple.loginwindow",
        "com.apple.SecurityAgent",
        "com.apple.coreservices.uiagent",
        "com.apple.UserNotificationCenter",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systempreferences",
        "com.apple.screencaptureui",
        "com.apple.screenshot.launcher",
        "com.apple.EscrowSecurityAlert",
        "com.apple.security.Keychain-Circle-Notification",
        "com.apple.OSDUIHelper",
        "com.apple.ScreenSaver.Engine"
    ]

    init(
        systemBundleIDs: Set<String> = BaselineAllowlist.systemDefaults,
        passwordManagerBundleIDs: Set<String> = [],
        extraBundleIDs: Set<String> = [],
        selfBundleID: String = "app.focusguard.mvp"
    ) {
        self.systemBundleIDs = systemBundleIDs
        self.passwordManagerBundleIDs = passwordManagerBundleIDs
        self.extraBundleIDs = extraBundleIDs
        self.selfBundleID = selfBundleID
    }

    var all: Set<String> {
        systemBundleIDs.union(passwordManagerBundleIDs).union(extraBundleIDs).union([selfBundleID])
    }

    func contains(_ bundleID: String) -> Bool {
        all.contains(bundleID)
    }
}
