import AppKit

/// Pomodoro cycle: work → short break → … → long break every N sessions.
@MainActor
final class FocusTimer: ObservableObject {
    enum Phase { case idle, running, paused, finished }
    enum Kind: Equatable {
        case work, shortBreak, longBreak
        var isBreak: Bool { self != .work }
        var title: String {
            switch self {
            case .work: return String(localized: "Фокус")
            case .shortBreak: return String(localized: "Перерыв")
            case .longBreak: return String(localized: "Длинный перерыв")
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var kind: Kind = .work
    @Published private(set) var total: TimeInterval = 25 * 60
    @Published private(set) var remaining: TimeInterval = 25 * 60
    @Published private(set) var completedInCycle = 0
    @Published var label: String = String(localized: "Помидор")
    /// Jira key or task text the pomodoros are counted for.
    @Published private(set) var taskRef: String?

    /// (finished kind, next kind)
    var onFinish: ((Kind, Kind) -> Void)?
    var onPhaseChange: (() -> Void)?

    private var endDate: Date?
    private var ticker: Timer?
    private var autoWork: DispatchWorkItem?
    private let settings = Settings.shared

    var progress: Double { total > 0 ? 1 - remaining / total : 0 }
    var isActive: Bool { phase == .running || phase == .paused }
    var isWorking: Bool { phase == .running && kind == .work }
    var isOnBreak: Bool { isActive && kind.isBreak }
    var cycleLength: Int { max(1, settings.pomoCycle) }

    /// Next kind after the current work session completes.
    var nextBreak: Kind { (completedInCycle + 1) % cycleLength == 0 ? .longBreak : .shortBreak }

    // MARK: Control

    func start(minutes: Double? = nil, label: String = String(localized: "Помидор"), task: String? = nil) {
        autoWork?.cancel()
        kind = .work
        self.label = label
        taskRef = task ?? taskRef
        begin(seconds: (minutes ?? settings.pomoWork) * 60)
    }

    func startBreak(_ k: Kind? = nil) {
        autoWork?.cancel()
        kind = k ?? nextBreakAfterCompletion()
        begin(seconds: (kind == .longBreak ? settings.pomoLong : settings.pomoShort) * 60)
    }

    func skipBreak() {
        guard kind.isBreak else { return }
        start(label: label)
    }

    private func begin(seconds: TimeInterval) {
        total = seconds
        remaining = seconds
        resume()
    }

    func resume() {
        guard remaining > 0 else { return }
        endDate = Date().addingTimeInterval(remaining)
        phase = .running
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        onPhaseChange?()
    }

    func pause() {
        guard phase == .running else { return }
        tick()
        ticker?.invalidate()
        phase = .paused
        onPhaseChange?()
    }

    func toggle() { phase == .running ? pause() : resume() }

    func add(minutes: Double) {
        total += minutes * 60
        remaining += minutes * 60
        if phase == .running { endDate = endDate?.addingTimeInterval(minutes * 60) }
        if phase == .finished { resume() }
    }

    func reset() {
        ticker?.invalidate()
        autoWork?.cancel()
        phase = .idle
        kind = .work
        completedInCycle = 0
        total = settings.pomoWork * 60
        remaining = total
        onPhaseChange?()
    }

    private var lastFinishedWasWork = false

    private func nextBreakAfterCompletion() -> Kind {
        completedInCycle % cycleLength == 0 && completedInCycle > 0 ? .longBreak : .shortBreak
    }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        guard remaining <= 0 else { return }
        ticker?.invalidate()
        phase = .finished
        NSSound(named: kind == .work ? "Glass" : "Hero")?.play()

        let finished = kind
        let next: Kind
        if finished == .work {
            completedInCycle += 1
            recordPomodoro()
            next = nextBreakAfterCompletion()
        } else {
            next = .work
            if finished == .longBreak { completedInCycle = 0 }
        }
        onFinish?(finished, next)
        onPhaseChange?()

        let auto = finished == .work ? settings.pomoAutoBreak : settings.pomoAutoWork
        if auto {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.phase == .finished else { return }
                if next == .work { self.start(label: self.label) } else { self.startBreak(next) }
            }
            autoWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    // MARK: Stats per task

    private func recordPomodoro() {
        guard let ref = taskRef, !ref.isEmpty else { return }
        var counts = UserDefaults.standard.dictionary(forKey: "pomodorosByTask") as? [String: Int] ?? [:]
        counts[ref, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: "pomodorosByTask")
    }

    func pomodoros(for ref: String) -> Int {
        (UserDefaults.standard.dictionary(forKey: "pomodorosByTask") as? [String: Int])?[ref] ?? 0
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
