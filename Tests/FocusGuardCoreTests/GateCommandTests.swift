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

    @Test("Quick sessions, with or without a goal on the same line")
    func quick() {
        #expect(GateCommandParser.parse("/quick fix the build") == .quick("fix the build"))
        #expect(GateCommandParser.parse("/q fix the build") == .quick("fix the build"))
        #expect(GateCommandParser.parse("/5") == .quick(nil))
    }

    @Test("Presets by name, or listed")
    func presets() {
        #expect(GateCommandParser.parse("/preset deep work") == .preset("deep work"))
        #expect(GateCommandParser.parse("/p email") == .preset("email"))
        #expect(GateCommandParser.parse("/presets") == .listPresets)
        #expect(GateCommandParser.parse("/preset") == .listPresets)
    }

    @Test("Apps, time, sites and pins")
    func sessionSetup() {
        #expect(GateCommandParser.parse("/apps xcode terminal") == .apps(["xcode", "terminal"]))
        #expect(GateCommandParser.parse("/a xcode") == .apps(["xcode"]))
        #expect(GateCommandParser.parse("/time 50") == .time(minutes: 50))
        #expect(GateCommandParser.parse("/t 90") == .time(minutes: 90))
        #expect(GateCommandParser.parse("/sites apple.com swift.org") == .sites(["apple.com", "swift.org"]))
        #expect(GateCommandParser.parse("/sites") == .allowAllSites)
        #expect(GateCommandParser.parse("/pin https://youtube.com/watch?v=x") == .pin("https://youtube.com/watch?v=x"))
    }

    @Test("Nonsense is reported, not guessed at")
    func unknown() {
        #expect(GateCommandParser.parse("/frobnicate") == .unknown("/frobnicate"))
        #expect(GateCommandParser.parse("/time soon") == .unknown("/time soon"))
        #expect(GateCommandParser.parse("/pin") == .unknown("/pin"))
    }

    @Test("The escape hatches have their own commands")
    func escapes() {
        #expect(GateCommandParser.parse("/override") == .override)
        #expect(GateCommandParser.parse("/emergency") == .override)
        #expect(GateCommandParser.parse("/sleep") == .sleep)
        #expect(GateCommandParser.parse("/y") == .answerLastGoal(finished: true))
        #expect(GateCommandParser.parse("/n") == .answerLastGoal(finished: false))
    }

    @Test("The testing exit parses, under either name")
    func exit() {
        #expect(GateCommandParser.parse("/exit") == .exit)
        #expect(GateCommandParser.parse("/quit") == .exit)
        #expect(GateCommand.exit.isGlobal)
    }

    @Test("Tab completion behaves like a shell")
    func completion() {
        let apps = ["Xcode", "Terminal", "TextEdit", "Safari"]
        #expect(GateCommandParser.complete("xc", from: apps) == "Xcode")
        #expect(GateCommandParser.complete("te", from: apps) == "Te", "two matches share only 'Te'")
        #expect(GateCommandParser.complete("saf", from: apps) == "Safari")
        #expect(GateCommandParser.complete("z", from: apps) == nil)
        #expect(GateCommandParser.complete("", from: apps) == nil)
    }
}
