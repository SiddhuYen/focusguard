import Foundation

/// Pure URL normalization used for pinned-page matching (3.5). Keep it dumb and testable:
/// host + path, no fragment, no tracking params, with the YouTube video id preserved.
enum URLNormalizer {
    static let strippedQueryKeys: Set<String> = [
        "t", "start", "list", "index", "pp", "si", "ab_channel", "feature", "app",
        "fbclid", "gclid", "igshid", "ref", "ref_src", "spm", "s"
    ]

    /// Query keys that identify *which page* this is and must survive normalization.
    static let identifyingQueryKeys: Set<String> = ["v", "id", "q", "p", "docid", "page", "watch"]

    static func normalize(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let rawHost = components.host?.lowercased(), !rawHost.isEmpty else { return nil }

        var host = rawHost
        while host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        if host.hasPrefix("m.") { host = String(host.dropFirst(2)) }

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path = String(path.dropLast()) }

        var query = (components.queryItems ?? []).filter { item in
            let key = item.name.lowercased()
            guard !strippedQueryKeys.contains(key) else { return false }
            return identifyingQueryKeys.contains(key) || !key.hasPrefix("utm_")
        }

        // youtu.be/<id> is the same page as youtube.com/watch?v=<id>
        if host == "youtu.be" {
            let id = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !id.isEmpty {
                host = "youtube.com"
                path = "/watch"
                query = [URLQueryItem(name: "v", value: id)]
            }
        }

        // YouTube: the video id is the identity, everything else is noise.
        if host == "youtube.com", path == "/watch" {
            query = query.filter { $0.name.lowercased() == "v" }
        }

        components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query.sorted { $0.name < $1.name }
        components.fragment = nil

        return components.string
    }

    static func matches(url: URL, pinnedPattern: String) -> Bool {
        guard let normalized = normalize(url) else { return false }
        return normalized == pinnedPattern
    }

    static func host(of url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return Blocklist.normalize(host)
    }
}
