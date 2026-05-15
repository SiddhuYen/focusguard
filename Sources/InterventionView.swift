import SwiftUI

struct InterventionView: View {
    let session: FocusSession
    let violation: FocusViolation
    let settings: UserSettings
    let onReturn: () -> Void
    let onEscape: (String?) -> Void
    let onEnd: () -> Void

    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("You left \(session.allowedAppName).")
                        .font(.title3.weight(.semibold))
                    Text("You switched to \(violation.attemptedAppName). Are you sure?")
                        .foregroundStyle(.secondary)
                }
            }

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
                    Label("Return to \(session.allowedAppName)", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderedProminent)

                if settings.allowTemporaryEscapes {
                    Button {
                        onEscape(reason.nilIfBlank)
                    } label: {
                        Label("Leave for 1 minute", systemImage: "timer")
                    }
                    .disabled(settings.requireReasonToLeave && reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

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
}
