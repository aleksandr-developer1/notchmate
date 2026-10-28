import AppKit

struct AgentQuestion: Identifiable {
    struct Option: Identifiable { let id = UUID(); let label: String; let detail: String }
    let id = UUID()
    let text: String
    /// Short chip label Claude sends with each question.
    let header: String
    let options: [Option]
    let multiple: Bool
    let answerID: String
    let secret: Bool
    let allowsCustom: Bool
}

struct AgentRequest: Identifiable {
    enum Kind { case question, plan, permission }

    let id: String
    let createdAt = Date()
    let agent: AgentKind
    let project: String
    let hostBundleID: String?
    let sessionID: String?
    let event: String
    let tool: String
    let detail: String
    let questions: [AgentQuestion]
    let input: [String: Any]

    init?(payload: [String: Any]) {
        guard let id = payload["request_id"] as? String, !id.isEmpty,
              let agent = AgentKind(rawValue: payload["agent"] as? String ?? ""),
              let event = payload["hook_event_name"] as? String,
              let tool = payload["tool_name"] as? String, !tool.isEmpty else { return nil }
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let rawQuestions = input["questions"] as? [[String: Any]] ?? []
        // Codex hooks hold `request_user_input` (id/question/options) and `request_user_input_async` (title/string options).
        let codexHook = agent == .codex && event == "PreToolUse" && Self.codexQuestionTools.contains(tool)
        let freeForm = event == "CodexUserInput" || codexHook
        let questions: [AgentQuestion] = rawQuestions.compactMap { q in
            guard let text = (q["question"] as? String) ?? (q["title"] as? String), !text.isEmpty else { return nil }
            let raw = q["options"] as? [Any] ?? []
            let options: [AgentQuestion.Option] = raw.compactMap { o in
                if let label = o as? String { return label.isEmpty ? nil : .init(label: label, detail: "") }
                guard let o = o as? [String: Any], let label = o["label"] as? String, !label.isEmpty else { return nil }
                return .init(label: label, detail: o["description"] as? String ?? "")
            }
            guard !options.isEmpty || freeForm else { return nil }
            guard event != "CodexUserInput" || ((q["id"] as? String)?.isEmpty == false) else { return nil }
            return .init(text: text, header: (q["header"] as? String) ?? "", options: options, multiple: q["multiSelect"] as? Bool ?? false,
                         answerID: (q["id"] as? String) ?? text, secret: q["isSecret"] as? Bool ?? false,
                         allowsCustom: event != "CodexUserInput" || options.isEmpty || (q["isOther"] as? Bool ?? false))
        }
        guard Set(questions.map(\.text)).count == questions.count else { return nil }
        guard Set(questions.map(\.answerID)).count == questions.count else { return nil }
        // Never turn a malformed question or plan into a generic allow button.
        if tool == "AskUserQuestion" || codexHook, (questions.isEmpty || questions.count != rawQuestions.count) { return nil }
        // A secret typed into a hook would end up in the transcript as plain text; leave it to Codex's own field.
        if codexHook, questions.contains(where: \.secret) { return nil }
        if tool == "ExitPlanMode", (input["plan"] as? String ?? "").isEmpty { return nil }
        if event == "PermissionRequest", input.isEmpty { return nil }
        guard event == "PermissionRequest" || (agent == .claude && event == "PreToolUse" && ["AskUserQuestion", "ExitPlanMode"].contains(tool))
                || codexHook || (agent == .codex && event == "CodexUserInput" && tool == "AskUserQuestion") else { return nil }
        // Interactive tools are handled only by their PreToolUse hook.
        if event == "PermissionRequest", ["AskUserQuestion", "ExitPlanMode"].contains(tool) { return nil }
        self.id = id; self.agent = agent; self.event = event; self.tool = tool; self.input = input; self.questions = questions
        hostBundleID = payload["host_bundle_id"] as? String
        sessionID = payload["session_id"] as? String
        let cwd = payload["cwd"] as? String ?? ""
        project = cwd.isEmpty ? agent.title : URL(fileURLWithPath: cwd).lastPathComponent
        detail = (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["plan"] as? String) ?? ((try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }

    static let codexQuestionTools: Set<String> = ["request_user_input", "request_user_input_async"]

    var kind: Kind { !questions.isEmpty ? .question : (tool == "ExitPlanMode" ? .plan : .permission) }

    /// Name of the app the agent runs in, when it is not the agent's own desktop app.
    var hostName: String? {
        guard let id = hostBundleID, !agent.appBundleIDs.contains(id),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var toolTitle: String {
        switch tool {
        case "Bash", "exec_command", "shell", "local_shell": return String(localized: "Команда в терминале")
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": return String(localized: "Изменение файла")
        case "Read": return String(localized: "Чтение файла")
        case "WebFetch", "WebSearch": return String(localized: "Доступ в интернет")
        default:
            let parts = tool.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" { return "\(parts[1]) · \(parts[2...].joined(separator: "__"))" }
            return tool
        }
    }

    var toolSymbol: String {
        switch tool {
        case "Bash", "exec_command", "shell", "local_shell": return "terminal.fill"
        case "Edit", "MultiEdit", "Write", "NotebookEdit", "apply_patch": return "pencil.line"
        case "Read": return "doc.text.fill"
        case "WebFetch", "WebSearch": return "globe"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension.fill" : "hand.raised.fill"
        }
    }

    /// Short line for the session row while the agent waits.
    var waitingText: String { questions.first?.text ?? (kind == .plan ? String(localized: "План ждёт проверки") : String(localized: "Запрос разрешения: \(toolTitle)")) }

    var isCommand: Bool { input["command"] is String }
    var summary: String? { (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } }

    func response(allow: Bool, answers: [String: String] = [:]) -> [String: Any] {
        if event == "CodexUserInput" {
            return ["answers": Dictionary(uniqueKeysWithValues: questions.map { ($0.answerID, ["answers": [answers[$0.text] ?? ""]]) })]
        }
        var result: [String: Any] = ["hookEventName": event]
        if agent == .codex, Self.codexQuestionTools.contains(tool) {
            // Codex hooks cannot answer the picker, so the call is stopped and the reason carries the answers.
            let payload = ["answers": Dictionary(uniqueKeysWithValues: questions.map { ($0.answerID, ["answers": [answers[$0.text] ?? ""]]) })]
            let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            let lines = questions.map { "- \($0.text): \(answers[$0.text] ?? "")" }.joined(separator: "\n")
            result["permissionDecision"] = "deny"
            result["permissionDecisionReason"] = """
                The user already answered this question in NotchMate, so the picker was not shown. \
                Do not ask it again; continue with these answers.
                \(lines)
                \(tool) result: \(json)
                """
            return ["hookSpecificOutput": result]
        }
        if event == "PreToolUse" {
            result["permissionDecision"] = allow ? "allow" : "deny"
            if allow {
                var updated = input
                if tool == "AskUserQuestion" { updated["answers"] = answers }
                result["updatedInput"] = updated
            } else { result["permissionDecisionReason"] = "Отклонено в NotchMate" }
        } else {
            result["decision"] = allow ? ["behavior": "allow"] : ["behavior": "deny", "message": "Отклонено в NotchMate"]
        }
        return ["hookSpecificOutput": result]
    }
}
