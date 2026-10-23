import AppKit
import SwiftUI
import CryptoKit
import XCTest
@testable import Nano

/// What each agent's hooks let Nano do when the agent stops to ask: answer
/// from the island where the hook takes an answer, and otherwise say what the
/// agent is waiting for without pretending to answer it.
@MainActor
final class AgentInteractionParityTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let marker = "nano-agent-bridge"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NanoParityTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func payload(source: String, _ event: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["source": source, "event": event])
    }

    private func object(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any]
        )
    }

    /// A blocking request shows up in `pending` before its hook is answered.
    private func waitForPending(_ bridge: AgentHookBridge) async throws -> AgentHookBridge.PendingRequest {
        for _ in 0..<200 {
            if let request = bridge.pending.first { return request }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw XCTSkip("the bridge never queued the request")
    }

    // MARK: - Devin approvals

    func testDevinDecisionEncoding() throws {
        let adapter = try XCTUnwrap(AgentProviderRegistry.adapter(for: .devin))
        XCTAssertTrue(adapter.controls.contains(.approvePermission))
        XCTAssertEqual(
            adapter.permissionResponse(allowed: true) as? [String: String],
            ["decision": "approve"]
        )
        XCTAssertEqual(
            adapter.permissionResponse(allowed: false, message: "Not now") as? [String: String],
            ["decision": "block", "reason": "Not now"]
        )
        // The island's card has to outlive the five seconds the old entry had.
        XCTAssertEqual(adapter.hooks.first { $0.event == "PermissionRequest" }?.timeout, 86_400)
    }

    func testDevinPermissionIsAnsweredFromTheIsland() async throws {
        let bridge = AgentHookBridge()
        // The payload Devin sent in the live run, plus the bridge's project_dir.
        let data = try JSONSerialization.data(withJSONObject: [
            "source": "devin",
            "project_dir": "/tmp/Site",
            "event": [
                "hook_event_name": "PermissionRequest",
                "tool_name": "exec",
                "tool_input": ["command": "touch marker"],
                "tool_use_id": "toolu_01",
                "session_id": "mango-delphinium",
                "prompt_id": "b0f174af",
            ],
        ] as [String: Any])

        let reply = Task { await bridge.handle(data) }
        let request = try await waitForPending(bridge)
        XCTAssertEqual(request.kind, .permission)
        XCTAssertTrue(request.respondsThroughBridge)
        XCTAssertEqual(request.title, "exec")
        XCTAssertEqual(request.detail, "touch marker")
        XCTAssertEqual(request.preview, .command("touch marker"))
        XCTAssertEqual(request.projectName, "Site")

        bridge.resolvedCardLinger = .milliseconds(50)
        bridge.respond(to: request.id, choice: 1)
        let approved = try object(await reply.value)
        XCTAssertEqual(approved["decision"] as? String, "approve")
        // The card stays up long enough to say the tap landed, then leaves.
        XCTAssertEqual(bridge.pending.first?.outcome, .allowed)
        XCTAssertEqual(bridge.recentDecisions["mango-delphinium"]?.allowed, true)
        try await waitForEmpty(bridge)

        let second = Task { await bridge.handle(data) }
        bridge.respond(to: try await waitForPending(bridge).id, choice: 0)
        let blocked = try object(await second.value)
        XCTAssertEqual(blocked["decision"] as? String, "block")
        XCTAssertEqual(bridge.pending.first?.outcome, .denied)
        XCTAssertEqual(bridge.recentDecisions["mango-delphinium"]?.allowed, false)
        try await waitForEmpty(bridge)
    }

    /// The host answered first and the agent killed the hook: the card says
    /// so instead of vanishing, and the row gets no "from Nano" note.
    func testPermissionAnsweredElsewhereIsSaidBeforeTheCardLeaves() async throws {
        let bridge = AgentHookBridge()
        bridge.resolvedCardLinger = .milliseconds(50)
        let data = try JSONSerialization.data(withJSONObject: [
            "source": "claude",
            "hook_pids": [2_000_000_000],
            "event": [
                "hook_event_name": "PermissionRequest", "session_id": "claude-9", "cwd": "/tmp/Site",
                "tool_name": "Bash", "tool_input": ["command": "rm -rf build"],
            ],
        ] as [String: Any])

        let reply = Task { await bridge.handle(data) }
        _ = try await waitForPending(bridge)
        let answer = await reply.value
        XCTAssertNil(answer)
        XCTAssertEqual(bridge.pending.first?.outcome, .answeredElsewhere)
        XCTAssertNil(bridge.recentDecisions["claude-9"])
        try await waitForEmpty(bridge)
    }

    private func waitForEmpty(_ bridge: AgentHookBridge) async throws {
        for _ in 0..<200 where !bridge.pending.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(bridge.pending.isEmpty)
    }

    func testDevinToolNamesGetAPreview() {
        XCTAssertEqual(
            AgentHookBridge.preview(tool: "exec", input: ["command": "ls"]),
            .command("ls")
        )
        XCTAssertEqual(
            AgentHookBridge.preview(tool: "write", input: ["path": "/tmp/a/notes.md", "content": "one\ntwo"]),
            .diff(path: "notes.md", removed: [], added: ["one", "two"], startLine: 1)
        )
        XCTAssertEqual(
            AgentHookBridge.preview(
                tool: "edit",
                input: ["file_path": "/tmp/a/main.swift", "old_string": "a", "new_string": "b"]
            ),
            .diff(path: "main.swift", removed: ["a"], added: ["b"])
        )
        // An edit with no before and after has nothing to draw.
        XCTAssertEqual(AgentHookBridge.preview(tool: "apply_patch", input: ["path": "/tmp/a"]), .none)
        XCTAssertEqual(AgentHookBridge.preview(tool: "edit", input: ["path": "/tmp/a"]), .none)
        XCTAssertEqual(
            AgentHookBridge.preview(tool: "webfetch", input: ["url": "https://example.com"]),
            .command("https://example.com")
        )
    }

    // MARK: - Questions

    func testQuestionToolsPerProvider() {
        XCTAssertEqual(AgentProviderRegistry.adapter(for: .claude)?.questionTool, "AskUserQuestion")
        XCTAssertEqual(AgentProviderRegistry.adapter(for: .codex)?.questionTool, "request_user_input")
        XCTAssertEqual(AgentProviderRegistry.adapter(for: .devin)?.questionTool, "ask_user_question")
        XCTAssertEqual(AgentProviderRegistry.adapter(for: .grok)?.questionTool, "ask_user_question")
        XCTAssertEqual(AgentProviderRegistry.adapter(for: .opencode)?.questionTool, "question")
        XCTAssertNil(AgentProviderRegistry.adapter(for: .cursor)?.questionTool)
    }

    func testUnanswerableQuestionNamesItsProvider() {
        let none = AgentHookBridge.unanswerableQuestionRequest(
            input: [:], event: [:], source: "grok", sessionID: "s1"
        )
        XCTAssertEqual(none.title, "Grok has a question for you")
        let several = AgentHookBridge.unanswerableQuestionRequest(
            input: ["questions": [["question": "One?"], ["question": "Two?"]]],
            event: [:], source: "codex", sessionID: "s1"
        )
        XCTAssertEqual(several.title, "Codex has 2 questions for you")
        XCTAssertEqual(several.detail, "One?")
    }

    /// Devin, Grok and Codex report their question tool, but no hook reply
    /// answers it, so each gets a card and never a blocked hook.
    func testQuestionsThatOnlyTheHostCanAnswerShowAPassiveCard() async throws {
        let question: [String: Any] = ["questions": [[
            "question": "Pick one",
            "options": [
                ["label": "Choice A", "description": "Select Choice A"],
                ["label": "Choice B", "description": "Select Choice B"],
            ],
        ]]]
        let cases: [(source: String, event: [String: Any])] = [
            ("devin", [
                "hook_event_name": "PreToolUse", "session_id": "devin-1",
                "tool_name": "ask_user_question", "tool_input": question,
            ]),
            // Grok's own payload shape, as captured from the CLI.
            ("claude", [
                "hookEventName": "pre_tool_use", "hook_event_name": "PreToolUse",
                "sessionId": "grok-1", "session_id": "grok-1",
                "workspaceRoot": "/tmp/Site", "cwd": "/tmp/Site",
                "toolName": "ask_user_question", "tool_name": "ask_user_question",
                "toolInput": question, "tool_input": question,
            ]),
            ("codex", [
                "hook_event_name": "PreToolUse", "session_id": "codex-1", "cwd": "/tmp/Site",
                "tool_name": "request_user_input", "tool_input": question,
            ]),
        ]

        for (source, event) in cases {
            let bridge = AgentHookBridge()
            var cards: [AgentHookBridge.PendingRequest] = []
            bridge.didRequestAttention = { cards.append($0) }

            let reply = await bridge.handle(try payload(source: source, event))

            XCTAssertNil(reply, "\(source) must not be held or answered")
            XCTAssertTrue(bridge.pending.isEmpty)
            let card = try XCTUnwrap(cards.first, "no card for \(source)")
            XCTAssertEqual(cards.count, 1)
            XCTAssertEqual(card.kind, .question)
            XCTAssertEqual(card.title, "Pick one")
            XCTAssertFalse(card.respondsThroughBridge)
            XCTAssertTrue(card.options.isEmpty)
        }
    }

    func testOtherToolsNeverBecomeQuestionCards() async throws {
        let bridge = AgentHookBridge()
        var cards: [AgentHookBridge.PendingRequest] = []
        bridge.didRequestAttention = { cards.append($0) }
        for (source, tool) in [("cursor", "Shell"), ("devin", "exec"), ("codex", "shell"), ("kimi", "Bash")] {
            let reply = await bridge.handle(try payload(source: source, [
                "hook_event_name": "PreToolUse", "session_id": "s-\(source)",
                "tool_name": tool, "tool_input": ["command": "ls"],
            ]))
            XCTAssertNil(reply)
        }
        XCTAssertTrue(cards.isEmpty)
        XCTAssertTrue(bridge.pending.isEmpty)
    }

    func testClaudeQuestionIsStillAnsweredThroughUpdatedInput() async throws {
        let bridge = AgentHookBridge()
        let input: [String: Any] = ["questions": [[
            "question": "Ship now?", "header": "Release",
            "options": [["label": "Yes"], ["label": "No"]],
        ]]]
        let data = try payload(source: "claude", [
            "hook_event_name": "PreToolUse", "session_id": "claude-1",
            "tool_name": "AskUserQuestion", "tool_input": input,
        ])

        let reply = Task { await bridge.handle(data) }
        let request = try await waitForPending(bridge)
        XCTAssertEqual(request.options.map(\.label), ["Yes", "No"])
        bridge.respond(to: request.id, choice: 1)

        let answered = try object(await reply.value)
        let output = try XCTUnwrap(answered["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        let updated = try XCTUnwrap(output["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["answers"] as? [String: String], ["Ship now?": "No"])
    }

    // MARK: - OpenCode questions

    func testOpenCodeQuestionRoundTrip() async throws {
        let bridge = AgentHookBridge()
        let data = try payload(source: "opencode", [
            "hook_event_name": "PreToolUse", "session_id": "ses_1", "cwd": "/tmp/Site",
            "tool_name": "question",
            "tool_input": ["questions": [[
                "question": "Which database?", "header": "Storage",
                "options": [
                    ["label": "SQLite", "description": "One file"],
                    ["label": "Postgres", "description": "A server"],
                ],
            ]]],
        ])

        let reply = Task { await bridge.handle(data) }
        let request = try await waitForPending(bridge)
        XCTAssertEqual(request.kind, .question)
        XCTAssertEqual(request.title, "Which database?")
        XCTAssertEqual(request.options.map(\.label), ["SQLite", "Postgres"])
        bridge.respond(to: request.id, choice: 1)

        // The plugin wraps this label into OpenCode's `answers: [[label]]`.
        let answered = try object(await reply.value)
        XCTAssertEqual(answered as? [String: String], ["answer": "Postgres"])
    }

    func testOpenCodeMultipleChoiceQuestionStaysInOpenCode() async throws {
        let bridge = AgentHookBridge()
        var cards: [AgentHookBridge.PendingRequest] = []
        bridge.didRequestAttention = { cards.append($0) }

        let reply = await bridge.handle(try payload(source: "opencode", [
            "hook_event_name": "PreToolUse", "session_id": "ses_1",
            "tool_name": "question",
            "tool_input": ["questions": [[
                "question": "Which pages?", "multiple": true,
                "options": [["label": "Home"], ["label": "Docs"]],
            ]]],
        ]))

        XCTAssertNil(reply)
        XCTAssertEqual(cards.first?.respondsThroughBridge, false)
        XCTAssertEqual(cards.first?.title, "Which pages?")
    }

    /// Answered in OpenCode itself: the plugin reports it, and the island's
    /// card must let go instead of waiting out its day-long timeout.
    func testOpenCodeAnswerGivenInTheHostReleasesTheCard() async throws {
        let bridge = AgentHookBridge()
        var resumed: [String] = []
        bridge.didResumeSession = { resumed.append($0) }
        let data = try payload(source: "opencode", [
            "hook_event_name": "PreToolUse", "session_id": "ses_1",
            "tool_name": "question",
            "tool_input": ["questions": [[
                "question": "Which database?",
                "options": [["label": "SQLite"], ["label": "Postgres"]],
            ]]],
        ])
        let reply = Task { await bridge.handle(data) }
        _ = try await waitForPending(bridge)

        _ = await bridge.handle(try payload(source: "opencode", [
            "hook_event_name": "PostToolUse", "session_id": "ses_1", "tool_name": "question",
        ]))

        let answer = await reply.value
        XCTAssertNil(answer)
        XCTAssertTrue(bridge.pending.isEmpty)
        XCTAssertEqual(resumed, ["ses_1"])
    }

    // MARK: - Waiting cards

    /// Kimi announces a permission prompt and takes no answer from the hook.
    func testKimiPermissionRequestIsACardAndNeverBlocks() async throws {
        let bridge = AgentHookBridge()
        var cards: [AgentHookBridge.PendingRequest] = []
        var resumed: [String] = []
        bridge.didRequestAttention = { cards.append($0) }
        bridge.didResumeSession = { resumed.append($0) }

        let reply = await bridge.handle(try payload(source: "kimi", [
            "hook_event_name": "PermissionRequest", "session_id": "kimi-1", "cwd": "/tmp/Site",
            "tool_name": "Bash", "tool_input": ["command": "rm -rf build"],
        ]))

        XCTAssertNil(reply)
        XCTAssertTrue(bridge.pending.isEmpty, "nothing waits on the island")
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.kind, .permission)
        XCTAssertFalse(card.respondsThroughBridge)
        XCTAssertTrue(card.options.isEmpty)
        XCTAssertEqual(card.title, "Kimi needs approval for Bash")
        XCTAssertEqual(card.detail, "rm -rf build")
        XCTAssertEqual(card.preview, .command("rm -rf build"))
        XCTAssertEqual(card.projectName, "Site")

        // Unrelated traffic leaves the card up; the tool finishing retracts it.
        _ = await bridge.handle(try payload(source: "kimi", [
            "hook_event_name": "PreToolUse", "session_id": "kimi-1", "tool_name": "Bash",
        ]))
        XCTAssertTrue(resumed.isEmpty)
        _ = await bridge.handle(try payload(source: "kimi", [
            "hook_event_name": "PostToolUse", "session_id": "kimi-1", "tool_name": "Bash",
        ]))
        XCTAssertEqual(resumed, ["kimi-1"])
        _ = await bridge.handle(try payload(source: "kimi", [
            "hook_event_name": "Stop", "session_id": "kimi-1",
        ]))
        XCTAssertEqual(resumed, ["kimi-1"], "retracted once")
    }

    func testGrokNotificationsBecomeWaitingCards() async throws {
        // The payload Grok sent in the live run.
        let permission: [String: Any] = [
            "hookEventName": "notification", "hook_event_name": "Notification",
            "sessionId": "grok-1", "session_id": "grok-1",
            "cwd": "/tmp/Site", "workspaceRoot": "/tmp/Site",
            "permissionMode": "default", "notificationType": "permission_prompt",
            "message": "Tool permission requested", "level": "info",
        ]
        let bridge = AgentHookBridge()
        var cards: [AgentHookBridge.PendingRequest] = []
        var resumed: [String] = []
        bridge.didRequestAttention = { cards.append($0) }
        bridge.didResumeSession = { resumed.append($0) }

        let reply = await bridge.handle(try payload(source: "grok", permission))

        XCTAssertNil(reply)
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.source, "grok")
        XCTAssertEqual(card.kind, .permission)
        XCTAssertEqual(card.title, "Tool permission requested")
        XCTAssertFalse(card.respondsThroughBridge)
        XCTAssertEqual(card.projectName, "Site")

        // Approved in Grok: the tool runs and the card goes.
        _ = await bridge.handle(try payload(source: "grok", [
            "hookEventName": "post_tool_use", "hook_event_name": "PostToolUse",
            "session_id": "grok-1", "workspaceRoot": "/tmp/Site",
            "tool_name": "run_terminal_command",
        ]))
        XCTAssertEqual(resumed, ["grok-1"])

        var idle = permission
        idle["notificationType"] = "idle_prompt"
        idle["message"] = "Waiting for your input"
        let waiting = AgentHookBridge.notificationRequest(event: idle, source: "grok", sessionID: "grok-1")
        XCTAssertEqual(waiting.kind, .question)
        XCTAssertEqual(waiting.title, "Waiting for your input")
        XCTAssertFalse(waiting.respondsThroughBridge)
    }

    // MARK: - Bridge script

    /// The script is written from a Swift literal, where one lost backslash
    /// turns this line into a sed error on every hook event and an empty
    /// project directory for Devin.
    func testBridgeEscapesTheDevinProjectDirectory() throws {
        let line = try XCTUnwrap(
            AgentHookBridge.bridgeScript.split(separator: "\n").first { $0.hasPrefix("project_dir=") }
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(line)\nprintf '%s' \"$project_dir\""]
        process.environment = ["DEVIN_PROJECT_DIR": #"/tmp/My "Site"\src"#, "PATH": "/usr/bin:/bin"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            #"/tmp/My \"Site\"\\src"#
        )
        XCTAssertEqual(errors.fileHandleForReading.readDataToEndOfFile(), Data())
        XCTAssertEqual(process.terminationStatus, 0)
    }

    // MARK: - Installed hooks catch up

    func testDevinInstallUpgradesAnEntryNanoWroteEarlier() throws {
        let nano = "/bin/sh -c '[ -x \"/tmp/bin/\(marker)\" ] && \"/tmp/bin/\(marker)\" --source devin; exit 0'"
        let url = root.appendingPathComponent("config.json")
        let existing: [String: Any] = ["hooks": [
            "PermissionRequest": [
                ["hooks": [["type": "command", "command": "/Users/x/.orca/devin-hook.sh", "timeout": 10]]],
                ["hooks": [["type": "command", "command": nano, "timeout": 5]]],
            ],
            "Stop": [["hooks": [["type": "command", "command": nano, "timeout": 5]]]],
        ]]
        try JSONSerialization.data(withJSONObject: existing).write(to: url)

        AgentHookBridge.installDevinHooks(at: url, bridge: "/tmp/bin/\(marker)")

        let root = try object(try Data(contentsOf: url))
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let permission = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(permission.count, 2, "upgraded in place, not appended again")
        func handler(_ entry: [String: Any]) -> [String: Any]? {
            (entry["hooks"] as? [[String: Any]])?.first
        }
        XCTAssertEqual(handler(permission[0])?["command"] as? String, "/Users/x/.orca/devin-hook.sh")
        XCTAssertEqual(handler(permission[0])?["timeout"] as? Int, 10)
        XCTAssertEqual(handler(permission[1])?["command"] as? String, nano)
        XCTAssertEqual(handler(permission[1])?["timeout"] as? Int, 86_400)

        let question = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(question.count, 1)
        XCTAssertEqual(question[0]["matcher"] as? String, "^ask_user_question$")
        XCTAssertEqual((hooks["Stop"] as? [[String: Any]])?.count, 1)

        let installed = try Data(contentsOf: url)
        AgentHookBridge.installDevinHooks(at: url, bridge: "/tmp/bin/\(marker)")
        XCTAssertEqual(try Data(contentsOf: url), installed, "second install is a no-op")
    }

    func testOwnedPluginReplacesOnlyVersionsNanoShipped() throws {
        let url = root.appendingPathComponent("nano-opencode-plugin.js")
        let old = Data("old plugin".utf8)
        let new = Data("new plugin".utf8)
        func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        try old.write(to: url)
        AgentHookBridge.installOwnedPlugin(new, at: url, superseding: [sha256(Data("other".utf8))])
        XCTAssertEqual(try Data(contentsOf: url), old, "an unknown file is the user's")

        AgentHookBridge.installOwnedPlugin(new, at: url, superseding: [sha256(old)])
        XCTAssertEqual(try Data(contentsOf: url), new)

        AgentHookBridge.installOwnedPlugin(old, at: url)
        XCTAssertEqual(try Data(contentsOf: url), new, "without a known hash nothing is replaced")
    }

    // MARK: - Display

    func testModelNamesReadAsModels() {
        let expected: [(String, String)] = [
            ("claude-opus-5-20260101", "Opus 5"),
            ("gpt-5.6-terra", "GPT 5.6 Terra"),
            ("fusion-claude-opus-5-5-medium-sidekick-swe-2-medium", "Opus 5.5 + SWE 2"),
            ("fusion-claude-fable-5-1-medium-sidekick-swe-2-high", "Fable 5.1 + SWE 2"),
            ("fusion-gpt-6-1-sol-low-fast-sidekick-gpt-5-6-luna-high-priority", "GPT 6.1 Sol + GPT 5.6 Luna"),
            ("fusion-gpt-6-sol-medium-fast-sidekick-glm-5-2", "GPT 6 Sol + GLM 5.2"),
            ("anthropic/claude-sonnet-4.5", "Sonnet 4.5"),
            ("kilo/claude-sonnet-4.5", "Sonnet 4.5"),
            ("qwen3-coder-plus", "Qwen3 Coder Plus"),
            ("gpt-4o", "GPT 4o"),
            ("gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite"),
            // Unchanged behaviour.
            ("Cursor Grok 4.6", "Grok 4.6"),
            ("fable-5-thinking-high", "Fable 5"),
            ("claude-opus-5-5", "Opus 5.5"),
            ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
        ]
        for (raw, name) in expected {
            XCTAssertEqual(AgentModuleView.modelName(raw), name, raw)
        }
        XCTAssertNotNil(AgentModuleView.fusionPair("fusion-claude-opus-5-5-medium-sidekick-swe-2-medium"))
        XCTAssertNil(AgentModuleView.fusionPair("claude-opus-5-5"))
    }

    /// Agents found on disk run in a terminal; an editor that happens to be
    /// open is not where their session lives.
    func testDiskOnlyAgentsJumpToTheTerminalOrTheFolder() {
        func runtime(terminal: Bool) -> AgentSessionJump.Runtime {
            AgentSessionJump.Runtime(
                t3Running: true, cursorRunning: true, claudeRunning: false, codexRunning: false,
                t3Installed: true, cursorInstalled: true, claudeInstalled: true, codexInstalled: true,
                terminalRunning: terminal
            )
        }
        for provider in [AgentProviderID.cline, .qwen, .kilo, .goose] {
            let session = AgentSession(
                id: "disk-\(provider.rawValue)", provider: provider,
                projectName: "Site", lastActivityAt: Date()
            )
            XCTAssertEqual(AgentSessionJump.host(for: session, runtime: runtime(terminal: true)), .terminal)
            XCTAssertEqual(AgentSessionJump.host(for: session, runtime: runtime(terminal: false)), .folder)
        }
    }
}

