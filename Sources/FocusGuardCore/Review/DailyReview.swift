import Foundation

/// A day, folded out of the event log in the order the brief asks for: what got past the
/// rules first, then the numbers, then the sessions themselves (3.11).
struct DailyReview: Equatable, Sendable {
    struct Override: Equatable, Sendable, Identifiable {
        let id: UUID
        var startedAt: Date
        var endedAt: Date?
        var reason: String
        var early: Bool

        var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
    }

    struct SafeModeEntry: Equatable, Sendable, Identifiable {
        let id: UUID
        var at: Date
        var reason: SafeModeReason
        var detail: String
    }

    struct Gap: Equatable, Sendable, Identifiable {
        let id: UUID
        var from: Date
        var to: Date
        var explained: Bool

        var duration: TimeInterval { to.timeIntervalSince(from) }
    }

    struct BuildChange: Equatable, Sendable, Identifiable {
        let id: UUID
        var at: Date
        var previousVersion: String?
        var version: String
        var signatureChanged: Bool
    }

    struct PermissionEvent: Equatable, Sendable, Identifiable {
        let id: UUID
        var at: Date
        var permission: String
        var lost: Bool
        var detail: String
    }

    struct Addition: Equatable, Sendable, Identifiable {
        let id: UUID
        var at: Date
        var sessionGoal: String
        var target: String
        var reason: String
    }

    struct Totals: Equatable, Sendable {
        var activeSeconds: TimeInterval = 0
        var fullSessionSeconds: TimeInterval = 0
        var openSessionSeconds: TimeInterval = 0

        var sessionSeconds: TimeInterval { fullSessionSeconds + openSessionSeconds }

        /// Share of the time you were actually at the Mac that was inside a session.
        var coverage: Double {
            guard activeSeconds > 0 else { return 0 }
            return min(1, sessionSeconds / activeSeconds)
        }
    }

    struct SessionEntry: Equatable, Sendable, Identifiable {
        let id: UUID
        var kind: SessionKind
        var goal: String
        var startedAt: Date
        var endedAt: Date?
        var plannedSeconds: TimeInterval?
        var actualSeconds: TimeInterval
        var outcome: SessionOutcome?
        var violations: Int
        var additions: Int
        var extended: Bool
        var converted: Bool
        var appsUsed: [AppUsage]
        var domains: [String]
        /// An open session that started within ten minutes of the previous one ending.
        var chainedFromPrevious: Bool
    }

    var date: Date
    var overrides: [Override] = []
    var safeModeEntries: [SafeModeEntry] = []
    var gaps: [Gap] = []
    var buildChanges: [BuildChange] = []
    var permissionEvents: [PermissionEvent] = []
    var totals = Totals()
    var sessions: [SessionEntry] = []
    var additions: [Addition] = []
    var gateShownCount = 0
    var sleepRequests = 0

    var fullSessions: [SessionEntry] { sessions.filter { $0.kind == .full } }
    var openSessions: [SessionEntry] { sessions.filter { $0.kind == .open } }
    var chains: [SessionEntry] { sessions.filter(\.chainedFromPrevious) }

    var isEmpty: Bool {
        sessions.isEmpty && overrides.isEmpty && totals.activeSeconds == 0
    }
}

