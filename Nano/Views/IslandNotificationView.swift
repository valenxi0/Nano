import SwiftUI

enum NanoNotificationCenterGap {
    static func width(notchWidth: CGFloat, minimum: CGFloat) -> CGFloat {
        max(notchWidth, minimum)
    }
}

struct IslandNotificationView: View {
    let notification: IslandNotification
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    var ignoresNotch = false
    /// Skips the entrance, for rendering a card as a still image.
    var revealsImmediately = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedReveal = false

    private var revealed: Bool { animatedReveal || revealsImmediately }

    var body: some View {
        Group {
            if case let .agentSetup(provider) = notification.payload {
                AgentSetupCard(provider: provider, viewModel: viewModel)
                    .opacity(revealed ? 1 : 0)
                    .animation(notificationRevealAnimation, value: revealed)
            } else if case let .update(update) = notification.payload {
                UpdateNoticeCard(update: update, viewModel: viewModel)
                    .opacity(revealed ? 1 : 0)
                    .animation(notificationRevealAnimation, value: revealed)
            } else if case let .quillSuggestion(correction) = notification.payload {
                QuillSuggestionCard(correction: correction, viewModel: viewModel)
                    .opacity(revealed ? 1 : 0)
                    .animation(notificationRevealAnimation, value: revealed)
            } else if case let .agent(attention) = notification.payload {
                AgentNotificationCard(
                    attention: attention,
                    settings: settings,
                    viewModel: viewModel,
                    revealed: revealed,
                    reduceMotion: reduceMotion
                )
                // Reaching for Review must not race the timer, as on system cards.
                .onHover { inside in
                    if inside {
                        viewModel.notificationCenter.holdCurrent()
                    } else {
                        viewModel.notificationCenter.releaseCurrent()
                    }
                }
            } else if case let .system(content) = notification.payload {
                SystemNotificationCard(
                    notification: notification,
                    content: content,
                    settings: settings,
                    viewModel: viewModel
                )
                .padding(.top, notification.dropsBelowNotch ? viewModel.notchContentClearance : 0)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed || reduceMotion ? 0 : -6)
                .animation(notificationRevealAnimation, value: revealed)
            } else {
                VStack(spacing: 0) {
                    systemHUD.frame(height: notification.showsAirPodsBattery ? 48 : nil)
                    if notification.showsAirPodsBattery, let battery = notification.accessoryBattery {
                        HStack(spacing: 28) {
                            batteryValue(battery.left, symbol: "airpodpro.left")
                            batteryValue(battery.caseLevel, symbol: "airpodspro.chargingcase.wireless.fill")
                            batteryValue(battery.right, symbol: "airpodpro.right")
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .padding(.bottom, 6)
                    }
                }
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed || reduceMotion ? 0 : -6)
                    .animation(notificationRevealAnimation, value: revealed)
            }
        }
        .padding(.top, notification.source == .agent ? IslandNotification.topContentClearance : 0)
        .padding(.vertical, notification.source == .agent ? 0 : IslandNotification.topContentClearance / 2)
        .foregroundStyle(.white)
        .opacity(notification.source != .agent || revealed || reduceMotion ? 1 : 0)
        .animation(notificationRevealAnimation, value: revealed)
        .task {
            // A beat for the shell to grow past the compact width, so full
            // width content doesn't peek through it; then the parts follow
            // the shell rather than waiting for it to finish.
            if notification.source == .agent && !reduceMotion {
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
            }
            animatedReveal = true
        }
        .accessibilityElement(children: notification.source == .agent ? .contain : .combine)
        .accessibilityLabel(
            [notification.title, notification.subtitle].compactMap { $0 }.joined(separator: ", ")
        )
    }

    @ViewBuilder
    private func batteryValue(_ level: Int?, symbol: String) -> some View {
        if let level {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13))
                Text("\(level)%").font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.65))
        }
    }

    /// Reduce Motion keeps the fade and drops the travel and blur.
    private var notificationRevealAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.15) : NanoMotion.reveal
    }

    private var systemHUD: some View {
        GeometryReader { proxy in
            let innerWidth = max(proxy.size.width - 32, 0)
            let sideWidth = max((innerWidth - centerGap) / 2, 0)

            Group {
                if viewModel.notchWidth > 0, !ignoresNotch {
            HStack(spacing: 0) {
                leading
                    .frame(width: sideWidth, alignment: .leading)
                    .clipped()
                Color.clear
                    .frame(width: centerGap)
                trailing
                    .frame(width: sideWidth, alignment: .trailing)
                    .clipped()
            }
                } else {
                    HStack(spacing: 12) {
                        leading
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // As wide as its text, up to a limit: a fixed 120pt
                        // cut "Deep Work · 25 minutes" short beside empty space.
                        trailing
                            .frame(minWidth: 0, maxWidth: 220, alignment: .trailing)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                }
            }
            .padding(.horizontal, ignoresNotch ? 20 : 16)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.handleNotificationTap(notification)
        }
    }

    /// MacBooks have dead pixels in the camera housing. Placement changes the
    /// island silhouette, not the physical obstruction underneath it.
    private var centerGap: CGFloat {
        NanoNotificationCenterGap.width(notchWidth: viewModel.notchWidth, minimum: 12)
    }

    @ViewBuilder
    private var leading: some View {
        switch notification.payload {
        case .level:
            HUDLabel(symbol: notification.symbol, title: notification.title)
        case .battery:
            Text("Battery")
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
        case .timer:
            HUDLabel(symbol: notification.symbol, title: notification.title)
        case let .bluetooth(category, connected):
            if let presentation = BluetoothDevicePresentation.resolve(
                name: notification.title, category: category
            ), presentation.approvedAnimationName != nil {
                HStack(spacing: 6) {
                    BluetoothDeviceAnimationView(
                        presentation: presentation, reduceMotion: reduceMotion || !connected
                    )
                    .id(notification.id)
                    .frame(width: 76, height: 48)
                    .scaleEffect((presentation == .airPodsPro ? 0.76 : 0.84) * 0.75)
                    .frame(width: 58, height: 42)
                    .accessibilityHidden(true)
                    Text(notification.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            } else {
                // Keyboards, mice and other accessories use a compact 2D symbol.
                HStack(spacing: 9) {
                    if category == .keyboard || category == .mouse {
                        AccessoryNotificationIcon(category: category)
                    } else {
                        Image(systemName: category.symbol).font(.system(size: 15, weight: .medium))
                    }
                    Text(notification.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                }
            }
        case .system, .agent, .agentSetup, .update, .quillSuggestion:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch notification.payload {
        case let .level(value, muted):
            HStack(spacing: 8) {
                ThinMeter(value: muted ? 0 : value, width: 80)
                Text(muted ? "Off" : "\(Int((value * 100).rounded()))")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 26, alignment: .trailing)
            }
        case let .battery(snapshot):
            HStack(spacing: 7) {
                Text("\(snapshot.percentage)%")
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: snapshot.percentage)
                Image(systemName: snapshot.hudSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
            }
            .foregroundStyle(notification.tint)
        case .agent, .system, .agentSetup, .update, .quillSuggestion:
            EmptyView()
        default:
            if let subtitle = notification.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
        }
    }
}

/// A macOS notification in the notch, laid out like a system banner: app
/// icon or sender photo, then app name, title, and a one-line preview.
private struct SystemNotificationCard: View {
    let notification: IslandNotification
    let content: SystemNotificationContent
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel

    @State private var contactPhoto: NSImage?
    @State private var hovering = false
    @State private var replying = false
    @State private var replyText = ""
    @State private var eventMonitor: Any?
    @FocusState private var replyFocused: Bool

    private let iconSize: CGFloat = 40

    private var canReply: Bool {
        content.isMessage && content.message != nil && settings.systemNotificationsInlineReply
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                topRow
                if replying {
                    replyField
                } else {
                    Text(content.headline)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let detail = content.detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !replying {
                trailingControl
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .scaleEffect(hovering && !replying ? 1.01 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { inside in
            hovering = inside
            // Reading or reaching for a button should not race the timer.
            if inside {
                viewModel.notificationCenter.holdCurrent()
                installEventMonitor()
            } else {
                removeEventMonitor()
                if !replying { viewModel.notificationCenter.releaseCurrent() }
            }
        }
        .onDisappear {
            removeEventMonitor()
        }
        .onTapGesture {
            guard !replying else { return }
            viewModel.handleNotificationTap(notification)
        }
        .task(id: content.uuid) {
            guard content.isMessage, settings.systemNotificationsContactPhotos,
                  let handle = content.message?.handle, content.isRealRecord
            else { return }
            contactPhoto = await viewModel.contactPhotos.photo(for: handle)
        }
        .onChange(of: replying) { _, now in
            if now {
                viewModel.beginSystemReply()
                replyFocused = true
            }
        }
        .onExitCommand { escape() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(content.appName) notification: \(content.headline)")
    }

    /// Esc closes the reply field first, then the card.
    private func escape() {
        if replying {
            replying = false
            replyText = ""
            viewModel.cancelSystemReply()
        } else {
            viewModel.notificationCenter.dismissCurrent()
        }
    }

    /// A flick up on the trackpad or Esc dismisses, like the macOS banner.
    /// Local monitor: only events aimed at Nano's own windows, only while
    /// the pointer is on the card.
    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { event in
            switch event.type {
            case .scrollWheel:
                guard event.momentumPhase.isEmpty else { return event }
                // Natural scrolling: fingers up gives a negative delta.
                let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
                if delta > 14, !replying {
                    Task { @MainActor in viewModel.notificationCenter.dismissCurrent() }
                    return nil
                }
                return event
            case .keyDown where event.keyCode == 53:
                Task { @MainActor in escape() }
                return nil
            default:
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(content.appName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
                .lineLimit(1)
            Spacer(minLength: 8)
            if content.isRealRecord || content.summary != nil {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text(SystemNotificationContent.timeAgo(from: content.deliveredAt, now: context.date))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.56))
                        .monospacedDigit()
                }
            } else {
                Text("now")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
            }
            if viewModel.notificationCenter.queuedCount > 0 {
                Text("+\(viewModel.notificationCenter.queuedCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.15)))
                    .accessibilityLabel("\(viewModel.notificationCenter.queuedCount) more waiting")
            }
        }
    }

    private var visibleActions: [SystemNotificationAction] {
        guard !content.isMessage, content.summary == nil, !content.previewHidden else { return [] }
        return Array(content.actions.filter { !$0.wantsText }.prefix(2))
    }

    @ViewBuilder
    private var trailingControl: some View {
        if !visibleActions.isEmpty {
            HStack(spacing: 6) {
                ForEach(visibleActions) { action in
                    Button {
                        viewModel.performSystemAction(action, on: content)
                    } label: {
                        Text(action.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(
                                action.isDestructive ? Color(red: 1.0, green: 0.36, blue: 0.34).opacity(0.28) : .white.opacity(0.12),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.nanoPress)
                    .help(action.title)
                }
            }
        } else if canReply {
            Button {
                replying = true
            } label: {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.nanoPress)
            .help("Reply in Messages")
            .accessibilityLabel("Reply")
        } else if hovering {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .transition(.scale.combined(with: .opacity))
                .accessibilityHidden(true)
        }
    }

    private var iconShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
    }

    @ViewBuilder
    private var avatar: some View {
        if content.summary?.kind == .catchUp {
            ZStack {
                iconShape
                    .fill(LinearGradient(
                        colors: [Color(red: 0.55, green: 0.45, blue: 1.0), Color(red: 0.35, green: 0.30, blue: 0.85)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: iconSize, height: iconSize)
                Image(systemName: "tray.full.fill")
                    .font(.system(size: iconSize * 0.45, weight: .semibold))
            }
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .accessibilityHidden(true)
        } else if let contactPhoto {
            Image(nsImage: contactPhoto)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: iconSize, height: iconSize)
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    appBadge.offset(x: 4, y: 4)
                }
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .accessibilityHidden(true)
        } else if let icon = SystemNotificationAppInfo.icon(for: content.bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .clipShape(iconShape)
                .overlay(iconShape.stroke(.white.opacity(0.1), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) { stormBadge }
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .accessibilityHidden(true)
        } else {
            ZStack {
                iconShape
                    .fill(LinearGradient(
                        colors: [.gray.opacity(0.7), .gray.opacity(0.9)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: iconSize, height: iconSize)
                if let first = content.appName.first {
                    Text(String(first).uppercased())
                        .font(.system(size: iconSize * 0.55, weight: .bold, design: .rounded))
                } else {
                    Image(systemName: notification.symbol)
                        .font(.system(size: iconSize * 0.45, weight: .semibold))
                }
            }
            .overlay(alignment: .topTrailing) { stormBadge }
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var stormBadge: some View {
        if let summary = content.summary, summary.kind == .storm {
            Text("\(summary.count)")
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color(red: 1.0, green: 0.3, blue: 0.3)))
                .offset(x: 6, y: -6)
        }
    }

    @ViewBuilder
    private var appBadge: some View {
        if let icon = SystemNotificationAppInfo.icon(for: content.bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
        }
    }

    private var replyField: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                TextField("Reply to \(content.headline)", text: $replyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .focused($replyFocused)
                    .onSubmit(send)
                    .disabled(viewModel.systemReplyInFlight)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(.white.opacity(0.1), in: Capsule())
                Button(action: send) {
                    Image(systemName: viewModel.systemReplyInFlight ? "ellipsis" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(
                            replyText.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.white.opacity(0.12)
                                : Color(red: 0.30, green: 0.85, blue: 0.42),
                            in: Circle()
                        )
                }
                .buttonStyle(.nanoPress)
                .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.systemReplyInFlight)
                .accessibilityLabel("Send reply")
            }
            if let error = viewModel.systemReplyError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.4))
                    .lineLimit(1)
            }
        }
    }

    private func send() {
        let text = replyText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        viewModel.sendSystemReply(text, to: content)
    }
}


private struct HUDLabel: View {
    let symbol: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
        }
    }
}

private struct ThinMeter: View {
    let value: Double
    var width: CGFloat = 104

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(proxy.size.width * value, value > 0 ? 4 : 0))
            }
        }
        .frame(width: width, height: 3.5)
        .animation(.snappy(duration: 0.18), value: value)
    }
}

