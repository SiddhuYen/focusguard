import AppKit
import SwiftUI

@MainActor
final class InterventionEngine {
    private var window: FloatingPanel?
    private var delegate: InterventionWindowDelegate?

    func present(
        session: Session,
        violation: Violation,
        permissions: PermissionHealth,
        onReturn: @escaping () -> Void,
        onAdd: @escaping (String) -> Void,
        onEnd: @escaping () -> Void,
        onFixPermissions: @escaping () -> Void,
        onOverride: @escaping () -> Void
    ) {
        if window != nil { dismiss() }

        let view = InterventionView(
            session: session,
            violation: violation,
            permissions: permissions,
            onReturn: onReturn,
            onAdd: onAdd,
            onEnd: onEnd,
            onFixPermissions: onFixPermissions,
            onOverride: onOverride
        )

        var height: CGFloat = 340
        if !permissions.isHealthy { height += 56 }

        // Non-activating, so it appears over the app you just switched to, full screen
        // included, instead of pulling you back to the desktop Space.
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: height),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let delegate = InterventionWindowDelegate()
        panel.title = "Focus Guard"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.delegate = delegate
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.present()

        window = panel
        self.delegate = delegate
    }

    func bringToFront() {
        guard let window else { return }
        window.level = .modalPanel
        window.present()
    }

    func dismiss() {
        window?.orderOut(nil)
        window?.delegate = nil
        window = nil
        delegate = nil
    }
}

private final class InterventionWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }
}
