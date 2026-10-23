import AppKit
import Foundation
import SwiftUI

/// Sources the island can announce without opening a module.
///
/// Distinct from `NanoModuleID`: a module is something you open. These fire
/// on their own while the island is collapsed.
enum IslandNotificationSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case volume
    case brightness
    case bluetooth
    case battery
    case timer
    case agent
    case system

    var id: String { rawValue }

    /// The Labs iMessage source became the full Notification Center source.
    static let legacyMessagesRawValue = "messages"

    var title: String {
        switch self {
        case .volume: "Volume"
        case .brightness: "Brightness"
        case .bluetooth: "Bluetooth"
        case .battery: "Battery"
        case .timer: "Timer"
        case .agent: "Agents"
        case .system: "Notifications"
        }
    }

    var subtitle: String {
        switch self {
        case .volume: "Show the island when the volume keys change the output level."
        case .brightness: "Show the island when the brightness keys change the display."
        case .bluetooth: "Announce AirPods, mice, keyboards, and other accessories connecting or leaving."
        case .battery: "Announce when a laptop starts charging."
        case .timer: "Announce completed timers without opening the Timer module automatically."
        case .agent: "Show when an agent finishes, needs approval, asks a question, or is waiting on you."
        case .system: "Show every macOS notification in the island: iMessage, calls, Mail, and any app. Requires Full Disk Access to read the Notification Center store."
        }
    }

    var symbol: String {
        switch self {
        case .volume: "speaker.wave.2.fill"
        case .brightness: "sun.max.fill"
        case .bluetooth: "wave.3.right"
        case .battery: "battery.100percent.bolt"
        case .timer: "timer"
        case .agent: "terminal.fill"
        case .system: "bell.badge.fill"
        }
    }

    /// Higher wins when two announcements want the island at once.
    var priority: Int {
        switch self {
        case .agent: 100
        case .system: 80
        case .timer: 75
        case .bluetooth: 60
        case .battery: 40
        case .volume, .brightness: 20
        }
    }

    /// Small HUDs ride below an open dashboard instead of replacing it.
    var docksBelowDashboard: Bool {
        switch self {
        case .volume, .brightness, .bluetooth, .battery, .timer: true
        case .agent, .system: false
        }
    }

    /// Seconds on screen. `nil` stays until the user acts — used for an agent
    /// that is blocked on a decision.
    var defaultDuration: TimeInterval? {
        switch self {
        case .volume, .brightness: 1.6
        case .bluetooth: 4.8
        case .battery: 3.4
        case .timer: 5.0
        case .system: 6.5
        case .agent: nil
        }
    }
}

enum BluetoothAccessoryCategory: String, Sendable {
    case headphones
    case headset
    case keyboard
    case mouse
    case trackpad
    case gameController
    case phone
    case computer
    case other

    var symbol: String {
        switch self {
        case .headphones: "headphones"
        case .headset: "headset"
        case .keyboard: "keyboard.fill"
        case .mouse: "computermouse.fill"
        case .trackpad: "magicmouse.fill"
        case .gameController: "gamecontroller.fill"
        case .phone: "iphone"
        case .computer: "laptopcomputer"
        case .other: "wave.3.right"
        }
    }

    var label: String {
        switch self {
        case .headphones: "Headphones"
        case .headset: "Headset"
        case .keyboard: "Keyboard"
        case .mouse: "Mouse"
        case .trackpad: "Trackpad"
        case .gameController: "Controller"
        case .phone: "iPhone"
        case .computer: "Computer"
        case .other: "Accessory"
        }
    }

    /// IOBluetooth class bits plus the advertised name. Name wins for AirPods
    /// because Apple reports them as generic audio devices.
    static func classify(name: String, major: UInt32, minor: UInt32) -> Self {
        let lowered = name.lowercased()
        if lowered.contains("airpods") || lowered.contains("headphone")
            || lowered.contains("buds") || lowered.contains("beats") {
            return .headphones
        }
        if lowered.contains("keyboard") { return .keyboard }
        if lowered.contains("trackpad") { return .trackpad }
        if lowered.contains("mouse") { return .mouse }
        if lowered.contains("iphone") || lowered.contains("ipad") { return .phone }
        if lowered.contains("macbook") || lowered.contains("imac") { return .computer }

        // Bluetooth assigned numbers: major class in the high bits the stack
        // already isolated for us.
        switch major {
        case 1: return .computer
        case 2: return .phone
        case 4:
            return (minor & 0x04) != 0 ? .headset : .headphones
        case 5:
            switch minor & 0x3F {
            case 1, 3: return .keyboard
            case 2, 4: return .mouse
            case 5...7: return .gameController
            default: return .other
            }
        default:
            return .other
        }
    }
}

/// A plan, as far as the island needs it: a title and its top-level steps.
struct AgentPlanSummary: Equatable, Sendable {
    static let visibleSteps = 5

    let title: String?
    let steps: [String]

