import AVFoundation
import AppKit
import SwiftUI

enum OnboardingChrome {
    static let text = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let secondary = Color(red: 0.63, green: 0.63, blue: 0.65)
    static let tertiary = Color(red: 0.50, green: 0.50, blue: 0.52)
    static let card = Color(red: 0.075, green: 0.075, blue: 0.082)
    static let window = Color(red: 0.11, green: 0.11, blue: 0.118)
    static let accent = Color(red: 0.04, green: 0.52, blue: 1)
    static let positive = Color(red: 0.36, green: 0.86, blue: 0.5)
    static let danger = Color(red: 1, green: 0.42, blue: 0.4)
    static let quiet = Color.white.opacity(0.1)
}

struct OnboardingExperienceView: View {
    @ObservedObject var flow: OnboardingFlow

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settings: NanoSettings { flow.settings }
    private var viewModel: IslandViewModel { flow.viewModel }

    var body: some View {
        let size = CGSize(width: OnboardingFlow.windowWidth, height: flow.windowHeight)
        let top = flow.windowTop
        VStack(alignment: .leading, spacing: 0) {
            if flow.step != .resume {
                header.padding(.bottom, 22)
            }
            content
        }
        .padding(.horizontal, 34)
        .padding(.top, 26)
        .padding(.bottom, 28)
        .frame(width: size.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                    DispatchQueue.main.async { flow.windowHeight = height }
                }
            }
        }
        .foregroundStyle(OnboardingChrome.text)
        .background {
            ZStack {
                OnboardingBlur()
                OnboardingChrome.window.opacity(0.95)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 40, y: 24)
        .environment(\.colorScheme, .dark)
        .scaleEffect(
            flow.windowShown || reduceMotion ? 1 : 0.06,
            anchor: UnitPoint(x: 0.5, y: (16 - top) / size.height)
        )
        .opacity(flow.windowShown ? 1 : 0)
        .offset(y: top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .allowsHitTesting(flow.windowShown)
        .animation(windowAnimation, value: flow.windowShown)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.78), value: top)
        .animation(stepAnimation, value: size.height)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            flow.refreshSystemState()
        }
    }

    private var windowAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.25) }
        return flow.windowShown
            ? .spring(response: 0.55, dampingFraction: 0.8)
            : .easeIn(duration: 0.45)
    }

    private var stepAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(0..<flow.progressCount, id: \.self) { index in
                    Capsule()
                        .fill(segmentColor(index))
                        .frame(height: 2)
                }
            }
            .animation(stepAnimation, value: flow.progressIndex)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(flow.progressIndex + 1) of \(flow.progressCount)")
            if flow.step != .summary {
                Button("Set up later", action: flow.setUpLater)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingChrome.secondary)
                    .help("Setup counts as done. Settings keeps a checklist and Replay setup.")
            }
        }
        .frame(height: 16)
    }

    private func segmentColor(_ index: Int) -> Color {
        if index == flow.progressIndex { return OnboardingChrome.text }
        return index < flow.progressIndex ? Color.white.opacity(0.42) : Color.white.opacity(0.12)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            switch flow.step {
            case .resume: resume
            case .welcome: welcome
            case .pick: pick
            case .summary: summary
            case .room:
                switch flow.currentRoom {
                case .notifications: notifications
                case .agents: agents
                case .voice: quill
                case .sketch: sketch
                case .cue: cue
                case .mixer: mixer
                case .dashboard: dashboard
                case nil: EmptyView()
                }
            default:
                Color.clear.frame(height: 1)
            }
        }
        .id(flow.step)
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(insertion: .offset(y: 12).combined(with: .opacity), removal: .opacity)
        )
        .animation(stepAnimation, value: flow.step)
    }

    private var resume: some View {
        let target = flow.resumeTarget
        let steps = resumeSteps
        let targetIndex = steps.firstIndex { $0.step == target } ?? 0
        return room(spacing: 18) {
            heading(
                "Pick up where you left off?",
                "You stopped during \(flow.resumeTitle)\(savedWhen). Everything you set is saved."
            )
            panel {
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                        if index > 0 { divider }
                        HStack(spacing: 10) {
                            Group {
                                if index < targetIndex {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(OnboardingChrome.positive)
                                } else {
                                    Circle()
                                        .fill(index == targetIndex ? OnboardingChrome.accent : Color.white.opacity(0.25))
                                        .frame(width: 6, height: 6)
                                }
                            }
                            .frame(width: 14)
                            Text(item.title)
                                .font(.system(size: 13, weight: index <= targetIndex ? .semibold : .regular))
                                .foregroundStyle(index <= targetIndex ? OnboardingChrome.text : OnboardingChrome.tertiary)
                            Spacer()
                            if let detail = item.detail, index <= targetIndex {
                                Text(detail).font(.system(size: 12)).foregroundStyle(OnboardingChrome.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(index == targetIndex ? Color.white.opacity(0.04) : .clear)
                    }
                }
            }
        } footer: {
            HStack(spacing: 8) {
                Button("Set up later", action: flow.setUpLater)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(OnboardingChrome.secondary)
                Spacer()
                secondaryButton("Start over", action: flow.startOver)
                primaryButton("Continue with \(flow.resumeTitle)", action: flow.continueSetup)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var savedWhen: String {
        guard let date = flow.savedProgress?.savedAt else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return " earlier today" }
        if calendar.isDateInYesterday(date) { return " yesterday" }
        return ""
    }

    private var resumeSteps: [(step: OnboardingFlow.Step, title: String, detail: String?)] {
        var steps: [(OnboardingFlow.Step, String, String?)] = [
            (.welcome, "Welcome", "\(settings.placement.title), \(settings.appearance.title)"),
            (.pick, "Pick", "\(flow.picks.count) added"),
        ]
        for (index, room) in flow.rooms.enumerated() {
            steps.append((.room(index), room.title, resumeDetail(room)))
        }
        steps.append((.summary, "Summary", nil))
        return steps
    }

    private func resumeDetail(_ room: OnboardingRoom) -> String? {
        switch room {
        case .notifications: settings.hudReplacesSystemHUD ? "Volume cards on" : nil
        case .agents: flow.connectedCount > 0 ? "\(flow.connectedCount) connected" : nil
        case .voice: quillStatus(settings.voiceDictationEngine)
        default: nil
        }
    }

    private var welcome: some View {
        room(spacing: 16) {
            Text("Where should Nano live?")
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.3)
            HStack(spacing: 10) {
                placementCard(.attached, "Notch", hasNotch ? "Wraps the notch on this Mac" : "For Macs with a notch")
                placementCard(.floating, "Floating", "Hangs under the menu bar")
            }
            ZStack(alignment: .bottomLeading) {
                OnboardingVideo(name: dashboardClip)
                    .id(dashboardClip)
                    .transition(.opacity)
                segmented(IslandAppearance.allCases, selection: settings.appearance, title: appearanceTitle) {
                    settings.appearance = $0
                }
                .padding(3)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(10)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeInOut(duration: 0.3), value: dashboardClip)
            VStack(spacing: 0) {
                switchRow(
                    title: "Open Nano at login",
                    detail: viewModel.loginItem.needsApproval
                        ? "Blocked in System Settings › General › Login Items."
                        : nil,
                    isOn: Binding(
                        get: { viewModel.loginItem.isEnabled || viewModel.loginItem.needsApproval },
                        set: { viewModel.loginItem.setEnabled($0) }
                    )
                )
                divider
                switchRow(
                    title: "Tell me about new versions",
                    detail: "Checks GitHub once a day. You choose when to update.",
                    isOn: Binding(get: { settings.checksForUpdates }, set: { settings.checksForUpdates = $0 })
                )
            }
        } footer: {
            HStack {
                Text("Free and open source. No account, no analytics.")
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingChrome.secondary)
                Spacer()
                primaryButton("Next", action: flow.next)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .onAppear {
            flow.turnOnLoginItemOnce()
            viewModel.loginItem.refresh()
        }
    }

    private var hasNotch: Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    private var dashboardClip: String {
        switch settings.appearance {
        case .solidBlack: "dashboard"
        case .glass: "dashboard-glass"
        case .hybrid: "dashboard-hybrid"
        }
    }

    private func appearanceTitle(_ appearance: IslandAppearance) -> String {
        switch appearance {
        case .solidBlack: "Solid"
        case .glass: "Glass"
        case .hybrid: "Hybrid"
        }
    }

    private func placementCard(_ placement: IslandPlacement, _ title: String, _ detail: String) -> some View {
        let selected = settings.placement == placement
        return Button { settings.placement = placement } label: {
            HStack(spacing: 12) {
                PlacementGlyph(placement: placement)
                    .frame(width: 44, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(OnboardingChrome.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                selected ? OnboardingChrome.accent.opacity(0.12) : OnboardingChrome.card,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? OnboardingChrome.accent.opacity(0.7) : Color.white.opacity(0.06))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(OnboardingPress())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var pick: some View {
        let features = OnboardingFeature.offered
        let current = features[min(flow.showcaseIndex, features.count - 1)]
        let picked = flow.isPicked(current)
        return room(spacing: 0) {
            heading("What do you want Nano for?", "Watch each one and add what you'll use. Nothing is on until you add it.")

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(features.enumerated()), id: \.element) { index, feature in
                            pickTab(feature, selected: index == flow.showcaseIndex) { flow.showcaseIndex = index }
                        }
                    }
                    .padding(.horizontal, 34)
                }
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0), .init(color: .black, location: 0.07),
                            .init(color: .black, location: 0.93), .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                }
                .padding(.horizontal, -34)
                .onChange(of: flow.showcaseIndex) { _, index in
                    withAnimation(stepAnimation) { proxy.scrollTo(features[index], anchor: .center) }
                }
                .onAppear { proxy.scrollTo(features[flow.showcaseIndex], anchor: .center) }
            }
            .padding(.top, 16)

            ZStack(alignment: .bottom) {
                featureVisual(current)
                    .id(current)
                    .transition(.opacity)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title).font(.system(size: 13.5, weight: .semibold))
                        Text(current.line(word: flow.word))
                            .font(.system(size: 12))
                            .foregroundStyle(Color(white: 0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button { flow.toggle(current) } label: {
                        Label(picked ? "Added" : "Add", systemImage: picked ? "checkmark" : "plus")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .foregroundStyle(picked ? OnboardingChrome.text : .black)
                            .background(
                                picked ? Color.white.opacity(0.14) : OnboardingChrome.text,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                    }
                    .buttonStyle(OnboardingPress())
                    .accessibilityLabel(picked ? "Remove \(current.title)" : "Add \(current.title)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.06))
            }
            .animation(.easeInOut(duration: 0.3), value: flow.showcaseIndex)
            .padding(.top, 12)
        } footer: {
            HStack(spacing: 8) {
                Text("\(flow.picks.count) of \(features.count) added")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(OnboardingChrome.secondary)
                Spacer()
                secondaryButton("Just the island", action: flow.justTheIsland)
                primaryButton("Continue", enabled: !flow.picks.isEmpty, action: flow.startRooms)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 18)
        }
    }

    private func pickTab(_ feature: OnboardingFeature, selected: Bool, action: @escaping () -> Void) -> some View {
        let added = flow.isPicked(feature)
        return Button(action: action) {
            HStack(spacing: 5) {
                if added {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(selected ? Color.black : OnboardingChrome.accent)
                }
                Text(feature.title)
            }
            .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(selected ? .black : added ? OnboardingChrome.text : OnboardingChrome.secondary)
            .background(selected ? OnboardingChrome.text : Color.white.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(feature)
        .accessibilityLabel(feature.title)
        .accessibilityAddTraits(added ? .isSelected : [])
    }

    @ViewBuilder
    private func featureVisual(_ feature: OnboardingFeature) -> some View {
        if let clip = feature.clip, OnboardingClip.url(clip) != nil {
            OnboardingVideo(name: clip)
        } else {
            OnboardingPlaceholder(symbol: feature.symbol, line: feature.placeholderLine)
        }
    }

    private enum AlertKind: String, CaseIterable {
        case volume, airpods, battery

        var title: String {
            switch self {
            case .volume: "Volume"
            case .airpods: "AirPods"
            case .battery: "Battery"
            }
        }

        var clip: String { rawValue }
    }

    @State private var alertKind = AlertKind.volume

    private var notifications: some View {
        let kinds = AlertKind.allCases.filter { $0 != .battery || SystemStatusService.hasBattery }
        let systemOn = settings.isNotificationEnabled(.system)
        return room(spacing: 16) {
            heading("Notifications", "Choose what shows up in the \(flow.word).")
            ZStack(alignment: .bottomLeading) {
                OnboardingVideo(name: alertKind.clip).id(alertKind)
                segmented(kinds, selection: alertKind, title: \.title) { alertKind = $0 }
                    .padding(3)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(10)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(spacing: 0) {
                row(
                    "speaker.wave.2",
                    "Use Nano's volume and brightness cards",
                    detail: "They replace the macOS ones. Press a volume key to try."
                ) {
                    toggle("Use Nano's volume and brightness cards", isOn: Binding(
                        get: { settings.hudReplacesSystemHUD },
                        set: { flow.setSystemCards($0) }
                    ))
                }
                if settings.hudReplacesSystemHUD, !flow.accessibilityTrusted {
                    divider
                    row("accessibility", "Accessibility", detail: "Lets Nano catch the volume and brightness keys. Nano never records what you type.") {
                        allowButton("Allow", action: flow.requestAccessibility)
                    }
                }
                divider
                row(
                    "wave.3.right",
                    "AirPods and Bluetooth",
                    detail: "Shows battery when your AirPods or other devices connect. macOS asks for Bluetooth to do this."
                ) {
                    if flow.bluetoothAuthorization == .allowedAlways {
                        allowedLabel
                    } else {
                        allowButton(flow.bluetoothDenied ? "Open Settings" : "Allow", action: flow.requestBluetooth)
                    }
                }
                divider
                row(
                    "bell",
                    "Notifications from other apps",
                    tag: "Optional",
                    detail: "Messages, Mail and the rest appear in the \(flow.word). Needs Full Disk Access to read them."
                ) {
                    toggle("Notifications from other apps", isOn: Binding(
                        get: { settings.isNotificationEnabled(.system) },
                        set: { settings.setNotificationEnabled($0, for: .system) }
                    ))
                }
                if systemOn, !flow.fullDiskAccess {
                    divider
                    row("externaldrive", "Full Disk Access", detail: "macOS doesn't list Nano on its own. Drag Nano from the small window into the list, then turn it on.") {
                        allowButton("Open Settings") { NanoFullDiskAccess.request() }
                    }
                }
            }
        } footer: {
            navigation()
        }
    }

    private var agents: some View {
        Group {
            switch flow.agentPhase {
            case .pick, .connecting: agentPick
            case .test: agentTest
            case .done: agentsConnected
            }
        }
        .onAppear(perform: flow.seedAgentsIfNeeded)
    }

    private var agentPick: some View {
        let connecting = flow.agentPhase == .connecting
        let count = flow.connectableAgents.count
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                heading(
                    "Agents",
                    "Nano adds a small hook to each agent so its requests and limits show in the \(flow.word). Your own settings stay as they are."
                )
                Spacer(minLength: 0)
                miniVideo("agent-approval", label: "Approvals")
            }
            if flow.offeredAgents.isEmpty {
                Text("No supported agents found on this Mac yet. Connect one later from Settings › Agents.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(OnboardingChrome.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(OnboardingChrome.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                navigation()
            } else {
                sectionLabel("Found on this Mac")
                panel {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(flow.offeredAgents.enumerated()), id: \.element) { index, provider in
                                if index > 0 { divider }
                                agentCheckRow(provider, connecting: connecting)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(flow.offeredAgents.count), 5) * 50)
                }
                if let file = AgentHookBridge.installationConfigURLs(for: Set(flow.connectableAgents)).first {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.display(file)).foregroundStyle(OnboardingChrome.secondary)
                        Text("\"hooks\": {").foregroundStyle(OnboardingChrome.secondary)
                        Text("+ Nano's hook, next to your own entries").foregroundStyle(OnboardingChrome.positive)
                        Text("}").foregroundStyle(OnboardingChrome.secondary)
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(OnboardingChrome.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if !flow.hookFailures.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nano couldn't write these files. Check they aren't read-only, then try again.")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(flow.hookFailures, id: \.self) { url in
                            Text(Self.display(url)).font(.system(size: 11.5, design: .monospaced))
                        }
                    }
                    .foregroundStyle(Color.orange)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nano backs up each file first. Disconnect removes these lines.")
                    Text("Not installed yet? Connect later from Settings › Agents.")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(OnboardingChrome.secondary)
                HStack(spacing: 8) {
                    secondaryButton("Back", action: flow.back)
                    Spacer()
                    secondaryButton("Not now", action: flow.next)
                    primaryButton(
                        connecting ? "Connecting…" : count == 0 ? "Pick an agent" : "Connect \(count) agent\(count == 1 ? "" : "s")",
                        enabled: count > 0 && !connecting,
                        action: flow.connectAgents
                    )
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
        }
    }

    private func agentCheckRow(_ provider: AgentProviderID, connecting: Bool) -> some View {
        let on = flow.selectedAgents.contains(provider)
        let path = AgentHookBridge.installationConfigURLs(for: [provider]).first.map(Self.display)
        return Button { flow.toggleAgent(provider) } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(on ? OnboardingChrome.accent : Color.white.opacity(0.35))
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.title).font(.system(size: 13, weight: .semibold))
                    if let path {
                        Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(OnboardingChrome.secondary)
                    }
                }
                Spacer()
                if connecting, on {
                    Text("Adding hook…").font(.system(size: 11.5)).foregroundStyle(OnboardingChrome.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connecting)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var agentTest: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnboardingChrome.secondary)
                .modifier(OnboardingPulse(active: !reduceMotion))
            Text("Look up. Try it.")
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.3)
            Text("A test request is waiting in the \(flow.word). Press Allow or Deny. Nothing will run.")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingChrome.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            HStack(spacing: 6) {
                Circle().fill(OnboardingChrome.accent).frame(width: 5, height: 5)
                    .modifier(OnboardingPulse(active: !reduceMotion))
                Text("Waiting for your answer").font(.system(size: 11.5)).foregroundStyle(OnboardingChrome.secondary)
            }
            .padding(.top, 4)
            HStack {
                secondaryButton("Back", action: flow.back)
                Spacer()
                secondaryButton("Skip the test", action: flow.skipAgentTest)
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
    }

    private var agentsConnected: some View {
        room(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(OnboardingChrome.positive)
                    .frame(width: 24, height: 24)
                    .background(OnboardingChrome.positive.opacity(0.16), in: Circle())
                Text("Connected.").font(.system(size: 22, weight: .bold)).tracking(-0.3)
            }
            Text("Requests from these agents show up in the \(flow.word), the same way as the test.")
                .font(.system(size: 13))
                .foregroundStyle(OnboardingChrome.secondary)
                .fixedSize(horizontal: false, vertical: true)
            panel {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(flow.offeredAgents.enumerated()), id: \.element) { index, provider in
                            if index > 0 { divider }
                            agentStatusRow(provider)
                        }
                    }
                }
                .frame(height: min(CGFloat(flow.offeredAgents.count), 5) * 50)
            }
            HStack(spacing: 14) {
                OnboardingVideo(name: "usage-limits")
                    .frame(width: 150, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Usage limits too").font(.system(size: 13, weight: .semibold))
                    Text("Hover the \(flow.word) to see how much of each agent's limit is left and when it resets.")
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingChrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(OnboardingChrome.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } footer: {
            navigation()
        }
    }

    private func agentStatusRow(_ provider: AgentProviderID) -> some View {
        let connected = flow.isConnected(provider)
        let path = AgentHookBridge.installationConfigURLs(for: [provider]).first.map(Self.display)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.title).font(.system(size: 13, weight: .semibold))
                if let path {
                    Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(OnboardingChrome.secondary)
                }
            }
            Spacer()
            Text(connected ? "Connected" : "Not added")
                .font(.system(size: 11.5))
                .foregroundStyle(connected ? OnboardingChrome.positive : OnboardingChrome.tertiary)
            smallButton(connected ? "Disconnect" : "Connect") { flow.setConnected(provider, !connected) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var quill: some View {
        let dictation = viewModel.voiceDictation
        let mic = dictation.microphoneAuthorization
        let engine = settings.voiceDictationEngine
        return room(spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                heading("Quill", "Speak and Quill types it where your cursor is. It runs on this Mac and never keeps audio.")
                Spacer(minLength: 0)
                miniVideo("voice-dictation", label: nil)
            }
            sectionLabel("Engine")
            panel {
                VStack(spacing: 0) {
                    ForEach(Array(VoiceDictationEngine.offered.enumerated()), id: \.element) { index, option in
                        if index > 0 { divider }
                        engineRow(option)
                    }
                }
            }
            if let note = quillNote {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OnboardingChrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if mic == .denied || mic == .restricted {
                deniedCard(
                    symbol: "mic.slash",
                    title: "Microphone is off for Nano",
                    detail: "You said no, so macOS won't ask again. Quill can't hear you until you turn Nano on in System Settings.",
                    path: "Privacy & Security › Microphone",
                    anchor: NanoPermissionKind.microphone.settingsAnchor
                )
            }
            VStack(spacing: 0) {
                if mic != .denied, mic != .restricted {
                    row("mic", "Microphone", detail: "So Quill can hear you. Only while you dictate.") {
                        if mic == .authorized { allowedLabel } else { allowButton("Allow", action: flow.requestMicrophone) }
                    }
                    divider
                }
                row(
                    "accessibility",
                    "Accessibility",
                    tag: "Optional",
                    detail: "Lets Quill type the text for you. Without it, you paste with ⌘V."
                ) {
                    if flow.accessibilityTrusted { allowedLabel } else { allowButton("Allow", action: flow.requestAccessibility) }
                }
            }
            if mic == .authorized, dictation.modelStore.isReady(engine) {
                QuillTryField(hotkey: settings.voiceDictationHotkey.displayString, holds: settings.voiceDictationActivationMode != .toggle)
            }
        } footer: {
            navigation(trailingNote: mic == .denied ? "It stays on the summary list" : nil)
        }
    }

    private func engineRow(_ engine: VoiceDictationEngine) -> some View {
        let store = viewModel.voiceDictation.modelStore
        let selected = settings.voiceDictationEngine == engine
        let ready = store.isReady(engine)
        let progress = downloadProgress(engine)
        let failure = downloadFailure(engine)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? OnboardingChrome.accent : Color.white.opacity(0.35))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(engine.title).font(.system(size: 13, weight: .semibold))
                        tagLabel(engine.resourceLabel)
                    }
                    Text(Self.engineLine(engine))
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnboardingChrome.secondary)
                }
                Spacer(minLength: 8)
                if ready {
                    Text("Ready").font(.system(size: 12, weight: .medium)).foregroundStyle(OnboardingChrome.positive)
                } else if progress == nil {
                    HStack(spacing: 8) {
                        Text(Self.bytes(engineSize(engine)))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(OnboardingChrome.secondary)
                        if failure == nil {
                            smallButton("Download") { viewModel.voiceDictation.downloadForFirstUse(engine) }
                        }
                    }
                } else {
                    Text(Self.bytes(engineSize(engine)))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(OnboardingChrome.secondary)
                }
            }
            if let progress {
                HStack(spacing: 10) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(OnboardingChrome.accent)
                    Text("\(Self.bytes(progress.received)) of \(Self.bytes(engineSize(engine)))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(OnboardingChrome.secondary)
                        .fixedSize()
                }
                .padding(.leading, 24)
            }
            if let failure {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(OnboardingChrome.danger)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Download stopped").font(.system(size: 12, weight: .semibold))
                        Text(failure)
                            .font(.system(size: 11.5))
                            .foregroundStyle(OnboardingChrome.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    allowButton("Retry") { viewModel.voiceDictation.downloadModels(for: engine) }
                }
                .padding(10)
                .background(OnboardingChrome.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(OnboardingChrome.danger.opacity(0.3))
                }
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { settings.voiceDictationEngine = engine }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func engineLine(_ engine: VoiceDictationEngine) -> String {
        switch engine {
        case .parakeetS1: "English, best quality. Removes fillers and false starts."
        case .whisperTurbo, .cohereTranscribe: "Many languages. Hears which one you speak."
        case .whisperBase, .whisperTiny: "Small download. Good for clear speech."
        }
    }

    private func engineSize(_ engine: VoiceDictationEngine) -> Int64 {
        engine.requiredModels.reduce(0) { $0 + VoiceDictationModelManifest.descriptor(for: $1).totalBytes }
    }

    private func downloadProgress(_ engine: VoiceDictationEngine) -> (fraction: Double, received: Int64)? {
        let store = viewModel.voiceDictation.modelStore
        var received: Int64 = 0
        var active = false
        for model in engine.requiredModels {
            let size = VoiceDictationModelManifest.descriptor(for: model).totalBytes
            switch store.state(of: model) {
            case let .downloading(_, bytes):
                received += bytes
                active = true
            case .verifying:
                received += size
                active = true
            case .downloaded:
                received += size
            default:
                break
            }
        }
        guard active else { return nil }
        let total = max(engineSize(engine), 1)
        return (min(Double(received) / Double(total), 1), received)
    }

    private func downloadFailure(_ engine: VoiceDictationEngine) -> String? {
        let store = viewModel.voiceDictation.modelStore
        for model in engine.requiredModels {
            if case let .failed(reason) = store.state(of: model) { return reason }
        }
        return nil
    }

    private func quillStatus(_ engine: VoiceDictationEngine) -> String? {
        if viewModel.voiceDictation.modelStore.isReady(engine) { return "\(engine.title) ready" }
        if let progress = downloadProgress(engine) { return "Downloading \(Int(progress.fraction * 100))%" }
        if downloadFailure(engine) != nil { return "Download stopped" }
        return nil
    }

    private var quillNote: String? {
        let store = viewModel.voiceDictation.modelStore
        let starter = VoiceDictationEngine.whisperBase
        let waiting = VoiceDictationEngine.offered.first { $0 != starter && (downloadProgress($0) != nil || downloadFailure($0) != nil) }
        guard let waiting else { return nil }
        if downloadFailure(waiting) != nil, store.isReady(starter) {
            return "Whisper Base is ready, so Quill works now. You can also retry later from Settings › Quill."
        }
        guard settings.voiceDictationEngine == starter else { return nil }
        return "Whisper Base (\(Self.bytes(engineSize(starter)))) downloads too, so you can dictate now. Quill switches to \(waiting.title) when it's ready."
    }

    private var sketch: some View {
        room(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quill, optional").font(.system(size: 11.5)).foregroundStyle(OnboardingChrome.secondary)
                heading("Sketch", "Talk while you draw on the screen. Good for showing an agent or a teammate exactly what you mean.")
            }
            SketchArt()
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(spacing: 0) {
                row("display", "Screen Recording", detail: "So Sketch can capture what you marked. macOS may ask you to reopen Nano.") {
                    if flow.screenRecordingGranted { allowedLabel } else { allowButton("Allow", action: flow.requestScreenRecording) }
                }
                divider
                row(
                    "keyboard",
                    "Start and finish with \(settings.voiceDictationSketchHotkey.displayString)",
                    detail: "Hold \(settings.voiceDictationSketchDrawKey.symbol) to draw. Change both in Settings › Quill."
                ) { EmptyView() }
            }
        } footer: {
            HStack(spacing: 8) {
                secondaryButton("Back", action: flow.back)
                Spacer()
                secondaryButton("Skip Sketch", action: flow.turnOffSketchAndContinue)
                primaryButton("Next") {
                    settings.voiceDictationSketchEnabled = true
                    flow.next()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var cue: some View {
        let hotkey = settings.cueQuickCaptureHotkey.displayString
        return room(spacing: 16) {
            heading("Cue", "A to-do list for each project, one hover away.")
            CueArt(hotkey: hotkey)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                numbered(1, "Press \(hotkey) anywhere and type the to-do. Text you have selected comes with it.")
                numbered(2, "Keep a list for each project in its own folder.")
                numbered(3, "Hover the \(flow.word) to see what's next and tick it off.")
            }
            VStack(spacing: 0) {
                row(
                    "list.bullet",
                    "Sync with Reminders",
                    tag: "Optional",
                    detail: "Lets Cue sync a Reminders list, so your to-dos reach your iPhone. Pick the list in Settings › Cue."
                ) {
                    if flow.remindersGranted { allowedLabel } else { allowButton("Allow", action: flow.requestReminders) }
                }
                divider
                row(
                    "accessibility",
                    "Accessibility",
                    tag: "Optional",
                    detail: "Lets a new to-do start with the text you have selected. The shortcut works without it."
                ) {
                    if flow.accessibilityTrusted { allowedLabel } else { allowButton("Allow", action: flow.requestAccessibility) }
                }
            }
        } footer: {
            navigation()
        }
    }

    private func numbered(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.system(size: 12).monospacedDigit()).foregroundStyle(OnboardingChrome.tertiary)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var mixer: some View {
        let store = viewModel.mixerStore
        return room(spacing: 16) {
            heading("Mixer", "Turn one app down without touching the rest. Quiet a call, keep your music.")
            MixerArt()
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(spacing: 0) {
                row(
                    "speaker.wave.2",
                    "System audio",
                    detail: store.error ?? "Mixer needs it to change each app's volume. macOS calls it audio recording. Nano never saves any sound."
                ) {
                    if store.isConfigured {
                        allowedLabel
                    } else {
                        allowButton(store.error == nil ? "Allow" : "Try again", action: flow.connectMixer)
                    }
                }
                if settings.mixerMicMuteHotkeyEnabled {
                    divider
                    row(
                        "mic.slash",
                        "Mute your mic with \(settings.mixerMicMuteHotkey.displayString)",
                        detail: "Works in any app. The \(flow.word) shows when you're muted."
                    ) { EmptyView() }
                }
            }
        } footer: {
            navigation()
        }
    }

    private var dashboard: some View {
        room(spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                heading("Dashboard", "This is what opens when you hover the \(flow.word). Drag to put what you use most first.")
                Spacer(minLength: 0)
                miniVideo("dashboard", label: nil)
            }
            panel {
                DashboardEditor(settings: settings, viewModel: viewModel, libraryColumns: 3)
                    .padding(12)
            }
            if let current = flow.currentPermission {
                permissionQueue(current)
                    .transition(.opacity)
            }
        } footer: {
            navigation()
        }
    }

    private func permissionQueue(_ current: (feature: OnboardingFeature, kind: NanoPermissionKind)) -> some View {
        let pending = flow.pendingPermissions
        let position = (pending.firstIndex { $0.kind == current.kind } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("Access, one at a time")
                Spacer()
                Text("\(position) of \(pending.count)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(OnboardingChrome.secondary)
            }
            HStack(spacing: 12) {
                iconTile(current.kind.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.kind.title).font(.system(size: 13, weight: .semibold))
                    Text(permissionWhy(current.kind))
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingChrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                smallButton("Not now") { flow.deferPermission(current.kind) }
                allowButton("Allow") { flow.requestPermission(current.kind) }
            }
            divider
            HStack(spacing: 6) {
                ForEach(pending, id: \.kind) { item in
                    Text(item.kind.title)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .foregroundStyle(item.kind == current.kind ? .black : OnboardingChrome.secondary)
                        .background(item.kind == current.kind ? OnboardingChrome.text : Color.white.opacity(0.08), in: Capsule())
                }
                Spacer()
                Text("Only for widgets you added").font(.system(size: 11)).foregroundStyle(OnboardingChrome.tertiary)
            }
        }
        .padding(14)
        .background(OnboardingChrome.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func permissionWhy(_ kind: NanoPermissionKind) -> String {
        switch kind {
        case .calendar: "Shows your next events. Nano reads them on this Mac only."
        case .location: "So Weather shows where you are. Or pick a city in Settings."
        case .camera: "The camera turns on only while you look at it. Nothing is recorded."
        case .automation: "To play, pause and skip, Nano needs to control Music and Spotify."
        default: kind.detail
        }
    }

    private var summary: some View {
        let missing = flow.missingPermissions
        let quillEngine = settings.voiceDictationEngine
        let quillDownload = flow.picks.contains(.quill) ? downloadProgress(quillEngine) : nil
        return room(spacing: 18) {
            heading("You're set.", "Here's what's on. Hover the \(flow.word) anytime, and change anything in Settings.")
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("On")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
                    ForEach(flow.enabledSummary, id: \.self) { item in
                        Label(item, systemImage: "checkmark")
                            .font(.system(size: 12.5))
                            .labelStyle(CheckLabelStyle())
                    }
                }
            }
            if !missing.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("Still needs access")
                    VStack(spacing: 0) {
                        ForEach(Array(missing.enumerated()), id: \.element) { index, kind in
                            if index > 0 { divider }
                            row(kind.symbol, kind.title, detail: kind.detail) {
                                allowButton("Allow") { flow.allow(kind) }
                            }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if let quillDownload {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Quill download").font(.system(size: 12.5, weight: .semibold))
                            Spacer()
                            Text("\(Int(quillDownload.fraction * 100))%")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(OnboardingChrome.secondary)
                        }
                        ProgressView(value: quillDownload.fraction).progressViewStyle(.linear).tint(OnboardingChrome.accent)
                        Text("\(quillEngine.title). It keeps going after setup.")
                            .font(.system(size: 11))
                            .foregroundStyle(OnboardingChrome.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OnboardingChrome.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Open at login").font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        toggle("Open at login", isOn: Binding(
                            get: { viewModel.loginItem.isEnabled || viewModel.loginItem.needsApproval },
                            set: { viewModel.loginItem.setEnabled($0) }
                        ))
                    }
                    Text(viewModel.loginItem.isEnabled ? "Nano starts with your Mac." : "You open Nano yourself after a restart.")
                        .font(.system(size: 11))
                        .foregroundStyle(OnboardingChrome.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OnboardingChrome.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } footer: {
            HStack(spacing: 8) {
                secondaryButton("Back", action: flow.back)
                Spacer()
                secondaryButton("Open Settings") { flow.finish(openingSettings: true) }
                primaryButton("Start using Nano") { flow.finish() }
                    .keyboardShortcut(.defaultAction)
            }
            Text(Self.supportLine)
                .font(.system(size: 11.5))
                .foregroundStyle(OnboardingChrome.tertiary)
                .tint(OnboardingChrome.text)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
        }
        .onAppear {
            flow.refreshSystemState()
            viewModel.loginItem.refresh()
        }
    }

    /// What a step says scrolls when the screen is short; its buttons stay put.
    private func room<Body: View, Footer: View>(
        spacing: CGFloat,
        @ViewBuilder _ body: () -> Body,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        let chrome: CGFloat = flow.step == .resume ? 54 : 92
        return OnboardingRoomLayout(limit: flow.maxWindowHeight - chrome, spacing: spacing) {
            OnboardingScrollingBody {
                VStack(alignment: .leading, spacing: spacing) { body() }
            }
            VStack(alignment: .leading, spacing: 0) { footer() }
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.3)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(OnboardingChrome.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(OnboardingChrome.tertiary)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .background(OnboardingChrome.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.05)) }
    }

    private func miniVideo(_ name: String, label: String?) -> some View {
        ZStack(alignment: .bottomLeading) {
            OnboardingVideo(name: name, compact: true)
            if let label {
                Text(label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(6)
            }
        }
        .frame(width: 156, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func iconTile(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(OnboardingChrome.secondary)
            .frame(width: 26, height: 26)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func tagLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(OnboardingChrome.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func row<Trailing: View>(
        _ symbol: String,
        _ title: String,
        tag: String? = nil,
        detail: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            iconTile(symbol)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let tag {
                        Text(tag).font(.system(size: 11)).foregroundStyle(OnboardingChrome.tertiary)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnboardingChrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            trailing()
        }
        .padding(.vertical, 10)
    }

    private func switchRow(title: String, detail: String?, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(OnboardingChrome.secondary)
                }
            }
            Spacer()
            toggle(title, isOn: isOn)
        }
        .padding(.vertical, 10)
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .labelsHidden()
            .toggleStyle(OnboardingSwitchStyle())
    }

    private func deniedCard(symbol: String, title: String, detail: String, path: String, anchor: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnboardingChrome.danger)
                .frame(width: 26, height: 26)
                .background(OnboardingChrome.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingChrome.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(path).font(.system(size: 11)).foregroundStyle(OnboardingChrome.tertiary)
                    HStack(spacing: 8) {
                        NanoMark().frame(width: 16, height: 16)
                        Text("Nano").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Capsule().fill(Color.white.opacity(0.18)).frame(width: 26, height: 15)
                            .overlay(alignment: .leading) { Circle().fill(.white).frame(width: 11).padding(2) }
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack(spacing: 10) {
                    allowButton("Open System Settings") { NanoPrivacySettings.open(anchor) }
                    Text("Nano notices the change by itself.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OnboardingChrome.secondary)
                }
            }
        }
        .padding(14)
        .background(OnboardingChrome.danger.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(OnboardingChrome.danger.opacity(0.28)) }
    }

    private var allowedLabel: some View {
        Label("Allowed", systemImage: "checkmark")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(OnboardingChrome.positive)
            .fixedSize()
    }

    private func allowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .foregroundStyle(.black)
                .background(OnboardingChrome.text, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .fixedSize()
        }
        .buttonStyle(OnboardingPress())
    }

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(OnboardingChrome.quiet, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .fixedSize()
        }
        .buttonStyle(OnboardingPress())
    }

    private func navigation(trailingNote: String? = nil) -> some View {
        HStack(spacing: 10) {
            secondaryButton("Back", action: flow.back)
            Spacer()
            if let trailingNote {
                Text(trailingNote).font(.system(size: 11.5)).foregroundStyle(OnboardingChrome.secondary)
            }
            primaryButton("Next", action: flow.next)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 2)
    }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(height: 32)
                .foregroundStyle(enabled ? .black : OnboardingChrome.tertiary)
                .background(
                    enabled ? OnboardingChrome.text : Color.white.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
        }
        .buttonStyle(OnboardingPress())
        .disabled(!enabled)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(OnboardingChrome.quiet, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(OnboardingPress())
    }

    private func segmented<Value: Hashable>(
        _ values: [Value],
        selection: Value,
        title: @escaping (Value) -> String,
        pick: @escaping (Value) -> Void
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(values, id: \.self) { value in
                let selected = value == selection
                Button { pick(value) } label: {
                    Text(title(value))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 11)
                        .frame(height: 24)
                        .foregroundStyle(selected ? .black : Color(white: 0.85))
                        .background(selected ? OnboardingChrome.text : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private static var supportLine: AttributedString {
        var line = AttributedString("Nano is free and open source. If it helps you, ")
        var link = AttributedString("buy me a coffee")
        link.link = NanoLinks.tip
        link.underlineStyle = .single
        line.append(link)
        line.append(AttributedString("."))
        return line
    }

    private static func display(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

private struct CheckLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(OnboardingChrome.positive)
            configuration.title
        }
    }
}

private struct QuillTryField: View {
    let hotkey: String
    let holds: Bool
    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            TextField(holds ? "Hold the shortcut, speak, let go. Your words land here." : "Press the shortcut, speak, press it again. Your words land here.", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            Text(hotkey)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(OnboardingChrome.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)) }
    }
}

private struct PlacementGlyph: View {
    let placement: IslandPlacement

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if placement == .attached {
                UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 18, height: 5)
            } else {
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 18, height: 5)
                    .padding(.top, 5)
            }
        }
    }
}

