import Foundation

/// The day, in a shape something else can read: written to
/// ~/Library/Application Support/FocusGuard/exports/YYYY-MM-DD.json (3.11). No network.
struct DailyExport: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable {
        var kind: String
        var goal: String
        var startedAt: Date
        var endedAt: Date?
        var plannedMinutes: Double?
        var actualMinutes: Double
        var outcome: String?
        var violations: Int
        var additions: Int
        var extended: Bool
        var converted: Bool
        var chained: Bool
        var appsUsed: [String]
        var domains: [String]
    }

    struct Override: Codable, Equatable, Sendable {
        var startedAt: Date
        var minutes: Double?
        var reason: String
        var endedEarly: Bool
    }

    struct Gap: Codable, Equatable, Sendable {
        var from: Date
        var to: Date
        var minutes: Double
        var explained: Bool
    }

    var date: String
    var generatedAt: Date
    var activeMinutes: Double
    var fullSessionMinutes: Double
    var openSessionMinutes: Double
    var coverage: Double
    var sessionCount: Int
    var openSessionCount: Int
    var chainCount: Int
    var violationCount: Int
    var gateShownCount: Int
    var sessions: [Session]
    var overrides: [Override]
    var gaps: [Gap]
    var safeModeEntries: [String]
    var buildChanges: [String]
    var permissionLosses: Int

    /// Whole seconds: a file stamp gains nothing from milliseconds, and it keeps the
    /// JSON byte-identical across a round trip.
    init(review: DailyReview, generatedAt: Date = Date()) {
        let generatedAt = Date(timeIntervalSince1970: generatedAt.timeIntervalSince1970.rounded(.down))
        date = FocusGuardPaths.dayStamp(for: review.date)
        self.generatedAt = generatedAt
        activeMinutes = (review.totals.activeSeconds / 60).rounded(to: 1)
        fullSessionMinutes = (review.totals.fullSessionSeconds / 60).rounded(to: 1)
        openSessionMinutes = (review.totals.openSessionSeconds / 60).rounded(to: 1)
        coverage = review.totals.coverage.rounded(to: 3)
        sessionCount = review.sessions.count
        openSessionCount = review.openSessions.count
        chainCount = review.chains.count
        violationCount = review.sessions.reduce(0) { $0 + $1.violations }
        gateShownCount = review.gateShownCount
        sessions = review.sessions.map { entry in
            Session(
                kind: entry.kind.rawValue,
                goal: entry.goal,
                startedAt: entry.startedAt,
                endedAt: entry.endedAt,
                plannedMinutes: entry.plannedSeconds.map { ($0 / 60).rounded(to: 1) },
                actualMinutes: (entry.actualSeconds / 60).rounded(to: 1),
                outcome: entry.outcome?.rawValue,
                violations: entry.violations,
                additions: entry.additions,
                extended: entry.extended,
                converted: entry.converted,
                chained: entry.chainedFromPrevious,
                appsUsed: entry.appsUsed.map(\.bundleID),
                domains: entry.domains
            )
        }
        overrides = review.overrides.map {
            Override(
                startedAt: $0.startedAt,
                minutes: $0.duration.map { ($0 / 60).rounded(to: 1) },
                reason: $0.reason,
                endedEarly: $0.early
            )
        }
        gaps = review.gaps.map {
            Gap(from: $0.from, to: $0.to, minutes: ($0.duration / 60).rounded(to: 1), explained: $0.explained)
        }
        safeModeEntries = review.safeModeEntries.map { "\($0.reason.rawValue): \($0.detail)" }
        buildChanges = review.buildChanges.map { "\($0.previousVersion ?? "?") -> \($0.version)" }
        permissionLosses = review.permissionEvents.filter(\.lost).count
    }
}

private extension Double {
    func rounded(to places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
