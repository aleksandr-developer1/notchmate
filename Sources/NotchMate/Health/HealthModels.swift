import Foundation

enum HealthSource: String, Codable, CaseIterable, Identifiable {
    case garmin, appleHealth
    var id: String { rawValue }
    var title: String { self == .garmin ? "Garmin" : "Apple Health" }
    var icon: String { self == .garmin ? "applewatch.side.right" : "heart.text.square" }
}

struct HealthPoint: Codable, Equatable {
    let t: Date
    let v: Double
}

/// One calendar day of body data from any source. Every field is optional: Apple Health has no
/// stress or Body Battery, a watch may not have slept on the wrist, and so on.
struct HealthDay: Codable, Equatable {
    let date: String   // yyyy-MM-dd, local

    var restingHR: Double?
    var minHR: Double?
    var maxHR: Double?
    var stressAvg: Double?
    var stressMax: Double?
    /// Seconds spent at each Garmin stress level.
    var stressRest: Double?
    var stressLow: Double?
    var stressMedium: Double?
    var stressHigh: Double?
    var bbHigh: Double?
    var bbLow: Double?
    var bbCharged: Double?
    var bbDrained: Double?
    var bbLatest: Double?
    var sleepSeconds: Double?
    var deepSeconds: Double?
    var lightSeconds: Double?
    var remSeconds: Double?
    var awakeSeconds: Double?
    var sleepScore: Double?
    var sleepStart: Date?
    var sleepEnd: Date?
    var hrvLastNight: Double?
    var hrvWeekly: Double?
    var hrvStatus: String?
    var steps: Double?
    var respiration: Double?
    var spo2: Double?
    var readiness: Double?

    var heartRate: [HealthPoint] = []
    var stress: [HealthPoint] = []
    var bodyBattery: [HealthPoint] = []

    /// Which source filled the day's headline numbers (for the small tag in the UI).
    var sources: Set<HealthSource> = []

    init(date: String) { self.date = date }

    private static let scalarKeys: [WritableKeyPath<HealthDay, Double?>] = [
        \.restingHR, \.minHR, \.maxHR, \.stressAvg, \.stressMax, \.stressRest, \.stressLow, \.stressMedium, \.stressHigh,
        \.bbHigh, \.bbLow, \.bbCharged, \.bbDrained, \.bbLatest, \.sleepSeconds, \.deepSeconds, \.lightSeconds,
        \.remSeconds, \.awakeSeconds, \.sleepScore, \.hrvLastNight, \.hrvWeekly, \.steps, \.respiration, \.spo2, \.readiness,
    ]

    /// `self` wins; gaps are filled from `other` (Garmin merged over Apple Health).
    func filled(from other: HealthDay) -> HealthDay {
        var d = self
        for k in Self.scalarKeys where d[keyPath: k] == nil { d[keyPath: k] = other[keyPath: k] }
        if d.sleepStart == nil { d.sleepStart = other.sleepStart; d.sleepEnd = other.sleepEnd }
        if d.hrvStatus == nil { d.hrvStatus = other.hrvStatus }
        if d.heartRate.isEmpty { d.heartRate = other.heartRate }
        if d.stress.isEmpty { d.stress = other.stress }
        if d.bodyBattery.isEmpty { d.bodyBattery = other.bodyBattery }
        d.sources.formUnion(other.sources)
        return d
    }

    var hasData: Bool {
        Self.scalarKeys.contains { self[keyPath: $0] != nil } || !heartRate.isEmpty || !stress.isEmpty
    }

    static func key(_ date: Date) -> String { keyFormatter.string(from: date) }
    static func date(_ key: String) -> Date? { keyFormatter.date(from: key) }
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Garmin Connect raw JSON

enum GarminParser {
    static func parse(_ data: Data) -> HealthDay? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let date = root["date"] as? String else { return nil }
        var d = HealthDay(date: date)
        d.sources = [.garmin]

        if let s = root["summary"] as? [String: Any] {
            d.restingHR = num(s["restingHeartRate"])
            d.minHR = num(s["minHeartRate"])
            d.maxHR = num(s["maxHeartRate"])
            d.stressAvg = positive(s["averageStressLevel"])
            d.stressMax = positive(s["maxStressLevel"])
            d.stressRest = num(s["restStressDuration"])
            d.stressLow = num(s["lowStressDuration"])
            d.stressMedium = num(s["mediumStressDuration"])
            d.stressHigh = num(s["highStressDuration"])
            d.bbHigh = num(s["bodyBatteryHighestValue"])
            d.bbLow = num(s["bodyBatteryLowestValue"])
            d.bbCharged = num(s["bodyBatteryChargedValue"])
            d.bbDrained = num(s["bodyBatteryDrainedValue"])
            d.bbLatest = num(s["bodyBatteryMostRecentValue"])
            d.steps = num(s["totalSteps"])
            d.spo2 = num(s["averageSpo2"])
            d.respiration = num(s["avgWakingRespirationValue"])
        }

