import AppKit
import SwiftUI

/// The gate. Keyboard-first: the field is focused, typing filters presets and recents,
/// Return starts, Shift-Return starts an open session, Escape clears (3.3).
struct GateView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    @FocusState private var goalFocused: Bool

    @State private var goal = ""
    @State private var highlighted: Int?
    @State private var expanded = false
    @State private var duration: TimeInterval = FocusGuardConfig.current.fullSessionQuickPicks[1]
    @State private var showOverride = false
    @State private var pacingCountdown: TimeInterval = 0
    @State private var pacingGoal = ""
    @State private var pacingTimer: Timer?

    private var suggestions: [Suggestion] {
        sessionManager.suggestions(for: goal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !sessionManager.permissions.isHealthy {
                PermissionBanner(permissions: sessionManager.permissions)
            }

            if let prompt = sessionManager.gateContext?.lastSession {
                LastGoalPrompt(prompt: prompt)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What are you working on?")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)

                goalField
            }

            if pacingCountdown > 0 {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("That's another quick session. Starting in \(Int(ceil(pacingCountdown)))s…")
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    Button("Cancel") {
                        pacingTimer?.invalidate()
                        pacingTimer = nil
                        pacingCountdown = 0
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            if !suggestions.isEmpty {
                SuggestionList(suggestions: suggestions, highlighted: highlighted) { index in
                    accept(suggestions[index], startImmediately: true)
                }
            }

            if expanded {
                GateOptions(duration: $duration)
                    .transition(.opacity)
            }

            hints

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 12) {
                Button("Emergency override…") { showOverride = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))

                Spacer()

                if sessionManager.gateContext?.offerSleep == true {
                    Button {
                        sessionManager.requestSleep()
                    } label: {
                        Label("I'm done: sleep the Mac", systemImage: "moon.zzz.fill")
                    }
                }

                Button("Open session · 5 min") { startOpen() }
                    .disabled(goal.nilIfBlank == nil)

                // Keyboard-first does not mean keyboard-only: once you click into the app
                // search or the site field, Return belongs to that field, and there has to
                // be something to press.
                Button(startLabel) { startFull() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(goal.nilIfBlank == nil)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { goalFocused = true }
        .sheet(isPresented: $showOverride) {
            OverrideView(onComplete: { reason in
                showOverride = false
                sessionManager.startOverride(reason: reason)
            }, onCancel: { showOverride = false })
        }
    }

    private var goalField: some View {
        TextField("Finish the reducer, reply to the landlord, edit the clip…", text: $goal)
            .textFieldStyle(.plain)
            .font(.system(size: 22))
            .foregroundStyle(.white)
            .padding(14)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)))
            .focused($goalFocused)
            .onChange(of: goal) { _, _ in highlighted = nil }
            .onKeyPress(keys: [.return], phases: .down) { press in
                handleReturn(shift: press.modifiers.contains(.shift))
                return .handled
            }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.tab) { move(1); return .handled }
            .onKeyPress(.escape) {
                goal = ""
                highlighted = nil
                expanded = false
                return .handled
            }
    }

    private var hints: some View {
        HStack(spacing: 16) {
            if let hint = specificityHint {
                Label(hint, systemImage: "lightbulb")
                    .foregroundStyle(.yellow.opacity(0.8))
            }
            Spacer()
            KeyHint(keys: "return", label: highlighted != nil ? "start preset" : (expanded ? "start" : "options"))
            KeyHint(keys: "⇧return", label: "open session, 5 min")
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.5))
    }

    /// Soft nudge only, and never for open sessions (3.3).
    private var specificityHint: String? {
        guard let trimmed = goal.nilIfBlank else { return nil }
        return (trimmed.count < 12 || !trimmed.contains(" ")) ? "What does done look like?" : nil
    }

    private var startLabel: String {
        expanded ? "Start · \(Int(duration / 60)) min" : "Start session"
    }

    private func startFull() {
        guard let goal = goal.nilIfBlank else { return }
        if let index = highlighted {
            accept(suggestions[index], startImmediately: true)
            return
        }
        sessionManager.startFullSession(goal: goal, duration: duration)
        reset()
    }

    private func startOpen() {
        guard let goal = goal.nilIfBlank else { return }

        // Chaining "quick" sessions is the pattern this guards against, so the wait grows
        // with how many you have already started this hour (3.2).
        let wait = sessionManager.openSessionCountdown()
        guard wait > 0 else {
            sessionManager.startOpenSession(goal: goal)
            reset()
            return
        }

        pacingGoal = goal
        pacingCountdown = wait
        pacingTimer?.invalidate()
        pacingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                pacingCountdown -= 1
                guard pacingCountdown <= 0 else { return }
                pacingTimer?.invalidate()
                pacingTimer = nil
                sessionManager.startOpenSession(goal: pacingGoal)
                reset()
            }
        }
    }

    // MARK: - Keyboard

    private func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let count = suggestions.count
        switch highlighted {
        case nil:
            highlighted = delta > 0 ? 0 : count - 1
        case .some(let current):
            let next = current + delta
            highlighted = (next < 0 || next >= count) ? nil : next
        }
        if let index = highlighted { completeText(with: suggestions[index]) }
    }

    private func handleReturn(shift: Bool) {
        if shift {
            startOpen()
            return
        }

        if highlighted != nil {
            startFull()
            return
        }

        guard goal.nilIfBlank != nil else { return }

        // First Return opens the options; the second starts. The button does the same
        // thing, for when focus has moved elsewhere.
        if expanded {
            startFull()
        } else {
            expanded = true
        }
    }

    /// Accepting a suggestion completes the text; the goal is still whatever is in the
    /// field, so you can keep typing to make it specific (3.3).
    private func completeText(with suggestion: Suggestion) {
        if suggestion.isPreset { goal = suggestion.title }
    }

    private func accept(_ suggestion: Suggestion, startImmediately: Bool) {
        completeText(with: suggestion)
        sessionManager.applySuggestion(suggestion)
        if let suggested = suggestion.duration { duration = suggested }
        guard startImmediately, let goal = goal.nilIfBlank else { return }
        sessionManager.startFullSession(
            goal: goal,
            duration: suggestion.duration ?? duration,
            presetID: suggestion.presetID,
            sites: suggestion.allowedSites
        )
        reset()
    }

    private func reset() {
        goal = ""
        highlighted = nil
        expanded = false
        pacingCountdown = 0
        pacingGoal = ""
        pacingTimer?.invalidate()
        pacingTimer = nil
    }
}

