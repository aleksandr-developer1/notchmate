import SwiftUI

/// Every shortcut and gesture in one place, each with what it does.
struct HotkeysSettings: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                ShortcutRow(keys: ["⌃", "⌥", "N"], title: String(localized: "Открыть / закрыть панель"),
                            detail: String(localized: "Открывает на последней вкладке, повторное нажатие закрывает."),
                            isOn: $settings.hotKeyToggleEnabled)
                ShortcutRow(keys: ["⌃", "⌥", "M"], title: String(localized: "Быстрая заметка"),
                            detail: String(localized: "Открывает «Заметки» с полем ввода: пишите и нажмите ↩."),
                            isOn: $settings.hotKeyCaptureEnabled)
                ShortcutRow(keys: ["⌃", "⌥", "H"], title: String(localized: "Помощник на созвоне"),
                            detail: String(localized: "Первое нажатие включает подсказки и запись разговора, повторное — подсказать прямо сейчас."),
                            isOn: $settings.hotKeyMeetingEnabled)
            } header: {
                Text(String(localized: "В любой программе"))
            } footer: {
                Text(String(localized: "Если сочетание не срабатывает, скорее всего его уже заняла другая программа — выключите его здесь или там."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(String(localized: "В открытой панели")) {
                ForEach(Array(NotchGroup.visible.enumerated()), id: \.element) { i, group in
                    ShortcutRow(keys: ["⌘", "\(i + 1)"], title: group.title, detail: String(localized: "Перейти на вкладку."))
                }
                ShortcutRow(keys: ["Esc"], title: String(localized: "Закрыть панель"), detail: String(localized: "Возвращает фокус в программу, где вы работали."))
                ShortcutRow(keys: ["⌘", ","], title: String(localized: "Настройки"), detail: String(localized: "Открывает это окно."))
            }

            Section(String(localized: "Ввод текста")) {
                ShortcutRow(keys: ["↩"], title: String(localized: "Чат ИИ — отправить"), detail: String(localized: "⇧↩ — новая строка."))
                ShortcutRow(keys: ["↩"], title: String(localized: "Быстрая заметка — сохранить"),
                            detail: settings.captureTarget == .daily ? String(localized: "Добавляет в заметку дня. ⇧↩ — новая строка.") : String(localized: "Добавляет во «Входящие». ⇧↩ — новая строка."))
                ShortcutRow(keys: ["⌘", "↩"], title: String(localized: "Быстрая заметка — новой заметкой"), detail: String(localized: "Создаёт отдельную заметку из написанного."))
                ShortcutRow(keys: ["↩"], title: String(localized: "Помощник на созвоне — спросить"), detail: String(localized: "Задать свой вопрос в поле внизу панели подсказок."))
            }

            Section(String(localized: "Мышь и трекпад")) {
                GestureRow(icon: "cursorarrow.motionlines", title: settings.openTrigger == .hover ? String(localized: "Навести на вырез") : String(localized: "Клик по вырезу"),
                           detail: String(localized: "Открывает панель."))
                GestureRow(icon: "doc.on.doc", title: String(localized: "Перетащить файл на вырез"), detail: String(localized: "Кладёт файл на полку."))
                GestureRow(icon: "hand.tap", title: String(localized: "Двойной клик"), detail: String(localized: "Открывает задачу Jira, заметку, файл на полке или изменённый файл в Git."))
                GestureRow(icon: "arrow.up.left.and.arrow.down.right", title: String(localized: "Щипок или прокрутка над шкалой дня"),
                           detail: String(localized: "Сужает и расширяет шкалу от 1 до 24 часов. Двойной клик по шкале — снова 10 часов."))
                GestureRow(icon: "hand.draw", title: String(localized: "Перетащить панель подсказок"), detail: String(localized: "Панель помощника на созвоне двигается за любое пустое место."))
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let title: String
    let detail: String
    var isOn: Binding<Bool>? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCap(key) }
            }
            .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let isOn { Toggle("", isOn: isOn).labelsHidden() }
        }
        .opacity(isOn?.wrappedValue == false ? 0.55 : 1)
    }
}

private struct GestureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, key.count > 1 ? 5 : 0)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                    .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
            )
    }
}
