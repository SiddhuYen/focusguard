import AppKit
import Foundation

/// An app you can allow in a session, whether or not it is running. The gate is where you
/// name the apps you are *about* to open, so a list of running apps is not enough.
struct CatalogApp: Identifiable, Equatable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let isRunning: Bool
    let iconPath: String?

    static func == (lhs: CatalogApp, rhs: CatalogApp) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.isRunning == rhs.isRunning && lhs.name == rhs.name
    }
}

@MainActor
final class AppCatalog {
    private(set) var installed: [CatalogApp] = []
    private var iconCache: [String: NSImage] = [:]

    private static let searchPaths = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications"
    ]

    /// Scans the usual application folders. Around a tenth of a second for ~110 apps, so
    /// the first call is synchronous rather than racing the UI that needs it; later calls
    /// reuse the cache unless asked to rescan.
    @discardableResult
    func refresh(force: Bool = false) -> [CatalogApp] {
        guard force || installed.isEmpty else { return installed }

        var results: [CatalogApp] = []
        var seen = Set<String>()
        let fileManager = FileManager.default

        for directory in AppCatalog.searchPaths {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = directory + "/" + entry
                guard let bundle = Bundle(path: path),
                      let bundleID = bundle.bundleIdentifier,
                      seen.insert(bundleID).inserted else { continue }
                let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                    ?? String(entry.dropLast(4))
                results.append(CatalogApp(bundleID: bundleID, name: name, isRunning: false, iconPath: path))
            }
        }

        installed = results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return installed
    }

    /// Running apps first (they are what you are most likely to mean), then everything
    /// else installed, deduplicated by bundle ID.
    func merged(withRunning running: [RunningApp], excluding excluded: Set<String>) -> [CatalogApp] {
        var seen = Set<String>()
        var result: [CatalogApp] = []

        for app in running where !excluded.contains(app.bundleIdentifier) {
            guard seen.insert(app.bundleIdentifier).inserted else { continue }
            if let icon = app.icon { iconCache[app.bundleIdentifier] = icon }
            result.append(CatalogApp(bundleID: app.bundleIdentifier, name: app.name, isRunning: true, iconPath: nil))
        }

        for app in installed where !excluded.contains(app.bundleID) {
            guard seen.insert(app.bundleID).inserted else { continue }
            result.append(app)
        }

        return result
    }

    /// Icons are loaded on demand and kept, so scrolling a long list stays cheap.
    func icon(for app: CatalogApp) -> NSImage? {
        if let cached = iconCache[app.bundleID] { return cached }
        guard let path = app.iconPath else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        iconCache[app.bundleID] = icon
        return icon
    }
}
