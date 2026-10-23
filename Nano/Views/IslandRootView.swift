import AppKit
import SwiftUI

struct IslandRootView: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            VStack(spacing: IslandChromeMetrics.gap) {
                island
                if let docked = viewModel.dockedNotification {
                    dockedHUD(docked)
                        .transition(.asymmetric(
                            insertion: .offset(y: -10).combined(with: .opacity),
                            removal: .offset(y: -6).combined(with: .opacity)
                        ))
                } else if viewModel.phase.showsChrome {
                    chromeIsland
                        .transition(.asymmetric(
                            insertion: .offset(y: -10).combined(with: .opacity),
                            removal: .offset(y: -6).combined(with: .opacity)
                        ))
                }
            }
            .animation(
                NanoMotion.chromeSpring(
                    dropping: viewModel.phase.isExpanded,
                    reduceMotion: reduceMotion
                ),
                value: viewModel.phase
            )
            .animation(
                NanoMotion.chromeSpring(dropping: true, reduceMotion: reduceMotion),
                value: viewModel.dockedNotification?.id
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The panel sits in the menu-bar / notch safe area. If SwiftUI insets
        // this view, the drawn island drifts off the AppKit hit path.
        .ignoresSafeArea()
        // Every animated component reads this instead of running at its design
        // rate unconditionally.
        .environment(\.nanoMotionBudget, viewModel.motionBudget)
    }

    private var island: some View {
        GeometryReader { proxy in
            ZStack {
                IslandSurfaceBackground(
                    appearance: settings.appearance,
                    blackOpacity: settings.blackOpacity,
                    glassIntensity: settings.blurIntensity,
                    gradientMidpoint: settings.gradientMidpoint,
                    surfaceColor: settings.surfaceColor,
                    glassTintColor: settings.glassTintColor,
                    cornerRadius: cornerRadius
                )
                .contentShape(Rectangle())

                if viewModel.phase.showsDashboard {
                    ZStack {
                        Group {
                            if let module = viewModel.displayedModule {
                                IslandModuleView(
                                    module: module,
                                    settings: settings,
                                    viewModel: viewModel
                                )
                            } else {
                                NanoDashboardView(
                                    settings: settings,
                                    viewModel: viewModel
                                )
                            }
                        }
                        .id(viewModel.displayedModule)
                        // Swapping modules: the old one leaves at once and the
                        // new one settles in while the shell resizes for it.
                        .transition(.nanoSwap(anchor: .top, delay: 0.1, reduceMotion: reduceMotion))
                    }
                    .padding(.top, viewModel.notchContentClearance)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, settings.placement == .attached ? notchFlare : 0)
                    // In: once the shell has room, so nothing is clipped while
                    // it grows. Out: gone before the shell has shrunk much.
                    .transition(.nanoSwap(anchor: .top, delay: NanoMotion.contentDelay, reduceMotion: reduceMotion))
                } else if viewModel.phase == .transientHUD,
                          let notification = viewModel.notificationCenter.current {
                    IslandNotificationView(
                        notification: notification,
                        settings: settings,
                        viewModel: viewModel
                    )
                    .id(notification.coalesceKey)
                    .padding(.horizontal, settings.placement == .attached ? notchFlare : 0)
                    // The card reveals its own parts; on the way out it fades
                    // instead of vanishing while the shell is still shrinking.
                    .transition(.asymmetric(
                        insertion: .identity,
                        removal: .opacity.animation(NanoMotion.dismiss)
                    ))
                } else if let content = viewModel.onboardingIsland {
                    OnboardingIslandView(
                        content: content,
                        notchClearance: viewModel.notchContentClearance,
                        notchWidth: viewModel.notchWidth
                    )
                    .padding(.horizontal, settings.placement == .attached ? notchFlare : 0)
                    .id(content)
                        .transition(.opacity)
                } else {
                    CompactIslandView(
                        settings: settings,
                        viewModel: viewModel
                    )
                    .padding(.horizontal, settings.placement == .attached ? notchFlare : 0)
                    // Back in once the closing shell is nearly its compact size.
                    .transition(.nanoSwap(scale: 0.96, delay: 0.12, reduceMotion: reduceMotion))
                }
            }
            // The content transitions carry their own timing (see nanoSwap),
            // since animations from outside the GeometryReader don't reach
            // these insertions and removals.
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(width: islandSize.width, height: islandSize.height)
        .clipShape(islandShape)
        .overlay {
            // One persistent outline follows the container through every phase.
            islandShape.stroke(islandBorderColor, lineWidth: 0.8)
            if settings.isEnabled(.voiceDictation) {
                VoiceDictationCancelOutline(
                    controller: viewModel.voiceDictation,
                    shape: islandShape
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            if viewModel.phase == .transientHUD,
               case let .agent(attention) = viewModel.notificationCenter.current?.payload,
               !reduceMotion && (attention.kind == .permission || attention.kind == .question) {
                ProviderNotificationStroke(
                    tint: NSColor(attention.provider?.notificationColor ?? .gray),
                    animated: true,
                    attached: settings.placement == .attached,
                    cornerRadius: cornerRadius,
                    flare: notchFlare,
                    showsBase: false
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.identity)
            }
        }
        .shadow(
            color: .black.opacity(viewModel.phase.isExpanded ? 0.45 : 0.34),
            radius: viewModel.phase.isExpanded ? 16 : 9,
            y: viewModel.phase.isExpanded ? 8 : 4
        )
        .contentShape(islandShape)
        .onExitCommand { viewModel.collapseIncludingPinned() }
        // Order matters: the modifier nearer the frame wins. Opening and
        // closing change the size too, so the phase spring must sit nearer,
        // or every open and close ran on the resize spring. A size change on
        // its own (a module swap, a collapsing section) leaves the phase
        // unchanged and falls through to the resize spring.
        .animation(islandPhaseMotion, value: viewModel.phase)
        .animation(NanoMotion.islandResize(reduceMotion: reduceMotion), value: islandSize)
        .accessibilityElement(children: viewModel.phase.isExpanded ? .contain : .combine)
        .accessibilityLabel(
            viewModel.phase.showsDashboard
                ? "Nano dashboard"
                : viewModel.phase == .transientHUD
                    ? (viewModel.notificationCenter.current?.title ?? "Nano")
                    : "Nano"
        )
    }

    private var chromeIsland: some View {
        let inSession = viewModel.displayedModule == .agents
            && (viewModel.sessionStore.selectedID != nil || viewModel.showsAgentUsageDetail)
        // Agents can be home itself, so an open session or usage view on the
        // dashboard still needs the back button.
        let onDashboard = viewModel.activeModule == nil && !inSession

        return HStack(spacing: IslandChromeMetrics.clusterGap) {
            if settings.isEnabled(.voiceDictation) {
                VoiceDictationChromeSlot(
                    controller: viewModel.voiceDictation,
                    surface: { chromeSurface(cornerRadius: IslandChromeMetrics.height / 2) },
                    borderOpacity: borderOpacity
                )
            }
            IslandChromeBar(
                homeSymbol: inSession ? "chevron.left" : "house.fill",
                homeHelp: inSession ? "Back to sessions" : "Dashboard",
                homeSelected: onDashboard,
                homeEnabled: !onDashboard,
                cueSelected: viewModel.activeModule == .cue,
                mixerSelected: viewModel.activeModule == .mixer,
                onCue: settings.isEnabled(.cue) ? {
                    if viewModel.activeModule == .cue {
                        viewModel.closeModule()
                    } else {
                        viewModel.openModule(.cue)
                    }
                } : nil,
                onMixer: settings.isEnabled(.mixer) ? {
                    if viewModel.activeModule == .mixer {
                        viewModel.closeModule()
                    } else {
                        viewModel.openModule(.mixer)
                    }
                } : nil,
                onHome: {
                    if viewModel.showsAgentUsageDetail {
                        viewModel.setAgentUsageDetail(false)
                    } else if inSession {
                        viewModel.sessionStore.selectedID = nil
                    } else {
                        viewModel.closeModule()
                    }
                }
            )
            .frame(width: IslandChromeMetrics.pillWidth, height: IslandChromeMetrics.height)
            .background { chromeSurface(cornerRadius: IslandChromeMetrics.height / 2) }
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(borderOpacity), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.34), radius: 9, y: 4)

            IslandUtilityBar(isPinned: viewModel.isPinned, onPin: { viewModel.togglePin() })
                .frame(width: IslandChromeMetrics.utilityWidth, height: IslandChromeMetrics.height)
                .background { chromeSurface(cornerRadius: IslandChromeMetrics.height / 2) }
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(borderOpacity), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.34), radius: 9, y: 4)
        }
        // The Quill pill rising in or out moves the other pills over; they
        // slide on the same curve instead of jumping.
        .animation(reduceMotion ? nil : NanoMotion.reveal, value: viewModel.voiceDictation.phase == .idle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Island controls")
    }

    private func dockedHUD(_ notification: IslandNotification) -> some View {
        let size = IslandChromeMetrics.dockedSize(
            for: notification,
            islandWidth: islandSize.width
        )
        return IslandNotificationView(
            notification: notification,
            settings: settings,
            viewModel: viewModel,
            ignoresNotch: true
        )
        .id(notification.coalesceKey)
        .frame(width: size.width, height: size.height)
        .background { chromeSurface(cornerRadius: IslandChromeMetrics.dockedCornerRadius) }
        .clipShape(RoundedRectangle(cornerRadius: IslandChromeMetrics.dockedCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IslandChromeMetrics.dockedCornerRadius, style: .continuous)
                .stroke(.white.opacity(borderOpacity), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.34), radius: 9, y: 4)
        .accessibilityElement(children: .combine)
    }

    private func chromeSurface(cornerRadius: CGFloat) -> some View {
        IslandSurfaceBackground(
            appearance: settings.appearance,
            blackOpacity: settings.blackOpacity,
            glassIntensity: settings.blurIntensity,
            gradientMidpoint: settings.gradientMidpoint,
            surfaceColor: settings.surfaceColor,
            glassTintColor: settings.glassTintColor,
            cornerRadius: cornerRadius
        )
    }

    private var islandSize: CGSize {
        viewModel.preferredSize
    }

    private var islandPhaseMotion: Animation? {
        // Agent and system notifications use the same clean downward spring as
        // hover expansion. They differ in destination size, not motion language.
        if viewModel.phase == .transientHUD {
            guard !reduceMotion else { return nil }
            return NanoMotion.smooth(0.40)
        }
        return NanoMotion.islandSpring(
            dropping: viewModel.phase.isExpanded,
            reduceMotion: reduceMotion
        )
    }

    /// Setup's greeting is a short card, shaped like a HUD.
    private var showsOnboardingIsland: Bool {
        viewModel.phase == .idleCompact && viewModel.onboardingIsland?.isCard == true
    }

    private var cornerRadius: CGFloat {
        IslandHitGeometry.cornerRadius(
            expanded: viewModel.phase.showsDashboard,
            hud: viewModel.phase == .transientHUD || showsOnboardingIsland
        )
    }

    private var islandShape: AnyShape {
        guard settings.placement == .attached else {
            return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }

        return AnyShape(NanoNotchShape(bottomRadius: cornerRadius, flare: notchFlare))
    }

    private var notchFlare: CGFloat {
        IslandHitGeometry.notchFlare(
            expanded: viewModel.phase.showsDashboard,
            hud: viewModel.phase == .transientHUD || showsOnboardingIsland
        )
    }

    private var borderOpacity: Double {
        settings.appearance == .solidBlack ? 0.08 : 0.18
    }

    private var islandBorderColor: Color {
        if viewModel.phase == .transientHUD,
           case let .agent(attention) = viewModel.notificationCenter.current?.payload {
            return (attention.provider?.notificationColor ?? .gray).opacity(0.25)
        }
        return .white.opacity(borderOpacity)
    }
}

