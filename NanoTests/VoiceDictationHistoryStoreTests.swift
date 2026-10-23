import XCTest
@testable import Nano

@MainActor
final class VoiceDictationHistoryStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nano-vd-history-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        try await super.tearDown()
    }

    /// A clock the test advances by hand.
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    func testRecordStoresTextOnlyAndPersists() throws {
        let clock = Clock()
        let store = VoiceDictationHistoryStore(fileURL: fileURL, now: { clock.now })
        store.record("  Ship the release notes.  ", engine: .whisperBase)
        store.record("", engine: .whisperBase)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "Ship the release notes.")
        XCTAssertEqual(store.entries[0].engine, .whisperBase)

        let data = try Data(contentsOf: fileURL)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("Ship the release notes."))
        XCTAssertFalse(json.lowercased().contains("audio"))

        let reloaded = VoiceDictationHistoryStore(fileURL: fileURL, now: { clock.now })
        XCTAssertEqual(reloaded.entries, store.entries)
    }

    func testEntriesExpireAfterTwentyFourHours() {
        let clock = Clock()
        let store = VoiceDictationHistoryStore(fileURL: fileURL, now: { clock.now })
        store.record("first", engine: .parakeetS1)
        clock.now += 60 * 60
        store.record("second", engine: .parakeetS1)

        clock.now += VoiceDictationHistoryStore.retention - 60 * 60 // first is now exactly 24h old
        XCTAssertEqual(store.purgeExpired(), 1)
        XCTAssertEqual(store.entries.map(\.text), ["second"])

        clock.now += 60 * 60
        XCTAssertEqual(store.purgeExpired(), 1)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "an empty history leaves no file")
    }

    func testExpiredEntriesArePurgedWhenTheStoreLoads() {
        let clock = Clock()
        let writer = VoiceDictationHistoryStore(fileURL: fileURL, now: { clock.now })
        writer.record("stale", engine: .whisperTiny)
        writer.suspend()

        clock.now += VoiceDictationHistoryStore.retention + 1
        let reader = VoiceDictationHistoryStore(fileURL: fileURL, now: { clock.now })
        XCTAssertTrue(reader.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testClearRemovesEverythingIncludingTheFile() {
        let store = VoiceDictationHistoryStore(fileURL: fileURL)
        store.record("one", engine: .parakeetS1)
        store.record("two", engine: .parakeetS1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(store.nextExpiry)
    }

    func testRemoveDeletesOneEntry() {
        let store = VoiceDictationHistoryStore(fileURL: fileURL)
        store.record("keep", engine: .parakeetS1)
        store.record("drop", engine: .parakeetS1)
        let drop = store.entries.first { $0.text == "drop" }!
        store.remove(drop)
        XCTAssertEqual(store.entries.map(\.text), ["keep"])
    }

    func testHistoryLivesUnderNanoStorageNotICloud() {
        let path = VoiceDictationHistoryStore.defaultFileURL.path
        XCTAssertTrue(path.hasPrefix(NanoStorage.root.path))
        XCTAssertFalse(path.contains("Mobile Documents"))
    }
}
