import AppKit
import SwiftUI

/// Floating panel for the end-of-session review. Like the intervention panel it cannot be
/// closed: the session ends by answering, not by dismissing.
@MainActor
final class ReviewPanelController: NSObject, NSWindowDelegate {
    static let shared = ReviewPanelController()

    private var panel: NSPanel?

    func show(session: Session, reason: ReviewReason) {
        dismiss()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Focus Guard"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: ReviewView(session: session, reason: reason)
                .environmentObject(FocusSessionManager.shared)
        )
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    func dismiss() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
}
