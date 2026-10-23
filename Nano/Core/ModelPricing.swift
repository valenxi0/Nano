import CryptoKit
import Foundation

// Resolves what a user's local agent usage would have cost at API list prices.
//
// Source of truth is https://models.dev/api.json, cached on disk with a 24 hour
// TTL. Shape of that document (verified 2026-07-30):
//
//   { "<provider id>": { "id", "name", "npm", "doc", "env",
//       "models": { "<model id>": { ..., "cost": {
//           "input": 5, "output": 25, "cache_read": 0.5, "cache_write": 6.25,
//           "context_over_200k": { "input": 10, "output": 45, ... },
//           "tiers": [ ... ] } } } } }
//
// All cost figures are USD per 1,000,000 tokens. `cost` may be null or absent,
// which means unpriced rather than free.

/// USD-per-token rates for one pricing lane, stored as nanodollars per token so
/// the cost math never has to re-derive the per-1M conversion.
struct NanoRateLane: Codable, Equatable, Sendable {
    var inputNanos: Double
    var outputNanos: Double
    var cacheReadNanos: Double?
    var cacheWrite5mNanos: Double?
    var cacheWrite1hNanos: Double?

    /// 1 USD per 1M tokens == 1000 nanodollars per token.
    init(perMillionInput: Double, perMillionOutput: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, cacheWrite1h: Double? = nil) {
        inputNanos = perMillionInput * 1_000
        outputNanos = perMillionOutput * 1_000
        cacheReadNanos = cacheRead.map { $0 * 1_000 }
        cacheWrite5mNanos = cacheWrite.map { $0 * 1_000 }
        cacheWrite1hNanos = cacheWrite1h.map { $0 * 1_000 }
    }

    var perMillionInput: Double { inputNanos / 1_000 }
    var perMillionOutput: Double { outputNanos / 1_000 }
}

/// Base rates plus the optional above-200k-context lane models.dev publishes as
/// `context_over_200k`.
struct NanoModelRate: Codable, Equatable, Sendable {
    var base: NanoRateLane
    var longContext: NanoRateLane?
}

/// Prices token counts against the models.dev catalog, falling back to a small
/// bundled table when the catalog is unreachable or lags a new model.
final class NanoModelPricing: NanoPriceResolver, @unchecked Sendable {
    static let shared = NanoModelPricing()

    /// Bump whenever the cost formula below changes, so cached costs recompute.
    private static let costFormulaVersion = 4

    /// Log source to models.dev provider id. Also defines which catalog entries
    /// are "in use" for fingerprinting purposes.
    private static let providerAliases: [String: String] = [
        "codex": "openai",
        "openai": "openai",
        "claude": "anthropic",
        "claude-code": "anthropic",
        "anthropic": "anthropic",
        "opencode": "opencode",
        // kimi-for-coding is a subscription plan, so models.dev prices it at
        // $0. The ledger answers "what would this cost at API list prices",
        // which is Moonshot's published rate for the same model.
        "kimi-for-coding": "moonshotai",
        "moonshot": "moonshotai",
        "moonshotai": "moonshotai",
        "kimi": "moonshotai",
        "gemini": "google",
        "google": "google",
        "grok": "xai",
        // Cursor is a harness, not a vendor. Vendor routing is inferred from
        // the model id; this alias only puts xAI rates into the fingerprint.
        "xai": "xai"
    ]

    /// models.dev model ids where they differ from what a harness reports,
    /// keyed "catalogProvider|reportedModel".
    private static let modelAliases: [String: String] = [
        "moonshotai|k3": "kimi-k3",
        "moonshotai|k3-256k": "kimi-k3",
        // The Kimi CLI's generic subscription model name; current Kimi for
        // Coding runs K2.6-class models (ccusage's convention too).
        "moonshotai|kimi-for-coding": "kimi-k2.6",
        // Devin labels its context compactor "Compactor (Luna)".
        "devin|compactor": "gpt-6-luna-medium",
        // Grok CLI tags the coding lane as `<model>-build`.
        "xai|grok-4.6-build": "grok-4.6",
        "xai|grok-4.5-build": "grok-4.5",
        // Cursor reports Grok 4.6 as a routing lane, not the catalog id.
        "cursor|grok-bot": "grok-4.6",
        "cursor|grok-bot-default": "grok-4.6",
        "cursor|grok-bot-cua": "grok-4.6",
        "xai|grok-bot": "grok-4.6",
        "xai|grok-bot-default": "grok-4.6",
        "xai|grok-bot-cua": "grok-4.6"
    ]

