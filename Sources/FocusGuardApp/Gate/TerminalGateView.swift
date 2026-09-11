import AppKit
import SwiftUI

/// The gate, as a terminal. You type your goal, then answer apps and time; everything else
/// is a slash command. Green on black, monospaced, no buttons.
struct TerminalGateView: View {
    /// Debug only: seeds the transcript so the layout can be rendered offscreen and looked
    /// at without having to type the flow by hand.
    var demoLines: [TerminalLine]?

    @EnvironmentObject private var sessionManager: FocusSessionManager
    @FocusState private var inputFocused: Bool

    @State private var lines: [TerminalLine] = []
    @State private var input = ""
    @State private var stage: Stage = .goal
    @State private var draft = SessionDraft()
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var override = OverrideDraft()
    @State private var countdownTimer: Timer?
    private let promptAnchor = "prompt"

    private enum Stage: Equatable {
        case lastGoal
        case goal
        case apps
        case duration
        case overrideReason
        case overridePhrase
        case waiting

        var prompt: String {
            switch self {
            case .lastGoal: return "finished?"
            case .goal: return "focus"
            case .apps: return "apps"
            case .duration: return "time"
            case .overrideReason: return "reason"
            case .overridePhrase: return "phrase"
            case .waiting: return "wait"
            }
        }
    }

    private struct SessionDraft {
        var goal = ""
        var bundleIDs: [String] = []
        var minutes = Int(FocusGuardConfig.current.fullSessionQuickPicks[1] / 60)
        var sites: [SiteRule] = []
        var allowAllSites = false
        var presetID: UUID?
    }

    private struct OverrideDraft {
        var reason = ""
        var remaining: TimeInterval = 0
        var pasteBlocked = false
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .foregroundStyle(line.style.color)
                            .textSelection(.enabled)
                            .id(line.id)
                    }

