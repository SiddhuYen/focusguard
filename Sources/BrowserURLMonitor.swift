// BrowserURLMonitor.swift
// Monitors the active tab URL for supported browsers and reports changes.

import AppKit
import Foundation
import ApplicationServices

@MainActor
final class BrowserURLMonitor {
    struct URLChange {
        let app: RunningApp
        let url: URL
    }

    var onURLChange: ((URLChange) -> Void)?

    private var timer: Timer?
    private var currentApp: RunningApp?
    private var lastURLString: String?
    private let pollInterval: TimeInterval = 0.8

    // Start monitoring URLs for a specific running browser app
    func start(for app: RunningApp) {
        guard isSupportedBrowser(bundleID: app.bundleIdentifier) else {
            stop()
            return
        }
        currentApp = app
        lastURLString = nil

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.poll()
            }
        }
        // Fire immediately once
        Task { @MainActor in
            await poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        currentApp = nil
        lastURLString = nil
    }

    private func poll() async {
        guard let app = currentApp else { return }
        guard let urlString = fetchURLString(for: app), !urlString.isEmpty else { return }
        if urlString == lastURLString { return }
        lastURLString = urlString
        if let url = URL(string: urlString) {
            onURLChange?(URLChange(app: app, url: url))
        }
    }

    private func isSupportedBrowser(bundleID: String) -> Bool {
        switch bundleID {
        case "com.apple.Safari",
             "com.google.Chrome",
             "com.microsoft.edgemac",
             "com.brave.Browser",
             "org.mozilla.firefox",
             "org.mozilla.firefoxdeveloperedition",
             "org.mozilla.nightly":
            return true
        default:
            return false
        }
    }
}

// MARK: - URL fetchers per browser

private extension BrowserURLMonitor {
    func fetchURLString(for app: RunningApp) -> String? {
        switch app.bundleIdentifier {
        case "com.apple.Safari":
            return safariURL()
        case "com.google.Chrome":
            return chromeFamilyURL(appName: "Google Chrome")
        case "com.microsoft.edgemac":
            return chromeFamilyURL(appName: "Microsoft Edge")
        case "com.brave.Browser":
            return chromeFamilyURL(appName: "Brave Browser")
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly":
            if let u = firefoxURLViaIdentifierSearch(pid: app.processIdentifier) { return u }
            if let u = firefoxURLViaWindowDocument(pid: app.processIdentifier) { return u }
            if let u = firefoxURLViaWebArea(pid: app.processIdentifier) { return u }
            if let u = firefoxURLViaFocusedElement(pid: app.processIdentifier) { return u }
            if let u = firefoxURLViaAXAddressBar(pid: app.processIdentifier) { return u }
            if let u = firefoxURLViaAppleScript() { return u }
            return urlFromWindowTitle(pid: app.processIdentifier)
        default:
            return nil
        }
    }

    // Safari via AppleScript
    func safariURL() -> String? {
        let script = """
        tell application "Safari"
            if (count of windows) is 0 then return ""
            set theURL to URL of current tab of front window
            return theURL
        end tell
        """
        return runAppleScript(script)
    }

    // Chrome/Edge/Brave share similar AppleScript dictionaries
    func chromeFamilyURL(appName: String) -> String? {
        let script = """
        tell application "\(appName)"
            if (count of windows) is 0 then return ""
            set theURL to URL of active tab of front window
            return theURL
        end tell
        """
        return runAppleScript(script)
    }

    // Some Firefox builds expose a minimal AppleScript window title; try getting URL via JavaScript bridge if available, else nil
    func firefoxURLViaAppleScript() -> String? {
        let script = """
        tell application "Firefox"
            if (count of windows) is 0 then return ""
            try
                tell application "System Events"
                    tell process "Firefox"
                        set winTitle to name of front window
                    end tell
                end tell
                return winTitle
            on error
                return ""
            end try
        end tell
        """
        // This returns window title; parse URL from it if present
        guard let title = runAppleScript(script), !title.isEmpty else { return nil }
        if let url = extractURL(fromWindowTitle: title) { return url }
        return nil
    }

