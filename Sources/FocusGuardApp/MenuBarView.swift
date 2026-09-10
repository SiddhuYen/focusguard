import SwiftUI

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

            if sessionManager.isSafeMode {
                Text("Safe mode: enforcement is off for this launch")
                Divider()
            }

            if let session = sessionManager.activeSession {
                Text(sessionManager.menuBarTitle)
                Text("Goal: \(session.goal)")
                Text("Time: \(session.elapsed.formattedDuration)")
                if let remaining = session.remaining() {
                    Text("Remaining: \(max(0, remaining).formattedDuration)")
                }
                Text("Attempts: \(session.violations.count)")
                if !session.additions.isEmpty {
                    Text("Added this session: \(session.additions.count)")
                }
                Divider()
            } else {
                Text("Focus Guard: Idle")
                Text("Current: \(sessionManager.currentAppName)")
                Divider()
            }

            Button {
                sessionManager.startFocusOnCurrentApp()
            } label: {
                Label("Focus on Current App", systemImage: "target")
            }
            .disabled(!sessionManager.canStartFocus)

            Button {
                sessionManager.presentMultiAppSelector()
            } label: {
                Label("Multi-App Focus", systemImage: "square.stack.3d.up.fill")
            }
            .disabled(!sessionManager.canStartFocus)

            Button {
                sessionManager.addCurrentAppToAllowed()
            } label: {
                Label("Add Current App to Session…", systemImage: "plus.app")
            }
            .disabled(sessionManager.canStartFocus)

            Button {
                sessionManager.stopFocus()
            } label: {
                Label("End Session", systemImage: "stop.circle")
            }
            .disabled(sessionManager.canStartFocus)

            Divider()

            Button {
                openWindow(id: "settings")
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                openWindow(id: "history")
            } label: {
                Label("Session History", systemImage: "clock.arrow.circlepath")
            }

            Divider()

            Button {
                sessionManager.quit()
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
    }
}
