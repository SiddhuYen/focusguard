import Foundation

struct PolicyResult: Equatable {
    enum Kind: Equatable {
        case allowed
        case appSwitchViolation
        case blockedWebsite(domain: String, url: URL)
    }

    let kind: Kind
}

@MainActor
final class FocusPolicyEngine {
    // Supported browsers for URL checks
    static let safariBundleID = "com.apple.Safari"
    static let chromeBundleID = "com.google.Chrome"

    private let browserBundleIDs: Set<String> = [
        FocusPolicyEngine.safariBundleID,
        FocusPolicyEngine.chromeBundleID
    ]

    // Default blocked domains (subdomain matching supported)
    // Keep this list obvious and centralized for MVP.
    private let defaultBlockedDomains: Set<String> = [
        "youtube.com",
        "youtu.be",
        "instagram.com",
        "tiktok.com",
        "snapchat.com",
        "reddit.com",
        "x.com",
        "twitter.com",
        "facebook.com",
        "netflix.com",
        "twitch.tv"
    ]

    private let urlReader: BrowserURLReader

    init(urlReader: BrowserURLReader = BrowserURLReader()) {
        self.urlReader = urlReader
    }

    func isBrowser(bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }

    // Evaluate current state relative to the session and active app.
    // - If the focus target is a normal app: allowed only when current app is the same or whitelisted by FocusRules (handled by caller if desired). If different -> violation.
    // - If the focus target is a browser: staying in that browser is allowed unless URL matches a blocked domain. Switching away from the browser is always a violation.
    func evaluate(session: FocusSession, currentApp: RunningApp, settings: UserSettings, focusRules: FocusRules) -> PolicyResult {
        let allowedBundleID = session.allowedBundleID
        let currentBundleID = currentApp.bundleIdentifier
        let isTargetBrowser = isBrowser(bundleID: allowedBundleID)

        if !isTargetBrowser {
            // Normal app behavior: current behavior stays the same.
            if currentBundleID == allowedBundleID { return PolicyResult(kind: .allowed) }
            // Allow some system apps per rules
            if focusRules.allowedBundleIDs.contains(currentBundleID) { return PolicyResult(kind: .allowed) }
            return PolicyResult(kind: .appSwitchViolation)
        }

        // Target is a browser
        if currentBundleID != allowedBundleID {
            // Switching away from the browser still counts as a violation (override allowlist)
            return PolicyResult(kind: .appSwitchViolation)
        }

        // Still in the browser: check URL
        guard let url = urlReader.activeTabURL(forBrowserBundleID: allowedBundleID) else {
            // If we can't read URL, treat as allowed to be safe (no false positives)
            return PolicyResult(kind: .allowed)
        }

        if let domain = blockedDomain(for: url) {
            return PolicyResult(kind: .blockedWebsite(domain: domain, url: url))
        }

        return PolicyResult(kind: .allowed)
    }

    // Returns the blocked domain that matches this URL's host, if any.
    private func blockedDomain(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        for domain in defaultBlockedDomains {
            if host == domain { return domain }
            if host.hasSuffix("." + domain) { return domain }
        }
        return nil
    }
}
