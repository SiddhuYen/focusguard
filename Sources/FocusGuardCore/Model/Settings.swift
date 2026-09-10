import Foundation

/// Everything the user can change. Changes run through SettingsChange so that loosening
/// edits can be delayed 24 hours (3.8).
struct Settings: Codable, Equatable, Sendable {
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
    /// Turned on in Phase 2. When set, a browser whose URL cannot be read for
    /// `urlFailClosedPolls` polls counts as a violation instead of being ignored (3.5).
    var failClosedURLReading = false

    // Override (3.7)
    var overrideCountdown: TimeInterval = FocusGuardConfig.current.overrideCountdown
    var overrideDuration: TimeInterval = FocusGuardConfig.current.overrideDuration
    var overridePhrase: String = FocusGuardConfig.current.overridePhrase

    var launchAtLogin = false
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
