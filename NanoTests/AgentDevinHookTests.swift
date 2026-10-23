import SQLite3
import XCTest
@testable import Nano

/// Devin ships no `cwd`, `model`, or title in its hook payloads, so the
/// installer, the bridge's `project_dir` fallback, and the sessions.db reader
/// are what give a Devin row an identity at all.
final class AgentDevinHookTests: XCTestCase {
    private var root: URL!
    private let marker = "nano-agent-bridge"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NanoDevinHookTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - Codex internal memory sessions (phantom row regression)

    func testCodexMemorySessionMatchesMemoryTreeOnly() {
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
        let memories = home.appendingPathComponent("memories").path

        XCTAssertTrue(AgentHookBridge.isCodexInternalMemorySession(
            source: "codex",
            event: ["cwd": memories],
            codexHome: home
        ))
        XCTAssertTrue(AgentHookBridge.isCodexInternalMemorySession(
            source: "codex",
            event: ["cwd": memories + "/2026/10"],
            codexHome: home
        ))
        XCTAssertFalse(AgentHookBridge.isCodexInternalMemorySession(
            source: "codex",
            event: ["cwd": home.appendingPathComponent("memories-app").path],
            codexHome: home
        ), "a sibling sharing the prefix is still a real project")
        XCTAssertFalse(AgentHookBridge.isCodexInternalMemorySession(
            source: "codex",
            event: ["cwd": root.appendingPathComponent("project").path],
            codexHome: home
        ))
        XCTAssertFalse(AgentHookBridge.isCodexInternalMemorySession(
            source: "claude",
            event: ["cwd": memories],
            codexHome: home
        ), "only codex runs this internal agent")
        XCTAssertFalse(AgentHookBridge.isCodexInternalMemorySession(
            source: "codex",
            event: [:],
            codexHome: home
        ))
    }

    @MainActor
    func testCodexMemorySessionEventsRecordNothing() async throws {
        let bridge = AgentHookBridge()
        var activity: [AgentHookBridge.ActivitySignal] = []
        var finished: [String?] = []
        bridge.didSignalActivity = { activity.append($0) }
        bridge.didFinishTurn = { finished.append($0) }

        let memories = AgentHookBridge.codexHome
            .appendingPathComponent("memories", isDirectory: true).path
        for name in ["UserPromptSubmit", "Stop"] {
            let payload: [String: Any] = [
                "source": "codex",
                "event": [
                    "hook_event_name": name,
                    "session_id": "memory-consolidation",
                    "cwd": memories,
                    "prompt": "## Memory Writing Agent: Phase 2 (Consolidation)",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let reply = await bridge.handle(data)
            XCTAssertNil(reply)
        }

        XCTAssertTrue(bridge.sessionStates.isEmpty)
        XCTAssertTrue(bridge.liveSessions.isEmpty)
        XCTAssertTrue(activity.isEmpty)
        XCTAssertTrue(finished.isEmpty)
    }

    /// A host checking that Devin is reachable opens a session and closes it
    /// without a prompt. That is not a finished run.
    @MainActor
    func testSessionOpenedAndClosedWithoutAPromptAnnouncesNothing() async throws {
        let bridge = AgentHookBridge()
        var finished: [String?] = []
        bridge.didFinishTurn = { finished.append($0) }

        func send(_ name: String, session: String) async throws {
            let payload: [String: Any] = [
                "source": "devin",
                "project_dir": "/Users/someone",
                "event": ["hook_event_name": name, "session_id": session],
            ]
            _ = await bridge.handle(try JSONSerialization.data(withJSONObject: payload))
        }

        try await send("SessionStart", session: "probe")
        try await send("SessionEnd", session: "probe")
        XCTAssertTrue(bridge.sessionStates.isEmpty)
        XCTAssertTrue(finished.isEmpty)

        try await send("SessionStart", session: "real")
        try await send("UserPromptSubmit", session: "real")
        try await send("Stop", session: "real")
        XCTAssertEqual(finished, ["real"])
    }

    // MARK: - Install into ~/.config/devin/config.json

    @MainActor
    private func writeDevinConfig(_ contents: String, permissions: Int? = nil) throws -> URL {
        let url = root.appendingPathComponent(".config/devin/config.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if let permissions {
            try FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: url.path
            )
        }
        return url
    }

    @MainActor
    func testDevinInstallAppendsPreservesAndIsIdempotent() throws {
        // The shape Orca and Vibe Island already write into this file.
        let existing = """
        {
          "hooks": {
            "PermissionRequest": [
              {"hooks": [{"command": "/Users/x/.orca/agent-hooks/devin-hook.sh", "timeout": 10, "type": "command"}]},
              {"hooks": [{"command": "/Users/x/.vibe-island/bin/vibe-island-bridge --source devin", "timeout": 600, "type": "command"}]}
            ],
            "Stop": [
              {"hooks": [{"command": "/Users/x/.vibe-island/bin/vibe-island-bridge --source devin", "timeout": 10, "type": "command"}]}
            ]
          },
          "model": "fusion-claude"
        }
        """
        let url = try writeDevinConfig(existing, permissions: 0o600)

        AgentHookBridge.installDevinHooks(at: url, bridge: "/tmp/bin/\(marker)")

        let result = try json(url)
        XCTAssertEqual(result["model"] as? String, "fusion-claude")
        let hooks = try XCTUnwrap(result["hooks"] as? [String: Any])

        for event in [
            "SessionStart", "UserPromptSubmit", "PostToolUse",
            "PermissionRequest", "Stop", "PostCompaction", "SessionEnd",
        ] {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], "missing \(event)")
            XCTAssertTrue(
                entries.contains { entry in
                    (entry["hooks"] as? [[String: Any]])?
                        .contains { ($0["command"] as? String)?.contains(marker) == true }
                        == true
                },
                "Nano entry missing under \(event)"
            )
        }

