import SwiftUI
import AppKit

struct MultiAppSelectorView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Form {
                Section("Select Allowed Apps") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            TextField("Search apps…", text: $sessionManager.multiAppSearchText)
                                .textFieldStyle(.roundedBorder)

                            Button("Add Current App") {
                                sessionManager.addCurrentAppToAllowed()
                            }
                        }

                        if !sessionManager.multiAppSearchResults.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Search Results")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                ForEach(sessionManager.multiAppSearchResults, id: \.bundleIdentifier) { app in
                                    HStack {
                                        Text(app.displayName)
                                        Spacer()
                                        Button("Add") {
                                            sessionManager.addAllowedApp(app)
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Allowed Apps")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if sessionManager.multiAppAllowedBundleIDs.isEmpty {
                                Text("No apps added yet.")
                                    .foregroundStyle(.tertiary)
                            } else {
                                ForEach(sessionManager.multiAppAllowedDisplayItems, id: \.bundleIdentifier) { item in
                                    HStack {
                                        Text(item.displayName)
                                        Spacer()
                                        Button(role: .destructive) {
                                            sessionManager.removeAllowedApp(item)
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Start Multi-App Focus") {
                    sessionManager.startMultiAppFocusAndDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 520, height: 460)
        .onAppear {
            // Ensure a fresh selection every time
            sessionManager.resetMultiAppSelection()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Multi‑App Focus")
                .font(.title2.bold())
            Text("Choose the apps you’ll allow during this focus session. Browsers whose tabs Focus Guard can’t read can’t be added.")
                .foregroundStyle(.secondary)
        }
    }
}

