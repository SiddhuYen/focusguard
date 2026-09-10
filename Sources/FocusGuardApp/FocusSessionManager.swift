import AppKit
import ApplicationServices
import Combine
import Foundation

/// The AppKit side of the state machine: it turns notifications, timers and clicks into
/// events, hands them to the pure reducer, and runs the effects that come back. No
/// decision about what is allowed lives here.
@MainActor
final class FocusSessionManager: ObservableObject {
    /// The app delegate, the shield and the SwiftUI scenes need the same instance, and it
    /// must exist before any window does so the restart escape can be read at launch.
    static let shared = FocusSessionManager()

    @Published private(set) var state: AppState
    @Published private(set) var sessionHistory: [SessionSummary] = []
    @Published private(set) var currentAppName = "Unknown"
    /// Ticks once a second while a session is running, so countdowns move.
    @Published private(set) var now = Date()
    @Published private(set) var pickerApps: [RunningApp] = []
    @Published private(set) var multiAppAllowedBundleIDs: [String] = []
    @Published var allowAllNonBlockedSites = false

    /// The Settings window edits this copy; every edit is routed through the reducer so
    /// loosening changes can be delayed (3.8).
    @Published var settingsDraft: Settings {
        didSet {
            guard !isSyncingSettings, settingsDraft != state.settings else { return }
            dispatch(.settingsEdited(settingsDraft))
        }
    }

    private let paths = FocusGuardPaths()
    private let log: EventLogStore
    private let store: StateStore
    private let launchGuard: LaunchGuard
    private let watchdog: MainThreadWatchdog
    private let permissionMonitor = PermissionMonitor()
    private let gateTriggers = GateTriggerMonitor()
    private let appResolver = AppIdentityResolver()
    private let appMonitor = ActiveAppMonitor()
    private let urlMonitor = BrowserURLMonitor()
    private let interventionEngine = InterventionEngine()
    private let commitmentPromptEngine = CommitmentPromptEngine()