struct CompactAgentActivitySummary: Equatable {
    struct ProviderActivity: Identifiable, Equatable {
        let provider: AgentProviderID
        let sessionCount: Int

        var id: AgentProviderID { provider }
    }

    let providers: [ProviderActivity]
    let totalSessions: Int

    static func singleActiveSnapshot(
        snapshots: [AgentProviderSnapshot],
        sessions: [AgentSession],
        enabledProviders: Set<AgentProviderID>
    ) -> AgentProviderSnapshot? {
        // Use the same session authority as the multi-session count. The
        // provider's latest completion can belong to a different task.
        if let session = sessions.first(where: { $0.isActive && enabledProviders.contains($0.provider) }) {
            if let snapshot = snapshots.first(where: { $0.id == session.provider && $0.isActive }) {
                return snapshot
            }
            return AgentProviderSnapshot(
                id: session.provider, isConfigured: true, isActive: true,
                projectName: session.projectName, lastActivityAt: session.lastActivityAt,
                usage: [], usageMessage: nil
            )
        }
        return snapshots.first { $0.isActive && enabledProviders.contains($0.id) }
    }

    static func make(
        snapshots: [AgentProviderSnapshot],
        sessions: [AgentSession],
        enabledProviders: Set<AgentProviderID>
    ) -> Self? {
        let activeSessions = sessions.filter {
            $0.isActive && enabledProviders.contains($0.provider)
        }
        let sessionCounts = Dictionary(grouping: activeSessions, by: \.provider)
            .mapValues(\.count)
        let snapshotProviders = Set(
            snapshots.lazy
                .filter { $0.isActive && enabledProviders.contains($0.id) }
                .map(\.id)
        )

        let providers: [ProviderActivity] = AgentProviderID.supported.compactMap { provider in
            guard enabledProviders.contains(provider) else { return nil }
            let sessionCount = max(
                sessionCounts[provider, default: 0],
                snapshotProviders.contains(provider) ? 1 : 0
            )
            guard sessionCount > 0 else { return nil }
            return ProviderActivity(provider: provider, sessionCount: sessionCount)
        }
        guard !providers.isEmpty else { return nil }

        return Self(
            providers: providers,
            totalSessions: providers.reduce(0) { $0 + $1.sessionCount }
        )
    }
}

