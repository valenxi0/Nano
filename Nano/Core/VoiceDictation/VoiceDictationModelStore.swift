import CryptoKit
import Foundation

struct VoiceDictationModelFile: Equatable, Hashable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
}

/// Provenance for one model asset. Everything a future update or a license
/// review needs is here rather than scattered through download code.
struct VoiceDictationModelDescriptor: Identifiable, Equatable, Sendable {
    let id: VoiceDictationModelID
    let title: String
    let publisher: String
    /// What the asset does in the pipeline, in the user's words.
    let role: String
    let repository: String
    let revision: String
    let directoryName: String
    let license: String
    let licenseNote: String
    let runtime: String
    let sourceURL: URL

    var files: [VoiceDictationModelFile] {
        VoiceDictationModelManifest.pinnedFiles[id] ?? []
    }

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    func remoteURL(for file: VoiceDictationModelFile) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(file.path)"
        return components.url!
    }
}

enum VoiceDictationModelManifest {
    static let descriptors: [VoiceDictationModelDescriptor] = [
        VoiceDictationModelDescriptor(
            id: .parakeetTDT06BV3,
            title: "Parakeet TDT 0.6B v3",
            publisher: "NVIDIA, Core ML conversion by Fluid Inference",
            role: "Speech recognition",
            repository: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
            // Must equal FluidAudio's `Repo.parakeetV3.folderName`: it resolves
            // the cache as `<parent>/<folderName>` from the URL we hand it.
            directoryName: "parakeet-tdt-0.6b-v3",
            license: "CC BY 4.0",
            licenseNote: "Attribution to NVIDIA is required. Verify commercial distribution terms before bundling or redistributing the weights.",
            runtime: "Core ML via FluidAudio (Neural Engine)",
            sourceURL: URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")!
        ),
        VoiceDictationModelDescriptor(
            id: .parakeetVocabularyBooster,
            title: "Vocabulary booster",
            publisher: "NVIDIA Parakeet CTC 110M, Core ML conversion by Fluid Inference",
            role: "Listens for your dictionary terms",
            repository: "FluidInference/parakeet-ctc-110m-coreml",
            revision: "accdafd8cf8a2ff1cabe3c11e54416b405d409aa",
            directoryName: "parakeet-ctc-110m",
            license: "CC BY 4.0",
            licenseNote: "Attribution to NVIDIA is required. Optional: Parakeet runs without it, and uses it to hear your dictionary terms.",
            runtime: "Core ML via FluidAudio (Neural Engine)",
            sourceURL: URL(string: "https://huggingface.co/nvidia/parakeet-tdt_ctc-110m")!
        ),
        VoiceDictationModelDescriptor(
            id: .s1Mini,
            title: "S1-mini",
            publisher: "Superwhisper",
            role: "Text cleanup",
            repository: "superwhisper/s1-mini-GGUF",
            revision: "34add00a48a2e5d24e5a4ee5405a99620a3a240c",
            directoryName: "s1-mini",
            license: "Apache 2.0 with naming clause",
            licenseNote: "The model must keep its name, “S1-mini” by “Superwhisper”, with that exact capitalization wherever it is used. LICENSE and NOTICE are downloaded alongside the weights and must be retained.",
            runtime: "GGUF Q4_K_M via llama.cpp (Metal)",
            sourceURL: URL(string: "https://huggingface.co/superwhisper/s1-mini")!
        ),
        VoiceDictationModelDescriptor(
            id: .cohereTranscribe,
            title: "Cohere Transcribe 03-2026",
            publisher: "Cohere Labs, Core ML conversion by Fluid Inference",
            role: "Speech recognition in 14 languages",
            repository: "FluidInference/cohere-transcribe-03-2026-coreml",
            revision: "fccec19ecf93b40969d4888f27e10d714daeb3cf",
            directoryName: "cohere-transcribe-03-2026",
            license: "Apache 2.0",
            licenseNote: "Cohere Transcribe and its Core ML conversion are Apache 2.0 licensed. The README is kept with the weights.",
            runtime: "Core ML via FluidAudio (Neural Engine)",
            sourceURL: URL(string: "https://huggingface.co/CohereLabs/cohere-transcribe-03-2026")!
        ),
        VoiceDictationModelDescriptor(
            id: .whisperLargeV3Turbo,
            title: "Whisper Large v3 Turbo",
            publisher: "OpenAI, ggml conversion by Georgi Gerganov",
            role: "Speech recognition in 99 languages",
            repository: "ggerganov/whisper.cpp",
            revision: "5359861c739e955e79d9a303bcbc70fb988958b1",
            directoryName: "whisper-large-v3-turbo",
            license: "MIT",
            licenseNote: "OpenAI Whisper weights and the ggml conversion are MIT licensed. Quantized to 5 bits.",
            runtime: "ggml Q5_0 via whisper.cpp (Metal)",
            sourceURL: URL(string: "https://github.com/openai/whisper")!
        ),
        VoiceDictationModelDescriptor(
            id: .whisperBaseEnglish,
            title: "Whisper Base (English)",
            publisher: "OpenAI, ggml conversion by Georgi Gerganov",
            role: "Speech recognition",
            repository: "ggerganov/whisper.cpp",
            revision: "5359861c739e955e79d9a303bcbc70fb988958b1",
            directoryName: "whisper-base.en",
            license: "MIT",
            licenseNote: "OpenAI Whisper weights and the ggml conversion are MIT licensed.",
            runtime: "ggml via whisper.cpp (Metal)",
            sourceURL: URL(string: "https://github.com/openai/whisper")!
        ),
        VoiceDictationModelDescriptor(
            id: .whisperTinyEnglish,
            title: "Whisper Tiny (English)",
            publisher: "OpenAI, ggml conversion by Georgi Gerganov",
            role: "Speech recognition",
            repository: "ggerganov/whisper.cpp",
            revision: "5359861c739e955e79d9a303bcbc70fb988958b1",
            directoryName: "whisper-tiny.en",
            license: "MIT",
            licenseNote: "OpenAI Whisper weights and the ggml conversion are MIT licensed.",
            runtime: "ggml via whisper.cpp (Metal)",
            sourceURL: URL(string: "https://github.com/openai/whisper")!
        ),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

    static func descriptor(for id: VoiceDictationModelID) -> VoiceDictationModelDescriptor {
        byID[id]!
    }

    /// The primary weights file for engines that load a single file.
    static func primaryFile(for id: VoiceDictationModelID) -> String? {
        switch id {
        case .s1Mini: "s1-mini-q4_k_m.gguf"
        case .whisperBaseEnglish: "ggml-base.en.bin"
        case .whisperTinyEnglish: "ggml-tiny.en.bin"
        case .whisperLargeV3Turbo: "ggml-large-v3-turbo-q5_0.bin"
        case .parakeetTDT06BV3, .parakeetVocabularyBooster, .cohereTranscribe: nil
        }
    }
}

enum VoiceDictationModelState: Equatable, Sendable {
    case notDownloaded
    case updateAvailable
    case downloading(fraction: Double, bytesReceived: Int64)
    case verifying
    case downloaded
    case failed(String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        if case .verifying = self { return true }
        return false
    }