    func urlFromWindowTitle(pid: pid_t) -> String? {
        guard let title = accessibilityWindowTitle(pid: pid) else { return nil }
        return extractURL(fromWindowTitle: title)
    }

    func firefoxURLViaAXAddressBar(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        // Get focused window
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              windowRef != nil else { return nil }
        let window = windowRef as! AXUIElement
        // Search the entire window for a text field that looks like the address bar
        if let value = findURLFieldValueInTree(in: window) {
            return value
        }
        return nil
    }

    func findFirstElement(withRole role: String, in root: AXUIElement, maxDepth: Int = 12) -> AXUIElement? {
        if roleOf(root) == role { return root }
        guard maxDepth > 0, let children = childrenOf(root), !children.isEmpty else { return nil }
        for child in children {
            if let found = findFirstElement(withRole: role, in: child, maxDepth: maxDepth - 1) {
                return found
            }
        }
        return nil
    }

    func findFirstElement(withAttribute attr: String, equals attrValue: String, in root: AXUIElement, maxDepth: Int = 12) -> AXUIElement? {
        if let v = stringAttribute(attr, of: root), v == attrValue {
            return root
        }
        guard maxDepth > 0, let children = childrenOf(root), !children.isEmpty else { return nil }
        for child in children {
            if let found = findFirstElement(withAttribute: attr, equals: attrValue, in: child, maxDepth: maxDepth - 1) {
                return found
            }
        }
        return nil
    }

    func findURLFieldValue(in root: AXUIElement, maxDepth: Int = 12) -> String? {
        // Look for text-like fields in the toolbar
        if let role = roleOf(root), role == (kAXTextFieldRole as String) {
            if let value = stringAttribute(kAXValueAttribute as String, of: root), !value.isEmpty {
                return value
            }
        }
        guard maxDepth > 0, let children = childrenOf(root), !children.isEmpty else { return nil }
        for child in children {
            if let v = findURLFieldValue(in: child, maxDepth: maxDepth - 1) { return v }
        }
        return nil
    }
    
    func findURLFieldValueInTree(in root: AXUIElement, maxDepth: Int = 12) -> String? {
        // Depth-first traversal looking for any text field whose value normalizes to a URL
        if let role = roleOf(root), role == (kAXTextFieldRole as String) {
            if let raw = stringAttribute(kAXValueAttribute as String, of: root), let url = normalizePotentialURL(raw) {
                return url
            }
        }
        guard maxDepth > 0, let children = childrenOf(root), !children.isEmpty else { return nil }
        for child in children {
            if let v = findURLFieldValueInTree(in: child, maxDepth: maxDepth - 1) { return v }
        }
        return nil
    }

    func roleOf(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func childrenOf(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return nil }
        return array
    }

    func stringAttribute(_ attr: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func normalizePotentialURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        // If it looks like a domain, synthesize a URL
        if let range = trimmed.range(of: #"[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#, options: .regularExpression) {
            let domain = String(trimmed[range])
            return "https://\(domain)"
        }
        return nil
    }

    func extractURL(fromWindowTitle title: String) -> String? {
        // Heuristic: find something that looks like a URL or domain within the title
        // Common formats: "Some Page – YouTube" or "https://example.com/path – Firefox"
        // Try to detect a full URL first
        let patterns = [
            #"https?://[^\s]+"#,
            #"[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#
        ]
        for pattern in patterns {
            if let range = title.range(of: pattern, options: .regularExpression) {
                let candidate = String(title[range])
                if candidate.hasPrefix("http://") || candidate.hasPrefix("https://") {
                    return candidate
                } else {
                    // Build a URL from domain only
                    return "https://\(candidate)"
                }
            }
        }
        return nil
    }

