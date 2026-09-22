import SwiftUI

struct HealthInsight: Identifiable {
    enum Tone { case good, bad, neutral }
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let tone: Tone

    var tint: Color {
        switch tone {
        case .good: return .green
        case .bad: return .orange
        case .neutral: return Color(red: 0.45, green: 0.75, blue: 1)
        }
    }
}

struct ContextLoad: Identifiable {
    var id: String { title }
    let title: String
    let icon: String
    /// Average stress (Garmin) or pulse (Apple Health) while in this context.
    let value: Double
    /// Difference from the at-the-Mac baseline.
    let delta: Double
    let minutes: Int
}

/// Pure analytics over merged days + the Mac context log. Uses Garmin stress where there is one and
/// falls back to pulse, so Apple-Health-only setups still get the comparisons.
@MainActor
enum HealthAnalytics {
    enum Metric { case stress, pulse
        var unit: String { self == .stress ? "" : String(localized: " уд/мин") }
        var title: String { self == .stress ? String(localized: "стресс") : String(localized: "пульс") }
    }

    static func metric(_ days: [HealthDay]) -> Metric {
        days.contains { !$0.stress.isEmpty } ? .stress : .pulse
    }

    static func series(_ day: HealthDay, _ m: Metric) -> [HealthPoint] {
        m == .stress ? day.stress : day.heartRate
    }

    // MARK: Context comparison

    static func contextLoads(days: [HealthDay], log: ContextLog) -> (Metric, [ContextLoad], baseline: Double?) {
        let m = metric(days)
        var buckets: [UInt16: [Double]] = [:]
        var baseline: [Double] = []
        for d in days {
            for p in series(d, m) {
                guard let c = log.context(at: p.t), c.contains(.atMac) || c.contains(.call) else { continue }
                baseline.append(p.v)
                for (flag, _, _) in MacContext.tracked where c.contains(flag) {
                    buckets[flag.rawValue, default: []].append(p.v)
                }
            }
        }
        guard let base = avg(baseline) else { return (m, [], nil) }
        // Garmin samples every 3 min, Apple Health roughly every few minutes.
        let step = m == .stress ? 3 : 5
        let loads = MacContext.tracked.compactMap { flag, title, icon -> ContextLoad? in
            guard let v = buckets[flag.rawValue], v.count >= 4, let a = avg(v) else { return nil }
            return ContextLoad(title: title, icon: icon, value: a, delta: a - base, minutes: v.count * step)
        }
        return (m, loads.sorted { $0.delta > $1.delta }, base)
    }

    /// Stress / pulse per app or site in front (enough minutes only), plus time away from the Mac.
    static func activityLoads(days: [HealthDay], log: ContextLog) -> (Metric, [ContextLoad], baseline: Double?) {
        let m = metric(days)
        var buckets: [String: [Double]] = [:]
        var baseline: [Double] = []
        var away: [Double] = []
        for d in days {
            let points = series(d, m)
            guard let sample = points.first, let first = log.firstMinute(onDayOf: sample.t) else { continue }
            for p in points {
                let minute = Int(p.t.timeIntervalSince1970 / 60)
                guard minute >= first else { continue }
                let c = log.minutes[minute]
                if let c, c.contains(.atMac) || c.contains(.call) {
                    baseline.append(p.v)
                    if let label = log.activities[minute] { buckets[label, default: []].append(p.v) }
                } else if p.t < Date() {
                    // No record (Mac asleep) or no input and nothing playing.
                    away.append(p.v)
                }
            }
        }
        guard let base = avg(baseline) else { return (m, [], nil) }
        let step = m == .stress ? 3 : 5
        var loads = buckets.filter { $0.value.count >= 5 }
            .sorted { $0.value.count > $1.value.count }
            .prefix(12)
            .compactMap { label, v -> ContextLoad? in
                guard let a = avg(v) else { return nil }
                return ContextLoad(title: label, icon: label.contains(".") ? "globe" : "app.fill", value: a, delta: a - base, minutes: v.count * step)
            }
        if away.count >= 5, let a = avg(away) {
            loads.append(ContextLoad(title: String(localized: "Не за Mac"), icon: "figure.walk", value: a, delta: a - base, minutes: away.count * step))
        }
        return (m, loads.sorted { $0.delta > $1.delta }, base)
    }

    // MARK: Hours

