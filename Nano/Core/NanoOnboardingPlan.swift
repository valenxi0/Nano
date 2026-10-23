import Foundation

enum NanoOnboardingPlan {
    /// The agents Nano supports end to end, in the order setup lists them.
    static let agentProviders: [AgentProviderID] = [
        .claude, .codex, .cursor, .devin, .gemini, .grok, .kimi, .opencode, .pi,
    ]
}

/// Setup that is still open after onboarding. Shared by the last setup step
/// and the Settings card, so both always agree on what is left.
struct NanoSetupChecklist: Equatable {
    enum Item: String, CaseIterable, Identifiable, Sendable {
        case connectAgents
        case allowMicrophone
        case downloadVoiceModel
        case allowFullDiskAccess
        case allowSessionJump
        case allowAutoPaste

        var id: String { rawValue }

        var title: String {
            switch self {
            case .connectAgents: "Connect your agents"
            case .allowMicrophone: "Allow the microphone"
            case .downloadVoiceModel: "Download a voice model"
            case .allowFullDiskAccess: "Allow Full Disk Access"
            case .allowSessionJump: "Jump into sessions"
            case .allowAutoPaste: "Paste dictation automatically"
            }
        }

        var detail: String {
            switch self {
            case .connectAgents: "Hooks send approvals and questions to the island."
            case .allowMicrophone: "Dictation cannot listen until macOS allows it."
            case .downloadVoiceModel: "Transcription runs on this Mac once a model is on disk."
            case .allowFullDiskAccess: "Nano reads Notification Center to mirror your notifications."
            case .allowSessionJump: "Accessibility lets a click on a session open its window."
            case .allowAutoPaste: "Accessibility pastes text for you. The clipboard works without it."
            }
        }

        var symbol: String {
            switch self {
            case .connectAgents: "link"
            case .allowMicrophone: "mic.fill"
            case .downloadVoiceModel: "arrow.down.circle"
            case .allowFullDiskAccess: "externaldrive.fill"
            case .allowSessionJump: "arrow.up.forward.app"
            case .allowAutoPaste: "doc.on.clipboard"
            }
        }

        /// Optional items improve a feature that already works without them.
        var isOptional: Bool {
            self == .allowSessionJump || self == .allowAutoPaste
        }
    }

    struct Facts: Equatable, Sendable {
        var agentsEnabled = false
        var hookableAgentsFound = false
        var hooksInstalled = false
        var accessibilityTrusted = false
        var voiceEnabled = false
        var microphoneAuthorized = false
        var voiceModelReady = false
        var systemNotificationsEnabled = false
        var fullDiskAccess = false
    }

    let items: [Item]

    init(_ facts: Facts) {
        var items: [Item] = []
        if facts.agentsEnabled, facts.hookableAgentsFound, !facts.hooksInstalled {
            items.append(.connectAgents)
        }
        if facts.voiceEnabled, !facts.microphoneAuthorized { items.append(.allowMicrophone) }
        if facts.voiceEnabled, !facts.voiceModelReady { items.append(.downloadVoiceModel) }
        if facts.systemNotificationsEnabled, !facts.fullDiskAccess { items.append(.allowFullDiskAccess) }
        if facts.agentsEnabled, !facts.accessibilityTrusted { items.append(.allowSessionJump) }
        if facts.voiceEnabled, !facts.accessibilityTrusted { items.append(.allowAutoPaste) }
        self.items = items
    }

    var required: [Item] { items.filter { !$0.isOptional } }
    var hasRequiredItems: Bool { !required.isEmpty }
}
