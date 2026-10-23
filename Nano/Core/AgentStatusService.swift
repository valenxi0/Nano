import AppKit
import Darwin
import Dispatch
import Foundation

struct AgentAccentComponents: Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
}

enum AgentProviderID: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex
    case claude
    case cursor
    case copilot
    case gemini
    case amp
    case opencode
    case pi
    case windsurf
    case kiro
    case factory
    case augment
    case ollama
    case openai
    case azureopenai
    case clinepass
    case opencodego
    case alibaba
    case alibabatokenplan
    case antigravity
    case devin
    case zai
    case minimax
    case manus
    case kimi
    case kilo
    case vertexai
    case jetbrains
    case moonshot
    case t3chat
    case synthetic
    case warp
    case openrouter
    case elevenlabs
    case zed
    case perplexity
    case mimo
    case doubao
    case sakana
    case abacus
    case mistral
    case deepseek
    case deepinfra
    case codebuff
    case crof
    case venice
    case commandcode
    case qoder
    case stepfun
    case bedrock
    case grok
    case groq
    case llmproxy
    case litellm
    case deepgram
    case poe
    case chutes
    case neuralwatt
    case clawrouter
    case longcat
    case sub2api
    case wayfinder
    case zenmux
    case aiand
    case cline
    case qwen
    case goose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .copilot: "GitHub Copilot"
        case .gemini: "Gemini"
        case .amp: "Amp"
        case .opencode: "OpenCode"
        case .pi: "Pi"
        case .grok: "Grok"
        case .windsurf: "Windsurf"
        case .kiro: "Kiro"
        case .factory: "Factory"
        case .augment: "Augment"
        case .ollama: "Ollama"
        default: Self.additionalDisplayNames[self] ?? rawValue.capitalized
        }
    }

    var symbol: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        case .cursor: "cursorarrow.rays"
        case .copilot: "point.3.connected.trianglepath.dotted"
        case .gemini: "diamond.fill"
        case .amp: "bolt.fill"
        case .opencode: "terminal.fill"
        case .pi: "apple.terminal"
        case .grok: "sparkle"
        case .windsurf: "wind"
        case .kiro: "wand.and.stars"
        case .factory: "building.2.fill"
        case .augment: "plus.forwardslash.minus"
        case .ollama: "server.rack"
        default: "sparkle"
        }
    }

    /// Stable provider identity shared by every working-state surface.
    /// Activity changes the copy and symbol, never the provider's color.
    var accentComponents: AgentAccentComponents {
        switch self {
        case .codex: AgentAccentComponents(red: 0.36, green: 0.55, blue: 0.98)
        case .claude: AgentAccentComponents(red: 0.86, green: 0.42, blue: 0.28)
        case .cursor: AgentAccentComponents(red: 0.78, green: 0.82, blue: 0.94)
        case .copilot: AgentAccentComponents(red: 0.42, green: 0.78, blue: 0.62)
        case .gemini: AgentAccentComponents(red: 0.52, green: 0.42, blue: 0.98)
        case .amp: AgentAccentComponents(red: 0.98, green: 0.76, blue: 0.32)
        case .opencode: AgentAccentComponents(red: 0.98, green: 0.55, blue: 0.26)
        case .grok: AgentAccentComponents(red: 0.96, green: 0.78, blue: 0.38)
        case .kimi: AgentAccentComponents(red: 0.28, green: 0.58, blue: 0.98)
        case .pi: AgentAccentComponents(red: 0.98, green: 0.56, blue: 0.22)
        case .windsurf: AgentAccentComponents(red: 0.40, green: 0.80, blue: 0.85)
        case .ollama: AgentAccentComponents(red: 0.78, green: 0.55, blue: 0.95)
        case .devin: AgentAccentComponents(red: 0.27, green: 0.71, blue: 0.51)
        case .cline: AgentAccentComponents(red: 0.56, green: 0.61, blue: 0.69)
        case .qwen: AgentAccentComponents(red: 0.42, green: 0.24, blue: 0.90)
        case .kilo: AgentAccentComponents(red: 0.36, green: 0.80, blue: 0.78)
        case .goose: AgentAccentComponents(red: 0.87, green: 0.84, blue: 0.74)
        default: AgentAccentComponents(red: 0.66, green: 0.68, blue: 0.75)
        }
    }

    /// The agents Nano ships support for.
    ///
    /// The enum still carries every provider we know of, but listing 63 of them
    /// in Settings implied support that does not exist - several had no scanner
    /// and no adapter, so enabling them did nothing. The first row has live
    /// hooks (`NanoOnboardingPlan.agentProviders`) plus a token scanner, a usage
    /// adapter, or both. The second row is batch one of the CLI expansion:
    /// presence and token scanning, no hooks, no quota.
    static let supported: [AgentProviderID] = [
        .claude, .codex, .cursor, .gemini, .grok, .kimi, .opencode, .pi,
        .devin, .cline, .qwen, .kilo, .goose,
    ]

    /// Maps a vendor string from a harness log onto a provider Nano knows.
    ///
    /// OpenCode records the vendor behind each message, not itself, so rows
    /// arrive tagged `moonshotai` or `kimi-for-coding`. Those are real and were
    /// being counted, but they matched no provider, so the per-agent breakdown
    /// silently dropped them while the totals included them.
    static func normalize(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let slug = raw.lowercased()

        if let exact = AgentProviderID(rawValue: slug) { return exact.rawValue }

        for (needles, provider) in [
            (["moonshot", "kimi"], AgentProviderID.kimi),
            (["anthropic", "claude"], .claude),
            (["openai", "codex", "gpt"], .codex),
            (["google", "gemini"], .gemini),
            (["xai", "grok"], .grok),
            (["cursor"], .cursor),
        ] where needles.contains(where: slug.contains) {
            return provider.rawValue
        }
        return slug
    }

    /// Hook `--source` (and optional vendor `providerID`) onto a Nano agent.
    /// Cursor, Grok, and the rest used to collapse to Claude here, which is
    /// why only Codex ever lit the working chip.
    static func fromHook(source: String, providerID: String? = nil) -> AgentProviderID? {
        if let providerID, let id = normalize(providerID).flatMap(AgentProviderID.init(rawValue:)) {
            return id
        }
        return normalize(source).flatMap(AgentProviderID.init(rawValue:))
            ?? AgentProviderID(rawValue: source.lowercased())
    }

    /// Whether Nano can read a remaining-quota figure for this provider.
    /// Token counting works from local logs regardless. Pi and Goose are BYOK
    /// and Qwen Code publishes no quota, so Usage stays off for those.
    var supportsUsage: Bool {
        switch self {
        case .codex, .claude, .cursor, .kimi, .grok,
             .devin, .kilo, .gemini, .cline, .opencode: true
        default: false
        }
    }

    /// Why the Usage toggle stays off for a provider, for its Settings
    /// tooltip. The generic case keeps the old wording.
    var usageUnavailableHelp: String {
        switch self {
        case .pi:
            "Pi runs on your own provider keys — their quota shows under that provider."
        case .goose:
            "Goose runs on your own provider keys — their quota shows under that provider."
        case .qwen:
            "Qwen Code does not publish a quota Nano can read."
        default:
            "\(title) does not publish a quota Nano can read"
        }
    }

    private static let additionalDisplayNames: [AgentProviderID: String] = [
        .openai: "OpenAI API",
        .azureopenai: "Azure OpenAI",
        .clinepass: "Cline Pass",
        .opencodego: "OpenCode Go",
        .alibaba: "Alibaba Cloud",
        .alibabatokenplan: "Alibaba Token Plan",
        .antigravity: "Antigravity",
        .devin: "Devin",
        .cline: "Cline",
        .qwen: "Qwen Code",
        .goose: "Goose",
        .zai: "Z.AI",
        .minimax: "MiniMax",
        .manus: "Manus",
        .kimi: "Kimi",
        .kilo: "Kilo Code",
        .vertexai: "Vertex AI",
        .jetbrains: "JetBrains AI",
        .moonshot: "Moonshot",
        .t3chat: "T3 Chat",
        .synthetic: "Synthetic",
        .warp: "Warp",
        .openrouter: "OpenRouter",
        .elevenlabs: "ElevenLabs",
        .zed: "Zed",
        .perplexity: "Perplexity",
        .mimo: "MiMo",
        .doubao: "Doubao",
        .sakana: "Sakana",
        .abacus: "Abacus",
        .mistral: "Mistral",
        .deepseek: "DeepSeek",
        .deepinfra: "DeepInfra",
        .codebuff: "Codebuff",
        .crof: "Crof",
        .venice: "Venice",
        .commandcode: "Command Code",
        .qoder: "Qoder",
        .stepfun: "StepFun",
        .bedrock: "Amazon Bedrock",
        .grok: "Grok",
        .groq: "Groq",
        .llmproxy: "LLM Proxy",
        .litellm: "LiteLLM",
        .deepgram: "Deepgram",
        .poe: "Poe",
        .chutes: "Chutes",
        .neuralwatt: "NeuralWatt",
        .clawrouter: "ClawRouter",
        .longcat: "LongCat",
        .sub2api: "Sub2API",
        .wayfinder: "Wayfinder",
        .zenmux: "ZenMux",
        .aiand: "ai&",
    ]
}

