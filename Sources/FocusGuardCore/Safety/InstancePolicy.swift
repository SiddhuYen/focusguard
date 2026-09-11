import Foundation

/// Which copy of Focus Guard this process is. Two copies meant two gates, each with its own
/// belief about whether a session was running: start a session in one, and the other kept
/// asking about the last goal and demanding a new one.
enum InstanceRole: Equatable, Sendable {
    /// Started by launchd from the login agent. This is the copy that should survive.
    case agent
    /// Opened by hand, from Finder, the Dock, or a terminal.
    case manual
}

enum InstanceAction: Equatable, Sendable {
    case proceed
    /// The lock is held by a hand-opened copy: ask it to step aside, then try again.
    case requestYieldThenRetry
    /// Someone else is already the gate: bring them forward and leave.
    case activateExistingAndExit
    /// The agent asked and the holder did not yield in time: leave quietly and let launchd
    /// try again later, rather than running a second gate.
    case exitQuietly
}

enum InstancePolicy {
    static let agentLabel = "app.focusguard.mvp.agent"
    static let yieldNotification = "app.focusguard.mvp.yield"
    static let yieldLockPathKey = "lockPath"

    /// launchd sets XPC_SERVICE_NAME to the job label; LaunchServices sets it to
    /// "application.<bundle id>.<ids>". Verified on both live processes, 2026-09-10.
    static func role(xpcServiceName: String?) -> InstanceRole {
        xpcServiceName == agentLabel ? .agent : .manual
    }

    static func decide(role: InstanceRole, lockAcquired: Bool, yieldAlreadyRequested: Bool) -> InstanceAction {
        if lockAcquired { return .proceed }
        switch role {
        case .manual:
            return .activateExistingAndExit
        case .agent:
            return yieldAlreadyRequested ? .exitQuietly : .requestYieldThenRetry
        }
    }

    /// A hand-opened copy steps aside for the agent. The agent never steps aside, and a
    /// request aimed at a different data directory (a self-check, a render) is ignored.
    static func shouldYield(role: InstanceRole, requestLockPath: String?, ownLockPath: String) -> Bool {
        role == .manual && requestLockPath == ownLockPath
    }
}
