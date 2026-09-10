import SwiftUI

/// Shown when a session's time runs out, or when you end one early (3.6). Open sessions
/// get the extend/convert/end choice instead (3.2).
struct ReviewView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    let session: Session
    let reason: ReviewReason

    @State private var notFinished = false
    @State private var converting = false
    @State private var convertDuration = FocusGuardConfig.current.fullSessionQuickPicks[1]
    @State private var presetName = ""
    @State private var savingPreset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                Text(session.goal)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 22) {
                ReviewStat(label: "Planned", value: plannedText)
                ReviewStat(label: "Actual", value: session.elapsed.formattedDuration)
                ReviewStat(label: "Attempts", value: "\(session.violations.count)")
                if !session.additions.isEmpty {
                    ReviewStat(label: "Added", value: "\(session.additions.count)")
                }
            }

            if converting {
                convertControls
            } else if savingPreset {
                presetControls
            } else if session.kind == .open {
                openControls
            } else if notFinished {
                extendControls
            } else {
                finishedControls
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private var headline: String {
        switch (session.kind, reason) {
        case (.open, _): return session.extensionsUsed == 0 ? "Five minutes is up." : "Ten minutes is up."
        case (.full, .timeUp): return "Time's up. Did you finish?"
        case (.full, .endedByUser): return "Ending early. Did you finish?"
        }
    }

    private var plannedText: String {
        guard let plannedEnd = session.plannedEnd else { return "—" }
        return plannedEnd.timeIntervalSince(session.startedAt).formattedDuration
    }

    private var finishedControls: some View {
        HStack {
            Button("Not yet") { notFinished = true }
            Spacer()
            if session.presetID == nil {
                Button("Save as preset") {
                    presetName = session.goal
                    savingPreset = true
                }
            }
            Button("Yes, finished") { sessionManager.answerReview(finished: true) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var extendControls: some View {
        HStack {
            ForEach(FocusGuardConfig.current.reviewExtendOptions, id: \.self) { amount in
                Button("Extend \(Int(amount / 60)) min") {
                    sessionManager.extendReview(by: amount)
                }
                .disabled(!canExtend)
            }
            Spacer()
            Button("End anyway", role: .destructive) { sessionManager.answerReview(finished: false) }
                .keyboardShortcut(.defaultAction)
        }
        .overlay(alignment: .bottomLeading) {
            if !canExtend {
                Text("This session has hit the \(Int(sessionManager.settingsDraft.maxFullSessionLength / 60)) minute cap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .offset(y: 22)
            }
        }
    }

    private var canExtend: Bool {
        guard let plannedEnd = session.plannedEnd else { return true }
        return plannedEnd.timeIntervalSince(session.startedAt) < sessionManager.settingsDraft.maxFullSessionLength
    }

    private var openControls: some View {
        HStack {
            if session.extensionsUsed == 0 {
                Button("Extend 5 min") { sessionManager.extendOpenSession() }
            }
            Button("Convert to full session") {
                convertDuration = FocusGuardConfig.current.fullSessionQuickPicks[1]
                converting = true
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            Spacer()
            Button("End", role: .destructive) { sessionManager.answerReview(finished: true) }
        }
    }

    private var convertControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Carrying over what you actually used")
                .font(.headline)
            if session.appsUsed.isEmpty {
                Text("No apps were used long enough to carry over; your current app will be allowed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(session.appsUsed.sorted { $0.seconds > $1.seconds }.map(\.name).joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !session.domainsVisited.isEmpty {
                Text(session.domainsVisited.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(FocusGuardConfig.current.fullSessionQuickPicks, id: \.self) { pick in
                    Button("\(Int(pick / 60))m") { convertDuration = pick }
                        .buttonStyle(.bordered)
                        .tint(convertDuration == pick ? .accentColor : .gray)
                }
            }

            HStack {
                Button("Back") { converting = false }
                Spacer()
                Button("Convert") { sessionManager.convertOpenSession(duration: convertDuration) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var presetControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save this as a preset")
                .font(.headline)
            TextField("Name", text: $presetName)
                .textFieldStyle(.roundedBorder)
            Text("Keeps these apps and a \(Int((session.plannedEnd?.timeIntervalSince(session.startedAt) ?? 1500) / 60)) minute default.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Back") { savingPreset = false }
                Spacer()
                Button("Save preset") {
                    sessionManager.savePreset(named: presetName, from: session)
                    savingPreset = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(presetName.nilIfBlank == nil)
            }
        }
    }
}

private struct ReviewStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
