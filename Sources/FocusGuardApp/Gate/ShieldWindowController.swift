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

    /// Puts the shield back in front of whatever took focus, in the Space you are in.
    func bringToFront() {
        guard !windows.isEmpty else { return }
        for window in windows { window.orderFrontRegardless() }
        primaryWindow?.makeKey()
        activateForGate()
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

    /// Only the gate takes activation, because kiosk mode needs the app active. Forcing
    /// activation while you are in a full-screen app makes macOS switch to Focus Guard's own
    /// Space: that is what froze the screen at time-up, and a retry loop here made it
    /// flicker. The review shows as a non-activating panel on every Space and takes the
    /// keyboard without it. One attempt, never a loop.
    private func activateForGate() {
        guard case .some(.gate) = content, !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
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
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
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

/// A borderless, non-activating panel: it joins whatever Space you are in, full-screen apps
/// included, and still becomes key so the gate and review can take typing.
private final class ShieldWindow: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
