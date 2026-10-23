import Foundation

/// What sync remembers between passes, kept in `sync.json` next to `cue.json`.
/// Tokens never go here; they live in the Keychain.
struct CueSyncState: Codable, Equatable {
    struct Destination: Codable, Equatable, Identifiable {
        var id: String
        var kind: String
        var name: String
        var settings: [String: String] = [:]
    }

    /// A Cue folder (nil is the Inbox) mapped to a project in one app.
    struct FolderLink: Codable, Equatable {
        var folderID: UUID?
        var destinationID: String
        var projectID: String
        var projectName: String
    }

    /// Both sides as of the last successful sync.
    struct Snapshot: Codable, Equatable {
        var title: String
        var notes: String
        var done: Bool
        var projectID: String
        var remoteUpdatedAt: Date
        var kind: CueKind?
        /// Image file names last sent.
        var images: [String]?
    }

    struct Link: Codable, Equatable {
        var destinationID: String
        var ref: RemoteRef
        var snapshot: Snapshot
    }

    /// A create that may have reached the app before Nano stopped.
    struct Pending: Codable, Equatable {
        var destinationID: String
        var key: UUID
    }

    var destinations: [Destination] = []
    var folderLinks: [FolderLink] = []
    /// Keyed by cue ID.
    var links: [String: Link] = [:]
    var pending: [String: Pending] = [:]
    var cursors: [String: String] = [:]
}

/// Two-way sync between Cue's to-dos and any number of `TaskDestination`s.
///
/// Each pass pulls what changed in the app, compares three versions of every
/// linked task (Cue now, the app now, the last-synced snapshot) field by
/// field, then writes both sides. Only to-dos in linked folders sync.
@MainActor
final class CueSyncEngine: ObservableObject {
    struct Status: Equatable {
        var info: DestinationInfo?
        var lastSync: Date?
        var error: String?
        var isSyncing = false
    }

    /// A pass that stopped because it would have deleted a lot at once.
    struct HeldDeletes: Equatable {
        var destinationID: String
        var count: Int
    }

    @Published private(set) var state = CueSyncState()
    @Published private(set) var statuses: [String: Status] = [:]
    @Published private(set) var projects: [String: [RemoteProject]] = [:]
    @Published private(set) var heldDeletes: HeldDeletes?
    /// Short messages for the Sync tab, such as a list that was removed.
    @Published private(set) var notices: [String] = []

    let store: CueStore
    private let stateURL: URL
    private let makeDestination: (CueSyncState.Destination) -> TaskDestination?
    private var destinations: [String: TaskDestination] = [:]
    private var allowsDeletesOnce: Set<String> = []
    private var running = false
    private var rerun = false
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Wait after a change in Cue, so a burst of edits goes out as one pass.
    var debounce: Duration = .milliseconds(500)
    /// How often the poll loop checks which apps are due (each app sets its
    /// own `pollInterval`).
    var pollTick: Duration = .seconds(1)
    private var lastPass: [String: ContinuousClock.Instant] = [:]