enum DailyReviewProjection {
    /// `events` should cover the day; `priorSessionEnd` is the end of the last session
    /// before it, so a chain across midnight is still a chain.
    static func review(
        date: Date,
        events: [LogEvent],
        priorSessionEnd: Date? = nil,
        config: FocusGuardConfig = .current
    ) -> DailyReview {
        var review = DailyReview(date: date)
        var started: [UUID: DailyReview.SessionEntry] = [:]
        var goalsByID: [UUID: String] = [:]
        var openOverride: DailyReview.Override?

        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch event.type {
            case .gateShown:
                review.gateShownCount += 1

            case .sleepRequested:
                review.sleepRequests += 1

            case .activitySample:
                guard let payload = event.decode(ActivitySamplePayload.self) else { continue }
                review.totals.activeSeconds += payload.activeSeconds

            case .overrideStarted:
                guard let payload = event.decode(OverrideStartedPayload.self) else { continue }
                openOverride = DailyReview.Override(
                    id: event.id, startedAt: event.timestamp, endedAt: nil, reason: payload.reason, early: false
                )

            case .overrideEnded:
                let payload = event.decode(OverrideEndedPayload.self)
                if var override = openOverride {
                    override.endedAt = event.timestamp
                    override.early = payload?.early ?? false
                    review.overrides.append(override)
                    openOverride = nil
                }

            case .safeModeEntered:
                guard let payload = event.decode(SafeModePayload.self) else { continue }
                review.safeModeEntries.append(DailyReview.SafeModeEntry(
                    id: event.id, at: event.timestamp, reason: payload.reason, detail: payload.detail
                ))

            case .heartbeatGap:
                guard let payload = event.decode(HeartbeatGapPayload.self) else { continue }
                review.gaps.append(DailyReview.Gap(
                    id: event.id, from: payload.from, to: payload.to, explained: payload.explained
                ))

            case .buildChanged:
                guard let payload = event.decode(BuildChangedPayload.self) else { continue }
                review.buildChanges.append(DailyReview.BuildChange(
                    id: event.id,
                    at: event.timestamp,
                    previousVersion: payload.previousVersion,
                    version: payload.version,
                    signatureChanged: payload.previousSignature != payload.signature
                ))

            case .permissionLost:
                guard let payload = event.decode(PermissionPayload.self) else { continue }
                review.permissionEvents.append(DailyReview.PermissionEvent(
                    id: event.id, at: event.timestamp, permission: payload.permission, lost: true, detail: payload.detail
                ))

            case .permissionRestored:
                guard let payload = event.decode(PermissionRestoredPayload.self) else { continue }
                review.permissionEvents.append(DailyReview.PermissionEvent(
                    id: event.id, at: event.timestamp, permission: payload.permission, lost: false, detail: ""
                ))

            case .sessionStarted:
                guard let payload = event.decode(SessionStartedPayload.self) else { continue }
                goalsByID[payload.sessionID] = payload.goal
                started[payload.sessionID] = DailyReview.SessionEntry(
                    id: payload.sessionID,
                    kind: payload.kind,
                    goal: payload.goal,
                    startedAt: event.timestamp,
                    endedAt: nil,
                    plannedSeconds: payload.plannedEnd.map { $0.timeIntervalSince(event.timestamp) },
                    actualSeconds: 0,
                    outcome: nil,
                    violations: 0,
                    additions: 0,
                    extended: false,
                    converted: false,
                    appsUsed: [],
                    domains: [],
                    chainedFromPrevious: false
                )

            case .sessionExtended:
                guard let payload = event.decode(SessionExtendedPayload.self),
                      var entry = started[payload.sessionID] else { continue }
                entry.extended = true
                entry.plannedSeconds = payload.newPlannedEnd.timeIntervalSince(entry.startedAt)
                started[payload.sessionID] = entry

            case .sessionConverted:
                guard let payload = event.decode(SessionConvertedPayload.self) else { continue }
                started[payload.fromSessionID]?.converted = true

            case .violation:
                guard let payload = event.decode(ViolationPayload.self) else { continue }
                started[payload.sessionID]?.violations += 1

            case .additionToSession:
                guard let payload = event.decode(AdditionPayload.self) else { continue }
                started[payload.sessionID]?.additions += 1
                review.additions.append(DailyReview.Addition(
                    id: event.id,
                    at: event.timestamp,
                    sessionGoal: goalsByID[payload.sessionID] ?? "",
                    target: describe(payload.target),
                    reason: payload.reason
                ))

            case .appsUsedSnapshot:
                guard let payload = event.decode(AppsUsedSnapshotPayload.self) else { continue }
                started[payload.sessionID]?.appsUsed = payload.apps
                started[payload.sessionID]?.domains = payload.domains

            case .sessionEnded:
                guard let payload = event.decode(SessionEndedPayload.self) else { continue }
                var entry = started[payload.sessionID] ?? DailyReview.SessionEntry(
                    id: payload.sessionID,
                    kind: payload.kind,
                    goal: payload.goal,
                    startedAt: payload.startedAt,
                    endedAt: nil,
                    plannedSeconds: payload.plannedEnd.map { $0.timeIntervalSince(payload.startedAt) },
                    actualSeconds: 0,
                    outcome: nil,
                    violations: payload.violationCount,
                    additions: payload.additionCount,
                    extended: false,
                    converted: false,
                    appsUsed: [],
                    domains: [],
                    chainedFromPrevious: false
                )
                entry.endedAt = payload.endedAt
                entry.outcome = payload.outcome
                entry.actualSeconds = payload.endedAt.timeIntervalSince(payload.startedAt)
                if entry.violations == 0 { entry.violations = payload.violationCount }
                if entry.additions == 0 { entry.additions = payload.additionCount }
                started[payload.sessionID] = entry

            default:
                continue
            }
        }

        if let override = openOverride { review.overrides.append(override) }

        // Sessions still running at the end of the window still count for what they ran.
        let now = Date()
        review.sessions = started.values
            .map { entry in
                var entry = entry
                if entry.endedAt == nil {
                    entry.actualSeconds = max(0, min(now, endOfDay(date)).timeIntervalSince(entry.startedAt))
                }
                return entry
            }
            .sorted { $0.startedAt < $1.startedAt }

        review.sessions = markChains(review.sessions, priorSessionEnd: priorSessionEnd, threshold: config.chainThreshold)

        for entry in review.sessions {
            switch entry.kind {
            case .full: review.totals.fullSessionSeconds += entry.actualSeconds
            case .open: review.totals.openSessionSeconds += entry.actualSeconds
            }
        }

        return review
    }

    /// An open session starting within the threshold of the previous session ending is a
    /// chain: the pattern worth noticing is five "quick" sessions in a row (3.11).
    static func markChains(
        _ sessions: [DailyReview.SessionEntry],
        priorSessionEnd: Date?,
        threshold: TimeInterval
    ) -> [DailyReview.SessionEntry] {
        var previousEnd = priorSessionEnd
        return sessions.map { entry in
            var entry = entry
            if entry.kind == .open, let end = previousEnd {
                entry.chainedFromPrevious = entry.startedAt.timeIntervalSince(end) <= threshold
                    && entry.startedAt >= end
            }
            previousEnd = entry.endedAt ?? previousEnd
            return entry
        }
    }

    private static func describe(_ target: AdditionTarget) -> String {
        switch target {
        case .app(let app): return app.name
        case .site(let rule): return rule.displayName
        }
    }

    private static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? date
    }
}
