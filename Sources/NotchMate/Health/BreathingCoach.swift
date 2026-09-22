import Foundation

enum BreathPattern: String, CaseIterable, Identifiable {
    case calm, coherent, box, relax478

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calm: return "Спокойствие"
        case .coherent: return "Резонанс"
        case .box: return "Квадрат"
        case .relax478: return "4-7-8"
        }
    }

    var subtitle: String {
        switch self {
        case .calm: return "вдох 4 · выдох 6 — снять напряжение"
        case .coherent: return "5,5 · 5,5 — выровнять пульс"
        case .box: return "4 · 4 · 4 · 4 — собраться перед задачей"
        case .relax478: return "4 · 7 · 8 — перед сном"
        }
    }

    /// inhale, hold, exhale, hold (seconds)
    var steps: (Double, Double, Double, Double) {
        switch self {
        case .calm: return (4, 0, 6, 0)
        case .coherent: return (5.5, 0, 5.5, 0)
        case .box: return (4, 4, 4, 4)
        case .relax478: return (4, 7, 8, 0)
        }
    }

    var cycle: Double { let s = steps; return s.0 + s.1 + s.2 + s.3 }
}

enum BreathPhase: Equatable {
    case inhale, holdIn, exhale, holdOut

    var title: String {
        switch self {
        case .inhale: return "Вдох"
        case .holdIn, .holdOut: return "Пауза"
        case .exhale: return "Выдох"
        }
    }
}

struct BreathSession: Codable, Identifiable {
    var id: Date { start }
    let start: Date
    let seconds: Double
    let pattern: String
}

/// Guided breathing drawn by the notch and the face. Time-based, so every view just asks for the
/// state at its own frame time — nothing ticks while no session runs.
@MainActor
final class BreathingCoach: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var pattern: BreathPattern = .calm
    @Published private(set) var startedAt = Date()
    @Published private(set) var duration: Double = 120
    @Published private(set) var sessions: [BreathSession] = []

    var onFinish: ((BreathSession, _ completed: Bool) -> Void)?

    private var endWork: DispatchWorkItem?
    private static let storeKey = "breathSessions"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let s = try? JSONDecoder().decode([BreathSession].self, from: data) {
            sessions = s
        }
    }

    func start(_ pattern: BreathPattern? = nil, minutes: Double? = nil) {
        if isActive { stop(completed: false) }
        self.pattern = pattern ?? BreathPattern(rawValue: Settings.shared.breathPattern) ?? .calm
        // Whole cycles only, so the session ends on an exhale.
        let wanted = (minutes ?? Settings.shared.breathMinutes) * 60
        duration = max(1, (wanted / self.pattern.cycle).rounded()) * self.pattern.cycle
        startedAt = Date()
        isActive = true
        let work = DispatchWorkItem { [weak self] in self?.stop(completed: true) }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func stop(completed: Bool = false) {
        guard isActive else { return }
        endWork?.cancel()
        isActive = false
        let elapsed = min(Date().timeIntervalSince(startedAt), duration)
        let session = BreathSession(start: startedAt, seconds: elapsed, pattern: pattern.rawValue)
        // Very short tries aren't sessions.
        if elapsed >= 30 {
            sessions.append(session)
            sessions = Array(sessions.suffix(200))
            if let data = try? JSONEncoder().encode(sessions) { UserDefaults.standard.set(data, forKey: Self.storeKey) }
        }
        onFinish?(session, completed)
    }

    struct State {
        let phase: BreathPhase
        /// 0…1 within the current phase.
        let phaseProgress: Double
        /// 0 (empty lungs) … 1 (full) — drives sizes.
        let fullness: Double
        let secondsLeftInPhase: Int
        let remaining: Double
    }

    func state(at date: Date) -> State {
        let s = pattern.steps
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        let t = elapsed.truncatingRemainder(dividingBy: pattern.cycle)
        func ease(_ x: Double) -> Double { 0.5 - cos(min(max(x, 0), 1) * .pi) / 2 }
        let phase: BreathPhase, p: Double, length: Double, fullness: Double
        if t < s.0 {
            phase = .inhale; length = s.0; p = t / s.0; fullness = ease(p)
        } else if t < s.0 + s.1 {
            phase = .holdIn; length = s.1; p = (t - s.0) / s.1; fullness = 1
        } else if t < s.0 + s.1 + s.2 {
            phase = .exhale; length = s.2; p = (t - s.0 - s.1) / s.2; fullness = 1 - ease(p)
        } else {
            phase = .holdOut; length = s.3; p = (t - s.0 - s.1 - s.2) / max(s.3, 0.001); fullness = 0
        }
        return State(phase: phase, phaseProgress: p, fullness: fullness,
                     secondsLeftInPhase: Int(ceil(length * (1 - p))), remaining: max(0, duration - elapsed))
    }
}