private struct AgentNotificationCard: View {
    let attention: IslandAgentAttention
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    let revealed: Bool
    let reduceMotion: Bool
    @State private var selectedOptionID: Int?

    init(
        attention: IslandAgentAttention,
        settings: NanoSettings,
        viewModel: IslandViewModel,
        revealed: Bool,
        reduceMotion: Bool
    ) {
        self.attention = attention
        self.settings = settings
        self.viewModel = viewModel
        self.revealed = revealed
        self.reduceMotion = reduceMotion
        _selectedOptionID = State(initialValue: attention.options.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if attention.kind == .completion && !attention.isFailure {
                completionRow
            } else if let plan = attention.plan {
                header
                    .modifier(AgentNotificationRevealStage(revealed: revealed, delay: 0.02, reduceMotion: reduceMotion))
                planContent(plan)
                    .modifier(AgentNotificationRevealStage(revealed: revealed, delay: 0.06, reduceMotion: reduceMotion))
                Group {
                    Rectangle()
                        .fill(.white.opacity(0.085))
                        .frame(height: 1)
                    planFooter
                }
                .modifier(AgentNotificationRevealStage(revealed: revealed, delay: 0.10, reduceMotion: reduceMotion))
            } else {
            header
                .modifier(AgentNotificationRevealStage(
                    revealed: revealed,
                    delay: 0.02,
                    reduceMotion: reduceMotion
                ))
            content
                .modifier(AgentNotificationRevealStage(
                    revealed: revealed,
                    delay: 0.06,
                    reduceMotion: reduceMotion
                ))
            if showsFooter {
                Group {
                    Rectangle()
                        .fill(.white.opacity(0.085))
                        .frame(height: 1)
                    footer
                }
                .modifier(AgentNotificationRevealStage(
                    revealed: revealed,
                    delay: 0.10,
                    reduceMotion: reduceMotion
                ))
            }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // IslandRootView owns the shared, settings-driven HUD background.
        // Keep agent cards transparent so glass, hybrid and custom colors show through.

    }

    private var completionRow: some View {
        HStack(spacing: 12) {
            providerLogo
            VStack(alignment: .leading, spacing: 5) {
                Text(attention.displayHeadline).font(.system(size: 15, weight: .semibold))
                if let notice = viewModel.agentJumpNotices[attention.requestID] {
                    Text(notice).font(.system(size: 11)).foregroundStyle(Color.orange.opacity(0.9)).lineLimit(2)
                } else {
                    Text(completionSummary).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            actionButton("Review", symbol: "arrow.up.right") { viewModel.openAgentSession(attention) }
        }
        .frame(maxHeight: .infinity)
    }

    /// Leads with the session's own title: two sessions in one project
    /// otherwise finish with identical cards.
    private var completionSummary: String {
        let detail = attention.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String? = sessionName == attention.projectName || sessionName == "Agent session"
            ? nil : sessionName
        return [title, attention.projectName, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func highlightedCommand(_ command: String) -> AttributedString {
        AgentModuleView.highlighted(AgentApprovalCopy.readableCommand(command))
    }

    private var commandRisk: String? {
        attention.commandPreview.flatMap(AgentModuleView.risk(ofCommand:))
    }

    private var outcome: AgentHookBridge.Outcome? {
        viewModel.hookBridge.pending.first { $0.id == attention.requestID }?.outcome
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                providerLogo
                VStack(alignment: .leading, spacing: 3) {
                    Text([attention.providerName, attention.projectName].compactMap { $0 }.joined(separator: " \u{00B7} "))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(sessionName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Color.clear.frame(width: centerGap)

            Group {
                if let outcome {
                    let tint = AgentDecisionReceipt.tint(outcome)
                    Text(AgentDecisionReceipt.label(outcome))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 0.75))
                } else if let commandRisk {
                    Text(commandRisk)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color(red: 1.0, green: 0.36, blue: 0.34))
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .overlay(Capsule().stroke(Color(red: 1.0, green: 0.36, blue: 0.34).opacity(0.5), lineWidth: 0.75))
                } else {
                    Text(attention.statusLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(attention.isFailure ? Color.red.opacity(0.85) : (attention.kind == .permission || attention.kind == .question ? Color.orange.opacity(0.9) : .white.opacity(0.64)))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 26)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attention.displayHeadline)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let command = attention.commandPreview {
                ScrollView(.vertical) {
                    Text(Self.highlightedCommand(command)).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: IslandAgentAttention.commandBoxHeight(command))
                .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.15), lineWidth: 0.75))
                // Six lines fit. A longer command says so, rather than
                // looking complete while its tail is out of sight.
                .overlay(alignment: .bottomTrailing) {
                    if AgentApprovalCopy.wrappedLineCount(command, perLine: IslandAgentAttention.commandCharactersPerLine) > IslandAgentAttention.commandVisibleLines {
                        Text("Scroll for the rest")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.75), in: Capsule())
                            .padding(5)
                            .allowsHitTesting(false)
                    }
                }
            } else if let detail = attention.displayDetail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if attention.kind == .question,
               attention.respondsThroughBridge,
               !attention.options.isEmpty {
                choices
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(attention.options) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedOptionID = option.id
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: selectedOptionID == option.id
                            ? "checkmark.circle.fill"
                            : "circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selectedOptionID == option.id
                                ? providerTint
                                : .white.opacity(0.32))
                            .contentTransition(.symbolEffect(.replace))
                        Text(option.label)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AgentNotificationChoiceStyle(
                    selected: selectedOptionID == option.id,
                    tint: providerTint
                ))
                .accessibilityAddTraits(selectedOptionID == option.id ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 7) {
            if attention.kind == .permission && attention.respondsThroughBridge {
                actionButton("Open session", symbol: "arrow.up.right") { viewModel.openAgentSession(attention) }
            }
            waitingCount

            switch attention.kind {
            case .permission where attention.respondsThroughBridge:
                if let outcome {
                    AgentDecisionReceipt(outcome: outcome, provider: attention.providerName, size: 11)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                } else {
                    if let deny = attention.options.first(where: { $0.id == 0 }) {
                        actionButton(deny.label) {
                            viewModel.hookBridge.respond(to: attention.requestID, choice: deny.id)
                        }
                    }
                    if let allow = attention.options.first(where: { $0.id == 1 })
                        ?? attention.options.last {
                        actionButton(allow.label, prominent: true) {
                            viewModel.hookBridge.respond(to: attention.requestID, choice: allow.id)
                        }
                    }
                }

            case .question where attention.respondsThroughBridge:
                actionButton("Send", prominent: true, symbol: "arrow.right") {
                    guard let selectedOptionID else { return }
                    viewModel.hookBridge.respond(
                        to: attention.requestID,
                        choice: selectedOptionID
                    )
                }
                .disabled(selectedOptionID == nil)
                openButton()

            case .permission, .question:
                actionButton(
                    "Open \(attention.providerName)",
                    symbol: "arrow.up.right"
                ) {
                    viewModel.openAgentSession(attention)
                }

            case .completion:
                actionButton(attention.isFailure ? "View output" : "Review", symbol: "arrow.up.right") {
                    viewModel.openAgentSession(attention)
                }

            case .notification:
                if attention.isFailure {
                    actionButton("View output", symbol: "arrow.up.right") { viewModel.openAgentSession(attention) }
                }
            }
        }
        .padding(.top, 2)
        .frame(height: 36)
    }

