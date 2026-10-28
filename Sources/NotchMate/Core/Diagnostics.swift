import AppKit
import OSLog

/// Plain-text report for a bug: app and system versions, enabled plugins, missing permissions and recent errors.
/// Nothing is sent anywhere; the user copies it into an issue.
enum Diagnostics {
    static let issuesURL = URL(string: "https://github.com/aleksandr-developer1/notchmate/issues/new")!

    /// Reading the system log takes seconds, so it runs off the main thread.
    @MainActor
    static func report(now: Date = Date()) async -> String {
        let since = now.addingTimeInterval(-3600)
        let errors = await Task.detached(priority: .userInitiated) { recentErrors(since: since) }.value
        return summary(errors: errors)
    }

    @MainActor
    static func summary(errors: [String]) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let settings = Settings.shared
        let enabled = PluginID.allCases.filter { settings.pluginEnabled($0) }.map(\.rawValue)
        let disabled = PluginID.allCases.filter { !settings.pluginEnabled($0) }.map(\.rawValue)
        let missing = PermissionCenter.shared.missing.map { "\($0)" }
        let lines = [
            "NotchMate \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac: \(model)",
            "Language: \(AppLanguage.code)",
            "Notch: \(NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } ? "yes" : "no"), screens: \(NSScreen.screens.count)",
            "Plugins on: \(enabled.joined(separator: ", "))",
            "Plugins off: \(disabled.isEmpty ? "—" : disabled.joined(separator: ", "))",
            "Missing permissions: \(missing.isEmpty ? "—" : missing.joined(separator: ", "))",
            "",
            "Recent errors (last hour):",
            errors.joined(separator: "\n").nonEmpty ?? "—",
        ]
        return sanitize(lines.joined(separator: "\n"))
    }

    /// Hides the home folder and account name that paths in log lines carry.
    static func sanitize(_ text: String) -> String {
        var result = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let user = NSUserName()
        if user.count > 2 { result = result.replacingOccurrences(of: user, with: "<user>") }
        return result
    }

    private static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// This process's own log lines that mention a failure.
    nonisolated private static func recentErrors(since start: Date) -> [String] {
        let filter = NSPredicate(format: "messageType == error OR messageType == fault OR composedMessage BEGINSWITH 'NotchMate:'")
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: start), matching: filter) else { return [] }
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            let message = entry.composedMessage
            let failed = entry.level == .error || entry.level == .fault
                || (message.hasPrefix("NotchMate:") && message.range(of: "fail|error|не удалось", options: [.caseInsensitive, .regularExpression]) != nil)
            guard failed else { continue }
            lines.append("\(entry.date.formatted(time)) \(message.prefix(300))")
        }
        return Array(lines.suffix(40))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
