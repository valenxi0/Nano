import os
import Foundation
import SQLite3

// Durable local record of how many tokens the user has spent across agents.
//
// Transcripts are not a reliable long-term source — Codex rotates them and
// Claude Code keeps only a short window — so once a session's tokens are
// counted they are banked here and survive the log being pruned. Lifetime
// is every recovered session, not the date Nano was installed.

/// One (provider, day, model) delta produced by a scanner.
struct ScanDelta: Sendable {
    let provider: String
    let day: String
    let model: String
    let counts: NanoTokenCounts
}

struct ScanOutput: Sendable {
    var deltas: [ScanDelta] = []
    var modelCorrections: [ScanModelCorrection] = []
    var watermarks: [String: NanoScanWatermark] = [:]
    /// Codex only: last banked cumulative total per session file.
    var banked: [String: NanoTokenCounts] = [:]
    /// True for scanners that read their sources a bounded amount at a time and
    /// so can report how much history is still outstanding.
    var reportsBacklog = false
    /// Bytes of past sessions still unread after this pass.
    var backlogBytes: Int64 = 0
    /// Bytes read during this pass.
    var readBytes: Int64 = 0
}

/// Moves a previously banked dashboard event from a routing label to the
/// canonical model once the host can prove that event's conversation model.
struct ScanModelCorrection: Sendable {
    let provider: String
    let day: String
    let oldModel: String
    let newModel: String
    let counts: NanoTokenCounts
}

/// Progress through the one-time read of history a source has not seen yet.
///
/// Worth publishing rather than hiding behind a spinner: the first scan of a
/// large session archive takes minutes, and totals climb the whole time. An
/// indeterminate ring for that long reads as a hang.
struct NanoScanCatchUp: Equatable, Sendable {
    var remaining: Int64
    /// What was outstanding when the catch-up started, so progress has a
    /// denominator that does not move.
    var total: Int64

    var fraction: Double {
        guard total > 0 else { return 1 }
        return min(max(Double(total - remaining) / Double(total), 0), 1)
    }
}

/// One usage-bearing line from an append-only JSONL log.
struct ParsedUsageLine {
    /// Restatement dedup key, when the source has message ids.
    var id: String?
    var provider: String
    /// `yyyy-MM-dd` in the user's local time zone.
    var day: String
    var model: String
    var counts: NanoTokenCounts
}

@MainActor
final class TokenLedger: ObservableObject {
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: Double = 0
    /// Set while a source still has history it has never read. Nil the rest of
    /// the time, which is almost always.
    @Published private(set) var catchUp: NanoScanCatchUp?
    @Published private(set) var trackedSince: Date?
    @Published private(set) var lastScan: Date?
    @Published private(set) var rows: [String: NanoTokenRollup] = [:]

    private var watermarks: [String: NanoScanWatermark] = [:]
    private var banked: [String: NanoTokenCounts] = [:]
    private var storedFingerprint = ""
    private var queuedProviders: Set<AgentProviderID>?
    private let resolver: NanoPriceResolver

    init(resolver: NanoPriceResolver) {
        self.resolver = resolver
        load()
    }

    // MARK: - Totals

    func totals(for window: NanoTokenWindow) -> NanoTokenTotals {
        var totals = NanoTokenTotals()
        totals.trackedSince = trackedSince

        let cutoff = Self.cutoffDay(for: window)
        for row in rows.values {
            if let cutoff, row.day < cutoff { continue }
            totals.counts += row.counts
            totals.costNanos += row.costNanos
            if !row.priced {
                totals.unpricedModels.insert(row.model)
            }
        }

        // Incomplete while a catch-up pass still has unread history, or when
        // a model has no list price. Lifetime is recovered sessions, not
        // "since Nano was installed".
        totals.isComplete = totals.unpricedModels.isEmpty && catchUp == nil
        return totals
    }

    /// Per-provider split for the same window, newest-heaviest first.
    func breakdown(for window: NanoTokenWindow) -> [(provider: String, counts: NanoTokenCounts, costNanos: Int)] {
        let cutoff = Self.cutoffDay(for: window)
        var byProvider: [String: (NanoTokenCounts, Int)] = [:]
        for row in rows.values {
            if let cutoff, row.day < cutoff { continue }
            var entry = byProvider[row.provider] ?? (NanoTokenCounts(), 0)
            entry.0 += row.counts
            entry.1 += row.costNanos
            byProvider[row.provider] = entry
        }
        return byProvider
            .map { (provider: $0.key, counts: $0.value.0, costNanos: $0.value.1) }
            .sorted { $0.counts.total > $1.counts.total }
    }

    /// Per-model split for the usage detail page. A model stays visibly
    /// unpriced when any contributing day lacked a rate; `$0` would imply the
    /// work was free rather than that Nano could not estimate it.
    func modelBreakdown(for window: NanoTokenWindow) -> [NanoTokenModelTotal] {
        let cutoff = Self.cutoffDay(for: window)
        var models: [String: NanoTokenModelTotal] = [:]
        for row in rows.values {
            if let cutoff, row.day < cutoff { continue }
            let key = "\(row.provider)|\(row.model)"
            var total = models[key] ?? NanoTokenModelTotal(
                provider: row.provider,
                model: row.model,
                counts: NanoTokenCounts(),
                costNanos: 0,
                priced: true
            )
            total.counts += row.counts
            total.costNanos += row.costNanos
            total.priced = total.priced && row.priced
            models[key] = total
        }
        return models.values.sorted {
            if $0.costNanos != $1.costNanos { return $0.costNanos > $1.costNanos }
            return $0.counts.total > $1.counts.total
        }
    }

    /// Cost per calendar day for the last `days` days ending today, oldest
    /// first, with empty days as zero, for the usage bar chart.
    func dailyCost(days: Int) -> [(day: String, costNanos: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let keys = (0..<days).reversed().compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map(Self.dayString)
        }
        var totals = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        for row in rows.values where totals[row.day] != nil {
            totals[row.day, default: 0] += row.costNanos
        }
        return keys.map { (day: $0, costNanos: totals[$0] ?? 0) }
    }

    private static func cutoffDay(for window: NanoTokenWindow) -> String? {
        let calendar = Calendar.current
        let now = Date()
        let start: Date?
        switch window {
        case .today:
            start = calendar.startOfDay(for: now)
        case .week:
            start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month:
            start = calendar.dateInterval(of: .month, for: now)?.start
        case .lifetime:
            start = nil
        }
        return start.map(Self.dayString)
    }

    /// Calendar start of a `yyyy-MM-dd` row day in the user's time zone.
    nonisolated static func date(fromDay day: String) -> Date? {
        let bits = day.split(separator: "-")
        guard bits.count == 3,
              let year = Int(bits[0]),
              let month = Int(bits[1]),
              let day = Int(bits[2])
        else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }

