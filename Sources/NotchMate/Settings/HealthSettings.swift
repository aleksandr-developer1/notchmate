import AppKit
import SwiftUI

struct HealthSettings: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var health = AppEnvironment.shared.health
    @ObservedObject var breathing = AppEnvironment.shared.breathing

    var body: some View {
        Form {
            Section {
                Text(String(localized: "Можно подключить оба источника. Если данные есть и там и там, берётся Garmin, а недостающее (например, шаги с iPhone) добавляется из Apple Health."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(get: { settings.garminEnabled }, set: { on in
                    settings.garminEnabled = on
                    if on, !health.garminLoggedIn { health.connectGarmin() } else { health.refresh(force: true) }
                })) {
                    Label("Garmin Connect", systemImage: HealthSource.garmin.icon)
                }
                if settings.garminEnabled {
                    LabeledContent(String(localized: "Состояние")) {
                        HStack(spacing: 6) {
                            if health.garminState == .syncing { ProgressView().controlSize(.mini) }
                            Text(health.garminState.text).foregroundStyle(health.garminState.isReady ? .green : .secondary)
                        }
                    }
                    if !health.garminName.isEmpty { LabeledContent(String(localized: "Аккаунт"), value: health.garminName) }
                    HStack {
                        Button(health.garminLoggedIn ? String(localized: "Войти заново") : String(localized: "Войти в Garmin Connect…")) { health.connectGarmin() }
                        Button(String(localized: "Синхронизировать")) { health.syncGarmin() }.disabled(!health.garminLoggedIn || health.garminState == .syncing)
                        Spacer()
                        Button(String(localized: "Отключить"), role: .destructive) { health.disconnectGarmin() }
                    }
                }
            } header: {
                Text("Garmin")
            } footer: {
                Text(String(localized: "Вход откроется в Терминале: email, пароль и код MFA вводятся прямо в официальный вход Garmin. NotchMate не видит и не хранит пароль — на Mac остаётся только токен доступа. Данные подтягиваются каждые 15 минут, пока часы синхронизируются с телефоном. Используется неофициальная библиотека python-garminconnect: если Garmin поменяет вход, её нужно будет обновить кнопкой «Войти заново»."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.appleHealthEnabled.onChange { health.refresh() }) {
                    Label("Apple Health", systemImage: HealthSource.appleHealth.icon)
                }
                if settings.appleHealthEnabled {
                    LabeledContent(String(localized: "Состояние")) {
                        Text(health.appleState.text).foregroundStyle(health.appleState.isReady ? .green : .secondary)
                    }
                    HStack {
                        TextField(String(localized: "Папка экспорта"), text: $settings.appleHealthFolder)
                            .onSubmit { health.refresh() }
                        Button(String(localized: "Выбрать…"), action: chooseFolder)
                        Button(String(localized: "Открыть")) { health.openAppleFolder() }
                    }
                    DisclosureGroup(String(localized: "Как настроить на iPhone")) {
                        VStack(alignment: .leading, spacing: 6) {
                            step(1, String(localized: "Установите на iPhone приложение Health Auto Export и разрешите доступ к «Здоровью»."))
                            step(2, String(localized: "Автоматизации → Новая: тип «Health Metrics», назначение «iCloud Drive», формат JSON, папка \(iCloudFolder)."))
                            step(3, String(localized: "Метрики: пульс, пульс покоя, вариабельность пульса, шаги, анализ сна, частота дыхания, кислород в крови."))
                            step(4, String(localized: "Период «Сегодня», интервал агрегации — минуты или час, запуск каждый час."))
                            Text(String(localized: "На Mac нет приложения «Здоровье», поэтому данные приходят с iPhone через iCloud Drive. Подойдёт и команда «Быстрые команды», которая пишет JSON того же формата."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text("Apple Health")
            }

            Section(String(localized: "Помощник")) {
                Toggle(String(localized: "Настроение по телу (утренний заряд, стресс, усталость)"), isOn: $settings.healthMoods)
                Toggle(String(localized: "Предлагать подышать при высоком стрессе"), isOn: $settings.healthStressNudges)
                if settings.healthStressNudges {
                    Stepper(String(localized: "Порог стресса: \(Int(settings.healthStressThreshold))"), value: $settings.healthStressThreshold, in: 40...90, step: 5)
                    Text(String(localized: "Шкала Garmin: 0–25 покой, 26–50 низкий, 51–75 средний, 76–100 высокий. Не чаще раза в час и не во время созвона."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "Дыхание")) {
                Picker(String(localized: "Техника"), selection: $settings.breathPattern) {
                    ForEach(BreathPattern.allCases) { p in
                        Text("\(p.title) — \(p.subtitle)").tag(p.rawValue)
                    }
                }
                Stepper(String(localized: "Длительность: \(Int(settings.breathMinutes)) мин"), value: $settings.breathMinutes, in: 1...10, step: 1)
                HStack {
                    Button(breathing.isActive ? String(localized: "Остановить") : String(localized: "Попробовать")) {
                        breathing.isActive ? breathing.stop() : breathing.start()
                    }
                    Spacer()
                    Text(String(localized: "Сессий: \(breathing.sessions.count)")).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { health.refresh() }
    }

    /// The export folder as Health Auto Export shows it: relative to iCloud Drive.
    private var iCloudFolder: String {
        let path = settings.appleHealthFolder
        return path.range(of: "com~apple~CloudDocs/").map { String(path[$0.upperBound...]) } ?? path
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = health.appleFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.appleHealthFolder = url.path
            health.refresh()
        }
    }
}

private extension Binding {
    func onChange(_ action: @escaping () -> Void) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; action() })
    }
}
