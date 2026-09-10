import Foundation

/// One-time import of the v1 UserDefaults data into the event log. The old keys are left
/// in place: they are only rewritten by v1, which is no longer running, and keeping them
/// means a failed migration can be retried (4.2).
@MainActor
enum LegacyMigrationRunner {
    static let historyKey = "FocusGuard.SessionHistory"
    static let settingsKey = "FocusGuard.UserSettings"
    static let blockedDomainsKey = "FocusGuard.BlockedDomains"

    @discardableResult
    static func runIfNeeded(
        store: StateStore,
        log: EventLogStore,
        defaults: UserDefaults = .standard
    ) -> Settings? {
        guard store.migrationCompleted() == nil else { return nil }

        let input = LegacyMigration.Input(
            historyJSON: defaults.data(forKey: historyKey),
            settingsJSON: defaults.data(forKey: settingsKey),
            blockedDomains: defaults.array(forKey: blockedDomainsKey) as? [String]
        )

        let output = LegacyMigration.migrate(input)
        for session in output.sessions {
            log.append(SessionImportedPayload(session: session), at: session.startedAt)
        }

        var settings = store.loadSettings() ?? output.settings
        if output.importedSettings {
            settings.requireReasonToLeave = output.settings.requireReasonToLeave
            settings.allowTemporaryEscapes = output.settings.allowTemporaryEscapes
            settings.defaultEscapeDuration = output.settings.defaultEscapeDuration
            settings.launchAtLogin = output.settings.launchAtLogin
        }
        if output.importedBlocklist {
            settings.blocklist = output.settings.blocklist
        }
        store.saveSettings(settings)

        store.recordMigration(MigrationRecord(
            completedAt: .nowLoggable,
            importedSessions: output.sessions.count,
            importedSettings: output.importedSettings,
            importedBlocklist: output.importedBlocklist
        ))

        return settings
    }
}