    nonisolated static func dayString(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Scanning

    /// Keeps scanning until every incremental source has caught up, so
    /// Lifetime is recovered history rather than one 64 MB slice per launch.
    func scanToCompletion(providers: Set<AgentProviderID>) async {
        await scan(providers: providers)
        var previousRemaining: Int64?
        while let remaining = catchUp?.remaining, !isScanning {
            // A pass that left the backlog where it found it will not do
            // better on the next one; looping on it only repeats the pricing
            // refresh, the Cursor fetch and a ledger save with nothing gained.
            if remaining == previousRemaining { break }
            previousRemaining = remaining
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { break }
            await scan(providers: providers)
        }
    }

    /// Scans the sources behind the providers enabled in Settings. Disabled
    /// providers stop accruing; what they already banked stays counted.
    func scan(providers: Set<AgentProviderID>) async {
        guard !isScanning else {
            queuedProviders = providers
            return
        }
        isScanning = true
        scanProgress = 0
        defer {
            isScanning = false
            scanProgress = 1
        }

        await runScan(providers: providers)
        while let queued = queuedProviders {
            queuedProviders = nil
            await runScan(providers: queued)
        }
    }

    private func runScan(providers: Set<AgentProviderID>) async {

        // Catalog TTL is 24h. Refresh before pricing new deltas so a model
        // that landed this week is not left at $0 until someone restarts.
        await resolver.refreshPricing()

        let existingWatermarks = watermarks
        let existingBanked = banked

        var steps: [@Sendable () -> ScanOutput] = []
        if providers.contains(.codex) {
            let budgets = TokenScanners.codexBudgets(
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
            steps.append {
                TokenScanners.scanCodex(
                    watermarks: existingWatermarks,
                    budget: budgets.file,
                    passBudget: budgets.pass
                )
            }
        }
        if providers.contains(.claude) {
            steps.append { TokenScanners.scanClaude(watermarks: existingWatermarks) }
        }
        if providers.contains(.cursor) {
            steps.append { TokenScanners.scanCursor(watermarks: existingWatermarks) }
        }
        // opencode is a harness: usage through it belongs to whichever vendor
        // the row names, so it runs when any of its possible vendors is on.
        if providers.contains(.opencode) || providers.contains(.kimi) || providers.contains(.moonshot) {
            steps.append { TokenScanners.scanOpenCode(watermarks: existingWatermarks, banked: existingBanked) }
        }
        if providers.contains(.kimi) || providers.contains(.moonshot) {
            steps.append { TokenScanners.scanKimiCLI(watermarks: existingWatermarks) }
        }
        if providers.contains(.gemini) {
            steps.append { TokenScanners.scanGemini(watermarks: existingWatermarks, banked: existingBanked) }
        }
        if providers.contains(.pi) {
            steps.append { TokenScanners.scanPi(watermarks: existingWatermarks) }
        }
        if providers.contains(.grok) {
            steps.append { TokenScanners.scanGrokCLI(watermarks: existingWatermarks) }
        }
        if providers.contains(.devin) {
            steps.append {
                TokenScanners.scanDevin(watermarks: existingWatermarks, banked: existingBanked)
            }
        }
        if providers.contains(.cline) {
            steps.append {
                TokenScanners.scanCline(watermarks: existingWatermarks, banked: existingBanked)
            }
        }
        if providers.contains(.qwen) {
            steps.append {
                TokenScanners.scanQwen(watermarks: existingWatermarks, banked: existingBanked)
            }
        }
        if providers.contains(.kilo) {
            steps.append {
                TokenScanners.scanKilo(watermarks: existingWatermarks, banked: existingBanked)
            }
        }
        if providers.contains(.goose) {
            steps.append {
                TokenScanners.scanGoose(watermarks: existingWatermarks, banked: existingBanked)
            }
        }

        var completed = 0
        var lastCheckpoint = Date()
        for step in steps {
            let output = await Task.detached(priority: .utility, operation: step).value
            apply(output)
            completed += 1
            scanProgress = Double(completed) / Double(steps.count) * 0.9
            // Checkpoint per source. A first scan against a large backlog runs
            // for minutes; without this, quitting before it ends throws away
            // every watermark and the next launch starts from nothing again.
            // A caught-up scan finishes in well under this, and saves once
            // at the end.
            if Date().timeIntervalSince(lastCheckpoint) > 5 {
                save()
                lastCheckpoint = Date()
            }
            await Task.yield()
        }

        if providers.contains(.cursor) {
            await ingestCursorEvents()
        }

        // A pricing change must reprice history rather than serve stale costs.
        if storedFingerprint != resolver.pricingFingerprint {
            repriceAll()
            storedFingerprint = resolver.pricingFingerprint
        }

        syncTrackedSince()
        lastScan = Date()
        save()
    }

    /// Recent events incrementally, then any older dashboard history the
    /// first 14-day window never asked for. Dedup is by event id.
    private func ingestCursorEvents() async {
        let authoritativeModels = await Task.detached(priority: .utility) {
            AgentT3RuntimeIndex.index().modelsByProviderSessionID
        }.value
        let eventsMark = watermarks[TokenScanners.cursorEventsPath]
        let historyMark = watermarks[TokenScanners.cursorHistoryPath]
        let historyComplete = historyMark?.size == 1

        if !historyComplete {
            // The feed is newest-first. Walk backward from the oldest event
            // already pulled (or now) until a page run is not truncated.
            let until = historyMark.flatMap { $0.offset > 0 ? $0.offset : nil }
            let fetch = await CursorUsageAdapter.fetchTokenEvents(sinceMs: 0, untilMs: until)
            if !fetch.events.isEmpty {
                apply(TokenScanners.output(
                    fromCursorEvents: fetch.events,
                    banked: banked,
                    authoritativeModels: authoritativeModels
                ))
                CursorConversationModels.record(
                    fetch.events,
                    authoritativeModels: authoritativeModels
                )
            }
            if !fetch.failed {
                if fetch.truncated, let oldest = fetch.events.map(\.timestampMs).min() {
                    watermarks[TokenScanners.cursorHistoryPath] = NanoScanWatermark(
                        path: TokenScanners.cursorHistoryPath,
                        size: 0,
                        modified: 0,
                        offset: max(oldest - 1, 0)
                    )
                } else {
                    watermarks[TokenScanners.cursorHistoryPath] = NanoScanWatermark(
                        path: TokenScanners.cursorHistoryPath,
                        size: 1,
                        modified: 0,
                        offset: 0
                    )
                }
                save()
            }
        }

        // A routing-only event may be older than the normal one-hour overlap.
        // Revisit history only when a stored routing conversation has since
        // gained an exact T3 model. Recording the resolved model removes that
        // conversation from this candidate set, so this is a one-time repair.
        let repairCandidates = CursorConversationModels.routingConversationIDs()
            .intersection(authoritativeModels.keys)
        if historyComplete, !repairCandidates.isEmpty {
            let repair = await CursorUsageAdapter.fetchTokenEvents(sinceMs: 0)
            if !repair.failed, !repair.events.isEmpty {
                apply(TokenScanners.output(
                    fromCursorEvents: repair.events,
                    banked: banked,
                    authoritativeModels: authoritativeModels
                ))
                CursorConversationModels.record(
                    repair.events,
                    authoritativeModels: authoritativeModels
                )
                save()
            }
        }

        // Overlap an hour so a timestamp-exclusive feed cannot drop the
        // event that set the watermark.
        let since = eventsMark.flatMap { $0.offset > 0 ? max($0.offset - 3_600_000, 0) : nil }
        let recent = await CursorUsageAdapter.fetchTokenEvents(sinceMs: since)
        if !recent.failed, !recent.events.isEmpty {
            apply(TokenScanners.output(
                fromCursorEvents: recent.events,
                banked: banked,
                authoritativeModels: authoritativeModels
            ))
            CursorConversationModels.record(
                recent.events,
                authoritativeModels: authoritativeModels
            )
            save()
        }
    }

    /// Lifetime starts at the earliest recovered row, not at install.
    private func syncTrackedSince() {
        guard let earliest = rows.values.map(\.day).min(),
              let date = Self.date(fromDay: earliest)
        else { return }
        trackedSince = date
    }

    private func apply(_ output: ScanOutput) {
        for correction in output.modelCorrections {
            apply(correction)
        }
        for delta in output.deltas where delta.counts.total > 0 {
            let key = NanoTokenRollup.key(
                provider: delta.provider,
                day: delta.day,
                model: delta.model
            )
            var row = rows[key] ?? NanoTokenRollup(
                provider: delta.provider,
                day: delta.day,
                model: delta.model,
                counts: NanoTokenCounts(),
                costNanos: 0,
                priced: true
            )
            row.counts += delta.counts
            price(&row)
            rows[key] = row
        }
        watermarks.merge(output.watermarks) { _, new in new }
        banked.merge(output.banked) { _, new in new }

        guard output.reportsBacklog else { return }
        if output.backlogBytes > 0 {
            // The denominator is fixed at the first pass that saw a backlog, so
            // the figure only ever climbs.
            let total = catchUp?.total ?? (output.backlogBytes + output.readBytes)
            catchUp = NanoScanCatchUp(
                remaining: output.backlogBytes,
                total: max(total, output.backlogBytes)
            )
        } else {
            catchUp = nil
        }
    }

    private func apply(_ correction: ScanModelCorrection) {
        guard correction.oldModel != correction.newModel else { return }
        let oldKey = NanoTokenRollup.key(
            provider: correction.provider,
            day: correction.day,
            model: correction.oldModel
        )
        guard var oldRow = rows[oldKey], oldRow.counts.contains(correction.counts) else { return }

        oldRow.counts.subtract(correction.counts)
        if oldRow.counts.total == 0 {
            rows.removeValue(forKey: oldKey)
        } else {
            price(&oldRow)
            rows[oldKey] = oldRow
        }

        let newKey = NanoTokenRollup.key(
            provider: correction.provider,
            day: correction.day,
            model: correction.newModel
        )
        var newRow = rows[newKey] ?? NanoTokenRollup(
            provider: correction.provider,
            day: correction.day,
            model: correction.newModel,
            counts: NanoTokenCounts(),
            costNanos: 0,
            priced: true
        )
        newRow.counts += correction.counts
        price(&newRow)
        rows[newKey] = newRow
    }

    private func price(_ row: inout NanoTokenRollup) {
        if let nanos = resolver.costNanos(
            provider: row.provider,
            model: row.model,
            day: row.day,
            counts: row.counts
        ) {
            row.costNanos = nanos
            row.priced = true
        } else {
            row.costNanos = 0
            row.priced = false
        }
    }

    private func repriceAll() {
        for (key, var row) in rows {
            price(&row)
            rows[key] = row
        }
    }

    // MARK: - Persistence

    private struct LedgerFile: Codable, Sendable {
        // Version 2: the version 1 Claude scanner re-banked whole transcripts
        // on every change, so any ledger written by it is inflated beyond
        // repair and gets discarded on load.
        //
        // Version 3: the version 2 Codex scanner banked each rollout's final
        // running total, which on a forked or subagent session includes the
        // parent history it replayed. Those rows cannot be corrected in place
        // — the inflation is per file and unrecorded — so they are dropped and
        // rebuilt from the logs, which still hold every session.
        var version = 3
        var trackedSince: Date?
        var lastScan: Date?
        var pricingFingerprint = ""
        var rows: [NanoTokenRollup] = []
        var watermarks: [NanoScanWatermark] = []
        var banked: [String: NanoTokenCounts] = [:]
    }

    private static func fileURL() throws -> URL {
        try NanoStorage.directory("tokens").appendingPathComponent("ledger.json")
    }

    private func load() {
        guard let url = try? Self.fileURL() else { return }
        Self.removeStaleTemporaries(in: url.deletingLastPathComponent())
        guard let data = try? Data(contentsOf: url) else { return }
        guard let file = try? JSONDecoder().decode(LedgerFile.self, from: data) else {
            // Starting empty is survivable; the next save overwriting the only
            // copy of the history is not. Keep the unreadable file beside it.
            Self.preserveUnreadableLedger(at: url)
            return
        }
        guard file.version >= 3 else { return }

        trackedSince = file.trackedSince
        lastScan = file.lastScan
        storedFingerprint = file.pricingFingerprint
        banked = file.banked
        rows = Dictionary(
            uniqueKeysWithValues: file.rows.map {
                (NanoTokenRollup.key(provider: $0.provider, day: $0.day, model: $0.model), $0)
            }
        )
        watermarks = Dictionary(uniqueKeysWithValues: file.watermarks.map { ($0.path, $0) })
        // Install date is not Lifetime. Recompute from the oldest banked row
        // so a ledger written before this rule corrects itself on launch.
        let previous = trackedSince
        syncTrackedSince()
        if trackedSince != previous {
            save()
        }
    }

    /// Copies a ledger that would not decode to `ledger.json.bad-<day>`, once
    /// per day, so a repeat failure cannot pile up copies.
    private nonisolated static func preserveUnreadableLedger(at url: URL) {
        let copy = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).bad-\(dayString(Date()))")
        guard !FileManager.default.fileExists(atPath: copy.path) else { return }
        try? FileManager.default.copyItem(at: url, to: copy)
    }

    /// `write` removes its own temporary on failure, but a crash or a forced
    /// quit between the write and the swap leaves it behind for good.
    private nonisolated static func removeStaleTemporaries(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for name in names where name.hasPrefix("ledger-") && name.hasSuffix(".tmp") {
            let path = directory.appendingPathComponent(name).path
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
                as? Date,
                modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func save() {
        var file = LedgerFile()
        file.trackedSince = trackedSince
        file.lastScan = lastScan
        file.pricingFingerprint = storedFingerprint
        file.rows = Array(rows.values)
        file.watermarks = Array(watermarks.values)
        file.banked = banked

        guard let url = try? Self.fileURL() else { return }
        // Only the snapshot is taken here; encoding megabytes on the main
        // actor stalled the island. A scan saves several times, so saves in
        // the same second share one write of the newest snapshot.
        let snapshot = file
        let firstInWindow = Self.pendingSave.withLock { pending in
            defer { pending = (snapshot, url) }
            return pending == nil
        }
        guard firstInWindow else { return }
        Self.saveQueue.asyncAfter(deadline: .now() + 1, execute: Self.writePendingSave)
    }

    /// Writes a save that is still waiting, before the app quits.
    nonisolated static func flushPendingSave() {
        saveQueue.sync(execute: writePendingSave)
    }

    private nonisolated static func writePendingSave() {
        guard let (file, url) = pendingSave.withLock({ pending in
            defer { pending = nil }
            return pending
        }) else { return }
        write(file, to: url)
    }

    private nonisolated static let saveQueue = DispatchQueue(label: "com.nanoapp.token-ledger.save", qos: .utility)
    private nonisolated static let pendingSave = OSAllocatedUnfairLock<(LedgerFile, URL)?>(initialState: nil)

    private nonisolated static func write(_ file: LedgerFile, to url: URL) {
        guard let data = try? JSONEncoder().encode(file) else { return }

        // Write to a sibling then swap, so a crash mid-write cannot leave a
        // truncated ledger behind.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("ledger-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}

// MARK: - Scanners

enum TokenScanners {
    /// Cloud Cursor events, distinct from the on-disk JSONL walk.
    static let cursorEventsPath = "cursor://events"
    /// Set once the dashboard feed has been walked back to the oldest event
    /// it still has. `size == 1` means that backfill is finished.
    static let cursorHistoryPath = "cursor://events-history"

    /// Which scanners a Settings Tokens set actually runs. The test that
    /// walks `AgentProviderID.supported` uses this so a provider cannot ship
    /// with a toggle and no source.
    static func sources(for providers: Set<AgentProviderID>) -> Set<String> {
        var sources: Set<String> = []
        if providers.contains(.codex) { sources.insert("codex") }
        if providers.contains(.claude) { sources.insert("claude") }
        if providers.contains(.cursor) {
            sources.insert("cursor")
            sources.insert("cursor-events")
            sources.insert("cursor-history")
        }
        if providers.contains(.opencode) || providers.contains(.kimi) || providers.contains(.moonshot) {
            sources.insert("opencode")
        }
        if providers.contains(.kimi) || providers.contains(.moonshot) {
            sources.insert("kimi")
        }
        if providers.contains(.gemini) { sources.insert("gemini") }
        if providers.contains(.pi) { sources.insert("pi") }
        if providers.contains(.grok) { sources.insert("grok") }
        if providers.contains(.devin) { sources.insert("devin") }
        if providers.contains(.cline) { sources.insert("cline") }
        if providers.contains(.qwen) { sources.insert("qwen") }
        if providers.contains(.kilo) { sources.insert("kilo") }
        if providers.contains(.goose) { sources.insert("goose") }
        return sources
    }

    /// Banks Cursor dashboard events that the JSONL walker cannot see.
    /// Already-seen ids stay in `banked` so a rescan is a no-op.
    static func output(
        fromCursorEvents events: [CursorUsageAdapter.TokenEvent],
        banked: [String: NanoTokenCounts],
        authoritativeModels: [String: String] = [:]
    ) -> ScanOutput {
        var output = ScanOutput()
        var newest: Int64 = 0
        var ids: [String] = []

        for event in events {
            newest = max(newest, event.timestampMs)
            ids.append(event.id)
            let key = "cursor://event/\(event.id)"
            let model = CursorUsageAdapter.resolvedModel(
                reportedModel: event.model,
                conversationID: event.conversationID,
                authoritativeModels: authoritativeModels
            )
            if let previous = banked[key] {
                let correctionKey = "cursor://model-correction/\(event.id)|\(model)"
                if model != event.model,
                   previous == event.counts,
                   banked[correctionKey] == nil {
                    output.modelCorrections.append(ScanModelCorrection(
                        provider: AgentProviderID.cursor.rawValue,
                        day: TokenLedger.dayString(
                            Date(timeIntervalSince1970: TimeInterval(event.timestampMs) / 1000)
                        ),
                        oldModel: event.model,
                        newModel: model,
                        counts: previous
                    ))
                    output.banked[correctionKey] = previous
                }
                continue
            }
            output.banked[key] = event.counts
            output.deltas.append(ScanDelta(
                provider: AgentProviderID.cursor.rawValue,
                day: TokenLedger.dayString(
                    Date(timeIntervalSince1970: TimeInterval(event.timestampMs) / 1000)
                ),
                model: model,
                counts: event.counts
            ))
        }

        if newest > 0 {
            output.watermarks[cursorEventsPath] = NanoScanWatermark(
                path: cursorEventsPath,
                size: 0,
                modified: 0,
                offset: newest,
                recentIDs: Array(ids.suffix(500))
            )
        }
        return output
    }

    // MARK: Codex

    /// Longest pause tolerated inside a burst of replayed usage.
    ///
    /// A forked or subagent rollout opens with its parent's history copied in,
    /// every line re-stamped to the fork instant, and Codex writes that copy in
    /// one go. The burst is therefore dense, while the child's own first turn
    /// only lands after a real model call. A second sits far above the gaps
    /// inside a burst and far below the pause that follows it.
    static let replayBurstGap: Double = 1_000

    /// Sums each turn's own usage, skipping history a fork replayed from its
    /// parent.
    ///
    /// Codex reports two figures per turn: `total_token_usage`, a running total
    /// for the session, and `last_token_usage`, the turn itself. Reading the
    /// final running total looks like the cheap way to price a session and is
    /// what this did — but a fork replays its parent's usage events into its own
    /// log, so those totals count work that another session already paid for.
    /// On this machine 203 of 369 recent rollouts were forks or subagents, and
    /// trusting their totals inflated Codex by more than eight times.
    ///
    /// Summing per-turn deltas instead reconciles with the running total on any
    /// session that is not a fork, which `testCodexPerTurnDeltasReconcile`
    /// pins down.
    static func scanCodex(
        watermarks: [String: NanoScanWatermark],
        roots: [URL]? = nil,
        budget: Int64 = codexScanBudget,
        passBudget: Int64 = codexPassBudget
    ) -> ScanOutput {
        var output = ScanOutput()
        output.reportsBacklog = true
        var read: Int64 = 0

        // Archiving moves a rollout from `sessions/<date>/` to
        // `archived_sessions/`. Its name carries the session id, so the moved
        // file resumes from the mark it already earned instead of recounting.
        var marksByName: [String: NanoScanWatermark] = [:]
        for (path, mark) in watermarks {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if name.hasPrefix("rollout-") { marksByName[name] = mark }
        }

        for root in roots ?? codexRoots() {
            for file in jsonlFiles(under: root) {
                guard let attributes = try? FileManager.default
                    .attributesOfItem(atPath: file.path),
                    let size = attributes[.size] as? Int64,
                    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
                else { continue }

                let key = file.path
                let mark = watermarks[key] ?? marksByName[file.lastPathComponent]
                if let mark, mark.size == size, mark.modified == modified { continue }

                // Same rule as the Claude scanner: read only what was appended
                // since the last scan, and start over on a file that shrank.
                let resumeAt = (mark?.size ?? 0) <= size ? (mark?.offset ?? 0) : 0

                // Out of budget for this pass. Counting what is left is a stat
                // that already happened, so the remaining work stays visible
                // without reading any of it.
                if read >= passBudget {
                    output.backlogBytes += max(size - resumeAt, 0)
                    continue
                }

                var state = resumeAt == 0
                    ? codexOpeningState(of: file)
                    : (mark?.codex ?? NanoCodexScanState())

                var byDayModel: [String: NanoTokenCounts] = [:]
                let endOffset = streamCodexLines(of: file, from: resumeAt, budget: budget) { line in
                    consumeCodexLine(line, state: &state, into: &byDayModel, fallbackDay: modified)
                }
                read += max(endOffset - resumeAt, 0)
                // A file the per-file budget cut short is still outstanding.
                // A read that stopped short of the budget reached the end of
                // the file, so what is left is an unterminated last line: it
                // cannot be consumed until the writer finishes it, and
                // counting it as backlog would keep the catch-up loop alive.
                if endOffset - resumeAt >= budget {
                    output.backlogBytes += max(size - endOffset, 0)
                }

                // The consumed offset stands in for the size, so a file left
                // part-read on this pass is picked up again on the next one
                // rather than looking finished. They match once it is caught up.
                output.watermarks[key] = NanoScanWatermark(
                    path: key,
                    size: endOffset,
                    modified: modified,
                    offset: endOffset,
                    codex: state
                )

                for (composite, counts) in byDayModel {
                    let parts = composite.split(separator: "|", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    output.deltas.append(ScanDelta(
                        provider: AgentProviderID.codex.rawValue,
                        day: String(parts[0]),
                        model: String(parts[1]),
                        counts: counts
                    ))
                }
            }
        }

        output.readBytes = read
        return output
    }

    /// How much of one rollout a single scan will read.
    ///
    /// Rollouts here reach 7GB. The Claude reader answers a file bigger than its
    /// window by jumping to the last bytes, which is right for "what is it doing
    /// now" and wrong for a ledger — the skipped span is never counted. This
    /// reads forward instead and stops at the budget, so a backlog is consumed
    /// over several scans and nothing is dropped.
    private static let codexScanBudget: Int64 = 32_000_000

    /// How much of the whole Codex backlog one scan will read.
    ///
    /// There are 21GB of rollouts on this machine. Reading them in one pass
    /// pins a core for minutes and banks nothing until it finishes; stopping at
    /// a ceiling lets each pass checkpoint its watermarks, and the passes that
    /// follow — on launch, on a finished turn, on opening the module — carry on
    /// where it left off.
    private static let codexPassBudget: Int64 = 64_000_000

    /// Catch-up is optional background work, so Low Power Mode gets a much
    /// smaller slice. Both figures remain well above a normal live append and
    /// the watermark makes every later pass resume without dropping history.
    nonisolated static func codexBudgets(lowPower: Bool) -> (file: Int64, pass: Int64) {
        lowPower ? (8_000_000, 16_000_000) : (codexScanBudget, codexPassBudget)
    }

    /// Streams complete lines from `offset`, returning where to resume.
    ///
    /// Deliberately not `String(contentsOf:)`: these files are far larger than
    /// anything worth holding in memory at once.
    private static func streamCodexLines(
        of url: URL,
        from offset: Int64,
        budget: Int64 = codexScanBudget,
        consume: (Substring) -> Void
    ) -> Int64 {
        guard let handle = try? FileHandle(forReadingFrom: url),
              (try? handle.seek(toOffset: UInt64(max(offset, 0)))) != nil
        else { return offset }
        defer { try? handle.close() }

        var consumed: Int64 = 0
        var carry = Data()

        while consumed < budget {
            guard let block = try? handle.read(upToCount: 4_000_000), !block.isEmpty else { break }
            carry.append(block)

            // Whole lines only: a block boundary lands mid-record, and the tail
            // of a live file is a half-written line.
            guard let lastBreak = carry.lastIndex(of: UInt8(ascii: "\n")) else {
                // Records here reach tens of megabytes on a single line, so a
                // block with no break in it is normal. Past this the line is
                // not one Nano can use and holding it only costs memory.
                if carry.count > 64_000_000 {
                    consumed += Int64(carry.count)
                    carry.removeAll(keepingCapacity: false)
                }
                continue
            }
            let complete = carry[..<lastBreak]
            carry = Data(carry[carry.index(after: lastBreak)...])

            if let text = String(data: complete, encoding: .utf8) {
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    consume(line)
                }
            }
            consumed += Int64(complete.count) + 1
        }
        return offset + consumed
    }

    /// Reads the head of a rollout for the two things stated only at the top:
    /// whether it is a fork, and the model it opened with.
    ///
    /// Cheap on purpose. `boundedText` skips ahead on a file larger than its
    /// window, so on a multi-gigabyte rollout the chunk the scanner reads may
    /// begin well past these records.
    private static func codexOpeningState(of url: URL, limit: Int = 256_000) -> NanoCodexScanState {
        var state = NanoCodexScanState()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return state }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit),
              let text = String(data: data, encoding: .utf8)
        else { return state }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("session_meta") || line.contains("turn_context"),
                  let object = json(from: line)
            else { continue }
            let payload = (object["payload"] as? [String: Any]) ?? [:]

            if object["type"] as? String == "session_meta" {
                if isForkedCodexSession(payload) {
                    state.isReplayingParent = true
                    state.replayAnchorMs = milliseconds(fromISO: object["timestamp"] as? String) ?? 0
                }
                continue
            }
            if let model = payload["model"] as? String, !model.isEmpty {
                state.model = model
                break
            }
        }
        return state
    }

    /// Whether a `session_meta` payload marks the rollout as a fork or subagent.
    private static func isForkedCodexSession(_ payload: [String: Any]) -> Bool {
        if payload["forked_from_id"] is String { return true }
        guard let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              let spawn = subagent["thread_spawn"] as? [String: Any]
        else { return false }
        return spawn["parent_thread_id"] is String
    }

    private static func consumeCodexLine(
        _ line: Substring,
        state: inout NanoCodexScanState,
        into byDayModel: inout [String: NanoTokenCounts],
        fallbackDay modified: TimeInterval
    ) {
        // Rollouts are mostly message content; only three record types matter,
        // so the expensive parse is gated on a substring test.
        guard line.contains("token_count")
            || line.contains("turn_context")
            || line.contains("session_meta")
        else { return }
        guard let object = json(from: line) else { return }
        let payload = (object["payload"] as? [String: Any]) ?? [:]

        switch object["type"] as? String {
        case "session_meta":
            if isForkedCodexSession(payload) {
                state.isReplayingParent = true
                state.replayAnchorMs = milliseconds(fromISO: object["timestamp"] as? String) ?? 0
            }
            return
        case "turn_context":
            if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
            return
        default:
            break
        }

        guard (payload["type"] as? String) == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["last_token_usage"] as? [String: Any]
        else { return }

        let input = int(usage["input_tokens"])
        let cached = int(usage["cached_input_tokens"])
        let written = int(usage["cache_write_input_tokens"])
        let produced = int(usage["output_tokens"])

        // Codex restates the same usage event when a turn ends without moving
        // the counters; counting those would multiply a quiet session.
        let signature = "\(input):\(cached):\(written):\(produced)"
        if signature == state.lastUsage { return }
        state.lastUsage = signature

        let at = milliseconds(fromISO: object["timestamp"] as? String)
        if state.isReplayingParent {
            guard let at else { return }
            if at - state.replayAnchorMs < replayBurstGap {
                state.replayAnchorMs = at
                return
            }
            state.isReplayingParent = false
        }

        let counts = NanoTokenCounts(
            // Codex folds cached and newly written tokens into its input count.
            freshInput: max(input - cached - written, 0),
            cacheRead: cached,
            cacheWrite5m: written,
            output: produced,
            reasoning: min(int(usage["reasoning_output_tokens"]), produced)
        )
        guard counts.total > 0 else { return }

        // Attributed to the day the turn ran, not the day the file was last
        // touched: a session left open overnight belongs to both days.
        let day = (object["timestamp"] as? String).flatMap(day(fromISO:))
            ?? TokenLedger.dayString(Date(timeIntervalSince1970: modified))
        byDayModel["\(day)|\(state.model ?? "unknown")", default: NanoTokenCounts()] += counts
    }

    private static func codexRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return [
            base.appendingPathComponent("sessions", isDirectory: true),
            base.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    // MARK: Claude

    /// Claude reports cache tokens separately from `input_tokens`, the opposite
    /// of Codex, and repeats messages across resumes and sidechains.
    static func scanClaude(
        watermarks: [String: NanoScanWatermark],
        roots: [URL]? = nil,
        readLimit: Int64 = 64_000_000
    ) -> ScanOutput {
        scanAnthropicStyleTranscripts(
            provider: .claude,
            watermarks: watermarks,
            roots: roots ?? claudeRoots(),
            readLimit: readLimit
        )
    }

    /// Cursor agent transcripts use the same `message.usage` shape as Claude
    /// when the CLI writes it. Most editor sessions do not; those come from
    /// `output(fromCursorEvents:banked:)` instead. This walk stays so a
    /// future CLI transcript with usage is not ignored.
    static func scanCursor(
        watermarks: [String: NanoScanWatermark],
        roots: [URL]? = nil,
        readLimit: Int64 = 64_000_000
    ) -> ScanOutput {
        scanAnthropicStyleTranscripts(
            provider: .cursor,
            watermarks: watermarks,
            roots: roots ?? cursorRoots(),
            readLimit: readLimit
        )
    }

    private static func scanAnthropicStyleTranscripts(
        provider: AgentProviderID,
        watermarks: [String: NanoScanWatermark],
        roots: [URL],
        readLimit: Int64 = 64_000_000
    ) -> ScanOutput {
        var output = ScanOutput()

        for root in roots {
            for file in jsonlFiles(under: root) {
                guard let attributes = try? FileManager.default
                    .attributesOfItem(atPath: file.path),
                    let size = attributes[.size] as? Int64,
                    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
                else { continue }

                let key = file.path
                let mark = watermarks[key]
                if let mark, mark.size == size, mark.modified == modified { continue }

                // A file that shrank was rotated; read it from the start again.
                // Otherwise read only the bytes appended since the last scan —
                // re-reading the whole file would re-bank every message in it,
                // and transcripts are appended to on every turn.
                let resumeAt = (mark?.size ?? 0) <= size ? (mark?.offset ?? 0) : 0
                guard let chunk = boundedText(
                    of: file, size: size, from: resumeAt, limit: readLimit
                ) else { continue }

                // Restated messages are deduped within the chunk, and the
                // watermark carries the tail of the previous chunk's ids so a
                // restatement that straddles a scan boundary is caught too.
                var seen: Set<String> = mark?.recentIDs.map(Set.init) ?? []
                var chunkIDs: [String] = []
                var byDayModel: [String: NanoTokenCounts] = [:]

                for line in chunk.text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard line.contains("\"usage\"") else { continue }
                    guard let object = json(from: line),
                          let message = object["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any]
                    else { continue }

                    if let id = message["id"] as? String {
                        if seen.contains(id) { continue }
                        seen.insert(id)
                        chunkIDs.append(id)
                    }

                    let model = (message["model"] as? String) ?? "unknown"
                    if model == "<synthetic>" { continue }

                    let breakdown = message["cache_creation"] as? [String: Any]
                        ?? usage["cache_creation"] as? [String: Any]
                    let creation = breakdown ?? [:]
                    // Without the per-TTL breakdown only the flat total is
                    // stated. It is banked at the default 5 minute tier rather
                    // than dropped.
                    let flatCacheWrite = breakdown == nil
                        ? int(usage["cache_creation_input_tokens"])
                        : 0

                    // `iterations` restates the same message per attempt and is
                    // deliberately not summed.
                    let counts = NanoTokenCounts(
                        freshInput: int(usage["input_tokens"]),
                        cacheRead: int(usage["cache_read_input_tokens"]),
                        cacheWrite5m: int(creation["ephemeral_5m_input_tokens"]) + flatCacheWrite,
                        cacheWrite1h: int(creation["ephemeral_1h_input_tokens"]),
                        output: int(usage["output_tokens"])
                    )

                    let day = (object["timestamp"] as? String).flatMap(day(fromISO:))
                        ?? TokenLedger.dayString(Date(timeIntervalSince1970: modified))
                    byDayModel["\(day)|\(model)", default: NanoTokenCounts()] += counts
                }

                output.watermarks[key] = NanoScanWatermark(
                    path: key,
                    size: chunk.endOffset,
                    modified: modified,
                    offset: chunk.endOffset,
                    recentIDs: Array(((mark?.recentIDs ?? []) + chunkIDs).suffix(500))
                )

                for (composite, counts) in byDayModel {
                    let parts = composite.split(separator: "|", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    output.deltas.append(ScanDelta(
                        provider: provider.rawValue,
                        day: String(parts[0]),
                        model: String(parts[1]),
                        counts: counts
                    ))
                }
            }
        }

        return output
    }

    private static func cursorRoots() -> [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cursor/projects", isDirectory: true)
        ]
    }

    private static func claudeRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [URL] = []

        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            for part in configured.split(separator: ",") {
                let trimmed = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let url = URL(fileURLWithPath: trimmed, isDirectory: true)
                roots.append(
                    url.lastPathComponent == "projects"
                        ? url
                        : url.appendingPathComponent("projects", isDirectory: true)
                )
            }
        } else {
            roots.append(home.appendingPathComponent(".config/claude/projects", isDirectory: true))
            roots.append(home.appendingPathComponent(".claude/projects", isDirectory: true))
        }

        var seen: Set<String> = []
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // MARK: OpenCode

    /// opencode stores one row per step in a SQLite database, with token
    /// counts that fill in as the step streams, so rows are re-queried by
    /// their update time and banked per message id — the Codex trick at row
    /// granularity. The ledger provider is the row's own `providerID`
    /// (e.g. `kimi-for-coding`): opencode is the harness, not the vendor.
    static func scanOpenCode(
        watermarks: [String: NanoScanWatermark],
        banked: [String: NanoTokenCounts],
        databaseURL: URL? = nil,
        /// Watermark key when the caller wants something other than the file
        /// path — e.g. a fork scanning its own database file.
        sourceKey: String? = nil,
        /// Fixed ledger provider for OpenCode forks like Kilo, where rows
        /// belong to the harness regardless of the vendor `providerID`.
        providerOverride: AgentProviderID? = nil
    ) -> ScanOutput {
        var output = ScanOutput()
        guard let dbPath = databaseURL ?? openCodeDatabaseURL() else { return output }

        let key = sourceKey ?? dbPath.path
        let bankPrefix = providerOverride?.rawValue ?? AgentProviderID.opencode.rawValue
        var latestUpdate = watermarks[key]?.offset ?? 0

        var db: OpaquePointer?
        guard sqlite3_open_v2(key, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { return output }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT id, time_created, time_updated, data
        FROM message
        WHERE time_updated > ?
        ORDER BY time_updated ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return output }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, latestUpdate)

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let dataText = sqlite3_column_text(statement, 3)
            else { continue }
            let id = String(cString: idText)
            let createdMs = sqlite3_column_int64(statement, 1)
            let updatedMs = sqlite3_column_int64(statement, 2)
            latestUpdate = max(latestUpdate, updatedMs)

            guard let object = (try? JSONSerialization.jsonObject(
                with: Data(String(cString: dataText).utf8)
            )) as? [String: Any],
                object["role"] as? String == "assistant",
                let tokens = object["tokens"] as? [String: Any]
            else { continue }

            let cache = tokens["cache"] as? [String: Any]
            let counts = NanoTokenCounts(
                freshInput: int(tokens["input"]),
                cacheRead: int(cache?["read"]),
                // opencode reports a single cache-write figure with no TTL split.
                cacheWrite5m: int(cache?["write"]),
                output: int(tokens["output"]),
                reasoning: int(tokens["reasoning"])
            )

            let bankKey = "\(bankPrefix)://" + id
            let previous = banked[bankKey] ?? NanoTokenCounts()
            let delta = NanoTokenCounts(
                freshInput: max(counts.freshInput - previous.freshInput, 0),
                cacheRead: max(counts.cacheRead - previous.cacheRead, 0),
                cacheWrite5m: max(counts.cacheWrite5m - previous.cacheWrite5m, 0),
                output: max(counts.output - previous.output, 0),
                reasoning: max(counts.reasoning - previous.reasoning, 0)
            )
            output.banked[bankKey] = counts

            guard delta.total > 0 else { continue }
            output.deltas.append(ScanDelta(
                provider: providerOverride?.rawValue
                    ?? AgentProviderID.normalize(object["providerID"] as? String)
                    ?? AgentProviderID.opencode.rawValue,
                day: TokenLedger.dayString(
                    Date(timeIntervalSince1970: TimeInterval(createdMs) / 1000)
                ),
                model: (object["modelID"] as? String) ?? "unknown",
                counts: delta
            ))
        }

        output.watermarks[key] = NanoScanWatermark(
            path: key,
            size: 0,
            modified: 0,
            offset: latestUpdate
        )
        return output
    }