private struct CompactIslandView: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var timer: FocusTimerStore
    @ObservedObject private var media: MediaController
    @ObservedObject private var agents: AgentStatusService
    @ObservedObject private var sessions: AgentSessionStore
    @ObservedObject private var voice: VoiceDictationController
    @ObservedObject private var tray: TrayStore
    @ObservedObject private var hooks: AgentHookBridge

    init(settings: NanoSettings, viewModel: IslandViewModel) {
        self.settings = settings
        self.viewModel = viewModel
        _timer = ObservedObject(wrappedValue: viewModel.timerStore)
        _media = ObservedObject(wrappedValue: viewModel.mediaController)
        _agents = ObservedObject(wrappedValue: viewModel.agentService)
        _sessions = ObservedObject(wrappedValue: viewModel.sessionStore)
        _voice = ObservedObject(wrappedValue: viewModel.voiceDictation)
        _tray = ObservedObject(wrappedValue: viewModel.trayStore)
        _hooks = ObservedObject(wrappedValue: viewModel.hookBridge)
    }

    /// Requests an agent is blocked on. Their card can be dismissed by a click
    /// elsewhere; this keeps them in view until they are answered.
    private var waitingRequestCount: Int {
        settings.isEnabled(.agents) ? hooks.pending.count : 0
    }

    /// A dictation in flight outranks everything else on the compact island:
    /// it is the only state the user is actively waiting on.
    private var voiceIsShowing: Bool {
        settings.isEnabled(.voiceDictation) && voice.phase != .idle
    }

    /// With agents running, dictation shares the island instead of taking it:
    /// agents stay on the left and the right-hand badge becomes the recorder,
    /// so neither the work nor the open microphone disappears from view.
    private var voiceSharesWithAgents: Bool {
        guard voiceIsShowing, timer.state == .idle else { return false }
        return agentsAreShowing
    }

    /// Music keeps the left side while a dictation records on the right.
    private var voiceSharesWithMusic: Bool {
        voiceIsShowing && timer.state == .idle && !agentsAreShowing && musicIsPlaying
    }

    private var agentsAreShowing: Bool {
        if let activity = compactAgentActivity, activity.totalSessions > 1 { return true }
        return compactSingleAgent != nil
    }

    /// Stale tracks linger in a deactivated controller, so the module switch
    /// decides as well.
    private var musicIsPlaying: Bool {
        settings.isEnabled(.music) && media.nowPlaying?.isPlaying == true
    }

    /// Playing, or paused recently enough that the cover still holds its place.
    private var musicIsShowing: Bool {
        musicIsPlaying || (settings.isEnabled(.music) && media.nowPlaying != nil && viewModel.holdsPausedMusic)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                leading
            }
            .frame(width: sideZoneWidth, alignment: .leading)
            .clipped()

            Color.clear
                .frame(width: viewModel.notchWidth)

            HStack(spacing: 8) {
                trailing
            }
            .frame(width: sideZoneWidth, alignment: .trailing)
            .clipped()
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.white)
        // The end of a paused track's hold fades out rather than cutting.
        .animation(musicIsShowing ? nil : .easeOut(duration: 0.6), value: musicIsShowing)
    }

    @ViewBuilder
    private var leading: some View {
        if voiceIsShowing, !voiceSharesWithAgents, !voiceSharesWithMusic {
            VoiceDictationCompactLeading(
                controller: voice,
                failureLabelPlacement: voiceFailureLabelPlacement
            )
                .transition(.nanoSwap(anchor: .leading, scale: 0.94, reduceMotion: reduceMotion))
        } else if timer.state != .idle {
            VStack(alignment: .leading, spacing: 0) {
                Text(timer.sessionName.nilIfBlank ?? timer.mode.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Text(timerStateLabel)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }
        } else if let activity = compactAgentActivity, activity.totalSessions > 1 {
            HStack(spacing: 6) {
                CompactAgentLogoGroup(providers: activity.providers)

                Text("\(activity.totalSessions) active")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .transition(.nanoSwap(anchor: .leading, scale: 0.94, reduceMotion: reduceMotion))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(activityAccessibilityLabel(activity))
        } else if let active = compactSingleAgent {
            NanoThinkingOrb(scale: .inline, tint: active.id.accentColor)

            // The orb beside it already says "working"; trailing dots read as
            // a name that had been cut off.
            Text(active.id.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        } else if musicIsShowing {
            // Concentric with the island: its 18pt corner less the 7pt inset.
            NanoArtworkTile(
                image: media.artwork,
                size: 30,
                cornerRadius: 11,
                symbolSize: 13
            )
            .opacity(musicIsPlaying ? 1 : 0.6)
            .animation(.easeOut(duration: 0.3), value: musicIsPlaying)
            .transition(.nanoSwap(anchor: .leading, scale: 0.94, reduceMotion: reduceMotion))

            // A new song widens the island for a moment to say what it is.
            if let peek = viewModel.mediaPeek {
                VStack(alignment: .leading, spacing: 1) {
                    Text(peek.title)
                        .font(.system(size: 11, weight: .semibold))
                    Text(peek.artist)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .lineLimit(1)
                .transition(.nanoSwap(anchor: .leading, reduceMotion: reduceMotion))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Now playing: \(peek.title), \(peek.artist)")
            }
        }
    }

    /// Files waiting in the tray, for the quiet count at rest.
    private var trayCount: Int {
        guard settings.isEnabled(.tray), settings.trayShowsCompactCount else { return 0 }
        return tray.items.count
    }

    /// Open cues in the folder last shown, for the quiet count at rest.
    private var cueCount: Int {
        guard settings.isEnabled(.cue), settings.cueShowsCompactCount else { return 0 }
        return viewModel.cueStore.openCount(in: viewModel.cueStore.scope)
    }

    @ViewBuilder
    private var trailing: some View {
        if voiceSharesWithAgents || voiceSharesWithMusic, voice.phase == .recording {
            HStack(spacing: 6) {
                // Agents hold the left, so music shrinks to its cover here.
                if voiceSharesWithAgents, musicIsPlaying {
                    NanoArtworkTile(image: media.artwork, size: 18, cornerRadius: 5, symbolSize: 8)
                        .transition(.nanoSwap(reduceMotion: reduceMotion))
                }
                VoiceDictationRecordingBadge(controller: voice)
            }
            .transition(.nanoSwap(anchor: .trailing, scale: 0.94, reduceMotion: reduceMotion))
        } else if voiceIsShowing {
            VoiceDictationCompactTrailing(
                controller: voice,
                maxWidth: sideZoneWidth,
                // The left side belongs to the agents or the music while they share.
                failureLabelPlacement: voiceSharesWithAgents || voiceSharesWithMusic
                    ? .trailing
                    : voiceFailureLabelPlacement
            )
                .transition(.nanoSwap(reduceMotion: reduceMotion))
        } else if waitingRequestCount > 0 {
            NanoActivityChip(
                symbol: "exclamationmark.circle.fill",
                text: waitingRequestCount == 1 ? "Needs you" : "\(waitingRequestCount) need you",
                tint: .orange,
                maxWidth: sideZoneWidth
            )
            .transition(.nanoSwap(reduceMotion: reduceMotion))
            .accessibilityLabel(waitingRequestCount == 1
                ? "An agent is waiting for your answer"
                : "\(waitingRequestCount) agents are waiting for your answer")
        } else if timer.state != .idle {
            Text(timer.formattedRemaining)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy(duration: 0.3), value: timer.formattedRemaining)
        } else if agentsAreShowing, musicIsPlaying, let track = media.nowPlaying {
            // Agents on the left, what is playing on the right.
            CompactNowPlayingBadge(artwork: media.artwork, tint: track.player.accentColor)
                .transition(.nanoSwap(anchor: .trailing, scale: 0.94, reduceMotion: reduceMotion))
        } else if let activity = compactAgentActivity, activity.totalSessions > 1,
                  let first = activity.providers.first {
            NanoActivityChip(
                symbol: "sparkle",
                text: "Working",
                tint: first.provider.accentColor,
                rimPalette: NanoActivityChipPalette.multiSession,
                maxWidth: sideZoneWidth
            )
        } else if let active = compactSingleAgent {
            NanoActivityChip(
                symbol: activitySymbol(active),
                text: activityLabel(active),
                tint: active.id.accentColor,
                maxWidth: sideZoneWidth
            )
        } else if musicIsShowing, let track = media.nowPlaying {
            NanoWave(barWidth: 2.5, height: 17, color: track.player.accentColor, isActive: track.isPlaying)
                .transition(.nanoSwap(reduceMotion: reduceMotion))
        } else if cueCount > 0 || trayCount > 0 {
            CompactCountsPill(
                cueCount: cueCount,
                cueHelp: "\(cueCount) open in \(viewModel.cueStore.title(for: viewModel.cueStore.scope))",
                trayCount: trayCount
            )
            .transition(.nanoSwap(reduceMotion: reduceMotion))
            .animation(.snappy(duration: 0.25), value: cueCount > 0)
            .animation(.snappy(duration: 0.25), value: trayCount > 0)
        }
    }

    private var sideZoneWidth: CGFloat {
        let flare: CGFloat = settings.placement == .attached ? 20 : 0
        let usable = viewModel.preferredSize.width - 24 - flare - viewModel.notchWidth
        return max(usable / 2, 60)
    }

    private var voiceFailureLabelPlacement: VoiceDictationFailureLabelPlacement {
        VoiceDictationCompactLayout.failureLabelPlacement(notchWidth: viewModel.notchWidth)
    }

    private var compactAgentActivity: CompactAgentActivitySummary? {
        CompactAgentActivitySummary.make(
            snapshots: agents.snapshots,
            sessions: sessions.sessions,
            enabledProviders: settings.enabledAgentProviders
        )
    }

    private var compactSingleAgent: AgentProviderSnapshot? {
        CompactAgentActivitySummary.singleActiveSnapshot(
            snapshots: agents.snapshots,
            sessions: sessions.sessions,
            enabledProviders: settings.enabledAgentProviders
        )
    }

    private func activityAccessibilityLabel(_ activity: CompactAgentActivitySummary) -> String {
        let providers = activity.providers.map { item in
            item.sessionCount == 1
                ? item.provider.title
                : "\(item.provider.title), \(item.sessionCount) sessions"
        }.joined(separator: ", ")
        return "\(activity.totalSessions) active sessions. \(providers)"
    }

    private func activityLabel(_ snapshot: AgentProviderSnapshot) -> String {
        snapshot.activityDetail ?? "Working"
    }

    private func activitySymbol(_ snapshot: AgentProviderSnapshot) -> String {
        guard let detail = snapshot.activityDetail else { return "sparkle" }

        if detail.hasPrefix("Editing") { return "pencil" }
        if detail.hasPrefix("Running") { return "terminal" }
        if detail.hasPrefix("Reading") { return "doc.text" }
        if detail.hasPrefix("Searching") { return "magnifyingglass" }
        if detail.hasPrefix("Using") { return "wrench.and.screwdriver" }
        if detail.hasPrefix("Writing") { return "text.cursor" }
        if detail.hasPrefix("Delegating") { return "person.2.fill" }
        if detail.hasPrefix("Thinking") { return "brain" }
        return "sparkle"
    }

    private var timerStateLabel: String {
        switch timer.state {
        case .idle: "Ready"
        case .running: "Focus session"
        case .paused: "Paused"
        case .completed: "Time is up"
        }
    }
}

/// Open cues and held files in one capsule, each half named by its icon.
/// One element on the right however many counts there are; the left stays
/// empty at rest.
private struct CompactCountsPill: View {
    let cueCount: Int
    let cueHelp: String
    let trayCount: Int

    var body: some View {
        HStack(spacing: 0) {
            if cueCount > 0 {
                segment(symbol: "checklist", count: cueCount, tint: Color(red: 0.62, green: 0.71, blue: 1.0))
                    .help(cueHelp)
            }
            if cueCount > 0, trayCount > 0 {
                Rectangle()
                    .fill(.white.opacity(0.14))
                    .frame(width: 1, height: 11)
            }
            if trayCount > 0 {
                segment(symbol: "tray.full.fill", count: trayCount, tint: .white.opacity(0.82))
                    .help(trayCount == 1 ? "1 file in the tray" : "\(trayCount) files in the tray")
            }
        }
        .frame(height: 20)
        .background(.white.opacity(0.1), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func segment(symbol: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.3), value: count)
        }
        .padding(.horizontal, 8)
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if cueCount > 0 { parts.append(cueCount == 1 ? "1 open cue" : "\(cueCount) open cues") }
        if trayCount > 0 { parts.append(trayCount == 1 ? "1 file in the tray" : "\(trayCount) files in the tray") }
        return parts.joined(separator: ", ")
    }
}

/// Music playing behind other live work: its cover and pulse, small enough to
/// sit opposite the agents.
private struct CompactNowPlayingBadge: View {
    let artwork: NSImage?
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            NanoWave(barWidth: 2, height: 12, color: tint)
            NanoArtworkTile(image: artwork, size: 20, cornerRadius: 6, symbolSize: 9)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Music playing")
    }
}

