import Foundation

/// Provider-specific behavior behind one stable Nano interface.
///
/// A hook event is not a universal protocol: Claude and Codex expect a nested
/// response, OpenCode's plugin expects a flat response, and the remaining
/// providers do not currently expose a safe hook decision path. Keeping those
/// facts here prevents generic UI code from pretending every provider can do
/// the same thing.
struct AgentProviderAdapter: Equatable, Sendable {
    enum Control: String, CaseIterable, Sendable {
        case observeActivity
        case detectCompletion
        case approvePermission
        case answerStructuredQuestion
    }

    enum Integration: String, Sendable {
        case nestedHooks
        case flatHooks
        case plugin
        case extensionScript
    }

    enum DecisionEncoding: Equatable, Sendable {
        case hookSpecificOutput
        case legacyFlat
        /// Devin: `{"decision": "approve" | "block", "reason": …}`.
        case approveBlock
        case unavailable
    }

    struct Hook: Equatable, Sendable {
        let event: String
        let timeout: Int
        var matcher: String?
    }

    let provider: AgentProviderID
    let integration: Integration
    let controls: Set<Control>
    let hooks: [Hook]
    let decisionEncoding: DecisionEncoding
    /// The agent's own ask-the-user tool, as its hooks name it. Seeing it in
    /// a pre-tool event means the agent is blocked on a question.
    var questionTool: String? = nil

    func permissionResponse(allowed: Bool, message: String? = nil) -> [String: Any]? {
        switch decisionEncoding {
        case .hookSpecificOutput:
            var decision: [String: Any] = ["behavior": allowed ? "allow" : "deny"]
            if let message, !message.isEmpty { decision["message"] = message }
            return [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": decision,
                ],
            ]
        case .legacyFlat:
            return ["permissionDecision": allowed ? "allow" : "deny"]
        case .approveBlock:
            var response: [String: Any] = ["decision": allowed ? "approve" : "block"]
            if let message, !message.isEmpty { response["reason"] = message }
            return response
        case .unavailable:
            return nil
        }
    }

    func questionResponse(
        originalInput: [String: Any],
        question: String,
        answer: String
    ) -> [String: Any]? {
        guard controls.contains(.answerStructuredQuestion) else { return nil }
        // OpenCode's plugin turns this into its own reply call.
        if decisionEncoding == .legacyFlat { return ["answer": answer] }
        guard decisionEncoding == .hookSpecificOutput else { return nil }

        var updatedInput = originalInput
        var answers = updatedInput["answers"] as? [String: Any] ?? [:]
        answers[question] = answer
        updatedInput["answers"] = answers
        return [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": updatedInput,
            ],
        ]
    }
}

enum AgentProviderRegistry {
    private static let interactiveControls: Set<AgentProviderAdapter.Control> = [
        .observeActivity, .detectCompletion, .approvePermission,
    ]
    private static let observeControls: Set<AgentProviderAdapter.Control> = [
        .observeActivity, .detectCompletion,
    ]

