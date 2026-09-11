import Foundation
import Testing
@testable import FocusGuardCore

@Suite("Single instance")
struct InstancePolicyTests {
    @Test("The launch agent is recognised by its job label, and nothing else is")
    func roles() {
        #expect(InstancePolicy.role(xpcServiceName: "app.focusguard.mvp.agent") == .agent)
        #expect(InstancePolicy.role(xpcServiceName: "application.app.focusguard.mvp.88199362.88199367") == .manual)
        #expect(InstancePolicy.role(xpcServiceName: nil) == .manual)
    }

    @Test("Whoever gets the lock carries on")
    func lockWins() {
        #expect(InstancePolicy.decide(role: .manual, lockAcquired: true, yieldAlreadyRequested: false) == .proceed)
        #expect(InstancePolicy.decide(role: .agent, lockAcquired: true, yieldAlreadyRequested: false) == .proceed)
    }

    @Test("A hand-opened copy never becomes a second gate")
    func manualDefers() {
        #expect(InstancePolicy.decide(role: .manual, lockAcquired: false, yieldAlreadyRequested: false) == .activateExistingAndExit)
    }

    @Test("The agent asks once, then leaves rather than doubling up")
    func agentAsksOnce() {
        #expect(InstancePolicy.decide(role: .agent, lockAcquired: false, yieldAlreadyRequested: false) == .requestYieldThenRetry)
        #expect(InstancePolicy.decide(role: .agent, lockAcquired: false, yieldAlreadyRequested: true) == .exitQuietly)
    }

    @Test("Only a hand-opened copy on the same data directory steps aside")
    func yieldRules() {
        let own = "/Users/x/Library/Application Support/FocusGuard/state/instance.lock"
        #expect(InstancePolicy.shouldYield(role: .manual, requestLockPath: own, ownLockPath: own))
        #expect(!InstancePolicy.shouldYield(role: .agent, requestLockPath: own, ownLockPath: own), "the agent never yields")
        #expect(!InstancePolicy.shouldYield(role: .manual, requestLockPath: "/tmp/fg-check/state/instance.lock", ownLockPath: own),
                "a self-check in a scratch directory must not be told to quit")
        #expect(!InstancePolicy.shouldYield(role: .manual, requestLockPath: nil, ownLockPath: own))
    }
}