    init(
        store: CueStore,
        stateURL: URL? = nil,
        makeDestination: @escaping (CueSyncState.Destination) -> TaskDestination?
    ) {
        self.store = store
        self.stateURL = stateURL ?? store.directoryURL.appendingPathComponent("sync.json")
        self.makeDestination = makeDestination
        loadState()
        for record in state.destinations {
            if let destination = makeDestination(record) { attach(destination) }
        }
        if !destinations.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                for id in self.destinations.keys.sorted() { await self.refresh(id) }
            }
        }
        store.onChange = { [weak self] in self?.requestSync() }
    }

    var connectedDestinations: [CueSyncState.Destination] { state.destinations }

    /// Connected apps a folder can sync with; send-only apps are left out.
    var twoWayDestinations: [CueSyncState.Destination] {
        state.destinations.filter { statuses[$0.id]?.info?.twoWay != false }
    }

    func destination(_ id: String) -> TaskDestination? { destinations[id] }

    func folderLink(for folderID: UUID?) -> CueSyncState.FolderLink? {
        state.folderLinks.first { $0.folderID == folderID }
    }

    // MARK: Connecting

    func connect(_ record: CueSyncState.Destination, destination: TaskDestination) {
        state.destinations.removeAll { $0.id == record.id }
        state.destinations.append(record)
        attach(destination)
        saveState()
        Task { await refresh(record.id) }
        requestSync()
    }

    /// Leaves both sides as they are and forgets every link to the app.
    func disconnect(_ id: String) {
        destinations[id]?.onChange = nil
        destinations[id] = nil
        state.destinations.removeAll { $0.id == id }
        state.folderLinks.removeAll { $0.destinationID == id }
        state.links = state.links.filter { $0.value.destinationID != id }
        state.pending = state.pending.filter { $0.value.destinationID != id }
        state.cursors[id] = nil
        statuses[id] = nil
        projects[id] = nil
        if heldDeletes?.destinationID == id { heldDeletes = nil }
        saveState()
    }

    /// Maps a folder (nil is the Inbox) to a project, or unlinks it.
    func link(folderID: UUID?, destinationID: String, project: RemoteProject?) {
        state.folderLinks.removeAll { $0.folderID == folderID }
        if let project {
            state.folderLinks.append(CueSyncState.FolderLink(
                folderID: folderID,
                destinationID: destinationID,
                projectID: project.id,
                projectName: project.name
            ))
        }
        saveState()
        requestSync()
    }

    func unlink(folderID: UUID?) {
        state.folderLinks.removeAll { $0.folderID == folderID }
        saveState()
        requestSync()
    }

    func refresh(_ id: String) async {
        guard let destination = destinations[id] else { return }
        do {
            let info = try await destination.describe()
            statuses[id, default: Status()].info = info
            projects[id] = try await destination.listProjects()
            statuses[id, default: Status()].error = nil
        } catch {
            statuses[id, default: Status()].error = error.localizedDescription
        }
    }

    func dismissNotice(_ notice: String) {
        notices.removeAll { $0 == notice }
    }

    func continueHeldDeletes() {
        guard let held = heldDeletes else { return }
        allowsDeletesOnce.insert(held.destinationID)
        heldDeletes = nil
        requestSync()
    }

    // MARK: Send to

    /// A one-time copy of any cue. No link is kept; the cue's ID still goes
    /// with it, so sending again updates the same task.
    func send(_ cueID: UUID, to destinationID: String, projectID: String) async throws {
        guard let item = store.items.first(where: { $0.id == cueID }),
              let destination = destinations[destinationID] else { return }
        let info = statuses[destinationID]?.info ?? Self.todoOnly
        let (title, notes) = Self.split(item.text)
        _ = try await destination.upsertTask(OutgoingTask(
            externalID: item.id,
            ref: nil,
            title: title.isEmpty ? item.headline : title,
            notes: notes,
            projectID: projectID,
            done: item.isDone,
            idempotencyKey: UUID(),
            kind: info.acceptsAllKinds ? item.kind : .todo,
            images: info.acceptsImages ? loadImages(item.images) : nil
        ))
    }

    // MARK: Scheduling

    func requestSync() {
        guard !state.destinations.isEmpty else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Pulls from each app on its own schedule: every few seconds for a
    /// server on this Mac, about once a minute for services on the internet.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let tick = self?.pollTick else { return }
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled, let self else { return }
                let now = ContinuousClock.now
                let due = self.state.destinations.compactMap { self.destinations[$0.id] }.filter { destination in
                    self.lastPass[destination.id].map { now - $0 >= destination.pollInterval } ?? true
                }
                if !due.isEmpty { await self.sync(due.map(\.id)) }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        debounceTask?.cancel()
    }

    /// Runs a pass for every connected app. A request during a pass runs
    /// one more pass afterwards.
    func syncNow() async {
        await sync(nil)
    }

    /// `ids` nil means every app. A pass already running picks up the request
    /// as one more pass for every app.
    private func sync(_ ids: [String]?) async {
        if running {
            rerun = true
            return
        }
        running = true
        var only = ids.map(Set.init)
        repeat {
            rerun = false
            for record in state.destinations where only?.contains(record.id) ?? true {
                guard let destination = destinations[record.id] else { continue }
                await pass(destination)
                lastPass[record.id] = .now
            }
            only = nil
        } while rerun
        running = false
    }

    private func attach(_ destination: TaskDestination) {
        destinations[destination.id] = destination
        destination.onChange = { [weak self] in self?.requestSync() }
    }

    // MARK: The pass

    fileprivate struct Fields: Equatable {
        var title: String
        var notes: String
        var done: Bool
        var projectID: String
        var kind: CueKind = .todo
        var images: [String] = []
    }

    /// What an app that hasn't described itself is assumed to take.
    private static let todoOnly = DestinationInfo(name: "", twoWay: true, supportsDelete: true)

    /// To-dos always; other kinds only for apps that take them. A cue needs
    /// text, or images for an app that takes images.
    private static func syncs(_ cue: CueItem, _ info: DestinationInfo) -> Bool {
        (cue.kind == .todo || info.acceptsAllKinds)
            && (!cue.text.isEmpty || (info.acceptsImages && !cue.images.isEmpty))
    }

    /// A cue as the app should see it. Kind and images are left at their
    /// defaults for apps that don't take them, so they never look changed.
    private static func fields(_ cue: CueItem, project: String, _ info: DestinationInfo) -> Fields {
        let (title, notes) = split(cue.text)
        return Fields(
            title: title.isEmpty && !cue.images.isEmpty ? "Image" : title,
            notes: notes,
            done: cue.isDone,
            projectID: project,
            kind: info.acceptsAllKinds ? cue.kind : .todo,
            images: info.acceptsImages ? cue.images : []
        )
    }

    private func loadImages(_ names: [String]) -> [OutgoingImage] {
        names.compactMap { name in
            (try? Data(contentsOf: store.imageURL(named: name))).map {
                OutgoingImage(name: name, mimeType: "image/png", data: $0)
            }
        }
    }

    private func pass(_ destination: TaskDestination) async {
        let id = destination.id
        guard !store.libraryIsUnreadable else {
            statuses[id, default: Status()].error = "Cue's library couldn't be read, so sync is paused."
            return
        }
        // Apps Cue can only send to have nothing to pull.
        if statuses[id]?.info == nil { await refresh(id) }
        if statuses[id]?.info?.twoWay == false { return }
        statuses[id, default: Status()].isSyncing = true
        defer { statuses[id]?.isSyncing = false }

        let info = statuses[id]?.info ?? Self.todoOnly
        pruneFolderLinks()
        // Creates that may have reached the app before Nano heard back go
        // first, so the pull below sees their tasks as linked, not new.
        guard await retryPendingCreates(destination, info) else { return }
        let projectIDs = Array(Set(state.folderLinks.filter { $0.destinationID == id }.map(\.projectID))).sorted()
        let known = state.links.values.filter { $0.destinationID == id }.map(\.ref)

        let batch: ChangeBatch
        if projectIDs.isEmpty {
            batch = ChangeBatch(tasks: [], cursor: state.cursors[id], isFullSnapshot: false)
        } else {
            do {
                batch = try await destination.listChanges(since: state.cursors[id], projectIDs: projectIDs, known: known)
            } catch {
                statuses[id, default: Status()].error = error.localizedDescription
                return
            }
        }

        if !batch.missingProjectIDs.isEmpty {
            for link in state.folderLinks where link.destinationID == id && batch.missingProjectIDs.contains(link.projectID) {
                notices.append("\u{201C}\(link.projectName)\u{201D} no longer exists, so its folder stopped syncing.")
            }
            state.folderLinks.removeAll { $0.destinationID == id && batch.missingProjectIDs.contains($0.projectID) }
        }

        // Everything below reads Cue as it is now, after the await.
        var projectForFolder: [UUID?: String] = [:]
        var folderForProject: [String: UUID?] = [:]
        for link in state.folderLinks where link.destinationID == id {
            projectForFolder[link.folderID] = link.projectID
            if folderForProject[link.projectID] == nil { folderForProject[link.projectID] = .some(link.folderID) }
        }
        let linkedProjects = Set(projectForFolder.values)
        let pendingUndo = store.pendingUndoIDs
        let itemsByID = Dictionary(store.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var ownLinks: [UUID: CueSyncState.Link] = [:]
        var cueByRemoteID: [String: UUID] = [:]
        var cueByStableID: [String: UUID] = [:]
        for (key, link) in state.links where link.destinationID == id {
            guard let cueID = UUID(uuidString: key) else { continue }
            ownLinks[cueID] = link
            cueByRemoteID[link.ref.remoteID] = cueID
            if let stable = link.ref.stableID { cueByStableID[stable] = cueID }
        }

        var remoteByCue: [UUID: RemoteTask] = [:]
        var unmatched: [RemoteTask] = []
        for task in batch.tasks {
            if let external = task.externalID, ownLinks[external] != nil {
                remoteByCue[external] = task
            } else if let cueID = cueByRemoteID[task.ref.remoteID] {
                remoteByCue[cueID] = task
            } else if let stable = task.ref.stableID, let cueID = cueByStableID[stable] {
                remoteByCue[cueID] = task
            } else {
                unmatched.append(task)
            }
        }

        var localEdits: [CueStore.SyncEdit] = []
        var upserts: [(cueID: UUID, task: OutgoingTask, fields: Fields, fallback: CueSyncState.Snapshot?)] = []
        var remoteDeletes: [(cueID: UUID, ref: RemoteRef)] = []
        var dropped: Set<UUID> = []
        var updatedLinks: [UUID: CueSyncState.Link] = [:]
        var localDeletes: [UUID] = []
        var deletedProject: [UUID: String] = [:]

        for (cueID, link) in ownLinks {
            if pendingUndo.contains(cueID) { continue }
            let base = Fields(link.snapshot)
            let remote = remoteByCue[cueID]
            let remoteGone = remote?.deleted == true
                || (batch.isFullSnapshot && remote == nil && linkedProjects.contains(link.snapshot.projectID))
            var rem = remote.map { Fields($0, base: base) } ?? base
            // An edit that empties the task keeps Cue's text.
            if rem.title.isEmpty, rem.notes.isEmpty {
                rem.title = base.title
                rem.notes = base.notes
            }

            guard let cue = itemsByID[cueID] else {
                // Deleted in Cue.
                if remoteGone {
                    dropped.insert(cueID)
                } else if let remote, rem != base {
                    // Edited in the app after the delete: keep the edited one.
                    if let folder = folderForProject[rem.projectID] {
                        localEdits.append(.insert(CueItem(
                            id: cueID,
                            text: Self.compose(rem.title, rem.notes),
                            kind: rem.kind,
                            folderID: folder,
                            images: [],
                            sourceApp: nil,
                            createdAt: remote.updatedAt,
                            completedAt: rem.done ? remote.updatedAt : nil,
                            updatedAt: remote.updatedAt
                        )))
                        updatedLinks[cueID] = CueSyncState.Link(
                            destinationID: id,
                            ref: remote.ref,
                            snapshot: Self.snapshot(rem, remote.updatedAt)
                        )
                    } else {
                        dropped.insert(cueID)
                    }
                } else {
                    remoteDeletes.append((cueID, remote?.ref ?? link.ref))
                    if !link.snapshot.done { deletedProject[cueID] = link.snapshot.projectID }
                }
                continue
            }

            guard Self.syncs(cue, info), let target = projectForFolder[cue.folderID] else {
                dropped.insert(cueID)
                continue
            }
            let local = Self.fields(cue, project: target, info)

            if remoteGone {
                if local != base {
                    // Edited in Cue after the delete: send it again.
                    upserts.append((cueID, outgoing(cueID, local, ref: nil, info: info), local, nil))
                } else {
                    localDeletes.append(cueID)
                    if !link.snapshot.done { deletedProject[cueID] = link.snapshot.projectID }
                }
                continue
            }

            var merged = local
            let remoteIsNewer = (remote?.updatedAt ?? .distantPast) > cue.updatedAt
            let localText = (local.title, local.notes) != (base.title, base.notes)
            let remoteText = (rem.title, rem.notes) != (base.title, base.notes)
            if remoteText, !localText || remoteIsNewer {
                merged.title = rem.title
                merged.notes = rem.notes
            }
            if rem.kind != base.kind, local.kind == base.kind || remoteIsNewer {
                merged.kind = rem.kind
            }
            if rem.done != base.done { merged.done = rem.done }
            var movedTo: UUID??
            if rem.projectID != base.projectID {
                guard let folder = folderForProject[rem.projectID] else {
                    // Moved to a list no folder is linked to.
                    dropped.insert(cueID)
                    continue
                }
                merged.projectID = rem.projectID
                if folder != cue.folderID { movedTo = .some(folder) }
            }

            let textChanged = (merged.title, merged.notes) != (local.title, local.notes)
            let kindChanged = merged.kind != local.kind
            if textChanged || merged.done != local.done || movedTo != nil || kindChanged {
                localEdits.append(.update(
                    id: cueID,
                    expected: cue.updatedAt,
                    text: textChanged ? Self.compose(merged.title, merged.notes) : nil,
                    done: merged.done != local.done ? merged.done : nil,
                    folderID: movedTo,
                    kind: kindChanged ? merged.kind : nil
                ))
            }

            let needsPush = merged != rem || (remote != nil && remote?.externalID != cueID)
            let remoteTime = remote?.updatedAt ?? link.snapshot.remoteUpdatedAt
            if needsPush {
                upserts.append((cueID, outgoing(cueID, merged, ref: remote?.ref ?? link.ref, had: rem, info: info), merged, Self.snapshot(rem, remoteTime)))
            } else {
                let next = CueSyncState.Link(destinationID: id, ref: remote?.ref ?? link.ref, snapshot: Self.snapshot(merged, remoteTime))
                if next != link { updatedLinks[cueID] = next }
            }
        }

        // Tasks Cue has no link for.
        var newLinks: [UUID: CueSyncState.Link] = [:]
        for task in unmatched where !task.deleted && linkedProjects.contains(task.projectID) {
            if let external = task.externalID {
                // Created by Cue, but the link wasn't saved: adopt it.
                if let cue = itemsByID[external], Self.syncs(cue, info),
                   projectForFolder[cue.folderID] == task.projectID,
                   state.links[external.uuidString] == nil {
                    state.pending[external.uuidString] = nil
                    // Images aren't reported back, so assume they arrived.
                    var fields = Fields(task, base: nil)
                    fields.images = Self.fields(cue, project: task.projectID, info).images
                    newLinks[external] = CueSyncState.Link(
                        destinationID: id,
                        ref: task.ref,
                        snapshot: Self.snapshot(fields, task.updatedAt)
                    )
                }
                continue
            }
            guard !task.done, let folder = folderForProject[task.projectID] else { continue }
            let cueID = UUID()
            let fields = Fields(task, base: nil)
            localEdits.append(.insert(CueItem(
                id: cueID,
                text: Self.compose(fields.title, fields.notes),
                kind: info.acceptsAllKinds ? fields.kind : .todo,
                folderID: folder,
                images: [],
                sourceApp: nil,
                createdAt: task.updatedAt,
                completedAt: nil,
                updatedAt: task.updatedAt
            )))
            newLinks[cueID] = CueSyncState.Link(destinationID: id, ref: task.ref, snapshot: Self.snapshot(fields, task.updatedAt))
            // Writes the cue's ID back to the task.
            upserts.append((cueID, outgoing(cueID, fields, ref: task.ref, had: fields, info: info), fields, Self.snapshot(fields, task.updatedAt)))
        }

        // Cues the app doesn't have yet.
        for cue in store.items where !cue.isDone && Self.syncs(cue, info) {
            guard state.links[cue.id.uuidString] == nil, newLinks[cue.id] == nil,
                  !pendingUndo.contains(cue.id),
                  let project = projectForFolder[cue.folderID] else { continue }
            let fields = Self.fields(cue, project: project, info)
            let key = state.pending[cue.id.uuidString].flatMap { $0.destinationID == id ? $0.key : nil } ?? UUID()
            state.pending[cue.id.uuidString] = CueSyncState.Pending(destinationID: id, key: key)
            upserts.append((cue.id, outgoing(cue.id, fields, ref: nil, info: info, key: key), fields, nil))
        }

        // Backstop against mass deletion, e.g. an app that wrongly reports
        // an empty list. Finished tasks don't count, so clearing done cues
        // never trips it.
        let deleteCount = deletedProject.count
        if deleteCount >= 3, !allowsDeletesOnce.contains(id) {
            var perProject: [String: Int] = [:]
            for project in deletedProject.values { perProject[project, default: 0] += 1 }
            var sizes: [String: Int] = [:]
            for link in ownLinks.values { sizes[link.snapshot.projectID, default: 0] += 1 }
            let tooMany = deleteCount > 10 || perProject.contains { $0.value * 4 > (sizes[$0.key] ?? 0) }
            if tooMany {
                heldDeletes = HeldDeletes(destinationID: id, count: deleteCount)
                // Pending markers are safe to keep; nothing else is written.
                saveState()
                return
            }
        }
        allowsDeletesOnce.remove(id)

        saveState()
        store.applySyncEdits(localEdits + localDeletes.map { .delete($0) })

        for cueID in dropped { state.links[cueID.uuidString] = nil }
        for cueID in localDeletes { state.links[cueID.uuidString] = nil }
        for (cueID, link) in updatedLinks { state.links[cueID.uuidString] = link }
        for (cueID, link) in newLinks { state.links[cueID.uuidString] = link }
        state.cursors[id] = batch.cursor

        var failure: String?
        for upsert in upserts {
            if failure == nil {
                do {
                    let result = try await destination.upsertTask(upsert.task)
                    state.links[upsert.cueID.uuidString] = CueSyncState.Link(
                        destinationID: id,
                        ref: result.ref,
                        snapshot: Self.snapshot(upsert.fields, result.updatedAt)
                    )
                    state.pending[upsert.cueID.uuidString] = nil
                    continue
                } catch {
                    failure = error.localizedDescription
                }
            }
            // Not sent: remember the app's side, so the next pass sees Cue's
            // change and sends it.
            if let fallback = upsert.fallback, var link = state.links[upsert.cueID.uuidString] {
                link.snapshot = fallback
                state.links[upsert.cueID.uuidString] = link
            }
        }
        for delete in remoteDeletes where failure == nil {
            do {
                try await destination.deleteTask(delete.ref, externalID: delete.cueID)
                state.links[delete.cueID.uuidString] = nil
            } catch {
                failure = error.localizedDescription
            }
        }

        saveState()
        statuses[id, default: Status()].error = failure
        if failure == nil { statuses[id, default: Status()].lastSync = Date() }
    }

    /// Resends unfinished creates under their original key. False if one failed.
    private func retryPendingCreates(_ destination: TaskDestination, _ info: DestinationInfo) async -> Bool {
        let id = destination.id
        for (key, pending) in state.pending where pending.destinationID == id {
            guard let cueID = UUID(uuidString: key), state.links[key] == nil,
                  let cue = store.items.first(where: { $0.id == cueID }),
                  Self.syncs(cue, info),
                  let project = state.folderLinks.first(where: { $0.destinationID == id && $0.folderID == cue.folderID })?.projectID
            else {
                state.pending[key] = nil
                continue
            }
            let fields = Self.fields(cue, project: project, info)
            do {
                let result = try await destination.upsertTask(outgoing(cueID, fields, ref: nil, info: info, key: pending.key))
                state.links[key] = CueSyncState.Link(destinationID: id, ref: result.ref, snapshot: Self.snapshot(fields, result.updatedAt))
                state.pending[key] = nil
            } catch {
                statuses[id, default: Status()].error = error.localizedDescription
                saveState()
                return false
            }
        }
        saveState()
        return true
    }

    /// Drops links for folders that are gone, but not one whose Undo is on offer.
    private func pruneFolderLinks() {
        let folderIDs = Set(store.folders.map(\.id))
        let pending = store.pendingUndoFolderID
        state.folderLinks.removeAll { link in
            guard let folderID = link.folderID else { return false }
            return !folderIDs.contains(folderID) && folderID != pending
        }
    }

    /// Images go only when the set changed since the app last had it.
    private func outgoing(
        _ cueID: UUID,
        _ fields: Fields,
        ref: RemoteRef?,
        had: Fields? = nil,
        info: DestinationInfo,
        key: UUID = UUID()
    ) -> OutgoingTask {
        let imagesChanged = fields.images != (had?.images ?? [])
        return OutgoingTask(
            externalID: cueID,
            ref: ref,
            title: fields.title,
            notes: fields.notes,
            projectID: fields.projectID,
            done: fields.done,
            idempotencyKey: key,
            remoteDone: had?.done,
            remoteProjectID: had?.projectID,
            kind: fields.kind,
            images: info.acceptsImages && imagesChanged ? loadImages(fields.images) : nil
        )
    }

    private static func snapshot(_ fields: Fields, _ remoteUpdatedAt: Date) -> CueSyncState.Snapshot {
        CueSyncState.Snapshot(
            title: fields.title,
            notes: fields.notes,
            done: fields.done,
            projectID: fields.projectID,
            remoteUpdatedAt: remoteUpdatedAt,
            kind: fields.kind,
            images: fields.images
        )
    }

    // MARK: Text

    /// The first line is the title; the rest is notes.
    static func split(_ text: String) -> (title: String, notes: String) {
        guard let newline = text.firstIndex(of: "\n") else {
            return (text.trimmingCharacters(in: .whitespaces), "")
        }
        return (
            text[..<newline].trimmingCharacters(in: .whitespaces),
            text[text.index(after: newline)...].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func compose(_ title: String, _ notes: String) -> String {
        notes.isEmpty ? title : "\(title)\n\(notes)"
    }

    // MARK: Persistence

    private func loadState() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            state = try decoder.decode(CueSyncState.self, from: Data(contentsOf: stateURL))
        } catch {
            // Start over rather than stop: links are rebuilt from the cue IDs
            // the apps already hold.
            let aside = stateURL.deletingPathExtension().appendingPathExtension("bad.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: stateURL, to: aside)
        }
    }

    private func saveState() {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        } catch {
            notices.append("Sync couldn't save its state: \(error.localizedDescription)")
        }
    }
}

private extension CueSyncEngine.Fields {
    init(_ snapshot: CueSyncState.Snapshot) {
        self.init(
            title: snapshot.title,
            notes: snapshot.notes,
            done: snapshot.done,
            projectID: snapshot.projectID,
            kind: snapshot.kind ?? .todo,
            images: snapshot.images ?? []
        )
    }

    /// Apps don't report images, and may not report kinds; those come from
    /// `base`, the last-synced state.
    init(_ task: RemoteTask, base: CueSyncEngine.Fields?) {
        self.init(
            title: task.title,
            notes: task.notes,
            done: task.done,
            projectID: task.projectID,
            kind: task.kind ?? base?.kind ?? .todo,
            images: base?.images ?? []
        )
    }
}
