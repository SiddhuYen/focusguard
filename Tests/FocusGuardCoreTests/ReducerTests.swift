import Foundation
import Testing
@testable import FocusGuardCore

@Suite("Reducer: gate and sessions")
struct ReducerTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let xcode = AppIdentity(bundleID: "com.apple.dt.Xcode", name: "Xcode")
    let slack = AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    let safari = AppIdentity(bundleID: KnownBrowser.safari.rawValue, name: "Safari")

    private func context(_ offset: TimeInterval = 0) -> ReducerContext {
        .fixed(now: start.addingTimeInterval(offset))
    }

    private func gated() -> AppState {
        var state = AppState()
        state.settings.blocklist = Blocklist(domains: ["youtube.com"])
        state.frontmostApp = xcode
        let (next, _) = FocusReducer.reduce(state, .launched(restoredSession: nil, safeMode: nil), context: context())
        return next
    }

    private func request(kind: SessionKind = .full, duration: TimeInterval? = 25 * 60, allowed: [String]? = nil) -> SessionRequest {
        SessionRequest(
            kind: kind,
            goal: "ship the gate",
            anchor: xcode,
            allowedBundleIDs: allowed ?? [xcode.bundleID],
            duration: duration
        )
    }

    private func inSession(kind: SessionKind = .full, allowed: [String]? = nil, at offset: TimeInterval = 0) -> AppState {
        let (next, _) = FocusReducer.reduce(
            gated(), .sessionStartRequested(request(kind: kind, allowed: allowed)), context: context(offset)
        )
        return next
    }

    // MARK: Gate

    @Test("Launching with no session shows the gate and raises the shield")
    func launchShowsGate() {
        let (state, effects) = FocusReducer.reduce(AppState(), .launched(restoredSession: nil, safeMode: nil), context: context())
        #expect(state.isGated)
        #expect(effects.contains { if case .showShield = $0 { return true } else { return false } })
        #expect(effects.contains(.setKiosk(true)))
        #expect(effects.contains { effect in
            guard case .log(let event) = effect else { return false }
            return event.decode(GateShownPayload.self)?.trigger == .launch
        })
    }

    @Test("Coming back mid-session does not gate you")
    func resumeRule() {
        let state = inSession()
        for trigger in [GateTrigger.unlock, .wake, .idleReturn] {
            let (next, effects) = FocusReducer.reduce(state, .gateTriggered(trigger), context: context(60))
            #expect(!next.isGated, "\(trigger) must not gate an active session")
            #expect(!effects.contains { if case .showShield = $0 { return true } else { return false } })
        }
    }

    @Test("Coming back after the session ran out gates you and asks about the goal")
    func expiredWhileAway() {
        let state = inSession()
        let (next, effects) = FocusReducer.reduce(state, .gateTriggered(.unlock), context: context(30 * 60))
        guard case .gate(let gate) = next.phase else { Issue.record("expected the gate"); return }
        #expect(gate.lastSession?.goal == "ship the gate")
        #expect(gate.offerSleep)
        let ended = effects.compactMap { effect -> SessionEndedPayload? in
            guard case .log(let event) = effect else { return nil }
            return event.decode(SessionEndedPayload.self)
        }
        #expect(ended.first?.outcome == .expired)
        // The session ended at its planned end, not when you happened to come back.
        #expect(ended.first?.endedAt == start.addingTimeInterval(25 * 60))
    }

    @Test("Relaunching into a live session resumes it without the gate")
    func relaunchResumes() {
        let session = inSession().activeSession!
        let (next, effects) = FocusReducer.reduce(AppState(), .launched(restoredSession: session, safeMode: nil), context: context(60))
        #expect(next.activeSession?.id == session.id)
        #expect(!next.isGated)
        #expect(!effects.contains(.setKiosk(true)))
    }

    @Test("Answering the gate's question logs it and clears the prompt")
    func gateAnswer() {
        let expired = FocusReducer.reduce(inSession(), .gateTriggered(.unlock), context: context(30 * 60)).0
        let (next, effects) = FocusReducer.reduce(expired, .gateAnswered(finished: true), context: context(30 * 60 + 5))
        guard case .gate(let gate) = next.phase else { Issue.record("expected the gate"); return }
        #expect(gate.lastSession == nil)
        #expect(effects.contains { effect in
            guard case .log(let event) = effect else { return false }
            return event.decode(GateAnsweredPayload.self)?.finished == true
        })
    }

    @Test("A crash loop skips the gate once; the restart escape skips it all launch")
    func safeModeTriggers() {
        let crash = FocusReducer.reduce(
            AppState(),
            .launched(restoredSession: nil, safeMode: SafeModeEntry(reason: .crashLoop, detail: "3 crashes")),
            context: context()
        ).0
        #expect(crash.phase == .safeMode(.crashLoop))
        let (afterTrigger, _) = FocusReducer.reduce(crash, .gateTriggered(.unlock), context: context(60))
        #expect(afterTrigger.isGated, "normal behavior resumes at the next trigger")

        let escape = FocusReducer.reduce(
            AppState(),
            .launched(restoredSession: nil, safeMode: SafeModeEntry(reason: .restartEscape, detail: "keys held")),
            context: context()
        ).0
        let (stillSafe, _) = FocusReducer.reduce(escape, .gateTriggered(.unlock), context: context(60))
        #expect(stillSafe.phase == .safeMode(.restartEscape), "the escape lasts the whole launch")
    }

    // MARK: Starting sessions

    @Test("Starting a session drops the shield, hides other apps and returns you to work")
    func startSession() {
        let (state, effects) = FocusReducer.reduce(gated(), .sessionStartRequested(request()), context: context())
        guard case .session(let session) = state.phase else { Issue.record("expected a session"); return }
        #expect(session.plannedEnd == start.addingTimeInterval(25 * 60))
        #expect(effects.contains(.hideShield))
        #expect(effects.contains(.setKiosk(false)))
        #expect(effects.contains(.hideApps(allowed: session.allowedBundleIDs)))
        #expect(effects.contains(.activateApp(bundleID: xcode.bundleID)))
        #expect(state.recentGoals.first?.goal == "ship the gate")
    }

    @Test("Full sessions are capped at the maximum length")
    func durationCap() {
        var state = gated()
        state.settings.maxFullSessionLength = 3600
        let (next, _) = FocusReducer.reduce(state, .sessionStartRequested(request(duration: 6 * 3600)), context: context())
        #expect(next.activeSession?.plannedEnd == start.addingTimeInterval(3600))
    }

    @Test("Open sessions run five minutes and never hide your apps")
    func openSession() {
        let (state, effects) = FocusReducer.reduce(gated(), .sessionStartRequested(request(kind: .open, duration: nil)), context: context())
        #expect(state.activeSession?.plannedEnd == start.addingTimeInterval(5 * 60))
        #expect(!effects.contains { if case .hideApps = $0 { return true } else { return false } })
    }

    @Test("An open session extends once, to ten minutes total, and no further")
    func openSessionExtension() {
        let state = inSession(kind: .open)
        let (extended, effects) = FocusReducer.reduce(state, .openSessionExtended, context: context(5 * 60))
        #expect(extended.activeSession?.plannedEnd == start.addingTimeInterval(10 * 60))
        #expect(extended.activeSession?.extensionsUsed == 1)
        #expect(effects.contains { effect in
            guard case .log(let event) = effect else { return false }
            return event.type == .sessionExtended
        })

        let (again, _) = FocusReducer.reduce(extended, .openSessionExtended, context: context(10 * 60))
        #expect(again.activeSession?.plannedEnd == start.addingTimeInterval(10 * 60), "only one extension")
    }

    @Test("Converting an open session ends it as converted and starts a full one")
    func convertToFull() {
        var state = inSession(kind: .open)
        // Pretend the open session was spent in Xcode and Terminal.
        if case .session(var session) = state.phase {
            session.noteUsage(of: xcode, seconds: 120)
            session.noteUsage(of: AppIdentity(bundleID: "com.apple.Terminal", name: "Terminal"), seconds: 60)
            state.phase = .session(session)
        }
        let openID = state.activeSession!.id

        let converted = SessionRequest(
            kind: .full,
            goal: "ship the gate",
            anchor: xcode,
            allowedBundleIDs: [xcode.bundleID, "com.apple.Terminal"],
            duration: 50 * 60
        )
        let (next, effects) = FocusReducer.reduce(state, .convertToFullRequested(converted), context: context(5 * 60))

        guard case .session(let full) = next.phase else { Issue.record("expected a full session"); return }
        #expect(full.kind == .full)
        #expect(full.id != openID)
        #expect(full.convertedFrom == openID)
        #expect(full.allowedBundleIDs.contains("com.apple.Terminal"))
        #expect(full.plannedEnd == start.addingTimeInterval(5 * 60 + 50 * 60))

        let ended = effects.compactMap { effect -> SessionEndedPayload? in
            guard case .log(let event) = effect else { return nil }
            return event.decode(SessionEndedPayload.self)
        }
        #expect(ended.first?.outcome == .converted)
        #expect(effects.contains { effect in
            guard case .log(let event) = effect else { return false }
            return event.decode(SessionConvertedPayload.self)?.fromSessionID == openID
        })
    }

    // MARK: Time up and review

    @Test("Time running out while you are here opens the review")
    func timeUpWhileActive() {
        let state = inSession()
        let (next, effects) = FocusReducer.reduce(state, .tick(idleSeconds: 5), context: context(25 * 60 + 1))
        guard case .review(_, let reason) = next.phase else { Issue.record("expected the review"); return }
        #expect(reason == .timeUp)
        #expect(effects.contains { if case .showReview = $0 { return true } else { return false } })
    }

    @Test("Time running out while you are away shows nothing until you come back")
    func timeUpWhileIdle() {
        let state = inSession()
        let (next, effects) = FocusReducer.reduce(state, .tick(idleSeconds: 20 * 60), context: context(25 * 60 + 1))
        #expect(next.activeSession != nil)
        #expect(!effects.contains { if case .showReview = $0 { return true } else { return false } })

        // ...and the gate takes over when you do.
        let (returned, _) = FocusReducer.reduce(next, .gateTriggered(.idleReturn), context: context(40 * 60))
        #expect(returned.isGated)
    }

    @Test("Answering the review ends the session and raises the gate with the sleep offer")
    func reviewAnswered() {
        let review = FocusReducer.reduce(inSession(), .tick(idleSeconds: 0), context: context(25 * 60 + 1)).0
        let (next, effects) = FocusReducer.reduce(review, .reviewAnswered(finished: true), context: context(25 * 60 + 30))

        guard case .gate(let gate) = next.phase else { Issue.record("expected the gate"); return }
        #expect(gate.offerSleep)
        #expect(gate.lastSession == nil, "you just answered, so the gate must not ask again")
        #expect(effects.contains(.dismissReview))
        #expect(effects.contains(.persistSession(nil)))

        let ended = effects.compactMap { effect -> SessionEndedPayload? in
            guard case .log(let event) = effect else { return nil }
            return event.decode(SessionEndedPayload.self)
        }
        #expect(ended.first?.outcome == .finished)
    }

    @Test("Extending from the review stays inside the max session length")
    func reviewExtendRespectsCap() {
        var state = inSession()
        state.settings.maxFullSessionLength = 30 * 60
        let review = FocusReducer.reduce(state, .tick(idleSeconds: 0), context: context(25 * 60 + 1)).0
        let (extended, _) = FocusReducer.reduce(review, .reviewExtended(by: 25 * 60), context: context(25 * 60 + 5))
        #expect(extended.activeSession?.plannedEnd == start.addingTimeInterval(30 * 60), "capped, not 50 minutes")
        #expect(extended.phase.isEnforcing)
    }

    @Test("Ending from the menu goes through the review rather than straight out")
    func endGoesThroughReview() {
        let (next, effects) = FocusReducer.reduce(inSession(), .endRequested, context: context(60))
        guard case .review(_, let reason) = next.phase else { Issue.record("expected the review"); return }
        #expect(reason == .endedByUser)
        #expect(effects.contains { if case .showReview = $0 { return true } else { return false } })
        #expect(next.activeSession != nil, "not ended until the review is answered")
    }

    @Test("Force ending skips the review, for quitting")
    func forceEnd() {
        let (next, _) = FocusReducer.reduce(inSession(), .forceEnd(outcome: .abandoned), context: context(60))
        #expect(next.isGated)
        #expect(next.activeSession == nil)
    }

    // MARK: Enforcement

    @Test("Switching to a non-allowed app opens an intervention")
    func appViolation() {
        let (next, effects) = FocusReducer.reduce(inSession(), .appActivated(slack), context: context(60))
        guard case .intervention(let session, let violation) = next.phase else {
            Issue.record("expected an intervention")
            return
        }
        #expect(session.violations.count == 1)
        #expect(violation.kind == .app(slack))
        #expect(effects.contains { if case .showIntervention = $0 { return true } else { return false } })
    }

    @Test("Finder never counts as a violation")
    func finderIsFine() {
        let finder = AppIdentity(bundleID: "com.apple.finder", name: "Finder")
        let (next, _) = FocusReducer.reduce(inSession(), .appActivated(finder), context: context(60))
        #expect(next.phase.isEnforcing)
        if case .intervention = next.phase { Issue.record("Finder must never intervene") }
    }

    @Test("Open sessions allow any app but still block blocked domains")
    func openSessionEnforcement() {
        var state = inSession(kind: .open)
        let (afterApp, _) = FocusReducer.reduce(state, .appActivated(slack), context: context(30))
        if case .intervention = afterApp.phase { Issue.record("open sessions allow any app") }

        state = afterApp
        state.frontmostApp = safari
        let url = URL(string: "https://www.youtube.com/watch?v=abc")!
        let (afterURL, _) = FocusReducer.reduce(state, .urlObserved(browser: safari, url: url), context: context(40))
        guard case .intervention(_, let violation) = afterURL.phase else {
            Issue.record("blocked domains apply to open sessions")
            return
        }
        #expect(violation.kind == .blockedSite(domain: "youtube.com", url: url.absoluteString))
        #expect(!violation.isAddable)
    }

    @Test("Return goes back to the session and reactivates the anchor")
    func returnToApp() {
        let intervened = FocusReducer.reduce(inSession(), .appActivated(slack), context: context(60)).0
        let (next, effects) = FocusReducer.reduce(intervened, .returnRequested, context: context(70))
        #expect(next.phase.isEnforcing)
        #expect(effects.contains(.activateApp(bundleID: xcode.bundleID)))
        #expect(effects.contains(.dismissIntervention))
    }

    @Test("Add to this session widens it for this session only")
    func addToSession() {
        let intervened = FocusReducer.reduce(inSession(), .appActivated(slack), context: context(60)).0
        let (next, _) = FocusReducer.reduce(
            intervened,
            .addToSessionRequested(target: .app(slack), reason: "on-call ping"),
            context: context(65)
        )
        #expect(next.activeSession?.allowedBundleIDs.contains(slack.bundleID) == true)

        let ended = FocusReducer.reduce(next, .forceEnd(outcome: .finished), context: context(70)).0
        let (fresh, _) = FocusReducer.reduce(ended, .sessionStartRequested(request()), context: context(80))
        #expect(fresh.activeSession?.allowedBundleIDs.contains(slack.bundleID) == false)
    }

    @Test("URL polling keeps following the browser through an intervention")
    func urlMonitoringSurvivesViolation() {
        var state = inSession(allowed: [safari.bundleID])
        state.frontmostApp = safari
        let url = URL(string: "https://www.youtube.com/watch?v=abc")!

        let (intervened, effects) = FocusReducer.reduce(state, .urlObserved(browser: safari, url: url), context: context(30))
        #expect(effects.contains(.monitorURLs(safari)))

        let (returned, returnEffects) = FocusReducer.reduce(intervened, .returnRequested, context: context(40))
        #expect(returnEffects.contains(.monitorURLs(safari)))

        let (gated, gatedEffects) = FocusReducer.reduce(returned, .forceEnd(outcome: .finished), context: context(50))
        #expect(gated.isGated)
        #expect(gatedEffects.contains(.monitorURLs(nil)))
    }

    // MARK: Override

    @Test("An override suspends enforcement, drops the shield, and later hands the session back")
    func override() {
        let intervened = FocusReducer.reduce(inSession(), .appActivated(slack), context: context(60)).0
        let (overridden, effects) = FocusReducer.reduce(
            intervened, .overrideStarted(reason: "power is out, need the router page"), context: context(70)
        )

        guard case .overridden(let override) = overridden.phase else { Issue.record("expected an override"); return }
        #expect(override.until == start.addingTimeInterval(70 + 15 * 60))
        #expect(override.suspendedSession != nil)
        #expect(effects.contains(.dismissIntervention))
        #expect(!overridden.phase.isEnforcing)

        // Nothing is a violation while it runs.
        let (during, _) = FocusReducer.reduce(overridden, .appActivated(slack), context: context(120))
        if case .intervention = during.phase { Issue.record("enforcement is suspended") }

        // When it expires the session comes back, because it still has time on it.
        let (after, _) = FocusReducer.reduce(during, .tick(idleSeconds: 0), context: context(70 + 15 * 60 + 1))
        #expect(after.phase.isEnforcing)
        #expect(after.activeSession?.goal == "ship the gate")
    }

    @Test("An override that outlives its session hands you the gate")
    func overrideOutlivesSession() {
        // Override starts a minute before the session would have ended, so by the time it
        // lifts there is nothing left to go back to.
        let state = inSession()
        let (overridden, _) = FocusReducer.reduce(state, .overrideStarted(reason: "emergency"), context: context(24 * 60))
        let (after, _) = FocusReducer.reduce(overridden, .tick(idleSeconds: 0), context: context(24 * 60 + 15 * 60 + 1))
        #expect(after.isGated)
    }

    @Test("Sleeping the Mac is logged and asked for")
    func sleep() {
        let (_, effects) = FocusReducer.reduce(gated(), .sleepRequested, context: context())
        #expect(effects.contains(.sleepMac))
        #expect(effects.contains { effect in
            guard case .log(let event) = effect else { return false }
            return event.type == .sleepRequested
        })
    }
}

