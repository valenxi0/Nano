import SwiftUI

struct AgentModuleView: View {
    @ObservedObject var service: AgentStatusService
    @ObservedObject var settings: NanoSettings
    @ObservedObject var ledger: TokenLedger
    @ObservedObject var sessions: AgentSessionStore
    @ObservedObject var hooks: AgentHookBridge
    let showingUsage: Bool
    @Binding var usageWindow: NanoTokenWindow

    /// Sections the user has closed. Empty by default, so everything is open
    /// on first view and collapsing is a deliberate act.
    @State private var collapsed: Set<String> = []
    @State private var expandedActivitySessions: Set<String> = []
    @State private var openActivitySessions: Set<String> = []

    /// In-progress rename. The store holds which session is being renamed; the
    /// text being typed is view state and dies with the field.
    @State private var nameDraft = ""
    @State private var hoveredSessionID: String?
    @State private var copiedReplySessionID: String?
    /// Height of the newest exchange, which sizes the conversation's window.
    @State private var newestTurnHeight: CGFloat = 0
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 9) {
            // An agent blocked on a decision outranks everything else here.
            // Past a few cards they scroll: an island as tall as the screen
            // pushed its own controls out of reach.
            if requestCardsHeight > IslandViewModel.maxRequestCardsHeight {
                ScrollView(.vertical) {
                    VStack(spacing: 9) {
                        ForEach(hooks.pending) { requestCard($0) }
                    }
                }
                .frame(height: IslandViewModel.maxRequestCardsHeight - 9)
            } else {
                ForEach(hooks.pending) { requestCard($0) }
            }
            ZStack {
                if showingUsage {
                    AgentUsageDetailView(ledger: ledger, sessions: sessions, window: $usageWindow)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else if let selected = sessions.selectedSession {
                    detail(for: selected)
                        .transition(.asymmetric(
                            // Forward: arrives from the right, the direction of
                            // travel. Reversed on the way out so the same view
                            // leaves the way it came.
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    sessionList
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
            // Clipped so a sliding pane never paints outside the island.
            .clipped()
            .animation(.snappy(duration: 0.26), value: sessions.selectedID)
            .animation(.snappy(duration: 0.24), value: showingUsage)
        }
        .onChange(of: hooks.liveSessions) { _, _ in applyLiveSignals() }
        // An answer from the island changes a row before any hook event does.
        .onChange(of: hooks.pending) { _, _ in applyLiveSignals() }
        .onChange(of: hooks.recentDecisions) { _, _ in applyLiveSignals() }
    }

    private func applyLiveSignals() {
        sessions.applyLiveSignals(hooks.liveSessions, waiting: waitingSessionIDs, decisions: hooks.recentDecisions)
    }

    /// An answered card is no longer anyone waiting.
    private var waitingSessionIDs: Set<String> {
        Set(hooks.pending.filter { !$0.isResolved }.compactMap(\.sessionID))
    }

    // MARK: - Session detail

    /// Built to answer "what is it doing for me, and do I need to act?" before
    /// "which tools ran". Hierarchy comes from type and spacing, not boxes:
    /// one accent (the provider's), semantic colour only for state and diffs.
    /// Every section is driven by fields every provider can fill, and one with
    /// nothing to say is left out, so thinner providers get a shorter panel.
    private func detail(for session: AgentSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailHeader(session)
                    .nanoRevealRow(0)
                detailRule
                conversation(session)
                    .nanoRevealRow(1)
                if !session.todos.isEmpty {
                    planTimeline(session)
                        .nanoRevealRow(2)
                } else if session.plan != nil {
                    planSection(session)
                        .nanoRevealRow(2)
                }
                let subagents = AgentSubagentEntry.entries(
                    for: session,
                    children: sessions.childSessions(of: session.id)
                )
                if !subagents.isEmpty {
                    subagentSection(subagents)
                        .nanoRevealRow(3)
                }
                if Self.hasChanges(session) {
                    detailRule
                    if session.changedFiles.isEmpty {
                        changes(session)
                            .nanoRevealRow(4)
                    } else {
                        changedFiles(session)
                            .nanoRevealRow(4)
                    }
                }
                detailActions(session)
                    .nanoRevealRow(5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: NanoDetailHeightKey.self,
                        // Rounded so sub-pixel jitter during the resize
                        // animation cannot feed back as a new height.
                        value: proxy.size.height.rounded()
                    )
                }
            )
        }
        .scrollIndicators(.never)
        .onPreferenceChange(NanoDetailHeightKey.self) { height in
            sessions.detailContentHeight = height
        }
    }

    /// The title gets its own line: fixed to one line at its natural width, a
    /// long prompt-derived title pushed the whole panel past the island edge.
    private func detailHeader(_ session: AgentSession) -> some View {
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AgentSessionStatusLabel(session: session, size: 11.5)
                Spacer(minLength: 8)
                AgentBrandMark(provider: session.provider, size: 12)
                if let model = session.model {
                    AgentModelName(raw: model, markSize: 11.5)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            Text(session.displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .contextMenu { nameMenu(session) }

            if let parent = sessions.parentSession(of: session) {
                Button { sessions.selectedID = parent.id } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Subagent of \(parent.displayName)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7.5, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Self.subagentsTint)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.nanoPress)
                .help("Open the session that started this one")
            }

            HStack(spacing: 10) {
                if let project = session.project {
                    HStack(spacing: 4) {
                        Text(project.name)
                            .foregroundStyle(.white.opacity(0.7))
                        if project.isWorktree {
                            Text("\u{00B7} worktree")
                        }
                    }
                    .lineLimit(1)
                    .help(session.workingDirectory ?? project.name)
                }
                if let branch = session.gitBranch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                }
                if let started = session.startedAt {
                    Label(Self.elapsed(since: started), systemImage: "clock")
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                if let fraction = session.contextFraction {
                    contextGauge(fraction)
                }
            }
            .labelStyle(NanoCompactLabelStyle())
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    /// A ring: fullness reads at a glance, the number stays for precision.
    private func contextGauge(_ fraction: Double) -> some View {
        let tint = fraction >= AgentSession.contextWarningFraction ? Self.contextTint(fraction) : Color.white.opacity(0.55)
        return HStack(spacing: 4) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 1.8)
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0.02), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            Text("\(Int(fraction * 100))%")
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText(value: fraction))
                .animation(.snappy(duration: 0.35), value: Int(fraction * 100))
        }
        .fixedSize()
        .help("How full the model's context window is")
    }

    private var detailRule: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(height: 1)
    }

    /// The last few exchanges in reading order, ending on what the agent is
    /// doing now. The newest turn is the headline; older ones are context.
    private func conversation(_ session: AgentSession) -> some View {
        let turns = Array(session.displayedTurns.suffix(Self.visibleTurns))
        let latest = session.recentActivity.last
        return VStack(alignment: .leading, spacing: 12) {
            if turns.count > 1 {
                // Only the newest exchange is in view; earlier ones sit above
                // it and scroll into view, so the rest of the panel stays put.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                            let isNewest = index == turns.count - 1
                            if isNewest {
                                turnView(turn, isNewest: true, session: session)
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: {
                                        newestTurnHeight = $0
                                    }
                            } else {
                                turnView(turn, isNewest: false, session: session)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.automatic)
                .frame(height: max(newestTurnHeight, 40))
                .id(session.id)
            } else if let turn = turns.first {
                turnView(turn, isNewest: true, session: session)
            }

            if session.isActive, let latest {
                HStack(spacing: 7) {
                    Image(systemName: latest.kind.symbol)
                        .font(.system(size: 10.5))
                        .foregroundStyle(session.provider.accentColor)
                        .frame(width: 13)
                    NanoShimmerText(
                        text: latest.target.map { "\(latest.detail) \($0)" } ?? latest.detail,
                        active: true
                    )
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(Self.ago(latest.at))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.35))
                        .fixedSize()
                }
            }

            if turns.isEmpty, latest == nil {
                emptyLine("Nothing recorded for this session yet")
            }
        }
    }

    /// One exchange: the prompt, what the agent did, and its reply.
    @ViewBuilder
    private func turnView(_ turn: AgentConversationTurn, isNewest: Bool, session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let prompt = turn.prompt {
                promptBubble(prompt, isNewest: isNewest)
            }
            if isNewest, !session.recentActivity.isEmpty {
                toolSection(session)
            } else if let summary = turn.toolSummary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.36))
                    .lineLimit(1)
                    .padding(.leading, 10)
            }
            if let reply = turn.reply {
                agentReply(reply, session: session, isNewest: isNewest)
            }
        }
    }

    /// Turns kept for scrolling back; only the newest is in view.
    private static let visibleTurns = 6

    private func promptBubble(_ prompt: String, isNewest: Bool) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 70)
            Text(prompt)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(.white.opacity(isNewest ? 0.88 : 0.55))
                .lineLimit(isNewest ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    .white.opacity(isNewest ? 0.09 : 0.05),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private func agentReply(_ reply: String, session: AgentSession, isNewest: Bool) -> some View {
        Group {
            if isNewest {
                NanoStreamingText(text: reply)
                    .lineLimit(8)
            } else {
                Text(reply)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
            }
        }
        .font(.system(size: 12.5))
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 10)
        .padding(.trailing, 30)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(session.provider.accentColor.opacity(isNewest ? 0.55 : 0.25))
                .frame(width: 2)
        }
    }

    /// One row per edited file, newest first. A row opens its file in the
    /// app that owns that file type.
    private func changedFiles(_ session: AgentSession) -> some View {
        let files = Array(session.changedFiles.reversed().prefix(5))
        let hidden = session.changedFiles.count - files.count
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Changed \(session.changedFiles.count) \(session.changedFiles.count == 1 ? "file" : "files")")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text("+\(session.linesAdded)").foregroundStyle(Self.addedTint)
                    Text("\u{2212}\(session.linesRemoved)").foregroundStyle(Self.removedTint)
                }
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
            }
            VStack(spacing: 4) {
                ForEach(files, id: \.path) { file in
                    Button { Self.open(file, in: session) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 13)
                            Text(file.name)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Group {
                                Text("+\(file.added)").foregroundStyle(Self.addedTint)
                                Text("\u{2212}\(file.removed)").foregroundStyle(Self.removedTint)
                            }
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.nanoPress)
                    .help("Open \(file.path)")
                }
            }
            if hidden > 0 {
                Text("\(hidden) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.leading, 10)
            }
        }
    }

    private static let addedTint = Color(red: 0.45, green: 0.8, blue: 0.55)
    private static let removedTint = Color(red: 0.9, green: 0.5, blue: 0.5)

    private static func open(_ file: AgentFileChange, in session: AgentSession) {
        var url = URL(fileURLWithPath: file.path)
        if !file.path.hasPrefix("/"), let directory = session.workingDirectory {
            url = URL(fileURLWithPath: directory).appendingPathComponent(file.path)
        }
        NSWorkspace.shared.open(url)
    }

    /// What is left to do once the result has been read: go there, take the
    /// reply elsewhere, or put the row away.
    private func detailActions(_ session: AgentSession) -> some View {
        let reply = session.conversation.last?.fullReply ?? session.lastAgentMessage
        return HStack(spacing: 7) {
            if AgentSessionJump.canJump(session) {
                detailAction("Open session", symbol: "arrow.up.right") {
                    AgentSessionJump.open(session)
                }
                .help("Open this session in \(AgentSessionJump.hostTitle(for: session))")
            }
            if let reply {
                let copied = copiedReplySessionID == session.id
                detailAction(copied ? "Copied" : "Copy reply", symbol: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reply, forType: .string)
                    copiedReplySessionID = session.id
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        if copiedReplySessionID == session.id { copiedReplySessionID = nil }
                    }
                }
            }
            Spacer(minLength: 0)
            if !session.needsAttention {
                detailAction("Hide", symbol: "eye.slash") { sessions.dismiss(session.id) }
                    .help("Hide until this session is active again")
            }
        }
    }

    private func detailAction(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(.white.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.nanoPress)
    }

    /// Todos as a timeline: nodes on a thin rail, the live step marked, and a
    /// plain count instead of a progress bar.
    private func planTimeline(_ session: AgentSession) -> some View {
        let todos = session.todos
        let done = todos.filter(\.done).count
        let current = todos.firstIndex { !$0.done }
        let window = max(0, (current ?? todos.count) - 1)
        let shown = Array(Array(todos.enumerated()).dropFirst(window).prefix(5))
        let hidden = todos.count - shown.count
        let accent = session.provider.accentColor

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(done == todos.count ? "Plan complete" : "Plan")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text("\(done)/\(todos.count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .contentTransition(.numericText(value: Double(done)))
                    .animation(.snappy(duration: 0.35), value: done)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(accent.opacity(0.14), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.offset) { position, item in
                    let isCurrent = item.offset == current
                    HStack(alignment: .center, spacing: 9) {
                        ZStack {
                            if item.element.done {
                                Circle().fill(accent.opacity(0.85))
                                Image(systemName: "checkmark")
                                    .font(.system(size: 6.5, weight: .heavy))
                                    .foregroundStyle(.black.opacity(0.75))
                                    .transition(.scale(scale: 0.2).combined(with: .opacity))
                            } else if isCurrent && session.isActive {
                                // Core Animation spin: no per-frame work in Nano.
                                NanoSpinnerRing(color: NSColor(accent), lineWidth: 1.6)
                            } else if isCurrent {
                                Circle().stroke(accent, lineWidth: 1.5)
                                Circle().fill(accent).frame(width: 4, height: 4)
                            } else {
                                Circle().stroke(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                            }
                        }
                        .frame(width: 11, height: 11)
                        .animation(.snappy(duration: 0.3), value: item.element.done)
                        Text(item.element.title)
                            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(item.element.done ? 0.42 : (isCurrent ? 0.95 : 0.7)))
                            .lineLimit(1)
                    }
                    .frame(height: 21)
                    .background(alignment: .leading) {
                        // The rail between nodes.
                        if position < shown.count - 1 {
                            Rectangle()
                                .fill(.white.opacity(0.12))
                                .frame(width: 1, height: 10)
                                .offset(x: 5, y: 10.5)
                        }
                    }
                }
            }
            if hidden > 0 {
                Text("\(hidden) more \(hidden == 1 ? "step" : "steps")")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.leading, 20)
            }
        }
    }

    private static func hasChanges(_ session: AgentSession) -> Bool {
        session.linesAdded > 0 || session.linesRemoved > 0 || !session.focusScores.isEmpty
    }

    /// The net diff in one sentence, then the files it kept returning to.
    private func changes(_ session: AgentSession) -> some View {
        let files = session.focusScores.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(files.isEmpty ? "Changes" : "Working in \(files.count) \(files.count == 1 ? "file" : "files")")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
                if session.linesAdded > 0 || session.linesRemoved > 0 {
                    HStack(spacing: 6) {
                        Text("+\(session.linesAdded)").foregroundStyle(Color(red: 0.45, green: 0.8, blue: 0.55))
                            .contentTransition(.numericText(value: Double(session.linesAdded)))
                        Text("\u{2212}\(session.linesRemoved)").foregroundStyle(Color(red: 0.9, green: 0.5, blue: 0.5))
                            .contentTransition(.numericText(value: Double(session.linesRemoved)))
                    }
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .animation(.snappy(duration: 0.35), value: session.linesAdded)
                    .animation(.snappy(duration: 0.35), value: session.linesRemoved)
                }
            }
            if !files.isEmpty {
                NanoFlowLayout(spacing: 5) {
                    ForEach(files, id: \.self) { file in
                        Text(file)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: - Collapsible sections

    /// Header for a collapsible section. Clicking anywhere on the row toggles,
    /// so the target is the whole width rather than a chevron.
    private func sectionHeader(
        _ title: String,
        count: Int?,
        tint: Color,
        isOpen: Bool,
        toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .rotationEffect(.degrees(isOpen ? 0 : -90))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.nanoPress)
    }

    private func isOpen(_ key: String) -> Bool { !collapsed.contains(key) }

    private func toggle(_ key: String) {
        withAnimation(.snappy(duration: 0.18)) {
            if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.42))
    }

    // MARK: Activity

    private static let toolRowHeight: CGFloat = 22
    private static let visibleToolRows = 6

    /// Closed by default and phrased as a sentence: the step log is the detail
    /// behind everything above, not the headline.
    private func toolSection(_ session: AgentSession) -> some View {
        let entries = AgentActivityEntry.groupedForDisplay(
            Array(session.recentActivity.reversed())
        )
        let isExpanded = expandedActivitySessions.contains(session.id)
        let visibleEntries = isExpanded ? entries : Array(entries.prefix(Self.visibleToolRows))
        let hiddenCount = max(0, entries.count - Self.visibleToolRows)
        let isShowing = openActivitySessions.contains(session.id)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isShowing { openActivitySessions.remove(session.id) } else { openActivitySessions.insert(session.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(Self.activitySummary(session.recentActivity))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .rotationEffect(.degrees(isShowing ? 0 : -90))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.nanoPress)

            if isShowing {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        toolRow(entry, index: index, isLast: index == visibleEntries.count - 1)
                    }
                    if hiddenCount > 0 {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                if isExpanded {
                                    expandedActivitySessions.remove(session.id)
                                } else {
                                    expandedActivitySessions.insert(session.id)
                                }
                            }
                        } label: {
                            Text(isExpanded ? "Show less" : "Show \(hiddenCount) earlier")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.leading, 20)
                                .frame(height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.nanoPress)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// "Edited 3 files, read 6, ran 12 commands": the shape of the work.
    private static func activitySummary(_ entries: [AgentActivityEntry]) -> String {
        let counts = Dictionary(grouping: entries, by: \.kind).mapValues(\.count)
        var parts: [String] = []
        if let n = counts[.edit] { parts.append("edited \(n) \(n == 1 ? "file" : "files")") }
        if let n = counts[.read] { parts.append("read \(n)") }
        if let n = counts[.command] { parts.append("ran \(n) \(n == 1 ? "command" : "commands")") }
        if let n = counts[.search] { parts.append("searched \(n) \(n == 1 ? "time" : "times")") }
        if let n = counts[.web] { parts.append("browsed \(n)") }
        if let n = counts[.subagent] { parts.append("delegated \(n)") }
        guard var sentence = parts.first.map({ _ in parts.joined(separator: ", ") }) else {
            return "\(entries.count) steps"
        }
        sentence = sentence.prefix(1).uppercased() + sentence.dropFirst()
        return sentence
    }

    /// One step on the timeline rail.
    private func toolRow(
        _ entry: AgentActivityEntry,
        index: Int,
        isLast: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.kind.symbol)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(index == 0 ? 0.8 : 0.45))
                .frame(width: 12)
            Text(entry.detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(index == 0 ? 0.9 : 0.72))
                .lineLimit(1)
                .layoutPriority(1)
            if let target = entry.target {
                Text(target)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if entry.repeatCount > 1 {
                Text("\u{00D7}\(entry.repeatCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
            Text(Self.ago(entry.at))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.3))
                .fixedSize()
        }
        .frame(height: Self.toolRowHeight)
        .background(alignment: .leading) {
            if !isLast {
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(width: 1, height: 12)
                    .offset(x: 5.5, y: 11)
            }
        }
        .nanoRevealRow(index)
    }

    // MARK: Todos

    // MARK: Plan

    private func planSection(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(
                "Plan",
                count: nil,
                tint: Self.planTint,
                isOpen: isOpen("plan")
            ) { toggle("plan") }

            if isOpen("plan"), let plan = session.plan {
                Text(Self.planMarkdown(plan))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) {
                        // A rule rather than a card: the plan is a quotation
                        // from the agent, and boxing it would add a third
                        // container inside an already nested panel.
                        Rectangle()
                            .fill(Self.planTint.opacity(0.55))
                            .frame(width: 2)
                    }
                    .nanoRevealRow(0)
            }
        }
    }

    private static func planMarkdown(_ plan: String) -> AttributedString {
        (try? AttributedString(
            markdown: plan,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(plan)
    }

    // MARK: Subagents

    private func subagentSection(_ entries: [AgentSubagentEntry]) -> some View {
        let running = entries.filter(\.isRunning).count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                sectionHeader(
                    "Subagents",
                    count: entries.count,
                    tint: Self.subagentsTint,
                    isOpen: isOpen("subagents")
                ) { toggle("subagents") }
                    .fixedSize()
                if running > 0 {
                    Text("\(running) working")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Self.subagentsTint.opacity(0.9))
                }
                Spacer(minLength: 0)
            }

            if isOpen("subagents") {
                let rows = VStack(spacing: Self.subagentRowSpacing) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        subagentRow(entry)
                            .nanoRevealRow(index)
                    }
                }
                // Past a few rows the list scrolls, so a session that
                // delegated a lot does not stretch the island.
                if entries.count > Self.visibleSubagents {
                    ScrollView(.vertical) { rows }
                        .scrollIndicators(.automatic)
                        .frame(height: CGFloat(Self.visibleSubagents) * Self.subagentRowHeight
                            + CGFloat(Self.visibleSubagents - 1) * Self.subagentRowSpacing
                            + Self.subagentRowHeight / 2)
                } else {
                    rows
                }
            }
        }
    }

    /// A child session opens its own detail; a transcript subagent has no
    /// session to open, so its row is not a button.
    @ViewBuilder
    private func subagentRow(_ entry: AgentSubagentEntry) -> some View {
        if let id = entry.sessionID {
            Button { sessions.selectedID = id } label: { subagentRowContent(entry) }
                .buttonStyle(.nanoPress)
                .help("Open this subagent's session")
        } else {
            subagentRowContent(entry)
        }
    }

    private func subagentRowContent(_ entry: AgentSubagentEntry) -> some View {
        HStack(spacing: 8) {
            subagentStatusMark(entry.status)
                .frame(width: 12)
            Text(entry.name)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if let model = entry.model {
                AgentModelName(raw: model, markSize: 10.5)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            } else if let role = entry.role {
                Text(role)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            subagentTime(entry)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .opacity(entry.sessionID == nil ? 0 : 1)
        }
        .padding(.horizontal, 9)
        .frame(height: Self.subagentRowHeight)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(entry.status == .needsYou ? Color.orange.opacity(0.35) : .white.opacity(0.05), lineWidth: 0.75)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func subagentStatusMark(_ status: AgentSubagentEntry.Status) -> some View {
        switch status {
        case .working:
            AgentWorkingOrb(diameter: 11)
                .frame(width: 11, height: 6)
        case .needsYou:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(red: 0.24, green: 0.81, blue: 0.43))
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.red.opacity(0.85))
        case .stopped:
            Circle()
                .fill(.white.opacity(0.25))
                .frame(width: 6, height: 6)
        }
    }

    /// Ticks every second while the subagent runs.
    @ViewBuilder
    private func subagentTime(_ entry: AgentSubagentEntry) -> some View {
        if entry.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                subagentTimeText(entry.timeLabel(now: context.date), live: true)
            }
        } else {
            subagentTimeText(entry.timeLabel(), live: false)
        }
    }

    @ViewBuilder
    private func subagentTimeText(_ text: String?, live: Bool) -> some View {
        if let text {
            Text(text)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(live ? 0.7 : 0.42))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private static let planTint = Color(red: 0.96, green: 0.66, blue: 0.36)
    private static let visibleSubagents = 4
    private static let subagentRowHeight: CGFloat = 27
    private static let subagentRowSpacing: CGFloat = 4
    private static let subagentsTint = AgentSessionRow.subagentTint

    /// Compact age for a feed row: "now", "4m", "2h", "3d".
    private static func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 45 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    /// "2h 14m", and days once an hour count stops being readable. A session
    /// resumed over several days was rendering as "143h 36m".
    private static func elapsed(since start: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(start))
        guard seconds > 0 else { return "just started" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    // MARK: - Pending agent requests

    private var requestCardsHeight: CGFloat {
        hooks.pending.reduce(CGFloat(0)) { $0 + IslandViewModel.requestCardHeight($1) }
    }

    /// Which keys answer a yes/no approval: Return and Escape for the first
    /// card, the same with Command for the second, none after that. On a
    /// question, "option 2" and "option 1" are not a default and a cancel.
    private func keyModifiers(_ request: AgentHookBridge.PendingRequest) -> EventModifiers? {
        guard request.kind == .permission,
              let index = hooks.pending.firstIndex(where: { $0.id == request.id })
        else { return nil }
        switch index {
        case 0: return []
        case 1: return .command
        default: return nil
        }
    }

    private func requestCard(_ request: AgentHookBridge.PendingRequest) -> some View {
        let provider = AgentProviderID.fromHook(source: request.source)
        let tint = provider?.accentColor ?? .orange
        let session = request.sessionID.flatMap { id in sessions.sessions.first { $0.id == id } }
        let risk = Self.risk(of: request)

        return VStack(alignment: .leading, spacing: 11) {
            // Who is asking, for which piece of work.
            HStack(alignment: .center, spacing: 9) {
                Group {
                    if let provider {
                        AgentBrandMark(provider: provider, size: 17)
                    } else {
                        Image(systemName: request.kind == .permission ? "hand.raised.fill" : "bubble.left.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.requestHeadline(request))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    let context = [request.projectName, session?.displayName].compactMap { $0 }
                    if !context.isEmpty {
                        Text(context.joined(separator: "  \u{00B7}  "))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                if let risk {
                    Text(risk)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Self.riskTint)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .overlay(Capsule().stroke(Self.riskTint.opacity(0.5), lineWidth: 0.75))
                } else if case let .diff(_, removed, added, _) = request.preview,
                          let summary = AgentApprovalCopy.diffSummary(removed: removed.count, added: added.count) {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            preview(for: request.preview)

            // Full-width row: a decision that blocks an agent should not be a
            // pair of 60pt buttons tucked at the end of a line.
            if let outcome = request.outcome {
                AgentDecisionReceipt(outcome: outcome, provider: provider?.title ?? "the agent")
                    .frame(height: 32)
            } else {
            HStack(spacing: 8) {
                ForEach(request.options) { option in
                    let primary = option.id == 1 && request.kind == .permission
                    let modifiers = keyModifiers(request)
                    let keyed = modifiers != nil
                    let command = modifiers == .command ? "\u{2318}" : ""
                    Button { hooks.respond(to: request.id, choice: option.id) } label: {
                        HStack(spacing: 6) {
                            Text(AgentApprovalCopy.optionLabel(option, preview: request.preview))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if keyed, primary || option.id == 0 {
                                Text(command + (primary ? "\u{21A9}" : "esc"))
                                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(primary ? .black.opacity(0.5) : .white.opacity(0.4))
                                    .padding(.horizontal, 4)
                                    .frame(height: 15)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(
                                        primary ? .black.opacity(0.25) : .white.opacity(0.2), lineWidth: 0.75
                                    ))
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(primary ? .black : .white.opacity(0.88))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            primary ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.09)),
                            in: Capsule()
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.nanoPress)
                    .keyboardShortcut(Self.shortcut(primary: primary, cancel: option.id == 0, modifiers: modifiers))
                    .help(option.label)
                }

                if request.options.isEmpty {
                    Button { hooks.dismiss(request.id) } label: {
                        Text("Dismiss")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(.white.opacity(0.09), in: Capsule())
                    }
                    .buttonStyle(.nanoPress)
                }
            }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    (request.isResolved ? AgentDecisionReceipt.tint(request.outcome) : (risk != nil ? Self.riskTint : Color.orange)).opacity(0.35),
                    lineWidth: 0.75
                )
        }
        .animation(.snappy(duration: 0.22), value: request.outcome)
    }

    private static let riskTint = Color(red: 1.0, green: 0.36, blue: 0.34)

    /// Tokens that make a command worth a second look, and how to say so.
    /// Pattern checks only: a hint to read carefully, not a verdict.
    private static let riskRules: [(pattern: String, label: String)] = [
        (#"(^|[\s;&|(])rm\s+(-[a-zA-Z]*[rf]|--recursive|--force)"#, "Deletes files"),
        (#"git\s+push\s+.*(--force|-f\b)"#, "Force push"),
        (#"git\s+(reset\s+--hard|clean\s+-[a-zA-Z]*f)"#, "Discards changes"),
        (#"(^|[\s;&|(])sudo\s"#, "Runs as admin"),
        (#"(curl|wget)[^|]*\|\s*(sh|bash|zsh)"#, "Pipes a download to a shell"),
        (#"(?i)\bdrop\s+(table|database)\b"#, "Drops data"),
        (#"(^|[\s;&|(])(mkfs|dd\s+if=|diskutil\s+erase)"#, "Erases a disk"),
        (#"chmod\s+(-R\s+)?777"#, "Opens permissions"),
    ]

    static func risk(of request: AgentHookBridge.PendingRequest) -> String? {
        guard request.kind == .permission, case let .command(command) = request.preview else { return nil }
        return risk(ofCommand: command)
    }

    /// The island's approval card shows the same tag as the module's.
    static func risk(ofCommand command: String) -> String? {
        riskRules.first { command.range(of: $0.pattern, options: .regularExpression) != nil }?.label
    }

    /// The command with its program names in blue and risky tokens in red.
    static func highlighted(_ command: String) -> AttributedString {
        var text = AttributedString(command)
        text.foregroundColor = .white.opacity(0.78)
        // Program names: the first word of each chained command.
        if let regex = try? NSRegularExpression(pattern: #"(^|&&|\|\||;|\|)\s*([A-Za-z0-9_./-]+)"#) {
            for match in regex.matches(in: command, range: NSRange(command.startIndex..., in: command)) {
                guard let range = Range(match.range(at: 2), in: command),
                      let attributed = Range(range, in: text) else { continue }
                text[attributed].foregroundColor = Color(red: 0.55, green: 0.8, blue: 1.0)
            }
        }
        for token in [#"\brm\b"#, #"-rf\b"#, #"--force\b"#, #"\bsudo\b"#, #"--hard\b"#, #"(?i)\bdrop\b"#] {
            guard let regex = try? NSRegularExpression(pattern: token) else { continue }
            for match in regex.matches(in: command, range: NSRange(command.startIndex..., in: command)) {
                guard let range = Range(match.range, in: command),
                      let attributed = Range(range, in: text) else { continue }
                text[attributed].foregroundColor = riskTint
            }
        }
        return text
    }

    private static func shortcut(primary: Bool, cancel: Bool, modifiers: EventModifiers?) -> KeyboardShortcut? {
        guard let modifiers else { return nil }
        if primary { return KeyboardShortcut(.return, modifiers: modifiers) }
        if cancel { return KeyboardShortcut(.escape, modifiers: modifiers) }
        return nil
    }

    private static func requestHeadline(_ request: AgentHookBridge.PendingRequest) -> String {
        guard request.kind == .permission, request.respondsThroughBridge else { return request.title }
        let who = AgentProviderID.fromHook(source: request.source)?.title ?? request.source.capitalized
        return AgentApprovalCopy.headline(provider: who, tool: request.title, preview: request.preview)
    }

    /// The subject of the decision, rendered so it can be judged on sight.
    @ViewBuilder
    private func preview(for preview: AgentHookBridge.Preview) -> some View {
        switch preview {
        case .none:
            EmptyView()

        case let .command(command):
            // The whole command, broken at its joins. A very long one scrolls
            // rather than being cut.
            ScrollView(.vertical) {
                (Text("$ ").foregroundColor(.white.opacity(0.35))
                    + Text(Self.highlighted(AgentApprovalCopy.readableCommand(command))))
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 20 + CGFloat(min(AgentApprovalCopy.wrappedLineCount(command), 8)) * 15)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.07), lineWidth: 0.75)
                )

        case let .diff(path, removed, added, startLine):
            let first = startLine ?? 1
            VStack(alignment: .leading, spacing: 0) {
                Text(startLine.map { "\(path) \u{00B7} line \($0)" } ?? path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.03))
                ForEach(Array(removed.enumerated()), id: \.offset) { index, line in
                    diffRow(number: first + index, text: line, added: false)
                }
                ForEach(Array(added.enumerated()), id: \.offset) { index, line in
                    diffRow(number: first + index, text: line, added: true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

        case let .arguments(fields):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    Text(field)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case let .plan(markdown):
            let plan = AgentPlanSummary.parse(markdown)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(plan.steps.prefix(AgentPlanSummary.visibleSteps).enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(index + 1).")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.45))
                        Text(step)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func diffRow(number: Int, text: String, added: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .frame(width: 30, alignment: .trailing)
            Text(added ? "+" : "-")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(added ? .green.opacity(0.9) : .red.opacity(0.85))
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(added ? Color.green.opacity(0.14) : Color.red.opacity(0.14))
    }

    // MARK: - Sessions

    /// Three different reasons for an empty list, each with what to do next.
    @ViewBuilder
    private var emptyList: some View {
        let found = service.snapshots.filter(\.isConfigured).map(\.id.title)
        let connected = AgentHookBridge.hooksAreInstalled()
        VStack(alignment: .leading, spacing: 3) {
            if found.isEmpty && !connected {
                Text("No agents found on this Mac")
                    .font(.system(size: 13, weight: .semibold))
                Text("Nano works with Claude Code, Codex, Cursor, Gemini and others. Install one and it shows up here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            } else if !connected {
                Text(Self.foundSentence(found))
                    .font(.system(size: 13, weight: .semibold))
                Text("Connect them to answer approvals and questions from the notch.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
                Button {
                    NotificationCenter.default.post(name: .nanoOpenSettings, object: SettingsDestination.agents.rawValue)
                } label: {
                    Text("Connect\u{2026}")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.nanoPress)
                .padding(.top, 7)
            } else {
                Text("Nothing running")
                    .font(.system(size: 13, weight: .semibold))
                Text("Start an agent and it shows up here.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }

    private static func foundSentence(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Your agents aren't connected"
        case 1: return "\(names[0]) found"
        case 2: return "\(names[0]) and \(names[1]) found"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more found"
        }
    }

    private var sessionList: some View {
        let live = sessions.liveSessions

        return ScrollView {
            // This list is capped at eight rows. Keeping those rows eager and
            // top-anchored prevents LazyVStack from retaining old viewport
            // positions while the island's height spring adds a new first row.
            VStack(alignment: .leading, spacing: 4) {
                if live.isEmpty {
                    emptyList
                } else {
                    let shown = Array(live.prefix(AgentSessionStore.islandVisibleLimit))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, session in
                        // The field cannot live inside the row's button: the
                        // button would swallow the clicks that place the caret.
                        if sessions.renamingID == session.id {
                            renameRow(session)
                        } else {
                            HStack(alignment: .top, spacing: 6) {
                                Button { sessions.selectedID = session.id } label: { sessionRow(session) }
                                    .buttonStyle(.nanoPress)
                                    .contextMenu { nameMenu(session) }
                                // Same top inset as the row, so the arrow sits
                                // on the model line instead of floating in the
                                // middle of a two-line session.
                                // The dismiss button takes the second line
                                // under the arrow, so hovering never shifts
                                // the row's own columns.
                                VStack(spacing: 7) {
                                    AgentJumpButton(session: session)
                                    if !session.needsAttention {
                                        AgentDismissButton { sessions.dismiss(session.id) }
                                            .opacity(hoveredSessionID == session.id ? 1 : 0)
                                    }
                                }
                                .frame(width: 14)
                                .padding(.top, 9)
                                .padding(.trailing, 8)
                            }
                            .onHover { inside in
                                if inside {
                                    hoveredSessionID = session.id
                                } else if hoveredSessionID == session.id {
                                    hoveredSessionID = nil
                                }
                            }
                            .animation(.snappy(duration: 0.16), value: hoveredSessionID)
                            // Every row owns the same full-width lane. Without
                            // this, the stack centers each row at its intrinsic
                            // width, so longer titles pull their provider mark
                            // farther left than shorter titles do.
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // Separator between rows only - no trailing rule under
                        // the last one, which would read as a box edge again.
                        if index < shown.count - 1 {
                            Rectangle()
                                .fill(.white.opacity(0.07))
                                .frame(height: 1)
                                .padding(.horizontal, 8)
                        }
                    }
                }

                let hidden = sessions.dismissedSessionCount
                if hidden > 0 {
                    Button { sessions.restoreDismissedSessions() } label: {
                        Text("\(hidden) hidden \u{00B7} Show")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.nanoPress)
                    .help("Hidden sessions come back on their own when they are active again")
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: NanoListHeightKey.self,
                        value: proxy.size.height.rounded()
                    )
                }
            )
        }
        .scrollIndicators(.never)
        .onPreferenceChange(NanoListHeightKey.self) { height in
            sessions.listContentHeight = height
        }
    }

    /// Rename in place, in the row the name is already in — a sheet over a
    /// panel this size would cover the thing being renamed.
    private func renameRow(_ session: AgentSession) -> some View {
        HStack(alignment: .center, spacing: 10) {
            AgentBrandMark(provider: session.provider, size: 29)
                .frame(width: 33, height: 33)

            // The placeholder is the automatic name, so leaving the field empty
            // visibly means "keep using that one".
            TextField(session.displayName, text: $nameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .focused($nameFieldFocused)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .onSubmit { sessions.rename(session.id, to: nameDraft) }
                // Escape leaves the name as it was; an empty field commits as
                // "no name" and hands the row back to the automatic one.
                .onExitCommand { sessions.renamingID = nil }

            Text("\u{21A9}")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            nameDraft = sessions.localName(session.id) ?? ""
            nameFieldFocused = true
        }
    }

    @ViewBuilder
    private func nameMenu(_ session: AgentSession) -> some View {
        Button("Rename\u{2026}") { sessions.beginRename(session.id) }
        if sessions.localName(session.id) != nil {
            Button("Use Automatic Name") { sessions.rename(session.id, to: nil) }
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        AgentSessionRow(session: session)
    }

    /// Grey while there is room, warming to red as the window fills. A full
    /// context is the thing worth noticing before the agent starts forgetting.
    static func contextTint(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.5: .white.opacity(0.32)
        case ..<0.75: .orange.opacity(0.65)
        case ..<0.9: .orange
        default: .red.opacity(0.9)
        }
    }

    /// Ids whose literal form names no plan the vendor actually sells.
    ///
    /// Checked against each vendor's own pricing page on 2026-08-12. Scoped per
    /// provider because the same id means different things: `free` is Cursor's
    /// Hobby tier, while for OpenAI it really is called Free.
    private static let planNames: [AgentProviderID: [String: String]] = [
        // Free, Go, Plus, Pro, Business, Enterprise. Pro has two usage tiers —
        // 5x and 20x — and the API reports the 5x one as `prolite`.
        .codex: ["prolite": "Pro 5x"],
        // Hobby, Pro, Pro+, Ultra, Teams, Enterprise.
        .cursor: [
            "pro-plus": "Pro+",
            "proplus": "Pro+",
            "business": "Teams",
        ],
        // Kimi names its tiers after musical tempos — Adagio, Moderato,
        // Allegretto, Allegro, Vivace — which survive capitalisation intact,
        // so there is nothing here to translate.
        // OpenCode's quota endpoint is the Go subscription; keep the camel
        // case the title-caser would flatten.
        .opencode: ["opencode go": "OpenCode Go"],
    ]

    /// Entry tiers, which get no label at all.
    ///
    /// Naming one says nothing a user wants on screen next to their quota —
    /// Cursor's Hobby and Kimi's Adagio are the free tiers, and OpenAI's Go is
    /// the entry tier below Plus. The pill drops the slot entirely rather than
    /// showing a placeholder, so those users see mark, usage, and nothing else.
    private static let unlabelledPlans: [AgentProviderID: Set<String>] = [
        .codex: ["free", "go"],
        .cursor: ["free", "hobby"],
        .kimi: ["free", "adagio"],
        .gemini: ["free"],
    ]

    /// Providers report a plan as an id, not a name: Codex says `prolite`,
    /// Kimi `LEVEL_ALLEGRO`, Cursor `free`.
    ///
    /// Display only. Ids are tidied into words and shown as reported, except
    /// where the literal form names nothing real — "Pro Lite" is not a plan
    /// OpenAI sells — and except the entry tiers, which are shown as no label
    /// at all. Claude reports no plan either way, so its pill never has one.
    static func planLabel(_ raw: String?, provider: AgentProviderID) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }

        let slug = raw.lowercased().replacingOccurrences(of: "level_", with: "")
        if Self.unlabelledPlans[provider]?.contains(slug) == true { return nil }
        if let named = Self.planNames[provider]?[slug] { return named }

        return slug
            .split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            .map(\.capitalized)
            .joined(separator: " ")
    }

    /// `claude-opus-5` reads as a config value, not a model. Strip the vendor
    /// prefix and the deployment suffix and title-case what is left.
    ///
    /// Cursor's system prompt names the host ("Cursor Grok 4.6"). The island
    /// already shows the Cursor mark, so only the model remains.
    static func fusionPair(_ raw: String) -> (lead: String, sidekick: String)? {
        let slug = raw.lowercased()
        guard slug.hasPrefix("fusion-"), let split = slug.range(of: "-sidekick-") else { return nil }
        // Speed tiers trail the effort and are not part of either name.
        func model(_ half: Substring) -> String {
            var parts = half.split(separator: "-")
            while let last = parts.last, last == "fast" || last == "priority" { parts.removeLast() }
            return parts.joined(separator: "-")
        }
        return (model(slug[slug.index(slug.startIndex, offsetBy: 7)..<split.lowerBound]),
                model(slug[split.upperBound...]))
    }

    static func modelName(_ raw: String) -> String {
        var slug = raw.lowercased()
        // Devin's Fusion pairs a lead with a sidekick:
        // `fusion-claude-opus-5-5-medium-sidekick-swe-2-medium`. Name both;
        // `AgentModelName` draws the mark that says they are fused.
        if let pair = fusionPair(slug) {
            return "\(modelName(pair.lead)) + \(modelName(pair.sidekick))"
        }
        // Whoever routes the model (`anthropic/`, `kilo/`) is not its name.
        if let slash = slug.lastIndex(of: "/") {
            slug = String(slug[slug.index(after: slash)...])
        }
        for prefix in ["claude-", "openai-", "cursor-"] where slug.hasPrefix(prefix) {
            slug.removeFirst(prefix.count)
        }
        if slug.hasPrefix("cursor ") {
            slug.removeFirst("cursor ".count)
        }
        var parts = slug.split { $0 == "-" || $0 == " " }.map(String.init)
        let effortTags: Set<String> = [
            "minimal", "low", "medium", "high", "xhigh", "max", "ultra",
        ]
        if let last = parts.last, effortTags.contains(last) {
            parts.removeLast()
        }
        if let last = parts.last, last == "thinking" || last == "reasoning" {
            parts.removeLast()
        }
        if parts.count > 1, let last = parts.last,
           last.count >= 3, last.allSatisfy(\.isNumber) || last.allSatisfy(\.isLetter) && last.count <= 4,
           !["codex", "mini", "pro", "max", "high", "low", "plus", "lite", "sol", "luna"].contains(last),
           Double(last) == nil {
            parts.removeLast()
        }
        // A release date (`-20250929`) says nothing the version does not.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        // `opus-5-5` is Opus 5.5: one version split across two short numbers.
        if let index = parts.indices.dropLast().first(where: { index in
            [parts[index], parts[index + 1]].allSatisfy { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        }) {
            parts[index] += "." + parts.remove(at: index + 1)
        }

        return parts.map { part in
            if part.hasPrefix("gpt") || ["o3", "o4", "swe", "glm"].contains(part) {
                return part.uppercased()
            }
            if Double(part) != nil { return part }
            // `4o` is a version, not a word.
            if part.first?.isNumber == true { return part }
            return part.capitalized
        }.joined(separator: " ")
    }

    // MARK: - Formatting

    static func compact(_ value: Int) -> String {
        let magnitudes: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        let amount = Double(value)
        for (threshold, suffix) in magnitudes where amount >= threshold {
            let scaled = amount / threshold
            return String(format: scaled >= 100 ? "%.0f%@" : "%.1f%@", scaled, suffix)
        }
        return "\(value)"
    }

    static func money(_ nanos: Int) -> String {
        let dollars = Double(nanos) / 1_000_000_000
        // Four figures without a separator reads as a token count, not money.
        if dollars >= 1000 {
            let grouped = Self.grouping.string(from: NSNumber(value: dollars.rounded()))
            return "$\(grouped ?? String(format: "%.0f", dollars))"
        }
        if dollars >= 1 { return String(format: "$%.2f", dollars) }
        return dollars > 0 ? String(format: "$%.3f", dollars) : "$0"
    }

    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

struct MusicModuleView: View {
    @ObservedObject var controller: MediaController
    @ObservedObject var settings: NanoSettings

    var body: some View {
        HStack(spacing: 20) {
            MediaArtwork(
                controller: controller,
                size: 162,
                cornerRadius: 20,
                symbolSize: 48
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        NanoMarqueeText(
                            text: controller.nowPlaying?.title ?? controller.lastPlayed?.title ?? "Nothing playing",
                            fontSize: 17,
                            weight: .semibold,
                            height: 22
                        )
                        .opacity(controller.nowPlaying == nil && controller.lastPlayed != nil ? 0.75 : 1)
                        Text(controller.nowPlaying?.artist ?? controller.lastPlayed?.artist ?? mediaSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)

                    if let track = controller.nowPlaying {
                        HStack(spacing: 6) {
                            NanoWave(
                                barWidth: 2.5,
                                height: 11,
                                color: track.player.accentColor,
                                isActive: track.isPlaying
                            )
                            Text(track.isPlaying ? "Playing" : "Paused")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(playbackTint)
                        }
                        .frame(height: 22)
                    } else {
                        MediaIdlePill(controller: controller)
                    }
                }

                if controller.nowPlaying != nil {
                    moduleControls
                } else {
                    Spacer(minLength: 0)
                    if let last = controller.lastPlayed {
                        MediaLastPlayedLine(lastPlayed: last)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }

                if let error = controller.errorMessage {
                    Text(error)
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            .frame(height: 162)
        }
    }

    private var moduleControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaProgressRow(controller: controller, spacing: 11)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))

            HStack(spacing: 28) {
                Spacer()
                Button(action: controller.previousTrack) {
                    Image(systemName: "backward.fill")
                }
                Button(action: controller.playPause) {
                    Image(
                        systemName: controller.nowPlaying?.isPlaying == true
                            ? "pause.fill"
                            : "play.fill"
                    )
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 43, height: 43)
                    .background(.white, in: Circle())
                    .foregroundStyle(.black)
                }
                Button(action: controller.nextTrack) {
                    Image(systemName: "forward.fill")
                }
                Spacer()
            }
            .buttonStyle(.nanoPress)
            .font(.system(size: 17))
        }
    }

    private var playerAccent: Color {
        controller.nowPlaying?.player.accentColor ?? .green
    }

    private var playbackTint: Color {
        controller.nowPlaying?.isPlaying == true ? playerAccent : .white.opacity(0.42)
    }

    private var mediaSubtitle: String {
        guard let first = controller.availablePlayers.first else {
            return "Open Apple Music or Spotify"
        }
        return "Ready to control \(first.title)"
    }

}

struct BatteryModuleView: View {
    @ObservedObject var service: SystemStatusService

    var body: some View {
        Group {
            if let battery = service.battery {
                HStack(spacing: 18) {
                    Image(
                        systemName: battery.isCharging
                            ? "battery.100percent.bolt"
                            : batterySymbol(battery.percentage)
                    )
                    .font(.system(size: 42))
                    .foregroundStyle(battery.percentage <= 20 ? Color.red : .green)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(battery.percentage)%")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text(batteryStatus(battery))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    Spacer()
                }
            } else {
                ContentUnavailableView(
                    "No internal battery",
                    systemImage: "battery.0percent",
                    description: Text("Battery status is available on portable Macs.")
                )
            }
        }
    }

    private func batterySymbol(_ percentage: Int) -> String {
        if percentage >= 75 { return "battery.100percent" }
        if percentage >= 50 { return "battery.75percent" }
        if percentage >= 25 { return "battery.50percent" }
        return "battery.25percent"
    }

    private func batteryStatus(_ battery: BatterySnapshot) -> String {
        if battery.isCharging { return "Charging" }
        if battery.isPluggedIn { return "Connected to power" }
        guard let minutes = battery.timeRemainingMinutes else { return "On battery" }
        return "\(minutes / 60)h \(minutes % 60)m remaining"
    }
}

struct VolumeModuleView: View {
    @ObservedObject var service: SystemStatusService

    var body: some View {
        Group {
            if let volume = service.outputVolume {
                VStack(spacing: 16) {
                    Image(
                        systemName: service.isMuted
                            ? "speaker.slash.fill"
                            : volumeSymbol(volume)
                    )
                    .font(.system(size: 38))
                    HStack {
                        Image(systemName: "speaker.fill")
                        Slider(value: volumeBinding, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill")
                        Text(volume, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Volume unavailable",
                    systemImage: "speaker.slash",
                    description: Text(
                        "The current output device does not expose a master volume."
                    )
                )
            }
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { service.outputVolume ?? 0 },
            set: { newValue in service.setOutputVolume(newValue) }
        )
    }

    private func volumeSymbol(_ volume: Double) -> String {
        if volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// Elapsed time, the seek bar and time remaining. While a track plays the
/// labels tick every second from the controller's last sample; nothing asks
/// the player for it. Dragging the bar previews the time and seeks on release.
struct MediaProgressRow: View {
    @ObservedObject var controller: MediaController
    var spacing: CGFloat = 9
    var barHeight: CGFloat = 4
    var showsTimes = true

    @State private var scrub: Double?

    var body: some View {
        let track = controller.nowPlaying
        TimelineView(MediaClockSchedule(track: track)) { context in
            row(track, at: context.date)
        }
    }

    private func row(_ track: MediaNowPlaying?, at date: Date) -> some View {
        let duration = track?.duration ?? 0
        let elapsed = scrub.map { $0 * duration } ?? track?.position(at: date) ?? 0
        let fraction = scrub ?? track?.progress(at: date) ?? 0

        return HStack(spacing: spacing) {
            if showsTimes {
                Text(Self.label(elapsed))
            }
            MediaScrubBar(
                value: fraction,
                height: barHeight,
                isEnabled: duration > 0,
                scrub: $scrub
            ) { fraction in
                controller.seek(to: fraction * duration)
            }
            if showsTimes {
                // Radio and other live streams have no end to count down to.
                Text(track != nil && duration <= 0 ? "Live" : "-\(Self.label(max(duration - elapsed, 0)))")
            }
        }
    }

    static func label(_ interval: TimeInterval) -> String {
        let seconds = max(Int(interval), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Ticks once a second while the track plays, on the instants its displayed
/// second changes. A paused or missing track gets a single entry, so an idle
/// player costs nothing.
private struct MediaClockSchedule: TimelineSchedule {
    let track: MediaNowPlaying?

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        guard let track, track.isPlaying else {
            var pending: Date? = startDate
            return AnyIterator {
                defer { pending = nil }
                return pending
            }
        }
        let fraction = track.position - track.position.rounded(.down)
        let anchor = track.sampledAt.addingTimeInterval(1 - fraction + 0.01)
        return AnyIterator(
            PeriodicTimelineSchedule(from: anchor, by: 1)
                .entries(from: startDate, mode: mode)
                .makeIterator()
        )
    }
}

/// The progress bar, and the seek control whenever there is a duration to
/// seek within. It thickens and shows a knob under the pointer.
struct MediaScrubBar: View {
    let value: Double
    var height: CGFloat = 4
    var isEnabled = true
    @Binding var scrub: Double?
    let onSeek: (Double) -> Void

    @State private var isHovering = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = min(max(value, 0), 1)
            let isActive = isEnabled && (isHovering || scrub != nil)

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(.white)
                    .frame(width: width * fraction)
                if isActive {
                    Circle()
                        .fill(.white)
                        .frame(width: 10, height: 10)
                        .offset(x: width * fraction - 5)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .frame(height: isActive ? height + 2 : height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled else { return }
                        scrub = min(max(drag.location.x / width, 0), 1)
                    }
                    .onEnded { drag in
                        guard isEnabled else { return }
                        onSeek(min(max(drag.location.x / width, 0), 1))
                        scrub = nil
                    }
            )
            .onHover { isHovering = $0 }
        }
        .frame(height: 14)
        .animation(.snappy(duration: 0.15), value: isHovering)
        .animation(.snappy(duration: 0.15), value: scrub == nil)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: onSeek(min(value + 0.05, 1))
            case .decrement: onSeek(max(value - 0.05, 0))
            @unknown default: break
            }
        }
    }
}

/// Top right of a music view once nothing is playing: Resume for the last
/// song, or a way into a player before there has been one.
struct MediaIdlePill: View {
    @ObservedObject var controller: MediaController
    @State private var isHovering = false

    var body: some View {
        if let last = controller.lastPlayed {
            pill("Resume", symbol: "play.fill", action: controller.resumeLastPlayed)
                .help("Play \(last.title) in \(last.player.title)")
        } else if let player = controller.suggestedPlayer {
            pill("Open \(player.title)", symbol: nil) { controller.open(player) }
        }
    }

    private func pill(_ title: String, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 8, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.leading, symbol == nil ? 10 : 8)
            .padding(.trailing, 10)
            .frame(height: 22)
            .background(.white.opacity(isHovering ? 0.16 : 0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.nanoPress)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.15), value: isHovering)
    }
}

/// "Last played on Spotify · 2h ago", kept current once a minute.
struct MediaLastPlayedLine: View {
    let lastPlayed: MediaLastPlayed

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(lastPlayed.player.accentColor)
                    .frame(width: 6, height: 6)
                Text("Last played on \(lastPlayed.player.title) · \(MediaLastPlayed.ago(from: lastPlayed.playedAt, now: context.date))")
                    .lineLimit(1)
            }
        }
    }
}

/// The now-playing cover, which opens the player. Dimmed while it shows the
/// last song rather than a playing one.
struct MediaArtwork: View {
    @ObservedObject var controller: MediaController
    let size: CGFloat
    var cornerRadius: CGFloat = 12
    var symbolSize: CGFloat = 20

    var body: some View {
        Button(action: controller.openPlayer) {
            NanoArtworkTile(
                image: controller.artwork,
                size: size,
                cornerRadius: cornerRadius,
                symbolSize: symbolSize
            )
            .opacity(controller.nowPlaying == nil && controller.artwork != nil ? 0.45 : 1)
        }
        .buttonStyle(.nanoPress)
        .disabled(controller.nowPlaying == nil)
        .help(controller.nowPlaying.map { "Open \($0.player.title)" } ?? "")
    }
}

struct NanoArtworkTile: View {
    let image: NSImage?
    let size: CGFloat
    var cornerRadius: CGFloat = 12
    var symbolSize: CGFloat = 20

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                emptySleeve
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: image.map(ObjectIdentifier.init))
    }

    /// Dark sleeve, paused mix. Still bars instead of a disc, a note, or
    /// another jacket — same idle language as the island's waveform.
    private var emptySleeve: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.white.opacity(0.03),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            idleBars
        }
    }

    private var idleBars: some View {
        let heights: [CGFloat] = if size >= 80 {
            [0.34, 0.62, 0.46, 0.78, 0.40]
        } else if size >= 52 {
            [0.38, 0.64, 0.50]
        } else {
            [0.42, 0.58]
        }
        let barWidth = max(size * 0.075, 2.4)

        return HStack(alignment: .center, spacing: barWidth * 0.9) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, fraction in
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(width: barWidth, height: max(size * fraction * 0.40, 4))
            }
        }
    }
}

extension MediaPlayerKind {
    var accentColor: Color {
        switch self {
        case .appleMusic: Color(red: 0.98, green: 0.19, blue: 0.35)
        case .spotify: Color(red: 0.11, green: 0.73, blue: 0.33)
        }
    }
}

/// Fades a row up as it appears, staggered by its position in the list.
///
/// Translated from a Framer Motion spec: `opacity 0 -> 1` with a short upward
/// travel, children delayed behind one another. Only the text half of that
/// reference — the path-drawing flourish around it is deliberately not here.
///
/// The travel is 6pt rather than the reference's 20: that spec was for a hero
/// title, and the same distance on an 18pt row reads as a jump.
private struct NanoRevealRow: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onAppear {
                guard !reduceMotion else {
                    shown = true
                    return
                }
                withAnimation(
                    .easeOut(duration: 0.32)
                        // Capped: a 60-row tool list should not take two
                        // seconds to finish arriving.
                        .delay(Double(min(index, 10)) * 0.03)
                ) {
                    shown = true
                }
            }
    }
}

extension View {
    func nanoRevealRow(_ index: Int) -> some View {
        modifier(NanoRevealRow(index: index))
    }
}

/// Reports the detail view's natural content height up to the window sizer.
///
/// Measured rather than tallied. Every previous version of this added up
/// per-section constants by hand, which had to be re-derived whenever the view
/// changed and failed silently by clipping. The content already knows how tall
/// it is; the island just has to ask.
struct NanoDetailHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Same idea as `NanoDetailHeightKey`, for the session list.
///
/// A separate key rather than a shared one: during the slide transition both
/// panes are mounted at once, and `reduce` taking the max of the two would
/// size the island to whichever is taller mid-animation.
struct NanoListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The primary session label is its own view so its width contract can be
/// exercised without constructing a live agent store. Session names come from
/// several clients and are not guaranteed to be short.
/// One session as the Agents module lists it. The dashboard draws the same
/// row in `compact` form, so the two never read as different designs.
/// "2 subagents" on a parent's row, spinning while any of them works.
struct AgentSubagentCountChip: View {
    let working: Int
    let total: Int
    var size: CGFloat = 11

    private var running: Bool { working > 0 }

    var body: some View {
        HStack(spacing: 4) {
            if running {
                AgentWorkingOrb(diameter: size)
                    .frame(width: size, height: 6)
            }
            Text(label)
                .lineLimit(1)
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(AgentSessionRow.subagentTint.opacity(running ? 1 : 0.75))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(AgentSessionRow.subagentTint.opacity(0.14), in: Capsule())
        .fixedSize()
        .help(running ? "\(working) of \(total) subagents still working" : "All \(total) subagents finished")
    }

    private var label: String {
        let noun = total == 1 ? "subagent" : "subagents"
        if running { return working == total ? "\(total) \(noun)" : "\(working)/\(total) \(noun)" }
        return "\(total) \(noun) \u{00B7} done"
    }
}

struct AgentSessionRow: View {
    /// The Subagents section's colour, shared by every subagent marker.
    static let subagentTint = Color(red: 0.86, green: 0.56, blue: 0.96)

    let session: AgentSession
    var compact = false
    /// Model and context column. A half-width widget has no room for it.
    var showsDetails = true

    private func size(_ full: CGFloat, _ small: CGFloat) -> CGFloat { compact ? small : full }

    var body: some View {
        let waiting = session.needsAttention
        return HStack(alignment: .top, spacing: size(10, 8)) {
            // No enclosing circle: the brand marks already read as badges, and
            // ringing them just added a second shape at every row's left edge.
            AgentBrandMark(provider: session.provider, size: size(29, 22))
                .opacity(session.isActive || waiting ? 1 : 0.5)
                .frame(width: size(33, 25), height: size(33, 25))

            VStack(alignment: .leading, spacing: size(3, 2)) {
                AgentSessionTitleLabel(title: session.displayName, size: size(15, 12.5))

                if let parentTitle = session.parentTitle {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: size(9, 8), weight: .semibold))
                        Text("Subagent of \(parentTitle)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: size(11.5, 10), weight: .medium))
                    .foregroundStyle(AgentSessionRow.subagentTint)
                }

                HStack(spacing: 6) {
                    AgentSessionStatusLabel(session: session, size: size(12, 10.5))
                    if session.subagentCount > 0 {
                        AgentSubagentCountChip(
                            working: session.subagentsWorking,
                            total: session.subagentCount,
                            size: size(11, 9.5)
                        )
                        .layoutPriority(1)
                    }
                    // The answer just sent from the island, so a glance
                    // confirms the tap landed after its card is gone.
                    if let note = session.nanoDecision {
                        TimelineView(.periodic(from: note.at, by: AgentSession.decisionNoteLifetime)) { context in
                            if context.date.timeIntervalSince(note.at) < AgentSession.decisionNoteLifetime {
                                Text("\u{00B7} \(note.allowed ? "allowed" : "denied") from Nano")
                                    .font(.system(size: size(12, 10.5), weight: .medium))
                                    .foregroundStyle(AgentDecisionReceipt.tint(note.allowed ? .allowed : .denied).opacity(0.9))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                    }
                    // Which project, first: several sessions often share a
                    // title's topic but not a checkout. When the line runs
                    // out of room the activity goes first, then the branch.
                    if let project = session.project {
                        Text("\u{00B7} \(project.name)")
                            .font(.system(size: size(12, 10.5), weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                            .help(session.workingDirectory ?? project.name)
                    }
                    if let branch = session.gitBranch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: size(11.5, 10)))
                            .foregroundStyle(.white.opacity(0.3))
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                    if let detail = session.statusDetail() {
                        Text("\u{00B7} \(detail)")
                            .font(.system(size: size(12, 10.5)))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .layoutPriority(-2)
                    }
                }

                // Your last prompt, on its own dimmer line so it does not
                // compete with the title.
                if !compact, let prompt = session.lastUserPrompt, prompt != session.displayName {
                    Text(prompt)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.36))
                        .lineLimit(1)
                }

                // Plan progress, only while it is moving.
                if session.isActive, !session.todos.isEmpty {
                    let total = min(session.todos.count, 10)
                    let done = min(session.todos.filter(\.done).count, total)
                    HStack(spacing: 3) {
                        ForEach(0..<total, id: \.self) { index in
                            Capsule()
                                .fill(index < done ? session.provider.accentColor : .white.opacity(0.12))
                                .frame(height: size(2.5, 2))
                        }
                    }
                    .frame(width: CGFloat(total) * size(22, 16))
                    .padding(.top, 2)
                    .animation(.snappy(duration: 0.3), value: done)
                }
            }

            Spacer(minLength: 0)

            if showsDetails {
                VStack(alignment: .trailing, spacing: size(3, 2)) {
                    if let model = session.model {
                        AgentModelName(raw: model, markSize: size(12, 10.5))
                            .font(.system(size: size(12, 10.5), weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    if let fraction = session.contextFraction {
                        HStack(spacing: 4) {
                            ZStack {
                                Circle().stroke(.white.opacity(0.12), lineWidth: 1.7)
                                Circle()
                                    .trim(from: 0, to: min(max(fraction, 0.02), 1))
                                    .stroke(
                                        fraction >= AgentSession.contextWarningFraction ? AgentModuleView.contextTint(fraction) : .white.opacity(0.55),
                                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
                                    )
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: size(11, 9), height: size(11, 9))
                            Text("\(Int(fraction * 100))%")
                                .font(.system(size: size(12, 10.5)))
                                .foregroundStyle(fraction >= AgentSession.contextWarningFraction ? AgentModuleView.contextTint(fraction) : .white.opacity(0.5))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: fraction))
                                .animation(.snappy(duration: 0.3), value: fraction)
                        }
                        .help("How full the model's context window is")
                    }
                    AgentTurnRuntimeLabel(session: session, size: size(11.5, 10))
                }
            }
        }
        .padding(.horizontal, size(8, 6))
        .padding(.vertical, size(7, 5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            waiting ? Color.orange.opacity(0.08) : .clear,
            in: RoundedRectangle(cornerRadius: size(12, 10), style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size(12, 10), style: .continuous)
                .stroke(waiting ? Color.orange.opacity(0.35) : .clear, lineWidth: 0.75)
        )
        .contentShape(Rectangle())
    }
}

/// What replaced the buttons once a permission card was answered: the
/// outcome, and where the answer went.
struct AgentDecisionReceipt: View {
    let outcome: AgentHookBridge.Outcome
    let provider: String
    var size: CGFloat = 12

    static func tint(_ outcome: AgentHookBridge.Outcome?) -> Color {
        switch outcome {
        case .allowed: Color(red: 0.24, green: 0.81, blue: 0.43)
        case .denied: .orange
        case .answeredElsewhere, nil: .white.opacity(0.5)
        }
    }

    static func label(_ outcome: AgentHookBridge.Outcome) -> String {
        switch outcome {
        case .allowed: "Allowed"
        case .denied: "Denied"
        case .answeredElsewhere: "Answered elsewhere"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: outcome == .answeredElsewhere ? "arrow.uturn.forward" : "checkmark")
                .font(.system(size: size - 2, weight: .bold))
            Text(outcome == .answeredElsewhere
                ? "\(provider) took its answer from somewhere else"
                : "\(Self.label(outcome)) from Nano, sent to \(provider)")
                .lineLimit(1)
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(Self.tint(outcome))
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}

/// How long the current turn has run, ticking while it works; how long the
/// last one took once it is done.
struct AgentTurnRuntimeLabel: View {
    let session: AgentSession
    var size: CGFloat = 11.5

    var body: some View {
        if session.phase == .working || session.phase == .needsYou {
            // Seconds matter only in the first minute.
            let young = session.turnStartedAt.map { Date().timeIntervalSince($0) < 60 } ?? false
            TimelineView(.periodic(from: .now, by: young ? 1 : 15)) { context in
                label(session.turnRuntime(now: context.date), live: true)
            }
        } else {
            label(session.turnRuntime(), live: false)
        }
    }

    @ViewBuilder
    private func label(_ text: String?, live: Bool) -> some View {
        if let text {
            HStack(spacing: 3) {
                Image(systemName: live ? "timer" : "checkmark")
                    .font(.system(size: size - 2, weight: .semibold))
                Text(text)
                    .monospacedDigit()
            }
            .font(.system(size: size))
            .foregroundStyle(.white.opacity(live ? 0.55 : 0.35))
            .lineLimit(1)
            .help(live ? "This turn has been running for \(text)" : "The last turn took \(text)")
        }
    }
}

/// A session's "working" mark: dotted orbits turning in 3D. A Canvas port of
/// the `working` state of thinking-orbs at its 20 px size, by Jakub Antalik
/// (MIT, github.com/Jakubantalik/Libraries). Every orb reads one clock, so a
/// list of them moves in step.
struct AgentWorkingOrb: View {
    var diameter: CGFloat = 15
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            Canvas { graphics, size in
                // The preset's own speed. Wrapped so `sin` keeps its precision.
                let t = reduceMotion
                    ? 0.6
                    : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000) * Self.speed
                let scale = size.width / Self.designSize
                for dot in Self.frame(at: t) {
                    let r = dot.r * scale
                    let rect = CGRect(x: dot.x * scale - r, y: dot.y * scale - r, width: r * 2, height: r * 2)
                    graphics.fill(Path(ellipseIn: rect), with: .color(Color(white: 1 - dot.white).opacity(dot.alpha)))
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Working")
    }

    struct Dot {
        var x, y, z, r, white, alpha: Double
    }

    private static let designSize = 20.0
    private static let speed = 3.9
    // The 20 px preset: counts scaled by 0.238, radii by 2.4.
    private static let orbitCount = 3
    private static let ghostCount = 10
    private static let particles = 3
    private static let ghostRadius = 0.9 * 2.4
    private static let ghostAlpha = 0.5
    private static let particleRadius = 1.2 * 2.4
    private static let particleDepthRadius = 1.6 * 2.4
    private static let minimumRadius = 0.3

    static func frame(at t: Double) -> [Dot] {
        let size = designSize
        let center = size / 2
        let radius = size / 2 * 0.82
        let radiusScale = pow(size / 300, 0.6)
        let yaw = t * 0.12, tilt = 0.3
        let sinTilt = sin(tilt), cosTilt = cos(tilt), sinYaw = sin(yaw), cosYaw = cos(yaw)
        func project(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let x1 = x * cosYaw + z * sinYaw
            let z1 = -x * sinYaw + z * cosYaw
            let y1 = y * cosTilt - z1 * sinTilt
            let z2 = y * sinTilt + z1 * cosTilt
            return (center + x1, center - y1, z2)
        }

        var dots: [Dot] = []
        for orbit in 0 ..< orbitCount {
            let h1 = hash(Double(orbit), 1.7), h2 = hash(Double(orbit), 5.2), h3 = hash(Double(orbit), 8.9)
            let ro = radius * (0.45 + 0.52 * h1)
            let theta = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            let nx = sin(phi) * cos(theta), ny = cos(phi), nz = sin(phi) * sin(theta)
            var ux = -ny, uy = nx
            let uz = 0.0
            let length = max(1e-6, (ux * ux + uy * uy).squareRoot())
            ux /= length
            uy /= length
            let vx = ny * uz - nz * uy, vy = nz * ux - nx * uz, vz = nx * uy - ny * ux
            let orbitSpeed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

            func point(_ a: Double) -> (Double, Double, Double) {
                project(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro
                )
            }
            for k in 0 ..< ghostCount {
                let (x, y, z) = point(Double(k) / Double(ghostCount) * 2 * .pi)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: x, y: y, z: z, r: ghostRadius * radiusScale, white: 0.72,
                                alpha: ghostAlpha * (0.4 + 0.6 * depth)))
            }
            for m in 0 ..< particles {
                let (x, y, z) = point(t * orbitSpeed + Double(m) / Double(particles) * 2 * .pi + h2 * 6)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: x, y: y, z: z, r: (particleRadius + particleDepthRadius * depth) * radiusScale,
                                white: 0.3 - 0.22 * depth, alpha: 1))
            }
        }
        return dots
            .filter { $0.alpha >= 0.02 }
            .map { var dot = $0; dot.r = max(minimumRadius, dot.r); return dot }
            .sorted { $0.z < $1.z }
    }

    private static func hash(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - floor(h)
    }
}

/// The status word with its mark: amber dot for Needs you, the working orb
/// for Working, grey dots for Done and Idle. Neutral text, so it never reads as a link.
struct AgentSessionStatusLabel: View {
    let session: AgentSession
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 5) {
            if session.phase == .working {
                // Full width so it clears the word; no taller than the text.
                AgentWorkingOrb(diameter: size + 3)
                    .frame(width: size + 3, height: 6)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            }
            Text(session.statusWord())
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private var dotColor: Color {
        switch session.phase {
        case .needsYou: .orange
        case .working: Color(red: 0.24, green: 0.81, blue: 0.43)
        case .done: .white.opacity(0.5)
        case .idle: .white.opacity(0.22)
        }
    }

    private var textColor: Color {
        switch session.phase {
        case .needsYou: Color.orange.opacity(0.95)
        case .working: .white.opacity(0.9)
        case .done: .white.opacity(0.6)
        case .idle: .white.opacity(0.4)
        }
    }
}

struct AgentSessionTitleLabel: View {
    let title: String
    var size: CGFloat = 15

    var body: some View {
        Text(title)
            .font(.system(size: size, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
    }
}

/// Hairline between header groups.
///
/// A drawn rule rather than a "|" glyph: a character inherits font metrics and
/// baseline, so it sits slightly high and scales with whatever text follows it.
struct NanoHeaderDivider: View {
    var height: CGFloat = 15

    var body: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(.white.opacity(0.13))
            .frame(width: 1, height: height)
    }
}

/// Backing shape for a click-to-cycle control: invisible at rest so the value
/// reads as plain text, with the capsule appearing on hover to say it is
/// pressable. Keeps the hit target the same either way.
private struct NanoHoverCapsule: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .background(.white.opacity(isHovered ? 0.09 : 0), in: Capsule())
            .contentShape(Capsule())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
    }
}

extension View {
    func nanoHoverCapsule() -> some View {
        modifier(NanoHoverCapsule())
    }
}

extension AgentActivityEntry.Kind {
    /// One hue per kind, so a long feed can be scanned for "what did it change"
    /// without reading every line.
    var tint: Color {
        switch self {
        case .read: Color(red: 0.44, green: 0.66, blue: 0.98)
        case .edit: Color(red: 0.42, green: 0.82, blue: 0.55)
        case .search: Color(red: 0.72, green: 0.58, blue: 0.98)
        case .command: Color(red: 0.96, green: 0.72, blue: 0.36)
        case .web: Color(red: 0.36, green: 0.80, blue: 0.85)
        case .message: Color(red: 0.70, green: 0.72, blue: 0.78)
        case .subagent: Color(red: 0.96, green: 0.52, blue: 0.72)
        }
    }
}

extension AgentProviderID {
    var accentColor: Color {
        let accent = accentComponents
        return Color(red: accent.red, green: accent.green, blue: accent.blue)
    }
}


/// Opens the host that owns the session. Icon only — a labelled pill sat
/// taller than the 12pt model name and read as a second control, not metadata.
struct AgentJumpButton: View {
    let session: AgentSession
    @State private var pressed = false

    var body: some View {
        if AgentSessionJump.canJump(session) {
            Button {
                pressed = true
                AgentSessionJump.open(session)
                Task {
                    try? await Task.sleep(for: .milliseconds(140))
                    pressed = false
                }
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(pressed ? 0.92 : 0.42))
                    .frame(width: 14, height: 14)
                    // A 28 pt target without moving anything.
                    .padding(7).contentShape(Rectangle()).padding(-7)
            }
            .buttonStyle(.nanoPress)
            .animation(.snappy(duration: 0.16), value: pressed)
            .help("Open this session in \(AgentSessionJump.hostTitle(for: session))")
            .accessibilityLabel("Open in \(AgentSessionJump.hostTitle(for: session))")
        }
    }
}

struct AgentDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 14, height: 14)
                .padding(7).contentShape(Rectangle()).padding(-7)
        }
        .buttonStyle(.nanoPress)
        .help("Hide until this session is active again")
        .accessibilityLabel("Hide session")
    }
}

