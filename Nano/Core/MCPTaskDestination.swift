import Foundation
import Security

/// Any app that serves Cue's sync tools over MCP. The contract is in
/// `docs/cue-sync.md`; nothing here knows which app is on the other end.
@MainActor
final class MCPTaskDestination: TaskDestination {
    static let kind = "mcp"
    static let sendTools: Set<String> = ["cue_describe", "cue_list_projects", "cue_upsert_task"]
    static let syncTools: Set<String> = ["cue_list_changes", "cue_delete_task"]

    let id: String
    var onChange: (() -> Void)?
    private let client: MCPClient
    /// From `cue_describe`; `kind` and `images` go only to servers that list them.
    private var capabilities: Set<String> = []

    /// A server on this Mac answers in milliseconds, so it's checked every
    /// few seconds; one on the internet less often.
    var pollInterval: Duration {
        let local = ["localhost", "127.0.0.1", "::1"].contains(client.url.host?.lowercased() ?? "")
        return local ? .seconds(5) : .seconds(30)
    }

    init(id: String, client: MCPClient) {
        self.id = id
        self.client = client
    }

    /// Rebuilds a saved connection. The token comes from the Keychain.
    static func make(_ record: CueSyncState.Destination, session: URLSession = .shared) -> MCPTaskDestination? {
        guard let string = record.settings["url"], let url = URL(string: string) else { return nil }
        let id = record.id
        let client = MCPClient(url: url, token: CueSyncKeychain.token(for: id), session: session) { fresh in
            CueSyncKeychain.setToken(fresh.encoded(), for: id)
        }
        return MCPTaskDestination(id: record.id, client: client)
    }

    static func recordID(for url: URL) -> String {
        "mcp:\(url.host ?? "local"):\(url.port.map(String.init) ?? "")\(url.path)"
    }

    /// Plain http only reaches this Mac; anything else must be https.
    static func validate(_ url: URL) throws {
        let scheme = url.scheme?.lowercased()
        let local = ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        guard scheme == "https" || (scheme == "http" && local) else { throw MCPError.insecureURL }
    }

    /// Checks the server has the tools Cue needs before it is saved.
    func verify() async throws -> DestinationInfo {
        let tools = Set(try await client.listTools())
        let missing = Self.sendTools.subtracting(tools)
        guard missing.isEmpty else { throw MCPError.missingTools(missing.sorted()) }
        var info = try await describe()
        if info.twoWay, !Self.syncTools.isSubset(of: tools) { info.twoWay = false }
        return info
    }

    // MARK: TaskDestination

    func describe() async throws -> DestinationInfo {
        let result = try await client.callTool("cue_describe", [:])
        capabilities = Set(result["capabilities"] as? [String] ?? [])
        return DestinationInfo(
            name: result["name"] as? String ?? "App",
            twoWay: capabilities.contains("two_way"),
            supportsDelete: capabilities.contains("two_way"),
            acceptsAllKinds: capabilities.contains("all_kinds"),
            acceptsImages: capabilities.contains("images")
        )
    }

    func listProjects() async throws -> [RemoteProject] {
        let result = try await client.callTool("cue_list_projects", [:])
        guard let projects = result["projects"] as? [[String: Any]] else { throw MCPError.badResponse("cue_list_projects") }
        return projects.compactMap { project in
            guard let id = Self.string(project["project_id"]) else { return nil }
            return RemoteProject(id: id, name: project["name"] as? String ?? id)
        }
    }

    func upsertTask(_ task: OutgoingTask) async throws -> RemoteTask {
        var arguments: [String: Any] = [
            "external_id": task.externalID.uuidString,
            "source": "cue",
            "title": task.title,
            "notes": task.notes,
            "project_id": task.projectID,
            "done": task.done,
        ]
        if let ref = task.ref { arguments["task_id"] = ref.remoteID }
        if capabilities.contains("all_kinds") { arguments["kind"] = task.kind.rawValue }
        if capabilities.contains("images"), let images = task.images {
            arguments["images"] = images.map {
                ["name": $0.name, "mime_type": $0.mimeType, "data": $0.data.base64EncodedString()]
            }
        }
        let result = try await client.callTool("cue_upsert_task", arguments)
        guard let taskID = Self.string(result["task_id"]) else { throw MCPError.badResponse("cue_upsert_task") }
        return RemoteTask(
            ref: RemoteRef(remoteID: taskID, stableID: nil),
            externalID: task.externalID,
            title: task.title,
            notes: task.notes,
            projectID: task.projectID,
            done: task.done,
            updatedAt: SyncDates.parse(result["updated_at"]) ?? Date(),
            kind: capabilities.contains("all_kinds") ? task.kind : nil
        )
    }

