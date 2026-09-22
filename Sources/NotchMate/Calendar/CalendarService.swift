import AppKit
import EventKit
import SwiftUI

struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let color: Color
    let meetingURL: URL?
    let location: String?

    var isNow: Bool { start <= Date() && end > Date() }
    var minutesUntil: Int { Int(ceil(start.timeIntervalSinceNow / 60)) }
}

/// One calendar in the user's accounts, for the "which calendars to show" picker.
struct CalendarSource: Identifiable, Hashable {
    let id: String
    let title: String
    let account: String
    let color: Color
}

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var sources: [CalendarSource] = []
    /// Calendars the user switched off. Stored as an exclusion list so newly added calendars show up by default.
    @Published private(set) var excluded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: CalendarService.excludedKey) ?? [])
    private static let excludedKey = "calendarExcludedIDs"

    var onSoon: ((CalendarEvent) -> Void)?
    var onStart: ((CalendarEvent) -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var notifiedSoon: Set<String> = []
    private var notifiedStart: Set<String> = []
    /// Occurrences the user has swiped away: key → when it stops mattering.
    /// Kept on disk so a dismissed meeting doesn't come back after a restart.
    private var hidden: [String: Date] = CalendarService.loadHidden()
    private static let hiddenKey = "calendarHiddenEvents"

    var hasAccess: Bool { status == .fullAccess }

    func isShown(_ source: CalendarSource) -> Bool { !excluded.contains(source.id) }

    func setShown(_ source: CalendarSource, _ shown: Bool) {
        if shown { excluded.remove(source.id) } else { excluded.insert(source.id) }
        UserDefaults.standard.set(Array(excluded), forKey: Self.excludedKey)
        refresh()
    }

    /// Hide one occurrence until it is over (a recurring series keeps its other days).
    func hide(_ event: CalendarEvent) {
        hidden[Self.key(id: event.id, start: event.start)] = event.end
        Self.saveHidden(hidden)
        refresh()
    }

    func isHidden(_ event: CalendarEvent) -> Bool { hidden[Self.key(id: event.id, start: event.start)] != nil }

    func unhideAll() {
        hidden = [:]
        Self.saveHidden(hidden)
        refresh()
    }

    var hiddenCount: Int { hidden.count }

    private static func key(id: String, start: Date) -> String { "\(id)@\(Int(start.timeIntervalSince1970))" }

    private static func loadHidden() -> [String: Date] {
        let raw = (UserDefaults.standard.dictionary(forKey: hiddenKey) as? [String: Double]) ?? [:]
        return raw.mapValues(Date.init(timeIntervalSince1970:))
    }

    private static func saveHidden(_ value: [String: Date]) {
        UserDefaults.standard.set(value.mapValues(\.timeIntervalSince1970), forKey: hiddenKey)
    }

    /// Next event that hasn't started, or the one in progress.
    var next: CalendarEvent? { events.first { $0.end > Date() } }

    func start() {
        guard Settings.shared.calendarEnabled else { return }
        if hasAccess { refresh() }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {}
        status = EKEventStore.authorizationStatus(for: .event)
        if hasAccess { refresh() }
    }

    func refresh() {
        guard hasAccess else { events = []; return }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 7, to: startOfDay)!
        let all = store.calendars(for: .event)
        sources = all
            .map { CalendarSource(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? String(localized: "Другие"),
                                  color: Color(nsColor: $0.color ?? .systemBlue)) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        let chosen = all.filter { !excluded.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { events = []; tick(); return }
        let predicate = store.predicateForEvents(withStart: startOfDay, end: end, calendars: chosen)
        let now = Date()
        if hidden.contains(where: { $0.value < now }) {
            hidden = hidden.filter { $0.value >= now }
            Self.saveHidden(hidden)
        }
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .filter { hidden[Self.key(id: $0.eventIdentifier ?? "", start: $0.startDate)] == nil }
            .sorted { $0.startDate < $1.startDate }
            .map { e in
                CalendarEvent(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? String(localized: "Без названия"),
                              start: e.startDate, end: e.endDate,
                              color: Color(nsColor: e.calendar?.color ?? .systemBlue),
                              meetingURL: Self.meetingLink(e), location: e.location)
            }
        tick()
    }

    private func tick() {
        guard hasAccess, Settings.shared.calendarEnabled else { return }
        let lead = Double(max(1, Settings.shared.calendarLeadMinutes)) * 60
        for e in events {
            let until = e.start.timeIntervalSinceNow
            if until > 0, until <= lead, !notifiedSoon.contains(e.id) {
                notifiedSoon.insert(e.id)
                onSoon?(e)
            }
            if until <= 0, until > -90, !notifiedStart.contains(e.id) {
                notifiedStart.insert(e.id)
                onStart?(e)
            }
        }
        objectWillChange.send()
    }

    var today: [CalendarEvent] {
        events.filter { Calendar.current.isDateInToday($0.start) && $0.end > Date() }
    }

    func describe(days: Int) -> String {
        guard hasAccess else { return String(localized: "Календарь: нет доступа") }
        let limit = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date()))!
        let list = events.filter { $0.end > Date() && $0.start < limit }
        guard !list.isEmpty else { return String(localized: "Календарь: событий нет") }
        let df = DateFormatter(); df.locale = Locale(identifier: "ru_RU"); df.dateFormat = "EEE d MMM HH:mm"
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        return String(localized: "События календаря:\n") + list.map { "• \(df.string(from: $0.start))–\(tf.string(from: $0.end)) \($0.title)\($0.meetingURL != nil ? String(localized: " (есть ссылка на звонок)") : "")" }.joined(separator: "\n")
    }

    func join(_ event: CalendarEvent) {
        if let url = event.meetingURL { NSWorkspace.shared.open(url) }
    }

    private static let linkPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|telemost\.yandex\.ru|telemost\.360\.yandex\.ru|salutejazz\.ru|jazz\.sber\.ru|webex\.com|ktalk\.ru|mts-link\.ru)[^\s<>"]*"#,
        options: [.caseInsensitive])

    private static func meetingLink(_ e: EKEvent) -> URL? {
        if let url = e.url, linkPattern.firstMatch(in: url.absoluteString, range: NSRange(url.absoluteString.startIndex..., in: url.absoluteString)) != nil { return url }
        for text in [e.location, e.notes].compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            if let m = linkPattern.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                return URL(string: String(text[r]))
            }
        }
        return nil
    }
}
