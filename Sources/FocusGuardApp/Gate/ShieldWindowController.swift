import AppKit
import SwiftUI

/// The gate: one window per display, covering everything, with the setup UI on the main
/// display (3.1). Debug builds are deliberately escapable (3.9.4).
@MainActor
final class ShieldWindowController: NSObject {
    static let shared = ShieldWindowController()

    private var windows: [NSWindow] = []
    private var context: GateContext?
    private var screenObserver: NSObjectProtocol?
    private var debugDismissTimer: Timer?
    private var savedPresentationOptions: NSApplication.PresentationOptions?

    /// Debug builds sit below the menu bar so Xcode and Terminal stay reachable.
    private var shieldLevel: NSWindow.Level {
        BuildInfo.isDebugBuild ? .floating : NSWindow.Level(Int(CGShieldingWindowLevel()))
    }

    func show(context: GateContext) {
        self.context = context

        if windows.isEmpty {
            build()
            observeScreenChanges()
        } else {
            refreshContent()
        }

        for window in windows { window.orderFrontRegardless() }
        windows.first?.makeKey()
        NSApp.activate(ignoringOtherApps: true)

        #if DEBUG
        debugDismissTimer?.invalidate()
        debugDismissTimer = Timer.scheduledTimer(
            withTimeInterval: FocusGuardConfig.current.debugShieldAutoDismiss,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                NSLog("FocusGuard: debug shield auto-dismissed")
                self?.hide()
            }
        }
        #endif
    }

    func hide() {
        debugDismissTimer?.invalidate()
        debugDismissTimer = nil
        setKiosk(false)
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    var isVisible: Bool { windows.contains { $0.isVisible } }

    /// Kiosk options are release-only and only while the gate is up. An invalid
    /// combination raises an ObjC exception, so the set is fixed and checked against the
    /// documented rules: hideMenuBar and disableProcessSwitching both require hideDock.
    func setKiosk(_ enabled: Bool) {
        #if !DEBUG
        if enabled {
            guard savedPresentationOptions == nil else { return }
            savedPresentationOptions = NSApp.presentationOptions
            NSApp.activate(ignoringOtherApps: true)
            NSApp.presentationOptions = [
                .hideDock,
                .hideMenuBar,
                .disableProcessSwitching,
                .disableForceQuit,
                .disableSessionTermination,
                .disableHideApplication
            ]
        } else if let saved = savedPresentationOptions {
            NSApp.presentationOptions = saved
            savedPresentationOptions = nil
        }
        #endif
    }

    // MARK: - Windows

    private func build() {
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        windows = NSScreen.screens.map { screen in
            let window = ShieldWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.setFrame(screen.frame, display: true)
            window.level = shieldLevel
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
            window.hasShadow = false
            window.isReleasedWhenClosed = false

            window.contentView = NSHostingView(
                rootView: ShieldRootView(isPrimary: screen == mainScreen)
                    .environmentObject(FocusSessionManager.shared)
            )
            return window
        }
    }

    private func refreshContent() {
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        for window in windows {
            let isPrimary = window.screen == mainScreen || windows.count == 1
            window.contentView = NSHostingView(
                rootView: ShieldRootView(isPrimary: isPrimary)
                    .environmentObject(FocusSessionManager.shared)
            )
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible, let context = self.context else { return }
                // Plugging in a display must not leave a gap in the gate.
                for window in self.windows { window.orderOut(nil) }
                self.windows.removeAll()
                self.show(context: context)
            }
        }
    }
}

/// Borderless windows refuse key status by default, and the goal field has to be typable.
private final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
