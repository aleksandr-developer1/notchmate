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
                    description: "Сводка дня пользователя: дата, фокус-таймер, задача Jira в работе (прошло/осталось), мои задачи Jira, события календаря, музыка, активные ИИ-агенты. Вызывай, когда спрашивают про день, задачи или планы.",
                    schema: obj([:])),
        NotchMateTool(name: "add_note",
                    description: "Записать мысль строкой в ежедневную заметку Obsidian.",
                    schema: obj(["text": ["type": "string"]], required: ["text"])),
        NotchMateTool(name: "search_notes",
                    description: "Поиск по заметкам Obsidian (заголовки и текст). Возвращает до 6 результатов со сниппетами.",
                    schema: obj(["query": ["type": "string"]], required: ["query"])),
        NotchMateTool(name: "start_focus",
                    description: "Запустить помидоро-таймер фокуса.",
                    schema: obj(["minutes": ["type": "number", "description": "Длительность, по умолчанию из настроек"],
                                 "label": ["type": "string", "description": "На что фокус, например ключ задачи"]])),
        NotchMateTool(name: "stop_focus", description: "Остановить фокус-таймер.", schema: obj([:])),
        NotchMateTool(name: "jira_log_time",
                    description: "Списать время (worklog) в задачу Jira. Используй ТОЛЬКО когда пользователь явно попросил списать время.",
                    schema: obj(["key": ["type": "string", "description": "Ключ задачи, например PROJ-123; по умолчанию задача в работе"],
                                 "minutes": ["type": "number", "description": "Сколько минут списать"],
                                 "comment": ["type": "string"]], required: ["minutes"])),
        NotchMateTool(name: "calendar_events",
                    description: "События календаря на ближайшие дни.",
                    schema: obj(["days": ["type": "number", "description": "Сколько дней вперёд, 1–7"]])),
        NotchMateTool(name: "media_control",
                    description: "Управление музыкой: play, pause, toggle, next, previous.",
                    schema: obj(["action": ["type": "string", "enum": ["play", "pause", "toggle", "next", "previous"]]], required: ["action"])),
        NotchMateTool(name: "call_recording",
                    description: "Управление записью созвона: start — начать, stop — остановить и сделать протокол, status — состояние, process_pending — доделать записи, оставшиеся с прошлого запуска.",
                    schema: obj(["action": ["type": "string", "enum": ["start", "stop", "status", "process_pending"]],
                                 "folder": ["type": "string", "description": "Имя папки записи, например «2026-09-16 10-55»"]], required: ["action"])),
        NotchMateTool(name: "show_message",
                    description: "Показать короткое сообщение под вырезом MacBook (например, когда долгая задача агента завершена).",
                    schema: obj(["text": ["type": "string", "description": "До 60 символов"]], required: ["text"])),
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
            guard let text = args["text"] as? String, env.notes.capture(text) else { return ("Не удалось записать", true) }
            return ("Записано в заметку дня", false)
        case "search_notes":
            let hits = await env.notes.search(args["query"] as? String ?? "")
            if hits.isEmpty { return ("Ничего не найдено", false) }
            return (hits.prefix(6).map { "• \($0.note.relativePath)\($0.snippet.map { " — \($0)" } ?? "")" }.joined(separator: "\n"), false)
        case "start_focus":
            let minutes = (args["minutes"] as? NSNumber)?.doubleValue
            let label = args["label"] as? String ?? env.jira.activeIssue.map { "\($0.key) · \($0.summary)" } ?? "Помидор"
            env.focus.start(minutes: minutes, label: label, task: env.jira.activeIssue?.key)
            return ("Фокус запущен на \(Int(minutes ?? env.settings.pomoWork)) мин", false)
        case "stop_focus":
            env.focus.reset()
            return ("Фокус остановлен", false)
        case "jira_log_time":
            guard let minutes = (args["minutes"] as? NSNumber)?.doubleValue, minutes >= 1 else { return ("Укажите минуты", true) }
            guard let key = (args["key"] as? String) ?? env.jira.activeIssue?.key else { return ("Нет задачи в работе — укажите ключ", true) }
            do {
                try await env.jira.logWork(key: key, seconds: Int(minutes * 60), comment: args["comment"] as? String ?? "")
                return ("Списано \(JiraService.format(Int(minutes * 60))) в \(key)", false)
            } catch { return ("Jira: \(error.localizedDescription)", true) }
        case "calendar_events":
            let days = max(1, min(7, (args["days"] as? NSNumber)?.intValue ?? 1))
            return (env.calendar.describe(days: days) + "\n\n" + env.reminders.describe(), false)
        case "media_control":
            let map: [String: MediaCommand] = ["play": .play, "pause": .pause, "toggle": .toggle, "next": .next, "previous": .previous]
            guard let cmd = map[args["action"] as? String ?? ""] else { return ("Неизвестное действие", true) }
            env.nowPlaying.send(cmd)
            return ("Ок", false)
        case "call_recording":
            let calls = env.calls
            switch args["action"] as? String {
            case "start":
                await calls.beginRecording()
                return (calls.stage == .recording ? "Запись началась" : (calls.lastError ?? "Не удалось начать"), calls.stage != .recording)
            case "stop":
                guard calls.stage == .recording else { return ("Запись не идёт", true) }
                Task { await calls.finishRecording() }
                return ("Останавливаю запись, делаю протокол", false)
            case "process_pending":
                let pending = CallRecorder.pendingRecordings()
                let wanted = args["folder"] as? String
                guard let target = wanted.flatMap({ name in pending.first { $0.lastPathComponent == name } }) ?? pending.first else {
                    return ("Незавершённых записей нет", false)
                }
                Task { await calls.processExisting(folder: target) }
                return ("Обрабатываю запись \(target.lastPathComponent)", false)
            default:
                let state: String
                switch calls.stage {
                case .idle: state = calls.micActive ? "микрофон занят, запись не идёт" : "ожидание"
                case .recording: state = "идёт запись \(FocusTimer.format(calls.elapsed))"
                case .transcribing: state = "расшифровка"
                case .summarizing: state = "готовлю протокол"
                }
                let pending = CallRecorder.pendingRecordings().count
                return ("Созвон: \(state)" + (pending > 0 ? ", незавершённых записей: \(pending)" : "") + (calls.lastNote.map { ", последний протокол: \($0)" } ?? ""), false)
            }
        case "show_message":
            let text = String((args["text"] as? String ?? "").prefix(80))
            NotificationCenter.default.post(name: .notchMateShowSpeech, object: text)
            return ("Показано", false)
        default:
            return ("Неизвестный инструмент \(name)", true)
        }
    }

    static func todaySummary(env: AppEnvironment) -> String {
        var out: [String] = []
        let df = DateFormatter(); df.locale = Locale(identifier: "ru_RU"); df.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        out.append("Сейчас: \(df.string(from: Date()))")
        let f = env.focus
        if f.isActive { out.append("Фокус-таймер: \(f.kind.title), осталось \(FocusTimer.format(f.remaining)), помидоров в цикле: \(f.completedInCycle)") }
        if let i = env.jira.activeIssue {
            let spent = i.progressPeriods.isEmpty ? (i.timeSpent ?? 0) : i.timeInWork()
            let left = i.originalEstimate.map { JiraService.format($0 - spent) } ?? JiraService.format(i.remainingEstimate)
            out.append("Jira в работе: \(i.key) «\(i.summary)» [\(i.status)] прошло \(JiraService.format(spent)), осталось \(left), оценка \(JiraService.format(i.originalEstimate))")
        }
        let others = env.jira.issues.filter { $0.key != env.jira.activeIssue?.key }.prefix(8)
        if !others.isEmpty { out.append("Мои задачи Jira:\n" + others.map { "• \($0.key) \($0.summary) [\($0.status)]" }.joined(separator: "\n")) }
        let events = env.calendar.describe(days: 1)
        out.append(events)
        out.append(env.reminders.describe())
        if let t = env.nowPlaying.track, t.isPlaying { out.append("Играет: \(t.artist) — \(t.title)") }
        let agents = env.agents.sessions.values.filter { $0.state == .working }
        if !agents.isEmpty { out.append("ИИ-агенты работают: " + agents.map { "\($0.agent.title) (\($0.project))" }.joined(separator: ", ")) }
        return out.joined(separator: "\n\n")
    }
}

extension Notification.Name {
    static let notchMateShowSpeech = Notification.Name("notchmate.showSpeech")
}
