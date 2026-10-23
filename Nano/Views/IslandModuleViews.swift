import AppKit
import SwiftUI

struct IslandModuleView: View {
    let module: NanoModuleID
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    @State private var agentTokenWindow: NanoTokenWindow = .today

    var body: some View {
        VStack(spacing: 11) {
            // The tray is a bare shelf that fits what it holds, like the notch it grows from.
            if module != .tray {
                moduleHeader
                    .zIndex(20)
            }

            Group {
                switch module {
                case .calendar:
                    CalendarModuleView(service: viewModel.calendarService, settings: settings)
                case .timer:
                    TimerModuleView(store: viewModel.timerStore, settings: settings)
                case .camera:
                    CameraModuleView(service: viewModel.cameraService)
                case .weather:
                    WeatherModuleView(service: viewModel.weatherService, settings: settings)
                case .agents:
                    AgentModuleView(
                        service: viewModel.agentService,
                        settings: settings,
                        ledger: viewModel.tokenLedger,
                        sessions: viewModel.sessionStore,
                        hooks: viewModel.hookBridge,
                        showingUsage: viewModel.showsAgentUsageDetail,
                        usageWindow: $agentTokenWindow
                    )
                case .mixer:
                    MixerModuleView(store: viewModel.mixerStore, system: viewModel.systemStatusService)
                case .music:
                    MusicModuleView(controller: viewModel.mediaController, settings: settings)
                case .battery:
                    BatteryModuleView(service: viewModel.systemStatusService)
                case .volume:
                    VolumeModuleView(service: viewModel.systemStatusService)
                case .tray:
                    TrayModuleView(
                        store: viewModel.trayStore,
                        settings: settings,
                        isDropping: viewModel.phase == .dragTarget
                    )
                case .cue:
                    CueModuleView(store: viewModel.cueStore, viewModel: viewModel)
                case .voiceDictation:
                    VoiceDictationModuleView(controller: viewModel.voiceDictation)
                case .notificationLabs:
                    NotificationHistoryView(center: viewModel.notificationCenter)
                case .bluetooth, .brightness:
                    AdjustmentUnavailableView(module: module)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(module == .tray ? IslandViewModel.trayPadding : 15)
        .foregroundStyle(.white)
    }

    /// Usage, title, and context only. Home / pin / settings live on the
    /// detached chrome pill under the island.
    private var moduleHeader: some View {
        HStack(alignment: .top, spacing: 9) {
            // The agent module states its own identity through the session
            // list and the provider marks, so the symbol and name are noise.
            if module != .agents {
                Image(systemName: module.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.64))
            }
            if module != .agents {
                Text(module == .cue && viewModel.cueStore.draft != nil ? "New cue" : module.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }

            if module == .agents {
                if viewModel.showsAgentUsageDetail {
                    Label("Usage", systemImage: "chart.xyaxis.line")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))

                    NanoHeaderDivider()
                        .padding(.horizontal, 3)

                    AgentTokenWindowPicker(window: $agentTokenWindow)
                } else {
                    AgentUsagePill(service: viewModel.agentService, settings: settings)

                    // A fixed gap and a rule, not a Spacer: two Spacers left this
                    // group floating in whatever room was left over, so it sat at a
                    // different place depending on the numbers' width.
                    NanoHeaderDivider()
                        .padding(.horizontal, 3)

                    AgentTokenSummary(
                        ledger: viewModel.tokenLedger,
                        window: $agentTokenWindow,
                        onBreakdownHeightChange: viewModel.setAgentTokenBreakdownHeight
                    )
                }
            }

            Spacer(minLength: 0)

            if module == .agents {
                Button {
                    withAnimation(.snappy(duration: 0.24)) {
                        viewModel.setAgentUsageDetail(!viewModel.showsAgentUsageDetail)
                    }
                } label: {
                    Image(systemName: viewModel.showsAgentUsageDetail ? "xmark" : "chart.xyaxis.line")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 32, height: 30)
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(
                            viewModel.showsAgentUsageDetail
                                ? .orange.opacity(0.95)
                                : .white.opacity(0.62)
                        )
                        .nanoHoverCapsule()
                }
                .buttonStyle(.nanoPress)
                .help(viewModel.showsAgentUsageDetail ? "Back to agent activity" : "Open usage breakdown")
                .accessibilityLabel(
                    viewModel.showsAgentUsageDetail ? "Close usage breakdown" : "Open usage breakdown"
                )
            }

            if module != .agents {
                Text(moduleContext)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.36))
            }
        }
        .frame(minHeight: 30)
    }

    private var moduleContext: String {
        switch module {
        case .calendar: "\(settings.calendarLayout.title) · Right-click to change"
        case .agents: "Local status"
        case .tray: "Kept until you clear them"
        case .voiceDictation: "On-device · Copies to clipboard"
        case .cue: viewModel.cueStore.draft == nil ? "\(viewModel.cueStore.totalOpenCount) open · Local" : "Saved on this Mac"
        case .timer: viewModel.timerStore.state == .idle ? "Set up a session" : viewModel.timerStore.mode.title
        case .mixer: mixerContext
        default: "Quick Access"
        }
    }

    private var mixerContext: String {
        let adjusting = viewModel.mixerStore.apps.count { $0.isRunning && $0.preference.needsProcessing }
        return adjusting == 0 ? "All apps at 100%" : "Adjusting \(adjusting) app\(adjusting == 1 ? "" : "s")"
    }
}

