import CryptoKit
import Foundation

// Agents push their own events to Nano instead of Nano hunting through logs.
//
// A small shell bridge is installed into each agent's hook configuration and
// writes one JSON line per event to a Unix socket. This is what lets Nano see
// a session no matter who launched it — a terminal, a script, or an IDE like
// T3 Code that spawns the CLI with no terminal attached, which process-watching
// tools miss entirely.
//
// Permission events block: the agent waits on the bridge while Nano asks the
// user, and the user's answer becomes the hook's stdout.

@MainActor
final class AgentHookBridge: ObservableObject {
    enum RequestKind: String, Sendable {
        case permission
        case question
        case notification
        case completion
    }

    struct Option: Identifiable, Equatable, Sendable {
        let id: Int
        let label: String
    }

    struct PendingRequest: Identifiable, Equatable, Sendable {
        let id: String
        let source: String
        let kind: RequestKind
        let title: String
        let detail: String?
        let options: [Option]
        let sessionID: String?
        let receivedAt: Date
        /// True only when this card owns a blocked hook continuation that Nano
        /// can answer. Providers also emit delayed "needs input" notifications;
        /// those should stay visible, but their notification hook cannot carry
        /// a decision back to the agent.
        let respondsThroughBridge: Bool
        /// What the agent is about to do, shown so the decision can be made
        /// from the island rather than by switching to the terminal to look.
        var preview: Preview
        var projectName: String?
        /// Set once the card has been answered. The card stays up briefly
        /// to say so; a card that vanishes on the tap looks like it did
        /// nothing, and the host's own prompt may still be on screen.
        var outcome: Outcome?

        var isResolved: Bool { outcome != nil }

        init(
            id: String,
            source: String,
            kind: RequestKind,
            title: String,
            detail: String?,
            options: [Option],
            sessionID: String?,
            receivedAt: Date,
            respondsThroughBridge: Bool? = nil,
            preview: Preview = .none,
            projectName: String? = nil
        ) {
            self.id = id
            self.source = source
            self.kind = kind
            self.title = title
            self.detail = detail
            self.options = options
            self.sessionID = sessionID
            self.receivedAt = receivedAt
            self.respondsThroughBridge = respondsThroughBridge
                ?? (kind == .permission || kind == .question)
            self.preview = preview
            self.projectName = projectName
        }
    }

    /// How an answerable permission card ended.
    enum Outcome: Equatable, Sendable {
        /// Nano's answer reached the hook while it was still waiting, so it
        /// is the answer that counts: the agent kills the hook as soon as it
        /// has a decision from anywhere else.
        case allowed
        case denied
        /// The hook died before Nano answered. The host, or an auto-approve,
        /// got there first.
        case answeredElsewhere
    }

    /// The last answer Nano sent for a session, for the row to confirm.
    struct DecisionNote: Equatable, Sendable {
        let allowed: Bool
        let at: Date
    }

    /// A decision needs its subject on screen. "Claude wants to run Bash" tells
    /// you nothing; the command, or the lines about to change, tells you
    /// everything.
    enum Preview: Equatable, Sendable {
        case none
        case command(String)
        /// `startLine` is where the change sits in the file, when the file
        /// could be read; without it the lines are numbered from 1.
        case diff(path: String, removed: [String], added: [String], startLine: Int? = nil)
        /// Markdown from Claude's `ExitPlanMode`: the plan waiting for approval.
        case plan(String)
        /// A tool's own arguments as "name: value" lines (MCP tools).
        case arguments([String])

        var isEmpty: Bool {
            if case .none = self { return true }
            return false
        }
    }

    /// How strongly a hook event implies quota just moved.
    enum ActivitySignal: Sendable {
        /// A turn finished or context was compacted. Usage has definitely
        /// changed and will not change again until the user speaks.
        case turnEnded
        /// Mid-turn tool traffic. Usage is moving, but with no boundary to
        /// latch onto, so acting on every one of these would be worse than a poll.
        case working
    }

    /// Fired for every hook event, ahead of any request handling.
    var didSignalActivity: ((ActivitySignal) -> Void)?

    /// An agent is blocked waiting on the user. The island opens for this: the
    /// agent is doing nothing until it is answered, and a card nobody sees is
    /// the same as no card.
    var didRequestAttention: ((PendingRequest) -> Void)?

    /// A turn finished. Announced rather than expanded - this happens after
    /// every response, and an island that drops open each time would be worse
    /// than no island.
    var didFinishTurn: ((String?) -> Void)?

    /// The user spoke again in a session. This resolves delayed provider
    /// notifications such as `idle_prompt` without touching a real permission
    /// request that is still blocked inside the bridge.
    var didResumeSession: ((String) -> Void)?

    @Published private(set) var pending: [PendingRequest] = []
    /// Session id to the last permission answer Nano sent for it.
    @Published private(set) var recentDecisions: [String: DecisionNote] = [:]
    /// How long an answered permission card stays up with its outcome.
    var resolvedCardLinger: Duration = .seconds(2)
    @Published private(set) var isListening = false
    @Published private(set) var hooksInstalled = false
    private(set) var lastEventAt: Date?

    /// Session id to the moment it last spoke, so live sessions can be ranked
    /// without re-reading any transcript.
    private(set) var liveSessions: [String: Date] = [:]

    /// Everything hooks know about a session, which is most of what the island
    /// shows. Agents push this; nothing has to be scanned to learn it.
    private(set) var sessionStates: [String: LiveSessionState] = [:]

    struct LiveSessionState: Equatable, Sendable {
        let sessionID: String
        var source: String
        /// The model vendor can differ from the host agent (OpenCode running
        /// Kimi, for example). Kept separately so Settings and branding stay
        /// honest while the transport still knows which integration spoke.
        var providerID: String?
        /// The app that owns the session when a host reports it explicitly.
        /// This stays separate from the provider because T3 can host Cursor,
        /// Grok, Codex, and other agents.
        var host: AgentSessionJump.Host? = nil
        var hostBundleID: String? = nil
        var workingDirectory: String?
        /// Supplied by the agent, so the right transcript is known without
        /// enumerating a directory to guess at it.
        var transcriptPath: String?
        var lastTool: String?
        var lastToolInputDescription: String?
        var lastToolKindRaw: String?
        var recentActivity: [AgentActivityEntry] = []
        var lastUserPrompt: String?
        /// Excerpt of the agent's latest reply, from turn-end hooks.
        var lastAgentMessage: String?
        var model: String?
        var firstSeen: Date
        var lastEventAt: Date
        /// False once the turn ends. A session that finished is still worth
        /// listing for a while, but it is not working.
        var isWorking: Bool
        /// When the current or last turn began: the last real prompt.
        var turnStartedAt: Date? = nil
        /// When a turn-end hook last arrived. Cleared as soon as work resumes.
        var finishedAt: Date? = nil
    }

    /// A turn that ends without a hook (an interrupt, a killed terminal) never
    /// reports it. After this long with no event the session is not working.
    static let silentWorkingWindow: TimeInterval = 30 * 60

    private let server = HookSocketServer()
    private var token = ""
    private var waiters: [String: CheckedContinuation<Int?, Never>] = [:]
    private var waiterExpiryTasks: [String: Task<Void, Never>] = [:]
    /// Requests whose hook died unanswered, so `decision(for:)` can tell a
    /// retraction from a dismissal.
    private var retractedByAgent: Set<String> = []
    private var lingerTasks: [String: Task<Void, Never>] = [:]
    private var enabledProviders = Set(AgentProviderID.supported)
    /// Sessions showing a permission card that only the agent's own prompt
    /// can answer. The next event that proves the agent moved on retracts it.
    private var sessionsAwaitingHostApproval: Set<String> = []

    /// Codex re-locks hooks whose position in `hooks.json` moved. Re-approving
    /// Nano's own entries is safe to do silently; the fingerprint below keeps
    /// this a stat of two files instead of an app-server spawn every minute.
    private var codexTrustTask: Task<Void, Never>?
    private var lastCodexTrustFingerprint: String?

    // MARK: - Lifecycle

    func start() {
        guard !isListening else { return }
        // The test host is this same app and shares Application Support. A
        // bridge started there took the socket path from the installed Nano,
        // which then heard no hooks until it was relaunched.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        token = Self.loadOrCreateToken()

        guard let socketPath = try? Self.socketPath() else { return }

        server.expectedToken = token
        // Data rather than a dictionary: [String: Any] is not Sendable and
        // this crosses from the socket thread to the main actor.
        server.onEvent = { [weak self] data in
            guard let self else { return nil }
            return await self.handle(data)
        }
        guard server.start(at: socketPath) else { return }
        publishTransport(socketPath: socketPath)
        Self.refreshInstalledBridge()
        Self.refreshInstalledHooks()
        isListening = true
        hooksInstalled = Self.hooksAreInstalled()
        scheduleCodexTrustChecks()
    }

    func setEnabledProviders(_ providers: Set<AgentProviderID>) {
        enabledProviders = providers
    }

    func stop() {
        let activeWaiters = Array(waiters.values)
        waiters.removeAll()
        waiterExpiryTasks.values.forEach { $0.cancel() }
        waiterExpiryTasks.removeAll()
        pending.removeAll()
        activeWaiters.forEach { $0.resume(returning: nil) }
        server.stop()
        codexTrustTask?.cancel()
        codexTrustTask = nil
        isListening = false
    }

    // MARK: - Codex hook trust