    static func parse(_ markdown: String) -> AgentPlanSummary {
        var title: String?
        var steps: [String] = []
        var paragraphs: [String] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            // Nested items belong to the step above them.
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                if title == nil { title = clean(String(line.drop { $0 == "#" })) }
                continue
            }
            guard indent < 2 else { continue }
            if let range = line.range(of: #"^(\d+[.)]|[-*•])\s+"#, options: .regularExpression) {
                steps.append(clean(String(line[range.upperBound...])))
            } else {
                paragraphs.append(clean(line))
            }
        }
        if steps.isEmpty { steps = Array(paragraphs.prefix(8)) }
        return AgentPlanSummary(title: title, steps: steps.filter { !$0.isEmpty })
    }

    /// Markdown emphasis and code ticks read as noise at this size.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

struct IslandAgentAttention: Equatable, Sendable {
    let requestID: String
    let kind: AgentHookBridge.RequestKind
    let source: String
    let title: String
    let detail: String?
    let options: [AgentHookBridge.Option]
    let sessionID: String?
    let projectName: String?
    let respondsThroughBridge: Bool
    let preview: AgentHookBridge.Preview

    init(_ request: AgentHookBridge.PendingRequest) {
        requestID = request.id
        kind = request.kind
        source = request.source
        title = request.title
        detail = request.detail
        options = request.options
        sessionID = request.sessionID
        projectName = request.projectName
        respondsThroughBridge = request.respondsThroughBridge
        preview = request.preview
    }

    var headline: String {
        switch kind {
        case .permission:
            return respondsThroughBridge ? "\(source.capitalized) wants to run \(title)" : title
        case .question:
            return title
        case .notification:
            return title
        case .completion:
            let lowered = title.lowercased()
            if lowered.contains("finished") || lowered.contains("completed")
                || lowered.contains("failed") || lowered.contains("done") {
                return title
            }
            return "\(title) finished"
        }
    }

    var isSticky: Bool {
        kind == .permission || kind == .question || !options.isEmpty
    }

    /// Blocking decisions must interrupt informational agent updates, while a
    /// completion still outranks passive provider activity.
    var priority: Int {
        switch kind {
        case .permission, .question: 120
        case .completion: 90
        case .notification: 85
        }
    }

    /// The host that sent the request owns the controls and the visual identity.
    /// OpenCode running a Kimi model still uses OpenCode's plugin protocol.
    var provider: AgentProviderID? {
        AgentProviderRegistry.adapter(source: source)?.provider
            ?? AgentProviderID.fromHook(source: source)
    }

    var providerName: String {
        provider?.title ?? source.capitalized
    }

    var isFailure: Bool {
        let value = title.lowercased()
        return value.contains("failed") || value.hasPrefix("error:") || value == "error"
    }

    var commandPreview: String? {
        guard kind == .permission else { return nil }
        if case let .command(command) = preview { return command }
        return permissionSubject == "Terminal" ? detail : nil
    }

    var statusLabel: String {
        if isFailure { return "Error" }
        return switch kind {
        case .permission, .question:
            "Needs you"
        case .completion:
            "Done"
        case .notification:
            "Update"
        }
    }

    var displayHeadline: String {
        switch kind {
        case .permission:
            if respondsThroughBridge {
                return AgentApprovalCopy.headline(provider: providerName, tool: title, preview: preview)
            }
            return "Approval waiting in \(providerName)"
        case .question:
            if respondsThroughBridge { return title }
            return "Question waiting in \(providerName)"
        case .completion:
            return isFailure ? title : "\(providerName) finished"
        case .notification:
            return title
        }
    }

    var displayDetail: String? {
        switch kind {
        case .permission:
            if respondsThroughBridge { return permissionSummary }
            return title
        case .question:
            if respondsThroughBridge {
                return detail ?? "Choose an answer so the agent can continue."
            }
            return title
        case .completion:
            return detail ?? projectName ?? "The agent finished its turn."
        case .notification:
            return detail ?? projectName
        }
    }

    /// The plan behind a plan-approval request, parsed for the card.
    var plan: AgentPlanSummary? {
        guard kind == .permission, case let .plan(markdown) = preview else { return nil }
        return AgentPlanSummary.parse(markdown)
    }

    var cardHeight: CGFloat {
        if let plan {
            // Header, title, up to five steps, the "more" line, then the footer.
            let steps = CGFloat(min(plan.steps.count, AgentPlanSummary.visibleSteps))
            let more: CGFloat = plan.steps.count > AgentPlanSummary.visibleSteps ? 20 : 0
            return 24 + 26 + 12 + 24 + steps * 24 + more + 16 + 42
        }
        return switch kind {
        case .question where respondsThroughBridge && !options.isEmpty:
            max(126 + CGFloat(options.count) * 40, measuredCardHeight)
        case .permission:
            max(196, measuredCardHeight)
        case .question:
            max(150, measuredCardHeight)
        case .completion:
            isFailure ? 154 : 86
        case .notification:
            isFailure ? 154 : 100
        }
    }