    private static func openCodeDatabaseURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = ProcessInfo.processInfo.environment["OPENCODE_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        let url = base.appendingPathComponent("opencode.db")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Pi

    /// pi-mono session logs: one JSONL record per message, assistant records
    /// carry `usage { input, output, cacheRead, cacheWrite }`. Messages are
    /// written once with final counts, so no id dedup is needed.
    static func scanPi(
        watermarks: [String: NanoScanWatermark],
        roots: [URL]? = nil
    ) -> ScanOutput {
        let files = (roots ?? piRoots()).flatMap { jsonlFiles(under: $0) }
        return scanJsonlAppends(files: files, watermarks: watermarks) { _, line in
            guard line.contains("\"usage\""),
                  let object = json(from: line),
                  let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant",
                  let usage = message["usage"] as? [String: Any]
            else { return nil }

            let counts = NanoTokenCounts(
                freshInput: int(usage["input"]),
                cacheRead: int(usage["cacheRead"]),
                cacheWrite5m: int(usage["cacheWrite"]),
                output: int(usage["output"])
            )
            guard counts.total > 0 else { return nil }
            return ParsedUsageLine(
                id: nil,
                provider: AgentProviderID.pi.rawValue,
                day: (object["timestamp"] as? String).flatMap(day(fromISO:))
                    ?? TokenLedger.dayString(Date()),
                model: (message["model"] as? String) ?? "unknown",
                counts: counts
            )
        }
    }

    private static func piRoots() -> [URL] {
        if let configured = ProcessInfo.processInfo.environment["PI_AGENT_DIR"] {
            let roots = configured.split(separator: ",").map {
                URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
            }
            if !roots.isEmpty { return roots }
        }
        return [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)]
    }