        // The foreign entries survived next to Nano's, in front of them.
        let permission = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        XCTAssertEqual(permission.count, 3)
        XCTAssertEqual(
            (permission.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String,
            "/Users/x/.orca/agent-hooks/devin-hook.sh"
        )
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2)
        XCTAssertEqual(
            (stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String,
            "/Users/x/.vibe-island/bin/vibe-island-bridge --source devin"
        )

        // Devin writes this file 0600; a rewrite must not widen it.
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)

        let installed = try Data(contentsOf: url)
        AgentHookBridge.installDevinHooks(at: url, bridge: "/tmp/bin/\(marker)")
        XCTAssertEqual(try Data(contentsOf: url), installed, "second install is a no-op")
    }

    @MainActor
    func testDevinInstallSkipsMissingAndUnparseableFiles() throws {
        let missing = root.appendingPathComponent(".config/devin/config.json")
        AgentHookBridge.installDevinHooks(at: missing, bridge: "/tmp/bin/\(marker)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        // JSONC: comments are legal in the real file but not to JSONSerialization.
        let jsonc = try writeDevinConfig("""
        {
          // user note
          "hooks": {"Stop": [{"hooks": [{"command": "other", "type": "command"}]}]}
        }
        """)
        let before = try Data(contentsOf: jsonc)
        AgentHookBridge.installDevinHooks(at: jsonc, bridge: "/tmp/bin/\(marker)")
        XCTAssertEqual(try Data(contentsOf: jsonc), before)
    }

    @MainActor
    func testDevinUninstallRemovesOnlyNanoEntries() throws {
        let url = try writeDevinConfig("""
        {
          "hooks": {
            "Stop": [
              {"hooks": [{"command": "/Users/x/.vibe-island/bin/vibe-island-bridge --source devin", "type": "command"}]}
            ]
          }
        }
        """, permissions: 0o600)
        AgentHookBridge.installDevinHooks(at: url, bridge: "/tmp/bin/\(marker)")

        AgentHookBridge.removeNestedHooks(from: url)

        let result = try json(url)
        let hooks = try XCTUnwrap(result["hooks"] as? [String: Any])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(marker))
        // The foreign Stop entry and nothing else survives.
        XCTAssertEqual(hooks.keys.sorted(), ["Stop"])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 1)
        XCTAssertEqual(
            (stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String,
            "/Users/x/.vibe-island/bin/vibe-island-bridge --source devin"
        )
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
    }

    // MARK: - Event and provider naming

    func testDevinEventNamesCanonicalize() {
        XCTAssertEqual(AgentHookBridge.canonicalHookEventName("PostCompaction"), "PostCompact")
        XCTAssertEqual(AgentHookBridge.canonicalHookEventName("UserPromptSubmit"), "UserPromptSubmit")
        XCTAssertEqual(AgentProviderID.fromHook(source: "devin"), .devin)
    }

    // MARK: - sessions.db reader

    /// Rows are `(id, workingDirectory, model, created_at, last_activity_at,
    /// title, hidden)`, matching the real schema's column order.
    private func makeSessionsDatabase(
        _ rows: [(String, String, String, Int, Int, String?, Int)]
    ) throws -> URL {
        let database = root.appendingPathComponent("sessions.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY,
              working_directory TEXT NOT NULL,
              backend_type TEXT NOT NULL DEFAULT 'local',
              model TEXT NOT NULL DEFAULT '',
              agent_mode TEXT NOT NULL DEFAULT '',
              created_at INTEGER NOT NULL DEFAULT 0,
              last_activity_at INTEGER NOT NULL,
              title TEXT,
              hidden INTEGER NOT NULL DEFAULT 0
            )
            """, nil, nil, nil), SQLITE_OK)
        for (id, directory, model, created, activity, title, hidden) in rows {
            let insert = """
            INSERT INTO sessions (id, working_directory, model, created_at, last_activity_at, title, hidden)
            VALUES ('\(id)', '\(directory)', '\(model)', \(created), \(activity), \(title.map { "'\($0)'" } ?? "NULL"), \(hidden))
            """
            XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        }
        return database
    }

    func testDevinSessionMetadataIndexReadsTitles() throws {
        let recent = Int(Date().timeIntervalSince1970)
        let stale = recent - 30 * 24 * 3600
        let database = try makeSessionsDatabase([
            ("pool-gallon", "/tmp/work", "fusion-x", recent - 500, recent - 10, "Fix missing Devin sessions", 0),
            ("hidden-one", "/tmp/other", "fusion-x", recent - 500, recent - 10, "Hidden", 1),
            ("old-one", "/tmp/old", "fusion-x", stale - 500, stale, "Ancient", 0),
        ])

        let index = AgentDevinSessionMetadata.index(databaseURL: database)

        let entry = try XCTUnwrap(index["pool-gallon"])
        XCTAssertEqual(entry.title, "Fix missing Devin sessions")
        XCTAssertEqual(entry.model, "fusion-x")
        XCTAssertEqual(entry.workingDirectory, "/tmp/work")
        XCTAssertEqual(entry.createdAt?.timeIntervalSince1970, Double(recent - 500))
        XCTAssertEqual(entry.lastActivityAt?.timeIntervalSince1970, Double(recent - 10))
        XCTAssertNil(index["hidden-one"], "sessions hidden in Devin's UI stay hidden")
        XCTAssertNil(index["old-one"], "sessions past the recency cutoff are ignored")
        XCTAssertTrue(AgentDevinSessionMetadata.index(
            databaseURL: root.appendingPathComponent("missing.db")
        ).isEmpty)
    }

    // MARK: - Disk discovery (sessions.db is authoritative, hooks only annotate)

    @MainActor
    func testDevinDiskDiscoveryProducesActiveSessions() throws {
        let now = Int(Date().timeIntervalSince1970)
        let database = try makeSessionsDatabase([
            ("pool-gallon", "/tmp/fix-mixer", "fusion-odd",
             now - 3600, now - 30, "Fix missing Devin sessions", 0),
            ("lowly-cinnamon", "/tmp/faders", "fusion-odd",
             now - 7200, now - 600, "Match fadersmac.com design", 0),
            ("hidden-one", "/tmp/other", "fusion-odd",
             now - 500, now - 30, "Hidden", 1),
            ("old-one", "/tmp/old", "fusion-odd",
             now - 10 * 24 * 3600, now - 10 * 24 * 3600, "Ancient", 0),
        ])

        let sessions = AgentSessionParsers.devinSessions(databaseURL: database)

        XCTAssertEqual(sessions.count, 2, "hidden and stale rows stay out")
        let pool = try XCTUnwrap(sessions.first { $0.id == "pool-gallon" })
        XCTAssertEqual(pool.provider, .devin)
        XCTAssertEqual(pool.title?.text, "Fix missing Devin sessions")
        XCTAssertEqual(pool.title?.source, .client)
        XCTAssertEqual(pool.workingDirectory, "/tmp/fix-mixer")
        XCTAssertEqual(pool.projectName, "fix-mixer")
        XCTAssertEqual(pool.model, "fusion-odd")
        XCTAssertEqual(pool.startedAt?.timeIntervalSince1970, Double(now - 3600))
        XCTAssertEqual(pool.lastActivityAt.timeIntervalSince1970, Double(now - 30))
        XCTAssertNil(pool.finishedAt)
        XCTAssertEqual(pool.hostBundleID, "com.exafunction.windsurf")
        XCTAssertEqual(AgentSessionJump.host(for: pool), .app)

        // The store's generic liveness rule: unfinished + inside activeWindow.
        let store = AgentSessionStore()
        store.applyIncrementalSessions(sessions)
        XCTAssertTrue(store.sessions.first { $0.id == "pool-gallon" }?.isActive == true)
        XCTAssertFalse(store.sessions.first { $0.id == "lowly-cinnamon" }?.isActive == true,
                       "last activity 10 minutes ago is past the active window")

        // A provider the user turned off contributes no rows.
        store.enabledProviders = [.codex]
        XCTAssertTrue(store.liveSessions.isEmpty)
        store.enabledProviders = [.devin]
        XCTAssertEqual(store.liveSessions.map(\.id).sorted(),
                       ["lowly-cinnamon", "pool-gallon"])
    }

    @MainActor
    func testDevinHookStateMergesIntoDiskRow() throws {
        let now = Int(Date().timeIntervalSince1970)
        let database = try makeSessionsDatabase([
            ("pool-gallon", "/tmp/fix-mixer", "fusion-odd",
             now - 3600, now - 20, "Fix missing Devin sessions", 0),
        ])
        let store = AgentSessionStore()
        store.applyIncrementalSessions(
            AgentSessionParsers.devinSessions(databaseURL: database)
        )

        // The same id arriving over hooks annotates the row instead of
        // appending a second one.
        var state = AgentHookBridge.LiveSessionState(
            sessionID: "pool-gallon",
            source: "devin",
            firstSeen: Date().addingTimeInterval(-3600),
            lastEventAt: Date(),
            isWorking: true
        )
        state.lastUserPrompt = "fix the phantom rows"
        store.applyHookState([state.sessionID: state])

        XCTAssertEqual(store.sessions.count, 1)
        let merged = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(merged.provider, .devin)
        XCTAssertEqual(merged.title?.text, "Fix missing Devin sessions")
        XCTAssertEqual(merged.lastUserPrompt, "fix the phantom rows")
        XCTAssertEqual(merged.hostBundleID, "com.exafunction.windsurf")
        XCTAssertTrue(merged.isActive)
    }

    @MainActor
    func testHookOnlySessionSilentForDaysIsNotRunningWhenRebuilt() {
        // An automated run left these "working" with no turn-end hook. Every
        // disk scan drops hook-only sessions and re-adds them from hook state.
        let now = Date()
        let store = AgentSessionStore()
        let stale = AgentHookBridge.LiveSessionState(
            sessionID: "zenith-brow",
            source: "devin",
            firstSeen: now.addingTimeInterval(-2 * 86_400),
            lastEventAt: now.addingTimeInterval(-2 * 86_400),
            isWorking: true
        )
        let fresh = AgentHookBridge.LiveSessionState(
            sessionID: "brave-gadget",
            source: "devin",
            firstSeen: now.addingTimeInterval(-60),
            lastEventAt: now.addingTimeInterval(-5),
            isWorking: true
        )
        store.applyHookState([stale.sessionID: stale, fresh.sessionID: fresh], now: now, t3Runtime: AgentT3RuntimeIndex())

        XCTAssertEqual(store.sessions.first { $0.id == "zenith-brow" }?.isActive, false)
        XCTAssertEqual(store.sessions.first { $0.id == "brave-gadget" }?.isActive, true)
    }
}

/// Runs that an agent starts for itself (a `claude -p` from a Bash tool, a
/// test harness in /tmp) must not show up as the user's sessions.
final class AgentSpawnedSessionTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NanoSpawnedSessions.\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// pid -> (parent, name), shaped like a real process table.
    private func lookup(_ table: [Int32: (Int32, String)]) -> (Int32) -> (parent: Int32, name: String)? {
        { pid in table[pid].map { (parent: $0.0, name: $0.1) } }
    }

    func testClaudeStartedFromAnotherAgentsBashToolIsNested() {
        // hook sh -> sh -c -> claude (child) -> zsh (Bash tool) -> claude (parent) -> T3
        let table = lookup([
            10: (11, "sh"), 11: (12, "sh"), 12: (13, "claude"),
            13: (14, "zsh"), 14: (15, "claude"), 15: (1, "T3 Code (Nightly)"),
        ])
        XCTAssertTrue(AgentSpawnedSessions.isNested(startingAt: 10, lookup: table))
    }

    func testSessionsLaunchedByAppsAndTerminalsAreNotNested() {
        let fromT3 = lookup([10: (11, "sh"), 11: (12, "claude"), 12: (1, "T3 Code (Nightly)")])
        XCTAssertFalse(AgentSpawnedSessions.isNested(startingAt: 10, lookup: fromT3))

        let fromTerminal = lookup([
            10: (11, "sh"), 11: (12, "claude"), 12: (13, "zsh"), 13: (14, "login"), 14: (1, "Terminal"),
        ])
        XCTAssertFalse(AgentSpawnedSessions.isNested(startingAt: 10, lookup: fromTerminal))
    }

    func testALauncherThatStartsTheAgentBinaryDirectlyIsOneAgent() {
        // npm's codex launcher execs the native codex as its direct child.
        let table = lookup([10: (11, "sh"), 11: (12, "codex"), 12: (13, "codex"), 13: (1, "T3 Code")])
        XCTAssertFalse(AgentSpawnedSessions.isNested(startingAt: 10, lookup: table))
    }

    func testTemporaryFoldersAreRecognised() {
        XCTAssertTrue(AgentSpawnedSessions.isTemporaryDirectory("/private/tmp/atlas-mcp-check"))
        XCTAssertTrue(AgentSpawnedSessions.isTemporaryDirectory("/tmp"))
        XCTAssertTrue(AgentSpawnedSessions.isTemporaryDirectory("/var/folders/ab/T/run"))
        XCTAssertFalse(AgentSpawnedSessions.isTemporaryDirectory("/tmpfoo"))
        XCTAssertFalse(AgentSpawnedSessions.isTemporaryDirectory("/Volumes/Projects/North-Star"))
        XCTAssertFalse(AgentSpawnedSessions.isTemporaryDirectory(nil))
    }

    func testANestedRunStaysHiddenAfterItsProcessesAreGone() {
        let nested = lookup([
            10: (11, "sh"), 11: (12, "claude"), 12: (13, "zsh"), 13: (14, "claude"), 14: (1, "T3 Code"),
        ])
        let store = AgentSpawnedSessions(storeURL: storeURL)
        XCTAssertTrue(store.hides(
            sessionID: "child", hookPIDs: [10], isKnown: false, lookup: nested
        ))
        XCTAssertFalse(store.hides(
            sessionID: "own", hookPIDs: [12], isKnown: false, lookup: nested
        ))

        // A fresh instance reads what the first one wrote, as after a relaunch.
        let relaunched = AgentSpawnedSessions(storeURL: storeURL)
        XCTAssertTrue(relaunched.hides(sessionID: "child", workingDirectory: "/Users/me/project", isHeadless: false))
        XCTAssertFalse(relaunched.hides(sessionID: "own", workingDirectory: "/Users/me/project", isHeadless: false))
    }

    func testOnlyHeadlessRunsInTemporaryFoldersAreHiddenFromScans() {
        let store = AgentSpawnedSessions(storeURL: storeURL)
        XCTAssertTrue(store.hides(sessionID: "a", workingDirectory: "/private/tmp/atlas-mcp-check", isHeadless: true))
        XCTAssertFalse(store.hides(sessionID: "b", workingDirectory: "/private/tmp/scratch", isHeadless: false))
        XCTAssertFalse(store.hides(sessionID: "c", workingDirectory: "/Users/me/project", isHeadless: true))
    }

    func testAKnownSessionIsNotReclassified() {
        let nested = lookup([
            10: (11, "sh"), 11: (12, "claude"), 12: (13, "zsh"), 13: (14, "claude"), 14: (1, "T3 Code"),
        ])
        let store = AgentSpawnedSessions(storeURL: storeURL)
        XCTAssertFalse(store.hides(
            sessionID: "row", hookPIDs: [10], isKnown: true, lookup: nested
        ))
    }

    func testTheRealProcessTableNamesProcessesByHowTheyWereLaunched() {
        let me = AgentSpawnedSessions.process(ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(me?.name, URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent)
        XCTAssertEqual(me?.parent, getppid())
    }
}
