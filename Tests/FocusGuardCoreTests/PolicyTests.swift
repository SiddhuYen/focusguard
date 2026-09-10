import Foundation
import Testing
@testable import FocusGuardCore

@Suite("Blocklist matching")
struct BlocklistTests {
    @Test("Normalization strips scheme, path, port and www")
    func normalization() {
        #expect(Blocklist.normalize("  HTTPS://WWW.YouTube.com/watch?v=1 ") == "youtube.com")
        #expect(Blocklist.normalize("m.youtube.com") == "m.youtube.com")
        #expect(Blocklist.normalize("example.com:8443") == "example.com")
        #expect(Blocklist.normalize("www.www.reddit.com") == "reddit.com")
    }

    @Test("Blocks the domain and every subdomain")
    func subdomains() {
        let blocklist = Blocklist(domains: ["youtube.com", "www.instagram.com"])
        #expect(blocklist.blocks(host: "youtube.com") == "youtube.com")
        #expect(blocklist.blocks(host: "www.youtube.com") == "youtube.com")
        #expect(blocklist.blocks(host: "m.youtube.com") == "youtube.com")
        #expect(blocklist.blocks(host: "music.youtube.com") == "youtube.com")
        // "www." entries collapse to the bare domain, so the bare domain is blocked too.
        #expect(blocklist.blocks(host: "instagram.com") == "instagram.com")
        #expect(blocklist.blocks(host: "notyoutube.com") == nil)
        #expect(blocklist.blocks(host: "youtube.com.evil.test") == nil)
    }

    @Test("A multi-label host is not reduced to its last two labels")
    func multiLabelTLD() {
        // v1 compared the last two labels, so any *.co.uk host matched a "co.uk" entry.
        let blocklist = Blocklist(domains: ["bbc.co.uk"])
        #expect(blocklist.blocks(host: "www.bbc.co.uk") == "bbc.co.uk")
        #expect(blocklist.blocks(host: "theguardian.co.uk") == nil)
    }

    @Test("Canonicalize dedupes and drops empties")
    func canonicalize() {
        let blocklist = Blocklist(domains: ["youtube.com", "www.youtube.com", "  ", "YOUTUBE.com"])
        #expect(blocklist.domains == ["youtube.com"])
    }
}

@Suite("URL normalization for pins")
struct URLNormalizerTests {
    private func normalize(_ string: String) -> String? {
        URL(string: string).flatMap(URLNormalizer.normalize)
    }

    @Test("Tracking params and fragments are dropped, the video id survives")
    func youtube() {
        let pinned = normalize("https://www.youtube.com/watch?v=abc123&t=42s&list=PL9&pp=xyz")
        #expect(pinned == "https://youtube.com/watch?v=abc123")
        #expect(normalize("https://m.youtube.com/watch?v=abc123#comments") == pinned)
        #expect(normalize("https://youtu.be/abc123?t=90") == pinned)
        #expect(normalize("https://www.youtube.com/watch?v=different") != pinned)
    }

    @Test("Trailing slashes and utm params do not change identity")
    func generalPages() {
        let a = normalize("https://example.com/docs/guide/?utm_source=x")
        let b = normalize("https://www.example.com/docs/guide")
        #expect(a == b)
    }

    @Test("Different paths are different pages")
    func distinctPages() {
        #expect(normalize("https://example.com/a") != normalize("https://example.com/b"))
    }
}

@Suite("Allowlist decisions")
struct AllowlistTests {
    private let baseline = BaselineAllowlist(selfBundleID: "app.focusguard.mvp")

