import AppKit
import SwiftUI

enum AgentKind: String {
    case claude, codex
    var title: String { self == .claude ? "Claude" : "Codex" }
    var appBundleIDs: [String] { self == .claude ? ["com.anthropic.claudefordesktop"] : ["com.openai.codex", "com.openai.chat"] }
    var fallbackSymbol: String { self == .claude ? "sparkle" : "terminal.fill" }
    var tint: Color { self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.2, green: 0.8, blue: 0.6) }

    var icon: NSImage? {
        for id in appBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return NSWorkspace.shared.icon(forFile: url.path) }
        }
        return nil
    }
}

struct AgentSession: Identifiable, Equatable {
    enum State { case working, waiting, done }
    let id: String
    let agent: AgentKind
    var project: String
    var state: State
    var startedAt: Date
    var updatedAt: Date
    /// Bundle ID of the app the agent runs in (terminal, IDE, desktop app), when known.
    var hostBundleID: String? = nil
    var waitingMessage: String? = nil
}

/// Tracks Claude Code / Codex sessions through their hooks (forwarded by `NotchMate --event`).
@MainActor
final class AgentMonitor: ObservableObject {
    @Published private(set) var sessions: [String: AgentSession] = [:]
    @Published private(set) var claudeHooksInstalled = false
    @Published private(set) var codexHooksInstalled = false
    @Published private(set) var requests: [AgentRequest] = []
    private var requestWaiters: [String: CheckedContinuation<[String: Any], Never>] = [:]
    var onRequest: (() -> Void)?
    /// Called when the last pending request has been answered or released.
    var onRequestsCleared: (() -> Void)?
    /// How long a hook waits for an answer in the notch before the agent asks in its own UI.
    static let requestTimeout: TimeInterval = 90

    var onStarted: ((AgentSession) -> Void)?
    var onWaiting: ((AgentSession) -> Void)?
    var onFinished: ((AgentSession) -> Void)?

    private var cleanup: EnergyTimer?

    struct Group: Identifiable {
        let agent: AgentKind
        let sessions: [AgentSession]
        var id: String { agent.rawValue }
        var isWaiting: Bool { sessions.contains { $0.state == .waiting } }
        var isWorking: Bool { sessions.contains { $0.state == .working } }
        /// Timer shows the longest-running active session of this agent.
        var startedAt: Date { sessions.filter { $0.state != .done }.map(\.startedAt).min() ?? Date() }
        var projects: String { Array(Set(sessions.map(\.project))).sorted().joined(separator: ", ") }
    }

    /// Active sessions grouped per agent, Claude first, then Codex.
    var groups: [Group] {
        [AgentKind.claude, .codex].compactMap { kind in
            let list = sessions.values.filter { $0.agent == kind && $0.state != .done }.sorted { $0.startedAt < $1.startedAt }
            return list.isEmpty ? nil : Group(agent: kind, sessions: list)
        }
    }

    var working: [AgentSession] { sessions.values.filter { $0.state == .working }.sorted { $0.startedAt < $1.startedAt } }
    var primary: AgentSession? { working.first ?? sessions.values.first { $0.state == .waiting } }

    func start() {
        refreshInstallState()
        cleanup = EnergyTimer(interval: { Settings.shared.pluginEnabled(.agents) ? 60 : nil },
                              action: { [weak self] in self?.dropStale() })
    }

    func pluginAvailabilityChanged() {
        if Settings.shared.pluginEnabled(.agents) { refreshInstallState() }
        else {
            sessions.removeAll()
            for id in Array(requestWaiters.keys) { finishRequest(id, response: [:]) }
        }
    }

