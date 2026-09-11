#if DEBUG
import AppKit
import SwiftUI

/// Renders the gate offscreen to a PNG, so its look can be checked without a screen
/// recording permission or a person describing it.
///
///   FOCUSGUARD_RENDER_GATE=/tmp/gate.png <binary>
@MainActor
enum GateRenderer {
    /// A transcript that exercises the shapes most likely to look wrong: the help table,
    /// a preset list, warnings, and a session summary.
    private static func demoTranscript() -> [TerminalLine] {
        var lines: [TerminalLine] = [
            TerminalLine(text: "focusguard 0.2.0 (2) · gate", style: .banner),
            TerminalLine(text: "type a goal, or /help", style: .dim),
            TerminalLine(text: "", style: .dim),
            TerminalLine(text: "last goal: \"ship the reducer\"", style: .output),
            TerminalLine(text: "did you finish it? y / n", style: .output),
            TerminalLine(text: "finished? ▸ y", style: .input),
            TerminalLine(text: "logged as finished", style: .output),
            TerminalLine(text: "", style: .dim),
            TerminalLine(text: "focus ▸ /help", style: .input)
        ]
        for entry in GateCommandParser.help {
            lines.append(TerminalLine(
                text: "  " + entry.command.padding(toLength: 18, withPad: " ", startingAt: 0) + entry.description,
                style: .output
            ))
        }
        lines += [
            TerminalLine(text: "focus ▸ /presets", style: .input),
            TerminalLine(text: "  /p Email         25m  Outlook, Safari", style: .output),
            TerminalLine(text: "  /p Deep work     90m  Xcode, Terminal", style: .output),
            TerminalLine(text: "focus ▸ write the physics lab report", style: .input),
            TerminalLine(text: "which apps? [Xcode] — tab completes, return accepts", style: .dim),
            TerminalLine(text: "apps ▸ pages safari", style: .input),
            TerminalLine(text: "allowed: Pages, Safari", style: .output),
            TerminalLine(text: "browser included — /sites <domains> to limit it, /pin <url> for one page,", style: .dim),
            TerminalLine(text: "or /sites alone to allow everything that isn't blocked", style: .dim),
            TerminalLine(text: "apps ▸ /pin https://www.youtube.com/watch?v=lecture1&t=30", style: .input),
            TerminalLine(text: "pinned: youtube.com/watch?v=lecture1", style: .output),
            TerminalLine(text: "only that page — the rest of the site still counts as leaving", style: .dim),
            TerminalLine(text: "apps ▸ /sites youtube.com", style: .input),
            TerminalLine(text: "youtube.com is blocked and can never be allowlisted. You can pin one exact page on it instead.", style: .warn),
            TerminalLine(text: "how long? [25] minutes — 10 / 25 / 50 / 90", style: .dim),
            TerminalLine(text: "time ▸ 50", style: .input),
            TerminalLine(text: "▸ write the physics lab report · 50m · Pages, Safari", style: .success)
        ]
        return lines
    }

    static func render(to path: String, size: NSSize = NSSize(width: 1100, height: 760)) {
        let manager = FocusSessionManager.shared
        manager.suppressDisruptiveEffects = true

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Offscreen: this must not flash on anyone's display.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        let demo = ProcessInfo.processInfo.environment["FOCUSGUARD_RENDER_DEMO"] == "1" ? demoTranscript() : nil
        window.contentView = NSHostingView(
            rootView: ShieldRootView(isPrimary: true, demoLines: demo).environmentObject(manager)
        )
        window.orderFrontRegardless()

        // Give SwiftUI a beat to run onAppear and lay out before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated {
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    NSLog("FocusGuard: could not make a bitmap")
                    exit(1)
                }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    NSLog("FocusGuard: could not encode PNG")
                    exit(1)
                }
                try? data.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
                exit(0)
            }
        }
    }
}
#endif
