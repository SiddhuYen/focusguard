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
                NoSessionView()
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

// MARK: - Not in a session

/// With the gate model there is no idle state: if no session is running, the gate is up
/// (or an override is). This window then just points you back at it.
struct NoSessionView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: sessionManager.overrideState == nil ? "target" : "lock.open.trianglebadge.exclamationmark.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)

            if let override = sessionManager.overrideState {
                Text("Override active")
                    .font(.title3.weight(.semibold))
                Text("Enforcement is suspended until \(override.until.formatted(date: .omitted, time: .shortened)).")
                    .foregroundStyle(.secondary)
                Text(override.reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("End override now") { sessionManager.endOverride() }
            } else if sessionManager.isSafeMode {
                Text("Safe mode")
                    .font(.title3.weight(.semibold))
                Text("Enforcement is off for this launch. The gate returns on the next unlock or wake.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Every stretch of time starts with a goal")
                    .font(.title3.weight(.semibold))
                Text("State yours at the gate to get started.")
                    .foregroundStyle(.secondary)
                Button("Go to the gate") { sessionManager.showGate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
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
                .help("Goes through the end-of-session review")
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