private struct TimerModuleView: View {
    @ObservedObject var store: FocusTimerStore
    @ObservedObject var settings: NanoSettings

    @State private var isEditingDuration = false
    @State private var durationDraft = ""
    @FocusState private var durationFieldFocused: Bool

    private var selectedMinutes: Binding<Int> {
        Binding(
            get: { max(Int(store.configuredDuration) / 60, 1) },
            set: { store.setDuration(seconds: Double($0) * 60) }
        )
    }

    var body: some View {
        Group {
            switch store.state {
            case .idle:
                setupLayout
            case .running, .paused:
                liveLayout
            case .completed:
                completionLayout
            }
        }
        .animation(.snappy(duration: 0.26), value: store.state)
    }

    // MARK: - Idle

    private var setupLayout: some View {
        VStack(alignment: .leading, spacing: 11) {
            sessionNameField
            SessionGoalsList(store: store, allowsEditing: true)

            TimerDurationRuler(minutes: selectedMinutes, isEnabled: true)

            HStack(alignment: .bottom, spacing: 8) {
                primaryButton("Start Timer", action: store.startOrResume)
                if store.canUndoReset {
                    secondaryButton("Undo reset", action: store.undoReset)
                        .transition(.opacity)
                }
                Spacer()
                readout
            }
        }
    }

