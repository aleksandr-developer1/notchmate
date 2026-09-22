import Foundation

/// Agentic loops for API providers so the chat can act in NotchMate (tasks, focus, Jira, calendar…).
/// ChatGPT/Claude accounts get the same tools through the NotchMate MCP server instead.
enum ToolCalling {
    typealias Runner = @Sendable (String, [String: Any]) async -> (text: String, isError: Bool)
    static let maxRounds = 6

    // MARK: OpenAI-compatible (api.openai.com or a custom server)

    static func openAICompatible(baseURL: String, key: String, model: String, system: String, history: [AITurn],
                                 runTool: Runner, onDelta: @escaping @Sendable (String) -> Void) async throws {
        let tools: [[String: Any]] = NotchMateToolCatalog.tools.map {
            ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]]
        }
        var messages: [[String: Any]] = [["role": "system", "content": system]] + history.map { ["role": $0.role, "content": $0.text] }
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions") else { throw AIError.message("Неверный Base URL") }

        for _ in 0..<maxRounds {
            try Task.checkCancellation()
            var req = URLRequest(url: url, timeoutInterval: 600)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
            req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": messages, "tools": tools])
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw AIError.message("HTTP \(status): \(String(decoding: data.prefix(600), as: UTF8.self))")
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
                throw AIError.message("Неожиданный ответ сервера")
            }
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            if calls.isEmpty {
                onDelta(message["content"] as? String ?? "")
                return
            }
            var assistant: [String: Any] = ["role": "assistant", "tool_calls": calls]
            assistant["content"] = message["content"] ?? NSNull()
            messages.append(assistant)
            for call in calls {
                let fn = call["function"] as? [String: Any] ?? [:]
                let name = fn["name"] as? String ?? ""
                let argsText = fn["arguments"] as? String ?? "{}"
                let args = (try? JSONSerialization.jsonObject(with: Data(argsText.utf8)) as? [String: Any]) ?? [:]
                onDelta("`⚙︎ \(name)`\n\n")
                let result = await runTool(name, args)
                messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": result.text])
            }
        }
        onDelta("\n\n_Слишком много шагов с инструментами — остановился._")
    }

    // MARK: Anthropic Messages API

    static func anthropic(key: String, model: String, system: String, history: [AITurn],
                          runTool: Runner, onDelta: @escaping @Sendable (String) -> Void) async throws {
        let tools: [[String: Any]] = NotchMateToolCatalog.tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }
        var messages: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }

        for _ in 0..<maxRounds {
            try Task.checkCancellation()
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 600)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            var body: [String: Any] = ["model": model, "max_tokens": 16000, "system": system, "messages": messages, "tools": tools]
            if model == "claude-opus-5" {
                req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                body["fallbacks"] = "default"
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIError.message("Anthropic API \(status)")
            }
            guard (200..<300).contains(status) else {
                throw AIError.message("Anthropic API \(status): \((obj["error"] as? [String: Any])?["message"] as? String ?? "")")
            }
            let content = obj["content"] as? [[String: Any]] ?? []
            let stop = obj["stop_reason"] as? String
            for block in content where (block["type"] as? String) == "text" {
                if let t = block["text"] as? String, !t.isEmpty { onDelta(t) }
            }
            if stop == "refusal" { onDelta("\n\n_Модель отказалась отвечать на этот запрос._"); return }
            guard stop == "tool_use" else { return }
            // Echo the full assistant content back, then answer every tool_use in one user message.
            messages.append(["role": "assistant", "content": content])
            var results: [[String: Any]] = []
            for block in content where (block["type"] as? String) == "tool_use" {
                let name = block["name"] as? String ?? ""
                onDelta("\n\n`⚙︎ \(name)`\n\n")
                let r = await runTool(name, block["input"] as? [String: Any] ?? [:])
                var item: [String: Any] = ["type": "tool_result", "tool_use_id": block["id"] as? String ?? "", "content": r.text]
                if r.isError { item["is_error"] = true }
                results.append(item)
            }
            messages.append(["role": "user", "content": results])
        }
        onDelta("\n\n_Слишком много шагов с инструментами — остановился._")
    }
}
