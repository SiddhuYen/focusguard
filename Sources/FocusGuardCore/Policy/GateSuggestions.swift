import Foundation

/// What appears under the gate's text field as you type (3.3). A suggestion supplies
/// apps, sites and a duration; the goal is always whatever is in the field.
enum Suggestion: Equatable, Sendable, Identifiable {
    case preset(Preset)
    case recent(RecentGoal)

    var id: UUID {
        switch self {
        case .preset(let preset): return preset.id
        case .recent(let recent): return recent.id
        }
    }

    var title: String {
        switch self {
        case .preset(let preset): return preset.name
        case .recent(let recent): return recent.goal
        }
    }

    var allowedBundleIDs: [String] {
        switch self {
        case .preset(let preset): return preset.allowedBundleIDs
        case .recent(let recent): return recent.allowedBundleIDs
        }
    }

    var allowedSites: [SiteRule] {
        switch self {
        case .preset(let preset): return preset.allowedSites
        case .recent(let recent): return recent.allowedSites
        }
    }

    var duration: TimeInterval? {
        switch self {
        case .preset(let preset): return preset.defaultDuration
        case .recent(let recent): return recent.duration
        }
    }

    var presetID: UUID? {
        if case .preset(let preset) = self { return preset.id }
        return nil
    }

    var isPreset: Bool {
        if case .preset = self { return true }
        return false
    }
}

enum GateSuggestions {
    /// Presets first (they are deliberate), then recents by how recently they were used.
    /// A prefix match always outranks a match in the middle of a word.
    static func suggestions(
        query: String,
        presets: [Preset],
        recents: [RecentGoal],
        limit: Int = 6
    ) -> [Suggestion] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            let recentSuggestions = recents
                .sorted { $0.lastUsed > $1.lastUsed }
                .prefix(limit / 2)
                .map(Suggestion.recent)
            return Array((presets.sorted { $0.name < $1.name }.map(Suggestion.preset) + recentSuggestions).prefix(limit))
        }

        var scored: [(Suggestion, Int)] = []

        for preset in presets {
            guard let score = score(query: query, name: preset.name, keywords: preset.keywords) else { continue }
            scored.append((.preset(preset), score + 100))
        }

        for recent in recents {
            guard let score = score(query: query, name: recent.goal, keywords: []) else { continue }
            let freshness = max(0, 30 - Int(Date().timeIntervalSince(recent.lastUsed) / 86400))
            scored.append((.recent(recent), score + freshness))
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private static func score(query: String, name: String, keywords: [String]) -> Int? {
        let name = name.lowercased()
        if name.hasPrefix(query) { return 60 }
        if name.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 40 }
        if name.contains(query) { return 20 }
        for keyword in keywords {
            let keyword = keyword.lowercased()
            if keyword.hasPrefix(query) { return 30 }
            if keyword.contains(query) { return 10 }
        }
        return nil
    }

    /// Normalized tokens, shared by suggestion ranking and Phase 3's preset learning.
    static func tokens(_ goal: String) -> Set<String> {
        let stopWords: Set<String> = ["the", "a", "an", "my", "to", "for", "on", "in", "of", "and", "some"]
        return Set(
            goal.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        )
    }

    static func similarity(_ first: String, _ second: String) -> Double {
        let a = tokens(first)
        let b = tokens(second)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }
}