    @ViewBuilder
    private var waitingCount: some View {
        let count = viewModel.notificationCenter.queuedAgentCount
        if count > 0 {
            Button { viewModel.notificationCenter.showNextAgent() } label: {
                HStack(spacing: 5) {
                    Text("1 of \(count + 1)")
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .contentShape(Rectangle())
            }
            .buttonStyle(.nanoPress)
            .help("Show the next request")
            .fixedSize()
        }
        Spacer(minLength: 4)
    }

    @ViewBuilder
    private var providerLogo: some View {
        if let provider = attention.provider,
           let image = provider.brandImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .scaleEffect(provider.brandScale)
                .frame(width: 30, height: 30)
        } else {
            Image(systemName: attention.provider?.symbol ?? "terminal.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(providerTint)
                .frame(width: 30, height: 30)
        }
    }

    private var sessionName: String {
        guard let sessionID = attention.sessionID,
              let session = viewModel.sessionStore.sessions.first(where: { $0.id == sessionID })
        else { return attention.projectName ?? "Agent session" }
        return session.displayName
    }

    private var centerGap: CGFloat {
        NanoNotificationCenterGap.width(notchWidth: viewModel.notchWidth, minimum: 72)
    }

    private var providerTint: Color {
        attention.provider?.notificationColor ?? Color(red: 0.62, green: 0.70, blue: 0.94)
    }

    /// Claude finished planning: the plan's steps, numbered, with room for
    /// the first five.
    private func planContent(_ plan: AgentPlanSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan.title ?? "\(attention.providerName) has a plan")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(plan.steps.prefix(AgentPlanSummary.visibleSteps).enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 18, height: 18)
                            .background(.white.opacity(0.1), in: Circle())
                        Text(step)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(height: 18)
                }
                if plan.steps.count > AgentPlanSummary.visibleSteps {
                    let more = plan.steps.count - AgentPlanSummary.visibleSteps
                    Text("+\(more) more step\(more == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var planFooter: some View {
        HStack(spacing: 7) {
            actionButton("Open", symbol: "arrow.up.right") { viewModel.openAgentSession(attention) }
            waitingCount
            Spacer(minLength: 8)
            if let outcome, attention.respondsThroughBridge {
                AgentDecisionReceipt(outcome: outcome, provider: attention.providerName, size: 11)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else if attention.respondsThroughBridge {
                if let deny = attention.options.first(where: { $0.id == 0 }) {
                    actionButton("Keep planning") {
                        viewModel.hookBridge.respond(to: attention.requestID, choice: deny.id)
                    }
                    .help("Send the plan back to \(attention.providerName)")
                }
                if let allow = attention.options.first(where: { $0.id == 1 }) ?? attention.options.last {
                    actionButton("Approve plan", prominent: true) {
                        viewModel.hookBridge.respond(to: attention.requestID, choice: allow.id)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(height: 42)
    }

    private var showsFooter: Bool {
        attention.kind != .notification || attention.isFailure
    }

    private func openButton() -> some View {
        actionButton("Open", symbol: "arrow.up.right") {
            viewModel.openAgentSession(attention)
        }
    }

    private func actionButton(
        _ title: String,
        prominent: Bool = false,
        symbol: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 8.5, weight: .bold))
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1)
            .frame(minWidth: 40, minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            AgentNotificationActionStyle(
                prominent: prominent,
                tint: providerTint
            )
        )
    }
}

private struct AgentNotificationActionStyle: ButtonStyle {
    let prominent: Bool
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.black.opacity(0.9) : Color.white.opacity(0.9))
            .padding(.horizontal, 10)
            .background(
                prominent
                    ? Color(red: 0.94, green: 0.93, blue: 0.9).opacity(isEnabled ? 1 : 0.35)
                    : Color.white.opacity(0.065),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        prominent
                            ? Color.white.opacity(isEnabled ? 0.65 : 0.14)
                            : .white.opacity(0.24),
                        lineWidth: 1
                    )
            }
            // Keep a 40pt desktop hit target while the visible control stays
            // compact at 30pt.
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: NanoMotion.control), value: configuration.isPressed)
    }
}

