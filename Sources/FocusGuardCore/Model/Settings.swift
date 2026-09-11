import Foundation

/// Everything the user can change. Changes run through SettingsChange so that loosening
/// edits can be delayed 24 hours (3.8).
struct Settings: Codable, Equatable, Sendable {
    /// Bumped when a new setting ships with a default that existing installs should pick
    /// up. Files written before versioning decode as 1.
    var schemaVersion = SettingsMigration.currentVersion
    var blocklist = Blocklist()
    var baseline = BaselineAllowlist()

    // Gate triggers (3.1)
    var gateOnUnlock = true
    var gateOnWake = true
    var gateOnIdleReturn = true
    var idleThreshold: TimeInterval = FocusGuardConfig.current.idleThreshold

    // Session limits
    var maxFullSessionLength: TimeInterval = FocusGuardConfig.current.fullSessionMaxLength
    var openSessionCountdownEnabled = FocusGuardConfig.current.openSessionCountdownEnabled
    /// A browser whose address cannot be read for several polls counts as a violation
    /// rather than being waved through (3.5). Thresholds differ per browser.
    var failClosedURLReading = true

    // Override (3.7)
    var overrideCountdown: TimeInterval = FocusGuardConfig.current.overrideCountdown
    var overrideDuration: TimeInterval = FocusGuardConfig.current.overrideDuration
    var overridePhrase: String = FocusGuardConfig.current.overridePhrase

    var launchAtLogin = true
}

extension Settings {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, blocklist, baseline
        case gateOnUnlock, gateOnWake, gateOnIdleReturn, idleThreshold
        case maxFullSessionLength, openSessionCountdownEnabled, failClosedURLReading
        case overrideCountdown, overrideDuration, overridePhrase, launchAtLogin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        blocklist = try container.decodeIfPresent(Blocklist.self, forKey: .blocklist) ?? defaults.blocklist
        baseline = try container.decodeIfPresent(BaselineAllowlist.self, forKey: .baseline) ?? defaults.baseline
        gateOnUnlock = try container.decodeIfPresent(Bool.self, forKey: .gateOnUnlock) ?? defaults.gateOnUnlock
        gateOnWake = try container.decodeIfPresent(Bool.self, forKey: .gateOnWake) ?? defaults.gateOnWake
        gateOnIdleReturn = try container.decodeIfPresent(Bool.self, forKey: .gateOnIdleReturn) ?? defaults.gateOnIdleReturn
        idleThreshold = try container.decodeIfPresent(TimeInterval.self, forKey: .idleThreshold) ?? defaults.idleThreshold
        maxFullSessionLength = try container.decodeIfPresent(TimeInterval.self, forKey: .maxFullSessionLength) ?? defaults.maxFullSessionLength
        openSessionCountdownEnabled = try container.decodeIfPresent(Bool.self, forKey: .openSessionCountdownEnabled) ?? defaults.openSessionCountdownEnabled
        failClosedURLReading = try container.decodeIfPresent(Bool.self, forKey: .failClosedURLReading) ?? defaults.failClosedURLReading
        overrideCountdown = try container.decodeIfPresent(TimeInterval.self, forKey: .overrideCountdown) ?? defaults.overrideCountdown
        overrideDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .overrideDuration) ?? defaults.overrideDuration
        overridePhrase = try container.decodeIfPresent(String.self, forKey: .overridePhrase) ?? defaults.overridePhrase
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
    }
}

/// Brings a stored settings file up to the current defaults. Only changes that *tighten*
/// are applied automatically: a new default that would loosen an existing install is left
/// alone, the same rule the 24 hour delay follows (3.8).
enum SettingsMigration {
    static let currentVersion = 3

    struct Result: Equatable, Sendable {
        var settings: Settings
        var applied: [SettingsChange] = []
    }

    static func upgrade(_ stored: Settings) -> Result {
        var result = Result(settings: stored)

        if stored.schemaVersion < 3, !stored.launchAtLogin {
            // The gate cannot gate anything if it is not running at login. Turning this on
            // is tightening, so it applies rather than waiting.
            result.settings.launchAtLogin = true
            result.applied.append(.launchAtLoginChanged(to: true))
        }

        if stored.schemaVersion < 2, !stored.failClosedURLReading {
            // Shipped off during Phase 1, on by default from Phase 2. Turning it on is
            // tightening, so it applies immediately rather than waiting.
            result.settings.failClosedURLReading = true
            result.applied.append(.failClosedURLReadingEnabled)
        }

        result.settings.schemaVersion = currentVersion
        return result
    }
}

