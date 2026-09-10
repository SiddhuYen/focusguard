import Foundation
import Testing
@testable import FocusGuardCore

@Suite("Legacy UserDefaults migration")
struct MigrationTests {
    /// The v1 shape, exactly as FocusSession encoded it: dates are seconds since the 2001
    /// reference date, because v1 used JSONEncoder's default strategy.
    private let historyJSON = Data("""
    [
      {
        "id": "1D6E2CFB-0000-0000-0000-000000000001",
        "allowedAppName": "Xcode",
        "allowedBundleID": "com.apple.dt.Xcode",
        "allowedProcessIdentifier": 1234,
        "allowedBundleIDsMulti": ["com.apple.dt.Xcode", "com.apple.Terminal"],
        "goal": "finish the reducer",
        "startedAt": 811000000.5,
        "endedAt": 811003600.5,
        "violations": [
          {
            "id": "1D6E2CFB-0000-0000-0000-000000000002",
            "timestamp": 811001000,
            "attemptedAppName": "Slack",
            "attemptedBundleID": "com.tinyspeck.slackmacgap"
          }
        ],
        "escapes": [
          {
            "id": "1D6E2CFB-0000-0000-0000-000000000003",
            "startedAt": 811002000,
            "duration": 60,
            "reason": "on-call"
          }
        ]
      },
      {
        "id": "1D6E2CFB-0000-0000-0000-000000000004",
        "allowedAppName": "Pages",
        "allowedBundleID": "com.apple.iWork.Pages",
        "allowedProcessIdentifier": 99,
        "goal": "draft the brief",
        "startedAt": 810000000,
        "violations": [],
        "escapes": []
      }
    ]
    """.utf8)

    private let settingsJSON = Data("""
    {"requireReasonToLeave":true,"gracePeriodSeconds":1,"allowTemporaryEscapes":true,"defaultEscapeDuration":60,"launchAtLogin":false}
    """.utf8)

    @Test("Sessions import with goals, allowlists, violations and escapes intact")
    func importsSessions() {
        let output = LegacyMigration.migrate(.init(historyJSON: historyJSON))
        #expect(output.sessions.count == 2)

        let pages = output.sessions[0]
        #expect(pages.goal == "draft the brief")
        #expect(pages.allowedBundleIDs == ["com.apple.iWork.Pages"])
        #expect(pages.endedAt == nil)

        let xcode = output.sessions[1]
        #expect(xcode.kind == .full)
        #expect(xcode.goal == "finish the reducer")
        #expect(xcode.allowedBundleIDs == ["com.apple.dt.Xcode", "com.apple.Terminal"])
        #expect(xcode.violations.count == 1)
        #expect(xcode.violations[0].kind == .app(AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")))
        #expect(xcode.escapes.count == 1)
        #expect(xcode.escapes[0].reason == "on-call")
        // Reference-date seconds, not epoch seconds.
        #expect(xcode.startedAt == Date(timeIntervalSinceReferenceDate: 811000000.5))
        #expect(xcode.elapsed == 3600)
    }

    @Test("A session missing the multi-app list falls back to its single app")
    func singleAppSessions() {
        let output = LegacyMigration.migrate(.init(historyJSON: historyJSON))
        #expect(output.sessions[0].allowedBundleIDs == ["com.apple.iWork.Pages"])
    }

    @Test("Settings and the blocked domains come across")
    func importsSettings() {
        let output = LegacyMigration.migrate(.init(
            settingsJSON: settingsJSON,
            blockedDomains: ["youtube.com", "www.youtube.com", "m.youtube.com", "reddit.com"]
        ))
        #expect(output.importedSettings)
        #expect(output.importedBlocklist)
        // The duplicate www/m variants collapse into one entry that still blocks all of them.
        #expect(output.settings.blocklist.domains == ["youtube.com", "m.youtube.com", "reddit.com"])
        #expect(output.settings.blocklist.blocks(host: "www.youtube.com") == "youtube.com")
    }

