import AppKit
import Foundation

@MainActor
final class BrowserURLReader {
    func activeTabURL(forBrowserBundleID bundleID: String) -> URL? {
        switch bundleID {
        case FocusPolicyEngine.safariBundleID:
            return safariActiveTabURL()
        case FocusPolicyEngine.chromeBundleID:
            return chromeActiveTabURL()
        default:
            return nil
        }
    }

    private func safariActiveTabURL() -> URL? {
        let source = """
        tell application "Safari"
            if (count of windows) is 0 then return missing value
            set theURL to URL of current tab of front window
            return theURL
        end tell
        """
        return runAppleScriptReturningURL(source)
    }

    private func chromeActiveTabURL() -> URL? {
        let source = """
        tell application "Google Chrome"
            if (count of windows) is 0 then return missing value
            set theURL to URL of active tab of front window
            return theURL
        end tell
        """
        return runAppleScriptReturningURL(source)
    }

    private func runAppleScriptReturningURL(_ source: String) -> URL? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorDict: NSDictionary? = nil
        let output = script.executeAndReturnError(&errorDict)
        if errorDict != nil { return nil }
        guard let string = output.stringValue, let url = URL(string: string) else { return nil }
        return url
    }
}