    func waitForRequest(_ payload: [String: Any]) async -> [String: Any] {
        guard Settings.shared.pluginEnabled(.agents), Settings.shared.agentStatusEnabled else { return [:] }
        guard let request = AgentRequest(payload: payload), requestWaiters[request.id] == nil else {
            // Not answerable here, but the session still waits for the user.
            if payload["hook_event_name"] as? String == "PermissionRequest" { handle(payload) }
            return [:]
        }
        var waiting = payload
        waiting["hook_event_name"] = "Notification"
        waiting["message"] = request.waitingText
        handle(waiting)
        return await withCheckedContinuation { continuation in
            requestWaiters[request.id] = continuation
            requests.append(request)
            onRequest?()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.requestTimeout))
                self?.finishRequest(request.id, response: [:])
            }
        }
    }

    func finishRequest(_ id: String, response: [String: Any]) {
        guard let waiter = requestWaiters.removeValue(forKey: id) else { return }
        let request = requests.first { $0.id == id }
        requests.removeAll { $0.id == id }
        waiter.resume(returning: response)
        // Answered here: the agent carries on. Released: it asks in its own window, so the session keeps waiting.
        if !response.isEmpty, let sid = request?.sessionID, var session = sessions[sid], session.state == .waiting,
           !requests.contains(where: { $0.sessionID == sid }) {
            session.state = .working
            session.waitingMessage = nil
            sessions[sid] = session
        }
        if requests.isEmpty { onRequestsCleared?() }
    }

    // MARK: Events

    func handle(_ payload: [String: Any]) {
        guard Settings.shared.pluginEnabled(.agents) else { return }
        guard Settings.shared.agentStatusEnabled else { return }
        let agent = AgentKind(rawValue: payload["agent"] as? String ?? "") ?? .claude
        let event = payload["hook_event_name"] as? String ?? ""
        let sid = (payload["session_id"] as? String) ?? "\(agent.rawValue)-default"
        clearFinishedRequests(agent: agent, sessionID: sid, event: event, payload: payload)
        let cwd = payload["cwd"] as? String ?? ""
        // Ignore NotchMate's own chat runs.
        if !cwd.isEmpty, URL(fileURLWithPath: cwd).standardizedFileURL.path == CLITools.workspace.standardizedFileURL.path { return }
        let project = cwd.isEmpty ? agent.title : (cwd as NSString).lastPathComponent
        let now = Date()
        var session = sessions[sid] ?? AgentSession(id: sid, agent: agent, project: project, state: .done, startedAt: now, updatedAt: now)
        session.project = project
        session.updatedAt = now
        if let host = payload["host_bundle_id"] as? String, !host.isEmpty { session.hostBundleID = host }

        switch event {
        case "PreToolUse" where requests.contains(where: { $0.sessionID == sid }):
            // The tool hook runs alongside the one holding the question; keep showing that it waits.
            return
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart":
            let wasWorking = session.state == .working
            if !wasWorking { session.startedAt = now }
            session.state = .working
            session.waitingMessage = nil
            sessions[sid] = session
            if !wasWorking { onStarted?(session) }
        case "Notification" where payload["notification_type"] as? String == "idle_prompt"
            || (payload["message"] as? String ?? "").localizedCaseInsensitiveContains("waiting for your input"):
            // "Claude is waiting for your input" after a finished turn — nothing to attend to.
            return
        case "Notification", "PermissionRequest":
            session.state = .waiting
            session.waitingMessage = Self.waitingMessage(payload)
            sessions[sid] = session
            onWaiting?(session)
        case "Stop":
            let wasActive = session.state != .done
            session.state = .done
            session.waitingMessage = nil
            sessions[sid] = session
            if wasActive { onFinished?(session) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if self?.sessions[sid]?.state == .done { self?.sessions.removeValue(forKey: sid) }
            }
        case "SessionEnd":
            sessions.removeValue(forKey: sid)
        default:
            break
        }
    }

    func clearFinishedRequests(agent: AgentKind, sessionID: String, event: String, payload: [String: Any]) {
        let ending = ["Stop", "SessionEnd"].contains(event)
        let completed = ["PostToolUse", "PostToolUseFailure"].contains(event)
        guard ending || completed else { return }
        let tool = payload["tool_name"] as? String
        let input = payload["tool_input"] as? [String: Any]
        let ids = requests.filter { request in
            guard request.agent == agent, request.sessionID == sessionID else { return false }
            if ending { return true }
            guard let tool, let input, request.tool == tool else { return false }
            return NSDictionary(dictionary: request.input).isEqual(to: input)
        }.map(\.id)
        for id in ids { finishRequest(id, response: [:]) }
    }

    static func waitingMessage(_ payload: [String: Any]) -> String? {
        if let message = payload["message"] as? String {
            let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        if payload["hook_event_name"] as? String == "PermissionRequest",
           let name = payload["tool_name"] as? String, !name.isEmpty {
            return String(localized: "Запрос разрешения: \(name)")
        }
        return nil
    }

    private func dropStale() {
        let now = Date()
        sessions = sessions.filter { now.timeIntervalSince($0.value.updatedAt) < 45 * 60 }
        // An interrupted turn (Esc, killed process) never sends Stop — don't keep "working" forever.
        for (id, session) in sessions where session.state == .working && now.timeIntervalSince(session.updatedAt) > 10 * 60 {
            sessions[id]?.state = .done
        }
    }

    // MARK: Hooks install

    /// Configure each installed CLI once. Later manual disconnects remain respected.
    func configureAvailableAgents(codex: CodexAppServer) async {
        guard Settings.shared.pluginEnabled(.agents) else { return }
        let defaults = UserDefaults.standard
        await upgradeInstalledHooks(codex: codex)
        for (name, target) in [("claude", MCPTarget.claude), ("codex", MCPTarget.codex)] {
            let key = "agentAutoSetup.v1.\(name)"
            guard !defaults.bool(forKey: key), CLITools.find(name) != nil else { continue }
            do {
                if name == "claude" { try setClaudeHooks(true) }
                else {
                    try setCodexHooks(true)
                    guard try await codex.trustNotchMateHooks() > 0 else {
                        NSLog("NotchMate: Codex hooks not found for trust; will retry on next launch")
                        continue
                    }
                }
                if !mcpInstalled(target) {
                    let result = await setMCP(target, install: true)
                    guard result.ok else { NSLog("NotchMate: \(name) MCP setup failed: \(result.text)"); continue }
                }
                defaults.set(true, forKey: key)
            } catch {
                NSLog("NotchMate: \(name) integration setup failed: \(error)")
            }
        }
    }

    /// Bump when the hook set changes so already connected agents get the new events.
    private static let hooksVersion = 2

    /// Rewrites hooks the user already connected; disconnected agents stay untouched.
    private func upgradeInstalledHooks(codex: CodexAppServer) async {
        let key = "agentHooksVersion"
        guard UserDefaults.standard.integer(forKey: key) < Self.hooksVersion else { return }
        refreshInstallState()
        do {
            if claudeHooksInstalled { try setClaudeHooks(true) }
            if codexHooksInstalled {
                try setCodexHooks(true)
                _ = try await codex.trustNotchMateHooks()
            }
            UserDefaults.standard.set(Self.hooksVersion, forKey: key)
        } catch {
            NSLog("NotchMate: hook upgrade failed: \(error)")
        }
    }

    static var helperCommand: String {
        "\"\(Bundle.main.executablePath ?? "/Applications/NotchMate.app/Contents/MacOS/NotchMate")\""
    }

    private static var claudeSettingsURL: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json") }
    private static var codexHooksURL: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.codex/hooks.json") }

    private static let claudeEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "Notification", "SessionEnd"]
    private static let codexEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]

    func refreshInstallState() {
        claudeHooksInstalled = Self.hooksPresent(at: Self.claudeSettingsURL, marker: "--event claude")
        codexHooksInstalled = Self.hooksPresent(at: Self.codexHooksURL, marker: "--event codex")
    }

    func setClaudeHooks(_ install: Bool) throws {
        try Self.update(url: Self.claudeSettingsURL, events: Self.claudeEvents, agent: "claude", install: install)
        refreshInstallState()
    }

    func setCodexHooks(_ install: Bool) throws {
        try Self.update(url: Self.codexHooksURL, events: Self.codexEvents, agent: "codex", install: install)
        refreshInstallState()
    }

    private static func hooksPresent(at url: URL, marker: String) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    /// Merges our command hooks into a Claude/Codex hooks JSON without touching anything else.
    private static func update(url: URL, events: [String], agent: String, install: Bool) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIError.message(String(localized: "Не удалось прочитать \(url.path)"))
            }
            root = obj
            let backup = url.appendingPathExtension("notchmate-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let marker = "--event \(agent)"
        // Remove previous NotchMate entries.
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                var g = group
                let inner = (g["hooks"] as? [[String: Any]] ?? []).filter { !(($0["command"] as? String) ?? "").contains(marker) }
                if inner.isEmpty && g["hooks"] != nil { return nil }
                g["hooks"] = inner
                return g
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if install {
            for event in events {
                var groups = hooks[event] as? [[String: Any]] ?? []
                groups.append(["hooks": [["type": "command", "command": "\(helperCommand) --event \(agent)", "timeout": 5]]])
                hooks[event] = groups
            }
            var permission = hooks["PermissionRequest"] as? [[String: Any]] ?? []
            permission.append(["hooks": [["type": "command", "command": "\(helperCommand) --event \(agent) --wait", "timeout": 100]]])
            hooks["PermissionRequest"] = permission
            // Questions and plans: held before the agent shows its own picker.
            var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []
            let matcher = agent == "claude" ? "AskUserQuestion|ExitPlanMode" : "^request_user_input(_async)?$"
            pre.append(["matcher": matcher, "hooks": [["type": "command", "command": "\(helperCommand) --event \(agent) --wait", "timeout": 100]]])
            hooks["PreToolUse"] = pre
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    // MARK: MCP registration

    enum MCPTarget { case claude, codex }

    func mcpInstalled(_ target: MCPTarget) -> Bool {
        switch target {
        case .claude:
            guard let text = try? String(contentsOfFile: NSHomeDirectory() + "/.claude.json", encoding: .utf8) else { return false }
            return text.contains("\"notchmate\"")
        case .codex:
            guard let text = try? String(contentsOfFile: NSHomeDirectory() + "/.codex/config.toml", encoding: .utf8) else { return false }
            return text.contains("[mcp_servers.notchmate]")
        }
    }

    /// Swaps an MCP server registered under the app's former name for the current one.
    func replaceLegacyMCP(oldName: String) async {
        let exe = Bundle.main.executablePath ?? ""
        let claudeConfig = (try? String(contentsOfFile: NSHomeDirectory() + "/.claude.json", encoding: .utf8)) ?? ""
        if claudeConfig.contains("\"\(oldName)\""), let claude = CLITools.find("claude") {
            _ = await CLITools.run(claude, ["mcp", "remove", "--scope", "user", oldName])
            _ = await CLITools.run(claude, ["mcp", "add", "--scope", "user", "notchmate", "--", exe, "--mcp"])
        }
        let codexConfig = (try? String(contentsOfFile: NSHomeDirectory() + "/.codex/config.toml", encoding: .utf8)) ?? ""
        if codexConfig.contains("[mcp_servers.\(oldName)]"), let codex = CLITools.find("codex") {
            _ = await CLITools.run(codex, ["mcp", "remove", oldName])
            _ = await CLITools.run(codex, ["mcp", "add", "notchmate", "--", exe, "--mcp"])
        }
        objectWillChange.send()
    }

    func setMCP(_ target: MCPTarget, install: Bool) async -> (text: String, ok: Bool) {
        let exe = Bundle.main.executablePath ?? ""
        switch target {
        case .claude:
            guard let claude = CLITools.find("claude") else { return (String(localized: "Claude Code не найден"), false) }
            if install {
                _ = await CLITools.run(claude, ["mcp", "remove", "--scope", "user", "notchmate"])
                let r = await CLITools.run(claude, ["mcp", "add", "--scope", "user", "notchmate", "--", exe, "--mcp"])
                objectWillChange.send()
                return r.status == 0 ? (String(localized: "Подключено к Claude Code"), true) : (r.out, false)
            } else {
                let r = await CLITools.run(claude, ["mcp", "remove", "--scope", "user", "notchmate"])
                objectWillChange.send()
                return r.status == 0 ? (String(localized: "Отключено от Claude Code"), true) : (r.out, false)
            }
        case .codex:
            guard let codex = CLITools.find("codex") else { return (String(localized: "Codex не найден"), false) }
            if install {
                _ = await CLITools.run(codex, ["mcp", "remove", "notchmate"])
                let r = await CLITools.run(codex, ["mcp", "add", "notchmate", "--", exe, "--mcp"])
                objectWillChange.send()
                return r.status == 0 ? (String(localized: "Подключено к Codex"), true) : (r.out, false)
            } else {
                let r = await CLITools.run(codex, ["mcp", "remove", "notchmate"])
                objectWillChange.send()
                return r.status == 0 ? (String(localized: "Отключено от Codex"), true) : (r.out, false)
            }
        }
    }
}
