import AppKit
import SwiftUI

@main
struct FocusGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessionManager = FocusSessionManager.shared

    var body: some Scene {
        // Status readout only: the window and the Dock icon are where you do things.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(sessionManager)
        } label: {
            if sessionManager.menuBarStatusText.isEmpty {
                Image(systemName: sessionManager.menuBarSystemImage)
            } else {
                Label(sessionManager.menuBarStatusText, systemImage: sessionManager.menuBarSystemImage)
            }
        }
        .menuBarExtraStyle(.menu)

        .commands { FocusGuardCommands(sessionManager: sessionManager) }

        Window("Focus Guard Settings", id: "settings") {
            SettingsView()
                .environmentObject(sessionManager)
                .frame(minWidth: 480, minHeight: 460)
        }
        .defaultPosition(.center)

        Window("Session History", id: "history") {
            SessionHistoryView()
                .environmentObject(sessionManager)
                .frame(minWidth: 520, minHeight: 420)
        }
        .defaultPosition(.center)
    }
}

/// A regular app needs real menu commands: the status item is a readout now, not a menu.
struct FocusGuardCommands: Commands {
    @ObservedObject var sessionManager: FocusSessionManager
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: "settings") }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Session") {
            Button("Focus Guard Window") { MainWindowController.shared.show() }
                .keyboardShortcut("0", modifiers: .command)

            Divider()

            Button("Add Current App to Session…") { sessionManager.addCurrentAppToAllowed() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(sessionManager.activeSession == nil)

            Button("End Session") { sessionManager.stopFocus() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(sessionManager.activeSession == nil)

            Divider()

            Button("Session History") { openWindow(id: "history") }
                .keyboardShortcut("y", modifiers: .command)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The launch guard decides safe mode from the modifier keys and the crash history,
    /// and the watchdog has to be running before anything can wedge the main thread. Both
    /// happen here, before a single window exists.
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            FocusSessionManager.shared.start()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            DebugHooks.runIfRequested()
            // A resumed session means you were already working: stay out of the way.
            if FocusSessionManager.shared.activeSession == nil {
                MainWindowController.shared.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { MainWindowController.shared.show() }
        return true
    }

    /// Quitting is now one Command-Q away, so it goes through the same commitment prompt
    /// as ending a session from the window.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let manager = FocusSessionManager.shared
            guard manager.activeSession != nil else { return .terminateNow }
            return manager.confirmQuit() ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            FocusSessionManager.shared.prepareForTermination(reason: "terminate")
        }
    }
}
