import AppKit
import Foundation

/// Body data from Garmin Connect and/or Apple Health, merged per day with Garmin first.
@MainActor
final class HealthService: ObservableObject {
    enum SourceState: Equatable {
        case off
        /// Garmin: python helper or login missing. Apple: folder not found yet.
        case setupNeeded(String)
        case syncing
        case ok(Date?)
        case error(String)

        var text: String {
            switch self {
            case .off: return String(localized: "выключено")
            case .setupNeeded(let s): return s
            case .syncing: return String(localized: "синхронизация…")
            case .ok(let d): return d.map { String(localized: "обновлено ") + Self.relative.localizedString(for: $0, relativeTo: Date()) } ?? String(localized: "подключено")
            case .error(let s): return s
            }
        }

        var isReady: Bool { if case .ok = self { return true } else { return false } }

        private static let relative: RelativeDateTimeFormatter = {
            let f = RelativeDateTimeFormatter()
            f.locale = AppLanguage.locale
            f.unitsStyle = .short
            return f
        }()
    }

    @Published private(set) var garminState: SourceState = .off
    @Published private(set) var appleState: SourceState = .off
    /// Merged days, key yyyy-MM-dd.
    @Published private(set) var days: [String: HealthDay] = [:]
    @Published private(set) var garminName = ""

    let contextLog = ContextLog()

    private var garminDays: [String: HealthDay] = [:]
    private var appleDays: [String: HealthDay] = [:]
    private var timer: Timer?
    private var loginPoll: Timer?
    private var appleFingerprint = ""
    private var garminProcess: Process?
    private var lastGarminSync = Date.distantPast

    // MARK: Paths

