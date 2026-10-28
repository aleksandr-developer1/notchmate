import SwiftUI

enum PluginCategory: String, CaseIterable, Identifiable {
    case productivity, media, connections, wellbeing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .productivity: return String(localized: "Работа")
        case .media: return String(localized: "Музыка и файлы")
        case .connections: return String(localized: "Интеграции")
        case .wellbeing: return String(localized: "Для себя")
        }
    }
}

/// Built-in modules share one persistent switch across the catalog, navigation and services.
enum PluginID: String, CaseIterable, Identifiable {
    case companion, ai, jira, git, notes, obsidian, music, shelf, clipboard
    case focus, calendar, reminders, calls, meetingAssistant, agents, garmin, appleHealth, weather
    var id: String { rawValue }

    var title: String {
        switch self {
        case .companion: return String(localized: "Помощник")
        case .ai: return String(localized: "Чат ИИ")
        case .jira: return "Jira"
        case .git: return String(localized: "Git и GitHub")
        case .notes: return "Apple Notes"
        case .obsidian: return "Obsidian"
        case .music: return String(localized: "Музыка")
        case .shelf: return String(localized: "Полка")
        case .clipboard: return String(localized: "Буфер обмена")
        case .focus: return String(localized: "Фокус")
        case .calendar: return String(localized: "Календарь")
        case .reminders: return String(localized: "Напоминания")
        case .calls: return String(localized: "Запись созвонов")
        case .meetingAssistant: return String(localized: "Помощник на встрече")
        case .agents: return String(localized: "ИИ-агенты и MCP")
        case .garmin: return "Garmin Connect"
        case .appleHealth: return "Apple Health"
        case .weather: return String(localized: "Погода")
        }
    }

    var summary: String {
        switch self {
        case .companion: return String(localized: "Живой персонаж, события дня и заботливые напоминания.")
        case .ai: return String(localized: "ChatGPT, Claude и свои модели — разговор прямо в вырезе.")
        case .jira: return String(localized: "Задачи, рабочее время и списание без переключения окон.")
        case .git: return String(localized: "Изменения в репозитории, pull request и состояние CI.")
        case .notes: return String(localized: "Быстрая запись, поиск и закреплённые заметки Apple Notes.")
        case .obsidian: return String(localized: "Ваше хранилище Markdown, ежедневные заметки и поиск.")
        case .music: return String(localized: "Текущий трек, обложка, громкость и управление плеером.")
        case .shelf: return String(localized: "Файлы и ссылки под рукой: перетащите их в вырез.")
        case .clipboard: return String(localized: "История скопированного текста, изображений и файлов.")
        case .focus: return String(localized: "Помидоры, перерывы и защита от отвлекающих приложений.")
        case .calendar: return String(localized: "Ближайшие встречи и ссылки на звонки на шкале дня.")
        case .reminders: return String(localized: "Дела из приложения «Напоминания» на вашей шкале дня.")
        case .calls: return String(localized: "Локальная запись звука, расшифровка и протокол созвона.")
        case .meetingAssistant: return String(localized: "Подсказки, вопросы и контекст кода во время встречи.")
        case .agents: return String(localized: "Статусы Claude Code и Codex, уведомления и инструменты MCP.")
        case .garmin: return String(localized: "Данные Garmin: стресс, сон, пульс и Body Battery.")
        case .appleHealth: return String(localized: "Данные Apple «Здоровье» с iPhone через экспорт в iCloud.")
        case .weather: return String(localized: "Температура в шапке панели и предупреждение о дожде.")
        }
    }

    var icon: String {
        switch self {
        case .companion: return "face.smiling"
        case .ai: return "sparkles"
        case .jira: return "briefcase.fill"
        case .git: return "arrow.triangle.branch"
        case .notes: return "note.text"
        case .obsidian: return "text.book.closed.fill"
        case .music: return "music.note"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .focus: return "timer"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .calls: return "waveform"
        case .meetingAssistant: return "waveform.and.mic"
        case .agents: return "terminal.fill"
        case .garmin: return "applewatch.side.right"
        case .appleHealth: return "heart.text.square"
        case .weather: return "cloud.sun.fill"
        }
    }

    var category: PluginCategory {
        switch self {
        case .ai, .jira, .git, .notes, .focus: return .productivity
        case .music, .shelf, .clipboard: return .media
        case .obsidian, .calendar, .reminders, .calls, .meetingAssistant, .agents: return .connections
        case .companion, .garmin, .appleHealth, .weather: return .wellbeing
        }
    }

    var tint: Color {
        switch self {
        case .ai, .obsidian, .meetingAssistant: return Color(red: 0.65, green: 0.49, blue: 1)
        case .jira, .git, .calendar: return Color(red: 0.3, green: 0.63, blue: 1)
        case .music, .garmin, .appleHealth: return Color(red: 1, green: 0.4, blue: 0.55)
        case .notes, .focus, .companion: return Color(red: 1, green: 0.72, blue: 0.3)
        default: return Color(red: 0.3, green: 0.8, blue: 0.7)
        }
    }

    var dependencies: [PluginID] {
        switch self {
        case .meetingAssistant: return [.calls, .ai]
        default: return []
        }
    }

    func isEnabled(disabled: Set<String>) -> Bool {
        !disabled.contains(rawValue) && dependencies.allSatisfy { $0.isEnabled(disabled: disabled) }
    }

    /// Disabling a parent also disables its dependent modules without deleting their configuration.
    var disabling: Set<PluginID> {
        var result: Set<PluginID> = [self]
        while true {
            let next = result.union(Self.allCases.filter { $0.dependencies.contains { result.contains($0) } })
            if next == result { return result }
            result = next
        }
    }
}

enum PluginError: LocalizedError {
    case disabled(PluginID)
    var errorDescription: String? {
        switch self {
        case .disabled(let plugin): return String(localized: "Плагин «\(plugin.title)» выключен. Включите его в каталоге плагинов.")
        }
    }
}

extension Settings {
    func pluginEnabled(_ plugin: PluginID) -> Bool {
        guard plugin.isEnabled(disabled: disabledPlugins) else { return false }
        switch plugin {
        case .garmin: return garminEnabled
        case .appleHealth: return appleHealthEnabled
        case .git: return gitEnabled
        case .calendar: return calendarEnabled
        case .reminders: return remindersEnabled
        case .clipboard: return clipboardEnabled
        case .agents: return agentStatusEnabled
        default: return true
        }
    }
}
