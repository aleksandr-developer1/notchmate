import AppKit
import SwiftUI

/// Settings live in a sidebar, not in a row of tabs: everything that can grow
/// (integrations above all) gets its own page instead of a new tab.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, hotkeys, assistant, work, calls, integrations, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Основные"
        case .hotkeys: return "Горячие клавиши"
        case .assistant: return "Помощник"
        case .work: return "Фокус и время"
        case .calls: return "Созвоны"
        case .integrations: return "Интеграции"
        case .permissions: return "Разрешения"
        case .about: return "О программе"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .hotkeys: return "keyboard"
        case .assistant: return "face.smiling"
        case .work: return "timer"
        case .calls: return "waveform"
        case .integrations: return "puzzlepiece.extension"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var settings = Settings.shared
    @State private var page: SettingsPage? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    row(.general); row(.hotkeys); row(.assistant); row(.work); row(.calls)
                }
                Section {
                    row(.integrations); row(.permissions)
                }
                Section {
                    row(.about)
                }
            }
            .navigationSplitViewColumnWidth(196)
        } detail: {
            detail
                .navigationTitle(page?.title ?? "Настройки")
        }
        .frame(width: 820, height: 620)
    }

    private func row(_ p: SettingsPage) -> some View {
        Label(p.title, systemImage: p.icon).tag(p)
    }

    @ViewBuilder private var detail: some View {
        switch page ?? .general {
        case .general: GeneralSettings()
        case .hotkeys: HotkeysSettings()
        case .assistant: AssistantSettings()
        case .work: WorkSettings()
        case .calls: Form { CallSettings() }.formStyle(.grouped)
        case .integrations: IntegrationsSettings()
        case .permissions: PermissionsSettings()
        case .about: AboutSettings()
        }
    }
}

// MARK: - Основные

struct GeneralSettings: View {
    @ObservedObject var settings = Settings.shared

