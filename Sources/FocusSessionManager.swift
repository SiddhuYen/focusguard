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
    private var lastNonSelfApp: RunningApp?
    @Published private(set) var statusMessage: String?

    // MARK: - Multi-App Focus scaffolding
    struct AppDisplayItem: Identifiable, Equatable {
        var id: String { bundleIdentifier }
        let bundleIdentifier: String
        let displayName: String
    }

    @Published var multiAppSearchText: String = "" {
        didSet { updateMultiAppSearchResults() }
    }
    @Published private(set) var multiAppSearchResults: [AppDisplayItem] = []
    @Published private(set) var multiAppAllowedBundleIDs: [String] = []

    // Derived display items for the allowed list
    var multiAppAllowedDisplayItems: [AppDisplayItem] {
        multiAppAllowedBundleIDs.map { id in
            AppDisplayItem(bundleIdentifier: id, displayName: resolveDisplayName(for: id) ?? id)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private let appResolver = AppIdentityResolver()
    private let monitor = ActiveAppMonitor()
    private let settingsStore = UserSettingsStore()
    private let historyStore = SessionHistoryStore()
    private let interventionEngine = InterventionEngine()
    private let selectorEngine = MultiAppSelectorEngine()
    private let urlMonitor = BrowserURLMonitor()
    private let commitmentPromptEngine = CommitmentPromptEngine()
    private var graceTimer: Timer?

    // Editable distracting domains list (persisted)
    @Published var blockedDomainsEditable: [String] = [] {
        didSet { saveBlockedDomains() }
    }
    private var blockedDomains: Set<String> {
        Set(blockedDomainsEditable.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
    }
    private let blockedDomainsKey = "FocusGuard.BlockedDomains"

    init() {
        let settingsStore = UserSettingsStore()
        self.settings = settingsStore.load()
        self.sessionHistory = SessionHistoryStore().load()

        monitor.onActiveAppChanged = { [weak self] app in
            self?.handleActiveAppChanged(to: app)
        }

        urlMonitor.onURLChange = { [weak self] change in
            guard let self else { return }
            self.handleURLChange(change)
        }

        if let app = appResolver.frontmostApp() {
            currentAppName = app.name
            lastNonSelfApp = app
        }

        if let data = UserDefaults.standard.array(forKey: blockedDomainsKey) as? [String], !data.isEmpty {
            blockedDomainsEditable = data
        } else {
            blockedDomainsEditable = [
                "instagram.com",
                "www.instagram.com",
                "youtube.com",
                "www.youtube.com",
                "m.youtube.com",
                "tiktok.com",
                "www.tiktok.com",
                "snapchat.com",
                "www.snapchat.com",
                "twitter.com",
                "www.twitter.com",
                "x.com",
                "www.x.com",
                "reddit.com",
                "www.reddit.com"
            ]
        }
    }

    // MARK: - Multi-App Focus API (minimal)
    func presentMultiAppSelector() {
        guard canStartFocus else { return }
        selectorEngine.present(sessionManager: self)
    }

    func startMultiAppFocusAndDismiss() {
        startMultiAppFocus()
        selectorEngine.dismiss()
    }

    func addCurrentAppToAllowed() {
        if let app = appResolver.frontmostApp() ?? lastNonSelfApp {
            addAllowedBundleID(app.bundleIdentifier)
        }
    }

    func addAllowedApp(_ item: AppDisplayItem) {
        addAllowedBundleID(item.bundleIdentifier)
    }

    func removeAllowedApp(_ item: AppDisplayItem) {
        multiAppAllowedBundleIDs.removeAll { $0 == item.bundleIdentifier }
    }

    func resetMultiAppSelection() {
        multiAppSearchText = ""
        multiAppSearchResults = []
        multiAppAllowedBundleIDs = []
    }

    func startMultiAppFocus() {
        guard canStartFocus else { return }

        // Seed with current app if empty, to match requested UX
        if multiAppAllowedBundleIDs.isEmpty, let app = appResolver.frontmostApp() ?? lastNonSelfApp {
            addAllowedBundleID(app.bundleIdentifier)
        }

        // Start a session anchored to the current app (preserves existing design/feel)
        let anchorApp = appResolver.frontmostApp() ?? lastNonSelfApp
        guard let app = anchorApp else {
            statusMessage = "Could not read the current app."
            return
        }

        guard let goal = commitmentPromptEngine.promptForGoal(appName: app.name) else {
            statusMessage = "Focus start canceled."
            return
        }
  
        dismissIntervention()
        graceTimer?.invalidate()
        currentAppName = app.name

        let session = FocusSession(anchorApp: app, allowedBundleIDsMulti: multiAppAllowedBundleIDs, goal: goal)
        state = .focusing(session)
        monitor.start()

        if let current = appResolver.frontmostApp() {
            startURLMonitoringIfNeeded(for: current)
        }

        statusMessage = "Focusing on \(multiAppAllowedBundleIDs.count) apps."
        resetMultiAppSelection()
    }

    // MARK: - Search helpers
    private func updateMultiAppSearchResults() {
        let query = multiAppSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            multiAppSearchResults = []
            return
        }

        // Build candidate list from running apps, session history, and current allowed list
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> AppDisplayItem? in
            guard let bundleID = app.bundleIdentifier else { return nil }
            let name = app.localizedName ?? bundleID
            return AppDisplayItem(bundleIdentifier: bundleID, displayName: name)
        }

        let historyItems: [AppDisplayItem] = sessionHistory.compactMap { s in
            if let list = s.allowedBundleIDsMulti, let id = list.first {
                return AppDisplayItem(
                    bundleIdentifier: id,
                    displayName: resolveDisplayName(for: id) ?? id
                )
            }

            let id = s.allowedBundleID
            return AppDisplayItem(
                bundleIdentifier: id,
                displayName: resolveDisplayName(for: id) ?? id
            )
        }
        let allowedItems: [AppDisplayItem] = multiAppAllowedDisplayItems

        let candidates = (running + historyItems + allowedItems)
            .reduce(into: [String: AppDisplayItem]()) { dict, item in
                dict[item.bundleIdentifier] = dict[item.bundleIdentifier] ?? item
            }
            .map { $0.value }

        multiAppSearchResults = candidates
            .filter { item in
                item.displayName.localizedCaseInsensitiveContains(query) ||
                item.bundleIdentifier.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func addAllowedBundleID(_ bundleID: String) {
        if !multiAppAllowedBundleIDs.contains(bundleID) {
            multiAppAllowedBundleIDs.append(bundleID)
        }
    }

    private func resolveDisplayName(for bundleID: String) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }?.localizedName
    }

    var menuBarTitle: String {
        switch state {
        case .idle:
            return "Focus App: Idle"
        case .focusing(let session):
            return multiTitle(prefix: "Focusing", session: session)
        case .gracePeriod(let session, _):
            return multiTitle(prefix: "Escape", session: session)
        case .intervention(let session, _):
            return multiTitle(prefix: "Left", session: session)
        case .paused(let session):
            return multiTitle(prefix: "Paused", session: session)
        }
    }

    private func multiTitle(prefix: String, session: FocusSession) -> String {
        if let list = session.allowedBundleIDsMulti, !list.isEmpty {
            return "\(prefix): \(list.count) apps"
        } else {
            return "\(prefix): \(session.allowedAppName)"
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
        let app = appResolver.frontmostApp() ?? lastNonSelfApp
        guard let app else {
            statusMessage = "Could not read the current app."
            return
        }

        startFocus(on: app)
    }

    func startFocus(on app: RunningApp) {
        guard let goal = commitmentPromptEngine.promptForGoal(appName: app.name) else {
            statusMessage = "Focus start canceled."
            return
        }

        dismissIntervention()
        graceTimer?.invalidate()
        currentAppName = app.name

        let session = FocusSession(app: app, goal: goal)
        state = .focusing(session)
        monitor.start()
        startURLMonitoringIfNeeded(for: app)
        statusMessage = "Focusing on \(app.name)."
    }

    func stopFocus(reason: StopReason = .user) {
        guard confirmGoalIfNeeded(action: .endFocus) else {
            return
        }

        performStopFocus(reason: reason)
    }

    func quit() {
        guard confirmGoalIfNeeded(action: .quit) else {
            return
        }

        performStopFocus(reason: .quit)
        NSApp.terminate(nil)
    }

    private func performStopFocus(reason: StopReason = .user) {
        graceTimer?.invalidate()
        dismissIntervention()
        urlMonitor.stop()

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
        lastNonSelfApp = app

        // Update URL monitoring to follow the frontmost app
        startURLMonitoringIfNeeded(for: app)

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
        case .intervention:
            interventionEngine.bringToFront()
        }
    }

    func allowTemporaryEscape(duration: TimeInterval? = nil, reason: String? = nil) {
        guard confirmGoalIfNeeded(action: .takeBreak) else {
            interventionEngine.bringToFront()
            return
        }

        performTemporaryEscape(duration: duration, reason: reason)
    }

    private func performTemporaryEscape(duration: TimeInterval? = nil, reason: String? = nil) {
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
        if rules.allowedBundleIDs.contains(app.bundleIdentifier) ||
            (session.allowedBundleIDsMulti?.contains(app.bundleIdentifier) ?? false) ||
            multiAppAllowedBundleIDs.contains(app.bundleIdentifier) {
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

    private func confirmGoalIfNeeded(action: CommitmentAction) -> Bool {
        guard let session = state.activeSession else {
            return true
        }

        return commitmentPromptEngine.confirm(action: action, session: session)
    }

    private var focusRules: FocusRules {
        var rules = FocusRules(
            allowSystemApps: true,
            allowFinder: false,
            gracePeriodSeconds: settings.gracePeriodSeconds,
            requireReason: settings.requireReasonToLeave
        )
        // Merge multi-app whitelist when a session is active (keeps identical warning style)
        if !multiAppAllowedBundleIDs.isEmpty {
            rules = mergeAllowedBundleIDs(rules, extra: Set(multiAppAllowedBundleIDs))
        }
        return rules
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

    // Helper to merge additional allowed bundle IDs into FocusRules.allowedBundleIDs behavior
    private func mergeAllowedBundleIDs(_ rules: FocusRules, extra: Set<String>) -> FocusRules {
        var merged = rules
        // We cannot modify allowedBundleIDs directly (it's computed), but we honor it by checking both in handlePotentialViolation.
        // Here we just return the same rules; handlePotentialViolation will reference extra via multiAppAllowedBundleIDs.
        return merged
    }

    private func startURLMonitoringIfNeeded(for app: RunningApp) {
        // Only monitor URLs while actively focusing
        guard case .focusing(let session) = state else {
            urlMonitor.stop()
            return
        }

        // Monitor only when the frontmost app is itself allowed by the current session
        let isAllowedApp = (app.bundleIdentifier == session.allowedBundleID)
            || (session.allowedBundleIDsMulti?.contains(app.bundleIdentifier) ?? false)

        if isAllowedApp {
            urlMonitor.start(for: app)
        } else {
            urlMonitor.stop()
        }
    }

    private func handleURLChange(_ change: BrowserURLMonitor.URLChange) {
        guard case .focusing(let session) = state else { return }
        // Evaluate the domain and block if needed
        guard let host = change.url.host?.lowercased() else { return }
        if isBlockedDomain(host) {
            handlePotentialURLViolation(domain: host, app: change.app, session: session)
        }
    }

    private func isBlockedDomain(_ host: String) -> Bool {
        // Match exact host or parent domain
        if blockedDomains.contains(host) { return true }
        // Check parent domains (e.g., subdomain.youtube.com)
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return false }
        let parent = parts.suffix(2).joined(separator: ".")
        return blockedDomains.contains(parent)
    }

    private func handlePotentialURLViolation(domain: String, app: RunningApp, session: FocusSession) {
        // Reuse the same intervention flow as app violations
        var updatedSession = session
        let violation = FocusViolation(app: app)
        updatedSession.violations.append(violation)
        state = .intervention(updatedSession, violation: violation)

        statusMessage = "Blocked distracting site: \(domain)"

        interventionEngine.present(
            session: updatedSession,
            violation: violation,
            settings: settings,
            onReturn: { [weak self] in self?.returnToAllowedApp() },
            onEscape: { [weak self] reason in self?.allowTemporaryEscape(reason: reason) },
            onEnd: { [weak self] in self?.stopFocus() }
        )
    }
    
    private func saveBlockedDomains() {
        UserDefaults.standard.set(blockedDomainsEditable, forKey: blockedDomainsKey)
    }
}
