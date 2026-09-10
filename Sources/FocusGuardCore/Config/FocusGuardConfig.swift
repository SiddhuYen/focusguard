import Foundation

/// Every tunable number in the app lives here. Values match the v2 brief, Section 7.
struct FocusGuardConfig: Codable, Equatable, Sendable {
    // Gate
    var idleThreshold: TimeInterval = 10 * 60
    var idlePollInterval: TimeInterval = 20
    var gateTriggerDebounce: TimeInterval = 2

    // Sessions
    var fullSessionMaxLength: TimeInterval = 2 * 3600
    var fullSessionQuickPicks: [TimeInterval] = [10 * 60, 25 * 60, 50 * 60, 90 * 60]
    var openSessionLength: TimeInterval = 5 * 60
    var openSessionExtension: TimeInterval = 5 * 60
    var reviewExtendOptions: [TimeInterval] = [10 * 60, 25 * 60]
    var appsUsedThreshold: TimeInterval = 10

    // Open session countdown (3.2). Off by default; ladder is indexed by how many open
    // sessions started within `openSessionCountdownWindow`.
    var openSessionCountdownEnabled = false
    var openSessionCountdownLadder: [TimeInterval] = [0, 0, 30, 60, 120]
    var openSessionCountdownWindow: TimeInterval = 3600

    // Review and presets
    var chainThreshold: TimeInterval = 10 * 60
    var presetSuggestionCount = 3
    var presetSuggestionWindowDays = 14

    // Emergency override (3.7)
    var overridePhrase = "I am overriding Focus Guard and this goes in my daily review"
    var overrideCountdown: TimeInterval = 60
    var overrideDuration: TimeInterval = 15 * 60

    // Settings changes (3.8)
    var looseningDelay: TimeInterval = 24 * 3600

    // Browser enforcement (3.5)
    var urlPollInterval: TimeInterval = 0.8
    var urlFailClosedPolls = 5

    // Safety (3.9)
    var watchdogPingInterval: TimeInterval = 2
    var watchdogHangLimit: TimeInterval = 10
    var crashLoopThreshold = 3
    var crashLoopWindow: TimeInterval = 120
    /// Brief says 5 minutes; widened to 10 because a cold boot with FileVault plus login
    /// items can burn five before the app is even up. See the Phase 0 audit.
    var restartEscapeMaxUptime: TimeInterval = 600
    var debugShieldAutoDismiss: TimeInterval = 90

    // Tamper visibility (3.10)
    var heartbeatInterval: TimeInterval = 30
    var heartbeatGapThreshold: TimeInterval = 120

    static let current = FocusGuardConfig()
}