@Suite("Reducer: settings, permissions, presets")
struct ReducerSettingsTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func context(_ offset: TimeInterval = 0) -> ReducerContext {
        .fixed(now: start.addingTimeInterval(offset))
    }

    @Test("Tightening settings apply now, loosening ones are scheduled")
    func settingsChanges() {
        var edited = AppState().settings
        edited.blocklist.add("news.ycombinator.com")
        edited.blocklist.remove("reddit.com")

        let (next, effects) = FocusReducer.reduce(AppState(), .settingsEdited(edited), context: context())
        #expect(next.settings.blocklist.blocks(host: "news.ycombinator.com") != nil)
        #expect(next.settings.blocklist.blocks(host: "reddit.com") != nil, "unblocking waits 24 hours")
        #expect(next.pendingChanges.count == 1)
        #expect(effects.contains { if case .persistPendingChanges = $0 { return true } else { return false } })
    }

    @Test("A due pending change applies on the next tick")
    func pendingChangeApplies() {
        var edited = AppState().settings
        edited.blocklist.remove("reddit.com")
        let (scheduled, _) = FocusReducer.reduce(AppState(), .settingsEdited(edited), context: context())

        let (tooEarly, _) = FocusReducer.reduce(scheduled, .tick(), context: context(3600))
        #expect(tooEarly.pendingChanges.count == 1)

        let (applied, _) = FocusReducer.reduce(scheduled, .tick(), context: context(24 * 3600 + 1))
        #expect(applied.pendingChanges.isEmpty)
        #expect(applied.settings.blocklist.blocks(host: "reddit.com") == nil)
    }

    @Test("Cancelling a pending change removes it and logs it")
    func cancelPendingChange() {
        var edited = AppState().settings
        edited.blocklist.remove("reddit.com")
        let (scheduled, _) = FocusReducer.reduce(AppState(), .settingsEdited(edited), context: context())
        let id = scheduled.pendingChanges[0].id

        let (cancelled, effects) = FocusReducer.reduce(scheduled, .pendingChangeCancelled(id), context: context(60))
        #expect(cancelled.pendingChanges.isEmpty)
        #expect(effects.contains { effect in
            guard case .log(let event) = effect else { return false }
            return event.type == .settingsChangeCancelled
        })
    }

    @Test("Losing and regaining a permission is logged once each way")
    func permissionHealth() {
        var unhealthy = PermissionHealth()
        unhealthy.accessibilityTrusted = false

        let (lost, lostEffects) = FocusReducer.reduce(AppState(), .permissionsChanged(unhealthy), context: context())
        #expect(!lost.permissions.isHealthy)
        #expect(lostEffects.contains { effect in
            guard case .log(let event) = effect else { return false }
            return event.type == .permissionLost
        })

        let (again, repeatEffects) = FocusReducer.reduce(lost, .permissionsChanged(unhealthy), context: context(10))
        #expect(!repeatEffects.contains { effect in
            guard case .log(let event) = effect else { return false }
            return event.type == .permissionLost
        })

        let (restored, restoredEffects) = FocusReducer.reduce(again, .permissionsChanged(PermissionHealth()), context: context(20))
        #expect(restored.permissions.isHealthy)
        #expect(restoredEffects.contains { effect in
            guard case .log(let event) = effect else { return false }
            return event.type == .permissionRestored
        })
    }

    @Test("Saving a preset stores and logs it")
    func presetCreated() {
        let preset = Preset(name: "Email", keywords: ["inbox"], allowedBundleIDs: ["com.microsoft.Outlook"], defaultDuration: 25 * 60)
        let (next, effects) = FocusReducer.reduce(AppState(), .presetCreated(preset, source: "review"), context: context())
        #expect(next.presets.count == 1)
        #expect(effects.contains { if case .persistPresets = $0 { return true } else { return false } })
        #expect(effects.contains { effect in
            guard case .log(let event) = effect else { return false }
            return event.decode(PresetCreatedPayload.self)?.name == "Email"
        })
    }
}

