import AppKit
import Foundation

/// Exactly one Focus Guard per data directory, enforced with flock(2). The kernel drops the
/// lock when the process dies, crash included, so a dead copy can never block the next one.
@MainActor
enum SingleInstance {
    private static var lockDescriptor: Int32 = -1
    private static var yieldObserver: NSObjectProtocol?

    static let role = InstancePolicy.role(xpcServiceName: ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"])

    static var lockPath: String {
        FocusGuardPaths().state.appendingPathComponent("instance.lock").path
    }

    /// True if this process should go on launching. Runs before any window or state exists.
    static func claim() -> Bool {
        try? FocusGuardPaths().createDirectories()
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o644)
        // Fail open: a lock file we cannot open must never be the reason the gate is missing.
        guard descriptor >= 0 else { return true }

        func tryLock() -> Bool { flock(descriptor, LOCK_EX | LOCK_NB) == 0 }

        var acquired = tryLock()
        var yieldRequested = false

        while true {
            switch InstancePolicy.decide(role: role, lockAcquired: acquired, yieldAlreadyRequested: yieldRequested) {
            case .proceed:
                lockDescriptor = descriptor
                let pid = Data("\(getpid())\n".utf8)
                ftruncate(descriptor, 0)
                _ = pid.withUnsafeBytes { write(descriptor, $0.baseAddress, pid.count) }
                return true

            case .requestYieldThenRetry:
                yieldRequested = true
                DistributedNotificationCenter.default().postNotificationName(
                    .init(InstancePolicy.yieldNotification),
                    object: nil,
                    userInfo: [InstancePolicy.yieldLockPathKey: lockPath],
                    deliverImmediately: true
                )
                // Before any UI and before the watchdog starts, so a short blocking wait is fine.
                let deadline = Date().addingTimeInterval(3)
                while !acquired, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                    acquired = tryLock()
                }

            case .activateExistingAndExit:
                close(descriptor)
                NSRunningApplication.runningApplications(withBundleIdentifier: BuildInfo.bundleID)
                    .first { $0.processIdentifier != getpid() }?
                    .activate()
                return false

            case .exitQuietly:
                close(descriptor)
                return false
            }
        }
    }

    /// A hand-opened copy steps aside when the login agent starts, so the agent is the one
    /// that survives kills and logins.
    static func observeYieldRequests(_ yield: @escaping @MainActor () -> Void) {
        guard role == .manual, yieldObserver == nil else { return }
        let ownPath = lockPath
        yieldObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init(InstancePolicy.yieldNotification),
            object: nil,
            queue: .main
        ) { notification in
            let requested = notification.userInfo?[InstancePolicy.yieldLockPathKey] as? String
            guard InstancePolicy.shouldYield(role: .manual, requestLockPath: requested, ownLockPath: ownPath) else { return }
            Task { @MainActor in yield() }
        }
    }
}
