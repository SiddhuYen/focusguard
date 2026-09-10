import AppKit
import SwiftUI

@main
struct FocusGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessionManager = FocusSessionManager.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(sessionManager)
        } label: {
            Label(sessionManager.menuBarTitle, systemImage: sessionManager.menuBarSystemImage)
        }
        .menuBarExtraStyle(.menu)

        Window("Focus Guard Settings", id: "settings") {
            SettingsView()
                .environmentObject(sessionManager)
                .frame(minWidth: 480, minHeight: 460)
        }

        Window("Session History", id: "history") {
            SessionHistoryView()
                .environmentObject(sessionManager)
                .frame(minWidth: 520, minHeight: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The launch guard decides safe mode from the modifier keys and the crash history,
    /// and the watchdog has to be running before anything can wedge the main thread. Both
    /// happen here, before SwiftUI builds a single window.
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            _ = FocusSessionManager.shared
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugHooks.runIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            FocusSessionManager.shared.prepareForTermination(reason: "terminate")
        }
    }
}
