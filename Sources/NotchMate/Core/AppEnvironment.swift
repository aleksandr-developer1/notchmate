import Foundation
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

    /// The notch, set by its window controller (features show HUDs through it).
    weak var notch: NotchViewModel?

    func notchIsOpen(on tab: NotchTab) -> Bool { notch.map { $0.isOpen && $0.tab == tab } ?? false }

    /// Quiet mode: during a call or while focusing, Taby doesn't pop reminders or chatter.
    var isDoNotDisturb: Bool {
        settings.dndEnabled && (companion.inCall || focus.isWorking || jira.isTracking)
    }

    /// Notes store the user currently works with: Apple Notes by default, Obsidian only when connected and chosen.
    var notes: any NotesStore {
        obsidian.isConnected && settings.notesSource == .obsidian ? obsidian : appleNotes
    }

    func start() {
        nowPlaying.start()
        tempo.start(player: nowPlaying)
        disco.start(env: self)
        obsidian.start()
        clipboard.start()
        battery.start()
        volume.start()
        companion.start(env: self)
        jira.start()
        systemEvents.start(env: self)
        ai.start()
        calendar.start()
        reminders.start()
        agents.start()
        activity.start()
        distractions.isFocusing = { [unowned self] in self.focus.isWorking || self.jira.isTracking }
        distractions.start()
        bridge.onEvent = { [unowned self] payload in
            self.agents.handle(payload)
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { self.git.noteAgentDirectory(cwd) }
        }
        bridge.onTool = { [unowned self] name, args in await NotchMateToolRunner.run(name, args, env: self) }
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
    }
}
