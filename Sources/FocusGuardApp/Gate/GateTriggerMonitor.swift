import AppKit
import CoreGraphics
import Foundation

/// Watches for the moments the gate should appear: login, unlock, wake, and coming back
/// after being idle (3.1). Several of these fire together for one physical event, so
/// everything is debounced.
@MainActor
final class GateTriggerMonitor {
    var onTrigger: ((GateTrigger) -> Void)?
    /// Read at fire time so a settings change takes effect without restarting monitors.
    var settingsProvider: () -> Settings = { Settings() }

    private var idleTimer: Timer?
    private var lastTriggerAt = Date.distantPast
    private var wasIdle = false
    private let config: FocusGuardConfig
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    init(config: FocusGuardConfig = .current) {
        self.config = config
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fire(.wake, enabled: \.gateOnWake) }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fire(.wake, enabled: \.gateOnWake) }
        })

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.fire(.unlock, enabled: \.gateOnUnlock) }
        })
        distributedObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.wasIdle = true }
        })

        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: config.idlePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIdle() }
        }
    }

    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
    }

    /// Seconds since the last keyboard, mouse or trackpad event.
    static func idleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    private func checkIdle() {
        let idle = GateTriggerMonitor.idleSeconds()
        let threshold = settingsProvider().idleThreshold

        if idle >= threshold {
            wasIdle = true
        } else if wasIdle, idle < config.idlePollInterval {
            // Input resumed after a long gap: that is a return, not a lull.
            wasIdle = false
            fire(.idleReturn, enabled: \.gateOnIdleReturn)
        }
    }

    private func fire(_ trigger: GateTrigger, enabled keyPath: KeyPath<Settings, Bool>) {
        guard settingsProvider()[keyPath: keyPath] else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTriggerAt) > config.gateTriggerDebounce else { return }
        lastTriggerAt = now
        wasIdle = false
        onTrigger?(trigger)
    }
}
