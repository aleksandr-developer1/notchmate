import XCTest
import AppKit
import SwiftUI
@testable import NotchMate

final class AgentMonitorTests: XCTestCase {
    @MainActor
    func testWaitingMessageUsesNotificationOrPermissionTool() {
        XCTAssertEqual(AgentMonitor.waitingMessage(["message": "  Choose an option  "]), "Choose an option")
        XCTAssertTrue(AgentMonitor.waitingMessage(["hook_event_name": "PermissionRequest", "tool_name": "Bash"])?.contains("Bash") == true)
        XCTAssertNil(AgentMonitor.waitingMessage(["message": "  "]))
    }

    func testQuestionResponsePreservesInputAndCarriesEveryAnswer() throws {
        let input: [String: Any] = ["questions": [["question": "Where?", "options": [["label": "Here"], ["label": "There"]], "multiSelect": true]], "extra": "kept"]
        let request = try XCTUnwrap(AgentRequest(payload: ["request_id": "one", "agent": "claude", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": input]))
        let output = try XCTUnwrap(request.response(allow: true, answers: ["Where?": "Here, There"])["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        let updated = try XCTUnwrap(output["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["extra"] as? String, "kept")
        XCTAssertEqual((updated["answers"] as? [String: String])?["Where?"], "Here, There")
    }

    func testMalformedQuestionsAndInteractivePermissionFallBack() {
        let payload: [String: Any] = ["request_id": "one", "agent": "claude", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Missing options"]]]]
        XCTAssertNil(AgentRequest(payload: payload))
        var permission = payload
        permission["hook_event_name"] = "PermissionRequest"
        XCTAssertNil(AgentRequest(payload: permission))
    }

    func testCodexQuestionUsesQuestionIDsAndAcceptsFreeText() throws {
        let payload: [String: Any] = ["request_id": "codex-1", "agent": "codex", "hook_event_name": "CodexUserInput", "tool_name": "AskUserQuestion", "tool_input": ["questions": [["id": "choice", "question": "Choose", "options": [["label": "One"]]], ["id": "secret", "question": "Secret", "isSecret": true]]]]
        let request = try XCTUnwrap(AgentRequest(payload: payload))
        XCTAssertTrue(request.questions[1].secret)
        let result = request.response(allow: true, answers: ["Choose": "One", "Secret": "value"])
        let answers = try XCTUnwrap(result["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["choice"]?["answers"], ["One"])
        XCTAssertEqual(answers["secret"]?["answers"], ["value"])
    }

    func testCodexOnlyInterceptsMatchingHumanReviewer() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let payload: [String: Any] = ["transcript_path": url.path, "session_id": "s", "turn_id": "t"]
        func write(_ reviewer: String, turn: String = "t") throws {
            try "{\"type\":\"session_meta\",\"payload\":{\"id\":\"s\"}}\n{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"\(turn)\",\"approvals_reviewer\":\"\(reviewer)\"}}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        try write("user")
        XCTAssertTrue(CodexReview.isUser(payload))
        try write("auto_review")
        XCTAssertFalse(CodexReview.isUser(payload))
        try write("user", turn: "other")
        XCTAssertFalse(CodexReview.isUser(payload))
    }

    func testCodexHookQuestionsAnswerThroughDenyReason() throws {
        // Payloads recorded from Codex CLI hooks (request_user_input in Plan mode, request_user_input_async otherwise).
        let sync: [String: Any] = ["request_id": "s", "agent": "codex", "hook_event_name": "PreToolUse", "tool_name": "request_user_input", "session_id": "x",
                                   "tool_input": ["questions": [["header": "License", "id": "license_choice", "question": "Which license should the LICENSE file use?",
                                                                 "options": [["label": "MIT", "description": "Use the MIT License."], ["label": "Apache-2.0", "description": "Use the Apache License 2.0."]]]]]]
        let request = try XCTUnwrap(AgentRequest(payload: sync))
        XCTAssertEqual(request.kind, .question)
        XCTAssertEqual(request.questions.first?.header, "License")
        XCTAssertTrue(request.questions.first?.allowsCustom == true)
        XCTAssertEqual(request.waitingText, "Which license should the LICENSE file use?")
        let output = try XCTUnwrap(request.response(allow: true, answers: ["Which license should the LICENSE file use?": "MIT"])["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["permissionDecision"] as? String, "deny")
        let reason = try XCTUnwrap(output["permissionDecisionReason"] as? String)
        XCTAssertTrue(reason.contains(#"{"answers":{"license_choice":{"answers":["MIT"]}}}"#))
        XCTAssertNil(output["updatedInput"])

        let async: [String: Any] = ["request_id": "a", "agent": "codex", "hook_event_name": "PreToolUse", "tool_name": "request_user_input_async",
                                    "tool_input": ["questions": [["title": "Should I add an MIT or Apache-2.0 LICENSE file?", "options": ["MIT", "Apache-2.0"]]]]]
        let asyncRequest = try XCTUnwrap(AgentRequest(payload: async))
        XCTAssertEqual(asyncRequest.questions.first?.options.map(\.label), ["MIT", "Apache-2.0"])

        var secret = sync
        secret["tool_input"] = ["questions": [["id": "token", "question": "Token?", "isSecret": true]]]
        XCTAssertNil(AgentRequest(payload: secret))
        var other = sync
        other["tool_name"] = "update_plan"
        XCTAssertNil(AgentRequest(payload: other))
    }

    @MainActor
    func testPendingRequestMarksSessionWaiting() async throws {
        guard Settings.shared.pluginEnabled(.agents), Settings.shared.agentStatusEnabled else { throw XCTSkip("Agent integration disabled") }
        let monitor = AgentMonitor()
        let payload: [String: Any] = ["request_id": "w", "agent": "codex", "hook_event_name": "PreToolUse", "tool_name": "request_user_input", "session_id": "codex-s", "cwd": "/tmp/demo",
                                      "tool_input": ["questions": [["id": "q", "question": "Proceed?", "options": [["label": "Yes"]]]]]]
        let task = Task { await monitor.waitForRequest(payload) }
        while monitor.requests.isEmpty { await Task.yield() }
        XCTAssertEqual(monitor.sessions["codex-s"]?.state, .waiting)
        XCTAssertEqual(monitor.sessions["codex-s"]?.waitingMessage, "Proceed?")
        // The plain tool hook fired alongside must not hide the question.
        monitor.handle(["agent": "codex", "hook_event_name": "PreToolUse", "session_id": "codex-s", "cwd": "/tmp/demo", "tool_name": "request_user_input"])
        XCTAssertEqual(monitor.sessions["codex-s"]?.state, .waiting)
        let request = try XCTUnwrap(monitor.requests.first)
        monitor.finishRequest(request.id, response: request.response(allow: true, answers: ["Proceed?": "Yes"]))
        _ = await task.value
        XCTAssertEqual(monitor.sessions["codex-s"]?.state, .working)
    }

    @MainActor
    func testPendingRequestReturnsOnlyItsOwnDecision() async throws {
        guard Settings.shared.pluginEnabled(.agents), Settings.shared.agentStatusEnabled else { throw XCTSkip("Agent integration disabled") }
        let monitor = AgentMonitor()
        func payload(_ id: String) -> [String: Any] {
            ["request_id": id, "agent": "claude", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "echo hello"]]
        }
        let one = Task { await monitor.waitForRequest(payload("one")) }
        let two = Task { await monitor.waitForRequest(payload("two")) }
        while monitor.requests.count != 2 { await Task.yield() }
        let second = try XCTUnwrap(monitor.requests.first { $0.id == "two" })
        monitor.finishRequest("two", response: second.response(allow: false))
        let result = await two.value
        XCTAssertEqual(((result["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: String])?["behavior"], "deny")
        XCTAssertEqual(monitor.requests.map(\.id), ["one"])
        monitor.finishRequest("one", response: [:])
        let passed = await one.value
        XCTAssertTrue(passed.isEmpty)
    }

    @MainActor
    func testRequestCardsRender() throws {
        _ = NSApplication.shared
        let payloads: [(String, [String: Any])] = [
            ("question", ["request_id": "q", "agent": "claude", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "cwd": "/tmp/dock", "host_bundle_id": "com.apple.Terminal",
                          "tool_input": ["questions": [["question": "Какой вариант выбрать?", "header": "Подход", "options": [["label": "Первый", "description": "Быстро и просто"], ["label": "Второй", "description": "Больше возможностей"]]],
                                                       ["question": "Добавить тесты?", "header": "Тесты", "options": [["label": "Да"], ["label": "Нет"]]]]]]),
            ("plan", ["request_id": "p", "agent": "claude", "hook_event_name": "PreToolUse", "tool_name": "ExitPlanMode", "cwd": "/tmp/dock",
                      "tool_input": ["plan": "## План\n1. Изучить **код**\n2. Сделать карточку\n- проверить `тесты`\n\nГотово."]]),
            ("permission", ["request_id": "b", "agent": "codex", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "cwd": "/tmp/dock",
                            "tool_input": ["command": "swift test --filter AgentMonitorTests", "description": "Запустить тесты"]]),
        ]
        for (name, payload) in payloads {
            let request = try XCTUnwrap(AgentRequest(payload: payload))
            let view = AgentRequestView(request: request).environmentObject(AgentMonitor()).environmentObject(NotchViewModel(env: AppEnvironment.shared))
                .frame(width: 560, height: 300).background(Color.black).preferredColorScheme(.dark)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 560, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderBack(nil)
            defer { window.close() }
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let dir = ProcessInfo.processInfo.environment["NOTCHMATE_REQUEST_PREVIEW_DIR"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
    }

    @MainActor
    func testBridgeReturnsDeferredDecision() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("bridge.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bridge = LocalBridge(infoURL: url)
        bridge.onRequest = { payload in
            try? await Task.sleep(for: .milliseconds(50))
            return ["request": payload["request_id"] as? String ?? ""]
        }
        bridge.start()
        defer { bridge.stop() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: url.path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let result = await Task.detached { BridgeClient.post("/request", ["request_id": "test"], timeout: 2, infoURL: url) }.value
        XCTAssertEqual(result?["request"] as? String, "test")
    }
}
