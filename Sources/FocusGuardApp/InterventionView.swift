import SwiftUI

struct InterventionView: View {
    let session: Session
    let violation: Violation
    let settings: Settings
    let permissions: PermissionHealth
    let onReturn: () -> Void
    let onEscape: (String?) -> Void
    let onEnd: () -> Void

    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !permissions.isHealthy {
                PermissionBanner(permissions: permissions)
            }

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
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
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if settings.requireReasonToLeave {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reason")
                        .font(.headline)
                    TextField("Why are you leaving?", text: $reason, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3, reservesSpace: true)
                }
            }

            HStack(spacing: 10) {
                Button {
                    onReturn()
                } label: {
                    Label("Return to \(session.anchor.name)", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                if settings.allowTemporaryEscapes {
                    Button {
                        onEscape(reason.nilIfBlank)
                    } label: {
                        Label("Leave for \(Int(settings.defaultEscapeDuration / 60)) minute", systemImage: "timer")
                    }
                    .disabled(settings.requireReasonToLeave && reason.nilIfBlank == nil)
                }

                Spacer()

                Button(role: .destructive) {
                    onEnd()
                } label: {
                    Label("End Focus", systemImage: "xmark.circle")
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        case .blockedSite: return "Blocked sites stay blocked in every session, and can't be added."
        case .unlistedSite(_, let url), .unpinnedPage(_, let url): return url
        case .unverifiableURL(let browser): return "Reading \(browser)'s tab failed, so this page can't be checked."
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
