import AppKit
import SwiftUI

@MainActor
final class InterventionEngine {
    private var window: NSPanel?
    private var delegate: InterventionWindowDelegate?

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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: settings.requireReasonToLeave ? 390 : 310),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let delegate = InterventionWindowDelegate()
        panel.title = "FocusGuard"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = delegate
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = panel
        self.delegate = delegate
    }

    func bringToFront() {
        guard let window else { return }

        window.level = .modalPanel
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.orderOut(nil)
        window?.delegate = nil
        window = nil
        delegate = nil
    }
}

private final class InterventionWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        false
    }
}