private struct OnboardingPlaceholder: View {
    let symbol: String
    let line: String

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.1, blue: 0.22), Color(white: 0.05)],
                startPoint: .top, endPoint: .center
            )
            UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                .fill(.black)
                .frame(width: 90, height: 12)
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(line).font(.system(size: 12)).foregroundStyle(OnboardingChrome.secondary)
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, 50)
        }
    }
}

private struct CueArt: View {
    let hotkey: String

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.05)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("nano")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Color.white.opacity(0.12), in: Capsule())
                    Spacer()
                    Text("3 left").font(.system(size: 10.5)).foregroundStyle(OnboardingChrome.secondary)
                }
                item("Write the release notes", done: false)
                item("Record the Mixer clip", done: false)
                item("Answer the GitHub issue about AirPods", done: false)
                item("Fix the floating island gap", done: true)
            }
            .padding(14)
            .frame(width: 270)
            .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Text(hotkey).font(.system(size: 10.5, weight: .semibold))
                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1, height: 10)
                    Text("\"Remind me to tag the release\"").font(.system(size: 10.5))
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(.black, in: Capsule())
                .padding(.bottom, 12)
            }
        }
    }

    private func item(_ title: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(done ? OnboardingChrome.accent : Color.white.opacity(0.5))
            Text(title)
                .font(.system(size: 11))
                .strikethrough(done)
                .foregroundStyle(done ? OnboardingChrome.tertiary : OnboardingChrome.text)
        }
    }
}

