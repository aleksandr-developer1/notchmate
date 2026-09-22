import AppKit

/// While focusing (pomodoro work or a Jira timer), notices distracting apps and sites and nudges back.
@MainActor
final class DistractionGuard: ObservableObject {
    @Published private(set) var sessionCount = 0
    @Published private(set) var current: String?

    var isFocusing: () -> Bool = { false }
    var onNudge: ((String) -> Void)?

    private var timer: Timer?
    private var distractedSince: Date?
    private var lastNudge: Date?
    private var lastSource: String?
    private let settings = Settings.shared

    private static let browsers: [String: String] = [
        "com.apple.Safari": "safari",
        "com.google.Chrome": "chromium", "company.thebrowser.Browser": "chromium", "com.microsoft.edgemac": "chromium",
        "ru.yandex.desktop.yandex-browser": "chromium", "com.brave.Browser": "chromium", "com.vivaldi.Vivaldi": "chromium",
    ]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func resetSession() {
        sessionCount = 0
        distractedSince = nil
        current = nil
    }

    private func check() {
        guard settings.distractionGuard, isFocusing() else {
            distractedSince = nil
            current = nil
            return
        }
        guard let source = distractionSource() else {
            distractedSince = nil
            current = nil
            return
        }
        let now = Date()
        if distractedSince == nil || lastSource != source { distractedSince = now; lastSource = source }
        current = source
        guard let since = distractedSince, now.timeIntervalSince(since) >= 8 else { return }
        if lastNudge == nil || now.timeIntervalSince(lastNudge!) >= 120 || lastSource != source {
            lastNudge = now
            sessionCount += 1
            onNudge?(source)
        }
    }

    private func distractionSource() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = app.localizedName ?? ""
        let blockedApps = settings.distractionApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if blockedApps.contains(where: { name.lowercased().contains($0) }) { return name }

        guard settings.distractionBrowsers, let bid = app.bundleIdentifier, BrowserTabs.isBrowser(bid),
              let urlString = BrowserTabs.activeURL(bundleID: bid),
              let host = URL(string: urlString)?.host?.lowercased() else { return nil }
        let sites = settings.distractionSites.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if let site = sites.first(where: { host == $0 || host.hasSuffix("." + $0) }) { return site }
        return nil
    }

    /// Asks the browser for its active tab URL (macOS asks for Automation permission once per browser).
    private static func activeURL(bundleID: String, kind: String) -> String? {
        let source = kind == "safari"
            ? "tell application id \"\(bundleID)\" to if (count of windows) > 0 then get URL of current tab of front window"
            : "tell application id \"\(bundleID)\" to if (count of windows) > 0 then get URL of active tab of front window"
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }
}
