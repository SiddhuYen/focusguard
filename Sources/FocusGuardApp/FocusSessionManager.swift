import AppKit
import ApplicationServices
import Combine
import Foundation

/// The AppKit side of the state machine: it turns notifications, timers and clicks into
/// events, hands them to the pure reducer, and runs the effects that come back. No
/// decision about what is allowed lives here.
@MainActor
final class FocusSessionManager: ObservableObject {
    /// The app delegate and the SwiftUI scene need the same instance, and it must exist
    /// before any window does so the restart escape can be read at launch (3.9.3).
    static let shared = FocusSessionManager()

    @Published private(set) var state: AppState
    @Published private(set) var sessionHistory: [SessionSummary] = []
    @Published private(set) var currentAppName = "Unknown"
    /// Ticks once a second while a session is running, so countdowns move.
    @Published private(set) var now = Date()
    @Published private(set) var pickerApps: [RunningApp] = []

    /// The Settings window edits this copy; every edit is routed through the reducer so
    /// loosening changes can be delayed (3.8).
    @Published var settingsDraft: Settings {
        didSet {
            guard !isSyncingSettings, settingsDraft != state.settings else { return }
            dispatch(.settingsEdited(settingsDraft))
        }
    }

    // Multi-app picker state. This is UI selection only: it never reaches enforcement,
    // which is what leaked allowlists between sessions in v1.
    @Published var multiAppSearchText = "" {
        didSet { updateMultiAppSearchResults() }
    }
    @Published private(set) var multiAppSearchResults: [AppDisplayItem] = []
    @Published private(set) var multiAppAllowedBundleIDs: [String] = []

    struct AppDisplayItem: Identifiable, Equatable {
        var id: String { bundleIdentifier }
        let bundleIdentifier: String
        let displayName: String
    }

    private let paths = FocusGuardPaths()
    private let log: EventLogStore
    private let store: StateStore
    private let launchGuard: LaunchGuard
    private let watchdog: MainThreadWatchdog
    private let permissionMonitor = PermissionMonitor()
    private let appResolver = AppIdentityResolver()
    private let appMonitor = ActiveAppMonitor()
    private let urlMonitor = BrowserURLMonitor()
    private let interventionEngine = InterventionEngine()
    private let selectorEngine = MultiAppSelectorEngine()
    private let commitmentPromptEngine = CommitmentPromptEngine()

    private var escapeTimer: Timer?
    private var tickTimer: Timer?
    private var displayTimer: Timer?
    private var isSyncingSettings = false
    private var lastKnownApp: RunningApp?

    init() {
        let paths = FocusGuardPaths()
        try? paths.createDirectories()
        let log = EventLogStore(paths: paths)
        let store = StateStore(paths: paths)
        self.log = log
        self.store = store

        // Order matters: the safe-mode decision has to happen before any window exists.
        launchGuard = LaunchGuard(store: store, log: log)

        let hangPaths = paths
        watchdog = MainThreadWatchdog { unresponsive in
            // Runs on the watchdog thread with the main thread wedged: touch nothing but
            // this one file, then leave without writing a clean-exit marker.
            let marker = HangMarker(detectedAt: Date(), unresponsiveSeconds: unresponsive)
            try? AtomicFile.writeJSON(marker, to: hangPaths.hangMarker)
        }

        LegacyMigrationRunner.runIfNeeded(store: store, log: log)

        var initial = AppState()
        initial.settings = store.loadSettings() ?? Settings()
        initial.settings.baseline.selfBundleID = BuildInfo.bundleID
        initial.presets = store.loadPresets()
        initial.pendingChanges = store.loadPendingChanges()
        // Seed the observed permission state so a permission that was already missing at
        // launch is recorded by appLaunched, not as a fresh "lost" event every time.
        initial.permissions.accessibilityTrusted = AXIsProcessTrusted()
        state = initial
        settingsDraft = initial.settings

        if let app = appResolver.frontmostApp() {
            currentAppName = app.name
            lastKnownApp = app
            state.frontmostApp = app.identity
            state.frontmostSince = .nowLoggable
        }

        configureMonitors()

        dispatch(.launched(
            restoredSession: store.loadActiveSession(),
            safeMode: launchGuard.safeMode
        ))

        watchdog.start()
        launchGuard.startHeartbeat()
        permissionMonitor.start()
        appMonitor.start()
        startTickTimer()
        startDisplayTimer()
        observeSystemEvents()
        reloadHistory()
        refreshPickerApps()
    }

