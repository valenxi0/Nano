import Foundation

/// Todoist through its Sync endpoint (API v1). Signs in with a personal API
/// token the user pastes; Todoist's OAuth needs a client secret, which an
/// open-source app can't keep.
///
/// Todoist has no field for Cue's ID, so a retried create relies on the
/// command `uuid`, which Todoist runs only once. The engine reuses the same
/// key on every retry of a create.
@MainActor
final class TodoistDestination: TaskDestination {
    static let kind = "todoist"
    static let record = CueSyncState.Destination(id: "todoist", kind: kind, name: "Todoist")
    static let endpoint = URL(string: "https://api.todoist.com/api/v1/sync")!

    let id = TodoistDestination.record.id
    var onChange: (() -> Void)?
    private let token: String
    private let session: URLSession

    enum Failure: LocalizedError {
        case unauthorized
        case rateLimited
        case http(Int)
        case command(String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .unauthorized: "Todoist didn't accept the API token. Copy it again from Todoist's Settings > Integrations > Developer."
            case .rateLimited: "Todoist asked Nano to slow down. Sync will try again shortly."
            case let .http(code): "Todoist answered with HTTP \(code)."
            case let .command(message): "Todoist refused a change: \(message)"
            case .badResponse: "Todoist's reply wasn't understood."
            }
        }
    }

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    static func make(_ record: CueSyncState.Destination) -> TodoistDestination? {
        CueSyncKeychain.token(for: record.id).map { TodoistDestination(token: $0) }
    }

    // MARK: TaskDestination

    func describe() async throws -> DestinationInfo {
        DestinationInfo(name: Self.record.name, twoWay: true, supportsDelete: true)
    }

    func listProjects() async throws -> [RemoteProject] {
        let reply = try await sync(["sync_token": "*", "resource_types": ["projects"]])
        let projects = reply["projects"] as? [[String: Any]] ?? []
        return projects.compactMap { project in
            guard let id = project["id"] as? String,
                  project["is_deleted"] as? Bool != true,
                  project["is_archived"] as? Bool != true else { return nil }
            return RemoteProject(id: id, name: project["name"] as? String ?? id)
        }
    }

    /// Incremental: Todoist returns tasks changed since the token, including
    /// completed (`checked`) and deleted (`is_deleted`) ones.
    func listChanges(since cursor: String?, projectIDs: [String], known: [RemoteRef]) async throws -> ChangeBatch {
        let reply = try await sync(["sync_token": cursor ?? "*", "resource_types": ["items", "projects"]])
        let items = reply["items"] as? [[String: Any]] ?? []
        let tasks = items.compactMap { item -> RemoteTask? in
            guard let id = item["id"] as? String else { return nil }
            return RemoteTask(
                ref: RemoteRef(remoteID: id, stableID: nil),
                externalID: nil,
                title: item["content"] as? String ?? "",
                notes: item["description"] as? String ?? "",
                projectID: item["project_id"] as? String ?? "",
                done: item["checked"] as? Bool ?? false,
                updatedAt: SyncDates.parse(item["updated_at"])
                    ?? SyncDates.parse(item["completed_at"])
                    ?? SyncDates.parse(item["added_at"])
                    ?? .distantPast,
                deleted: item["is_deleted"] as? Bool ?? false
            )
        }

        let requested = Set(projectIDs)
        let projects = reply["projects"] as? [[String: Any]] ?? []
        var missing = Set(projects.compactMap { project -> String? in
            guard let id = project["id"] as? String, requested.contains(id),
                  project["is_deleted"] as? Bool == true || project["is_archived"] as? Bool == true else { return nil }
            return id
        })
        if reply["full_sync"] as? Bool == true {
            let present = Set(projects.compactMap { $0["id"] as? String })
            missing.formUnion(requested.subtracting(present))
        }
        return ChangeBatch(
            tasks: tasks,
            cursor: reply["sync_token"] as? String ?? cursor,
            isFullSnapshot: false,
            missingProjectIDs: missing
        )
    }

    func upsertTask(_ task: OutgoingTask) async throws -> RemoteTask {
        var commands: [[String: Any]] = []
        let taskID: String
        if let ref = task.ref {
            taskID = ref.remoteID
            commands.append(Self.command("item_update", ["id": taskID, "content": task.title, "description": task.notes]))
            if task.remoteProjectID != task.projectID {
                commands.append(Self.command("item_move", ["id": taskID, "project_id": task.projectID]))
            }
        } else {
            // The same key on every retry, so Todoist adds it only once.
            taskID = task.idempotencyKey.uuidString
            var add = Self.command("item_add", [
                "content": task.title,
                "description": task.notes,
                "project_id": task.projectID,
            ], uuid: task.idempotencyKey.uuidString)
            add["temp_id"] = taskID
            commands.append(add)
        }
        if task.done != (task.remoteDone ?? false) {
            commands.append(task.done
                ? Self.command("item_complete", ["id": taskID, "completed_at": SyncDates.format(Date())])
                : Self.command("item_uncomplete", ["id": taskID]))
        }

        let reply = try await sync(["commands": commands])
        try Self.check(reply, commands)
        var realID = taskID
        if task.ref == nil {
            let mapping = reply["temp_id_mapping"] as? [String: String] ?? [:]
            if let mapped = mapping[taskID] {
                realID = mapped
            } else {
                // A repeated command can come back "ok" without the new ID.
                // Create once more under a fresh key rather than stay stuck.
                var fresh = task
                fresh.idempotencyKey = UUID()
                return try await upsertTask(fresh)
            }
        }
        return RemoteTask(
            ref: RemoteRef(remoteID: realID, stableID: nil),
            externalID: task.externalID,
            title: task.title,
            notes: task.notes,
            projectID: task.projectID,
            done: task.done,
            updatedAt: Date()
        )
    }

    func deleteTask(_ ref: RemoteRef, externalID: UUID) async throws {
        let commands = [Self.command("item_delete", ["id": ref.remoteID])]
        let reply = try await sync(["commands": commands])
        try Self.check(reply, commands, ignoringNotFound: true)
    }

    // MARK: Requests

    private static func command(_ type: String, _ args: [String: Any], uuid: String = UUID().uuidString) -> [String: Any] {
        ["type": type, "uuid": uuid, "args": args]
    }

    /// Every command must come back "ok".
    private static func check(_ reply: [String: Any], _ commands: [[String: Any]], ignoringNotFound: Bool = false) throws {
        let statuses = reply["sync_status"] as? [String: Any] ?? [:]
        for command in commands {
            guard let uuid = command["uuid"] as? String else { continue }
            let status = statuses[uuid]
            if status as? String == "ok" { continue }
            if let error = status as? [String: Any] {
                if ignoringNotFound, error["http_code"] as? Int == 404 { continue }
                throw Failure.command(error["error"] as? String ?? error["error_tag"] as? String ?? "unknown")
            }
            throw Failure.badResponse
        }
    }

    private func sync(_ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        switch http.statusCode {
        case 200 ..< 300: break
        case 401, 403: throw Failure.unauthorized
        case 429: throw Failure.rateLimited
        default: throw Failure.http(http.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.badResponse }
        return object
    }
}
