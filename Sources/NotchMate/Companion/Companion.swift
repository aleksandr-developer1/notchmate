import os
import AppKit
import SwiftUI

enum Mood: String, Equatable {
    case idle, startup, happy, love, sleepy, focused, excited, surprised, tired, music, eating, wink
    case alert, message, shutter, call, sad, proud, dizzy, nod
    case agent, ready, disappointed, relax, flow, bored, fishing, basketball, watch
    case breathe, stressed, zen, charged, drained

    @MainActor var caption: String {
        let n = Settings.shared.companionName
        switch self {
        case .idle: return String(localized: "\(n) рядом")
        case .startup: return String(localized: "\(n) просыпается…")
        case .happy: return String(localized: "\(n) доволен")
        case .love: return String(localized: "\(n) любит тебя ♥")
        case .sleepy: return String(localized: "\(n) дремлет…")
        case .focused: return String(localized: "\(n) сосредоточен")
        case .excited: return String(localized: "Ура!")
        case .surprised: return String(localized: "О!")
        case .tired: return String(localized: "\(n) устал — батарея садится")
        case .music: return String(localized: "\(n) качается под музыку")
        case .eating: return String(localized: "Ням-ням!")
        case .wink: return String(localized: "\(n) подмигивает")
        case .alert: return String(localized: "Уведомление!")
        case .message: return String(localized: "Тебе написали")
        case .shutter: return String(localized: "Щёлк — скриншот")
        case .call: return String(localized: "\(n) тихо слушает созвон")
        case .sad: return String(localized: "\(n) грустит")
        case .proud: return String(localized: "Готово! \(n) гордится")
        case .dizzy: return String(localized: "Столько уведомлений…")
        case .nod: return String(localized: "\(n) кивает")
        case .agent: return String(localized: "\(n) смотрит, как работает агент")
        case .ready: return String(localized: "Ответ готов!")
        case .disappointed: return String(localized: "Мы же фокусировались…")
        case .relax: return String(localized: "\(n) отдыхает с кофе")
        case .flow: return String(localized: "\(n) в потоке")
        case .bored: return String(localized: "\(n) скучает")
        case .fishing: return String(localized: "\(n) рыбачит")
        case .basketball: return String(localized: "\(n) играет в мяч")
        case .watch: return String(localized: "\(n) следит за курсором")
        case .breathe: return String(localized: "Дышим вместе")
        case .stressed: return String(localized: "\(n) чувствует напряжение")
        case .zen: return String(localized: "\(n) спокоен")
        case .charged: return String(localized: "\(n) полон сил")
        case .drained: return String(localized: "\(n) без сил")
        }
    }
}

struct DailyStats: Codable, Equatable {
    var day: String
    var focusMinutes: Int = 0
    var notes: Int = 0
    var pomodoros: Int = 0
    var tracks: Int = 0

    init(day: String) { self.day = day }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        focusMinutes = try c.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? 0
        notes = try c.decodeIfPresent(Int.self, forKey: .notes) ?? 0
        pomodoros = try c.decodeIfPresent(Int.self, forKey: .pomodoros) ?? 0
        tracks = try c.decodeIfPresent(Int.self, forKey: .tracks) ?? 0
    }
}

/// Small icon shown next to the face for a moment (who/what triggered a reaction).
struct CompanionBadge: Equatable {
    let id = UUID()
    let symbol: String?
    let image: NSImage?
    let tint: Color

    static func == (a: CompanionBadge, b: CompanionBadge) -> Bool { a.id == b.id }
}

/// Бип — a little living face under the camera that reacts to what the Mac is doing.
@MainActor
final class Companion: ObservableObject {
    private static let log = Logger(subsystem: "com.aleksandrkezikov.notchmate", category: "companion")
    @Published private(set) var mood: Mood = .idle
    @Published private(set) var look: CGPoint = .zero      // -1...1
    @Published private(set) var stats: DailyStats
    @Published private(set) var badge: CompanionBadge?
    /// True while a camera is in use (a call) — set by SystemEvents.
    var inCall = false

    /// Asks the notch to show a speech bubble.
    var onSpeak: ((String) -> Void)?

    private weak var env: AppEnvironment?
    private var reaction: (mood: Mood, until: Date)?
    private var tickTimer: Timer?
    private var lastPointerMove = Date()
    private var lastPointer: CGVector?
    private var shake = ShakeDetector()
    private var dizzyUntil = Date.distantPast
    private var lastDizzy = Date.distantPast
    private var dizzyStreak = 0
    private var lastWater = Date()
    private var lastStretch = Date()
    private var alertTimes: [Date] = []
    private var idleMoodSince = Date()
    private var lastScene = Date()
    private var badgeWork: DispatchWorkItem?
    private var greeted = false