    var isDownloaded: Bool { self == .downloaded }

}

/// Written beside verified weights so a later Nano release can tell that its
/// newly pinned model revision differs from the one already on disk.
struct VoiceDictationModelReceipt: Codable, Equatable, Sendable {
    let revision: String

    static let fileName = ".nano-model.json"
}

enum VoiceDictationModelStoreError: Error, Equatable {
    case checksumMismatch(String)
    case sizeMismatch(String)
    case httpStatus(Int, String)
    case cancelled
}

/// Owns the on-disk model library: where assets live, whether they are
/// complete, and the download/verify/remove lifecycle. Downloads never run
/// on the main actor; only state publication does.
@MainActor
final class VoiceDictationModelStore: ObservableObject {
    @Published private(set) var states: [VoiceDictationModelID: VoiceDictationModelState] = [:]

    let rootDirectory: URL
    private let session: URLSession
    private var downloadTasks: [VoiceDictationModelID: Task<Void, Never>] = [:]
    private var legacyVerificationTasks: [VoiceDictationModelID: Task<Void, Never>] = [:]

    static var defaultRootDirectory: URL {
        NanoStorage.root
            .appendingPathComponent("VoiceDictation", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    init(rootDirectory: URL = VoiceDictationModelStore.defaultRootDirectory, session: URLSession = .shared) {
        self.rootDirectory = rootDirectory
        self.session = session
        refresh()
    }

    // MARK: - Locations

    func directory(for id: VoiceDictationModelID) -> URL {
        rootDirectory.appendingPathComponent(
            VoiceDictationModelManifest.descriptor(for: id).directoryName,
            isDirectory: true
        )
    }

    private func stagingDirectory(for id: VoiceDictationModelID) -> URL {
        rootDirectory.appendingPathComponent(
            VoiceDictationModelManifest.descriptor(for: id).directoryName + ".partial",
            isDirectory: true
        )
    }

    func primaryFileURL(for id: VoiceDictationModelID) -> URL? {
        guard let name = VoiceDictationModelManifest.primaryFile(for: id) else { return nil }
        return directory(for: id).appendingPathComponent(name)
    }

    // MARK: - State

    func state(of id: VoiceDictationModelID) -> VoiceDictationModelState {
        states[id] ?? .notDownloaded
    }

    func isInstalled(_ id: VoiceDictationModelID) -> Bool {
        state(of: id).isDownloaded
    }

    func missingModels(for engine: VoiceDictationEngine) -> [VoiceDictationModelID] {
        engine.requiredModels.filter { !isInstalled($0) }
    }

    func isReady(_ engine: VoiceDictationEngine) -> Bool {
        missingModels(for: engine).isEmpty
    }

    func hasUpdate(for engine: VoiceDictationEngine) -> Bool {
        engine.requiredModels.contains { state(of: $0) == .updateAvailable }
    }

    func hasLocalData(_ id: VoiceDictationModelID) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: directory(for: id).path)
            || fileManager.fileExists(atPath: stagingDirectory(for: id).path)
    }

