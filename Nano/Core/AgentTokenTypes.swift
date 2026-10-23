import Foundation

// Shared contracts for the agent usage, token, and pricing layers. Every provider
// adapter converts into these types so the rest of Nano never has to know how an
// individual CLI reports its numbers.

/// Mutually exclusive token buckets.
///
/// Providers disagree on conventions: Codex folds cached tokens into its input
/// count, Claude reports them as separate fields. Adapters normalize into these
/// buckets so totals from different providers can be added together.
struct NanoTokenCounts: Codable, Equatable, Sendable {
    /// Input billed at the full rate, with cached tokens excluded.
    var freshInput = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var output = 0
    /// Subset of `output`, carried for display only — never added to `total`.
    var reasoning = 0

    var total: Int {
        freshInput + cacheRead + cacheWrite5m + cacheWrite1h + output
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        NanoTokenCounts(
            freshInput: lhs.freshInput + rhs.freshInput,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h,
            output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning
        )
    }

    static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }

    func contains(_ other: Self) -> Bool {
        freshInput >= other.freshInput
            && cacheRead >= other.cacheRead
            && cacheWrite5m >= other.cacheWrite5m
            && cacheWrite1h >= other.cacheWrite1h
            && output >= other.output
            && reasoning >= other.reasoning
    }

    mutating func subtract(_ other: Self) {
        guard contains(other) else { return }
        freshInput -= other.freshInput
        cacheRead -= other.cacheRead
        cacheWrite5m -= other.cacheWrite5m
        cacheWrite1h -= other.cacheWrite1h
        output -= other.output
        reasoning -= other.reasoning
    }
}

/// One ledger row per provider, per local calendar day, per model. This grain is
/// what serves the today / week / month / lifetime filters, and per-model is
/// required because each model prices differently.
struct NanoTokenRollup: Codable, Equatable, Sendable {
    let provider: String
    /// `yyyy-MM-dd` in the user's local time zone.
    let day: String
    let model: String
    var counts: NanoTokenCounts
    /// Integer nanodollars. Summing Doubles over billions of tokens drifts.
    var costNanos: Int
    /// False when no price could be resolved, so the UI can say "partial"
    /// instead of silently reporting a low total as if it were complete.
    var priced: Bool

    static func key(provider: String, day: String, model: String) -> String {
        "\(provider)|\(day)|\(model)"
    }
}

enum NanoTokenWindow: String, CaseIterable, Identifiable, Sendable {
    case today
    case week
    case month
    case lifetime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "This Week"
        case .month: "This Month"
        case .lifetime: "Lifetime"
        }
    }
}

/// Aggregated answer for one window.
struct NanoTokenTotals: Equatable, Sendable {
    var counts = NanoTokenCounts()
    var costNanos = 0
    /// Models encountered with no resolvable price.
    var unpricedModels: Set<String> = []
    /// Earliest recovered session day, not the date Nano was installed.
    var trackedSince: Date?
    /// False when any counted row lacked pricing, or when history predates the
    /// ledger. Never label an incomplete total "Lifetime" without qualification.
    var isComplete = true

    var costUSD: Double { Double(costNanos) / 1_000_000_000 }
}

/// Aggregated model row for the in-island usage breakdown.
struct NanoTokenModelTotal: Identifiable, Equatable, Sendable {
    let provider: String
    let model: String
    var counts: NanoTokenCounts
    var costNanos: Int
    var priced: Bool

    var id: String { "\(provider)|\(model)" }
}

/// Models grouped by the tool that ran them — the adapter's provider id — so a
/// GPT model used through Cursor lands under Cursor, not under OpenAI.
struct NanoTokenProviderGroup: Identifiable, Equatable, Sendable {
    let provider: String
    /// Sorted by costNanos desc, then counts.total desc.
    var models: [NanoTokenModelTotal]
    /// Sum of the member models' counts.
    var counts: NanoTokenCounts
    /// Sum of the priced models' costNanos.
    var costNanos: Int
    var hasUnpriced: Bool
    var allUnpriced: Bool

    var id: String { provider }