    init() {
        let today = Self.dayKey()
        if let data = UserDefaults.standard.data(forKey: "companionStats"),
           let s = try? JSONDecoder().decode(DailyStats.self, from: data), s.day == today {
            stats = s
        } else {
            stats = DailyStats(day: today)
        }
    }

    func start(env: AppEnvironment) {
        self.env = env
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        react(.startup, for: 8)
    }

    // MARK: Reactions

    func react(_ mood: Mood, for seconds: TimeInterval = 2) {
        reaction = (mood, Date().addingTimeInterval(seconds))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { self.mood = mood }
    }

    func say(_ text: String, mood: Mood? = nil, force: Bool = false) {
        if let mood { react(mood, for: 3) }
        if force || !(env?.isDoNotDisturb ?? false) { onSpeak?(text) }
    }

    /// A reaction that doesn't interrupt a stronger one already playing.
    func nudge(_ mood: Mood, for seconds: TimeInterval = 1.4) {
        if let r = reaction, r.until > Date() { return }
        react(mood, for: seconds)
    }

    /// Notification-like events; several in a row make the assistant dizzy.
    func notify(_ mood: Mood, badge: CompanionBadge?, seconds: TimeInterval = 3) {
        let now = Date()
        alertTimes = alertTimes.filter { now.timeIntervalSince($0) < 30 } + [now]
        if alertTimes.count >= 4 {
            react(.dizzy, for: 3.5)
            alertTimes.removeAll()
        } else {
            react(mood, for: seconds)
        }
        if let badge { show(badge, for: seconds) }
    }

