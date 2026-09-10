import AppKit
import Foundation

/// Test affordances for the safety systems, debug builds only. Without these the watchdog
/// and the crash-loop breaker can only be exercised by actually wedging or killing the
/// app, which is not something to do on a Mac you are using.
///
///   FOCUSGUARD_SIMULATE_HANG=15   block the main thread for 15s at launch
///   FOCUSGUARD_SIMULATE_CRASH=1   die uncleanly ~1s after launch
///   FOCUSGUARD_SIMULATE_QUIT=3    quit cleanly after 3s, exercising the exit path
///   FOCUSGUARD_SIMULATE_RESTART_ESCAPE=1  enter safe mode as if the escape keys were held
enum DebugHooks {
    static func runIfRequested() {
        #if DEBUG
        if let seconds = value(for: "FOCUSGUARD_SIMULATE_HANG") {
            NSLog("FocusGuard: simulating a \(seconds)s main-thread hang")
            Thread.sleep(forTimeInterval: seconds)
        }

        if let delay = value(for: "FOCUSGUARD_SIMULATE_QUIT") {
            NSLog("FocusGuard: quitting cleanly in \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.terminate(nil)
            }
        }

        if let delay = value(for: "FOCUSGUARD_SIMULATE_CRASH") {
            NSLog("FocusGuard: simulating an unclean exit in \(delay)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // No clean-exit marker, exactly like a crash or a kill -9.
                _exit(1)
            }
        }
        #endif
    }

    private static func value(for key: String) -> TimeInterval? {
        guard let raw = ProcessInfo.processInfo.environment[key], let value = TimeInterval(raw), value > 0 else {
            return nil
        }
        return value
    }
}