        if let s = root["stress"] as? [String: Any] {
            // -1 / -2: off wrist or moving — not stress.
            d.stress = pairs(s["stressValuesArray"]).filter { $0.v >= 0 }
            d.bodyBattery = (s["bodyBatteryValuesArray"] as? [[Any]] ?? []).compactMap { row in
                guard row.count >= 3, let ms = num(row[0]), let v = num(row[2]) else { return nil }
                return HealthPoint(t: Date(timeIntervalSince1970: ms / 1000), v: v)
            }
            d.stressAvg = d.stressAvg ?? positive(s["avgStressLevel"])
            d.stressMax = d.stressMax ?? positive(s["maxStressLevel"])
        }

        if let h = root["heartRate"] as? [String: Any] {
            d.heartRate = pairs(h["heartRateValues"]).filter { $0.v > 20 }
            d.restingHR = d.restingHR ?? num(h["restingHeartRate"])
            d.minHR = d.minHR ?? num(h["minHeartRate"])
            d.maxHR = d.maxHR ?? num(h["maxHeartRate"])
        }

        if let sleep = root["sleep"] as? [String: Any], let dto = sleep["dailySleepDTO"] as? [String: Any] {
            d.sleepSeconds = positive(dto["sleepTimeSeconds"])
            d.deepSeconds = num(dto["deepSleepSeconds"])
            d.lightSeconds = num(dto["lightSleepSeconds"])
            d.remSeconds = num(dto["remSleepSeconds"])
            d.awakeSeconds = num(dto["awakeSleepSeconds"])
            if let a = num(dto["sleepStartTimestampGMT"]), let b = num(dto["sleepEndTimestampGMT"]) {
                d.sleepStart = Date(timeIntervalSince1970: a / 1000)
                d.sleepEnd = Date(timeIntervalSince1970: b / 1000)
            }
            if let scores = dto["sleepScores"] as? [String: Any], let overall = scores["overall"] as? [String: Any] {
                d.sleepScore = num(overall["value"])
            }
            d.hrvLastNight = num(sleep["avgOvernightHrv"])
            d.hrvStatus = sleep["hrvStatus"] as? String
        }

        if let hrv = root["hrv"] as? [String: Any], let s = hrv["hrvSummary"] as? [String: Any] {
            d.hrvLastNight = num(s["lastNightAvg"]) ?? d.hrvLastNight
            d.hrvWeekly = num(s["weeklyAvg"])
            d.hrvStatus = (s["status"] as? String) ?? d.hrvStatus
        }

        let readiness = (root["readiness"] as? [[String: Any]])?.first ?? root["readiness"] as? [String: Any]
        d.readiness = readiness.flatMap { num($0["score"]) }

        if d.respiration == nil, let r = root["respiration"] as? [String: Any] {
            d.respiration = num(r["avgWakingRespirationValue"])
        }
        return d
    }

    private static func pairs(_ any: Any?) -> [HealthPoint] {
        (any as? [[Any]] ?? []).compactMap { row in
            guard row.count >= 2, let ms = num(row[0]), let v = num(row[1]) else { return nil }
            return HealthPoint(t: Date(timeIntervalSince1970: ms / 1000), v: v)
        }
    }

    static func num(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }
    private static func positive(_ any: Any?) -> Double? { num(any).flatMap { $0 >= 0 ? $0 : nil } }
}

// MARK: - Apple Health (Health Auto Export JSON)