    func show(_ badge: CompanionBadge, for seconds: TimeInterval = 3) {
        badgeWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { self.badge = badge }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.badge = nil }
        }
        badgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func bump(_ key: WritableKeyPath<DailyStats, Int>, by n: Int = 1) {
        rollDayIfNeeded()
        stats[keyPath: key] += n
        if let data = try? JSONEncoder().encode(stats) {
            UserDefaults.standard.set(data, forKey: "companionStats")
        }
    }

    // MARK: Pointer

    /// `vector` is pointer position relative to the face, in points (y grows downward).
    func pointerMoved(vector: CGVector) {
        let now = Date()
        lastPointerMove = now
        guard Settings.shared.followCursor else { return }
        defer { lastPointer = vector }

        if let last = lastPointer, shake.add(dx: vector.dx - last.dx, dy: vector.dy - last.dy, at: now) {
            getDizzy(now)
            return
        }
        // Spinning spiral eyes don't look anywhere.
        guard now >= dizzyUntil else { return }

        // Eyes reach their limit ~300 pt away and ease in closer; looking up is limited by the bezel.
        let dist = max(hypot(vector.dx, vector.dy), 1)
        let reach = 1 - exp(-dist / 140)
        let nx = (vector.dx / dist) * reach
        let ny = max((vector.dy / dist) * reach, -0.35)
        let q = CGPoint(x: (nx * 20).rounded() / 20, y: (ny * 20).rounded() / 20)
        if q != look {
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.72)) { look = q }
        }
        if mood == .sleepy {
            react(.surprised, for: 1.0)
        }
    }

    private func getDizzy(_ now: Date) {
        guard now >= dizzyUntil else { return }
        dizzyStreak = now.timeIntervalSince(lastDizzy) < 45 ? dizzyStreak + 1 : 0
        lastDizzy = now
        dizzyUntil = now.addingTimeInterval(3.2)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { look = .zero }
        react(.dizzy, for: 3.2)
        if Settings.shared.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        let phrases: [[String]] = [
            [String(localized: "Ой-ой, голова кружится 😵‍💫"), String(localized: "Уф… всё плывёт 🌀"), String(localized: "Эй, не тряси меня! 😵")],
            [String(localized: "Опять?! Меня сейчас укачает 🤢"), String(localized: "Пощади… 🌀🌀")],
            [String(localized: "Всё, я в домике 🙈"), String(localized: "Я жалуюсь в поддержку 😤")],
        ]
        let line = phrases[min(dizzyStreak, phrases.count - 1)].randomElement()!
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.say(line) }
        // Recovering: a slightly offended look after repeated shaking.
        if dizzyStreak >= 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) { [weak self] in self?.react(.sad, for: 2.5) }
        }
    }

    // MARK: Loop

    private func tick() {
        rollDayIfNeeded()
        guard let env else { return }
        let settings = Settings.shared
        let now = Date()
        let systemIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)

        if !greeted {
            greeted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.2) { [weak self] in
                self?.say(Self.greeting(), mood: .happy)
            }
        }

        // Base mood from context.
        var base: Mood = .idle
        let hour = Calendar.current.component(.hour, from: now)
        let intensity = env.activity.intensity
        if env.breathing.isActive { base = .breathe }
        else if inCall { base = .call }
        // A question from an agent alerts for a minute; after that the orange dot in the wing is enough.
        else if env.agents.sessions.values.contains(where: { $0.state == .waiting && now.timeIntervalSince($0.updatedAt) < 60 }) { base = .alert }
        else if env.focus.isOnBreak { base = .relax }
        else if env.focus.phase == .running || env.jira.isTracking {
            base = settings.activityMoods && intensity == .flow && env.activity.duration > 60 ? .flow : .focused
        }
        // A working AI agent beats music: the track is still shown in the notch wing.
        else if !env.agents.working.isEmpty { base = .agent }
        else if let t = env.nowPlaying.track, t.isPlaying { base = .music }
        else if systemIdle > 180 || (hour >= 1 && hour < 6 && systemIdle > 30) { base = .sleepy }
        else if env.battery.hasBattery && env.battery.level <= 12 && !env.battery.isCharging { base = .tired }
        else if settings.activityMoods && intensity == .flow && env.activity.duration > 90 { base = .flow }
        else if settings.activityMoods && systemIdle > 70 { base = .bored }
        // Body: only replaces the calm moods, never work or music.
        if base == .idle || base == .bored, settings.healthMoods, let body = bodyMood(env: env, now: now) { base = body }
        // Pointer moving around: calm eyes that follow it instead of the idle glances.
        if base == .idle, settings.followCursor, now.timeIntervalSince(lastPointerMove) < 5 { base = .watch }

        // Now and then, when nothing happens, a little scene (fishing, basketball).
        if (base == .idle || base == .watch) && reaction == nil {
            if now.timeIntervalSince(idleMoodSince) > 8 * 60, now.timeIntervalSince(lastScene) > 10 * 60, settings.idleScenes, systemIdle < 60 {
                lastScene = now
                idleMoodSince = now
                react(Bool.random() ? .fishing : .basketball, for: 5)
            }
        } else {
            idleMoodSince = now
        }

        var target = base
        if let r = reaction {
            if r.until > now { target = r.mood } else { reaction = nil }
        }
        if target != mood {
            Self.log.info("mood \(self.mood.rawValue, privacy: .public) → \(target.rawValue, privacy: .public); agents working \(env.agents.working.count), waiting \(env.agents.sessions.values.filter { $0.state == .waiting }.count), playing \(env.nowPlaying.track?.isPlaying ?? false), bpm \(env.tempo.tempo?.bpm ?? 0)")
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { mood = target }
        }

        // Idle gaze wandering when the pointer is still.
        if now.timeIntervalSince(lastPointerMove) > 6, target == .idle, Int.random(in: 0..<4) == 0 {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                look = [CGPoint(x: -0.8, y: 0), CGPoint(x: 0.8, y: 0), CGPoint(x: 0, y: 0.6),
                        CGPoint(x: -0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5), .zero].randomElement()!
            }
        }

        // Care reminders (only while the user is actually at the Mac).
        if systemIdle < 120 && !env.isDoNotDisturb && !env.breathing.isActive {
            checkBody(env: env, now: now)
            if settings.waterReminder, now.timeIntervalSince(lastWater) > settings.waterInterval * 60 {
                lastWater = now
                say([String(localized: "Попей воды 💧"), String(localized: "Глоток воды — и дальше! 💧"), String(localized: "Время для стакана воды 💧")].randomElement()!, mood: .wink)
            } else if settings.stretchReminder, now.timeIntervalSince(lastStretch) > settings.stretchInterval * 60 {
                lastStretch = now
                say([String(localized: "Разомнись немного 🙆"), String(localized: "Встань, потянись 🧘")].randomElement()!, mood: .happy)
            }
        } else if systemIdle >= 120 {
            // Away from the Mac counts as a break.
            lastStretch = now
        }
    }

    // MARK: Body (Garmin / Apple Health)

    private var lastStressNudge = Date.distantPast
    private var batteryGreetedDay = ""

    /// Fresh stress / Body Battery turned into a resting mood.
    private func bodyMood(env: AppEnvironment, now: Date) -> Mood? {
        let health = env.health
        if let s = health.latestStress, now.timeIntervalSince(s.t) < 30 * 60, s.v >= Settings.shared.healthStressThreshold + 10 {
            return .stressed
        }
        if let b = health.latestBodyBattery, now.timeIntervalSince(b.t) < 2 * 3600, b.v <= 20 { return .drained }
        return nil
    }

    private func checkBody(env: AppEnvironment, now: Date) {
        let settings = Settings.shared
        let health = env.health
        guard health.isEnabled else { return }

        // Once a day, at the first activity: how charged the body is.
        let today = Self.dayKey()
        if batteryGreetedDay != today, settings.healthMoods, let bb = health.today?.bbLatest ?? health.today?.bbHigh {
            batteryGreetedDay = today
            let sleep = health.today?.sleepSeconds.map { String(localized: " · сон ") + HealthAnalytics.hours($0) } ?? ""
            if bb >= 70 {
                say(String(localized: "Body Battery \(Int(bb))\(sleep) — отличный день для сложных задач ⚡️"), mood: .charged)
                react(.charged, for: 4)
            } else if bb <= 35 {
                say(String(localized: "Body Battery всего \(Int(bb))\(sleep). Береги силы сегодня 🪫"), mood: .drained)
                react(.drained, for: 4)
            }
            return
        }

        // Stress nudge: fresh high reading, not in a call, at most once an hour.
        guard settings.healthStressNudges, !inCall, now.timeIntervalSince(lastStressNudge) > 60 * 60,
              let s = health.latestStress, now.timeIntervalSince(s.t) < 20 * 60, s.v >= settings.healthStressThreshold else { return }
        lastStressNudge = now
        react(.stressed, for: 4)
        say(String(localized: "Стресс \(Int(s.v)) по Garmin. Подышим \(Int(settings.breathMinutes)) мин? Кликни на меня 🌬️"))
        pendingBreathOffer = now
    }

    /// Set when the assistant offered breathing; a click on the face within 3 minutes starts it.
    private(set) var pendingBreathOffer: Date?

    /// Returns true when the click was consumed by a breathing offer.
    func acceptBreathOffer() -> Bool {
        guard let at = pendingBreathOffer, Date().timeIntervalSince(at) < 180, let env else { return false }
        pendingBreathOffer = nil
        env.breathing.start()
        return true
    }

    private func rollDayIfNeeded() {
        let today = Self.dayKey()
        if stats.day != today { stats = DailyStats(day: today) }
    }

    private static func dayKey() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func greeting() -> String {
        let n = Settings.shared.companionName
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return String(localized: "Доброе утро! Я \(n) ☀️")
        case 12..<18: return String(localized: "Привет! \(n) на месте 👋")
        case 18..<23: return String(localized: "Добрый вечер! \(n) тут 🌙")
        default: return String(localized: "Не спится? \(n) с тобой 🌙")
        }
    }
}

