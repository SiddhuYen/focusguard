import Foundation
import Security

enum BuildInfo {
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    static var versionStamp: String { "\(version) (\(build))" }

    static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "app.focusguard.mvp"
    }

    /// Team identifier plus cdhash, so a rebuild or a re-sign is visible in the log (3.10).
    static var signature: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }

        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else { return nil }

        let team = info[kSecCodeInfoTeamIdentifier as String] as? String ?? "no-team"
        let hash = (info[kSecCodeInfoUnique as String] as? Data)?
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined() ?? "unknown"
        return "\(team):\(hash)"
    }
}
