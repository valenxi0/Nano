import CryptoKit
import FluidAudio
import XCTest
@testable import Nano

@MainActor
final class VoiceDictationModelStoreTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nano-vd-models-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: Manifest

    func testEveryModelIsFullyPinned() {
        for id in VoiceDictationModelID.allCases {
            let descriptor = VoiceDictationModelManifest.descriptor(for: id)
            XCTAssertFalse(descriptor.files.isEmpty, "\(id) has no files")
            XCTAssertEqual(descriptor.revision.count, 40, "\(id) revision must be a full commit hash")
            XCTAssertFalse(descriptor.license.isEmpty, "\(id) license")
            XCTAssertFalse(descriptor.licenseNote.isEmpty, "\(id) license note")
            for file in descriptor.files {
                XCTAssertEqual(file.sha256.count, 64, "\(id)/\(file.path) sha256")
                XCTAssertGreaterThan(file.size, 0, "\(id)/\(file.path) size")
                XCTAssertFalse(file.path.hasPrefix("/"))
                XCTAssertFalse(file.path.contains(".."))
            }
            XCTAssertEqual(Set(descriptor.files.map(\.path)).count, descriptor.files.count, "\(id) duplicate paths")
            if let primary = VoiceDictationModelManifest.primaryFile(for: id) {
                XCTAssertTrue(descriptor.files.contains { $0.path == primary }, "\(id) primary file is pinned")
            }
        }
    }

    func testRemoteURLsPinTheRevision() {
        let descriptor = VoiceDictationModelManifest.descriptor(for: .s1Mini)
        let url = descriptor.remoteURL(for: descriptor.files[0])
        XCTAssertEqual(url.host, "huggingface.co")
        XCTAssertTrue(url.path.contains("/resolve/\(descriptor.revision)/"), url.absoluteString)
    }

    func testS1MiniKeepsItsLicenseAndNoticeFiles() {
        let paths = VoiceDictationModelManifest.descriptor(for: .s1Mini).files.map(\.path)
        XCTAssertTrue(paths.contains("LICENSE"))
        XCTAssertTrue(paths.contains("NOTICE"))
        XCTAssertTrue(paths.contains("s1-mini-q4_k_m.gguf"))
    }

    func testParakeetDirectoryMatchesFluidAudioCacheFolder() {
        // FluidAudio derives the cache folder from the repo URL we pass by
        // taking its parent and appending `Repo.parakeetV3.folderName`.
        XCTAssertEqual(
            VoiceDictationModelManifest.descriptor(for: .parakeetTDT06BV3).directoryName,
            Repo.parakeetV3.folderName
        )
    }

    func testParakeetManifestCoversWhatFluidAudioLoads() {
        let paths = VoiceDictationModelManifest.descriptor(for: .parakeetTDT06BV3).files.map(\.path)
        for required in ["Preprocessor.mlmodelc/", "Encoder.mlmodelc/", "Decoder.mlmodelc/", "JointDecisionv3.mlmodelc/"] {
            XCTAssertTrue(paths.contains { $0.hasPrefix(required) }, required)
        }
        XCTAssertTrue(paths.contains("parakeet_vocab.json"))
    }

    func testEnginesRequireTheRightModels() {
        XCTAssertEqual(VoiceDictationEngine.parakeetS1.requiredModels, [.parakeetTDT06BV3, .s1Mini])
        XCTAssertEqual(VoiceDictationEngine.whisperBase.requiredModels, [.whisperBaseEnglish])
        XCTAssertEqual(VoiceDictationEngine.whisperTiny.requiredModels, [.whisperTinyEnglish])
        XCTAssertTrue(VoiceDictationEngine.parakeetS1.appliesCleanup)
        XCTAssertFalse(VoiceDictationEngine.whisperBase.appliesCleanup)
    }

    func testEveryEngineExplainsItsQualityAndResourceTradeoff() {
        XCTAssertEqual(VoiceDictationEngine.offered.map(\.choiceTitle), ["English, best quality", "Many languages", "Small download"])
        XCTAssertEqual(VoiceDictationEngine.parakeetS1.resourceLabel, "Recommended")
    }

    // MARK: Disk state

    func testFreshStoreReportsNothingDownloadedAndDownloadsNothing() {
        let store = VoiceDictationModelStore(rootDirectory: root)
        for id in VoiceDictationModelID.allCases {
            XCTAssertEqual(store.state(of: id), .notDownloaded)
        }
        XCTAssertEqual(store.missingModels(for: .parakeetS1), [.parakeetTDT06BV3, .s1Mini])
        XCTAssertFalse(store.isReady(.whisperTiny))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "no network, no directories")
    }

    func testCompletenessIsJudgedByEveryPinnedFileSize() throws {
        let descriptor = VoiceDictationModelManifest.descriptor(for: .whisperTinyEnglish)
        let directory = root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertFalse(VoiceDictationModelStore.isComplete(descriptor: descriptor, at: directory))

        let file = descriptor.files[0]
        let target = directory.appendingPathComponent(file.path)
        try Data(count: 10).write(to: target)
        XCTAssertFalse(VoiceDictationModelStore.isComplete(descriptor: descriptor, at: directory), "wrong size")

        try FileManager.default.removeItem(at: target)
        try FileHandle.sparseFile(at: target, size: file.size)
        XCTAssertTrue(VoiceDictationModelStore.isComplete(descriptor: descriptor, at: directory))

        let store = VoiceDictationModelStore(rootDirectory: root)
        XCTAssertTrue(
            [.verifying, .updateAvailable].contains(store.state(of: .whisperTinyEnglish)),
            "a receipt-less file with the right size must be verified before use"
        )
        XCTAssertFalse(store.isReady(.whisperTiny))
        XCTAssertEqual(store.primaryFileURL(for: .whisperTinyEnglish), target)

        try store.remove(.whisperTinyEnglish)
        XCTAssertEqual(store.state(of: .whisperTinyEnglish), .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testReceiptMakesAPreviouslyInstalledRevisionUpdateable() throws {
        let descriptor = VoiceDictationModelManifest.descriptor(for: .whisperTinyEnglish)
        let directory = root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in descriptor.files {
            let target = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileHandle.sparseFile(at: target, size: file.size)
        }
        let oldReceipt = VoiceDictationModelReceipt(revision: "older-pinned-revision")
        try JSONEncoder().encode(oldReceipt).write(
            to: directory.appendingPathComponent(VoiceDictationModelReceipt.fileName)
        )

        let store = VoiceDictationModelStore(rootDirectory: root)

        XCTAssertEqual(store.state(of: .whisperTinyEnglish), .updateAvailable)
        XCTAssertTrue(store.hasUpdate(for: .whisperTiny))
        XCTAssertFalse(store.isReady(.whisperTiny), "an outdated model must be replaced before use")
    }

    func testReceiptlessVerifiedInstallIsMigratedOnce() throws {
        let payload = Data("verified model".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let descriptor = VoiceDictationModelDescriptor(
            id: .whisperTinyEnglish,
            title: "Fixture",
            publisher: "Fixture",
            role: "Test",
            repository: "fixture/model",
            revision: "0123456789012345678901234567890123456789",
            directoryName: "fixture",
            license: "Test",
            licenseNote: "Test",
            runtime: "Test",
            sourceURL: URL(string: "https://example.com")!
        )
        let directory = root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: directory.appendingPathComponent("weights.bin"))
        let pinned = VoiceDictationModelFile(path: "weights.bin", size: Int64(payload.count), sha256: hash)

        let state = VoiceDictationModelStore.installationState(
            descriptor: descriptor,
            files: [pinned],
            at: directory
        )

        XCTAssertEqual(state, .downloaded)
        let receiptData = try Data(contentsOf: directory.appendingPathComponent(VoiceDictationModelReceipt.fileName))
        XCTAssertEqual(try JSONDecoder().decode(VoiceDictationModelReceipt.self, from: receiptData).revision, descriptor.revision)
    }

    func testReceiptlessSameSizeButWrongHashRequiresUpdate() throws {
        let expected = Data("expected".utf8)
        let actual = Data("wrongone".utf8)
        XCTAssertEqual(expected.count, actual.count)
        let hash = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        let descriptor = VoiceDictationModelDescriptor(
            id: .whisperTinyEnglish,
            title: "Fixture",
            publisher: "Fixture",
            role: "Test",
            repository: "fixture/model",
            revision: "0123456789012345678901234567890123456789",
            directoryName: "fixture",
            license: "Test",
            licenseNote: "Test",
            runtime: "Test",
            sourceURL: URL(string: "https://example.com")!
        )
        let directory = root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try actual.write(to: directory.appendingPathComponent("weights.bin"))
        let pinned = VoiceDictationModelFile(path: "weights.bin", size: Int64(expected.count), sha256: hash)

        XCTAssertEqual(
            VoiceDictationModelStore.installationState(descriptor: descriptor, files: [pinned], at: directory),
            .updateAvailable
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(VoiceDictationModelReceipt.fileName).path
        ))
    }

    func testEngineRemoveDeletesEveryInstalledAssetAndStagingDirectory() throws {
        let engine = VoiceDictationEngine.parakeetS1
        for id in engine.requiredModels {
            let descriptor = VoiceDictationModelManifest.descriptor(for: id)
            let directory = root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
            for file in descriptor.files {
                let target = directory.appendingPathComponent(file.path)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileHandle.sparseFile(at: target, size: file.size)
            }
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(descriptor.directoryName + ".partial"),
                withIntermediateDirectories: true
            )
            try VoiceDictationModelStore.writeReceipt(for: descriptor, into: directory)
        }
        let store = VoiceDictationModelStore(rootDirectory: root)
        XCTAssertTrue(store.isReady(engine))

        try store.remove(engine)

        for id in engine.requiredModels {
            let descriptor = VoiceDictationModelManifest.descriptor(for: id)
            XCTAssertEqual(store.state(of: id), .notDownloaded)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(descriptor.directoryName).path
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(descriptor.directoryName + ".partial").path
            ))
        }
    }

    func testLocalDataDetectsAndRemovesOutdatedAndPartialModels() throws {
        let id = VoiceDictationModelID.whisperTinyEnglish
        let descriptor = VoiceDictationModelManifest.descriptor(for: id)
        let installed = root.appendingPathComponent(descriptor.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try JSONEncoder().encode(VoiceDictationModelReceipt(revision: "old-revision")).write(
            to: installed.appendingPathComponent(VoiceDictationModelReceipt.fileName)
        )
        let partial = root.appendingPathComponent(descriptor.directoryName + ".partial", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partial.appendingPathComponent("download"))

        let store = VoiceDictationModelStore(rootDirectory: root)
        XCTAssertEqual(store.state(of: id), .updateAvailable)
        XCTAssertTrue(store.hasLocalData(id))
        XCTAssertTrue(store.hasLocalData(for: .whisperTiny))

        try store.remove(id)

        XCTAssertFalse(store.hasLocalData(id))
        XCTAssertEqual(store.state(of: id), .notDownloaded)
    }

    func testCommitReplacesDestinationAtomically() async throws {
        let staging = root.appendingPathComponent("m.partial", isDirectory: true)
        let destination = root.appendingPathComponent("m", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staging.appendingPathComponent("a"))
        try Data("old".utf8).write(to: destination.appendingPathComponent("stale"))

        try await VoiceDictationModelStore.commit(staging: staging, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale").path))
    }

    func testSHA256MatchesCryptoKit() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("blob")
        let data = Data((0 ..< 5_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try data.write(to: url)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try VoiceDictationModelStore.sha256Hex(of: url), expected)
    }

    func testModelsLiveUnderNanoApplicationSupport() {
        let path = VoiceDictationModelStore.defaultRootDirectory.path
        XCTAssertTrue(path.hasPrefix(NanoStorage.root.path))
        XCTAssertTrue(path.hasSuffix("VoiceDictation/Models"))
    }
}

private extension FileHandle {
    /// A file of exactly `size` bytes without writing them all.
    static func sparseFile(at url: URL, size: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }
}