    @Test("Garbage input migrates to nothing instead of crashing")
    func toleratesGarbage() {
        let output = LegacyMigration.migrate(.init(historyJSON: Data("not json".utf8), settingsJSON: Data("{".utf8)))
        #expect(output.sessions.isEmpty)
        #expect(!output.importedSettings)
    }

    @Test("Imported sessions can be written to the log and read back")
    func importsIntoLog() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fg-migrate-\(UUID().uuidString)")
        let paths = FocusGuardPaths(root: root)
        try paths.createDirectories()
        let store = EventLogStore(paths: paths)

        let output = LegacyMigration.migrate(.init(historyJSON: historyJSON))
        for session in output.sessions {
            store.append(SessionImportedPayload(session: session), at: session.startedAt)
        }

        let imported = store.allEvents().compactMap { $0.decode(SessionImportedPayload.self) }
        #expect(imported.count == 2)
        #expect(imported.map(\.session.goal).contains("finish the reducer"))
    }
}

@Suite("History projection")
struct HistoryProjectionTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000).loggable

    @Test("A live session folds start, violations and end into one row")
    func liveSession() {
        let id = UUID()
        let events: [LogEvent] = [
            LogEvent(SessionStartedPayload(
                sessionID: id, kind: .full, goal: "ship the gate", anchorBundleID: "com.apple.dt.Xcode",
                allowedBundleIDs: ["com.apple.dt.Xcode"], allowedSites: [], plannedEnd: start.addingTimeInterval(1500), presetID: nil
            ), timestamp: start),
            LogEvent(ViolationPayload(
                sessionID: id, kind: .app(AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")),
                appBundleID: "com.tinyspeck.slackmacgap", appName: "Slack"
            ), timestamp: start.addingTimeInterval(60)),
            LogEvent(AdditionPayload(
                sessionID: id, target: .app(AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")), reason: "on-call"
            ), timestamp: start.addingTimeInterval(70)),
            LogEvent(SessionEndedPayload(
                sessionID: id, kind: .full, goal: "ship the gate", outcome: .finished,
                startedAt: start, endedAt: start.addingTimeInterval(1500), plannedEnd: nil,
                violationCount: 1, additionCount: 1
            ), timestamp: start.addingTimeInterval(1500))
        ]

        let sessions = SessionHistoryProjection.sessions(from: events)
        #expect(sessions.count == 1)
        #expect(sessions[0].goal == "ship the gate")
        #expect(sessions[0].violationCount == 1)
        #expect(sessions[0].additionCount == 1)
        #expect(sessions[0].outcome == .finished)
        #expect(sessions[0].duration == 1500)
    }

    @Test("Imported sessions and live sessions sort together, newest first, with no cap")
    func mixedHistory() {
        var events: [LogEvent] = []
        for index in 0..<150 {
            var session = Session(
                kind: .full,
                goal: "imported \(index)",
                anchor: AppIdentity(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
                allowedBundleIDs: ["com.apple.dt.Xcode"],
                startedAt: start.addingTimeInterval(Double(index) * 3600)
            )
            session.endedAt = session.startedAt.addingTimeInterval(600)
            events.append(LogEvent(SessionImportedPayload(session: session), timestamp: session.startedAt))
        }

        let sessions = SessionHistoryProjection.sessions(from: events)
        #expect(sessions.count == 150, "history is no longer capped at 100")
        #expect(sessions.first?.goal == "imported 149")
        #expect(sessions.first?.imported == true)
    }

    @Test("An unfinished session still shows, with no end date")
    func openEnded() {
        let id = UUID()
        let events = [LogEvent(SessionStartedPayload(
            sessionID: id, kind: .open, goal: "quick fix", anchorBundleID: "com.apple.Terminal",
            allowedBundleIDs: [], allowedSites: [], plannedEnd: nil, presetID: nil
        ), timestamp: start)]

        let sessions = SessionHistoryProjection.sessions(from: events)
        #expect(sessions.count == 1)
        #expect(sessions[0].endedAt == nil)
        #expect(sessions[0].kind == .open)
    }
}