    private var sessionNameField: some View {
        TextField("Enter Session Name", text: $store.sessionName)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            }
    }

    // MARK: - Running and paused

    private var liveLayout: some View {
        // Big Clock: the time dominates, a bar fills as the session runs, the
        // goal sits on one line, and the controls stack on the right.
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                clockCards
                progressBar
                    .padding(.top, 14)
                goalLine
                    .padding(.top, 12)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(width: 1)

            controlColumn
            .frame(width: 140)
        }
    }

    private var controlColumn: some View {
        VStack(spacing: 7) {
            columnButton(
                store.state == .running ? "Pause" : "Resume",
                symbol: store.state == .running ? "pause.fill" : "play.fill",
                primary: true,
                action: { store.state == .running ? store.pause() : store.startOrResume() }
            )
            columnButton("5 min", symbol: "plus", primary: false) { store.addTime(5 * 60) }
                .disabled(!store.canAddTime)
                .help("Add five minutes")
            if isBreak {
                columnButton("Back to it", symbol: "arrow.uturn.backward", primary: false, action: store.backToWork)
                    .help("End the break and start the session again")
            } else {
                if store.nextTask != nil {
                    columnButton("Goal done", symbol: "checkmark", primary: false, action: store.completeCurrentTask)
                        .help("Cross off \(store.nextTask?.title ?? "the current goal")")
                }
                columnButton("Finish early", symbol: "flag.checkered", primary: false, action: store.finishEarly)
                    .help("End the session now and see how it went")
            }
            Spacer(minLength: 0)
            Button(isBreak ? "End break" : "Reset") {
                if isBreak { store.clearSession() } else { store.reset() }
            }
            .buttonStyle(.nanoPress)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.4))
            .help(isBreak ? "Stop the break and the session" : "Throw this session away")
        }
    }

    /// Hours, minutes and seconds straight on the island; hours only when there are some.
    private var clockCards: some View {
        let total = max(Int(store.remaining.rounded(.up)), 0)
        let parts: [(String, String)] = (total >= 3600 ? [("\(total / 3600)", "hr")] : [])
            + [(String(format: "%02d", (total % 3600) / 60), "min"), (String(format: "%02d", total % 60), "sec")]
        return HStack(spacing: 22) {
            ForEach(Array(parts.enumerated()), id: \.element.1) { index, part in
                VStack(spacing: 4) {
                    NanoRollingText(text: part.0, size: 50)
                        .foregroundStyle(.white.opacity(index == parts.count - 1 ? 0.55 : 0.95))
                    Text(part.1.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(.white.opacity(0.34))
                }
            }
        }
        .padding(.top, 6)
        .opacity(store.state == .paused ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(store.formattedRemaining) remaining")
    }

    private var progressBar: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(tint.opacity(store.state == .paused ? 0.5 : 0.95))
                        .frame(width: max(geometry.size.width * store.progress, 6))
                        .animation(.linear(duration: 0.5), value: store.progress)
                }
            }
            .frame(height: 6)
            HStack {
                Text("\(Int(store.elapsed / 60)) min in")
                Spacer()
                Text(store.endsAt.map { "ends \($0.formatted(date: .omitted, time: .shortened))" }
                    ?? (store.state == .paused ? "Paused" : ""))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.36))
        }
    }

    /// Orange for a session, a calmer mint for its break.
    private var isBreak: Bool { store.mode == .rest }
    private var tint: Color { isBreak ? Color(red: 0.42, green: 0.84, blue: 0.74) : .orange }

    @ViewBuilder
    private var goalLine: some View {
        if isBreak {
            Label(
                store.nextTask.map { "Break · then back to \($0.title)" } ?? "Break · step away for a bit",
                systemImage: "cup.and.saucer.fill"
            )
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
        } else if let current = store.nextTask {
            let later = store.tasks.first { !$0.isDone && $0.id != current.id }
            HStack(spacing: 7) {
                Image(systemName: "arrow.right.square")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                Text(current.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text([later.map { "then \($0.title)" }, "\(store.completedTaskCount) of \(store.tasks.count) done"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.36))
                    .lineLimit(1)
            }
        } else if !store.tasks.isEmpty {
            Label("All \(store.tasks.count) goals done", systemImage: "checkmark.square.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
        } else {
            Text(sessionTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
    }

    private func columnButton(
        _ title: String,
        symbol: String,
        primary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .foregroundStyle(primary ? Color.black : .white.opacity(0.88))
                .background(primary ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.09)), in: Capsule())
                .contentShape(Capsule())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.nanoPress)
    }

    // MARK: - Completed

    private var completionLayout: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isBreak ? "Break's over" : "Session complete")
                    .font(.system(size: 19, weight: .semibold))

                Text(isBreak
                    ? (store.nextTask.map { "Back to \($0.title)?" } ?? "Back to \(sessionTitle)?")
                    : sessionTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            if !isBreak {
                if store.tasks.isEmpty {
                    Text("No goals were set for this session.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.38))
                } else {
                    Text(goalSummary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            store.completedTaskCount == store.tasks.count
                                ? .orange
                                : .white.opacity(0.5)
                        )

                    SessionGoalsList(store: store, allowsEditing: false)
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .bottom, spacing: 8) {
                if isBreak {
                    primaryButton("Back to It", action: store.backToWork)
                    secondaryButton("Done for Now", action: store.clearSession)
                } else {
                    primaryButton(
                        "Take a \(Int(store.suggestedBreak / 60))-Min Break",
                        tint: Color(red: 0.25, green: 0.66, blue: 0.57),
                        action: store.startBreak
                    )
                    secondaryButton("Keep Going +15", action: store.keepGoing)
                    secondaryButton("Done", action: store.clearSession)
                }
                Spacer()
            }
        }
    }

    private var goalSummary: String {
        let done = store.completedTaskCount
        let total = store.tasks.count
        guard done < total else {
            return total == 1 ? "Your goal is done" : "All \(total) goals done"
        }
        return "\(done) of \(total) goals done"
    }

    // MARK: - Shared pieces

    private var sessionTitle: String {
        let trimmed = store.sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? store.mode.title : trimmed
    }

    private func primaryButton(_ title: String, tint: Color = .orange, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.nanoPress)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 15)
            .frame(height: 30)
            .background(tint.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.nanoPress)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 13)
            .frame(height: 30)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var readout: some View {
        let font = Font.system(size: 38, weight: .medium)

        if isEditingDuration {
            TextField("", text: $durationDraft)
                .textFieldStyle(.plain)
                .font(font)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.orange)
                .frame(width: 200)
                .focused($durationFieldFocused)
                .onAppear { durationFieldFocused = true }
                .onSubmit(commitDuration)
                .onExitCommand { isEditingDuration = false }
                .onChange(of: durationFieldFocused) { _, focused in
                    guard !focused else { return }
                    commitDuration()
                }
        } else {
            Text(store.formattedRemaining)
                .font(font)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.3), value: store.formattedRemaining)
                .foregroundStyle(.white.opacity(0.95))
                .onTapGesture(perform: beginEditingDuration)
                .help("Click to type a duration, such as 90 or 1:30")
        }
    }

    private func beginEditingDuration() {
        guard store.state == .idle else { return }

        let minutes = selectedMinutes.wrappedValue
        durationDraft = minutes < 60
            ? "\(minutes)"
            : "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
        isEditingDuration = true
    }

    private func commitDuration() {
        guard isEditingDuration else { return }
        isEditingDuration = false

        guard let parsed = Self.parseMinutes(durationDraft) else { return }
        store.setDuration(seconds: Double(min(max(parsed, 1), 240)) * 60)
    }

    /// Accepts plain minutes ("90"), clock notation ("1:30") and hour
    /// shorthand ("2h", "1h30").
    static func parseMinutes(_ raw: String) -> Int? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        let separator: Character? = text.contains(":") ? ":" : (text.contains("h") ? "h" : nil)
        guard let separator else { return Int(text.filter(\.isNumber)) }

        let parts = text.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        guard let hours = Int(parts[0].filter(\.isNumber)) else { return nil }

        let tail = parts.count > 1 ? parts[1].filter(\.isNumber) : ""
        return hours * 60 + (Int(tail) ?? 0)
    }
}


