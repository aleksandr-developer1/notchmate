import AppKit
import Foundation

struct NotchMateTool {
    let name: String
    let description: String
    let schema: [String: Any]
}

/// Tool catalog shared by the MCP server (separate process) and in-app AI tool calling.
enum NotchMateToolCatalog {
    private static func obj(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }

    static let tools: [NotchMateTool] = [
        NotchMateTool(name: "get_today",
                    description: String(localized: "Сводка дня пользователя: дата, фокус-таймер, задача Jira в работе (прошло/осталось), мои задачи Jira, события календаря, музыка, активные ИИ-агенты. Вызывай, когда спрашивают про день, задачи или планы."),
                    schema: obj([:])),
        NotchMateTool(name: "add_note",
                    description: String(localized: "Записать мысль строкой в ежедневную заметку Obsidian."),
                    schema: obj(["text": ["type": "string"]], required: ["text"])),
        NotchMateTool(name: "search_notes",
                    description: String(localized: "Поиск по заметкам Obsidian (заголовки и текст). Возвращает до 6 результатов со сниппетами."),
                    schema: obj(["query": ["type": "string"]], required: ["query"])),
        NotchMateTool(name: "start_focus",
                    description: String(localized: "Запустить помидоро-таймер фокуса."),
                    schema: obj(["minutes": ["type": "number", "description": String(localized: "Длительность, по умолчанию из настроек")],
                                 "label": ["type": "string", "description": String(localized: "На что фокус, например ключ задачи")]])),
        NotchMateTool(name: "stop_focus", description: String(localized: "Остановить фокус-таймер."), schema: obj([:])),
        NotchMateTool(name: "jira_log_time",
                    description: String(localized: "Списать время (worklog) в задачу Jira. Используй ТОЛЬКО когда пользователь явно попросил списать время."),
                    schema: obj(["key": ["type": "string", "description": String(localized: "Ключ задачи, например PROJ-123; по умолчанию задача в работе")],
                                 "minutes": ["type": "number", "description": String(localized: "Сколько минут списать")],
                                 "comment": ["type": "string"]], required: ["minutes"])),
        NotchMateTool(name: "calendar_events",
                    description: String(localized: "События календаря на ближайшие дни."),
                    schema: obj(["days": ["type": "number", "description": String(localized: "Сколько дней вперёд, 1–7")]])),
        NotchMateTool(name: "media_control",
                    description: String(localized: "Управление музыкой: play, pause, toggle, next, previous."),
                    schema: obj(["action": ["type": "string", "enum": ["play", "pause", "toggle", "next", "previous"]]], required: ["action"])),
        NotchMateTool(name: "call_recording",
                    description: String(localized: "Управление записью созвона: start — начать, stop — остановить и сделать протокол, status — состояние, process_pending — доделать записи, оставшиеся с прошлого запуска."),
                    schema: obj(["action": ["type": "string", "enum": ["start", "stop", "status", "process_pending"]],
                                 "folder": ["type": "string", "description": String(localized: "Имя папки записи, например «2026-09-16 10-55»")]], required: ["action"])),
        NotchMateTool(name: "show_message",
                    description: String(localized: "Показать короткое сообщение под вырезом MacBook (например, когда долгая задача агента завершена)."),
                    schema: obj(["text": ["type": "string", "description": String(localized: "До 60 символов")]], required: ["text"])),
    ]
}