struct AgentBrandMark: View {
    let provider: AgentProviderID
    var size: CGFloat = 14

    var body: some View {
        if let image = provider.brandImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                // Scaled inside a fixed box so rows stay aligned.
                .frame(width: size * provider.brandScale, height: size * provider.brandScale)
                .frame(width: size, height: size)
        } else {
            Image(systemName: provider.symbol)
                .font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(.orange.opacity(0.85))
                .frame(width: size, height: size)
        }
    }
}


/// Quota for one provider on a single line, in the module's usage row rather
/// than a row of its own. Tapping advances to the next connected provider.
struct AgentUsagePill: View {
    @ObservedObject var service: AgentStatusService
    @ObservedObject var settings: NanoSettings
    @AppStorage("agentUsage.selectedProvider") private var selectedProviderRawValue = ""

    var body: some View {
        let available = AgentUsagePill.displayable(service.snapshots, settings: settings)

        if available.isEmpty {
            // The first fetch takes a second or two. Saying so beats a gap that
            // reads as "no agents" until the numbers appear.
            if service.isRefreshing {
                HStack(spacing: 7) {
                    NanoThinkingOrb(scale: .inline)
                        .frame(width: 16, height: 16)
                    Text("Verifying\u{2026}")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(height: 30)
                .transition(.opacity)
            } else {
                EmptyView()
            }
        } else {
            let availableProviderIDs = available.map(\.id)
            let selectedProviderID = Self.selectedProviderID(
                storedRawValue: selectedProviderRawValue,
                availableProviderIDs: availableProviderIDs
            )
            let snapshot = available.first { $0.id == selectedProviderID } ?? available[0]
            let plan = AgentModuleView.planLabel(snapshot.planName, provider: snapshot.id)

            HStack(spacing: 7) {
                Button {
                    if let next = Self.nextProviderID(
                        storedRawValue: selectedProviderRawValue,
                        availableProviderIDs: availableProviderIDs
                    ) {
                        selectedProviderRawValue = next.rawValue
                    }
                } label: {
                    HStack(spacing: 6) {
                        AgentBrandMark(provider: snapshot.id, size: 20)

                        // What the quota beside it is a quota of. Only the
                        // providers whose usage API reports a plan have one.
                        if let plan {
                            Text(plan)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                                .fixedSize()
                        }

                        if snapshot.usage.isEmpty {
                            Text(snapshot.usageMessage ?? "Usage unavailable")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }

                        ForEach(Array(Self.ordered(snapshot.usage).prefix(3).enumerated()), id: \.element.id) { position, usage in
                            if position > 0 || plan != nil {
                                Text("·")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                            HStack(spacing: 3) {
                                Text("\(Int(settings.usageDisplayMode.percent(for: usage).rounded()))%")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(.snappy(duration: 0.3), value: Int(settings.usageDisplayMode.percent(for: usage).rounded()))
                                    .foregroundStyle(Self.usageTint(usage.usedPercent))
                                Text(Self.short(Self.canonicalLabel(usage)))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                settings.usageDisplayMode.accessibilityDescription(for: usage)
                            )
                        }

                        // Cursor's two pools share one monthly reset. Codex and
                        // Claude already encode theirs in the window label.
                        if let reset = Self.sharedReset(snapshot.usage) {
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.25))
                            Text(reset)
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.45))
                                .accessibilityLabel("Resets in \(reset)")
                        } else if let (window, reset) = Self.pressingReset(snapshot.usage) {
                            // Once a window is past half, when it frees up is
                            // the number that matters.
                            Text("·")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.25))
                            Text("resets \(reset)")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.45))
                                .accessibilityLabel("\(Self.canonicalLabel(window)) resets in \(reset)")
                        }

                        if available.count > 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.32))
                        }
                    }
                    .frame(height: 30)
                    .nanoHoverCapsule()
                }
                .buttonStyle(.nanoPress)
                .help(Self.pillHelp(
                    snapshot.id,
                    plan: plan,
                    cycles: available.count > 1,
                    usage: snapshot.usage,
                    message: snapshot.usageMessage
                ))

                Button {
                    service.refresh()
                } label: {
                    if service.isRefreshing {
                        NanoLoadingRing(size: 11, label: "Refreshing agents")
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(service.isRefreshing)
            }
        }
    }

    /// Keep every provider whose Usage switch is on. A provider without a
    /// quota window still needs to explain whether it is waiting or unavailable.
    static func displayable(
        _ snapshots: [AgentProviderSnapshot],
        settings: NanoSettings
    ) -> [AgentProviderSnapshot] {
        snapshots.filter { settings.isUsageEnabled($0.id) }
    }

    static func selectedProviderID(
        storedRawValue: String,
        availableProviderIDs: [AgentProviderID]
    ) -> AgentProviderID? {
        guard let first = availableProviderIDs.first else { return nil }
        guard let stored = AgentProviderID(rawValue: storedRawValue),
              availableProviderIDs.contains(stored)
        else { return first }
        return stored
    }

    static func nextProviderID(
        storedRawValue: String,
        availableProviderIDs: [AgentProviderID]
    ) -> AgentProviderID? {
        guard let selected = selectedProviderID(
            storedRawValue: storedRawValue,
            availableProviderIDs: availableProviderIDs
        ),
        let index = availableProviderIDs.firstIndex(of: selected)
        else { return nil }
        return availableProviderIDs[(index + 1) % availableProviderIDs.count]
    }

    /// The plan named in full on hover, where there is room for the word
    /// "plan" that the pill itself cannot spare.
    private static func pillHelp(
        _ provider: AgentProviderID,
        plan: String?,
        cycles: Bool,
        usage: [NanoUsageWindow],
        message: String?
    ) -> String {
        var text = plan.map { "\(provider.title) \($0) plan" } ?? provider.title
        // With numbers on screen the message is their age ("3h ago") during
        // a cool-off; leaving it out made old numbers look live.
        if let message, !message.isEmpty, message != "now" { text += ". \(message)" }
        let resets = ordered(usage).compactMap { window in
            window.resetCountdown.map { "\(canonicalLabel(window)) in \($0)" }
        }
        if !resets.isEmpty { text += ". Resets: " + resets.joined(separator: ", ") }
        if usage.contains(where: { $0.id == "cursor.models" || $0.id == "cursor.other" }) {
            text += ". Cursor Models are Composer and Grok. Other Models are Claude, Codex, and the rest. Both reset monthly"
        }
        if cycles { text += " \u{00B7} click for the next agent" }
        return text
    }

    /// The window closest to its limit, with its reset countdown, once it is
    /// at least half used.
    static func pressingReset(_ windows: [NanoUsageWindow]) -> (NanoUsageWindow, String)? {
        guard let window = ordered(windows).prefix(3).max(by: { $0.usedPercent < $1.usedPercent }),
              window.usedPercent >= 50,
              let reset = window.resetCountdown else { return nil }
        return (window, reset)
    }

    /// Countdown shown once when every window is a named pool that shares a
    /// reset, so Cursor's monthly cycle is not drawn as a third usage percent.
    static func sharedReset(_ windows: [NanoUsageWindow]) -> String? {
        let named = windows.filter { featureName(in: $0.label) != nil }
        guard !named.isEmpty, named.count == windows.count else { return nil }
        let countdowns = named.compactMap(\.resetCountdown)
        guard let first = countdowns.first, countdowns.allSatisfy({ $0 == first }) else {
            return nil
        }
        return first
    }

    /// One vocabulary for window lengths.
    ///
    /// Providers name the same thing differently: Codex derives "5h" and "7d"
    /// from a seconds field, Kimi says "Weekly". Reading "97% Weekly · 0% 5h"
    /// forces the eye to translate mid-row, so every label is re-derived from
    /// its duration. A provider's own feature name is kept when it has one.
    static func canonicalLabel(_ window: NanoUsageWindow) -> String {
        let seconds = span(of: window)
        guard seconds != .max else { return window.label }

        let duration = NanoUsageFormat.windowLabel(seconds: seconds)
        guard let feature = featureName(in: window.label) else { return duration }
        return "\(feature) \(duration)"
    }

    /// The part of a label that is not the duration - "Spark" in "Spark · 7d".
    /// Returns nil when the label is nothing but a period, however spelled.
    private static func featureName(in label: String) -> String? {
        let head = label
            .split(separator: "\u{00B7}")
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? label

        var candidate = head
        // Trim a trailing duration token so "Spark 7d" yields "Spark".
        if let last = head.split(separator: " ").last,
           last.count <= 4,
           last.first?.isNumber == true {
            candidate = head
                .dropLast(last.count)
                .trimmingCharacters(in: .whitespaces)
        }

        let bare = candidate.lowercased()
        let periodWords = ["weekly", "monthly", "daily", "hourly", "week", "month", "day", "hour"]
        if bare.isEmpty || periodWords.contains(bare) { return nil }
        if bare.allSatisfy({ $0.isNumber || "hdms".contains($0) }) { return nil }
        return candidate
    }

    /// Shortest window first, so the 5h limit - the one that actually stops you
    /// working - is read before the weekly one. Providers return these in
    /// whatever order their API happens to use.
    static func ordered(_ windows: [NanoUsageWindow]) -> [NanoUsageWindow] {
        windows.sorted { left, right in
            let a = span(of: left)
            let b = span(of: right)
            if a != b { return a < b }
            return left.id < right.id
        }
    }

    /// Window length in seconds, recovered from the label when the provider
    /// did not hand one over ("5h", "7d", "Weekly").
    private static func span(of window: NanoUsageWindow) -> Int {
        let text = window.label.lowercased()
        if text.contains("week") { return 7 * 86_400 }
        if text.contains("month") { return 30 * 86_400 }
        if text.contains("day") { return 86_400 }

        // Trailing "5h" / "7d" survives a prefixed feature name.
        var digits = ""
        for character in text {
            if character.isNumber { digits.append(character); continue }
            if character == "h", let value = Int(digits) { return value * 3_600 }
            if character == "d", let value = Int(digits) { return value * 86_400 }
            if character == "m", let value = Int(digits) { return value * 60 }
            digits = ""
        }
        // Unlabelled windows sort last rather than jumping the queue.
        return .max
    }

    /// Consumption, warming as the window fills. Grey while there is room, so
    /// the pill only draws attention when a limit is actually close.
    static func usageTint(_ used: Double) -> Color {
        switch used {
        case ..<50: .white
        case ..<75: .yellow.opacity(0.9)
        case ..<90: .orange
        default: .red.opacity(0.9)
        }
    }

    /// Per-feature limits carry long names that would push the pill wide.
    private static func short(_ label: String) -> String {
        switch label {
        case "Cursor Models": return "Cursor"
        case "Other Models": return "Other"
        default: break
        }
        guard label.count > 12 else { return label }
        let parts = label.split(separator: "·")
        guard let last = parts.last?.trimmingCharacters(in: .whitespaces),
              let first = parts.first?.trimmingCharacters(in: .whitespaces)
        else { return String(label.prefix(12)) }
        let name = first.split(separator: "-").last.map(String.init) ?? first
        return parts.count > 1 ? "\(name.prefix(8)) \(last)" : String(name.prefix(12))
    }
}