    private func session(kind: SessionKind = .full, allowed: [String] = ["com.apple.dt.Xcode"], sites: [SiteRule] = []) -> Session {
        Session(
            kind: kind,
            goal: "ship the gate",
            anchor: AppIdentity(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
            allowedBundleIDs: allowed,
            allowedSites: sites
        )
    }

    @Test("Finder and Focus Guard itself never count as violations")
    func baselineApps() {
        let session = session()
        #expect(Allowlist.decide(app: AppIdentity(bundleID: "com.apple.finder", name: "Finder"), session: session, baseline: baseline).isAllowed)
        #expect(Allowlist.decide(app: AppIdentity(bundleID: "app.focusguard.mvp", name: "Focus Guard"), session: session, baseline: baseline).isAllowed)
        #expect(Allowlist.decide(app: AppIdentity(bundleID: "com.apple.SecurityAgent", name: "SecurityAgent"), session: session, baseline: baseline).isAllowed)
    }

    @Test("A non-allowed app is an app violation in a full session")
    func appViolation() {
        let slack = AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let decision = Allowlist.decide(app: slack, session: session(), baseline: baseline)
        #expect(decision == .violation(.app(slack)))
    }

    @Test("Open sessions allow any app")
    func openSessionApps() {
        let slack = AppIdentity(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        #expect(Allowlist.decide(app: slack, session: session(kind: .open, allowed: []), baseline: baseline).isAllowed)
    }

    @Test("Blocked domains are blocked in open sessions too")
    func blockedInOpenSession() {
        let url = URL(string: "https://www.youtube.com/watch?v=abc")!
        let decision = Allowlist.decide(
            url: url,
            in: AppIdentity(bundleID: KnownBrowser.safari.rawValue, name: "Safari"),
            session: session(kind: .open, allowed: []),
            blocklist: Blocklist(domains: ["youtube.com"])
        )
        #expect(decision == .violation(.blockedSite(domain: "youtube.com", url: url.absoluteString)))
    }

    @Test("A pinned page on a blocked domain is allowed in a full session, the rest of the domain is not")
    func pinnedPageOnBlockedDomain() {
        let pin = SiteRule(scope: .pinnedPage, pattern: "https://youtube.com/watch?v=lecture1")
        let session = session(kind: .full, allowed: [KnownBrowser.safari.rawValue], sites: [pin])
        let browser = AppIdentity(bundleID: KnownBrowser.safari.rawValue, name: "Safari")
        let blocklist = Blocklist(domains: ["youtube.com"])

        let lecture = URL(string: "https://www.youtube.com/watch?v=lecture1&t=30")!
        #expect(Allowlist.decide(url: lecture, in: browser, session: session, blocklist: blocklist).isAllowed)

        let autoplay = URL(string: "https://www.youtube.com/watch?v=nextvideo")!
        #expect(Allowlist.decide(url: autoplay, in: browser, session: session, blocklist: blocklist)
            == .violation(.blockedSite(domain: "youtube.com", url: autoplay.absoluteString)))

        let home = URL(string: "https://www.youtube.com/")!
        #expect(!Allowlist.decide(url: home, in: browser, session: session, blocklist: blocklist).isAllowed)
    }

    @Test("A pin on a blocked domain does not help an open session")
    func pinnedPageInOpenSession() {
        let pin = SiteRule(scope: .pinnedPage, pattern: "https://youtube.com/watch?v=lecture1")
        let session = session(kind: .open, allowed: [], sites: [pin])
        let url = URL(string: "https://youtube.com/watch?v=lecture1")!
        let decision = Allowlist.decide(
            url: url,
            in: AppIdentity(bundleID: KnownBrowser.safari.rawValue, name: "Safari"),
            session: session,
            blocklist: Blocklist(domains: ["youtube.com"])
        )
        #expect(decision == .violation(.blockedSite(domain: "youtube.com", url: url.absoluteString)))
    }

    @Test("A full session with a site list rejects everything else")
    func siteAllowlist() {
        let session = session(kind: .full, allowed: [KnownBrowser.chrome.rawValue], sites: [.domain("developer.apple.com")])
        let browser = AppIdentity(bundleID: KnownBrowser.chrome.rawValue, name: "Chrome")
        let blocklist = Blocklist(domains: [])

        #expect(Allowlist.decide(url: URL(string: "https://developer.apple.com/documentation")!, in: browser, session: session, blocklist: blocklist).isAllowed)
        let hn = URL(string: "https://news.ycombinator.com")!
        #expect(Allowlist.decide(url: hn, in: browser, session: session, blocklist: blocklist)
            == .violation(.unlistedSite(host: "news.ycombinator.com", url: hn.absoluteString)))
    }

    @Test("Browsers we cannot read cannot be allowlisted")
    func unreadableBrowsers() {
        #expect(Allowlist.canAllowlist(bundleID: KnownBrowser.safari.rawValue))
        #expect(Allowlist.canAllowlist(bundleID: "com.apple.dt.Xcode"))
        #expect(!Allowlist.canAllowlist(bundleID: "ai.perplexity.comet"))
    }
}
