import SwiftUI

/// Status readout. Anything you can *do* lives in the window; this exists so you can see
/// where you stand without leaving the app you are working in.
struct MenuBarView: View {
    @EnvironmentObject private var sessionManager: FocusSessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !sessionManager.permissions.isHealthy {
                Button {
                    sessionManager.openPermissionSettings()
                } label: {
                    Label(sessionManager.permissions.summary, systemImage: "exclamationmark.octagon.fill")
                }
                Divider()
            }

            if sessionManager.isSafeMode {
                Text("Safe mode: enforcement is off for this launch")
                Divider()
            }

            if let session = sessionManager.activeSession {
                Text(session.goal)
                if let remaining = session.remaining() {
                    Text("\(max(0, remaining).formattedDuration) left")
                } else {
                    Text("Running for \(session.elapsed.formattedDuration)")
                }
                Text("Attempts: \(session.violations.count)")
            } else {
                Text("No session. Every stretch starts with a goal.")
                Text("Current app: \(sessionManager.currentAppName)")
            }

            Divider()

            Button {
                MainWindowController.shared.show()
            } label: {
                Label(sessionManager.activeSession == nil ? "Start a Session…" : "Open Focus Guard", systemImage: "target")
            }
        }
    }
}