/// Token spend for a window, sized for the module's usage row.
///
/// Headlines processed volume (input + cache reads + output), the same
/// figure T3 Code shows, plus the dollar amount at list API rates — not
/// subscription spend. Hover splits that total by provider.
struct AgentTokenSummary: View {
    @ObservedObject var ledger: TokenLedger
    @Binding var window: NanoTokenWindow
    let onBreakdownHeightChange: (CGFloat) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var overFigures = false

    var body: some View {
        let totals = ledger.totals(for: window)
        let counts = totals.counts

        HStack(spacing: 6) {
            figures(totals: totals, counts: counts)
                .fixedSize()
                .onHover { overFigures = $0 }

            // A first scan of a large archive runs for minutes, and an
            // indeterminate ring held that long reads as a hang. While there is
            // history left to read it says how much; once caught up, scans are
            // short enough that the ring barely appears.
            if let catchUp = ledger.catchUp {
                Label(
                    "\(Int(catchUp.fraction * 100))%",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.42))
            } else if ledger.isScanning {
                NanoLoadingRing(size: 11, label: "Counting tokens")
            }

            // The range governs every figure to its left, so it reads as a
            // control rather than another value.
            NanoHeaderDivider(height: 13)
                .padding(.horizontal, 2)

            AgentTokenWindowPicker(window: $window)
        }
        .overlay(alignment: .topLeading) {
            if overFigures {
                splitCard(totals: totals, counts: counts)
                    .offset(y: 24)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: NanoTokenBreakdownHeightKey.self,
                                value: proxy.size.height.rounded(.up) + 4
                            )
                        }
                    )
                    .allowsHitTesting(false)
                    .transition(.asymmetric(
                        insertion: .offset(y: -12).combined(with: .opacity),
                        removal: .offset(y: -8).combined(with: .opacity)
                    ))
                    .zIndex(30)
            }
        }
        .onPreferenceChange(NanoTokenBreakdownHeightKey.self) {
            onBreakdownHeightChange(overFigures ? $0 : 0)
        }
        .onChange(of: overFigures) { _, isOpen in
            if !isOpen { onBreakdownHeightChange(0) }
        }
        .onDisappear { onBreakdownHeightChange(0) }
        .animation(
            NanoMotion.islandSpring(
                dropping: overFigures,
                reduceMotion: reduceMotion
            ),
            value: overFigures
        )
    }

    private func figures(totals: NanoTokenTotals, counts: NanoTokenCounts) -> some View {
        HStack(spacing: 6) {
            Text(AgentModuleView.compact(counts.total))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.white)

            if counts.total == 0 {
                Text("empty")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.38))
            }

            HStack(spacing: 4) {
                Text(AgentModuleView.money(totals.costNanos))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.orange.opacity(0.95))

                Text("API")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange.opacity(0.95))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        .orange.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            }
            .help("Estimated token cost at standard API list prices, not your subscription bill. Excludes per-request long-context and service-tier adjustments, tool fees, and cache storage.")

            if !totals.unpricedModels.isEmpty {
                Text("Partial")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .help("API cost estimate excludes models without a published price: " + totals.unpricedModels.sorted().joined(separator: ", "))
                    .padding(.leading, 1)
            }
        }
        .contentShape(Rectangle())
    }

    private func splitCard(totals: NanoTokenTotals, counts: NanoTokenCounts) -> some View {
        let providers = ledger.breakdown(for: window)
        return VStack(alignment: .leading, spacing: 4) {
            if counts.total == 0 {
                Text("No tokens banked for this range.")
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                ForEach(providers, id: \.provider) { row in
                    HStack(spacing: 8) {
                        Text(AgentProviderID(rawValue: row.provider)?.title ?? row.provider.capitalized)
                        Spacer(minLength: 12)
                        Text(AgentModuleView.compact(row.counts.total))
                            .monospacedDigit()
                        Text(AgentModuleView.money(row.costNanos))
                            .monospacedDigit()
                            .foregroundStyle(.orange.opacity(0.95))
                    }
                }
                if providers.count > 1 {
                    HStack(spacing: 8) {
                        Text("All")
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer(minLength: 12)
                        Text(AgentModuleView.compact(counts.total))
                            .monospacedDigit()
                        Text(AgentModuleView.money(totals.costNanos))
                            .monospacedDigit()
                            .foregroundStyle(.orange.opacity(0.95))
                    }
                }
                Text("List API rates — plans already cover this.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.top, 2)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 220, alignment: .leading)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .fixedSize()
        .allowsHitTesting(false)
    }

    /// Per-provider processed volume and list-API cost. The left quota pill is
    /// one provider; this is what makes the summed headline readable.
    static func breakdown(
        counts: NanoTokenCounts,
        costNanos: Int,
        providers: [(provider: String, counts: NanoTokenCounts, costNanos: Int)]
    ) -> String {
        var lines = providers.map { row in
            let name = AgentProviderID(rawValue: row.provider)?.title
                ?? row.provider.capitalized
            return "\(name) \(AgentModuleView.compact(row.counts.total)) · \(AgentModuleView.money(row.costNanos))"
        }
        if providers.count > 1 {
            lines.append(
                "All \(AgentModuleView.compact(counts.total)) · \(AgentModuleView.money(costNanos))"
            )
        }
        return lines.joined(separator: "\n")
            + "\nPriced at list API rates \u{2014} your plans already cover this."
    }
}

struct NanoTokenBreakdownHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Cycles rather than dropping down, matching the quota pill beside it and
/// keeping the selected range when the user opens the full usage page.
struct AgentTokenWindowPicker: View {
    @Binding var window: NanoTokenWindow

    var body: some View {
        Button {
            let all = NanoTokenWindow.allCases
            let next = (all.firstIndex(of: window).map { $0 + 1 } ?? 0) % all.count
            withAnimation(.snappy(duration: 0.18)) { window = all[next] }
        } label: {
            HStack(spacing: 4) {
                Text(window.title)
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.numericText())
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(height: 22)
            .nanoHoverCapsule()
        }
        .buttonStyle(.nanoPress)
        .help("Next range")
    }
}

/// A second page inside the expanded agent island. It explains the compact
/// token headline in the place where the user encountered it, without turning
/// Settings into an analytics destination.
struct AgentUsageDetailView: View {
    @ObservedObject var ledger: TokenLedger
    let sessions: AgentSessionStore
    @Binding var window: NanoTokenWindow
    @State private var expandedProviders: Set<String> = []
    @State private var collapsedDefault = false

    /// One model line within a CLI, with its effort variants folded in:
    /// `cursor-grok-4.6-high`, `-high-fast`, and `-xhigh` are one Grok 4.6.
    private struct MergedModel: Identifiable {
        let name: String
        var counts: NanoTokenCounts
        var costNanos: Int
        var priced: Bool
        var variants: Int
        var id: String { name }
    }

    var body: some View {
        let totals = ledger.totals(for: window)
        let groups = NanoTokenProviderGroup.grouping(ledger.modelBreakdown(for: window))
        let totalCost = max(groups.reduce(0) { $0 + $1.costNanos }, 1)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headline(totals)
                    .nanoRevealRow(0)
                if window != .today {
                    dailyBars
                        .nanoRevealRow(1)
                }
                if groups.contains(where: { $0.costNanos > 0 }) {
                    partitionBar(groups, total: totalCost)
                        .nanoRevealRow(2)
                }
                if groups.isEmpty {
                    Text("No token history for this range")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.42))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            providerSection(group, total: totalCost, isFirst: index == 0)
                            if index < groups.count - 1 {
                                Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5)
                            }
                        }
                    }
                    .nanoRevealRow(3)
                }
                Text("API-equivalent estimate, not your subscription bill.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.36))
                    .nanoRevealRow(4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: NanoDetailHeightKey.self, value: proxy.size.height.rounded())
                }
            )
        }
        .scrollIndicators(.never)
        .onPreferenceChange(NanoDetailHeightKey.self) { height in
            sessions.usageContentHeight = height
        }
    }

    // MARK: Header

    private func headline(_ totals: NanoTokenTotals) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(AgentModuleView.money(totals.costNanos))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: totals.costUSD))
                .animation(.snappy(duration: 0.35), value: totals.costNanos)
            Text("\(AgentModuleView.compact(totals.counts.total)) tokens")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 0)
            if !totals.unpricedModels.isEmpty {
                let names = totals.unpricedModels.map { AgentModuleView.modelName($0) }.sorted()
                Text("\(totals.unpricedModels.count) unpriced")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.yellow.opacity(0.75))
                    .help(
                        "No published rate for \(names.joined(separator: ", ")). "
                            + "Their tokens are counted, but not their cost, rather than guessing."
                    )
            }
        }
    }

    /// Daily spend for the last two weeks (after 21st's "Revenue Bars"):
    /// today in white, earlier days quiet. Labelled with its own span and end
    /// dates because it does not follow the range picker.
    private var dailyBars: some View {
        let days = ledger.dailyCost(days: 14)
        let peakCost = days.map(\.costNanos).max() ?? 0
        let peak = max(peakCost, 1)
        let peakIndex = days.firstIndex { $0.costNanos == peakCost && peakCost > 0 }
        return VStack(alignment: .leading, spacing: 5) {
            Text("Last 14 days")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(days.enumerated()), id: \.element.day) { index, day in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(index == days.count - 1 ? Color.white : .white.opacity(0.22))
                        .frame(height: max(3, 44 * CGFloat(day.costNanos) / CGFloat(peak)))
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) {
                            // The busiest day carries its amount, so the scale
                            // has a number without an axis.
                            if index == peakIndex {
                                Text(AgentModuleView.money(day.costNanos))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.7))
                                    .fixedSize()
                                    .offset(y: -14)
                            }
                        }
                        .help("\(Self.dayLabel(day.day)): \(AgentModuleView.money(day.costNanos))")
                }
            }
            .frame(height: 44, alignment: .bottom)
            .padding(.top, 14)
            HStack {
                Text(days.first.map { Self.dayLabel($0.day) } ?? "")
                Spacer()
                Text("Today")
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.38))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily cost for the last 14 days")
    }

    /// "Sep 11" from a ledger day key.
    private static func dayLabel(_ day: String) -> String {
        guard let date = TokenLedger.date(fromDay: day) else { return day }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Where the money goes, one segment per CLI (after 21st's "Partition
    /// Bar"). Tiny shares keep a sliver so every CLI stays visible.
    private func partitionBar(_ groups: [NanoTokenProviderGroup], total: Int) -> some View {
        let priced = groups.filter { $0.costNanos > 0 }
        return GeometryReader { proxy in
            let gaps = CGFloat(max(priced.count - 1, 0)) * 2
            let width = max(proxy.size.width - gaps, 0)
            let floor: CGFloat = 4
            let small = priced.filter { CGFloat($0.costNanos) / CGFloat(total) * width < floor }
            let bigTotal = max(priced.filter { CGFloat($0.costNanos) / CGFloat(total) * width >= floor }
                .reduce(0) { $0 + $1.costNanos }, 1)
            let usable = width - CGFloat(small.count) * floor
            HStack(spacing: 2) {
                ForEach(priced) { group in
                    let share = CGFloat(group.costNanos) / CGFloat(total) * width
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(providerColor(group.provider))
                        .frame(width: share < floor ? floor : CGFloat(group.costNanos) / CGFloat(bigTotal) * usable)
                }
            }
        }
        .frame(height: 8)
    }

    // MARK: Groups

    private func providerSection(_ group: NanoTokenProviderGroup, total: Int, isFirst: Bool) -> some View {
        let providerID = AgentProviderID(rawValue: group.provider)
        let models = merged(group.models)
        let expandable = models.count > 1
        // The largest CLI starts open; the rest wait for a click.
        let expanded = expandable && (expandedProviders.contains(group.provider)
            || (isFirst && !collapsedDefault))

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                guard expandable else { return }
                withAnimation(.snappy(duration: 0.2)) {
                    if isFirst, !collapsedDefault, !expandedProviders.contains(group.provider) {
                        collapsedDefault = true
                    } else if expandedProviders.contains(group.provider) {
                        expandedProviders.remove(group.provider)
                    } else {
                        expandedProviders.insert(group.provider)
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    Group {
                        if let providerID {
                            AgentBrandMark(provider: providerID, size: 16)
                        } else {
                            Circle().fill(providerColor(group.provider)).frame(width: 8, height: 8)
                        }
                    }
                    .frame(width: 18)
                    Text(providerID?.title ?? group.provider.capitalized)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(models.count) \(models.count == 1 ? "model" : "models")")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                    if expandable {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.35))
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                    Spacer(minLength: 6)
                    Text(AgentModuleView.compact(group.counts.total))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                    Text(share(group.costNanos, of: total))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 36, alignment: .trailing)
                    cost(group.costNanos, priced: !group.allUnpriced, partial: group.hasUnpriced)
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(width: 78, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.nanoPress)

            if expanded {
                VStack(spacing: 5) {
                    ForEach(models) { model in
                        HStack(spacing: 8) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(providerColor(group.provider).opacity(0.55))
                                    .frame(
                                        width: max(3, proxy.size.width * CGFloat(model.costNanos) / CGFloat(max(group.costNanos, 1))),
                                        height: 3
                                    )
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(width: 44, height: 12)
                            Text(model.name)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.78))
                                .lineLimit(1)
                            if model.variants > 1 {
                                Text("\(model.variants) effort levels")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            Spacer(minLength: 6)
                            Text(AgentModuleView.compact(model.counts.total))
                                .font(.system(size: 10.5))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.35))
                            cost(model.costNanos, priced: model.priced, partial: false)
                                .font(.system(size: 11.5))
                                .opacity(0.85)
                                .frame(width: 78, alignment: .trailing)
                        }
                    }
                }
                .padding(.leading, 27)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 7)
    }

    private func merged(_ models: [NanoTokenModelTotal]) -> [MergedModel] {
        var order: [String] = []
        var byName: [String: MergedModel] = [:]
        for model in models {
            let name = AgentModuleView.modelName(model.model)
            if var existing = byName[name] {
                existing.counts += model.counts
                existing.costNanos += model.costNanos
                existing.priced = existing.priced && model.priced
                existing.variants += 1
                byName[name] = existing
            } else {
                order.append(name)
                byName[name] = MergedModel(
                    name: name, counts: model.counts, costNanos: model.costNanos,
                    priced: model.priced, variants: 1
                )
            }
        }
        return order.compactMap { byName[$0] }.sorted {
            $0.costNanos != $1.costNanos ? $0.costNanos > $1.costNanos : $0.counts.total > $1.counts.total
        }
    }

    /// `$0` from a real rate is "Included" (a plan's free model), not
    /// unpriced; a missing rate stays "Unpriced" so it never reads as free.
    @ViewBuilder
    private func cost(_ nanos: Int, priced: Bool, partial: Bool) -> some View {
        if !priced {
            Text("Unpriced").foregroundStyle(.yellow.opacity(0.78))
        } else if nanos == 0 {
            Text("Included").foregroundStyle(Color(red: 0.52, green: 0.82, blue: 0.62))
        } else {
            HStack(spacing: 2) {
                Text(AgentModuleView.money(nanos))
                if partial {
                    Text("+").foregroundStyle(.yellow.opacity(0.78))
                }
            }
            .foregroundStyle(.white)
            .monospacedDigit()
            .help(partial ? "Includes unpriced models" : "")
        }
    }

    private func share(_ nanos: Int, of total: Int) -> String {
        guard nanos > 0 else { return "" }
        let value = Double(nanos) / Double(total) * 100
        return value < 1 ? "<1%" : String(format: "%.0f%%", value)
    }

    private func providerColor(_ raw: String) -> Color {
        AgentProviderID(rawValue: raw)?.accentColor ?? .white.opacity(0.45)
    }
}

