import AppKit
import SwiftUI

/// Focus Guard's primary window. It is AppKit-owned rather than a SwiftUI scene because
/// in Phase 1 this same window becomes the gate: borderless, full-screen, above
/// everything, with sibling shields on the other displays.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    private var window: NSWindow?

    func show(activating: Bool = true) {
        let window = existingWindow()
        window.makeKeyAndOrderFront(nil)
        if activating { NSApp.activate(ignoringOtherApps: true) }
    }

    func hide() {
        window?.orderOut(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    private func existingWindow() -> NSWindow {
        if let window { return window }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Focus Guard"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 420)
        window.center()
        window.setFrameAutosaveName("FocusGuardMain")
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: MainWindowView().environmentObject(FocusSessionManager.shared)
        )
        self.window = window
        return window
    }

    /// Closing the window just puts it away: the app keeps enforcing, and the menu bar
    /// readout and Dock icon bring it back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
