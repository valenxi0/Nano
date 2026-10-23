import SwiftUI
import AppKit
import XCTest
@testable import Nano

@MainActor
final class CueStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCue-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testCuesPersistWithFoldersOrderAndScope() throws {
        let store = CueStore(directoryURL: directory)
        let folder = store.addFolder(named: "harbor-next", section: .project, linkedPath: "/tmp/harbor-next/")
        store.scope = .folder(folder.id)
        let first = try XCTUnwrap(store.add(text: "Run migrations", scope: .folder(folder.id)))
        let second = try XCTUnwrap(store.add(text: "Send the RLS prompt", scope: .folder(folder.id)))
        store.reorder(second.id, before: first.id)
        store.save()

        let reloaded = CueStore(directoryURL: directory)
        XCTAssertEqual(reloaded.folders.map(\.name), ["harbor-next"])
        XCTAssertEqual(reloaded.folders.first?.linkedPath, "/tmp/harbor-next")
        XCTAssertEqual(reloaded.scope, .folder(folder.id))
        XCTAssertEqual(reloaded.openItems(in: .folder(folder.id)).map(\.text), ["Send the RLS prompt", "Run migrations"])
    }

    func testReorderMovesDownAndUp() throws {
        let store = CueStore(directoryURL: directory)
        let a = try XCTUnwrap(store.add(text: "A", scope: .inbox))
        let b = try XCTUnwrap(store.add(text: "B", scope: .inbox))
        let c = try XCTUnwrap(store.add(text: "C", scope: .inbox))

        store.reorder(a.id, before: c.id)
        XCTAssertEqual(store.openItems(in: .inbox).map(\.text), ["B", "C", "A"])
        store.reorder(a.id, before: b.id)
        XCTAssertEqual(store.openItems(in: .inbox).map(\.text), ["A", "B", "C"])
    }

    func testDoneCuesLeaveTheOpenListAndUndoRestoresThem() throws {
        let store = CueStore(directoryURL: directory)
        let item = try XCTUnwrap(store.add(text: "Ship it", scope: .inbox))

        // Not `copy`: tests must not replace the user's clipboard.
        store.setDone(item.id, true, announce: true)
        XCTAssertTrue(store.openItems(in: .inbox).isEmpty)
        XCTAssertEqual(store.doneItems(in: .inbox).map(\.id), [item.id])

        store.undoToast()
        XCTAssertEqual(store.openItems(in: .inbox).map(\.id), [item.id])
    }

    func testAnUnreadableLibraryIsSetAsideAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cue.json")
        let corrupt = Data("{ \"folders\": [".utf8)
        try corrupt.write(to: file)

        let store = CueStore(directoryURL: directory)
        XCTAssertTrue(store.libraryIsUnreadable)
        XCTAssertNotNil(store.errorMessage)

        store.add(text: "Typed after the library failed to load", scope: .inbox)
        store.save()
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertNotNil(store.errorMessage)

        let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("cue.json.bad-") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(copies.first))), corrupt)

        // A second launch reads the same file and doesn't pile up copies.
        _ = CueStore(directoryURL: directory)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix("cue.json.bad-") }.count,
            1
        )
    }

    func testDeleteWithUndoPutsTheCueBackWhereItWas() throws {
        let store = CueStore(directoryURL: directory)
        let a = try XCTUnwrap(store.add(text: "A", scope: .inbox))
        let b = try XCTUnwrap(store.add(text: "B", scope: .inbox))
        let c = try XCTUnwrap(store.add(text: "C", scope: .inbox))

        store.delete(b.id, undoable: true)
        XCTAssertEqual(store.openItems(in: .inbox).map(\.id), [a.id, c.id])
        store.undoToast()
        XCTAssertEqual(store.openItems(in: .inbox).map(\.id), [a.id, b.id, c.id])
    }

    func testDeletingAFolderMovesItsCuesToTheInbox() throws {
        let store = CueStore(directoryURL: directory)
        let folder = store.addFolder(named: "Ideas", section: .stash)
        store.add(text: "Voice-first capture", scope: .folder(folder.id))

        store.deleteFolder(folder.id)
        XCTAssertEqual(store.openItems(in: .inbox).map(\.text), ["Voice-first capture"])
    }

    func testImagesAreStoredAndRemovedWithTheirCue() throws {
        let store = CueStore(directoryURL: directory)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(CueStore.pngData(image))

        let item = try XCTUnwrap(store.add(text: "", images: [data], scope: .inbox))
        let url = store.imageURL(named: try XCTUnwrap(item.images.first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(item.headline, "Image")

        store.delete(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDraftCommitSavesToTheChosenFolderAndKeepsItOpen() throws {
        let store = CueStore(directoryURL: directory)
        let folder = store.addFolder(named: "Prompts", section: .stash)
        store.beginCapture(text: "Draft a changelog entry")
        store.draft?.scope = .folder(folder.id)

        store.commitDraft(keepOpen: true)
        XCTAssertEqual(store.openItems(in: .folder(folder.id)).map(\.text), ["Draft a changelog entry"])
        XCTAssertEqual(store.draft?.scope, .folder(folder.id))
        XCTAssertEqual(store.draft?.text, "")
        XCTAssertEqual(store.scope, .folder(folder.id))
    }

    func testRecentProjectsSkipScratchFoldersAndFoldWorktreesIntoTheirRepository() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/NanoTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("App", isDirectory: true)
        let worktree = root.appendingPathComponent("app-agent-1", isDirectory: true)
        let scratch = root.appendingPathComponent("2026-10-03-a-chat", isDirectory: true)
        let nested = repository.appendingPathComponent("Sources/Views", isDirectory: true)
        for folder in [repository.appendingPathComponent(".git"), worktree, scratch, nested] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "gitdir: \(repository.path)/.git/worktrees/app-agent-1\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let projects = CueRecentProjects.projects(in: [
            scratch.path,
            nested.path,
            worktree.path,
            root.appendingPathComponent("deleted-agent-2").path,
            "/private/tmp",
            NSHomeDirectory(),
            repository.path,
        ])

        XCTAssertEqual(projects, [repository.path])
    }

    func testOnlyCommandVCountsAsAPaste() {
        XCTAssertTrue(CuePasteRelay.isPaste(keyCode: 9, flags: .command))
        XCTAssertTrue(CuePasteRelay.isPaste(keyCode: 9, flags: [.command, .shift]))
        XCTAssertFalse(CuePasteRelay.isPaste(keyCode: 9, flags: []))
        XCTAssertFalse(CuePasteRelay.isPaste(keyCode: 8, flags: .command))
    }

    func testKindGuessing() {
        XCTAssertEqual(CueKind.guess(for: "supabase.com/docs/guides/database"), .link)
        XCTAssertEqual(CueKind.guess(for: "https://example.com"), .link)
        XCTAssertEqual(CueKind.guess(for: "Run the migration"), .todo)
        XCTAssertEqual(CueKind.guess(for: "Nano.app/Contents"), .todo)
        XCTAssertEqual(CueKind.guess(for: "1.5/2"), .todo)
        XCTAssertEqual(CueKind.guess(for: "Line one\nLine two"), .prompt)
        XCTAssertEqual(CueKind.guess(for: String(repeating: "word ", count: 30)), .prompt)
    }

    func testDeletingAFolderCanBeUndoneAndAPassingMessageKeepsTheUndo() throws {
        let store = CueStore(directoryURL: directory)
        let folder = store.addFolder(named: "Atlas", section: .project)
        let cue = try XCTUnwrap(store.add(text: "ship it", scope: .folder(folder.id)))

        store.deleteFolder(folder.id)
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertNil(store.items.first { $0.id == cue.id }?.folderID)

        store.showToast("Copied")
        XCTAssertEqual(store.toast?.isUndoable, true)

        store.undoToast()
        XCTAssertEqual(store.folders.map(\.id), [folder.id])
        XCTAssertEqual(store.items.first { $0.id == cue.id }?.folderID, folder.id)
    }
}

