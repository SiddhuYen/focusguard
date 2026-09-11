import Foundation
import Testing
@testable import FocusGuardCore

@Suite("Reducer: the review cannot be skipped")
struct ReviewUnskippableTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let xcode = AppIdentity(bundleID: "com.apple.dt.Xcode", name: "Xcode")
    let slack = AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    private func context(_ offset: TimeInterval = 0) -> ReducerContext {
        .fixed(now: start.addingTimeInterval(offset))
    }

    private func inSession() -> AppState {
        var state = AppState()
        state.frontmostApp = xcode
        let request = SessionRequest(
            kind: .full, goal: "ship the gate", anchor: xcode,
            allowedBundleIDs: [xcode.bundleID], duration: 25 * 60
        )
        return FocusReducer.reduce(state, .sessionStartRequested(request), context: context()).0
    }

    private func timedOut() -> (AppState, [Effect]) {
        FocusReducer.reduce(inSession(), .tick(idleSeconds: 0), context: context(25 * 60 + 1))
    }

    @Test("Time running out covers the screen the way the gate does")
    func timeUpLocksTheScreen() {
        let (state, effects) = timedOut()
        guard case .review = state.phase else { Issue.record("expected the review"); return }
        #expect(effects.contains { if case .showReview = $0 { return true } else { return false } })
        #expect(effects.contains(.setKiosk(true)))
    }

    @Test("Switching to another app during the review brings it straight back")
    func cannotClickAway() {
        let review = timedOut().0
        let (next, effects) = FocusReducer.reduce(review, .appActivated(slack), context: context(25 * 60 + 5))
        guard case .review = next.phase else { Issue.record("must still be the review"); return }
        #expect(effects.contains(.bringReviewToFront))
    }

    @Test("Extending hands the screen back")
    func extendReleases() {
        let review = timedOut().0
        let (next, effects) = FocusReducer.reduce(review, .reviewExtended(by: 10 * 60), context: context(25 * 60 + 5))
        #expect(next.phase.isEnforcing)
        #expect(effects.contains(.dismissReview))
        #expect(effects.contains(.setKiosk(false)))
    }

    @Test("Answering goes straight to the gate without releasing kiosk in between")
    func answerKeepsKiosk() {
        let review = timedOut().0
        let (next, effects) = FocusReducer.reduce(review, .reviewAnswered(finished: true), context: context(25 * 60 + 5))
        #expect(next.isGated)
        #expect(!effects.contains(.setKiosk(false)), "no gap where the Mac is usable between review and gate")
        #expect(effects.contains(.setKiosk(true)))
    }

    @Test("Being away when time runs out still waits until you are back")
    func idleStillWaits() {
        let (state, effects) = FocusReducer.reduce(inSession(), .tick(idleSeconds: 20 * 60), context: context(25 * 60 + 1))
        if case .review = state.phase { Issue.record("no review for an empty chair") }
        #expect(!effects.contains(.setKiosk(true)))
    }
}
