import AppKit
import SwiftUI

@MainActor
final class InterventionEngine {
    private var window: NSPanel?

    func present(
        session: FocusSession,
        violation: FocusViolation,
        settings: UserSettings,
        onReturn: @escaping () -> Void,
        onEscape: @escaping (String?) -> Void,
        onEnd: @escaping () -> Void
    ) {
        if window != nil {
            dismiss()
        }

        let view = InterventionView(
            session: session,
            violation: violation,
            settings: settings,
            onReturn: onReturn,
            onEscape: onEscape,
            onEnd: onEnd
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: settings.requireReasonToLeave ? 310 : 230),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = "FocusGuard"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
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