    static func grouping(_ models: [NanoTokenModelTotal]) -> [NanoTokenProviderGroup] {
        var buckets: [String: [NanoTokenModelTotal]] = [:]
        for model in models {
            buckets[model.provider, default: []].append(model)
        }
        return buckets.map { provider, rows in
            NanoTokenProviderGroup(
                provider: provider,
                models: rows.sorted {
                    $0.costNanos != $1.costNanos
                        ? $0.costNanos > $1.costNanos
                        : $0.counts.total > $1.counts.total
                },
                counts: rows.reduce(NanoTokenCounts()) { $0 + $1.counts },
                costNanos: rows.reduce(0) { $0 + ($1.priced ? $1.costNanos : 0) },
                hasUnpriced: rows.contains { !$0.priced },
                allUnpriced: rows.allSatisfy { !$0.priced }
            )
        }
        .sorted {
            $0.costNanos != $1.costNanos
                ? $0.costNanos > $1.costNanos
                : $0.counts.total != $1.counts.total
                    ? $0.counts.total > $1.counts.total
                    : $0.provider < $1.provider
        }
    }
}

/// Resolves prices for a (provider, model) pair. Implemented in ModelPricing.swift.
protocol NanoPriceResolver: Sendable {
    /// Nanodollars for these counts, or nil when the model has no known price.
    ///
    /// `day` is the row's own calendar day. Most models price the same whenever
    /// they ran, but a few names identify a role rather than a model — Codex
    /// logs its review passes as `codex-auto-review` — and which model filled
    /// that role changed over time, so the day is what disambiguates them.
    func costNanos(provider: String, model: String, day: String, counts: NanoTokenCounts) -> Int?

    /// Changes whenever pricing data or the cost formula changes, so previously
    /// computed costs are recomputed rather than served stale.
    var pricingFingerprint: String { get }

    /// Pull a fresher catalog when the cache is stale. Default is a no-op so
    /// tests can keep using a static table.
    func refreshPricing() async
}

extension NanoPriceResolver {
    func refreshPricing() async {}
}

/// Incremental scan bookmark for one log source, so a rescan reads only new bytes.
struct NanoScanWatermark: Codable, Equatable, Sendable {
    var path: String
    var size: Int64
    var modified: Double
    var offset: Int64
    /// For SQLite sources with monotonic AUTOINCREMENT rowids.
    var rowID: Int64?
    /// Tail of the message ids already banked from this source. Restated
    /// messages cluster together, so a bounded window catches a restatement
    /// that straddles two scans without growing the ledger file unboundedly.
    var recentIDs: [String]?
    /// Codex only: what the reader needs to interpret the next chunk of a
    /// rollout it has already started.
    var codex: NanoCodexScanState?
}

/// Stream state for one Codex rollout, carried between incremental scans.
///
/// Codex rollouts are read forward in chunks, and everything needed to read a
/// chunk correctly was established earlier in the file: the model (stated once
/// in `turn_context`, never on the usage event), the last usage event seen
/// (Codex restates one verbatim when nothing moved), and whether this session
/// is a fork still replaying its parent's history. Resuming at a byte offset
/// means none of that can be re-derived, so it is persisted with the watermark.
struct NanoCodexScanState: Codable, Equatable, Sendable {
    var model: String?
    /// Compact form of the last usage event, to drop verbatim restatements.
    var lastUsage: String?
    /// True while the leading burst of a fork's replayed history is being
    /// skipped — see `TokenScanners.replayBurstGap`.
    var isReplayingParent = false
    /// Epoch milliseconds of the last event counted as part of that burst.
    var replayAnchorMs: Double = 0
}