    func deleteTask(_ ref: RemoteRef, externalID: UUID) async throws {
        _ = try await client.callTool("cue_delete_task", ["task_id": ref.remoteID])
    }

    /// Always incremental: a task missing from the batch is unchanged.
    func listChanges(since cursor: String?, projectIDs: [String], known: [RemoteRef]) async throws -> ChangeBatch {
        var arguments: [String: Any] = ["project_ids": projectIDs]
        if let cursor { arguments["since"] = cursor }
        let result = try await client.callTool("cue_list_changes", arguments)
        guard let rows = result["tasks"] as? [[String: Any]] else { throw MCPError.badResponse("cue_list_changes") }
        let tasks = rows.compactMap { row -> RemoteTask? in
            guard let taskID = Self.string(row["task_id"]) else { return nil }
            return RemoteTask(
                ref: RemoteRef(remoteID: taskID, stableID: nil),
                externalID: (row["external_id"] as? String).flatMap(UUID.init(uuidString:)),
                title: row["title"] as? String ?? "",
                notes: row["notes"] as? String ?? "",
                projectID: Self.string(row["project_id"]) ?? "",
                done: row["done"] as? Bool ?? false,
                updatedAt: SyncDates.parse(row["updated_at"]) ?? .distantPast,
                deleted: row["deleted"] as? Bool ?? false,
                kind: (row["kind"] as? String).flatMap(CueKind.init(rawValue:))
            )
        }
        let missing = (result["missing_project_ids"] as? [Any] ?? []).compactMap(Self.string)
        return ChangeBatch(
            tasks: tasks,
            cursor: Self.string(result["cursor"]) ?? cursor,
            isFullSnapshot: false,
            missingProjectIDs: Set(missing)
        )
    }

    // MARK: Values

    /// IDs may arrive as strings or numbers.
    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}

enum MCPError: LocalizedError {
    case insecureURL
    case http(Int)
    case unauthorized
    case rpc(String)
    case tool(String, String)
    case missingTools([String])
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .insecureURL: "Use https, or http only for a server on this Mac (localhost)."
        case let .http(code): "The server answered with HTTP \(code)."
        case .unauthorized: "The server didn't accept the token."
        case let .rpc(message): "The server reported an error: \(message)"
        case let .tool(name, message): "\(name) failed: \(message)"
        case let .missingTools(names): "This server doesn't offer Cue sync. Missing: \(names.joined(separator: ", "))."
        case let .badResponse(what): "The server's reply to \(what) wasn't understood."
        }
    }
}

/// MCP over Streamable HTTP with plain URLSession: `initialize`, then
/// `notifications/initialized`, then tool calls. Replies may be JSON or an
/// event stream.
@MainActor
final class MCPClient {
    static let protocolVersion = "2025-06-18"

    let url: URL
    private var token: String?
    private var credentials: MCPCredentials?
    private let session: URLSession
    /// Called with refreshed sign-in credentials so they can be saved.
    private let onCredentialsChange: ((MCPCredentials) -> Void)?
    private var sessionID: String?
    private var negotiatedVersion: String?
    private var nextID = 1

    /// `token` is a pasted token or stored sign-in credentials (`MCPCredentials` JSON).
    init(url: URL, token: String?, session: URLSession = .shared, onCredentialsChange: ((MCPCredentials) -> Void)? = nil) {
        self.url = url
        self.session = session
        self.onCredentialsChange = onCredentialsChange
        if let token, let credentials = MCPCredentials.decode(token) {
            self.credentials = credentials
        } else {
            self.token = token?.isEmpty == true ? nil : token
        }
    }

