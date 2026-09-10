import Foundation
import Testing
@testable import FocusGuardCore

@Suite("Site rules from what you type")
struct SiteRuleInputTests {
    private let blocklist = Blocklist(domains: ["youtube.com", "reddit.com"])

    @Test("A plain domain becomes a domain rule")
    func domainRule() {
        let result = SiteRuleInput.make(from: " https://www.Apple.com/docs ", scope: .domain, blocklist: blocklist)
        #expect(result == .rule(SiteRule(scope: .domain, pattern: "apple.com")))
    }

    @Test("A blocked domain can never be allowlisted, only pinned")
    func blockedDomainRefused() {
        let result = SiteRuleInput.make(from: "youtube.com", scope: .domain, blocklist: blocklist)
        guard case .rejected(let reason) = result else {
            Issue.record("a blocked domain must be refused")
            return
        }
        #expect(reason.contains("youtube.com"))
        #expect(reason.contains("pin"))
    }

    @Test("A pin is an exact page, normalized")
    func pinnedPage() {
        let result = SiteRuleInput.make(
            from: "https://www.youtube.com/watch?v=lecture1&t=42",
            scope: .pinnedPage,
            blocklist: blocklist
        )
        #expect(result == .rule(SiteRule(scope: .pinnedPage, pattern: "https://youtube.com/watch?v=lecture1")))
    }

    @Test("A bare blocked domain cannot sneak in as a pin")
    func barePinRefused() {
        let result = SiteRuleInput.make(from: "https://youtube.com", scope: .pinnedPage, blocklist: blocklist)
        guard case .rejected(let reason) = result else {
            Issue.record("a bare domain is not a page")
            return
        }
        #expect(reason.contains("stays blocked"))
    }

    @Test("Nonsense is refused rather than guessed at")
    func nonsense() {
        if case .rule = SiteRuleInput.make(from: "not a site", scope: .domain, blocklist: blocklist) {
            Issue.record("should not have parsed")
        }
        if case .rule = SiteRuleInput.make(from: "   ", scope: .pinnedPage, blocklist: blocklist) {
            Issue.record("should not have parsed")
        }
    }
}

@Suite("Pins never outlive their session")
struct PinPortabilityTests {
    private let blocklist = Blocklist(domains: ["youtube.com"])

    @Test("A pin on a blocked domain is stripped from presets and recents")
    func blockedPinIsNotPortable() {
        let sites: [SiteRule] = [
            SiteRule(scope: .pinnedPage, pattern: "https://youtube.com/watch?v=lecture1"),
            SiteRule(scope: .pinnedPage, pattern: "https://developer.apple.com/videos/wwdc"),
            SiteRule(scope: .domain, pattern: "developer.apple.com")
        ]
        let portable = FocusReducer.portableSites(sites, blocklist: blocklist)
        #expect(portable.count == 2)
        #expect(!portable.contains { $0.pattern.contains("youtube") })
    }

    @Test("Saving a preset drops the blocked-domain pin")
    func presetIsCleaned() {
        var state = AppState()
        state.settings.blocklist = blocklist
        let preset = Preset(
            name: "Lecture",
            allowedBundleIDs: [KnownBrowser.safari.rawValue],
            allowedSites: [
                SiteRule(scope: .pinnedPage, pattern: "https://youtube.com/watch?v=lecture1"),
                SiteRule(scope: .domain, pattern: "developer.apple.com")
            ]
        )
        let (next, _) = FocusReducer.reduce(state, .presetCreated(preset, source: "review"), context: .fixed(now: Date()))
        #expect(next.presets.first?.allowedSites == [SiteRule(scope: .domain, pattern: "developer.apple.com")])
    }
}

@Suite("Fail-closed URL reading")
struct FailClosedTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let safari = AppIdentity(bundleID: KnownBrowser.safari.rawValue, name: "Safari")
    let firefox = AppIdentity(bundleID: KnownBrowser.firefox.rawValue, name: "Firefox")

    private func session(with browser: AppIdentity) -> AppState {
        var state = AppState()
        state.frontmostApp = browser
        let request = SessionRequest(
            kind: .full, goal: "research", anchor: browser,
            allowedBundleIDs: [browser.bundleID], duration: 25 * 60
        )
        return FocusReducer.reduce(state, .sessionStartRequested(request), context: .fixed(now: start)).0
    }

    @Test("Five unreadable polls in an AppleScript browser is a violation")
    func appleScriptBrowser() {
        let state = session(with: safari)
        let (below, _) = FocusReducer.reduce(state, .urlReadFailed(browser: safari, consecutiveFailures: 4), context: .fixed(now: start))
        #expect(!isIntervention(below.phase))

        let (at, _) = FocusReducer.reduce(state, .urlReadFailed(browser: safari, consecutiveFailures: 5), context: .fixed(now: start))
        guard case .intervention(_, let violation) = at.phase else {
            Issue.record("expected the can't-verify intervention")
            return
        }
        #expect(violation.kind == .unverifiableURL(browser: safari.bundleID))
    }

    @Test("Firefox gets more rope, because its reads come from the accessibility tree")
    func firefoxThreshold() {
        let state = session(with: firefox)
        let (five, _) = FocusReducer.reduce(state, .urlReadFailed(browser: firefox, consecutiveFailures: 5), context: .fixed(now: start))
        #expect(!isIntervention(five.phase), "five flaky reads is not evidence in Firefox")

        let (twelve, _) = FocusReducer.reduce(state, .urlReadFailed(browser: firefox, consecutiveFailures: 12), context: .fixed(now: start))
        #expect(isIntervention(twelve.phase))
    }

    @Test("Turning fail-closed off silences it entirely")
    func disabled() {
        var state = session(with: safari)
        state.settings.failClosedURLReading = false
        let (next, _) = FocusReducer.reduce(state, .urlReadFailed(browser: safari, consecutiveFailures: 99), context: .fixed(now: start))
        #expect(!isIntervention(next.phase))
    }

    @Test("Enabling fail-closed is tightening; disabling it waits 24 hours")
    func classification() {
        #expect(SettingsChange.failClosedURLReadingEnabled.direction == .tightening)
        #expect(SettingsChange.failClosedURLReadingDisabled.direction == .loosening)
    }

    private func isIntervention(_ phase: AppPhase) -> Bool {
        if case .intervention = phase { return true }
        return false
    }
}
