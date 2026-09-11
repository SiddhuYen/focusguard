import Foundation

/// What you typed at the gate. Bare text is the goal, so the quickest path is still to type
/// what you're doing; everything else is an explicit command.
enum GateCommand: Equatable, Sendable {
    case text(String)
    case goal(String)
    case add([String])
    case apps([String])
    case time(minutes: Int)
    case sites([String])
    case allowAllSites
    case pin(String)
    case start
    case quick(String?)
    case preset(String)
    case listPresets
    case status
    case help
    case override
    case sleep
    case answerLastGoal(finished: Bool)
    case cancel
    case exit
    /// A real command typed without the argument it needs.
    case needsArgument(command: String, hint: String)
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
        case "g", "goal":
            return rest.isEmpty ? .needsArgument(command: "/goal", hint: "words: /goal write the lab report") : .goal(rest)
        case "a", "add", "+":
            return words.isEmpty ? .needsArgument(command: "/add", hint: "app names: /add xcode terminal") : .add(words)
        case "app", "apps":
            return .apps(words)
        case "t", "time", "min", "mins":
            guard let first = words.first else {
                return .needsArgument(command: "/time", hint: "minutes: /time 50")
            }
            guard let minutes = Int(first) else { return .unknown(line) }
            return .time(minutes: minutes)
        case "s", "site", "sites":
            return words.isEmpty ? .allowAllSites : .sites(words)
        case "pin":
            return rest.isEmpty ? .needsArgument(command: "/pin", hint: "a page address: /pin https://…") : .pin(rest)
        case "start", "go", "run":
            return .start
        case "q", "quick", "5":
            return .quick(rest.isEmpty ? nil : rest)
        case "p", "preset":
            return rest.isEmpty ? .listPresets : .preset(rest)
        case "presets":
            return .listPresets
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
        case "exit", "quit":
            return .exit
        default:
            return .unknown(line)
        }
    }

    /// Shown by /help, in the order you would use them.
    static let help: [(command: String, description: String)] = [
        ("<goal>", "set the goal by just typing it"),
        ("/goal <text>", "set the goal"),
        ("/add <apps>", "add apps by name: /add xcode terminal"),
        ("/apps <apps>", "replace the app list"),
        ("/time <minutes>", "set how long"),
        ("/sites <domains>", "limit the browser; /sites alone allows all non-blocked"),
        ("/pin <url>", "allow one exact page, even on a blocked domain"),
        ("/start", "start the session (return on an empty line does too)"),
        ("/quick <goal>", "five minute open session, any app, blocklist still applies"),
        ("/preset <name>", "start from a preset; /presets lists them"),
        ("/status", "today's numbers"),
        ("/override", "emergency override: reason, phrase, and a wait"),
        ("/sleep", "you're done: sleep the Mac"),
        ("/cancel", "clear the draft")
    ]

    /// Shown only while the testing exit is compiled in.
    static let testingHelp: (command: String, description: String) =
        ("/exit", "TESTING ONLY: quit Focus Guard and stop the login agent")

    /// Command names for tab completion, without their arguments.
    static var commandNames: [String] {
        (help.map(\.command) + [testingHelp.command])
            .filter { $0.hasPrefix("/") }
            .map { $0.split(separator: " ").first.map(String.init) ?? $0 }
    }

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