struct AgentProviderSnapshot: Identifiable, Equatable, Sendable {
    let id: AgentProviderID
    let isConfigured: Bool
    let isActive: Bool
    let projectName: String?
    let lastActivityAt: Date?
    let usage: [NanoUsageWindow]
    let usageMessage: String?
    /// False when the provider grants no included quota, so the UI can skip a
    /// row of meaningless "100% left" gauges.
    var hasQuota = false
    /// Plan name straight from the provider's API.
    var planName: String?
    var activityDetail: String?
}

    /// Providers Nano can read a live quota for.
    private let usageCapableProviders = Set(
        AgentProviderID.supported.filter(\.supportsUsage))

private struct LocalProviderScan: Sendable {
    let snapshot: AgentProviderSnapshot
    let activityFileURL: URL?
}

private struct LocalProviderEvidence: Sendable {
    let configured: Bool
    let isActive: Bool
    let projectName: String?
    let lastActivityAt: Date?
    let activityFileURL: URL?
    let activityDetail: String?
}

@MainActor
final class AgentStatusService: ObservableObject {
    @Published private(set) var snapshots: [AgentProviderSnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?

    var activityDidChange: ((Bool) -> Void)?
    /// After a usage refresh finishes, so token ingest can follow the same
    /// cadence as the quota pill without a second timer.
    var usageDidRefresh: (() -> Void)?

    private var refreshTask: Task<Void, Never>?
    private var activityRefreshTask: Task<Void, Never>?
    private var activityFileSources: [AgentProviderID: DispatchSourceFileSystemObject] = [:]
    private var activityFileURLs: [AgentProviderID: URL] = [:]
    private var selectedProviders: Set<AgentProviderID> = [.codex, .claude]

    /// Set the first time a hook event arrives. Until then the user may not have
    /// granted hook installation at all, so polling stays on its short interval.
    private var isHookDriven = false
    private var trailingRefreshTask: Task<Void, Never>?
    private var claudeUsageDirectorySource: DispatchSourceFileSystemObject?
    private var claudeUsageDirectoryFD: Int32 = -1
    private var claudeCacheRefreshTask: Task<Void, Never>?

    /// A turn boundary is worth an immediate call. Mid-turn tool traffic earns
    /// one no more often than the old poll did, so an active agent is never
    /// staler than before while an idle machine costs nothing.
    private static let turnEndCooldown: TimeInterval = 15
    private static let workingCooldown: TimeInterval = 120

    var hasActiveAgent: Bool {
        snapshots.contains(where: \.isActive)
    }

    /// Providers the user has opted into live-quota lookups for. Empty means
    /// Nano never reaches for a credential.
    private var usageProviders: Set<AgentProviderID> = []

    /// Internal visibility for deterministic configuration tests.
    var configuredUsageProviders: Set<AgentProviderID> { usageProviders }

    func activate(providers: Set<AgentProviderID>, usage: Set<AgentProviderID> = []) {
        selectedProviders = providers
        usageProviders = usage
        configureClaudeUsageMonitoring()
        refresh()
    }

    /// Applies a Settings change without restarting hook and file monitoring.
    /// A plain `refresh()` would keep using the configuration captured by the
    /// last `activate()` call.
    func updateUsageProviders(_ usage: Set<AgentProviderID>) {
        usageProviders = usage
        configureClaudeUsageMonitoring()
        refresh()
    }

    func deactivate() {
        cancelRefresh()
        activityRefreshTask?.cancel()
        activityRefreshTask = nil
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil
        claudeCacheRefreshTask?.cancel()
        claudeCacheRefreshTask = nil
        stopClaudeUsageMonitoring()
        isHookDriven = false
        stopActivityFileMonitoring()
    }

    private func configureClaudeUsageMonitoring() {
        guard usageProviders.contains(.claude) else {
            stopClaudeUsageMonitoring()
            return
        }
        guard claudeUsageDirectorySource == nil else { return }
        let directory = ClaudeStatusBridge().cacheURL.deletingLastPathComponent()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        claudeUsageDirectoryFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.claudeCacheRefreshTask?.cancel()
            self.claudeCacheRefreshTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.claudeCacheRefreshTask = nil
                self?.refresh()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.claudeUsageDirectoryFD >= 0 {
                close(self.claudeUsageDirectoryFD)
                self.claudeUsageDirectoryFD = -1
            }
        }
        claudeUsageDirectorySource = source
        source.resume()
    }