    /// Codex labels its automatic review passes `codex-auto-review`, which names
    /// a role rather than a model and so has no catalog entry of its own. The
    /// model behind it is whichever Codex shipped as current at the time, so the
    /// row's day picks the entry in force on that date.
    ///
    /// Newest first. Mirrors ccusage's `codex-auto-review-fallbacks.json`.
    private static let autoReviewModels: [(since: String, model: String)] = [
        ("2026-04-23", "gpt-5.5"),
        ("2026-03-05", "gpt-5.4"),
        ("2026-02-05", "gpt-5.3-codex"),
        ("2025-12-11", "gpt-5.2-codex"),
        ("2025-11-13", "gpt-5.1-codex"),
        ("2025-09-15", "gpt-5-codex"),
        ("2025-08-07", "gpt-5")
    ]

    /// `yyyy-MM-dd` sorts lexicographically, so the first entry not newer than
    /// the row's day is the one that was current when it ran.
    private static func autoReviewModel(on day: String) -> String? {
        autoReviewModels.first { day >= $0.since }?.model
    }

    /// Official list rates checked September 4, 2026. Fresh catalog entries
    /// win over these offline fallbacks, so future price changes can refresh.
    private static let fallbackTable: [String: NanoModelRate] = [
        "anthropic|claude-opus-5": claudeRate(5.00, 25.00),
        "anthropic|claude-opus-4-8": claudeRate(5.00, 25.00),
        "anthropic|claude-opus-4-7": claudeRate(5.00, 25.00),
        "anthropic|claude-opus-4-6": claudeRate(5.00, 25.00),
        "anthropic|claude-sonnet-5": claudeRate(2.00, 10.00),
        "anthropic|claude-sonnet-4-6": claudeRate(3.00, 15.00),
        "anthropic|claude-haiku-4-5": claudeRate(1.00, 5.00),
        "openai|gpt-6-astra": NanoModelRate(base: NanoRateLane(perMillionInput: 10, perMillionOutput: 50, cacheRead: 1, cacheWrite: 12.5), longContext: NanoRateLane(perMillionInput: 20, perMillionOutput: 75, cacheRead: 2, cacheWrite: 25)),
        "anthropic|claude-fable-5-1": claudeRate(10, 50, read: 0.25),
        "anthropic|claude-fable-5": claudeRate(10.00, 50.00),
        "moonshotai|kimi-k3": rate(3.00, 15.00, read: 0.3),
        "moonshotai|kimi-k2.6": rate(0.95, 4.00, read: 0.16),
        "xai|grok-4.6": rate(2.00, 6.00, read: 0.5),
        "xai|grok-4.5": rate(2.00, 6.00, read: 0.3),
        // Cursor's own Composer models, from Cursor's published rates (Fast is
        // the default variant). Cursor is a harness, so these are keyed by it.
        "cursor|composer-2.5": rate(0.50, 2.50, read: 0.20),
        "cursor|composer-2.5-fast": rate(3.00, 15.00, read: 0.20)
    ]

    /// Cursor (and other harnesses) append reasoning-effort and routing tags
    /// that the catalog never lists: `gpt-5.6-sol-medium`,
    /// `cursor-grok-4.6-high-fast`, `claude-opus-4-8-thinking-high`.
    /// Longest first so `thinking-high` peels in one step.
    private static let effortSuffixes = [
        "thinking-xhigh", "thinking-high", "thinking-medium", "thinking-low",
        "high-fast", "extra-high", "xhigh", "thinking",
        "high", "medium", "low", "fast", "max", "ultra"
    ]

    private static let catalogVendors: Set<String> = [
        "openai", "anthropic", "google", "moonshotai", "opencode", "xai"
    ]

    private static func rate(_ input: Double, _ output: Double, read: Double? = nil) -> NanoModelRate {
        NanoModelRate(base: NanoRateLane(perMillionInput: input, perMillionOutput: output, cacheRead: read))
    }