struct CompactAgentLogoGroup: View {
    let providers: [CompactAgentActivitySummary.ProviderActivity]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nanoMotionBudget) private var budget
    @State private var hoveredProvider: AgentProviderID?

    private let markSize: CGFloat = 20
    private let overlap: CGFloat = 2
    private let maximumMarks = 4

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(visibleProviders.enumerated()), id: \.element.id) { index, item in
                providerMark(item, index: index)
                    .offset(
                        x: CGFloat(index) * step + hoverOffset(for: item.provider),
                        y: hoveredProvider == item.provider ? -1.5 : 0
                    )
                    .scaleEffect(hoveredProvider == item.provider ? 1.08 : 1)
                    .zIndex(hoveredProvider == item.provider
                        ? 100
                        : Double(visibleProviders.count - index))
                    .onHover { hovering in
                        hoveredProvider = hovering ? item.provider : nil
                    }
                    .help(providerHelp(item))
            }

            if overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize()
                    .offset(x: CGFloat(visibleProviders.count) * step + 2)
            }
        }
        .frame(width: groupWidth, height: markSize + 7, alignment: .leading)
        .animation(
            reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.78),
            value: hoveredProvider
        )
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.22),
            value: providers
        )
    }

    private var visibleProviders: [CompactAgentActivitySummary.ProviderActivity] {
        let limit = providers.count > maximumMarks ? maximumMarks - 1 : maximumMarks
        return Array(providers.prefix(limit))
    }

    private var overflowCount: Int {
        max(providers.count - visibleProviders.count, 0)
    }

    private var step: CGFloat { markSize - overlap }

    private var groupWidth: CGFloat {
        guard !visibleProviders.isEmpty else { return 0 }
        let marks = markSize + CGFloat(visibleProviders.count - 1) * step
        return marks + (overflowCount > 0 ? 18 : 0)
    }

    private func providerMark(
        _ item: CompactAgentActivitySummary.ProviderActivity,
        index: Int
    ) -> some View {
        NanoAgentLogoRippleMark(
            provider: item.provider,
            size: markSize,
            phaseOffset: NanoProviderRipple.itemOffset * Double(index),
            isAnimating: !reduceMotion && !budget.isPaused
        )
            .frame(width: markSize, height: markSize)
            .overlay(alignment: .topTrailing) {
                if item.sessionCount > 1 {
                    Text("\(item.sessionCount)")
                        .font(.system(size: 7, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.95), radius: 1.5)
                        .offset(x: 3, y: -4)
                }
            }
            .contentShape(Rectangle())
    }

    private func hoverOffset(for provider: AgentProviderID) -> CGFloat {
        hoveredProvider == provider ? 2 : 0
    }

    private func providerHelp(
        _ item: CompactAgentActivitySummary.ProviderActivity
    ) -> String {
        item.sessionCount == 1
            ? "\(item.provider.title) · 1 active session"
            : "\(item.provider.title) · \(item.sessionCount) active sessions"
    }
}