    private var tickTimer: Timer?
    private var displayTimer: Timer?
    /// Swapped for a controllable clock by the debug self-check.
    var reducerContext: ReducerContext = .live
    /// Debug self-check hook: sees every effect the reducer produced.
    var effectObserver: ((Effect) -> Void)?
    /// Debug self-check: skip effects that would disturb the machine (hiding apps,
    /// stealing focus, sleeping).
    var suppressDisruptiveEffects = false
    private var isSyncingSettings = false
    private var hasStarted = false
    private var isTerminating = false
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
        initial.recentGoals = store.loadRecentGoals()
        initial.pendingChanges = store.loadPendingChanges()
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
    }

    /// Test seam: drive the state machine directly from the debug self-check.
    func send(_ event: AppEvent) { dispatch(event) }

    /// Called once, from applicationWillFinishLaunching. Kept out of `init` so that
    /// nothing an effect touches can re-enter the singleton while it is being created.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // The watchdog goes first: from here on a wedged main thread is recoverable.
        watchdog.start()
        launchGuard.startHeartbeat()

        reloadHistory()
        refreshPickerApps()

        dispatch(.launched(
            restoredSession: store.loadActiveSession(),
            safeMode: launchGuard.safeMode
        ))

        permissionMonitor.start()
        appMonitor.start()
        gateTriggers.start()
        startTickTimer()
        startDisplayTimer()
        observeSystemEvents()
        if !suppressDisruptiveEffects { SystemControl.syncLoginItem(enabled: true) }
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

        gateTriggers.settingsProvider = { [weak self] in self?.state.settings ?? Settings() }
        gateTriggers.onTrigger = { [weak self] trigger in
            self?.dispatch(.gateTriggered(trigger))
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

    private func startTickTimer() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.dispatch(.tick(idleSeconds: GateTriggerMonitor.idleSeconds()))
            }
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

    // MARK: - The event loop

    private func dispatch(_ event: AppEvent) {
        let (next, effects) = FocusReducer.reduce(state, event, context: reducerContext)
        let wasEnded = state.activeSession?.id != next.activeSession?.id
        state = next
        syncSettingsDraft()
        for effect in effects {
            effectObserver?(effect)
            perform(effect)
        }
        if wasEnded { reloadHistory() }
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

        case .persistPresets(let presets):
            store.savePresets(presets)

        case .persistRecentGoals(let recents):
            store.saveRecentGoals(recents)

        case .showShield(let context):
            guard !isTerminating else { return }
            MainWindowController.shared.hide()
            refreshPickerApps()
            ShieldWindowController.shared.show(context: context)

        case .hideShield:
            ShieldWindowController.shared.hide()

        case .setKiosk(let enabled):
            ShieldWindowController.shared.setKiosk(enabled)

        case .showReview(let session, let reason):
            ReviewPanelController.shared.show(session: session, reason: reason)

        case .dismissReview:
            ReviewPanelController.shared.dismiss()

        case .showIntervention(let session, let violation):
            interventionEngine.present(
                session: session,
                violation: violation,
                permissions: state.permissions,
                onReturn: { [weak self] in self?.dispatch(.returnRequested) },
                onAdd: { [weak self] reason in self?.addViolationTargetToSession(reason: reason) },
                onEnd: { [weak self] in self?.dispatch(.endRequested) },
                onFixPermissions: { [weak self] in self?.openPermissionSettings() },
                onOverride: { [weak self] in self?.presentOverrideFromIntervention() }
            )

        case .bringInterventionToFront:
            interventionEngine.bringToFront()

        case .dismissIntervention:
            interventionEngine.dismiss()

        case .activateApp(let bundleID):
            guard !suppressDisruptiveEffects else { return }
            guard let app = appResolver.runningApplication(bundleID: bundleID) else { return }
            app.unhide()
            app.activate(options: [.activateAllWindows])

        case .hideApps(let allowed):
            guard !suppressDisruptiveEffects else { return }
            hideApps(except: allowed)

        case .monitorURLs(let app):
            guard let app,
                  let running = appResolver.runningApplication(bundleID: app.bundleID)
                      .flatMap(RunningApp.init(runningApplication:)) else {
                urlMonitor.stop()
                return
            }
            urlMonitor.start(for: running)

        case .sleepMac:
            guard !suppressDisruptiveEffects else { return }
            SystemControl.sleepNow()
        }
    }

    /// Hides, never quits: your unsaved work is your business (Section 5).
    private func hideApps(except allowed: [String]) {
        let keep = Set(allowed).union(state.settings.baseline.all)
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden {
            guard let bundleID = app.bundleIdentifier, !keep.contains(bundleID) else { continue }
            app.hide()
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
    var presets: [Preset] { state.presets }
    var canStartFocus: Bool { state.canStartSession }
    var isGated: Bool { state.isGated }
    var overrideState: OverrideState? { state.overrideActive }
    var isSafeMode: Bool { if case .safeMode = state.phase { return true } else { return false } }

    var gateContext: GateContext? {
        if case .gate(let context) = state.phase { return context }
        return nil
    }

    /// One line describing where the app is, for Settings and the menu.
    var stateSummary: String {
        if let override = state.overrideActive {
            return "Override until \(override.until.formatted(date: .omitted, time: .shortened))"
        }
        switch state.phase {
        case .gate: return "At the gate"
        case .session(let session):
            let kind = session.kind == .open ? "Open session" : "Session"
            return "\(kind): \(session.goal)"
        case .intervention: return "Intervention"
        case .review: return "Review"
        case .overridden: return "Override"
        case .safeMode: return "Safe mode"
        }
    }

    var menuBarStatusText: String {
        if let override = state.overrideActive {
            return "override \(max(0, override.until.timeIntervalSince(now)).formattedDuration)"
        }
        guard let session = state.activeSession else { return "" }
        if let remaining = session.remaining() {
            return max(0, remaining).formattedDuration
        }
        return session.elapsed.formattedDuration
    }

    var menuBarSystemImage: String {
        if state.overrideActive != nil { return "lock.open.trianglebadge.exclamationmark.fill" }
        if !state.permissions.isHealthy { return "exclamationmark.octagon.fill" }
        switch state.phase {
        case .gate: return "circle"
        case .session(let session): return session.kind == .open ? "timer" : "target"
        case .intervention: return "exclamationmark.triangle"
        case .review: return "questionmark.circle"
        case .overridden: return "lock.open"
        case .safeMode: return "exclamationmark.shield.fill"
        }
    }

    var selectionIncludesBrowser: Bool {
        multiAppAllowedBundleIDs.contains { KnownBrowser.isBrowser(bundleID: $0) }
    }

    /// The baseline, named where the app is running so it is readable in Settings.
    var baselineDisplayNames: [(bundleID: String, name: String)] {
        state.settings.baseline.all.sorted().map { bundleID in
            (bundleID, appResolver.displayName(for: bundleID) ?? friendlyName(for: bundleID))
        }
    }

    private func friendlyName(for bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    func suggestions(for query: String) -> [Suggestion] {
        GateSuggestions.suggestions(query: query, presets: state.presets, recents: state.recentGoals)
    }

    func displayName(for bundleID: String) -> String {
        appResolver.displayName(for: bundleID) ?? bundleID
    }

    // MARK: - Gate commands

    func startFullSession(
        goal: String,
        duration: TimeInterval,
        presetID: UUID? = nil,
        sites: [SiteRule] = []
    ) {
        guard let goal = goal.nilIfBlank else { return }
        let anchor = anchorApp()
        var allowed = multiAppAllowedBundleIDs
        if allowed.isEmpty { allowed = [anchor.bundleID] }

        dispatch(.sessionStartRequested(SessionRequest(
            kind: .full,
            goal: goal,
            anchor: anchor,
            allowedBundleIDs: allowed,
            allowedSites: sites,
            allowAllNonBlockedSites: allowAllNonBlockedSites || sites.isEmpty,
            duration: duration,
            presetID: presetID
        )))
        resetSelection()
    }

    func startOpenSession(goal: String) {
        guard let goal = goal.nilIfBlank else { return }
        dispatch(.sessionStartRequested(SessionRequest(
            kind: .open,
            goal: goal,
            anchor: anchorApp(),
            allowedBundleIDs: [],
            duration: nil
        )))
        resetSelection()
    }

    func applySuggestion(_ suggestion: Suggestion) {
        multiAppAllowedBundleIDs = suggestion.allowedBundleIDs
    }

    /// Re-raise the shield, for the "go to the gate" button and the menu bar item.
    func showGate() {
        guard let context = gateContext else { return }
        ShieldWindowController.shared.show(context: context)
    }

    func answerGate(finished: Bool) {
        dispatch(.gateAnswered(finished: finished))
    }

    func requestSleep() {
        dispatch(.sleepRequested)
    }

    /// The override is reachable from the intervention panel as well as the gate (3.7).
    func presentOverrideFromIntervention() {
        OverridePanelController.shared.show { [weak self] reason in
            self?.startOverride(reason: reason)
        }
    }

    func startOverride(reason: String) {
        dispatch(.overrideStarted(reason: reason))
    }

    func endOverride() {
        dispatch(.overrideEnded(early: true))
    }

    // MARK: - Session commands

    func answerReview(finished: Bool) {
        dispatch(.reviewAnswered(finished: finished))
    }

    func extendReview(by amount: TimeInterval) {
        dispatch(.reviewExtended(by: amount))
    }

    func extendOpenSession() {
        dispatch(.openSessionExtended)
        ReviewPanelController.shared.dismiss()
    }

    func convertOpenSession(duration: TimeInterval) {
        guard let session = state.activeSession else { return }
        // Include the app currently in front: the reducer credits it on the way out, but
        // the allowlist is built here, before that happens.
        var appsUsed = session.appsUsed
        if let current = state.frontmostApp, let since = state.frontmostSince {
            let now = reducerContext.now()
            let dwell = min(now.timeIntervalSince(since), now.timeIntervalSince(session.startedAt))
            if dwell >= FocusGuardConfig.current.appsUsedThreshold,
               !appsUsed.contains(where: { $0.bundleID == current.bundleID }) {
                appsUsed.append(AppUsage(bundleID: current.bundleID, name: current.name, seconds: dwell))
            }
        }
        var allowed = appsUsed
            .filter { $0.seconds >= FocusGuardConfig.current.appsUsedThreshold }
            .sorted { $0.seconds > $1.seconds }
            .map(\.bundleID)
        if allowed.isEmpty { allowed = [anchorApp().bundleID] }

        dispatch(.convertToFullRequested(SessionRequest(
            kind: .full,
            goal: session.goal,
            anchor: appsUsed.max(by: { $0.seconds < $1.seconds })
                .map { AppIdentity(bundleID: $0.bundleID, name: $0.name) } ?? anchorApp(),
            allowedBundleIDs: allowed,
            allowedSites: session.domainsVisited.map { SiteRule.domain($0) },
            allowAllNonBlockedSites: session.domainsVisited.isEmpty,
            duration: duration
        )))
    }

    func stopFocus() {
        dispatch(.endRequested)
    }

    func savePreset(named name: String, from session: Session) {
        guard let name = name.nilIfBlank else { return }
        let preset = Preset(
            name: name,
            keywords: Array(GateSuggestions.tokens(session.goal)),
            allowedBundleIDs: session.allowedBundleIDs,
            allowedSites: session.allowedSites,
            defaultDuration: session.plannedEnd?.timeIntervalSince(session.startedAt)
                ?? FocusGuardConfig.current.fullSessionQuickPicks[1]
        )
        dispatch(.presetCreated(preset, source: "review"))
    }

    /// "Add current app" from the menu, and the intervention panel's add button.
    func addCurrentAppToAllowed() {
        guard let app = appResolver.frontmostApp() ?? lastKnownApp else { return }
        guard state.activeSession != nil else {
            toggleAllowed(bundleID: app.bundleIdentifier)
            return
        }
        guard let reason = commitmentPromptEngine.promptForReason(
            title: "Add \(app.name) to this session?",
            message: "It stays allowed until this session ends, and the reason goes in your review."
        ) else { return }
        dispatch(.addToSessionRequested(target: .app(app.identity), reason: reason))
    }

    private func addViolationTargetToSession(reason: String) {
        guard case .intervention(_, let violation) = state.phase else { return }
        let target: AdditionTarget
        switch violation.kind {
        case .app(let app):
            target = .app(app)
        case .unlistedSite(let host, _), .unpinnedPage(let host, _):
            target = .site(.domain(host))
        case .unverifiableURL:
            target = .app(violation.app)
        case .blockedSite:
            return
        }
        dispatch(.addToSessionRequested(target: target, reason: reason))
    }

    /// Called from applicationShouldTerminate: true means the quit may proceed.
    func confirmQuit() -> Bool {
        guard let session = state.activeSession else { return true }
        guard commitmentPromptEngine.confirm(action: .quit, goal: session.goal) else { return false }
        isTerminating = true
        dispatch(.forceEnd(outcome: .abandoned))
        return true
    }

    func quit() {
        guard confirmQuit() else { return }
        NSApp.terminate(nil)
    }

    func prepareForTermination(reason: String) {
        isTerminating = true
        displayTimer?.invalidate()
        tickTimer?.invalidate()
        watchdog.stop()
        urlMonitor.stop()
        appMonitor.stop()
        gateTriggers.stop()
        permissionMonitor.stop()
        ShieldWindowController.shared.setKiosk(false)
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
            PermissionMonitor.promptForAccessibility()
        } else {
            PermissionMonitor.openAutomationSettings()
        }
    }

    // MARK: - App selection

    func toggleAllowed(bundleID: String) {
        if multiAppAllowedBundleIDs.contains(bundleID) {
            multiAppAllowedBundleIDs.removeAll { $0 == bundleID }
        } else {
            guard Allowlist.canAllowlist(bundleID: bundleID) else {
                state.statusMessage = "Focus Guard can't read \(displayName(for: bundleID))'s tabs, so it can't police them."
                return
            }
            multiAppAllowedBundleIDs.append(bundleID)
        }
    }

    func refreshPickerApps() {
        let current = appResolver.frontmostApp()
        var apps = appResolver.runningApps().filter { $0.bundleIdentifier != BuildInfo.bundleID }
        if let current, !apps.contains(where: { $0.bundleIdentifier == current.bundleIdentifier }) {
            apps.insert(current, at: 0)
        }
        pickerApps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if multiAppAllowedBundleIDs.isEmpty, let current, Allowlist.canAllowlist(bundleID: current.bundleIdentifier) {
            multiAppAllowedBundleIDs = [current.bundleIdentifier]
        }
    }

    private func resetSelection() {
        multiAppAllowedBundleIDs = []
        allowAllNonBlockedSites = false
    }

    private func anchorApp() -> AppIdentity {
        if let first = multiAppAllowedBundleIDs.first {
            return AppIdentity(bundleID: first, name: displayName(for: first))
        }
        if let app = appResolver.frontmostApp() ?? lastKnownApp {
            return app.identity
        }
        return AppIdentity(bundleID: BuildInfo.bundleID, name: "Focus Guard")
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
