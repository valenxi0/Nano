import AppKit
import Foundation

/// Totals behind Settings → Voice Dictation → Insights.
///
/// Counts only. No transcript, phrase, or audio is ever written here: a
/// dictation contributes its word count, its audio length, the app it went
/// into, how many filler words cleanup removed, which dictionary entries fired
/// (by ID), and how long release-to-paste took.
struct VoiceDictationStats: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        var words = 0
        var seconds: Double = 0
        var sessions = 0
    }

    /// Keyed by local calendar day, "yyyy-MM-dd".
    var days: [String: Day] = [:]
    /// Words per app per month: "yyyy-MM" → bundle ID → words.
    var appWords: [String: [String: Int]] = [:]
    var appNames: [String: String] = [:]
    var fillersRemoved = 0
    /// Dictionary entry ID → times it fired.
    var dictionaryHits: [String: Int] = [:]
    /// The most recent release-to-paste times, newest last.
    var latencies: [Double] = []
    var since: Date?
}

@MainActor
final class VoiceDictationStatsStore: ObservableObject {
    /// The typing speed "time saved" is measured against.
    static let typingWordsPerMinute: Double = 40
    private static let latencyWindow = 200

    @Published private(set) var stats = VoiceDictationStats()

    let fileURL: URL
    private let calendar: Calendar

    static var defaultFileURL: URL {
        NanoStorage.root
            .appendingPathComponent("VoiceDictation", isDirectory: true)
            .appendingPathComponent("stats.json")
    }

    init(fileURL: URL = VoiceDictationStatsStore.defaultFileURL, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.calendar = calendar
        load()
    }

    var isEmpty: Bool { stats.days.isEmpty }

    // MARK: Writing

    func record(
        words: Int,
        seconds: Double,
        fillersRemoved: Int,
        dictionaryEntryIDs: [UUID],
        latency: Double?,
        app: (bundleID: String, name: String)?,
        at date: Date = Date()
    ) {
        guard words > 0 else { return }
        var next = stats
        let day = dayKey(date)
        next.days[day, default: .init()].words += words
        next.days[day, default: .init()].seconds += max(seconds, 0)
        next.days[day, default: .init()].sessions += 1
        if let app {
            next.appWords[monthKey(date), default: [:]][app.bundleID, default: 0] += words
            next.appNames[app.bundleID] = app.name
        }
        next.fillersRemoved += max(fillersRemoved, 0)
        for id in dictionaryEntryIDs {
            next.dictionaryHits[id.uuidString, default: 0] += 1
        }
        if let latency, latency > 0 {
            next.latencies.append(latency)
            if next.latencies.count > Self.latencyWindow {
                next.latencies.removeFirst(next.latencies.count - Self.latencyWindow)
            }
        }
        if next.since == nil { next.since = date }
        stats = next
        save()
    }

    func reset() {
        stats = VoiceDictationStats()
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Filler words in `raw` that cleanup took out of `final`.
    nonisolated static func fillersRemoved(raw: String, final: String) -> Int {
        max(fillerCount(raw) - fillerCount(final), 0)
    }

    nonisolated static func fillerCount(_ text: String) -> Int {
        let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "mm", "ah"]
        return text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .filter { fillers.contains(String($0)) }
            .count
    }

    // MARK: Reading

    var totalWords: Int { stats.days.values.reduce(0) { $0 + $1.words } }

    func words(from start: Date, through end: Date = Date()) -> Int {
        range(from: start, through: end).reduce(0) { $0 + $1.words }
    }

    /// Words per minute of speech over the last `days` days.
    func speed(lastDays days: Int = 30, now: Date = Date()) -> Double? {
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) else { return nil }
        let window = range(from: start, through: now)
        let seconds = window.reduce(0) { $0 + $1.seconds }
        guard seconds >= 5 else { return nil }
        return Double(window.reduce(0) { $0 + $1.words }) / (seconds / 60)
    }

    /// Speed on each of the last `count` days that had dictation, oldest first.
    func dailySpeeds(count: Int = 15) -> [Double] {
        stats.days.keys.sorted().suffix(count).compactMap { key in
            guard let day = stats.days[key], day.seconds >= 3 else { return nil }
            return Double(day.words) / (day.seconds / 60)
        }
    }

    /// Typing time the dictation replaced, less the time spent speaking.
    func timeSaved(from start: Date, through end: Date = Date()) -> TimeInterval {
        let window = range(from: start, through: end)
        let words = Double(window.reduce(0) { $0 + $1.words })
        let spoken = window.reduce(0) { $0 + $1.seconds }
        return max(words / Self.typingWordsPerMinute * 60 - spoken, 0)
    }

    var currentStreak: Int {
        var day = calendar.startOfDay(for: Date())
        // Today doesn't break a streak until it's over.
        if stats.days[dayKey(day)] == nil, let yesterday = calendar.date(byAdding: .day, value: -1, to: day) {
            day = yesterday
        }
        var count = 0
        while stats.days[dayKey(day)] != nil {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    var longestStreak: Int {
        let dates = stats.days.keys.sorted().compactMap(date(fromKey:))
        var longest = 0
        var run = 0
        var previous: Date?
        for date in dates {
            if let previous, calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        return longest
    }

    /// Word counts for the last `weeks` weeks, one array of 7 per week (Monday
    /// first), oldest week first. Future days are nil.
    func heatmap(weeks: Int, now: Date = Date()) -> [[(date: Date, words: Int)?]] {
        var mondayCalendar = calendar
        mondayCalendar.firstWeekday = 2
        guard let thisWeek = mondayCalendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let today = calendar.startOfDay(for: now)
        return (0..<weeks).reversed().map { back in
            let weekStart = mondayCalendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek) ?? thisWeek
            return (0..<7).map { offset in
                guard let date = mondayCalendar.date(byAdding: .day, value: offset, to: weekStart),
                      date <= today else { return nil }
                return (date, stats.days[dayKey(date)]?.words ?? 0)
            }
        }
    }

    /// Apps by words dictated this month, largest first.
    func apps(in month: Date = Date()) -> [(bundleID: String, name: String, words: Int)] {
        (stats.appWords[monthKey(month)] ?? [:])
            .map { (bundleID: $0.key, name: stats.appNames[$0.key] ?? $0.key, words: $0.value) }
            .sorted { $0.words > $1.words }
    }

    func hits(for entry: UUID) -> Int {
        stats.dictionaryHits[entry.uuidString] ?? 0
    }

    // MARK: Storage

    private func range(from start: Date, through end: Date) -> [VoiceDictationStats.Day] {
        let lower = dayKey(start)
        let upper = dayKey(end)
        return stats.days.filter { $0.key >= lower && $0.key <= upper }.map(\.value)
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func monthKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private func date(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        stats = (try? decoder.decode(VoiceDictationStats.self, from: data)) ?? VoiceDictationStats()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(stats) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
