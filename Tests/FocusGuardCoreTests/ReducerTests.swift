import Foundation
import Testing
@testable import FocusGuardCore

@Suite("Reducer")
struct ReducerTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let xcode = AppIdentity(bundleID: "com.apple.dt.Xcode", name: "Xcode")
    let slack = AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    let safari = AppIdentity(bundleID: KnownBrowser.safari.rawValue, name: "Safari")

    private func context(_ offset: TimeInterval = 0) -> ReducerContext {
        .fixed(now: start.addingTimeInterval(offset))
    }

    private func started(kind: SessionKind = .full, allowed: [String]? = nil) -> AppState {
        var state = AppState()
        state.settings.blocklist = Blocklist(domains: ["youtube.com"])
        state.frontmostApp = xcode
        let request = SessionRequest(
            kind: kind,
            goal: "ship the gate",
            anchor: xcode,
            allowedBundleIDs: allowed ?? [xcode.bundleID],
            duration: 25 * 60
        )
        let (next, _) = FocusReducer.reduce(state, .sessionStartRequested(request), context: context())
        return next
    }

    @Test("Starting a session logs it, persists it, and sets a planned end")
    func startSession() {
        let state = started()
        guard case .session(let session) = state.phase else { Issue.record("expected a session"); return }
        #expect(session.goal == "ship the gate")
        #expect(session.allowedBundleIDs == [xcode.bundleID])
        #expect(session.plannedEnd == start.addingTimeInterval(25 * 60))
        #expect(!state.canStartSession)
    }

    @Test("A full session caps duration at the configured maximum")
    func durationCap() {
        var state = AppState()
        state.settings.maxFullSessionLength = 3600
        let request = SessionRequest(kind: .full, goal: "long", anchor: xcode, allowedBundleIDs: [], duration: 6 * 3600)
        let (next, _) = FocusReducer.reduce(state, .sessionStartRequested(request), context: context())
        #expect(next.activeSession?.plannedEnd == start.addingTimeInterval(3600))
    }

    @Test("Switching to a non-allowed app opens an intervention and records the violation")
    func appViolation() {
        let (next, effects) = FocusReducer.reduce(started(), .appActivated(slack), context: context(60))
        guard case .intervention(let session, let violation) = next.phase else {
            Issue.record("expected an intervention")
            return
        }
        #expect(session.violations.count == 1)
        #expect(violation.kind == .app(slack))
        #expect(effects.contains { if case .showIntervention = $0 { return true } else { return false } })
        #expect(effects.contains { if case .persistSession(.some) = $0 { return true } else { return false } })
    }

    @Test("Clicking Return goes back to the session and reactivates the anchor app")
    func returnToApp() {
        let (intervened, _) = FocusReducer.reduce(started(), .appActivated(slack), context: context(60))
        let (next, effects) = FocusReducer.reduce(intervened, .returnRequested, context: context(70))
        #expect(next.phase.isEnforcing)
        if case .intervention = next.phase { Issue.record("should have left the intervention") }
        #expect(effects.contains(.activateApp(bundleID: xcode.bundleID)))
        #expect(effects.contains(.dismissIntervention))
    }

    @Test("Add to this session widens the allowlist for this session only")
    func addToSession() {
        let (intervened, _) = FocusReducer.reduce(started(), .appActivated(slack), context: context(60))
        let (next, effects) = FocusReducer.reduce(
            intervened,
            .addToSessionRequested(target: .app(slack), reason: "answering the on-call ping"),
            context: context(65)
        )
        #expect(next.activeSession?.allowedBundleIDs.contains(slack.bundleID) == true)
        #expect(next.activeSession?.additions.first?.reason == "answering the on-call ping")
        #expect(effects.contains(.dismissIntervention))

        // Ending the session must not leak the addition into the next one.
        let (ended, _) = FocusReducer.reduce(next, .endRequested(outcome: .finished), context: context(70))
        let (fresh, _) = FocusReducer.reduce(
            ended,
            .sessionStartRequested(SessionRequest(kind: .full, goal: "next", anchor: xcode, allowedBundleIDs: [xcode.bundleID], duration: 600)),
            context: context(80)
        )
        #expect(fresh.activeSession?.allowedBundleIDs.contains(slack.bundleID) == false)
    }

    @Test("A blocked domain can never be added to a session")
    func blockedSiteCannotBeAdded() {
        var state = started(allowed: [safari.bundleID])
        state.frontmostApp = safari
        let url = URL(string: "https://www.youtube.com/watch?v=abc")!
        let (intervened, _) = FocusReducer.reduce(state, .urlObserved(browser: safari, url: url), context: context(30))
        guard case .intervention(_, let violation) = intervened.phase else {
            Issue.record("expected an intervention")
            return
        }
        #expect(!violation.isAddable)

        let (after, effects) = FocusReducer.reduce(
            intervened,
            .addToSessionRequested(target: .site(.domain("youtube.com")), reason: "just this once"),
            context: context(35)
        )
        if case .intervention = after.phase {} else { Issue.record("must stay in the intervention") }
        #expect(!effects.contains(.dismissIntervention))
    }

    @Test("URL polling keeps following the browser through an intervention")
    func urlMonitoringSurvivesViolation() {
        var state = started(allowed: [safari.bundleID])
        state.frontmostApp = safari

        let url = URL(string: "https://www.youtube.com/watch?v=abc")!
        let (intervened, violationEffects) = FocusReducer.reduce(state, .urlObserved(browser: safari, url: url), context: context(30))
        // v1 stopped polling here and never restarted, so the rest of the session was unpoliced.
        #expect(violationEffects.contains(.monitorURLs(safari)))

        let (returned, returnEffects) = FocusReducer.reduce(intervened, .returnRequested, context: context(40))
        #expect(returnEffects.contains(.monitorURLs(safari)))

        let (idle, idleEffects) = FocusReducer.reduce(returned, .endRequested(outcome: .finished), context: context(50))
        #expect(idle.isIdle)
        #expect(idleEffects.contains(.monitorURLs(nil)))
    }

    @Test("Exactly one monitoring effect is emitted per event")
    func singleMonitoringEffect() {
        let (_, effects) = FocusReducer.reduce(started(), .appActivated(slack), context: context(60))
        let monitoring = effects.filter { if case .monitorURLs = $0 { return true } else { return false } }
        #expect(monitoring.count == 1)
    }

    @Test("Ending a session logs the outcome and clears persisted state")
    func endSession() {
        let (next, effects) = FocusReducer.reduce(started(), .endRequested(outcome: .finished), context: context(1200))
        #expect(next.isIdle)
        #expect(effects.contains(.persistSession(nil)))
        let ended = effects.compactMap { effect -> SessionEndedPayload? in
            guard case .log(let event) = effect else { return nil }
            return event.decode(SessionEndedPayload.self)
        }
        #expect(ended.first?.outcome == .finished)
    }

    @Test("Launching with a persisted session resumes it instead of starting over")
    func resumeSession() {
        let session = started().activeSession!
        let (next, _) = FocusReducer.reduce(AppState(), .launched(restoredSession: session, safeMode: nil), context: context(90))
        #expect(next.activeSession?.id == session.id)
    }

    @Test("Launching in safe mode enters safe mode and logs it")
    func safeModeLaunch() {
        let entry = SafeModeEntry(reason: .crashLoop, detail: "3 unclean exits within 120s of launch")
        let (next, effects) = FocusReducer.reduce(AppState(), .launched(restoredSession: nil, safeMode: entry), context: context())
        #expect(next.phase == .safeMode(.crashLoop))
        let logged = effects.compactMap { effect -> SafeModePayload? in
            guard case .log(let event) = effect else { return nil }
            return event.decode(SafeModePayload.self)
        }
        #expect(logged.first?.reason == .crashLoop)
        #expect(logged.first?.detail == "3 unclean exits within 120s of launch")
    }

    @Test("Apps used are credited only past the 10 second threshold")
    func appsUsedThreshold() {
        var state = started(allowed: [xcode.bundleID, slack.bundleID])
        state.frontmostSince = start
        let (quick, _) = FocusReducer.reduce(state, .appActivated(slack), context: context(5))
        #expect(quick.activeSession?.appsUsed.isEmpty == true)

        let (slow, _) = FocusReducer.reduce(state, .appActivated(slack), context: context(30))
        #expect(slow.activeSession?.appsUsed.first?.bundleID == xcode.bundleID)
        #expect(slow.activeSession?.appsUsed.first?.seconds == 30)
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
        #expect(next.pendingChanges[0].effectiveAt == start.addingTimeInterval(24 * 3600))
        #expect(effects.contains { if case .persistPendingChanges = $0 { return true } else { return false } })
    }

    @Test("A due pending change applies on the next tick")
    func pendingChangeApplies() {
        var edited = AppState().settings
        edited.blocklist.remove("reddit.com")
        let (scheduled, _) = FocusReducer.reduce(AppState(), .settingsEdited(edited), context: context())

        let (tooEarly, _) = FocusReducer.reduce(scheduled, .tick, context: context(3600))
        #expect(tooEarly.pendingChanges.count == 1)

        let (applied, effects) = FocusReducer.reduce(scheduled, .tick, context: context(24 * 3600 + 1))
        #expect(applied.pendingChanges.isEmpty)
        #expect(applied.settings.blocklist.blocks(host: "reddit.com") == nil)
        #expect(effects.contains { if case .persistSettings = $0 { return true } else { return false } })
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
        unhealthy.detail = "AXIsProcessTrusted() returned false"

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

    @Test("Unreadable URLs only bite once fail-closed is switched on")
    func failClosed() {
        var state = started(allowed: [safari.bundleID])
        state.frontmostApp = safari

        let (ignored, _) = FocusReducer.reduce(state, .urlReadFailed(browser: safari, consecutiveFailures: 9), context: context(30))
        #expect(!isIntervention(ignored.phase))

        state.settings.failClosedURLReading = true
        let (below, _) = FocusReducer.reduce(state, .urlReadFailed(browser: safari, consecutiveFailures: 4), context: context(30))
        #expect(!isIntervention(below.phase))

        let (blocked, _) = FocusReducer.reduce(state, .urlReadFailed(browser: safari, consecutiveFailures: 5), context: context(30))
        #expect(isIntervention(blocked.phase))
    }

    @Test("Timed escape still works in Phase 0 and expires back into the session")
    func legacyEscape() {
        let (intervened, _) = FocusReducer.reduce(started(), .appActivated(slack), context: context(60))
        let (escaped, effects) = FocusReducer.reduce(intervened, .escapeRequested(duration: 60, reason: nil), context: context(65))
        guard case .gracePeriod(_, let until) = escaped.phase else { Issue.record("expected a grace period"); return }
        #expect(until == start.addingTimeInterval(125))
        #expect(effects.contains(.scheduleEscapeEnd(at: until)))

        let (expired, _) = FocusReducer.reduce(escaped, .tick, context: context(130))
        #expect(isIntervention(expired.phase), "still on Slack when the escape ends")
    }

    private func isIntervention(_ phase: AppPhase) -> Bool {
        if case .intervention = phase { return true }
        return false
    }
}