enum ChangeDirection: String, Codable, Equatable, Sendable {
    case tightening
    case loosening
    case neutral
}

/// One user-visible settings edit. Applying a change is separated from making it so that
/// a loosening edit can be stored, shown as pending, and applied 24 hours later.
enum SettingsChange: Codable, Equatable, Sendable {
    case blockedDomainAdded(String)
    case blockedDomainRemoved(String)
    case baselineAppAdded(String)
    case baselineAppRemoved(String)
    case passwordManagerSet(from: [String], to: [String])
    case gateTriggerEnabled(GateTriggerKind)
    case gateTriggerDisabled(GateTriggerKind)
    case idleThresholdChanged(from: TimeInterval, to: TimeInterval)
    case maxFullSessionLengthChanged(from: TimeInterval, to: TimeInterval)
    case openSessionCountdownEnabled
    case openSessionCountdownDisabled
    case failClosedURLReadingEnabled
    case failClosedURLReadingDisabled
    case overrideCountdownChanged(from: TimeInterval, to: TimeInterval)
    case overrideDurationChanged(from: TimeInterval, to: TimeInterval)
    case overridePhraseChanged(from: String, to: String)
    case launchAtLoginChanged(to: Bool)

    /// Anything not obviously tightening defaults to loosening, per 3.8.
    var direction: ChangeDirection {
        switch self {
        case .blockedDomainAdded,
             .baselineAppRemoved,
             .gateTriggerEnabled,
             .openSessionCountdownEnabled,
             .failClosedURLReadingEnabled:
            return .tightening

        case .idleThresholdChanged(let from, let to),
             .maxFullSessionLengthChanged(let from, let to):
            return to < from ? .tightening : .loosening

        case .overrideCountdownChanged(let from, let to):
            return to >= from ? .tightening : .loosening

        case .overrideDurationChanged(let from, let to):
            return to <= from ? .tightening : .loosening

        case .overridePhraseChanged(let from, let to):
            return to.count >= from.count ? .tightening : .loosening

        case .launchAtLoginChanged(to: true):
            return .tightening

        case .launchAtLoginChanged(to: false):
            return .loosening

        default:
            return .loosening
        }
    }

    var summary: String {
        switch self {
        case .blockedDomainAdded(let d): return "Block \(d)"
        case .blockedDomainRemoved(let d): return "Unblock \(d)"
        case .baselineAppAdded(let id): return "Always allow \(id)"
        case .baselineAppRemoved(let id): return "Stop always allowing \(id)"
        case .passwordManagerSet(_, let to): return to.isEmpty ? "Clear password manager" : "Set password manager to \(to.joined(separator: ", "))"
        case .gateTriggerEnabled(let kind): return "Gate on \(kind.rawValue)"
        case .gateTriggerDisabled(let kind): return "Stop gating on \(kind.rawValue)"
        case .idleThresholdChanged(_, let to): return "Idle threshold \(Int(to / 60)) min"
        case .maxFullSessionLengthChanged(_, let to): return "Max session \(Int(to / 60)) min"
        case .openSessionCountdownEnabled: return "Enable open-session countdown"
        case .openSessionCountdownDisabled: return "Disable open-session countdown"
        case .failClosedURLReadingEnabled: return "Treat unreadable pages as violations"
        case .failClosedURLReadingDisabled: return "Stop treating unreadable pages as violations"
        case .overrideCountdownChanged(_, let to): return "Override countdown \(Int(to))s"
        case .overrideDurationChanged(_, let to): return "Override window \(Int(to / 60)) min"
        case .overridePhraseChanged: return "Change override phrase"
        case .launchAtLoginChanged(let to): return to ? "Launch at login" : "Stop launching at login"
        }
    }
}

enum GateTriggerKind: String, Codable, Equatable, Sendable {
    case unlock
    case wake
    case idleReturn
}

struct PendingChange: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let change: SettingsChange
    let scheduledAt: Date
    let effectiveAt: Date

    init(id: UUID = UUID(), change: SettingsChange, scheduledAt: Date, delay: TimeInterval) {
        self.id = id
        self.change = change
        self.scheduledAt = scheduledAt
        self.effectiveAt = scheduledAt.addingTimeInterval(delay)
    }

    func isDue(at now: Date) -> Bool { now >= effectiveAt }
}
