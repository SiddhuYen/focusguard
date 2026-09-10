import AppKit

@MainActor
struct AppIdentityResolver {
    func frontmostApp() -> RunningApp? {
        guard let runningApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        if runningApplication.bundleIdentifier == BuildInfo.bundleID { return nil }
        return RunningApp(runningApplication: runningApplication)
    }

    func runningApplication(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    func displayName(for bundleID: String) -> String? {
        runningApplication(bundleID: bundleID)?.localizedName
    }

    /// Every regular app that is running right now, deduplicated by bundle ID.
    func runningApps() -> [RunningApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { RunningApp(runningApplication: $0) }
            .filter { seen.insert($0.bundleIdentifier).inserted }
    }
}
