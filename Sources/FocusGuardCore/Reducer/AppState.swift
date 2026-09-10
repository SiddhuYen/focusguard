import Foundation

/// Why the gate is up, and what to say at the top of it.
struct GateContext: Equatable, Sendable {
    var trigger: GateTrigger
    var shownAt: Date
    /// Set when a session ended while you were away, so the gate can ask about it (3.1).
    var lastSession: LastSessionPrompt?
    /// After a session ends, "I'm done: sleep the Mac" is the prominent action (3.1).
    var offerSleep: Bool

    init(trigger: GateTrigger, shownAt: Date, lastSession: LastSessionPrompt? = nil, offerSleep: Bool = false) {
        self.trigger = trigger
        self.shownAt = shownAt
        self.lastSession = lastSession
        self.offerSleep = offerSleep
    }
}

struct LastSessionPrompt: Equatable, Sendable {
    var sessionID: UUID
    var goal: String
    var endedAt: Date
}

enum ReviewReason: String, Codable, Equatable, Sendable {
    case timeUp
    case endedByUser
}

struct OverrideState: Equatable, Sendable {
    var startedAt: Date
    var until: Date
    var reason: String
    /// A session that was running when the override started. It keeps running: the
    /// override suspends enforcement, not the commitment (3.7).
    var suspendedSession: Session?
}

/// Where the app is. There is no "idle": you are either at the gate or in a session,
/// except while overridden or in safe mode.
enum AppPhase: Equatable, Sendable {
    case gate(GateContext)
    case session(Session)
    case intervention(Session, Violation)
    case review(Session, ReviewReason)
    case overridden(OverrideState)
    case safeMode(SafeModeReason)

    var session: Session? {
        switch self {
        case .session(let session),
             .intervention(let session, _),
             .review(let session, _):
            return session
        case .gate, .overridden, .safeMode:
            return nil
        }
    }

    /// True when app switches and URLs are being policed.
    var isEnforcing: Bool {
        switch self {
        case .session, .intervention: return true
        case .gate, .review, .overridden, .safeMode: return false
        }
    }

    var isGate: Bool {
        if case .gate = self { return true }
        return false
    }
}

/// Permission state is an orthogonal flag, not a phase (4.1). Losing Accessibility or
/// Automation must be loud but must never stop the gate from working (3.5).
struct PermissionHealth: Equatable, Sendable, Codable {
    var accessibilityTrusted = true
    var automationAuthorized = true
    var detail: String?

    var isHealthy: Bool { accessibilityTrusted && automationAuthorized }

    var summary: String {
        switch (accessibilityTrusted, automationAuthorized) {
        case (true, true): return "Permissions OK"
        case (false, true): return "Accessibility permission missing"
        case (true, false): return "Automation permission missing"
        case (false, false): return "Accessibility and Automation permissions missing"
        }
    }
}

struct AppState: Equatable, Sendable {
    var phase: AppPhase = .gate(GateContext(trigger: .launch, shownAt: .distantPast))
    var settings = Settings()
    var presets: [Preset] = []
    var recentGoals: [RecentGoal] = []
    var pendingChanges: [PendingChange] = []
    var permissions = PermissionHealth()
    var frontmostApp: AppIdentity?
    /// When the frontmost app last changed, used to credit "apps used" time (3.2).
    var frontmostSince: Date?
    var statusMessage: String?

    var activeSession: Session? { phase.session }

    var isGated: Bool { phase.isGate }

    var canStartSession: Bool {
        switch phase {
        case .gate, .safeMode, .overridden: return true
        case .session, .intervention, .review: return false
        }
    }

    var overrideActive: OverrideState? {
        if case .overridden(let state) = phase { return state }
        return nil
    }
}

/// A goal you have used before, offered under the gate's text field (3.3).
struct RecentGoal: Equatable, Sendable, Codable, Identifiable {
    var id: UUID
    var goal: String
    var allowedBundleIDs: [String]
    var allowedSites: [SiteRule]
    var duration: TimeInterval?
    var lastUsed: Date

    init(
        id: UUID = UUID(),
        goal: String,
        allowedBundleIDs: [String],
        allowedSites: [SiteRule] = [],
        duration: TimeInterval? = nil,
        lastUsed: Date
    ) {
        self.id = id
        self.goal = goal
        self.allowedBundleIDs = allowedBundleIDs
        self.allowedSites = allowedSites
        self.duration = duration
        self.lastUsed = lastUsed
    }
}

struct ReducerContext: Sendable {
    var now: @Sendable () -> Date
    var newID: @Sendable () -> UUID

    static let live = ReducerContext(now: { Date.nowLoggable }, newID: { UUID() })

    static func fixed(now: Date, ids: [UUID] = []) -> ReducerContext {
        let box = IDBox(ids: ids)
        let now = now.loggable
        return ReducerContext(now: { now }, newID: { box.next() })
    }

    private final class IDBox: @unchecked Sendable {
        private var ids: [UUID]
        private let lock = NSLock()
        private var counter = 0

        init(ids: [UUID]) { self.ids = ids }

        func next() -> UUID {
            lock.lock()
            defer { lock.unlock() }
            if !ids.isEmpty { return ids.remove(at: 0) }
            counter += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter)) ?? UUID()
        }
    }
}
