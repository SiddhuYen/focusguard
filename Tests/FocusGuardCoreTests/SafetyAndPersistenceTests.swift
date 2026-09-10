import Foundation
import Testing
@testable import FocusGuardCore

@Suite("Settings change classification")
struct SettingsChangeTests {
    @Test("Tightening edits")
    func tightening() {
        #expect(SettingsChange.blockedDomainAdded("x.com").direction == .tightening)
        #expect(SettingsChange.baselineAppRemoved("com.apple.finder").direction == .tightening)
        #expect(SettingsChange.gateTriggerEnabled(.idleReturn).direction == .tightening)
        #expect(SettingsChange.openSessionCountdownEnabled.direction == .tightening)
        #expect(SettingsChange.failClosedURLReadingEnabled.direction == .tightening)
        #expect(SettingsChange.maxFullSessionLengthChanged(from: 7200, to: 3600).direction == .tightening)
        #expect(SettingsChange.idleThresholdChanged(from: 900, to: 600).direction == .tightening)
        #expect(SettingsChange.overrideCountdownChanged(from: 60, to: 120).direction == .tightening)
        #expect(SettingsChange.overrideDurationChanged(from: 900, to: 300).direction == .tightening)
    }

    @Test("Loosening edits")
    func loosening() {
        #expect(SettingsChange.blockedDomainRemoved("x.com").direction == .loosening)
        #expect(SettingsChange.baselineAppAdded("com.spotify.client").direction == .loosening)
        #expect(SettingsChange.gateTriggerDisabled(.unlock).direction == .loosening)
        #expect(SettingsChange.openSessionCountdownDisabled.direction == .loosening)
        #expect(SettingsChange.failClosedURLReadingDisabled.direction == .loosening)
        #expect(SettingsChange.maxFullSessionLengthChanged(from: 3600, to: 7200).direction == .loosening)
        #expect(SettingsChange.overrideCountdownChanged(from: 60, to: 10).direction == .loosening)
        #expect(SettingsChange.overrideDurationChanged(from: 900, to: 3600).direction == .loosening)
        #expect(SettingsChange.overridePhraseChanged(from: "a long phrase", to: "ok").direction == .loosening)
        #expect(SettingsChange.passwordManagerSet(from: [], to: ["com.1password.1password"]).direction == .loosening)
    }

    @Test("The diff finds every edited field")
    func diff() {
        var new = Settings()
        new.blocklist.add("news.example.com")
        new.gateOnWake = false
        new.maxFullSessionLength = 3 * 3600
        new.idleThreshold = 5 * 60

        let changes = SettingsChangeClassifier.diff(from: Settings(), to: new)
        #expect(changes.contains(SettingsChange.blockedDomainAdded("news.example.com")))
        #expect(changes.contains(SettingsChange.gateTriggerDisabled(.wake)))
        #expect(changes.contains(SettingsChange.maxFullSessionLengthChanged(from: 2 * 3600, to: 3 * 3600)))
        #expect(changes.contains(SettingsChange.idleThresholdChanged(from: 600, to: 300)))
        #expect(changes.count == 4)
    }

    @Test("Planning splits applied from scheduled and never applies a loosening edit early")
    func plan() {
        var new = Settings()
        new.blocklist.add("news.example.com")
        new.blocklist.remove("x.com")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let plan = SettingsChangeClassifier.plan(from: Settings(), to: new, now: now)
        #expect(plan.applied == [.blockedDomainAdded("news.example.com")])
        #expect(plan.scheduled.count == 1)
        #expect(plan.scheduled[0].effectiveAt == now.addingTimeInterval(24 * 3600))
        #expect(plan.settings.blocklist.blocks(host: "x.com") != nil)
    }
}

@Suite("Crash loop and restart escape")
struct SafetyTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(secondsAgo: TimeInterval, lifetime: TimeInterval?, clean: Bool) -> LaunchRecord {
        let launchedAt = now.addingTimeInterval(-secondsAgo)
        return LaunchRecord(
            launchedAt: launchedAt,
            exitedCleanly: clean,
            exitedAt: lifetime.map { launchedAt.addingTimeInterval($0) },
            version: "1"
        )
    }

    @Test("Three quick unclean exits trip safe mode")
    func crashLoop() {
        let records = [
            record(secondsAgo: 300, lifetime: 20, clean: false),
            record(secondsAgo: 200, lifetime: 15, clean: false),
            record(secondsAgo: 100, lifetime: 10, clean: false)
        ]
        #expect(CrashLoopDetector.evaluate(records: records, now: now))
    }

    @Test("Two quick crashes are not enough")
    func twoCrashes() {
        let records = [
            record(secondsAgo: 200, lifetime: 15, clean: false),
            record(secondsAgo: 100, lifetime: 10, clean: false)
        ]
        #expect(!CrashLoopDetector.evaluate(records: records, now: now))
    }

    @Test("A clean exit breaks the streak")
    func cleanExitBreaksStreak() {
        let records = [
            record(secondsAgo: 400, lifetime: 10, clean: false),
            record(secondsAgo: 300, lifetime: 30, clean: true),
            record(secondsAgo: 200, lifetime: 10, clean: false),
            record(secondsAgo: 100, lifetime: 10, clean: false)
        ]
        #expect(!CrashLoopDetector.evaluate(records: records, now: now))
    }

    @Test("A crash after a long healthy run is not a loop")
    func longRunBreaksStreak() {
        let records = [
            record(secondsAgo: 5000, lifetime: 10, clean: false),
            record(secondsAgo: 4000, lifetime: 3600, clean: false),
            record(secondsAgo: 300, lifetime: 10, clean: false),
            record(secondsAgo: 200, lifetime: 10, clean: false)
        ]
        #expect(!CrashLoopDetector.evaluate(records: records, now: now))
    }

    @Test("A still-running record counts by elapsed time, not by nothing")
    func openEndedRecord() {
        let records = [
            record(secondsAgo: 300, lifetime: 10, clean: false),
            record(secondsAgo: 200, lifetime: 10, clean: false),
            record(secondsAgo: 30, lifetime: nil, clean: false)
        ]
        #expect(CrashLoopDetector.evaluate(records: records, now: now))
    }

    @Test("Restart escape needs both the modifiers and a fresh boot")
    func restartEscape() {
        #expect(CrashLoopDetector.isRestartEscape(modifiersHeld: true, systemUptime: 120))
        #expect(!CrashLoopDetector.isRestartEscape(modifiersHeld: false, systemUptime: 120))
        #expect(!CrashLoopDetector.isRestartEscape(modifiersHeld: true, systemUptime: 4000))
    }
}

