import AppKit
import SwiftUI

/// Focus, do-not-disturb and distraction settings.
struct WorkSettings: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section(String(localized: "Помидоро")) {
                Stepper(String(localized: "Фокус: \(Int(settings.pomoWork)) мин"), value: $settings.pomoWork, in: 5...120, step: 5)
                Stepper(String(localized: "Короткий перерыв: \(Int(settings.pomoShort)) мин"), value: $settings.pomoShort, in: 1...30)
                Stepper(String(localized: "Длинный перерыв: \(Int(settings.pomoLong)) мин"), value: $settings.pomoLong, in: 5...60, step: 5)
                Stepper(String(localized: "Длинный перерыв каждые \(settings.pomoCycle) помидора"), value: $settings.pomoCycle, in: 2...8)
                Toggle(String(localized: "Автоматически начинать перерыв"), isOn: $settings.pomoAutoBreak)
                Toggle(String(localized: "Автоматически возвращаться к работе"), isOn: $settings.pomoAutoWork)
            }

            Section(String(localized: "Не беспокоить")) {
                Toggle(String(localized: "Во время созвона и фокуса Taby не отвлекает"), isOn: $settings.dndEnabled)
                Text(String(localized: "Молчат напоминания о воде и разминке, всплывающие названия треков, реплики и баннеры уведомлений. Напоминания о встречах и завершение долгой работы агента всё равно показываются."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(String(localized: "Антиотвлечение в фокусе")) {
                Toggle(String(localized: "Замечать отвлечения во время фокуса и таймера Jira"), isOn: $settings.distractionGuard)
                TextField(String(localized: "Приложения"), text: $settings.distractionApps, axis: .vertical).lineLimit(1...3)
                TextField(String(localized: "Сайты"), text: $settings.distractionSites, axis: .vertical).lineLimit(1...3)
                Toggle(String(localized: "Проверять открытый сайт в браузере"), isOn: $settings.distractionBrowsers)
                Text(String(localized: "Через 8 секунд на отвлекающем приложении или сайте Taby расстраивается и зовёт обратно. Для проверки сайтов macOS один раз спросит разрешение управлять браузером."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Calendar access and meeting reminders (shown inside Интеграции).
struct CalendarSettings: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var calendar = AppEnvironment.shared.calendar

    var body: some View {
        Section(String(localized: "Календарь")) {
            Toggle(String(localized: "Показывать встречи в вырезе"), isOn: $settings.calendarEnabled)
            if settings.calendarEnabled {
                if calendar.hasAccess {
                    LabeledContent(String(localized: "Доступ")) { Text(String(localized: "есть · событий на неделю: \(calendar.events.count)")) }
                } else {
                    Button(String(localized: "Разрешить доступ к календарю…")) { Task { await PermissionCenter.shared.request(.calendar) } }
                }
                Stepper(String(localized: "Напоминать за \(settings.calendarLeadMinutes) мин"), value: $settings.calendarLeadMinutes, in: 1...30)
                if calendar.hiddenCount > 0 {
                    HStack {
                        Text(String(localized: "Скрытых встреч: \(calendar.hiddenCount)")).foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Показать снова")) { calendar.unhideAll() }
                    }
                }
                Text(String(localized: "Крестик на встрече в «Требует внимания» убирает её из панели до конца встречи — остальные дни повторяющейся встречи остаются."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if settings.calendarEnabled, calendar.hasAccess, !calendar.sources.isEmpty {
            Section {
                ForEach(Dictionary(grouping: calendar.sources, by: \.account).sorted { $0.key < $1.key }, id: \.key) { account, list in
                    Text(account).font(.caption).foregroundStyle(.secondary)
                    ForEach(list) { source in
                        Toggle(isOn: Binding(get: { calendar.isShown(source) }, set: { calendar.setShown(source, $0) })) {
                            HStack(spacing: 8) {
                                Circle().fill(source.color).frame(width: 9, height: 9)
                                Text(source.title)
                            }
                        }
                    }
                }
            } header: {
                Text(String(localized: "Какие календари показывать"))
            } footer: {
                Text(String(localized: "Выключите календари отпусков, отгулов, праздников и чужих расписаний — их события не попадут на шкалу дня и в напоминания о встречах."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Reminders app: access, on/off and which lists feed the day timeline.
struct RemindersSettings: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var reminders = AppEnvironment.shared.reminders

    var body: some View {
        Form {
            Section(String(localized: "Напоминания")) {
                Toggle(String(localized: "Показывать напоминания в Помощнике"), isOn: $settings.remindersEnabled)
                if settings.remindersEnabled {
                    if reminders.hasAccess {
                        LabeledContent(String(localized: "Доступ")) { Text(String(localized: "есть · на сегодня: \(reminders.items.count)")) }
                    } else {
                        Button(String(localized: "Разрешить доступ к напоминаниям…")) {
                            Task { await PermissionCenter.shared.request(.reminders); reminders.refresh() }
                        }
                    }
                    Button(String(localized: "Открыть «Напоминания»")) { reminders.openApp() }
                }
                Text(String(localized: "На шкале дня появятся незакрытые напоминания на сегодня со временем. Просроченные и те, что без времени, — в делах под шкалой. Их можно отметить выполненными или отложить на час."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if settings.remindersEnabled, reminders.hasAccess, !reminders.lists.isEmpty {
                Section(String(localized: "Какие списки показывать")) {
                    ForEach(Dictionary(grouping: reminders.lists, by: \.account).sorted { $0.key < $1.key }, id: \.key) { account, list in
                        Text(account).font(.caption).foregroundStyle(.secondary)
                        ForEach(list) { source in
                            Toggle(isOn: Binding(get: { reminders.isShown(source) }, set: { reminders.setShown(source, $0) })) {
                                HStack(spacing: 8) {
                                    Circle().fill(source.color).frame(width: 9, height: 9)
                                    Text(source.title)
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reminders.refresh() }
    }
}

/// Claude Code / Codex hooks and the NotchMate MCP server.
struct AgentSettings: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var agents = AppEnvironment.shared.agents
    @State private var status: (text: String, ok: Bool)?
    @State private var busy = false

    var body: some View {
        Form {
            Section(String(localized: "Статус агентов")) {
                Toggle(String(localized: "Показывать, когда агент работает и когда ответ готов"), isOn: $settings.agentStatusEnabled)
                Toggle(String(localized: "Звук, когда агент закончил или ждёт ответа"), isOn: $settings.agentSound)
                hookRow(title: "Claude Code", installed: agents.claudeHooksInstalled,
                        note: String(localized: "Добавит хуки в ~/.claude/settings.json (резервная копия рядом).")) { try agents.setClaudeHooks($0) }
                hookRow(title: "Codex", installed: agents.codexHooksInstalled,
                        note: String(localized: "Добавит хуки в ~/.codex/hooks.json и сразу подтвердит их в Codex (только хуки NotchMate).")) { install in
                    try agents.setCodexHooks(install)
                    if install {
                        Task {
                            do {
                                let n = try await AppEnvironment.shared.ai.codex.trustNotchMateHooks()
                                status = (String(localized: "Codex: хуки установлены и подтверждены (\(n))"), true)
                            } catch {
                                status = (String(localized: "Ошибка подтверждения хуков Codex: \(error.localizedDescription)"), false)
                            }
                        }
                    }
                }
            }

            Section(String(localized: "MCP-сервер NotchMate")) {
                Text(String(localized: "Даёт Claude Code и Codex инструменты NotchMate: сводка дня, задачи и заметки Obsidian, фокус, Jira, календарь, музыка, сообщения в вырезе. Через него же работают действия в чате ИИ для аккаунтов ChatGPT и Claude."))
                    .font(.caption).foregroundStyle(.secondary)
                mcpRow("Claude Code", target: .claude)
                mcpRow("Codex", target: .codex)
            }

            if let status {
                Text(status.text).foregroundStyle(status.ok ? .green : .red)
            }
        }
        .formStyle(.grouped)
        .onAppear { agents.refreshInstallState() }
    }

    private func hookRow(title: String, installed: Bool, note: String, action: @escaping (Bool) throws -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: installed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(installed ? .green : .primary)
                Spacer()
                Button(installed ? String(localized: "Отключить") : String(localized: "Подключить")) {
                    do {
                        try action(!installed)
                        status = (installed ? String(localized: "\(title): хуки удалены") : String(localized: "\(title): хуки установлены"), true)
                    } catch {
                        status = (String(localized: "Ошибка: \(error.localizedDescription)"), false)
                    }
                }
            }
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func mcpRow(_ title: String, target: AgentMonitor.MCPTarget) -> some View {
        let installed = agents.mcpInstalled(target)
        return HStack {
            Label(title, systemImage: installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(installed ? .green : .primary)
            Spacer()
            Button(busy ? "…" : (installed ? String(localized: "Отключить") : String(localized: "Подключить"))) {
                busy = true
                Task {
                    status = await agents.setMCP(target, install: !installed)
                    busy = false
                }
            }
            .disabled(busy)
        }
    }
}

struct CallSettings: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var calls = AppEnvironment.shared.calls
    @ObservedObject var copilot = AppEnvironment.shared.copilot

    var body: some View {
        Section(String(localized: "Созвоны")) {
            Toggle(String(localized: "Записывать автоматически, когда включается микрофон"), isOn: $settings.callsAutoRecord)
            Toggle(String(localized: "Записывать и мой микрофон (иначе только собеседников)"), isOn: $settings.callsCaptureMic)
            Stepper(String(localized: "Считать созвоном после \(settings.callsMinSeconds) сек разговора"), value: $settings.callsMinSeconds, in: 5...300, step: 5)
            CallAppsEditor()
            CallSitesEditor()
            Toggle(String(localized: "Резюме делать своей ИИ, если она настроена"), isOn: $settings.callsSummaryLocalOnly)
            Toggle(String(localized: "Хранить аудио после расшифровки"), isOn: $settings.callsKeepAudio)
            TextField(String(localized: "Папка заметок"), text: $settings.callsFolder)
            TextField(String(localized: "Язык распознавания"), text: $settings.callsLocale)
            HStack {
                Text(status).foregroundStyle(calls.lastError == nil ? Color.secondary : Color.red)
                Spacer()
                Button(calls.stage == .recording ? String(localized: "Остановить") : String(localized: "Записать сейчас")) {
                    Task {
                        if calls.stage == .recording { await calls.finishRecording() } else { await calls.beginRecording() }
                    }
                }
            }
            Text(String(localized: "Автозапись включается, только если микрофон держит программа из списка дольше указанного времени, или если в календаре идёт встреча. Голосовые в мессенджерах короче порога не записываются."))
                .font(.caption).foregroundStyle(.secondary)
            Text(String(localized: "Запись, расшифровка и аудио остаются на этом компьютере: \(CallRecorder.recordingsFolder.path). Наружу уходит только текст расшифровки — в ту ИИ, которой делается протокол. Предупреждайте собеседников о записи."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(String(localized: "Помощник на встрече")) {
            HStack {
                Text(String(localized: "Слушает созвон и подсказывает, что спросить, что ответить и что уже есть в коде. Окно подсказок не видно при демонстрации экрана."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(copilot.isActive ? String(localized: "Выключить") : String(localized: "Включить")) {
                    if copilot.isActive { copilot.close() } else { copilot.activate() }
                }
            }
            Toggle(String(localized: "Подсказывать самому на паузах в разговоре"), isOn: $settings.meetingAutoHints)
            Stepper(String(localized: "Не чаще раза в \(settings.meetingHintInterval) сек"), value: $settings.meetingHintInterval, in: 8...120, step: 4)
                .disabled(!settings.meetingAutoHints)
            TextField(String(localized: "Кто я на встречах"), text: $settings.meetingRole, axis: .vertical)
            Picker(String(localized: "Модель (только быстрые)"), selection: $settings.meetingModel) {
                Text(String(localized: "Самая быстрая из доступных")).tag("")
                ForEach(copilot.fastModels) { m in
                    Text(m.available ? m.title : "\(m.title) — \(m.note)").tag(m.id)
                }
            }
            .onAppear { copilot.refreshModels() }
            Toggle(String(localized: "Скрывать подсказки при демонстрации и записи экрана"), isOn: $settings.meetingHideFromCapture)
            Text(String(localized: "Расшифровка идёт на этом компьютере. В ИИ уходят последние несколько минут разговора и короткие выдержки из кода выбранного репозитория."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        if let e = calls.lastError { return e }
        switch calls.stage {
        case .idle: return calls.micActive ? String(localized: "Микрофон занят — идёт созвон") : String(localized: "Ожидание созвона")
        case .recording: return String(localized: "Идёт запись: \(FocusTimer.format(calls.elapsed))")
        case .transcribing: return String(localized: "Расшифровка…")
        case .summarizing: return String(localized: "Готовлю протокол…")
        }
    }
}

/// Programs whose microphone use means "a call is going on".
struct CallAppsEditor: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Программы созвонов")).font(.subheadline.weight(.medium))
            if settings.callsAppIDs.isEmpty {
                Text(String(localized: "Пока ничего не выбрано — созвон определяется по встрече в календаре или по сайту."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(settings.callsAppIDs, id: \.self) { id in
                HStack(spacing: 8) {
                    Image(nsImage: Self.icon(id)).resizable().frame(width: 18, height: 18)
                    Text(Self.name(id)).lineLimit(1)
                    Text(id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button {
                        settings.callsAppIDs.removeAll { $0 == id }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                Menu(String(localized: "Из недавних…")) {
                    let recents = settings.callsSeenApps.filter { !settings.callsAppIDs.contains($0.key) }
                    if recents.isEmpty {
                        Text(String(localized: "Пока никто не занимал микрофон"))
                    } else {
                        ForEach(recents.sorted(by: { $0.value < $1.value }), id: \.key) { id, name in
                            Button(name) { add(id) }
                        }
                    }
                }
                .fixedSize()
                Menu(String(localized: "Из запущенных…")) {
                    let running = NSWorkspace.shared.runningApplications
                        .filter { $0.activationPolicy == .regular }
                        .compactMap { app -> (String, String)? in
                            guard let id = app.bundleIdentifier, !settings.callsAppIDs.contains(id) else { return nil }
                            return (id, app.localizedName ?? id)
                        }
                    ForEach(running.sorted(by: { $0.1 < $1.1 }), id: \.0) { id, name in
                        Button(name) { add(id) }
                    }
                }
                .fixedSize()
                Button(String(localized: "Добавить программу…")) { pick() }
            }
        }
    }

    private func add(_ id: String) {
        guard !settings.callsAppIDs.contains(id) else { return }
        settings.callsAppIDs.append(id)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Добавить")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { add(id) }
        }
    }

    static func name(_ id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return Settings.shared.callsSeenApps[id] ?? id
    }

    static func icon(_ id: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }
}

/// Sites that mean a call when they are open in a browser holding the microphone.
struct CallSitesEditor: View {
    @ObservedObject private var settings = Settings.shared
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Сайты созвонов")).font(.subheadline.weight(.medium))
            ForEach(settings.callsSites, id: \.self) { site in
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Text(site)
                    Spacer()
                    Button {
                        settings.callsSites.removeAll { $0 == site }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("meet.google.com", text: $draft).onSubmit(addSite)
                Button(String(localized: "Добавить"), action: addSite).disabled(cleaned.isEmpty)
            }
        }
    }

    private var cleaned: String {
        var s = draft.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["https://", "http://", "www."] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        return s.split(separator: "/").first.map(String.init) ?? ""
    }

    private func addSite() {
        let site = cleaned
        guard !site.isEmpty, !settings.callsSites.contains(site) else { return }
        settings.callsSites.append(site)
        draft = ""
    }
}
