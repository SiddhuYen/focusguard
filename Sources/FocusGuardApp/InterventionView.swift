import SwiftUI

/// Shown when you leave your session. Three ways out: go back, widen the session with a
/// reason, or end it and face the review (3.4). The timed escape is gone.
struct InterventionView: View {
    let session: Session
    let violation: Violation
    let permissions: PermissionHealth
    let onReturn: () -> Void
    let onAdd: (String) -> Void
    let onEnd: () -> Void
    let onFixPermissions: () -> Void
    let onOverride: () -> Void

    @State private var addingReason = false
    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !permissions.isHealthy {
                PermissionBanner(permissions: permissions)
            }

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.title3.weight(.semibold))
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Your goal")
                    .font(.headline)
                Text(session.goal)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let remaining = session.remaining() {
                    Text("\(max(0, remaining).formattedDuration) left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if addingReason {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Why does this belong in this session?")
                        .font(.headline)
                    TextField("Reason", text: $reason, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2, reservesSpace: true)
                    HStack {
                        Button("Cancel") { addingReason = false; reason = "" }
                        Spacer()
                        Button("Add for this session") { onAdd(reason) }
                            .buttonStyle(.borderedProminent)
                            .disabled(reason.nilIfBlank == nil)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        onReturn()
                    } label: {
                        Label("Return to \(session.anchor.name)", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                    if violation.isAddable {
                        Button("Add to this session…") { addingReason = true }
                    } else if case .unverifiableURL = violation.kind {
                        Button("Fix permissions…") { onFixPermissions() }
                            .buttonStyle(.borderedProminent)
                    }

                    Spacer()

                    Button("End session", role: .destructive) { onEnd() }
                }

                if case .blockedSite = violation.kind {
                    Text("Blocked sites can never be added to a session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Emergency override…") { onOverride() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var icon: String {
        switch violation.kind {
        case .unverifiableURL: return "eye.trianglebadge.exclamationmark.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var headline: String {
        switch violation.kind {
        case .app: return "You left \(session.anchor.name)."
        case .blockedSite(let domain, _): return "\(domain) is blocked."
        case .unlistedSite(let host, _): return "\(host) is not in this session."
        case .unpinnedPage(let host, _): return "That is not the pinned page on \(host)."
        case .unverifiableURL: return "Focus Guard can't verify this page."
        }
    }

    private var detail: String {
        switch violation.kind {
        case .app(let app): return "You switched to \(app.name). Are you sure?"
        case .blockedSite: return "Blocked sites stay blocked in every session."
        case .unlistedSite(_, let url), .unpinnedPage(_, let url): return url
        case .unverifiableURL: return "Reading \(violation.app.name)'s tab failed, so this page can't be checked."
        }
    }
}

struct PermissionBanner: View {
    let permissions: PermissionHealth

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(permissions.summary)
                    .font(.subheadline.weight(.semibold))
                Text("Enforcement is degraded until this is fixed in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Fix") {
                if !permissions.accessibilityTrusted {
                    PermissionMonitor.promptForAccessibility()
                } else {
                    PermissionMonitor.openAutomationSettings()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