private struct NanoAgentLogoRippleMark: NSViewRepresentable {
    let provider: AgentProviderID
    let size: CGFloat
    let phaseOffset: Double
    let isAnimating: Bool

    func makeNSView(context: Context) -> NanoAgentLogoRippleView {
        NanoAgentLogoRippleView()
    }

    func updateNSView(_ nsView: NanoAgentLogoRippleView, context: Context) {
        nsView.configure(
            provider: provider,
            image: provider.brandImage,
            fallbackSymbol: provider.symbol,
            brandScale: provider.brandScale,
            size: size,
            phaseOffset: phaseOffset,
            isAnimating: isAnimating
        )
    }

    static func dismantleNSView(_ nsView: NanoAgentLogoRippleView, coordinator: Void) {
        nsView.stopAnimating()
    }
}

private final class NanoAgentLogoRippleView: NSView {
    private let markLayer = CALayer()

    private var provider: AgentProviderID?
    private var image: NSImage?
    private var fallbackSymbol = "sparkle"
    private var brandScale: CGFloat = 1
    private var markSize: CGFloat = 20
    private var phaseOffset: Double = 0
    private var isAnimating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        markLayer.contentsGravity = .resizeAspect
        markLayer.masksToBounds = false
        markLayer.shadowOpacity = 0
        markLayer.allowsEdgeAntialiasing = true
        layer?.addSublayer(markLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimating()
        } else {
            rebuild()
            applyAnimations()
        }
    }

    override func layout() {
        super.layout()
        rebuild()
        applyAnimations()
    }

    func configure(
        provider: AgentProviderID,
        image: NSImage?,
        fallbackSymbol: String,
        brandScale: CGFloat,
        size: CGFloat,
        phaseOffset: Double,
        isAnimating: Bool
    ) {
        let contentChanged = provider != self.provider
            || size != markSize
            || brandScale != self.brandScale
        let animationChanged = phaseOffset != self.phaseOffset
            || isAnimating != self.isAnimating
        guard contentChanged || animationChanged else { return }

        self.provider = provider
        self.image = image
        self.fallbackSymbol = fallbackSymbol
        self.brandScale = brandScale
        markSize = size
        self.phaseOffset = phaseOffset
        self.isAnimating = isAnimating
        if contentChanged { rebuild() }
        applyAnimations()
    }

    private func rebuild() {
        guard bounds.width > 0, bounds.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let side = min(markSize * brandScale, min(bounds.width, bounds.height) * 1.2)
        markLayer.frame = CGRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        markLayer.contents = resolvedImage()?.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        )
    }

    private func resolvedImage() -> NSImage? {
        if let image { return image }
        let configuration = NSImage.SymbolConfiguration(
            pointSize: markSize * 0.8,
            weight: .semibold
        )
        return NSImage(
            systemSymbolName: fallbackSymbol,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
    }

    private func applyAnimations() {
        markLayer.removeAllAnimations()

        guard isAnimating, window != nil else {
            markLayer.opacity = 1
            markLayer.transform = CATransform3DIdentity
            return
        }

        markLayer.opacity = 0.72
        markLayer.transform = CATransform3DIdentity

        let beginTime = CACurrentMediaTime() + phaseOffset
        addRipple(
            keyPath: "opacity",
            values: NanoProviderRipple.opacity,
            beginTime: beginTime,
            key: "nano.logo.opacity"
        )
        addRipple(
            keyPath: "transform.translation.y",
            values: NanoProviderRipple.translationY,
            beginTime: beginTime,
            key: "nano.logo.lift"
        )
        addRipple(
            keyPath: "transform.scale",
            values: NanoProviderRipple.scale,
            beginTime: beginTime,
            key: "nano.logo.scale"
        )
    }

    private func addRipple(
        keyPath: String,
        values: [NSNumber],
        beginTime: CFTimeInterval,
        key: String
    ) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = NanoProviderRipple.keyTimes
        animation.duration = NanoProviderRipple.duration
        animation.beginTime = beginTime
        animation.repeatCount = .infinity
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
        ]
        animation.fillMode = .backwards
        animation.isRemovedOnCompletion = false
        markLayer.add(animation, forKey: key)
    }

    func stopAnimating() {
        markLayer.removeAllAnimations()
    }
}