    // MARK: Kimi CLI

    /// Kimi CLI keeps one `wire.jsonl` per session under `<root>/sessions`.
    /// Two record formats exist: the old `StatusUpdate` token_usage payload
    /// (per message, with an id) and the new `usage.record` lines, where only
    /// `turn` scope is per-use — session scope is a cumulative restatement.
    static func scanKimiCLI(
        watermarks: [String: NanoScanWatermark],
        roots: [URL]? = nil
    ) -> ScanOutput {
        let rootList = roots ?? kimiRoots()
        let files = rootList.flatMap { root in
            jsonlFiles(under: root.appendingPathComponent("sessions", isDirectory: true))
                .filter { $0.lastPathComponent == "wire.jsonl" }
        }
        return scanJsonlAppends(files: files, watermarks: watermarks) { file, line in
            guard line.contains("token_usage") || line.contains("usage.record"),
                  let object = json(from: line)
            else { return nil }

            if object["type"] as? String == "usage.record" {
                guard object["usageScope"] as? String == "turn",
                      let usage = object["usage"] as? [String: Any]
                else { return nil }
                let counts = NanoTokenCounts(
                    freshInput: int(usage["inputOther"]),
                    cacheRead: int(usage["inputCacheRead"]),
                    cacheWrite5m: int(usage["inputCacheCreation"]),
                    output: int(usage["output"])
                )
                guard counts.total > 0 else { return nil }
                var model = (object["model"] as? String) ?? "kimi-for-coding"
                if model.hasPrefix("kimi-code/") {
                    model = String(model.dropFirst("kimi-code/".count))
                }
                let ms = int64(object["time"])
                return ParsedUsageLine(
                    id: nil,
                    provider: AgentProviderID.kimi.rawValue,
                    day: ms > 0
                        ? TokenLedger.dayString(Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
                        : TokenLedger.dayString(Date()),
                    model: model,
                    counts: counts
                )
            }

            guard let message = object["message"] as? [String: Any],
                  message["type"] as? String == "StatusUpdate",
                  let payload = message["payload"] as? [String: Any],
                  let usage = payload["token_usage"] as? [String: Any]
            else { return nil }
            let counts = NanoTokenCounts(
                freshInput: int(usage["input_other"]),
                cacheRead: int(usage["input_cache_read"]),
                cacheWrite5m: int(usage["input_cache_creation"]),
                output: int(usage["output"])
            )
            guard counts.total > 0 else { return nil }
            let seconds = double(object["timestamp"])
            return ParsedUsageLine(
                id: payload["message_id"] as? String,
                provider: AgentProviderID.kimi.rawValue,
                day: seconds > 0
                    ? TokenLedger.dayString(Date(timeIntervalSince1970: seconds))
                    : TokenLedger.dayString(Date()),
                // The old format never names the model; the CLI's configured
                // model from `<root>/config.json` stands in for it.
                model: kimiConfigModel(forWireFile: file),
                counts: counts
            )
        }
    }

    private static func kimiRoots() -> [URL] {
        if let configured = ProcessInfo.processInfo.environment["KIMI_DATA_DIR"] {
            let roots = configured.split(separator: ",").map {
                URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
            }
            if !roots.isEmpty { return roots }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".kimi", ".kimi-code"].map {
            home.appendingPathComponent($0, isDirectory: true)
        }
    }

    private static func kimiConfigModel(forWireFile file: URL) -> String {
        // Layout-independent: the data root is whatever directory holds the
        // "sessions" subtree this wire file sits under. Prefix-matching the
        // configured roots breaks when one side resolves /var symlinks and
        // the other does not.
        var directory = file.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.lastPathComponent == "sessions" {
                let root = directory.deletingLastPathComponent()
                guard let data = try? Data(contentsOf: root.appendingPathComponent("config.json")),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let model = object["model"] as? String, !model.isEmpty
                else { break }
                return model
            }
            directory = directory.deletingLastPathComponent()
        }
        return "kimi-for-coding"
    }

