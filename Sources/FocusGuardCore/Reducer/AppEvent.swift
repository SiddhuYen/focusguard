import Foundation

/// Everything that can happen to the app. The AppKit layer translates notifications,
/// timers, and clicks into these; nothing else drives state.
enum AppEvent: Equatable, Sendable {
    case launched(restoredSession: Session?, safeMode: SafeModeEntry?)
    case sessionStartRequested(SessionRequest)
    case appActivated(AppIdentity)
    case urlObserved(browser: AppIdentity, url: URL)
    case urlReadFailed(browser: AppIdentity, consecutiveFailures: Int)
    case returnRequested
    case addToSessionRequested(target: AdditionTarget, reason: String)
    case escapeRequested(duration: TimeInterval, reason: String?)
    case escapeExpired
    case endRequested(outcome: SessionOutcome)
    case permissionsChanged(PermissionHealth)
    case settingsEdited(Settings)
    case pendingChangeCancelled(UUID)
    case presetsLoaded([Preset])
    case tick
    case statusMessageCleared
}

struct SessionRequest: Equatable, Sendable {
    var kind: SessionKind
    var goal: String
    var anchor: AppIdentity
    var allowedBundleIDs: [String]
    var allowedSites: [SiteRule] = []
    var allowAllNonBlockedSites = false
    var duration: TimeInterval?
    var presetID: UUID?
}

/// Side effects. Only the AppKit layer executes these.
enum Effect: Equatable, Sendable {
    case log(LogEvent)
    case persistSession(Session?)
    case persistSettings(Settings)
    case persistPendingChanges([PendingChange])
    case showIntervention(Session, Violation)
    case bringInterventionToFront
    case dismissIntervention
    case activateApp(bundleID: String)
    case monitorURLs(AppIdentity?)
    case scheduleEscapeEnd(at: Date)
    case cancelEscapeTimer
}
