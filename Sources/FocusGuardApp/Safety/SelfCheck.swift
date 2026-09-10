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
        check("review panel is on screen", panelCount(minWidth: 500) >= 1)

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

        report()
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