@Suite("Event log and state files")
struct PersistenceTests {
    private func temporaryPaths() throws -> FocusGuardPaths {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("focusguard-tests-\(UUID().uuidString)", isDirectory: true)
        let paths = FocusGuardPaths(root: root)
        try paths.createDirectories()
        return paths
    }

    @Test("Events round-trip through JSON Lines with typed payloads")
    func roundTrip() throws {
        let paths = try temporaryPaths()
        let store = EventLogStore(paths: paths)
        let sessionID = UUID()

        store.append(SessionStartedPayload(
            sessionID: sessionID,
            kind: .full,
            goal: "ship the gate",
            anchorBundleID: "com.apple.dt.Xcode",
            allowedBundleIDs: ["com.apple.dt.Xcode"],
            allowedSites: [],
            plannedEnd: nil,
            presetID: nil
        ))
        store.append(OverrideStartedPayload(reason: "power cut", until: .nowLoggable))

        let events = store.allEvents()
        #expect(events.count == 2)
        #expect(events[0].decode(SessionStartedPayload.self)?.sessionID == sessionID)
        #expect(events[0].decode(OverrideStartedPayload.self) == nil, "payload decoding is type-checked")
        #expect(events[1].type == .overrideStarted)
    }

    @Test("One file per month, and a day query spans the boundary")
    func monthlyFiles() throws {
        let paths = try temporaryPaths()
        let store = EventLogStore(paths: paths)
        // Files are named in local time, because a "month" in the review is a human month.
        var components = DateComponents(year: 2024, month: 1, day: 15, hour: 12)
        let january = Calendar.current.date(from: components)!
        components.month = 2
        let february = Calendar.current.date(from: components)!

        store.append(LogEvent(type: .appLaunched, payload: .object([:])))
        store.append(LogEvent(timestamp: january, type: .gateShown))
        store.append(LogEvent(timestamp: february, type: .gateShown))

        let files = try FileManager.default.contentsOfDirectory(at: paths.events, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).sorted()
        #expect(files.contains("2024-01.jsonl"))
        #expect(files.contains("2024-02.jsonl"))
    }

    @Test("A torn last line from a crash does not lose the earlier events")
    func tornLine() throws {
        let paths = try temporaryPaths()
        let store = EventLogStore(paths: paths)
        store.append(LogEvent(type: .appLaunched))
        store.append(LogEvent(type: .gateShown))

        let url = paths.eventsFile(for: Date())
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"broken","timesta"#.utf8))
        try handle.close()

        #expect(store.allEvents().count == 2)
    }

    @Test("The active session survives a simulated kill")
    func activeSessionRoundTrip() throws {
        let paths = try temporaryPaths()
        let store = StateStore(paths: paths)
        var session = Session(
            kind: .open,
            goal: "quick fix",
            anchor: AppIdentity(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
            allowedBundleIDs: ["com.apple.dt.Xcode"],
            startedAt: .nowLoggable
        )
        session.noteVisit(host: "www.swift.org")
        store.saveActiveSession(session)

        let reloaded = StateStore(paths: paths).loadActiveSession()
        #expect(reloaded?.id == session.id)
        #expect(reloaded?.goal == session.goal)
        #expect(reloaded?.kind == session.kind)
        #expect(reloaded?.allowedBundleIDs == session.allowedBundleIDs)
        // Timestamps are millisecond precision on disk, so compare within tolerance.
        #expect(reloaded?.startedAt.isSameInstant(as: session.startedAt) == true)
        #expect(reloaded?.domainsVisited == ["swift.org"])

        store.saveActiveSession(nil)
        #expect(StateStore(paths: paths).loadActiveSession() == nil)
    }

    @Test("Settings and pending changes persist as files, not defaults")
    func settingsRoundTrip() throws {
        let paths = try temporaryPaths()
        let store = StateStore(paths: paths)
        var settings = Settings()
        settings.blocklist.add("example.com")
        store.saveSettings(settings)

        let pending = PendingChange(change: .blockedDomainRemoved("x.com"), scheduledAt: .nowLoggable, delay: 3600)
        store.savePendingChanges([pending])

        let reloaded = StateStore(paths: paths)
        #expect(reloaded.loadSettings()?.blocklist.blocks(host: "example.com") == "example.com")
        let reloadedPending = reloaded.loadPendingChanges()
        #expect(reloadedPending.count == 1)
        #expect(reloadedPending.first?.id == pending.id)
        #expect(reloadedPending.first?.change == pending.change)
        #expect(reloadedPending.first?.effectiveAt.isSameInstant(as: pending.effectiveAt) == true)
    }
}