    func hasLocalData(for engine: VoiceDictationEngine) -> Bool {
        engine.requiredModels.contains(where: hasLocalData)
    }

    /// Rescans the disk. Downloads in flight keep their live state.
    func refresh() {
        for id in VoiceDictationModelID.allCases {
            if state(of: id).isDownloading { continue }
            let descriptor = VoiceDictationModelManifest.descriptor(for: id)
            let directory = directory(for: id)
            let state = Self.installationState(descriptor: descriptor, at: directory)
            states[id] = state

            guard state == .updateAvailable,
                  Self.hasCompleteReceiptlessInstall(descriptor: descriptor, at: directory),
                  legacyVerificationTasks[id] == nil
            else { continue }

            states[id] = .verifying
            legacyVerificationTasks[id] = Task.detached(priority: .utility) { [weak self] in
                let verifiedState = Self.installationState(
                    descriptor: descriptor,
                    files: descriptor.files,
                    at: directory
                )
                await MainActor.run {
                    guard let self, self.legacyVerificationTasks[id] != nil else { return }
                    self.states[id] = verifiedState
                    self.legacyVerificationTasks[id] = nil
                }
            }
        }
    }

    nonisolated static func installationState(
        descriptor: VoiceDictationModelDescriptor,
        at directory: URL
    ) -> VoiceDictationModelState {
        let receiptURL = directory.appendingPathComponent(VoiceDictationModelReceipt.fileName)
        if let data = try? Data(contentsOf: receiptURL),
           let receipt = try? JSONDecoder().decode(VoiceDictationModelReceipt.self, from: data) {
            guard receipt.revision == descriptor.revision else { return .updateAvailable }
            return isComplete(descriptor: descriptor, at: directory) ? .downloaded : .notDownloaded
        }
        return isComplete(descriptor: descriptor, at: directory) ? .updateAvailable : .notDownloaded
    }

