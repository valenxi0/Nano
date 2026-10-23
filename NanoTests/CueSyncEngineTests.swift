import XCTest
@testable import Nano

/// An in-memory to-do app. Dedupes on the cue's ID like a real adapter must.
@MainActor
final class FakeTaskDestination: TaskDestination {
    struct Stored {
        var task: RemoteTask
        var version: Int
    }

    let id: String
    var onChange: (() -> Void)?
    var isFullSnapshot = true
    var projects = [RemoteProject(id: "p1", name: "One"), RemoteProject(id: "p2", name: "Two"), RemoteProject(id: "p3", name: "Three")]
    private(set) var stored: [String: Stored] = [:]
    private(set) var upsertCount = 0
    private var version = 0
    private var nextID = 0
    /// The next upsert reaches the app, then throws, as if Nano quit before saving the link.
    var failAfterNextWrite = false
    var failsPulls = false
    var failsWrites = false
    var pollInterval: Duration = .seconds(60)
    private(set) var pullCount = 0

    init(id: String = "fake") {
        self.id = id
    }

    var live: [RemoteTask] { stored.values.map(\.task).filter { !$0.deleted } }

    func task(for cueID: UUID) -> RemoteTask? {
        live.first { $0.externalID == cueID }
    }

    var info = DestinationInfo(name: "Fake", twoWay: true, supportsDelete: true)
    /// Every image set sent, by cue, in order. Nil entries mean "unchanged".
    private(set) var imageSends: [UUID: [[OutgoingImage]?]] = [:]

    func describe() async throws -> DestinationInfo { info }

    var failsProjects = false

    func listProjects() async throws -> [RemoteProject] {
        if failsProjects { throw URLError(.userAuthenticationRequired) }
        return projects
    }

    func upsertTask(_ outgoing: OutgoingTask) async throws -> RemoteTask {
        if failsWrites { throw URLError(.notConnectedToInternet) }
        upsertCount += 1
        let existing = outgoing.ref.flatMap { ref in stored[ref.remoteID].map { _ in ref.remoteID } }
            ?? stored.first { !$0.value.task.deleted && $0.value.task.externalID == outgoing.externalID }?.key
        let remoteID = existing ?? { nextID += 1; return "r\(nextID)" }()
        let task = RemoteTask(
            ref: RemoteRef(remoteID: remoteID, stableID: "s-\(remoteID)"),
            externalID: outgoing.externalID,
            title: outgoing.title,
            notes: outgoing.notes,
            projectID: outgoing.projectID,
            done: outgoing.done,
            updatedAt: Date(),
            kind: info.acceptsAllKinds ? outgoing.kind : nil
        )
        imageSends[outgoing.externalID, default: []].append(outgoing.images)
        put(task)
        if failAfterNextWrite {
            failAfterNextWrite = false
            throw URLError(.networkConnectionLost)
        }
        return task
    }

    func deleteTask(_ ref: RemoteRef, externalID: UUID) async throws {
        if failsWrites { throw URLError(.notConnectedToInternet) }
        guard var task = stored[ref.remoteID]?.task else { return }
        task.deleted = true
        put(task)
    }

    func listChanges(since cursor: String?, projectIDs: [String], known: [RemoteRef]) async throws -> ChangeBatch {
        pullCount += 1
        if failsPulls { throw URLError(.notConnectedToInternet) }
        let missing = Set(projectIDs).subtracting(projects.map(\.id))
        if isFullSnapshot {
            let knownIDs = Set(known.map(\.remoteID))
            let tasks = live.filter { projectIDs.contains($0.projectID) || knownIDs.contains($0.ref.remoteID) }
            return ChangeBatch(tasks: tasks, cursor: nil, isFullSnapshot: true, missingProjectIDs: missing)
        }
        let since = cursor.flatMap(Int.init) ?? 0
        let tasks = stored.values.filter { $0.version > since }.map(\.task)
        return ChangeBatch(tasks: tasks, cursor: String(version), isFullSnapshot: false, missingProjectIDs: missing)
    }

    // What a person does in the app.

    @discardableResult
    func create(title: String, notes: String = "", project: String, done: Bool = false) -> RemoteTask {
        nextID += 1
        let task = RemoteTask(
            ref: RemoteRef(remoteID: "r\(nextID)", stableID: "s-r\(nextID)"),
            externalID: nil,
            title: title,
            notes: notes,
            projectID: project,
            done: done,
            updatedAt: Date()
        )
        put(task)
        return task
    }

