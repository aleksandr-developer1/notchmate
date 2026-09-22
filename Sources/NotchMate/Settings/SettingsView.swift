import AppKit
import SwiftUI

/// Settings live in a sidebar, not in a row of tabs: everything that can grow
/// (integrations above all) gets its own page instead of a new tab.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, hotkeys, assistant, work, calls, integrations, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "Основные")
        case .hotkeys: return String(localized: "Горячие клавиши")
        case .assistant: return String(localized: "Помощник")
        case .work: return String(localized: "Фокус и время")
        case .calls: return String(localized: "Созвоны")
        case .integrations: return String(localized: "Интеграции")
        case .permissions: return String(localized: "Разрешения")
        case .about: return String(localized: "О программе")
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
                .navigationTitle(page?.title ?? String(localized: "Настройки"))
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
            Section(String(localized: "Поведение")) {
                Picker(String(localized: "Открывать панель"), selection: $settings.openTrigger) {
                    ForEach(OpenTrigger.allCases) { Text($0.title).tag($0) }
                }
                if settings.openTrigger == .hover {
                    LabeledContent(String(localized: "Задержка наведения")) {
                        HStack {
                            Slider(value: $settings.hoverDelay, in: 0...0.8)
                            Text(String(localized: "\(Int(settings.hoverDelay * 1000)) мс")).monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                }
                Toggle(String(localized: "Тактильный отклик трекпада"), isOn: $settings.haptics)
                LabeledContent(String(localized: "Ширина панели")) {
                    HStack {
                        Slider(value: $settings.expandedWidth, in: 600...820, step: 10)
                        Text("\(Int(settings.expandedWidth)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Toggle(String(localized: "Ширина свёрнутого островка по вырезу камеры"), isOn: Binding(
                    get: { settings.collapsedWidth <= 0 },
                    set: { settings.collapsedWidth = $0 ? 0 : Double(Self.cameraCutoutWidth.rounded()) }))
                if settings.collapsedWidth > 0 {
                    LabeledContent(String(localized: "Ширина свёрнутого островка")) {
                        HStack {
                            Slider(value: $settings.collapsedWidth, in: Self.collapsedRange, step: 2)
                            Text("\(Int(settings.collapsedWidth)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                        }
                    }
                }
            }
            Section(String(localized: "Живые активности")) {
                Toggle(String(localized: "Обложка и эквалайзер в вырезе во время музыки"), isOn: $settings.showMusicActivity)
                Picker(String(localized: "Подсветка панели"), selection: $settings.notchGlowMode) {
                    ForEach(NotchGlowMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle(String(localized: "Дискотека сама включается, если мак не трогают под музыку"), isOn: $settings.autoDisco)
                Toggle(String(localized: "Показывать название нового трека"), isOn: $settings.sneakPeek)
                Toggle(String(localized: "Индикатор зарядки при подключении питания"), isOn: $settings.chargingHUD)
            }
            Section(String(localized: "Буфер обмена")) {
                Toggle(String(localized: "Вести историю буфера"), isOn: $settings.clipboardEnabled)
                Text(String(localized: "Пароли из менеджеров паролей (помеченные как скрытые) не сохраняются. История хранится только в памяти."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(String(localized: "Система")) {
                LanguagePicker()
                Toggle(String(localized: "Запускать при входе в систему"), isOn: $settings.launchAtLogin)
                Toggle(String(localized: "Иконка в строке меню"), isOn: $settings.showMenuBarIcon)
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
            Section(String(localized: "Компаньон")) {
                HStack {
                    Spacer()
                    FaceView(mood: .idle, scale: 1.5, color: settings.faceColor.color)
                        .padding(12).background(RoundedRectangle(cornerRadius: 14).fill(.black))
                    Spacer()
                }
                Toggle(String(localized: "Показывать мордочку под вырезом"), isOn: $settings.showFace)
                Toggle(String(localized: "Убирать мордочку влево от выреза, когда под ней окно"), isOn: $settings.dockFaceWhenCovered)
                    .disabled(!settings.showFace)
                Picker(String(localized: "Данные активности"), selection: $settings.activityLayout) {
                    ForEach(ActivityLayout.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!settings.showFace)
                Text(String(localized: "Музыка, таймеры, Jira и зарядка: по бокам от мордочки — вырез не расширяется; слева и справа от камеры — вырез становится шире."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(String(localized: "Имя"), text: $settings.companionName)
                Picker(String(localized: "Цвет мордочки"), selection: $settings.faceColor) {
                    ForEach(FacePalette.allCases) { Text($0.title).tag($0) }
                }
                Toggle(String(localized: "Следит взглядом за курсором"), isOn: $settings.followCursor)
                Text(String(localized: "Если быстро потрясти курсором, у мордочки закружится голова."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ReactionSettings()
            Section(String(localized: "Характер")) {
                Toggle(String(localized: "Настроение по интенсивности работы (в потоке / скучает)"), isOn: $settings.activityMoods)
                Toggle(String(localized: "Мини-сценки в простое (рыбалка, мяч)"), isOn: $settings.idleScenes)
            }
            Section(String(localized: "Забота")) {
                Toggle(String(localized: "Напоминать пить воду"), isOn: $settings.waterReminder)
                if settings.waterReminder {
                    Stepper(String(localized: "Каждые \(Int(settings.waterInterval)) мин"), value: $settings.waterInterval, in: 15...180, step: 15)
                }
                Toggle(String(localized: "Напоминать размяться"), isOn: $settings.stretchReminder)
                if settings.stretchReminder {
                    Stepper(String(localized: "Каждые \(Int(settings.stretchInterval)) мин"), value: $settings.stretchInterval, in: 30...240, step: 15)
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
        case .git: return String(localized: "Git и GitHub")
        case .ai: return String(localized: "ИИ")
        case .agents: return String(localized: "ИИ-агенты и MCP")
        case .calendar: return String(localized: "Календарь")
        case .reminders: return String(localized: "Напоминания")
        case .health: return String(localized: "Здоровье")
        }
    }

    var subtitle: String {
        switch self {
        case .obsidian: return String(localized: "Заметки, быстрая запись, протоколы созвонов")
        case .jira: return String(localized: "Задачи, время в работе, списание")
        case .git: return String(localized: "Репозиторий из терминала, CI и PR, сообщения коммитов")
        case .ai: return String(localized: "Аккаунты ChatGPT и Claude, ключи API, своя модель")
        case .agents: return String(localized: "Claude Code и Codex: статус работы и инструменты NotchMate")
        case .calendar: return String(localized: "Встречи на шкале дня и в вырезе")
        case .reminders: return String(localized: "Дела из «Напоминаний» на шкале дня")
        case .health: return String(localized: "Garmin Connect и Apple Health: стресс, Body Battery, сон, пульс")
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
                        Label(String(localized: "Интеграции"), systemImage: "chevron.left")
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
                    Text(String(localized: "Дальше здесь появятся другие сервисы. Все ключи и токены остаются на этом компьютере."))
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
            return (false, String(localized: "не найдено"))
        case .jira:
            let ready = !settings.jiraURL.isEmpty && !(Keychain.get(JiraService.tokenAccount) ?? "").isEmpty
            return (ready, ready ? String(localized: "подключено") : String(localized: "не настроено"))
        case .git:
            if !settings.gitEnabled { return (false, String(localized: "выключено")) }
            return (true, env.git.ghAvailable ? String(localized: "GitHub CLI найден") : String(localized: "без CI"))
        case .ai:
            return (true, settings.aiProvider.title)
        case .agents:
            let n = [agents.claudeHooksInstalled, agents.codexHooksInstalled].filter { $0 }.count
            return (n > 0, n > 0 ? String(localized: "подключено: \(n)") : String(localized: "не подключено"))
        case .calendar:
            if !settings.calendarEnabled { return (false, String(localized: "выключен")) }
            return (calendar.hasAccess, calendar.hasAccess ? String(localized: "есть доступ") : String(localized: "нет доступа"))
        case .reminders:
            if !settings.remindersEnabled { return (false, String(localized: "выключены")) }
            return (reminders.hasAccess, reminders.hasAccess ? String(localized: "есть доступ") : String(localized: "нет доступа"))
        case .health:
            let on = [settings.garminEnabled ? "Garmin" : nil, settings.appleHealthEnabled ? "Apple Health" : nil].compactMap { $0 }
            return (!on.isEmpty, on.isEmpty ? String(localized: "не подключено") : on.joined(separator: " + "))
        }
    }
}

// MARK: - Obsidian

struct ObsidianSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section(String(localized: "Хранилище")) {
                Picker(String(localized: "Хранилище"), selection: $settings.vaultPath) {
                    Text(String(localized: "Авто (последнее открытое)")).tag("")
                    ForEach(env.obsidian.vaults) { v in Text(v.name).tag(v.path) }
                    if !settings.vaultPath.isEmpty && !env.obsidian.vaults.contains(where: { $0.path == settings.vaultPath }) {
                        Text((settings.vaultPath as NSString).lastPathComponent).tag(settings.vaultPath)
                    }
                }
                .onChange(of: settings.vaultPath) { _, _ in env.obsidian.refresh(force: true) }
                LabeledContent(String(localized: "Путь")) {
                    HStack {
                        Text(env.obsidian.vault?.path ?? String(localized: "не найдено")).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button(String(localized: "Выбрать…")) { pickVault() }
                    }
                }
                LabeledContent(String(localized: "Заметок")) { Text("\(env.obsidian.notes.count)").monospacedDigit() }
            }
            Section(String(localized: "Быстрая запись")) {
                Picker(String(localized: "Куда записывать"), selection: $settings.captureTarget) {
                    ForEach(CaptureTarget.allCases) { Text($0.title).tag($0) }
                }
                if settings.captureTarget == .inbox {
                    TextField(String(localized: "Файл входящих"), text: $settings.inboxPath)
                }
                Toggle(String(localized: "Добавлять время (HH:mm)"), isOn: $settings.captureTimestamp)
                Text(String(localized: "Ежедневная заметка использует папку и формат из настроек плагина «Ежедневные заметки» в Obsidian."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func pickVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Выбрать хранилище")
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
            Text(String(localized: "Умный помощник за вырезом камеры: музыка, Obsidian, полка файлов, буфер обмена и фокус-таймер."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
            Text("Now Playing: ungive/mediaremote-adapter (BSD-3)").font(.caption).foregroundStyle(.tertiary)
            Button(String(localized: "Выйти из NotchMate")) { NSApp.terminate(nil) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Jira

struct JiraSettings: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject var settings = Settings.shared
    @State private var secret = Keychain.get(JiraService.tokenAccount) ?? ""
    @State private var status: (text: String, ok: Bool)?
    @State private var testing = false

    var body: some View {
        Form {
            Section(String(localized: "Подключение")) {
                TextField(String(localized: "Адрес Jira"), text: $settings.jiraURL)
                Picker(String(localized: "Вход"), selection: $settings.jiraAuth) {
                    ForEach(JiraAuth.allCases) { Text($0.title).tag($0) }
                }
                if settings.jiraAuth == .basic {
                    TextField(String(localized: "Логин"), text: $settings.jiraUser)
                }
                SecureField(settings.jiraAuth == .token ? String(localized: "Токен") : String(localized: "Пароль"), text: $secret)
                    .onSubmit(save)
                HStack {
                    Button(testing ? String(localized: "Проверяю…") : String(localized: "Сохранить и проверить")) { save(); test() }
                        .disabled(testing || secret.isEmpty || settings.jiraURL.isEmpty)
                    if let status {
                        Text(status.text).foregroundStyle(status.ok ? .green : .red).lineLimit(2)
                    }
                }
                if settings.jiraAuth == .token {
                    Button(String(localized: "Создать токен в Jira…")) {
                        let base = settings.jiraURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                        if let url = URL(string: base + "/secure/ViewProfile.jspa?selectedTab=com.atlassian.pats.pats-plugin:jira-user-personal-access-tokens") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Text(String(localized: "Профиль → Personal Access Tokens → Create token. Токен хранится локально в настройках NotchMate."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(String(localized: "Учёт времени")) {
                Toggle(String(localized: "Считать только рабочие часы (пн–пт)"), isOn: $settings.jiraWorkHoursOnly)
                if settings.jiraWorkHoursOnly {
                    Stepper(String(localized: "Начало дня: \(settings.jiraDayStart):00"), value: $settings.jiraDayStart, in: 0...23)
                    Stepper(String(localized: "Конец дня: \(settings.jiraDayEnd):00"), value: $settings.jiraDayEnd, in: 1...24)
                }
                Text(String(localized: "«Прошло» — сколько задача была в рабочих статусах, пока была назначена на вас (время тестировщика и других не считается). «Осталось» — исходная оценка минус это время."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(String(localized: "Какие статусы считать работой")) {
                if env.jira.workStatusNames.isEmpty {
                    Text(String(localized: "Список появится после подключения к Jira")).foregroundStyle(.secondary)
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
                    Text(String(localized: "По умолчанию ожидание, блокировки, ревью и тестирование не считаются работой. Время засчитывается только пока задача назначена на вас."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(String(localized: "Задачи")) {
                TextField("JQL", text: $settings.jiraJQL, axis: .vertical).lineLimit(2...4)
                    .font(.system(.body, design: .monospaced))
                Text(String(localized: "«В работе» — задача с запущенным таймером, выбранная вами или первая в статусе In Progress. Кнопка «Списать» создаёт worklog, остаток эстимейта Jira пересчитает сама."))
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
        Section(String(localized: "Реакции помощника")) {
            Toggle(String(localized: "Включилась камера — тихо слушает созвон"), isOn: $settings.reactCamera)
            Toggle(String(localized: "Пропала / появилась сеть"), isOn: $settings.reactNetwork)
            Toggle(String(localized: "Кивает на копирование в буфер"), isOn: $settings.reactClipboard)
            Toggle(String(localized: "Скриншоты и записи экрана"), isOn: $settings.reactScreenshots)
            Toggle(String(localized: "Системные уведомления"), isOn: $settings.reactNotifications)
            Toggle(String(localized: "Новые сообщения (бейджи в Доке: Telegram, Slack…)"), isOn: $settings.reactMessages)
            if (settings.reactNotifications || settings.reactMessages) && !events.accessibilityTrusted {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(String(localized: "Нужен доступ «Универсальный доступ»"))
                    Spacer()
                    Button(String(localized: "Разрешить…")) { Task { await PermissionCenter.shared.request(.accessibility) } }
                }
            }
            Text(String(localized: "Помощник также реагирует на пробуждение и разблокировку Mac, подключение дисков, низкий заряд, выполненные задачи, списание времени и превышение эстимейта в Jira. Содержимое уведомлений не читается и никуда не отправляется — только кто прислал."))
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
    @State private var keyStatus: (text: String, ok: Bool)?

    var body: some View {
        Form {
            Section(String(localized: "По умолчанию")) {
                Picker(String(localized: "Чат ИИ использует"), selection: $settings.aiProvider) {
                    ForEach(AIProvider.allCases) { p in Text("\(p.title) — \(p.subtitle)").tag(p) }
                }
                Toggle(String(localized: "ИИ может действовать в NotchMate (задачи, фокус, Jira, календарь)"), isOn: $settings.aiToolsEnabled)
                Text(String(localized: "Для ключей API и своей ИИ — встроенные инструменты. Для аккаунтов ChatGPT и Claude подключите MCP-сервер NotchMate: Интеграции → ИИ-агенты и MCP."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(String(localized: "ChatGPT — личный аккаунт")) {
                if !codex.isInstalled {
                    Label(String(localized: "Нужен Codex CLI от OpenAI: npm i -g @openai/codex"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if codex.isLoggedIn {
                    LabeledContent(String(localized: "Аккаунт")) { Text([codex.email, codex.plan?.capitalized].compactMap { $0 }.joined(separator: " · ")) }
                    if let used = codex.usedPercent {
                        LabeledContent(String(localized: "Лимит (5 ч)")) { Text(String(localized: "использовано \(Int(used))%")) }
                    }
                    Picker(String(localized: "Модель"), selection: $settings.aiCodexModel) {
                        Text(String(localized: "По умолчанию")).tag("")
                        ForEach(codex.models) { m in Text(m.displayName).tag(m.id) }
                    }
                    Button(String(localized: "Выйти из ChatGPT")) { Task { await codex.logout() } }
                } else {
                    Button(codex.loginInProgress ? String(localized: "Ждём вход в браузере…") : String(localized: "Войти через ChatGPT…")) { Task { await codex.login() } }
                }
                Text(String(localized: "Вход и токены полностью внутри официального Codex от OpenAI — тот же аккаунт, что и в Codex. Используется ваша подписка ChatGPT."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(String(localized: "Claude — личный аккаунт")) {
                if !claude.isInstalled {
                    Label(String(localized: "Нужен Claude Code: brew install claude-code"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if claude.isLoggedIn {
                    LabeledContent(String(localized: "Аккаунт")) { Text(claude.email ?? claude.authMethod ?? String(localized: "подключено")) }
                    Picker(String(localized: "Модель"), selection: $settings.aiClaudeModel) {
                        ForEach(ClaudeCodeCLI.models, id: \.id) { Text($0.title).tag($0.id) }
                    }
                    Button(String(localized: "Выйти из Claude")) { Task { await claude.logout() } }
                } else {
                    HStack {
                        Button(String(localized: "Войти в Claude…")) { claude.login() }
                        Button(String(localized: "Проверить")) { Task { await claude.refreshStatus() } }
                    }
                }
                Text(String(localized: "Работает через официальный Claude Code: откроется Терминал со входом, дальше NotchMate сам увидит подключение. Используется ваша подписка Claude — только для личного использования."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(String(localized: "OpenAI API — ключ")) {
                Text(String(localized: "API-ключи хранятся локально в файле настроек NotchMate с закрытыми правами доступа. Связка ключей macOS не используется."))
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("sk-…", text: $openAIKey)
                    .onSubmit { Keychain.set(openAIKey, for: OpenAIKeyBackend.account) }
                if openAIModels.isEmpty {
                    TextField(String(localized: "Модель"), text: $settings.aiOpenAIModel)
                } else {
                    Picker(String(localized: "Модель"), selection: $settings.aiOpenAIModel) {
                        ForEach(openAIModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                HStack {
                    Button(String(localized: "Сохранить и проверить")) {
                        Keychain.set(openAIKey, for: OpenAIKeyBackend.account)
                        Task {
                            do {
                                openAIModels = try await OpenAIKeyBackend.models(key: openAIKey)
                                keyStatus = (String(localized: "OpenAI: ключ работает, моделей: \(openAIModels.count)"), true)
                            } catch { keyStatus = ("OpenAI: \(error.localizedDescription)", false) }
                        }
                    }
                    .disabled(openAIKey.isEmpty)
                }
            }

            Section(String(localized: "Anthropic API — ключ")) {
                SecureField("sk-ant-…", text: $anthropicKey)
                    .onSubmit { Keychain.set(anthropicKey, for: AnthropicKeyBackend.account) }
                Picker(String(localized: "Модель"), selection: $settings.aiAnthropicModel) {
                    ForEach(AnthropicKeyBackend.models, id: \.self) { Text($0).tag($0) }
                }
                Button(String(localized: "Сохранить")) {
                    Keychain.set(anthropicKey, for: AnthropicKeyBackend.account)
                    keyStatus = (String(localized: "Anthropic: ключ сохранён"), true)
                }
                .disabled(anthropicKey.isEmpty)
            }

            Section(String(localized: "Своя ИИ — OpenAI-совместимый сервер")) {
                TextField("Base URL", text: $settings.aiCustomBaseURL)
                TextField(String(localized: "Модель"), text: $settings.aiCustomModel)
                SecureField(String(localized: "API key (необязательно)"), text: $customAIKey)
                    .onSubmit { Keychain.set(customAIKey, for: CustomOpenAIBackend.account) }
                Text(String(localized: "Пример: http://localhost:11434/v1 · API должен поддерживать /chat/completions и потоковый SSE-ответ."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(String(localized: "Сохранить и проверить")) {
                        Keychain.set(customAIKey, for: CustomOpenAIBackend.account)
                        Task {
                            do {
                                let models = try await CustomOpenAIBackend.models(baseURL: settings.aiCustomBaseURL, key: customAIKey)
                                keyStatus = (models.isEmpty ? String(localized: "Своя ИИ: сервер отвечает") : String(localized: "Своя ИИ: подключено, моделей: \(models.count)"), true)
                            } catch { keyStatus = (String(localized: "Своя ИИ: \(error.localizedDescription)"), false) }
                        }
                    }
                    .disabled(settings.aiCustomBaseURL.isEmpty || settings.aiCustomModel.isEmpty)
                }
            }

            if let keyStatus {
                Text(keyStatus.text).foregroundStyle(keyStatus.ok ? .green : .red)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await claude.refreshStatus() }
            Task { await codex.refreshAccount() }
        }
    }
}

/// App language: follows the system unless one is picked here. macOS reads it at launch, so it asks to restart.
private struct LanguagePicker: View {
    @State private var choice = AppLanguage.override
    private let launched = AppLanguage.override

    var body: some View {
        Picker(String(localized: "Язык"), selection: $choice) {
            Text(String(localized: "Как в системе")).tag("")
            Divider()
            ForEach(AppLanguage.supported, id: \.self) { Text(AppLanguage.nativeName($0)).tag($0) }
        }
        .onChange(of: choice) { _, new in AppLanguage.override = new }
        if choice != launched {
            HStack {
                Text(String(localized: "Язык сменится после перезапуска.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Перезапустить"), action: Self.relaunch)
            }
        }
    }

    /// Opens the app again a moment after this instance quits, so the new one gets the hotkeys and the bridge port.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}