/// Label with a smaller, dimmer icon, for the detail header's meta line.
private struct NanoCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
                .font(.system(size: 9))
                .opacity(0.8)
            configuration.title
        }
    }
}

/// The live step, with a light sweep while the agent is working. Static when
/// the step is finished or Reduce Motion is on.
struct NanoShimmerText: View {
    let text: String
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nanoMotionBudget) private var budget

    private static let period: TimeInterval = 1.8

    var body: some View {
        Text(text)
            .foregroundStyle(.white.opacity(active ? 0.62 : 0.82))
            .overlay {
                if active, !reduceMotion {
                    // Budgeted like every other timeline: 20fps while looked
                    // at, slower in the collapsed strip, paused when hidden.
                    TimelineView(.animation(
                        minimumInterval: budget.interval(1.0 / 30, cost: .light),
                        paused: budget.isPaused
                    )) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = CGFloat(t.truncatingRemainder(dividingBy: Self.period) / Self.period) * 1.6 - 0.5
                        Text(text)
                            .foregroundStyle(.white)
                            .mask {
                                GeometryReader { proxy in
                                    LinearGradient(
                                        colors: [.clear, .white, .clear],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                    .frame(width: proxy.size.width * 0.45)
                                    .offset(x: phase * proxy.size.width)
                                }
                            }
                    }
                }
            }
    }
}