/// Collapsible checklist of session goals. Each row cycles through pending,
/// active and done, and the header carries a rolling completed count.
private struct SessionGoalsList: View {
    @ObservedObject var store: FocusTimerStore
    var allowsEditing: Bool

    @State private var draft = ""
    @State private var hoveredID: FocusSessionTask.ID?

    private var progress: Double {
        guard !store.tasks.isEmpty else { return 0 }
        return Double(store.completedTaskCount) / Double(store.tasks.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header

            if store.goalsExpanded {
                if allowsEditing {
                    TextField("Add a goal, then press Return", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        .onSubmit {
                            store.addTask(draft)
                            draft = ""
                        }
                }

                if !store.tasks.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(store.tasks.enumerated()), id: \.element.id) { index, task in
                                row(task, index: index)
                            }
                        }
                    }
                    // Sized to fit exactly, since the island grows to match.
                    .frame(
                        maxHeight: CGFloat(
                            min(store.tasks.count, IslandViewModel.maxUnscrolledGoals)
                        ) * IslandViewModel.goalRowHeight
                    )
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.snappy(duration: 0.24)) { store.goalsExpanded.toggle() }
        } label: {
            HStack(spacing: 7) {
                headerIcon
                    .frame(width: 13, height: 13)

                Text("Session Goals")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))

                Text("\(store.completedTaskCount)/\(store.tasks.count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.3), value: store.completedTaskCount)
                    .foregroundStyle(.white.opacity(0.4))

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(store.goalsExpanded ? 0 : -90))
                    .foregroundStyle(.white.opacity(0.32))

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.nanoPress)
        .accessibilityLabel("Toggle session goals")
    }

    @ViewBuilder
    private var headerIcon: some View {
        if store.tasks.isEmpty {
            Image(systemName: "list.bullet")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
        } else if store.completedTaskCount == store.tasks.count {
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        } else {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .animation(.snappy(duration: 0.3), value: progress)
        }
    }

    private func row(_ task: FocusSessionTask, index: Int) -> some View {
        // The first unfinished goal is what the session is working on now.
        let isActive = !task.isDone && store.nextTask?.id == task.id

        return HStack(spacing: 8) {
            Button {
                store.toggleTask(task.id)
            } label: {
                Image(systemName: symbol(done: task.isDone, active: isActive))
                    .font(.system(size: 13))
                    .foregroundStyle(tint(done: task.isDone, active: isActive))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.nanoPress)
            .help(task.isDone ? "Mark as not done" : "Cross off")

            Text(task.title)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .strikethrough(task.isDone, color: .white.opacity(0.3))
                .foregroundStyle(labelTint(done: task.isDone, active: isActive))
                .lineLimit(1)

            Spacer(minLength: 0)

            if allowsEditing {
                Button {
                    store.removeTask(task.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 14, height: 14)
                        .padding(7).contentShape(Rectangle()).padding(-7)
                }
                .buttonStyle(.nanoPress)
                .opacity(hoveredID == task.id ? 1 : 0)
                .help("Remove goal")
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredID = hovering ? task.id : (hoveredID == task.id ? nil : hoveredID)
        }
        .animation(
            .snappy(duration: 0.22).delay(Double(index) * 0.03),
            value: store.goalsExpanded
        )
    }

    private func symbol(done: Bool, active: Bool) -> String {
        if done { return "checkmark.square.fill" }
        return active ? "arrow.right.square" : "square.dashed"
    }

    private func tint(done: Bool, active: Bool) -> Color {
        if done { return .orange }
        return active ? .orange.opacity(0.85) : .white.opacity(0.3)
    }

    private func labelTint(done: Bool, active: Bool) -> Color {
        if done { return .white.opacity(0.4) }
        return active ? .white.opacity(0.95) : .white.opacity(0.7)
    }
}

