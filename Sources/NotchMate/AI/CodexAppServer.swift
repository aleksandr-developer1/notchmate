import AppKit
import Foundation

/// ChatGPT account via the official `codex app-server` JSON-RPC protocol (stdio, JSONL).
/// Credentials stay inside Codex; we only drive login, threads and turns.
@MainActor
final class CodexAppServer: ObservableObject {
    struct Model: Identifiable, Hashable { let id: String; let displayName: String; let isDefault: Bool }

    @Published private(set) var isInstalled = CLITools.find("codex") != nil
    @Published private(set) var isRunning = false
    @Published private(set) var email: String?
    @Published private(set) var plan: String?
    @Published private(set) var authMode: String?
    @Published private(set) var models: [Model] = []
    @Published private(set) var usedPercent: Double?
    @Published private(set) var resetsAt: Date?
    @Published var loginInProgress = false
    @Published var lastError: String?

    var isLoggedIn: Bool { authMode != nil }

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var initialized = false
    private var threadID: String?
    private var activeTurnID: String?
    private var onDelta: ((String) -> Void)?
    private var turnContinuation: CheckedContinuation<Void, Error>?
    private var pendingLoginID: String?

    // MARK: Lifecycle

    func ensureStarted() async throws {
        if initialized, process?.isRunning == true { return }
        guard let exe = CLITools.find("codex") else {
            isInstalled = false
            throw AIError.message(String(localized: "Codex CLI не найден. Установите: npm i -g @openai/codex (или brew install codex)"))
        }
        isInstalled = true
        let p = Process()
        p.executableURL = exe
        p.arguments = ["app-server"]
        p.environment = CLITools.environment
        p.currentDirectoryURL = CLITools.workspace
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isRunning = false
                    self.initialized = false
                    self.threadID = nil
                    for (_, c) in self.pending { c.resume(throwing: AIError.message(String(localized: "Codex app-server завершился"))) }
                    self.pending.removeAll()
                    self.turnContinuation?.resume(throwing: AIError.message(String(localized: "Codex app-server завершился")))
                    self.turnContinuation = nil
                }
            }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        isRunning = true
        _ = try await request("initialize", ["clientInfo": ["name": "notchmate", "title": "NotchMate", "version": "1.0"]])
        notify("initialized", [:])
        initialized = true
        await refreshAccount()
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    // MARK: Account

    func refreshAccount() async {
        do {
            try await ensureStartedIfNeeded()
            let r = try await request("account/read", ["refreshToken": false])
            if let acc = r["account"] as? [String: Any] {
                authMode = acc["type"] as? String
                email = acc["email"] as? String
                plan = acc["planType"] as? String
            } else {
                authMode = nil; email = nil; plan = nil
            }
            if isLoggedIn, models.isEmpty { await loadModels() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ensureStartedIfNeeded() async throws {
        if !initialized { try await ensureStarted() }
    }

    func login() async {
        do {
            try await ensureStartedIfNeeded()
            loginInProgress = true
            let r = try await request("account/login/start", ["type": "chatgpt"])
            pendingLoginID = r["loginId"] as? String
            if let s = r["authUrl"] as? String, let url = URL(string: s) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            loginInProgress = false
            lastError = error.localizedDescription
        }
    }

    func logout() async {
        do {
            _ = try await request("account/logout", [:])
            authMode = nil; email = nil; plan = nil; threadID = nil
        } catch { lastError = error.localizedDescription }
    }

    func loadModels() async {
        guard let r = try? await request("model/list", ["limit": 30]), let data = r["data"] as? [[String: Any]] else { return }
        models = data.compactMap { m in
            guard let id = m["id"] as? String, (m["hidden"] as? Bool) != true else { return nil }
            return Model(id: id, displayName: m["displayName"] as? String ?? id, isDefault: m["isDefault"] as? Bool ?? false)
        }
    }

    // MARK: Hook trust

    /// Marks NotchMate's own hooks as trusted — the same thing Codex's hooks review does
    /// (`hooks/list` → `config/value/write hooks.state."<key>".trusted_hash`). Other hooks are left untouched.
    func trustNotchMateHooks() async throws -> Int {
        try await ensureStartedIfNeeded()
        let list = try await request("hooks/list", [:])
        let exe = Bundle.main.executablePath ?? "NotchMate"
        var trusted = 0
        for entry in list["data"] as? [[String: Any]] ?? [] {
            for hook in entry["hooks"] as? [[String: Any]] ?? [] {
                guard let command = hook["command"] as? String, command.contains(exe), command.contains("--event codex"),
                      let key = hook["key"] as? String, let hash = hook["currentHash"] as? String else { continue }
                if (hook["trustStatus"] as? String) == "trusted" { trusted += 1; continue }
                _ = try await request("config/value/write", ["keyPath": "hooks.state.\"\(key)\".trusted_hash", "value": hash, "mergeStrategy": "replace"])
                trusted += 1
            }
        }
        return trusted
    }

    // MARK: Chat

    func resetThread() { threadID = nil }

    func send(_ text: String, model: String?, instructions: String = AIChatService.systemPrompt, quick: Bool = false,
              onDelta: @escaping (String) -> Void) async throws {
        try await ensureStartedIfNeeded()
        guard isLoggedIn else { throw AIError.message(String(localized: "Войдите в ChatGPT в настройках ИИ")) }
        if threadID == nil {
            var params: [String: Any] = ["cwd": CLITools.workspace.path, "approvalPolicy": "on-request", "sandbox": "read-only", "ephemeral": true,
                                         "developerInstructions": instructions]
            if let model, !model.isEmpty { params["model"] = model }
            let r = try await request("thread/start", params)
            threadID = (r["thread"] as? [String: Any])?["id"] as? String
        }
        guard let threadID else { throw AIError.message(String(localized: "Не удалось начать диалог")) }
        self.onDelta = onDelta
        var turn: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text]]]
        if let model, !model.isEmpty { turn["model"] = model }
        if quick { turn["effort"] = "low" }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            turnContinuation = cont
            Task { @MainActor in
                do {
                    let r = try await self.request("turn/start", turn)
                    self.activeTurnID = (r["turn"] as? [String: Any])?["id"] as? String
                } catch {
                    self.turnContinuation?.resume(throwing: error)
                    self.turnContinuation = nil
                }
            }
        }
    }

    func cancel() {
        guard let threadID, let activeTurnID else { return }
        Task { _ = try? await request("turn/interrupt", ["threadId": threadID, "turnId": activeTurnID]) }
    }

    // MARK: JSON-RPC

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            write(["method": method, "id": id, "params": params])
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        write(["method": method, "params": params])
    }

    private func write(_ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        try? stdin?.write(contentsOf: data)
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        let method = obj["method"] as? String
        if let id = obj["id"] as? Int, method == nil {
            let cont = pending.removeValue(forKey: id)
            if let err = obj["error"] as? [String: Any] {
                cont?.resume(throwing: AIError.message(err["message"] as? String ?? String(localized: "Ошибка Codex")))
            } else {
                cont?.resume(returning: obj["result"] as? [String: Any] ?? [:])
            }
            return
        }
        guard let method else { return }
        let params = obj["params"] as? [String: Any] ?? [:]
        if let id = obj["id"] {
            // Server → client request. Only NotchMate's own MCP tools are approved; everything else is declined.
            let raw = (try? JSONSerialization.data(withJSONObject: params)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            let ours = Settings.shared.aiToolsEnabled && raw.contains("notchmate")
            if method.contains("elicitation") {
                write(["id": id, "result": ["action": ours ? "accept" : "decline", "content": [String: Any]()]])
            } else {
                write(["id": id, "result": ["decision": ours ? "accept" : "decline"]])
            }
            return
        }
        switch method {
        case "item/agentMessage/delta":
            if let d = params["delta"] as? String { onDelta?(d) }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            activeTurnID = nil
            if let err = turn?["error"] as? [String: Any], let msg = err["message"] as? String {
                turnContinuation?.resume(throwing: AIError.message(msg))
            } else {
                turnContinuation?.resume()
            }
            turnContinuation = nil
        case "error":
            if let msg = (params["error"] as? [String: Any])?["message"] as? String { lastError = msg }
        case "account/login/completed":
            loginInProgress = false
            if params["success"] as? Bool == false { lastError = params["error"] as? String ?? String(localized: "Вход не выполнен") }
            Task { await refreshAccount() }
            NSApp.activate()
        case "account/updated":
            authMode = params["authMode"] as? String
            plan = params["planType"] as? String ?? plan
            Task { await refreshAccount() }
        case "account/rateLimits/updated":
            if let primary = (params["rateLimits"] as? [String: Any])?["primary"] as? [String: Any] {
                usedPercent = (primary["usedPercent"] as? NSNumber)?.doubleValue
                resetsAt = (primary["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            }
        default:
            break
        }
    }
}
