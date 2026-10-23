import XCTest
@testable import Nano

/// The MCP adapter against `tools/cue-sync-reference-server.py`. Start the
/// servers, then pass their addresses with TEST_RUNNER_ variables:
///
///     python3 tools/cue-sync-reference-server.py --port 8765 --debug &
///     python3 tools/cue-sync-reference-server.py --port 8766 --debug --sse --token t0ken &
///     python3 tools/cue-sync-reference-server.py --port 8767 --debug --oauth &
///     TEST_RUNNER_CUE_SYNC_SERVER_URL=http://localhost:8765/mcp \
///     TEST_RUNNER_CUE_SYNC_SSE_SERVER_URL=http://localhost:8766/mcp \
///     TEST_RUNNER_CUE_SYNC_OAUTH_SERVER_URL=http://localhost:8767/mcp \
///     TEST_RUNNER_CUE_SYNC_SSE_TOKEN=t0ken xcodebuild ... test
///
/// Without them the server tests skip; the parsing tests always run.
@MainActor
final class MCPTaskDestinationTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoMCPSync-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: Without a server

    func testEventStreamsYieldEachDataPayload() {
        let stream = "event: message\r\ndata: {\"id\":1}\r\n\r\n: comment\n\ndata: {\"id\":\ndata: 2}\n\n"
        let payloads = MCPClient.events(in: Data(stream.utf8)).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(payloads, ["{\"id\":1}", "{\"id\":\n2}"])
    }

    func testPlainHTTPIsOnlyAllowedForThisMac() throws {
        XCTAssertNoThrow(try MCPTaskDestination.validate(XCTUnwrap(URL(string: "http://localhost:8765/mcp"))))
        XCTAssertNoThrow(try MCPTaskDestination.validate(XCTUnwrap(URL(string: "http://127.0.0.1:9/mcp"))))
        XCTAssertNoThrow(try MCPTaskDestination.validate(XCTUnwrap(URL(string: "https://tasks.example.com/mcp"))))
        XCTAssertThrowsError(try MCPTaskDestination.validate(XCTUnwrap(URL(string: "http://tasks.example.com/mcp"))))
        XCTAssertThrowsError(try MCPTaskDestination.validate(XCTUnwrap(URL(string: "ftp://localhost/mcp"))))
    }

    // MARK: Against the reference server

    private func server(_ variable: String) throws -> URL {
        guard let value = ProcessInfo.processInfo.environment[variable], let url = URL(string: value) else {
            throw XCTSkip("Set TEST_RUNNER_\(variable) to a running reference server")
        }
        return url
    }

    private func check(_ url: URL, token: String?) async throws {
        let destination = MCPTaskDestination(id: "mcp:test", client: MCPClient(url: url, token: token))
        // A second client plays the person using the app.
        let person = MCPClient(url: url, token: token)

        let info = try await destination.verify()
        XCTAssertEqual(info.name, "Reference Server")
        XCTAssertTrue(info.twoWay)

        let store = CueStore(directoryURL: directory)
        let engine = CueSyncEngine(store: store) { _ in destination }
        engine.debounce = .seconds(3600)
        engine.connect(CueSyncState.Destination(id: destination.id, kind: MCPTaskDestination.kind, name: info.name), destination: destination)
        let projects = try await destination.listProjects()
        engine.link(folderID: nil, destinationID: destination.id, project: try XCTUnwrap(projects.first { $0.id == "p1" }))

        func serverTask(_ cueID: UUID) async throws -> [String: Any]? {
            let tasks = try await person.callTool("debug_list_tasks", [:])["tasks"] as? [[String: Any]] ?? []
            return tasks.first { ($0["external_id"] as? String)?.uppercased() == cueID.uuidString }
        }

        // Cue to app, twice: the retry finds the same task.
        let item = try XCTUnwrap(store.add(text: "Book flights\nWindow seat", kind: .todo, scope: .inbox))
        await engine.syncNow()
        await engine.syncNow()
        let created = try await serverTask(item.id)
        XCTAssertEqual(created?["title"] as? String, "Book flights")
        XCTAssertEqual(created?["notes"] as? String, "Window seat")
        let all = try await person.callTool("debug_list_tasks", [:])["tasks"] as? [[String: Any]]
        XCTAssertEqual(all?.count, 1)

        // App to Cue: a new task, and a completion.
        let made = try await person.callTool("debug_create_task", ["title": "Renew passport", "project_id": "p1"])
        let taskID = try XCTUnwrap(made["task_id"] as? String)
        _ = try await person.callTool("debug_edit_task", ["task_id": try XCTUnwrap(created?["task_id"] as? String), "done": true])
        await engine.syncNow()
        XCTAssertNil(engine.statuses[destination.id]?.error)
        XCTAssertEqual(store.items.first { $0.id == item.id }?.isDone, true)
        let imported = try XCTUnwrap(store.items.first { $0.text == "Renew passport" })
        let tagged = try await serverTask(imported.id)
        XCTAssertEqual(tagged?["task_id"] as? String, taskID)

        // The reference server takes every kind and images.
        XCTAssertTrue(info.acceptsAllKinds)
        XCTAssertTrue(info.acceptsImages)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let prompt = try XCTUnwrap(store.add(text: "Explain the crash", kind: .prompt, images: [png], scope: .inbox))
        await engine.syncNow()
        XCTAssertNil(engine.statuses[destination.id]?.error)
        let sent = try await serverTask(prompt.id)
        XCTAssertEqual(sent?["kind"] as? String, "prompt")
        let images = sent?["images"] as? [[String: Any]]
        XCTAssertEqual(images?.count, 1)
        XCTAssertEqual(images?.first?["bytes"] as? Int, png.count)
        store.delete(prompt.id)
        await engine.syncNow()

        // A server that forgot the session gets a new one.
        _ = try await person.callTool("debug_forget_sessions", [:])

        // Deletes both ways.
        store.delete(imported.id)
        await engine.syncNow()
        XCTAssertNil(engine.statuses[destination.id]?.error)
        let gone = try await serverTask(imported.id)
        XCTAssertNil(gone)
        _ = try await person.callTool("debug_delete_task", ["task_id": try XCTUnwrap(created?["task_id"] as? String)])
        await engine.syncNow()
        XCTAssertNil(store.items.first { $0.id == item.id })
        engine.stop()
    }

    func testSyncAgainstAServerThatAnswersInJSON() async throws {
        try await check(server("CUE_SYNC_SERVER_URL"), token: nil)
    }

    func testSyncAgainstAServerThatStreamsAndWantsAToken() async throws {
        let url = try server("CUE_SYNC_SSE_SERVER_URL")
        let token = ProcessInfo.processInfo.environment["CUE_SYNC_SSE_TOKEN"]
        try await check(url, token: token)
    }

    func testASignInReplyWithAnUnknownStateIsIgnored() throws {
        let url = try XCTUnwrap(URL(string: "nano://cue/oauth?code=abc&state=nobody-asked"))
        XCTAssertFalse(MCPOAuthCallbacks.shared.handle(url))
    }

    func testSignInThenRefreshAnExpiredToken() async throws {
        let url = try server("CUE_SYNC_OAUTH_SERVER_URL")

        let anonymous = MCPTaskDestination(id: "mcp:oauth", client: MCPClient(url: url, token: nil))
        do {
            _ = try await anonymous.verify()
            XCTFail("expected the server to ask for sign-in")
        } catch MCPError.unauthorized {
        }

        // The "browser": follow the authorize URL, hand its redirect to Nano.
        let credentials = try await MCPOAuth.signIn(to: url, open: { authorize in
            Task { @MainActor in
                do {
                    let (_, response) = try await URLSession.shared.data(from: authorize, delegate: NoRedirects())
                    let location = try XCTUnwrap((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"))
                    XCTAssertTrue(location.hasPrefix(MCPOAuth.redirectURI))
                    XCTAssertTrue(MCPOAuthCallbacks.shared.handle(try XCTUnwrap(URL(string: location))))
                } catch {
                    XCTFail("the browser step failed: \(error)")
                }
            }
        }, timeout: .seconds(10))
        XCTAssertNotNil(credentials.refreshToken)

        var saved: MCPCredentials?
        let destination = MCPTaskDestination(id: "mcp:oauth", client: MCPClient(url: url, credentials: credentials) { saved = $0 })
        let info = try await destination.verify()
        XCTAssertEqual(info.name, "Reference Server")

        // The server drops every access token; the next call refreshes once.
        _ = try await MCPClient(url: url, credentials: credentials).callTool("debug_expire_tokens", [:])
        let projects = try await destination.listProjects()
        XCTAssertFalse(projects.isEmpty)
        let fresh = try XCTUnwrap(saved)
        XCTAssertNotEqual(fresh.accessToken, credentials.accessToken)

        // Stored credentials round-trip through the Keychain's string form.
        XCTAssertEqual(MCPCredentials.decode(try XCTUnwrap(fresh.encoded())), fresh)
    }

    func testAWrongTokenIsReported() async throws {
        let url = try server("CUE_SYNC_SSE_SERVER_URL")
        let destination = MCPTaskDestination(id: "mcp:test", client: MCPClient(url: url, token: "wrong"))
        do {
            _ = try await destination.verify()
            XCTFail("expected the token to be rejected")
        } catch MCPError.unauthorized {
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