/// Horizontal scrub ruler. Each tick is a minute and the centred tick is the
/// selected duration, so dragging or scrolling counts the time up or down.
private struct TimerDurationRuler: View {
    @Binding var minutes: Int
    var isEnabled: Bool

    private let lowerBound = 1.0
    private let upperBound = 240.0
    private let tickSpacing: CGFloat = 9

    /// Continuous position so a drag reads smoothly between whole minutes.
    @State private var value = 1.0

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                draw(in: context, size: size)
            }
            .frame(height: 38)
            .overlay {
                RulerInteraction(
                    isEnabled: isEnabled,
                    onDelta: { adjust(minutes: $0) },
                    onEnded: { value = value.rounded() }
                )
            }

            RulerArrow()
                .fill(.white.opacity(isEnabled ? 0.85 : 0.4))
                .frame(width: 14, height: 8)
        }
        .onAppear { value = Double(minutes) }
        .onChange(of: minutes) { _, new in
            // Only fires when something other than the ruler set the duration
            // — a preset or a typed value — so it can glide there.
            guard Int(value.rounded()) != new else { return }
            withAnimation(.snappy(duration: 0.45)) { value = Double(new) }
        }
    }

    private func adjust(minutes delta: Double) {
        guard isEnabled else { return }
        setValue(value + delta)
    }

    /// Plain minutes below an hour, then hours. Labels thin out past the hour
    /// mark so "2:15" and "3h" have room to breathe.
    private func label(for minute: Int) -> String? {
        guard minute >= 60 else { return "\(minute)" }
        guard minute.isMultiple(of: 15) else { return nil }

        let hours = minute / 60
        let remainder = minute % 60
        return remainder == 0 ? "\(hours)h" : "\(hours):\(String(format: "%02d", remainder))"
    }

    private func setValue(_ proposed: Double) {
        let clamped = min(max(proposed, lowerBound), upperBound)
        guard clamped != value else { return }
        value = clamped

        let rounded = Int(clamped.rounded())
        guard rounded != minutes else { return }
        minutes = rounded
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let center = size.width / 2
        let reach = Int(center / tickSpacing) + 2
        let anchor = Int(value.rounded())

        for minute in (anchor - reach)...(anchor + reach) {
            guard Double(minute) >= lowerBound, Double(minute) <= upperBound else { continue }

            let x = center + (CGFloat(minute) - CGFloat(value)) * tickSpacing
            guard x > -4, x < size.width + 4 else { continue }

            // Brightest at the centre, falling away toward both edges.
            let fade = max(1 - pow(abs(x - center) / center, 1.4), 0.05)
            let isMajor = minute.isMultiple(of: 5)
            let width: CGFloat = isMajor ? 1.6 : 1
            let height: CGFloat = isMajor ? 22 : 11

            context.fill(
                Path(
                    roundedRect: CGRect(
                        x: x - width / 2,
                        y: size.height - height,
                        width: width,
                        height: height
                    ),
                    cornerRadius: width / 2
                ),
                with: .color(.orange.opacity((isMajor ? 0.9 : 0.42) * fade))
            )

            guard isMajor, let text = label(for: minute) else { continue }

            var label = context.resolve(
                Text(text).font(.system(size: 9, weight: .medium))
            )
            label.shading = .color(.orange.opacity(0.85 * fade))
            context.draw(label, at: CGPoint(x: x, y: 6), anchor: .center)
        }

        context.fill(
            Path(
                roundedRect: CGRect(x: center - 1, y: size.height - 26, width: 2, height: 26),
                cornerRadius: 1
            ),
            with: .color(.orange)
        )
    }
}

private struct RulerArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// SwiftUI's scroll views will not report a centred item across ticks this
/// narrow, so the ruler takes trackpad and mouse input straight from AppKit.
private struct RulerInteraction: NSViewRepresentable {
    var isEnabled: Bool
    let onDelta: (Double) -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> RulerInteractionView {
        let view = RulerInteractionView()
        view.onDelta = onDelta
        view.onEnded = onEnded
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: RulerInteractionView, context: Context) {
        nsView.onDelta = onDelta
        nsView.onEnded = onEnded
        nsView.isEnabled = isEnabled
    }
}

