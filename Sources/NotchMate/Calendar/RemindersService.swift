import AppKit
import EventKit
import SwiftUI

struct ReminderItem: Identifiable, Hashable {
    let id: String
    let title: String
    let due: Date
    /// Whether the reminder has a time, not just a day.
    let hasTime: Bool
    let color: Color

    var isOverdue: Bool { hasTime ? due < Date() : !Calendar.current.isDateInToday(due) && due < Date() }
}

/// Unfinished reminders from the Reminders app that are due today or already overdue.
@MainActor
final class RemindersService: ObservableObject {
    @Published private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var items: [ReminderItem] = []
    @Published private(set) var lists: [CalendarSource] = []
    /// Lists the user switched off; new lists show up by default.
    @Published private(set) var excluded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: RemindersService.excludedKey) ?? [])
    private static let excludedKey = "remindersExcludedIDs"

    private let store = EKEventStore()
    private var timer: Timer?

    var hasAccess: Bool { status == .fullAccess }

    func isShown(_ list: CalendarSource) -> Bool { !excluded.contains(list.id) }

    func setShown(_ list: CalendarSource, _ shown: Bool) {
        if shown { excluded.remove(list.id) } else { excluded.insert(list.id) }
        UserDefaults.standard.set(Array(excluded), forKey: Self.excludedKey)
        refresh()
    }

    func start() {
        if hasAccess { refresh() }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // A new day brings a new set of reminders.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {}
        status = EKEventStore.authorizationStatus(for: .reminder)
        if hasAccess { refresh() }
    }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .reminder)
        guard hasAccess else { items = []; lists = []; return }
        let all = store.calendars(for: .reminder)
        lists = all
            .map { CalendarSource(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? String(localized: "Другие"),
                                  color: Color(nsColor: $0.color ?? .systemOrange)) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        let chosen = all.filter { !excluded.contains($0.calendarIdentifier) }
        guard Settings.shared.remindersEnabled, !chosen.isEmpty else { items = []; return }
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfDay, calendars: chosen)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let mapped: [ReminderItem] = (reminders ?? []).compactMap { r in
                guard let comps = r.dueDateComponents, let due = Calendar.current.date(from: comps) else { return nil }
                return ReminderItem(id: r.calendarItemIdentifier, title: r.title ?? String(localized: "Без названия"), due: due,
                                    hasTime: comps.hour != nil,
                                    color: Color(nsColor: r.calendar?.color ?? .systemOrange))
            }
            .sorted { $0.due < $1.due }
            Task { @MainActor in self?.items = mapped }
        }
    }

    func complete(_ item: ReminderItem) {
        guard let r = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        r.isCompleted = true
        try? store.save(r, commit: true)
        withAnimation(.spring(response: 0.3)) { items.removeAll { $0.id == item.id } }
    }

    /// Push the reminder an hour ahead (or to an hour from now, if it's already late).
    func snooze(_ item: ReminderItem) {
        guard let r = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        let base = max(item.due, Date())
        let next = base.addingTimeInterval(3600)
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        r.alarms?.forEach { r.removeAlarm($0) }
        r.addAlarm(EKAlarm(absoluteDate: next))
        try? store.save(r, commit: true)
        refresh()
    }

    func openApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
    }

    func describe() -> String {
        guard hasAccess else { return String(localized: "Напоминания: нет доступа") }
        guard !items.isEmpty else { return String(localized: "Напоминания на сегодня: нет") }
        let f = DateFormatter(); f.dateFormat = "H:mm"
        return String(localized: "Напоминания на сегодня:\n") + items.map { i in
            let when = i.hasTime ? f.string(from: i.due) : String(localized: "без времени")
            return "- \(i.title) (\(when)\(i.isOverdue ? String(localized: ", просрочено") : ""))"
        }.joined(separator: "\n")
    }
}
