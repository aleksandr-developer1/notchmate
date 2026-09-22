import Foundation

/// Non-UI entry points of the same binary:
///   NotchMate --event claude|codex   (agent hook: reads hook JSON on stdin, forwards to the app, prints nothing)
///   NotchMate --mcp                  (MCP server over stdio for Claude Code / Codex)
///   NotchMate --meeting [hint|close] (meeting assistant: toggle / hint now / close)
///   NotchMate --permissions          (asks the running app to open the permissions window)
enum HelperModes {
    static func runIfNeeded() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--event") {
            let agent = args.count > i + 1 ? args[i + 1] : "agent"
            runEvent(agent: agent)
            exit(0)
        }
        if args.contains("--permissions") {
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.notchmate.showPermissions"), object: nil, deliverImmediately: true)
            exit(0)
        }
        if let i = args.firstIndex(of: "--meeting") {
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.notchmate.meetingAssistant"), object: args.count > i + 1 ? args[i + 1] : nil, deliverImmediately: true)
            exit(0)
        }
        if args.contains("--mcp") {
            MCPServer.run()
            exit(0)
        }
    }

    private static func runEvent(agent: String) {
        var payload: [String: Any] = [:]
        let stdinData = FileHandle.standardInput.readAll()
        if let obj = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] { payload = obj }
        payload["agent"] = agent
        // The app that launched the agent (Terminal, iTerm, VS Code, Claude desktop…) — macOS passes it down to child processes.
        if let host = ProcessInfo.processInfo.environment["__CFBundleIdentifier"], !host.isEmpty { payload["host_bundle_id"] = host }
        _ = BridgeClient.post("/event", payload, timeout: 1.5)
    }
}

/// Minimal MCP (JSON-RPC 2.0 over stdio) server exposing NotchMate tools.
enum MCPServer {
    static func run() {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let id = obj["id"]
            let method = obj["method"] as? String ?? ""
            let params = obj["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue } // notifications
            switch method {
            case "initialize":
                let version = params["protocolVersion"] as? String ?? "2025-06-18"
                reply(id, ["protocolVersion": version,
                           "capabilities": ["tools": ["listChanged": false]],
                           "serverInfo": ["name": "notchmate", "title": "NotchMate", "version": "1.0"],
                           "instructions": String(localized: "Инструменты NotchMate: заметки Obsidian (добавить, найти), Jira (задачи, списание времени), фокус-таймер, календарь, музыка, сообщения в вырезе MacBook.")])
            case "ping":
                reply(id, [:])
            case "tools/list":
                reply(id, ["tools": NotchMateToolCatalog.tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                if let r = BridgeClient.post("/tool", ["name": name, "arguments": arguments], timeout: 60) {
                    reply(id, ["content": [["type": "text", "text": r["text"] as? String ?? ""]], "isError": r["isError"] as? Bool ?? false])
                } else {
                    reply(id, ["content": [["type": "text", "text": String(localized: "NotchMate не запущен — откройте приложение.")]], "isError": true])
                }
            default:
                let msg: [String: Any] = ["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found: \(method)"]]
                write(msg)
            }
        }
    }

    private static func reply(_ id: Any?, _ result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        print(s)
    }
}