    private func stopClaudeUsageMonitoring() {
        claudeUsageDirectorySource?.cancel()
        claudeUsageDirectorySource = nil
        if claudeUsageDirectoryFD >= 0 {
            close(claudeUsageDirectoryFD)
            claudeUsageDirectoryFD = -1
        }
    }

    /// Quota only moves when an agent does something, so let the agent say when
    /// rather than asking on a fixed schedule.
    func noteHookActivity(_ signal: AgentHookBridge.ActivitySignal) {
        isHookDriven = true
        let cooldown = signal == .turnEnded ? Self.turnEndCooldown : Self.workingCooldown

        guard !isRefreshing else {
            // Parallel sessions finish together. Coalesce the burst into one
            // trailing call instead of dropping it, or the last turn to end
            // is the one whose usage never lands.
            if signal == .turnEnded { scheduleTrailingRefresh(after: cooldown) }
            return
        }

        let elapsed = lastRefreshedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard elapsed >= cooldown else {
            if signal == .turnEnded { scheduleTrailingRefresh(after: cooldown - elapsed) }
            return
        }
        refresh()
    }

    private func scheduleTrailingRefresh(after delay: TimeInterval) {
        guard trailingRefreshTask == nil else { return }
        trailingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(delay, 0)))
            guard !Task.isCancelled else { return }
            self?.trailingRefreshTask = nil
            self?.refresh()
        }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    func refresh() {
        cancelRefresh()
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil
        let providers = selectedProviders
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        isRefreshing = true

        refreshTask = Task {
            defer { if !Task.isCancelled { isRefreshing = false } }

            let localScans = await Task.detached(priority: .utility) {
                Self.scanLocalProviders(
                    providers,
                    runningBundleIDs: runningBundleIDs
                )
            }.value
            guard !Task.isCancelled else { return }

            // Publish the local scan before fetching usage. The scan is local
            // and instant; usage is two network calls with 20s timeouts, and
            // holding the provider rows hostage to them left the island with
            // nothing to show for the first several seconds.
            snapshots = localScans.map(\.snapshot).sorted {
                guard $0.isActive == $1.isActive else { return $0.isActive && !$1.isActive }
                return AgentProviderID.allCases.firstIndex(of: $0.id)!
                    < AgentProviderID.allCases.firstIndex(of: $1.id)!
            }

            var merged = localScans.map(\.snapshot)
            // Opt-in only: an untouched install makes no network calls and
            // raises no credential prompts. Fetch every enabled provider
            // together so Verifying covers Claude, Cursor, and Codex at once.
            await withTaskGroup(of: (Int, AgentUsageResult).self) { group in
                for index in merged.indices where usageProviders.contains(merged[index].id) {
                    let id = merged[index].id
                    group.addTask {
                        (index, await Self.fetchUsage(for: id))
                    }
                }
                for await (index, usage) in group {
                    guard !Task.isCancelled else { return }
                    merged[index] = AgentProviderSnapshot(
                        id: merged[index].id,
                        isConfigured: merged[index].isConfigured,
                        isActive: merged[index].isActive,
                        projectName: merged[index].projectName,
                        lastActivityAt: merged[index].lastActivityAt,
                        usage: usage.windows,
                        usageMessage: usage.message,
                        hasQuota: usage.hasQuota,
                        planName: usage.planName,
                        activityDetail: merged[index].activityDetail
                    )
                }
            }
            guard !Task.isCancelled else { return }

            snapshots = merged.sorted {
                guard $0.isActive == $1.isActive else { return $0.isActive && !$1.isActive }
                return AgentProviderID.allCases.firstIndex(of: $0.id)!
                    < AgentProviderID.allCases.firstIndex(of: $1.id)!
            }
            updateActivityFileMonitoring(
                Dictionary(
                    uniqueKeysWithValues: localScans.compactMap { scan in
                        scan.activityFileURL.map { (scan.snapshot.id, $0) }
                    }
                )
            )
            activityDidChange?(snapshots.contains(where: \.isActive))
            lastRefreshedAt = Date()
            usageDidRefresh?()
        }
    }

    /// Applies hook-derived liveness to the provider snapshots.
    ///
    /// The other half of removing the poll. `isActive` and `activityDetail`
    /// used to be produced by scanning; dropping the scan without supplying
    /// them from hooks left the compact island blank and `hasActiveAgent`
    /// permanently false, which reads as "cheap" but is really "off".
    func applyHookActivity(_ states: [String: AgentHookBridge.LiveSessionState]) {
        guard !snapshots.isEmpty else { return }

        let now = Date()
        let newest = Self.representativeHookStates(states, now: now)

        var updated = snapshots
        var changed = false

        for index in updated.indices {
            guard let state = newest[updated[index].id] else { continue }

            // A turn that ended is not activity, but it stays fresh briefly so
            // the strip does not blink out between tool calls.
            let fresh = now.timeIntervalSince(state.lastEventAt) < Self.activityFreshnessWindow
            let active = state.isWorking && fresh
            let detail = active ? Self.hookActivityDetail(from: state) : nil

            guard updated[index].isActive != active
                    || updated[index].activityDetail != detail
            else { continue }

            changed = true
            updated[index] = AgentProviderSnapshot(
                id: updated[index].id,
                isConfigured: updated[index].isConfigured,
                isActive: active,
                projectName: state.workingDirectory
                    .map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? updated[index].projectName,
                lastActivityAt: state.lastEventAt,
                usage: updated[index].usage,
                usageMessage: updated[index].usageMessage,
                hasQuota: updated[index].hasQuota,
                planName: updated[index].planName,
                activityDetail: detail
            )
        }

        guard changed else { return }
        snapshots = updated.sorted {
            guard $0.isActive == $1.isActive else { return $0.isActive && !$1.isActive }
            return $0.id.title < $1.id.title
        }
        activityDidChange?(snapshots.contains(where: \.isActive))
    }

    /// The island reports the agent, not each session, so several sessions of
    /// one provider fold into one snapshot. A provider is working while any of
    /// its sessions is; the newest working session supplies the detail.
    /// Picking the newest event regardless of state let one session's `stop`
    /// blank the provider while a sibling was mid-turn.
    nonisolated static func representativeHookStates(
        _ states: [String: AgentHookBridge.LiveSessionState],
        now: Date = Date()
    ) -> [AgentProviderID: AgentHookBridge.LiveSessionState] {
        func rank(_ state: AgentHookBridge.LiveSessionState) -> (Int, Date) {
            let working = state.isWorking
                && now.timeIntervalSince(state.lastEventAt) < activityFreshnessWindow
            return (working ? 1 : 0, state.lastEventAt)
        }
        var newest: [AgentProviderID: AgentHookBridge.LiveSessionState] = [:]
        for state in states.values {
            guard let provider = AgentProviderID.fromHook(
                source: state.source,
                providerID: state.providerID
            ) else { continue }
            if let existing = newest[provider], rank(existing) >= rank(state) { continue }
            newest[provider] = state
        }
        return newest
    }

    /// Providers whose liveness is arriving over hooks. Recovery scans can
    /// exclude them rather than re-deriving the same state from transcripts.
    private var hookCoveredProviders: Set<AgentProviderID> = []

    func noteHookCoverage(_ providers: Set<AgentProviderID>) {
        let completeProviders = Self.providersWithCompleteHookCoverage(providers)
        guard completeProviders != hookCoveredProviders else { return }
        hookCoveredProviders = completeProviders
    }

    /// Cursor hooks can omit the session id and miss IDE lifecycle edges.
    /// Keep its transcript fallback alive even after a Cursor hook arrives.
    nonisolated static func providersWithCompleteHookCoverage(
        _ providers: Set<AgentProviderID>
    ) -> Set<AgentProviderID> {
        providers.subtracting([.cursor])
    }

    /// Called by the shared directory watcher and its 12-minute integrity pass.
    /// Known transcript writes use the cheaper per-file watcher below.
    func refreshLocalActivity() {
        guard !snapshots.isEmpty else { return }

        // Hook-covered providers are already reporting; scanning them again
        // would be the same answer at a much higher price.
        let providers = selectedProviders.subtracting(hookCoveredProviders)
        guard !providers.isEmpty else { return }
        let runningBundleIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )

        activityRefreshTask?.cancel()
        activityRefreshTask = Task {
            let scans = await Task.detached(priority: .utility) {
                Self.scanLocalProviders(providers, runningBundleIDs: runningBundleIDs)
            }.value
            guard !Task.isCancelled else { return }
            applyActivity(from: scans)
        }
    }

    private func applyActivity(from scans: [LocalProviderScan]) {
        var updated = snapshots
        var changed = false

        // Switch watchers even when the display fields happen to be identical;
        // otherwise a newly-created session can remain attached to the previous
        // transcript until some unrelated label changes.
        updateActivityFileMonitoring(
            Dictionary(
                uniqueKeysWithValues: scans.compactMap { scan in
                    scan.activityFileURL.map { (scan.snapshot.id, $0) }
                }
            )
        )

        for scan in scans {
            guard let index = updated.firstIndex(where: { $0.id == scan.snapshot.id }) else {
                continue
            }

            let existing = updated[index]
            guard existing.isActive != scan.snapshot.isActive
                    || existing.activityDetail != scan.snapshot.activityDetail
                    || existing.projectName != scan.snapshot.projectName
            else {
                continue
            }

            changed = true
            updated[index] = AgentProviderSnapshot(
                id: existing.id,
                isConfigured: existing.isConfigured,
                isActive: scan.snapshot.isActive,
                projectName: scan.snapshot.projectName,
                lastActivityAt: scan.snapshot.lastActivityAt,
                usage: existing.usage,
                usageMessage: existing.usageMessage,
                hasQuota: existing.hasQuota,
                planName: existing.planName,
                activityDetail: scan.snapshot.activityDetail
            )
        }

        guard changed else { return }

        snapshots = updated.sorted {
            guard $0.isActive == $1.isActive else { return $0.isActive && !$1.isActive }
            return $0.id.title < $1.id.title
        }

        activityDidChange?(snapshots.contains(where: \.isActive))
    }

    nonisolated private static func scanLocalProviders(
        _ selectedProviders: Set<AgentProviderID>,
        runningBundleIDs: Set<String>
    ) -> [LocalProviderScan] {
        selectedProviders.map { provider in
            let evidence = localEvidence(
                for: provider,
                runningBundleIDs: runningBundleIDs
            )
            return LocalProviderScan(
                snapshot: AgentProviderSnapshot(
                    id: provider,
                    isConfigured: evidence.configured,
                    isActive: evidence.isActive,
                    projectName: evidence.projectName,
                    lastActivityAt: evidence.lastActivityAt,
                    usage: [],
                    usageMessage: usageCapableProviders.contains(provider)
                        ? "Usage not refreshed yet"
                        : "Usage adapter not configured",
                    activityDetail: evidence.activityDetail
                ),
                activityFileURL: evidence.activityFileURL
            )
        }
    }

    nonisolated private static func localEvidence(
        for provider: AgentProviderID,
        runningBundleIDs: Set<String>
    ) -> LocalProviderEvidence {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment

        let paths: [URL]
        let appBundleIDs: Set<String>
        switch provider {
        case .codex:
            let root = AgentRoutes.root(for: provider, home: home, environment: environment)
            paths = [
                root.appendingPathComponent("sessions", isDirectory: true),
                root.appendingPathComponent("session_index.jsonl"),
            ]
            appBundleIDs = ["com.openai.codex"]
        case .claude:
            let root = AgentRoutes.root(for: provider, home: home, environment: environment)
            paths = [
                root.appendingPathComponent("projects", isDirectory: true),
                root.appendingPathComponent(".credentials.json"),
            ]
            appBundleIDs = []
        case .cursor:
            paths = [AgentRoutes.root(for: provider, home: home, environment: environment)]
            appBundleIDs = ["com.todesktop.230313mzl4w4u92"]
        case .copilot:
            paths = [home.appendingPathComponent(".config/github-copilot", isDirectory: true)]
            appBundleIDs = ["com.microsoft.VSCode"]
        case .gemini:
            paths = [AgentRoutes.root(for: provider, home: home, environment: environment)]
            appBundleIDs = []
        case .amp:
            paths = [home.appendingPathComponent(".config/amp", isDirectory: true)]
            appBundleIDs = []
        case .opencode:
            paths = [
                AgentRoutes.root(for: provider, home: home, environment: environment),
                home.appendingPathComponent(".local/share/opencode", isDirectory: true),
            ]
            appBundleIDs = []
        case .pi:
            paths = [
                AgentRoutes.root(for: provider, home: home, environment: environment)
                    .appendingPathComponent("sessions", isDirectory: true),
            ]
            appBundleIDs = []
        case .grok:
            let root = AgentRoutes.root(for: provider, home: home, environment: environment)
            paths = [
                root.appendingPathComponent("sessions", isDirectory: true),
                root.appendingPathComponent("auth.json"),
            ]
            appBundleIDs = []
        case .windsurf:
            paths = [home.appendingPathComponent(".codeium/windsurf", isDirectory: true)]
            appBundleIDs = ["com.exafunction.windsurf"]
        case .kiro:
            paths = [home.appendingPathComponent(".kiro", isDirectory: true)]
            appBundleIDs = ["dev.kiro.desktop"]
        case .factory:
            paths = [home.appendingPathComponent(".factory", isDirectory: true)]
            appBundleIDs = []
        case .augment:
            paths = [home.appendingPathComponent(".augment", isDirectory: true)]
            appBundleIDs = []
        case .ollama:
            paths = [home.appendingPathComponent(".ollama", isDirectory: true)]
            appBundleIDs = ["com.electron.ollama"]
        // Batch-1 CLIs: evidence is the session store, never the root dir —
        // a skills installer can leave `~/.qwen` or `~/.config/goose` behind
        // without the CLI ever having run.
        case .devin:
            // Devin Desktop's bundle id is Windsurf's (`com.exafunction.
            // windsurf`), so the sessions db is the only signal.
            paths = [TokenScanners.devinDatabaseURL(environment: environment, home: home)]
            appBundleIDs = []
        case .cline:
            let dirs = TokenScanners.clineDirectories(environment: environment, home: home)
            paths = [dirs.sessions, dirs.database]
            appBundleIDs = []
        case .qwen:
            paths = [
                TokenScanners.qwenRuntimeDirectory(environment: environment, home: home)
                    .appendingPathComponent("projects", isDirectory: true),
            ]
            appBundleIDs = []
        case .kilo:
            paths = [TokenScanners.kiloDatabaseURL(environment: environment, home: home)]
            appBundleIDs = []
        case .goose:
            paths = TokenScanners.gooseDatabaseURLs(environment: environment, home: home)
            appBundleIDs = []
        default:
            paths = [
                home.appendingPathComponent(".\(provider.rawValue)", isDirectory: true),
                home.appendingPathComponent(
                    ".config/\(provider.rawValue)",
                    isDirectory: true
                ),
            ]
            appBundleIDs = []
        }

        let existingPaths = paths.filter { FileManager.default.fileExists(atPath: $0.path) }
        let newest: (url: URL, modifiedAt: Date)?
        if provider == .cursor,
           let root = existingPaths.first,
           let url = newestCursorActivityFile(in: root),
           let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate {
            newest = (url, modifiedAt)
        } else {
            newest = newestSessionFile(in: existingPaths)
        }
        let cwd = newest.flatMap { extractWorkingDirectory(from: $0.url) }
        let isActive = newest.map {
            $0.modifiedAt > Date().addingTimeInterval(-activityFreshnessWindow)
                && providerHasActiveTask(provider, in: $0.url)
        } ?? false

        return LocalProviderEvidence(
            configured: !existingPaths.isEmpty || !appBundleIDs.isDisjoint(with: runningBundleIDs),
            isActive: isActive,
            projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            lastActivityAt: newest?.modifiedAt,
            activityFileURL: newest?.url,
            activityDetail: isActive
                ? newest.flatMap { latestActivity(provider, in: $0.url) }
                : nil
        )
    }

    nonisolated static func activityLabel(for provider: AgentProviderID, url: URL?) -> String? {
        guard let url else { return nil }
        return latestActivity(provider, in: url)
    }

    /// Walks the tail newest-first and stops at the first line that yields an
    /// activity. Both extractors already returned on their first match, but the
    /// whole window was decoded up front to get there — an 8MB `JSONSerialization`
    /// pass every 5 seconds, per provider, to read the last few events.
    nonisolated private static func latestActivity(
        _ provider: AgentProviderID,
        in url: URL
    ) -> String? {
        guard provider == .codex || provider == .claude || provider == .cursor,
              let lines = recentLines(in: url, maximumBytes: 256 * 1_024)
        else {
            return nil
        }

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            let activity = provider == .codex
                ? codexActivity(record)
                : claudeActivity(record)
            if let activity { return activity }
        }

        return nil
    }

    nonisolated private static func codexActivity(_ record: [String: Any]) -> String? {
        do {
            guard record["type"] as? String == "event_msg",
                  let payload = record["payload"] as? [String: Any],
                  let event = payload["type"] as? String
            else {
                return nil
            }

            switch event {
            case "patch_apply_begin", "patch_apply_end":
                if let changes = payload["changes"] as? [String: Any],
                   let path = changes.keys.sorted().first {
                    return "Editing \(URL(fileURLWithPath: path).lastPathComponent)"
                }
                if let stdout = payload["stdout"] as? String,
                   let line = stdout.components(separatedBy: "\n").first(where: { $0.hasPrefix("M ") || $0.hasPrefix("A ") }) {
                    let path = String(line.dropFirst(2))
                    return "Editing \(URL(fileURLWithPath: path).lastPathComponent)"
                }
                return "Editing files"
            case "exec_command_begin", "exec_command_end":
                if let command = payload["command"] as? [String], let first = command.first {
                    return "Running \(URL(fileURLWithPath: first).lastPathComponent)"
                }
                if let command = payload["command"] as? String,
                   let first = command.split(separator: " ").first {
                    return "Running \(first)"
                }
                return "Running a command"
            case "mcp_tool_call_begin", "mcp_tool_call_end":
                guard let invocation = payload["invocation"] as? [String: Any] else {
                    return "Using a tool"
                }
                let server = invocation["server"] as? String
                let tool = invocation["tool"] as? String
                return "Using \([server, tool].compactMap { $0 }.joined(separator: " · "))"
            case "web_search_begin", "web_search_end":
                return "Searching the web"
            case "agent_reasoning", "agent_reasoning_delta":
                return "Thinking"
            case "agent_message", "agent_message_delta":
                return "Writing a response"
            case "task_started":
                return "Working"
            default:
                return nil
            }
        }
    }

    nonisolated private static func claudeActivity(_ record: [String: Any]) -> String? {
        do {
            guard let message = record["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else {
                return nil
            }

            for block in content.reversed() {
                guard block["type"] as? String == "tool_use",
                      let name = block["name"] as? String
                else {
                    continue
                }

                let input = block["input"] as? [String: Any] ?? [:]
                let file = (input["file_path"] as? String)
                    .map { URL(fileURLWithPath: $0).lastPathComponent }

                switch name {
                case "Edit", "Write", "NotebookEdit":
                    return file.map { "Editing \($0)" } ?? "Editing files"
                case "Read":
                    return file.map { "Reading \($0)" } ?? "Reading files"
                case "Bash":
                    if let description = input["description"] as? String, !description.isEmpty {
                        return description
                    }
                    if let command = input["command"] as? String,
                       let first = command.split(separator: " ").first {
                        return "Running \(first)"
                    }
                    return "Running a command"
                case "Grep", "Glob":
                    return (input["pattern"] as? String).map { "Searching \($0)" } ?? "Searching files"
                case "WebFetch", "WebSearch":
                    return "Searching the web"
                case "Task", "Agent":
                    return "Delegating to a subagent"
                default:
                    return "Using \(name)"
                }
            }
        }

        return nil
    }

    nonisolated private static let activityFreshnessWindow: TimeInterval = 120

    /// Same vocabulary as the Codex/Claude transcript scanners, so the chip
    /// symbol and "Writing a response" fallback work for every hook source.
    nonisolated static func hookActivityDetail(
        from state: AgentHookBridge.LiveSessionState
    ) -> String {
        if let detail = state.lastToolInputDescription, !detail.isEmpty {
            return presentTenseActivity(detail)
        }
        if let tool = state.lastTool, !tool.isEmpty {
            return "Using \(tool)"
        }
        return "Writing a response"
    }

    nonisolated private static func presentTenseActivity(_ detail: String) -> String {
        let mappings = [
            ("Edited ", "Editing "),
            ("Wrote ", "Editing "),
            ("Ran ", "Running "),
            ("Read ", "Reading "),
            ("Searched ", "Searching "),
            ("Fetched ", "Searching "),
            ("Delegated ", "Delegating "),
            ("Updated ", "Writing "),
        ]
        for (past, present) in mappings where detail.hasPrefix(past) {
            return present + detail.dropFirst(past.count)
        }
        return detail
    }

    nonisolated private static func providerHasActiveTask(
        _ provider: AgentProviderID,
        in url: URL
    ) -> Bool {
        switch provider {
        case .codex:
            codexTaskIsActive(in: url)
        case .claude:
            claudeTaskIsActive(in: url)
        case .cursor:
            cursorTaskIsActive(in: url)
        default:
            false
        }
    }

    nonisolated static func codexTaskIsActive(in url: URL) -> Bool {
        codexTaskState(in: url) ?? false
    }

    nonisolated private static func codexTaskState(in url: URL) -> Bool? {
        scanBackwards(in: url, markers: ["\"task_", "\"turn_aborted\""]) { record in
            guard record["type"] as? String == "event_msg",
                  let payload = record["payload"] as? [String: Any],
                  let event = payload["type"] as? String
            else {
                return nil
            }

            switch event {
            case "task_started":
                return true
            case "task_complete", "task_completed", "task_failed", "task_cancelled",
                 "task_canceled", "task_interrupted", "task_stopped", "turn_aborted":
                return false
            default:
                return nil
            }
        }
    }

    nonisolated static func claudeTaskIsActive(in url: URL) -> Bool {
        claudeTaskState(in: url) ?? false
    }

    /// Cursor IDE transcripts end with `turn_ended`. Until that marker lands,
    /// a user or assistant record is an unfinished turn. Some releases omit
    /// the marker, so the outer freshness window supplies the same two-minute
    /// grace period used by the session list before it considers the turn idle.
    nonisolated static func cursorTaskIsActive(in url: URL) -> Bool {
        scanBackwards(in: url, markers: ["turn_ended", "\"role\""]) { record in
            if record["type"] as? String == "turn_ended" { return false }
            switch record["role"] as? String {
            case "user", "assistant": return true
            default: return nil
            }
        } ?? false
    }

    nonisolated private static func claudeTaskState(in url: URL) -> Bool? {
        scanBackwards(in: url, markers: ["\"stop_reason\"", "\"type\":\"user\""]) { record in
            switch record["type"] as? String {
            case "assistant":
                guard let message = record["message"] as? [String: Any],
                      let stopReason = message["stop_reason"] as? String
                else {
                    return nil
                }
                return stopReason == "tool_use"
            case "user":
                return true
            default:
                return nil
            }
        }
    }

    nonisolated private static func providerActivityUpdate(
        _ provider: AgentProviderID,
        in url: URL,
        currentState: Bool
    ) -> Bool {
        switch provider {
        case .codex:
            return codexTaskState(in: url) ?? currentState
        case .claude:
            return claudeTaskState(in: url) ?? currentState
        case .cursor:
            return cursorTaskIsActive(in: url)
        default:
            return false
        }
    }

    /// Walks a session log backwards, decoding one line at a time until
    /// `decide` returns an answer, widening the read window only if it runs out.
    ///
    /// Answers are remembered per file with the byte offset they cover, so a
    /// write only costs a read of the bytes appended since. Re-scanning from the
    /// end on every write was the dominant idle cost: a Codex task started hours
    /// ago sits 38MB back, and every append re-read and decoded all of it.
    ///
    /// `markers` are substrings a deciding line must contain. Lines without one
    /// are skipped undecoded, which keeps multi-megabyte image lines cheap.
    nonisolated private static func scanBackwards<T>(
        in url: URL,
        markers: [String] = [],
        windows: [UInt64] = [256 * 1_024, 4 * 1_024 * 1_024],
        decide: ([String: Any]) -> T?
    ) -> T? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? UInt64) ?? 0
        // Identity guards the cached offset: an atomic rewrite is a new file.
        let identity = (attributes?[.systemFileNumber] as? UInt64) ?? 0
        let key = url.standardizedFileURL.path + "|" + markers.joined(separator: ",")

        func decodeNewestFirst(_ lines: [Substring]) -> T? {
            for line in lines.reversed() {
                if !markers.isEmpty, !markers.contains(where: { line.contains($0) }) { continue }
                guard let data = line.data(using: .utf8),
                      let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                if let value = decide(record) { return value }
            }
            return nil
        }

        // Warm: only the bytes appended since the last answer.
        if let cached = LogScanCache.shared.entry(for: key),
           cached.identity == identity, cached.offset <= size {
            if cached.offset == size { return cached.value as? T }
            // A huge burst of appends is read from its tail only, like a cold scan.
            let cap = windows.last ?? (size - cached.offset)
            let start = size - cached.offset > cap ? size - cap : cached.offset
            guard let (lines, end) = completeLines(in: url, from: start, dropFirst: start > cached.offset)
            else { return cached.value as? T }
            let value = decodeNewestFirst(lines) ?? (cached.value as? T)
            LogScanCache.shared.store(value, offset: end, identity: identity, for: key)
            return value
        }

        // Cold: backwards from the end, widening, capped at the last window.
        var alreadyScanned = 0
        var answer: T?
        var coveredEnd = size
        for window in windows {
            let start = size > window ? size - window : 0
            guard let (lines, end) = completeLines(in: url, from: start, dropFirst: start > 0) else { return nil }
            coveredEnd = end
            let fresh = lines.count - alreadyScanned
            if fresh > 0, let value = decodeNewestFirst(Array(lines.prefix(fresh))) {
                answer = value
                break
            }
            alreadyScanned = lines.count
            if window >= size { break }
        }
        LogScanCache.shared.store(answer, offset: coveredEnd, identity: identity, for: key)
        return answer
    }

    /// Lines in `[start, end of file)`, and the offset just past the last
    /// newline so the next read resumes on a line boundary. A trailing line
    /// without its newline is included (it may be a finished last record) but
    /// not counted as covered, so it is read again once complete.
    nonisolated private static func completeLines(
        in url: URL,
        from start: UInt64,
        dropFirst: Bool
    ) -> ([Substring], UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        let coveredCount = data.lastIndex(of: UInt8(ascii: "\n")).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n")
        if dropFirst, !lines.isEmpty { lines.removeFirst() }
        return (lines, start + UInt64(coveredCount))
    }

    /// Raw tail lines, undecoded. Callers parse only as far back as they need.
    nonisolated private static func recentLines(
        in url: URL,
        maximumBytes: UInt64
    ) -> [Substring]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let length = (try? handle.seekToEnd()) ?? 0
        let offset = length > maximumBytes ? length - maximumBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        var lines = text.split(separator: "\n")
        // A mid-line seek leaves the first line truncated; it would never parse.
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private func updateActivityFileMonitoring(_ urls: [AgentProviderID: URL]) {
        for provider in Array(activityFileSources.keys)
        where activityFileURLs[provider] != urls[provider] {
            activityFileSources.removeValue(forKey: provider)?.cancel()
        }

        activityFileURLs = urls

        for (provider, url) in urls where activityFileSources[provider] == nil {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                // Known-file writes only need a tail check. Cursor used to walk
                // every provider tree on every streamed token; reselect its
                // newest active transcript only after this one actually ends.
                self?.refreshMonitoredActivity()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            activityFileSources[provider] = source
            source.resume()
        }
    }

    private func stopActivityFileMonitoring() {
        for source in activityFileSources.values {
            source.cancel()
        }
        activityFileSources.removeAll()
        activityFileURLs.removeAll()
    }

    private func refreshMonitoredActivity() {
        activityRefreshTask?.cancel()
        let urls = activityFileURLs
        let currentStates = Dictionary(
            uniqueKeysWithValues: snapshots.map { ($0.id, $0.isActive) }
        )

        activityRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }

            let states = await Task.detached(priority: .utility) {
                Dictionary(
                    uniqueKeysWithValues: urls.map { provider, url in
                        (
                            provider,
                            Self.providerActivityUpdate(
                                provider,
                                in: url,
                                currentState: currentStates[provider] ?? false
                            )
                        )
                    }
                )
            }.value
            guard !Task.isCancelled else { return }

            var changed = false
            snapshots = snapshots.map { snapshot in
                guard let isActive = states[snapshot.id], snapshot.isActive != isActive else {
                    return snapshot
                }
                changed = true
                return AgentProviderSnapshot(
                    id: snapshot.id,
                    isConfigured: snapshot.isConfigured,
                    isActive: isActive,
                    projectName: snapshot.projectName,
                    lastActivityAt: snapshot.lastActivityAt,
                    usage: snapshot.usage,
                    usageMessage: snapshot.usageMessage,
                    hasQuota: snapshot.hasQuota,
                    planName: snapshot.planName,
                    activityDetail: isActive
                        ? Self.activityLabel(for: snapshot.id, url: self.activityFileURLs[snapshot.id])
                        : nil
                )
            }

            if changed {
                snapshots.sort {
                    guard $0.isActive == $1.isActive else { return $0.isActive && !$1.isActive }
                    return AgentProviderID.allCases.firstIndex(of: $0.id)!
                        < AgentProviderID.allCases.firstIndex(of: $1.id)!
                }
                activityDidChange?(snapshots.contains(where: \.isActive))
            }
            if currentStates[.cursor] == true, states[.cursor] == false {
                refreshLocalActivity()
            }
        }
    }

    nonisolated private static func newestSessionFile(
        in roots: [URL],
        limit: Int = 500
    ) -> (url: URL, modifiedAt: Date)? {
        var newest: (URL, Date)?
        var visited = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]

        for root in roots {
            guard visited < limit else { break }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                continue
            }

            if !isDirectory.boolValue {
                let values = try? root.resourceValues(forKeys: Set(keys))
                if let date = values?.contentModificationDate {
                    if newest == nil || date > newest!.1 { newest = (root, date) }
                }
                visited += 1
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            while let file = enumerator.nextObject() as? URL, visited < limit {
                visited += 1
                guard ["jsonl", "json"].contains(file.pathExtension.lowercased()) else { continue }
                let values = try? file.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, let date = values?.contentModificationDate else {
                    continue
                }
                if newest == nil || date > newest!.1 { newest = (file, date) }
            }
        }
        return newest
    }

    /// Cursor's project tree also contains frequently rewritten MCP metadata.
    /// Restrict liveness to real agent transcripts, then choose the newest
    /// unfinished turn so one completed session cannot hide another active one.
    nonisolated static func newestCursorActivityFile(in root: URL) -> URL? {
        let projects = root.lastPathComponent == "projects"
            ? root
            : root.appendingPathComponent("projects", isDirectory: true)

        return AgentSessionParsers.cursorTranscriptURLs(in: projects)
            .filter(cursorTaskIsActive)
            .max { lhs, rhs in
                let left = try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                let right = try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                return (left ?? .distantPast) < (right ?? .distantPast)
            }
    }

    nonisolated private static func extractWorkingDirectory(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        let offset = length > 131_072 ? length - 131_072 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let pattern = #""(?:cwd|working_directory|project_path)"\s*:\s*"((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ).last,
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        let escaped = String(text[range])
        return escaped
            .replacingOccurrences(of: #"\/"#, with: "/")
            .replacingOccurrences(of: #"\\\\"#, with: "\\")
    }

    private static func fetchUsage(for provider: AgentProviderID) async -> AgentUsageResult {
        do {
            switch provider {
            case .codex: return try await CodexUsageAdapter.fetch()
            case .claude: return try await ClaudeUsageAdapter.fetch()
            case .cursor: return try await CursorUsageAdapter.fetch()
            case .kimi: return try await KimiUsageAdapter.fetch()
            case .grok: return try await GrokUsageAdapter.fetch()
            case .devin: return try await DevinUsageAdapter.fetch()
            case .kilo: return try await KiloUsageAdapter.fetch()
            case .gemini: return try await GeminiUsageAdapter.fetch()
            case .cline: return try await ClineUsageAdapter.fetch()
            case .opencode: return try await OpenCodeUsageAdapter.fetch()
            default: return .unavailable("Usage adapter not configured")
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}

/// Remembered answers from `scanBackwards`, keyed by file and question.
final class LogScanCache: @unchecked Sendable {
    static let shared = LogScanCache()
    private let lock = NSLock()
    private var entries: [String: (value: Any?, offset: UInt64, identity: UInt64)] = [:]

    func entry(for key: String) -> (value: Any?, offset: UInt64, identity: UInt64)? {
        lock.withLock { entries[key] }
    }

    func store(_ value: Any?, offset: UInt64, identity: UInt64, for key: String) {
        lock.withLock {
            // Bounded: one entry per watched log and question.
            if entries.count > 64 { entries.removeAll() }
            entries[key] = (value, offset, identity)
        }
    }
}
