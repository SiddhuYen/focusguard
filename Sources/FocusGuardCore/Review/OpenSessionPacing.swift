import Foundation

/// Optional friction before an open session, off by default (3.2). The worry is chaining
/// five "quick" sessions in a row, not the daily total, so the ladder is indexed by how
/// many you have started in the last hour.
enum OpenSessionPacing {
    static func countdown(
        recentStarts: [Date],
        now: Date,
        settings: Settings,
        config: FocusGuardConfig = .current
    ) -> TimeInterval {
        guard settings.openSessionCountdownEnabled else { return 0 }
        let window = now.addingTimeInterval(-config.openSessionCountdownWindow)
        let count = recentStarts.filter { $0 >= window && $0 <= now }.count
        let ladder = config.openSessionCountdownLadder
        guard !ladder.isEmpty else { return 0 }
        return ladder[min(count, ladder.count - 1)]
    }

    /// When the last few open sessions started, newest first, out of the log.
    static func recentOpenSessionStarts(from events: [LogEvent], limit: Int = 20) -> [Date] {
        events
            .filter { $0.type == .sessionStarted }
            .compactMap { event -> Date? in
                guard let payload = event.decode(SessionStartedPayload.self), payload.kind == .open else { return nil }
                return event.timestamp
            }
            .sorted(by: >)
            .prefix(limit)
            .map { $0 }
    }
}
