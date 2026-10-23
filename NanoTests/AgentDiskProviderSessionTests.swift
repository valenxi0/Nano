import SQLite3
import XCTest
@testable import Nano

/// Cline, Qwen Code, Kilo Code and Goose ship no Nano hooks at all, so their
/// rows come from reading the agents' own stores. The fixtures mirror the
/// upstream schemas: Cline's `sessions` table, Kilo's OpenCode-shaped
/// `session` table, Goose's `sessions` table, and Qwen's chat JSONL files.
final class AgentDiskProviderSessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NanoDiskProviderTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func open(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        return db
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
    }

    // MARK: - Cline

    private func makeClineDatabase(
        name: String = "sessions.db",
        extraColumns: String = "",
        dropColumns: Set<String> = []
    ) throws -> (URL, OpaquePointer?) {
        let url = root.appendingPathComponent(name)
        let db = open(url)
        let all = [
            "session_id TEXT PRIMARY KEY", "source TEXT", "pid INTEGER",
            "started_at TEXT", "ended_at TEXT", "exit_code INTEGER",
            "status TEXT", "status_lock INTEGER DEFAULT 0",
            "interactive INTEGER", "provider TEXT", "model TEXT",
            "cwd TEXT", "workspace_root TEXT", "team_name TEXT",
            "parent_session_id TEXT", "parent_agent_id TEXT", "agent_id TEXT",
            "conversation_id TEXT", "is_subagent INTEGER DEFAULT 0",
            "prompt TEXT", "metadata_json TEXT", "transcript_path TEXT",
            "hook_path TEXT", "messages_path TEXT", "updated_at TEXT",
        ]
        var schema = all.filter { column in
            !dropColumns.contains(where: { column.hasPrefix("\($0) ") })
        }.joined(separator: ", ")
        if !extraColumns.isEmpty { schema += ", " + extraColumns }
        exec(db, "CREATE TABLE sessions (\(schema))")
        return (url, db)
    }

    private func insertClineSession(
        _ db: OpaquePointer?, id: String, cwd: String = "/tmp/proj",
        model: String? = "claude-sonnet-4", prompt: String? = "fix the bug",
        started: Date, updated: Date, ended: Date? = nil,
        subagent: Int = 0, parent: String? = nil
    ) {
        exec(db, """
        INSERT INTO sessions
          (session_id, source, pid, started_at, ended_at, status, interactive,
           provider, model, cwd, workspace_root, is_subagent, prompt, updated_at,
           parent_session_id)
        VALUES ('\(id)', 'cli', 1, '\(iso(started))',
                \(ended.map { "'\(iso($0))'" } ?? "NULL"), 'running', 0,
                'anthropic', \(model.map { "'\($0)'" } ?? "NULL"), '\(cwd)',
                '\(cwd)', \(subagent), \(prompt.map { "'\($0)'" } ?? "NULL"),
                '\(iso(updated))', \(parent.map { "'\($0)'" } ?? "NULL"))
        """)
    }

    func testClineSessionsReadRowsAndExcludeSubagentsAndStale() throws {
        let now = Date()
        let (url, db) = try makeClineDatabase()
        defer { sqlite3_close(db) }
        insertClineSession(db, id: "ses-live",
                           started: now.addingTimeInterval(-3600),
                           updated: now.addingTimeInterval(-30))
        insertClineSession(db, id: "ses-done",
                           started: now.addingTimeInterval(-3600),
                           updated: now.addingTimeInterval(-60),
                           ended: now.addingTimeInterval(-60))
        insertClineSession(db, id: "ses-sub",
                           started: now, updated: now, subagent: 1)
        insertClineSession(db, id: "ses-child",
                           started: now, updated: now, parent: "ses-live")
        insertClineSession(db, id: "ses-old",
                           started: now.addingTimeInterval(-10 * 86400),
                           updated: now.addingTimeInterval(-10 * 86400))

        let sessions = AgentSessionParsers.clineSessionsIn(databaseURL: url)

        XCTAssertEqual(sessions.map(\.id).sorted(), ["ses-done", "ses-live"])
        let live = try XCTUnwrap(sessions.first { $0.id == "ses-live" })
        XCTAssertEqual(live.provider, .cline)
        XCTAssertEqual(live.workingDirectory, "/tmp/proj")
        XCTAssertEqual(live.projectName, "proj")
        XCTAssertEqual(live.model, "claude-sonnet-4")
        XCTAssertEqual(live.lastUserPrompt, "fix the bug")
        XCTAssertEqual(try XCTUnwrap(live.startedAt).timeIntervalSince1970,
                       now.addingTimeInterval(-3600).timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(live.finishedAt)
        let done = try XCTUnwrap(sessions.first { $0.id == "ses-done" })
        XCTAssertEqual(try XCTUnwrap(done.finishedAt).timeIntervalSince1970,
                       now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 1)
    }

    func testClineSessionsTolerateMissingColumnsAndTable() throws {
        let now = Date()
        // A schema missing every optional column still yields a row.
        let (sparseURL, sparse) = try makeClineDatabase(
            name: "sparse.db", dropColumns: ["model", "prompt", "cwd",
                                             "workspace_root", "is_subagent",
                                             "parent_session_id", "ended_at",
                                             "started_at"]
        )
        defer { sqlite3_close(sparse) }
        exec(sparse, """
        INSERT INTO sessions (session_id, updated_at) VALUES ('s1', '\(iso(now))')
        """)
        let sparseSessions = AgentSessionParsers.clineSessionsIn(databaseURL: sparseURL)
        XCTAssertEqual(sparseSessions.map(\.id), ["s1"])

        // No `sessions` table at all: an empty result, not a crash.
        let emptyURL = root.appendingPathComponent("empty.db")
        let empty = open(emptyURL)
        exec(empty, "CREATE TABLE other (id TEXT)")
        sqlite3_close(empty)
        XCTAssertTrue(AgentSessionParsers.clineSessionsIn(databaseURL: emptyURL).isEmpty)
        XCTAssertTrue(AgentSessionParsers.clineSessionsIn(
            databaseURL: root.appendingPathComponent("missing.db")).isEmpty)
    }

    // MARK: - Kilo Code

    private func makeKiloDatabase() throws -> (URL, OpaquePointer?) {
        let url = root.appendingPathComponent("kilo.db")
        let db = open(url)
        exec(db, """
        CREATE TABLE session (
          id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT,
          directory TEXT, title TEXT, version TEXT,
          time_created INTEGER, time_updated INTEGER,
          time_compacting INTEGER, time_archived INTEGER
        )
        """)
        return (url, db)
    }

    func testKiloSessionsReadRowsAndExcludeChildrenArchivedAndStale() throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let (url, db) = try makeKiloDatabase()
        defer { sqlite3_close(db) }
        func insert(_ id: String, title: String, directory: String, parent: String?,
                    created: Int64, updated: Int64, archived: Int64?) {
            exec(db, """
            INSERT INTO session (id, parent_id, slug, directory, title, version,
                                 time_created, time_updated, time_archived)
            VALUES ('\(id)', \(parent.map { "'\($0)'" } ?? "NULL"), 's', '\(directory)',
                    '\(title)', '1', \(created), \(updated),
                    \(archived.map { "\($0)" } ?? "NULL"))
            """)
        }
        insert("s-live", title: "Wire the mixer", directory: "/tmp/mixer-proj",
               parent: nil, created: nowMs - 3_600_000, updated: nowMs - 30_000,
               archived: nil)
        insert("s-child", title: "subtask", directory: "/tmp/mixer-proj",
               parent: "s-live", created: nowMs, updated: nowMs, archived: nil)
        insert("s-arch", title: "old work", directory: "/tmp/mixer-proj",
               parent: nil, created: nowMs, updated: nowMs, archived: nowMs)
        insert("s-stale", title: "ancient", directory: "/tmp/mixer-proj",
               parent: nil, created: nowMs - 10 * 86_400_000,
               updated: nowMs - 10 * 86_400_000, archived: nil)

        let sessions = AgentSessionParsers.kiloSessionsIn(databaseURL: url)

        XCTAssertEqual(sessions.map(\.id), ["s-live"])
        let live = try XCTUnwrap(sessions.first)
        XCTAssertEqual(live.provider, .kilo)
        XCTAssertEqual(live.title?.text, "Wire the mixer")
        XCTAssertEqual(live.title?.source, .client)
        XCTAssertEqual(live.workingDirectory, "/tmp/mixer-proj")
        XCTAssertEqual(live.projectName, "mixer-proj")
        XCTAssertEqual(try XCTUnwrap(live.startedAt).timeIntervalSince1970,
                       Double(nowMs - 3_600_000) / 1000, accuracy: 0.5)
        XCTAssertEqual(live.lastActivityAt.timeIntervalSince1970,
                       Double(nowMs - 30_000) / 1000, accuracy: 0.5)
        XCTAssertNil(live.finishedAt)
    }

    // MARK: - Goose

    private func makeGooseDatabase() throws -> (URL, OpaquePointer?) {
        let url = root.appendingPathComponent("goose-sessions.db")
        let db = open(url)
        exec(db, """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY, working_dir TEXT, name TEXT,
          user_set_name INTEGER DEFAULT 0, session_type TEXT DEFAULT 'user',
          created_at TIMESTAMP, updated_at TIMESTAMP,
          provider_name TEXT, model_config_json TEXT, archived_at TIMESTAMP
        )
        """)
        return (url, db)
    }

    private func gooseTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    func testGooseSessionsReadRowsAndExcludeNonUserArchivedAndStale() throws {
        let now = Date()
        let (url, db) = try makeGooseDatabase()
        defer { sqlite3_close(db) }
        func insert(_ id: String, name: String?, userSet: Int, type: String,
                    directory: String, created: Date, updated: Date,
                    model: String?, archived: String? = nil) {
            exec(db, """
            INSERT INTO sessions
              (id, working_dir, name, user_set_name, session_type,
               created_at, updated_at, model_config_json, archived_at)
            VALUES ('\(id)', '\(directory)',
                    \(name.map { "'\($0)'" } ?? "NULL"), \(userSet), '\(type)',
                    '\(gooseTimestamp(created))', '\(gooseTimestamp(updated))',
                    \(model.map { "'{\"model_name\":\"\($0)\"}'" } ?? "NULL"),
                    \(archived.map { "'\($0)'" } ?? "NULL"))
            """)
        }
        insert("g-live", name: "daily standup notes", userSet: 1, type: "user",
               directory: "/tmp/notes", created: now.addingTimeInterval(-7200),
               updated: now.addingTimeInterval(-45), model: "claude-opus-5")
        insert("g-sub", name: "sub", userSet: 0, type: "subagent",
               directory: "/tmp/notes", created: now, updated: now, model: nil)
        insert("g-arch", name: "old", userSet: 0, type: "user",
               directory: "/tmp/notes", created: now, updated: now, model: nil,
               archived: gooseTimestamp(now))
        insert("g-stale", name: "ancient", userSet: 0, type: "user",
               directory: "/tmp/notes",
               created: now.addingTimeInterval(-10 * 86400),
               updated: now.addingTimeInterval(-10 * 86400), model: nil)

        let sessions = AgentSessionParsers.gooseSessionsIn(databaseURL: url)

        XCTAssertEqual(sessions.map(\.id), ["g-live"])
        let live = try XCTUnwrap(sessions.first)
        XCTAssertEqual(live.provider, .goose)
        XCTAssertEqual(live.title?.text, "daily standup notes")
        XCTAssertEqual(live.title?.source, .userNamed,
                       "a name the user set outranks a client title")
        XCTAssertEqual(live.workingDirectory, "/tmp/notes")
        XCTAssertEqual(live.model, "claude-opus-5")
        XCTAssertEqual(try XCTUnwrap(live.startedAt).timeIntervalSince1970,
                       now.addingTimeInterval(-7200).timeIntervalSince1970,
                       accuracy: 1)
        XCTAssertNil(live.finishedAt)
    }

    // MARK: - Qwen Code

    private func writeQwenChat(
        _ name: String, lines: [String], age: TimeInterval = 0
    ) throws -> URL {
        let chats = root.appendingPathComponent(
            "runtime/projects/-tmp-proj/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent(name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        if age > 0 {
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)],
                ofItemAtPath: file.path)
        }
        return file
    }

    func testQwenSessionsReadChatFilesAndSkipStale() throws {
        let now = Date()
        _ = try writeQwenChat("sess-a.jsonl", lines: [
            #"{"id":"sess-a","workspaceRootPath":"/tmp/proj","name":"drafted title"}"#,
            #"{"uuid":"u1","sessionId":"sess-a","type":"user","cwd":"/tmp/proj","timestamp":"\#(iso(now.addingTimeInterval(-300)))","message":{"role":"user","parts":[{"text":"summarise the logs"}]}}"#,
            #"{"uuid":"a1","sessionId":"sess-a","type":"assistant","cwd":"/tmp/proj","model":"qwen3-coder","timestamp":"\#(iso(now.addingTimeInterval(-30)))","message":{"role":"model","parts":[{"text":"done"}]}}"#,
            #"{"uuid":"t1","sessionId":"sess-a","type":"system","subtype":"ui_telemetry","timestamp":"\#(iso(now))"}"#,
        ])
        _ = try writeQwenChat("sess-old.jsonl", lines: [
            #"{"uuid":"u1","sessionId":"sess-old","type":"user","cwd":"/tmp/proj","timestamp":"\#(iso(now))","message":{"role":"user","parts":[{"text":"old"}]}}"#,
        ], age: 10 * 86400)

        let sessions = AgentSessionParsers.qwenSessions(
            roots: [root.appendingPathComponent("runtime", isDirectory: true)])

        XCTAssertEqual(sessions.map(\.id), ["sess-a"], "stale files stay out")
        let live = try XCTUnwrap(sessions.first)
        XCTAssertEqual(live.provider, .qwen)
        XCTAssertEqual(live.title?.text, "drafted title")
        XCTAssertEqual(live.title?.source, .client)
        XCTAssertEqual(live.workingDirectory, "/tmp/proj")
        XCTAssertEqual(live.projectName, "proj")
        XCTAssertEqual(live.model, "qwen3-coder")
        XCTAssertEqual(try XCTUnwrap(live.startedAt).timeIntervalSince1970,
                       now.addingTimeInterval(-300).timeIntervalSince1970,
                       accuracy: 1)
        // The newest non-telemetry record, not the telemetry line, is activity.
        XCTAssertEqual(live.lastActivityAt.timeIntervalSince1970,
                       now.addingTimeInterval(-30).timeIntervalSince1970,
                       accuracy: 1)
        XCTAssertNil(live.finishedAt)
    }

    func testQwenCustomTitleOutranksPromptAndHeader() throws {
        let now = Date()
        _ = try writeQwenChat("sess-b.jsonl", lines: [
            #"{"id":"sess-b","workspaceRootPath":"/tmp/proj","name":"drafted"}"#,
            #"{"uuid":"u1","sessionId":"sess-b","type":"user","cwd":"/tmp/proj","timestamp":"\#(iso(now.addingTimeInterval(-300)))","message":{"role":"user","parts":[{"text":"do the thing"}]}}"#,
            #"{"uuid":"r1","sessionId":"sess-b","type":"system","subtype":"custom_title","cwd":"/tmp/proj","timestamp":"\#(iso(now.addingTimeInterval(-60)))","message":{"role":"model","parts":[{"text":"My Renamed Chat"}]}}"#,
        ])

        let sessions = AgentSessionParsers.qwenSessions(
            roots: [root.appendingPathComponent("runtime", isDirectory: true)])

        let live = try XCTUnwrap(sessions.first { $0.id == "sess-b" })
        XCTAssertEqual(live.title?.text, "My Renamed Chat")
        XCTAssertEqual(live.title?.source, .userNamed)
    }

    func testQwenUntitledChatFallsBackToFirstPrompt() throws {
        let now = Date()
        _ = try writeQwenChat("sess-c.jsonl", lines: [
            #"{"id":"sess-c","workspaceRootPath":"/tmp/proj"}"#,
            #"{"uuid":"u1","sessionId":"sess-c","type":"user","cwd":"/tmp/proj","timestamp":"\#(iso(now))","message":{"role":"user","parts":[{"text":"first user line"}]}}"#,
        ])

        let sessions = AgentSessionParsers.qwenSessions(
            roots: [root.appendingPathComponent("runtime", isDirectory: true)])

        let live = try XCTUnwrap(sessions.first { $0.id == "sess-c" })
        XCTAssertNil(live.title)
        XCTAssertEqual(live.lastUserPrompt, "first user line")
        XCTAssertTrue(live.hasVisibleWork)
    }

    // MARK: - Provider gating

    @MainActor
    func testDiskProviderGateHidesDisabledRowsButNeverHookRows() throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let (kiloURL, kiloDB) = try makeKiloDatabase()
        defer { sqlite3_close(kiloDB) }
        exec(kiloDB, """
        INSERT INTO session (id, slug, directory, title, version,
                             time_created, time_updated)
        VALUES ('s-live', 's', '/tmp/mixer-proj', 'Wire the mixer', '1',
                \(nowMs - 3_600_000), \(nowMs - 30_000))
        """)
        _ = try writeQwenChat("sess-g.jsonl", lines: [
            #"{"uuid":"u1","sessionId":"sess-g","type":"user","cwd":"/tmp/proj","timestamp":"\#(iso(Date()))","message":{"role":"user","parts":[{"text":"qwen prompt"}]}}"#,
        ])

        let store = AgentSessionStore()
        store.applyIncrementalSessions(
            AgentSessionParsers.kiloSessionsIn(databaseURL: kiloURL)
                + AgentSessionParsers.qwenSessions(
                    roots: [root.appendingPathComponent("runtime", isDirectory: true)])
        )
        // A hook-attributed row for a vendor Nano never scanned (OpenCode
        // running a Kimi model) shares the store.
        var kimi = AgentHookBridge.LiveSessionState(
            sessionID: "kimi-hook", source: "kimi",
            firstSeen: Date(), lastEventAt: Date(), isWorking: true
        )
        kimi.lastUserPrompt = "hook prompt"
        store.applyHookState([kimi.sessionID: kimi])
        XCTAssertEqual(store.liveSessions.count, 3)

        store.enabledProviders = [.kilo]
        let visible = Set(store.liveSessions.map(\.id))
        XCTAssertTrue(visible.contains("s-live"), "enabled disk provider shows")
        XCTAssertFalse(visible.contains("sess-g"), "disabled disk provider hides")
        XCTAssertTrue(visible.contains("kimi-hook"),
                      "hook rows are never gated by the disk-provider set")
    }
}
