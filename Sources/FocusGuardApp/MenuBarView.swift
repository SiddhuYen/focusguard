import SwiftUI

/// Status readout. Anything you can *do* lives in the window, the gate, or the panels;
/// this exists so you can see where you stand without leaving the app you are working in.
/// There is deliberately no Quit item (3.4).
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
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

            if let override = sessionManager.overrideState {
                Text("Override active until \(override.until.formatted(date: .omitted, time: .shortened))")
                Text(override.reason)
                Button("End override now") { sessionManager.endOverride() }
                Divider()
            } else if sessionManager.isSafeMode {
                Text("Safe mode: enforcement is off for this launch")
                Divider()
            } else if let session = sessionManager.activeSession {
                Text(session.goal)
                if let remaining = session.remaining() {
                    Text("\(max(0, remaining).formattedDuration) left")
                } else {
                    Text("Running for \(session.elapsed.formattedDuration)")
                }
                Text("\(session.kind == .open ? "Open session" : "Focus session") · \(session.violations.count) attempts")

                Divider()

                Button("Add Current App to Session…") { sessionManager.addCurrentAppToAllowed() }
                Button("End Session…") { sessionManager.stopFocus() }
            } else {
                Text("No session. Every stretch starts with a goal.")
                Button("Go to the gate") { sessionManager.showGate() }
            }

            Divider()

            Button {
                MainWindowController.shared.show()
            } label: {
                Label("Open Focus Guard", systemImage: "target")
            }

            Button {
                openWindow(id: "history")
            } label: {
                Label("Session History", systemImage: "clock.arrow.circlepath")
            }

            Button {
                openWindow(id: "settings")
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}
