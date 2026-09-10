import Foundation

/// Imports the v1 UserDefaults data into the event log (4.2). Pure: the app layer reads
/// UserDefaults and hands the raw blobs in, so this is testable with fixtures.
enum LegacyMigration {
    struct Input: Equatable, Sendable {
        var historyJSON: Data?
        var settingsJSON: Data?
        var blockedDomains: [String]?

        init(historyJSON: Data? = nil, settingsJSON: Data? = nil, blockedDomains: [String]? = nil) {
            self.historyJSON = historyJSON
            self.settingsJSON = settingsJSON
            self.blockedDomains = blockedDomains
        }
    }

    struct Output: Equatable, Sendable {
        var sessions: [Session] = []
        var settings: Settings = Settings()
        var importedSettings = false
        var importedBlocklist = false
    }

    private struct LegacySession: Decodable {
        var id: UUID
        var allowedAppName: String
        var allowedBundleID: String
        var allowedBundleIDsMulti: [String]?
        var goal: String?
        var startedAt: Date
        var endedAt: Date?
        var violations: [LegacyViolation]
        var escapes: [LegacyEscape]
    }

    private struct LegacyViolation: Decodable {
        var id: UUID
        var timestamp: Date
        var attemptedAppName: String
        var attemptedBundleID: String
    }

    private struct LegacyEscape: Decodable {
        var id: UUID
        var startedAt: Date
        var duration: TimeInterval
        var reason: String?
    }

    private struct LegacySettings: Decodable {
        var gracePeriodSeconds: Int?
        var requireReasonToLeave: Bool?
        var allowTemporaryEscapes: Bool?
        var defaultEscapeDuration: TimeInterval?
        var launchAtLogin: Bool?
    }

    static func migrate(_ input: Input) -> Output {
        var output = Output()
        // v1 wrote dates with JSONEncoder's default strategy: seconds since 2001.
        let decoder = JSONDecoder()

        if let data = input.historyJSON, let legacy = try? decoder.decode([LegacySession].self, from: data) {
            output.sessions = legacy.map(convert).sorted { $0.startedAt < $1.startedAt }
        }

        if let data = input.settingsJSON, let legacy = try? decoder.decode(LegacySettings.self, from: data) {
            // v1's escape settings have no meaning in v2; only launch-at-login carries over.
            output.settings.launchAtLogin = legacy.launchAtLogin ?? false
            output.importedSettings = true
        }

        if let domains = input.blockedDomains, !domains.isEmpty {
            output.settings.blocklist = Blocklist(domains: domains)
            output.importedBlocklist = true
        }

        return output
    }

    private static func convert(_ legacy: LegacySession) -> Session {
        let anchor = AppIdentity(bundleID: legacy.allowedBundleID, name: legacy.allowedAppName)
        var allowed = legacy.allowedBundleIDsMulti ?? [legacy.allowedBundleID]
        if !allowed.contains(legacy.allowedBundleID) { allowed.append(legacy.allowedBundleID) }

        var session = Session(
            id: legacy.id,
            kind: .full,
            goal: legacy.goal ?? "Stay focused on \(legacy.allowedAppName)",
            anchor: anchor,
            allowedBundleIDs: allowed,
            startedAt: legacy.startedAt
        )
        session.endedAt = legacy.endedAt
        session.violations = legacy.violations.map { violation in
            let app = AppIdentity(bundleID: violation.attemptedBundleID, name: violation.attemptedAppName)
            return Violation(id: violation.id, timestamp: violation.timestamp, kind: .app(app), app: app)
        }
        session.escapes = legacy.escapes.map {
            Escape(id: $0.id, startedAt: $0.startedAt, duration: $0.duration, reason: $0.reason)
        }
        return session
    }
}