/// A new agent reply writes itself in word by word, newest words fading up.
/// Only a change animates: the first appearance, and Reduce Motion, show the
/// whole reply at once. About 40 steps per reply, then it sits still.
struct NanoStreamingText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: String?
    @State private var revealed = Int.max
    @State private var task: Task<Void, Never>?

    var body: some View {
        let words = (shown ?? text).split(separator: " ", omittingEmptySubsequences: false)
        return words.enumerated().reduce(Text("")) { result, pair in
            let (index, word) = pair
            let distance = index - revealed
            let opacity: Double = distance < 0 ? 0.86 : distance < 3 ? 0.55 - Double(distance) * 0.17 : 0
            return result + Text(word + (index < words.count - 1 ? " " : "")).foregroundColor(.white.opacity(opacity))
        }
        .onAppear { shown = text }
        .onChange(of: text) { _, newText in
            task?.cancel()
            shown = newText
            guard !reduceMotion else { revealed = .max; return }
            let count = newText.split(separator: " ").count
            let step = max(1, count / 40)
            revealed = 0
            task = Task { @MainActor in
                while revealed < count + 3 {
                    try? await Task.sleep(for: .milliseconds(28))
                    if Task.isCancelled { return }
                    revealed += step
                }
                revealed = .max
            }
        }
        .onDisappear { task?.cancel() }
    }
}