private struct NanoDashboardView: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var viewModel: IslandViewModel

    var body: some View {
        let filled = DashboardLayout.filledAreas(settings)
        Group {
            if filled.isEmpty {
                emptyDashboard
            } else {
                DashboardCollapsedGrid(filled: filled) { area, placement in
                    if let module = settings.visibleDashboardFeature(in: area) {
                        DashboardWidget(
                            module: module,
                            slot: placement.slot,
                            widensQuick: placement.widensQuick,
                            settings: settings,
                            viewModel: viewModel
                        ) {
                            viewModel.openModule(module)
                        }
                    }
                }
                .frame(height: DashboardLayout.contentHeight(filled: filled))
            }
        }
        .padding(DashboardLayout.inset)
        .foregroundStyle(.white)
    }

    /// Nothing chosen: one way into the editor, not a box of empty slots.
    private var emptyDashboard: some View {
        VStack(spacing: 10) {
            Text("Your dashboard is empty.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
            Button {
                NotificationCenter.default.post(name: .nanoOpenSettings, object: SettingsDestination.dashboard.rawValue)
            } label: {
                Label("Set up dashboard", systemImage: "square.grid.2x2")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(.white, in: Capsule())
            }
            .buttonStyle(.nanoPress)
        }
        .frame(maxWidth: .infinity)
        .frame(height: DashboardLayout.emptyHeight)
    }
}

