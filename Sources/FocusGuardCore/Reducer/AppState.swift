import Foundation

/// Where the app is right now. Phase 1 replaces `.idle` with `.gate` and adds `.review`
/// and `.overridden`; `.gracePeriod` disappears with the timed escape.
enum AppPhase: Equatable, Sendable {
    case idle
    case session(Session)
    case intervention(Session, Violation)
    case gracePeriod(Session, until: Date)
    case safeMode(SafeModeReason)

    var session: Session? {
        switch self {
        case .idle, .safeMode: return nil
        case .session(let session),
             .intervention(let session, _),
             .gracePeriod(let session, _):
            return session
        }
    }

    var isEnforcing: Bool {
        switch self {
        case .session, .intervention: return true
        case .idle, .gracePeriod, .safeMode: return false
        }
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
    var phase: AppPhase = .idle
    var settings = Settings()
    var presets: [Preset] = []
    var pendingChanges: [PendingChange] = []
    var permissions = PermissionHealth()
    var frontmostApp: AppIdentity?
    /// When the frontmost app last changed, used to credit "apps used" time (3.2).
    var frontmostSince: Date?
    var statusMessage: String?

    var activeSession: Session? { phase.session }

    var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    var canStartSession: Bool {
        switch phase {
        case .idle, .safeMode: return true
        case .session, .intervention, .gracePeriod: return false
        }
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