    func edit(_ cueID: UUID, at date: Date = Date(), _ change: (inout RemoteTask) -> Void) {
        guard var task = task(for: cueID) else { return XCTFail("no task for cue") }
        change(&task)
        task.updatedAt = date
        put(task)
    }

    func remove(_ cueID: UUID) {
        edit(cueID) { $0.deleted = true }
    }

    private func put(_ task: RemoteTask) {
        version += 1
        stored[task.ref.remoteID] = Stored(task: task, version: version)
    }
}

@MainActor
final class CueSyncEngineTests: XCTestCase {
    private var directory: URL!
    private var store: CueStore!
    private var fake: FakeTaskDestination!
    private var engine: CueSyncEngine!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCueSync-\(UUID().uuidString)", isDirectory: true)
        store = CueStore(directoryURL: directory)
        fake = FakeTaskDestination()
        engine = makeEngine()
        engine.connect(CueSyncState.Destination(id: fake.id, kind: "fake", name: "Fake"), destination: fake)
        engine.link(folderID: nil, destinationID: fake.id, project: RemoteProject(id: "p1", name: "One"))
    }

    override func tearDown() async throws {
        engine.stop()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private func makeEngine() -> CueSyncEngine {
        let engine = CueSyncEngine(store: store, stateURL: directory.appendingPathComponent("sync.json")) { [unowned self] _ in
            self.fake
        }
        // Tests run passes themselves.
        engine.debounce = .seconds(3600)
        return engine
    }

    private func synced(_ text: String, scope: CueScope = .inbox) async throws -> CueItem {
        let item = try XCTUnwrap(store.add(text: text, kind: .todo, scope: scope))
        await engine.syncNow()
        XCTAssertNotNil(fake.task(for: item.id))
        return item
    }

    private func cue(_ id: UUID) -> CueItem? {
        store.items.first { $0.id == id }
    }

    // MARK: Retry safety

    func testACrashBeforeTheLinkIsSavedDoesNotDuplicate() async throws {
        let item = try XCTUnwrap(store.add(text: "Book flights", kind: .todo, scope: .inbox))
        fake.failAfterNextWrite = true
        await engine.syncNow()
        XCTAssertEqual(fake.live.count, 1)
        XCTAssertNotNil(engine.statuses[fake.id]?.error)

        // Nano restarts with the pending create still recorded.
        engine = makeEngine()
        await engine.syncNow()
        await engine.syncNow()
        XCTAssertEqual(fake.live.count, 1)
        XCTAssertEqual(fake.task(for: item.id)?.title, "Book flights")
        XCTAssertNotNil(engine.state.links[item.id.uuidString])
        XCTAssertTrue(engine.state.pending.isEmpty)
    }

    func testRetryWorksInIncrementalModeToo() async throws {
        fake.isFullSnapshot = false
        let item = try XCTUnwrap(store.add(text: "Renew passport", kind: .todo, scope: .inbox))
        fake.failAfterNextWrite = true
        await engine.syncNow()
        await engine.syncNow()
        await engine.syncNow()
        XCTAssertEqual(fake.live.count, 1)
        XCTAssertNotNil(engine.state.links[item.id.uuidString])
    }

    // MARK: Done

    func testDoneSyncsBothWays() async throws {
        let item = try await synced("Pay rent")

        store.setDone(item.id, true)
        await engine.syncNow()
        XCTAssertEqual(fake.task(for: item.id)?.done, true)

        fake.edit(item.id) { $0.done = false }
        await engine.syncNow()
        XCTAssertEqual(cue(item.id)?.isDone, false)
    }

    func testEditsToDifferentFieldsBothSurvive() async throws {
        let item = try await synced("Pay rent")
        fake.edit(item.id) { $0.done = true }
        store.update(item.id, text: "Pay rent and water")
        await engine.syncNow()
        XCTAssertEqual(cue(item.id)?.isDone, true)
        XCTAssertEqual(cue(item.id)?.text, "Pay rent and water")
        XCTAssertEqual(fake.task(for: item.id)?.done, true)
        XCTAssertEqual(fake.task(for: item.id)?.title, "Pay rent and water")
    }

    // MARK: Text

    func testTitleConflictGoesToTheLaterEdit() async throws {
        let item = try await synced("Call the bank")

        // The app's edit is older than Cue's.
        fake.edit(item.id, at: Date().addingTimeInterval(-60)) { $0.title = "Call bank (app)" }
        store.update(item.id, text: "Call bank (cue)")
        await engine.syncNow()
        XCTAssertEqual(cue(item.id)?.text, "Call bank (cue)")
        XCTAssertEqual(fake.task(for: item.id)?.title, "Call bank (cue)")

        // Now the app's edit is newer.
        store.update(item.id, text: "Call bank (cue again)")
        fake.edit(item.id, at: Date().addingTimeInterval(60)) { $0.title = "Call bank (app again)" }
        await engine.syncNow()
        XCTAssertEqual(cue(item.id)?.text, "Call bank (app again)")
        XCTAssertEqual(fake.task(for: item.id)?.title, "Call bank (app again)")
    }

    func testNotesSurviveARemoteTitleEdit() async throws {
        let item = try await synced("Draft the brief\nInclude the budget\nand dates")
        XCTAssertEqual(fake.task(for: item.id)?.title, "Draft the brief")
        XCTAssertEqual(fake.task(for: item.id)?.notes, "Include the budget\nand dates")

        fake.edit(item.id) { $0.title = "Draft the client brief" }
        await engine.syncNow()
        XCTAssertEqual(cue(item.id)?.text, "Draft the client brief\nInclude the budget\nand dates")
    }

    func testAnEmptyRemoteEditIsIgnored() async throws {
        let item = try await synced("Water plants")
        fake.edit(item.id) {
            $0.title = ""
            $0.notes = ""
        }
        await engine.syncNow()
        XCTAssertEqual(cue(item.id)?.text, "Water plants")
    }

    // MARK: Deletes

    func testDeletesSyncBothWays() async throws {
        let first = try await synced("One")
        let second = try await synced("Two")

        store.delete(first.id)
        await engine.syncNow()
        XCTAssertNil(fake.task(for: first.id))

        fake.remove(second.id)
        await engine.syncNow()
        XCTAssertNil(cue(second.id))
        XCTAssertTrue(engine.state.links.isEmpty)
    }

    func testADeleteWaitsForItsUndoWindow() async throws {
        let item = try await synced("Cancel gym")
        store.delete(item.id, undoable: true)
        await engine.syncNow()
        XCTAssertNotNil(fake.task(for: item.id))

        store.dismissToast()
        await engine.syncNow()
        XCTAssertNil(fake.task(for: item.id))
    }

    func testAnUndoneDeleteSendsNothing() async throws {
        let item = try await synced("Cancel gym")
        let writes = fake.upsertCount
        store.delete(item.id, undoable: true)
        await engine.syncNow()
        store.undoToast()
        await engine.syncNow()
        XCTAssertNotNil(fake.task(for: item.id))
        XCTAssertEqual(fake.upsertCount, writes)
    }

    func testAnUndoneFolderDeleteChangesNothingRemotely() async throws {
        let folder = store.addFolder(named: "Errands", section: .stash)
        engine.link(folderID: folder.id, destinationID: fake.id, project: RemoteProject(id: "p2", name: "Two"))
        let item = try await synced("Buy stamps", scope: .folder(folder.id))
        let writes = fake.upsertCount

        store.deleteFolder(folder.id)
        await engine.syncNow()
        XCTAssertEqual(fake.task(for: item.id)?.projectID, "p2")

        store.undoToast()
        await engine.syncNow()
        XCTAssertEqual(fake.task(for: item.id)?.projectID, "p2")
        XCTAssertEqual(fake.upsertCount, writes)
        XCTAssertNotNil(engine.folderLink(for: folder.id))
    }

    func testAfterAFolderDeleteItsCuesFollowTheInbox() async throws {
        let folder = store.addFolder(named: "Errands", section: .stash)
        engine.link(folderID: folder.id, destinationID: fake.id, project: RemoteProject(id: "p2", name: "Two"))
        let item = try await synced("Buy stamps", scope: .folder(folder.id))

        store.deleteFolder(folder.id)
        store.dismissToast()
        await engine.syncNow()
        XCTAssertEqual(fake.task(for: item.id)?.projectID, "p1")
        XCTAssertNil(engine.folderLink(for: folder.id))
    }

    func testDeletedInCueButEditedInTheAppKeepsTheEdit() async throws {
        let item = try await synced("Plan trip")
        store.delete(item.id)
        fake.edit(item.id) { $0.title = "Plan trip to Lisbon" }
        await engine.syncNow()
        XCTAssertEqual(cue(item.id)?.text, "Plan trip to Lisbon")
        XCTAssertNotNil(fake.task(for: item.id))
    }

    // MARK: Created in the app

    func testATaskCreatedInTheAppIsImportedAtTheEndAndTagged() async throws {
        _ = try await synced("Existing")
        let task = fake.create(title: "From the app", notes: "with notes", project: "p1")
        fake.create(title: "Already done", project: "p1", done: true)
        fake.create(title: "Unlinked list", project: "p3")
        await engine.syncNow()

        XCTAssertEqual(store.openItems(in: .inbox).map(\.text), ["Existing", "From the app\nwith notes"])
        let imported = try XCTUnwrap(store.items.last)
        XCTAssertEqual(imported.kind, .todo)
        XCTAssertEqual(fake.stored[task.ref.remoteID]?.task.externalID, imported.id)

        // A second pass changes nothing.
        let count = store.items.count
        await engine.syncNow()
        XCTAssertEqual(store.items.count, count)
        XCTAssertEqual(fake.live.count, 4)
    }

    // MARK: Moves and kinds

    func testMovingACueBetweenLinkedFoldersMovesTheTask() async throws {
        let folder = store.addFolder(named: "Work", section: .project)
        engine.link(folderID: folder.id, destinationID: fake.id, project: RemoteProject(id: "p2", name: "Two"))
        let item = try await synced("Write report")

        store.move(item.id, to: .folder(folder.id))
        await engine.syncNow()
        XCTAssertEqual(fake.task(for: item.id)?.projectID, "p2")
        XCTAssertEqual(fake.live.count, 1)
    }

    func testMovingACueToAnUnlinkedFolderUnlinksIt() async throws {
        let folder = store.addFolder(named: "Private", section: .stash)
        let item = try await synced("Write report")
        store.move(item.id, to: .folder(folder.id))
        await engine.syncNow()
        XCTAssertNil(engine.state.links[item.id.uuidString])
        XCTAssertNotNil(fake.task(for: item.id))
        XCTAssertNotNil(cue(item.id))
    }

    func testATaskMovedInTheAppFollowsToItsFolder() async throws {
        let folder = store.addFolder(named: "Work", section: .project)
        engine.link(folderID: folder.id, destinationID: fake.id, project: RemoteProject(id: "p2", name: "Two"))
        let item = try await synced("Write report")
        fake.edit(item.id) { $0.projectID = "p2" }
        await engine.syncNow()
        XCTAssertEqual(cue(item.id)?.folderID, folder.id)
    }

    func testATaskMovedToAnUnlinkedListIsNotTreatedAsDeleted() async throws {
        let item = try await synced("Write report")
        fake.edit(item.id) { $0.projectID = "p3" }
        await engine.syncNow()
        XCTAssertNotNil(cue(item.id))
        XCTAssertNil(engine.state.links[item.id.uuidString])
    }

    func testChangingKindAwayFromToDoUnlinks() async throws {
        let item = try await synced("Refactor the parser")
        store.update(item.id, kind: .prompt)
        await engine.syncNow()
        XCTAssertNil(engine.state.links[item.id.uuidString])
        XCTAssertNotNil(fake.task(for: item.id))
    }

    func testOnlyOpenToDosAreSent() async throws {
        store.add(text: "A long prompt for an agent", kind: .prompt, scope: .inbox)
        store.add(text: "An idea", kind: .idea, scope: .inbox)
        let done = try XCTUnwrap(store.add(text: "Finished", kind: .todo, scope: .inbox))
        store.setDone(done.id, true)
        await engine.syncNow()
        XCTAssertTrue(fake.live.isEmpty)
    }

    // MARK: Prompts and images

    private func takeEverything() async {
        fake.info.acceptsAllKinds = true
        fake.info.acceptsImages = true
        await engine.refresh(fake.id)
    }

    func testAppsThatTakeAllKindsGetPromptsAndImages() async throws {
        await takeEverything()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let prompt = try XCTUnwrap(store.add(text: "Refactor the parser", kind: .prompt, images: [png], scope: .inbox))
        let imageOnly = try XCTUnwrap(store.add(text: "", kind: .idea, images: [png], scope: .inbox))
        await engine.syncNow()

        XCTAssertEqual(fake.task(for: prompt.id)?.kind, .prompt)
        XCTAssertEqual(fake.imageSends[prompt.id]?.last??.map(\.data), [png])
        XCTAssertEqual(fake.task(for: imageOnly.id)?.title, "Image")

        // A text edit doesn't send the images again.
        store.update(prompt.id, text: "Refactor the parser, then test it")
        await engine.syncNow()
        XCTAssertEqual(fake.task(for: prompt.id)?.title, "Refactor the parser, then test it")
        XCTAssertNil(fake.imageSends[prompt.id]?.last ?? nil)

        // Removing the image sends the new, empty set.
        let name = try XCTUnwrap(store.items.first { $0.id == prompt.id }?.images.first)
        store.removeImage(name, from: prompt.id)
        await engine.syncNow()
        XCTAssertEqual(fake.imageSends[prompt.id]?.last??.count, 0)

        // Nothing changed: nothing is sent.
        let sends = fake.upsertCount
        await engine.syncNow()
        XCTAssertEqual(fake.upsertCount, sends)
    }

    func testAKindChangedInTheAppReachesCue() async throws {
        await takeEverything()
        let item = try await synced("Remember the milk")
        fake.edit(item.id) { $0.kind = .idea }
        await engine.syncNow()
        XCTAssertEqual(cue(item.id)?.kind, .idea)

        store.update(item.id, kind: .prompt)
        await engine.syncNow()
        XCTAssertEqual(fake.task(for: item.id)?.kind, .prompt)
        XCTAssertNotNil(engine.state.links[item.id.uuidString])
    }

    func testAppsThatOnlyTakeToDosNeverSeeKindsOrImages() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let todo = try XCTUnwrap(store.add(text: "Pick up film", kind: .todo, images: [png], scope: .inbox))
        store.add(text: "A prompt", kind: .prompt, scope: .inbox)
        await engine.syncNow()
        XCTAssertEqual(fake.live.count, 1)
        XCTAssertNil(fake.task(for: todo.id)?.kind)
        XCTAssertNil(fake.imageSends[todo.id]?.last ?? nil)
    }

    // MARK: Schedule

    func testAnAppOnThisMacIsPulledEveryFewSeconds() async throws {
        let item = try await synced("Water plants")
        fake.pollInterval = .milliseconds(200)
        engine.pollTick = .milliseconds(50)
        engine.startPolling()
        fake.edit(item.id) { $0.done = true }
        try await Task.sleep(for: .seconds(1))
        engine.stop()
        XCTAssertEqual(cue(item.id)?.isDone, true)
    }

    func testASlowAppIsNotPulledBeforeItsTime() async throws {
        _ = try await synced("Water plants")
        let pulls = fake.pullCount
        engine.pollTick = .milliseconds(50)
        engine.startPolling()
        try await Task.sleep(for: .milliseconds(500))
        engine.stop()
        XCTAssertEqual(fake.pullCount, pulls)
    }

    func testAnEditInCueGoesOutWithinASecond() async throws {
        let item = try await synced("Water plants")
        engine.debounce = .milliseconds(500)
        store.setDone(item.id, true)
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(fake.task(for: item.id)?.done, true)
    }

    // MARK: Failures and safety

    func testADisconnectedAppLeavesCuesUntouched() async throws {
        let item = try await synced("Keep me")
        engine.disconnect(fake.id)
        fake.remove(item.id)
        await engine.syncNow()
        XCTAssertNotNil(cue(item.id))
        XCTAssertTrue(engine.state.links.isEmpty)
    }

    func testAFailedPullChangesNothing() async throws {
        let item = try await synced("Stay put")
        fake.failsPulls = true
        store.update(item.id, text: "Edited in Cue")
        await engine.syncNow()
        XCTAssertNotNil(cue(item.id))
        XCTAssertEqual(fake.task(for: item.id)?.title, "Stay put")
        XCTAssertNotNil(engine.statuses[fake.id]?.error)

        fake.failsPulls = false
        await engine.syncNow()
        XCTAssertEqual(fake.task(for: item.id)?.title, "Edited in Cue")
    }

    func testAFailedPushIsSentOnTheNextPass() async throws {
        let item = try await synced("First")
        fake.failsWrites = true
        store.update(item.id, text: "Second")
        await engine.syncNow()
        XCTAssertEqual(fake.task(for: item.id)?.title, "First")

        fake.failsWrites = false
        await engine.syncNow()
        XCTAssertEqual(fake.task(for: item.id)?.title, "Second")
        XCTAssertEqual(cue(item.id)?.text, "Second")
    }

    func testAnUnreadableLibraryStopsSync() async throws {
        let other = directory.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: other.appendingPathComponent("cue.json"))
        store = CueStore(directoryURL: other)
        XCTAssertTrue(store.libraryIsUnreadable)
        fake.create(title: "Remote", project: "p1")
        engine = makeEngine()
        await engine.syncNow()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(engine.statuses[fake.id]?.error)
    }

    func testASuccessfulRefreshClearsAnEarlierError() async throws {
        fake.failsProjects = true
        await engine.refresh(fake.id)
        XCTAssertNotNil(engine.statuses[fake.id]?.error)
        fake.failsProjects = false
        await engine.refresh(fake.id)
        XCTAssertNil(engine.statuses[fake.id]?.error)
        XCTAssertEqual(engine.projects[fake.id]?.count, 3)
    }

    func testAMissingListUnlinksItsFolder() async throws {
        let item = try await synced("Orphan")
        fake.projects.removeAll { $0.id == "p1" }
        await engine.syncNow()
        XCTAssertNil(engine.folderLink(for: nil))
        XCTAssertEqual(engine.notices.count, 1)
        XCTAssertNotNil(cue(item.id))
    }

    // MARK: Mass-delete guard

    func testTheGuardHoldsAMassDelete() async throws {
        var ids: [UUID] = []
        for index in 0 ..< 12 {
            ids.append(try XCTUnwrap(store.add(text: "Task \(index)", kind: .todo, scope: .inbox)).id)
        }
        await engine.syncNow()
        XCTAssertEqual(fake.live.count, 12)

        ids.forEach(fake.remove)
        await engine.syncNow()
        XCTAssertEqual(store.items.count, 12)
        XCTAssertEqual(engine.heldDeletes?.count, 12)

        engine.continueHeldDeletes()
        await engine.syncNow()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(engine.heldDeletes)
    }

    func testTheGuardIgnoresSmallDeletesInSmallLists() async throws {
        let first = try await synced("One")
        let second = try await synced("Two")
        fake.remove(first.id)
        fake.remove(second.id)
        await engine.syncNow()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(engine.heldDeletes)
    }

    func testClearingDoneCuesNeverTripsTheGuard() async throws {
        for index in 0 ..< 6 {
            let item = try await synced("Done \(index)")
            store.setDone(item.id, true)
        }
        _ = try await synced("Still open")
        await engine.syncNow()
        store.clearCompleted()
        await engine.syncNow()
        XCTAssertNil(engine.heldDeletes)
        XCTAssertEqual(fake.live.map(\.title), ["Still open"])
    }

    // MARK: Model

    func testOldLibrariesWithoutUpdatedAtDecode() throws {
        let other = directory.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let json = """
        {"folders":[],"items":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"Old","kind":"todo",
        "images":[],"createdAt":"2026-01-01T00:00:00Z","completedAt":"2026-02-01T00:00:00Z"}]}
        """
        try Data(json.utf8).write(to: other.appendingPathComponent("cue.json"))
        let old = CueStore(directoryURL: other)
        XCTAssertFalse(old.libraryIsUnreadable)
        XCTAssertEqual(old.items.first?.updatedAt, ISO8601DateFormatter().date(from: "2026-02-01T00:00:00Z"))
    }

    func testEditsInCueBumpUpdatedAtButSyncEditsDoNot() throws {
        let item = try XCTUnwrap(store.add(text: "Stamp", kind: .todo, scope: .inbox))
        let before = item.updatedAt
        store.applySyncEdits([.update(id: item.id, expected: before, text: "Stamped", done: true, folderID: nil)])
        XCTAssertEqual(cue(item.id)?.updatedAt, before)
        XCTAssertEqual(cue(item.id)?.text, "Stamped")

        store.update(item.id, text: "Stamp again")
        XCTAssertGreaterThan(try XCTUnwrap(cue(item.id)?.updatedAt), before)
    }

    func testTheSetupGuideShipsWithTheApp() throws {
        let guide = try XCTUnwrap(CueSyncGuide.text)
        for tool in ["cue_describe", "cue_list_projects", "cue_upsert_task", "cue_list_changes", "cue_delete_task"] {
            XCTAssertTrue(guide.contains(tool), tool)
        }
        XCTAssertTrue(guide.contains("Settings > Cue > Sync > Custom"))
    }

    func testTextSplitsIntoTitleAndNotes() {
        XCTAssertEqual(CueSyncEngine.split("One line").title, "One line")
        XCTAssertEqual(CueSyncEngine.split("One line").notes, "")
        XCTAssertEqual(CueSyncEngine.split("Title\n\nBody\nmore").notes, "Body\nmore")
        XCTAssertEqual(CueSyncEngine.compose("Title", "Body"), "Title\nBody")
    }
}
