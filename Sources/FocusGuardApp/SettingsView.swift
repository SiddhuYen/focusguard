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

                Section("The Gate") {
                    Text("The gate appears when there is no session running.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("On unlock", isOn: $sessionManager.settingsDraft.gateOnUnlock)
                    Toggle("On wake", isOn: $sessionManager.settingsDraft.gateOnWake)
                    Toggle("On returning from idle", isOn: $sessionManager.settingsDraft.gateOnIdleReturn)
                    Picker("Idle counts as away after", selection: $sessionManager.settingsDraft.idleThreshold) {
                        ForEach([5.0, 10.0, 15.0, 30.0], id: \.self) { minutes in
                            Text("\(Int(minutes)) min").tag(TimeInterval(minutes * 60))
                        }
                    }
                }

                Section("Sessions") {
                    Picker("Maximum session length", selection: $sessionManager.settingsDraft.maxFullSessionLength) {
                        ForEach([60.0, 90.0, 120.0, 180.0], id: \.self) { minutes in
                            Text("\(Int(minutes)) min").tag(TimeInterval(minutes * 60))
                        }
                    }
                    LabeledContent("Open sessions", value: "5 min, one 5 min extension")
                    LabeledContent("Launch at login", value: SystemControl.loginItemStatus)
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

                Section("Always Allowed") {
                    Text("These never count as a violation, in any session. Adding to this list is a loosening change and waits 24 hours.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(sessionManager.baselineDisplayNames, id: \.bundleID) { entry in
                        LabeledContent(entry.name, value: entry.bundleID)
                            .font(.caption)
                    }
                }

                Section("Permissions") {
                    LabeledContent("Accessibility", value: sessionManager.permissions.accessibilityTrusted ? "Granted" : "Missing")
                    LabeledContent("Automation", value: sessionManager.permissions.automationAuthorized ? "Granted" : "Missing")
                    HStack {
                        if !sessionManager.permissions.accessibilityTrusted {
                            Button("Request Accessibility…") { PermissionMonitor.promptForAccessibility() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Open Accessibility Settings") { PermissionMonitor.openAccessibilitySettings() }
                        Button("Open Automation Settings") { PermissionMonitor.openAutomationSettings() }
                    }
                }

                Section("Current Status") {
                    LabeledContent("State", value: sessionManager.stateSummary)
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