    /// The standard card measured at its real width: padding, header, the
    /// headline, the detail or command, the choices, and the footer, matching
    /// `AgentNotificationCard`. A long question or long option labels wrap,
    /// and the island grows with them instead of cutting off the buttons.
    var measuredCardHeight: CGFloat {
        let textWidth = Self.cardWidth - 40
        var content = 12 + Self.textHeight(displayHeadline, size: 16, weight: .semibold, width: textWidth, maxLines: 2)
        if let commandPreview {
            content += 4 + Self.commandBoxHeight(commandPreview)
        } else if let detail = displayDetail, !detail.isEmpty {
            content += 4 + Self.textHeight(detail, size: 10.5, weight: .regular, width: textWidth, maxLines: 2)
        }
        if kind == .question, respondsThroughBridge, !options.isEmpty {
            // Each choice: 10pt insets, a 13pt check, 9pt spacing, then its label.
            let labelWidth = textWidth - 20 - 13 - 9
            let rows = options.map { option in
                max(34, Self.textHeight(option.label, size: 11, weight: .medium, width: labelWidth, maxLines: 2) + 14)
            }
            content += 4 + 6 + rows.reduce(0, +) + CGFloat(rows.count - 1) * 4
        }
        let footer: CGFloat = 1 + 36
        return (24 + 26 + content + footer).rounded(.up)
    }

    static let cardWidth: CGFloat = 640
    static let commandCharactersPerLine = 84
    static let commandVisibleLines = 6

    /// The command box grows with the command up to six lines, then scrolls.
    static func commandBoxHeight(_ command: String) -> CGFloat {
        let lines = min(AgentApprovalCopy.wrappedLineCount(command, perLine: commandCharactersPerLine), commandVisibleLines)
        return 20 + CGFloat(max(lines, 1)) * 14
    }

    private static func textHeight(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        width: CGFloat,
        maxLines: Int
    ) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lines = min(max(Int((bounds.height / lineHeight).rounded(.up)), 1), maxLines)
        return CGFloat(lines) * lineHeight
    }

    private var permissionSubject: String {
        switch title.lowercased() {
        case "bash", "shell", "terminal", "exec", "exec_command", "shell_command":
            "Terminal"
        case "edit", "multiedit", "write", "apply_patch":
            "Files"
        case "webfetch", "websearch", "web_fetch", "web_search":
            "Network"
        default:
            title
        }
    }

    private var permissionSummary: String? {
        switch preview {
        case let .command(command):
            let summary = AgentToolLabel.shellSummary(command)
            guard !summary.isEmpty else { return detail }
            return "Run \(AgentToolLabel.truncated(summary, 96))."
        case let .diff(path, _, _, _):
            return "Change \(path)."
        case let .arguments(fields):
            return fields.joined(separator: " · ")
        case .plan:
            return "Review the plan."
        case .none:
            guard let detail, !detail.isEmpty else { return projectName }
            if ["bash", "shell", "terminal", "exec", "exec_command", "shell_command"]
                .contains(title.lowercased()) {
                return "Run \(AgentToolLabel.truncated(AgentToolLabel.shellSummary(detail), 96))."
            }
            if detail.hasPrefix("/") {
                return "Access \(URL(fileURLWithPath: detail).lastPathComponent)."
            }
            return AgentToolLabel.truncated(detail, 100)
        }
    }
}

struct IslandNotification: Identifiable, Equatable, Sendable {
    /// Keeps notification content clear of the display edge in both attached
    /// and floating placements.
    static let topContentClearance: CGFloat = 8

    enum Payload: Equatable, Sendable {
        case level(Double, muted: Bool)
        case bluetooth(category: BluetoothAccessoryCategory, connected: Bool)
        case battery(BatterySnapshot)
        case timer(mode: FocusTimerMode, configuredDuration: TimeInterval)
        case system(SystemNotificationContent)
        case agent(IslandAgentAttention)
        /// A supported agent appeared on this Mac without Nano's hooks.
        case agentSetup(AgentProviderID)
        case update(NanoUpdate)
        /// Something Quill learned from the user's fixes, offered to keep.
        case quillSuggestion(VoiceDictationCorrection)
    }

    let id: UUID
    let source: IslandNotificationSource
    let title: String
    let subtitle: String?
    let symbol: String
    let duration: TimeInterval?
    let coalesceKey: String
    let payload: Payload
    let createdAt: Date
    var accessoryBattery: AirPodsBatteryLevels? = nil

    var priority: Int {
        if case let .agent(attention) = payload {
            return attention.priority
        }
        // A text or call outranks a Slack ping; both stay below agent decisions.
        if case let .system(content) = payload, content.tier == .important {
            return source.priority + 5
        }
        return source.priority
    }

    var isSticky: Bool {
        if case let .agent(attention) = payload {
            return attention.isSticky
        }
        return duration == nil
    }

    /// An ephemeral HUD should not appear long after the event that created
    /// it. Blocking agent decisions deliberately have no queue deadline.
    var maximumQueueAge: TimeInterval? {
        switch payload {
        case let .agent(attention):
            if attention.isSticky { return nil }
            return attention.kind == .completion ? 30 : 60
        case .level:
            return 4
        case .timer:
            return 15 * 60
        case .bluetooth, .battery:
            return 30
        case .system:
            return 60
        case .agentSetup:
            return 10 * 60
        case .update, .quillSuggestion:
            return nil
        }
    }

    var ignoresSourceSettings: Bool {
        switch payload {
        case .update, .quillSuggestion: return true
        default: return false
        }
    }

    var systemContent: SystemNotificationContent? {
        if case let .system(content) = payload { return content }
        return nil
    }

    func isExpiredFromQueue(at date: Date) -> Bool {
        guard let maximumQueueAge else { return false }
        return date.timeIntervalSince(createdAt) > maximumQueueAge
    }

