import Foundation

/// One run of the app. `exitedCleanly` is written on normal termination; anything else is
/// evidence of a crash, a kill, or a watchdog exit (3.9.2).
struct LaunchRecord: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var launchedAt: Date
    var exitedCleanly: Bool
    var exitedAt: Date?
    var version: String
    var signature: String?
    var safeMode: SafeModeReason?

    init(
        id: UUID = UUID(),
        launchedAt: Date,
        exitedCleanly: Bool = false,
        exitedAt: Date? = nil,
        version: String,
        signature: String? = nil,
        safeMode: SafeModeReason? = nil
    ) {
        self.id = id
        self.launchedAt = launchedAt
        self.exitedCleanly = exitedCleanly
        self.exitedAt = exitedAt
        self.version = version
        self.signature = signature
        self.safeMode = safeMode
    }

    func lifetime(fallbackEnd: Date) -> TimeInterval {
        (exitedAt ?? fallbackEnd).timeIntervalSince(launchedAt)
    }
}

/// Pure decision: given past runs, should this launch skip the gate and enter safe mode?
enum CrashLoopDetector {
    /// Trailing runs that died uncleanly within `window` of their own launch. Three of
    /// those in a row means the app is failing on startup and must not gate the Mac.
    static func evaluate(
        records: [LaunchRecord],
        now: Date,
        threshold: Int = FocusGuardConfig.current.crashLoopThreshold,
        window: TimeInterval = FocusGuardConfig.current.crashLoopWindow
    ) -> Bool {
        var streak = 0
        for record in records.reversed() {
            // A run that ended cleanly, or survived past the window, breaks the streak.
            guard !record.exitedCleanly else { break }
            guard record.lifetime(fallbackEnd: now) < window else { break }
            streak += 1
            if streak >= threshold { return true }
        }
        return false
    }

    /// Control+Option+Command held at launch, shortly after boot (3.9.3).
    static func isRestartEscape(
        modifiersHeld: Bool,
        systemUptime: TimeInterval,
        maxUptime: TimeInterval = FocusGuardConfig.current.restartEscapeMaxUptime
    ) -> Bool {
        modifiersHeld && systemUptime < maxUptime
    }
}
