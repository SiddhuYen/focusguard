import Foundation
import Testing
@testable import FocusGuardCore

// Note: compare TimeIntervals against TimeInterval(...), not a bare `40 * 60`. The macro
// picks an Int overload for the literal and the comparison then fails on equal values.

@Suite("Daily review")
struct DailyReviewTests {
    let day = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 9))!

    private func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60).loggable }

    private func session(
        id: UUID,
        kind: SessionKind,
        goal: String,
        start: Double,
        end: Double,
        planned: Double,
        outcome: SessionOutcome = .finished,
        violations: Int = 0
    ) -> [LogEvent] {
        var events: [LogEvent] = [
            LogEvent(SessionStartedPayload(
                sessionID: id, kind: kind, goal: goal, anchorBundleID: "com.apple.dt.Xcode",
                allowedBundleIDs: ["com.apple.dt.Xcode"], allowedSites: [], allowAllNonBlockedSites: false,
                plannedEnd: at(start + planned), presetID: nil
            ), timestamp: at(start))
        ]
        for index in 0..<violations {
            events.append(LogEvent(ViolationPayload(
                sessionID: id,
                kind: .app(AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")),
                appBundleID: "com.tinyspeck.slackmacgap", appName: "Slack"
            ), timestamp: at(start + Double(index) + 1)))
        }
        events.append(LogEvent(SessionEndedPayload(
            sessionID: id, kind: kind, goal: goal, outcome: outcome,
            startedAt: at(start), endedAt: at(end), plannedEnd: at(start + planned),
            violationCount: violations, additionCount: 0
        ), timestamp: at(end)))
        return events
    }

    @Test("Totals add up the way a hand count would")
    func totals() {
        var events = session(id: UUID(), kind: .full, goal: "ship the gate", start: 0, end: 50, planned: 50)
        events += session(id: UUID(), kind: .open, goal: "quick fix", start: 60, end: 65, planned: 5)
        // Four hours of activity sampled in five minute windows.
        for window in 0..<48 {
            events.append(LogEvent(ActivitySamplePayload(
                windowStart: at(Double(window) * 5), windowSeconds: 300, activeSeconds: 300
            ), timestamp: at(Double(window) * 5 + 5)))
        }

        let review = DailyReviewProjection.review(date: day, events: events)
        #expect(review.totals.fullSessionSeconds == TimeInterval(3000))
        #expect(review.totals.openSessionSeconds == TimeInterval(300))
        #expect(review.totals.activeSeconds == TimeInterval(14400))
        #expect(abs(review.totals.coverage - (55.0 / 240.0)) < 0.001)
        #expect(review.fullSessions.count == 1)
        #expect(review.openSessions.count == 1)
    }

    @Test("Violations, extensions and conversions land on the right session")
    func sessionDetail() {
        let id = UUID()
        var events = session(id: id, kind: .full, goal: "write", start: 0, end: 40, planned: 25, violations: 3)
        events.append(LogEvent(SessionExtendedPayload(
            sessionID: id, by: 15 * 60, newPlannedEnd: at(40)
        ), timestamp: at(25)))

        let review = DailyReviewProjection.review(date: day, events: events)
        let entry = review.fullSessions[0]
        #expect(entry.violations == 3)
        #expect(entry.extended)
        #expect(entry.plannedSeconds == TimeInterval(2400))
        #expect(entry.actualSeconds == TimeInterval(2400))
        #expect(entry.outcome == .finished)
    }

    @Test("An open session right after the last one is a chain")
    func chains() {
        var events = session(id: UUID(), kind: .open, goal: "check email", start: 0, end: 5, planned: 5)
        events += session(id: UUID(), kind: .open, goal: "check slack", start: 8, end: 13, planned: 5)
        events += session(id: UUID(), kind: .open, goal: "one more thing", start: 40, end: 45, planned: 5)

        let review = DailyReviewProjection.review(date: day, events: events)
        #expect(review.chains.count == 1, "eight minutes later is a chain, twenty-seven is not")
        #expect(review.chains.first?.goal == "check slack")
    }

    @Test("A chain across midnight still counts")
    func chainAcrossMidnight() {
        let events = session(id: UUID(), kind: .open, goal: "late night", start: 0, end: 5, planned: 5)
        let review = DailyReviewProjection.review(
            date: day, events: events, priorSessionEnd: at(-6)
        )
        #expect(review.sessions[0].chainedFromPrevious)
    }

    @Test("Overrides, safe mode, gaps and build changes are all surfaced")
    func tamperVisibility() {
        let events: [LogEvent] = [
            LogEvent(OverrideStartedPayload(reason: "power cut", until: at(20)), timestamp: at(5)),
            LogEvent(OverrideEndedPayload(startedAt: at(5), early: false), timestamp: at(20)),
            LogEvent(SafeModePayload(reason: .crashLoop, detail: "3 unclean exits"), timestamp: at(30)),
            LogEvent(HeartbeatGapPayload(from: at(40), to: at(100), explained: false), timestamp: at(100)),
            LogEvent(BuildChangedPayload(
                previousVersion: "0.2.0 (2)", version: "0.2.0 (3)",
                previousSignature: "a", signature: "b"
            ), timestamp: at(110)),
            LogEvent(PermissionPayload(permission: "automation", detail: "-1743"), timestamp: at(120))
        ]

        let review = DailyReviewProjection.review(date: day, events: events)
        #expect(review.overrides.count == 1)
        #expect(review.overrides[0].reason == "power cut")
        #expect(review.overrides[0].duration == TimeInterval(900))
        #expect(review.safeModeEntries.first?.reason == .crashLoop)
        #expect(review.gaps.first?.duration == TimeInterval(3600))
        #expect(review.gaps.first?.explained == false)
        #expect(review.buildChanges.first?.signatureChanged == true)
        #expect(review.permissionEvents.filter(\.lost).count == 1)
    }

    @Test("Mid-session additions are listed with their reasons")
    func additions() {
        let id = UUID()
        var events = session(id: id, kind: .full, goal: "ship the gate", start: 0, end: 30, planned: 30)
        events.append(LogEvent(AdditionPayload(
            sessionID: id,
            target: .app(AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")),
            reason: "on-call ping"
        ), timestamp: at(10)))

        let review = DailyReviewProjection.review(date: day, events: events)
        #expect(review.additions.count == 1)
        #expect(review.additions[0].target == "Slack")
        #expect(review.additions[0].reason == "on-call ping")
        #expect(review.additions[0].sessionGoal == "ship the gate")
    }

    @Test("An empty day says so rather than inventing numbers")
    func emptyDay() {
        let review = DailyReviewProjection.review(date: day, events: [])
        #expect(review.isEmpty)
        #expect(review.totals.coverage == 0)
    }

    @Test("The export mirrors the review")
    func export() throws {
        var events = session(id: UUID(), kind: .full, goal: "ship the gate", start: 0, end: 50, planned: 50, violations: 2)
        events += session(id: UUID(), kind: .open, goal: "quick fix", start: 52, end: 57, planned: 5)
        events.append(LogEvent(ActivitySamplePayload(
            windowStart: at(0), windowSeconds: 3600, activeSeconds: 3600
        ), timestamp: at(60)))

        let review = DailyReviewProjection.review(date: day, events: events)
        let export = DailyExport(review: review)
        #expect(export.date == FocusGuardPaths.dayStamp(for: day))
        #expect(export.sessionCount == 2)
        #expect(export.openSessionCount == 1)
        #expect(export.chainCount == 1)
        #expect(export.violationCount == 2)
        #expect(export.fullSessionMinutes == 50)
        #expect(export.activeMinutes == 60)

        // It has to survive a round trip: this is the hook for something else to read.
        let data = try JSONCoding.encoder(pretty: true).encode(export)
        let decoded = try JSONCoding.decoder().decode(DailyExport.self, from: data)
        let reencoded = try JSONCoding.encoder(pretty: true).encode(decoded)
        #expect(reencoded == data)
        #expect(decoded.sessions.map(\.goal) == export.sessions.map(\.goal))
    }
}

@Suite("Preset learning")
struct PresetLearningTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func past(_ daysAgo: Double, goal: String, apps: [String], minutes: Double = 5) -> LearnedSession {
        LearnedSession(
            id: UUID(),
            kind: .open,
            goal: goal,
            startedAt: now.addingTimeInterval(-daysAgo * 86400),
            seconds: minutes * 60,
            appBundleIDs: apps,
            domains: []
        )
    }

    @Test("Three similar open sessions earn a suggestion")
    func suggestsAfterThree() {
        let current = past(0, goal: "email the landlord about the lease", apps: ["com.microsoft.Outlook"])
        let history = [
            past(2, goal: "email the landlord", apps: ["com.microsoft.Outlook"]),
            past(6, goal: "email landlord about rent", apps: ["com.microsoft.Outlook"])
        ]

        let suggestion = PresetLearning.suggestion(
            for: current, history: history, presets: [], blocklist: Blocklist(), now: now
        )
        #expect(suggestion?.matchCount == 3)
        #expect(suggestion?.allowedBundleIDs == ["com.microsoft.Outlook"])
        #expect(suggestion?.name.lowercased().contains("landlord") == true)
        #expect(suggestion?.duration == TimeInterval(600), "five minute sessions want the next size up")
    }

    @Test("Two is not a pattern")
    func twoIsNotEnough() {
        let current = past(0, goal: "email the landlord", apps: ["com.microsoft.Outlook"])
        let history = [past(1, goal: "email the landlord", apps: ["com.microsoft.Outlook"])]
        #expect(PresetLearning.suggestion(for: current, history: history, presets: [], blocklist: Blocklist(), now: now) == nil)
    }

    @Test("Different words, same apps, still a pattern")
    func matchesOnAppsToo() {
        let current = past(0, goal: "sort out the invoice", apps: ["com.apple.Numbers", "com.microsoft.Outlook"])
        let history = [
            past(3, goal: "expenses", apps: ["com.apple.Numbers", "com.microsoft.Outlook"]),
            past(9, goal: "finance admin", apps: ["com.apple.Numbers", "com.microsoft.Outlook"])
        ]
        let suggestion = PresetLearning.suggestion(
            for: current, history: history, presets: [], blocklist: Blocklist(), now: now
        )
        #expect(suggestion?.matchCount == 3)
        #expect(suggestion?.allowedBundleIDs.count == 2)
    }

    @Test("Sessions older than the window do not count")
    func windowIsRespected() {
        let current = past(0, goal: "email the landlord", apps: ["com.microsoft.Outlook"])
        let history = [
            past(20, goal: "email the landlord", apps: ["com.microsoft.Outlook"]),
            past(30, goal: "email the landlord", apps: ["com.microsoft.Outlook"])
        ]
        #expect(PresetLearning.suggestion(for: current, history: history, presets: [], blocklist: Blocklist(), now: now) == nil)
    }

    @Test("It does not suggest what you already have")
    func existingPresetWins() {
        let current = past(0, goal: "email the landlord", apps: ["com.microsoft.Outlook"])
        let history = [
            past(2, goal: "email the landlord", apps: ["com.microsoft.Outlook"]),
            past(5, goal: "email the landlord", apps: ["com.microsoft.Outlook"])
        ]
        let existing = Preset(name: "Email", allowedBundleIDs: ["com.microsoft.Outlook"])
        #expect(PresetLearning.suggestion(
            for: current, history: history, presets: [existing], blocklist: Blocklist(), now: now
        ) == nil)
    }

    @Test("Blocked domains never make it into a learned preset")
    func blockedDomainsExcluded() {
        var current = past(0, goal: "watch the lecture", apps: [KnownBrowser.safari.rawValue])
        current.domains = ["youtube.com", "developer.apple.com"]
        var older = current
        older.id = UUID()
        older.startedAt = now.addingTimeInterval(-2 * 86400)
        var oldest = current
        oldest.id = UUID()
        oldest.startedAt = now.addingTimeInterval(-4 * 86400)

        let suggestion = PresetLearning.suggestion(
            for: current,
            history: [older, oldest],
            presets: [],
            blocklist: Blocklist(domains: ["youtube.com"]),
            now: now
        )
        #expect(suggestion?.allowedSites == [SiteRule.domain("developer.apple.com")])
    }
}

