import AppKit

@MainActor
final class CommitmentPromptEngine {
    func promptForGoal(appName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "What is your goal for this focus session?"
        alert.informativeText = "FocusGuard will remind you of this before you take a break, stop, or quit."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start Focus")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        textField.placeholderString = "Finish the Xcode task, write the draft, edit the clip..."
        textField.stringValue = ""
        alert.accessoryView = textField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        guard response == .alertFirstButtonReturn else {
            return nil
        }

        let goal = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return goal.isEmpty ? "Stay focused on \(appName)" : goal
    }

    func confirm(action: CommitmentAction, session: FocusSession) -> Bool {
        let alert = NSAlert()
        alert.messageText = action.title
        alert.informativeText = """
        Your goal was:
        "\(session.goal)"

        Have you finished it?
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: action.confirmTitle)
        alert.addButton(withTitle: action.cancelTitle)

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum CommitmentAction {
    case takeBreak
    case endFocus
    case quit

    var title: String {
        switch self {
        case .takeBreak:
            return "Take a break?"
        case .endFocus:
            return "End this focus session?"
        case .quit:
            return "Quit FocusGuard?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .takeBreak:
            return "Yes, Take a Break"
        case .endFocus:
            return "Yes, End Focus"
        case .quit:
            return "Yes, Quit"
        }
    }

    var cancelTitle: String {
        switch self {
        case .takeBreak:
            return "Return to Goal"
        case .endFocus, .quit:
            return "Keep Focusing"
        }
    }
}