@Suite("Gate suggestions")
struct GateSuggestionTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var presets: [Preset] {
        [
            Preset(name: "Email", keywords: ["inbox", "outlook"], allowedBundleIDs: ["com.microsoft.Outlook"], defaultDuration: 25 * 60),
            Preset(name: "Deep work", keywords: ["code", "xcode"], allowedBundleIDs: ["com.apple.dt.Xcode"], defaultDuration: 90 * 60)
        ]
    }

    private var recents: [RecentGoal] {
        [
            RecentGoal(goal: "email the landlord", allowedBundleIDs: ["com.microsoft.Outlook"], lastUsed: now),
            RecentGoal(goal: "write the physics lab report", allowedBundleIDs: ["com.apple.iWork.Pages"], lastUsed: now.addingTimeInterval(-86400))
        ]
    }

    @Test("Typing a preset name ranks the preset first")
    func presetFirst() {
        let results = GateSuggestions.suggestions(query: "ema", presets: presets, recents: recents)
        #expect(results.first?.isPreset == true)
        #expect(results.first?.title == "Email")
        #expect(results.first?.duration == TimeInterval(1500))
    }

    @Test("Keywords match too")
    func keywords() {
        let results = GateSuggestions.suggestions(query: "xcode", presets: presets, recents: recents)
        #expect(results.first?.title == "Deep work")
    }

    @Test("Recent goals match on any word")
    func recentGoals() {
        let results = GateSuggestions.suggestions(query: "physics", presets: presets, recents: recents)
        #expect(results.count == 1)
        #expect(results.first?.title == "write the physics lab report")
        #expect(results.first?.allowedBundleIDs == ["com.apple.iWork.Pages"])
    }

    @Test("An empty field still offers presets")
    func emptyQuery() {
        let results = GateSuggestions.suggestions(query: "  ", presets: presets, recents: recents)
        #expect(results.contains { $0.isPreset })
    }

    @Test("Nonsense matches nothing")
    func noMatch() {
        #expect(GateSuggestions.suggestions(query: "zzzz", presets: presets, recents: recents).isEmpty)
    }

    @Test("Goal similarity powers preset learning later")
    func similarity() {
        #expect(GateSuggestions.similarity("email the landlord", "email landlord about rent") > 0.3)
        #expect(GateSuggestions.similarity("email the landlord", "write the lab report") < 0.2)
    }
}