    /// Verifies a receipt-less install once, off the main actor in production,
    /// then records the pinned revision so future launches only need size checks.
    nonisolated static func installationState(
        descriptor: VoiceDictationModelDescriptor,
        files: [VoiceDictationModelFile],
        at directory: URL
    ) -> VoiceDictationModelState {
        guard isComplete(files: files, at: directory) else { return .notDownloaded }
        do {
            for file in files {
                guard try sha256Hex(of: directory.appendingPathComponent(file.path)) == file.sha256 else {
                    return .updateAvailable
                }
            }
            try writeReceipt(for: descriptor, into: directory)
            return .downloaded
        } catch {
            return .updateAvailable
        }
    }

    /// Complete means every pinned file exists with the pinned byte size. Hashes
    /// are verified once, at download time; re-hashing 480 MB on every launch
    /// would be paid by every user for no realistic gain.
    nonisolated static func isComplete(descriptor: VoiceDictationModelDescriptor, at directory: URL) -> Bool {
        isComplete(files: descriptor.files, at: directory)
    }

    private nonisolated static func isComplete(files: [VoiceDictationModelFile], at directory: URL) -> Bool {
        let fileManager = FileManager.default
        for file in files {
            let url = directory.appendingPathComponent(file.path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value == file.size
            else {
                return false
            }
        }
        return true
    }

    private nonisolated static func hasCompleteReceiptlessInstall(
        descriptor: VoiceDictationModelDescriptor,
        at directory: URL
    ) -> Bool {
        !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(VoiceDictationModelReceipt.fileName).path
        ) && isComplete(descriptor: descriptor, at: directory)
    }

    // MARK: - Download

    func download(_ id: VoiceDictationModelID) {
        guard downloadTasks[id] == nil, !isInstalled(id) else { return }
        legacyVerificationTasks[id]?.cancel()
        legacyVerificationTasks[id] = nil
        let descriptor = VoiceDictationModelManifest.descriptor(for: id)
        let staging = stagingDirectory(for: id)
        let destination = directory(for: id)
        if let shortfall = Self.spaceShortfall(needing: descriptor.files.reduce(0) { $0 + $1.size }, at: rootDirectory) {
            states[id] = .failed("Not enough space. Free up \(Self.byteString(shortfall)) and retry.")
            return
        }
        let session = self.session
        states[id] = .downloading(fraction: 0, bytesReceived: 0)

        downloadTasks[id] = Task { [weak self] in
            do {
                let report: @Sendable (Double, Int64) -> Void = { [weak self] fraction, bytes in
                    Task { @MainActor in
                        guard let self, self.downloadTasks[id] != nil else { return }
                        self.states[id] = .downloading(fraction: fraction, bytesReceived: bytes)
                    }
                }
                try await Self.fetch(
                    descriptor: descriptor,
                    into: staging,
                    session: session,
                    progress: report
                )
                try Task.checkCancellation()
                try Self.writeReceipt(for: descriptor, into: staging)
                await MainActor.run { [weak self] in self?.states[id] = .verifying }
                try await Self.commit(staging: staging, to: destination)
                await MainActor.run { [weak self] in
                    self?.states[id] = .downloaded
                    self?.downloadTasks[id] = nil
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.states[id] = .notDownloaded
                    self?.downloadTasks[id] = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.states[id] = .failed(Self.describe(error))
                    self?.downloadTasks[id] = nil
                }
            }
        }
    }

    /// One user action installs every asset required by an engine. Existing
    /// assets are left alone; outdated assets are replaced from pinned URLs.
    func download(_ engine: VoiceDictationEngine) {
        for id in missingModels(for: engine) {
            download(id)
        }
    }

    func cancelDownload(_ id: VoiceDictationModelID) {
        downloadTasks[id]?.cancel()
    }

    func remove(_ id: VoiceDictationModelID) throws {
        cancelDownload(id)
        legacyVerificationTasks[id]?.cancel()
        legacyVerificationTasks[id] = nil
        let fileManager = FileManager.default
        for url in [directory(for: id), stagingDirectory(for: id)] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        states[id] = .notDownloaded
    }

    func remove(_ engine: VoiceDictationEngine) throws {
        for id in engine.requiredModels {
            try remove(id)
        }
    }