    var tint: Color {
        if case let .agent(attention) = payload,
           let provider = attention.provider {
            return provider.accentColor
        }
        switch source {
        case .volume: return Color.white
        case .brightness: return Color.white
        case .bluetooth: return Color(red: 0.35, green: 0.62, blue: 1.0)
        case .battery: return Color(red: 0.20, green: 0.84, blue: 0.35)
        case .timer: return Color(red: 0.98, green: 0.60, blue: 0.25)
        case .agent: return Color(red: 1.0, green: 0.62, blue: 0.28)
        case .system:
            if case let .system(content) = payload {
                if content.isMessage { return Color(red: 0.30, green: 0.85, blue: 0.42) }
                if let tint = content.tint {
                    return Color(red: tint.red, green: tint.green, blue: tint.blue)
                }
            }
            return Color(red: 0.55, green: 0.72, blue: 1.0)
        }
    }

    var showsAirPodsBattery: Bool {
        guard case let .bluetooth(category, connected) = payload, connected,
              BluetoothDevicePresentation.resolve(name: title, category: category) == .airPodsPro
        else { return false }
        return accessoryBattery?.hasValues == true
    }

    var contentSize: CGSize {
        switch payload {
        case .level, .battery, .timer:
            return CGSize(width: 400, height: 40)
        case let .system(content):
            // One left-aligned row: 40pt icon beside a three-line text stack.
            // The app's action buttons sit at the right edge and need room.
            let actions = content.isMessage ? 0 : min(content.actions.filter { !$0.wantsText }.count, 2)
            return CGSize(width: 440 + CGFloat(actions) * 84, height: content.detail == nil ? 62 : 72)
        case .bluetooth:
            return CGSize(width: 420, height: showsAirPodsBattery ? 80 : 48)
        case let .agent(attention):
            return CGSize(width: IslandAgentAttention.cardWidth, height: attention.cardHeight)
        case .agentSetup:
            return CGSize(width: 560, height: 132)
        case .update, .quillSuggestion:
            return CGSize(width: 560, height: 116)
        }
    }

    func preferredSize(notchWidth: CGFloat, attached: Bool, notchClearance: CGFloat = 0) -> CGSize {
        let flare: CGFloat = attached ? 44 : 0
        let body = contentSize
        // Room on each side of the camera housing. A full-width row would
        // draw the bar and title through the physical notch.
        return CGSize(
            width: max(body.width + flare, notchWidth + 168 * 2 + flare),
            height: body.height + Self.topContentClearance + (dropsBelowNotch ? notchClearance : 0)
        )
    }

    /// Left-aligned cards read across the housing, so they sit under it.
    var dropsBelowNotch: Bool {
        if case .system = payload { return true }
        return false
    }

    static func preview(for source: IslandNotificationSource) -> Self {
        switch source {
        case .volume:
            .volume(level: 0.30, muted: false)
        case .brightness:
            .brightness(level: 0.75)
        case .bluetooth:
            .bluetooth(
                name: "AirPods Pro",
                category: .headphones,
                connected: true,
                address: "preview"
            )
        case .battery:
            .battery(
                BatterySnapshot(
                    percentage: 91,
                    isCharging: false,
                    isPluggedIn: true,
                    timeRemainingMinutes: nil
                )
            )
        case .timer:
            .timerCompletion(
                mode: .focus,
                sessionName: "Deep Work",
                configuredDuration: 25 * 60
            )
        case .system:
            .systemPreview(kind: .message)
        case .agent:
            .agentPreview(provider: .claude, kind: .permission)
        }
    }

    enum SystemPreviewKind: String, CaseIterable, Identifiable {
        case message
        case call
        case mail
        case app

        var id: String { rawValue }

        var title: String {
            switch self {
            case .message: "iMessage"
            case .call: "FaceTime call"
            case .mail: "Mail"
            case .app: "Any app"
            }
        }
    }

    static func systemPreview(kind: SystemPreviewKind) -> Self {
        let content: SystemNotificationContent
        switch kind {
        case .message:
            content = SystemNotificationContent(
                recordID: -1, uuid: "preview-system:message", bundleID: "com.apple.MobileSMS",
                appName: "Messages", title: "Ada Lovelace", subtitle: nil,
                body: "On my way — save me a seat.", deliveredAt: Date(),
                message: SystemNotificationMessageContext(
                    chatGUID: "preview", handle: "preview", isGroup: false
                )
            )
        case .call:
            content = SystemNotificationContent(
                recordID: -1, uuid: "preview-system:call", bundleID: "com.apple.facetime",
                appName: "FaceTime", title: "Ada Lovelace", subtitle: nil,
                body: "Incoming FaceTime Video", deliveredAt: Date()
            )
        case .mail:
            content = SystemNotificationContent(
                recordID: -1, uuid: "preview-system:mail", bundleID: "com.apple.mail",
                appName: "Mail", title: "Grace Hopper", subtitle: "Re: Compiler notes",
                body: "Attached the revised draft. Let me know what you think.", deliveredAt: Date()
            )
        case .app:
            content = SystemNotificationContent(
                recordID: -1, uuid: "preview-system:app", bundleID: "com.apple.reminders",
                appName: "Reminders", title: "Pick up the package", subtitle: nil,
                body: "Today at 5:00 PM", deliveredAt: Date()
            )
        }
        return .system(content)
    }

