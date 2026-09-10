import Foundation

/// Typed, atomic files for the things that must survive a kill -9 (4.2, 3.9.5).
final class StateStore: @unchecked Sendable {
    let paths: FocusGuardPaths

    init(paths: FocusGuardPaths) {
        self.paths = paths
        try? paths.createDirectories()
    }

    // MARK: Active session

    func loadActiveSession() -> Session? {
        AtomicFile.readJSON(Session.self, from: paths.activeSession)
    }

    func saveActiveSession(_ session: Session?) {
        guard let session else {
            try? FileManager.default.removeItem(at: paths.activeSession)
            return
        }
        try? AtomicFile.writeJSON(session, to: paths.activeSession)
    }

    // MARK: Settings, presets, pending changes

    func loadSettings() -> Settings? {
        AtomicFile.readJSON(Settings.self, from: paths.settings)
    }

    func saveSettings(_ settings: Settings) {
        try? AtomicFile.writeJSON(settings, to: paths.settings)
    }

    func loadPresets() -> [Preset] {
        AtomicFile.readJSON([Preset].self, from: paths.presets) ?? []
    }

    func savePresets(_ presets: [Preset]) {
        try? AtomicFile.writeJSON(presets, to: paths.presets)
    }

    func loadRecentGoals() -> [RecentGoal] {
        AtomicFile.readJSON([RecentGoal].self, from: paths.recentGoals) ?? []
    }

    func saveRecentGoals(_ recents: [RecentGoal]) {
        try? AtomicFile.writeJSON(recents, to: paths.recentGoals)
    }

    func loadPendingChanges() -> [PendingChange] {
        AtomicFile.readJSON([PendingChange].self, from: paths.pendingChanges) ?? []
    }

    func savePendingChanges(_ changes: [PendingChange]) {
        try? AtomicFile.writeJSON(changes, to: paths.pendingChanges)
    }

    // MARK: Launch records and liveness

    func loadLaunchRecords() -> [LaunchRecord] {
        AtomicFile.readJSON([LaunchRecord].self, from: paths.launchRecord) ?? []
    }

    func saveLaunchRecords(_ records: [LaunchRecord]) {
        try? AtomicFile.writeJSON(Array(records.suffix(20)), to: paths.launchRecord)
    }

    func loadHeartbeat() -> Heartbeat? {
        AtomicFile.readJSON(Heartbeat.self, from: paths.heartbeat)
    }

    func saveHeartbeat(_ heartbeat: Heartbeat) {
        try? AtomicFile.writeJSON(heartbeat, to: paths.heartbeat)
    }

    func loadHangMarker() -> HangMarker? {
        AtomicFile.readJSON(HangMarker.self, from: paths.hangMarker)
    }

    /// Written from the watchdog thread while the main thread is wedged, so it deliberately
    /// avoids every other lock in the app.
    func saveHangMarker(_ marker: HangMarker) {
        try? AtomicFile.writeJSON(marker, to: paths.hangMarker)
    }

    func clearHangMarker() {
        try? FileManager.default.removeItem(at: paths.hangMarker)
    }

    // MARK: Migration

    func migrationCompleted() -> MigrationRecord? {
        AtomicFile.readJSON(MigrationRecord.self, from: paths.migrationMarker)
    }

    func recordMigration(_ record: MigrationRecord) {
        try? AtomicFile.writeJSON(record, to: paths.migrationMarker)
    }
}

struct Heartbeat: Codable, Equatable, Sendable {
    var timestamp: Date
    /// Set when the app knows why it is about to be gone: sleep, shutdown, clean quit.
    var reason: String?
}

struct HangMarker: Codable, Equatable, Sendable {
    var detectedAt: Date
    var unresponsiveSeconds: TimeInterval
}

struct MigrationRecord: Codable, Equatable, Sendable {
    var completedAt: Date
    var importedSessions: Int
    var importedSettings: Bool
    var importedBlocklist: Bool
}