    /// Camera cutout width of the built-in display, or the virtual island width on Macs without a notch.
    static var cameraCutoutWidth: CGFloat {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return 200 }
        return screen.frame.width - left.width - right.width
    }

    /// Never narrower than a physical notch — the camera must stay covered.
    static var collapsedRange: ClosedRange<Double> {
        let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
        return (hasNotch ? Double(cameraCutoutWidth.rounded(.up)) : 120)...420
    }

    var body: some View {
        Form {
            Section("Поведение") {
                Picker("Открывать панель", selection: $settings.openTrigger) {
                    ForEach(OpenTrigger.allCases) { Text($0.title).tag($0) }
                }
                if settings.openTrigger == .hover {
                    LabeledContent("Задержка наведения") {
                        HStack {
                            Slider(value: $settings.hoverDelay, in: 0...0.8)
                            Text("\(Int(settings.hoverDelay * 1000)) мс").monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                }
                Toggle("Тактильный отклик трекпада", isOn: $settings.haptics)
                LabeledContent("Ширина панели") {
                    HStack {
                        Slider(value: $settings.expandedWidth, in: 600...820, step: 10)
                        Text("\(Int(settings.expandedWidth)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Toggle("Ширина свёрнутого островка по вырезу камеры", isOn: Binding(
                    get: { settings.collapsedWidth <= 0 },
                    set: { settings.collapsedWidth = $0 ? 0 : Double(Self.cameraCutoutWidth.rounded()) }))
                if settings.collapsedWidth > 0 {
                    LabeledContent("Ширина свёрнутого островка") {
                        HStack {
                            Slider(value: $settings.collapsedWidth, in: Self.collapsedRange, step: 2)
                            Text("\(Int(settings.collapsedWidth)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
            Section("Живые активности") {
                Toggle("Обложка и эквалайзер в вырезе во время музыки", isOn: $settings.showMusicActivity)
                Picker("Подсветка панели", selection: $settings.notchGlowMode) {
                    ForEach(NotchGlowMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Дискотека сама включается, если мак не трогают под музыку", isOn: $settings.autoDisco)
                Toggle("Показывать название нового трека", isOn: $settings.sneakPeek)
                Toggle("Индикатор зарядки при подключении питания", isOn: $settings.chargingHUD)
            }
            Section("Буфер обмена") {
                Toggle("Вести историю буфера", isOn: $settings.clipboardEnabled)
                Text("Пароли из менеджеров паролей (помеченные как скрытые) не сохраняются. История хранится только в памяти.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Система") {
                Toggle("Запускать при входе в систему", isOn: $settings.launchAtLogin)
                Toggle("Иконка в строке меню", isOn: $settings.showMenuBarIcon)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Помощник

struct AssistantSettings: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section("Компаньон") {
                HStack {
                    Spacer()
                    FaceView(mood: .idle, scale: 1.5, color: settings.faceColor.color)
                        .padding(12).background(RoundedRectangle(cornerRadius: 14).fill(.black))
                    Spacer()
                }
                Toggle("Показывать мордочку под вырезом", isOn: $settings.showFace)
                Toggle("Убирать мордочку влево от выреза, когда под ней окно", isOn: $settings.dockFaceWhenCovered)
                    .disabled(!settings.showFace)
                Picker("Данные активности", selection: $settings.activityLayout) {
                    ForEach(ActivityLayout.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!settings.showFace)
                Text("Музыка, таймеры, Jira и зарядка: по бокам от мордочки — вырез не расширяется; слева и справа от камеры — вырез становится шире.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Имя", text: $settings.companionName)
                Picker("Цвет мордочки", selection: $settings.faceColor) {
                    ForEach(FacePalette.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Следит взглядом за курсором", isOn: $settings.followCursor)
                Text("Если быстро потрясти курсором, у мордочки закружится голова.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ReactionSettings()
            Section("Характер") {
                Toggle("Настроение по интенсивности работы (в потоке / скучает)", isOn: $settings.activityMoods)
                Toggle("Мини-сценки в простое (рыбалка, мяч)", isOn: $settings.idleScenes)
            }
            Section("Забота") {
                Toggle("Напоминать пить воду", isOn: $settings.waterReminder)
                if settings.waterReminder {
                    Stepper("Каждые \(Int(settings.waterInterval)) мин", value: $settings.waterInterval, in: 15...180, step: 15)
                }
                Toggle("Напоминать размяться", isOn: $settings.stretchReminder)
                if settings.stretchReminder {
                    Stepper("Каждые \(Int(settings.stretchInterval)) мин", value: $settings.stretchInterval, in: 30...240, step: 15)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Интеграции

/// Everything that connects NotchMate to something outside it. New services get a
/// row here instead of a new tab in the window.
enum Integration: String, CaseIterable, Identifiable {
    case obsidian, jira, git, ai, agents, calendar, reminders, health
    var id: String { rawValue }

    var title: String {
        switch self {
        case .obsidian: return "Obsidian"
        case .jira: return "Jira"
        case .git: return "Git и GitHub"
        case .ai: return "ИИ"
        case .agents: return "ИИ-агенты и MCP"
        case .calendar: return "Календарь"
        case .reminders: return "Напоминания"
        case .health: return "Здоровье"
        }
    }

    var subtitle: String {
        switch self {
        case .obsidian: return "Заметки, быстрая запись, протоколы созвонов"
        case .jira: return "Задачи, время в работе, списание"
        case .git: return "Репозиторий из терминала, CI и PR, сообщения коммитов"
        case .ai: return "Аккаунты ChatGPT и Claude, ключи API, своя модель"
        case .agents: return "Claude Code и Codex: статус работы и инструменты NotchMate"
        case .calendar: return "Встречи на шкале дня и в вырезе"
        case .reminders: return "Дела из «Напоминаний» на шкале дня"
        case .health: return "Garmin Connect и Apple Health: стресс, Body Battery, сон, пульс"
        }
    }

    var icon: String {
        switch self {
        case .obsidian: return "text.book.closed"
        case .jira: return "briefcase"
        case .git: return "arrow.triangle.branch"
        case .ai: return "sparkles"
        case .agents: return "terminal"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .health: return "heart.text.square"
        }
    }
}

struct IntegrationsSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var settings = Settings.shared
    @ObservedObject var agents = AppEnvironment.shared.agents
    @ObservedObject var calendar = AppEnvironment.shared.calendar
    @ObservedObject var reminders = AppEnvironment.shared.reminders

    @State private var opened: Integration?

    var body: some View {
        // A plain state switch instead of NavigationStack: inside a split-view
        // detail the automatic back button lands in the (transparent) titlebar
        // and is easy to miss, so the header below carries it.
        if let opened {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        self.opened = nil
                    } label: {
                        Label("Интеграции", systemImage: "chevron.left")
                    }
                    .buttonStyle(.accessoryBar)
                    Divider().frame(height: 14)
                    Image(systemName: opened.icon).foregroundStyle(.secondary)
                    Text(opened.title).font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
                page(opened)
            }
        } else {
            List {
                Section {
                    ForEach(Integration.allCases) { item in
                        Button { opened = item } label: { row(item) }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                    }
                } footer: {
                    Text("Дальше здесь появятся другие сервисы. Все ключи и токены остаются на этом компьютере.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onAppear { agents.refreshInstallState() }
        }
    }

    private func row(_ item: Integration) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.medium))
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            let s = state(item)
            HStack(spacing: 5) {
                Circle().fill(s.on ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                Text(s.text).font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func page(_ item: Integration) -> some View {
        switch item {
        case .obsidian: ObsidianSettings()
        case .jira: JiraSettings()
        case .git: GitSettings()
        case .ai: AISettings()
        case .agents: AgentSettings()
        case .calendar: Form { CalendarSettings() }.formStyle(.grouped)
        case .reminders: RemindersSettings()
        case .health: HealthSettings()
        }
    }

    private func state(_ item: Integration) -> (on: Bool, text: String) {
        switch item {
        case .obsidian:
            if let v = env.obsidian.vault { return (true, v.name) }
            return (false, "не найдено")
        case .jira:
            let ready = !settings.jiraURL.isEmpty && !(Keychain.get(JiraService.tokenAccount) ?? "").isEmpty
            return (ready, ready ? "подключено" : "не настроено")
        case .git:
            if !settings.gitEnabled { return (false, "выключено") }
            return (true, env.git.ghAvailable ? "GitHub CLI найден" : "без CI")
        case .ai:
            return (true, settings.aiProvider.title)
        case .agents:
            let n = [agents.claudeHooksInstalled, agents.codexHooksInstalled].filter { $0 }.count
            return (n > 0, n > 0 ? "подключено: \(n)" : "не подключено")
        case .calendar:
            if !settings.calendarEnabled { return (false, "выключен") }
            return (calendar.hasAccess, calendar.hasAccess ? "есть доступ" : "нет доступа")
        case .reminders:
            if !settings.remindersEnabled { return (false, "выключены") }
            return (reminders.hasAccess, reminders.hasAccess ? "есть доступ" : "нет доступа")
        case .health:
            let on = [settings.garminEnabled ? "Garmin" : nil, settings.appleHealthEnabled ? "Apple Health" : nil].compactMap { $0 }
            return (!on.isEmpty, on.isEmpty ? "не подключено" : on.joined(separator: " + "))
        }
    }
}

// MARK: - Obsidian

struct ObsidianSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section("Хранилище") {
                Picker("Хранилище", selection: $settings.vaultPath) {
                    Text("Авто (последнее открытое)").tag("")
                    ForEach(env.obsidian.vaults) { v in Text(v.name).tag(v.path) }
                    if !settings.vaultPath.isEmpty && !env.obsidian.vaults.contains(where: { $0.path == settings.vaultPath }) {
                        Text((settings.vaultPath as NSString).lastPathComponent).tag(settings.vaultPath)
                    }
                }
                .onChange(of: settings.vaultPath) { _, _ in env.obsidian.refresh(force: true) }
                LabeledContent("Путь") {
                    HStack {
                        Text(env.obsidian.vault?.path ?? "не найдено").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Выбрать…") { pickVault() }
                    }
                }
                LabeledContent("Заметок") { Text("\(env.obsidian.notes.count)").monospacedDigit() }
            }
            Section("Быстрая запись") {
                Picker("Куда записывать", selection: $settings.captureTarget) {
                    ForEach(CaptureTarget.allCases) { Text($0.title).tag($0) }
                }
                if settings.captureTarget == .inbox {
                    TextField("Файл входящих", text: $settings.inboxPath)
                }
                Toggle("Добавлять время (HH:mm)", isOn: $settings.captureTimestamp)
                Text("Ежедневная заметка использует папку и формат из настроек плагина «Ежедневные заметки» в Obsidian.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Выбрать хранилище"
        if panel.runModal() == .OK, let url = panel.url {
            settings.vaultPath = url.path
        }
    }
}

// MARK: - О программе

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.topthird.inset.filled").font(.system(size: 54)).foregroundStyle(.tint)
            Text("NotchMate").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Умный помощник за вырезом камеры: музыка, Obsidian, полка файлов, буфер обмена и фокус-таймер.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            Text("Now Playing: ungive/mediaremote-adapter (BSD-3)").font(.caption).foregroundStyle(.tertiary)
            Button("Выйти из NotchMate") { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Jira

struct JiraSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var settings = Settings.shared
    @State private var secret = Keychain.get(JiraService.tokenAccount) ?? ""
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Подключение") {
                TextField("Адрес Jira", text: $settings.jiraURL)
                Picker("Вход", selection: $settings.jiraAuth) {
                    ForEach(JiraAuth.allCases) { Text($0.title).tag($0) }
                }
                if settings.jiraAuth == .basic {
                    TextField("Логин", text: $settings.jiraUser)
                }
                SecureField(settings.jiraAuth == .token ? "Токен" : "Пароль", text: $secret)
                    .onSubmit(save)
                HStack {
                    Button(testing ? "Проверяю…" : "Сохранить и проверить") { save(); test() }
                        .disabled(testing || secret.isEmpty || settings.jiraURL.isEmpty)
                    if let status {
                        Text(status).foregroundStyle(status.hasPrefix("Подключено") ? .green : .red).lineLimit(2)
                    }
                }
                if settings.jiraAuth == .token {
                    Button("Создать токен в Jira…") {
                        let base = settings.jiraURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                        if let url = URL(string: base + "/secure/ViewProfile.jspa?selectedTab=com.atlassian.pats.pats-plugin:jira-user-personal-access-tokens") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text("Профиль → Personal Access Tokens → Create token. Токен хранится локально в настройках NotchMate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Учёт времени") {
                Toggle("Считать только рабочие часы (пн–пт)", isOn: $settings.jiraWorkHoursOnly)
                if settings.jiraWorkHoursOnly {
                    Stepper("Начало дня: \(settings.jiraDayStart):00", value: $settings.jiraDayStart, in: 0...23)
                    Stepper("Конец дня: \(settings.jiraDayEnd):00", value: $settings.jiraDayEnd, in: 1...24)
                }
                Text("«Прошло» — сколько задача была в рабочих статусах, пока была назначена на вас (время тестировщика и других не считается). «Осталось» — исходная оценка минус это время.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Какие статусы считать работой") {
                if env.jira.workStatusNames.isEmpty {
                    Text("Список появится после подключения к Jira").foregroundStyle(.secondary)
                } else {
                    ForEach(env.jira.workStatusNames, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { env.jira.effectiveWorkStatuses.contains(name) },
                            set: { on in
                                var set = env.jira.effectiveWorkStatuses
                                if on { if !set.contains(name) { set.append(name) } } else { set.removeAll { $0 == name } }
                                settings.jiraWorkStatuses = set
                                env.jira.refresh()
                            }))
                    }
                    Text("По умолчанию ожидание, блокировки, ревью и тестирование не считаются работой. Время засчитывается только пока задача назначена на вас.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Задачи") {
                TextField("JQL", text: $settings.jiraJQL, axis: .vertical).lineLimit(2...4)
                    .font(.system(.body, design: .monospaced))
                Text("«В работе» — задача с запущенным таймером, выбранная вами или первая в статусе In Progress. Кнопка «Списать» создаёт worklog, остаток эстимейта Jira пересчитает сама.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        Keychain.set(secret, for: JiraService.tokenAccount)
    }

    private func test() {
        testing = true
        Task {
            status = await env.jira.testConnection()
            testing = false
        }
    }
}

struct ReactionSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var settings = Settings.shared
    @ObservedObject var events = AppEnvironment.shared.systemEvents

    var body: some View {
        Section("Реакции помощника") {
            Toggle("Включилась камера — тихо слушает созвон", isOn: $settings.reactCamera)
            Toggle("Пропала / появилась сеть", isOn: $settings.reactNetwork)
            Toggle("Кивает на копирование в буфер", isOn: $settings.reactClipboard)
            Toggle("Скриншоты и записи экрана", isOn: $settings.reactScreenshots)
            Toggle("Системные уведомления", isOn: $settings.reactNotifications)
            Toggle("Новые сообщения (бейджи в Доке: Telegram, Slack…)", isOn: $settings.reactMessages)
            if (settings.reactNotifications || settings.reactMessages) && !events.accessibilityTrusted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Нужен доступ «Универсальный доступ»")
                    Spacer()
                    Button("Разрешить…") { Task { await PermissionCenter.shared.request(.accessibility) } }
                }
            }
            Text("Помощник также реагирует на пробуждение и разблокировку Mac, подключение дисков, низкий заряд, выполненные задачи, списание времени и превышение эстимейта в Jira. Содержимое уведомлений не читается и никуда не отправляется — только кто прислал.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AISettings: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var codex = AppEnvironment.shared.ai.codex
    @ObservedObject var claude = AppEnvironment.shared.ai.claude
    @State private var openAIKey = Keychain.get(OpenAIKeyBackend.account) ?? ""
    @State private var anthropicKey = Keychain.get(AnthropicKeyBackend.account) ?? ""
    @State private var customAIKey = Keychain.get(CustomOpenAIBackend.account) ?? ""
    @State private var openAIModels: [String] = []
    @State private var keyStatus: String?

    var body: some View {
        Form {
            Section("По умолчанию") {
                Picker("Чат ИИ использует", selection: $settings.aiProvider) {
                    ForEach(AIProvider.allCases) { p in Text("\(p.title) — \(p.subtitle)").tag(p) }
                }
                Toggle("ИИ может действовать в NotchMate (задачи, фокус, Jira, календарь)", isOn: $settings.aiToolsEnabled)
                Text("Для ключей API и своей ИИ — встроенные инструменты. Для аккаунтов ChatGPT и Claude подключите MCP-сервер NotchMate: Интеграции → ИИ-агенты и MCP.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("ChatGPT — личный аккаунт") {
                if !codex.isInstalled {
                    Label("Нужен Codex CLI от OpenAI: npm i -g @openai/codex", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if codex.isLoggedIn {
                    LabeledContent("Аккаунт") { Text([codex.email, codex.plan?.capitalized].compactMap { $0 }.joined(separator: " · ")) }
                    if let used = codex.usedPercent {
                        LabeledContent("Лимит (5 ч)") { Text("использовано \(Int(used))%") }
                    }
                    Picker("Модель", selection: $settings.aiCodexModel) {
                        Text("По умолчанию").tag("")
                        ForEach(codex.models) { m in Text(m.displayName).tag(m.id) }
                    }
                    Button("Выйти из ChatGPT") { Task { await codex.logout() } }
                } else {
                    Button(codex.loginInProgress ? "Ждём вход в браузере…" : "Войти через ChatGPT…") { Task { await codex.login() } }
                }
                Text("Вход и токены полностью внутри официального Codex от OpenAI — тот же аккаунт, что и в Codex. Используется ваша подписка ChatGPT.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Claude — личный аккаунт") {
                if !claude.isInstalled {
                    Label("Нужен Claude Code: brew install claude-code", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if claude.isLoggedIn {
                    LabeledContent("Аккаунт") { Text(claude.email ?? claude.authMethod ?? "подключено") }
                    Picker("Модель", selection: $settings.aiClaudeModel) {
                        ForEach(ClaudeCodeCLI.models, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    Button("Выйти из Claude") { Task { await claude.logout() } }
                } else {
                    HStack {
                        Button("Войти в Claude…") { claude.login() }
                        Button("Проверить") { Task { await claude.refreshStatus() } }
                    }
                }
                Text("Работает через официальный Claude Code: откроется Терминал со входом, дальше NotchMate сам увидит подключение. Используется ваша подписка Claude — только для личного использования.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("OpenAI API — ключ") {
                Text("API-ключи хранятся локально в файле настроек NotchMate с закрытыми правами доступа. Связка ключей macOS не используется.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("sk-…", text: $openAIKey)
                    .onSubmit { Keychain.set(openAIKey, for: OpenAIKeyBackend.account) }
                if openAIModels.isEmpty {
                    TextField("Модель", text: $settings.aiOpenAIModel)
                } else {
                    Picker("Модель", selection: $settings.aiOpenAIModel) {
                        ForEach(openAIModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                HStack {
                    Button("Сохранить и проверить") {
                        Keychain.set(openAIKey, for: OpenAIKeyBackend.account)
                        Task {
                            do {
                                openAIModels = try await OpenAIKeyBackend.models(key: openAIKey)
                                keyStatus = "OpenAI: ключ работает, моделей: \(openAIModels.count)"
                            } catch { keyStatus = "OpenAI: \(error.localizedDescription)" }
                        }
                    }
                    .disabled(openAIKey.isEmpty)
                }
            }

            Section("Anthropic API — ключ") {
                SecureField("sk-ant-…", text: $anthropicKey)
                    .onSubmit { Keychain.set(anthropicKey, for: AnthropicKeyBackend.account) }
                Picker("Модель", selection: $settings.aiAnthropicModel) {
                    ForEach(AnthropicKeyBackend.models, id: \.self) { Text($0).tag($0) }
                }
                Button("Сохранить") {
                    Keychain.set(anthropicKey, for: AnthropicKeyBackend.account)
                    keyStatus = "Anthropic: ключ сохранён"
                }
                .disabled(anthropicKey.isEmpty)
            }

            Section("Своя ИИ — OpenAI-совместимый сервер") {
                TextField("Base URL", text: $settings.aiCustomBaseURL)
                TextField("Модель", text: $settings.aiCustomModel)
                SecureField("API key (необязательно)", text: $customAIKey)
                    .onSubmit { Keychain.set(customAIKey, for: CustomOpenAIBackend.account) }
                Text("Пример: http://localhost:11434/v1 · API должен поддерживать /chat/completions и потоковый SSE-ответ.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Сохранить и проверить") {
                        Keychain.set(customAIKey, for: CustomOpenAIBackend.account)
                        Task {
                            do {
                                let models = try await CustomOpenAIBackend.models(baseURL: settings.aiCustomBaseURL, key: customAIKey)
                                keyStatus = models.isEmpty ? "Своя ИИ: сервер отвечает" : "Своя ИИ: подключено, моделей: \(models.count)"
                            } catch { keyStatus = "Своя ИИ: \(error.localizedDescription)" }
                        }
                    }
                    .disabled(settings.aiCustomBaseURL.isEmpty || settings.aiCustomModel.isEmpty)
                }
            }

            if let keyStatus {
                Text(keyStatus).foregroundStyle(["работает", "сохранён", "подключено", "отвечает"].contains(where: keyStatus.contains) ? .green : .red)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await claude.refreshStatus() }
            Task { await codex.refreshAccount() }
        }
    }
}
