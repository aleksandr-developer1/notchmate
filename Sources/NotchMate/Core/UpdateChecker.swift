import AppKit
import CryptoKit

/// A published NotchMate release on GitHub.
struct AppRelease: Equatable {
    /// The app archive attached to the release.
    struct Asset: Equatable {
        let url: URL
        let size: Int
        /// Hex SHA-256 that GitHub reports for the upload.
        let sha256: String?
    }

    let version: String
    let notes: String
    let url: URL
    var asset: Asset? = nil

    /// Picks the newest release that is neither a draft nor older than `current` from the GitHub releases list.
    static func newest(in json: [[String: Any]], newerThan current: String) -> AppRelease? {
        for entry in json where entry["draft"] as? Bool != true {
            guard let tag = entry["tag_name"] as? String,
                  let link = (entry["html_url"] as? String).flatMap(URL.init(string:)) else { continue }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isNewer(version, than: current) else { return nil }
            return AppRelease(version: version, notes: (entry["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              url: link, asset: asset(in: entry))
        }
        return nil
    }

    /// The `NotchMate-<version>-arm64.zip` archive; only GitHub's own download host is accepted.
    static func asset(in entry: [String: Any]) -> Asset? {
        for item in entry["assets"] as? [[String: Any]] ?? [] {
            guard let name = item["name"] as? String, name.hasPrefix("NotchMate-"), name.hasSuffix(".zip"),
                  let link = (item["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  link.scheme == "https", link.host() == "github.com" else { continue }
            let digest = (item["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
            return Asset(url: link, size: item["size"] as? Int ?? 0, sha256: digest)
        }
        return nil
    }

    /// Numeric comparison: 0.10.0 is newer than 0.9.1; a trailing "-beta" sorts before the plain version.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> (numbers: [Int], pre: Bool) {
            let main = v.split(separator: "-", maxSplits: 1)
            return (main[0].split(separator: ".").map { Int($0) ?? 0 }, main.count > 1)
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x > y }
        }
        return !a.pre && b.pre
    }
}

/// Checks GitHub once a day for a newer NotchMate. Nothing about the user is sent.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var available: AppRelease?
    @Published private(set) var checking = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: lastCheckKey) as? Date

    /// Fires once per new version.
    var onFound: ((AppRelease) -> Void)?

    static let releasesURL = URL(string: "https://api.github.com/repos/aleksandr-developer1/notchmate/releases?per_page=10")!
    static let releasesPage = URL(string: "https://github.com/aleksandr-developer1/notchmate/releases")!
    private static let lastCheckKey = "updateLastCheck"
    private static let announcedKey = "updateAnnouncedVersion"
    private var timer: EnergyTimer?

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    func start() {
        timer = EnergyTimer(interval: { [weak self] in
            guard let self, Settings.shared.checkUpdates else { return nil }
            let since = Date().timeIntervalSince(self.lastChecked ?? .distantPast)
            return max(30, 24 * 3600 - since)
        }, action: { [weak self] in Task { await self?.check(manual: false) } })
    }

    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: Self.releasesURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw URLError(.badServerResponse)
            }
            lastError = nil
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckKey)
            let release = AppRelease.newest(in: json, newerThan: currentVersion)
            available = release
            guard let release, manual || release.version != Settings.shared.skippedVersion,
                  UserDefaults.standard.string(forKey: Self.announcedKey) != release.version || manual else { return }
            UserDefaults.standard.set(release.version, forKey: Self.announcedKey)
            if !manual { onFound?(release) }
        } catch {
            lastError = String(localized: "Не удалось проверить обновления")
            NSLog("NotchMate: update check failed: \(error)")
        }
    }

    func download() { NSWorkspace.shared.open(available?.url ?? Self.releasesPage) }

    // MARK: One-click install

    enum InstallState: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var install = InstallState.idle

    /// Whether this copy can replace itself: a release archive exists and the app folder is writable.
    var canInstall: Bool {
        guard available?.asset != nil else { return false }
        return UpdateInstaller.problem(installingOver: Bundle.main.bundleURL) == nil
    }

    /// Downloads the archive, checks it, swaps the app and relaunches.
    func installUpdate() async {
        guard let release = available, let asset = release.asset else { return }
        switch install { case .downloading, .installing: return; default: break }
        if let problem = UpdateInstaller.problem(installingOver: Bundle.main.bundleURL) {
            install = .failed(problem)
            return
        }
        install = .downloading(0)
        do {
            let zip = try await UpdateInstaller.download(asset) { [weak self] progress in
                Task { @MainActor in
                    if case .downloading = self?.install { self?.install = .downloading(progress) }
                }
            }
            install = .installing
            let app = try await UpdateInstaller.unpack(zip, expectingVersion: release.version,
                                                       bundleID: Bundle.main.bundleIdentifier ?? "")
            try UpdateInstaller.relaunch(replacing: Bundle.main.bundleURL, with: app)
            NSApp.terminate(nil)
        } catch {
            install = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            NSLog("NotchMate: update install failed: \(error)")
        }
    }

    func skip() {
        guard let available else { return }
        Settings.shared.skippedVersion = available.version
    }
}