private struct MixerArt: View {
    private let apps: [(String, Double?)] = [("Music", 0.78), ("Zoom", 0.35), ("Safari", 0.6), ("Slack", nil)]

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.05)
            VStack(spacing: 10) {
                ForEach(apps, id: \.0) { app in
                    HStack(spacing: 12) {
                        Text(app.0).font(.system(size: 11, weight: .medium)).frame(width: 44, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.12))
                                Capsule().fill(.white).frame(width: proxy.size.width * (app.1 ?? 0))
                            }
                        }
                        .frame(height: 4)
                        Text(app.1.map { "\(Int($0 * 100))" } ?? "Off")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(OnboardingChrome.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                    .opacity(app.1 == nil ? 0.45 : 1)
                }
            }
            .padding(16)
            .frame(width: 280)
            .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
            VStack {
                Spacer()
                Text("Every app that plays sound gets its own slider")
                    .font(.system(size: 11))
                    .foregroundStyle(OnboardingChrome.secondary)
                    .padding(.bottom, 12)
            }
        }
    }
}

private struct SketchArt: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.12, green: 0.1, blue: 0.22), Color(white: 0.05)], startPoint: .top, endPoint: .center)
            UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8)
                .fill(.black)
                .frame(width: 90, height: 12)
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(Color.white.opacity(0.18)).frame(width: 100, height: 6)
                Capsule().fill(Color.white.opacity(0.1)).frame(width: 200, height: 5)
                Capsule().fill(Color.white.opacity(0.1)).frame(width: 170, height: 5)
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.14)).frame(width: 56, height: 18)
                        .overlay {
                            Ellipse()
                                .stroke(Color.orange, lineWidth: 1.6)
                                .frame(width: 80, height: 34)
                        }
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)).frame(width: 56, height: 18)
                }
                .padding(.top, 6)
            }
            .padding(16)
            .frame(width: 270, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
            .padding(.top, 40)
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("\"Make this button the main one\"").font(.system(size: 10.5))
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(.black, in: Capsule())
                .padding(.bottom, 12)
            }
        }
    }
}

