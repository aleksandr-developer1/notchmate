import AppKit

/// Reads the active tab URL of the common browsers (macOS asks for Automation permission once per browser).
enum BrowserTabs {
    /// bundle id → AppleScript dialect
    static let browsers: [String: String] = [
        "com.apple.Safari": "safari",
        "com.google.Chrome": "chromium", "company.thebrowser.Browser": "chromium", "com.microsoft.edgemac": "chromium",
        "ru.yandex.desktop.yandex-browser": "chromium", "com.brave.Browser": "chromium", "com.vivaldi.Vivaldi": "chromium",
        "com.operasoftware.Opera": "chromium", "org.chromium.Chromium": "chromium",
    ]

    static func isBrowser(_ bundleID: String) -> Bool { browsers[bundleID] != nil }

    static func activeURL(bundleID: String) -> String? {
        guard let kind = browsers[bundleID] else { return nil }
        let source = kind == "safari"
            ? "tell application id \"\(bundleID)\" to if (count of windows) > 0 then get URL of current tab of front window"
            : "tell application id \"\(bundleID)\" to if (count of windows) > 0 then get URL of active tab of front window"
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }

    /// Any open tab of the running browsers (a call can sit in a background tab).
    static func openURLs() -> [String] {
        var urls: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, let kind = browsers[id] else { continue }
            let source = kind == "safari"
                ? "tell application id \"\(id)\" to get URL of every tab of every window"
                : "tell application id \"\(id)\" to get URL of every tab of every window"
            var error: NSDictionary?
            guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else { continue }
            func collect(_ desc: NSAppleEventDescriptor) {
                if let s = desc.stringValue, s.hasPrefix("http") { urls.append(s) }
                guard desc.numberOfItems > 0 else { return }
                for i in 1...desc.numberOfItems { if let item = desc.atIndex(i) { collect(item) } }
            }
            collect(result)
        }
        return urls
    }
}
