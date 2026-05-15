import Foundation

@MainActor
final class UserSettingsStore {
    private let key = "FocusGuard.UserSettings"

    func load() -> UserSettings {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let settings = try? JSONDecoder().decode(UserSettings.self, from: data)
        else {
            return UserSettings()
        }

        return settings
    }

    func save(_ settings: UserSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }

        UserDefaults.standard.set(data, forKey: key)
    }
}

@MainActor
final class SessionHistoryStore {
    private let key = "FocusGuard.SessionHistory"

    func load() -> [FocusSession] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let sessions = try? JSONDecoder().decode([FocusSession].self, from: data)
        else {
            return []
        }

        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    func append(_ session: FocusSession) {
        var sessions = load()
        sessions.insert(session, at: 0)

        if sessions.count > 100 {
            sessions = Array(sessions.prefix(100))
        }

        guard let data = try? JSONEncoder().encode(sessions) else {
            return
        }

        UserDefaults.standard.set(data, forKey: key)
    }
}
