import Foundation

/// A site the session allows. `domain` matches the host or any subdomain; `pinnedPage`
/// matches one normalized URL only (3.5). Pin enforcement lands in Phase 2.
struct SiteRule: Codable, Equatable, Hashable, Sendable {
    enum Scope: String, Codable, Equatable, Hashable, Sendable {
        case domain
        case pinnedPage
    }

    var scope: Scope
    /// Normalized domain (no scheme, no leading "www.") or normalized page URL.
    var pattern: String

    static func domain(_ value: String) -> SiteRule {
        SiteRule(scope: .domain, pattern: Blocklist.normalize(value))
    }
}

/// Domains blocked in every session type, always. Never allowlistable (Section 2).
struct Blocklist: Codable, Equatable, Sendable {
    private(set) var domains: [String]

    init(domains: [String] = Blocklist.seeded) {
        self.domains = Blocklist.canonicalize(domains)
    }

    static let seeded = [
        "instagram.com", "youtube.com", "tiktok.com", "snapchat.com",
        "twitter.com", "x.com", "reddit.com", "facebook.com", "twitch.tv", "netflix.com"
    ]

    /// Lowercase, trim, drop a scheme or path if one was pasted in, and drop a leading
    /// "www." so that entering "www.youtube.com" also blocks "youtube.com".
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        if let at = value.lastIndex(of: "@") { value = String(value[value.index(after: at)...]) }
        if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        while value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        return value
    }

    static func canonicalize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.map(normalize).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    mutating func add(_ domain: String) {
        domains = Blocklist.canonicalize(domains + [domain])
    }

    mutating func remove(_ domain: String) {
        let target = Blocklist.normalize(domain)
        domains.removeAll { $0 == target }
    }

    func blocks(host: String) -> String? {
        let host = Blocklist.normalize(host)
        guard !host.isEmpty else { return nil }
        return domains.first { host == $0 || host.hasSuffix("." + $0) }
    }

    func blocks(url: URL) -> String? {
        guard let host = url.host else { return nil }
        return blocks(host: host)
    }
}

struct Preset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var keywords: [String]
    var allowedBundleIDs: [String]
    var allowedSites: [SiteRule]
    var defaultDuration: TimeInterval
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        keywords: [String] = [],
        allowedBundleIDs: [String] = [],
        allowedSites: [SiteRule] = [],
        defaultDuration: TimeInterval = 25 * 60,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.keywords = keywords
        self.allowedBundleIDs = allowedBundleIDs
        self.allowedSites = allowedSites
        self.defaultDuration = defaultDuration
        self.createdAt = createdAt
    }

    func matches(query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return false }
        if name.lowercased().contains(query) { return true }
        return keywords.contains { $0.lowercased().contains(query) }
    }
}
