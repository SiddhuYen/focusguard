import Foundation

/// Pings the main thread on a background thread. If the main thread stops answering for
/// `limit` seconds the app is wedged, which for a full-screen gate means the Mac is
/// unusable, so we get out of the way immediately (3.9.1).
final class MainThreadWatchdog: @unchecked Sendable {
    private let interval: TimeInterval
    private let limit: TimeInterval
    private let onHang: @Sendable (TimeInterval) -> Void
    private let lock = NSLock()
    private var lastPong = MainThreadWatchdog.awakeSeconds()
    private var thread: Thread?
    private var beacon: Timer?
    private var stopped = false

    /// Seconds since boot *excluding* time asleep. Wall-clock time would count a five
    /// minute nap as five minutes of unresponsiveness and kill the app on every wake.
    static func awakeSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

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
        pong()
        startBeacon()

        let thread = Thread { [weak self] in self?.run() }
        thread.name = "com.focusguard.watchdog"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    /// The main thread's proof of life. It is a run loop timer rather than only a
    /// DispatchQueue.main block because AppKit switches run loop modes for modal panels,
    /// menu tracking and window dragging, and the main queue can starve in those. A
    /// wedged main thread services none of these modes; a busy one services all of them.
    private func startBeacon() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.pong()
        }
        for mode in [RunLoop.Mode.common, .modalPanel, .eventTracking] {
            RunLoop.main.add(timer, forMode: mode)
        }
        beacon = timer
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        beacon?.invalidate()
        beacon = nil
    }

    private func run() {
        while true {
            Thread.sleep(forTimeInterval: interval)

            lock.lock()
            let stopped = stopped
            let last = lastPong
            lock.unlock()
            if stopped { return }

            let unresponsive = MainThreadWatchdog.awakeSeconds() - last
            if unresponsive >= limit {
                // Confirm once before acting: one missed window is not a wedge.
                Thread.sleep(forTimeInterval: interval)
                lock.lock()
                let confirmed = MainThreadWatchdog.awakeSeconds() - lastPong
                lock.unlock()
                guard confirmed >= limit else { continue }
                onHang(confirmed)
                // Deliberately not exit(): atexit handlers run on a wedged process and can
                // deadlock. _exit leaves no clean-exit marker, so this counts as unclean.
                _exit(70)
            }

            DispatchQueue.main.async { [weak self] in self?.pong() }
        }
    }

    private func pong() {
        lock.lock()
        lastPong = MainThreadWatchdog.awakeSeconds()
        lock.unlock()
    }
}
