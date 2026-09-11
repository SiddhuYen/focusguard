import AppKit
import SwiftUI

/// The shield covers everything, including Focus Guard's own windows: opening Settings
/// from the gate looked like nothing happened. Utility windows raise themselves above the
/// shield while it is up, and drop back to normal when it comes down.
struct AboveShield: ViewModifier {
    let windowID: String

    func body(content: Content) -> some View {
        content
            .onAppear { raise() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                raise()
            }
    }

    private func raise() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: {
                    $0.identifier?.rawValue.hasPrefix(windowID) == true
                }) else { return }

                if let shieldLevel = ShieldWindowController.shared.currentLevel {
                    window.level = NSWindow.Level(rawValue: shieldLevel.rawValue + 1)
                    window.orderFrontRegardless()
                } else if window.level != .normal {
                    window.level = .normal
                }
            }
        }
    }
}

extension View {
    func aboveShield(_ windowID: String) -> some View {
        modifier(AboveShield(windowID: windowID))
    }
}
