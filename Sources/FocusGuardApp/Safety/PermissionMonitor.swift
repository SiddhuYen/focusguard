import AppKit
import ApplicationServices
import Foundation

/// Watches the two permissions enforcement depends on. Losing one must be loud, and must
/// never be silent (3.5).
@MainActor
final class PermissionMonitor {
    /// AppleScript's "not authorized to send Apple events" error.
    static let notAuthorizedErrorCode = -1743

    var onChange: ((PermissionHealth) -> Void)?

    private var timer: Timer?
    private(set) var health = PermissionHealth()

    func start(interval: TimeInterval = 5) {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        var updated = health
        updated.accessibilityTrusted = AXIsProcessTrusted()
        if updated.accessibilityTrusted && updated.automationAuthorized {
            updated.detail = nil
        } else if !updated.accessibilityTrusted {
            updated.detail = "AXIsProcessTrusted() is false"
        }
        publish(updated)
    }

    /// Called by the URL monitor when AppleScript refuses to talk to a browser.
    func noteAutomationError(code: Int, browser: String) {
        guard code == PermissionMonitor.notAuthorizedErrorCode else { return }
        var updated = health
        updated.automationAuthorized = false
        updated.detail = "AppleScript to \(browser) returned \(code)"
        publish(updated)
    }

    func noteAutomationSuccess() {
        guard !health.automationAuthorized else { return }
        var updated = health
        updated.automationAuthorized = true
        updated.detail = health.accessibilityTrusted ? nil : health.detail
        publish(updated)
    }

    private func publish(_ updated: PermissionHealth) {
        guard updated != health else { return }
        health = updated
        onChange?(updated)
    }

    // MARK: - Opening the right System Settings panes

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openAutomationSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
