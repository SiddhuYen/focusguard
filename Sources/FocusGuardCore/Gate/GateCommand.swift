import Foundation

/// What you typed at the gate. Anything that is not a slash command is the goal itself,
/// so the common case is still "type what you're doing and press return".
enum GateCommand: Equatable, Sendable {
    case text(String)
    case quick(String?)
    case preset(String)
    case listPresets
    case apps([String])
    case time(minutes: Int)
    case sites([String])
    case pin(String)
    case allowAllSites
    case status
    case help
    case override
    case sleep
    case answerLastGoal(finished: Bool)
    case cancel
    case unknown(String)

    /// True for commands that make sense at any prompt, not just the goal line.
    var isGlobal: Bool {
        switch self {
        case .text, .answerLastGoal: return false
        default: return true
        }
    }
}

enum GateCommandParser {
    static let commandPrefix: Character = "/"

    static func parse(_ raw: String) -> GateCommand {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return .text("") }
        guard line.first == commandPrefix else { return .text(line) }

        let withoutSlash = String(line.dropFirst())
        let parts = withoutSlash.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let verb = parts.first.map({ $0.lowercased() }) else { return .unknown(line) }
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        let words = rest.split(separator: " ").map(String.init)

        switch verb {
        case "q", "quick", "5":
            return .quick(rest.isEmpty ? nil : rest)
        case "p", "preset":
            return rest.isEmpty ? .listPresets : .preset(rest)
        case "presets":
            return .listPresets
        case "a", "app", "apps":
            return .apps(words)
        case "t", "time", "min", "mins":
            guard let minutes = Int(words.first ?? "") else { return .unknown(line) }
            return .time(minutes: minutes)
        case "s", "site", "sites":
            return words.isEmpty ? .allowAllSites : .sites(words)
        case "pin":
            return rest.isEmpty ? .unknown(line) : .pin(rest)
        case "status", "today":
            return .status
        case "h", "help", "?":
            return .help
        case "override", "emergency":
            return .override
        case "sleep", "done":
            return .sleep
        case "y", "yes":
            return .answerLastGoal(finished: true)
        case "n", "no":
            return .answerLastGoal(finished: false)
        case "c", "cancel", "clear":
            return .cancel
        default:
            return .unknown(line)
        }
    }

    /// Shown by /help, and hinted on the gate's first line.
    static let help: [(command: String, description: String)] = [
        ("<goal>", "state what you're doing, then answer apps and time"),
        ("/quick <goal>", "five minute open session, any app, blocklist still applies"),
        ("/preset <name>", "start from a preset; /presets lists them"),
        ("/apps <names>", "set the apps for this session"),
        ("/time <minutes>", "set the length"),
        ("/sites <domains>", "limit the browser to these; /sites alone allows all non-blocked"),
        ("/pin <url>", "allow one exact page, even on a blocked domain"),
        ("/status", "today's numbers"),
        ("/override", "emergency override: reason, phrase, and a wait"),
        ("/sleep", "you're done: sleep the Mac"),
        ("/cancel", "clear the line")
    ]

    /// Tab completion over whatever the current prompt offers.
    static func complete(_ partial: String, from candidates: [String]) -> String? {
        let lowered = partial.lowercased()
        guard !lowered.isEmpty else { return nil }
        let matches = candidates.filter { $0.lowercased().hasPrefix(lowered) }
        guard let first = matches.first else { return nil }
        if matches.count == 1 { return first }

        // Several matches: extend to their longest shared prefix, like a shell does.
        var prefix = ""
        for character in first {
            let next = prefix + String(character)
            guard matches.allSatisfy({ $0.lowercased().hasPrefix(next.lowercased()) }) else { break }
            prefix = next
        }
        // Returning a same-length prefix still helps: it fixes your capitalisation.
        return prefix != partial ? prefix : nil
    }
}
