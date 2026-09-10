import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager

    var body: some View {
        VStack(spacing: 18) {
            header

            Form {
                Section("Focus Rules") {
                    Stepper(
                        "Grace period: \(sessionManager.settings.gracePeriodSeconds) seconds",
                        value: $sessionManager.settings.gracePeriodSeconds,
                        in: 0...15
                    )

                    Toggle("Allow temporary one-minute escapes", isOn: $sessionManager.settings.allowTemporaryEscapes)
                    Toggle("Require a reason before escaping", isOn: $sessionManager.settings.requireReasonToLeave)
                }

                Section("Blocked Sites") {
                    Text("Domains you want to block during focus. One per line.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextEditor(text: Binding(
                        get: { sessionManager.blockedDomainsEditable.joined(separator: "\n") },
                        set: { sessionManager.blockedDomainsEditable = $0
                            .components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        }
                    ))
                    .frame(minHeight: 120)
                    .font(.system(.body, design: .monospaced))
                }

                Section("Current Status") {
                    LabeledContent("State", value: sessionManager.menuBarTitle)
                    LabeledContent("Current app", value: sessionManager.currentAppName)

                    if let message = sessionManager.statusMessage {
                        HStack {
                            Label(message, systemImage: "info.circle.fill")
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("Clear") {
                                sessionManager.clearStatusMessage()
                            }
                        }
                    }
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FocusGuard")
                            .font(.headline)

                        Text("Commit to one task at a time.")
                            .foregroundStyle(.secondary)

                        Text("Version 1.0")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
        }
        .padding(22)
        .frame(width: 480, height: 420)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 58, height: 58)
                .cornerRadius(12)

            Text("FocusGuard")
                .font(.title2.bold())

            Text("Stay committed to the app you chose.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
