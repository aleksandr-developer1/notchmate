import Foundation
import Combine
import SwiftUI

/// Shared services container.
@MainActor
final class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()

    let settings = Settings.shared
    let nowPlaying = NowPlayingService()
    let tempo = TempoService()
    let disco = DiscoMode()
    let health = HealthService()
    let breathing = BreathingCoach()
    let obsidian = ObsidianService()
    let appleNotes = AppleNotesService()
    let shelf = ShelfStore()
    let clipboard = ClipboardHistory()
    let focus = FocusTimer()
    let battery = BatteryMonitor()
    let volume = SystemVolume()
    let companion = Companion()
    let jira = JiraService()
    let systemEvents = SystemEvents()
    let ai = AIChatService()
    let calendar = CalendarService()
    let reminders = RemindersService()
    let agents = AgentMonitor()
    let distractions = DistractionGuard()
    let activity = ActivityMonitor()
    let bridge = LocalBridge()
    let attention = AttentionCenter()
    let calls = CallRecorder()
    let copilot = MeetingCopilot()
    let git = GitService()
    private var pluginObserver: AnyCancellable?
    private var pluginStates: [PluginID: Bool] = [:]

    /// The notch, set by its window controller (features show HUDs through it).
    weak var notch: NotchViewModel?

    func notchIsOpen(on tab: NotchTab) -> Bool { notch.map { $0.isOpen && $0.tab == tab } ?? false }

    /// Quiet mode: during a call or while focusing, Taby doesn't pop reminders or chatter.
    var isDoNotDisturb: Bool {
        settings.dndEnabled && (companion.inCall || focus.isWorking || jira.isTracking)
    }

    /// Notes store the user currently works with: Apple Notes by default, Obsidian only when connected and chosen.
    var notes: any NotesStore {
        settings.activeNotesSource == .obsidian ? obsidian : appleNotes
    }

    func start() {
        pluginStates = Dictionary(uniqueKeysWithValues: PluginID.allCases.map { ($0, settings.pluginEnabled($0)) })
        if settings.pluginEnabled(.music) { nowPlaying.start() }
        tempo.start(player: nowPlaying)
        disco.start(env: self)
        obsidian.start()
        clipboard.start()
        battery.start()
        volume.start()
        companion.start(env: self)
        jira.start()
        systemEvents.start(env: self)
        if settings.pluginEnabled(.ai) { ai.start() }
        calendar.start()
        reminders.start()
        agents.start()
        activity.start()
        distractions.isFocusing = { [unowned self] in self.focus.isWorking || self.jira.isTracking }
        distractions.start()
        bridge.onEvent = { [unowned self] payload in
            guard self.settings.pluginEnabled(.agents) else { return }
            self.agents.handle(payload)
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { self.git.noteAgentDirectory(cwd) }
        }
        bridge.onTool = { [unowned self] name, args in
            guard self.settings.pluginEnabled(.agents) else {
                return (PluginError.disabled(.agents).localizedDescription, true)
            }
            return await NotchMateToolRunner.run(name, args, env: self)
        }
        bridge.start()
        attention.start(env: self)
        calls.start(env: self)
        copilot.start(env: self)
        git.start(env: self)
        health.start(env: self)
        breathing.onFinish = { [unowned self] session, completed in
            guard session.seconds >= 30 else { return }
            self.companion.react(.zen, for: 5)
            let minutes = max(1, Int((session.seconds / 60).rounded()))
            self.companion.say(completed ? String(localized: "Готово: \(minutes) мин дыхания. Посмотрим, как изменится стресс 🌿") : String(localized: "Хорошая пауза — \(minutes) мин 🌿"), force: true)
            // Garmin needs a few minutes to sync the watch; check the effect later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20 * 60) { self.health.refresh(force: true) }
        }
        jira.onIssuesLoaded = { [unowned self] keys in self.attention.jiraUpdated(keys: keys) }
        pluginObserver = settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.syncPlugins()
        }
    }

    /// Never interrupt recording, responses or unlogged work when a parent module is disabled.
    func setPlugin(_ plugin: PluginID, enabled: Bool) -> String? {
        if enabled {
            if let missing = plugin.dependencies.first(where: { !settings.pluginEnabled($0) }) {
                return String(localized: "Сначала включите плагин «\(missing.title)».")
            }
            switch plugin {
            case .garmin: settings.garminEnabled = true
            case .appleHealth: settings.appleHealthEnabled = true
            case .git: settings.gitEnabled = true
            case .calendar: settings.calendarEnabled = true
            case .reminders: settings.remindersEnabled = true
            case .clipboard: settings.clipboardEnabled = true
            case .agents: settings.agentStatusEnabled = true
            default: break
            }
            settings.disabledPlugins.remove(plugin.rawValue)
        } else {
            let affected = plugin.disabling
            if affected.contains(.calls) || affected.contains(.obsidian) || affected.contains(.ai), calls.stage != .idle {
                return String(localized: "Дождитесь завершения записи и обработки созвона.")
            }
            if affected.contains(.ai), ai.isResponding || ai.tabyThinking || git.generating || copilot.isThinking {
                return String(localized: "Сначала дождитесь ответа ИИ или остановите его.")
            }
            if affected.contains(.git), git.generating || git.busy != nil {
                return String(localized: "Дождитесь завершения операции Git.")
            }
            if affected.contains(.jira), jira.sessionKey != nil {
                return String(localized: "Сначала сохраните или завершите таймер Jira.")
            }
            if affected.contains(.focus), focus.isActive {
                return String(localized: "Сначала завершите таймер фокуса.")
            }
            if (plugin == .garmin || plugin == .appleHealth), breathing.isActive,
               ![PluginID.garmin, .appleHealth].contains(where: { !affected.contains($0) && settings.pluginEnabled($0) }) {
                return String(localized: "Сначала завершите дыхательную практику.")
            }
            settings.disabledPlugins.formUnion(affected.map(\.rawValue))
        }
        syncPlugins()
        return nil
    }

    private func syncPlugins() {
        for plugin in PluginID.allCases {
            let enabled = settings.pluginEnabled(plugin)
            guard pluginStates[plugin] != enabled else { continue }
            pluginStates[plugin] = enabled
            switch plugin {
            case .music:
                if enabled { nowPlaying.start() } else { nowPlaying.stop(); tempo.audio.suspend(); disco.turnOff() }
            case .ai:
                if enabled { ai.start() } else { ai.suspendPlugin(); copilot.close() }
            case .meetingAssistant: if !enabled { copilot.close() }
            case .jira: jira.refresh()
            case .git: if enabled { git.detect() }
            case .calendar: calendar.refresh()
            case .reminders: reminders.refresh()
            case .notes: if enabled { appleNotes.refresh(force: true) }
            case .obsidian: if enabled { obsidian.refresh(force: true) }
            case .garmin, .appleHealth: health.refresh(force: enabled)
            case .agents: agents.pluginAvailabilityChanged()
            default: break
            }
        }
        if !settings.discoAvailable { disco.turnOff() }
        tempo.refreshAudio()
        notch?.ensureAvailableTab()
    }
}