/// Blurs the desktop behind the window. SwiftUI materials only blur what is
/// inside the window, and this one is transparent.
private struct OnboardingBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct OnboardingPress: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct OnboardingVideo: View {
    let name: String
    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paused: Bool?

    private var isPaused: Bool { paused ?? reduceMotion }

    var body: some View {
        ZStack {
            OnboardingClip(name: name, playing: !isPaused)
            if isPaused {
                Image(systemName: "play.fill")
                    .font(.system(size: compact ? 11 : 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: compact ? 28 : 40, height: compact ? 28 : 40)
                    .background(.black.opacity(0.55), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { paused = !isPaused }
        .accessibilityElement()
        .accessibilityLabel(isPaused ? "Play the clip" : "Pause the clip")
        .accessibilityAddTraits(.isButton)
        .animation(.easeOut(duration: 0.15), value: isPaused)
    }
}

struct OnboardingClip: NSViewRepresentable {
    let name: String
    var playing = true

    static func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "mp4", subdirectory: "Onboarding")
    }

    func makeNSView(context: Context) -> ClipView {
        let view = ClipView()
        view.load(Self.url(name), plays: playing)
        return view
    }

    func updateNSView(_ view: ClipView, context: Context) {
        view.setPlaying(playing)
    }

    static func dismantleNSView(_ view: ClipView, coordinator: Void) {
        view.stop()
    }

    final class ClipView: NSView {
        private let playerLayer = AVPlayerLayer()
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func load(_ url: URL?, plays: Bool) {
            guard let url else { return }
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
            playerLayer.player = queue
            player = queue
            if plays { queue.play() }
        }

        func setPlaying(_ playing: Bool) {
            if playing { player?.play() } else { player?.pause() }
        }

        func stop() {
            player?.pause()
            looper = nil
            playerLayer.player = nil
            player = nil
        }

        override func layout() {
            super.layout()
            let height = max(bounds.height, bounds.width * 9 / 16)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
            CATransaction.commit()
        }
    }
}

/// A step's body over its buttons. The body gets what is left once the buttons
/// fit under the limit, and never more than it asks for.
private struct OnboardingRoomLayout: Layout {
    let limit: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let heights = heights(width: proposal.width, subviews: subviews)
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }

    private func heights(width: CGFloat?, subviews: Subviews) -> [CGFloat] {
        guard let body = subviews.first else { return [] }
        let fixed = subviews.dropFirst().map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let room = limit - fixed.reduce(0, +) - spacing * CGFloat(fixed.count)
        let wanted = body.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return [min(wanted, max(room, 120))] + fixed
    }
}

/// Scrolls only when it was given less height than its content needs. Until
/// then nothing is clipped, so shadows and edge fades show.
private struct OnboardingScrollingBody<Content: View>: View {
    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    var body: some View {
        let overflows = contentHeight > shownHeight + 1
        ScrollView(.vertical) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in contentHeight = height }
                    }
                }
        }
        .scrollIndicators(overflows ? .automatic : .never)
        .scrollClipDisabled(!overflows)
        .scrollBounceBehavior(.basedOnSize)
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in shownHeight = height }
            }
        }
    }
}

/// The system switch turns grey whenever the onboarding window isn't key,
/// which is most of the time, so "on" looked like "off".
private struct OnboardingSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? OnboardingChrome.accent : Color.white.opacity(0.16))
            .frame(width: 32, height: 18)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .animation(.snappy(duration: 0.18), value: configuration.isOn)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
    }
}