    static func agentPreview(
        provider: AgentProviderID,
        kind: AgentHookBridge.RequestKind,
        failure: Bool = false
    ) -> Self {
        let adapter = AgentProviderRegistry.adapter(for: provider)
        let respondsThroughBridge: Bool
        let title: String
        let detail: String?
        let options: [AgentHookBridge.Option]
        let preview: AgentHookBridge.Preview

        switch kind {
        case .permission:
            respondsThroughBridge = adapter?.controls.contains(.approvePermission) == true
            title = respondsThroughBridge
                ? "Bash"
                : "\(provider.title) needs approval for Terminal"
            detail = "xcodebuild test -project Nano.xcodeproj -scheme Nano"
            options = respondsThroughBridge
                ? [.init(id: 0, label: "Deny"), .init(id: 1, label: "Allow once")]
                : []
            preview = .command("xcodebuild test -project Nano.xcodeproj -scheme Nano")
        case .question:
            respondsThroughBridge = adapter?.controls.contains(.answerStructuredQuestion) == true
            title = respondsThroughBridge
                ? "Where should Nano return you?"
                : "\(provider.title) is waiting for your answer"
            detail = respondsThroughBridge ? "Choose the exact session or its project." : nil
            options = respondsThroughBridge
                ? [.init(id: 0, label: "Exact session"), .init(id: 1, label: "Project")]
                : []
            preview = .none
        case .completion:
            respondsThroughBridge = false
            title = "Fix Nano notifications"
            detail = "The agent finished its turn."
            options = []
            preview = .none
        case .notification:
            respondsThroughBridge = false
            title = "\(provider.title) sent an update"
            detail = "Open the working session for details."
            options = []
            preview = .none
        }

        return .agent(
            IslandAgentAttention(
                AgentHookBridge.PendingRequest(
                    id: "preview-agent:\(provider.rawValue):\(kind.rawValue)",
                    source: provider.rawValue,
                    kind: kind,
                    title: failure ? "Build failed" : title,
                    detail: failure ? "Missing dependency: SwiftLint" : detail,
                    options: options,
                    sessionID: nil,
                    receivedAt: Date(),
                    respondsThroughBridge: respondsThroughBridge,
                    preview: preview,
                    projectName: "North-Star"
                )
            )
        )
    }

    static func update(_ update: NanoUpdate) -> Self {
        IslandNotification(
            id: UUID(),
            source: .system,
            title: "Nano \(update.version) is available",
            subtitle: update.notes,
            symbol: "arrow.down.circle.fill",
            duration: nil,
            coalesceKey: updateCoalesceKey,
            payload: .update(update),
            createdAt: Date()
        )
    }

    static let updateCoalesceKey = "nano-update"

    static func quillSuggestion(_ correction: VoiceDictationCorrection) -> Self {
        IslandNotification(
            id: UUID(),
            source: .system,
            title: "Quill can get better",
            subtitle: nil,
            symbol: "waveform",
            duration: nil,
            coalesceKey: quillSuggestionCoalesceKey,
            payload: .quillSuggestion(correction),
            createdAt: Date()
        )
    }

    static let quillSuggestionCoalesceKey = "quill-suggestion"

    static func agentSetup(provider: AgentProviderID) -> Self {
        IslandNotification(
            id: UUID(),
            source: .agent,
            title: "\(provider.title) is new on this Mac",
            subtitle: "Connect it to see its sessions, usage, and approvals on the island.",
            symbol: "terminal.fill",
            duration: nil,
            coalesceKey: "agent-setup:\(provider.rawValue)",
            payload: .agentSetup(provider),
            createdAt: Date()
        )
    }

    /// A plan-mode approval, as Claude sends it after `ExitPlanMode`.
    static func agentPlanPreview(provider: AgentProviderID) -> Self {
        .agent(
            IslandAgentAttention(
                AgentHookBridge.PendingRequest(
                    id: "preview-agent:\(provider.rawValue):plan",
                    source: provider.rawValue,
                    kind: .permission,
                    title: "ExitPlanMode",
                    detail: nil,
                    options: [.init(id: 0, label: "Keep planning"), .init(id: 1, label: "Approve")],
                    sessionID: nil,
                    receivedAt: Date(),
                    respondsThroughBridge: true,
                    preview: .plan("""
                    # Add a reset countdown to the usage pill
                    1. Add pressingReset to AgentUsagePill
                    2. Show "resets 1h12m" once a window passes 50%
                    3. List every window's reset in the tooltip
                    4. Add the countdown to the dashboard Agents widget
                    5. Test the threshold and the window choice
                    6. Update the handoff notes
                    7. Install and verify
                    """),
                    projectName: "North-Star"
                )
            )
        )
    }

    static func volume(level: Double, muted: Bool, at date: Date = Date()) -> Self {
        let clamped = min(max(level, 0), 1)
        return IslandNotification(
            id: UUID(),
            source: .volume,
            title: "Volume",
            subtitle: muted ? "Muted" : "\(Int((clamped * 100).rounded()))%",
            symbol: muted
                ? "speaker.slash.fill"
                : clamped == 0
                    ? "speaker.slash.fill"
                    : clamped < 0.34
                        ? "speaker.wave.1.fill"
                        : clamped < 0.67
                            ? "speaker.wave.2.fill"
                            : "speaker.wave.3.fill",
            duration: IslandNotificationSource.volume.defaultDuration,
            coalesceKey: "volume",
            payload: .level(clamped, muted: muted),
            createdAt: date
        )
    }

