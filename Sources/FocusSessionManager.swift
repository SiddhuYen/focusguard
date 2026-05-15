import AppKit
import Combine
import Foundation

@MainActor
final class FocusSessionManager: ObservableObject {
    @Published private(set) var state: FocusState = .idle
    @Published var settings: UserSettings {
        didSet {
            settingsStore.save(settings)
        }
    }
    @Published private(set) var sessionHistory: [FocusSession]
    @Published private(set) var currentAppName: String = "Unknown"
    @Published private(set) var statusMessage: String?

    private let appResolver = AppIdentityResolver()
    private let monitor = ActiveAppMonitor()
    private let settingsStore = UserSettingsStore()
    private let historyStore = SessionHistoryStore()
    private let interventionEngine = InterventionEngine()
    private var graceTimer: Timer?

    init() {
        let settingsStore = UserSettingsStore()
        self.settings = settingsStore.load()
        self.sessionHistory = SessionHistoryStore().load()

        monitor.onActiveAppChanged = { [weak self] app in
            self?.handleActiveAppChanged(to: app)
        }

        if let app = appResolver.frontmostApp() {
            currentAppName = app.name
        }
    }

    var menuBarTitle: String {
        switch state {
        case .idle:
            return "Focus App: Idle"
        case .focusing(let session):
            return "Focusing: \(session.allowedAppName)"
        case .gracePeriod(let session, _):
            return "Escape: \(session.allowedAppName)"
        case .intervention(let session, _):
            return "Left: \(session.allowedAppName)"
        case .paused(let session):
            return "Paused: \(session.allowedAppName)"
        }
    }

    var menuBarSystemImage: String {
        switch state {
        case .idle:
            return "circle"
        case .focusing:
            return "target"
        case .gracePeriod:
            return "timer"
        case .intervention:
            return "exclamationmark.triangle"
        case .paused:
            return "pause.circle"
        }
    }

    var activeSession: FocusSession? {
        state.activeSession
    }

    var canStartFocus: Bool {
        if case .idle = state {
            return true
        }
        return false
    }

    func startFocusOnCurrentApp() {
        guard let app = appResolver.frontmostApp() else {
            statusMessage = "Could not read the current app."
            return
        }

        startFocus(on: app)
    }

    func startFocus(on app: RunningApp) {
        dismissIntervention()
        graceTimer?.invalidate()
        currentAppName = app.name

        let session = FocusSession(app: app)
        state = .focusing(session)
        monitor.start()
        statusMessage = "Focusing on \(app.name)."
    }

    func stopFocus(reason: StopReason = .user) {
        graceTimer?.invalidate()
        dismissIntervention()

        if var session = state.activeSession {
            session.endedAt = Date()
            historyStore.append(session)
            sessionHistory = historyStore.load()
        }

        state = .idle
        monitor.stop()
        statusMessage = reason == .quit ? nil : "Focus ended."
    }

    func handleActiveAppChanged(to app: RunningApp) {
        currentAppName = app.name

        switch state {
        case .idle, .paused:
            return
        case .focusing(let session):
            handlePotentialViolation(app: app, session: session)
        case .gracePeriod(let session, let until):
            if Date() >= until {
                state = .focusing(session)
                handlePotentialViolation(app: app, session: session)
            }
        case .intervention(let session, _):
            if app.bundleIdentifier == session.allowedBundleID {
                dismissIntervention()
                state = .focusing(session)
            }
        }
    }

    func allowTemporaryEscape(duration: TimeInterval? = nil, reason: String? = nil) {
        guard var session = state.activeSession else {
            return
        }

        let escapeDuration = duration ?? settings.defaultEscapeDuration
        let escape = FocusEscape(duration: escapeDuration, reason: reason)
        session.escapes.append(escape)

        let until = Date().addingTimeInterval(escapeDuration)
        dismissIntervention()
        state = .gracePeriod(session, until: until)
        statusMessage = "Temporary escape started."

        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(withTimeInterval: escapeDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.finishGracePeriod()
            }
        }
    }

    func returnToAllowedApp() {
        guard let session = state.activeSession else {
            return
        }

        dismissIntervention()

        if let runningApplication = appResolver.runningApplication(for: session) {
            runningApplication.unhide()
            runningApplication.activate(options: [.activateAllWindows])
            state = .focusing(session)
            statusMessage = "Returned to \(session.allowedAppName)."
        } else {
            statusMessage = "\(session.allowedAppName) does not appear to be running."
            state = .focusing(session)
        }
    }

    func clearStatusMessage() {
        statusMessage = nil
    }

    private func handlePotentialViolation(app: RunningApp, session: FocusSession) {
        if app.bundleIdentifier == session.allowedBundleID {
            return
        }

        let rules = focusRules
        if rules.allowedBundleIDs.contains(app.bundleIdentifier) {
            return
        }

        var updatedSession = session
        let violation = FocusViolation(app: app)
        updatedSession.violations.append(violation)
        state = .intervention(updatedSession, violation: violation)

        interventionEngine.present(
            session: updatedSession,
            violation: violation,
            settings: settings,
            onReturn: { [weak self] in self?.returnToAllowedApp() },
            onEscape: { [weak self] reason in self?.allowTemporaryEscape(reason: reason) },
            onEnd: { [weak self] in self?.stopFocus() }
        )
    }

    private var focusRules: FocusRules {
        FocusRules(
            allowSystemApps: true,
            allowFinder: false,
            gracePeriodSeconds: settings.gracePeriodSeconds,
            requireReason: settings.requireReasonToLeave
        )
    }

    private func finishGracePeriod() {
        guard case .gracePeriod(let session, _) = state else {
            return
        }

        state = .focusing(session)

        if let currentApp = appResolver.frontmostApp() {
            handlePotentialViolation(app: currentApp, session: session)
        }
    }

    private func dismissIntervention() {
        interventionEngine.dismiss()
    }
}