    private static func claudeRate(_ input: Double, _ output: Double, read: Double? = nil) -> NanoModelRate {
        NanoModelRate(base: NanoRateLane(perMillionInput: input, perMillionOutput: output,
            cacheRead: read ?? input * 0.1, cacheWrite: input * 1.25, cacheWrite1h: input * 2))
    }

    private let session: URLSession
    private let lock = NSLock()
    /// Guarded by `lock`. Keyed `provider|model`.
    private var catalog: [String: NanoModelRate] = [:]
    private var catalogFetchedAt: Date?
    /// Guarded by `lock`. Devin's own rate card, keyed by its `model_uid`.
    private var devinCard: [String: NanoModelRate] = [:]
    private var devinCardFetchedAt: Date?
    /// Last time `devin models list` failed or returned nothing usable.
    private var devinCardAttemptedAt: Date?
    private var fingerprint: String

    init(
        session: URLSession = .shared,
        catalogData: Data? = nil,
        devinCardData: Data? = nil,
        loadCache: Bool = true
    ) {
        self.session = session
        if let catalogData, let rates = try? Self.decodeCatalog(catalogData) {
            catalog = rates
        } else if loadCache, let cached = Self.readCache() {
            catalog = cached.rates
            catalogFetchedAt = cached.fetchedAt
        }
        if let devinCardData {
            devinCard = Self.decodeDevinCard(devinCardData)
        } else if loadCache, let cached = Self.readCache(url: Self.devinCacheURL) {
            devinCard = cached.rates
            devinCardFetchedAt = cached.fetchedAt
        }
        fingerprint = Self.makeFingerprint(catalog: catalog, devinCard: devinCard)
    }

    // MARK: - NanoPriceResolver

    func costNanos(provider: String, model: String, day: String, counts: NanoTokenCounts) -> Int? {
        costNanos(provider: provider, model: model, day: day, counts: counts, longContext: false)
    }

    var pricingFingerprint: String {
        lock.withLock { fingerprint }
    }

    func refreshPricing() async {
        await refresh()
    }

    // MARK: - Pricing

    /// `longContext` selects the above-200k lane when the catalog publishes one.
    func costNanos(
        provider: String,
        model: String,
        day: String,
        counts: NanoTokenCounts,
        longContext: Bool
    ) -> Int? {
        guard let rate = rate(provider: provider, model: model, day: day) else { return nil }
        let lane = (longContext ? rate.longContext : nil) ?? rate.base
        // An absent price is not a free bucket. Reasoning is already in output.
        // Cache writes are the exception: vendors without a write premium
        // (xAI, OpenAI, Devin) bill written tokens as ordinary input and so
        // publish no write price. Leaving them nil made every Cursor Grok row
        // with a cache write unpriced.
        let buckets: [(Int, Double?)] = [
            (counts.freshInput, lane.inputNanos), (counts.output, lane.outputNanos),
            (counts.cacheRead, lane.cacheReadNanos),
            (counts.cacheWrite5m, lane.cacheWrite5mNanos ?? lane.inputNanos),
            (counts.cacheWrite1h, lane.cacheWrite1hNanos ?? lane.cacheWrite5mNanos ?? lane.inputNanos)
        ]
        var total = 0.0
        for (count, price) in buckets {
            guard count >= 0 else { return nil }
            if count == 0 { continue }
            guard let price, price.isFinite, price >= 0 else { return nil }
            total += Double(count) * price
        }
        guard total.isFinite, total < Double(Int.max) else { return nil }
        return Int(total.rounded())
    }

    /// Catalog first, bundled table second, nil when neither knows the model.
    func rate(provider: String, model: String, day: String = "") -> NanoModelRate? {
        let providerID = Self.providerID(provider)
        let candidates = Self.modelCandidates(model, providerID: providerID, day: day)
        let vendors = Self.vendors(logged: providerID, model: model)

        let (snapshot, devin) = lock.withLock { (catalog, devinCard) }
        // Devin bills its own card, including models no vendor sells directly
        // (SWE-2) and its own rates for vendor models it resells.
        if providerID == "devin" {
            for candidate in candidates {
                if let hit = devin[candidate] { return hit }
            }
        }
        for vendor in vendors {
            for candidate in candidates {
                if let hit = snapshot["\(vendor)|\(candidate)"] { return hit }
            }
        }
        for vendor in vendors {
            for candidate in candidates {
                if let hit = Self.fallbackTable["\(vendor)|\(candidate)"] { return hit }
            }
        }
        // Harness-owned models (Cursor's Composer) have no catalog vendor.
        for candidate in candidates {
            if let hit = Self.fallbackTable["\(providerID)|\(candidate)"] { return hit }
        }

        return nil
    }

