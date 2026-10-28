import Foundation

/// Current weather plus the next few hours, from Open-Meteo (free, no key).
struct WeatherReport: Equatable {
    struct Hour: Equatable {
        let time: Date
        let temperature: Double
        let code: Int
        let precipitationChance: Int
    }

    let temperature: Double
    let code: Int
    let isDay: Bool
    let hours: [Hour]

    var symbol: String { WeatherCode.symbol(code, isDay: isDay) }
    var summary: String { WeatherCode.title(code) }
    var isWet: Bool { WeatherCode.isWet(code) }

    /// The first hour within `window` that will likely bring rain or snow while it is dry now.
    func precipitationSoon(after now: Date = Date(), window: TimeInterval = 2 * 3600) -> Hour? {
        guard !isWet else { return nil }
        return hours.first { hour in
            hour.time > now && hour.time <= now.addingTimeInterval(window)
                && (hour.precipitationChance >= 60 || (WeatherCode.isWet(hour.code) && hour.precipitationChance >= 40))
        }
    }

    static func parse(_ data: Data) -> WeatherReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue,
              let code = (current["weather_code"] as? NSNumber)?.intValue else { return nil }
        let hourly = root["hourly"] as? [String: Any] ?? [:]
        let times = (hourly["time"] as? [NSNumber]) ?? []
        let temps = (hourly["temperature_2m"] as? [NSNumber]) ?? []
        let codes = (hourly["weather_code"] as? [NSNumber]) ?? []
        let chances = (hourly["precipitation_probability"] as? [Any]) ?? []
        let hours = times.indices.compactMap { i -> Hour? in
            guard i < temps.count, i < codes.count else { return nil }
            return Hour(time: Date(timeIntervalSince1970: times[i].doubleValue), temperature: temps[i].doubleValue,
                        code: codes[i].intValue, precipitationChance: i < chances.count ? (chances[i] as? NSNumber)?.intValue ?? 0 : 0)
        }
        return WeatherReport(temperature: temperature, code: code, isDay: (current["is_day"] as? NSNumber)?.intValue != 0, hours: hours)
    }
}

/// WMO weather interpretation codes used by Open-Meteo.
enum WeatherCode {
    static func isWet(_ code: Int) -> Bool { (51...67).contains(code) || (71...86).contains(code) || (95...99).contains(code) }
    static func isSnow(_ code: Int) -> Bool { (71...77).contains(code) || code == 85 || code == 86 }

    static func symbol(_ code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func title(_ code: Int) -> String {
        switch code {
        case 0: return String(localized: "Ясно")
        case 1, 2: return String(localized: "Переменная облачность")
        case 3: return String(localized: "Пасмурно")
        case 45, 48: return String(localized: "Туман")
        case 51...57: return String(localized: "Морось")
        case 61...67, 80...82: return String(localized: "Дождь")
        case 71...77, 85, 86: return String(localized: "Снег")
        case 95...99: return String(localized: "Гроза")
        default: return String(localized: "Облачно")
        }
    }
}

@MainActor
final class WeatherService: ObservableObject {
    struct Place: Codable, Equatable {
        let query: String
        let name: String
        let latitude: Double
        let longitude: Double
    }

    @Published private(set) var report: WeatherReport?
    @Published private(set) var place: Place? = WeatherService.loadPlace()
    @Published private(set) var error: String?

    /// Fires when rain or snow is likely within two hours (at most once every three hours).
    var onPrecipitationSoon: ((WeatherReport.Hour) -> Void)?

    private var timer: EnergyTimer?
    private var lastWarning = Date.distantPast
    /// City of the last request; a new city is fetched shortly after typing stops.
    private var requestedCity: String?
    private static let placeKey = "weatherPlace"

    private static var city: String { Settings.shared.weatherCity.trimmingCharacters(in: .whitespaces) }

    private var isActive: Bool { Settings.shared.pluginEnabled(.weather) && !Self.city.isEmpty }

    func start() {
        timer = EnergyTimer(interval: { [weak self] in
            guard let self, self.isActive else { return nil }
            return self.requestedCity == Self.city ? 30 * 60 : 1.5
        }, action: { [weak self] in
            self?.requestedCity = Self.city
            Task { await self?.refresh() }
        })
    }

    func refresh() async {
        let city = Self.city
        guard isActive else { report = nil; return }
        do {
            let place = try await resolve(city)
            var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            components.queryItems = [
                .init(name: "latitude", value: String(format: "%.3f", place.latitude)),
                .init(name: "longitude", value: String(format: "%.3f", place.longitude)),
                .init(name: "current", value: "temperature_2m,weather_code,is_day"),
                .init(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
                .init(name: "forecast_hours", value: "6"),
                .init(name: "timeformat", value: "unixtime"),
                .init(name: "timezone", value: "auto"),
            ]
            if Locale.current.measurementSystem == .us { components.queryItems?.append(.init(name: "temperature_unit", value: "fahrenheit")) }
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            guard let report = WeatherReport.parse(data) else { throw URLError(.cannotParseResponse) }
            self.report = report
            error = nil
            if Settings.shared.weatherRainWarnings, let hour = report.precipitationSoon(), Date().timeIntervalSince(lastWarning) > 3 * 3600 {
                lastWarning = Date()
                onPrecipitationSoon?(hour)
            }
        } catch {
            self.error = String(localized: "Не удалось получить погоду")
            NSLog("NotchMate: weather failed: \(error)")
        }
    }

    /// Looks the city up once and keeps the coordinates until the city changes.
    private func resolve(_ city: String) async throws -> Place {
        if let place, place.query == city { return place }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"),
                                 .init(name: "language", value: AppLanguage.code.prefix(2).lowercased())]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["results"] as? [[String: Any]])?.first,
              let lat = (first["latitude"] as? NSNumber)?.doubleValue, let lon = (first["longitude"] as? NSNumber)?.doubleValue else {
            place = nil
            throw AIError.message(String(localized: "Город не найден"))
        }
        let country = first["country"] as? String
        let found = Place(query: city, name: [first["name"] as? String ?? city, country].compactMap { $0 }.joined(separator: ", "), latitude: lat, longitude: lon)
        place = found
        if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: Self.placeKey) }
        return found
    }

    private static func loadPlace() -> Place? {
        UserDefaults.standard.data(forKey: placeKey).flatMap { try? JSONDecoder().decode(Place.self, from: $0) }
    }

    var temperatureText: String? {
        report.map { "\(Int($0.temperature.rounded()))°" }
    }
}