private struct LastGoalPrompt: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    let prompt: LastSessionPrompt

    var body: some View {
        HStack(spacing: 12) {
            Text("Your last goal was “\(prompt.goal)”. Did you finish?")
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button("Yes") { sessionManager.answerGate(finished: true) }
            Button("Not yet") { sessionManager.answerGate(finished: false) }
        }
        .font(.subheadline)
        .padding(12)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct SuggestionList: View {
    let suggestions: [Suggestion]
    let highlighted: Int?
    let onPick: (Int) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    onPick(index)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.isPreset ? "square.stack.3d.up.fill" : "clock.arrow.circlepath")
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 18)
                        Text(suggestion.title)
                            .foregroundStyle(.white)
                        Spacer()
                        if let duration = suggestion.duration {
                            Text("\(Int(duration / 60)) min")
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Text(suggestion.isPreset ? "preset" : "recent")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(index == highlighted ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct GateOptions: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    @Binding var duration: TimeInterval
    @State private var customMinutes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("How long?")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 8) {
                    ForEach(FocusGuardConfig.current.fullSessionQuickPicks, id: \.self) { pick in
                        Button {
                            duration = pick
                            customMinutes = ""
                        } label: {
                            Text("\(Int(pick / 60))m")
                                .frame(minWidth: 42)
                                .padding(.vertical, 6)
                                .background(duration == pick ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }

                    TextField("custom", text: $customMinutes)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .onChange(of: customMinutes) { _, value in
                            if let minutes = Double(value), minutes > 0 {
                                duration = min(minutes * 60, sessionManager.settingsDraft.maxFullSessionLength)
                            }
                        }
                    Text("max \(Int(sessionManager.settingsDraft.maxFullSessionLength / 60))m")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Apps you'll need")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                GateAppPicker()
            }

            if sessionManager.selectionIncludesBrowser {
                GateSiteList()
            }
        }
    }
}

/// Per-session site allowlist (3.5). A domain allows the whole site; a pin allows one
/// exact page and nothing else on that host.
private struct GateSiteList: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    @State private var entry = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Sites")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))

            HStack(spacing: 8) {
                TextField("apple.com, or paste an exact page address", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(.domain) }
                Button("Allow site") { add(.domain) }
                    .disabled(entry.nilIfBlank == nil)
                Button("Pin page") { add(.pinnedPage) }
                    .disabled(entry.nilIfBlank == nil)
            }

            if let error = sessionManager.siteInputError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if sessionManager.sessionSites.isEmpty {
                Toggle(
                    "Allow all non-blocked sites in this browser",
                    isOn: $sessionManager.allowAllNonBlockedSites
                )
                .toggleStyle(.checkbox)
                .foregroundStyle(.white.opacity(0.75))
                .font(.subheadline)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(sessionManager.sessionSites, id: \.self) { rule in
                        HStack(spacing: 6) {
                            Image(systemName: rule.scope == .pinnedPage ? "pin.fill" : "globe")
                                .font(.caption2)
                            Text(rule.displayName)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Button {
                                sessionManager.removeSessionSite(rule)
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text("Everything else in this browser counts as leaving the session.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func add(_ scope: SiteRule.Scope) {
        sessionManager.addSessionSite(entry, scope: scope)
        if sessionManager.siteInputError == nil { entry = "" }
    }
}

private struct GateAppPicker: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Search apps you'll need, running or not", text: $sessionManager.pickerSearch)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            if !sessionManager.selectedApps.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(sessionManager.selectedApps) { app in
                        AppRow(app: app, isSelected: true)
                    }
                }
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(sessionManager.unselectedPickerApps) { app in
                        AppRow(app: app, isSelected: false)
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }
}

private struct AppRow: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    let app: CatalogApp
    let isSelected: Bool

    var body: some View {
        let allowed = Allowlist.canAllowlist(bundleID: app.bundleID)
        Button {
            sessionManager.toggleAllowed(bundleID: app.bundleID)
        } label: {
            HStack(spacing: 7) {
                if let icon = sessionManager.icon(for: app) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "app.dashed")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 16, height: 16)
                }
                Text(app.name)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                if app.isRunning {
                    Circle()
                        .fill(.green.opacity(0.7))
                        .frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.white)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .opacity(allowed ? 1 : 0.35)
        .help(allowed ? app.bundleID : "Focus Guard can't read this browser's tabs, so it can't police them.")
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(label)
        }
    }
}