@Suite("Open session pacing")
struct OpenSessionPacingTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func settings(enabled: Bool) -> Settings {
        var settings = Settings()
        settings.openSessionCountdownEnabled = enabled
        return settings
    }

    @Test("Off by default, so nothing waits")
    func offByDefault() {
        let starts = (0..<5).map { now.addingTimeInterval(-Double($0) * 300) }
        #expect(OpenSessionPacing.countdown(recentStarts: starts, now: now, settings: settings(enabled: false)) == 0)
    }

    @Test("The first two are free, then it escalates")
    func ladder() {
        let on = settings(enabled: true)
        func countdown(_ count: Int) -> TimeInterval {
            let starts = (0..<count).map { now.addingTimeInterval(-Double($0) * 300) }
            return OpenSessionPacing.countdown(recentStarts: starts, now: now, settings: on)
        }
        #expect(countdown(0) == 0)
        #expect(countdown(1) == 0)
        #expect(countdown(2) == TimeInterval(30))
        #expect(countdown(3) == TimeInterval(60))
        #expect(countdown(4) == TimeInterval(120))
        #expect(countdown(9) == TimeInterval(120), "the ladder tops out")
    }

    @Test("Sessions from over an hour ago do not count")
    func windowed() {
        let on = settings(enabled: true)
        let old = (0..<5).map { now.addingTimeInterval(-3600 - Double($0) * 300) }
        #expect(OpenSessionPacing.countdown(recentStarts: old, now: now, settings: on) == 0)
    }
}
