import AppKit
import SwiftUI

@MainActor
final class MultiAppSelectorEngine {
    private var window: NSPanel?

    func present(sessionManager: FocusSessionManager) {
        // Dismiss any existing panel
        dismiss()

        // Ensure fresh selection each time
        sessionManager.resetMultiAppSelection()

        let view = MultiAppSelectorView()
            .environmentObject(sessionManager)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Multi‑App Focus"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = panel
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}