    /// Mixer mic-mute feedback. Uses the volume source's small docked HUD and
    /// timing; callers bypass the source's enabled check because the mute was
    /// user-requested.
    static func microphone(muted: Bool, at date: Date = Date()) -> Self {
        IslandNotification(
            id: UUID(),
            source: .volume,
            title: "Microphone",
            subtitle: muted ? "Muted" : "On",
            symbol: muted ? "mic.slash.fill" : "mic.fill",
            duration: IslandNotificationSource.volume.defaultDuration,
            coalesceKey: "mixer-mic",
            payload: .level(muted ? 0 : 1, muted: muted),
            createdAt: date
        )
    }

    static func brightness(level: Double, at date: Date = Date()) -> Self {
        let clamped = min(max(level, 0), 1)
        return IslandNotification(
            id: UUID(),
            source: .brightness,
            title: "Brightness",
            subtitle: "\(Int((clamped * 100).rounded()))%",
            symbol: clamped < 0.34 ? "sun.min.fill" : "sun.max.fill",
            duration: IslandNotificationSource.brightness.defaultDuration,
            coalesceKey: "brightness",
            payload: .level(clamped, muted: false),
            createdAt: date
        )
    }

    static func bluetooth(
        name: String,
        category: BluetoothAccessoryCategory,
        connected: Bool,
        address: String,
        battery: AirPodsBatteryLevels? = nil,
        at date: Date = Date()
    ) -> Self {
        IslandNotification(
            id: UUID(),
            source: .bluetooth,
            title: name,
            subtitle: connected ? "Connected" : "Disconnected",
            symbol: category.symbol,
            duration: IslandNotificationSource.bluetooth.defaultDuration,
            coalesceKey: "bluetooth:\(address)",
            payload: .bluetooth(category: category, connected: connected),
            createdAt: date,
            accessoryBattery: battery
        )
    }

    static func battery(_ snapshot: BatterySnapshot, at date: Date = Date()) -> Self {
        IslandNotification(
            id: UUID(),
            source: .battery,
            title: "Battery",
            subtitle: "\(snapshot.percentage)%",
            symbol: snapshot.hudSymbol,
            duration: IslandNotificationSource.battery.defaultDuration,
            coalesceKey: "battery",
            payload: .battery(snapshot),
            createdAt: date
        )
    }

    static func timerCompletion(
        mode: FocusTimerMode,
        sessionName: String?,
        configuredDuration: TimeInterval,
        at date: Date = Date()
    ) -> Self {
        let trimmedName = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let durationLabel = timerDurationLabel(configuredDuration)
        let subtitle: String
        if let trimmedName, !trimmedName.isEmpty {
            subtitle = "\(trimmedName) · \(durationLabel)"
        } else {
            subtitle = durationLabel
        }
        return IslandNotification(
            id: UUID(),
            source: .timer,
            title: mode == .rest ? "Break's over" : "Focus complete",
            subtitle: subtitle,
            symbol: IslandNotificationSource.timer.symbol,
            duration: IslandNotificationSource.timer.defaultDuration,
            coalesceKey: "timer-completion",
            payload: .timer(mode: mode, configuredDuration: configuredDuration),
            createdAt: date
        )
    }