@MainActor
final class BatchOneUndoTests: XCTestCase {
    func testClearingTheTrayCanBeUndone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTrayUndo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try "a".write(to: file, atomically: true, encoding: .utf8)
        let store = TrayStore(storageURL: directory.appendingPathComponent("items.json"))
        store.add([file])

        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.canUndo)

        store.undoDiscard()
        XCTAssertEqual(store.items.map(\.url), [file.standardizedFileURL])
        XCTAssertFalse(store.canUndo)
    }

    func testResettingARunningTimerCanBeUndone() {
        let store = FocusTimerStore(defaults: nil)
        store.startOrResume()
        store.reset()
        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.canUndoReset)

        store.undoReset()
        XCTAssertEqual(store.state, .running)
        XCTAssertFalse(store.canUndoReset)
        store.pause()
    }

    func testOpeningSomethingElseKeepsWaitingCardsForLater() {
        let center = IslandNotificationCenter()
        center.present(.preview(for: .volume))
        center.present(.preview(for: .battery))
        XCTAssertEqual(center.queuedCount, 1)

        center.setAside()
        XCTAssertNil(center.current)
        XCTAssertEqual(center.queuedCount, 1)

        center.resumeQueue()
        XCTAssertNotNil(center.current)
        XCTAssertEqual(center.queuedCount, 0)
    }
}

