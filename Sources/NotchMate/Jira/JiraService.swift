import AppKit
import Foundation

enum JiraAuth: String, CaseIterable, Identifiable {
    case token, basic
    var id: String { rawValue }
    var title: String { self == .token ? "Personal Access Token" : String(localized: "Логин и пароль") }
}

/// A stretch of time the issue spent in an "In Progress"-category status. `end == nil` — still there.
struct ProgressPeriod: Hashable {
    let start: Date
    let end: Date?
}

struct JiraIssue: Identifiable, Hashable {
    let key: String
    let summary: String
    let status: String
    let statusCategory: String      // new | indeterminate | done
    let type: String
    let priority: String?
    let project: String
    let originalEstimate: Int?      // seconds
    let remainingEstimate: Int?
    let timeSpent: Int?
    let updated: Date?
    var progressPeriods: [ProgressPeriod] = []
    /// Current status counts as my work (work status + assigned to me).
    var isWorking = false
    var id: String { key }

    /// Start of the current in-progress stretch.
    var inProgressSince: Date? { progressPeriods.last.flatMap { $0.end == nil ? $0.start : nil } }

    /// Time spent in work according to the status history.
    @MainActor func timeInWork(at now: Date = Date()) -> Int {
        let s = Settings.shared
        return Int(progressPeriods.reduce(0) { sum, p in
            sum + WorkCalendar.seconds(from: p.start, to: p.end ?? now,
                                       workHoursOnly: s.jiraWorkHoursOnly, dayStart: s.jiraDayStart, dayEnd: s.jiraDayEnd)
        })
    }

    var isInProgress: Bool { statusCategory == "indeterminate" }
}

/// Jira Server / Data Center (REST API v2): my issues, estimates and work logging.
@MainActor
final class JiraService: ObservableObject {
    @Published private(set) var issues: [JiraIssue] = []
    @Published private(set) var me: String?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var lastUpdated: Date?

    // Local work session (not yet logged to Jira). Persisted across restarts.
    @Published private(set) var sessionKey: String?
    @Published private(set) var sessionStart: Date?
    @Published private(set) var sessionAccumulated: TimeInterval = 0
    @Published var lastLogMessage: (text: String, ok: Bool)?

    private let settings = Settings.shared
    private let d = UserDefaults.standard
    private var timer: Timer?
    var onLogged: (() -> Void)?
    var onIssuesLoaded: (([String]) -> Void)?
    var onOverrun: ((JiraIssue) -> Void)?
    private var overrunNotified: Set<String> = []
    private var overrunTimer: Timer?
    private var statusCategoryByID: [String: String] = [:]
    private var statusNameByID: [String: String] = [:]
    private var myIDs: Set<String> = []
    /// "In progress"-category status names seen in my issues' history (for the settings picker).
    @Published private(set) var workStatusNames: [String] = []

    static let tokenAccount = "jira-token"

    init() {
        sessionKey = d.string(forKey: "jiraSessionKey")
        sessionStart = d.object(forKey: "jiraSessionStart") as? Date
        sessionAccumulated = d.double(forKey: "jiraSessionAccum")
    }