    /// Catalog vendors to try for a logged provider. Cursor is a harness, so
    /// the vendor is inferred from the model (`grok-…` → xAI, `gpt-…` → OpenAI).
    private static func vendors(logged providerID: String, model: String) -> [String] {
        var ids: [String] = []
        if catalogVendors.contains(providerID) {
            ids.append(providerID)
        }
        ids.append(contentsOf: inferredVendors(from: model))
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func inferredVendors(from model: String) -> [String] {
        var slug = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        if slug.hasPrefix("cursor-") {
            slug.removeFirst("cursor-".count)
        }
        if slug.hasPrefix("grok") { return ["xai"] }
        if slug.hasPrefix("gpt")
            || slug.hasPrefix("o1")
            || slug.hasPrefix("o3")
            || slug.hasPrefix("o4")
            || slug.hasPrefix("chatgpt")
        {
            return ["openai"]
        }
        if slug.hasPrefix("claude") { return ["anthropic"] }
        if slug.hasPrefix("gemini") { return ["google"] }
        if slug.hasPrefix("kimi") { return ["moonshotai"] }
        return []
    }

    private static func providerID(_ provider: String) -> String {
        let normalized = provider.lowercased()
        return providerAliases[normalized] ?? normalized
    }

    /// Exact id first, then the id with a trailing `-YYYYMMDD` release stamp
    /// stripped, since CLI logs report dated ids the catalog may not list.
    /// Harness-specific aliases (e.g. opencode's `k3` for Kimi K3) last.
    private static func modelCandidates(
        _ model: String,
        providerID: String,
        day: String = ""
    ) -> [String] {
        let normalized = model.lowercased().split(separator: "/").last.map(String.init) ?? model.lowercased()
        var candidates = [normalized]

        var core = normalized
        if core.hasPrefix("cursor-") {
            core.removeFirst("cursor-".count)
            if !core.isEmpty { candidates.append(core) }
        }

        var peeled = core
        var peeling = true
        while peeling {
            peeling = false
            for suffix in effortSuffixes {
                let token = "-" + suffix
                guard peeled.hasSuffix(token), peeled.count > token.count else { continue }
                peeled = String(peeled.dropLast(token.count))
                candidates.append(peeled)
                peeling = true
                break
            }
        }

        // The catalog sometimes lists only the preview name (Cursor logs
        // `gemini-3.1-pro`; models.dev has `gemini-3.1-pro-preview`).
        if !peeled.hasSuffix("-preview") {
            candidates.append(peeled + "-preview")
        }
        if let range = peeled.range(of: "-[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) {
            candidates.append(String(peeled[..<range.lowerBound]))
        }
        let parts = peeled.split(separator: "-")
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            candidates.append(parts.dropLast().joined(separator: "-"))
        }
        // `codex-auto-review` names a role, so it only resolves once the row's
        // day says which model was behind it.
        if normalized == "codex-auto-review", !day.isEmpty,
           let dated = autoReviewModel(on: day) {
            candidates.append(dated)
        }
        // Cursor's Grok lane (`grok-bot`, `grok-bot-default`, `grok-bot-cua`)
        // is Grok 4.6. Keep the stored routing name; price it as the catalog id.
        if normalized == "grok-bot" || normalized.hasPrefix("grok-bot-") {
            candidates.append("grok-4.6")
        }
        for candidate in Array(candidates) {
            if let alias = modelAliases["\(providerID)|\(candidate)"] {
                candidates.append(alias)
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    // MARK: - Refresh

    /// Fetches models.dev unless the disk cache is still inside its 24 hour TTL.
    /// A failed refresh keeps serving the previous cache.
    func refresh(force: Bool = false) async {
        await refreshDevinCard(force: force)
        let (fetchedAt, isEmpty) = lock.withLock { (catalogFetchedAt, catalog.isEmpty) }

        if !force, !isEmpty, let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.cacheTTL {
            return
        }

        guard let url = URL(string: "https://models.dev/api.json") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Nano/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let rates = try Self.decodeCatalog(data)
            guard !rates.isEmpty else { return }

            let cache = CachedCatalog(fetchedAt: Date(), rates: rates)
            lock.withLock {
                catalog = rates
                catalogFetchedAt = cache.fetchedAt
                fingerprint = Self.makeFingerprint(catalog: rates, devinCard: devinCard)
            }
            Self.writeCache(cache)
        } catch {
            // Network or schema trouble: keep the last valid cache.
        }
    }

    // MARK: - Devin rate card

    /// models.dev has no Devin entries, and Cognition publishes no per-token
    /// rates for its own models. The CLI does: `devin models list` prints the
    /// price of every model the account can use, so Nano reads that rather
    /// than hand-maintaining a table of several hundred variants.
    private func refreshDevinCard(force: Bool) async {
        let (fetchedAt, attemptedAt) = lock.withLock { (devinCardFetchedAt, devinCardAttemptedAt) }
        if !force, let fetchedAt, Date().timeIntervalSince(fetchedAt) < Self.cacheTTL { return }
        // A missing, signed-out or hanging CLI fails the same way on the next
        // scan pass. Without this it was respawned on every one of them.
        if !force, let attemptedAt,
           Date().timeIntervalSince(attemptedAt) < Self.devinRetryInterval { return }
        let data = await Task.detached(priority: .utility, operation: Self.readDevinModels).value
        let rates = data.map(Self.decodeDevinCard) ?? [:]
        guard !rates.isEmpty else {
            lock.withLock { devinCardAttemptedAt = Date() }
            return
        }
        let cache = CachedCatalog(fetchedAt: Date(), rates: rates)
        lock.withLock {
            devinCard = rates
            devinCardFetchedAt = cache.fetchedAt
            fingerprint = Self.makeFingerprint(catalog: catalog, devinCard: rates)
        }
        Self.writeCache(cache, to: Self.devinCacheURL)
    }

    /// GUI apps do not inherit the login shell's PATH, so look where the
    /// installer and Homebrew put the binary.
    private static func readDevinModels() -> Data? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let executable = [
            home.appendingPathComponent(".local/bin/devin").path,
            "/opt/homebrew/bin/devin",
            "/usr/local/bin/devin"
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["models", "list", "--format", "json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // The read below only returns when the CLI closes its output. One
        // stuck on the network or a sign-in prompt would hold the ledger scan
        // that is waiting on this, so it is ended after a bounded wait.
        let pid = process.processIdentifier
        let timeout = DispatchWorkItem { _ = kill(pid, SIGTERM) }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + devinListTimeout,
            execute: timeout
        )
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 0 ? data : nil
    }

    private struct DevinModelList: Decodable {
        struct Family: Decodable { var variants: [Variant] }
        struct Variant: Decodable {
            var modelUID: String
            var costTier: String?
            var costSummary: String?

            enum CodingKeys: String, CodingKey {
                case modelUID = "model_uid"
                case costTier = "cost_tier"
                case costSummary = "cost_summary"
            }
        }
        var families: [Family]
    }

    /// `cost_summary` reads "$4 / 1M Input · $0.2 / 1M Cached input · $20 /
    /// 1M Output", sometimes followed by Sidekick rates, which bill a helper
    /// model the ledger records separately. `cost_tier: "Free"` with no
    /// summary is a real $0 (SWE-2 during its launch offer), not unpriced.
    static func decodeDevinCard(_ data: Data) -> [String: NanoModelRate] {
        guard let list = try? JSONDecoder().decode(DevinModelList.self, from: data) else { return [:] }
        func price(_ label: String, in summary: String) -> Double? {
            guard let range = summary.range(
                of: #"\$([0-9.]+) / 1M \#(label)"#, options: .regularExpression
            ) else { return nil }
            let match = summary[range].dropFirst()
            return Double(match.prefix { $0.isNumber || $0 == "." })
        }

        var rates: [String: NanoModelRate] = [:]
        for variant in list.families.flatMap(\.variants) {
            let id = variant.modelUID.lowercased()
            if let summary = variant.costSummary,
               let input = price("Input", in: summary),
               let output = price("Output", in: summary) {
                rates[id] = rate(input, output, read: price("Cached input", in: summary))
            } else if variant.costTier?.caseInsensitiveCompare("Free") == .orderedSame {
                rates[id] = rate(0, 0, read: 0)
            }
        }
        return rates
    }

    // MARK: - Catalog decoding

    private static let cacheTTL: TimeInterval = 24 * 60 * 60
    private static let devinRetryInterval: TimeInterval = 60 * 60
    private static let devinListTimeout: TimeInterval = 10

    private struct CatalogProvider: Decodable {
        var models: [String: CatalogModel]?
    }

    private struct CatalogModel: Decodable {
        var cost: CatalogCost?
    }

    static func decodeCatalog(_ data: Data) throws -> [String: NanoModelRate] {
        flatten(try JSONDecoder().decode([String: CatalogProvider].self, from: data))
    }

    private final class CatalogCost: Decodable {
        var input: Double?
        var output: Double?
        var contextOver200k: CatalogLane?
        var cacheRead: Double?
        var cacheWrite: Double?

        enum CodingKeys: String, CodingKey {
            case input
            case output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
            case contextOver200k = "context_over_200k"
        }
    }

    private typealias CatalogLane = CatalogCost

    private static func flatten(_ providers: [String: CatalogProvider]) -> [String: NanoModelRate] {
        var rates: [String: NanoModelRate] = [:]
        for (providerID, provider) in providers {
            for (modelID, model) in provider.models ?? [:] {
                guard let cost = model.cost, let input = cost.input, let output = cost.output,
                      input.isFinite, output.isFinite, input >= 0, output >= 0 else {
                    continue
                }
                var rate = NanoModelRate(
                    base: NanoRateLane(perMillionInput: input, perMillionOutput: output, cacheRead: cost.cacheRead, cacheWrite: cost.cacheWrite, cacheWrite1h: providerID == "anthropic" ? input * 2 : nil)
                )
                if let lane = cost.contextOver200k, let over = lane.input, let overOut = lane.output {
                    rate.longContext = NanoRateLane(perMillionInput: over, perMillionOutput: overOut, cacheRead: lane.cacheRead, cacheWrite: lane.cacheWrite, cacheWrite1h: providerID == "anthropic" ? over * 2 : nil)
                }
                rates["\(providerID.lowercased())|\(modelID.lowercased())"] = rate
            }
        }
        return rates
    }

    // MARK: - Disk cache

    private struct CachedCatalog: Codable {
        var schemaVersion: Int = 2
        var fetchedAt: Date
        var rates: [String: NanoModelRate]
    }

    private static var cacheURL: URL? {
        try? NanoStorage.directory("pricing").appendingPathComponent("models-dev.json")
    }

    private static var devinCacheURL: URL? {
        try? NanoStorage.directory("pricing").appendingPathComponent("devin-models.json")
    }

    private static func readCache(url: URL? = cacheURL) -> CachedCatalog? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        guard let cache = try? JSONDecoder().decode(CachedCatalog.self, from: data), cache.schemaVersion == 2 else { return nil }
        return cache
    }

    private static func writeCache(_ cache: CachedCatalog, to url: URL? = cacheURL) {
        guard let url, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Fingerprint

    /// SHA-256 over the formula version, the bundled fallback table, and the
    /// catalog entries Nano can actually price against (the providers reachable
    /// through `providerAliases`). Changes whenever any of those change.
    private static func makeFingerprint(
        catalog: [String: NanoModelRate],
        devinCard: [String: NanoModelRate] = [:]
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("formula:\(costFormulaVersion)".utf8))

        for key in fallbackTable.keys.sorted() {
            guard let rate = fallbackTable[key] else { continue }
            hasher.update(data: Data("fallback:\(key):\(describe(rate))".utf8))
        }

        let tracked = Set(providerAliases.values)
        let usable = catalog.keys.filter { key in
            guard let provider = key.split(separator: "|").first else { return false }
            return tracked.contains(String(provider))
        }
        for key in usable.sorted() {
            guard let rate = catalog[key] else { continue }
            hasher.update(data: Data("catalog:\(key):\(describe(rate))".utf8))
        }
        for key in devinCard.keys.sorted() {
            guard let rate = devinCard[key] else { continue }
            hasher.update(data: Data("devin:\(key):\(describe(rate))".utf8))
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func describe(_ rate: NanoModelRate) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(rate)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}
