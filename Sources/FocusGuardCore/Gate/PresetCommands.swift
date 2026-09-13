import Foundation

/// Presets as their own slash commands: a preset named "Deep work" answers to /deepwork.
enum PresetCommands {
    /// Verbs the gate already owns. A preset can never shadow one of these.
    static let reserved: Set<String> = [
        "g", "goal", "a", "add", "+", "app", "apps", "t", "time", "min", "mins",
        "s", "site", "sites", "pin", "start", "go", "run", "q", "quick", "5",
        "p", "preset", "presets", "save", "status", "today", "h", "help", "?",
        "override", "emergency", "sleep", "done", "y", "yes", "n", "no",
        "c", "cancel", "clear", "exit", "quit"
    ]

    /// "Deep work!" → "deepwork". Letters and digits only, so a name types the same way
    /// however it was capitalised or punctuated.
    static func slug(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The command a preset answers to, or nil when its name collides with a built-in or
    /// has nothing typable in it.
    static func command(for preset: Preset) -> String? {
        let slug = slug(preset.name)
        guard !slug.isEmpty, !reserved.contains(slug) else { return nil }
        return "/" + slug
    }

    struct Match: Equatable, Sendable {
        var preset: Preset
        var goal: String?
    }

    /// `/email reply to the landlord` → the Email preset, with that goal. Exact names only:
    /// a command that starts a session must never fire on a guessed prefix.
    static func resolve(_ raw: String, presets: [Preset]) -> Match? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("/") else { return nil }
        let parts = line.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let verb = parts.first.map({ String($0).lowercased() }), !reserved.contains(verb) else { return nil }

        let matches = presets.filter { command(for: $0) == "/" + verb }
        guard matches.count == 1, let preset = matches.first else { return nil }

        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return Match(preset: preset, goal: rest.isEmpty ? nil : rest)
    }

    /// Why a name can't be saved, or nil if it can: it has to produce a command, not a
    /// built-in one, and not one another preset already has.
    static func problem(withNewName name: String, existing: [Preset]) -> String? {
        let slug = slug(name)
        if slug.isEmpty { return "a preset name needs letters or numbers" }
        if reserved.contains(slug) { return "/\(slug) is already a built-in command — pick another name" }
        if existing.contains(where: { self.slug($0.name) == slug }) { return "/\(slug) already exists" }
        return nil
    }
}
