import XCTest
@testable import Nano

/// Removal is the half of the bridge that can destroy something the user owns.
/// These configs are shared with other tools and hand-edited, so the bar is not
/// "Nano's hooks are gone" but "nothing else moved".
final class AgentHookUninstallTests: XCTestCase {
    private var root: URL!
    private let marker = "nano-agent-bridge"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NanoHookTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func json(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func nanoCommand(_ source: String) -> String {
        "/bin/sh -c '[ -x \"/tmp/bin/\(marker)\" ] && \"/tmp/bin/\(marker)\" --source \(source); exit 0'"
    }

    @MainActor
    func testHookInstallationPlanOnlyIncludesSelectedConfiguredProviders() throws {
        for path in [".codex", ".cursor", ".pi/agent"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        XCTAssertEqual(
            AgentHookBridge.installationProviders([.codex, .cursor, .gemini, .ollama], homeDirectory: root),
            [.codex, .cursor]
        )
        XCTAssertTrue(AgentHookBridge.installationProviders([], homeDirectory: root).isEmpty)
        XCTAssertEqual(
            AgentHookBridge.installationConfigURLs(for: [.codex], homeDirectory: root),
            [root.appendingPathComponent(".codex/hooks.json")]
        )
        XCTAssertEqual(AgentHookBridge.installationConfigURLs(for: [.pi], homeDirectory: root).count, 2)
    }

    @MainActor
    func testCursorInstallPreservesConfigurationAndIsIdempotent() throws {
        let url = try write("{\"version\":1,\"custom\":true,\"hooks\":{\"stop\":[{\"command\":\"other-tool\",\"timeout\":17}]}}", to: "cursor.json")
        let original = try Data(contentsOf: url)
        AgentHookBridge.installCursorHooks(at: url, bridge: "/tmp/bin/\(marker)")
        let installed = try Data(contentsOf: url)
        let result = try json(url)
        XCTAssertEqual(result["custom"] as? Bool, true)
        let hooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["stop"] as? [[String: Any]])
        XCTAssertEqual(stop.first?["command"] as? String, "other-tool")
        XCTAssertEqual(stop.first?["timeout"] as? Int, 17)
        // A failed Write must be able to clear the pending permission probe.
        let failure = try XCTUnwrap(hooks["postToolUseFailure"] as? [[String: Any]])
        XCTAssertTrue(failure.contains { ($0["command"] as? String)?.contains(marker) == true })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + ".nano-bak")), original)
        AgentHookBridge.installCursorHooks(at: url, bridge: "/tmp/bin/\(marker)")
        XCTAssertEqual(try Data(contentsOf: url), installed)
    }

    @MainActor
    func testCursorInstallDoesNotRewriteUnknownHookShapes() throws {
        for (index, contents) in ["{\"hooks\":[]}", "{\"hooks\":{\"stop\":\"custom\"}}", "{\"hooks\":{\"stop\":[42]}}", "not JSON"].enumerated() {
            let url = try write(contents, to: "unknown-\(index).json")
            AgentHookBridge.installCursorHooks(at: url, bridge: "/tmp/bin/\(marker)")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), contents)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".nano-bak"))
        }
    }

    // MARK: - Nested JSON (Claude, Codex, Gemini, Pi)

    func testNestedRemovalKeepsOtherToolsHooks() throws {
        let foreign: [String: Any] = [
            "hooks": [["type": "command", "command": "/usr/local/bin/other-tool", "timeout": 5]]
        ]
        let mine: [String: Any] = [
            "matcher": "*",
            "hooks": [["type": "command", "command": nanoCommand("claude"), "timeout": 5]],
        ]
        let original: [String: Any] = [
            "model": "opus",
            "permissions": ["allow": ["Bash"]],
            "hooks": [
                "PostToolUse": [foreign, mine],
                "Stop": [mine],
                "PreToolUse": [foreign],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: original)
        let url = root.appendingPathComponent("settings.json")
        try data.write(to: url)

        AgentHookBridge.removeNestedHooks(from: url)
        let result = try json(url)

        // Nothing outside `hooks` may be disturbed.
        XCTAssertEqual(result["model"] as? String, "opus")
        XCTAssertNotNil(result["permissions"])

        let hooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        // The event Nano shared with another tool keeps that tool's entry.
        let postToolUse = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(postToolUse.count, 1)
        // An event that held only Nano is removed rather than left as `[]`.
        XCTAssertNil(hooks["Stop"])
        // An event Nano never touched is untouched.
        XCTAssertNotNil(hooks["PreToolUse"])

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(marker))
    }

    func testNestedRemovalPreservesForeignHandlersWithinSharedEntry() throws {
        let foreign: [[String: Any]] = [
            ["type": "command", "command": "/usr/local/bin/other-tool", "timeout": 17],
            ["type": "prompt", "prompt": "Check the result"],
        ]
        let shared: [String: Any] = [
            "matcher": "Bash|Write",
            "customMetadata": ["owner": "fixture"],
            "hooks": [foreign[0], ["type": "command", "command": nanoCommand("claude")], foreign[1]],
        ]
        let url = root.appendingPathComponent("shared.json")
        let original = try JSONSerialization.data(withJSONObject: ["hooks": ["PostToolUse": [shared]]])
        try original.write(to: url)

        AgentHookBridge.removeNestedHooks(from: url)

        let hooks = try XCTUnwrap(try json(url)["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        var expected = shared
        expected["hooks"] = foreign
        XCTAssertEqual(entries as NSArray, [expected] as NSArray)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + ".nano-bak")), original)

        let once = try Data(contentsOf: url)
        AgentHookBridge.removeNestedHooks(from: url)
        XCTAssertEqual(try Data(contentsOf: url), once)
    }

    func testNestedRemovalPreservesUnrecognizedAndEmptyEntries() throws {
        let untouched: [[String: Any]] = [
            ["matcher": "Write", "hooks": []],
            ["matcher": "Read", "hooks": "unknown-shape"],
            ["customMetadata": true],
        ]
        let mine: [String: Any] = ["hooks": [["command": nanoCommand("codex")]]]
        let url = root.appendingPathComponent("unrecognized.json")
        try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": untouched + [mine]]]).write(to: url)

        AgentHookBridge.removeNestedHooks(from: url)

        let hooks = try XCTUnwrap(try json(url)["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(entries as NSArray, untouched as NSArray)
    }

    func testNestedRemovalLeavesCleanFileByteIdentical() throws {
        let contents = """
        {"hooks":{"Stop":[{"hooks":[{"command":"/usr/local/bin/other","type":"command"}]}]}}
        """
        let url = try write(contents, to: "clean.json")
        let before = try Data(contentsOf: url)
        let stamp = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]

        AgentHookBridge.removeNestedHooks(from: url)

        // A file holding nothing of Nano's must not be rewritten at all — a
        // rewritten config is a config a running agent may reload for nothing.
        XCTAssertEqual(try Data(contentsOf: url), before)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        XCTAssertEqual(stamp as? Date, after as? Date)
    }

    func testNestedRemovalDropsEmptyHooksKeyEntirely() throws {
        let original: [String: Any] = [
            "theme": "dark",
            "hooks": ["Stop": [["hooks": [["command": nanoCommand("pi"), "type": "command"]]]]],
        ]
        let url = root.appendingPathComponent("pi.json")
        try JSONSerialization.data(withJSONObject: original).write(to: url)

        AgentHookBridge.removeNestedHooks(from: url)
        let result = try json(url)

        XCTAssertEqual(result["theme"] as? String, "dark")
        XCTAssertNil(result["hooks"])
    }

    func testNestedRemovalIgnoresAbsentFile() {
        // Must not resurrect a config for an agent the user does not have.
        let url = root.appendingPathComponent("missing.json")
        AgentHookBridge.removeNestedHooks(from: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMalformedConfigIsNotTreatedAsAnEmptyDictionary() throws {
        let url = try write(#"{"hooks": ["#, to: "malformed.json")
        XCTAssertNil(AgentHookBridge.load(url))
        let before = try Data(contentsOf: url)
        AgentHookBridge.removeNestedHooks(from: url)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testPiExtensionUsesANanoOwnedFilename() {
        XCTAssertEqual(AgentHookBridge.piExtensionURL.lastPathComponent, "nano-agent-monitor.ts")
    }

    // MARK: - Flat JSON (Cursor)

    @MainActor
    func testCursorInstallRegistersForWritesBeforeCursorBlocks() throws {
        let original: [String: Any] = [
            "version": 1,
            "hooks": [
                "preToolUse": [["command": "/usr/local/bin/other", "timeout": 5]],
            ],
        ]
        let url = root.appendingPathComponent("cursor-install.json")
        try JSONSerialization.data(withJSONObject: original).write(to: url)

        AgentHookBridge.installCursorHooks(at: url, bridge: "/tmp/bin/\(marker)")

        let result = try json(url)
        let hooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["preToolUse"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2, "Nano must append without replacing other tools")
        let nano = try XCTUnwrap(entries.first { entry in
            (entry["command"] as? String)?.contains(marker) == true
        })
        XCTAssertEqual(nano["matcher"] as? String, "Write|Delete")
    }

    func testCursorRemovalKeepsOtherToolsHooks() throws {
        let original: [String: Any] = [
            "version": 1,
            "hooks": [
                "beforeShellExecution": [
                    ["command": "/usr/local/bin/other", "timeout": 5],
                    ["command": nanoCommand("cursor"), "timeout": 5],
                ],
                "stop": [["command": nanoCommand("cursor"), "timeout": 5]],
                "beforeReadFile": [["command": "/usr/local/bin/other", "timeout": 5]],
            ],
        ]
        let url = root.appendingPathComponent("cursor.json")
        try JSONSerialization.data(withJSONObject: original).write(to: url)

        AgentHookBridge.removeCursorHooks(from: url)
        let result = try json(url)

        XCTAssertEqual(result["version"] as? Int, 1)
        let hooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        XCTAssertEqual((hooks["beforeShellExecution"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(hooks["stop"])
        XCTAssertNotNil(hooks["beforeReadFile"])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(marker))
    }

    // MARK: - TOML (Kimi)

    func testKimiRemovalPreservesCommentsAndUserTables() throws {
        let contents = """
        # Kimi config — hand written, comments matter
        model = "kimi-k2"

        [[hooks]]
        event = "Stop"
        command = "/usr/local/bin/other-tool"
        timeout = 5

        [[hooks]]
        event = "UserPromptSubmit"
        command = "\(nanoCommand("kimi").replacingOccurrences(of: "\"", with: "\\\""))"
        timeout = 5

        [[hooks]]
        event = "Stop"
        command = "\(nanoCommand("kimi").replacingOccurrences(of: "\"", with: "\\\""))"
        timeout = 5

        [telemetry]
        enabled = false
        """
        let url = try write(contents, to: "kimi.toml")

        AgentHookBridge.removeKimiHooks(from: url)
        let result = try String(contentsOf: url, encoding: .utf8)

        XCTAssertFalse(result.contains(marker))
        // The user's own comment, scalar, foreign hook and trailing table all live.
        XCTAssertTrue(result.contains("# Kimi config — hand written, comments matter"))
        XCTAssertTrue(result.contains("model = \"kimi-k2\""))
        XCTAssertTrue(result.contains("/usr/local/bin/other-tool"))
        XCTAssertTrue(result.contains("[telemetry]"))
        XCTAssertTrue(result.contains("enabled = false"))
        // Exactly one `[[hooks]]` table survives: the foreign one.
        XCTAssertEqual(
            result.components(separatedBy: "[[hooks]]").count - 1, 1,
            "only the other tool's hook table should remain"
        )
    }

    func testKimiRemovalIsIdempotentAndDoesNotAccumulateBlankLines() throws {
        let contents = """
        model = "kimi-k2"

        [[hooks]]
        event = "Stop"
        command = "\(nanoCommand("kimi").replacingOccurrences(of: "\"", with: "\\\""))"
        timeout = 5
        """
        let url = try write(contents, to: "kimi-repeat.toml")

        AgentHookBridge.removeKimiHooks(from: url)
        let once = try String(contentsOf: url, encoding: .utf8)
        AgentHookBridge.removeKimiHooks(from: url)
        let twice = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(once, twice)
        XCTAssertEqual(once, "model = \"kimi-k2\"\n")
    }

    func testKimiRemovalLeavesCleanFileAlone() throws {
        let contents = """
        model = "kimi-k2"

        [[hooks]]
        event = "Stop"
        command = "/usr/local/bin/other-tool"
        timeout = 5
        """
        let url = try write(contents, to: "kimi-clean.toml")
        let before = try Data(contentsOf: url)

        AgentHookBridge.removeKimiHooks(from: url)

        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testPluginInstallAndRemovalPreserveModifiedFiles() throws {
        let url = root.appendingPathComponent("plugin.js")
        let bundled = Data("bundled plugin".utf8)
        AgentHookBridge.installOwnedPlugin(bundled, at: url)
        XCTAssertEqual(try Data(contentsOf: url), bundled)
        let edited = Data("user edited plugin".utf8)
        try edited.write(to: url)
        AgentHookBridge.installOwnedPlugin(bundled, at: url)
        AgentHookBridge.removeOwnedPlugin(at: url, matching: bundled)
        XCTAssertEqual(try Data(contentsOf: url), edited)
        try bundled.write(to: url)
        AgentHookBridge.removeOwnedPlugin(at: url, matching: bundled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testGrokRemovalPreservesSharedHandlersAndMalformedFiles() throws {
        let url = root.appendingPathComponent("grok-shared.json")
        let foreign: [String: Any] = ["command": "other-tool", "type": "command"]
        try JSONSerialization.data(withJSONObject: ["custom": true, "hooks": ["Stop": [["hooks": [foreign, ["command": nanoCommand("grok"), "type": "command"]]]]]]).write(to: url)
        AgentHookBridge.removeGrokHooks(from: url)
        XCTAssertEqual(try json(url)["custom"] as? Bool, true)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("other-tool"))
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(marker))
        let malformed = try write("invalid " + marker, to: "malformed-grok.json")
        AgentHookBridge.removeGrokHooks(from: malformed)
        XCTAssertEqual(try String(contentsOf: malformed, encoding: .utf8), "invalid " + marker)
    }

    // MARK: - Backups

    func testGrokRemovalDeletesNanoFileAndLeavesForeignHooks() throws {
        let url = root.appendingPathComponent("nano.json")
        try JSONSerialization.data(withJSONObject: ["hooks": ["Stop": [["hooks": [["command": nanoCommand("grok"), "type": "command"]]]]]]).write(to: url)
        AgentHookBridge.removeGrokHooks(from: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let foreign = try write(#"{"hooks":{"Stop":[{"hooks":[{"command":"/usr/local/bin/other","type":"command"}]}]}}"#, to: "vibe-island.json")
        let before = try Data(contentsOf: foreign)
        AgentHookBridge.removeGrokHooks(from: foreign)
        XCTAssertEqual(try Data(contentsOf: foreign), before)
    }

    func testRemovalDeletesAFileNanoCreated() throws {
        let url = root.appendingPathComponent("hooks.json")
        let onlyNano: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["command": nanoCommand("codex"), "type": "command"]]]]]
        ]
        try JSONSerialization.data(withJSONObject: onlyNano).write(to: url)

        AgentHookBridge.removeNestedHooks(from: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".nano-bak"))
    }

    func testBackupCapturesPreNanoStateAndIsNotOverwritten() throws {
        let original: [String: Any] = [
            "theme": "dark",
            "hooks": ["Stop": [["hooks": [["command": nanoCommand("claude"), "type": "command"]]]]],
        ]
        let url = root.appendingPathComponent("backup.json")
        try JSONSerialization.data(withJSONObject: original).write(to: url)
        let pristine = try Data(contentsOf: url)

        AgentHookBridge.removeNestedHooks(from: url)

        let backup = URL(fileURLWithPath: url.path + ".nano-bak")
        XCTAssertEqual(try Data(contentsOf: backup), pristine)

        // A second pass must not overwrite the copy with the already-stripped file.
        try JSONSerialization.data(withJSONObject: original).write(to: url)
        AgentHookBridge.removeNestedHooks(from: url)
        XCTAssertEqual(try Data(contentsOf: backup), pristine)
    }

    /// The backup can hold the same API keys as the file it copies.
    func testBackupIsOwnerOnly() throws {
        let original: [String: Any] = [
            "env": ["ANTHROPIC_API_KEY": "test-not-a-key"],
            "hooks": ["Stop": [["hooks": [["command": nanoCommand("claude"), "type": "command"]]]]],
        ]
        let url = root.appendingPathComponent("private.json")
        try JSONSerialization.data(withJSONObject: original).write(to: url)

        AgentHookBridge.removeNestedHooks(from: url)

        let backup = url.path + ".nano-bak"
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: backup)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    /// A stow or chezmoi dotfile is a symlink. Editing it must keep the link
    /// and leave paths readable.
    func testRewriteFollowsSymlinkAndKeepsSlashes() throws {
        let original: [String: Any] = [
            "statusLine": ["command": "/Users/someone/bin/status.sh"],
            "hooks": ["Stop": [["hooks": [["command": nanoCommand("claude"), "type": "command"]]]]],
        ]
        let real = root.appendingPathComponent("dotfiles-settings.json")
        try JSONSerialization.data(withJSONObject: original).write(to: real)
        let link = root.appendingPathComponent("linked-settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        AgentHookBridge.removeNestedHooks(from: link)

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path
        )
        let written = try String(contentsOf: real, encoding: .utf8)
        XCTAssertFalse(written.contains(nanoCommand("claude")))
        XCTAssertTrue(written.contains("/Users/someone/bin/status.sh"))
    }
}

@MainActor
final class AgentHookBridgeCursorTests: XCTestCase {
    func testActivityDisplayGroupsOnlyConsecutiveReads() {
        let now = Date()
        let entries = [
            AgentActivityEntry(kind: .read, detail: "Read A", at: now),
            AgentActivityEntry(kind: .read, detail: "Read B", at: now),
            AgentActivityEntry(kind: .command, detail: "swift test", at: now),
            AgentActivityEntry(kind: .read, detail: "Read C", at: now),
        ]

        let grouped = AgentActivityEntry.groupedForDisplay(entries)

        XCTAssertEqual(grouped.count, 3)
        XCTAssertEqual(grouped[0].detail, "Read files")
        XCTAssertEqual(grouped[0].repeatCount, 2)
        XCTAssertEqual(grouped[1].detail, "swift test")
        XCTAssertEqual(grouped[2].repeatCount, 1)
    }

    func testPythonInlineCommandUsesReadableSummary() {
        XCTAssertEqual(
            AgentToolLabel.shellSummary(#"python3 -c \"import json; print(json.dumps({}))\""#),
            "python3 (script)"
        )
    }

    func testCursorWritePreToolUseRemainsActivityWithoutApprovalSignal() async throws {
        let bridge = AgentHookBridge()
        let presented = expectation(description: "No inferred permission attention")
        presented.isInverted = true
        bridge.didRequestAttention = { _ in presented.fulfill() }

        _ = await bridge.handle(try payload(event: "preToolUse"))
        await fulfillment(of: [presented], timeout: 0.1)

        XCTAssertEqual(
            bridge.sessionStates["cursor-session"]?.lastToolInputDescription,
            "Wrote glb.py"
        )
    }

    func testCursorExplicitPermissionNotificationStillAlerts() async throws {
        let bridge = AgentHookBridge()
        let presented = expectation(description: "Explicit Cursor permission attention")
        var received: AgentHookBridge.PendingRequest?
        bridge.didRequestAttention = { request in
            received = request
            presented.fulfill()
        }

        let data = try JSONSerialization.data(withJSONObject: [
            "source": "cursor",
            "event": [
                "hook_event_name": "notification",
                "conversation_id": "cursor-session",
                "notification_type": "permission_prompt",
                "message": "Cursor needs approval",
                "cwd": "/tmp/Nano",
            ],
        ])
        _ = await bridge.handle(data)
        await fulfillment(of: [presented], timeout: 1)

        XCTAssertEqual(received?.source, AgentProviderID.cursor.rawValue)
        XCTAssertEqual(received?.kind, .permission)
        XCTAssertEqual(received?.title, "Cursor needs approval")
        XCTAssertEqual(received?.sessionID, "cursor-session")
        XCTAssertEqual(received?.respondsThroughBridge, false)
    }

    private func payload(event: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "source": "cursor",
            "event": [
                "hook_event_name": event,
                "conversation_id": "cursor-session",
                "tool_use_id": "write-1",
                "tool_name": "Write",
                "tool_input": [
                    "file_path": "/tmp/DeviceRenderPreview/glb.py",
                    "content": "print('preview')",
                ],
                "cwd": "/tmp/Nano",
            ] as [String: Any],
        ])
    }
}
