import Foundation

/// Append-only JSON Lines log, one file per month. This is the source of truth for
/// history, the daily review, and the export (4.2).
final class EventLogStore: @unchecked Sendable {
    private let paths: FocusGuardPaths
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(paths: FocusGuardPaths) {
        self.paths = paths
        encoder = JSONCoding.encoder()
        decoder = JSONCoding.decoder()
        try? paths.createDirectories()
    }

    @discardableResult
    func append(_ event: LogEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard var data = try? encoder.encode(event) else { return false }
        data.append(0x0A)

        let url = paths.eventsFile(for: event.timestamp)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try FileManager.default.createDirectory(at: paths.events, withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func append<P: EventPayload>(_ payload: P, at timestamp: Date = Date()) -> Bool {
        append(LogEvent(payload, timestamp: timestamp))
    }

    func events(in month: Date) -> [LogEvent] {
        read(url: paths.eventsFile(for: month))
    }

    func events(on day: Date, calendar: Calendar = .current) -> [LogEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        var result = events(in: day).filter { $0.timestamp >= start && $0.timestamp < end }
        // A day at a month boundary can straddle two files.
        if calendar.component(.day, from: day) == 1,
           let previousMonth = calendar.date(byAdding: .day, value: -1, to: start) {
            result += events(in: previousMonth).filter { $0.timestamp >= start && $0.timestamp < end }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    func allEvents() -> [LogEvent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.events, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .flatMap { read(url: $0) }
    }

    /// Tolerates a torn final line, which is what a crash mid-append leaves behind.
    private func read(url: URL) -> [LogEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(LogEvent.self, from: Data(line))
        }
    }
}
