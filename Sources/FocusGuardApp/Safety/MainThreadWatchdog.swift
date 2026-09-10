import Foundation

/// Pings the main thread on a background thread. If the main thread stops answering for
/// `limit` seconds the app is wedged, which for a full-screen gate means the Mac is
/// unusable, so we get out of the way immediately (3.9.1).
final class MainThreadWatchdog: @unchecked Sendable {
    private let interval: TimeInterval
    private let limit: TimeInterval
    private let onHang: @Sendable (TimeInterval) -> Void
    private let lock = NSLock()
    private var lastPong = Date()
    private var thread: Thread?
    private var stopped = false

    init(
        interval: TimeInterval = FocusGuardConfig.current.watchdogPingInterval,
        limit: TimeInterval = FocusGuardConfig.current.watchdogHangLimit,
        onHang: @escaping @Sendable (TimeInterval) -> Void
    ) {
        self.interval = interval
        self.limit = limit
        self.onHang = onHang
    }

    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "com.focusguard.watchdog"
        thread.qualityOfService = .utility
        self.thread = thread
        pong()
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private func run() {
        while true {
            Thread.sleep(forTimeInterval: interval)

            lock.lock()
            let stopped = stopped
            let last = lastPong
            lock.unlock()
            if stopped { return }

            let unresponsive = Date().timeIntervalSince(last)
            if unresponsive >= limit {
                onHang(unresponsive)
                // Deliberately not exit(): atexit handlers run on a wedged process and can
                // deadlock. _exit leaves no clean-exit marker, so this counts as unclean.
                _exit(70)
            }

            DispatchQueue.main.async { [weak self] in self?.pong() }
        }
    }

    private func pong() {
        lock.lock()
        lastPong = Date()
        lock.unlock()
    }
}
