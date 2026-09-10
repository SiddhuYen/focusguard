import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager

    var body: some View {
        VStack(spacing: 18) {
            header

            Form {
                if !sessionManager.permissions.isHealthy {
                    Section {
                        PermissionBanner(permissions: sessionManager.permissions)
                    }
                }

                Section("Focus Rules") {
                    Toggle("Allow temporary escapes", isOn: $sessionManager.settingsDraft.allowTemporaryEscapes)
                    Toggle("Require a reason before escaping", isOn: $sessionManager.settingsDraft.requireReasonToLeave)
                }

                Section("Blocked Sites") {
                    Text("Blocked in every session, always. Adding one applies immediately; removing one takes 24 hours.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextEditor(text: Binding(
                        get: { sessionManager.blockedDomainsEditable.joined(separator: "\n") },
                        set: { sessionManager.blockedDomainsEditable = $0.components(separatedBy: .newlines) }
                    ))
                    .frame(minHeight: 110)
                    .font(.system(.body, design: .monospaced))
                }

                if !sessionManager.pendingChanges.isEmpty {
                    Section("Pending Changes") {
                        ForEach(sessionManager.pendingChanges) { pending in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pending.change.summary)
                                    Text("Takes effect \(pending.effectiveAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Cancel") {
                                    sessionManager.cancelPendingChange(pending.id)
                                }
                            }
                        }
                    }
                }

                Section("Permissions") {
                    LabeledContent("Accessibility", value: sessionManager.permissions.accessibilityTrusted ? "Granted" : "Missing")
                    LabeledContent("Automation", value: sessionManager.permissions.automationAuthorized ? "Granted" : "Missing")
                    HStack {
                        Button("Open Accessibility Settings") { PermissionMonitor.openAccessibilitySettings() }
                        Button("Open Automation Settings") { PermissionMonitor.openAutomationSettings() }
                    }
                }

                Section("Current Status") {
                    LabeledContent("State", value: sessionManager.menuBarTitle)
                    LabeledContent("Current app", value: sessionManager.currentAppName)

                    if let message = sessionManager.statusMessage {
                        HStack {
                            Label(message, systemImage: "info.circle.fill")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear") { sessionManager.clearStatusMessage() }
                        }
                    }
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Focus Guard")
                            .font(.headline)
                        Text("Commit to one task at a time.")
                            .foregroundStyle(.secondary)
                        Text("Version \(BuildInfo.versionStamp)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
        }
        .padding(22)
        .frame(width: 500, height: 520)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 58, height: 58)
                .cornerRadius(12)

            Text("Focus Guard")
                .font(.title2.bold())

            Text("Stay committed to the app you chose.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