    // MARK: Gemini CLI

    /// Gemini CLI chat files are whole JSON documents rewritten as the session
    /// grows, so they are banked like Codex cumulative events: recompute the
    /// document's totals and apply only the growth. `.jsonl` siblings are
    /// append-only and scan incrementally.
    static func scanGemini(
        watermarks: [String: NanoScanWatermark],
        banked: [String: NanoTokenCounts],
        roots: [URL]? = nil
    ) -> ScanOutput {
        var output = ScanOutput()
        let rootList = roots ?? geminiRoots()

        for root in rootList {
            for file in files(under: root, extension: "json") {
                guard let attributes = try? FileManager.default
                    .attributesOfItem(atPath: file.path),
                    let size = attributes[.size] as? Int64,
                    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
                else { continue }

                let key = file.path
                let mark = watermarks[key]
                if let mark, mark.size == size, mark.modified == modified { continue }
                guard let data = try? Data(contentsOf: file),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                // Bank per message id rather than per file: Gemini rewrites
                // the whole document as the session grows and drops messages
                // when it compacts, so file-level totals are unreliable. An
                // id already banked stays banked even if compaction removes
                // the message, and a restated id applies only its growth.
                let fallbackDay = TokenLedger.dayString(Date(timeIntervalSince1970: modified))
                var eventsByKey: [String: (day: String, model: String, counts: NanoTokenCounts)] = [:]
                for event in geminiDocumentEvents(object, fallbackDay: fallbackDay) {
                    // Id-less messages have no dedup key of their own, so they
                    // pool into one cumulative bucket per (day, model) — the
                    // bucket only grows as the document does.
                    let bankKey = "gemini://\(key)#\(event.id ?? "idless|\(event.day)|\(event.model)")"
                    var entry = eventsByKey[bankKey] ?? (event.day, event.model, NanoTokenCounts())
                    entry.counts += event.counts
                    eventsByKey[bankKey] = entry
                }

                for (bankKey, event) in eventsByKey {
                    let previous = banked[bankKey] ?? NanoTokenCounts()
                    let delta = countsMinus(event.counts, previous)
                    output.banked[bankKey] = event.counts

                    guard delta.total > 0 else { continue }
                    output.deltas.append(ScanDelta(
                        provider: AgentProviderID.gemini.rawValue,
                        day: event.day,
                        model: event.model,
                        counts: delta
                    ))
                }

                output.watermarks[key] = NanoScanWatermark(
                    path: key,
                    size: size,
                    modified: modified,
                    offset: size
                )
            }
        }

        let appends = scanJsonlAppends(
            files: rootList.flatMap { files(under: $0, extension: "jsonl") },
            watermarks: watermarks
        ) { _, line in
            guard line.contains("\"gemini\""),
                  let object = json(from: line),
                  object["type"] as? String == "gemini"
            else { return nil }
            return geminiDirectEvent(object, fallbackDay: TokenLedger.dayString(Date()))
        }
        output.deltas += appends.deltas
        output.watermarks.merge(appends.watermarks) { _, new in new }
        return output
    }

