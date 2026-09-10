import Foundation

/// Everything that can happen to the app. The AppKit layer translates notifications,
/// timers, and clicks into these; nothing else drives state.
enum AppEvent: Equatable, Sendable {
    case launched(restoredSession: Session?, safeMode: SafeModeEntry?)
    /// Login, unlock, wake, return from idle, or a session ending (3.1).
    case gateTriggered(GateTrigger)
    /// Answering "Your last goal was X. Did you finish?" on the gate.
    case gateAnswered(finished: Bool)

    case sessionStartRequested(SessionRequest)
    case openSessionExtended
    case convertToFullRequested(SessionRequest)
    case reviewExtended(by: TimeInterval)
    case reviewAnswered(finished: Bool)
    /// Ending from the menu or the intervention panel goes through the review (3.6).
    case endRequested
    /// Ends immediately, no review: quitting, or a session that expired while away.
    case forceEnd(outcome: SessionOutcome)

    case appActivated(AppIdentity)
    case urlObserved(browser: AppIdentity, url: URL)
    case urlReadFailed(browser: AppIdentity, consecutiveFailures: Int)
    case returnRequested
    case addToSessionRequested(target: AdditionTarget, reason: String)

    case overrideStarted(reason: String)
    case overrideEnded(early: Bool)
    case sleepRequested

    case permissionsChanged(PermissionHealth)
    case settingsEdited(Settings)
    case pendingChangeCancelled(UUID)
    case presetsLoaded([Preset])
    case presetCreated(Preset, source: String)
    case recentGoalsLoaded([RecentGoal])

    /// Carries how long the user has been idle so an expired session can wait for them
    /// rather than throwing a review panel at an empty chair (3.6).
    case tick(idleSeconds: TimeInterval = 0)
    case statusMessageCleared
}

struct SessionRequest: Equatable, Sendable {
    var kind: SessionKind
    var goal: String
    var anchor: AppIdentity
    var allowedBundleIDs: [String]
    var allowedSites: [SiteRule] = []
    var allowAllNonBlockedSites = false
    /// Required for full sessions; ignored for open ones, which are always 5 minutes.
    var duration: TimeInterval?
    var presetID: UUID?
    var convertedFrom: UUID?
}

/// Side effects. Only the AppKit layer executes these.
enum Effect: Equatable, Sendable {
    case log(LogEvent)
    case persistSession(Session?)
    case persistSettings(Settings)
    case persistPendingChanges([PendingChange])
    case persistPresets([Preset])
    case persistRecentGoals([RecentGoal])

    case showShield(GateContext)
    case hideShield
    case setKiosk(Bool)
    case showReview(Session, ReviewReason)
    case dismissReview

    case showIntervention(Session, Violation)
    case bringInterventionToFront
    case dismissIntervention

    case activateApp(bundleID: String)
    case hideApps(allowed: [String])
    case monitorURLs(AppIdentity?)
    case sleepMac
}
