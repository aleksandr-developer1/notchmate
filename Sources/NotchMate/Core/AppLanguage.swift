import Foundation

/// The language NotchMate runs in, and helpers for text that is not a translated UI string.
enum AppLanguage {
    /// Languages shipped in Resources/Localizable.xcstrings; Russian is the source.
    static let supported = ["ru", "en", "de", "es", "fr", "pt-BR", "zh-Hans", "ja"]

    /// The localization macOS picked for the app (the system language, or the one chosen in the settings).
    static var code: String { Bundle.main.preferredLocalizations.first ?? "ru" }

    /// Dates and numbers shown in the UI follow the UI language.
    static var locale: Locale { Locale(identifier: code) }

    /// The system language, for names other apps create by it — Obsidian names daily notes in it.
    static var systemLocale: Locale {
        let global = UserDefaults(suiteName: UserDefaults.globalDomain)?.stringArray(forKey: "AppleLanguages")?.first
        return Locale(identifier: global ?? Locale.current.identifier)
    }

    /// Speech recognition default: the system language with its region, e.g. "ru-RU".
    static var defaultSpeechLocale: String {
        let lang = systemLocale.language.languageCode?.identifier ?? "ru"
        let region = Locale.current.region?.identifier ?? (lang == "ru" ? "RU" : "US")
        return "\(lang)-\(region)"
    }

    /// Appended to prompts (which stay in Russian) so answers come back in the UI language.
    static var replyInstruction: String {
        if code.hasPrefix("ru") { return "Отвечай по-русски." }
        let name = Locale(identifier: "en").localizedString(forIdentifier: code) ?? "English"
        return "Отвечай на языке: \(name) (\(code))."
    }

    /// Chosen in Settings → General; empty means "follow the system". Applies after a restart.
    static var override: String {
        get {
            // Only the app's own domain: the global AppleLanguages is the system list, not a choice made here.
            let own = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
            return ((own?["AppleLanguages"] as? [String])?.first).flatMap { supported.contains($0) ? $0 : nil } ?? ""
        }
        set {
            if newValue.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
            else { UserDefaults.standard.set([newValue], forKey: "AppleLanguages") }
        }
    }

    /// Name of a language in itself: "English", "Deutsch", "日本語".
    static func nativeName(_ code: String) -> String {
        Locale(identifier: code).localizedString(forIdentifier: code)?.capitalized(with: Locale(identifier: code)) ?? code
    }
}
