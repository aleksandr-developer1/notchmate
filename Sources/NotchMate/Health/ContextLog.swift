import AppKit

/// What the Mac was doing, one bit set per minute. Joined with stress / pulse from the watch
/// it answers "what actually wears me out": calls, focus, meetings, agents…
struct MacContext: OptionSet, Codable, Hashable {
    let rawValue: UInt16

    static let atMac = MacContext(rawValue: 1 << 0)
    static let focus = MacContext(rawValue: 1 << 1)
    static let call = MacContext(rawValue: 1 << 2)
    static let meeting = MacContext(rawValue: 1 << 3)
    static let music = MacContext(rawValue: 1 << 4)
    static let agent = MacContext(rawValue: 1 << 5)
    static let jira = MacContext(rawValue: 1 << 6)
    static let flow = MacContext(rawValue: 1 << 7)
    static let distracted = MacContext(rawValue: 1 << 8)
    static let breathing = MacContext(rawValue: 1 << 9)
    static let `break` = MacContext(rawValue: 1 << 10)

    /// Contexts worth comparing, in display order.
    static let tracked: [(MacContext, String, String)] = [
        (.call, String(localized: "Созвоны"), "video.fill"),
        (.meeting, String(localized: "Встречи"), "calendar"),
        (.focus, String(localized: "Фокус"), "timer"),
        (.flow, String(localized: "Активная печать"), "keyboard"),
        (.jira, String(localized: "Задачи Jira"), "briefcase.fill"),
        (.agent, String(localized: "С агентами"), "terminal"),
        (.music, String(localized: "С музыкой"), "music.note"),
        (.distracted, String(localized: "Отвлечения"), "eye.trianglebadge.exclamationmark"),
        (.break, String(localized: "Перерывы"), "cup.and.saucer.fill"),
    ]
}

@MainActor
final class ContextLog {
    /// minute (epoch / 60) → context, for the last `keepDays`.
    private(set) var minutes: [Int: MacContext] = [:]
    /// minute → what was in front: a site for browsers (`youtube.com`), otherwise the app name.
    private(set) var activities: [Int: String] = [:]
    private var sampleCounts: [String: Int] = [:]
    private var sampler: Timer?
    private var dirtyDays: Set<String> = []
    private var timer: Timer?
    private weak var env: AppEnvironment?
    private let keepDays = 30

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchMate/context", isDirectory: true)
    }

    func start(env: AppEnvironment) {
        self.env = env
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.record() }
        }
        // The front app changes within a minute; sample it and keep the most frequent.
        sampler = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleActivity() }
        }
        record()
    }

    func context(at date: Date) -> MacContext? { minutes[Int(date.timeIntervalSince1970 / 60)] }
    func activity(at date: Date) -> String? { activities[Int(date.timeIntervalSince1970 / 60)] }

    /// First minute recorded on the day of `date` — before it NotchMate wasn't running, so "away" is unknown.
    func firstMinute(onDayOf date: Date) -> Int? {
        let a = Int(Calendar.current.startOfDay(for: date).timeIntervalSince1970 / 60)
        return minutes.keys.filter { $0 >= a && $0 < a + 1440 }.min()
    }

    /// At the Mac: recent input, or something playing in the app in front (watching a video without touching anything).
    /// A locked screen is always away.
    private func isPresent() -> Bool {
        if Self.screenLocked { return false }
        if CGEventSourceSecondsIdle() < 120 { return true }
        guard let env, let track = env.nowPlaying.track, track.isPlaying,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return track.bundleID == front || BrowserTabs.isBrowser(front) && BrowserTabs.isBrowser(track.bundleID)
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func sampleActivity() {
        guard isPresent(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        var label = app.localizedName ?? app.bundleIdentifier ?? ""
        if let id = app.bundleIdentifier, BrowserTabs.isBrowser(id),
           let url = BrowserTabs.activeURL(bundleID: id).flatMap(URL.init(string:)), var host = url.host?.lowercased() {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if host.hasPrefix("m.") { host.removeFirst(2) }
            label = host
        }
        guard !label.isEmpty else { return }
        sampleCounts[label, default: 0] += 1
    }

    private func record() {
        guard let env else { return }
        var c: MacContext = []
        if isPresent() { c.insert(.atMac) }
        if env.focus.isWorking { c.insert(.focus) }
        if env.focus.isOnBreak { c.insert(.break) }
        if env.companion.inCall || env.calls.stage == .recording { c.insert(.call) }
        if let e = env.calendar.next, e.isNow { c.insert(.meeting) }
        if env.nowPlaying.track?.isPlaying == true { c.insert(.music) }
        if !env.agents.working.isEmpty { c.insert(.agent) }
        if env.jira.isTracking { c.insert(.jira) }
        if env.activity.intensity == .flow { c.insert(.flow) }
        if env.distractions.current != nil { c.insert(.distracted) }
        if env.breathing.isActive { c.insert(.breathing) }

        let now = Date()
        let minute = Int(now.timeIntervalSince1970 / 60)
        minutes[minute] = c
        if let top = sampleCounts.max(by: { $0.value < $1.value })?.key, c.contains(.atMac) { activities[minute] = top }
        sampleCounts.removeAll()
        dirtyDays.insert(HealthDay.key(now))
        save()
    }

    private func load() {
        let fm = FileManager.default
        let cutoff = HealthDay.key(Date().addingTimeInterval(-86400 * Double(keepDays)))
        for url in (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.deletingPathExtension().lastPathComponent
            let day = String(name.prefix(10))
            if day < cutoff { try? fm.removeItem(at: url); continue }
            if name.hasSuffix("-apps") {
                if let data = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([String: String].self, from: data) {
                    for (k, v) in rows { if let m = Int(k) { activities[m] = v } }
                }
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let rows = try? JSONDecoder().decode([[Int]].self, from: data) else { continue }
            for r in rows where r.count == 2 { minutes[r[0]] = MacContext(rawValue: UInt16(r[1])) }
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        for day in dirtyDays {
            guard let start = HealthDay.date(day) else { continue }
            let a = Int(start.timeIntervalSince1970 / 60), b = a + 24 * 60
            let rows = minutes.filter { $0.key >= a && $0.key < b }.sorted { $0.key < $1.key }.map { [$0.key, Int($0.value.rawValue)] }
            if let data = try? JSONEncoder().encode(rows) {
                try? data.write(to: Self.folder.appendingPathComponent("\(day).json"), options: .atomic)
            }
            let apps = Dictionary(uniqueKeysWithValues: activities.filter { $0.key >= a && $0.key < b }.map { (String($0.key), $0.value) })
            if let data = try? JSONEncoder().encode(apps) {
                try? data.write(to: Self.folder.appendingPathComponent("\(day)-apps.json"), options: .atomic)
            }
        }
        dirtyDays.removeAll()
    }
}

private func CGEventSourceSecondsIdle() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}
