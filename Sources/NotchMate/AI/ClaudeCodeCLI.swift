import Foundation

/// Claude account via the official Claude Code CLI in headless mode (`claude -p --output-format stream-json`).
/// Login happens in Claude Code itself (`claude auth login`), credentials never touch NotchMate.
@MainActor
final class ClaudeCodeCLI: ObservableObject {
    @Published private(set) var isInstalled = CLITools.find("claude") != nil
    @Published private(set) var isLoggedIn = false
    @Published private(set) var authMethod: String?
    @Published private(set) var email: String?
    @Published var lastError: String?

    private var sessionID: String?
    private var process: Process?
    private var loginPoll: Timer?

    static let models: [(id: String, title: String)] = [("opus", String(localized: "Opus (последний)")), ("sonnet", String(localized: "Sonnet (последний)")), ("haiku", "Haiku")]

    func refreshStatus() async {
        guard let exe = CLITools.find("claude") else { isInstalled = false; isLoggedIn = false; return }
        isInstalled = true
        let r = await CLITools.run(exe, ["auth", "status"])
        guard let data = r.out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        isLoggedIn = json["loggedIn"] as? Bool ?? false
        authMethod = json["authMethod"] as? String
        email = json["email"] as? String ?? (json["account"] as? [String: Any])?["email"] as? String
    }

    func login() {
        CLITools.openInTerminal("claude auth login --claudeai")
        loginPoll?.invalidate()
        var ticks = 0
        loginPoll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                ticks += 1
                Task { @MainActor in
                    await self?.refreshStatus()
                    if self?.isLoggedIn == true || ticks > 100 { t.invalidate() }
                }
            }
        }
    }

    func logout() async {
        guard let exe = CLITools.find("claude") else { return }
        _ = await CLITools.run(exe, ["auth", "logout"])
        await refreshStatus()
    }

    func resetSession() { sessionID = nil }

    func cancel() { process?.terminate() }

    /// `allowTools: false` also skips loading MCP servers — noticeably faster start for one-off requests.
    /// `quick`: our own short system prompt instead of Claude Code's, no extended thinking, short answers —
    /// a 13k-character prompt answers in ~2 s instead of a minute.
    func send(_ text: String, model: String, instructions: String = AIChatService.systemPrompt, allowTools: Bool = true,
              quick: Bool = false, onDelta: @escaping (String) -> Void) async throws {
        guard let exe = CLITools.find("claude") else { throw AIError.message(String(localized: "Claude Code не найден. Установите: brew install claude-code")) }
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--tools", "", "--model", model, quick ? "--system-prompt" : "--append-system-prompt", instructions]
        if let sessionID { args += ["--resume", sessionID] }
        if allowTools, Settings.shared.aiToolsEnabled { args += ["--allowedTools", "mcp__notchmate"] }
        if !allowTools { args += ["--strict-mcp-config"] }

        let p = Process()
        p.executableURL = exe
        p.arguments = args
        var environment = CLITools.environment
        if quick {
            environment["MAX_THINKING_TOKENS"] = "0"
            environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = "600"
        }
        p.environment = environment
        p.currentDirectoryURL = CLITools.workspace
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        process = p

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var buffer = Data()
            var finished = false
            var gotDelta = false
            func finish(_ error: Error?) {
                guard !finished else { return }
                finished = true
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if chunk.isEmpty { return }
                        buffer.append(chunk)
                        while let nl = buffer.firstIndex(of: 0x0A) {
                            let line = buffer[buffer.startIndex..<nl]
                            buffer.removeSubrange(buffer.startIndex...nl)
                            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                            switch obj["type"] as? String {
                            case "system":
                                if let s = obj["session_id"] as? String { self.sessionID = s }
                            case "stream_event":
                                if let ev = obj["event"] as? [String: Any], (ev["type"] as? String) == "content_block_delta",
                                   let delta = ev["delta"] as? [String: Any], (delta["type"] as? String) == "text_delta",
                                   let t = delta["text"] as? String {
                                    gotDelta = true
                                    onDelta(t)
                                }
                            case "assistant":
                                // Fallback when partial messages aren't streamed.
                                if !gotDelta, let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] {
                                    for block in content where (block["type"] as? String) == "text" {
                                        if let t = block["text"] as? String { onDelta(t) }
                                    }
                                }
                            case "result":
                                if let s = obj["session_id"] as? String { self.sessionID = s }
                                if obj["is_error"] as? Bool == true {
                                    let msg = obj["result"] as? String ?? String(localized: "Ошибка Claude")
                                    if msg.lowercased().contains("login") { self.isLoggedIn = false }
                                    finish(AIError.message(msg))
                                } else {
                                    finish(nil)
                                }
                            default: break
                            }
                        }
                    }
                }
            }
            // stderr is drained while Claude runs (see below): if it were read only here, a
            // chatty stderr would fill the pipe and Claude would hang before ever exiting.
            nonisolated(unsafe) var errData = Data()
            let errRead = DispatchGroup()
            p.terminationHandler = { proc in
                errRead.wait()
                let errText = String(decoding: errData, as: UTF8.self)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        outPipe.fileHandleForReading.readabilityHandler = nil
                        if proc.terminationReason == .uncaughtSignal { finish(AIError.cancelled) }
                        else if proc.terminationStatus != 0 { finish(AIError.message(errText.isEmpty ? String(localized: "Claude Code завершился с ошибкой") : errText)) }
                        else { finish(nil) }
                    }
                }
            }
            do {
                errRead.enter()
                try p.run()
                DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readAll(); errRead.leave() }
                // write(contentsOf:) throws if Claude already exited; the old write(_:) raised an exception (crash).
                try? inPipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
                try? inPipe.fileHandleForWriting.close()
            } catch {
                finish(error)
            }
        }
    }
}
