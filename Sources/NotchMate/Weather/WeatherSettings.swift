import SwiftUI

struct WeatherSettings: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var settings = Settings.shared
    @ObservedObject var weather: WeatherService

    var body: some View {
        Form {
            Section(String(localized: "Где смотреть погоду")) {
                TextField(String(localized: "Город"), text: $settings.weatherCity, prompt: Text(String(localized: "Например, Москва")))
                if settings.weatherCity.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(String(localized: "Укажите город — без него погода не запрашивается.")).font(.caption).foregroundStyle(.secondary)
                } else if let error = weather.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                } else if let place = weather.place, let report = weather.report {
                    Label("\(place.name): \(Int(report.temperature.rounded()))°, \(report.summary.lowercased())", systemImage: report.symbol)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(String(localized: "Помощник")) {
                Toggle(String(localized: "Предупреждать о дожде и снеге за час-два"), isOn: $settings.weatherRainWarnings)
            }
            Section {
                Text(String(localized: "Прогноз берётся из Open-Meteo раз в 30 минут. В запрос уходят только координаты города."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