    convenience init(url: URL, credentials: MCPCredentials, session: URLSession = .shared, onCredentialsChange: ((MCPCredentials) -> Void)? = nil) {
        self.init(url: url, token: credentials.encoded(), session: session, onCredentialsChange: onCredentialsChange)
    }

    private func refreshCredentials() async throws {
        guard let old = credentials else { throw MCPError.unauthorized }
        let fresh = try await MCPOAuth.refresh(old, session: session)
        credentials = fresh
        onCredentialsChange?(fresh)
    }

    func listTools() async throws -> [String] {
        try await ensureInitialized()
        let result = try await send("tools/list", [:])
        let tools = result?["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { $0["name"] as? String }
    }

    /// The tool's `structuredContent`, or its first text block read as JSON.
    func callTool(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        try await ensureInitialized()
        guard let result = try await send("tools/call", ["name": name, "arguments": arguments]) else {
            throw MCPError.badResponse(name)
        }
        let text = (result["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
        if result["isError"] as? Bool == true {
            throw MCPError.tool(name, text ?? "unknown error")
        }
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        if let text, let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        throw MCPError.badResponse(name)
    }

    private func ensureInitialized() async throws {
        guard negotiatedVersion == nil else { return }
        let result = try await send("initialize", [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "nano", "version": "1"],
        ], initializing: true)
        negotiatedVersion = result?["protocolVersion"] as? String ?? Self.protocolVersion
        _ = try await send("notifications/initialized", nil, notification: true)
    }

    /// One JSON-RPC message. A server that forgot the session (HTTP 404)
    /// gets a fresh `initialize` and one retry.
    private func send(
        _ method: String,
        _ params: [String: Any]?,
        notification: Bool = false,
        initializing: Bool = false,
        retried: Bool = false,
        refreshed: Bool = false
    ) async throws -> [String: Any]? {
        if let credentials, credentials.isExpired, !refreshed {
            try await refreshCredentials()
        }
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        let id = nextID
        if !notification {
            message["id"] = id
            nextID += 1
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: message)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let bearer = credentials?.accessToken ?? token {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        if !initializing { request.setValue(negotiatedVersion ?? Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.badResponse(method) }
        if http.statusCode == 404, sessionID != nil, !initializing, !retried {
            sessionID = nil
            negotiatedVersion = nil
            try await ensureInitialized()
            return try await send(method, params, notification: notification, retried: true)
        }
        if http.statusCode == 401, credentials != nil, !refreshed {
            try await refreshCredentials()
            return try await send(method, params, notification: notification, initializing: initializing, retried: retried, refreshed: true)
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw MCPError.unauthorized }
        guard (200 ..< 300).contains(http.statusCode) else { throw MCPError.http(http.statusCode) }
        if let header = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = header }
        if notification { return nil }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let messages = contentType.contains("text/event-stream") ? Self.events(in: data) : [data]
        for payload in messages {
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == id else { continue }
            if let error = object["error"] as? [String: Any] {
                throw MCPError.rpc(error["message"] as? String ?? "unknown")
            }
            return object["result"] as? [String: Any] ?? [:]
        }
        throw MCPError.badResponse(method)
    }

    /// The `data:` payload of each server-sent event.
    static func events(in data: Data) -> [Data] {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        return text.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst(5).drop { $0 == " " } }
            return lines.isEmpty ? nil : Data(lines.joined(separator: "\n").utf8)
        }
    }
}

/// Sync tokens, one per connected app, in the login Keychain. Test hosts
/// keep them in memory: the real items belong to the installed Nano, and
/// reading them from another build stops on a Keychain password prompt.
enum CueSyncKeychain {
    private static let service = "com.nanoapp.Nano.cue-sync"
    private static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    nonisolated(unsafe) private static var testTokens: [String: String] = [:]

    static func token(for account: String) -> String? {
        if isTestHost { return testTokens[account] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Nil or empty removes it.
    static func setToken(_ token: String?, for account: String) {
        if isTestHost {
            testTokens[account] = token?.isEmpty == false ? token : nil
            return
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = "Nano Cue sync"
        SecItemAdd(item as CFDictionary, nil)
    }
}
