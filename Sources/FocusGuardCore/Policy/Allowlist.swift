import Foundation

enum AccessDecision: Equatable, Sendable {
    case allowed
    case violation(ViolationKind)

    var isAllowed: Bool { self == .allowed }
}

/// The single place that decides whether what you are doing right now is permitted.
/// Everything else (menu items, monitors, panels) routes through this.
enum Allowlist {
    static func decide(
        app: AppIdentity,
        session: Session,
        baseline: BaselineAllowlist
    ) -> AccessDecision {
        if baseline.contains(app.bundleID) { return .allowed }
        if session.allows(bundleID: app.bundleID) { return .allowed }
        return .violation(.app(app))
    }

    /// URL rules. The blocklist wins over everything except an exact pinned page in a full
    /// session, which is the rule proposed in the Phase 0 audit (3.5).
    static func decide(
        url: URL,
        in browser: AppIdentity,
        session: Session,
        blocklist: Blocklist
    ) -> AccessDecision {
        guard let host = URLNormalizer.host(of: url) else { return .allowed }

        if let blocked = blocklist.blocks(host: host) {
            if session.kind == .full, isPinned(url: url, session: session) {
                return .allowed
            }
            return .violation(.blockedSite(domain: blocked, url: url.absoluteString))
        }

        switch session.kind {
        case .open:
            return .allowed
        case .full:
            if session.allowAllNonBlockedSites { return .allowed }
            if session.allowedSites.isEmpty { return .allowed }
            if matchesAllowedSite(url: url, host: host, session: session) { return .allowed }
            if hasPin(forHost: host, session: session) {
                return .violation(.unpinnedPage(host: host, url: url.absoluteString))
            }
            return .violation(.unlistedSite(host: host, url: url.absoluteString))
        }
    }

    /// A browser we cannot read is a browser we cannot police (3.5).
    static func canAllowlist(bundleID: String) -> Bool {
        !isBrowserLike(bundleID: bundleID) || KnownBrowser.isBrowser(bundleID: bundleID)
    }

    /// Bundle IDs we recognize as browsers even though we cannot read their URLs.
    static let unsupportedBrowserBundleIDs: Set<String> = [
        "ai.perplexity.comet",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.kagi.kagimacOS",
        "app.zen-browser.zen",
        "com.apple.SafariTechnologyPreview"
    ]

    static func isBrowserLike(bundleID: String) -> Bool {
        KnownBrowser.isBrowser(bundleID: bundleID) || unsupportedBrowserBundleIDs.contains(bundleID)
    }

    private static func matchesAllowedSite(url: URL, host: String, session: Session) -> Bool {
        for rule in session.allowedSites {
            switch rule.scope {
            case .domain:
                if host == rule.pattern || host.hasSuffix("." + rule.pattern) { return true }
            case .pinnedPage:
                if URLNormalizer.matches(url: url, pinnedPattern: rule.pattern) { return true }
            }
        }
        return false
    }

    private static func isPinned(url: URL, session: Session) -> Bool {
        session.allowedSites.contains { rule in
            rule.scope == .pinnedPage && URLNormalizer.matches(url: url, pinnedPattern: rule.pattern)
        }
    }

    private static func hasPin(forHost host: String, session: Session) -> Bool {
        session.allowedSites.contains { rule in
            guard rule.scope == .pinnedPage else { return false }
            guard let pinHost = URL(string: rule.pattern).flatMap(URLNormalizer.host(of:)) else { return false }
            return pinHost == host
        }
    }
}