/// An indeterminate ring spun by Core Animation, so the rotation costs nothing
/// in Nano's process. Stops when hidden or under Reduce Motion.
struct NanoSpinnerRing: NSViewRepresentable {
    let color: NSColor
    var lineWidth: CGFloat = 1.6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nanoMotionBudget) private var budget

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let track = CAShapeLayer()
        let arc = CAShapeLayer()
        for layer in [track, arc] {
            layer.fillColor = nil
            layer.lineWidth = lineWidth
            layer.lineCap = .round
            view.layer?.addSublayer(layer)
        }
        track.name = "track"
        arc.name = "arc"
        arc.strokeEnd = 0.62
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layers = view.layer?.sublayers,
              let track = layers.first(where: { $0.name == "track" }) as? CAShapeLayer,
              let arc = layers.first(where: { $0.name == "arc" }) as? CAShapeLayer
        else { return }
        let bounds = CGRect(x: 0, y: 0, width: 11, height: 11)
        let path = CGPath(ellipseIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: nil)
        for layer in [track, arc] {
            layer.frame = bounds
            layer.path = path
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        arc.strokeColor = color.cgColor

        let spinning = !reduceMotion && !budget.isPaused
        if spinning, arc.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.9
            spin.repeatCount = .infinity
            arc.add(spin, forKey: "spin")
        } else if !spinning {
            arc.removeAnimation(forKey: "spin")
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct NanoFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A model's display name. Devin's Fusion pairs get an atom in place of the
/// word, which with two model names would not fit a session row.
struct AgentModelName: View {
    let raw: String
    /// The atom's side, set to the label's font size by the caller.
    var markSize: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 3) {
            if AgentModuleView.fusionPair(raw) != nil {
                NanoAtomShape()
                    .stroke(style: StrokeStyle(
                        lineWidth: markSize / 12, lineCap: .round, lineJoin: .round
                    ))
                    .frame(width: markSize, height: markSize)
                    .accessibilityLabel("Fusion")
            }
            Text(AgentModuleView.modelName(raw))
        }
    }
}