    private func scheduleCodexTrustChecks() {
        codexTrustTask?.cancel()
        codexTrustTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkCodexHookTrust()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func checkCodexHookTrust() {
        guard enabledProviders.contains(.codex) else { return }
        let hooksURL = Self.codexHooksURL
        guard let fingerprint = Self.codexTrustFingerprint(hooksURL: hooksURL),
              fingerprint != lastCodexTrustFingerprint,
              let text = try? String(contentsOf: hooksURL, encoding: .utf8),
              text.contains(Self.bridgeMarker)
        else { return }
        lastCodexTrustFingerprint = fingerprint
        Task.detached { [weak self] in
            let repairs = CodexHookTrust.repairIfNeeded(hooksFile: hooksURL)
            guard let self else { return }
            await MainActor.run {
                switch repairs {
                case nil:
                    // The app-server never answered. Clear the fingerprint so
                    // the next tick retries instead of skipping a full minute.
                    self.lastCodexTrustFingerprint = nil
                case .some(let repairs) where !repairs.isEmpty:
                    // A successful repair rewrites config.toml, so store the
                    // fingerprint of what it left behind rather than
                    // re-scanning next tick.
                    self.lastCodexTrustFingerprint = Self.codexTrustFingerprint(hooksURL: hooksURL)
                case .some:
                    break
                }
            }
        }
    }

    /// `config.toml` sits next to `hooks.json` inside CODEX_HOME; the pair's
    /// mtimes are the whole signal for "Codex may have dropped our trust".
    nonisolated private static func codexTrustFingerprint(hooksURL: URL) -> String? {
        let configURL = hooksURL.deletingLastPathComponent()
            .appendingPathComponent("config.toml")
        func stamp(_ url: URL) -> TimeInterval? {
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
                .flatMap { ($0 as? Date)?.timeIntervalSince1970 }
        }
        guard let hooks = stamp(hooksURL) else { return nil }
        return "\(hooks)|\(stamp(configURL) ?? -1)"
    }

    // MARK: - Requests

    /// Returning a value unblocks the waiting agent; returning nil lets it fall
    /// through to its own prompt.
    func handle(_ data: Data) async -> Data? {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // One hook is one UI update. Publishing these three fields separately
        // made every tool event relayout the island three times.
        objectWillChange.send()
        lastEventAt = Date()

        var source = payload["source"] as? String ?? "unknown"
        var event = payload["event"] as? [String: Any] ?? [:]
        if event["host_bundle_id"] == nil, let host = payload["host_bundle_id"] as? String {
            event["host_bundle_id"] = host
        }
        // Devin's payloads carry no cwd; the bridge script adds the agent's
        // DEVIN_PROJECT_DIR at the top level so the session still gets a
        // project.
        if event["cwd"] == nil, let projectDir = payload["project_dir"] as? String,
           !projectDir.isEmpty {
            event["cwd"] = projectDir
        }
        // Grok CLI also loads Claude and Cursor hook files. T3 launches that
        // same binary, so a Grok turn would otherwise land as Claude/Cursor.
        if Self.looksLikeGrokHook(event) { source = "grok" }
        let name = Self.eventName(fromHook: payload)
        let sessionID = Self.sessionID(fromHook: payload)
        if !Self.looksLikeGrokHook(event), Self.isCursorSession(source: source, event: event, sessionID: sessionID) {
            source = "cursor"
        }
        let adapter = AgentProviderRegistry.adapter(
            source: source,
            providerID: source == "cursor" ? nil : ((event["provider_id"] as? String) ?? (event["provider"] as? String))
        )
        if let provider = adapter?.provider, !enabledProviders.contains(provider) {
            return nil
        }
        // Codex's background memory consolidation runs an internal agent whose
        // hooks arrive like any other session's. It has no rollout and no user,
        // so it must not become a row, a notification, or a permission card.
        if Self.isCodexInternalMemorySession(source: source, event: event) {
            return nil
        }
        // Absent from bridges installed before this field existed; those
        // requests keep the old behavior of waiting for an answer.
        let hookPIDs = (payload["hook_pids"] as? [NSNumber] ?? []).map(\.int32Value)
        // A run another agent started (a `claude -p` from a Bash tool, a test
        // harness in /tmp) is that agent's work, not a session of its own.
        if let sessionID, AgentSpawnedSessions.shared.hides(
            sessionID: sessionID,
            hookPIDs: hookPIDs,
            isKnown: sessionStates[sessionID] != nil
        ) {
            return nil
        }
        if name == "UserPromptSubmit", let sessionID {
            didResumeSession?(sessionID)
        }
        // Subagent lifecycle hooks describe work inside an existing parent.
        // Some providers report the parent's session ID, while others report
        // a child ID. Never let that event alone manufacture a top-level row;
        // if the parent is already known, it can still refresh its liveness.
        let isSubagentEvent = name == "SubagentStart" || name == "SubagentStop"
        // Provider discovery (notably T3's Grok status check) launches a CLI
        // just far enough to emit SessionStart, then exits without a prompt or
        // tool. That is connectivity, not work. Hold a new session back until
        // the first event that proves a real turn exists; an already-known
        // session can still use SessionStart to refresh after a reconnect.
        // The probe's SessionEnd is held back the same way: recording it would
        // create the session as working and announce it finished in one step.
        let isBareStartup = (name == "SessionStart" || name == "SessionEnd") && sessionID.map {
            sessionStates[$0] == nil
        } == true
        var finishedTurn = false
        if let sessionID,
           !isBareStartup,
           !isSubagentEvent || sessionStates[sessionID] != nil {
            let now = Date()
            liveSessions[sessionID] = now
            finishedTurn = recordState(
                sessionID: sessionID,
                source: source,
                event: event,
                name: name,
                at: now
            )
        }

        // Event names differ across agents. Classify every terminal spelling,
        // rather than making non-Claude providers look busy forever. Cursor's
        // AfterAgentResponse is deliberately absent: it is per-message, and a
        // turn with tool calls emits several before its `stop`.
        let endedEvents: Set<String> = [
            "Stop", "StopFailure", "StopCancelled", "SessionEnd",
            "AfterAgent", "PostCompact",
        ]
        if !isBareStartup {
            didSignalActivity?(endedEvents.contains(name) ? .turnEnded : .working)
        }
        // Ahead of the finished-turn card, so a turn that ends on a refused
        // permission still gets to announce itself.
        let movedOn: Set<String> = [
            "PostToolUse", "PostToolUseFailure", "PermissionDenied",
            "Stop", "StopFailure", "StopCancelled", "SessionEnd",
        ]
        if let sessionID, movedOn.contains(name),
           sessionsAwaitingHostApproval.remove(sessionID) != nil {
            didResumeSession?(sessionID)
        }
        if finishedTurn {
            didFinishTurn?(sessionID)
        }

        switch name {
        case "PermissionRequest":
            let tool = event["tool_name"] as? String ?? "an action"
            let input = event["tool_input"] as? [String: Any] ?? [:]
            let target = (input["file_path"] as? String)
                ?? (input["path"] as? String)
                ?? (input["command"] as? String)
                ?? (input["url"] as? String)
            let answerable = adapter?.controls.contains(.approvePermission) == true

            let request = PendingRequest(
                id: answerable ? UUID().uuidString : "permission:\(sessionID ?? "unknown")",
                source: source,
                kind: .permission,
                title: answerable
                    ? tool
                    : "\(AgentProviderID(rawValue: source.lowercased())?.title ?? "The agent") needs approval for \(tool)",
                detail: target,
                options: answerable
                    ? [Option(id: 0, label: "Deny"), Option(id: 1, label: "Allow once")]
                    : [],
                sessionID: sessionID,
                receivedAt: Date(),
                respondsThroughBridge: answerable,
                preview: Self.preview(tool: tool, input: input),
                projectName: AgentSession.projectLabel(
                    directory: (event["cwd"] as? String)
                        ?? (event["workspaceRoot"] as? String)
                )
            )

            guard answerable else {
                // Kimi reports this just before it waits for approval and
                // takes no answer from the hook. Say what it is waiting for
                // and let the agent's own prompt decide.
                if let sessionID { sessionsAwaitingHostApproval.insert(sessionID) }
                didRequestAttention?(request)
                return nil
            }

            guard let choice = await decision(for: request, hookPIDs: hookPIDs) else { return nil }
            guard let response = adapter?.permissionResponse(allowed: choice == 1) else {
                return nil
            }
            return try? JSONSerialization.data(withJSONObject: response)

        case "PreToolUse":
            // Any other pre-tool event is intended work, not a blocked agent.
            // Cursor's in particular fires for every command, so it stays
            // session activity only.
            guard let adapter, let questionTool = adapter.questionTool,
                  event["tool_name"] as? String == questionTool,
                  let input = event["tool_input"] as? [String: Any]
            else { return nil }
            guard let parsed = Self.singleSelectQuestion(from: input),
                  adapter.controls.contains(.answerStructuredQuestion)
            else {
                // Several questions, a multi-select, or an agent whose hook
                // takes no answer. The agent is still blocked on the user, so
                // say so rather than showing nothing; the answer happens in
                // the host.
                didRequestAttention?(Self.unanswerableQuestionRequest(
                    input: input,
                    event: event,
                    source: source,
                    sessionID: sessionID
                ))
                return nil
            }

            let request = PendingRequest(
                id: UUID().uuidString,
                source: source,
                kind: .question,
                title: parsed.question,
                detail: parsed.header,
                options: parsed.options.enumerated().map { Option(id: $0.offset, label: $0.element) },
                sessionID: sessionID,
                receivedAt: Date(),
                projectName: AgentSession.projectLabel(directory: event["cwd"] as? String)
            )
            guard let choice = await decision(for: request, hookPIDs: hookPIDs),
                  parsed.options.indices.contains(choice),
                  let response = adapter.questionResponse(
                      originalInput: input,
                      question: parsed.question,
                      answer: parsed.options[choice]
                  )
            else { return nil }
            return try? JSONSerialization.data(withJSONObject: response)

        case "Notification":
            let request = Self.notificationRequest(
                event: event,
                source: source,
                sessionID: sessionID
            )
            if request.kind == .permission,
               pending.contains(where: { $0.sessionID == sessionID && $0.kind == .permission }) {
                return nil
            }
            if request.kind == .permission, let sessionID {
                sessionsAwaitingHostApproval.insert(sessionID)
            }
            didRequestAttention?(request)
            return nil

        case "PostToolUse", "PostToolUseFailure":
            // The question was answered in the host; retract the island's card.
            if let questionTool = adapter?.questionTool,
               event["tool_name"] as? String == questionTool, let sessionID {
                didResumeSession?(sessionID)
                // OpenCode's plugin has no hook process to die, so an
                // answerable card is released here as well.
                pending.filter { $0.sessionID == sessionID && $0.kind == .question }
                    .forEach { respond(to: $0.id, choice: nil) }
            }
            return nil

        default:
            // SessionStart, PostCompact and Stop are liveness only.
            return nil
        }
    }

    nonisolated static func unanswerableQuestionRequest(
        input: [String: Any],
        event: [String: Any],
        source: String,
        sessionID: String?
    ) -> PendingRequest {
        let questions = input["questions"] as? [[String: Any]] ?? []
        let first = questions.first?["question"] as? String
        let agent = AgentProviderID(rawValue: source.lowercased())?.title ?? "The agent"
        let title = questions.count > 1
            ? "\(agent) has \(questions.count) questions for you"
            : (first ?? "\(agent) has a question for you")
        return PendingRequest(
            id: "question:\(sessionID ?? "unknown")",
            source: source,
            kind: .question,
            title: title,
            detail: questions.count > 1 ? first : nil,
            options: [],
            sessionID: sessionID,
            receivedAt: Date(),
            respondsThroughBridge: false,
            projectName: AgentSession.projectLabel(directory: event["cwd"] as? String)
        )
    }

    nonisolated static func singleSelectQuestion(
        from input: [String: Any]
    ) -> (question: String, header: String?, options: [String])? {
        guard let questions = input["questions"] as? [[String: Any]], questions.count == 1,
              let item = questions.first,
              item["multiSelect"] as? Bool != true,
              // OpenCode's spelling of the same flag.
              item["multiple"] as? Bool != true,
              let question = item["question"] as? String, !question.isEmpty,
              let rawOptions = item["options"] as? [[String: Any]]
        else { return nil }
        let options = rawOptions.compactMap { $0["label"] as? String }.filter { !$0.isEmpty }
        guard (2...4).contains(options.count) else { return nil }
        return (question, item["header"] as? String, options)
    }

    /// Claude's Notification hook is an alert channel, not a decision channel.
    /// Preserve the reason so Nano can keep actionable alerts open without
    /// pretending their buttons can answer a hook that accepts no response.
    nonisolated static func notificationRequest(
        event: [String: Any],
        source: String,
        sessionID: String?
    ) -> PendingRequest {
        let type = (event["notification_type"] as? String)
            ?? (event["notificationType"] as? String)
            ?? "notification"
        let kind: RequestKind = switch type {
        case "permission_prompt": .permission
        case "idle_prompt", "elicitation_dialog", "elicitation_url_dialog",
             "agent_needs_input", "quota_auto_resume_stale", "quota_auto_resume_disabled":
            .question
        case "agent_completed": .completion
        default: .notification
        }
        let fallback = switch kind {
        case .permission: "Agent needs approval"
        case .question: "Agent is waiting for you"
        case .completion: "Agent finished"
        case .notification: "Agent update"
        }
        return PendingRequest(
            id: "notification:\(sessionID ?? "unknown"):\(type)",
            source: source,
            kind: kind,
            title: event["message"] as? String ?? fallback,
            detail: event["title"] as? String,
            options: [],
            sessionID: sessionID,
            receivedAt: Date(),
            respondsThroughBridge: false,
            projectName: AgentSession.projectLabel(
                directory: (event["cwd"] as? String) ?? (event["workspaceRoot"] as? String)
            )
        )
    }

    /// Folds one hook event into what we know about its session.
    ///
    /// This is the whole point of the hook-first design: `cwd`, the transcript
    /// path, and the tool just run all arrive in the payload, so the common
    /// case needs no file reads at all.
    @discardableResult
    private func recordState(
        sessionID: String,
        source: String,
        event: [String: Any],
        name: String,
        at now: Date
    ) -> Bool {
        var state = sessionStates[sessionID] ?? LiveSessionState(
            sessionID: sessionID,
            source: source,
            firstSeen: now,
            lastEventAt: now,
            isWorking: true
        )

        state.source = source
        if source == "cursor" { state.providerID = nil }
        state.lastEventAt = now
        if let bundleID = event["host_bundle_id"] as? String, !bundleID.isEmpty {
            state.hostBundleID = bundleID.lowercased()
        }
        if let cwd = (event["cwd"] as? String) ?? (event["workspaceRoot"] as? String),
           !cwd.isEmpty {
            state.workingDirectory = cwd
        }
        if let path = event["transcript_path"] as? String, !path.isEmpty {
            state.transcriptPath = path
        }
        if source != "cursor", let provider = (event["provider_id"] as? String)
            ?? (event["provider"] as? String), !provider.isEmpty {
            state.providerID = provider
        }
        if let model = (event["model"] as? String)
            ?? (event["model_name"] as? String), !model.isEmpty {
            state.model = model
        }

        // Turn-end hooks carry the reply: Claude and Codex `Stop` send
        // `last_assistant_message`, Gemini `AfterAgent` sends `prompt_response`,
        // Cursor `afterAgentResponse` sends `text`.
        let reply = (event["last_assistant_message"] as? String)
            ?? (event["lastAssistantMessage"] as? String)
            ?? (event["prompt_response"] as? String)
            ?? (name == "AfterAgentResponse" || name == "afterAgentResponse" ? event["text"] as? String : nil)
        if let reply, let excerpt = AgentSessionPromptSummary.agentExcerpt(reply) {
            state.lastAgentMessage = excerpt
        }

        var finishedTurn = false
        switch name {
        case "PostToolUse", "PreToolUse", "PermissionRequest", "PermissionDenied",
             "PostToolUseFailure", "beforeShellExecution", "AfterTool":
            state.isWorking = true
            if let tool = (event["tool_name"] as? String) ?? (event["toolName"] as? String) {
                let described = AgentToolLabel.describe(
                    tool: tool,
                    input: (event["tool_input"] as? [String: Any])
                        ?? (event["toolInput"] as? [String: Any])
                        ?? [:]
                )
                state.lastTool = tool
                state.lastToolInputDescription = described.detail
                state.lastToolKindRaw = described.kind.rawValue
                state.recentActivity.append(AgentActivityEntry(
                    kind: described.kind,
                    detail: described.detail,
                    target: described.target,
                    at: now
                ))
                state.recentActivity = Array(state.recentActivity.suffix(40))
            }
        case "UserPromptSubmit", "BeforeAgent", "beforeSubmitPrompt":
            state.isWorking = true
            state.lastTool = nil
            state.lastToolInputDescription = nil
            state.lastToolKindRaw = nil
            // Hosts deliver their own notices through the same hook
            // (`<task-notification>`, `<system-reminder>`). Those are not what
            // the user asked, so the last real prompt stays.
            if let prompt = Self.promptText(from: event), !prompt.isEmpty,
               !Self.isHostInjectedPrompt(prompt) {
                state.lastUserPrompt = prompt
                state.turnStartedAt = now
            }
        case "Stop", "StopFailure", "StopCancelled", "SessionEnd", "AfterAgent":
            let wasWorking = state.isWorking
            state.isWorking = false
            state.finishedAt = now
            finishedTurn = wasWorking
        case "AfterAgentResponse":
            // Cursor emits one of these per assistant message, including the
            // intermediate text between tool calls. Treating it as the end of
            // the turn announced "finished" several times per real turn. The
            // agent is still working until `stop` arrives.
            state.isWorking = true
        case "SessionStart", "SubagentStart":
            state.isWorking = true
        case "SubagentStop":
            break
        default:
            break
        }

        if state.isWorking { state.finishedAt = nil }
        sessionStates[sessionID] = state

        // A machine left running for days would otherwise accumulate these.
        if sessionStates.count > 40 {
            let cutoff = Date().addingTimeInterval(-60 * 60 * 6)
            sessionStates = sessionStates.filter { $0.value.lastEventAt > cutoff }
        }
        return finishedTurn
    }

    /// Providers do not agree on the session key. Claude uses `session_id`,
    /// Cursor documents `conversation_id` (and only some events also send
    /// `session_id`), and ACP clients camelCase it. Missing this is how a
    /// live hook becomes a usage blip with no row.
    nonisolated static func sessionID(fromHook payload: [String: Any]) -> String? {
        let event = payload["event"] as? [String: Any] ?? [:]
        for source in [event, payload] {
            for key in ["session_id", "conversation_id", "sessionId", "sessionID"] {
                if let value = (source[key] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    /// Grok's own hook JSON uses `workspaceRoot` and snake_case `hookEventName`.
    /// Claude/Cursor files Grok also loads never look like that.
    nonisolated static func looksLikeGrokHook(_ event: [String: Any]) -> Bool {
        if let root = event["workspaceRoot"] as? String, !root.isEmpty { return true }
        if let name = event["hookEventName"] as? String, name.contains("_") { return true }
        return false
    }

    /// Cursor also runs Claude-compatible hooks. The hook configuration is
    /// transport metadata, not the identity of the process doing the work.
    nonisolated static func isCursorSession(source: String, event: [String: Any], sessionID: String?) -> Bool {
        if source == "cursor" { return true }
        guard source == "claude" else { return false }
        if event["conversation_id"] is String, event["generation_id"] is String { return true }
        guard let sessionID, UUID(uuidString: sessionID) != nil else { return false }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/acp-sessions/\(sessionID)")
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("meta.json").path)
    }

    /// One spelling per event so Grok's `pre_tool_use`, Cursor's `postToolUse`,
    /// and Claude's `PostToolUse` update the same session fields.
    nonisolated static func eventName(fromHook payload: [String: Any]) -> String {
        let event = payload["event"] as? [String: Any] ?? [:]
        let raw = (event["hook_event_name"] as? String)
            ?? (event["hookEventName"] as? String)
            ?? "Unknown"
        return canonicalHookEventName(raw)
    }

    nonisolated static func canonicalHookEventName(_ raw: String) -> String {
        switch raw {
        case "SessionStart", "sessionStart", "session_start": "SessionStart"
        case "SessionEnd", "sessionEnd", "session_end": "SessionEnd"
        case "UserPromptSubmit", "beforeSubmitPrompt", "user_prompt_submit": "UserPromptSubmit"
        case "PreToolUse", "preToolUse", "beforeShellExecution", "pre_tool_use": "PreToolUse"
        case "PostToolUse", "postToolUse", "AfterTool", "post_tool_use": "PostToolUse"
        case "PostToolUseFailure", "postToolUseFailure", "post_tool_use_failure":
            "PostToolUseFailure"
        case "PermissionRequest": "PermissionRequest"
        case "PermissionDenied", "permission_denied": "PermissionDenied"
        case "Stop", "stop": "Stop"
        case "StopFailure", "stop_failure": "StopFailure"
        case "StopCancelled", "stop_cancelled": "StopCancelled"
        case "Notification", "notification": "Notification"
        case "SubagentStart", "subagentStart", "subagent_start": "SubagentStart"
        case "SubagentStop", "SubagentEnd", "subagentStop", "subagent_stop", "subagent_end":
            "SubagentStop"
        case "PreCompact", "preCompact", "pre_compact": "PreCompact"
        case "PostCompact", "postCompact", "post_compact", "PostCompaction": "PostCompact"
        case "BeforeAgent": "BeforeAgent"
        case "AfterAgent": "AfterAgent"
        // Cursor fires this after every assistant message, including the ones
        // between tool calls inside a single turn. Only `stop` ends a turn.
        case "afterAgentResponse", "AfterAgentResponse": "AfterAgentResponse"
        default: raw
        }
    }

    nonisolated static func isHostInjectedPrompt(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.contains(">") { return true }
        return trimmed.hasPrefix("[SYSTEM NOTIFICATION")
    }

    /// Hook payload names differ, but all supported agents expose the prompt
    /// under one of these shallow keys. OpenCode supplies structured `parts`.
    private static func promptText(from event: [String: Any]) -> String? {
        if let text = (event["prompt"] as? String)
            ?? (event["user_prompt"] as? String)
            ?? (event["message"] as? String) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let message = event["message"] as? [String: Any]
        let parts = (event["parts"] as? [[String: Any]])
            ?? (message?["parts"] as? [[String: Any]])
        return parts?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the at-a-glance preview from the tool payload.
    ///
    /// Edits carry `old_string`/`new_string`, which is a diff in all but name.
    /// Rendering it here is the difference between approving a description and
    /// approving the actual change.
    static func preview(tool: String, input: [String: Any]) -> Preview {
        // Devin names the same tools in lowercase and may say `path`.
        let fullPath = (input["file_path"] as? String) ?? (input["path"] as? String)
        let file = fullPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch tool {
        case "Edit", "MultiEdit", "NotebookEdit", "edit", "notebook_edit":
            let old = input["old_string"] as? String
            let removed = lines(old)
            let added = lines(input["new_string"] as? String)
            // An edit described some other way has no lines to show; the
            // card's detail line still names the file.
            guard tool.first?.isUppercase == true || !removed.isEmpty || !added.isEmpty
            else { return .none }
            return .diff(
                path: file ?? tool, removed: removed, added: added,
                startLine: fullPath.flatMap { line(of: old, inFileAt: $0) }
            )
        case "Write", "write":
            return .diff(path: file ?? tool, removed: [], added: lines(input["content"] as? String), startLine: 1)
        case "Bash", "shell", "exec":
            guard let command = input["command"] as? String else { return .none }
            return .command(command)
        case "ExitPlanMode":
            guard let plan = input["plan"] as? String,
                  !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
            return .plan(plan)
        default:
            if let url = input["url"] as? String { return .command(url) }
            if let pattern = input["pattern"] as? String { return .command(pattern) }
            if tool.hasPrefix("mcp__") {
                let fields = input.keys.sorted().prefix(6).map { key -> String in
                    let value = input[key] ?? ""
                    let text: String
                    if let string = value as? String {
                        text = "\"\(string)\""
                    } else if JSONSerialization.isValidJSONObject(value),
                              let data = try? JSONSerialization.data(withJSONObject: value) {
                        text = String(decoding: data, as: UTF8.self)
                    } else {
                        text = "\(value)"
                    }
                    return "\(key): \(AgentToolLabel.truncated(text, 140))"
                }
                return fields.isEmpty ? .none : .arguments(fields)
            }
            return .none
        }
    }

    /// The 1-based line where `text` first appears, read before the edit
    /// lands. Large files and missing text give nil.
    private static func line(of text: String?, inFileAt path: String) -> Int? {
        guard let text, !text.isEmpty,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              size < 4_000_000,
              let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let range = contents.range(of: text)
        else { return nil }
        return contents[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// First few lines only. The card is a glance surface, and a 400 line write
    /// would push the buttons off screen.
    private static func lines(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(6)
            .map(String.init)
    }

    private func decision(for request: PendingRequest, hookPIDs: [Int32]) async -> Int? {
        let choice = await withCheckedContinuation { continuation in
            waiters[request.id] = continuation
            waiterExpiryTasks[request.id] = Task { [weak self] in
                // The agent can stop waiting without telling us: it kills the
                // hook once it has answered some other way. A card left up
                // after that looks answerable but answers nothing.
                let deadline = Date().addingTimeInterval(86_400)
                while Date() < deadline {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    if !hookPIDs.allSatisfy(Self.processIsAlive) { break }
                }
                guard !Task.isCancelled else { return }
                self?.retractedByAgent.insert(request.id)
                self?.respond(to: request.id, choice: nil)
            }
            append(request)
        }
        settle(request, choice: choice)
        return choice
    }

    /// Keep an answered permission card up with its outcome for a moment,
    /// then drop it. Anything else leaves at once.
    private func settle(_ request: PendingRequest, choice: Int?) {
        let retracted = retractedByAgent.remove(request.id) != nil
        let outcome: Outcome?
        switch (request.kind, choice) {
        case (.permission, 1): outcome = .allowed
        case (.permission, 0): outcome = .denied
        case (.permission, nil) where retracted: outcome = .answeredElsewhere
        default: outcome = nil
        }
        guard let outcome, let index = pending.firstIndex(where: { $0.id == request.id }) else {
            pending.removeAll { $0.id == request.id }
            return
        }
        pending[index].outcome = outcome
        if let sessionID = request.sessionID, outcome != .answeredElsewhere {
            recentDecisions[sessionID] = DecisionNote(allowed: outcome == .allowed, at: Date())
        }
        let linger = resolvedCardLinger
        lingerTasks[request.id] = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled else { return }
            self?.lingerTasks[request.id] = nil
            self?.pending.removeAll { $0.id == request.id }
        }
    }

    /// EPERM still means the process exists; only ESRCH means it is gone.
    nonisolated static func processIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    func respond(to id: String, choice: Int?) {
        waiterExpiryTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = waiters.removeValue(forKey: id) else {
            lingerTasks.removeValue(forKey: id)?.cancel()
            pending.removeAll { $0.id == id }
            return
        }
        continuation.resume(returning: choice)
    }

    func dismiss(_ id: String) {
        respond(to: id, choice: nil)
    }

    private func append(_ request: PendingRequest) {
        pending.append(request)
        didRequestAttention?(request)
    }

    // MARK: - Transport

    private static func socketPath() throws -> String {
        try NanoStorage.directory("run")
            .appendingPathComponent("nano-hooks.sock").path
    }

    private static func loadOrCreateToken() -> String {
        let url = try? NanoStorage.directory("run").appendingPathComponent("token")
        if let url,
           let existing = try? String(contentsOf: url, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let token = UUID().uuidString
        if let url {
            try? token.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
        return token
    }

    /// The bridge reads this to find the socket. Without the token any local
    /// process could post fake events into the island.
    private func publishTransport(socketPath: String) {
        guard let directory = try? NanoStorage.directory("run"),
              let data = try? JSONSerialization.data(
                  withJSONObject: ["socketPath": socketPath, "authToken": token]
              )
        else { return }

        let url = directory.appendingPathComponent("hook-transport.json")
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    // MARK: - Installation

    nonisolated static func bridgeURL() throws -> URL {
        try NanoStorage.directory("bin").appendingPathComponent("nano-agent-bridge")
    }

    /// Stable ordering shared by the confirmation preview and installer.
    nonisolated static func installationProviders(
        _ selected: Set<AgentProviderID>,
        homeDirectory: URL? = nil
    ) -> [AgentProviderID] {
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        return [.claude, .codex, .gemini, .cursor, .kimi, .pi, .grok, .opencode, .devin]
            .filter { selected.contains($0) }
            .filter { provider in
                // An injected home stands in for the whole machine in tests,
                // so the process environment only applies to the real one.
                let environment = homeDirectory == nil
                    ? ProcessInfo.processInfo.environment
                    : [:]
                let directory = AgentRoutes.root(
                    for: provider, home: home, environment: environment
                )
                return FileManager.default.fileExists(atPath: directory.path)
            }
    }

    /// Keeps an already-installed bridge current, so a new payload field reaches
    /// existing hooks without asking the user to reinstall. Only Nano's own
    /// script is touched, and only when one is already installed.
    nonisolated private static func refreshInstalledBridge() {
        guard let bridge = try? bridgeURL(),
              FileManager.default.fileExists(atPath: bridge.path),
              (try? String(contentsOf: bridge, encoding: .utf8)) != bridgeScript
        else { return }
        try? bridgeScript.write(to: bridge, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)
    }

    /// The same courtesy for hook entries: where the user already connected
    /// an agent, bring Nano's own entries up to what this version needs (a
    /// longer timeout, one more event). An agent that was never connected is
    /// left alone; connecting stays a decision made in Settings.
    private static func refreshInstalledHooks() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let bridge = try? bridgeURL(),
              FileManager.default.fileExists(atPath: bridge.path)
        else { return }
        func connected(_ url: URL) -> Bool {
            (try? String(contentsOf: url, encoding: .utf8))?.contains(bridgeMarker) == true
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        if connected(home.appendingPathComponent(".claude/settings.json")) {
            installClaudeHooks(bridge: bridge.path)
        }
        if connected(codexHooksURL) { installCodexHooks(bridge: bridge.path) }
        let devin = AgentRoutes.root(for: .devin).appendingPathComponent("config.json")
        if connected(devin) { installDevinHooks(at: devin, bridge: bridge.path) }
        refreshOpenCodePlugin()
    }

    /// Called only after the user reviews the providers and confirms installation.
    func installHooks(for selected: Set<AgentProviderID>) {
        let providers = Self.installationProviders(selected)
        guard !providers.isEmpty else { return }
        guard let bridge = try? Self.bridgeURL() else { return }
        try? Self.bridgeScript.write(to: bridge, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: bridge.path
        )

        for provider in providers {
            switch provider {
            case .claude: Self.installClaudeHooks(bridge: bridge.path)
            case .codex: Self.installCodexHooks(bridge: bridge.path)
            case .gemini: Self.installGeminiHooks(bridge: bridge.path)
            case .cursor: Self.installCursorHooks(bridge: bridge.path)
            case .kimi: Self.installKimiHooks(bridge: bridge.path)
            case .pi: Self.installPiHooks(bridge: bridge.path)
            case .grok: Self.installGrokHooks(bridge: bridge.path)
            case .opencode: Self.installOpenCodePlugin()
            case .devin: Self.installDevinHooks(bridge: bridge.path)
            default: break
            }
        }
        hooksInstalled = Self.hooksAreInstalled()
        // Installing just rewrote hooks.json, so every entry's trust key moved.
        if providers.contains(.codex) {
            lastCodexTrustFingerprint = nil
            checkCodexHookTrust()
        }
    }

    private static func command(_ bridge: String, source: String) -> String {
        // Guarded so a missing or non-executable bridge can never block the
        // agent — it exits clean and the agent carries on.
        "/bin/sh -c '[ -x \"\(bridge)\" ] && \"\(bridge)\" --source \(source); exit 0'"
    }

    private static func entry(_ command: String, timeout: Int) -> [String: Any] {
        ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
    }

    /// Appends Nano's entry for each hook the adapter wants. An entry Nano
    /// wrote earlier is left exactly as it is, with one exception: a watcher
    /// (a timeout of seconds) whose event Nano now answers gets the long
    /// timeout, or the card would vanish before anyone could answer it.
    /// Other tools' entries are never touched.
    private static func merge(
        _ wanted: [AgentProviderAdapter.Hook],
        into hooks: inout [String: Any],
        command: String,
        bridge: String
    ) -> Bool {
        var changed = false
        for hook in wanted {
            var entries = hooks[hook.event] as? [[String: Any]] ?? []
            var new = entry(command, timeout: hook.timeout)
            if let matcher = hook.matcher { new["matcher"] = matcher }

            if let index = entries.firstIndex(where: { contains($0, bridge) }) {
                let handlers = entries[index]["hooks"] as? [[String: Any]] ?? []
                // An entry Nano shares with someone else's handler is theirs
                // to shape; only one that is wholly Nano's is rewritten.
                guard handlers.count == 1,
                      let current = handlers[0]["timeout"] as? Int,
                      current <= 60, hook.timeout > 60
                else { continue }
                var handler = handlers[0]
                handler["timeout"] = hook.timeout
                entries[index]["hooks"] = [handler]
            } else {
                entries.append(new)
            }
            hooks[hook.event] = entries
            changed = true
        }
        return changed
    }

    private static func installClaudeHooks(bridge: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard var root = load(url) else { return }
        guard Self.hasSupportedHookShape(root) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = command(bridge, source: "claude")

        guard let adapter = AgentProviderRegistry.adapter(for: .claude) else { return }
        let changed = merge(adapter.hooks, into: &hooks, command: command, bridge: bridge)

        guard changed else { return }
        backUp(url)
        root["hooks"] = hooks
        write(root, to: url)
    }

    /// Gemini CLI keeps hooks in its own `settings.json`, same nested shape as
    /// Claude's but with its own event names. Verified against the file on
    /// disk rather than assumed - a malformed entry here would break the user's
    /// agent, not just Nano.
    private static func installGeminiHooks(bridge: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/settings.json")

        // Only where Gemini is actually set up. Creating the file would be
        // configuring an agent the user may not have.
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        guard var root = load(url) else { return }
        guard Self.hasSupportedHookShape(root) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = command(bridge, source: "gemini")
        var changed = false

        for event in ["AfterAgent", "BeforeAgent", "AfterTool"] {
            var entries = hooks[event] as? [[String: Any]] ?? []
            guard !entries.contains(where: { contains($0, bridge) }) else { continue }
            entries.append(entry(command, timeout: 5))
            hooks[event] = entries
            changed = true
        }

        guard changed else { return }
        backUp(url)
        root["hooks"] = hooks
        write(root, to: url)
    }

    /// OpenCode has no shell hooks, but it does have a plugin API. The plugin
    /// speaks the same socket as the bridge, so OpenCode ends up on the same
    /// event path as everything else rather than being polled.
    ///
    /// Copied out of the bundle and registered in `opencode.jsonc`, so the user
    /// installs nothing by hand.
    private static func installOpenCodePlugin() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent(".config/opencode", isDirectory: true)

        // Only where OpenCode is actually configured. Creating this tree would
        // be setting up an agent the user may not have.
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard let source = Bundle.main.url(
            forResource: "nano-opencode-plugin", withExtension: "js"
        ) else { return }

        let pluginDirectory = root.appendingPathComponent("plugin", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: pluginDirectory, withIntermediateDirectories: true
        )

        let destination = pluginDirectory.appendingPathComponent("nano-opencode-plugin.js")
        guard let contents = try? Data(contentsOf: source) else { return }

        // An existing file may contain user edits; installation leaves it
        // alone unless it is byte-for-byte a version Nano shipped earlier.
        Self.installOwnedPlugin(
            contents, at: destination, superseding: supersededOpenCodePlugins
        )
    }

    /// Replaces an earlier Nano plugin with this version's, where one is
    /// already installed.
    private static func refreshOpenCodePlugin() {
        guard FileManager.default.fileExists(atPath: openCodePluginURL.path) else { return }
        installOpenCodePlugin()
    }

    /// SHA-256 of each OpenCode plugin Nano shipped before the current one.
    nonisolated static let supersededOpenCodePlugins: Set<String> = [
        // Through 2026-09-28: activity, completion and permissions only.
        "cd19b33198e646ea0dbc1a724c22a007ef66facb87a479c9fba5894d16ea3b4e",
    ]

    /// Pi adopts Claude Code's hook schema    /// Pi adopts Claude Code's hook schema deliberately, so the same nested
    /// shape works. Its own event names are a subset, and `type: "command"` is
    /// the only handler kind it accepts.
    private static func installPiHooks(bridge: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let piRoot = home.appendingPathComponent(".pi/agent", isDirectory: true)
        guard FileManager.default.fileExists(atPath: piRoot.path),
              let source = Bundle.main.url(forResource: "nano-pi-extension", withExtension: "ts"),
              let contents = try? Data(contentsOf: source)
        else { return }

        // Remove Nano's old, unsupported settings.json hook entries during the
        // migration, then install the official Pi extension form.
        removeNestedHooks(from: piRoot.appendingPathComponent("settings.json"))
        let directory = piRoot.appendingPathComponent("extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("nano-agent-monitor.ts")
        Self.installOwnedPlugin(contents, at: destination)
    }

    /// Cursor uses a flatter shape than Claude: each event maps straight to an
    /// array of `{command, timeout}` with no inner `hooks` array. Verified
    /// against `~/.cursor/hooks.json` rather than assumed, since the wrong
    /// shape here silently disables the user's other hooks too.
    static func installCursorHooks(
        at url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/hooks.json"),
        bridge: String
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        guard var root = load(url) else { return }
        guard Self.hasSupportedHookShape(root) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = command(bridge, source: "cursor")
        var changed = false

        // postToolUseFailure resolves the Write/Delete permission probe when
        // the tool errors; without it a failed write reads as a stuck prompt.
        for event in [
            "beforeSubmitPrompt", "afterAgentResponse", "postToolUse", "postToolUseFailure",
            "preToolUse", "beforeShellExecution", "stop", "subagentStart", "subagentStop",
        ] {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // Append, never replace: other tools register here too.
            guard !entries.contains(where: { ($0["command"] as? String)?.contains(bridge) == true })
            else { continue }
            var entry: [String: Any] = ["command": command, "timeout": 5]
            if event == "preToolUse" { entry["matcher"] = "Write|Delete" }
            entries.append(entry)
            hooks[event] = entries
            changed = true
        }

        guard changed else { return }
        backUp(url)
        root["hooks"] = hooks
        write(root, to: url)
    }

    /// Kimi keeps hooks in TOML as repeated `[[hooks]]` tables. Rewriting a
    /// TOML document from Swift risks losing formatting and comments the user
    /// owns, so this appends whole tables and touches nothing else.
    private static func installKimiHooks(bridge: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/config.toml")
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard !existing.contains(bridge) else { return }
        backUp(url)

        let command = command(bridge, source: "kimi")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        var appended = existing
        if !appended.hasSuffix("\n") { appended += "\n" }
        for event in [
            "UserPromptSubmit", "PreToolUse", "PostToolUse",
            "PermissionRequest", "Stop",
        ] {
            appended += """

            [[hooks]]
            event = "\(event)"
            command = "\(command)"
            timeout = 5
            """
            appended += "\n"
        }
        writeConfig(Data(appended.utf8), to: url)
    }

    /// Grok Build keeps personal hooks as one JSON file per tool under
    /// `~/.grok/hooks`. Nano writes its own file so vibe-island and orca
    /// entries are never rewritten.
    private static func installGrokHooks(bridge: String) {
        let home = grokHome()
        guard FileManager.default.fileExists(atPath: home.path) else { return }

        let url = grokHookURL
        let command = command(bridge, source: "grok")
        guard var root = load(url) else { return }
        guard Self.hasSupportedHookShape(root) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for event in [
            "SessionStart", "SessionEnd", "UserPromptSubmit",
            "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "PermissionDenied", "Stop", "StopFailure", "StopCancelled",
            "Notification", "SubagentStart", "SubagentStop",
            "PreCompact", "PostCompact",
        ] {
            var entries = hooks[event] as? [[String: Any]] ?? []
            guard !entries.contains(where: { contains($0, bridge) }) else { continue }
            var new = entry(command, timeout: 5)
            if event == "PreToolUse" || event == "PostToolUse"
                || event == "PostToolUseFailure" || event == "PermissionDenied" {
                new["matcher"] = "*"
            }
            entries.append(new)
            hooks[event] = entries
            changed = true
        }

        guard changed else { return }
        if FileManager.default.fileExists(atPath: url.path) { backUp(url) }
        root["hooks"] = hooks
        write(root, to: url)
    }

    nonisolated static var grokHookURL: URL {
        grokHome().appendingPathComponent("hooks/nano.json")
    }

    nonisolated static func grokHome() -> URL {
        ProcessInfo.processInfo.environment["GROK_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".grok", isDirectory: true)
    }

    /// Honours `CODEX_HOME`, so a relocated Codex is found by both the
    /// installer and the remover — a remover that guessed `~/.codex` would
    /// leave hooks behind exactly where they were hardest to notice.
    nonisolated static var codexHooksURL: URL {
        codexHome.appendingPathComponent("hooks.json")
    }

    /// CODEX_HOME when set, else `~/.codex` — the same base `codexHooksURL`
    /// installs into.
    nonisolated static var codexHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
    }

    /// Codex runs a background memory-consolidation agent with cwd inside
    /// `<CODEX_HOME>/memories` and no rollout. Its hooks are real hook traffic
    /// but the session is internal, so the island must never record it.
    nonisolated static func isCodexInternalMemorySession(
        source: String,
        event: [String: Any],
        codexHome: URL? = nil
    ) -> Bool {
        guard source == AgentProviderID.codex.rawValue else { return false }
        guard let raw = (event["cwd"] as? String) ?? (event["workspaceRoot"] as? String),
              !raw.isEmpty
        else { return false }
        let memories = (codexHome ?? Self.codexHome)
            .appendingPathComponent("memories", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let cwd = URL(fileURLWithPath: raw, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        return cwd.path == memories.path || cwd.path.hasPrefix(memories.path + "/")
    }

    private static func installCodexHooks(bridge: String) {
        let url = codexHooksURL
        guard var root = load(url) else { return }
        guard Self.hasSupportedHookShape(root) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = command(bridge, source: "codex")

        guard let adapter = AgentProviderRegistry.adapter(for: .codex) else { return }
        let changed = merge(adapter.hooks, into: &hooks, command: command, bridge: bridge)

        guard changed else { return }
        backUp(url)
        root["hooks"] = hooks
        write(root, to: url)
    }

    /// Devin Desktop and the Devin CLI share one agent, which reads user hooks
    /// from `~/.config/devin/config.json` under a `"hooks"` key in the same
    /// nested shape as Claude's. The file can be JSONC with comments, so a
    /// parse failure means leave it alone rather than "fix" it. Appending only
    /// matters here too: Orca and Vibe Island already register their own
    /// handlers in this file.
    static func installDevinHooks(
        at url: URL = AgentRoutes.root(for: .devin).appendingPathComponent("config.json"),
        bridge: String
    ) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard var root = load(url) else { return }
        guard Self.hasSupportedHookShape(root) else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = command(bridge, source: "devin")

        guard let adapter = AgentProviderRegistry.adapter(for: .devin) else { return }
        let changed = merge(adapter.hooks, into: &hooks, command: command, bridge: bridge)

        guard changed else { return }
        backUp(url)
        root["hooks"] = hooks
        write(root, to: url)
    }

    nonisolated private static func contains(_ entry: [String: Any], _ bridge: String) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { ($0["command"] as? String)?.contains(bridge) == true }
    }

    /// One copy per file, taken immediately before the first change Nano makes
    /// to it, and never overwritten afterwards. The copy worth keeping is the
    /// file as it was before Nano existed, not as it was a moment ago.
    ///
    /// These files can hold API keys (an `env` block, Devin's 0600 config), so
    /// the copy is created owner-only rather than with the default 0644.
    nonisolated private static func backUp(_ url: URL) {
        let backup = URL(fileURLWithPath: url.path + ".nano-bak")
        if FileManager.default.fileExists(atPath: backup.path) {
            // A copy made by an older Nano is 0644; tighten it on the next edit.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        try? NanoStorage.writePrivate(data, to: backup)
    }

    // MARK: - Removal

    /// The bridge's filename, which is the one thing every entry Nano writes
    /// has in common. Matching on this rather than the current bridge path
    /// means hooks left by an older version — whose bridge lived elsewhere —
    /// are still removable, which is the case that would otherwise strand
    /// entries in a user's config forever.
    nonisolated static let bridgeMarker = "nano-agent-bridge"

    /// Takes Nano back out of every file `installHooks()` writes to.
    ///
    /// Surgical rather than restore-from-backup. These files are shared with
    /// the user's own hooks and with other tools', and may have been edited
    /// many times since Nano first touched them; rolling the whole file back
    /// would discard changes that were never Nano's to undo. Only entries whose
    /// command names the bridge are dropped, and a file holding nothing of
    /// Nano's is not rewritten at all — not even its mtime moves.
    /// Every agent Nano can hook into.
    nonisolated static let hookableProviders: [AgentProviderID] = [.claude, .codex, .gemini, .cursor, .kimi, .pi, .grok, .opencode, .devin]

    /// Removes Nano's hooks for the given agents, or for all of them.
    func uninstallHooks(for providers: [AgentProviderID] = AgentHookBridge.hookableProviders) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for provider in providers {
            switch provider {
            case .claude: Self.removeNestedHooks(from: home.appendingPathComponent(".claude/settings.json"))
            case .gemini: Self.removeNestedHooks(from: home.appendingPathComponent(".gemini/settings.json"))
            case .codex: Self.removeNestedHooks(from: Self.codexHooksURL)
            case .cursor: Self.removeCursorHooks(from: home.appendingPathComponent(".cursor/hooks.json"))
            case .kimi: Self.removeKimiHooks(from: home.appendingPathComponent(".kimi-code/config.toml"))
            case .grok: Self.removeGrokHooks(from: Self.grokHookURL)
            case .opencode: Self.removeOpenCodePlugin()
            case .devin:
                Self.removeNestedHooks(
                    from: AgentRoutes.root(for: .devin).appendingPathComponent("config.json")
                )
            case .pi:
                Self.removeNestedHooks(from: home.appendingPathComponent(".pi/agent/settings.json"))
                Self.removeOwnedPlugin(at: Self.piExtensionURL, resource: "nano-pi-extension", extension: "ts")
            default: break
            }
        }
        // Last, so that a failure above leaves the surviving hooks pointing at
        // a bridge that still exists rather than at a gap.
        if !Self.hooksAreInstalled() { Self.removeBridgeScript() }
        hooksInstalled = Self.hooksAreInstalled()
    }

    /// Claude, Codex, Gemini and Pi share one shape — event to entries, each
    /// entry holding an inner `hooks` array — so one remover covers four files.
    /// Removal needs no per-agent event list the way installation does: every
    /// event is swept, which also catches entries under names Nano no longer
    /// installs.
    nonisolated static func removeNestedHooks(from url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard var root = load(url) else { return }
        guard var hooks = root["hooks"] as? [String: Any] else { return }

        var changed = false
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            var eventChanged = false
            let kept = entries.compactMap { entry -> [String: Any]? in
                guard let handlers = entry["hooks"] as? [[String: Any]] else { return entry }
                let remaining = handlers.filter {
                    ($0["command"] as? String)?.contains(bridgeMarker) != true
                }
                guard remaining.count != handlers.count else { return entry }
                eventChanged = true
                guard !remaining.isEmpty else { return nil }
                var preserved = entry
                preserved["hooks"] = remaining
                return preserved
            }
            guard eventChanged else { continue }
            changed = true
            // An event left with no entries goes entirely. A bare `[]` is still
            // a trace of Nano in a file it was asked to leave.
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        guard changed else { return }

        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        finishRemoval(root, at: url)
    }

    /// A file with no copy beside it was created by Nano, so once it holds
    /// nothing it is deleted rather than left behind as `{}`.
    nonisolated private static func finishRemoval(_ root: [String: Any], at url: URL) {
        if root.isEmpty, !FileManager.default.fileExists(atPath: url.path + ".nano-bak") {
            try? FileManager.default.removeItem(at: url)
            return
        }
        backUp(url)
        write(root, to: url)
    }

    /// Cursor's flatter shape: an event maps straight to `{command, timeout}`
    /// with no inner array, so the match is one level shallower.
    nonisolated static func removeCursorHooks(from url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard var root = load(url) else { return }
        guard var hooks = root["hooks"] as? [String: Any] else { return }

        var changed = false
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter {
                ($0["command"] as? String)?.contains(bridgeMarker) != true
            }
            guard kept.count != entries.count else { continue }
            changed = true
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        guard changed else { return }

        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        finishRemoval(root, at: url)
    }

    /// Kimi's hooks are repeated `[[hooks]]` tables in a TOML file the user also
    /// writes by hand. Reserializing the document would cost them comments and
    /// formatting Nano has no business touching, so this deletes only the table
    /// bodies Nano appended and leaves every byte around them exactly as it was.
    nonisolated static func removeKimiHooks(from url: URL) {
        guard let existing = try? String(contentsOf: url, encoding: .utf8),
              existing.contains(bridgeMarker)
        else { return }

        var kept: [String] = []
        var table: [String] = []
        var isHooksTable = false

        func flush() {
            guard isHooksTable, table.joined(separator: "\n").contains(bridgeMarker) else {
                kept.append(contentsOf: table)
                table = []
                return
            }
            // Drop the blank line that separated this table from what precedes
            // it too, or the file grows a gap on every install/uninstall cycle.
            while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                kept.removeLast()
            }
            table = []
        }

        for line in existing.components(separatedBy: "\n") {
            // Any table header ends the previous table. Checked before the line
            // is filed, so the header belongs to the table it opens.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                flush()
                isHooksTable = line.trimmingCharacters(in: .whitespaces).hasPrefix("[[hooks]]")
            }
            table.append(line)
        }
        flush()

        backUp(url)
        var result = kept.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        writeConfig(Data(result.utf8), to: url)
    }

    /// Remove Nano handlers from its Grok file while preserving later user additions.
    nonisolated static func removeGrokHooks(from url: URL) {
        guard let before = try? Data(contentsOf: url) else { return }
        removeNestedHooks(from: url)
        // Delete the dedicated file only if removal left an empty configuration.
        if let after = try? Data(contentsOf: url), after != before,
           let root = load(url), root.isEmpty {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Existing plugin files may have user edits. Leave different contents
    /// alone, except a file whose hash says it is an older plugin of Nano's.
    nonisolated static func installOwnedPlugin(
        _ contents: Data, at url: URL, superseding: Set<String> = []
    ) {
        if let existing = try? Data(contentsOf: url) {
            let hash = SHA256.hash(data: existing).map { String(format: "%02x", $0) }.joined()
            guard existing != contents, superseding.contains(hash) else { return }
        } else if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        try? contents.write(to: url, options: .atomic)
    }

    nonisolated static func removeOwnedPlugin(at url: URL, matching contents: Data) {
        guard (try? Data(contentsOf: url)) == contents else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated private static func removeOwnedPlugin(at url: URL, resource: String, extension ext: String) {
        guard let source = Bundle.main.url(forResource: resource, withExtension: ext),
              let contents = try? Data(contentsOf: source) else { return }
        removeOwnedPlugin(at: url, matching: contents)
    }

    nonisolated private static func removeOpenCodePlugin() {
        removeOwnedPlugin(at: openCodePluginURL, resource: "nano-opencode-plugin", extension: "js")
    }

    nonisolated private static func removeBridgeScript() {
        guard let bridge = try? bridgeURL() else { return }
        try? FileManager.default.removeItem(at: bridge)
    }

    nonisolated static func load(_ url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Parse failure is not an empty config. Refusing to write is the
            // only safe choice when the existing file belongs to the user.
            return nil
        }
        return object
    }

    nonisolated static func hasSupportedHookShape(_ root: [String: Any]) -> Bool {
        guard let value = root["hooks"] else { return true }
        guard let hooks = value as? [String: Any] else { return false }
        return hooks.values.allSatisfy { $0 is [[String: Any]] }
    }

    nonisolated static func installationConfigURLs(
        for selected: Set<AgentProviderID>,
        homeDirectory: URL? = nil
    ) -> [URL] {
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        return installationProviders(selected, homeDirectory: homeDirectory).flatMap { provider -> [URL] in
            switch provider {
            case .claude: return [home.appendingPathComponent(".claude/settings.json")]
            case .codex: return [homeDirectory == nil ? codexHooksURL : home.appendingPathComponent(".codex/hooks.json")]
            case .gemini: return [home.appendingPathComponent(".gemini/settings.json")]
            case .cursor: return [home.appendingPathComponent(".cursor/hooks.json")]
            case .kimi: return [home.appendingPathComponent(".kimi-code/config.toml")]
            case .pi: return [
                home.appendingPathComponent(".pi/agent/settings.json"),
                homeDirectory == nil
                    ? piExtensionURL
                    : home.appendingPathComponent(".pi/agent/extensions/nano-agent-monitor.ts"),
            ]
            case .grok: return [homeDirectory == nil ? grokHookURL : home.appendingPathComponent(".grok/hooks/nano.json")]
            case .opencode: return [
                homeDirectory == nil
                    ? openCodePluginURL
                    : home.appendingPathComponent(".config/opencode/plugin/nano-opencode-plugin.js"),
            ]
            case .devin: return [home.appendingPathComponent(".config/devin/config.json")]
            default: return []
            }
        }
    }

    nonisolated private static func write(_ object: [String: Any], to url: URL) {
        // Without `.withoutEscapingSlashes` every path in the user's file comes
        // back as `\/Users\/...`. Key order cannot be kept through
        // JSONSerialization, so it stays sorted to at least be stable.
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        writeConfig(data, to: url)
    }

    /// Replaces another tool's config file in place.
    ///
    /// Dotfiles are often symlinks into a managed repo (stow, chezmoi). An
    /// atomic write to the link's path swaps the link for a plain file, so
    /// write through to the file it points at. An atomic write also replaces
    /// the inode, so a 0600 file such as Devin's config.json would silently
    /// come back 0644: carry the old mode over.
    nonisolated private static func writeConfig(_ data: Data, to url: URL) {
        let target = url.resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let permissions = (try? FileManager.default.attributesOfItem(atPath: target.path))
            .flatMap { $0[FileAttributeKey.posixPermissions] as? NSNumber }
        try? data.write(to: target, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: target.path
            )
        }
    }

    /// Every file `installHooks()` can write to, not just the two it used to
    /// check. After an uninstall this has to be able to report false, and a
    /// machine with only Cursor set up would otherwise have answered false all
    /// along while Nano was in fact installed there.
    nonisolated static func hookConfigURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ".claude/settings.json", ".gemini/settings.json", ".pi/agent/settings.json",
            ".cursor/hooks.json", ".kimi-code/config.toml", ".config/devin/config.json",
        ].map { home.appendingPathComponent($0) } + [codexHooksURL, grokHookURL]
    }

    nonisolated static var openCodePluginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugin/nano-opencode-plugin.js")
    }

    nonisolated static var piExtensionURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/extensions/nano-agent-monitor.ts")
    }

    /// Which files an uninstall would actually change, so the UI can name them
    /// before the user commits rather than list them afterwards.
    ///
    /// The shared configs are matched on content — they hold the user's hooks
    /// too. The OpenCode plugin is a file of Nano's own, so its mere presence
    /// is the answer and no marker need appear inside it.
    nonisolated static func installedHookConfigURLs() -> [URL] {
        var found = hookConfigURLs().filter { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains(bridgeMarker)
        }
        if FileManager.default.fileExists(atPath: openCodePluginURL.path) {
            found.append(openCodePluginURL)
        }
        if FileManager.default.fileExists(atPath: piExtensionURL.path) {
            found.append(piExtensionURL)
        }
        return found
    }

    nonisolated static func hooksAreInstalled() -> Bool {
        !installedHookConfigURLs().isEmpty
    }

    /// POSIX shell so it behaves identically however the agent invokes it.
    nonisolated static let bridgeScript = """
    #!/bin/sh
    # Installed by Nano. Forwards one agent hook event to the island and returns
    # the island's answer on stdout. Exits clean on every failure so the agent is
    # never blocked by Nano being closed.
    payload=$(cat 2>/dev/null)
    source="unknown"
    while [ $# -gt 0 ]; do
      case "$1" in
        --source) source="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    # T3 launches Grok CLI. Grok also runs Claude/Cursor hook files, so those
    # invocations arrive with --source claude or --source cursor. The runner
    # always injects GROK_* here; retag so the island attributes the turn to Grok.
    if [ -n "${GROK_HOOK_EVENT:-}" ] || [ -n "${GROK_SESSION_ID:-}" ]; then
      source="grok"
    fi

    transport="$HOME/Library/Application Support/Nano/run/hook-transport.json"
    [ -r "$transport" ] || { echo '{}'; exit 0; }

    # Foundation may escape slashes when it writes JSON. `plutil` decodes the
    # value instead of leaving a path such as `\\/Users\\/...` unusable.
    sock=$(/usr/bin/plutil -extract socketPath raw -o - "$transport" 2>/dev/null)
    token=$(/usr/bin/plutil -extract authToken raw -o - "$transport" 2>/dev/null)
    [ -S "$sock" ] || { echo '{}'; exit 0; }
    [ -n "$payload" ] || payload='{}'

    # The app that launched the agent (T3, Zed, a terminal). macOS sets this for
    # GUI-launched processes and children inherit it, so the island can jump
    # back to the right host. Restricted to bundle-ID characters for the JSON.
    host=$(printf '%s' "${__CFBundleIdentifier:-}" | tr -cd 'A-Za-z0-9.-')

    # Devin's hook payloads carry no cwd; it exports DEVIN_PROJECT_DIR to hook
    # processes instead. Escape the two characters JSON strings cannot hold
    # verbatim so the path survives as a value.
    project_dir=$(printf '%s' "${DEVIN_PROJECT_DIR:-}" | sed -e 's/\\\\/\\\\\\\\/g' -e 's/"/\\\\"/g' | tr -d '\\n')

    # This script and the shell the agent spawned. An agent that stops waiting
    # (Claude in bypass mode approves a command while its PermissionRequest
    # hook is still running) kills them, and the island retracts the card.
    # The socket cannot say so: nc half-closes as soon as it has sent.
    reply=$(printf '{"token":"%s","source":"%s","host_bundle_id":"%s","project_dir":"%s","hook_pids":[%s,%s],"event":%s}\\n' \\
      "$token" "$source" "$host" "$project_dir" "$$" "$PPID" "$payload" | nc -U "$sock" 2>/dev/null)

    if [ -n "$reply" ]; then echo "$reply"; else echo '{}'; fi
    exit 0
    """
}

// MARK: - Approval wording

/// One set of words for an approval, used by the island card, the Agents
/// module and the dashboard so the same request reads the same everywhere.
enum AgentApprovalCopy {
    /// "Claude wants to run a command", "… edit main.swift", "… use Slackbot: post message".
    static func headline(provider: String, tool: String, preview: AgentHookBridge.Preview) -> String {
        "\(provider) \(action(tool: tool, preview: preview))"
    }

    /// The headline without the provider: "Wants to run a command".
    static func shortHeadline(tool: String, preview: AgentHookBridge.Preview) -> String {
        let text = action(tool: tool, preview: preview)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func action(tool: String, preview: AgentHookBridge.Preview) -> String {
        switch preview {
        case .command where isShell(tool):
            return "wants to run a command"
        case let .diff(path, removed, _, _):
            let writes = ["write", "create"].contains(tool.lowercased()) && removed.isEmpty
            return "wants to \(writes ? "write" : "edit") \(path)"
        case .plan:
            return "wants you to approve a plan"
        default:
            break
        }
        switch tool.lowercased() {
        case "bash", "shell", "terminal", "exec", "exec_command", "shell_command":
            return "wants to run a command"
        case "edit", "multiedit", "write", "apply_patch", "notebookedit":
            return "wants to change files"
        case "read", "view":
            return "wants to read a file"
        case "glob", "grep", "ls", "search":
            return "wants to search files"
        case "webfetch", "web_fetch":
            return "wants to open a web page"
        case "websearch", "web_search":
            return "wants to search the web"
        case "task", "agent":
            return "wants to start a subagent"
        case "exitplanmode":
            return "wants you to approve a plan"
        default:
            return "wants to use \(toolName(tool))"
        }
    }

    /// `mcp__slackbot__post_message` → "Slackbot: post message"; `TodoWrite` → "Todo Write".
    static func toolName(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst(5).components(separatedBy: "__").filter { !$0.isEmpty }
            guard let server = parts.first else { return tool }
            let name = parts.dropFirst().joined(separator: " ")
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            let serverName = server.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
            return name.isEmpty ? serverName : "\(serverName): \(name)"
        }
        // CamelCase to words, keeping the first word's capital only.
        var words = ""
        for (index, character) in tool.enumerated() {
            if index > 0, character.isUppercase { words.append(" ") }
            words.append(character)
        }
        return words.replacingOccurrences(of: "_", with: " ")
    }

    /// Plan approvals answer with the plan's own words.
    static func optionLabel(_ option: AgentHookBridge.Option, preview: AgentHookBridge.Preview) -> String {
        guard case .plan = preview else { return option.label }
        switch option.id {
        case 1: return "Approve plan"
        case 0: return "Keep planning"
        default: return option.label
        }
    }

    /// "2 lines added, 1 removed": what the edit tries to change.
    static func diffSummary(removed: Int, added: Int) -> String? {
        func lines(_ count: Int) -> String { count == 1 ? "1 line" : "\(count) lines" }
        switch (added, removed) {
        case (0, 0): return nil
        case (_, 0): return "\(lines(added)) added"
        case (0, _): return "\(lines(removed)) removed"
        default: return "\(lines(added)) added, \(removed) removed"
        }
    }

    /// A long chained command, broken before each `&&`, `||` and `;` so the
    /// whole thing can be read.
    static func readableCommand(_ command: String) -> String {
        guard !command.contains("\n"), command.count > 70 else { return command }
        return command
            .replacingOccurrences(of: " && ", with: "\n&& ")
            .replacingOccurrences(of: " || ", with: "\n|| ")
            .replacingOccurrences(of: "; ", with: ";\n")
    }

    /// Lines the readable command takes at about `perLine` characters a line.
    static func wrappedLineCount(_ command: String, perLine: Int = 70) -> Int {
        readableCommand(command).split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(($1.count + perLine - 1) / perLine, 1) }
    }

    private static func isShell(_ tool: String) -> Bool {
        ["bash", "shell", "terminal", "exec", "exec_command", "shell_command"].contains(tool.lowercased())
    }
}

// MARK: - Sessions another agent started

/// Sessions that an agent started for itself, such as a `claude -p` run from
/// a Bash tool to test something, or a headless script in a temp folder.
/// They are not the user's work, so they never become rows.
///
/// A nested run is only recognisable while it runs, from its process tree.
/// Its ID is remembered on disk so later transcript scans skip it too.
final class AgentSpawnedSessions: @unchecked Sendable {
    static let shared = AgentSpawnedSessions(
        storeURL: NanoStorage.root.appendingPathComponent("spawned-agent-sessions.json")
    )

    /// Process names of agent CLIs. A wrapper that starts the real binary
    /// directly (npm's `codex` launcher) is one agent, not two.
    nonisolated static let agentProcessNames: Set<String> = [
        "claude", "codex", "gemini", "grok", "devin", "opencode", "cursor-agent",
        "kimi", "pi", "droid", "amp", "copilot", "qwen", "auggie", "kiro-cli",
    ]
    private static let limit = 1000

    private let storeURL: URL
    private let lock = NSLock()
    private var ids: [String]?

    init(storeURL: URL) {
        self.storeURL = storeURL
    }

    func contains(_ sessionID: String) -> Bool {
        lock.withLock { loaded().contains(sessionID) }
    }

    /// For transcript scans, which have no process tree to look at. A
    /// headless run (`claude -p`, an SDK script, `codex exec`) in a temp
    /// folder is an agent's scratch work even when Nano missed it live.
    func hides(sessionID: String, workingDirectory: String?, isHeadless: Bool) -> Bool {
        (isHeadless && Self.isTemporaryDirectory(workingDirectory)) || contains(sessionID)
    }

    /// For hook events. `isKnown` sessions are already rows and are not
    /// looked at again.
    func hides(
        sessionID: String,
        hookPIDs: [Int32],
        isKnown: Bool,
        lookup: (Int32) -> (parent: Int32, name: String)? = AgentSpawnedSessions.process
    ) -> Bool {
        if contains(sessionID) { return true }
        if isKnown { return false }
        guard hookPIDs.contains(where: { Self.isNested(startingAt: $0, lookup: lookup) })
        else { return false }
        remember(sessionID)
        return true
    }

    func remember(_ sessionID: String) {
        lock.withLock {
            var current = loaded()
            guard !current.contains(sessionID) else { return }
            current.append(sessionID)
            ids = Array(current.suffix(Self.limit))
            if let data = try? JSONSerialization.data(withJSONObject: ids ?? []) {
                try? FileManager.default.createDirectory(
                    at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? data.write(to: storeURL, options: .atomic)
            }
        }
    }

    private func loaded() -> [String] {
        if let ids { return ids }
        let stored = (try? Data(contentsOf: storeURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        ids = stored
        return stored
    }

    nonisolated static func isTemporaryDirectory(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        return roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Walks up from a hook process. The first agent above it is the session's
    /// own; a second one, past a shell or anything else, started that agent.
    nonisolated static func isNested(
        startingAt pid: Int32,
        lookup: (Int32) -> (parent: Int32, name: String)?
    ) -> Bool {
        var current = pid
        var agentsSeen = 0
        var previousWasAgent = false
        for _ in 0 ..< 64 {
            guard current > 1, let process = lookup(current) else { return false }
            let isAgent = agentProcessNames.contains(process.name.lowercased())
            if isAgent, !previousWasAgent {
                agentsSeen += 1
                if agentsSeen == 2 { return true }
            }
            previousWasAgent = isAgent
            current = process.parent
        }
        return false
    }

    nonisolated static func process(_ pid: Int32) -> (parent: Int32, name: String)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // The kernel's name is the binary's file name, which for Claude is
        // its version ("2.1.305"). The name it was launched by is `argv[0]`.
        let name = argumentZero(pid).map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
        return (info.kp_eproc.e_ppid, name)
    }

    /// KERN_PROCARGS2 is argc, the executable path, padding, then argv.
    nonisolated private static func argumentZero(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }
        return String(decoding: buffer[start ..< index], as: UTF8.self)
    }
}

// MARK: - Socket server

/// Minimal line-oriented Unix socket server: one JSON request per connection,
/// one JSON response, then close — which is what a blocking hook needs.
private final class HookSocketServer: @unchecked Sendable {
    var onEvent: (@Sendable (Data) async -> Data?)?
    var expectedToken = ""

    private var descriptor: Int32 = -1
    private var socketPath: String?
    private let queue = DispatchQueue(
        label: "com.nanoapp.hook-socket",
        qos: .utility,
        attributes: .concurrent
    )
    private var running = false

    @discardableResult
    func start(at path: String) -> Bool {
        stop()
        // Another Nano already answering here keeps its socket. Unlinking it
        // would leave that instance deaf with no way to notice.
        guard !Self.isAnswering(at: path) else { return false }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard let base = raw.baseAddress else { return }
            _ = path.withCString { source in
                strncpy(base.assumingMemoryBound(to: CChar.self), source, raw.count - 1)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return false
        }

        chmod(path, 0o600)
        descriptor = fd
        socketPath = path
        running = true
        queue.async { [weak self] in self?.acceptLoop(fd) }
        return true
    }

    /// True when a live server accepts connections on `path`. A leftover
    /// socket file from a process that died refuses them.
    private static func isAnswering(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard let base = raw.baseAddress else { return }
            _ = path.withCString { source in
                strncpy(base.assumingMemoryBound(to: CChar.self), source, raw.count - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        } == 0
    }

    func stop() {
        running = false
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        if let socketPath {
            unlink(socketPath)
            self.socketPath = nil
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while running {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if !running { return }
                // Out of descriptors (EMFILE) fails at once; without a pause
                // this loop pins a core until one frees up.
                usleep(50_000)
                continue
            }
            // Concurrent, so one waiting permission prompt cannot stall the
            // liveness events arriving behind it.
            queue.async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        // A hook that times out hangs up before its reply; without this the
        // late `send` raises SIGPIPE and terminates Nano.
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var buffer = [UInt8](repeating: 0, count: 65_536)
        var data = Data()
        while true {
            let read = recv(client, &buffer, buffer.count, 0)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
            if data.last == UInt8(ascii: "\n") { break }
            if data.count > 4_000_000 { break }
        }

        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["token"] as? String) == expectedToken,
              let onEvent
        else {
            reply(Data("{}\n".utf8), to: client)
            return
        }
        _ = object

        // The hook holds its stdout open until this returns, which is the whole
        // mechanism behind an in-island permission prompt.
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let request = data
        Task {
            box.value = await onEvent(request)
            semaphore.signal()
        }
        semaphore.wait()

        var payload = box.value ?? Data("{}".utf8)
        payload.append(0x0A)
        reply(payload, to: client)
    }

    private func reply(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = send(client, base, raw.count, 0)
        }
    }
}

/// Carries the async result back to the blocked socket thread.
private final class ResponseBox: @unchecked Sendable {
    var value: Data?
}
