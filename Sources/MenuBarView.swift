import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var sessionManager: FocusSessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = sessionManager.activeSession {
                Text(sessionManager.menuBarTitle)
                Text("Time: \(session.elapsed.formattedDuration)")
                Text("Escapes: \(session.escapes.count)")
                Text("Attempts: \(session.violations.count)")

                Divider()
            } else {
                Text("Focus App: Idle")
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
                sessionManager.stopFocus()
            } label: {
                Label("Stop Focus", systemImage: "stop.circle")
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
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
    }
}