struct DashboardCalendarWidget: View {
    @ObservedObject var service: CalendarService
    let isPrimary: Bool
    let openCalendar: () -> Void
    /// Which events this widget shows; the dashboard passes the user's filter.
    var includes: (NanoCalendarEvent) -> Bool = { _ in true }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate = Date()
    @State private var focusedMonth = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date())
    ) ?? Date()
    @State private var isMovingForward = true

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 14), spacing: 2),
        count: 7
    )

    var body: some View {
        Group {
            if isPrimary {
                HStack(spacing: 12) {
                    monthCalendar
                        .frame(width: 205)

                    Rectangle()
                        .fill(.white.opacity(0.10))
                        .frame(width: 1)

                    eventsPane
                }
            } else {
                monthCalendar
            }
        }
        .overlay {
            if service.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var monthCalendar: some View {
        VStack(spacing: 5) {
            calendarHeader
            calendarGrid
        }
        .contentShape(Rectangle())
        .onTapGesture {}
        .overlay {
            NanoScrollCatcher { step in
                moveMonth(by: step)
            }
        }
    }

    private var calendarHeader: some View {
        HStack(spacing: 6) {
            Text(focusedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .id(focusedMonth)
                .transition(.opacity)

            Spacer(minLength: 2)

            navButton(symbol: "chevron.left", label: "Previous month") {
                moveMonth(by: -1)
            }
            navButton(symbol: "chevron.right", label: "Next month") {
                moveMonth(by: 1)
            }
        }
    }

    private func navButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
                .padding(5).contentShape(Rectangle()).padding(-5)
        }
        .buttonStyle(.nanoPress)
        .foregroundStyle(.white.opacity(0.52))
        .help(label)
        .accessibilityLabel(label)
    }

    private var calendarGrid: some View {
        VStack(spacing: 2) {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    headerCell(symbol)
                }
            }

            ZStack(alignment: .top) {
                dayGrid
                    .id(focusedMonth)
                    .transition(monthTransition)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .clipped()
        }
    }

    private var dayGrid: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                if let date {
                    dayCell(date)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 20)
                }
            }
        }
    }

    private var monthTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }

        return .asymmetric(
            insertion: .move(edge: isMovingForward ? .trailing : .leading)
                .combined(with: .opacity),
            removal: .move(edge: isMovingForward ? .leading : .trailing)
                .combined(with: .opacity)
        )
    }

    private func headerCell(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: 7, weight: .semibold))
            .foregroundStyle(.white.opacity(0.34))
            .frame(maxWidth: .infinity, minHeight: 14)
    }

    private func dayCell(_ date: Date) -> some View {
        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
        let isToday = Calendar.current.isDateInToday(date)

        return Button {
            selectedDate = date
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 17, height: 17)
                } else if isToday {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                        .frame(width: 17, height: 17)
                }

                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(
                        isSelected
                            ? Color.black
                            : Color.white.opacity(isToday ? 1 : 0.72)
                    )

                if hasEvent(on: date) {
                    Circle()
                        .fill(isSelected ? Color.black : Color.red)
                        .frame(width: 2.5, height: 2.5)
                        .offset(y: 7)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 20)
        }
        .buttonStyle(.nanoPress)
    }

    private var eventsPane: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(selectedDate.formatted(.dateTime.day().month(.wide).year()))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                Spacer(minLength: 2)

                Button(action: openCalendar) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .padding(3).contentShape(Rectangle()).padding(-3)
                }
                .buttonStyle(.nanoPress)
                .foregroundStyle(.white.opacity(0.62))
                .help("Add Event")
                .accessibilityLabel("Add Event")
            }

            if !service.hasFullAccess {
                VStack(spacing: 5) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 18))
                    Text("Enable Calendar")
                        .font(.system(size: 9, weight: .medium))
                    Text("Open the full view to grant local access.")
                        .font(.system(size: 7))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.38))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedEvents.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 18))
                    Text("Nothing scheduled")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.52))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 5) {
                    ForEach(selectedEvents.prefix(3)) { event in
                        eventRow(event)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func eventRow(_ event: NanoCalendarEvent) -> some View {
        let accent = color(from: event.calendarColorHex)

        return HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)

            Text(event.title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(timeRange(event))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(accent)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            accent.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var selectedEvents: [NanoCalendarEvent] {
        service.events(on: selectedDate).filter(includes)
    }

    private var weekdaySymbols: [String] {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let first = max(Calendar.current.firstWeekday - 1, 0)
        return Array(symbols[first...] + symbols[..<first])
    }

    private var days: [Date?] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: focusedMonth)
        else {
            return []
        }
        let weekday = calendar.component(.weekday, from: focusedMonth)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: focusedMonth)
        }.map(Optional.some)
    }

    private func moveMonth(by offset: Int) {
        guard let month = Calendar.current.date(
            byAdding: .month,
            value: offset,
            to: focusedMonth
        ) else {
            return
        }

        let normalized = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: month)
        ) ?? month

        isMovingForward = offset > 0

        withAnimation(
            reduceMotion ? nil : .easeInOut(duration: NanoMotion.monthSlide)
        ) {
            focusedMonth = normalized
            selectedDate = normalized
        }
    }

    private func hasEvent(on date: Date) -> Bool {
        service.events.contains {
            Calendar.current.isDate($0.startDate, inSameDayAs: date) && includes($0)
        }
    }

    private func timeRange(_ event: NanoCalendarEvent) -> String {
        guard !event.isAllDay else { return "All day" }

        if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
            let start = event.startDate.formatted(date: .omitted, time: .shortened)
            let end = event.endDate.formatted(date: .omitted, time: .shortened)
            return "\(start) – \(end)"
        }

        let start = event.startDate.formatted(.dateTime.month(.abbreviated).day())
        let end = event.endDate.formatted(.dateTime.month(.abbreviated).day())
        return "\(start) – \(end)"
    }

    private func color(from hex: String) -> Color {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
            .scanHexInt64(&value)
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Home, Cue, and Mixer in the main capsule under the island. Settings and Pin
/// share a second capsule beside it.
struct IslandChromeBar: View {
    var homeSymbol = "house.fill"
    var homeHelp = "Dashboard"
    var homeSelected = false
    var homeEnabled = true
    var cueSelected = false
    var mixerSelected = false
    /// Nil hides the Cue button.
    var onCue: (() -> Void)?
    /// Nil hides the Mixer button.
    var onMixer: (() -> Void)?
    let onHome: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            homeItem
            if let onCue {
                chromeItem(symbol: "checklist", selected: cueSelected, help: "Cue", action: onCue)
            }
            if let onMixer {
                chromeItem(symbol: "slider.vertical.3", selected: mixerSelected, help: "Mixer", action: onMixer)
            }
        }
        // Three items fill the pill; fewer sit centered with the same margins.
        .padding(.horizontal, 8)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var homeItem: some View {
        let icon = Image(systemName: homeSymbol)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 32, height: 32)
            .background(.white.opacity(homeSelected ? 0.16 : 0), in: Circle())
            .contentTransition(.symbolEffect(.replace))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: homeSelected)

        if homeEnabled {
            Button(action: onHome) { icon }
                .buttonStyle(.nanoPress)
                .help(homeHelp)
        } else {
            icon
                .accessibilityLabel("Dashboard")
                .accessibilityAddTraits(.isSelected)
        }
    }

    private func chromeItem(
        symbol: String,
        selected: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.white.opacity(selected ? 0.16 : 0), in: Circle())
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selected)
        }
        .buttonStyle(.nanoPress)
        .help(help)
        // Without this VoiceOver reads the symbol's name ("Checklist With Checkmarks").
        .accessibilityLabel(help)
    }
}