/// Executes tools against live app state.
@MainActor
enum NotchMateToolRunner {
    static func run(_ name: String, _ args: [String: Any], env: AppEnvironment) async -> (text: String, isError: Bool) {
        switch name {
        case "get_today":
            return (todaySummary(env: env), false)
        case "add_note":
            guard let text = args["text"] as? String, env.notes.capture(text) else { return (String(localized: "Не удалось записать"), true) }
            return (String(localized: "Записано в заметку дня"), false)
        case "search_notes":
            let hits = await env.notes.search(args["query"] as? String ?? "")
            if hits.isEmpty { return (String(localized: "Ничего не найдено"), false) }
            return (hits.prefix(6).map { "• \($0.note.relativePath)\($0.snippet.map { " — \($0)" } ?? "")" }.joined(separator: "\n"), false)
        case "start_focus":
            let minutes = (args["minutes"] as? NSNumber)?.doubleValue
            let label = args["label"] as? String ?? env.jira.activeIssue.map { "\($0.key) · \($0.summary)" } ?? String(localized: "Помидор")
            env.focus.start(minutes: minutes, label: label, task: env.jira.activeIssue?.key)
            return (String(localized: "Фокус запущен на \(Int(minutes ?? env.settings.pomoWork)) мин"), false)
        case "stop_focus":
            env.focus.reset()
            return (String(localized: "Фокус остановлен"), false)
        case "jira_log_time":
            guard let minutes = (args["minutes"] as? NSNumber)?.doubleValue, minutes >= 1 else { return (String(localized: "Укажите минуты"), true) }
            guard let key = (args["key"] as? String) ?? env.jira.activeIssue?.key else { return (String(localized: "Нет задачи в работе — укажите ключ"), true) }
            do {
                try await env.jira.logWork(key: key, seconds: Int(minutes * 60), comment: args["comment"] as? String ?? "")
                return (String(localized: "Списано \(JiraService.format(Int(minutes * 60))) в \(key)"), false)
            } catch { return ("Jira: \(error.localizedDescription)", true) }
        case "calendar_events":
            let days = max(1, min(7, (args["days"] as? NSNumber)?.intValue ?? 1))
            return (env.calendar.describe(days: days) + "\n\n" + env.reminders.describe(), false)
        case "media_control":
            let map: [String: MediaCommand] = ["play": .play, "pause": .pause, "toggle": .toggle, "next": .next, "previous": .previous]
            guard let cmd = map[args["action"] as? String ?? ""] else { return (String(localized: "Неизвестное действие"), true) }
            env.nowPlaying.send(cmd)
            return (String(localized: "Ок"), false)
        case "call_recording":
            let calls = env.calls
            switch args["action"] as? String {
            case "start":
                await calls.beginRecording()
                return (calls.stage == .recording ? String(localized: "Запись началась") : (calls.lastError ?? String(localized: "Не удалось начать")), calls.stage != .recording)
            case "stop":
                guard calls.stage == .recording else { return (String(localized: "Запись не идёт"), true) }
                Task { await calls.finishRecording() }
                return (String(localized: "Останавливаю запись, делаю протокол"), false)
            case "process_pending":
                let pending = CallRecorder.pendingRecordings()
                let wanted = args["folder"] as? String
                guard let target = wanted.flatMap({ name in pending.first { $0.lastPathComponent == name } }) ?? pending.first else {
                    return (String(localized: "Незавершённых записей нет"), false)
                }
                Task { await calls.processExisting(folder: target) }
                return (String(localized: "Обрабатываю запись \(target.lastPathComponent)"), false)
            default:
                let state: String
                switch calls.stage {
                case .idle: state = calls.micActive ? String(localized: "микрофон занят, запись не идёт") : String(localized: "ожидание")
                case .recording: state = String(localized: "идёт запись \(FocusTimer.format(calls.elapsed))")
                case .transcribing: state = String(localized: "расшифровка")
                case .summarizing: state = String(localized: "готовлю протокол")
                }
                let pending = CallRecorder.pendingRecordings().count
                return (String(localized: "Созвон: \(state)") + (pending > 0 ? String(localized: ", незавершённых записей: \(pending)") : "") + (calls.lastNote.map { String(localized: ", последний протокол: \($0)") } ?? ""), false)
            }
        case "show_message":
            let text = String((args["text"] as? String ?? "").prefix(80))
            NotificationCenter.default.post(name: .notchMateShowSpeech, object: text)
            return (String(localized: "Показано"), false)
        default:
            return (String(localized: "Неизвестный инструмент \(name)"), true)
        }
    }

    static func todaySummary(env: AppEnvironment) -> String {
        var out: [String] = []
        let df = DateFormatter(); df.locale = Locale(identifier: "ru_RU"); df.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        out.append(String(localized: "Сейчас: \(df.string(from: Date()))"))
        let f = env.focus
        if f.isActive { out.append(String(localized: "Фокус-таймер: \(f.kind.title), осталось \(FocusTimer.format(f.remaining)), помидоров в цикле: \(f.completedInCycle)")) }
        if let i = env.jira.activeIssue {
            let spent = i.progressPeriods.isEmpty ? (i.timeSpent ?? 0) : i.timeInWork()
            let left = i.originalEstimate.map { JiraService.format($0 - spent) } ?? JiraService.format(i.remainingEstimate)
            out.append(String(localized: "Jira в работе: \(i.key) «\(i.summary)» [\(i.status)] прошло \(JiraService.format(spent)), осталось \(left), оценка \(JiraService.format(i.originalEstimate))"))
        }
        let others = env.jira.issues.filter { $0.key != env.jira.activeIssue?.key }.prefix(8)
        if !others.isEmpty { out.append(String(localized: "Мои задачи Jira:\n") + others.map { "• \($0.key) \($0.summary) [\($0.status)]" }.joined(separator: "\n")) }
        let events = env.calendar.describe(days: 1)
        out.append(events)
        out.append(env.reminders.describe())
        if let t = env.nowPlaying.track, t.isPlaying { out.append(String(localized: "Играет: \(t.artist) — \(t.title)")) }
        let agents = env.agents.sessions.values.filter { $0.state == .working }
        if !agents.isEmpty { out.append(String(localized: "ИИ-агенты работают: ") + agents.map { "\($0.agent.title) (\($0.project))" }.joined(separator: ", ")) }
        return out.joined(separator: "\n\n")
    }
}

extension Notification.Name {
    static let notchMateShowSpeech = Notification.Name("notchmate.showSpeech")
}