@MainActor
final class AgentApprovalCopyTests: XCTestCase {
    func testHeadlinesNameTheActionNotTheToolID() {
        XCTAssertEqual(
            AgentApprovalCopy.headline(provider: "Claude", tool: "ExitPlanMode", preview: .plan("1. Do it")),
            "Claude wants you to approve a plan"
        )
        XCTAssertEqual(
            AgentApprovalCopy.headline(provider: "Claude", tool: "Bash", preview: .command("ls")),
            "Claude wants to run a command"
        )
        XCTAssertEqual(
            AgentApprovalCopy.headline(provider: "Claude", tool: "Edit", preview: .diff(path: "main.swift", removed: ["a"], added: ["b"])),
            "Claude wants to edit main.swift"
        )
        XCTAssertEqual(
            AgentApprovalCopy.headline(provider: "Claude", tool: "mcp__slackbot__post_message", preview: .none),
            "Claude wants to use Slackbot: post message"
        )
        XCTAssertEqual(AgentApprovalCopy.optionLabel(.init(id: 1, label: "Allow once"), preview: .plan("x")), "Approve plan")
        XCTAssertEqual(AgentApprovalCopy.diffSummary(removed: 1, added: 2), "2 lines added, 1 removed")
    }

    func testAnEditKnowsWhereItLandsInTheFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("NanoLine-\(UUID().uuidString).swift")
        try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let preview = AgentHookBridge.preview(
            tool: "Edit",
            input: ["file_path": file.path, "old_string": "three", "new_string": "3"]
        )
        guard case let .diff(_, _, _, startLine) = preview else { return XCTFail("no diff") }
        XCTAssertEqual(startLine, 3)
    }

    func testMCPToolsShowTheirArguments() {
        let preview = AgentHookBridge.preview(tool: "mcp__slackbot__post_message", input: ["channel": "general", "text": "hi"])
        XCTAssertEqual(preview, .arguments(["channel: \"general\"", "text: \"hi\""]))
    }

    func testTurnRuntimeTicksWhileWorkingAndFreezesWhenDone() {
        let now = Date()
        var session = AgentSession(id: "t", provider: .claude, projectName: "Nano", lastActivityAt: now)
        XCTAssertNil(session.turnRuntime(now: now))
        session.turnStartedAt = now.addingTimeInterval(-252)
        session.isActive = true
        XCTAssertEqual(session.turnRuntime(now: now), "4m 12s")
        session.isActive = false
        session.finishedAt = now.addingTimeInterval(-200)
        XCTAssertEqual(session.turnRuntime(now: now), "52s")
        session.finishedAt = nil
        XCTAssertNil(session.turnRuntime(now: now))
    }

    func testLongChainedCommandsBreakAtTheirJoins() {
        let command = "cd ~/Coding/atlas && rm -rf node_modules/.cache dist && pnpm install --frozen-lockfile && pnpm -r build"
        XCTAssertEqual(AgentApprovalCopy.readableCommand(command).split(separator: "\n").count, 4)
    }
}

