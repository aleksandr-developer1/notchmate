import Foundation
import OpenAI

enum AIError: LocalizedError {
    case message(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .cancelled: return String(localized: "Остановлено")
        }
    }
}

struct AITurn {
    let role: String   // "user" | "assistant"
    let text: String
}

/// OpenAI API with a user key, via MacPaw/OpenAI.
enum OpenAIKeyBackend {
    static let account = "openai-api-key"

    static func models(key: String) async throws -> [String] {
        let client = OpenAI(apiToken: key)
        let result = try await client.models()
        // Chat models only: "gpt-…" and o-series ("o3", "o4-mini"), not "omni-moderation", TTS, image or realtime models.
        let nonChat = ["audio", "realtime", "tts", "transcribe", "image"]
        return result.data.map(\.id)
            .filter { $0.hasPrefix("gpt") || $0.range(of: #"^o\d"#, options: .regularExpression) != nil }
            .filter { id in !nonChat.contains { id.contains($0) } }
            .sorted()
    }

    static func stream(history: [AITurn], model: String, key: String, system: String? = nil, onDelta: @escaping @Sendable (String) -> Void) async throws {
        let client = OpenAI(apiToken: key)
        var messages: [ChatQuery.ChatCompletionMessageParam] = []
        if let sys = ChatQuery.ChatCompletionMessageParam(role: .system, content: system ?? AIChatService.systemPrompt) { messages.append(sys) }
        for turn in history {
            if let m = ChatQuery.ChatCompletionMessageParam(role: turn.role == "user" ? .user : .assistant, content: turn.text) {
                messages.append(m)
            }
        }
        let query = ChatQuery(messages: messages, model: model)
        for try await chunk in client.chatsStream(query: query) {
            try Task.checkCancellation()
            if let text = chunk.choices.first?.delta.content { onDelta(text) }
        }
    }
}

/// Any server implementing the OpenAI Chat Completions API.
enum CustomOpenAIBackend {
    static let account = "custom-openai-api-key"

    static func models(baseURL: String, key: String) async throws -> [String] {
        let request = try makeRequest(baseURL: baseURL, path: "models", key: key, method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data, service: String(localized: "Свой ИИ"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["id"] as? String }.sorted()
    }

    static func stream(history: [AITurn], model: String, baseURL: String, key: String, system: String? = nil, maxTokens: Int? = nil,
                       onDelta: @escaping @Sendable (String) -> Void) async throws {
        var request = try makeRequest(baseURL: baseURL, path: "chat/completions", key: key, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let messages = [["role": "system", "content": system ?? AIChatService.systemPrompt]] + history.map {
            ["role": $0.role, "content": $0.text]
        }
        var body: [String: Any] = ["model": model, "messages": messages, "stream": true]
        if let maxTokens {
            body["max_tokens"] = maxTokens
            body["temperature"] = 0.3
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status >= 200 && status < 300 else {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw AIError.message(String(localized: "Свой ИИ \(status): \(raw)"))
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let text = delta["content"] as? String else { continue }
            onDelta(text)
        }
    }

    private static func makeRequest(baseURL: String, path: String, key: String, method: String) throws -> URLRequest {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmed),
              let scheme = base.scheme, ["http", "https"].contains(scheme.lowercased()),
              base.host != nil else {
            throw AIError.message(String(localized: "Укажите корректный Base URL, например http://localhost:11434/v1"))
        }
        let url = base.appendingPathComponent(path)
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = method
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
        return request
    }

    private static func validate(_ response: URLResponse, data: Data, service: String) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status >= 200 && status < 300 else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw AIError.message("\(service) \(status): \(raw)")
        }
    }
}

/// Anthropic Messages API with a user key (raw HTTP + SSE; there is no official Swift SDK).
enum AnthropicKeyBackend {
    static let account = "anthropic-api-key"
    static let models = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]

    static func stream(history: [AITurn], model: String, key: String, system: String? = nil, maxTokens: Int? = nil,
                       onDelta: @escaping @Sendable (String) -> Void) async throws {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens ?? 64000,
            "stream": true,
            "system": system ?? AIChatService.systemPrompt,
            "messages": history.map { ["role": $0.role, "content": $0.text] },
        ]
        if model == "claude-opus-5" {
            // Server-side fallback on safety refusals.
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            let msg = ((try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            throw AIError.message("Anthropic API \(status): \(msg ?? raw)")
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "content_block_delta":
                if let d = obj["delta"] as? [String: Any], (d["type"] as? String) == "text_delta", let t = d["text"] as? String { onDelta(t) }
            case "message_delta":
                if (obj["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
                    onDelta(String(localized: "\n\n_Модель отказалась отвечать на этот запрос._"))
                }
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? String(localized: "Ошибка потока")
                throw AIError.message(msg)
            default: break
            }
        }
    }
}