    private static func geminiRoots() -> [URL] {
        if let configured = ProcessInfo.processInfo.environment["GEMINI_DATA_DIR"] {
            let roots = configured.split(separator: ",").map {
                URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
            }
            if !roots.isEmpty { return roots }
        }
        return [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp", isDirectory: true)]
    }

    /// Usage events for a whole-document chat file. Restated message ids keep
    /// only their latest values; stats-only documents get a synthetic id per
    /// model so their cumulative growth banks like any other message.
    private static func geminiDocumentEvents(
        _ object: [String: Any],
        fallbackDay: String
    ) -> [ParsedUsageLine] {
        var byID: [String: ParsedUsageLine] = [:]
        var idless: [ParsedUsageLine] = []

        if let messages = object["messages"] as? [[String: Any]] {
            for message in messages where message["type"] as? String == "gemini" {
                guard let parsed = geminiDirectEvent(message, fallbackDay: fallbackDay) else { continue }
                if let id = parsed.id {
                    byID[id] = parsed
                } else {
                    idless.append(parsed)
                }
            }
        }

        if !byID.isEmpty || !idless.isEmpty {
            // Id-less messages cannot be deduped across scans, so a document
            // mixes them in only until every message carries an id.
            return idless + byID.values
        }

        // Session-stats documents: per-model token blocks, or one block for the
        // document's own model. Stats inputs always include the cached share.
        let stats = (object["stats"] ?? (object["result"] as? [String: Any])?["stats"])
            as? [String: Any]
        let day = (object["startTime"] as? String).flatMap(day(fromISO:))
            ?? (object["lastUpdated"] as? String).flatMap(day(fromISO:))
            ?? fallbackDay
        var events: [ParsedUsageLine] = []
        if let models = stats?["models"] as? [String: [String: Any]] {
            for (model, data) in models {
                guard let counts = geminiStatsCounts(data["tokens"] as? [String: Any]) else { continue }
                events.append(ParsedUsageLine(
                    id: "stats|\(model)", provider: AgentProviderID.gemini.rawValue,
                    day: day, model: model, counts: counts
                ))
            }
        } else if let counts = geminiStatsCounts(stats) {
            let model = (object["model"] as? String) ?? "unknown"
            events.append(ParsedUsageLine(
                id: "stats|\(model)", provider: AgentProviderID.gemini.rawValue,
                day: day, model: model, counts: counts
            ))
        }
        return events
    }

    /// One `type: "gemini"` record, from a chat document's message or a JSONL
    /// line. Token keys vary by CLI version, hence the alias lists.
    private static func geminiDirectEvent(
        _ record: [String: Any],
        fallbackDay: String
    ) -> ParsedUsageLine? {
        guard let tokens = record["tokens"] as? [String: Any] else { return nil }
        let input = firstInt(tokens, ["input", "prompt", "input_tokens", "prompt_tokens"])
        let output = firstInt(tokens, ["output", "candidates", "output_tokens", "candidates_tokens"])
        let cached = firstInt(tokens, ["cached", "cached_tokens"])
        let thoughts = firstInt(tokens, ["thoughts", "reasoning", "thoughts_tokens", "reasoning_tokens"])
        let tool = firstInt(tokens, ["tool", "tool_tokens"])
        let total = firstOptionalInt(tokens, ["total", "total_tokens"])

        // When the reported total equals input+output+thoughts+tool, the input
        // figure still contains the cached share and it must come out.
        var fresh = input
        if cached > 0, let total,
           total == input + output + thoughts + tool,
           total != input + output + thoughts + tool + cached {
            fresh = input - min(input, cached)
        }

        let counts = NanoTokenCounts(
            freshInput: fresh + tool,
            cacheRead: cached,
            output: output,
            reasoning: thoughts
        )
        guard counts.total > 0 else { return nil }
        return ParsedUsageLine(
            id: record["id"] as? String,
            provider: AgentProviderID.gemini.rawValue,
            day: (record["timestamp"] as? String).flatMap(day(fromISO:))
                ?? (record["created_at"] as? String).flatMap(day(fromISO:))
                ?? fallbackDay,
            model: (record["model"] as? String) ?? "unknown",
            counts: counts
        )
    }

    /// Stats blocks report input with the cached share folded in, always.
    private static func geminiStatsCounts(_ tokens: [String: Any]?) -> NanoTokenCounts? {
        guard let tokens else { return nil }
        let input = firstInt(tokens, ["input", "prompt", "input_tokens", "prompt_tokens"])
        let output = firstInt(tokens, ["output", "candidates", "output_tokens", "candidates_tokens"])
        let cached = firstInt(tokens, ["cached", "cached_tokens"])
        let thoughts = firstInt(tokens, ["thoughts", "reasoning", "thoughts_tokens", "reasoning_tokens"])
        let tool = firstInt(tokens, ["tool", "tool_tokens"])
        let counts = NanoTokenCounts(
            freshInput: input - min(input, cached) + tool,
            cacheRead: cached,
            output: output,
            reasoning: thoughts
        )
        return counts.total > 0 ? counts : nil
    }

    // MARK: Grok CLI

    /// Grok Build writes one `updates.jsonl` per session. Token totals land on
    /// `turn_completed` lines: input still includes the cached share, and
    /// `reasoningTokens` is a subset of output. Each prompt is one billed turn.
    static func scanGrokCLI(
        watermarks: [String: NanoScanWatermark],
        roots: [URL]? = nil
    ) -> ScanOutput {
        let logs = (roots ?? grokRoots()).flatMap { root in
            files(under: root.appendingPathComponent("sessions", isDirectory: true), extension: "jsonl")
                .filter { $0.lastPathComponent == "updates.jsonl" }
        }
        return scanJsonlAppends(files: logs, watermarks: watermarks) { _, line in
            grokTurnUsage(line)
        }
    }

    private static func grokRoots() -> [URL] {
        if let configured = ProcessInfo.processInfo.environment["GROK_HOME"] {
            let roots = configured.split(separator: ",").map {
                URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
            }
            if !roots.isEmpty { return roots }
        }
        return [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)]
    }

    private static func grokTurnUsage(_ line: Substring) -> ParsedUsageLine? {
        guard line.contains("turn_completed"),
              let object = json(from: line)
        else { return nil }

        let params = object["params"] as? [String: Any]
        let update = (params?["update"] as? [String: Any]) ?? (object["update"] as? [String: Any])
        guard let update,
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any]
        else { return nil }

        let modelUsage = usage["modelUsage"] as? [String: [String: Any]]
        let billed = modelUsage?.values.first ?? usage
        let input = firstInt(billed, ["inputTokens", "input_tokens"])
        let output = firstInt(billed, ["outputTokens", "output_tokens"])
        let cached = firstInt(billed, ["cachedReadTokens", "cached_read_tokens"])
        let created = firstInt(billed, ["cacheCreationTokens", "cache_creation_tokens"])
        let reasoning = firstInt(billed, ["reasoningTokens", "reasoning_tokens"])
        let counts = NanoTokenCounts(
            freshInput: max(input - min(input, cached), 0),
            cacheRead: cached,
            cacheWrite5m: created,
            output: output,
            reasoning: reasoning
        )
        guard counts.total > 0 else { return nil }