/// Steps of a self-update. Nothing runs with extra privileges: the app only replaces a copy the user can write to.
enum UpdateInstaller {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    /// Why this copy can't replace itself, if it can't.
    static func problem(installingOver app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") {
            return String(localized: "Перенесите NotchMate в «Программы», чтобы обновляться в один клик.")
        }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            return String(localized: "Нет прав на запись в \(app.deletingLastPathComponent().path). Обновите вручную.")
        }
        return nil
    }

    static func download(_ asset: AppRelease.Asset, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadDelegate(expected: asset.size, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let file: URL = try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: URLRequest(url: asset.url, timeoutInterval: 60)).resume()
        }
        if let expected = asset.sha256 {
            let actual = try sha256(of: file)
            guard actual == expected else {
                try? FileManager.default.removeItem(at: file)
                throw Failure.message(String(localized: "Архив обновления повреждён. Попробуйте ещё раз."))
            }
        }
        return file
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Unzips next to the download and checks that it is the expected NotchMate with an intact signature.
    static func unpack(_ zip: URL, expectingVersion version: String, bundleID: String) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchMate-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard await run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]) == 0 else {
            throw Failure.message(String(localized: "Не удалось распаковать обновление."))
        }
        try? FileManager.default.removeItem(at: zip)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: { $0.pathExtension == "app" }),
              let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleShortVersionString"] as? String == version else {
            throw Failure.message(String(localized: "В архиве не та версия NotchMate."))
        }
        guard await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw Failure.message(String(localized: "Подпись обновления не прошла проверку."))
        }
        _ = await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// A small detached script waits for this process to quit, swaps the bundles (restoring the old one on failure) and opens the new app.
    static func relaunch(replacing old: URL, with new: URL, waitingFor pid: Int32 = ProcessInfo.processInfo.processIdentifier, launch: Bool = true) throws {
        let script = """
        pid="$1"; old="$2"; new="$3"; backup="$old.previous"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        rm -rf "$backup"
        if mv "$old" "$backup" && mv "$new" "$old"; then rm -rf "$backup"; else [ -d "$backup" ] && [ ! -d "$old" ] && mv "$backup" "$old"; fi
        [ "$4" = launch ] && open "$old"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "notchmate-update", String(pid), old.path, new.path, launch ? "launch" : "stay"]
        try process.run()
    }

    private static func run(_ tool: String, _ arguments: [String]) async -> Int32 {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    /// Reports progress and hands back the downloaded file, moved out of the session's temporary spot.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expected: Int
        let progress: @Sendable (Double) -> Void
        var continuation: CheckedContinuation<URL, Error>?

        init(expected: Int, progress: @escaping @Sendable (Double) -> Void) {
            self.expected = expected
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(max(expected, 1))
            progress(min(Double(totalBytesWritten) / total, 1))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                continuation?.resume(throwing: Failure.message(String(localized: "Не удалось скачать обновление.")))
                continuation = nil
                return
            }
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("NotchMate-update-\(UUID().uuidString).zip")
            do {
                try FileManager.default.moveItem(at: location, to: target)
                continuation?.resume(returning: target)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
