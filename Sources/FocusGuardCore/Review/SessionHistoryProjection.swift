import Foundation

/// A session as the history and review windows see it. Built by folding the event log,
/// which is the only source of truth (4.2).
struct SessionSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: SessionKind
    var goal: String
    var anchorName: String
    var allowedBundleIDs: [String]
    var startedAt: Date
    var endedAt: Date?
    var plannedEnd: Date?
    var outcome: SessionOutcome?
    var violationCount: Int
    var additionCount: Int
    var escapeCount: Int
    var imported: Bool

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
    var plannedDuration: TimeInterval? { plannedEnd.map { $0.timeIntervalSince(startedAt) } }
}

enum SessionHistoryProjection {
    /// Newest first, matching how the history window reads.
    static func sessions(from events: [LogEvent]) -> [SessionSummary] {
        var byID: [UUID: SessionSummary] = [:]
        var order: [UUID] = []

        func upsert(_ id: UUID, _ body: (inout SessionSummary) -> Void) {
            guard var summary = byID[id] else { return }
            body(&summary)
            byID[id] = summary
        }

        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch event.type {
            case .sessionImported:
                guard let payload = event.decode(SessionImportedPayload.self) else { continue }
                let session = payload.session
                if byID[session.id] == nil { order.append(session.id) }
                byID[session.id] = SessionSummary(
                    id: session.id,
                    kind: session.kind,
                    goal: session.goal,
                    anchorName: session.anchor.name,
                    allowedBundleIDs: session.allowedBundleIDs,
                    startedAt: session.startedAt,
                    endedAt: session.endedAt,
                    plannedEnd: session.plannedEnd,
                    outcome: session.outcome,
                    violationCount: session.violations.count,
                    additionCount: session.additions.count,
                    escapeCount: session.escapes.count,
                    imported: true
                )

            case .sessionStarted:
                guard let payload = event.decode(SessionStartedPayload.self) else { continue }
                if byID[payload.sessionID] == nil { order.append(payload.sessionID) }
                byID[payload.sessionID] = SessionSummary(
                    id: payload.sessionID,
                    kind: payload.kind,
                    goal: payload.goal,
                    anchorName: payload.anchorBundleID,
                    allowedBundleIDs: payload.allowedBundleIDs,
                    startedAt: event.timestamp,
                    endedAt: nil,
                    plannedEnd: payload.plannedEnd,
                    outcome: nil,
                    violationCount: 0,
                    additionCount: 0,
                    escapeCount: 0,
                    imported: false
                )

            case .violation:
                guard let payload = event.decode(ViolationPayload.self) else { continue }
                upsert(payload.sessionID) { $0.violationCount += 1 }

            case .additionToSession:
                guard let payload = event.decode(AdditionPayload.self) else { continue }
                upsert(payload.sessionID) { $0.additionCount += 1 }

            case .sessionExtended:
                guard let payload = event.decode(SessionExtendedPayload.self) else { continue }
                upsert(payload.sessionID) { $0.plannedEnd = payload.newPlannedEnd }

            case .sessionEnded:
                guard let payload = event.decode(SessionEndedPayload.self) else { continue }
                upsert(payload.sessionID) {
                    $0.endedAt = payload.endedAt
                    $0.outcome = payload.outcome
                    if $0.violationCount == 0 { $0.violationCount = payload.violationCount }
                    if $0.additionCount == 0 { $0.additionCount = payload.additionCount }
                }

            default:
                continue
            }
        }

        return order.compactMap { byID[$0] }.sorted { $0.startedAt > $1.startedAt }
    }

    /// Display names come from the log's app identities where we have them.
    static func applyNames(_ names: [String: String], to sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.map { session in
            var session = session
            if let name = names[session.anchorName] { session.anchorName = name }
            return session
        }
    }
}