    nonisolated static func writeReceipt(
        for descriptor: VoiceDictationModelDescriptor,
        into directory: URL
    ) throws {
        let receipt = VoiceDictationModelReceipt(revision: descriptor.revision)
        let data = try JSONEncoder().encode(receipt)
        try data.write(
            to: directory.appendingPathComponent(VoiceDictationModelReceipt.fileName),
            options: .atomic
        )
    }

    nonisolated static func spaceShortfall(needing bytes: Int64, at directory: URL) -> Int64? {
        var probe = directory
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        let needed = bytes + 200_000_000
        return available < needed ? needed - available : nil
    }

    nonisolated static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let storeError as VoiceDictationModelStoreError:
            switch storeError {
            case .checksumMismatch, .sizeMismatch:
                return "The download didn't check out. Retry gets a fresh copy."
            case let .httpStatus(code, path):
                return "The server returned \(code) for \(path). Check the connection and retry."
            case .cancelled:
                return "Cancelled."
            }
        case let urlError as URLError:
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return "You're offline. Retry once you're back."
            case .networkConnectionLost, .timedOut:
                return "The connection dropped before it finished."
            default:
                return urlError.localizedDescription
            }
        default:
            return error.localizedDescription
        }
    }

    /// Downloads every pinned file into `staging`, skipping files that already
    /// match, so a retry resumes at file granularity. Streams each file to
    /// disk and hashes it there; nothing large is held in memory.
    nonisolated static func fetch(
        descriptor: VoiceDictationModelDescriptor,
        into staging: URL,
        session: URLSession,
        progress: @escaping @Sendable (Double, Int64) -> Void
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = max(descriptor.totalBytes, 1)
        var completedBytes: Int64 = 0

        for file in descriptor.files {
            try Task.checkCancellation()
            let target = staging.appendingPathComponent(file.path)
            if let existing = try? fileManager.attributesOfItem(atPath: target.path)[.size] as? NSNumber,
               existing.int64Value == file.size,
               try sha256Hex(of: target) == file.sha256
            {
                completedBytes += file.size
                progress(Double(completedBytes) / Double(total), completedBytes)
                continue
            }
            try? fileManager.removeItem(at: target)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let base = completedBytes
            let temporary = try await ModelFileDownloader.download(
                descriptor.remoteURL(for: file),
                expectedBytes: file.size,
                session: session
            ) { received in
                progress(Double(base + received) / Double(total), base + received)
            }
            defer { try? fileManager.removeItem(at: temporary) }

            let size = (try? fileManager.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size == file.size else {
                throw VoiceDictationModelStoreError.sizeMismatch(file.path)
            }
            guard try sha256Hex(of: temporary) == file.sha256 else {
                throw VoiceDictationModelStoreError.checksumMismatch(file.path)
            }
            try fileManager.moveItem(at: temporary, to: target)
            completedBytes += file.size
            progress(Double(completedBytes) / Double(total), completedBytes)
        }
    }

    /// Atomically swaps the completed staging directory into place so a model
    /// directory is either complete or absent, never half-written.
    ///
    /// `async` so it runs off the main actor: removing a stale 480 MB
    /// directory is a real amount of filesystem work.
    nonisolated static func commit(staging: URL, to destination: URL) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: staging, to: destination)
    }

    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 << 20)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One URL to one temporary file with byte-level progress. `URLSession`'s
/// async `download(for:)` reports no progress and `bytes(for:)` is per-byte,
/// so this is the delegate-based task wrapped for structured concurrency.
private final class ModelFileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    private init(progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    static func download(
        _ url: URL,
        expectedBytes: Int64,
        session: URLSession,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        let delegate = ModelFileDownloader(progress: progress)
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let task = session.downloadTask(with: request)
        task.delegate = delegate
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.lock.withLock { delegate.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200 ..< 300).contains(response.statusCode) {
            finish(.failure(VoiceDictationModelStoreError.httpStatus(
                response.statusCode,
                downloadTask.originalRequest?.url?.lastPathComponent ?? "file"
            )))
            return
        }
        // `location` is deleted when this callback returns; keep our own copy.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("nano-voice-dictation-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            finish(.success(kept))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(error))
        }
    }
}
