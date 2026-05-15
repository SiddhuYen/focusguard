import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager

    var body: some View {
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

            Section("Current Status") {
                LabeledContent("State", value: sessionManager.menuBarTitle)
                LabeledContent("Current app", value: sessionManager.currentAppName)

                if let message = sessionManager.statusMessage {
                    HStack {
                        Text(message)
                        Spacer()
                        Button("Clear") {
                            sessionManager.clearStatusMessage()
                        }
                    }
                }
            }

            Section("MVP Scope") {
                Text("Global shortcuts, browser tab focus, and stricter blocking are intentionally left out of this first build.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
