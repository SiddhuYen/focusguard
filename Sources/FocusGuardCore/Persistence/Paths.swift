import Foundation

/// Where everything lives on disk (4.2). Injectable so tests can run in a temp directory.
struct FocusGuardPaths: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.root = base.appendingPathComponent("FocusGuard", isDirectory: true)
    }

    var events: URL { root.appendingPathComponent("events", isDirectory: true) }
    var state: URL { root.appendingPathComponent("state", isDirectory: true) }
    var exports: URL { root.appendingPathComponent("exports", isDirectory: true) }

    var activeSession: URL { state.appendingPathComponent("active-session.json") }
    var settings: URL { state.appendingPathComponent("settings.json") }
    var presets: URL { state.appendingPathComponent("presets.json") }
    var pendingChanges: URL { state.appendingPathComponent("pending-changes.json") }
    var recentGoals: URL { state.appendingPathComponent("recent-goals.json") }
    var launchRecord: URL { state.appendingPathComponent("launches.json") }
    var heartbeat: URL { state.appendingPathComponent("heartbeat.json") }
    var hangMarker: URL { state.appendingPathComponent("hang-marker.json") }
    var migrationMarker: URL { state.appendingPathComponent("migrated.json") }

    func eventsFile(for date: Date) -> URL {
        events.appendingPathComponent("\(FocusGuardPaths.monthStamp(for: date)).jsonl")
    }

    func exportFile(for date: Date) -> URL {
        exports.appendingPathComponent("\(FocusGuardPaths.dayStamp(for: date)).json")
    }

    func createDirectories() throws {
        for directory in [root, events, state, exports] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func monthStamp(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    static func dayStamp(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

enum AtomicFile {
    /// Write to a temp file and rename, so a crash mid-write cannot truncate the original.
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try write(try JSONCoding.encoder(pretty: true).encode(value), to: url)
    }

    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder().decode(T.self, from: data)
    }
}