    /// Average per hour of day (0…23) over the given days.
    static func hourly(days: [HealthDay], _ m: Metric) -> [Int: Double] {
        var byHour: [Int: [Double]] = [:]
        for d in days { for p in series(d, m) { byHour[Calendar.current.component(.hour, from: p.t), default: []].append(p.v) } }
        return byHour.compactMapValues { $0.count >= 3 ? avg($0) : nil }
    }

    // MARK: Insights

    static func insights(service: HealthService, breathing: BreathingCoach) -> [HealthInsight] {
        let week = service.recent(7)
        let prevWeek = service.recent(7, until: Date().addingTimeInterval(-7 * 86400))
        var out: [HealthInsight] = []
        let (m, loads, base) = contextLoads(days: service.recent(14), log: service.contextLog)

        if let worst = loads.first, worst.delta >= (m == .stress ? 5 : 4) {
            out.append(.init(icon: worst.icon, title: String(localized: "Сильнее всего нагружают: \(worst.title.lowercased())"),
                             detail: String(localized: "\(m.title) в среднем \(Int(worst.value))\(m.unit) — на \(Int(worst.delta)) выше обычного за Mac"),
                             tone: .bad))
        }
        if let best = loads.last, best.delta <= -(m == .stress ? 4 : 3) {
            out.append(.init(icon: best.icon, title: String(localized: "Спокойнее всего: \(best.title.lowercased())"),
                             detail: String(localized: "\(m.title) \(Int(best.value))\(m.unit), на \(Int(-best.delta)) ниже обычного"),
                             tone: .good))
        }

        // Calmest / tensest working hours.
        let byHour = hourly(days: service.recent(14), m).filter { (9...20).contains($0.key) }
        if byHour.count >= 4, let calm = byHour.min(by: { $0.value < $1.value }), let tense = byHour.max(by: { $0.value < $1.value }),
           tense.value - calm.value >= (m == .stress ? 8 : 5) {
            out.append(.init(icon: "clock", title: String(localized: "Лучшее время для сложных задач — \(calm.key):00–\(calm.key + 1):00"),
                             detail: String(localized: "Пик напряжения обычно в \(tense.key):00 (\(Int(tense.value)) против \(Int(calm.value)))"),
                             tone: .neutral))
        }

        // Body Battery spent during the working day.
        if let t = service.today, let drain = workdayDrain(t, log: service.contextLog), drain >= 15 {
            out.append(.init(icon: "battery.25percent", title: String(localized: "За рабочий день ушло \(Int(drain)) Body Battery"),
                             detail: t.bbLatest.map { String(localized: "Сейчас \(Int($0)) — ") + ($0 < 30 ? String(localized: "лучше закругляться") : String(localized: "запас ещё есть")) } ?? "",
                             tone: drain > 45 ? .bad : .neutral))
        }

        // Sleep vs. next-day stress.
        let month = service.recent(30).filter { $0.sleepSeconds != nil && ($0.stressAvg != nil || $0.restingHR != nil) }
        let short = month.filter { $0.sleepSeconds! < 6.5 * 3600 }, long = month.filter { $0.sleepSeconds! >= 7 * 3600 }
        if short.count >= 3, long.count >= 3 {
            if let a = avg(short.compactMap(\.stressAvg)), let b = avg(long.compactMap(\.stressAvg)), a - b >= 4 {
                out.append(.init(icon: "bed.double.fill", title: String(localized: "Недосып заметен в стрессе"),
                                 detail: String(localized: "После ночей меньше 6,5 ч средний стресс \(Int(a)), после 7+ ч — \(Int(b))"),
                                 tone: .bad))
            } else if let a = avg(short.compactMap(\.restingHR)), let b = avg(long.compactMap(\.restingHR)), a - b >= 2 {
                out.append(.init(icon: "bed.double.fill", title: String(localized: "Недосып поднимает пульс покоя"),
                                 detail: String(localized: "\(Int(a)) уд/мин после короткого сна против \(Int(b)) после 7+ ч"), tone: .bad))
            }
        }

        // Week over week.
        func change(_ k: KeyPath<HealthDay, Double?>) -> (Double, Double)? {
            guard let a = avg(week.compactMap { $0[keyPath: k] }), let b = avg(prevWeek.compactMap { $0[keyPath: k] }) else { return nil }
            return (a, b)
        }
        if let (a, b) = change(\.hrvLastNight), abs(a - b) >= 3 {
            out.append(.init(icon: "waveform.path.ecg", title: a > b ? String(localized: "HRV растёт") : String(localized: "HRV снижается"),
                             detail: String(localized: "\(Int(a)) мс в среднем за неделю против \(Int(b)) неделей раньше") + (a > b ? String(localized: " — восстановление лучше") : String(localized: " — организму тяжелее")),
                             tone: a > b ? .good : .bad))
        }
        if let (a, b) = change(\.restingHR), abs(a - b) >= 2 {
            out.append(.init(icon: "heart", title: a < b ? String(localized: "Пульс покоя снизился") : String(localized: "Пульс покоя вырос"),
                             detail: String(localized: "\(Int(a)) против \(Int(b)) уд/мин неделей раньше"), tone: a < b ? .good : .bad))
        }
        if let (a, b) = change(\.sleepSeconds), abs(a - b) >= 20 * 60 {
            out.append(.init(icon: "moon.zzz.fill", title: a > b ? String(localized: "Спишь больше") : String(localized: "Спишь меньше"),
                             detail: String(localized: "\(hours(a)) в среднем против \(hours(b)) неделей раньше"), tone: a > b ? .good : .bad))
        }
        if let (a, b) = change(\.stressAvg), abs(a - b) >= 4 {
            out.append(.init(icon: "gauge.with.dots.needle.33percent", title: a < b ? String(localized: "Неделя спокойнее прошлой") : String(localized: "Неделя напряжённее прошлой"),
                             detail: String(localized: "Средний стресс \(Int(a)) против \(Int(b))"), tone: a < b ? .good : .bad))
        }

        // Does breathing help?
        if let effect = breathingEffect(service: service, breathing: breathing, m) {
            out.append(.init(icon: "wind", title: effect.drop > 0 ? String(localized: "Дыхание работает") : String(localized: "Дыхание пока не снижает напряжение"),
                             detail: String(localized: "\(effect.count) сесс. · \(m.title) через 15 мин ") + (effect.drop > 0 ? String(localized: "ниже на \(Int(effect.drop))") : String(localized: "без изменений")),
                             tone: effect.drop > 0 ? .good : .neutral))
        }

        if out.isEmpty, base != nil {
            out.append(.init(icon: "sparkles", title: String(localized: "Собираю данные"),
                             detail: String(localized: "Через пару дней с часами и NotchMate здесь появятся закономерности"), tone: .neutral))
        }
        return out
    }

