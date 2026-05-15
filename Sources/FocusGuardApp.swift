import AppKit
import SwiftUI

@main
struct FocusGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessionManager = FocusSessionManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(sessionManager)
        } label: {
            Label(sessionManager.menuBarTitle, systemImage: sessionManager.menuBarSystemImage)
        }
        .menuBarExtraStyle(.menu)

        Window("FocusGuard Settings", id: "settings") {
            SettingsView()
                .environmentObject(sessionManager)
                .frame(minWidth: 440, minHeight: 360)
        }

        Window("Session History", id: "history") {
            SessionHistoryView()
                .environmentObject(sessionManager)
                .frame(minWidth: 520, minHeight: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
