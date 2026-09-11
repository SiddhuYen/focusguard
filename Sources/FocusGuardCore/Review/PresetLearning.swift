import Foundation

/// A past session, flattened for pattern matching.
struct LearnedSession: Equatable, Sendable {
    var id: UUID
    var kind: SessionKind
    var goal: String
    var startedAt: Date
    var seconds: TimeInterval
    var appBundleIDs: [String]
    var domains: [String]
}

struct PresetSuggestion: Equatable, Sendable {
    var name: String
    var matchCount: Int
    var allowedBundleIDs: [String]
    var allowedSites: [SiteRule]
    var duration: TimeInterval
    var keywords: [String]

    func asPreset(id: UUID = UUID(), createdAt: Date = Date()) -> Preset {
        Preset(
            id: id,
            name: name,
            keywords: keywords,
            allowedBundleIDs: allowedBundleIDs,
            allowedSites: allowedSites,
            defaultDuration: duration,
            createdAt: createdAt
        )
    }
}

/// "You've done this three times. Save it as a preset?" (3.11). Matches on what you wrote
/// or on what you actually used, because people describe the same task differently.
enum PresetLearning {
    static func suggestion(
        for current: LearnedSession,
        history: [LearnedSession],
        presets: [Preset],
        blocklist: Blocklist,
        now: Date,
        config: FocusGuardConfig = .current
    ) -> PresetSuggestion? {
        let window = now.addingTimeInterval(-Double(config.presetSuggestionWindowDays) * 86400)
        let candidates = history.filter {
            $0.kind == .open && $0.startedAt >= window && $0.id != current.id
        }

        let matches = candidates.filter { isSimilar($0, current) } + [current]
        guard matches.count >= config.presetSuggestionCount else { return nil }

        // Apps that showed up in at least half the matching sessions are the real set.
        let threshold = max(1, matches.count / 2)
        var appCounts: [String: Int] = [:]
        var domainCounts: [String: Int] = [:]
        for match in matches {
            for app in Set(match.appBundleIDs) { appCounts[app, default: 0] += 1 }
            for domain in Set(match.domains) { domainCounts[domain, default: 0] += 1 }
        }

        let apps = appCounts.filter { $0.value >= threshold }
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map(\.key)
        guard !apps.isEmpty else { return nil }

        let sites = domainCounts.filter { $0.value >= threshold && blocklist.blocks(host: $0.key) == nil }
            .keys
            .sorted()
            .map { SiteRule.domain($0) }

        let name = suggestedName(from: matches)
        // An existing preset that already covers this is not worth suggesting again.
        let alreadyCovered = presets.contains { preset in
            preset.name.caseInsensitiveCompare(name) == .orderedSame
                || jaccard(Set(preset.allowedBundleIDs), Set(apps)) >= 0.8
        }
        guard !alreadyCovered else { return nil }

        return PresetSuggestion(
            name: name,
            matchCount: matches.count,
            allowedBundleIDs: apps,
            allowedSites: sites,
            duration: suggestedDuration(from: matches, config: config),
            keywords: Array(commonTokens(matches)).sorted()
        )
    }

    /// Builds the flattened history the matcher needs out of the log.
    static func learnedSessions(from events: [LogEvent]) -> [LearnedSession] {
        var byID: [UUID: LearnedSession] = [:]
        var order: [UUID] = []

        for event in events.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch event.type {
            case .sessionStarted:
                guard let payload = event.decode(SessionStartedPayload.self) else { continue }
                if byID[payload.sessionID] == nil { order.append(payload.sessionID) }
                byID[payload.sessionID] = LearnedSession(
                    id: payload.sessionID,
                    kind: payload.kind,
                    goal: payload.goal,
                    startedAt: event.timestamp,
                    seconds: 0,
                    appBundleIDs: payload.allowedBundleIDs,
                    domains: []
                )

            case .appsUsedSnapshot:
                guard let payload = event.decode(AppsUsedSnapshotPayload.self), var entry = byID[payload.sessionID] else { continue }
                let used = payload.apps.map(\.bundleID)
                if !used.isEmpty { entry.appBundleIDs = used }
                entry.domains = payload.domains
                byID[payload.sessionID] = entry

            case .sessionEnded:
                guard let payload = event.decode(SessionEndedPayload.self), var entry = byID[payload.sessionID] else { continue }
                entry.seconds = payload.endedAt.timeIntervalSince(payload.startedAt)
                byID[payload.sessionID] = entry

            default:
                continue
            }
        }

        return order.compactMap { byID[$0] }
    }

    // MARK: - Matching

    static func isSimilar(_ a: LearnedSession, _ b: LearnedSession) -> Bool {
        if GateSuggestions.similarity(a.goal, b.goal) >= 0.4 { return true }
        let appOverlap = jaccard(Set(a.appBundleIDs), Set(b.appBundleIDs))
        return appOverlap >= 0.6
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    private static func commonTokens(_ sessions: [LearnedSession]) -> Set<String> {
        sessions
            .map { GateSuggestions.tokens($0.goal) }
            .reduce(nil) { (result: Set<String>?, tokens) in
                result.map { $0.intersection(tokens) } ?? tokens
            } ?? []
    }

    private static func suggestedName(from sessions: [LearnedSession]) -> String {
        let shared = commonTokens(sessions)
        if !shared.isEmpty {
            return shared.sorted().joined(separator: " ").capitalized
        }
        // No shared words: name it after the shortest goal, which is usually the plainest.
        let shortest = sessions.min { $0.goal.count < $1.goal.count }?.goal ?? "Routine"
        return shortest.capitalized
    }

    private static func suggestedDuration(from sessions: [LearnedSession], config: FocusGuardConfig) -> TimeInterval {
        let durations = sessions.map(\.seconds).filter { $0 > 0 }.sorted()
        guard !durations.isEmpty else { return config.fullSessionQuickPicks[1] }
        let median = durations[durations.count / 2]
        // Round up to the next quick pick: these sessions kept running out of time.
        return config.fullSessionQuickPicks.first { $0 >= median } ?? config.fullSessionQuickPicks[1]
    }
}