/// Settings and Pin in the second chrome capsule. The pin's fill already shows
/// state, so neither item ever draws a selected background.
private struct IslandUtilityBar: View {
    let isPinned: Bool
    let onPin: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NotificationCenter.default.post(name: .nanoOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.nanoPress)
            .help("Settings")
            .accessibilityLabel("Settings")

            Button(action: onPin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.nanoPress)
            .help(isPinned ? "Unpin island" : "Pin island")
            .accessibilityLabel(isPinned ? "Unpin island" : "Pin island")
        }
        .padding(.horizontal, 8)
        .foregroundStyle(.white)
    }
}

struct IslandSurfaceBackground: View {
    let appearance: IslandAppearance
    let blackOpacity: Double
    let glassIntensity: Double
    let gradientMidpoint: Double
    let surfaceColor: NanoColorValue
    let glassTintColor: NanoColorValue
    let cornerRadius: CGFloat

    var body: some View {
        switch appearance {
        case .solidBlack:
            surfaceColor.color.opacity(blackOpacity)
        case .glass:
            glass
        case .hybrid:
            ZStack {
                glass
                LinearGradient(
                    stops: [
                        .init(color: surfaceColor.color.opacity(blackOpacity), location: 0),
                        .init(
                            color: surfaceColor.color.opacity(blackOpacity * 0.92),
                            location: gradientMidpoint
                        ),
                        .init(color: glassTintColor.color.opacity(0.16), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    @ViewBuilder
    private var glass: some View {
        ZStack {
            if #available(macOS 26.0, *) {
                Color.clear
                    // The outer island alone owns the animated silhouette. Changing the
                    // native glass shape as well crossfades its old backing surface.
                    .glassEffect(.regular, in: .rect(cornerRadius: 0))
                    .opacity(0.34 + (glassIntensity * 0.66))
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.34 + (glassIntensity * 0.66))
            }

            glassTintColor.color
                .opacity(0.035 + (glassIntensity * 0.145))
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct DashboardMusicView: View {
    @ObservedObject var controller: MediaController
    let openModule: () -> Void

    var body: some View {
        expanded
    }

    private func playbackTint(_ track: MediaNowPlaying) -> Color {
        .white.opacity(track.isPlaying ? 0.9 : 0.42)
    }

    private var expanded: some View {
        HStack(spacing: 14) {
            MediaArtwork(
                controller: controller,
                size: 126,
                cornerRadius: 15,
                symbolSize: 34
            )

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        NanoMarqueeText(
                            text: controller.nowPlaying?.title ?? controller.lastPlayed?.title ?? "Nothing playing",
                            fontSize: 15,
                            weight: .semibold,
                            height: 19,
                            autoScrolls: true
                        )
                        .opacity(controller.nowPlaying == nil && controller.lastPlayed != nil ? 0.75 : 1)
                        Text(controller.nowPlaying?.artist ?? controller.lastPlayed?.artist ?? "Songs from Spotify or Apple Music show here")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    if let track = controller.nowPlaying {
                        HStack(spacing: 5) {
                            NanoWave(
                                barWidth: 2,
                                height: 10,
                                color: track.player.accentColor,
                                isActive: track.isPlaying
                            )
                            Text(track.isPlaying ? "Playing" : "Paused")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(playbackTint(track))
                        }
                        .frame(height: 19)
                    } else if controller.automationNote == nil {
                        MediaIdlePill(controller: controller)
                    }
                }

                Spacer(minLength: 0)

                if controller.nowPlaying != nil {
                    controls
                } else if let note = controller.automationNote {
                    // Without Automation nothing can be read, so "last played"
                    // and Resume would both be wrong.
                    Text(note)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange.opacity(0.9))
                        .lineLimit(2)
                } else if let last = controller.lastPlayed {
                    MediaLastPlayedLine(lastPlayed: last)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(height: 126)
        }
    }

    private var controls: some View {
        VStack(spacing: 9) {
            MediaProgressRow(controller: controller)
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))

            HStack(spacing: 22) {
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
                    .font(.system(size: 12))
                    .frame(width: 31, height: 31)
                    .background(.white, in: Circle())
                    .foregroundStyle(.black)
                }
                Button(action: controller.nextTrack) {
                    Image(systemName: "forward.fill")
                }
                Spacer()
            }
            .buttonStyle(.nanoPress)
            .font(.system(size: 13))
        }
        .contentShape(Rectangle())
        .onTapGesture {}
    }

}

extension NanoModuleID {
    var tint: Color {
        switch self {
        case .music: Color(red: 0.95, green: 0.35, blue: 0.55)
        case .calendar: Color(red: 0.98, green: 0.36, blue: 0.36)
        case .weather: Color(red: 0.36, green: 0.74, blue: 0.98)
        case .agents: Color(red: 0.66, green: 0.45, blue: 0.98)
        case .camera: Color(red: 0.30, green: 0.56, blue: 0.98)
        case .timer: Color(red: 0.98, green: 0.60, blue: 0.25)
        case .tray: Color(red: 0.30, green: 0.80, blue: 0.72)
        case .battery: Color(red: 0.38, green: 0.84, blue: 0.46)
        case .volume: Color(red: 0.55, green: 0.60, blue: 0.95)
        case .voiceDictation: Color(red: 0.98, green: 0.45, blue: 0.40)
        case .cue: Color(red: 0.43, green: 0.56, blue: 1.00)
        default: Color(red: 0.68, green: 0.70, blue: 0.76)
        }
    }
}