/// Reads the JSON that the iPhone app "Health Auto Export" writes to iCloud Drive
/// (`{"data": {"metrics": [{"name": "heart_rate", "data": [...]}]}}`). A Shortcuts automation
/// producing the same shape works too. Files overlap, so points are de-duplicated by timestamp.
enum AppleHealthParser {
    static func parse(files: [Data]) -> [String: HealthDay] {
        var hr: [Date: (min: Double, avg: Double, max: Double)] = [:]
        var resting: [Date: Double] = [:]
        var hrv: [Date: Double] = [:]
        var steps: [Date: Double] = [:]
        var resp: [Date: Double] = [:]
        var spo2: [Date: Double] = [:]
        var sleep: [String: HealthDay] = [:]

        for data in files {
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = root["data"] as? [String: Any],
                  let metrics = body["metrics"] as? [[String: Any]] else { continue }
            for m in metrics {
                let name = (m["name"] as? String ?? "").lowercased()
                for row in m["data"] as? [[String: Any]] ?? [] {
                    guard let t = date(row["date"]) else { continue }
                    let qty = GarminParser.num(row["qty"])
                    switch name {
                    case "heart_rate":
                        let avg = GarminParser.num(row["Avg"]) ?? qty
                        if let avg { hr[t] = (GarminParser.num(row["Min"]) ?? avg, avg, GarminParser.num(row["Max"]) ?? avg) }
                    case "resting_heart_rate": if let qty { resting[t] = qty }
                    case "heart_rate_variability", "heart_rate_variability_sdnn": if let qty { hrv[t] = qty }
                    case "step_count": if let qty { steps[t] = qty }
                    case "respiratory_rate": if let qty { resp[t] = qty }
                    case "blood_oxygen_saturation", "oxygen_saturation":
                        if let qty { spo2[t] = qty <= 1 ? qty * 100 : qty }
                    case "sleep_analysis":
                        // Aggregated nights: hours per stage; the night belongs to the morning it ended.
                        let end = date(row["sleepEnd"]) ?? t
                        var d = sleep[HealthDay.key(end)] ?? HealthDay(date: HealthDay.key(end))
                        let hours = { (k: String) in GarminParser.num(row[k]).map { $0 * 3600 } }
                        d.sleepSeconds = hours("totalSleep") ?? hours("asleep")
                        d.deepSeconds = hours("deep")
                        d.remSeconds = hours("rem")
                        d.lightSeconds = hours("core")
                        d.awakeSeconds = hours("awake")
                        d.sleepStart = date(row["sleepStart"])
                        d.sleepEnd = date(row["sleepEnd"])
                        sleep[d.date] = d
                    default: break
                    }
                }
            }
        }

        var days = sleep
        func day(_ t: Date) -> HealthDay {
            let k = HealthDay.key(t)
            return days[k] ?? HealthDay(date: k)
        }
        for (t, v) in hr.sorted(by: { $0.key < $1.key }) {
            var d = day(t)
            d.heartRate.append(HealthPoint(t: t, v: v.avg))
            d.minHR = min(d.minHR ?? v.min, v.min)
            d.maxHR = max(d.maxHR ?? v.max, v.max)
            days[d.date] = d
        }
        for (t, v) in resting.sorted(by: { $0.key < $1.key }) { var d = day(t); d.restingHR = v; days[d.date] = d }
        for (t, v) in steps { var d = day(t); d.steps = (d.steps ?? 0) + v; days[d.date] = d }
        for (key, group) in Dictionary(grouping: hrv, by: { HealthDay.key($0.key) }) {
            var d = days[key] ?? HealthDay(date: key)
            // Night readings (before 8:00) are closest to Garmin's "last night" HRV.
            let night = group.filter { Calendar.current.component(.hour, from: $0.key) < 8 }.map(\.value)
            let all = group.map(\.value)
            d.hrvLastNight = avg(night.isEmpty ? all : night)
            days[key] = d
        }
        for (key, group) in Dictionary(grouping: resp, by: { HealthDay.key($0.key) }) {
            var d = days[key] ?? HealthDay(date: key); d.respiration = avg(group.map(\.value)); days[key] = d
        }
        for (key, group) in Dictionary(grouping: spo2, by: { HealthDay.key($0.key) }) {
            var d = days[key] ?? HealthDay(date: key); d.spo2 = avg(group.map(\.value)); days[key] = d
        }
        for key in days.keys {
            days[key]?.sources = [.appleHealth]
            // Weekly HRV baseline from the surrounding week.
            if let date = HealthDay.date(key) {
                let week = (0..<7).compactMap { days[HealthDay.key(date.addingTimeInterval(-86400 * Double($0)))]?.hrvLastNight }
                if week.count >= 3 { days[key]?.hrvWeekly = avg(week) }
            }
        }
        return days
    }

    private static func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

    private static let formatters: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }
    private static let iso = ISO8601DateFormatter()

    private static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        if let d = iso.date(from: s) { return d }
        for f in formatters { if let d = f.date(from: s) { return d } }
        return nil
    }
}