    /// Body Battery at the first Mac minute of the day minus the latest value.
    static func workdayDrain(_ day: HealthDay, log: ContextLog) -> Double? {
        guard let first = day.bodyBattery.first(where: { log.context(at: $0.t)?.contains(.atMac) == true }),
              let last = day.bodyBattery.last, last.t > first.t else { return nil }
        return first.v - last.v
    }

    static func breathingEffect(service: HealthService, breathing: BreathingCoach, _ m: Metric) -> (count: Int, drop: Double)? {
        var drops: [Double] = []
        for s in breathing.sessions.suffix(40) {
            guard let d = service.day(s.start) else { continue }
            let pts = series(d, m)
            let end = s.start.addingTimeInterval(s.seconds)
            let before = pts.filter { $0.t >= s.start.addingTimeInterval(-15 * 60) && $0.t < s.start }.map(\.v)
            let after = pts.filter { $0.t > end.addingTimeInterval(5 * 60) && $0.t <= end.addingTimeInterval(20 * 60) }.map(\.v)
            if let a = avg(before), let b = avg(after) { drops.append(a - b) }
        }
        guard drops.count >= 2, let a = avg(drops) else { return nil }
        return (drops.count, a)
    }

    // MARK: Helpers

    static func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    static func hours(_ seconds: Double) -> String {
        let m = Int(seconds / 60)
        return String(localized: "\(m / 60) ч \(String(format: "%02d", m % 60)) мин")
    }

    static func stressLevel(_ v: Double) -> (title: String, color: Color) {
        switch v {
        case ..<26: return (String(localized: "покой"), Color(red: 0.35, green: 0.7, blue: 1))
        case ..<51: return (String(localized: "низкий"), Color(red: 1, green: 0.78, blue: 0.3))
        case ..<76: return (String(localized: "средний"), Color(red: 1, green: 0.55, blue: 0.2))
        default: return (String(localized: "высокий"), Color(red: 1, green: 0.3, blue: 0.25))
        }
    }

    static func batteryColor(_ v: Double) -> Color {
        switch v {
        case ..<26: return Color(red: 1, green: 0.35, blue: 0.3)
        case ..<51: return Color(red: 1, green: 0.7, blue: 0.25)
        case ..<76: return Color(red: 0.4, green: 0.75, blue: 1)
        default: return Color(red: 0.3, green: 0.9, blue: 0.55)
        }
    }
}
