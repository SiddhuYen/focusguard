import AppKit

@MainActor
struct AppIdentityResolver {
    func frontmostApp() -> RunningApp? {
        guard let runningApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return RunningApp(runningApplication: runningApplication)
    }

    func runningApplication(for session: FocusSession) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: session.allowedProcessIdentifier)
            ?? NSWorkspace.shared.runningApplications.first {
                $0.bundleIdentifier == session.allowedBundleID
            }
    }
}