private final class RulerInteractionView: NSView {
    /// Positive values count the duration up, measured in minutes.
    var onDelta: ((Double) -> Void)?
    var onEnded: (() -> Void)?
    var isEnabled = true

    /// Matches the ruler's tick spacing, so a drag tracks the ticks exactly.
    private let pointsPerMinute: CGFloat = 9
    private var lastScrollTime: TimeInterval = 0

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else {
            super.scrollWheel(with: event)
            return
        }

        let precise = event.hasPreciseScrollingDeltas
        let horizontal = precise ? event.scrollingDeltaX : event.deltaX
        let vertical = precise ? event.scrollingDeltaY : event.deltaY

        // Swiping left, or rolling the wheel forward, counts up.
        let raw = abs(horizontal) > abs(vertical) ? -horizontal : vertical
        guard raw != 0 else { return }

        // Trackpads report points of travel, so scale by the tick spacing.
        // Wheels report whole lines, where one detent is already a minute.
        let minutes = precise
            ? Double(raw / pointsPerMinute) * 1.2
            : Double(raw) * wheelBoost()

        onDelta?(minutes)
    }

    /// A free-spinning wheel should cross hours without a hundred detents,
    /// while a slow deliberate click still lands on a single minute.
    private func wheelBoost() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - lastScrollTime
        lastScrollTime = now

        return switch gap {
        case ..<0.02: 6
        case ..<0.04: 3.5
        case ..<0.08: 2
        case ..<0.16: 1
        default: 0.5
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, event.deltaX != 0 else { return }
        onDelta?(Double(-event.deltaX / pointsPerMinute))
    }

    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { return }
        onEnded?()
    }
}

private enum TrayDropSide {
    case holding
    case airDrop
}

/// The tray, after Droppy: while a file is dragged in, a row of drop targets
/// just wide enough for them; otherwise a shelf as wide as what it holds.
/// `IslandViewModel.traySize` sizes the island to match.
struct TrayModuleView: View {
    @ObservedObject var store: TrayStore
    @ObservedObject var settings: NanoSettings
    let isDropping: Bool

    @State private var targetedSide: TrayDropSide?