    static let adapters: [AgentProviderAdapter] = [
        AgentProviderAdapter(
            provider: .claude,
            integration: .nestedHooks,
            controls: interactiveControls.union([.answerStructuredQuestion]),
            hooks: [
                .init(event: "PermissionRequest", timeout: 86_400),
                .init(event: "PreToolUse", timeout: 86_400, matcher: "AskUserQuestion"),
                .init(event: "Notification", timeout: 5),
                .init(event: "SessionStart", timeout: 5),
                .init(event: "SessionEnd", timeout: 5),
                .init(event: "UserPromptSubmit", timeout: 5),
                .init(event: "PostToolUse", timeout: 5),
                .init(event: "SubagentStart", timeout: 5),
                .init(event: "SubagentStop", timeout: 5),
                .init(event: "PreCompact", timeout: 5),
                .init(event: "PostCompact", timeout: 5),
                .init(event: "Stop", timeout: 5),
            ],
            decisionEncoding: .hookSpecificOutput,
            questionTool: "AskUserQuestion"
        ),
        AgentProviderAdapter(
            provider: .codex,
            integration: .nestedHooks,
            controls: interactiveControls,
            hooks: [
                .init(event: "SessionStart", timeout: 5, matcher: "*"),
                .init(event: "UserPromptSubmit", timeout: 5, matcher: "*"),
                .init(event: "PostToolUse", timeout: 5, matcher: "*"),
                .init(event: "PermissionRequest", timeout: 86_400, matcher: "*"),
                // Watch only: a hook can rewrite this tool's input but not
                // supply its answer, so the card points back to Codex.
                .init(event: "PreToolUse", timeout: 5, matcher: "request_user_input"),
                .init(event: "Stop", timeout: 5, matcher: "*"),
                .init(event: "SessionEnd", timeout: 3, matcher: "*"),
            ],
            decisionEncoding: .hookSpecificOutput,
            questionTool: "request_user_input"
        ),
        AgentProviderAdapter(
            provider: .cursor,
            integration: .flatHooks,
            controls: observeControls,
            hooks: [],
            decisionEncoding: .unavailable
        ),
        AgentProviderAdapter(
            provider: .gemini,
            integration: .nestedHooks,
            controls: observeControls,
            hooks: [],
            decisionEncoding: .unavailable
        ),
        AgentProviderAdapter(
            provider: .grok,
            integration: .nestedHooks,
            controls: observeControls,
            hooks: [],
            decisionEncoding: .unavailable,
            // Grok ignores `updatedInput` here (checked live), so its
            // questions are shown but answered in Grok.
            questionTool: "ask_user_question"
        ),
        AgentProviderAdapter(
            provider: .kimi,
            integration: .nestedHooks,
            controls: observeControls,
            hooks: [],
            decisionEncoding: .unavailable
        ),
        AgentProviderAdapter(
            provider: .opencode,
            integration: .plugin,
            controls: interactiveControls.union([.answerStructuredQuestion]),
            hooks: [],
            decisionEncoding: .legacyFlat,
            questionTool: "question"
        ),
        AgentProviderAdapter(
            provider: .pi,
            integration: .extensionScript,
            controls: observeControls,
            hooks: [],
            decisionEncoding: .unavailable
        ),
        // Devin Desktop and the Devin CLI share one agent and one hook file,
        // `~/.config/devin/config.json`, in the nested Claude shape.
        // `PermissionRequest` fires only when Devin would ask, and Devin's own
        // prompt stays usable while the hook waits (checked live through
        // `devin acp`), so the long timeout never strands an answer given there.
        AgentProviderAdapter(
            provider: .devin,
            integration: .nestedHooks,
            controls: interactiveControls,
            hooks: [
                .init(event: "SessionStart", timeout: 5),
                .init(event: "UserPromptSubmit", timeout: 5),
                .init(event: "PostToolUse", timeout: 5),
                .init(event: "PermissionRequest", timeout: 86_400),
                // Watch only: answering through `updatedInput` is unverified.
                .init(event: "PreToolUse", timeout: 5, matcher: "^ask_user_question$"),
                .init(event: "Stop", timeout: 5),
                .init(event: "PostCompaction", timeout: 5),
                .init(event: "SessionEnd", timeout: 3),
            ],
            decisionEncoding: .approveBlock,
            questionTool: "ask_user_question"
        ),
    ]

    private static let byProvider = Dictionary(uniqueKeysWithValues: adapters.map {
        ($0.provider, $0)
    })

    static func adapter(for provider: AgentProviderID) -> AgentProviderAdapter? {
        byProvider[provider]
    }

    static func adapter(source: String, providerID: String? = nil) -> AgentProviderAdapter? {
        // Controls belong to the host transport, not the model vendor running
        // inside it. OpenCode using Kimi still speaks the OpenCode protocol.
        if let host = AgentProviderID(rawValue: source.lowercased()),
           let adapter = adapter(for: host) {
            return adapter
        }
        return AgentProviderID.fromHook(source: source, providerID: providerID).flatMap(adapter(for:))
    }
}


extension AgentProviderRegistry {
    static func notificationContext(source: String, host: AgentSessionJump.Host? = nil,
                                    explicitBundleID: String? = nil, sessionTitle: String? = nil) -> AgentNotificationContext {
        if let bundle = explicitBundleID, !bundle.isEmpty {
            return AgentNotificationContext(bundleIDs: [bundle.lowercased()], sessionTitle: sessionTitle)
        }
        let bundles: Set<String>
        if let host {
            switch host {
            case .codex: bundles = [AgentSessionJump.codexBundleID]
            case .claude: bundles = [AgentSessionJump.claudeBundleID]
            case .cursor: bundles = [AgentSessionJump.cursorBundleID]
            case .t3: bundles = [AgentSessionJump.t3BundleID]
            case .terminal: bundles = Set(AgentSessionJump.terminalBundleIDs)
            case .folder, .app: bundles = []
            }
        } else {
            switch source.lowercased() {
            case "codex": bundles = [AgentSessionJump.codexBundleID]
            case "claude": bundles = [AgentSessionJump.claudeBundleID]
            case "cursor": bundles = [AgentSessionJump.cursorBundleID]
            case "devin", "windsurf": bundles = ["com.exafunction.windsurf"]
            default: bundles = []
            }
        }
        return AgentNotificationContext(bundleIDs: Set(bundles.map { $0.lowercased() }), sessionTitle: sessionTitle)
    }
}