/// One rate-limit window as displayed. Nano shows what is left, not what is used.
struct NanoUsageWindow: Identifiable, Equatable, Sendable {
    /// Stable key, e.g. `codex.primary` or `cursor.models`.
    let id: String
    /// Derived from the window length rather than hardcoded by position —
    /// "5h", "7d", or a provider-specific name like "Cursor Models".
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    let resetAfterSeconds: Int?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

/// Where Nano keeps its own data. Everything is local and lives outside the
/// source tree so it survives rebuilds and ships cleanly.
/// ISO 8601 timestamps, with or without fractional seconds.
///
/// Transcript and usage parsers call this once per record. Building an
/// `ISO8601DateFormatter` each time was most of the cost of a parse, so the
/// two formatters are made once; the class is documented as thread-safe.
enum NanoISO8601 {
    nonisolated(unsafe) private static let precise: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let whole: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ text: String) -> Date? {
        fast(text) ?? precise.date(from: text) ?? whole.date(from: text)
    }

    /// `2026-10-22T19:04:05.123Z` and `+hh:mm` offsets, read straight from the
    /// bytes. The formatters cost tens of microseconds a call, and a transcript
    /// scan makes tens of thousands of calls.
    static func fast(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { bytes -> Date? in
            let count = bytes.count
            guard count >= 20 else { return nil }
            func number(_ start: Int, _ length: Int) -> Int? {
                var value = 0
                for index in start..<start + length {
                    let digit = Int(bytes[index]) - 48
                    guard (0...9).contains(digit) else { return nil }
                    value = value * 10 + digit
                }
                return value
            }
            guard bytes[4] == 45, bytes[7] == 45, bytes[10] == 84 || bytes[10] == 116,
                  bytes[13] == 58, bytes[16] == 58,
                  let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
                  let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2),
                  (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
            else { return nil }

            var index = 19
            var fraction = 0.0
            if bytes[index] == 46 {
                index += 1
                var scale = 0.1
                let start = index
                while index < count, (48...57).contains(bytes[index]) {
                    fraction += Double(bytes[index] - 48) * scale
                    scale /= 10
                    index += 1
                }
                guard index > start else { return nil }
            }
            guard index < count else { return nil }

            var offset = 0
            switch bytes[index] {
            case 90, 122:
                guard index + 1 == count else { return nil }
            case 43, 45:
                guard index + 6 == count, bytes[index + 3] == 58,
                      let hours = number(index + 1, 2), let minutes = number(index + 4, 2)
                else { return nil }
                offset = (hours * 3600 + minutes * 60) * (bytes[index] == 43 ? 1 : -1)
            default:
                return nil
            }

            // Days from 1970-01-01 in the proleptic Gregorian calendar.
            let shiftedYear = month <= 2 ? year - 1 : year
            let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
            let yearOfEra = shiftedYear - era * 400
            let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let days = era * 146_097 + dayOfEra - 719_468
            let seconds = days * 86_400 + hour * 3600 + minute * 60 + second - offset
            return Date(timeIntervalSince1970: Double(seconds) + fraction)
        }
    }
}

enum NanoStorage {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Nano", isDirectory: true)
    }

    /// Creates the directory on first use and returns it.
    static func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a file that only the user can read, for cached tokens.
    ///
    /// The file is created with mode 0600 and then renamed into place. Writing
    /// first and tightening the mode afterwards leaves it readable by other
    /// accounts for the moment in between.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

#if canImport(AppKit)
import AppKit

extension AgentProviderID {
    /// Bundled brand mark, or nil when we do not ship one for this provider.
    ///
    /// Resolved by filename (`agent-<rawValue>.png`), so adding a logo is a
    /// drop-in with no code change. Callers fall back to `symbol`.
    @MainActor
    var brandImage: NSImage? {
        AgentBrandIcons.image(named: "agent-\(rawValue)")
    }
}

extension AgentProviderID {
    /// Optical correction. Equal box sizes do not read as equal weight: the
    /// OpenAI mark is a thin outline that looks undersized, while Claude's
    /// solid asterisk fills its box and looks oversized next to it.
    var brandScale: CGFloat {
        switch self {
        case .codex, .openai: 1.2
        case .claude: 0.85
        default: 1
        }
    }
}

/// Loaded images are cached — session rows rebuild often and decoding a PNG on
/// every redraw is wasteful.
///
/// Main-actor isolated rather than a bare static: NSCache is not Sendable, and
/// every caller is a SwiftUI view already on the main actor.
@MainActor
enum AgentBrandIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(named name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}
#endif
