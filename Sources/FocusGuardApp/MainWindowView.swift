import AppKit
import SwiftUI

/// The app's one window. Idle it asks what you are doing; running it shows the session.
/// Phase 1 turns the idle state into the real gate: full screen, every display, with
/// presets and recents under the goal field.
struct MainWindowView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager

    var body: some View {
        VStack(spacing: 0) {
            if !sessionManager.permissions.isHealthy {
                PermissionBanner(permissions: sessionManager.permissions)
                    .padding([.horizontal, .top], 20)
            }

            if sessionManager.isSafeMode {
                SafeModeBanner()
                    .padding([.horizontal, .top], 20)
            }

            if let session = sessionManager.activeSession {
                ActiveSessionView(session: session)
            } else {
                StartSessionView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SafeModeBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            Text("Safe mode: enforcement is off for this launch.")
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Idle

struct StartSessionView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    @FocusState private var goalFieldFocused: Bool
    @State private var goal = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What are you working on?")
                    .font(.system(size: 26, weight: .semibold))
                Text("Every stretch of time on this Mac starts with a goal.")
                    .foregroundStyle(.secondary)
            }

            TextField("Finish the reducer, write the draft, edit the clip…", text: $goal)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                .focused($goalFieldFocused)
                .onSubmit(start)

            VStack(alignment: .leading, spacing: 8) {
                Text("Apps you'll need")
                    .font(.headline)
                AppPickerGrid()
            }

            Spacer(minLength: 0)

            HStack {
                if let hint = specificityHint {
                    Label(hint, systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("⏎")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                Button("Start Session", action: start)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(goal.nilIfBlank == nil)
            }
        }
        .padding(24)
        .onAppear { goalFieldFocused = true }
    }

    /// Soft nudge only, never a block (3.3).
    private var specificityHint: String? {
        guard let trimmed = goal.nilIfBlank else { return nil }
        let isVague = trimmed.count < 12 || !trimmed.contains(" ")
        return isVague ? "What does done look like?" : nil
    }

    private func start() {
        guard let goal = goal.nilIfBlank else { return }
        sessionManager.startSession(goal: goal)
        self.goal = ""
    }
}

private struct AppPickerGrid: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(sessionManager.pickerApps) { app in
                    AppChip(
                        app: app,
                        isSelected: sessionManager.multiAppAllowedBundleIDs.contains(app.bundleIdentifier),
                        isAllowed: Allowlist.canAllowlist(bundleID: app.bundleIdentifier)
                    ) {
                        sessionManager.toggleAllowed(bundleID: app.bundleIdentifier)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 150)
    }
}

private struct AppChip: View {
    let app: RunningApp
    let isSelected: Bool
    let isAllowed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 7) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 17, height: 17)
                }
                Text(app.name)
                    .lineLimit(1)
                    .font(.subheadline)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isAllowed)
        .opacity(isAllowed ? 1 : 0.45)
        .help(isAllowed ? app.bundleIdentifier : "Focus Guard can't read this browser's tabs, so it can't police them.")
    }
}

// MARK: - In session

struct ActiveSessionView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.goal)
                    .font(.system(size: 24, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(session.kind == .open ? "Open session" : "Focus session")
                    .foregroundStyle(.secondary)
            }

            SessionProgress(session: session, now: sessionManager.now)

            VStack(alignment: .leading, spacing: 8) {
                Text("Allowed")
                    .font(.headline)
                FlowRow(items: session.allowedBundleIDs) { bundleID in
                    Text(sessionManager.displayName(for: bundleID))
                        .font(.subheadline)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 24) {
                Stat(label: "Attempts", value: "\(session.violations.count)")
                Stat(label: "Added", value: "\(session.additions.count)")
                Stat(label: "Elapsed", value: session.elapsed.formattedDuration)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Add Current App…") {
                    sessionManager.addCurrentAppToAllowed()
                }
                Spacer()
                Button("End Session", role: .destructive) {
                    sessionManager.stopFocus()
                }
                .controlSize(.large)
            }
        }
        .padding(24)
    }
}

private struct SessionProgress: View {
    let session: Session
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let plannedEnd = session.plannedEnd {
                let total = plannedEnd.timeIntervalSince(session.startedAt)
                let elapsed = now.timeIntervalSince(session.startedAt)
                ProgressView(value: min(max(elapsed / max(total, 1), 0), 1))
                Text("\(max(0, plannedEnd.timeIntervalSince(now)).formattedDuration) left")
                    .font(.title3.monospacedDigit())
            } else {
                Text(session.elapsed.formattedDuration)
                    .font(.title3.monospacedDigit())
                Text("No end time set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Minimal wrapping row, so the allowed list does not clip with many apps.
private struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}
