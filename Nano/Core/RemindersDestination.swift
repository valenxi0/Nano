import EventKit
import Foundation

/// Apple Reminders through EventKit. A Cue folder maps to a reminders list.
/// Each reminder Cue syncs carries `nano://cue/<uuid>` in its URL field, which
/// is how a retried create finds the reminder it already made.
@MainActor
final class RemindersDestination: TaskDestination {
    static let kind = "reminders"
    static let record = CueSyncState.Destination(id: "reminders", kind: kind, name: "Apple Reminders")

    let id = RemindersDestination.record.id
    var onChange: (() -> Void)?
    /// Its own store, so Calendar's consent state and reload timing stay separate.
    private let eventStore = EKEventStore()
    private var observer: NSObjectProtocol?
    private var settleTask: Task<Void, Never>?

    enum Failure: LocalizedError {
        case noAccess
        case listMissing
        case fetchFailed

        var errorDescription: String? {
            switch self {
            case .noAccess: "Nano can't read Reminders. Allow it in System Settings > Privacy & Security > Reminders."
            case .listMissing: "That Reminders list no longer exists."
            case .fetchFailed: "Reminders didn't return its lists."
            }
        }
    }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleChange() }
        }
    }

    /// `authorizationStatus` keeps the answer it had when Nano started, so a
    /// grant made since then is remembered here.
    private static var grantedThisLaunch = false

    static var authorization: EKAuthorizationStatus {
        grantedThisLaunch ? .fullAccess : EKEventStore.authorizationStatus(for: .reminder)
    }

    static var hasAccess: Bool { authorization == .fullAccess }

    static func requestFullAccess(with store: EKEventStore = EKEventStore()) async -> Bool {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        if granted { grantedThisLaunch = true }
        return granted
    }

    /// Asked only when the user connects Reminders.
    func requestAccess() async throws -> Bool {
        await Self.requestFullAccess(with: eventStore)
    }

    /// EventKit posts a burst of changes for one sync. Report once it settles.
    private func scheduleChange() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }

    // MARK: TaskDestination

    func describe() async throws -> DestinationInfo {
        DestinationInfo(name: Self.record.name, twoWay: true, supportsDelete: true)
    }

    func listProjects() async throws -> [RemoteProject] {
        guard Self.hasAccess else { throw Failure.noAccess }
        return eventStore.calendars(for: .reminder)
            .map { RemoteProject(id: $0.calendarIdentifier, name: $0.title) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func listChanges(since cursor: String?, projectIDs: [String], known: [RemoteRef]) async throws -> ChangeBatch {
        guard Self.hasAccess else { throw Failure.noAccess }
        var calendars: [EKCalendar] = []
        var missing: Set<String> = []
        for id in projectIDs {
            if let calendar = eventStore.calendar(withIdentifier: id) {
                calendars.append(calendar)
            } else {
                missing.insert(id)
            }
        }
        // An empty list here would mean every list to EventKit.
        guard !calendars.isEmpty else {
            return ChangeBatch(tasks: [], cursor: nil, isFullSnapshot: true, missingProjectIDs: missing)
        }
        var tasks = try await fetch(in: calendars)

        // A linked reminder moved to a list no folder maps to.
        let seen = Set(tasks.map(\.ref.remoteID))
        for ref in known where !seen.contains(ref.remoteID) {
            if let reminder = reminder(for: ref) {
                tasks.append(Self.task(from: reminder))
            }
        }
        return ChangeBatch(tasks: tasks, cursor: nil, isFullSnapshot: true, missingProjectIDs: missing)
    }

    func upsertTask(_ task: OutgoingTask) async throws -> RemoteTask {
        guard Self.hasAccess else { throw Failure.noAccess }
        guard let calendar = eventStore.calendar(withIdentifier: task.projectID) else { throw Failure.listMissing }
        var reminder = task.ref.flatMap(reminder(for:))
        if reminder == nil {
            // A create retried after a crash finds the reminder by its cue link.
            let url = Self.url(for: task.externalID)
            let existing = try await fetchReminders(in: [calendar]).first { $0.url == url }
            reminder = existing
        }
        let target = reminder ?? EKReminder(eventStore: eventStore)
        target.calendar = calendar
        target.title = task.title
        target.notes = task.notes.isEmpty ? nil : task.notes
        target.url = Self.url(for: task.externalID)
        if target.isCompleted != task.done { target.isCompleted = task.done }
        try eventStore.save(target, commit: true)
        return Self.task(from: target)
    }

    func deleteTask(_ ref: RemoteRef, externalID: UUID) async throws {
        guard Self.hasAccess else { throw Failure.noAccess }
        guard let reminder = reminder(for: ref) else { return }
        try eventStore.remove(reminder, commit: true)
    }

    // MARK: Helpers

    /// By EventKit's local ID, then by the ID that survives an iCloud sync.
    private func reminder(for ref: RemoteRef) -> EKReminder? {
        if let reminder = eventStore.calendarItem(withIdentifier: ref.remoteID) as? EKReminder {
            return reminder
        }
        guard let stable = ref.stableID else { return nil }
        return eventStore.calendarItems(withExternalIdentifier: stable).compactMap { $0 as? EKReminder }.first
    }

    private func fetch(in calendars: [EKCalendar]) async throws -> [RemoteTask] {
        let predicate = eventStore.predicateForReminders(in: calendars)
        return try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                guard let reminders else { return continuation.resume(throwing: Failure.fetchFailed) }
                continuation.resume(returning: reminders.map(Self.task(from:)))
            }
        }
    }

    /// The reminders themselves, for the retry lookup on the main actor.
    private func fetchReminders(in calendars: [EKCalendar]) async throws -> [EKReminder] {
        let ids = try await fetch(in: calendars).map(\.ref.remoteID)
        return ids.compactMap { eventStore.calendarItem(withIdentifier: $0) as? EKReminder }
    }

    nonisolated static func url(for cueID: UUID) -> URL {
        URL(string: "nano://cue/\(cueID.uuidString)")!
    }

    nonisolated static func task(from reminder: EKReminder) -> RemoteTask {
        RemoteTask(
            ref: RemoteRef(remoteID: reminder.calendarItemIdentifier, stableID: reminder.calendarItemExternalIdentifier),
            externalID: reminder.url.flatMap(CueLink.cueID(from:)),
            title: reminder.title ?? "",
            notes: reminder.notes ?? "",
            projectID: reminder.calendar?.calendarIdentifier ?? "",
            done: reminder.isCompleted,
            updatedAt: reminder.lastModifiedDate ?? reminder.creationDate ?? .distantPast
        )
    }
}

/// `nano://cue/...` links.
enum CueLink {
    static func isCueLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "nano" && url.host?.lowercased() == "cue"
    }

    /// `nano://cue/<uuid>`.
    static func cueID(from url: URL) -> UUID? {
        guard isCueLink(url) else { return nil }
        return url.pathComponents.filter { $0 != "/" }.first.flatMap(UUID.init(uuidString:))
    }
}
