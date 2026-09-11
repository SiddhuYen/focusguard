import SwiftUI

/// The emergency override (3.7): a reason, an exact phrase you have to type out, and a
/// countdown. Slow and visible on purpose, and every step lands in the daily review.
struct OverrideView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    @State private var reason = ""
    @State private var typed = ""
    @State private var countdown: TimeInterval = 0
    @State private var counting = false
    @State private var pasteAttempted = false
    @State private var timer: Timer?

    private var phrase: String { sessionManager.settingsDraft.overridePhrase }
    private var phraseMatches: Bool { typed.trimmingCharacters(in: .whitespaces) == phrase }
    private var canStartCountdown: Bool { reason.nilIfBlank != nil && phraseMatches }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Emergency override")
                    .font(.title2.weight(.semibold))
                Text("Suspends everything, blocked sites included, for \(Int(sessionManager.settingsDraft.overrideDuration / 60)) minutes. It goes to the top of your daily review.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Why?").font(.headline)
                TextField("What is happening?", text: $reason, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2, reservesSpace: true)
                    .disabled(counting)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Type this exactly").font(.headline)
                Text(phrase)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.disabled)
                TextField("", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .disabled(counting)
                    .onChange(of: typed) { old, new in
                        // Typing only, no pasting: a jump of several characters is a paste.
                        if new.count > old.count + 1 {
                            typed = old
                            pasteAttempted = true
                        }
                    }
                if pasteAttempted {
                    Text("Type it out. Pasting is not accepted.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !typed.isEmpty, !phraseMatches {
                    Text(phrase.hasPrefix(typed.trimmingCharacters(in: .whitespaces))
                        ? "\(phrase.count - typed.trimmingCharacters(in: .whitespaces).count) characters to go."
                        : "That does not match yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if reason.nilIfBlank == nil {
                    Text("A reason is required.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if counting {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: 1 - countdown / sessionManager.settingsDraft.overrideCountdown)
                    Text("\(Int(ceil(countdown)))s — \(reason)")
                        .font(.callout.monospacedDigit())
                    if let goal = sessionManager.activeSession?.goal {
                        Text("Your goal was: \(goal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Cancel") { stop(); onCancel() }
                Spacer()
                if counting {
                    Button("Waiting…") { }
                        .disabled(true)
                } else {
                    Button("Start countdown") { startCountdown() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canStartCountdown)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .onDisappear { stop() }
    }

    private func startCountdown() {
        countdown = sessionManager.settingsDraft.overrideCountdown
        counting = true
        timer?.invalidate()
        let countdownTimer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                countdown -= 1
                if countdown <= 0 {
                    stop()
                    onComplete(reason.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        // Registered in every mode the panel might put the run loop into, or the clock
        // silently stops while the panel is up.
        for mode in [RunLoop.Mode.common, .modalPanel, .eventTracking] {
            RunLoop.main.add(countdownTimer, forMode: mode)
        }
        timer = countdownTimer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        counting = false
    }
}