    var body: some View {
        Group {
            if isDropping {
                targets
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if store.items.isEmpty {
                emptyShelf
            } else {
                shelf
            }
        }
        .animation(.snappy(duration: 0.24), value: isDropping)
        .animation(.snappy(duration: 0.24), value: store.items.count)
        .overlay(alignment: .bottom) {
            if let message = store.isCompressing ? "Compressing…" : store.message {
                HStack(spacing: 8) {
                    Text(message)
                        .lineLimit(1)
                    if store.canUndo, !store.isCompressing {
                        Button("Undo") { store.undoDiscard() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Color(white: 0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.message)
        .animation(.easeOut(duration: 0.2), value: store.isCompressing)
        .onAppear(perform: store.pruneMissing)
    }

    // MARK: Drop targets

    private var targets: some View {
        HStack(spacing: 8) {
            target(.holding, title: "Hold", hot: "Release to hold", symbol: "tray.and.arrow.down")
            target(.airDrop, title: "AirDrop", hot: "Release to AirDrop", symbol: "dot.radiowaves.left.and.right")
        }
        .animation(.snappy(duration: 0.2), value: targetedSide)
    }

    private func target(_ side: TrayDropSide, title: String, hot: String, symbol: String) -> some View {
        let isHot = targetedSide == side
        return VStack(spacing: 6) {
            Image(systemName: isHot ? symbol + ".fill" : symbol)
                .font(.system(size: 20, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
            Text(isHot ? hot : title)
                .font(.system(size: 11, weight: isHot ? .semibold : .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(isHot ? 1 : 0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(isHot ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .scaleEffect(isHot ? 1.04 : 1)
        .overlay(
            TrayDropTarget(
                onTargeted: { targeted in
                    targetedSide = targeted ? side : (targetedSide == side ? nil : targetedSide)
                },
                perform: { pasteboard in
                    targetedSide = nil
                    return side == .airDrop ? store.airDrop(pasteboard) : store.accept(pasteboard)
                }
            )
        )
    }

    // MARK: Shelf

    private var emptyShelf: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing held")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("Drag a file, link, or image onto the notch")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 8)
            Button("Paste", action: store.pasteFromClipboard)
                .buttonStyle(.nanoPress)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(.white.opacity(0.1), in: Capsule())
                .help("Hold what's on the clipboard: files, a link, an image, or text")
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    private var shelf: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: IslandViewModel.trayItemSpacing) {
                    ForEach(store.items) { item in
                        TrayShelfItem(
                            item: item,
                            isSelected: store.selection.contains(item.id),
                            dragURLs: store.urls(actingOn: item),
                            store: store,
                            settings: settings,
                            toggle: { toggle(item) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)

            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(width: 1)
                .padding(.vertical, 6)

            VStack(spacing: 6) {
                tool(allSelected ? "checkmark.circle.fill" : "checkmark.circle",
                     help: allSelected ? "Deselect all" : "Select all") {
                    store.selection = allSelected ? [] : Set(store.items.map(\.id))
                }
                tool("dot.radiowaves.left.and.right",
                     help: store.selection.isEmpty ? "AirDrop everything" : "AirDrop the selected items") {
                    store.sendViaAirDrop(store.selectedURLs)
                }
                tool("trash", help: store.selection.isEmpty ? "Clear the tray" : "Remove the selected items") {
                    store.discardSelectionOrAll()
                }
            }
            .frame(width: IslandViewModel.trayToolsWidth - 11)
        }
    }

    private var allSelected: Bool {
        !store.items.isEmpty && store.selection.count == store.items.count
    }

    private func toggle(_ item: TrayItem) {
        if store.selection.contains(item.id) {
            store.selection.remove(item.id)
        } else {
            store.selection.insert(item.id)
        }
    }

    private func tool(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.09), in: Circle())
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.nanoPress)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One held item on the shelf: its preview and name. Click to select, drag
/// out (with the rest of the selection), double-click to open, right-click
/// for the rest.
private struct TrayShelfItem: View {
    let item: TrayItem
    let isSelected: Bool
    let dragURLs: [URL]
    @ObservedObject var store: TrayStore
    @ObservedObject var settings: NanoSettings
    let toggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 5) {
            TrayThumbnail(url: item.url, side: 46)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 6, y: 6)
                    }
                }
            Text(item.name)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.7))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: IslandViewModel.trayItemWidth)
        .overlay(
            TrayFileDragSource(
                urls: dragURLs,
                onClick: toggle,
                onDoubleClick: { store.open(item) },
                menuItems: { TrayItemMenu.items(for: item, store: store) },
                onDragEnded: { delivered in
                    if delivered, settings.trayRemovesAfterDragOut {
                        store.remove(urls: dragURLs)
                    }
                }
            )
        )
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button { store.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9), .white.opacity(0.25))
                        .padding(7).contentShape(Rectangle()).padding(-7)
                }
                .buttonStyle(.nanoPress)
                .offset(x: -4, y: -4)
                .help("Remove from the tray")
            }
        }
        .onHover { isHovered = $0 }
        .help(item.url.path)
        .animation(.snappy(duration: 0.18), value: isSelected)
    }
}

/// A Quick Look preview: images, PDFs, and videos show their contents, and
/// anything else the icon Finder would draw.
struct TrayThumbnail: View {
    let url: URL
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Image(nsImage: image ?? TrayThumbnails.cached(url, side: side) ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .task(id: url) {
                image = await TrayThumbnails.load(url, side: side)
            }
    }
}

/// The quick actions for a held file. The island's context menu puts them
/// first when the click lands on one (`TrayFileDragView.menuItems`).
@MainActor
enum TrayItemMenu {
    static func items(for item: TrayItem, store: TrayStore) -> [NSMenuItem] {
        var items = [action("Open") { store.open(item) }]

        let applications = NSWorkspace.shared.urlsForApplications(toOpen: item.url)
        if !applications.isEmpty {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for application in applications.prefix(12) {
                let entry = action(FileManager.default.displayName(atPath: application.path)) {
                    store.open(item, with: application)
                }
                let icon = NSWorkspace.shared.icon(forFile: application.path)
                icon.size = NSSize(width: 16, height: 16)
                entry.image = icon
                submenu.addItem(entry)
            }
            openWith.submenu = submenu
            items.append(openWith)
        }

        items.append(action("Show in Finder") { store.reveal(item) })
        items.append(action("Copy") { store.copy(item) })
        let targets = store.urls(actingOn: item)
        items.append(action(targets.count > 1 ? "Compress \(targets.count) Items to ZIP" : "Compress to ZIP") {
            store.compressToZip(targets)
        })
        // The system's Share… item shows nothing when picked from the island's
        // menu. These services open their own windows, so they work from here.
        let services = [NSSharingService.Name.sendViaAirDrop, .composeMessage, .composeEmail]
            .compactMap(NSSharingService.init(named:))
            .filter { $0.canPerform(withItems: [item.url]) }
        if !services.isEmpty {
            let share = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for service in services {
                let entry = action(service.menuItemTitle) {
                    NSApp.activate(ignoringOtherApps: true)
                    service.perform(withItems: [item.url])
                }
                entry.image = service.image
                submenu.addItem(entry)
            }
            share.submenu = submenu
            items.append(share)
        }
        items.append(.separator())
        items.append(action("Remove from Tray") { store.remove(item) })
        return items
    }