/// Recognizes a quick back-and-forth shake of the pointer: several sharp direction flips in about a second.
struct ShakeDetector {
    /// One axis: current direction and how far the pointer has travelled in it.
    private struct Axis {
        var dir: CGFloat = 0, leg: CGFloat = 0

        /// True when the direction flips after a leg long enough to be deliberate (not trackpad jitter).
        mutating func flipped(_ delta: CGFloat) -> Bool {
            guard abs(delta) > 0.5 else { return false }
            let sign: CGFloat = delta > 0 ? 1 : -1
            if sign == dir { leg += abs(delta); return false }
            let flip = dir != 0 && leg > 70
            dir = sign
            leg = abs(delta)
            return flip
        }
    }

    private var x = Axis(), y = Axis()
    private var flips: [Date] = []
    private var lastFire = Date.distantPast

    /// Returns true once per shake.
    mutating func add(dx: CGFloat, dy: CGFloat, at now: Date) -> Bool {
        if x.flipped(dx) { flips.append(now) }
        if y.flipped(dy) { flips.append(now) }
        flips.removeAll { now.timeIntervalSince($0) > 1.1 }
        guard flips.count >= 6, now.timeIntervalSince(lastFire) > 4 else { return false }
        flips.removeAll()
        lastFire = now
        return true
    }
}