    private static func timerDurationLabel(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        if totalSeconds % 3_600 == 0, totalSeconds >= 3_600 {
            let hours = totalSeconds / 3_600
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if totalSeconds % 60 == 0, totalSeconds >= 60 {
            let minutes = totalSeconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return totalSeconds == 1 ? "1 second" : "\(totalSeconds) seconds"
    }

    static func system(
        _ content: SystemNotificationContent,
        at date: Date = Date(),
        coalesceKey: String? = nil
    ) -> Self {
        IslandNotification(
            id: UUID(),
            source: .system,
            title: content.headline,
            subtitle: content.detail,
            symbol: content.isMessage ? "message.fill" : content.isCall ? "phone.fill" : "bell.fill",
            // Calls stay while the phone rings; the watcher dismisses them.
            // Otherwise people and calendar get longer than everything else.
            duration: content.isCall ? 60.0 : content.tier.duration,
            coalesceKey: coalesceKey ?? "system:\(content.uuid)",
            payload: .system(content),
            createdAt: date
        )
    }

    static func agent(_ attention: IslandAgentAttention, at date: Date = Date()) -> Self {
        IslandNotification(
            id: UUID(),
            source: .agent,
            title: attention.headline,
            subtitle: attention.detail ?? attention.projectName,
            symbol: attention.kind == .permission
                ? "exclamationmark.triangle.fill"
                : attention.kind == .completion ? "checkmark.circle.fill" : "bubble.left.fill",
            duration: attention.isSticky ? nil : 6,
            coalesceKey: attention.kind == .completion
                ? "agent-completion:\(attention.sessionID ?? attention.requestID)"
                : "agent:\(attention.requestID)",
            payload: .agent(attention),
            createdAt: date
        )
    }
}

/// Pure queue rules so the island can be tested without sleeping.
enum IslandNotificationQueue {
    struct Outcome: Equatable {
        var current: IslandNotification
        var queue: [IslandNotification]
        var coalesced: Bool
    }

    static let maxQueued = 6

    static func apply(
        current: IslandNotification?,
        queue: [IslandNotification],
        incoming: IslandNotification,
        at date: Date = Date()
    ) -> Outcome {
        let freshQueue = queue.filter { !$0.isExpiredFromQueue(at: date) }
        if let current {
            if current.coalesceKey == incoming.coalesceKey {
                return Outcome(current: incoming, queue: freshQueue, coalesced: true)
            }

            var nextQueue = freshQueue
            if incoming.priority > current.priority {
                nextQueue.insert(current, at: 0)
                nextQueue = bounded(nextQueue)
                return Outcome(current: incoming, queue: nextQueue, coalesced: false)
            }

            if let index = nextQueue.firstIndex(where: { $0.coalesceKey == incoming.coalesceKey }) {
                nextQueue[index] = incoming
                return Outcome(current: current, queue: nextQueue, coalesced: true)
            }

            nextQueue.append(incoming)
            return Outcome(current: current, queue: bounded(nextQueue), coalesced: false)
        }

        return Outcome(current: incoming, queue: freshQueue, coalesced: false)
    }

    static func pop(
        _ queue: [IslandNotification],
        at date: Date = Date()
    ) -> (IslandNotification, [IslandNotification])? {
        let freshQueue = queue.filter { !$0.isExpiredFromQueue(at: date) }
        guard let first = freshQueue.first else { return nil }
        return (first, Array(freshQueue.dropFirst()))
    }

    private static func bounded(_ queue: [IslandNotification]) -> [IslandNotification] {
        guard queue.count > maxQueued else { return queue }
        // Preserve the oldest waiting work. Dropping the head here would turn a
        // FIFO attention queue into "newest wins" exactly when it is busiest.
        return Array(queue.prefix(maxQueued))
    }
}

@MainActor
final class IslandNotificationCenter: ObservableObject {
    @Published private(set) var current: IslandNotification?
    @Published private(set) var recents: [IslandNotification] = []

    var onCurrentChange: (() -> Void)?

    private var queue: [IslandNotification] = []
    private var previewID: UUID?
    private var dismissTask: Task<Void, Never>?

    var queuedCount: Int { queue.count }

    var queuedAgentCount: Int {
        queue.reduce(into: 0) { count, notification in
            if case .agent = notification.payload { count += 1 }
        }
    }

    func present(_ notification: IslandNotification) {
        let previousID = current?.id
        let coalescesCurrent = current?.coalesceKey == notification.coalesceKey
        let outcome = IslandNotificationQueue.apply(
            current: current,
            queue: queue,
            incoming: notification
        )
        queue = outcome.queue
        remember(outcome.current)
        // A card that has to wait its turn can expire in the queue. It still
        // belongs in history, or it is lost without ever being seen.
        if outcome.current.id != notification.id {
            remember(notification)
        }
        setCurrent(
            outcome.current,
            restartTimer: previousID != outcome.current.id || coalescesCurrent
        )
    }

    /// Previews replace each other immediately without discarding real attention.
    func presentPreview(_ notification: IslandNotification) {
        func isPreview(_ item: IslandNotification) -> Bool {
            if item.id == previewID { return true }
            guard case let .agent(attention) = item.payload else { return false }
            return attention.requestID.hasPrefix("preview-agent:")
        }
        queue.removeAll(where: isPreview)
        if let current, !isPreview(current) { queue.insert(current, at: 0) }
        previewID = notification.id
        setCurrent(notification, restartTimer: true)
    }

    func dismissCurrent() {
        dismissTask?.cancel()
        dismissTask = nil
        if let next = IslandNotificationQueue.pop(queue) {
            queue = next.1
            setCurrent(next.0, restartTimer: true)
        } else {
            setCurrent(nil, restartTimer: false)
        }
    }

    func dismissAll() {
        dismissTask?.cancel()
        dismissTask = nil
        queue.removeAll()
        setCurrent(nil, restartTimer: false)
    }

    /// Brings the next waiting agent card forward and sends the current one
    /// to the back of the line, so a stack of approvals can be paged through.
    func showNextAgent() {
        guard let current,
              let index = queue.firstIndex(where: { if case .agent = $0.payload { true } else { false } })
        else { return }
        let next = queue.remove(at: index)
        queue.append(current)
        setCurrent(next, restartTimer: true)
    }

    /// The user opened something else. The card on screen yields, but the
    /// ones waiting keep their turn for when the island is free again.
    func setAside() {
        dismissTask?.cancel()
        dismissTask = nil
        guard current != nil else { return }
        setCurrent(nil, restartTimer: false)
    }

    /// Shows the next waiting card, if nothing is on screen.
    func resumeQueue() {
        guard current == nil, let next = IslandNotificationQueue.pop(queue) else { return }
        queue = next.1
        setCurrent(next.0, restartTimer: true)
    }

    /// Held back (Focus on) but still worth finding in history later.
    func rememberQuietly(_ notification: IslandNotification) {
        remember(notification)
    }

    /// Typing a reply must not race the auto-dismiss timer.
    func holdCurrent() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    func releaseCurrent() {
        scheduleDismiss(of: current)
    }

    func forgetRecent(id: UUID) {
        recents.removeAll { $0.id == id }
    }

    func forgetAllRecents() {
        recents.removeAll()
    }

    func dismiss(source: IslandNotificationSource) {
        queue.removeAll { $0.source == source }
        guard current?.source == source else { return }

        dismissTask?.cancel()
        dismissTask = nil
        if let next = IslandNotificationQueue.pop(queue) {
            queue = next.1
            setCurrent(next.0, restartTimer: true)
        } else {
            setCurrent(nil, restartTimer: false)
        }
    }

    /// Removes one notification wherever it is, by its coalesce key.
    func removeDuplicate(coalesceKey: String) {
        recents.removeAll { $0.coalesceKey == coalesceKey }
        dismiss(coalesceKey: coalesceKey)
    }

    func dismiss(coalesceKey: String) {
        queue.removeAll { $0.coalesceKey == coalesceKey }
        guard current?.coalesceKey == coalesceKey else { return }

        dismissTask?.cancel()
        dismissTask = nil
        if let next = IslandNotificationQueue.pop(queue) {
            queue = next.1
            setCurrent(next.0, restartTimer: true)
        } else {
            setCurrent(nil, restartTimer: false)
        }
    }

    func dismissAgent(requestID: String) {
        if case let .agent(attention) = current?.payload, attention.requestID == requestID {
            dismissCurrent()
            return
        }
        queue.removeAll {
            if case let .agent(attention) = $0.payload {
                return attention.requestID == requestID
            }
            return false
        }
    }

    func retainPendingAgentRequests(_ requestIDs: Set<String>) {
        let previousCount = queue.count
        queue.removeAll { notification in
            guard case let .agent(attention) = notification.payload,
                  attention.respondsThroughBridge
            else { return false }
            return !requestIDs.contains(attention.requestID)
        }

        if case let .agent(attention) = current?.payload,
           attention.respondsThroughBridge,
           !requestIDs.contains(attention.requestID) {
            dismissCurrent()
        } else if queue.count != previousCount {
            objectWillChange.send()
        }
    }

    func dismissPassiveAgentAttention(sessionID: String) {
        queue.removeAll { notification in
            guard case let .agent(attention) = notification.payload else { return false }
            return attention.sessionID == sessionID && !attention.respondsThroughBridge
        }
        if case let .agent(attention) = current?.payload,
           attention.sessionID == sessionID,
           !attention.respondsThroughBridge {
            dismissCurrent()
        }
    }

    /// Settings changes must affect notifications already in flight, not only
    /// future events. Otherwise switching a source off can leave its sticky
    /// card covering the island indefinitely.
    func retainEnabledSources(_ sources: Set<IslandNotificationSource>) {
        let previousCount = queue.count
        queue.removeAll { !sources.contains($0.source) && !$0.ignoresSourceSettings }
        if let current, !sources.contains(current.source), !current.ignoresSourceSettings {
            dismissCurrent()
        } else if queue.count != previousCount {
            objectWillChange.send()
        }
    }

    private func setCurrent(_ notification: IslandNotification?, restartTimer: Bool) {
        current = notification
        onCurrentChange?()
        guard restartTimer else { return }
        scheduleDismiss(of: notification)
    }

    private func scheduleDismiss(of notification: IslandNotification?) {
        dismissTask?.cancel()
        guard let notification, let duration = notification.duration, duration > 0 else {
            dismissTask = nil
            return
        }

        let id = notification.id
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            guard self?.current?.id == id else { return }
            self?.dismissCurrent()
        }
    }

    private func remember(_ notification: IslandNotification) {
        recents.removeAll { $0.coalesceKey == notification.coalesceKey }
        recents.insert(notification, at: 0)
        if recents.count > 20 {
            recents = Array(recents.prefix(20))
        }
    }
}

struct AirPodsBatteryLevels: Equatable, Sendable {
    let left: Int?
    let caseLevel: Int?
    let right: Int?
    var hasValues: Bool { left != nil || caseLevel != nil || right != nil }

    static func fromProfiler(_ data: Data, address: String) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isHexDigit } }
        func percentage(_ value: Any?) -> Int? {
            let text = (value as? String)?.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            guard let number = (value as? NSNumber)?.intValue ?? text.flatMap(Int.init), (0...100).contains(number) else { return nil }
            return number
        }
        func visit(_ value: Any, connected: Bool = false) -> Self? {
            if let dictionary = value as? [String: Any] {
                if connected, let found = dictionary["device_address"] as? String, normalized(found) == normalized(address) {
                    let levels = Self(left: percentage(dictionary["device_batteryLevelLeft"]),
                        caseLevel: percentage(dictionary["device_batteryLevelCase"]),
                        right: percentage(dictionary["device_batteryLevelRight"]))
                    return levels.hasValues ? levels : nil
                }
                for (key, child) in dictionary {
                    if key == "device_not_connected" { continue }
                    if let result = visit(child, connected: connected || key == "device_connected") { return result }
                }
            } else if let array = value as? [Any] {
                for child in array { if let result = visit(child, connected: connected) { return result } }
            }
            return nil
        }
        return visit(object)
    }
}
