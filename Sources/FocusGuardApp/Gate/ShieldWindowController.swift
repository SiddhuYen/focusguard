import AppKit
import SwiftUI

/// Covers every display, above everything. Two things use it: the gate, and the review when
/// a session's time runs out, so neither can be worked around. Debug builds are
/// deliberately escapable (3.9.4).
@MainActor
final class ShieldWindowController: NSObject {
    static let shared = ShieldWindowController()

    enum Content {
        case gate(GateContext)
        case review(Session, ReviewReason)
    }

    private var windows: [NSWindow] = []
    private var primaryWindow: NSWindow?
    private(set) var content: Content?
    private var screenObserver: NSObjectProtocol?
    private var debugDismissTimer: Timer?
    private var savedPresentationOptions: NSApplication.PresentationOptions?

    /// Debug builds sit below the menu bar so Xcode and Terminal stay reachable.
    private var shieldLevel: NSWindow.Level {
        BuildInfo.isDebugBuild ? .floating : NSWindow.Level(Int(CGShieldingWindowLevel()))
    }

    func show(context: GateContext) {
        present(.gate(context))
    }

    func showReview(session: Session, reason: ReviewReason) {
        present(.review(session, reason))
    }

    private func present(_ content: Content) {
        self.content = content

        if windows.isEmpty {
            build()
            observeScreenChanges()
        } else {
            // Gate to review and back swaps what is shown without taking the shield down,
            // so there is never a moment where the desktop is reachable.
            refreshContent()
        }

        bringToFront()

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

    /// Puts the shield back in front of whatever took focus.
    func bringToFront() {
        guard !windows.isEmpty else { return }
        for window in windows { window.orderFrontRegardless() }
        primaryWindow?.makeKeyAndOrderFront(nil)
        activate()
    }

    func hide() {
        debugDismissTimer?.invalidate()
        debugDismissTimer = nil
        setKiosk(false)
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        primaryWindow = nil
        content = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    var isVisible: Bool { windows.contains { $0.isVisible } }

    /// The level the shield is sitting at, or nil when it is down.
    var currentLevel: NSWindow.Level? {
        isVisible ? shieldLevel : nil
    }

    /// Taking focus away from whatever you are working in is the point here. Both APIs:
    /// activate(ignoringOtherApps:) is deprecated, and the cooperative activation that
    /// replaced it can be declined. Activation is asynchronous, so it is retried briefly.
    private func activate(attempt: Int = 0) {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        guard attempt < 5 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.windows.isEmpty, !NSApp.isActive else { return }
                self.primaryWindow?.makeKeyAndOrderFront(nil)
                self.activate(attempt: attempt + 1)
            }
        }
    }

    /// Kiosk options are release-only and only while the shield is up. An invalid
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

            let isPrimary = screen == mainScreen
            if isPrimary { primaryWindow = window }
            window.contentView = hostingView(isPrimary: isPrimary)
            return window
        }
        if primaryWindow == nil { primaryWindow = windows.first }
    }

    private func refreshContent() {
        for window in windows {
            window.contentView = hostingView(isPrimary: window === primaryWindow)
        }
    }

    private func hostingView(isPrimary: Bool) -> NSView {
        NSHostingView(
            rootView: ShieldRootView(isPrimary: isPrimary, content: content)
                .environmentObject(FocusSessionManager.shared)
        )
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible, let content = self.content else { return }
                // Plugging in a display must not leave a gap in the gate or the review.
                for window in self.windows { window.orderOut(nil) }
                self.windows.removeAll()
                self.primaryWindow = nil
                self.present(content)
            }
        }
    }
}

/// Borderless windows refuse key status by default, and the gate and review take typing.
private final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
