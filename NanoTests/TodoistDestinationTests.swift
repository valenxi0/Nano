import XCTest
@testable import Nano

/// A stand-in for Todoist's `/api/v1/sync`, shaped after its docs and SDK:
/// JSON body, `sync_token`, commands with `uuid` and `temp_id`, `sync_status`.
final class StubTodoist: @unchecked Sendable {
    static let shared = StubTodoist()

    private let lock = NSLock()
    private var items: [String: [String: Any]] = [:]
    private var versions: [String: Int] = [:]
    private var version = 0
    private var nextID = 100
    private var commandResults: [String: String] = [:]
    private(set) var requests = 0
    /// Applies the next write, then answers 500, as if the reply was lost.
    var losesNextReply = false
    let projects: [[String: Any]] = [
        ["id": "p1", "name": "Inbox", "inbox_project": true, "is_deleted": false, "is_archived": false],
        ["id": "p2", "name": "Work", "is_deleted": false, "is_archived": false],
    ]

    func reset() {
        lock.withLock {
            items = [:]
            versions = [:]
            version = 0
            commandResults = [:]
            requests = 0
            losesNextReply = false
        }
    }

    var liveItems: [[String: Any]] {
        lock.withLock { items.values.filter { $0["is_deleted"] as? Bool != true } }
    }

    /// What a person does in Todoist.
    @discardableResult
    func edit(_ id: String? = nil, _ change: (inout [String: Any]) -> Void) -> String {
        lock.withLock {
            let key = id ?? { nextID += 1; return String(nextID) }()
            var item = items[key] ?? ["id": key, "content": "", "description": "", "project_id": "p1", "checked": false, "is_deleted": false]
            change(&item)
            store(item)
            return key
        }
    }

    private func store(_ item: [String: Any]) {
        var item = item
        version += 1
        item["updated_at"] = "2026-10-22T12:00:00.\(String(format: "%06d", version))Z"
        let id = item["id"] as! String
        items[id] = item
        versions[id] = version
    }

    func handle(_ request: URLRequest, body: Data) -> (Int, Data) {
        lock.withLock {
            requests += 1
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer good" else { return (401, Data()) }
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            var reply: [String: Any] = [:]

            if let commands = json["commands"] as? [[String: Any]] {
                var statuses: [String: Any] = [:]
                var mapping: [String: String] = [:]
                for command in commands {
                    let uuid = command["uuid"] as! String
                    let args = command["args"] as? [String: Any] ?? [:]
                    if let earlier = commandResults[uuid] {
                        // Run once; a repeat reports the first result.
                        statuses[uuid] = "ok"
                        if let temp = command["temp_id"] as? String { mapping[temp] = earlier }
                        continue
                    }
                    var target = (args["id"] as? String).flatMap { mapping[$0] ?? $0 }
                    switch command["type"] as? String {
                    case "item_add":
                        nextID += 1
                        let id = String(nextID)
                        store(["id": id, "content": args["content"] ?? "", "description": args["description"] ?? "",
                               "project_id": args["project_id"] ?? "p1", "checked": false, "is_deleted": false])
                        if let temp = command["temp_id"] as? String { mapping[temp] = id }
                        target = id
                    case "item_update":
                        guard let id = target, var item = items[id] else { statuses[uuid] = ["http_code": 404, "error": "Item not found"]; continue }
                        if let content = args["content"] { item["content"] = content }
                        if let description = args["description"] { item["description"] = description }
                        store(item)
                    case "item_move":
                        guard let id = target, var item = items[id] else { statuses[uuid] = ["http_code": 404, "error": "Item not found"]; continue }
                        item["project_id"] = args["project_id"]
                        store(item)
                    case "item_complete", "item_uncomplete":
                        guard let id = target, var item = items[id] else { statuses[uuid] = ["http_code": 404, "error": "Item not found"]; continue }
                        item["checked"] = command["type"] as? String == "item_complete"
                        store(item)
                    case "item_delete":
                        guard let id = target, var item = items[id], item["is_deleted"] as? Bool != true else {
                            statuses[uuid] = ["http_code": 404, "error": "Item not found"]
                            continue
                        }
                        item["is_deleted"] = true
                        store(item)
                    default:
                        statuses[uuid] = ["http_code": 400, "error": "Unknown command"]
                        continue
                    }
                    commandResults[uuid] = target ?? ""
                    statuses[uuid] = "ok"
                }
                reply["sync_status"] = statuses
                reply["temp_id_mapping"] = mapping
                if losesNextReply {
                    losesNextReply = false
                    return (500, Data())
                }
            }

            if let token = json["sync_token"] as? String {
                let types = json["resource_types"] as? [String] ?? []
                let full = token == "*"
                let since = Int(token) ?? 0
                if types.contains("items") {
                    reply["items"] = items.filter { id, item in
                        full ? (item["checked"] as? Bool != true && item["is_deleted"] as? Bool != true) : versions[id, default: 0] > since
                    }.map(\.value)
                }
                if types.contains("projects") { reply["projects"] = full ? projects : [] }
                reply["full_sync"] = full
                reply["sync_token"] = String(version)
            }
            return (200, try! JSONSerialization.data(withJSONObject: reply))
        }
    }
}

