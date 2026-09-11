import Foundation
import Testing
@testable import FocusGuardCore

@Suite("Gate command line")
struct GateCommandTests {
    @Test("Anything without a slash is the goal")
    func plainTextIsTheGoal() {
        #expect(GateCommandParser.parse("ship the reducer") == .text("ship the reducer"))
        #expect(GateCommandParser.parse("  email the landlord  ") == .text("email the landlord"))
        #expect(GateCommandParser.parse("") == .text(""))
    }

    @Test("The goal can also be set explicitly")
    func goalCommand() {
        #expect(GateCommandParser.parse("/goal write the lab report") == .goal("write the lab report"))
        #expect(GateCommandParser.parse("/g write the lab report") == .goal("write the lab report"))
        #expect(GateCommandParser.parse("/goal") == .needsArgument(command: "/goal", hint: "words: /goal write the lab report"))
    }

    @Test("Adding apps adds; setting apps replaces")
    func appCommands() {
        #expect(GateCommandParser.parse("/add xcode terminal") == .add(["xcode", "terminal"]))
        #expect(GateCommandParser.parse("/a xcode") == .add(["xcode"]))
        #expect(GateCommandParser.parse("/apps xcode terminal") == .apps(["xcode", "terminal"]))
        #expect(GateCommandParser.parse("/add") == .needsArgument(command: "/add", hint: "app names: /add xcode terminal"),
                "adding nothing is a mistake, not a clear")
    }

    @Test("Time, sites, pins and starting")
    func sessionSetup() {
        #expect(GateCommandParser.parse("/time 50") == .time(minutes: 50))
        #expect(GateCommandParser.parse("/t 90") == .time(minutes: 90))
        #expect(GateCommandParser.parse("/sites apple.com swift.org") == .sites(["apple.com", "swift.org"]))
        #expect(GateCommandParser.parse("/sites") == .allowAllSites)
        #expect(GateCommandParser.parse("/pin https://youtube.com/watch?v=x") == .pin("https://youtube.com/watch?v=x"))
        #expect(GateCommandParser.parse("/start") == .start)
        #expect(GateCommandParser.parse("/go") == .start)
    }

    @Test("Quick sessions and presets")
    func quickAndPresets() {
        #expect(GateCommandParser.parse("/quick fix the build") == .quick("fix the build"))
        #expect(GateCommandParser.parse("/q fix the build") == .quick("fix the build"))
        #expect(GateCommandParser.parse("/5") == .quick(nil))
        #expect(GateCommandParser.parse("/preset deep work") == .preset("deep work"))
        #expect(GateCommandParser.parse("/p email") == .preset("email"))
        #expect(GateCommandParser.parse("/presets") == .listPresets)
        #expect(GateCommandParser.parse("/preset") == .listPresets)
    }

    @Test("Nonsense is reported, not guessed at")
    func unknown() {
        #expect(GateCommandParser.parse("/frobnicate") == .unknown("/frobnicate"))
        #expect(GateCommandParser.parse("/time soon") == .unknown("/time soon"), "soon is not a number")
    }

    @Test("The escape hatches have their own commands")
    func escapes() {
        #expect(GateCommandParser.parse("/override") == .override)
        #expect(GateCommandParser.parse("/emergency") == .override)
        #expect(GateCommandParser.parse("/sleep") == .sleep)
        #expect(GateCommandParser.parse("/exit") == .exit)
        #expect(GateCommandParser.parse("/quit") == .exit)
        #expect(GateCommandParser.parse("/y") == .answerLastGoal(finished: true))
        #expect(GateCommandParser.parse("/n") == .answerLastGoal(finished: false))
    }

    @Test("A command that needs an argument says so, rather than claiming not to exist")
    func missingArguments() {
        for (name, typed) in [("/goal", "/goal"), ("/add", "/add"), ("/time", "/time"), ("/pin", "/pin")] {
            guard case .needsArgument(let command, let hint) = GateCommandParser.parse(typed) else {
                Issue.record("\(typed) should ask for its argument")
                continue
            }
            #expect(command == name)
            #expect(!hint.isEmpty)
        }
    }

    @Test("Every command in help is one the parser knows")
    func helpIsComplete() {
        let listed = GateCommandParser.commandNames
        #expect(listed.contains("/goal"))
        #expect(listed.contains("/add"))
        #expect(listed.contains("/time"))
        #expect(listed.contains("/start"))
        for name in listed {
            #expect(GateCommandParser.parse(name) != .unknown(name), "\(name) is listed in help but does not parse")
        }
    }

    @Test("Tab completion behaves like a shell")
    func completion() {
        let apps = ["Xcode", "Terminal", "TextEdit", "Safari"]
        #expect(GateCommandParser.complete("xc", from: apps) == "Xcode")
        #expect(GateCommandParser.complete("te", from: apps) == "Te", "two matches share only 'Te'")
        #expect(GateCommandParser.complete("saf", from: apps) == "Safari")
        #expect(GateCommandParser.complete("z", from: apps) == nil)
        #expect(GateCommandParser.complete("", from: apps) == nil)
        #expect(GateCommandParser.complete("/ti", from: GateCommandParser.commandNames) == "/time")
    }
}
