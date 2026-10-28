import AppKit
import Foundation

/// Locates CLI tools for a GUI app (which doesn't inherit the shell PATH).
enum CLITools {
    static let searchPaths = [
        NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
        NSHomeDirectory() + "/.claude/local", NSHomeDirectory() + "/.npm-global/bin", "/usr/bin", "/bin",
    ]

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? ""
        env["PATH"] = (searchPaths + [existing]).joined(separator: ":")
        return env
    }

    static func find(_ name: String) -> URL? {
        for dir in searchPaths {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        // Desktop installations can bundle their own CLI even when no command is on PATH.
        // Codex ships both as its own app and inside ChatGPT.
        if name == "codex" {
            for id in ["com.openai.codex", "com.openai.chat"] {
                guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
                let bundled = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
                if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
            }
        }
        if name == "claude" {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Claude/claude-code", isDirectory: true)
            let versions = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for version in versions.sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }) {
                let builds = (try? FileManager.default.contentsOfDirectory(at: version, includingPropertiesForKeys: nil)) ?? []
                for build in builds.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let binary = build.appendingPathComponent("claude.app/Contents/MacOS/claude")
                    if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
                }
            }
        }
        return nil
    }

    /// Private, empty working directory so agents don't pick up project context or touch files.
    static var workspace: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchMate/ai-workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs a command and returns stdout (for short status calls).
    static func run(_ exe: URL, _ args: [String], timeout: TimeInterval = 20) async -> (status: Int32, out: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            p.environment = environment
            p.currentDirectoryURL = workspace
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readAll()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Opens Terminal running a command (for interactive logins).
    static func openInTerminal(_ command: String) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("notchmate-\(UUID().uuidString.prefix(6)).command")
        // The translated line goes inside double quotes: keep the shell from expanding anything in it.
        let done = String(localized: "Готово — это окно можно закрыть.")
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`")
        let body = "#!/bin/zsh\nexport PATH=\"\(environment["PATH"] ?? "")\"\nclear\n\(command)\necho\necho \"\(done)\"\n"
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }
}