final class StubTodoistProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.todoist.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let (status, data) = StubTodoist.shared.handle(request, body: body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class TodoistDestinationTests: XCTestCase {
    private var directory: URL!
    private var store: CueStore!
    private var todoist: TodoistDestination!
    private var engine: CueSyncEngine!
    private let stub = StubTodoist.shared

    override func setUp() async throws {
        try await super.setUp()
        stub.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTodoist-\(UUID().uuidString)", isDirectory: true)
        store = CueStore(directoryURL: directory)
        todoist = TodoistDestination(token: "good", session: Self.session())
        engine = makeEngine()
        engine.connect(TodoistDestination.record, destination: todoist)
        engine.link(folderID: nil, destinationID: todoist.id, project: RemoteProject(id: "p1", name: "Inbox"))
    }

    override func tearDown() async throws {
        engine.stop()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTodoistProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeEngine() -> CueSyncEngine {
        let engine = CueSyncEngine(store: store, stateURL: directory.appendingPathComponent("sync.json")) { [unowned self] _ in
            self.todoist
        }
        engine.debounce = .seconds(3600)
        return engine
    }

    private func item(titled title: String) -> [String: Any]? {
        stub.liveItems.first { $0["content"] as? String == title }
    }

    func testProjectsSkipNothingLiveAndAWrongTokenIsReported() async throws {
        let projects = try await todoist.listProjects()
        XCTAssertEqual(projects.map(\.name), ["Inbox", "Work"])

        let wrong = TodoistDestination(token: "bad", session: Self.session())
        do {
            _ = try await wrong.listProjects()
            XCTFail("expected the token to be rejected")
        } catch TodoistDestination.Failure.unauthorized {
        }
    }

    func testCueChangesReachTodoist() async throws {
        let cue = try XCTUnwrap(store.add(text: "Book flights\nWindow seat", kind: .todo, scope: .inbox))
        await engine.syncNow()
        XCTAssertNil(engine.statuses[todoist.id]?.error)
        XCTAssertEqual(item(titled: "Book flights")?["description"] as? String, "Window seat")

        let work = store.addFolder(named: "Work", section: .project)
        engine.link(folderID: work.id, destinationID: todoist.id, project: RemoteProject(id: "p2", name: "Work"))
        store.move(cue.id, to: .folder(work.id))
        store.setDone(cue.id, true)
        await engine.syncNow()
        XCTAssertEqual(item(titled: "Book flights")?["project_id"] as? String, "p2")
        XCTAssertEqual(item(titled: "Book flights")?["checked"] as? Bool, true)

        store.delete(cue.id)
        await engine.syncNow()
        XCTAssertNil(item(titled: "Book flights"))
        XCTAssertNil(engine.statuses[todoist.id]?.error)
    }

    func testTodoistChangesReachCue() async throws {
        let cue = try XCTUnwrap(store.add(text: "Pay rent", kind: .todo, scope: .inbox))
        await engine.syncNow()
        let id = try XCTUnwrap(item(titled: "Pay rent")?["id"] as? String)

        stub.edit(id) {
            $0["content"] = "Pay rent today"
            $0["checked"] = true
        }
        stub.edit { $0["content"] = "Made in Todoist" }
        await engine.syncNow()
        XCTAssertEqual(store.items.first { $0.id == cue.id }?.text, "Pay rent today")
        XCTAssertEqual(store.items.first { $0.id == cue.id }?.isDone, true)
        XCTAssertTrue(store.items.contains { $0.text == "Made in Todoist" })

        stub.edit(id) { $0["is_deleted"] = true }
        await engine.syncNow()
        XCTAssertNil(store.items.first { $0.id == cue.id })
    }

    func testALostReplyDoesNotDuplicate() async throws {
        let cue = try XCTUnwrap(store.add(text: "Renew passport", kind: .todo, scope: .inbox))
        stub.losesNextReply = true
        await engine.syncNow()
        XCTAssertNotNil(engine.statuses[todoist.id]?.error)
        XCTAssertEqual(stub.liveItems.count, 1)

        // Nano restarts; the create is retried under the same key first.
        engine = makeEngine()
        await engine.syncNow()
        await engine.syncNow()
        XCTAssertEqual(stub.liveItems.count, 1)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertNotNil(engine.state.links[cue.id.uuidString])
    }

    func testDatesWithMicrosecondsParse() {
        XCTAssertNotNil(SyncDates.parse("2026-10-22T12:00:00.123456Z"))
        XCTAssertNotNil(SyncDates.parse("2026-10-22T12:00:00Z"))
        XCTAssertNotNil(SyncDates.parse("2026-10-22T12:00:00.5+02:00"))
        XCTAssertNil(SyncDates.parse("not a date"))
    }
}