    // MARK: - Wiring

    private func configureMonitors() {
        appMonitor.onActiveAppChanged = { [weak self] app in
            guard let self else { return }
            currentAppName = app.name
            lastKnownApp = app
            dispatch(.appActivated(app.identity))
            if state.canStartSession { refreshPickerApps() }
        }

        urlMonitor.onURLChange = { [weak self] change in
            self?.dispatch(.urlObserved(browser: change.app.identity, url: change.url))
        }

        urlMonitor.onReadFailure = { [weak self] app, failures in
            self?.dispatch(.urlReadFailed(browser: app.identity, consecutiveFailures: failures))
        }

        urlMonitor.onAutomationError = { [weak self] code, browser in
            self?.permissionMonitor.noteAutomationError(code: code, browser: browser)
        }

        urlMonitor.onAutomationSuccess = { [weak self] in
            self?.permissionMonitor.noteAutomationSuccess()
        }

        permissionMonitor.onChange = { [weak self] health in
            self?.dispatch(.permissionsChanged(health))
        }
    }

    private func observeSystemEvents() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.launchGuard.noteSystemEvent("sleep") }
        }
        center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.launchGuard.noteSystemEvent("shutdown") }
        }
    }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.state.activeSession != nil { self.now = Date() }
            }
        }
    }

    private func startTickTimer() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.dispatch(.tick) }
        }
    }

    // MARK: - The event loop

    private func dispatch(_ event: AppEvent) {
        let (next, effects) = FocusReducer.reduce(state, event)
        state = next
        syncSettingsDraft()
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case .log(let event):
            log.append(event)

        case .persistSession(let session):
            store.saveActiveSession(session)

        case .persistSettings(let settings):
            store.saveSettings(settings)

        case .persistPendingChanges(let changes):
            store.savePendingChanges(changes)

        case .showIntervention(let session, let violation):
            interventionEngine.present(
                session: session,
                violation: violation,
                settings: state.settings,
                permissions: state.permissions,
                onReturn: { [weak self] in self?.returnToAllowedApp() },
                onEscape: { [weak self] reason in self?.allowTemporaryEscape(reason: reason) },
                onEnd: { [weak self] in self?.stopFocus() }
            )

        case .bringInterventionToFront:
            interventionEngine.bringToFront()

        case .dismissIntervention:
            interventionEngine.dismiss()

        case .activateApp(let bundleID):
            guard let app = appResolver.runningApplication(bundleID: bundleID) else {
                state.statusMessage = "\(bundleID) does not appear to be running."
                return
            }
            app.unhide()
            app.activate(options: [.activateAllWindows])

        case .monitorURLs(let app):
            guard let app,
                  let running = appResolver.runningApplication(bundleID: app.bundleID)
                      .flatMap(RunningApp.init(runningApplication:)) else {
                urlMonitor.stop()
                return
            }
            urlMonitor.start(for: running)

        case .scheduleEscapeEnd(let date):
            escapeTimer?.invalidate()
            escapeTimer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.dispatch(.escapeExpired) }
            }
            RunLoop.main.add(escapeTimer!, forMode: .common)

        case .cancelEscapeTimer:
            escapeTimer?.invalidate()
            escapeTimer = nil
        }
    }

    private func syncSettingsDraft() {
        guard settingsDraft != state.settings else { return }
        isSyncingSettings = true
        settingsDraft = state.settings
        isSyncingSettings = false
    }

    private func reloadHistory() {
        let events = log.allEvents()
        let names = Dictionary(
            appResolver.runningApps().map { ($0.bundleIdentifier, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        sessionHistory = SessionHistoryProjection.applyNames(names, to: SessionHistoryProjection.sessions(from: events))
    }

    // MARK: - Derived view state

    var activeSession: Session? { state.activeSession }
    var statusMessage: String? { state.statusMessage }
    var permissions: PermissionHealth { state.permissions }
    var pendingChanges: [PendingChange] { state.pendingChanges }
    var canStartFocus: Bool { state.canStartSession }
    var isSafeMode: Bool { if case .safeMode = state.phase { return true } else { return false } }

    var menuBarTitle: String {
        switch state.phase {
        case .idle: return "Focus Guard: Idle"
        case .session(let session): return title(prefix: "Focusing", session: session)
        case .gracePeriod(let session, _): return title(prefix: "Escape", session: session)
        case .intervention(let session, _): return title(prefix: "Left", session: session)
        case .safeMode: return "Focus Guard: Safe mode"
        }
    }

    /// Short enough for the menu bar: time left, or elapsed when a session has no end.
    var menuBarStatusText: String {
        guard let session = state.activeSession else { return "" }
        if let remaining = session.remaining() {
            return max(0, remaining).formattedDuration
        }
        return session.elapsed.formattedDuration
    }

    var menuBarSystemImage: String {
        if !state.permissions.isHealthy { return "exclamationmark.octagon.fill" }
        switch state.phase {
        case .idle: return "circle"
        case .session: return "target"
        case .gracePeriod: return "timer"
        case .intervention: return "exclamationmark.triangle"
        case .safeMode: return "exclamationmark.shield.fill"
        }
    }

    private func title(prefix: String, session: Session) -> String {
        session.allowedBundleIDs.count > 1
            ? "\(prefix): \(session.allowedBundleIDs.count) apps"
            : "\(prefix): \(session.anchor.name)"
    }

    // MARK: - Commands from the UI

    func startFocusOnCurrentApp() {
        guard let app = appResolver.frontmostApp() ?? lastKnownApp else {
            state.statusMessage = "Could not read the current app."
            return
        }
        guard let goal = commitmentPromptEngine.promptForGoal(appName: app.name) else {
            state.statusMessage = "Focus start canceled."
            return
        }
        start(request: SessionRequest(
            kind: .full,
            goal: goal,
            anchor: app.identity,
            allowedBundleIDs: [app.bundleIdentifier]
        ))
    }

    /// Starts a session from the window: the goal is typed there, so no modal prompt.
    func startSession(goal: String, kind: SessionKind = .full, duration: TimeInterval? = nil) {
        guard canStartFocus else { return }
        let anchor = appResolver.frontmostApp() ?? lastKnownApp
        var allowed = multiAppAllowedBundleIDs
        if allowed.isEmpty, let anchor { allowed = [anchor.bundleIdentifier] }

        let anchorIdentity = anchor?.identity
            ?? allowed.first.map { AppIdentity(bundleID: $0, name: displayName(for: $0)) }
            ?? AppIdentity(bundleID: BuildInfo.bundleID, name: "Focus Guard")

        dispatch(.sessionStartRequested(SessionRequest(
            kind: kind,
            goal: goal,
            anchor: anchorIdentity,
            allowedBundleIDs: allowed,
            duration: duration
        )))
        resetMultiAppSelection()

        // Get out of the way and put you back in the app you are working in.
        MainWindowController.shared.hide()
        if let target = allowed.first ?? anchor?.bundleIdentifier {
            perform(.activateApp(bundleID: target))
        }
    }

    func toggleAllowed(bundleID: String) {
        if multiAppAllowedBundleIDs.contains(bundleID) {
            multiAppAllowedBundleIDs.removeAll { $0 == bundleID }
        } else {
            addAllowedBundleID(bundleID)
        }
    }

    func displayName(for bundleID: String) -> String {
        appResolver.displayName(for: bundleID) ?? bundleID
    }

    func refreshPickerApps() {
        let current = appResolver.frontmostApp()
        var apps = appResolver.runningApps().filter { $0.bundleIdentifier != BuildInfo.bundleID }
        if let current, !apps.contains(where: { $0.bundleIdentifier == current.bundleIdentifier }) {
            apps.insert(current, at: 0)
        }
        pickerApps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Preselect whatever you were just using.
        if multiAppAllowedBundleIDs.isEmpty, let current {
            addAllowedBundleID(current.bundleIdentifier)
        }
    }

    func presentMultiAppSelector() {
        guard canStartFocus else { return }
        selectorEngine.present(sessionManager: self)
    }

    func startMultiAppFocusAndDismiss() {
        startMultiAppFocus()
        selectorEngine.dismiss()
    }

    func startMultiAppFocus() {
        guard canStartFocus else { return }
        if multiAppAllowedBundleIDs.isEmpty, let app = appResolver.frontmostApp() ?? lastKnownApp {
            addAllowedBundleID(app.bundleIdentifier)
        }
        guard let anchor = appResolver.frontmostApp() ?? lastKnownApp else {
            state.statusMessage = "Could not read the current app."
            return
        }
        guard let goal = commitmentPromptEngine.promptForGoal(appName: anchor.name) else {
            state.statusMessage = "Focus start canceled."
            return
        }
        start(request: SessionRequest(
            kind: .full,
            goal: goal,
            anchor: anchor.identity,
            allowedBundleIDs: multiAppAllowedBundleIDs
        ))
        resetMultiAppSelection()
    }

    private func start(request: SessionRequest) {
        dispatch(.sessionStartRequested(request))
        if let app = appResolver.frontmostApp() {
            dispatch(.appActivated(app.identity))
        }
    }

    /// "Allow current app" during a session: a scoped addition with a reason, logged and
    /// gone when the session ends.
    func addCurrentAppToAllowed() {
        guard let app = appResolver.frontmostApp() ?? lastKnownApp else { return }

        if state.canStartSession {
            addAllowedBundleID(app.bundleIdentifier)
            return
        }

        guard let reason = commitmentPromptEngine.promptForReason(
            title: "Add \(app.name) to this session?",
            message: "It stays allowed until this session ends, and the reason goes in your review."
        ) else { return }

        dispatch(.addToSessionRequested(target: .app(app.identity), reason: reason))
    }

    func returnToAllowedApp() {
        dispatch(.returnRequested)
    }

    func allowTemporaryEscape(reason: String? = nil) {
        guard confirmGoalIfNeeded(action: .takeBreak) else {
            interventionEngine.bringToFront()
            return
        }
        dispatch(.escapeRequested(duration: state.settings.defaultEscapeDuration, reason: reason))
    }

    func stopFocus(reason: StopReason = .user) {
        guard confirmGoalIfNeeded(action: reason == .quit ? .quit : .endFocus) else { return }
        dispatch(.endRequested(outcome: .notFinished))
        reloadHistory()
    }

    /// Called from applicationShouldTerminate: true means the quit may proceed.
    func confirmQuit() -> Bool {
        guard state.activeSession != nil else { return true }
        guard confirmGoalIfNeeded(action: .quit) else { return false }
        dispatch(.endRequested(outcome: .abandoned))
        return true
    }

    func quit() {
        guard confirmQuit() else { return }
        NSApp.terminate(nil)
    }

    func prepareForTermination(reason: String) {
        displayTimer?.invalidate()
        watchdog.stop()
        urlMonitor.stop()
        appMonitor.stop()
        permissionMonitor.stop()
        tickTimer?.invalidate()
        escapeTimer?.invalidate()
        launchGuard.markCleanExit(reason: reason)
    }

    func clearStatusMessage() {
        dispatch(.statusMessageCleared)
    }

    func cancelPendingChange(_ id: UUID) {
        dispatch(.pendingChangeCancelled(id))
    }

    func openPermissionSettings() {
        if !state.permissions.accessibilityTrusted {
            PermissionMonitor.openAccessibilitySettings()
        } else {
            PermissionMonitor.openAutomationSettings()
        }
    }

    private func confirmGoalIfNeeded(action: CommitmentAction) -> Bool {
        guard let session = state.activeSession else { return true }
        return commitmentPromptEngine.confirm(action: action, goal: session.goal)
    }

    // MARK: - Multi-app picker

    var multiAppAllowedDisplayItems: [AppDisplayItem] {
        multiAppAllowedBundleIDs
            .map { AppDisplayItem(bundleIdentifier: $0, displayName: appResolver.displayName(for: $0) ?? $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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

    private func addAllowedBundleID(_ bundleID: String) {
        guard Allowlist.canAllowlist(bundleID: bundleID) else {
            state.statusMessage = "Focus Guard can't read \(appResolver.displayName(for: bundleID) ?? bundleID)'s tabs, so it can't police them."
            return
        }
        guard !multiAppAllowedBundleIDs.contains(bundleID) else { return }
        multiAppAllowedBundleIDs.append(bundleID)
    }

    private func updateMultiAppSearchResults() {
        let query = multiAppSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            multiAppSearchResults = []
            return
        }

        let running = appResolver.runningApps().map {
            AppDisplayItem(bundleIdentifier: $0.bundleIdentifier, displayName: $0.name)
        }
        let historical = sessionHistory.flatMap(\.allowedBundleIDs).map {
            AppDisplayItem(bundleIdentifier: $0, displayName: appResolver.displayName(for: $0) ?? $0)
        }

        var seen = Set<String>()
        multiAppSearchResults = (running + historical + multiAppAllowedDisplayItems)
            .filter { seen.insert($0.bundleIdentifier).inserted }
            .filter {
                $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.bundleIdentifier.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Settings helpers

    var blockedDomainsEditable: [String] {
        get { settingsDraft.blocklist.domains }
        set {
            var settings = settingsDraft
            settings.blocklist = Blocklist(domains: newValue)
            settingsDraft = settings
        }
    }
}