    nonisolated static var supportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchMate/garmin", isDirectory: true)
    }
    nonisolated static var venvPython: URL { supportURL.appendingPathComponent("venv/bin/python3") }
    nonisolated static var tokensURL: URL { supportURL.appendingPathComponent("tokens", isDirectory: true) }
    nonisolated static var dataURL: URL { supportURL.appendingPathComponent("data", isDirectory: true) }

    private var scriptURL: URL? {
        Bundle.main.url(forResource: "garmin_sync", withExtension: "py")
            ?? {
                let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/garmin_sync.py")
                return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
            }()
    }

    var appleFolderURL: URL {
        URL(fileURLWithPath: (Settings.shared.appleHealthFolder as NSString).expandingTildeInPath, isDirectory: true)
    }

    var isEnabled: Bool { Settings.shared.garminEnabled || Settings.shared.appleHealthEnabled }
    var hasData: Bool { days.values.contains { $0.hasData } }

    // MARK: Lifecycle

    func start(env: AppEnvironment) {
        contextLog.start(env: env)
        loadGarminCache()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Cheap to call often: Apple Health re-reads only changed files, Garmin syncs at most every 15 min.
    func refresh(force: Bool = false) {
        refreshApple()
        if Settings.shared.garminEnabled {
            if force || Date().timeIntervalSince(lastGarminSync) > 15 * 60 { syncGarmin() }
        } else {
            garminState = .off
            if !garminDays.isEmpty { garminDays = [:]; merge() }
        }
    }

    // MARK: Garmin

    var garminLoggedIn: Bool {
        FileManager.default.fileExists(atPath: Self.tokensURL.appendingPathComponent("garmin_tokens.json").path)
    }

    /// Opens Terminal: installs the helper into its own venv (first time) and asks for the login there.
    /// The password is typed into Garmin's login by the user and never passes through NotchMate.
    func connectGarmin() {
        guard let script = scriptURL else { garminState = .error(String(localized: "нет скрипта синхронизации")); return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.supportURL, withIntermediateDirectories: true)
        let installed = Self.supportURL.appendingPathComponent("garmin_sync.py")
        try? fm.removeItem(at: installed)
        try? fm.copyItem(at: script, to: installed)

        let q = { (u: URL) in "'" + u.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // Translated text goes inside double quotes: keep the shell from expanding anything in it.
        let sh = { (t: String) in t.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`") }
        let command = """
        #!/bin/zsh
        clear
        echo "\(sh(String(localized: "NotchMate · подключение Garmin Connect")))"
        echo
        SUPPORT=\(q(Self.supportURL))
        if [[ ! -x "$SUPPORT/venv/bin/python3" ]]; then
          echo "\(sh(String(localized: "▸ Устанавливаю помощник (один раз, ~30 сек)…")))"
          PY=$(command -v python3 || true)
          if [[ -z "$PY" ]]; then echo "\(sh(String(localized: "✗ Нужен Python 3: установите Xcode Command Line Tools (xcode-select --install)")))"; read; exit 1; fi
          "$PY" -m venv "$SUPPORT/venv" || { read; exit 1; }
        fi
        "$SUPPORT/venv/bin/python3" -m pip install -q --upgrade pip garminconnect || { echo "\(sh(String(localized: "✗ Не удалось установить garminconnect")))"; read; exit 1; }
        "$SUPPORT/venv/bin/python3" \(q(installed)) login \(q(Self.tokensURL))
        echo
        read "?\(sh(String(localized: "Нажмите Enter, чтобы закрыть окно")))"
        """
        let file = Self.supportURL.appendingPathComponent(String(localized: "Подключить Garmin.command"))
        do {
            try command.write(to: file, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            garminState = .error(String(localized: "не удалось подготовить вход"))
            return
        }
        NSWorkspace.shared.open(file)
        Settings.shared.garminEnabled = true
        garminState = .setupNeeded(String(localized: "жду вход в Терминале…"))

        // Pick the token up as soon as the login in Terminal finishes.
        loginPoll?.invalidate()
        let started = Date()
        loginPoll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                if self.garminLoggedIn {
                    t.invalidate()
                    self.syncGarmin()
                } else if Date().timeIntervalSince(started) > 15 * 60 {
                    t.invalidate()
                    self.garminState = .setupNeeded(String(localized: "войдите в Garmin Connect"))
                }
            }
        }
    }

    func disconnectGarmin() {
        garminProcess?.terminate()
        try? FileManager.default.removeItem(at: Self.tokensURL)
        try? FileManager.default.removeItem(at: Self.dataURL)
        Settings.shared.garminEnabled = false
        garminDays = [:]
        garminName = ""
        garminState = .off
        merge()
    }

    func syncGarmin() {
        guard garminProcess == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.venvPython.path) else {
            garminState = .setupNeeded(String(localized: "нужно подключить аккаунт")); return
        }
        guard garminLoggedIn else { garminState = .setupNeeded(String(localized: "войдите в Garmin Connect")); return }
        guard let script = scriptURL else { garminState = .error(String(localized: "нет скрипта синхронизации")); return }

        lastGarminSync = Date()
        garminState = .syncing
        let p = Process()
        p.executableURL = Self.venvPython
        // First sync pulls a month for trends; later ones only refresh the last days.
        let days = garminDays.count < 7 ? 30 : 14
        p.arguments = [script.path, "fetch", Self.tokensURL.path, Self.dataURL.path, String(days)]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            garminProcess = p
        } catch {
            garminState = .error(String(localized: "не запустился помощник"))
            return
        }
        // Read while the script runs: reading only after exit hangs forever if the
        // output outgrows the 64 KB pipe buffer (the script blocks, never exits).
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = out.fileHandleForReading.readAll()
            p.waitUntilExit()
            let code = p.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.garminFinished(output: data, code: code) }
            }
        }
    }

    private func garminFinished(output: Data, code: Int32) {
        garminProcess = nil
        let line = String(data: output, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        if json?["ok"] as? Bool == true {
            loadGarminCache()
            garminState = .ok(Date())
        } else {
            switch json?["error"] as? String {
            case "auth": garminState = .setupNeeded(String(localized: "войдите заново — токен истёк"))
            case "ratelimit", "blocked":
                // Every new attempt extends Garmin's IP block — back off for two hours.
                lastGarminSync = Date().addingTimeInterval(105 * 60)
                garminState = .error(String(localized: "Garmin ограничил запросы с этого IP, повторю через 2 ч"))
            case "network": garminState = .error(String(localized: "Garmin недоступен, повторю позже"))
            default: garminState = .error(code == 0 ? String(localized: "ошибка синхронизации") : String(localized: "ошибка помощника (\(code))"))
            }
            // Keep showing the cached days anyway.
            loadGarminCache()
        }
    }

    private func loadGarminCache() {
        let fm = FileManager.default
        var result: [String: HealthDay] = [:]
        for url in (try? fm.contentsOfDirectory(at: Self.dataURL, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let day = GarminParser.parse(data) { result[day.date] = day }
        }
        if let data = try? Data(contentsOf: Self.tokensURL.appendingPathComponent("profile.json")),
           let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            garminName = p["fullName"] as? String ?? ""
        }
        garminDays = result
        if Settings.shared.garminEnabled, garminState == .off, !result.isEmpty { garminState = .ok(nil) }
        merge()
    }

    // MARK: Apple Health

    private func refreshApple() {
        guard Settings.shared.appleHealthEnabled else {
            appleState = .off
            if !appleDays.isEmpty { appleDays = [:]; merge() }
            return
        }
        let folder = appleFolderURL
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            appleState = .setupNeeded(String(localized: "папка экспорта не найдена"))
            return
        }
        let cutoff = Date().addingTimeInterval(-40 * 86400)
        let files = urls.filter { $0.pathExtension.lowercased() == "json" }.compactMap { url -> (URL, Date)? in
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return m > cutoff ? (url, m) : nil
        }
        guard !files.isEmpty else { appleState = .setupNeeded(String(localized: "ждём первый экспорт с iPhone")); return }
        let fingerprint = files.map { "\($0.0.lastPathComponent)@\($0.1.timeIntervalSince1970)" }.sorted().joined(separator: "|")
        let newest = files.map(\.1).max()
        guard fingerprint != appleFingerprint else { appleState = .ok(newest); return }
        appleFingerprint = fingerprint

        let paths = files.map(\.0)
        Task.detached(priority: .utility) {
            let parsed = AppleHealthParser.parse(files: paths.compactMap { try? Data(contentsOf: $0) })
            await MainActor.run {
                self.appleDays = parsed
                self.appleState = parsed.isEmpty ? .error(String(localized: "файлы не похожи на экспорт Health Auto Export")) : .ok(newest)
                self.merge()
            }
        }
    }

    func openAppleFolder() {
        try? FileManager.default.createDirectory(at: appleFolderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(appleFolderURL)
    }

    // MARK: Merge & queries

    private func merge() {
        var result: [String: HealthDay] = [:]
        for key in Set(garminDays.keys).union(appleDays.keys) {
            switch (garminDays[key], appleDays[key]) {
            case let (g?, a?): result[key] = g.filled(from: a)
            case let (g?, nil): result[key] = g
            case let (nil, a?): result[key] = a
            default: break
            }
        }
        if result != days { days = result }
    }

    func day(_ date: Date) -> HealthDay? { days[HealthDay.key(date)] }
    var today: HealthDay? { day(Date()) }

    /// Last `n` days, oldest first (missing days included as empty so charts keep their spacing).
    func recent(_ n: Int, until: Date = Date()) -> [HealthDay] {
        (0..<n).reversed().map { back in
            let key = HealthDay.key(until.addingTimeInterval(-86400 * Double(back)))
            return days[key] ?? HealthDay(date: key)
        }
    }

    /// Latest stress reading and its age — only meaningful while fresh.
    var latestStress: HealthPoint? { today?.stress.last }
    var latestBodyBattery: HealthPoint? { today?.bodyBattery.last ?? today?.bbLatest.map { HealthPoint(t: Date(), v: $0) } }
    var latestHeartRate: HealthPoint? { today?.heartRate.last }

    /// Primary source currently feeding the notch (for small labels).
    var primarySource: HealthSource? {
        if Settings.shared.garminEnabled, !garminDays.isEmpty { return .garmin }
        if Settings.shared.appleHealthEnabled, !appleDays.isEmpty { return .appleHealth }
        return nil
    }
}
