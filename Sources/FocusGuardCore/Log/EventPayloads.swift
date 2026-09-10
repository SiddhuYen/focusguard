import Foundation

enum GateTrigger: String, Codable, Equatable, Sendable {
    case launch
    case unlock
    case wake
    case idleReturn
    case sessionEnded
    case overrideExpired
    case manual
}

enum SafeModeReason: String, Codable, Equatable, Sendable {
    case crashLoop
    case restartEscape
}

/// Why this launch is in safe mode, with the evidence that put it there.
struct SafeModeEntry: Codable, Equatable, Sendable {
    var reason: SafeModeReason
    var detail: String

    var message: String {
        switch reason {
        case .crashLoop: return "Safe mode: Focus Guard crashed repeatedly, so the gate is off for this launch."
        case .restartEscape: return "Safe mode: restart escape used, so the gate is off for this launch."
        }
    }
}

struct AppLaunchedPayload: EventPayload {
    static let eventType = EventType.appLaunched
    var version: String
    var build: String
    var systemUptime: TimeInterval
    var safeMode: SafeModeReason?
    var uncleanExit: Bool
    var accessibilityTrusted: Bool
}

struct AppTerminatingPayload: EventPayload {
    static let eventType = EventType.appTerminating
    var clean: Bool
    var reason: String
}

struct GateShownPayload: EventPayload {
    static let eventType = EventType.gateShown
    var trigger: GateTrigger
    var lastSessionID: UUID?
}

struct GateAnsweredPayload: EventPayload {
    static let eventType = EventType.gateAnswered
    var sessionID: UUID
    var finished: Bool
}

struct SessionStartedPayload: EventPayload {
    static let eventType = EventType.sessionStarted
    var sessionID: UUID
    var kind: SessionKind
    var goal: String
    var anchorBundleID: String
    var allowedBundleIDs: [String]
    var allowedSites: [SiteRule]
    var allowAllNonBlockedSites: Bool
    var plannedEnd: Date?
    var presetID: UUID?
}

struct SessionExtendedPayload: EventPayload {
    static let eventType = EventType.sessionExtended
    var sessionID: UUID
    var by: TimeInterval
    var newPlannedEnd: Date
}

struct SessionConvertedPayload: EventPayload {
    static let eventType = EventType.sessionConverted
    var fromSessionID: UUID
    var toSessionID: UUID
    var goal: String
    var allowedBundleIDs: [String]
}

struct SessionEndedPayload: EventPayload {
    static let eventType = EventType.sessionEnded
    var sessionID: UUID
    var kind: SessionKind
    var goal: String
    var outcome: SessionOutcome
    var startedAt: Date
    var endedAt: Date
    var plannedEnd: Date?
    var violationCount: Int
    var additionCount: Int
}

struct AppsUsedSnapshotPayload: EventPayload {
    static let eventType = EventType.appsUsedSnapshot
    var sessionID: UUID
    var apps: [AppUsage]
    var domains: [String]
}

struct ViolationPayload: EventPayload {
    static let eventType = EventType.violation
    var sessionID: UUID
    var kind: ViolationKind
    var appBundleID: String
    var appName: String
}

struct AdditionPayload: EventPayload {
    static let eventType = EventType.additionToSession
    var sessionID: UUID
    var target: AdditionTarget
    var reason: String
}

struct OverrideStartedPayload: EventPayload {
    static let eventType = EventType.overrideStarted
    var reason: String
    var until: Date
}

struct OverrideEndedPayload: EventPayload {
    static let eventType = EventType.overrideEnded
    var startedAt: Date
    var early: Bool
}

struct SafeModePayload: EventPayload {
    static let eventType = EventType.safeModeEntered
    var reason: SafeModeReason
    var detail: String
}

struct HangDetectedPayload: EventPayload {
    static let eventType = EventType.hangDetected
    var unresponsiveSeconds: TimeInterval
}

struct HeartbeatGapPayload: EventPayload {
    static let eventType = EventType.heartbeatGap
    var from: Date
    var to: Date
    var explained: Bool
}

struct BuildChangedPayload: EventPayload {
    static let eventType = EventType.buildChanged
    var previousVersion: String?
    var version: String
    var previousSignature: String?
    var signature: String?
}

struct PermissionPayload: EventPayload {
    static let eventType = EventType.permissionLost
    var permission: String
    var detail: String
}

struct PermissionRestoredPayload: EventPayload {
    static let eventType = EventType.permissionRestored
    var permission: String
}

/// How often we could actually read a browser's address bar. Fail-closed enforcement is
/// only as fair as this number, and for Firefox it is measured rather than assumed (3.5).
struct URLReadHealthPayload: EventPayload {
    static let eventType = EventType.urlReadHealth
    var browser: String
    var reads: Int
    var failures: Int
    var longestFailureRun: Int
    var viaAccessibility: Bool

    var successRate: Double {
        let total = reads + failures
        return total == 0 ? 1 : Double(reads) / Double(total)
    }
}

struct SettingsChangeScheduledPayload: EventPayload {
    static let eventType = EventType.settingsChangeScheduled
    var changeID: UUID
    var change: SettingsChange
    var effectiveAt: Date
}

struct SettingsChangeCancelledPayload: EventPayload {
    static let eventType = EventType.settingsChangeCancelled
    var changeID: UUID
    var change: SettingsChange
}

struct SettingsChangeAppliedPayload: EventPayload {
    static let eventType = EventType.settingsChangeApplied
    var changeID: UUID?
    var change: SettingsChange
    var delayed: Bool
}

struct PresetCreatedPayload: EventPayload {
    static let eventType = EventType.presetCreated
    var presetID: UUID
    var name: String
    var source: String
}

struct PresetSuggestedPayload: EventPayload {
    static let eventType = EventType.presetSuggested
    var name: String
    var accepted: Bool
}

struct SleepRequestedPayload: EventPayload {
    static let eventType = EventType.sleepRequested
    var source: String
    var succeeded: Bool
}

struct SessionImportedPayload: EventPayload {
    static let eventType = EventType.sessionImported
    var session: Session
}