/// Renders Cue's island and Settings screens to /tmp/nano-shots.
@MainActor
final class CueSnapshots: XCTestCase {
    func testRenderCue() throws {
        guard ProcessInfo.processInfo.environment["NANO_SNAPSHOTS"] == "1" else { throw XCTSkip("Snapshots run on request") }
        let defaults = UserDefaults(suiteName: "nano-shots-\(UUID().uuidString)")!
        let settings = NanoSettings(defaults: defaults)
        let viewModel = IslandViewModel(settings: settings, trayStorageURL: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NanoCueShots-\(UUID().uuidString)")
        let store = CueStore(directoryURL: directory)
        let atlas = store.addFolder(named: "Atlas-Desktop", section: .project, linkedPath: "/Users/me/Atlas-Desktop")
        _ = store.addFolder(named: "North-Star", section: .project, linkedPath: "/Users/me/North-Star")
        _ = store.addFolder(named: "Reading", section: .stash)
        _ = store.add(text: "Review the onboarding hook install and show which files changed", kind: .prompt, scope: .inbox, sourceApp: "T3 Code")
        _ = store.add(text: "Ask Fable to review Cue settings", kind: .todo, scope: .inbox)
        _ = store.add(text: "https://github.com/kitlangton/scrawl", kind: .link, scope: .inbox, sourceApp: "Safari")
        _ = store.add(text: "Per-project grouping in the agents list", kind: .idea, scope: .inbox)
        if let done = store.add(text: "Ship Batch 2 approvals", kind: .todo, scope: .inbox) { store.setDone(done.id, true) }
        _ = store.add(text: "Wire channel permissions into the MCP grants", kind: .prompt, scope: .folder(atlas.id))

        let out = URL(fileURLWithPath: "/tmp/nano-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, name: String, dark: Bool = true) throws {
            let hosting = NSHostingView(rootView: view.frame(width: width, height: height)
                .fixedSize(horizontal: false, vertical: height == nil)
                .environment(\.colorScheme, .dark))
            hosting.appearance = NSAppearance(named: .darkAqua)
            let size = hosting.fittingSize
            let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: height ?? size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
        }

        // The island module at its real size, list then capture.
        try shot(CueModuleView(store: store, viewModel: viewModel).padding(15).foregroundStyle(.white).background(Color.black),
                 width: 820, height: 440, name: "cue-island")
        store.draft = CueDraft(text: "Add a ⋯ menu to every Cue row", kind: nil, images: [], scope: .inbox,
                               sourceApp: "T3 Code", pulledFromSelection: false, returnsFocus: false)
        try shot(CueModuleView(store: store, viewModel: viewModel).padding(15).foregroundStyle(.white).background(Color.black),
                 width: 640, height: 250, name: "cue-capture")
        store.draft = nil

        for tab in CueSettingsTab.allCases {
            try shot(CueSettingsPane(settings: settings, store: store, viewModel: viewModel, initialTab: tab)
                .padding(20).background(Color(nsColor: .windowBackgroundColor)), width: 760, name: "cue-settings-\(tab.rawValue)")
        }
    }
}
