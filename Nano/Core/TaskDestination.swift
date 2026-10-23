import Foundation

/// An outside to-do app that Cue can sync with. Each app gets one adapter;
/// `CueSyncEngine` knows nothing about any particular app.
@MainActor
protocol TaskDestination: AnyObject {
    /// Stable for the life of the connection, e.g. "reminders".
    var id: String { get }
    /// Called when the app reports a change of its own, where it can.
    var onChange: (() -> Void)? { get set }

    func describe() async throws -> DestinationInfo
    func listProjects() async throws -> [RemoteProject]
    /// Creates the task, or updates it when one with `externalID` (or `ref`)
    /// already exists. Retrying with the same `externalID` must not duplicate.
    func upsertTask(_ task: OutgoingTask) async throws -> RemoteTask
    func deleteTask(_ ref: RemoteRef, externalID: UUID) async throws
    /// Tasks changed since `cursor` in `projectIDs`. A full snapshot must also
    /// include any task in `known` that now sits in another project, so a
    /// task moved elsewhere is not mistaken for a deleted one. Throws when the
    /// app can't be read; never returns an empty snapshot in place of an error.
    func listChanges(since cursor: String?, projectIDs: [String], known: [RemoteRef]) async throws -> ChangeBatch
    /// How often to pull when nothing else triggers a sync.
    var pollInterval: Duration { get }
}

extension TaskDestination {
    var pollInterval: Duration { .seconds(60) }
}

struct DestinationInfo: Equatable, Sendable {
    var name: String
    /// False for apps Cue can only send to.
    var twoWay: Bool
    var supportsDelete: Bool
    /// Prompts, ideas and links sync too, not only to-dos.
    var acceptsAllKinds = false
    /// Cue's images go along with each cue.
    var acceptsImages = false
}

/// One of a cue's images, as sent to an app.
struct OutgoingImage: Equatable, Sendable {
    var name: String
    var mimeType: String
    var data: Data
}

/// A list or project a Cue folder can map to.
struct RemoteProject: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
}

/// How to find one task in the other app. `stableID` is a second identifier
/// for apps whose own ID can change when they sync between devices.
struct RemoteRef: Codable, Equatable, Hashable, Sendable {
    var remoteID: String
    var stableID: String?
}

struct OutgoingTask: Equatable, Sendable {
    /// The cue's ID. Adapters dedupe on it wherever the app allows.
    var externalID: UUID
    var ref: RemoteRef?
    var title: String
    var notes: String
    var projectID: String
    var done: Bool
    /// Same value on every retry of the same create.
    var idempotencyKey: UUID
    /// What the app had at the last sync, when known, so an adapter can send
    /// only the changes (e.g. not complete an already completed task).
    var remoteDone: Bool?
    var remoteProjectID: String?
    var kind: CueKind = .todo
    /// The cue's whole image set when it changed; nil when unchanged or the
    /// app doesn't take images.
    var images: [OutgoingImage]?
}

struct RemoteTask: Equatable, Sendable {
    var ref: RemoteRef
    var externalID: UUID?
    var title: String
    var notes: String
    var projectID: String
    var done: Bool
    var updatedAt: Date
    var deleted = false
    /// Nil when the app doesn't track kinds.
    var kind: CueKind?
}

/// RFC 3339 dates, with or without fractional seconds of any length.
enum SyncDates {
    static func parse(_ value: Any?) -> Date? {
        guard var string = value as? String else { return nil }
        // ISO8601DateFormatter reads at most milliseconds.
        if let dot = string.firstIndex(of: "."),
           let end = string[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = string[string.index(after: dot) ..< end]
            if digits.count > 3 { string.replaceSubrange(string.index(dot, offsetBy: 4) ..< end, with: "") }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

struct ChangeBatch: Sendable {
    var tasks: [RemoteTask]
    var cursor: String?
    /// True when `tasks` lists every task in the requested projects, so a
    /// linked task that is missing was deleted.
    var isFullSnapshot: Bool
    /// Requested projects the app no longer has.
    var missingProjectIDs: Set<String> = []
}
