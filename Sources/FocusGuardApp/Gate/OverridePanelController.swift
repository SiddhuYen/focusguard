import AppKit
import SwiftUI

/// Hosts the override flow when it is started from the intervention panel or the review
/// rather than the gate, which shows it inline.
@MainActor
final class OverridePanelController: NSObject {
    static let shared = OverridePanelController()

    private var panel: FloatingPanel?

    func show(onComplete: @escaping (String) -> Void) {
        dismiss()

        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Emergency override"
        panel.titlebarAppearsTransparent = true
        panel.level = ShieldWindowController.shared.currentLevel.map {
            NSWindow.Level(rawValue: $0.rawValue + 1)
        } ?? .modalPanel
        panel.contentView = NSHostingView(
            rootView: OverrideView(
                onComplete: { [weak self] reason in
                    self?.dismiss()
                    onComplete(reason)
                },
                onCancel: { [weak self] in self?.dismiss() }
            )
            .environmentObject(FocusSessionManager.shared)
        )
        panel.center()
        panel.present()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}