    private static func action(_ title: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        DashboardOptionMenuItem(option: DashboardWidgetOption(title: title, kind: .action, perform: run))
    }
}

/// Takes drops at the AppKit level. SwiftUI's typed drops pick their own
/// representation: with images accepted, a JPEG dragged from Finder arrived
/// as image data and was held as a copy. The pasteboard is read directly
/// instead, files first (`TrayStore.holdables`).
struct TrayDropTarget: NSViewRepresentable {
    let onTargeted: (Bool) -> Void
    let perform: (NSPasteboard) -> Bool

    func makeNSView(context: Context) -> TrayDropTargetView {
        TrayDropTargetView()
    }

    func updateNSView(_ view: TrayDropTargetView, context: Context) {
        view.onTargeted = onTargeted
        view.perform = perform
    }
}

final class TrayDropTargetView: NSView {
    var onTargeted: ((Bool) -> Void)?
    var perform: ((NSPasteboard) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(TrayStore.holdableTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        return perform?(sender.draggingPasteboard) ?? false
    }
}

/// Drags held files out of Nano as the originals, the way Finder does.
/// SwiftUI's `onDrag` and `draggable` both hand receivers a copy from their
/// own cache, which Finder then duplicates and which can vanish later.
/// Copy and link only: dropping into a folder never moves the original.
struct TrayFileDragSource: NSViewRepresentable {
    let urls: [URL]
    /// A single click that didn't turn into a drag.
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var menuItems: (() -> [NSMenuItem])?
    /// True when a receiver took the files.
    var onDragEnded: ((Bool) -> Void)?

    func makeNSView(context: Context) -> TrayFileDragView {
        TrayFileDragView()
    }

    func updateNSView(_ view: TrayFileDragView, context: Context) {
        view.urls = urls
        view.onClick = onClick
        view.onDoubleClick = onDoubleClick
        view.menuItems = menuItems
        view.onDragEnded = onDragEnded
    }
}

final class TrayFileDragView: NSView, NSDraggingSource {
    var urls: [URL] = []
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var menuItems: (() -> [NSMenuItem])?
    var onDragEnded: ((Bool) -> Void)?
    private var mouseDownEvent: NSEvent?
    private var clickedOnce = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        if event.clickCount == 2 {
            // The first click of the pair already toggled the selection;
            // opening an item should leave it as it was.
            if clickedOnce { onClick?() }
            onDoubleClick?()
        }
        clickedOnce = false
    }

    override func mouseUp(with event: NSEvent) {
        // Still set only when the press never became a drag.
        if mouseDownEvent != nil, event.clickCount == 1 {
            onClick?()
            clickedOnce = true
        }
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard !urls.isEmpty, let down = mouseDownEvent else { return }
        mouseDownEvent = nil
        let point = convert(down.locationInWindow, from: nil)
        // A small fanned stack; past a few files the rest sit underneath.
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let offset = CGFloat(min(index, 4)) * 4
            item.setDraggingFrame(
                NSRect(x: point.x - 16 + offset, y: point.y - 16 - offset, width: 32, height: 32),
                contents: NSWorkspace.shared.icon(forFile: url.path)
            )
            return item
        }
        beginDraggingSession(with: items, event: down, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnded?(!operation.isEmpty)
    }
}

private struct AdjustmentUnavailableView: View {
    let module: NanoModuleID

    var body: some View {
        HStack(spacing: 22) {
            Image(systemName: module.symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 92, height: 92)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22))
            VStack(alignment: .leading, spacing: 7) {
                Text(module.title)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
    }

    private var explanation: String {
        switch module {
        case .bluetooth:
            "Connection alerts already appear on the island. Accessory battery percentages are not a public API, so this module will not guess."
        case .brightness:
            "Brightness key changes already appear on the island. A slider for every display is still planned."
        case .notificationLabs:
            "Recent island alerts land here after they fire."
        default:
            "This adjustment is unavailable on the current Mac."
        }
    }
}
