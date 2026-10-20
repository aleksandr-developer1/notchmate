import SwiftUI

struct PluginCatalogView: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var jira = AppEnvironment.shared.jira
    @ObservedObject private var calendar = AppEnvironment.shared.calendar
    @ObservedObject private var reminders = AppEnvironment.shared.reminders
    @ObservedObject private var health = AppEnvironment.shared.health
    @ObservedObject private var agents = AppEnvironment.shared.agents
    @ObservedObject private var obsidian = AppEnvironment.shared.obsidian
    @ObservedObject private var appleNotes = AppEnvironment.shared.appleNotes
    @ObservedObject private var codex = AppEnvironment.shared.ai.codex
    @ObservedObject private var claude = AppEnvironment.shared.ai.claude
    @State private var query = ""
    @State private var category: PluginCategory?
    @State private var enabledOnly = false
    @State private var configuring: PluginID?
    @State private var error: String?

    private var plugins: [PluginID] {
        PluginID.allCases.filter {
            (category == nil || $0.category == category)
                && (!enabledOnly || settings.pluginEnabled($0))
                && (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || "\($0.title) \($0.summary)".localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                controls
                if plugins.isEmpty {
                    ContentUnavailableView(String(localized: "Ничего не найдено"), systemImage: "puzzlepiece.extension",
                                           description: Text(String(localized: "Попробуйте другой запрос или выберите все категории.")))
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 235), spacing: 12)], spacing: 12) {
                        ForEach(plugins) { plugin in card(plugin) }
                    }
                }
                Text(String(localized: "Встроенные плагины NotchMate. Отключение сохраняет ваши настройки и аккаунты."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $configuring) { plugin in
            PluginConfigurationSheet(plugin: plugin).environmentObject(env)
        }
        .alert(String(localized: "Не удалось изменить плагин"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(String(localized: "Понятно")) { error = nil }
            } message: { Text(error ?? "") }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 28, weight: .medium)).foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 19))
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "Соберите свой NotchMate"))
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text(String(localized: "Только те возможности, которые нужны вам."))
                    .font(.callout).foregroundStyle(.secondary)
                let count = PluginID.allCases.filter { settings.pluginEnabled($0) }.count
                Text(String(localized: "Включено: \(count) из \(PluginID.allCases.count)"))
                    .font(.caption.weight(.medium)).foregroundStyle(.purple)
            }
            Spacer(minLength: 0)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "Найти плагин"), text: $query).textFieldStyle(.plain)
                    .accessibilityLabel(String(localized: "Поиск плагинов"))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel(String(localized: "Очистить поиск"))
                }
                Divider().frame(height: 16)
                Toggle(String(localized: "Включённые"), isOn: $enabledOnly).toggleStyle(.checkbox).font(.caption)
            }
            .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    categoryButton(nil, title: String(localized: "Все"))
                    ForEach(PluginCategory.allCases) { categoryButton($0, title: $0.title) }
                }
            }
        }
    }

    private func categoryButton(_ value: PluginCategory?, title: String) -> some View {
        Button { category = value } label: {
            Text(title).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(category == value ? Color.white : Color.primary)
                .background(category == value ? Color.indigo : Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityAddTraits(category == value ? .isSelected : [])
    }

    private func card(_ plugin: PluginID) -> some View {
        let enabled = settings.pluginEnabled(plugin)
        let status = connectionStatus(plugin)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: plugin.icon).font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(plugin.tint)
                    .frame(width: 44, height: 44)
                    .background(plugin.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
                Spacer()
                Toggle(plugin.title, isOn: Binding(get: { settings.pluginEnabled(plugin) }, set: {
                    error = env.setPlugin(plugin, enabled: $0)
                }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(plugin.tint)
                .accessibilityLabel(String(localized: "Включить плагин") + " «\(plugin.title)»")
            }
            Text(plugin.title).font(.system(size: 14, weight: .semibold))
            Text(plugin.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .lineLimit(3).frame(maxWidth: .infinity, minHeight: 43, alignment: .topLeading)
            HStack(spacing: 5) {
                Circle().fill(enabled ? (status.ready ? Color.green : Color.orange) : Color.secondary.opacity(0.5))
                    .frame(width: 5, height: 5).accessibilityHidden(true)
                Text(enabled ? status.text : String(localized: "Выключен"))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button { configuring = plugin } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                        .padding(6).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Настроить") + " «\(plugin.title)»")
                .accessibilityLabel(String(localized: "Настроить") + " «\(plugin.title)»")
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(enabled ? plugin.tint.opacity(0.22) : Color.primary.opacity(0.07)))
        .accessibilityElement(children: .contain)
    }

    private func connectionStatus(_ plugin: PluginID) -> (ready: Bool, text: String) {
        let ready: Bool
        switch plugin {
        case .jira: ready = env.jira.isConfigured
        case .ai: ready = env.ai.isReady(settings.aiProvider)
        case .obsidian: ready = env.obsidian.isConnected
        case .notes: ready = appleNotes.unavailableMessage == nil
        case .calendar: ready = env.calendar.hasAccess
        case .reminders: ready = env.reminders.hasAccess
        case .garmin: ready = health.garminState.isReady
        case .appleHealth: ready = health.appleState.isReady
        case .agents: ready = env.agents.claudeHooksInstalled || env.agents.codexHooksInstalled
        default: ready = true
        }
        return (ready, ready ? String(localized: "Включён") : String(localized: "Нужна настройка"))
    }
}

private struct PluginConfigurationSheet: View {
    let plugin: PluginID
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var settings = Settings.shared
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: plugin.icon).foregroundStyle(plugin.tint)
                Text(plugin.title).font(.headline)
                Spacer()
                Button(String(localized: "Готово")) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(18)
            Divider()
            HStack {
                Toggle(String(localized: "Плагин включён"), isOn: Binding(
                    get: { settings.pluginEnabled(plugin) }, set: { error = env.setPlugin(plugin, enabled: $0) }))
                    .toggleStyle(.switch)
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 12)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20) }
            if !plugin.dependencies.isEmpty {
                Text(String(localized: "Использует: ") + plugin.dependencies.map(\.title).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            if settings.pluginEnabled(plugin) {
                configuration
            } else {
                ContentUnavailableView(String(localized: "Выключен"), systemImage: plugin.icon,
                                       description: Text(plugin.summary))
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 610, height: 560)
    }

    @ViewBuilder private var configuration: some View {
        switch plugin {
        case .ai: AISettings()
        case .jira: JiraSettings()
        case .git: GitSettings()
        case .obsidian: ObsidianSettings()
        case .calendar: Form { CalendarSettings() }.formStyle(.grouped)
        case .reminders: RemindersSettings()
        case .agents: AgentSettings()
        case .garmin: HealthSettings(source: .garmin)
        case .appleHealth: HealthSettings(source: .appleHealth)
        case .companion: AssistantSettings()
        case .focus: WorkSettings()
        case .calls, .meetingAssistant: Form { CallSettings() }.formStyle(.grouped)
        case .music:
            Form {
                Section(String(localized: "Музыка")) {
                    Toggle(String(localized: "Обложка и эквалайзер в вырезе во время музыки"), isOn: $settings.showMusicActivity)
                    Toggle(String(localized: "Показывать название нового трека"), isOn: $settings.sneakPeek)
                    Picker(String(localized: "Подсветка панели"), selection: $settings.notchGlowMode) {
                        ForEach(NotchGlowMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle(String(localized: "Дискотека"), isOn: $settings.discoEnabled)
                    if settings.discoEnabled {
                        Toggle(String(localized: "Дискотека сама включается, если мак не трогают под музыку"), isOn: $settings.autoDisco)
                    }
                }
            }.formStyle(.grouped)
        case .notes:
            Form {
                Section("Apple Notes") {
                    Text(String(localized: "Этот плагин работает с приложением Apple «Заметки». Obsidian подключается отдельно."))
                    Button(String(localized: "Обновить")) { env.appleNotes.refresh(force: true) }
                    if let message = env.appleNotes.unavailableMessage {
                        Text(message).foregroundStyle(.orange)
                    }
                }
            }.formStyle(.grouped)
        case .shelf, .clipboard:
            Form {
                Section(plugin.title) {
                    Label(plugin.summary, systemImage: plugin.icon)
                    Text(plugin == .clipboard
                         ? String(localized: "Пароли из менеджеров паролей не сохраняются. История хранится только в памяти.")
                         : String(localized: "Перетащите файлы, изображения или ссылки в вырез. Отключение плагина не удаляет файлы."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }
    }
}