    func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var errorDict: NSDictionary?
        let output = script.executeAndReturnError(&errorDict)
        if errorDict != nil {
            return nil
        }
        return output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // Attempt to read the URL from the web content area (AXWebArea), which often exposes AXURL or AXDocument.
    func firefoxURLViaWebArea(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              windowRef != nil else { return nil }
        let window = windowRef as! AXUIElement

        // Find a web area in the window
        guard let webArea = findFirstElement(withRole: "AXWebArea", in: window) else { return nil }

        // Try AXURL first (may be a CFURL or String)
        if let urlString = urlStringFromAXAttribute("AXURL", of: webArea) {
            return urlString
        }
        // Try AXDocument (commonly a String URL)
        if let docURL = urlStringFromAXAttribute("AXDocument", of: webArea) {
            return docURL
        }
        return nil
    }

    func urlStringFromAXAttribute(_ attr: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success, let value else { return nil }
        // CFURL -> absoluteString
        if CFGetTypeID(value) == CFURLGetTypeID() {
            let cfurl = value as! CFURL
            let nsurl = cfurl as URL
            return nsurl.absoluteString
        }
        // String -> normalize to a valid URL string if possible
        if let s = value as? String, !s.isEmpty {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                return trimmed
            }
            if let normalized = normalizePotentialURL(trimmed) { return normalized }
        }
        return nil
    }

    // Attempt to read the URL directly from the focused window's AXDocument attribute
    func firefoxURLViaWindowDocument(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              windowRef != nil else { return nil }
        let window = windowRef as! AXUIElement
        if let s = urlStringFromAXAttribute("AXDocument", of: window) { return s }
        return nil
    }

    // Use the focused UI element and walk up to a web area, then read AXURL/AXDocument
    func firefoxURLViaFocusedElement(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              focusedRef != nil else { return nil }
        var element = focusedRef as! AXUIElement
        // If the focused element itself is a text field, try its value first (address bar case)
        if let role = roleOf(element), role == (kAXTextFieldRole as String) {
            if let raw = stringAttribute(kAXValueAttribute as String, of: element), let url = normalizePotentialURL(raw) {
                return url
            }
        }
        // Ascend to a WebArea if possible
        if let webArea = ancestor(withRole: "AXWebArea", of: element, maxHops: 8) {
            if let url = urlStringFromAXAttribute("AXURL", of: webArea) { return url }
            if let doc = urlStringFromAXAttribute("AXDocument", of: webArea) { return doc }
        }
        // As a fallback, try the window document
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success, windowRef != nil {
            let window = windowRef as! AXUIElement
            if let s = urlStringFromAXAttribute("AXDocument", of: window) { return s }
        }
        return nil
    }

    func ancestor(withRole role: String, of element: AXUIElement, maxHops: Int = 10) -> AXUIElement? {
        var current: AXUIElement? = element
        var hops = 0
        while let el = current, hops < maxHops {
            if roleOf(el) == role { return el }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success, let parent = parentRef {
                current = parent as! AXUIElement
            } else {
                break
            }
            hops += 1
        }
        return nil
    }

    func firefoxURLViaIdentifierSearch(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              windowRef != nil else { return nil }
        let window = windowRef as! AXUIElement

        // Firefox URL bar commonly has AXIdentifier "urlbar-input"
        if let urlbar = findFirstElement(withAttribute: "AXIdentifier", equals: "urlbar-input", in: window) {
            if let raw = stringAttribute(kAXValueAttribute as String, of: urlbar), let url = normalizePotentialURL(raw) {
                return url
            }
        }
        return nil
    }
}

// MARK: - Accessibility helpers

private extension BrowserURLMonitor {
    func accessibilityWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let window = focusedWindow else { return nil }

        var titleCF: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleCF)
        guard titleResult == .success, let title = titleCF as? String else { return nil }
        return title
    }
}

