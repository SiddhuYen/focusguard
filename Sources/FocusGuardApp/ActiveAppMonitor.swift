import AppKit

@MainActor
final class ActiveAppMonitor: NSObject {
    var onActiveAppChanged: ((RunningApp) -> Void)?

    private var isMonitoring = false

    func start() {
        guard !isMonitoring else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        isMonitoring = true
    }

    func stop() {
        guard isMonitoring else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        isMonitoring = false
    }

    @objc private func activeApplicationDidChange(_ notification: Notification) {
        guard
            let runningApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let app = RunningApp(runningApplication: runningApplication)
        else { return }

        // Focus Guard's own panels must never look like a violation.
        if runningApplication.bundleIdentifier == BuildInfo.bundleID { return }

        onActiveAppChanged?(app)
    }
}
