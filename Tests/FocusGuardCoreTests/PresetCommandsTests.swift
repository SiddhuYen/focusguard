import Foundation
import Testing
@testable import FocusGuardCore

@Suite("Presets as commands")
struct PresetCommandsTests {
    private let deepWork = Preset(name: "Deep work", allowedBundleIDs: ["com.apple.dt.Xcode"], defaultDuration: 90 * 60)
    private let email = Preset(name: "Email!", allowedBundleIDs: ["com.microsoft.Outlook"], defaultDuration: 25 * 60)

    @Test("A preset answers to its name, typed plainly")
    func commandNames() {
        #expect(PresetCommands.command(for: deepWork) == "/deepwork")
        #expect(PresetCommands.command(for: email) == "/email")
        #expect(PresetCommands.slug("  Physics Lab — 2 ") == "physicslab2")
    }

    @Test("Anything after the command is the goal")
    func goalAfterCommand() {
        let match = PresetCommands.resolve("/deepwork ship the reducer", presets: [deepWork, email])
        #expect(match?.preset.id == deepWork.id)
        #expect(match?.goal == "ship the reducer")

        let bare = PresetCommands.resolve("/EMAIL", presets: [deepWork, email])
        #expect(bare?.preset.id == email.id)
        #expect(bare?.goal == nil)
    }

    @Test("Only exact names start a session, never a guessed prefix")
    func exactOnly() {
        #expect(PresetCommands.resolve("/deep", presets: [deepWork]) == nil)
        #expect(PresetCommands.resolve("deepwork", presets: [deepWork]) == nil, "needs the slash")
    }

    @Test("Built-in commands always win over a preset with the same name")
    func builtInsWin() {
        let clash = Preset(name: "Time", allowedBundleIDs: ["com.apple.dt.Xcode"])
        #expect(PresetCommands.command(for: clash) == nil)
        #expect(PresetCommands.resolve("/time", presets: [clash]) == nil)
    }

    @Test("Two presets that type the same way are ambiguous, so neither fires")
    func ambiguity() {
        let a = Preset(name: "Deep work", allowedBundleIDs: ["x"])
        let b = Preset(name: "deep-work", allowedBundleIDs: ["y"])
        #expect(PresetCommands.resolve("/deepwork", presets: [a, b]) == nil)
    }

    @Test("Saving rejects names that would clash or cannot be typed")
    func namingRules() {
        #expect(PresetCommands.problem(withNewName: "Reading", existing: [deepWork]) == nil)
        #expect(PresetCommands.problem(withNewName: "Add", existing: []) != nil, "built-in")
        #expect(PresetCommands.problem(withNewName: "DEEP WORK", existing: [deepWork]) != nil, "duplicate")
        #expect(PresetCommands.problem(withNewName: "!!!", existing: []) != nil, "nothing typable")
    }

    @Test("/save parses, and asks for a name when it has none")
    func saveParses() {
        #expect(GateCommandParser.parse("/save deep work") == .save("deep work"))
        #expect(GateCommandParser.parse("/save") == .needsArgument(command: "/save", hint: "a name: /save deep work"))
    }
}