    var isConfigured: Bool {
        !settings.jiraURL.isEmpty && !(Keychain.get(Self.tokenAccount) ?? "").isEmpty
            && (settings.jiraAuth == .token || !settings.jiraUser.isEmpty)
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        overrunTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOverrun() }
        }
    }

    // MARK: Active issue

    /// Task "in work": running/paused session → the one the user picked → first issue in a work status on me.
    var activeIssue: JiraIssue? {
        if let k = sessionKey, let i = issues.first(where: { $0.key == k }) { return i }
        if let i = issues.first(where: { $0.key == settings.jiraActiveKey }) { return i }
        return issues.first(where: \.isWorking)
    }

    /// Statuses that are "In Progress" by category but aren't active work by default.
    nonisolated static let nonWorkPattern = "wait|ожида|block|блок|hold|паус|pause|review|ревью|test|тест|qa|verif|провер|feedback|обратн"

    nonisolated static func isDefaultWorkStatus(_ name: String) -> Bool {
        name.range(of: nonWorkPattern, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// Effective list of work statuses: user choice, or all "In Progress"-category ones minus waiting/review/testing.
    var effectiveWorkStatuses: [String] {
        settings.jiraWorkStatuses.isEmpty ? workStatusNames.filter(Self.isDefaultWorkStatus) : settings.jiraWorkStatuses
    }

    func select(_ issue: JiraIssue) {
        guard sessionIsIdle || sessionKey == issue.key else { return }
        settings.jiraActiveKey = issue.key
        objectWillChange.send()
    }

    /// The assistant gets sad once when the active issue runs past its estimate.
    private func checkOverrun() {
        guard let issue = activeIssue, issue.isWorking, let original = issue.originalEstimate,
              !overrunNotified.contains(issue.key) else { return }
        if issue.timeInWork() > original {
            overrunNotified.insert(issue.key)
            onOverrun?(issue)
        }
    }

    // MARK: Session timer

    var isTracking: Bool { sessionStart != nil }
    var sessionIsIdle: Bool { sessionStart == nil && sessionAccumulated < 1 }

    func sessionElapsed(at date: Date = Date()) -> TimeInterval {
        sessionAccumulated + (sessionStart.map { date.timeIntervalSince($0) } ?? 0)
    }

    func toggleTracking(_ issue: JiraIssue) {
        if sessionKey != issue.key, !sessionIsIdle { return }
        if let start = sessionStart {
            sessionAccumulated += Date().timeIntervalSince(start)
            sessionStart = nil
        } else {
            sessionKey = issue.key
            settings.jiraActiveKey = issue.key
            sessionStart = Date()
        }
        persistSession()
    }

    func discardSession() {
        sessionKey = nil; sessionStart = nil; sessionAccumulated = 0
        persistSession()
    }

    private func persistSession() {
        d.set(sessionKey, forKey: "jiraSessionKey")
        d.set(sessionStart, forKey: "jiraSessionStart")
        d.set(sessionAccumulated, forKey: "jiraSessionAccum")
    }

    /// Logs the tracked session as a worklog (Jira adjusts the remaining estimate automatically).
    /// Creates a worklog; Jira recalculates the remaining estimate itself.
    func logWork(key: String, seconds: Int, comment: String = "") async throws {
        let startedAt = Date().addingTimeInterval(-TimeInterval(seconds))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        var body: [String: Any] = ["timeSpentSeconds": seconds, "started": f.string(from: startedAt)]
        if !comment.isEmpty { body["comment"] = comment }
        _ = try await request("/rest/api/2/issue/\(key)/worklog", method: "POST", body: body)
        onLogged?()
        refresh()
    }

    func logSession(comment: String = "") async {
        guard let key = sessionKey else { return }
        let seconds = Int(sessionElapsed())
        guard seconds >= 60 else { lastLogMessage = (String(localized: "Меньше минуты — нечего списывать"), false); return }
        do {
            try await logWork(key: key, seconds: seconds, comment: comment)
            lastLogMessage = (String(localized: "Списано \(Self.format(seconds)) в \(key)"), true)
            discardSession()
        } catch {
            lastLogMessage = (String(localized: "Не удалось списать: \(error.localizedDescription)"), false)
        }
    }

    // MARK: Loading

    func refresh() {
        guard isConfigured else { issues = []; error = nil; return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                if myIDs.isEmpty, let json = try await request("/rest/api/2/myself") as? [String: Any] {
                    me = json["displayName"] as? String
                    myIDs = Set([json["key"], json["name"], json["accountId"]].compactMap { $0 as? String })
                }
                if statusCategoryByID.isEmpty, let list = try await request("/rest/api/2/status") as? [[String: Any]] {
                    for st in list {
                        if let id = st["id"] as? String, let cat = (st["statusCategory"] as? [String: Any])?["key"] as? String {
                            statusCategoryByID[id] = cat
                            statusNameByID[id] = st["name"] as? String
                        }
                    }
                }
                var comps = URLComponents()
                comps.queryItems = [
                    URLQueryItem(name: "jql", value: settings.jiraJQL),
                    URLQueryItem(name: "maxResults", value: "50"),
                    URLQueryItem(name: "expand", value: "changelog"),
                    URLQueryItem(name: "fields", value: "summary,status,assignee,issuetype,priority,project,created,updated,timeoriginalestimate,timeestimate,timespent"),
                ]
                let json = try await request("/rest/api/2/search?" + (comps.percentEncodedQuery ?? "")) as? [String: Any]
                let raw = json?["issues"] as? [[String: Any]] ?? []
                let rules = WorkRules(categories: statusCategoryByID, names: statusNameByID, me: myIDs,
                                      allowedStatuses: Set(settings.jiraWorkStatuses.map { $0.lowercased() }))
                let parsed = raw.compactMap { Self.parse($0, rules: rules) }
                workStatusNames = statusCategoryByID.filter { $0.value == "indeterminate" }
                    .compactMap { statusNameByID[$0.key] }.sorted()
                issues = parsed.filter(\.isWorking) + parsed.filter { !$0.isWorking }
                if let picked = issues.first(where: { $0.key == settings.jiraActiveKey }), !picked.isWorking, sessionKey != picked.key {
                    settings.jiraActiveKey = ""   // picked issue left work (e.g. moved to Waiting) — follow Jira again
                }
                error = nil
                lastUpdated = Date()
                onIssuesLoaded?(issues.map(\.key))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func testConnection() async -> (text: String, ok: Bool) {
        do {
            let json = try await request("/rest/api/2/myself") as? [String: Any]
            me = json?["displayName"] as? String
            refresh()
            return (String(localized: "Подключено: \(me ?? "OK")"), true)
        } catch {
            return (String(localized: "Ошибка: \(error.localizedDescription)"), false)
        }
    }

    private static func jiraDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let fixed = s.replacingOccurrences(of: "([+-]\\d{2})(\\d{2})$", with: "$1:$2", options: .regularExpression)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: fixed)
    }

    struct WorkRules {
        let categories: [String: String]     // status id -> category key
        let names: [String: String]          // status id -> name
        let me: Set<String>                  // my user key / name
        let allowedStatuses: Set<String>     // lowercased names; empty = default heuristic

        func isWork(status id: String?, assignee: String?) -> Bool {
            guard let id, categories[id] == "indeterminate" else { return false }
            let name = names[id] ?? ""
            if allowedStatuses.isEmpty {
                if !JiraService.isDefaultWorkStatus(name) { return false }
            } else if !allowedStatuses.contains(name.lowercased()) {
                return false
            }
            guard let assignee else { return false }
            return me.isEmpty || me.contains(assignee)
        }
    }

    /// Rebuilds the periods when the issue was in a work status AND assigned to me,
    /// replaying status and assignee changes from the changelog.
    private static func progressPeriods(_ obj: [String: Any], currentStatusID: String?, currentAssignee: String?,
                                        created: Date?, rules: WorkRules) -> [ProgressPeriod] {
        enum Field { case status, assignee }
        let histories = ((obj["changelog"] as? [String: Any])?["histories"] as? [[String: Any]]) ?? []
        var changes: [(date: Date, field: Field, from: String?, to: String?)] = []
        for h in histories {
            guard let date = jiraDate(h["created"] as? String) else { continue }
            for item in (h["items"] as? [[String: Any]]) ?? [] {
                switch item["field"] as? String {
                case "status": changes.append((date, .status, item["from"] as? String, item["to"] as? String))
                case "assignee": changes.append((date, .assignee, item["from"] as? String, item["to"] as? String))
                default: break
                }
            }
        }
        changes.sort { $0.date < $1.date }

        // Initial state = "from" of the first change of each field, else the current value.
        var status = changes.first(where: { $0.field == .status })?.from ?? currentStatusID
        var assignee = changes.first(where: { $0.field == .assignee }).map { $0.from } ?? currentAssignee
        var working = rules.isWork(status: status, assignee: assignee)
        var since = created ?? changes.first?.date ?? Date()
        var periods: [ProgressPeriod] = []
        for ch in changes {
            switch ch.field {
            case .status: status = ch.to
            case .assignee: assignee = ch.to
            }
            let next = rules.isWork(status: status, assignee: assignee)
            if working && !next { periods.append(ProgressPeriod(start: since, end: ch.date)) }
            if !working && next { since = ch.date }
            working = next
        }
        if working { periods.append(ProgressPeriod(start: since, end: nil)) }
        return periods
    }

    private static func parse(_ obj: [String: Any], rules: WorkRules) -> JiraIssue? {
        guard let key = obj["key"] as? String, let f = obj["fields"] as? [String: Any] else { return nil }
        let status = f["status"] as? [String: Any]
        let cat = status?["statusCategory"] as? [String: Any]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let updatedString = (f["updated"] as? String)?.replacingOccurrences(of: "([+-]\\d{2})(\\d{2})$", with: "$1:$2", options: .regularExpression)
        let assigneeID = (f["assignee"] as? [String: Any]).flatMap { ($0["key"] ?? $0["name"]) as? String }
        return JiraIssue(
            key: key,
            summary: f["summary"] as? String ?? "",
            status: status?["name"] as? String ?? "",
            statusCategory: cat?["key"] as? String ?? "new",
            type: (f["issuetype"] as? [String: Any])?["name"] as? String ?? "",
            priority: (f["priority"] as? [String: Any])?["name"] as? String,
            project: (f["project"] as? [String: Any])?["key"] as? String ?? "",
            originalEstimate: f["timeoriginalestimate"] as? Int,
            remainingEstimate: f["timeestimate"] as? Int,
            timeSpent: f["timespent"] as? Int,
            updated: updatedString.flatMap { iso.date(from: $0) },
            progressPeriods: progressPeriods(obj, currentStatusID: status?["id"] as? String,
                                             currentAssignee: assigneeID,
                                             created: jiraDate(f["created"] as? String), rules: rules),
            isWorking: rules.isWork(status: status?["id"] as? String, assignee: assigneeID)
        )
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any? {
        let base = settings.jiraURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + path) else { throw JiraError.message(String(localized: "Неверный адрес Jira")) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let secret = Keychain.get(Self.tokenAccount) ?? ""
        switch settings.jiraAuth {
        case .token:
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case .basic:
            let raw = Data("\(settings.jiraUser):\(secret)".utf8).base64EncodedString()
            req.setValue("Basic \(raw)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        case 401: throw JiraError.message(String(localized: "401 — неверный токен или логин"))
        case 403: throw JiraError.message(String(localized: "403 — нет доступа (возможно, нужна капча: войдите в Jira в браузере)"))
        default:
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["errorMessages"] as? [String])?.first }
            throw JiraError.message("HTTP \(code)\(msg.map { " — \($0)" } ?? "")")
        }
    }

    func open(_ issue: JiraIssue) {
        let base = settings.jiraURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if let url = URL(string: "\(base)/browse/\(issue.key)") { NSWorkspace.shared.open(url) }
    }

    static func format(_ seconds: Int?) -> String {
        guard let s = seconds else { return "—" }
        let neg = s < 0
        let a = abs(s)
        let h = a / 3600, m = a / 60 % 60
        let str = h > 0 ? (m > 0 ? String(localized: "\(h)ч \(m)м") : String(localized: "\(h)ч")) : String(localized: "\(m)м")
        return neg ? "−" + str : str
    }
}

/// Working-time arithmetic: weekdays between dayStart and dayEnd hours.
enum WorkCalendar {
    static func seconds(from start: Date, to end: Date, workHoursOnly: Bool, dayStart: Int, dayEnd: Int) -> TimeInterval {
        guard end > start else { return 0 }
        guard workHoursOnly, dayEnd > dayStart else { return end.timeIntervalSince(start) }
        let cal = Calendar.current
        var total: TimeInterval = 0
        var day = cal.startOfDay(for: start)
        while day < end {
            let weekday = cal.component(.weekday, from: day) // 1 = Sunday, 7 = Saturday
            if weekday != 1 && weekday != 7,
               let ws = cal.date(bySettingHour: dayStart, minute: 0, second: 0, of: day),
               let we = cal.date(bySettingHour: dayEnd, minute: 0, second: 0, of: day) {
                let a = max(ws, start), b = min(we, end)
                if b > a { total += b.timeIntervalSince(a) }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return total
    }
}

enum JiraError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}
