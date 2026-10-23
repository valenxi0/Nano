import Foundation

struct VoiceDictationHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let engine: VoiceDictationEngine
    let createdAt: Date
    /// Where it landed and how long it took. Absent on entries written
    /// before Quill recorded them.
    var appName: String?
    var bundleID: String?
    var audioSeconds: Double?
    var latency: Double?
    /// What the recognizer heard, before cleanup, and the style and context
    /// it was cleaned for, so the entry can be redone in another style.
    var raw: String?
    var level: VoiceDictationCleanupLevel?
    var context: VoiceDictationAppContext?

    func isExpired(at now: Date, retention: TimeInterval) -> Bool {
        now.timeIntervalSince(createdAt) >= retention
    }
}

/// Optional local backup for the clipboard. Off by default; final text only,
/// never audio; every record is removed 24 hours after it was written.
///
/// This is an application retention policy, not secure erasure: records are
/// deleted from Nano's JSON store on schedule, and the file is rewritten
/// atomically each time so a crash cannot leave a half-written history.
@MainActor
final class VoiceDictationHistoryStore: ObservableObject {
    static let retention: TimeInterval = 24 * 60 * 60

    @Published private(set) var entries: [VoiceDictationHistoryEntry] = []

    let fileURL: URL
    private let now: @Sendable () -> Date
    private var purgeTimer: Timer?

    static var defaultFileURL: URL {
        NanoStorage.root
            .appendingPathComponent("VoiceDictation", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    init(
        fileURL: URL = VoiceDictationHistoryStore.defaultFileURL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.now = now
        load()
        // Launch is also a purge point: records that expired while Nano was
        // not running go now rather than at the next dictation.
        purgeExpired()
    }

    /// The soonest moment a stored record expires, for scheduling.
    var nextExpiry: Date? {
        entries.map { $0.createdAt.addingTimeInterval(Self.retention) }.min()
    }

    func record(
        _ text: String,
        engine: VoiceDictationEngine,
        app: (bundleID: String, name: String)? = nil,
        audioSeconds: Double? = nil,
        latency: Double? = nil,
        raw: String? = nil,
        level: VoiceDictationCleanupLevel? = nil,
        context: VoiceDictationAppContext? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        purgeExpired()
        entries.insert(
            VoiceDictationHistoryEntry(
                id: UUID(), text: trimmed, engine: engine, createdAt: now(),
                appName: app?.name, bundleID: app?.bundleID,
                audioSeconds: audioSeconds, latency: latency,
                raw: raw, level: level, context: context
            ),
            at: 0
        )
        save()
        schedulePurge()
    }

    @discardableResult
    func purgeExpired() -> Int {
        let current = now()
        let kept = entries.filter { !$0.isExpired(at: current, retention: Self.retention) }
        let removed = entries.count - kept.count
        if removed > 0 {
            entries = kept
            save()
        }
        schedulePurge()
        return removed
    }

    func clear() {
        entries = []
        save()
        purgeTimer?.invalidate()
        purgeTimer = nil
    }

    func remove(_ entry: VoiceDictationHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Stops the timer. The store stays readable. The controller no longer
    /// calls this when Quill is turned off: the 24 hour limit keeps running.
    func suspend() {
        purgeTimer?.invalidate()
        purgeTimer = nil
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([VoiceDictationHistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let fileManager = FileManager.default
        if entries.isEmpty {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: fileURL, options: [.atomic])
        } catch {
            // A failed save leaves the previous file in place; the in-memory
            // list is still authoritative for this session.
        }
    }

    private func schedulePurge() {
        purgeTimer?.invalidate()
        purgeTimer = nil
        guard let nextExpiry else { return }
        let interval = max(nextExpiry.timeIntervalSince(now()), 1)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.purgeExpired() }
        }
        timer.tolerance = min(interval * 0.1, 60)
        RunLoop.main.add(timer, forMode: .common)
        purgeTimer = timer
    }
}