        let model = grokModelName(from: modelUsage)
            ?? (update["model"] as? String)
            ?? "grok-4.6"
        let meta = (params?["_meta"] as? [String: Any]) ?? (object["_meta"] as? [String: Any])
        let id = (update["prompt_id"] as? String)
            ?? (update["promptId"] as? String)
            ?? (meta?["eventId"] as? String)
        let day = grokDay(object: object, params: params, meta: meta)
        return ParsedUsageLine(
            id: id,
            provider: AgentProviderID.grok.rawValue,
            day: day,
            model: model,
            counts: counts
        )
    }

    private static func grokModelName(from modelUsage: [String: [String: Any]]?) -> String? {
        guard let model = modelUsage?.keys.sorted().first, !model.isEmpty else { return nil }
        if model.hasSuffix("-build") {
            return String(model.dropLast("-build".count))
        }
        return model
    }

    private static func grokDay(
        object: [String: Any],
        params: [String: Any]?,
        meta: [String: Any]?
    ) -> String {
        if let seconds = object["timestamp"] as? Double, seconds > 0 {
            let epoch = seconds > 1e12 ? seconds / 1000 : seconds
            return TokenLedger.dayString(Date(timeIntervalSince1970: epoch))
        }
        if let seconds = object["timestamp"] as? Int, seconds > 0 {
            let epoch = seconds > 1_000_000_000_000 ? Double(seconds) / 1000 : Double(seconds)
            return TokenLedger.dayString(Date(timeIntervalSince1970: epoch))
        }
        if let ms = firstOptionalInt(meta ?? [:], ["agentTimestampMs", "turnStartMs"]), ms > 0 {
            return TokenLedger.dayString(Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
        }
        if let iso = (params?["timestamp"] as? String) ?? (object["ts"] as? String),
           let day = day(fromISO: iso) {
            return day
        }
        return TokenLedger.dayString(Date())
    }

    // MARK: Batch-1 CLI data locations

    /// `$XDG_DATA_HOME` or `~/.local/share` — where Devin, Kilo, and Goose
    /// keep their session databases.
    static func xdgDataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["XDG_DATA_HOME"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(
                fileURLWithPath: NSString(string: configured).expandingTildeInPath,
                isDirectory: true
            )
        }
        return home.appendingPathComponent(".local/share", isDirectory: true)
    }

    /// `<xdg-data>/devin/cli/sessions.db`.
    static func devinDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        xdgDataDirectory(environment: environment, home: home)
            .appendingPathComponent("devin/cli/sessions.db")
    }

    /// Cline's data root and the two stores inside it. `CLINE_DATA_DIR`
    /// replaces `<root>/data`; `CLINE_DB_DATA_DIR` and `CLINE_SESSION_DATA_DIR`
    /// replace the `db/` and `sessions/` directories under it.
    static func clineDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (data: URL, database: URL, sessions: URL) {
        func dir(_ name: String) -> URL? {
            guard let value = environment[name],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return URL(
                fileURLWithPath: NSString(string: value).expandingTildeInPath,
                isDirectory: true
            )
        }
        let root = AgentRoutes.root(for: .cline, home: home, environment: environment)
        let data = dir("CLINE_DATA_DIR")
            ?? root.appendingPathComponent("data", isDirectory: true)
        let database = (dir("CLINE_DB_DATA_DIR")
            ?? data.appendingPathComponent("db", isDirectory: true))
            .appendingPathComponent("sessions.db")
        let sessions = dir("CLINE_SESSION_DATA_DIR")
            ?? data.appendingPathComponent("sessions", isDirectory: true)
        return (data, database, sessions)
    }

    /// `QWEN_RUNTIME_DIR`, falling back to the Qwen root (`QWEN_HOME` or
    /// `~/.qwen`). Chats live under `<runtime>/projects/*/chats`.
    static func qwenRuntimeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configured = environment["QWEN_RUNTIME_DIR"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(
                fileURLWithPath: NSString(string: configured).expandingTildeInPath,
                isDirectory: true
            )
        }
        return AgentRoutes.root(for: .qwen, home: home, environment: environment)
    }

    /// `KILO_DB` wins; a relative value resolves inside the data dir.
    /// Otherwise `<xdg-data>/kilo/kilo.db`.
    static func kiloDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let data = xdgDataDirectory(environment: environment, home: home)
            .appendingPathComponent("kilo", isDirectory: true)
        if let configured = environment["KILO_DB"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: configured).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded)
            }
            return data.appendingPathComponent(expanded)
        }
        return data.appendingPathComponent("kilo.db")
    }

    /// `sessions/sessions.db` under the Goose data dir (`GOOSE_PATH_ROOT/data`
    /// when the root is an absolute path, else `<xdg-data>/goose`), plus the
    /// pre-XDG location older installs used.
    static func gooseDatabaseURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let dataDir: URL
        if let root = environment["GOOSE_PATH_ROOT"],
           !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: root).expandingTildeInPath
            dataDir = expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded, isDirectory: true)
                    .appendingPathComponent("data", isDirectory: true)
                : xdgDataDirectory(environment: environment, home: home)
                    .appendingPathComponent("goose", isDirectory: true)
        } else {
            dataDir = xdgDataDirectory(environment: environment, home: home)
                .appendingPathComponent("goose", isDirectory: true)
        }
        return [
            dataDir.appendingPathComponent("sessions/sessions.db"),
            home.appendingPathComponent(
                "Library/Application Support/Block/goose/data/sessions/sessions.db"
            ),
        ]
    }

    // MARK: Devin CLI

    /// Devin's `message_nodes` table repeats one `request_id` across up to
    /// nine sibling nodes (conversation-tree forks) with identical integer
    /// token fields, so the request is banked once and the siblings skipped.
    /// `row_id` is a monotonic AUTOINCREMENT — the watermark.
    static func scanDevin(
        watermarks: [String: NanoScanWatermark],
        banked: [String: NanoTokenCounts],
        databaseURL: URL? = nil
    ) -> ScanOutput {
        var output = ScanOutput()
        let key = (databaseURL ?? devinDatabaseURL()).path

        var db: OpaquePointer?
        guard sqlite3_open_v2(key, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { return output }
        defer { sqlite3_close(db) }

        var latestRowID = watermarks[key]?.rowID ?? 0
        let sql = """
        SELECT row_id,
               json_extract(chat_message, '$.metadata.request_id'),
               json_extract(chat_message, '$.metadata.generation_model'),
               json_extract(chat_message, '$.metadata.created_at'),
               json_extract(chat_message, '$.metadata.metrics.input_tokens'),
               json_extract(chat_message, '$.metadata.metrics.cache_read_tokens'),
               json_extract(chat_message, '$.metadata.metrics.cache_creation_tokens'),
               json_extract(chat_message, '$.metadata.metrics.output_tokens'),
               created_at
        FROM message_nodes
        WHERE row_id > ?
          AND json_extract(chat_message, '$.role') = 'assistant'
          AND json_extract(chat_message, '$.metadata.metrics') IS NOT NULL
        ORDER BY row_id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return output }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, latestRowID)

        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = sqlite3_column_int64(statement, 0)
            latestRowID = max(latestRowID, rowID)

            let requestID = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let bankKey = "devin://" + (requestID ?? "row-\(rowID)")
            if banked[bankKey] != nil || output.banked[bankKey] != nil { continue }

            let counts = NanoTokenCounts(
                freshInput: Int(sqlite3_column_int64(statement, 4)),
                cacheRead: Int(sqlite3_column_int64(statement, 5)),
                cacheWrite5m: Int(sqlite3_column_int64(statement, 6)),
                output: Int(sqlite3_column_int64(statement, 7))
            )
            output.banked[bankKey] = counts
            guard counts.total > 0 else { continue }

            let model = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "unknown"
            let day = sqlite3_column_text(statement, 3)
                .map { String(cString: $0) }
                .flatMap(day(fromISO:))
                ?? TokenLedger.dayString(
                    Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 8)))
                )
            output.deltas.append(ScanDelta(
                provider: AgentProviderID.devin.rawValue,
                day: day,
                model: model,
                counts: counts
            ))
        }

        output.watermarks[key] = NanoScanWatermark(
            path: key, size: 0, modified: 0, offset: 0, rowID: latestRowID
        )
        return output
    }

    // MARK: Kilo Code

    /// Kilo Code is an OpenCode fork: same `message` table and `data` JSON
    /// shape, different database (`kilo.db`) and a fixed ledger provider —
    /// rows belong to Kilo regardless of the vendor `providerID` inside.
    static func scanKilo(
        watermarks: [String: NanoScanWatermark],
        banked: [String: NanoTokenCounts],
        databaseURL: URL? = nil
    ) -> ScanOutput {
        scanOpenCode(
            watermarks: watermarks,
            banked: banked,
            databaseURL: databaseURL ?? kiloDatabaseURL(),
            providerOverride: .kilo
        )
    }

    // MARK: Goose

    /// Newer Goose writes one `usage_ledger` row per call (watermark: `id`).
    /// Its `input_tokens` includes cache reads and writes — the Anthropic
    /// adapter sums them — so both come out of fresh input. Older Goose only
    /// has the `sessions` table's `accumulated_*` columns, which restate
    /// cumulative totals; those bank like a Gemini stats document.
    static func scanGoose(
        watermarks: [String: NanoScanWatermark],
        banked: [String: NanoTokenCounts],
        databaseURL: URL? = nil
    ) -> ScanOutput {
        var output = ScanOutput()
        let url = databaseURL ?? gooseDatabaseURLs().first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard let url else { return output }
        let key = url.path

        var db: OpaquePointer?
        guard sqlite3_open_v2(key, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { return output }
        defer { sqlite3_close(db) }

        if sqliteTableExists(db, name: "usage_ledger") {
            scanGooseUsageLedger(
                db, key: key, watermarks: watermarks, banked: banked, into: &output
            )
        } else if sqliteTableExists(db, name: "sessions") {
            scanGooseSessions(
                db, key: key, watermarks: watermarks, banked: banked, into: &output
            )
        }
        return output
    }

    private static func scanGooseUsageLedger(
        _ db: OpaquePointer?,
        key: String,
        watermarks: [String: NanoScanWatermark],
        banked: [String: NanoTokenCounts],
        into output: inout ScanOutput
    ) {
        var latestID = watermarks[key]?.rowID ?? 0
        let sql = """
        SELECT id, created_timestamp, model, input_tokens, output_tokens,
               cache_read_tokens, cache_write_tokens
        FROM usage_ledger
        WHERE id > ?
        ORDER BY id ASC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, latestID)

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            latestID = max(latestID, id)

            let bankKey = "goose://\(id)"
            if banked[bankKey] != nil || output.banked[bankKey] != nil { continue }

            let input = Int(sqlite3_column_int64(statement, 3))
            let cacheRead = Int(sqlite3_column_int64(statement, 5))
            let cacheWrite = Int(sqlite3_column_int64(statement, 6))
            let counts = NanoTokenCounts(
                freshInput: max(input - cacheRead - cacheWrite, 0),
                cacheRead: cacheRead,
                cacheWrite5m: cacheWrite,
                output: Int(sqlite3_column_int64(statement, 4))
            )
            output.banked[bankKey] = counts
            guard counts.total > 0 else { continue }

            // `carried_forward` rows record no model.
            let model = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? "unknown"
            output.deltas.append(ScanDelta(
                provider: AgentProviderID.goose.rawValue,
                day: TokenLedger.dayString(
                    Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1)))
                ),
                model: model,
                counts: counts
            ))
        }

        output.watermarks[key] = NanoScanWatermark(
            path: key, size: 0, modified: 0, offset: 0, rowID: latestID
        )
    }

    /// Older Goose has no per-call ledger; `sessions` restates each session's
    /// cumulative totals. A synthetic id per session keeps only the latest
    /// values — the Gemini stats-document pattern. The key is the session's
    /// own `id`, never `rowid`: rewriting a row can assign a new rowid and
    /// would double-count everything banked under the old one.
    private static func scanGooseSessions(
        _ db: OpaquePointer?,
        key: String,
        watermarks: [String: NanoScanWatermark],
        banked: [String: NanoTokenCounts],
        into output: inout ScanOutput
    ) {
        let columns = """
        accumulated_input_tokens, accumulated_output_tokens,
        accumulated_cache_read_tokens, accumulated_cache_write_tokens,
        json_extract(model_config_json, '$.model_name'), updated_at
        """
        var statement: OpaquePointer?
        // Prefer the stable `id` column; schemas without it fall back to rowid.
        if sqlite3_prepare_v2(
            db, "SELECT id, \(columns) FROM sessions", -1, &statement, nil
        ) != SQLITE_OK {
            sqlite3_finalize(statement)
            guard sqlite3_prepare_v2(
                db, "SELECT rowid, \(columns) FROM sessions", -1, &statement, nil
            ) == SQLITE_OK else { return }
        }
        defer { sqlite3_finalize(statement) }

        var latestUpdate: Int64 = watermarks[key]?.offset ?? 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let input = Int(sqlite3_column_int64(statement, 1))
            let cacheRead = Int(sqlite3_column_int64(statement, 3))
            let cacheWrite = Int(sqlite3_column_int64(statement, 4))
            let counts = NanoTokenCounts(
                freshInput: max(input - cacheRead - cacheWrite, 0),
                cacheRead: cacheRead,
                cacheWrite5m: cacheWrite,
                output: Int(sqlite3_column_int64(statement, 2))
            )

            let sessionID = sqlite3_column_text(statement, 0).map { String(cString: $0) }
                ?? String(sqlite3_column_int64(statement, 0))
            let bankKey = "goose://session-\(sessionID)"
            let previous = banked[bankKey] ?? output.banked[bankKey] ?? NanoTokenCounts()
            let delta = countsMinus(counts, previous)
            output.banked[bankKey] = counts
            guard delta.total > 0 else { continue }

            let model = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? "unknown"
            output.deltas.append(ScanDelta(
                provider: AgentProviderID.goose.rawValue,
                day: gooseDay(statement, column: 6),
                model: model,
                counts: delta
            ))
            if let updated = gooseUpdatedAt(statement, column: 6) {
                latestUpdate = max(latestUpdate, updated)
            }
        }

        output.watermarks[key] = NanoScanWatermark(
            path: key, size: 0, modified: 0, offset: latestUpdate
        )
    }

    /// `updated_at` is epoch seconds in some Goose builds and ISO-8601 text in
    /// others; accept both.
    private static func gooseUpdatedAt(_ statement: OpaquePointer?, column: Int32) -> Int64? {
        guard let text = sqlite3_column_text(statement, column).map({ String(cString: $0) }) else {
            return nil
        }
        if let seconds = Int64(text) { return seconds }
        if let ms = milliseconds(fromISO: text) { return Int64(ms / 1000) }
        return nil
    }

    private static func gooseDay(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let text = sqlite3_column_text(statement, column).map({ String(cString: $0) }) else {
            return TokenLedger.dayString(Date())
        }
        if let seconds = Int64(text) {
            return TokenLedger.dayString(Date(timeIntervalSince1970: TimeInterval(seconds)))
        }
        return day(fromISO: text) ?? TokenLedger.dayString(Date())
    }

    private static func sqliteTableExists(_ db: OpaquePointer?, name: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            -1, &statement, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    // MARK: Cline

    /// Cline rewrites each session's `messages.json` in place — a whole JSON
    /// document, either a top-level array or an object with a `messages`
    /// array — so files watermark by mtime+size and each message banks by id,
    /// keeping only the latest values on a rewrite (the Gemini document
    /// pattern). Id-less messages key on `<file>#<index>`.
    static func scanCline(
        watermarks: [String: NanoScanWatermark],
        banked: [String: NanoTokenCounts],
        directories: (data: URL, database: URL, sessions: URL)? = nil
    ) -> ScanOutput {
        let dirs = directories ?? clineDirectories()
        var files = clineMessageFiles(database: dirs.database)
        if files.isEmpty {
            files = self.files(under: dirs.sessions, extension: "json")
                .filter { $0.lastPathComponent == "messages.json" }
        }

        var output = ScanOutput()
        for file in files {
            guard let attributes = try? FileManager.default
                .attributesOfItem(atPath: file.path),
                let size = attributes[.size] as? Int64,
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
            else { continue }

            let key = file.path
            let mark = watermarks[key]
            if let mark, mark.size == size, mark.modified == modified { continue }
            guard let data = try? Data(contentsOf: file),
                  let messages = clineMessages(in: data)
            else { continue }

            let fallbackDay = TokenLedger.dayString(Date(timeIntervalSince1970: modified))
            var eventsByKey: [String: (day: String, model: String, counts: NanoTokenCounts)] = [:]
            for (index, message) in messages.enumerated() {
                guard let metrics = message["metrics"] as? [String: Any] else { continue }
                let counts = NanoTokenCounts(
                    // `inputTokens` excludes cache, so it is fresh input as-is.
                    freshInput: int(metrics["inputTokens"]),
                    cacheRead: int(metrics["cacheReadTokens"]),
                    cacheWrite5m: int(metrics["cacheWriteTokens"]),
                    output: int(metrics["outputTokens"])
                )
                guard counts.total > 0 else { continue }

                let id = (message["id"] as? String) ?? String(index)
                let ms = int64(message["ts"])
                let day = ms > 0
                    ? TokenLedger.dayString(Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
                    : fallbackDay
                let model = (message["modelInfo"] as? [String: Any])?["id"] as? String
                    ?? "unknown"
                // Last write wins when a rewrite restates an id.
                eventsByKey["cline://\(key)#\(id)"] = (day, model, counts)
            }

            for (bankKey, event) in eventsByKey {
                let previous = banked[bankKey] ?? NanoTokenCounts()
                let delta = countsMinus(event.counts, previous)
                output.banked[bankKey] = event.counts
                guard delta.total > 0 else { continue }
                output.deltas.append(ScanDelta(
                    provider: AgentProviderID.cline.rawValue,
                    day: event.day,
                    model: event.model,
                    counts: delta
                ))
            }

            output.watermarks[key] = NanoScanWatermark(
                path: key, size: size, modified: modified, offset: size
            )
        }
        return output
    }

    /// Session files come from the index db's `sessions.messages_path` when
    /// the db exists; the caller falls back to globbing `sessions/` without it.
    private static func clineMessageFiles(database: URL) -> [URL] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT messages_path FROM sessions WHERE messages_path IS NOT NULL",
            -1, &statement, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var files: [URL] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let path = String(cString: text)
            guard !path.isEmpty else { continue }
            if path.hasPrefix("/") || path.hasPrefix("~") {
                files.append(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
            } else {
                files.append(database.deletingLastPathComponent()
                    .appendingPathComponent(path))
            }
        }
        return files
    }

    private static func clineMessages(in data: Data) -> [[String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let array = object as? [[String: Any]] { return array }
        return (object as? [String: Any])?["messages"] as? [[String: Any]]
    }

    // MARK: Qwen Code

    /// Qwen Code appends one JSONL record per event under
    /// `<runtime>/projects/*/chats/`. Assistant records carry Gemini-shaped
    /// `usageMetadata`; `system` `ui_telemetry` records restate the same usage
    /// and are skipped. `/branch` copies records verbatim, so `uuid` dedups
    /// across files via the banked set, not just the per-file id tail.
    static func scanQwen(
        watermarks: [String: NanoScanWatermark],
        banked: [String: NanoTokenCounts],
        roots: [URL]? = nil
    ) -> ScanOutput {
        let runtimes = roots ?? [qwenRuntimeDirectory()]
        let chatFiles = runtimes.flatMap { runtime in
            files(under: runtime.appendingPathComponent("projects", isDirectory: true),
                  extension: "jsonl")
                .filter { $0.deletingLastPathComponent().lastPathComponent == "chats" }
        }

        var output = ScanOutput()
        var newlyBanked: [String: NanoTokenCounts] = [:]
        let appends = scanJsonlAppends(files: chatFiles, watermarks: watermarks) { _, line in
            guard line.contains("\"usageMetadata\""),
                  let object = json(from: line),
                  object["type"] as? String == "assistant",
                  let usage = object["usageMetadata"] as? [String: Any]
            else { return nil }

            let prompt = int(usage["promptTokenCount"])
            let cached = int(usage["cachedContentTokenCount"])
            let counts = NanoTokenCounts(
                // promptTokenCount includes the cached share.
                freshInput: max(prompt - cached, 0),
                cacheRead: cached,
                // Same convention as the Gemini scanner: candidates are output
                // and thoughts ride along as display-only reasoning.
                output: int(usage["candidatesTokenCount"]),
                reasoning: int(usage["thoughtsTokenCount"])
            )
            guard counts.total > 0 else { return nil }

            if let uuid = object["uuid"] as? String {
                let bankKey = "qwen://\(uuid)"
                if banked[bankKey] != nil || newlyBanked[bankKey] != nil { return nil }
                newlyBanked[bankKey] = counts
                return ParsedUsageLine(
                    id: uuid,
                    provider: AgentProviderID.qwen.rawValue,
                    day: (object["timestamp"] as? String).flatMap(day(fromISO:))
                        ?? TokenLedger.dayString(Date()),
                    model: (object["model"] as? String) ?? "unknown",
                    counts: counts
                )
            }
            return ParsedUsageLine(
                id: nil,
                provider: AgentProviderID.qwen.rawValue,
                day: (object["timestamp"] as? String).flatMap(day(fromISO:))
                    ?? TokenLedger.dayString(Date()),
                model: (object["model"] as? String) ?? "unknown",
                counts: counts
            )
        }
        output.deltas = appends.deltas
        output.watermarks = appends.watermarks
        output.banked = newlyBanked
        return output
    }

    // MARK: Shared helpers

    /// Shared incremental scan over append-only JSONL logs: reads only the
    /// bytes after each file's watermark, dedups restated ids (last write wins
    /// within a chunk, the watermark's recent-id tail across chunks), and
    /// aggregates by (provider, day, model).
    private static func scanJsonlAppends(
        files: [URL],
        watermarks: [String: NanoScanWatermark],
        readLimit: Int64 = 64_000_000,
        parseLine: (URL, Substring) -> ParsedUsageLine?
    ) -> ScanOutput {
        var output = ScanOutput()

        for file in files {
            guard let attributes = try? FileManager.default
                .attributesOfItem(atPath: file.path),
                let size = attributes[.size] as? Int64,
                let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
            else { continue }

            let key = file.path
            let mark = watermarks[key]
            if let mark, mark.size == size, mark.modified == modified { continue }

            // A file that shrank was rotated; read it from the start again.
            let resumeAt = (mark?.size ?? 0) <= size ? (mark?.offset ?? 0) : 0
            guard let chunk = boundedText(
                of: file, size: size, from: resumeAt, limit: readLimit
            ) else { continue }

            let seen: Set<String> = mark?.recentIDs.map(Set.init) ?? []
            var chunkIDs: [String] = []
            var byID: [String: ParsedUsageLine] = [:]
            var idless: [ParsedUsageLine] = []

            for line in chunk.text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let parsed = parseLine(file, line) else { continue }
                guard let id = parsed.id else {
                    idless.append(parsed)
                    continue
                }
                // Already banked in an earlier chunk. A source that restates an
                // id with grown tokens across scans loses that growth — a
                // message's worth, accepted for a bounded watermark.
                if seen.contains(id) { continue }
                if byID[id] == nil { chunkIDs.append(id) }
                byID[id] = parsed
            }

            var compositeTotals: [String: (provider: String, day: String, model: String, counts: NanoTokenCounts)] = [:]
            for parsed in idless + byID.values {
                let composite = "\(parsed.provider)|\(parsed.day)|\(parsed.model)"
                var entry = compositeTotals[composite]
                    ?? (parsed.provider, parsed.day, parsed.model, NanoTokenCounts())
                entry.counts += parsed.counts
                compositeTotals[composite] = entry
            }

            output.watermarks[key] = NanoScanWatermark(
                path: key,
                size: chunk.endOffset,
                modified: modified,
                offset: chunk.endOffset,
                recentIDs: Array(((mark?.recentIDs ?? []) + chunkIDs).suffix(500))
            )

            for entry in compositeTotals.values where entry.counts.total > 0 {
                output.deltas.append(ScanDelta(
                    provider: entry.provider,
                    day: entry.day,
                    model: entry.model,
                    counts: entry.counts
                ))
            }
        }

        return output
    }

    /// Whole-counters difference, floored at zero per bucket — counters that
    /// reset must never produce negative deltas.
    private static func countsMinus(_ latest: NanoTokenCounts, _ previous: NanoTokenCounts) -> NanoTokenCounts {
        NanoTokenCounts(
            freshInput: max(latest.freshInput - previous.freshInput, 0),
            cacheRead: max(latest.cacheRead - previous.cacheRead, 0),
            cacheWrite5m: max(latest.cacheWrite5m - previous.cacheWrite5m, 0),
            cacheWrite1h: max(latest.cacheWrite1h - previous.cacheWrite1h, 0),
            output: max(latest.output - previous.output, 0),
            reasoning: max(latest.reasoning - previous.reasoning, 0)
        )
    }

    private static func firstInt(_ object: [String: Any], _ keys: [String]) -> Int {
        for key in keys {
            if let value = object[key] { return int(value) }
        }
        return 0
    }

    private static func firstOptionalInt(_ object: [String: Any], _ keys: [String]) -> Int? {
        for key in keys where object[key] != nil {
            return int(object[key])
        }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64 {
        (value as? Int64) ?? Int64((value as? Int) ?? Int((value as? Double) ?? 0))
    }

    private static func double(_ value: Any?) -> Double {
        (value as? Double) ?? Double((value as? Int) ?? 0)
    }

    /// Reads forward from `offset` with a hard ceiling, so one oversized log
    /// cannot stall the app or exhaust memory. Lifetime must see the start of
    /// the file, so an unread span larger than `limit` is consumed over later
    /// scans rather than replaced by the tail. A trailing partial line (the
    /// file was mid-write) is excluded, and `endOffset` marks the last byte
    /// consumed so it is retried next scan.
    private static func boundedText(
        of url: URL,
        size: Int64,
        from offset: Int64 = 0,
        limit: Int64 = 64_000_000
    ) -> (text: String, endOffset: Int64)? {
        let start = max(offset, 0)
        let remaining = max(size - start, 0)
        let toRead = min(remaining, max(limit, 0))
        guard toRead > 0 else { return ("", start) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(start))) != nil else { return nil }
        let data = handle.readData(ofLength: Int(toRead))

        // Cut at the last newline before decoding. The read stops at a byte
        // count, which can land inside a multi-byte character; decoding that
        // strictly failed, and the file was then skipped on every scan.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            // One partial line and nothing else: consume nothing so the
            // completed line is picked up once the writer finishes it.
            return ("", start)
        }
        let complete = data[...lastNewline]
        return (String(decoding: complete, as: UTF8.self), start + Int64(complete.count))
    }

    private static func jsonlFiles(under root: URL) -> [URL] {
        files(under: root, extension: "jsonl")
    }

    private static func files(under root: URL, extension pathExtension: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == pathExtension {
            files.append(url)
        }
        return files
    }

    private static func json(from line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func nested(_ object: [String: Any], _ key: String) -> [String: Any]? {
        if let direct = object[key] as? [String: Any] { return direct }
        if let payload = object["payload"] as? [String: Any] {
            return payload[key] as? [String: Any]
        }
        return nil
    }

    private static func int(_ value: Any?) -> Int {
        (value as? Int) ?? Int((value as? Double) ?? 0)
    }

    private static func value(in line: Substring, key: String) -> String? {
        guard let object = json(from: line) else { return nil }
        if let direct = object[key] as? String { return direct }

        // Codex nests it: `turn_context` records carry the model at
        // `payload.model`, never at the top level. Reading only the top level
        // left every Codex row as "unknown", which resolved to no price at all
        // — so billions of Codex tokens were costing $0.00.
        if let payload = object["payload"] as? [String: Any] {
            if let nested = payload[key] as? String { return nested }
            if let settings = payload["thread_settings"] as? [String: Any],
               let nested = settings[key] as? String {
                return nested
            }
        }
        return nil
    }

    /// Epoch milliseconds, for measuring the gaps between Codex usage events.
    private static func milliseconds(fromISO text: String?) -> Double? {
        guard let text else { return nil }
        return NanoISO8601.date(text).map { $0.timeIntervalSince1970 * 1000 }
    }

    private static func day(fromISO text: String) -> String? {
        NanoISO8601.date(text).map(TokenLedger.dayString)
    }
}
