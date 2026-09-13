import Foundation
import Testing
@testable import FocusGuardCore

@Suite("Reducer: what a session records as allowed")
struct AllowlistRecordTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let code = AppIdentity(bundleID: "com.microsoft.VSCode", name: "Code")
    let slack = AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    private func context(_ offset: TimeInterval = 0) -> ReducerContext {
        .fixed(now: start.addingTimeInterval(offset))
    }

    @Test("An app listed twice is stored once")
    func duplicatesCollapse() {
        let request = SessionRequest(
            kind: .full, goal: "debug", anchor: code,
            allowedBundleIDs: [code.bundleID, code.bundleID, "com.apple.Terminal", code.bundleID],
            duration: 25 * 60
        )
        let (state, _) = FocusReducer.reduce(AppState(), .sessionStartRequested(request), context: context())
        #expect(state.activeSession?.allowedBundleIDs == [code.bundleID, "com.apple.Terminal"])
    }

    @Test("The end-of-session record carries the final allowlist, additions included")
    func endRecordHasFinalList() {
        let request = SessionRequest(
            kind: .full, goal: "debug", anchor: code, allowedBundleIDs: [code.bundleID], duration: 25 * 60
        )
        var state = FocusReducer.reduce(AppState(), .sessionStartRequested(request), context: context()).0
        state = FocusReducer.reduce(state, .addToSessionRequested(target: .app(slack), reason: "on call"), context: context(60)).0
        let (_, effects) = FocusReducer.reduce(state, .forceEnd(outcome: .finished), context: context(120))

        let ended = effects.compactMap { effect -> SessionEndedPayload? in
            guard case .log(let event) = effect else { return nil }
            return event.decode(SessionEndedPayload.self)
        }.first
        #expect(ended?.allowedBundleIDs == [code.bundleID, slack.bundleID])
        #expect(ended?.allowedSites == [])
    }

    @Test("End records written before the allowlist field was added still decode")
    func oldRecordsDecode() throws {
        let old = Data(#"{"sessionID":"6F1B0000-0000-0000-0000-000000000001","kind":"full","goal":"x","outcome":"finished","startedAt":"2026-09-10T07:00:00.000Z","endedAt":"2026-09-10T07:25:00.000Z","violationCount":0,"additionCount":0}"#.utf8)
        let decoded = try JSONCoding.decoder().decode(SessionEndedPayload.self, from: old)
        #expect(decoded.allowedBundleIDs == nil)
        #expect(decoded.goal == "x")
    }
}