/// Renders the approval cards and session list to /tmp/nano-shots.
/// `TEST_RUNNER_NANO_SNAPSHOTS=1 xcodebuild … -only-testing:NanoTests/AgentApprovalSnapshots`
@MainActor
final class AgentApprovalSnapshots: XCTestCase {
    func testRenderApprovals() async throws {
        guard ProcessInfo.processInfo.environment["NANO_SNAPSHOTS"] == "1" else { throw XCTSkip("Snapshots run on request") }
        let defaults = UserDefaults(suiteName: "nano-shots-\(UUID().uuidString)")!
        let settings = NanoSettings(defaults: defaults)
        let viewModel = IslandViewModel(settings: settings, trayStorageURL: nil)
        let bridge = viewModel.hookBridge

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("OnboardingFlow.swift")
        try (Array(repeating: "// line", count: 532) + ["let delay = 1.2", "done()"]).joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        func send(_ id: String, _ tool: String, _ input: [String: Any], cwd: String) {
            let data = try! JSONSerialization.data(withJSONObject: [
                "source": "claude",
                "event": ["hook_event_name": "PermissionRequest", "tool_name": tool, "tool_input": input,
                          "session_id": id, "cwd": cwd],
            ] as [String: Any])
            Task { _ = await bridge.handle(data) }
        }
        send("s1", "Bash", ["command": "cd ~/Coding/atlas && rm -rf node_modules/.cache dist && pnpm install --frozen-lockfile && pnpm -r build && pnpm test --filter @atlas/core -- --runInBand"], cwd: "/Users/me/atlas")
        send("s2", "Edit", ["file_path": file.path, "old_string": "let delay = 1.2", "new_string": "let written = try installer.install()\nstate = written ? .connected : .failed"], cwd: "/Users/me/North-Star")
        send("s3", "mcp__slackbot__post_message", ["channel": "general", "text": "Deploy finished"], cwd: "/Users/me/atlas")
        for _ in 0..<200 where bridge.pending.count < 3 { try await Task.sleep(for: .milliseconds(10)) }

        let now = Date()
        func state(_ id: String, prompt: String, working: Bool, finished: Date? = nil, ago: TimeInterval) -> AgentHookBridge.LiveSessionState {
            var state = AgentHookBridge.LiveSessionState(sessionID: id, source: "claude", firstSeen: now.addingTimeInterval(-3600), lastEventAt: now.addingTimeInterval(-ago), isWorking: working)
            state.lastUserPrompt = prompt
            state.turnStartedAt = now.addingTimeInterval(-ago - 252)
            state.finishedAt = finished
            state.workingDirectory = "/Users/me/North-Star"
            return state
        }
        viewModel.sessionStore.applyHookState([
            "w1": state("w1", prompt: "can you check the queue", working: false, ago: 30),
            "a1": state("a1", prompt: "The plan is written to docs/plans/connect-ade.md", working: true, ago: 5),
            "d1": state("d1", prompt: "after youre done, lets build at the bottom of settings", working: false, finished: now.addingTimeInterval(-240), ago: 240),
        ], now: now)
        viewModel.sessionStore.applyLiveSignals([:], waiting: ["w1"])

        let out = URL(fileURLWithPath: "/tmp/nano-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot<V: View>(_ view: V, width: CGFloat, name: String, wait: TimeInterval = 1.2) throws {
            let hosting = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
                .background(Color.black).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: max(hosting.fittingSize.height, 40)), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(wait))
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
        }

        try shot(AgentModuleView(
            service: viewModel.agentService, settings: settings, ledger: viewModel.tokenLedger,
            sessions: viewModel.sessionStore, hooks: bridge, showingUsage: false, usageWindow: .constant(.today)
        ).padding(14), width: 760, name: "agents-module")

        // The working orb, large enough to judge its dots.
        try shot(HStack(spacing: 24) {
            AgentWorkingOrb(diameter: 60)
            AgentWorkingOrb(diameter: 15)
        }.padding(20), width: 160, name: "working-orb")

        // One card alone, without the scrolling stack.
        let others = Array(bridge.pending.dropFirst())
        others.forEach { bridge.respond(to: $0.id, choice: 0) }
        try shot(AgentModuleView(
            service: viewModel.agentService, settings: settings, ledger: viewModel.tokenLedger,
            sessions: viewModel.sessionStore, hooks: bridge, showingUsage: false, usageWindow: .constant(.today)
        ).padding(14), width: 760, name: "agents-module-one")

        for (index, request) in bridge.pending.enumerated() {
            let attention = IslandAgentAttention(request)
            try shot(IslandNotificationView(notification: .agent(attention), settings: settings, viewModel: viewModel, ignoresNotch: true, revealsImmediately: true)
                .frame(height: attention.cardHeight), width: IslandAgentAttention.cardWidth, name: "island-card-\(index)", wait: 3)
        }
        bridge.pending.forEach { bridge.respond(to: $0.id, choice: 0) }
    }
}
