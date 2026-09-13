#if DEBUG
import AppKit
import Foundation

/// Drives the real app through the Phase 1 flows and checks what actually happened:
/// real windows, real event log, real persistence, with a controllable clock. It is not a
/// substitute for looking at the UI, but it covers everything below the pixels.
///
/// Run with:  FOCUSGUARD_SELFCHECK=1 FOCUSGUARD_DATA_DIR=/tmp/fg-check <binary>
@MainActor
enum SelfCheck {
    private static var results: [(name: String, passed: Bool, detail: String)] = []
    private static var effects: [Effect] = []
    /// nonisolated because the reducer context reads it from a Sendable closure.
    nonisolated(unsafe) private static let clock = TestClock()

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval = 0

        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return Date().addingTimeInterval(offset).loggable
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); offset += seconds; lock.unlock()
        }
    }

    static func run() {
        let manager = FocusSessionManager.shared
        manager.suppressDisruptiveEffects = true
        manager.schedulesWallClockTimers = false
        manager.reducerContext = ReducerContext(now: { clock.now }, newID: { UUID() })
        manager.effectObserver = { effects.append($0) }

        let xcode = AppIdentity(bundleID: "com.apple.dt.Xcode", name: "Xcode")
        let stray = AppIdentity(bundleID: "com.example.stray", name: "Stray")
        let finder = AppIdentity(bundleID: "com.apple.finder", name: "Finder")
        let safari = AppIdentity(bundleID: KnownBrowser.safari.rawValue, name: "Safari")

        // 1. Launch puts up the gate, one shield per display.
        check("gate on launch", manager.isGated)
        check("shield window per display", shieldCount() == NSScreen.screens.count,
              "\(shieldCount()) windows for \(NSScreen.screens.count) screens")
        check("shield is below the menu bar in debug", shieldLevels().allSatisfy { $0 < Int(CGShieldingWindowLevel()) },
              "levels \(shieldLevels())")
        check("gateShown logged", loggedTypes().contains(.gateShown))

        // 1b. The picker must offer apps you have not opened yet: at the gate you are
        // naming what you are about to use.
        manager.refreshPickerApps()
        check("picker includes apps that are not running",
              manager.pickerApps.contains { !$0.isRunning },
              "\(manager.pickerApps.filter { !$0.isRunning }.count) not running of \(manager.pickerApps.count)")
        check("Safari is offered whether or not it is open",
              manager.pickerApps.contains { $0.bundleID == KnownBrowser.safari.rawValue })
        manager.pickerSearch = "safa"
        check("search tolerates the app you meant", manager.pickerApps.contains { $0.name.contains("Safari") } || manager.pickerApps.isEmpty,
              "\(manager.pickerApps.count) results")
        manager.pickerSearch = "safari"
        check("search finds Safari", manager.pickerApps.contains { $0.bundleID == KnownBrowser.safari.rawValue })
        manager.pickerSearch = ""

        // 2. Starting a full session drops the shield and hides other apps.
        effects = []
        manager.toggleAllowed(bundleID: xcode.bundleID)
        manager.startFullSession(goal: "self check full session", duration: 25 * 60)
        check("session started", manager.activeSession?.goal == "self check full session")
        check("planned end is 25 minutes out",
              abs((manager.activeSession?.plannedEnd?.timeIntervalSince(clock.now) ?? 0) - 25 * 60) < 2)
        check("shield came down", shieldCount() == 0)
        check("kiosk released", effects.contains(.setKiosk(false)))
        check("non-allowed apps hidden", effects.contains { if case .hideApps = $0 { return true } else { return false } })
        check("active session persisted", FileManager.default.fileExists(atPath: FocusGuardPaths().activeSession.path))

        // 3. Finder is never a violation; a stray app is.
        manager.send(.appActivated(finder))
        check("Finder does not intervene", !isIntervening(manager))

        manager.send(.appActivated(stray))
        check("stray app intervenes", isIntervening(manager))
        check("intervention panel is on screen", panelCount(minWidth: 500) >= 1, "\(panelCount(minWidth: 500)) panels")
        check("the intervention joins the current Space instead of pulling you to the desktop",
              NSApp.windows.contains { window in
                  window.isVisible && window is NSPanel && window.frame.width >= 500
                      && window.styleMask.contains(.nonactivatingPanel)
                      && window.collectionBehavior.contains(.fullScreenAuxiliary)
                      && window.collectionBehavior.contains(.canJoinAllSpaces)
              })
        check("violation logged", loggedTypes().contains(.violation))

        // 4. Return, then add-to-session with a reason.
        manager.send(.returnRequested)
        check("return leaves the intervention", !isIntervening(manager))

        manager.send(.appActivated(stray))
        manager.send(.addToSessionRequested(target: .app(stray), reason: "self check"))
        check("addition widens this session", manager.activeSession?.allowedBundleIDs.contains(stray.bundleID) == true)
        check("addition logged", loggedTypes().contains(.additionToSession))
        check("panel dismissed after adding", !isIntervening(manager))

        // 5. Time up opens the review; extending respects the cap; answering ends it.
        clock.advance(26 * 60)
        manager.send(.tick(idleSeconds: 0))
        check("time up opens the review", isReviewing(manager))
        check("the review covers every display", shieldCount() == NSScreen.screens.count,
              "\(shieldCount()) of \(NSScreen.screens.count)")
        check("the review joins every Space, full-screen apps included, without activating",
              !shieldWindows().isEmpty && shieldWindows().allSatisfy { window in
                  window.styleMask.contains(.nonactivatingPanel)
                      && window.collectionBehavior.contains(.fullScreenAuxiliary)
                      && window.collectionBehavior.contains(.canJoinAllSpaces)
              })
        effects = []
        manager.send(.appActivated(stray))
        check("switching apps during the review pulls it straight back",
              effects.contains(.bringReviewToFront) && isReviewing(manager))

        manager.extendReview(by: 10 * 60)
        check("extend returns to the session", manager.activeSession != nil && !isReviewing(manager))
        check("extension logged", loggedTypes().contains(.sessionExtended))

        clock.advance(11 * 60)
        manager.send(.tick(idleSeconds: 0))
        manager.answerReview(finished: true)
        check("answering ends the session", manager.activeSession == nil)
        check("gate is back with the sleep offer", manager.gateContext?.offerSleep == true)
        check("no repeat question after answering", manager.gateContext?.lastSession == nil)
        check("session end logged as finished",
              lastPayload(SessionEndedPayload.self)?.outcome == .finished)
        check("persisted session cleared", !FileManager.default.fileExists(atPath: FocusGuardPaths().activeSession.path))

        // 6. An expired session while you are away: no panel, gate on return.
        manager.toggleAllowed(bundleID: xcode.bundleID)
        manager.startFullSession(goal: "expire while away", duration: 10 * 60)
        clock.advance(11 * 60)
        manager.send(.tick(idleSeconds: 20 * 60))
        check("no review while you are away", !isReviewing(manager))
        manager.send(.gateTriggered(.unlock))
        check("gate on return", manager.isGated)
        check("gate asks about the last goal", manager.gateContext?.lastSession?.goal == "expire while away")
        check("ended at its planned end, not on return",
              lastPayload(SessionEndedPayload.self).map { abs($0.endedAt.timeIntervalSince($0.startedAt) - 10 * 60) < 2 } == true)
        check("expired outcome recorded", lastPayload(SessionEndedPayload.self)?.outcome == .expired)

        // 7. Resume rule: coming back mid-session must not gate you.
        manager.send(.gateAnswered(finished: false))
        manager.toggleAllowed(bundleID: xcode.bundleID)
        manager.startFullSession(goal: "resume rule", duration: 30 * 60)
        for trigger in [GateTrigger.unlock, .wake, .idleReturn] {
            manager.send(.gateTriggered(trigger))
        }
        check("unlock, wake and idle-return do not gate a live session", manager.activeSession?.goal == "resume rule")
        check("shield stays down", shieldCount() == 0)
        manager.send(.forceEnd(outcome: .abandoned))

        // 8. Open sessions: any app allowed, blocked domains still blocked.
        manager.startOpenSession(goal: "self check open session")
        check("open session is five minutes",
              abs((manager.activeSession?.plannedEnd?.timeIntervalSince(clock.now) ?? 0) - 5 * 60) < 2)
        manager.send(.appActivated(stray))
        check("open sessions allow any app", !isIntervening(manager))

        manager.send(.appActivated(safari))
        manager.send(.urlObserved(browser: safari, url: URL(string: "https://www.youtube.com/watch?v=abc")!))
        check("blocked domain intervenes in an open session", isIntervening(manager))
        check("blocked site cannot be added", currentViolation(manager)?.isAddable == false)
        manager.send(.returnRequested)

        // 9. Five to ten minutes, then conversion carries what you used.
        manager.send(.appActivated(xcode))
        clock.advance(6 * 60)
        manager.send(.tick(idleSeconds: 0))
        check("open session hits the review at five minutes", isReviewing(manager))
        manager.extendOpenSession()
        check("extension gives ten minutes total",
              manager.activeSession.map { session in
                  abs((session.plannedEnd?.timeIntervalSince(session.startedAt) ?? 0) - 10 * 60) < 2
              } == true)
        check("only one extension is allowed", manager.activeSession?.extensionsUsed == 1)

        clock.advance(5 * 60)
        manager.send(.tick(idleSeconds: 0))
        let openID = manager.activeSession?.id
        manager.convertOpenSession(duration: 50 * 60)
        check("conversion starts a new full session",
              manager.activeSession?.kind == .full && manager.activeSession?.id != openID)
        check("conversion carries the app you were in the whole time",
              manager.activeSession?.allowedBundleIDs.contains(xcode.bundleID) == true,
              (manager.activeSession?.allowedBundleIDs ?? []).joined(separator: ","))
        check("conversion logged", loggedTypes().contains(.sessionConverted))
        check("old session closed as converted",
              payloads(SessionEndedPayload.self).contains { $0.sessionID == openID && $0.outcome == .converted })

        // 10. Override suspends enforcement and hands the session back.
        manager.startOverride(reason: "self check override")
        check("override suspends enforcement", manager.overrideState != nil)
        manager.send(.appActivated(stray))
        check("nothing intervenes during an override", !isIntervening(manager))
        check("override logged", loggedTypes().contains(.overrideStarted))
        clock.advance(16 * 60)
        manager.send(.tick(idleSeconds: 0))
        check("override expires back into the session", manager.activeSession?.goal == "self check open session")
        check("override end logged", loggedTypes().contains(.overrideEnded))

        // 11. Presets and recents.
        if let session = manager.activeSession {
            manager.savePreset(named: "Self Check Preset", from: session)
        }
        check("preset saved", manager.presets.contains { $0.name == "Self Check Preset" })
        check("preset suggested when typing",
              manager.suggestions(for: "self check").contains { $0.title == "Self Check Preset" })
        check("recent goals recorded", !manager.suggestions(for: "self check open").isEmpty)

        manager.send(.forceEnd(outcome: .finished))
        check("history reads back from the log", manager.sessionHistory.count >= 4,
              "\(manager.sessionHistory.count) sessions")

        runPhase2Checks(manager: manager, safari: safari)
        report()
    }

    // MARK: - Phase 2: sites, pins, fail-closed, settings delays

    private static func runPhase2Checks(manager: FocusSessionManager, safari: AppIdentity) {
        let firefox = AppIdentity(bundleID: KnownBrowser.firefox.rawValue, name: "Firefox")

        // A full session with a named site list allows that site and nothing else.
        manager.toggleAllowed(bundleID: safari.bundleID)
        manager.addSessionSite("developer.apple.com", scope: .domain)
        manager.addSessionSite("https://www.youtube.com/watch?v=lecture1&t=30", scope: .pinnedPage)
        check("a site can be allowed by domain", manager.sessionSites.contains(SiteRule(scope: .domain, pattern: "developer.apple.com")))
        check("a page on a blocked domain can be pinned",
              manager.sessionSites.contains(SiteRule(scope: .pinnedPage, pattern: "https://youtube.com/watch?v=lecture1")))

        manager.addSessionSite("youtube.com", scope: .domain)
        check("a blocked domain cannot be allowlisted", manager.siteInputError?.contains("blocked") == true,
              manager.siteInputError ?? "no error")
        manager.clearSiteInputError()

        // Starting with "allow all non-blocked sites" ticked must work, and must record
        // the choice on the session.
        manager.removeSessionSite(SiteRule(scope: .domain, pattern: "developer.apple.com"))
        manager.removeSessionSite(SiteRule(scope: .pinnedPage, pattern: "https://youtube.com/watch?v=lecture1"))
        manager.allowAllNonBlockedSites = true
        manager.startFullSession(goal: "self check allow all", duration: 10 * 60)
        check("a browser session starts with allow-all ticked", manager.activeSession?.goal == "self check allow all")
        check("the allow-all choice is on the session", manager.activeSession?.allowAllNonBlockedSites == true)
        manager.send(.appActivated(safari))
        manager.send(.urlObserved(browser: safari, url: URL(string: "https://news.ycombinator.com")!))
        check("allow-all lets a non-blocked site through", !isIntervening(manager))
        manager.send(.urlObserved(browser: safari, url: URL(string: "https://youtube.com/watch?v=x")!))
        check("allow-all still blocks the blocklist", isIntervening(manager))
        manager.send(.returnRequested)
        manager.send(.forceEnd(outcome: .finished))

        manager.toggleAllowed(bundleID: safari.bundleID)
        manager.addSessionSite("developer.apple.com", scope: .domain)
        manager.addSessionSite("https://www.youtube.com/watch?v=lecture1&t=30", scope: .pinnedPage)
        manager.startFullSession(goal: "self check sites", duration: 25 * 60)
        manager.send(.appActivated(safari))
        check("session carries its site list", manager.activeSession?.allowedSites.count == 2)

        manager.send(.urlObserved(browser: safari, url: URL(string: "https://developer.apple.com/documentation/swift")!))
        check("an allowed domain passes", !isIntervening(manager))

        manager.send(.urlObserved(browser: safari, url: URL(string: "https://news.ycombinator.com")!))
        check("an unlisted site is a violation", isIntervening(manager))
        check("an unlisted site can be added with a reason", currentViolation(manager)?.isAddable == true)
        manager.send(.returnRequested)

        // The pin: this exact video plays, the next one does not.
        manager.send(.urlObserved(browser: safari, url: URL(string: "https://www.youtube.com/watch?v=lecture1&t=900")!))
        check("the pinned video plays", !isIntervening(manager))

        manager.send(.urlObserved(browser: safari, url: URL(string: "https://www.youtube.com/watch?v=autoplayed")!))
        check("autoplay to the next video is a violation", isIntervening(manager))
        check("the rest of a blocked domain still cannot be added", currentViolation(manager)?.isAddable == false)
        manager.send(.returnRequested)

        manager.send(.urlObserved(browser: safari, url: URL(string: "https://www.youtube.com/")!))
        check("the blocked domain's homepage is still blocked", isIntervening(manager))
        manager.send(.returnRequested)

        // Fail-closed thresholds, by browser.
        check("fail-closed is on by default", manager.settingsDraft.failClosedURLReading)
        manager.send(.urlReadFailed(browser: safari, consecutiveFailures: 4))
        check("four unreadable polls are tolerated", !isIntervening(manager))
        manager.send(.urlReadFailed(browser: safari, consecutiveFailures: 5))
        check("five unreadable polls is a can't-verify violation", isIntervening(manager))
        check("can't-verify names the browser",
              currentViolation(manager)?.kind == .unverifiableURL(browser: safari.bundleID))
        check("an unreadable page offers the permission fix, not an allowlist entry",
              currentViolation(manager)?.isAddable == false)
        manager.send(.returnRequested)

        manager.send(.urlReadFailed(browser: firefox, consecutiveFailures: 5))
        check("Firefox gets a longer grace", !isIntervening(manager))
        manager.send(.urlReadFailed(browser: firefox, consecutiveFailures: 12))
        check("Firefox does fail closed eventually", isIntervening(manager))
        manager.send(.returnRequested)

        manager.send(.forceEnd(outcome: .finished))

        // A pin on a blocked domain must not survive into a recent or a preset.
        let recentSites = manager.suggestions(for: "self check sites").first?.allowedSites ?? []
        check("the pinned blocked page is not saved into recents",
              !recentSites.contains { $0.pattern.contains("youtube") },
              recentSites.map(\.pattern).joined(separator: ","))

        runPhase3Checks(manager: manager)

        // Settings: tightening now, loosening in 24 hours.
        var edited = manager.settingsDraft
        edited.blocklist.add("news.example.com")
        edited.blocklist.remove("reddit.com")
        manager.settingsDraft = edited

        check("a new blocked domain applies immediately",
              manager.settingsDraft.blocklist.blocks(host: "news.example.com") != nil)
        check("unblocking waits", manager.settingsDraft.blocklist.blocks(host: "reddit.com") != nil)
        check("the wait is visible as a pending change", manager.pendingChanges.count == 1)
        check("scheduled change logged", loggedTypes().contains(.settingsChangeScheduled))
        check("the countdown reads as a wait", manager.countdown(to: manager.pendingChanges[0].effectiveAt).hasPrefix("In "),
              manager.countdown(to: manager.pendingChanges.first?.effectiveAt ?? Date()))

        clock.advance(23 * 3600)
        manager.send(.tick(idleSeconds: 0))
        check("still pending after 23 hours", manager.pendingChanges.count == 1)

        clock.advance(2 * 3600)
        manager.send(.tick(idleSeconds: 0))
        check("applied after 24 hours", manager.pendingChanges.isEmpty)
        check("the domain is unblocked once the wait is over",
              manager.settingsDraft.blocklist.blocks(host: "reddit.com") == nil)
        check("applied change logged", loggedTypes().contains(.settingsChangeApplied))

        // Cancelling a pending change is itself tightening, so it is instant.
        var second = manager.settingsDraft
        second.maxFullSessionLength = 4 * 3600
        manager.settingsDraft = second
        check("raising the session cap waits", manager.pendingChanges.count == 1)
        manager.cancelPendingChange(manager.pendingChanges[0].id)
        check("cancelling is instant", manager.pendingChanges.isEmpty)
        check("cancellation logged", loggedTypes().contains(.settingsChangeCancelled))
    }

    // MARK: - Phase 3: review, export, learning, pacing

    private static func runPhase3Checks(manager: FocusSessionManager) {
        let today = clock.now

        // The review has to agree with what the log says happened.
        let review = manager.dailyReview(for: today)
        check("review finds today's sessions", review.sessions.count >= 4, "\(review.sessions.count) sessions")
        check("review splits full and open", !review.fullSessions.isEmpty && !review.openSessions.isEmpty,
              "\(review.fullSessions.count) full, \(review.openSessions.count) open")
        check("review counts violations", review.sessions.reduce(0) { $0 + $1.violations } > 0)
        check("review lists mid-session additions with reasons",
              review.additions.contains { $0.reason == "self check" },
              review.additions.map(\.reason).joined(separator: ","))
        check("review lists the override with its reason",
              review.overrides.contains { $0.reason == "self check override" })
        check("review counts trips through the gate", review.gateShownCount > 0, "\(review.gateShownCount)")

        // Chains: the self-check starts open sessions back to back.
        let chained = review.openSessions.filter(\.chainedFromPrevious)
        check("chained open sessions are flagged", !chained.isEmpty || review.openSessions.count < 2,
              "\(chained.count) of \(review.openSessions.count) open sessions chained")

        // Totals: sessions cannot claim more time than the day holds.
        check("session time is not longer than the day",
              review.totals.sessionSeconds <= 86400, "\(Int(review.totals.sessionSeconds))s")
        check("coverage is a fraction", (0...1).contains(review.totals.coverage), "\(review.totals.coverage)")

        // Export.
        guard let url = manager.exportDay(today) else {
            check("export writes a file", false)
            return
        }
        check("export writes a file", FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
        if let data = try? Data(contentsOf: url),
           let export = try? JSONCoding.decoder().decode(DailyExport.self, from: data) {
            check("export agrees with the review", export.sessionCount == review.sessions.count,
                  "export \(export.sessionCount) vs review \(review.sessions.count)")
            check("export names the day", export.date == FocusGuardPaths.dayStamp(for: today), export.date)
            check("export records coverage", export.coverage >= 0)
        } else {
            check("export is readable JSON", false)
        }

        // Preset learning: three similar open sessions inside the window.
        let outlook = AppIdentity(bundleID: "com.microsoft.Outlook", name: "Outlook")
        for index in 0..<3 {
            manager.startOpenSession(goal: "email the landlord \(index)")
            manager.send(.appActivated(outlook))
            clock.advance(60)
            manager.send(.forceEnd(outcome: .finished))
        }
        if let last = manager.sessionHistory.first {
            var session = Session(
                id: last.id, kind: .open, goal: "email the landlord again",
                anchor: outlook, allowedBundleIDs: [outlook.bundleID], startedAt: clock.now
            )
            session.noteUsage(of: outlook, seconds: 120)
            let suggestion = manager.presetSuggestion(for: session)
            check("three similar open sessions earn a preset suggestion", suggestion != nil,
                  suggestion?.name ?? "none")
            if let suggestion {
                manager.acceptPresetSuggestion(suggestion)
                check("accepting the suggestion saves the preset",
                      manager.presets.contains { $0.name == suggestion.name })
            }
        }

        // Quitting is not a way past the gate (3.4).
        check("quitting is refused at the gate", manager.isGated && manager.quitIsBlocked)

        // The refusal must not block. It used to open a modal alert behind the shield, which
        // swallowed every keystroke and looked like a frozen gate.
        let refusalStarted = Date()
        manager.refuseQuit()
        check("refusing a quit returns immediately instead of waiting on a hidden modal",
              Date().timeIntervalSince(refusalStarted) < 0.5,
              String(format: "%.3fs", Date().timeIntervalSince(refusalStarted)))
        check("the refusal is said in the terminal", manager.gateNotice?.lines.contains {
            $0.text.contains("quit refused")
        } == true)
        check("the refusal is logged", loggedTypes().contains(.quitBlocked))
        check("the testing exit is compiled in, and says so", FocusGuardConfig.testingExitCommandEnabled)
        manager.toggleAllowed(bundleID: "com.apple.dt.Xcode")
        manager.startFullSession(goal: "quit rules", duration: 10 * 60)
        check("quitting a running session is allowed, with the commitment prompt", !manager.quitIsBlocked)
        manager.send(.appActivated(AppIdentity(bundleID: "com.example.stray", name: "Stray")))
        check("quitting is refused during an intervention", manager.quitIsBlocked)
        manager.send(.returnRequested)
        manager.send(.endRequested)
        check("quitting is refused during the review", manager.quitIsBlocked)
        manager.answerReview(finished: true)

        // Open-session pacing, off by default.
        check("open sessions have no countdown by default", manager.openSessionCountdown() == 0)
        var paced = manager.settingsDraft
        paced.openSessionCountdownEnabled = true
        manager.settingsDraft = paced
        check("enabling the countdown applies immediately", manager.settingsDraft.openSessionCountdownEnabled)
        check("after several quick sessions the countdown bites", manager.openSessionCountdown() > 0,
              "\(Int(manager.openSessionCountdown()))s")
        paced.openSessionCountdownEnabled = false
        manager.settingsDraft = paced
        check("turning the countdown off waits 24 hours",
              manager.settingsDraft.openSessionCountdownEnabled)
        for pending in manager.pendingChanges { manager.cancelPendingChange(pending.id) }
    }

    // MARK: - Checking

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        results.append((name, passed, detail))
    }

    private static func isIntervening(_ manager: FocusSessionManager) -> Bool {
        if case .intervention = manager.state.phase { return true }
        return false
    }

    private static func isReviewing(_ manager: FocusSessionManager) -> Bool {
        if case .review = manager.state.phase { return true }
        return false
    }

    private static func currentViolation(_ manager: FocusSessionManager) -> Violation? {
        if case .intervention(_, let violation) = manager.state.phase { return violation }
        return nil
    }

    private static func shieldWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible && window.styleMask.contains(.borderless)
                && window.frame.width >= (NSScreen.main?.frame.width ?? 1000) - 1
        }
    }

    private static func shieldCount() -> Int { shieldWindows().count }
    private static func shieldLevels() -> [Int] { shieldWindows().map { $0.level.rawValue } }

    private static func panelCount(minWidth: CGFloat) -> Int {
        NSApp.windows.filter { $0.isVisible && $0 is NSPanel && $0.frame.width >= minWidth }.count
    }

    private static func events() -> [LogEvent] {
        EventLogStore(paths: FocusGuardPaths()).allEvents()
    }

    private static func loggedTypes() -> Set<EventType> {
        Set(events().map(\.type))
    }

    private static func payloads<P: EventPayload>(_ type: P.Type) -> [P] {
        events().compactMap { $0.decode(P.self) }
    }

    private static func lastPayload<P: EventPayload>(_ type: P.Type) -> P? {
        payloads(type).last
    }

    private static func report() {
        let failures = results.filter { !$0.passed }
        print("\n=== Focus Guard self-check ===")
        for result in results {
            let mark = result.passed ? "PASS" : "FAIL"
            let detail = result.detail.isEmpty ? "" : "  (\(result.detail))"
            print("\(mark)  \(result.name)\(detail)")
        }
        print("\(results.count - failures.count)/\(results.count) checks passed")
        exit(failures.isEmpty ? 0 : 1)
    }
}
#endif
