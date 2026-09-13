import AppKit

/// A panel that appears over whatever you are doing, including a full-screen app, without
/// dragging you to another Space.
///
/// Focus Guard is a regular app with a Dock icon, and activating a regular app makes macOS
/// switch to the Space its windows belong to: the desktop. So an intervention that called
/// NSApp.activate() landed on the desktop while you sat on the blocked site, and the review
/// froze a full-screen app it had put kiosk mode over. A non-activating panel joins the
/// current Space, full-screen ones included, and takes the keyboard without activating.
final class FloatingPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style.union(.nonactivatingPanel),
            backing: backingStoreType,
            defer: flag
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Front and focused, in the Space you are already in.
    func present() {
        orderFrontRegardless()
        makeKey()
    }
}