private struct AgentNotificationChoiceStyle: ButtonStyle {
    let selected: Bool
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
            .background(
                selected ? tint.opacity(0.09) : Color.white.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        selected ? tint.opacity(0.38) : .white.opacity(0.065),
                        lineWidth: 1
                    )
            }
            // The visible row is 34pt high, but the desktop hit target remains
            // 40pt so compactness does not make the answer harder to click.
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: NanoMotion.control), value: configuration.isPressed)
            .animation(.easeOut(duration: NanoMotion.control), value: selected)
    }
}

private struct AgentNotificationRevealStage: ViewModifier {
    let revealed: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : -6)
            .blur(radius: revealed || reduceMotion ? 0 : 2)
            .animation(animation, value: revealed)
    }

    private var animation: Animation? {
        guard !reduceMotion else { return nil }
        return NanoMotion.smooth(0.25).delay(delay)
    }
}

struct NotificationHistoryView: View {
    @ObservedObject var center: IslandNotificationCenter

    var body: some View {
        if center.recents.isEmpty {
            ContentUnavailableView(
                "No recent alerts",
                systemImage: "bell",
                description: Text("macOS notifications, volume, brightness, Bluetooth, charging, and agents appear here after they land on the island.")
            )
        } else {
            VStack(spacing: 6) {
                HStack {
                    Text("Recent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    Spacer()
                    Button("Clear all") { center.forgetAllRecents() }
                        .buttonStyle(.nanoPress)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 2)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(center.recents) { item in
                            HStack(spacing: 10) {
                                NotificationHistoryIcon(notification: item)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .lineLimit(1)
                                    if let subtitle = item.subtitle {
                                        Text(subtitle)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.white.opacity(0.5))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Text(historySourceName(item))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.38))
                                Button {
                                    center.forgetRecent(id: item.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .frame(width: 18, height: 18)
                                }
                                .buttonStyle(.nanoPress)
                                .accessibilityLabel("Remove \(item.title)")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func historySourceName(_ notification: IslandNotification) -> String {
        if case let .agent(attention) = notification.payload {
            return attention.providerName
        }
        if let content = notification.systemContent {
            return content.appName
        }
        return notification.source.title
    }
}

private struct NotificationHistoryIcon: View {
    let notification: IslandNotification

    var body: some View {
        Group {
            if case let .agent(attention) = notification.payload,
               let provider = attention.provider,
               let image = provider.brandImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .scaleEffect(provider.brandScale)
            } else if let content = notification.systemContent,
                      let icon = SystemNotificationAppInfo.icon(for: content.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: notification.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(notification.tint)
            }
        }
        .frame(width: 22, height: 22)
    }
}

/// A provider-tinted highlight travels along the border on the compositor.
/// No SwiftUI timer or idle view updates are needed.
struct ProviderNotificationStroke: NSViewRepresentable {
    let tint: NSColor
    let animated: Bool
    let attached: Bool
    let cornerRadius: CGFloat
    let flare: CGFloat
    var showsBase = true
    func makeNSView(context: Context) -> ProviderNotificationStrokeView {
        let view = ProviderNotificationStrokeView()
        view.configure(tint: tint, animated: animated, attached: attached, cornerRadius: cornerRadius, flare: flare, showsBase: showsBase)
        return view
    }
    func updateNSView(_ view: ProviderNotificationStrokeView, context: Context) {
        view.configure(tint: tint, animated: animated, attached: attached, cornerRadius: cornerRadius, flare: flare, showsBase: showsBase)
    }
    static func dismantleNSView(_ view: ProviderNotificationStrokeView, coordinator: Void) {
        view.highlight.removeAllAnimations()
    }
}

final class ProviderNotificationStrokeView: NSView {
    let highlight = CAShapeLayer()
    private let base = CAShapeLayer()
    override var isFlipped: Bool { true }
    private var attached = false
    private var cornerRadius: CGFloat = 17
    private var flare: CGFloat = 0
    private var moving = false
    private var configuredSize = CGSize.zero
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [base, highlight] {
            shape.fillColor = nil
            shape.lineWidth = 0.8
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(tint: NSColor, animated: Bool, attached: Bool, cornerRadius: CGFloat, flare: CGFloat, showsBase: Bool = true) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        base.isHidden = !showsBase
        if self.attached != attached || self.cornerRadius != cornerRadius || self.flare != flare {
            self.attached = attached; self.cornerRadius = cornerRadius; self.flare = flare
            configuredSize = .zero; needsLayout = true
        }
        base.strokeColor = tint.withAlphaComponent(0.25).cgColor
        highlight.strokeColor = tint.withAlphaComponent(0.8).cgColor
        if moving != animated { moving = animated; configuredSize = .zero; needsLayout = true }
        highlight.isHidden = !animated
    }
    override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1, configuredSize != bounds.size else { return }
        configuredSize = bounds.size
        // SwiftUI owns the resize; do not trail it with a second path animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = attached
            ? NanoNotchShape(bottomRadius: cornerRadius, flare: flare, closesTop: false).path(in: rect).cgPath
            : RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect).cgPath
        base.path = path
        highlight.path = path
        highlight.removeAllAnimations()
        guard moving else { return }
        let perimeter = max(1, (attached ? rect.width + 2 * rect.height : 2 * (rect.width + rect.height)) - 8 * cornerRadius + 2 * CGFloat.pi * cornerRadius)
        highlight.lineDashPattern = [NSNumber(value: Double(perimeter * 0.14)), NSNumber(value: Double(perimeter * 0.86))]
        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = -perimeter
        animation.duration = 9.5
        animation.repeatCount = .infinity
        highlight.add(animation, forKey: "providerStroke")
    }
}

// Notification colors are distinct even when providers share monochrome branding.
extension AgentProviderID {
    var notificationColor: Color {
        switch self {
        case .grok: Color(red: 0.52, green: 0.76, blue: 0.94)
        case .pi: Color(red: 0.78, green: 0.62, blue: 0.94)
        case .opencode: Color(red: 0.48, green: 0.84, blue: 0.69)
        case .kimi: Color(red: 0.39, green: 0.56, blue: 0.96)
        default: accentColor
        }
    }
}

/// Small flat silhouettes with the proportions of the Apple accessories.
private struct AccessoryNotificationIcon: View {
    let category: BluetoothAccessoryCategory
    var body: some View {
        Canvas { context, size in
            if category == .keyboard {
                let body = CGRect(x: 0, y: 3, width: 27, height: 15)
                context.fill(Path(roundedRect: body, cornerRadius: 2.5), with: .color(.white.opacity(0.95)))
                for row in 0..<3 {
                    for column in 0..<8 {
                        let key = CGRect(x: 2.4 + Double(column) * 2.8, y: 5 + Double(row) * 2.7, width: 1.9, height: 1.7)
                        context.fill(Path(roundedRect: key, cornerRadius: 0.4), with: .color(.black.opacity(0.72)))
                    }
                }
                context.fill(Path(roundedRect: CGRect(x: 7, y: 13.5, width: 12, height: 1.8), cornerRadius: 0.5), with: .color(.black.opacity(0.72)))
            } else {
                let body = CGRect(x: 7, y: 0.5, width: 13, height: 21)
                context.fill(Path(roundedRect: body, cornerRadius: 6.5), with: .color(.white.opacity(0.95)))
                context.stroke(Path(roundedRect: body.insetBy(dx: 1.2, dy: 1.2), cornerRadius: 5.5), with: .color(.gray.opacity(0.35)), lineWidth: 0.6)
                var seam = Path(); seam.move(to: CGPoint(x: 13.5, y: 2)); seam.addLine(to: CGPoint(x: 13.5, y: 7))
                context.stroke(seam, with: .color(.gray.opacity(0.45)), lineWidth: 0.7)
            }
        }
        .frame(width: 27, height: 22)
        .accessibilityHidden(true)
    }
}

private struct UpdateNoticeCard: View {
    let update: NanoUpdate
    @ObservedObject var viewModel: IslandViewModel

    private var summary: String {
        let line = update.notes?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { String($0.drop { $0 == "-" || $0 == "*" || $0 == " " }) }
        return line ?? "You have \(NanoAppInfo.version). Your settings and permissions carry over."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                NanoMark()
                    .frame(width: 22, height: 22)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nano \(update.version) is available")
                        .font(.system(size: 14, weight: .semibold))
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer()
                noticeButton("Later") { viewModel.dismissUpdateNotice() }
                if update.pageURL != update.downloadURL {
                    noticeButton("What's New") { viewModel.openUpdateNotes(update) }
                }
                noticeButton("Download", prominent: true) { viewModel.downloadUpdate() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
    }

    private func noticeButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(prominent ? Color.white : Color.white.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.nanoPress)
    }
}

/// Something Quill learned from the user's own fixes. Asked at most once a
/// day; "Ignore" never asks about it again.
private struct QuillSuggestionCard: View {
    let correction: VoiceDictationCorrection
    @ObservedObject var viewModel: IslandViewModel

    private var question: Text {
        let times = correction.count == 2 ? "twice" : "\(correction.count) times"
        switch correction.kind {
        case .word:
            return Text("You changed “\(correction.spoken)” to “\(correction.written)” \(times). Write it that way from now on?")
        case .leaveOut:
            return Text("You deleted “\(correction.spoken)” \(times). Leave it out from now on?")
        case .changeOfMind:
            return Text("You said “\(correction.spoken)” and deleted what came before it \(times). Treat it as changing your mind?")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quill can get better")
                        .font(.system(size: 14, weight: .semibold))
                    question
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer()
                cardButton("Ignore") { viewModel.ignoreQuillSuggestion(correction) }
                cardButton("Not now") { viewModel.dismissQuillSuggestion() }
                cardButton("Remember", prominent: true) { viewModel.rememberQuillSuggestion(correction) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
    }

    private func cardButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(prominent ? Color.white : Color.white.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.nanoPress)
    }
}

/// Offer to connect an agent that appeared after setup. Shown once per agent.
private struct AgentSetupCard: View {
    let provider: AgentProviderID
    @ObservedObject var viewModel: IslandViewModel

    private var files: [String] {
        AgentHookBridge.installationConfigURLs(for: [provider]).map { url in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AgentBrandMark(provider: provider, size: 22)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(provider.title) is new on this Mac")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Connect it to see its sessions, usage, and approvals on the island.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                    if let file = files.first {
                        Text("Adds Nano's hooks to \(file)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer()
                setupButton("Not now") { viewModel.dismissAgentSetup(provider) }
                setupButton("Review…") { viewModel.reviewAgentSetup(provider) }
                setupButton("Connect", prominent: true) { viewModel.connectAgent(provider) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .foregroundStyle(.white)
    }

    private func setupButton(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(prominent ? Color.white : Color.white.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.nanoPress)
    }
}