/// Lucide's `atom`: two crossed orbits around a nucleus, on its 24pt grid.
/// Paths from Lucide Animated (https://github.com/pqoqubbw/icons), MIT.
struct NanoAtomShape: Shape {
    func path(in rect: CGRect) -> Path {
        var orbit = Path()
        orbit.move(to: CGPoint(x: 20.2, y: 20.2))
        orbit.addCurve(to: CGPoint(x: 15.7, y: 8.3),
                       control1: CGPoint(x: 22.24, y: 18.17), control2: CGPoint(x: 20.22, y: 12.84))
        orbit.addCurve(to: CGPoint(x: 3.8, y: 3.8),
                       control1: CGPoint(x: 11.16, y: 3.78), control2: CGPoint(x: 5.83, y: 1.76))
        orbit.addCurve(to: CGPoint(x: 8.3, y: 15.7),
                       control1: CGPoint(x: 1.76, y: 5.83), control2: CGPoint(x: 3.78, y: 11.16))
        orbit.addCurve(to: CGPoint(x: 20.2, y: 20.2),
                       control1: CGPoint(x: 12.84, y: 20.22), control2: CGPoint(x: 18.17, y: 22.24))
        orbit.closeSubpath()

        var atom = orbit
        // The second orbit is the first mirrored left to right.
        atom.addPath(orbit, transform: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -24, y: 0))
        atom.addEllipse(in: CGRect(x: 11, y: 11, width: 2, height: 2))
        return atom.applying(
            CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .scaledBy(x: rect.width / 24, y: rect.height / 24)
        )
    }
}