                    promptLine
                        .padding(.top, 4)
                        .id(promptAnchor)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.vertical, 34)
            }
            .onChange(of: lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(promptAnchor, anchor: .bottom) }
            }
        }
        .font(.system(size: 14, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TerminalPalette.background)
        .onAppear(perform: boot)
        .onDisappear { countdownTimer?.invalidate() }
        .onChange(of: sessionManager.gateNotice) { _, notice in
            guard let notice else { return }
            for line in notice.lines { write(line.text, line.style) }
            inputFocused = true
        }
    }

    private var promptLine: some View {
        HStack(spacing: 8) {
            Text("\(stage.prompt) ▸")
                .foregroundStyle(TerminalPalette.prompt)
            TextField("", text: $input)
                .textFieldStyle(.plain)
                .foregroundStyle(TerminalPalette.input)
                .tint(TerminalPalette.input)
                .focused($inputFocused)
                .disabled(stage == .waiting)
                .onSubmit(submit)
                .onKeyPress(.upArrow) { recallHistory(-1); return .handled }
                .onKeyPress(.downArrow) { recallHistory(1); return .handled }
                .onKeyPress(.tab) { completeInput(); return .handled }
                .onKeyPress(.escape) { input = ""; return .handled }
                .onChange(of: input) { old, new in
                    // Typing only for the override phrase: a jump of several characters is
                    // a paste (3.7).
                    guard stage == .overridePhrase, new.count > old.count + 1 else { return }
                    input = old
                    override.pasteBlocked = true
                    write("pasting is not accepted — type it out", .warn)
                }
        }
        .onTapGesture { inputFocused = true }
    }

    // MARK: - Boot

    private func boot() {
        inputFocused = true
        guard lines.isEmpty else { return }

        if let demoLines {
            lines = demoLines
            stage = .apps
            return
        }

        write("focusguard \(BuildInfo.versionStamp) · gate", .banner)
        if !sessionManager.permissions.isHealthy {
            write("! \(sessionManager.permissions.summary) — enforcement is degraded", .error)
        }
        if sessionManager.gateContext?.offerSleep == true {
            write("type /sleep when you're done for the day", .dim)
        }
        write("type a goal, or /help", .dim)
        if FocusGuardConfig.testingExitCommandEnabled {
            write("testing build: /exit quits and stops the login agent", .warn)
        }
        write("", .dim)

        if let prompt = sessionManager.gateContext?.lastSession {
            write("last goal: \"\(prompt.goal)\"", .output)
            write("did you finish it? y / n", .output)
            stage = .lastGoal
        }
    }

    // MARK: - Submitting

    private func submit() {
        let raw = input
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        echo(raw)
        input = ""
        historyIndex = nil
        if !trimmed.isEmpty { history.append(trimmed) }

        let command = GateCommandParser.parse(trimmed)

        // Bare y/n answers the last-goal question without a slash.
        if stage == .lastGoal, case .text(let text) = command {
            switch text.lowercased() {
            case "y", "yes": answerLastGoal(true); return
            case "n", "no": answerLastGoal(false); return
            default: break
            }
        }

        if command.isGlobal {
            handleGlobal(command)
            return
        }

        switch (stage, command) {
        case (.lastGoal, .answerLastGoal(let finished)):
            answerLastGoal(finished)

        case (.lastGoal, _):
            write("(last goal left unanswered — it stays logged as expired)", .dim)
            stage = .goal
            submitText(trimmed)

        case (_, .answerLastGoal):
            write("nothing to answer", .dim)

        case (.goal, .text(let text)):
            submitText(text)

        case (.apps, .text(let text)):
            resolveApps(text)

        case (.duration, .text(let text)):
            resolveDuration(text)

        case (.overrideReason, .text(let text)):
            guard !text.isEmpty else {
                write("a reason is required", .warn)
                return
            }
            override.reason = text
            write("type this exactly:", .output)
            write(sessionManager.settingsDraft.overridePhrase, .banner)
            stage = .overridePhrase

        case (.overridePhrase, .text(let text)):
            guard text == sessionManager.settingsDraft.overridePhrase else {
                write("that doesn't match", .warn)
                return
            }
            startOverrideCountdown()

        default:
            write("nothing to do with that here", .dim)
        }
    }

    private func submitText(_ text: String) {
        guard !text.isEmpty else {
            write("what are you working on?", .dim)
            return
        }
        draft.goal = text
        if draft.bundleIDs.isEmpty {
            draft.bundleIDs = sessionManager.multiAppAllowedBundleIDs
        }
        let current = draft.bundleIDs.map { sessionManager.displayName(for: $0) }.joined(separator: ", ")
        write("which apps? [\(current.isEmpty ? "current app" : current)] — tab completes, return accepts", .dim)
        stage = .apps
    }

    private func resolveApps(_ text: String) {
        let names = text.split(separator: " ").map(String.init)
        if !names.isEmpty {
            var resolved: [String] = []
            var unknown: [String] = []
            for name in names {
                if let app = matchApp(name) {
                    if Allowlist.canAllowlist(bundleID: app.bundleID) {
                        resolved.append(app.bundleID)
                    } else {
                        write("\(app.name): can't read its tabs, so it can't be policed", .warn)
                    }
                } else {
                    unknown.append(name)
                }
            }
            if !unknown.isEmpty { write("no such app: \(unknown.joined(separator: ", "))", .warn) }
            if !resolved.isEmpty { draft.bundleIDs = resolved }
        }

        if draft.bundleIDs.isEmpty, let current = sessionManager.multiAppAllowedBundleIDs.first {
            draft.bundleIDs = [current]
        }

        let named = draft.bundleIDs.map { sessionManager.displayName(for: $0) }.joined(separator: ", ")
        write("allowed: \(named.isEmpty ? "current app" : named)", .output)

        if draft.bundleIDs.contains(where: { KnownBrowser.isBrowser(bundleID: $0) }), draft.sites.isEmpty, !draft.allowAllSites {
            write("browser included — /sites <domains> to limit it, /pin <url> for one page,", .dim)
            write("or /sites alone to allow everything that isn't blocked", .dim)
        }

        write("how long? [\(draft.minutes)] minutes — \(quickPicks())", .dim)
        stage = .duration
    }

    private func resolveDuration(_ text: String) {
        if !text.isEmpty {
            guard let minutes = Int(text), minutes > 0 else {
                write("minutes, as a number", .warn)
                return
            }
            draft.minutes = minutes
        }
        startFullSession()
    }

    // MARK: - Commands

    private func handleGlobal(_ command: GateCommand) {
        switch command {
        case .help:
            for entry in GateCommandParser.help {
                write("  \(entry.command.padding(toLength: 18, withPad: " ", startingAt: 0))\(entry.description)", .output)
            }
            if FocusGuardConfig.testingExitCommandEnabled {
                let entry = GateCommandParser.testingHelp
                write("  \(entry.command.padding(toLength: 18, withPad: " ", startingAt: 0))\(entry.description)", .warn)
            }

        case .cancel:
            input = ""
            draft = SessionDraft()
            stage = .goal
            write("cleared", .dim)

        case .quick(let goal):
            let goal = goal ?? draft.goal
            guard !goal.isEmpty else {
                write("/quick needs a goal: /quick fix the build", .warn)
                return
            }
            startOpenSession(goal: goal)

        case .listPresets:
            let presets = sessionManager.presets
            guard !presets.isEmpty else {
                write("no presets yet — save one from the end of a session", .dim)
                return
            }
            for preset in presets {
                let apps = preset.allowedBundleIDs.map { sessionManager.displayName(for: $0) }.joined(separator: ", ")
                write("  /p \(preset.name.padding(toLength: 14, withPad: " ", startingAt: 0))\(Int(preset.defaultDuration / 60))m  \(apps)", .output)
            }

        case .preset(let name):
            guard let preset = sessionManager.presets.first(where: {
                $0.name.lowercased().hasPrefix(name.lowercased())
            }) else {
                write("no preset named \(name) — /presets to list them", .warn)
                return
            }
            draft.bundleIDs = preset.allowedBundleIDs
            draft.sites = preset.allowedSites
            draft.minutes = Int(preset.defaultDuration / 60)
            draft.presetID = preset.id
            if draft.goal.isEmpty { draft.goal = preset.name }
            write("preset \(preset.name): \(draft.minutes)m · \(preset.allowedBundleIDs.map { sessionManager.displayName(for: $0) }.joined(separator: ", "))", .output)
            startFullSession()

        case .apps(let names):
            resolveApps(names.joined(separator: " "))
            if stage == .duration, !draft.goal.isEmpty { return }
            stage = draft.goal.isEmpty ? .goal : .duration

        case .time(let minutes):
            guard minutes > 0 else {
                write("minutes, as a positive number", .warn)
                return
            }
            draft.minutes = minutes
            write("length: \(minutes)m", .output)

        case .sites(let domains):
            for domain in domains {
                switch SiteRuleInput.make(from: domain, scope: .domain, blocklist: sessionManager.settingsDraft.blocklist) {
                case .rule(let rule):
                    draft.sites.append(rule)
                    write("site: \(rule.displayName)", .output)
                case .rejected(let reason):
                    write(reason, .warn)
                }
            }

        case .allowAllSites:
            draft.allowAllSites = true
            draft.sites = []
            write("all non-blocked sites allowed in this session", .output)

        case .pin(let url):
            switch SiteRuleInput.make(from: url, scope: .pinnedPage, blocklist: sessionManager.settingsDraft.blocklist) {
            case .rule(let rule):
                draft.sites.append(rule)
                write("pinned: \(rule.displayName)", .output)
                write("only that page — the rest of the site still counts as leaving", .dim)
            case .rejected(let reason):
                write(reason, .warn)
            }

        case .status:
            printStatus()

        case .override:
            write("emergency override — suspends everything for \(Int(sessionManager.settingsDraft.overrideDuration / 60)) minutes,", .warn)
            write("blocked sites included, and goes to the top of your daily review", .warn)
            write("why?", .output)
            stage = .overrideReason

        case .sleep:
            write("goodnight", .success)
            sessionManager.requestSleep()

        case .exit:
            guard FocusGuardConfig.testingExitCommandEnabled else {
                write("/exit: no such command — /help", .warn)
                return
            }
            write("exiting (testing) — login agent stopped until you open Focus Guard again", .warn)
            stage = .waiting
            // Let the line render before the process goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { sessionManager.exitForTesting() }
            }

        case .unknown(let text):
            write("\(text): no such command — /help", .warn)

        case .text, .answerLastGoal:
            break
        }
    }

    private func printStatus() {
        let review = sessionManager.dailyReview(for: Date())
        write("today", .banner)
        write("  active      \(review.totals.activeSeconds.formattedDuration)", .output)
        write("  in sessions \(review.totals.sessionSeconds.formattedDuration)  (\(Int(review.totals.coverage * 100))%)", .output)
        write("  sessions    \(review.fullSessions.count) full, \(review.openSessions.count) open\(review.chains.isEmpty ? "" : ", \(review.chains.count) chained")", .output)
        let violations = review.sessions.reduce(0) { $0 + $1.violations }
        if violations > 0 { write("  attempts    \(violations)", .output) }
        if !review.overrides.isEmpty { write("  overrides   \(review.overrides.count)", .warn) }
        if review.blockedQuits > 0 { write("  refused quits \(review.blockedQuits)", .warn) }
    }

    // MARK: - Starting

    private func startFullSession() {
        guard !draft.goal.isEmpty else {
            write("state a goal first", .warn)
            stage = .goal
            return
        }

        sessionManager.setSelection(draft.bundleIDs)
        sessionManager.allowAllNonBlockedSites = draft.allowAllSites
        let named = draft.bundleIDs.map { sessionManager.displayName(for: $0) }.joined(separator: ", ")
        write("▸ \(draft.goal) · \(draft.minutes)m · \(named.isEmpty ? "current app" : named)", .success)

        sessionManager.startFullSession(
            goal: draft.goal,
            duration: TimeInterval(draft.minutes * 60),
            presetID: draft.presetID,
            sites: draft.sites
        )
        resetAfterStart()
    }

    private func startOpenSession(goal: String) {
        let wait = sessionManager.openSessionCountdown()
        guard wait <= 0 else {
            write("that's another quick session — starting in \(Int(wait))s", .warn)
            stage = .waiting
            runCountdown(seconds: wait) {
                sessionManager.startOpenSession(goal: goal)
                resetAfterStart()
            }
            return
        }
        write("▸ \(goal) · 5m · any app · blocked sites still blocked", .success)
        sessionManager.startOpenSession(goal: goal)
        resetAfterStart()
    }

    private func startOverrideCountdown() {
        write("waiting \(Int(sessionManager.settingsDraft.overrideCountdown))s — \(override.reason)", .warn)
        stage = .waiting
        runCountdown(seconds: sessionManager.settingsDraft.overrideCountdown) {
            write("override active", .error)
            sessionManager.startOverride(reason: override.reason)
            override = OverrideDraft()
            stage = .goal
        }
    }

    private func runCountdown(seconds: TimeInterval, then finish: @escaping () -> Void) {
        override.remaining = seconds
        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                override.remaining -= 1
                if override.remaining > 0 {
                    if Int(override.remaining) % 10 == 0 || override.remaining <= 5 {
                        write("  \(Int(override.remaining))…", .dim)
                    }
                } else {
                    countdownTimer?.invalidate()
                    countdownTimer = nil
                    finish()
                }
            }
        }
        // Registered in every mode, or the clock stops whenever AppKit is tracking.
        for mode in [RunLoop.Mode.common, .modalPanel, .eventTracking] {
            RunLoop.main.add(timer, forMode: mode)
        }
        countdownTimer = timer
    }

    private func answerLastGoal(_ finished: Bool) {
        sessionManager.answerGate(finished: finished)
        write(finished ? "logged as finished" : "logged as unfinished", .output)
        write("", .dim)
        stage = .goal
    }

    private func resetAfterStart() {
        draft = SessionDraft()
        stage = .goal
        input = ""
    }

    // MARK: - Input helpers

    private func matchApp(_ name: String) -> CatalogApp? {
        let needle = name.lowercased()
        let apps = sessionManager.pickerApps
        return apps.first { $0.name.lowercased() == needle }
            ?? apps.first { $0.name.lowercased().hasPrefix(needle) }
            ?? apps.first { $0.name.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(needle) }
            ?? apps.first { $0.bundleID.lowercased().contains(needle) }
    }

    private func completeInput() {
        let words = input.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let partial = words.last, !partial.isEmpty else { return }

        let candidates: [String]
        if partial.hasPrefix("/") {
            candidates = GateCommandParser.help.map(\.command).filter { $0.hasPrefix("/") }
                .map { $0.split(separator: " ").first.map(String.init) ?? $0 }
        } else if stage == .apps {
            candidates = sessionManager.pickerApps.map { $0.name.replacingOccurrences(of: " ", with: "") }
        } else {
            candidates = sessionManager.presets.map(\.name)
        }

        guard let completion = GateCommandParser.complete(partial, from: candidates) else { return }
        input = (words.dropLast() + [completion]).joined(separator: " ")
    }

    private func recallHistory(_ delta: Int) {
        guard !history.isEmpty else { return }
        let next: Int
        switch historyIndex {
        case nil:
            next = delta < 0 ? history.count - 1 : history.count
        case .some(let current):
            next = current + delta
        }

        if next < 0 {
            historyIndex = 0
        } else if next >= history.count {
            historyIndex = nil
            input = ""
            return
        } else {
            historyIndex = next
        }
        if let index = historyIndex { input = history[index] }
    }

    // MARK: - Output

    private func echo(_ text: String) {
        lines.append(TerminalLine(text: "\(stage.prompt) ▸ \(text)", style: .input))
    }

    private func write(_ text: String, _ style: TerminalLine.Style) {
        lines.append(TerminalLine(text: text, style: style))
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    private func quickPicks() -> String {
        FocusGuardConfig.current.fullSessionQuickPicks.map { "\(Int($0 / 60))" }.joined(separator: " / ")
    }
}

struct TerminalLine: Identifiable {
    enum Style {
        case banner, output, input, dim, warn, error, success

        var color: Color {
            switch self {
            case .banner: return TerminalPalette.bright
            case .output: return TerminalPalette.text
            case .input: return TerminalPalette.input
            case .dim: return TerminalPalette.dim
            case .warn: return TerminalPalette.warn
            case .error: return TerminalPalette.error
            case .success: return TerminalPalette.bright
            }
        }
    }

    let id = UUID()
    var text: String
    var style: Style
}

enum TerminalPalette {
    static let background = Color(red: 0.02, green: 0.03, blue: 0.02)
    static let text = Color(red: 0.29, green: 0.87, blue: 0.31)
    static let bright = Color(red: 0.48, green: 1.0, blue: 0.42)
    static let input = Color(red: 0.76, green: 1.0, blue: 0.72)
    static let dim = Color(red: 0.29, green: 0.87, blue: 0.31).opacity(0.45)
    static let prompt = Color(red: 0.29, green: 0.87, blue: 0.31).opacity(0.8)
    static let warn = Color(red: 1.0, green: 0.78, blue: 0.25)
    static let error = Color(red: 1.0, green: 0.35, blue: 0.3)
}
