import Foundation

/// Простое локальное хранилище секретов приложения.
///
/// Файл находится в Application Support и закрыт правами 600. Это не так
/// безопасно, как системная Связка ключей, зато приложение не вызывает её
/// и macOS больше не показывает запросы доступа.
enum Keychain {
    private static let fileName = "secrets.json"

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchMate", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func get(_ account: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return values[account]
    }

    static func set(_ value: String, for account: String) {
        var values: [String: String] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            values = stored
        }

        if value.isEmpty {
            values.removeValue(forKey: account)
        } else {
            values[account] = value
        }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(values)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("Не удалось сохранить локальные секреты: %@", error.localizedDescription)
        }
    }
}
