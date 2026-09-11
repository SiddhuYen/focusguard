import Foundation

enum SessionKind: String, Codable, Equatable, Sendable {
    case full
    case open
}

enum SessionOutcome: String, Codable, Equatable, Sendable {
    case finished
    case notFinished
    case expired
    case converted
    case abandoned
}

enum ViolationKind: Codable, Equatable, Sendable {
    case app(AppIdentity)
    case blockedSite(domain: String, url: String)
    case unlistedSite(host: String, url: String)
    case unpinnedPage(host: String, url: String)
    case unverifiableURL(browser: String)
}

struct Violation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: ViolationKind
    /// The app that was frontmost when the violation happened.
    let app: AppIdentity

    init(id: UUID = UUID(), timestamp: Date = Date(), kind: ViolationKind, app: AppIdentity) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.app = app
    }

    /// Blocked domains can never be added to a session (3.4), and an unreadable page has
    /// nothing to add: the fix is the permission, not the allowlist (3.5).
    var isAddable: Bool {
        switch kind {
        case .blockedSite, .unverifiableURL: return false
        case .app, .unlistedSite, .unpinnedPage: return true
        }
    }
}

enum AdditionTarget: Codable, Equatable, Sendable {
    case app(AppIdentity)
    case site(SiteRule)
}

struct SessionAddition: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let target: AdditionTarget
    let reason: String

    init(id: UUID = UUID(), timestamp: Date = Date(), target: AdditionTarget, reason: String) {
        self.id = id
        self.timestamp = timestamp
        self.target = target
        self.reason = reason
    }
}

struct AppUsage: Codable, Equatable, Sendable {
    let bundleID: String
    var name: String
    var seconds: TimeInterval
}

/// Legacy timed escape. Kept so historical sessions decode; the flow is removed in Phase 1.
struct Escape: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let duration: TimeInterval
    let reason: String?

    init(id: UUID = UUID(), startedAt: Date = Date(), duration: TimeInterval, reason: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.reason = reason
    }
}

struct Session: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var kind: SessionKind
    var goal: String
    /// The app the session is named after; also the app "Return" sends you back to.
    var anchor: AppIdentity
    var allowedBundleIDs: [String]
    var allowedSites: [SiteRule]
    /// Set at setup when a full session includes a browser but lists no sites (3.5).
    var allowAllNonBlockedSites: Bool
    var startedAt: Date
    /// Wall-clock end, so the timer survives sleep. nil means unbounded (legacy sessions).
    var plannedEnd: Date?
    var endedAt: Date?
    var outcome: SessionOutcome?
    var extensionsUsed: Int
    var presetID: UUID?
    /// Set when this full session grew out of an open one (3.2).
    var convertedFrom: UUID?
    var violations: [Violation]
    var additions: [SessionAddition]
    var appsUsed: [AppUsage]
    var domainsVisited: [String]
    var escapes: [Escape]

    init(
        id: UUID = UUID(),
        kind: SessionKind,
        goal: String,
        anchor: AppIdentity,
        allowedBundleIDs: [String],
        allowedSites: [SiteRule] = [],
        allowAllNonBlockedSites: Bool = false,
        startedAt: Date = Date(),
        plannedEnd: Date? = nil,
        presetID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.goal = goal
        self.anchor = anchor
        self.allowedBundleIDs = allowedBundleIDs
        self.allowedSites = allowedSites
        self.allowAllNonBlockedSites = allowAllNonBlockedSites
        self.startedAt = startedAt
        self.plannedEnd = plannedEnd
        self.endedAt = nil
        self.outcome = nil
        self.extensionsUsed = 0
        self.presetID = presetID
        self.convertedFrom = nil
        self.violations = []
        self.additions = []
        self.appsUsed = []
        self.domainsVisited = []
        self.escapes = []
    }

    var elapsed: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    func remaining(at now: Date = Date()) -> TimeInterval? {
        guard let plannedEnd else { return nil }
        return plannedEnd.timeIntervalSince(now)
    }

    func hasExpired(at now: Date = Date()) -> Bool {
        guard let plannedEnd else { return false }
        return now >= plannedEnd
    }

    func allows(bundleID: String) -> Bool {
        kind == .open || allowedBundleIDs.contains(bundleID)
    }

    mutating func record(_ violation: Violation) {
        violations.append(violation)
    }

    mutating func add(_ addition: SessionAddition) {
        additions.append(addition)
        switch addition.target {
        case .app(let app):
            if !allowedBundleIDs.contains(app.bundleID) { allowedBundleIDs.append(app.bundleID) }
        case .site(let rule):
            if !allowedSites.contains(rule) { allowedSites.append(rule) }
        }
    }

    mutating func noteVisit(host: String) {
        let host = Blocklist.normalize(host)
        guard !host.isEmpty, !domainsVisited.contains(host) else { return }
        domainsVisited.append(host)
    }

    mutating func noteUsage(of app: AppIdentity, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        if let index = appsUsed.firstIndex(where: { $0.bundleID == app.bundleID }) {
            appsUsed[index].seconds += seconds
            appsUsed[index].name = app.name
        } else {
            appsUsed.append(AppUsage(bundleID: app.bundleID, name: app.name, seconds: seconds))
        }
    }
}
