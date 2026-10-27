import AppKit
import Combine
import CoreGraphics
import Foundation

enum IslandPhase: Equatable, Sendable {
    case idleCompact
    case hoverDashboard
    case pinnedDashboard
    case dragTarget
    case transientHUD

    var isExpanded: Bool {
        self != .idleCompact
    }

    var showsDashboard: Bool {
        self == .hoverDashboard || self == .pinnedDashboard || self == .dragTarget
    }

    var showsChrome: Bool { showsDashboard }

    var preferredSize: CGSize {
        switch self {
        case .idleCompact:
            CGSize(width: 360, height: 44)
        case .hoverDashboard, .pinnedDashboard, .dragTarget:
            CGSize(width: 760, height: 340)
        case .transientHUD:
            CGSize(width: 540, height: 44)
        }
    }
}

@MainActor
final class IslandViewModel: ObservableObject {
    @Published private(set) var phase: IslandPhase = .idleCompact {
        didSet {
            if phase != .idleCompact, mediaPeek != nil {
                mediaPeekTask?.cancel()
                mediaPeek = nil
            }
            // Cards set aside while the island was busy get their turn.
            if phase == .idleCompact, oldValue != .idleCompact {
                Task { @MainActor [weak self] in
                    guard self?.phase == .idleCompact else { return }
                    self?.notificationCenter.resumeQueue()
                }
            }
            guard phase.isExpanded != oldValue.isExpanded else { return }
            syncVolumeMonitoring()
            sessionStore.isObserved = phase.isExpanded
            if phase.isExpanded, settings.isEnabled(.cue) { cueSync.requestSync() }
        }
    }
    /// Published so the island redraws when the first agent starts or the last one stops.
    @Published private(set) var isAgentActive = false
    @Published private(set) var activeModule: NanoModuleID?

    /// What the expanded island draws. When Agents is the only widget on the
    /// dashboard, home is the Agents module itself: a one-widget dashboard is
    /// the same content in a poorer layout.
    var displayedModule: NanoModuleID? {
        if let activeModule { return activeModule }
        let home = Set(DashboardLayout.filledAreas(settings).compactMap(settings.visibleDashboardFeature(in:)))
        return home == [.agents] ? .agents : nil
    }
    @Published private(set) var showsAgentUsageDetail = false
    /// What a card says when Review reached the app but not the session,
    /// keyed by request. Without it the button looks like it did nothing.
    @Published private(set) var agentJumpNotices: [String: String] = [:]
    private var hoverGraceUntil = Date.distantPast
    @Published private(set) var agentTokenBreakdownHeight: CGFloat = 0
    @Published private(set) var isPinned = false
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 0

    /// False when the island is occluded by another window or the display has
    /// slept. Drives the motion budget — see `motionBudget`.
    @Published private(set) var surfaceIsVisible = true

    let settings: NanoSettings
    lazy var timerStore: FocusTimerStore = {
        let store = FocusTimerStore(defaults: settings.defaults)
        store.didComplete = { [weak self] in
            self?.announceTimerCompletion()
        }
        store.layoutDidChange = { [weak self] in
            self?.objectWillChange.send()
        }
        return store
    }()
    lazy var mixerStore: MixerStore = {
        let store = MixerStore(defaults: settings.defaults)
        store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }.store(in: &cancellables)
        return store
    }()
    lazy var cueStore: CueStore = {
        let store = CueStore()
        // A draft opening or closing resizes the island, and the compact
        // count follows the open cues.
        store.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
        return store
    }()
    lazy var cueSync = CueSyncEngine(store: cueStore) { record in
        switch record.kind {
        case RemindersDestination.kind: RemindersDestination()
        case MCPTaskDestination.kind: MCPTaskDestination.make(record)
        case TodoistDestination.kind: TodoistDestination.make(record)
        default: nil
        }
    }
    let cueQuickCapture = QuickCaptureHotkey(id: 1)
    let mixerMicMuteHotkey = QuickCaptureHotkey(id: 2)
    @Published private(set) var cueQuickCaptureError: String?
    @Published private(set) var mixerMicMuteHotkeyError: String?
    /// The app a shortcut capture came from, reactivated once the cue is saved.
    private var cueReturnApp: NSRunningApplication?
    /// The capture came from double Shift or the shortcut, not the Cue view's
    /// own button, so cancelling it closes the island too.
    private var cueCaptureFromShortcut = false
    lazy var trayStore: TrayStore = {
        let store = TrayStore(storageURL: trayStorageURL)
        // The shelf is as wide as what it holds, so the island resizes with it.
        store.$items
            .map(\.count)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        return store
    }()
    lazy var loginItem = NanoLoginItem()
    lazy var updateChecker = NanoUpdateChecker(settings: settings)
    /// Nil in tests, so they never touch the real tray.
    private let trayStorageURL: URL?
    lazy var calendarService = CalendarService()
    lazy var weatherService: NanoWeatherService = {
        let service = NanoWeatherService()
        service.onResolvedLocation = { [weak self] coordinate in
            guard let self, self.settings.weatherUsesCurrentLocation else { return }
            self.settings.rememberCurrentWeatherLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )
        }
        return service
    }()
    lazy var cameraService = CameraService()
    lazy var mediaController = MediaController()
    /// A new song the compact island is naming for a few seconds.
    @Published private(set) var mediaPeek: MediaNowPlaying?
    private var mediaPeekTask: Task<Void, Never>?
    private var lastAnnouncedTrackID: String?
    /// Music already playing when Nano launches is not a song change.
    private var mediaPeekReadyAt = Date.distantFuture
    static let mediaPeekWidth: CGFloat = 150
    /// A track that was just paused keeps the compact island for a moment
    /// instead of vanishing the instant playback stops.
    @Published private(set) var holdsPausedMusic = false
    private var pausedMusicTask: Task<Void, Never>?
    private var lastTrackWasPlaying = false
    static let pausedMusicHold: Duration = .seconds(10)
    /// What the closed island says while first-run setup is on screen. Setup
    /// talks through the real island instead of describing it.
    @Published var onboardingIsland: OnboardingIslandContent?
    /// Called when the pointer reaches the island while setup's greeting is up.
    var onOnboardingHover: (() -> Void)?
    lazy var systemStatusService = SystemStatusService()
    lazy var voiceDictation: VoiceDictationController = {
        let controller = VoiceDictationController(settings: settings)
        controller.corrections.$corrections
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.offerQuillSuggestionIfDue() }
            }
            .store(in: &cancellables)
        // Which terminal tabs hold an agent: sessions seen in the last half
        // hour, by the app they run in.
        controller.agentSessionNames = { [weak self] in
            guard let self else { return [:] }
            let cutoff = Date().addingTimeInterval(-30 * 60)
            var names: [String: [String]] = [:]
            for session in self.sessionStore.sessions
            where session.isActive || session.lastActivityAt > cutoff {
                guard let host = session.hostBundleID?.lowercased() else { continue }
                names[host, default: []] += [session.projectName, session.title?.text].compactMap { $0 }
            }
            return names
        }
        // Recording state drives the compact island; forward like the others.
        controller.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
        return controller
    }()
    lazy var agentService: AgentStatusService = {
        let service = AgentStatusService()
        service.activityDidChange = { [weak self] active in
            self?.updateAgentActivity(active)
        }
        service.usageDidRefresh = { [weak self] in
            self?.scanTokenLedger()
        }
        return service
    }()
    lazy var modelPricing = NanoModelPricing()
    lazy var tokenLedger = TokenLedger(resolver: modelPricing)
    lazy var sessionStore: AgentSessionStore = {
        let store = AgentSessionStore()
        // The session count drives the module's height, and this view model owns
        // that. Deferred a tick because `objectWillChange` fires before the
        // change lands, so reading the count now would give the old one.
        store.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
        store.discoveryDidChange = { [weak self] isIntegrityScan in
            if isIntegrityScan {
                self?.agentService.refresh()
            } else {
                self?.agentService.refreshLocalActivity()
            }
        }
        store.didFinishSession = { [weak self] session in
            self?.announceAgentCompletion(sessionID: session.id)
        }
        return store
    }()
    lazy var notificationCenter: IslandNotificationCenter = {
        let center = IslandNotificationCenter()
        center.onCurrentChange = { [weak self] in
            self?.syncTransientHUD()
        }
        return center
    }()
    lazy var eventMonitor = SystemEventMonitor()
    lazy var mediaKeyInterceptor: MediaKeyInterceptor = {
        let interceptor = MediaKeyInterceptor()
        interceptor.onNotification = { [weak self] in self?.routeNotification($0) }
        return interceptor
    }()
    lazy var notificationStore = NotificationCenterStore()
    lazy var contactPhotos = ContactPhotoProvider()
    lazy var bannerSuppressor = NativeBannerSuppressor()
    lazy var notificationRouter: NotificationRouter = {
        let router = NotificationRouter()
        router.onSystem = { [weak self] content, key in
            self?.presentSystemNotification(content, coalesceKey: key) ?? false
        }
        router.onRedelivery = { [weak self] content in
            guard let self, self.canPresentSystemNotification(content), self.settings.systemNotificationsHideNativeBanner else { return }
            self.bannerSuppressor.suppress(content)
        }
        router.onMerge = { [weak self] content, key in
            guard let self else { return }
            self.notificationCenter.removeDuplicate(coalesceKey: key)
            if self.canPresentSystemNotification(content), self.settings.systemNotificationsHideNativeBanner {
                self.bannerSuppressor.suppress(content)
            }
            notificationLog.info("merged native notification into agent card: \(content.bundleID, privacy: .public)")
        }
        return router
    }()

    lazy var screenLockMonitor = ScreenLockMonitor()
    lazy var callWatcher = IncomingCallWatcher()
    lazy var cameraMonitor = CameraUseMonitor()

    /// Storm-dropped notifications waiting to be summarised, by app.
    private var stormBuckets: [String: (count: Int, latest: SystemNotificationContent)] = [:]
    private var stormFlush: Task<Void, Never>?
    /// Notifications recorded while asleep or locked, waiting for one card.
    private var catchUpBucket: [SystemNotificationContent] = []
    private var catchUpFlush: Task<Void, Never>?
    private var catchUpSince: Date?
    private var sleepObservers: [NSObjectProtocol] = []
    lazy var hookBridge: AgentHookBridge = {
        let bridge = AgentHookBridge()
        bridge.didSignalActivity = { [weak self] signal in
            guard let self else { return }
            agentService.noteHookActivity(signal)

            let turnEnded: Bool
            if case .turnEnded = signal {
                turnEnded = true
            } else {
                turnEnded = false
            }

            // Hooks are the primary source of session state now: the agent
            // pushes its id, directory and last tool, so the list is built from
            // events rather than rediscovered by parsing transcripts.
            sessionStore.applyHookState(
                bridge.sessionStates,
                refreshT3Runtime: turnEnded
            )
            agentService.applyHookActivity(bridge.sessionStates)
            agentService.noteHookCoverage(coveredProviders(bridge.sessionStates))

            // A finished turn is exactly when new usage lands in the transcript.
            // (see didFinishTurn below for the user-visible half)
            // Without this the ledger only advanced when the module was opened,
            // so "Today" showed whatever was true the last time you looked.
            if turnEnded {
                self.scanTokenLedger()
            }
        }
        // Compact HUD while the island is idle; the full module if the user
        // already has it open. Expanding the dashboard on every prompt made
        // the island unusable, but a blocked agent still has to be seen.
        bridge.didRequestAttention = { [weak self] request in
            self?.presentAgentAttention(request)
        }

        bridge.didFinishTurn = { [weak self] sessionID in
            if let sessionID,
               self?.sessionStore.sessions.first(where: { $0.id == sessionID })?.isActive == true {
                return
            }
            self?.announceAgentCompletion(sessionID: sessionID)
        }

        bridge.didResumeSession = { [weak self] sessionID in
            self?.notificationCenter.dismissPassiveAgentAttention(sessionID: sessionID)
        }

        // Pending request cards add height too.
        bridge.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.syncAgentNotification()
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
        return bridge
    }()

    private var expansionTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var ambientMonitoringStarted = false
    private var enabledModuleSnapshot: Set<NanoModuleID> = []
    private var visibilityObservers: [NSObjectProtocol] = []
    private var screensAsleep = false
    private var cancellables = Set<AnyCancellable>()
    private var lastCompletionAnnouncement: (sessionID: String, at: Date)?
    private var presentationBeforeHUD: (phase: IslandPhase, module: NanoModuleID?)?
    private lazy var moduleRuntimeRegistry = NanoModuleRuntimeRegistry(runtimes: [
        .calendar: NanoModuleRuntime(
            activate: { [weak self] in self?.calendarService.activate() },
            deactivate: { [weak self] in self?.calendarService.deactivate() }
        ),
        .weather: NanoModuleRuntime(
            activate: { [weak self] in self?.refreshWeather() },
            deactivate: { [weak self] in self?.weatherService.cancel() }
        ),
        .camera: NanoModuleRuntime(
            activate: { [weak self] in self?.cameraService.activate() },
            deactivate: { [weak self] in self?.cameraService.deactivate() }
        ),
        .music: NanoModuleRuntime(
            activate: { [weak self] in
                guard let self else { return }
                mediaController.preferredPlayer = settings.preferredMediaPlayer
                mediaController.activate()
            },
            deactivate: { [weak self] in
                guard let self, !ambientMonitoringStarted else { return }
                mediaController.deactivate()
            }
        ),
        .battery: NanoModuleRuntime(
            activate: { [weak self] in self?.systemStatusService.activate() },
            deactivate: { [weak self] in
                guard let self, !ambientMonitoringStarted else { return }
                systemStatusService.deactivate()
            }
        ),
        .volume: NanoModuleRuntime(
            activate: { [weak self] in self?.systemStatusService.activate() },
            deactivate: { [weak self] in
                guard let self, !ambientMonitoringStarted else { return }
                systemStatusService.deactivate()
            }
        ),
        .agents: NanoModuleRuntime(
            activate: { [weak self] in
                guard let self else { return }
                agentService.activate(
                    providers: settings.enabledAgentProviders,
                    usage: settings.usageProviders
                )
                hookBridge.start()
                scanTokenLedger()
            },
            deactivate: { [weak self] in
                guard let self, !ambientMonitoringStarted else { return }
                agentService.deactivate()
            }
        ),
    ])

    /// Frame rate is the single largest cost in an app that mostly sits still,
    /// so it is spent in proportion to the attention the island actually has.
    var motionBudget: NanoMotionBudget {
        guard surfaceIsVisible else { return .hidden }
        return phase.isExpanded ? .full : .ambient
    }

    init(settings: NanoSettings, trayStorageURL: URL? = TrayStore.defaultStorageURL) {
        self.settings = settings
        self.trayStorageURL = trayStorageURL
    }

    var preferredSize: CGSize {
        if phase == .idleCompact,
           let card = onboardingIsland?.cardSize(notchClearance: notchContentClearance) {
            return card
        }
        if phase == .transientHUD, let hud = notificationCenter.current {
            return hud.preferredSize(
                notchWidth: notchWidth,
                attached: settings.placement == .attached,
                notchClearance: notchContentClearance
            )
        }

        guard phase.isExpanded else {
            let compact = phase.preferredSize
            let flare: CGFloat = settings.placement == .attached ? 44 : 0
            let peek: CGFloat = mediaPeek == nil ? 0 : Self.mediaPeekWidth
            guard notchWidth > 0 else {
                return CGSize(width: compact.width + flare + peek, height: compact.height)
            }
            let layoutPadding: CGFloat = settings.placement == .attached ? 44 : 24
            return CGSize(
                width: max(
                    compact.width + flare,
                    notchWidth + compactSideZone * 2 + layoutPadding
                ) + peek,
                height: compact.height
            )
        }
        let baseSize: CGSize
        guard let activeModule = displayedModule else {
            // Empty rows collapse, so the island is only as tall as what's on it.
            let content = DashboardLayout.contentHeight(filled: DashboardLayout.filledAreas(settings))
            return CGSize(width: 760, height: content + DashboardLayout.inset * 2 + notchContentClearance)
        }

        switch activeModule {
        case .calendar:
            baseSize = CGSize(width: 760, height: 340)
        case .music:
            baseSize = CGSize(width: 640, height: 280)
        case .timer:
            baseSize = CGSize(width: 680, height: timerHeight)
        case .camera:
            baseSize = CGSize(width: 680, height: 430)
        case .agents:
            baseSize = CGSize(width: 760, height: agentsHeight)
        case .tray:
            baseSize = Self.traySize(itemCount: trayStore.items.count, isDropping: phase == .dragTarget)
        case .weather:
            baseSize = CGSize(width: 640, height: 340)
        case .cue:
            baseSize = cueStore.draft == nil
                ? CGSize(width: 820, height: 440)
                : CGSize(width: 640, height: cueStore.draft?.images.isEmpty == false ? 332 : 250)
        case .mixer:
            // Mirrors MixerModuleView: 15 padding each side, 30 header + 11
            // spacing, output row, hairline, APPS header, 40pt rows at 2pt
            // spacing, and a microphone row only while an input exists.
            if mixerStore.isConfigured {
                let visible = mixerStore.visibleApps
                let rows = max(1, min(mixerStore.showsAllApps ? 5 : 4, visible.count))
                let errorLines = visible.reduce(0) { $0 + ($1.error == nil ? 0 : 1) }
                let appsHeight = CGFloat(rows) * 40 + CGFloat(max(rows - 1, 0)) * 2
                    + CGFloat(errorLines) * 18
                let storeError: CGFloat = mixerStore.error == nil ? 0 : 26
                let mic: CGFloat = mixerStore.inputName == nil ? 0 : 61
                baseSize = CGSize(width: 620,
                    height: 30 + 41 + 44 + 10 + 1 + storeError + 10 + 18 + 10
                        + appsHeight + mic)
            } else {
                baseSize = CGSize(width: 620, height: 290)
            }
        case .voiceDictation:
            baseSize = CGSize(width: 700, height: 300)
        case .battery, .bluetooth, .volume, .brightness,
             .notificationLabs:
            baseSize = CGSize(width: 580, height: 240)
        }

        return CGSize(
            width: baseSize.width,
            height: baseSize.height + notchContentClearance
        )
    }

    // MARK: Tray shelf

    static let trayPadding: CGFloat = 14
    static let trayItemWidth: CGFloat = 70
    static let trayItemSpacing: CGFloat = 10
    /// The divider and the column of Select all / AirDrop / Clear.
    static let trayToolsWidth: CGFloat = 50
    static let trayMaxWidth: CGFloat = 760

    /// While a file is dragged in, just room for the two drop targets. After,
    /// a shelf as wide as the items, scrolling past what fits.
    static func traySize(itemCount: Int, isDropping: Bool) -> CGSize {
        if isDropping {
            return CGSize(width: 300, height: 100)
        }
        guard itemCount > 0 else {
            return CGSize(width: 420, height: 84)
        }
        let items = CGFloat(itemCount) * trayItemWidth + CGFloat(itemCount - 1) * trayItemSpacing
        let width = items + trayToolsWidth + trayPadding * 2
        return CGSize(width: min(max(width, 300), trayMaxWidth), height: 118)
    }

    /// Sized to what is actually on screen. One session running should not
    /// reserve the height of four, and a blocked agent's card needs its own room.
    private var agentsHeight: CGFloat {
        let cards = min(
            hookBridge.pending.reduce(CGFloat(0)) { $0 + Self.requestCardHeight($1) },
            Self.maxRequestCardsHeight
        )
        // Header + the module's own padding. Chrome is a detached pill
        // under the island, so it is not part of this height.
        let chrome: CGFloat = 104

        // Usage is a purpose-built dashboard rather than a session list, so it
        // owns a stable reading height. The content scrolls only when an
        // unusually large number of models is present.
        if showsAgentUsageDetail {
            // Measured like the session detail: Today with three CLIs is
            // short, Lifetime with a CLI open is tall. Only content taller
            // than the screen scrolls.
            let measured = sessionStore.usageContentHeight
            let content = measured > 0 ? measured : 320
            return min(max(chrome - 16 + content, 180), Self.maximumDetailHeight)
        }

        // The detail view is a fixed composition — identity rail, activity
        // feed, composer — and much taller than any list row. Sizing it as if
        // it were the list is what was clipping it.
        // Sized from what the detail view measured itself to be, so collapsing
        // a section or opening a session with only tools shrinks the window.
        // The spring on `islandSize` in IslandRootView animates the change.
        if sessionStore.selectedSession != nil {
            // The header is part of the measured content now, so the list's
            // chrome allowance overshoots; this trims it back to the gap the
            // detail actually has above and below (measured 2026-09-24).
            let detailChrome: CGFloat = -16
            let measured = sessionStore.detailContentHeight

            // Until the first measurement lands, a middling height avoids a
            // visible jump from zero on the way in.
            let content = measured > 0 ? measured : 260
            // Grows with the session up to a cap well short of the screen;
            // past it the detail scrolls, so one long session does not take
            // over the desktop.
            return min(
                max(chrome + detailChrome + content, 150) + cards,
                min(Self.maximumDetailHeight, Self.sessionDetailHeightCap + cards)
            )
        }

        // Measured, like the detail view. Counting rows and multiplying by a
        // guessed row height meant the constant had to be retuned every time
        // the row's type sizes changed, which happened four times today.
        let measured = sessionStore.listContentHeight
        let content = measured > 0 ? measured : 56
        // The list itself is capped at eight rows; the screen cap only
        // matters when approval cards stack above it.
        return min(max(chrome + content, 150) + cards, max(470, cards > 0 ? Self.maximumDetailHeight : 470))
    }

    /// Grows with the goal list so the list itself never has to scroll. The
    /// panel stage also carries a separate camera-housing allowance.
    private var timerHeight: CGFloat {
        let store = timerStore
        let rows = CGFloat(min(store.tasks.count, Self.maxUnscrolledGoals)) * Self.goalRowHeight
        let goals = store.goalsExpanded ? rows : 0

        let height: CGFloat = switch store.state {
        case .idle:
            259 + (store.goalsExpanded ? 35 : 0) + goals
        case .running, .paused:
            store.tasks.isEmpty ? 226 : 244
        case .completed:
            store.mode == .rest ? 170 : (store.tasks.isEmpty ? 216 : 230 + goals)
        }

        return min(height, 490)
    }

    /// About three approval cards. More than that scroll inside the module.
    static let maxRequestCardsHeight: CGFloat = 480

    /// Estimated height of one pending-request card plus the gap below it:
    /// header, preview, and the button row. Kept in step with
    /// `AgentModuleView.requestCard`.
    static func requestCardHeight(_ request: AgentHookBridge.PendingRequest) -> CGFloat {
        let chrome: CGFloat = 24 + 30 + 11 + 32 + 9
        switch request.preview {
        case .none:
            return chrome
        case let .command(command):
            let lines = min(AgentApprovalCopy.wrappedLineCount(command), 8)
            return chrome + 11 + 20 + CGFloat(lines) * 15
        case let .diff(_, removed, added, _):
            return chrome + 11 + 22 + CGFloat(removed.count + added.count) * 21
        case let .plan(markdown):
            let steps = min(AgentPlanSummary.parse(markdown).steps.count, AgentPlanSummary.visibleSteps)
            return chrome + 11 + 20 + CGFloat(steps) * 18
        case let .arguments(fields):
            return chrome + 11 + 20 + CGFloat(fields.count) * 15
        }
    }

    /// Tallest the session detail may grow: the screen under the island, less
    /// room for the chrome pill below it.
    static var maximumDetailHeight: CGFloat {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = (screen?.visibleFrame.height ?? 900) - 120
        return max(470, available)
    }

    /// Tallest the session detail grows before it scrolls, approval cards
    /// aside.
    static let sessionDetailHeightCap: CGFloat = 560

    static let goalRowHeight: CGFloat = 22
    static let maxUnscrolledGoals = 6

    var compactSideZone: CGFloat { 132 }

    /// Expanded content can span the center, unlike compact and HUD layouts.
    /// Push it below the camera housing only on the display that reports one.
    var notchContentClearance: CGFloat {
        notchWidth > 0 ? notchHeight : 0
    }


    /// Launch, a finished turn, turning a provider on, or a quota refresh.
    /// Walks remaining history until the ledger is caught up.
    func scanTokenLedger() {
        let providers = settings.enabledAgentProviders
        Task {
            await tokenLedger.scanToCompletion(providers: providers)
            sessionStore.applyCursorModels()
        }
    }

    func startAmbientMonitoring() {
        guard !ambientMonitoringStarted else { return }
        ambientMonitoringStarted = true
        startVisibilityTracking()
        syncFeatureMonitoring()
        // The test host is this same app. Bluetooth and Messages observers
        // trip TCC at launch and crash XCTest if they start here.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            startNotificationMonitoring()
        }
        settings.objectWillChange
            .sink { [weak self] _ in
                // NanoSettings publishes before the new value lands. Wait one
                // turn so feature services follow the value the UI now shows.
                Task { @MainActor in
                    await Task.yield()
                    self?.syncFeatureMonitoring()
                    self?.startNotificationMonitoring()
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)
        notificationCenter.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
        mediaPeekReadyAt = Date().addingTimeInterval(3)
        mediaController.$nowPlaying
            .removeDuplicates { $0?.trackID == $1?.trackID && $0?.isPlaying == $1?.isPlaying }
            .sink { [weak self] track in
                Task { @MainActor in self?.mediaTrackDidChange(track) }
            }
            .store(in: &cancellables)
        updateChecker.$status
            .sink { [weak self] status in
                Task { @MainActor in self?.announceUpdateIfNew(status) }
            }
            .store(in: &cancellables)
        checkForNewAgents()
        let agentCheck = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForNewAgents()
                self?.offerQuillSuggestionIfDue()
            }
        }
        RunLoop.main.add(agentCheck, forMode: .common)
    }

    // MARK: Song changes

    private func mediaTrackDidChange(_ track: MediaNowPlaying?) {
        updatePausedMusicHold(track)
        guard let track, track.isPlaying else { return }
        let isNewSong = track.trackID != lastAnnouncedTrackID
        lastAnnouncedTrackID = track.trackID
        guard isNewSong,
              Date() >= mediaPeekReadyAt,
              settings.musicAnnouncesTrackChanges,
              phase == .idleCompact,
              compactIslandShowsMusic
        else { return }

        mediaPeekTask?.cancel()
        mediaPeek = track
        mediaPeekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.mediaPeek = nil
        }
    }

    /// Only a pause starts the hold. A stopped or quit player clears the
    /// track, and resuming or skipping while paused ends the hold.
    private func updatePausedMusicHold(_ track: MediaNowPlaying?) {
        let wasPlaying = lastTrackWasPlaying
        lastTrackWasPlaying = track?.isPlaying == true
        pausedMusicTask?.cancel()
        guard let track, !track.isPlaying, wasPlaying else {
            holdsPausedMusic = false
            return
        }
        holdsPausedMusic = true
        pausedMusicTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pausedMusicHold)
            guard !Task.isCancelled else { return }
            self?.holdsPausedMusic = false
        }
    }

    /// Timers, dictation and agents all outrank music on the compact island.
    private var compactIslandShowsMusic: Bool {
        settings.isEnabled(.music)
            && timerStore.state == .idle
            && voiceDictation.phase == .idle
            && !sessionStore.liveSessions.contains { $0.isActive || $0.subagentsWorking > 0 }
            && !agentService.snapshots.contains(where: \.isActive)
    }

    // MARK: New agents

    /// Set when a new-agent card asks Settings to open the hooks review.
    @Published var requestsHookReview = false

    private static let hookableProviders: Set<AgentProviderID> = [
        .claude, .codex, .gemini, .cursor, .kimi, .pi, .grok, .opencode, .devin,
    ]

    /// Offers to connect any supported agent that appeared since the last look.
    func checkForNewAgents() {
        guard settings.onboardingCompleted, settings.isEnabled(.agents) else { return }
        let present = Set(AgentHookBridge.installationProviders(Self.hookableProviders))
        guard let known = settings.knownAgentInstallations else {
            settings.knownAgentInstallations = present
            return
        }
        let fresh = present.subtracting(known)
        settings.knownAgentInstallations = known.union(present)
        let installed = Set(AgentHookBridge.installedHookConfigURLs().map(\.standardizedFileURL))
        for provider in fresh.sorted(by: { $0.rawValue < $1.rawValue }) {
            let files = AgentHookBridge.installationConfigURLs(for: [provider]).map(\.standardizedFileURL)
            guard !files.allSatisfy(installed.contains) else { continue }
            routeNotification(.agentSetup(provider: provider))
        }
    }

    func connectAgent(_ provider: AgentProviderID) {
        hookBridge.installHooks(for: [provider])
        settings.setAgentProviderEnabled(true, provider: provider)
        agentService.activate(providers: settings.enabledAgentProviders, usage: settings.usageProviders)
        dismissAgentSetup(provider)
    }

    func reviewAgentSetup(_ provider: AgentProviderID) {
        dismissAgentSetup(provider)
        requestsHookReview = true
        NotificationCenter.default.post(name: .nanoOpenSettings, object: SettingsDestination.agents.rawValue)
    }

    func announceUpdateIfNew(_ status: NanoUpdateChecker.Status) {
        guard case let .available(update) = status,
              settings.onboardingCompleted,
              settings.announcedUpdateVersion != update.version
        else { return }
        settings.announcedUpdateVersion = update.version
        routeNotification(.update(update))
    }

    func downloadUpdate() {
        updateChecker.download()
        dismissUpdateNotice()
    }

    func openUpdateNotes(_ update: NanoUpdate) {
        if NanoUpdateChecker.isSecure(update.pageURL) {
            NSWorkspace.shared.open(update.pageURL)
        }
        dismissUpdateNotice()
    }

    // MARK: Quill suggestions

    /// Offers the top thing Quill learned, at most once a day, unless the
    /// user lets Quill apply what it learns by itself.
    func offerQuillSuggestionIfDue(now: Date = Date()) {
        guard settings.onboardingCompleted,
              settings.isEnabled(.voiceDictation),
              settings.voiceDictationLearnsCorrections
        else { return }
        if settings.voiceDictationAppliesLearnedAutomatically {
            voiceDictation.applyLearnedIfAutomatic()
            return
        }
        guard !voiceDictation.phase.isBusy, let next = voiceDictation.correctionSuggestions.first else { return }
        if let asked = settings.quillSuggestionAskedAt, now.timeIntervalSince(asked) < 24 * 60 * 60 { return }
        settings.quillSuggestionAskedAt = now
        routeNotification(.quillSuggestion(next))
    }

    func rememberQuillSuggestion(_ correction: VoiceDictationCorrection) {
        voiceDictation.acceptCorrection(correction)
        dismissQuillSuggestion()
    }

    func ignoreQuillSuggestion(_ correction: VoiceDictationCorrection) {
        voiceDictation.dismissCorrection(correction)
        dismissQuillSuggestion()
    }

    func dismissQuillSuggestion() {
        notificationCenter.dismiss(coalesceKey: IslandNotification.quillSuggestionCoalesceKey)
    }

    func dismissUpdateNotice() {
        notificationCenter.dismiss(coalesceKey: IslandNotification.updateCoalesceKey)
    }

    func dismissAgentSetup(_ provider: AgentProviderID) {
        notificationCenter.dismiss(coalesceKey: "agent-setup:\(provider.rawValue)")
    }

    /// Animation is only worth paying for when something can see it.
    ///
    /// Display sleep is tracked on its own rather than inferred from occlusion:
    /// the island is a `.statusBar` level panel, so no ordinary window can ever
    /// cover it and occlusion alone would report "visible" essentially always.
    private func startVisibilityTracking() {
        let occlusionChanged: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refreshSurfaceVisibility() }
        }
        visibilityObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeOcclusionStateNotification,
                object: nil,
                queue: .main,
                using: occlusionChanged
            )
        )

        let workspace = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [
            (NSWorkspace.screensDidSleepNotification, true),
            (NSWorkspace.screensDidWakeNotification, false),
        ] {
            visibilityObservers.append(
                workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.screensAsleep = asleep
                        self?.refreshSurfaceVisibility()
                    }
                }
            )
        }

        refreshSurfaceVisibility()
    }

    /// Providers that have reported in over hooks recently.
    ///
    /// Coverage expires: an agent uninstalled or a hook config removed should
    /// put its provider back on the polling path rather than leaving Nano
    /// silently blind to it.
    private func coveredProviders(
        _ states: [String: AgentHookBridge.LiveSessionState]
    ) -> Set<AgentProviderID> {
        let cutoff = Date().addingTimeInterval(-15 * 60)
        return Set(
            states.values
                .filter { $0.lastEventAt > cutoff }
                .compactMap { AgentProviderID.fromHook(source: $0.source, providerID: $0.providerID) }
        )
    }

    /// The compact strip never shows a volume readout, so CoreAudio stays
    /// untouched until the island is actually open.
    private func syncVolumeMonitoring() {
        systemStatusService.monitorsVolume = phase.isExpanded && (settings.isEnabled(.volume) || settings.isEnabled(.mixer))
    }

    private func refreshSurfaceVisibility() {
        let occluded = !(NSApp?.occlusionState.contains(.visible) ?? true)
        let visible = !screensAsleep && !occluded
        guard surfaceIsVisible != visible else { return }
        surfaceIsVisible = visible
    }

    private func stopVisibilityTracking() {
        for observer in visibilityObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        visibilityObservers.removeAll()
        screensAsleep = false
        surfaceIsVisible = true
    }

    func pointerEntered() {
        collapseTask?.cancel()
        // During setup the island belongs to setup. Hovering it must not open
        // the dashboard of a Nano that is already configured.
        if let onboardingIsland {
            if onboardingIsland.isCard { onOnboardingHover?() }
            return
        }
        guard !settings.clickToOpen else { return }
        // A HUD is the thing the user is looking at. Hovering it must not
        // blow it open into the dashboard.
        guard phase == .idleCompact else { return }

        expansionTask?.cancel()
        expansionTask = Task { [weak self] in
            try? await Task.sleep(for: NanoHoverCadence.openDelay)
            guard !Task.isCancelled else { return }
            self?.phase = .hoverDashboard
            self?.routeToWorkingAgent()
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, phase == .hoverDashboard else { return }
                activateDashboardServices()
            }
        }
    }

    /// A text field in the island's panel is being edited.
    static var islandHasTextFocus: Bool {
        guard let window = NSApp.keyWindow, window is NanoPanel else { return false }
        return window.firstResponder is NSTextView
    }

    func pointerExited() {
        expansionTask?.cancel()
        guard !isPinned else { return }
        guard phase == .hoverDashboard || phase == .dragTarget else { return }

        collapseTask?.cancel()
        let grace = max(hoverGraceUntil.timeIntervalSinceNow, 0.35)
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(grace * 1000)))
            // Typing into a field (a timer name, a city) must not lose the
            // island just because the pointer drifted off it.
            while !Task.isCancelled, Self.islandHasTextFocus {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled, let self else { return }
            if phase == .dragTarget {
                endFileDrag()
                return
            }
            deactivateDashboardServices()
            // Only a file drag leaves a module open on a hover.
            activeModule = nil
            phase = .idleCompact
            // Phase first, then dismiss: if an agent card is next in the
            // queue, showTransientHUD can still take the island.
            if notificationCenter.current?.source.docksBelowDashboard == true {
                notificationCenter.dismissCurrent()
            }
            // A card held back during a file drag gets its turn now.
            syncTransientHUD()
        }
    }

    func togglePinnedDashboard() {
        let shouldClose = phase == .pinnedDashboard
        cancelPendingTransitions()
        notificationCenter.setAside()
        if shouldClose {
            deactivateModule(activeModule)
            deactivateDashboardServices()
            setAgentTokenBreakdownHeight(0)
            showsAgentUsageDetail = false
            activeModule = nil
            phase = .idleCompact
        } else {
            phase = .pinnedDashboard
            if activeModule == nil, !hookBridge.pending.isEmpty, settings.isEnabled(.agents) {
                // Clicking the island while an agent waits goes to its request.
                activeModule = .agents
                activateModule(.agents)
            } else if activeModule == nil {
                activateDashboardServices()
            }
        }
    }

    func togglePin() {
        isPinned.toggle()
        cancelPendingTransitions()

        if isPinned {
            if phase == .idleCompact {
                activateDashboardServices()
            }
            phase = .pinnedDashboard
        } else if activeModule == nil {
            phase = .hoverDashboard
        }
    }

    /// What a file drag interrupted, and the tray's drop count when it began.
    private var fileDragStart: (phase: IslandPhase, module: NanoModuleID?, drops: Int)?

    /// A file dragged onto the island opens the tray's drop targets, whatever
    /// the island was showing. HUDs and pinned modules come back afterwards.
    func beginFileDrag() {
        guard settings.isEnabled(.tray), phase != .dragTarget else { return }
        cancelPendingTransitions()
        fileDragStart = (phase, activeModule, trayStore.dropCount)
        if activeModule != .tray {
            deactivateModule(activeModule)
            deactivateDashboardServices()
        }
        trayStore.pruneMissing()
        activeModule = .tray
        phase = .dragTarget
    }

    /// The drag ended, over the island or away from it. A drop keeps the tray
    /// open under the pointer so its files can be seen; a
    /// pinned island goes back to what it was pinned to; anything else
    /// collapses and lets a waiting HUD return.
    func endFileDrag() {
        guard phase == .dragTarget, let start = fileDragStart else { return }
        fileDragStart = nil
        if trayStore.dropCount > start.drops {
            phase = isPinned ? .pinnedDashboard : .hoverDashboard
            return
        }
        if start.phase == .pinnedDashboard {
            activeModule = start.module.flatMap { settings.isEnabled($0) ? $0 : nil }
            if let module = activeModule, module != .tray {
                activateModule(module)
            } else if activeModule == nil {
                activateDashboardServices()
            }
            phase = .pinnedDashboard
            return
        }
        activeModule = nil
        phase = .idleCompact
        syncTransientHUD()
    }

    private func announceAgentCompletion(sessionID: String?) {
        guard settings.isEnabled(.agents), settings.isNotificationEnabled(.agent) else { return }
        if let sessionID,
           let previous = lastCompletionAnnouncement,
           previous.sessionID == sessionID,
           Date().timeIntervalSince(previous.at) < 2 {
            return
        }
        if let sessionID {
            lastCompletionAnnouncement = (sessionID, Date())
        }
        let session = sessionID.flatMap { id in
            sessionStore.sessions.first { $0.id == id }
        }
        let liveState = sessionID.flatMap { hookBridge.sessionStates[$0] }
        // T3 names a thread by running a one-shot Codex or Claude turn. It is
        // not the user's session and has nowhere to open, so it gets no card.
        if session.map(AgentSessionStore.isHostHousekeeping) == true
            || liveState?.lastUserPrompt.map(AgentSessionStore.isHostHousekeepingPrompt) == true {
            return
        }
        let provider = session?.provider
            ?? liveState.flatMap { AgentProviderID.fromHook(source: $0.source, providerID: $0.providerID) }
            ?? .claude
        let request = AgentHookBridge.PendingRequest(
            id: "completion:\(sessionID ?? UUID().uuidString):\(Date().timeIntervalSince1970)",
            source: provider.rawValue,
            kind: .completion,
            title: session?.displayName ?? "\(provider.title) session",
            detail: "Ready for review",
            options: [],
            sessionID: sessionID,
            receivedAt: Date(),
            projectName: session?.projectName
        )
        routeNotification(.agent(IslandAgentAttention(request)))
    }

    // MARK: Cue

    private func syncCue(isEnabled: Bool) {
        if isEnabled, settings.cueQuickCaptureEnabled {
            cueQuickCapture.onPress = { [weak self] in self?.quickCaptureCue() }
            cueQuickCapture.register(settings.cueQuickCaptureHotkey)
            cueQuickCaptureError = cueQuickCapture.registrationError
        } else {
            cueQuickCapture.unregister()
            cueQuickCaptureError = nil
        }

        if isEnabled {
            cueSync.startPolling()
            cueSync.requestSync()
        } else {
            cueSync.stop()
        }
    }

    /// `nano://cue/<uuid>`, from a synced reminder: shows that cue's folder.
    func openCue(_ id: UUID) {
        guard settings.isEnabled(.cue) else { return }
        if let item = cueStore.items.first(where: { $0.id == id }) {
            cueStore.scope = item.folderID.map(CueScope.folder) ?? .inbox
            cueStore.showsDone = item.isDone
        }
        openModule(.cue)
    }

    // MARK: Mixer

    private func syncMixerHotkey(isEnabled: Bool) {
        if isEnabled, settings.mixerMicMuteHotkeyEnabled {
            mixerMicMuteHotkey.onPress = { [weak self] in self?.toggleMixerMicrophone() }
            mixerMicMuteHotkey.register(settings.mixerMicMuteHotkey)
            mixerMicMuteHotkeyError = mixerMicMuteHotkey.registrationError
        } else {
            mixerMicMuteHotkey.unregister()
            mixerMicMuteHotkeyError = nil
        }
    }

    /// The shortcut pressed: flip every input's mute and flash the island HUD.
    /// It bypasses the per-source notification setting — a mute the user asked
    /// for must always confirm itself.
    private func toggleMixerMicrophone() {
        guard settings.isEnabled(.mixer) else { return }
        mixerStore.toggleMicMute()
        presentHUD(.microphone(muted: mixerStore.isMicMuted))
    }

    /// Same path as routeNotification minus the per-source enabled check.
    private func presentHUD(_ notification: IslandNotification) {
        if phase.showsDashboard, notification.source.docksBelowDashboard {
            notificationCenter.present(notification)
            return
        }
        if phase == .dragTarget {
            notificationCenter.present(notification)
            return
        }
        suspendDashboardForHUDIfNeeded()
        notificationCenter.present(notification)
        phase = .transientHUD
    }

    /// The shortcut path: read the selection before Nano takes focus, then
    /// open the island on a new cue with the editor focused. Pressing it
    /// again while the empty capture is up closes it.
    func quickCaptureCue() {
        guard settings.isEnabled(.cue) else { return }
        if activeModule == .cue, phase.isExpanded, let draft = cueStore.draft {
            if draft.isEmpty { finishCueCapture(save: false) }
            return
        }

        let front = NSWorkspace.shared.frontmostApplication
        let fromNano = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let selection = settings.cuePullsSelection && !fromNano
            ? CueSelectionReader.frontmostSelection()
            : (text: nil, appName: front?.localizedName)
        cueReturnApp = fromNano ? nil : front
        cueCaptureFromShortcut = true

        cueStore.beginCapture(
            text: selection.text ?? "",
            sourceApp: fromNano ? nil : selection.appName,
            pulledFromSelection: selection.text != nil,
            returnsFocus: !fromNano
        )
        if activeModule != .cue || !phase.isExpanded {
            openModule(.cue)
        }
        NotificationCenter.default.post(name: .nanoIslandWantsKeyboard, object: nil)
    }

    /// Starts a capture from inside the island. Focus stays in Nano.
    func beginCueCapture() {
        cueReturnApp = nil
        cueCaptureFromShortcut = false
        cueStore.beginCapture()
        NotificationCenter.default.post(name: .nanoIslandWantsKeyboard, object: nil)
    }

    func finishCueCapture(save: Bool, keepOpen: Bool = false) {
        guard let draft = cueStore.draft else { return }
        if save {
            cueStore.commitDraft(keepOpen: keepOpen)
        } else {
            cueStore.cancelDraft()
        }
        let fromShortcut = cueCaptureFromShortcut
        cueCaptureFromShortcut = false
        guard !keepOpen, draft.returnsFocus || fromShortcut else { return }
        collapseIncludingPinned()
        cueReturnApp?.activate()
        cueReturnApp = nil
    }

    /// Escape on the island. A capture is cancelled, and closes the island
    /// when the shortcut opened it; otherwise an open, unpinned island closes.
    /// Returns false to leave the key to whatever has focus.
    func handleEscape(textIsEditing: Bool) -> Bool {
        if activeModule == .cue, cueStore.draft != nil {
            finishCueCapture(save: false)
            return true
        }
        // A field being edited, like a folder being renamed, cancels itself.
        guard !textIsEditing, phase.isExpanded, !isPinned else { return false }
        // Opening a feature holds the island open without the user pinning
        // it; Escape closes that too. Only the pin button's pin survives.
        if phase == .pinnedDashboard {
            collapseIncludingPinned()
        } else {
            collapse()
        }
        return true
    }

    /// Timer completion uses the shared queue so a blocking agent decision is
    /// never dismissed or covered by the Timer module opening itself.
    func announceTimerCompletion() {
        guard settings.isEnabled(.timer) else { return }
        // The sound belongs to the notification: with Timer notifications
        // off, a finished session is silent as well as cardless.
        if settings.isNotificationEnabled(.timer) { NSSound.beep() }
        routeNotification(
            .timerCompletion(
                mode: timerStore.mode,
                sessionName: timerStore.sessionName,
                configuredDuration: timerStore.configuredDuration
            )
        )
    }

    /// While an agent is mid-task, that is what the user opened the island to
    /// see — the dashboard is a detour. Only applies on expansion, so closing
    /// the module still returns to the dashboard and stays there.
    private func routeToWorkingAgent() {
        // A waiting request counts as much as a working agent: its card may
        // have been dismissed, and this is where it can still be answered.
        guard activeModule == nil,
              settings.isEnabled(.agents),
              agentService.hasActiveAgent || !hookBridge.pending.isEmpty
        else { return }

        activeModule = .agents
        activateModule(.agents)
    }

    func updateAgentActivity(_ active: Bool) {
        guard isAgentActive != active else { return }
        isAgentActive = active
    }

    func openModule(_ module: NanoModuleID) {
        guard settings.isEnabled(module) else { return }
        cancelPendingTransitions()
        notificationCenter.setAside()
        deactivateDashboardServices()
        deactivateModule(activeModule)
        if module != .agents { setAgentTokenBreakdownHeight(0) }
        showsAgentUsageDetail = false
        activeModule = module
        phase = .pinnedDashboard
        activateModule(module)
    }

    func closeModule() {
        deactivateModule(activeModule)
        setAgentTokenBreakdownHeight(0)
        showsAgentUsageDetail = false
        activeModule = nil
        activateDashboardServices()
        phase = isPinned ? .pinnedDashboard : .hoverDashboard
        // The dashboard is usually shorter than the module it replaces, so
        // the Home button just clicked is now below the island. Give the
        // pointer time to follow before treating that as leaving.
        if !isPinned { hoverGraceUntil = Date().addingTimeInterval(1.5) }
    }

    func collapse() {
        if phase == .transientHUD {
            notificationCenter.dismissCurrent()
            return
        }
        guard phase != .pinnedDashboard else { return }
        cancelPendingTransitions()
        deactivateModule(activeModule)
        deactivateDashboardServices()
        setAgentTokenBreakdownHeight(0)
        showsAgentUsageDetail = false
        activeModule = nil
        phase = .idleCompact
    }

    func collapseIncludingPinned() {
        isPinned = false
        cancelPendingTransitions()
        notificationCenter.dismissAll()
        deactivateModule(activeModule)
        deactivateDashboardServices()
        setAgentTokenBreakdownHeight(0)
        showsAgentUsageDetail = false
        activeModule = nil
        phase = .idleCompact
    }

    func setAgentUsageDetail(_ presented: Bool) {
        guard displayedModule == .agents else { return }
        setAgentTokenBreakdownHeight(0)
        showsAgentUsageDetail = presented
    }

    func setAgentTokenBreakdownHeight(_ height: CGFloat) {
        let measured = max(height.rounded(.up), 0)
        guard measured != agentTokenBreakdownHeight else { return }
        agentTokenBreakdownHeight = measured
    }

    func handleNotificationTap(_ notification: IslandNotification) {
        switch notification.source {
        case .agent:
            if case let .agent(attention) = notification.payload {
                openAgentSession(attention)
            } else {
                openModule(.agents)
            }
        case .volume:
            openModule(.volume)
        case .battery:
            openModule(.battery)
        case .timer:
            openModule(.timer)
        case .system:
            if let content = notification.systemContent {
                if content.summary?.kind == .catchUp {
                    openModule(.notificationLabs)
                } else {
                    openSystemNotification(content)
                }
            }
            notificationCenter.dismissCurrent()
        case .bluetooth, .brightness:
            notificationCenter.dismissCurrent()
        }
    }

    /// Clicking a card goes where the macOS banner would have gone: the app.
    func openSystemNotification(_ content: SystemNotificationContent) {
        guard content.recordID >= 0 else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // iMessage with a known handle lands in that conversation, not just the app.
        if content.isMessage, let handle = content.message?.handle, !content.message!.isGroup,
           let url = Self.messagesConversationURL(handle: handle) {
            NSWorkspace.shared.open(url, configuration: configuration)
            return
        }
        guard let url = SystemNotificationAppInfo.applicationURL(for: content.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Messages clears the unread state when the conversation is shown, so
    /// open it without stealing focus. Group chats have no handle URL.
    private func markMessageRead(_ content: SystemNotificationContent) {
        guard let handle = content.message?.handle, content.message?.isGroup == false,
              let url = Self.messagesConversationURL(handle: handle) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration)
    }

    nonisolated static func messagesConversationURL(handle: String) -> URL? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "imessage://\(encoded)")
    }

    // MARK: Incoming calls

    nonisolated static func callCoalesceKey(_ banner: IncomingCallBanner) -> String {
        "system:call:\(banner.kind.label):\(banner.caller)"
    }

    /// A FaceTime or relayed iPhone call is ringing. Nano shows who it is and
    /// opens FaceTime on tap; the macOS banner keeps Accept and Decline.
    func handleIncomingCall(_ banner: IncomingCallBanner) {
        guard settings.isNotificationEnabled(.system) else { return }
        guard !settings.isSystemNotificationExcluded(bundleID: banner.kind.bundleID) else { return }
        guard !screenLockMonitor.isLocked else { return }
        let content = SystemNotificationContent(
            recordID: 0,
            uuid: "call:\(banner.kind.label):\(banner.caller):\(Date().timeIntervalSinceReferenceDate)",
            bundleID: banner.kind.bundleID,
            appName: banner.kind.appName,
            title: banner.caller,
            subtitle: nil,
            body: "Incoming \(banner.kind.label)",
            deliveredAt: Date()
        )
        routeNotification(.system(content, coalesceKey: Self.callCoalesceKey(banner)))
    }

    /// A banner that Accessibility saw, including apps that never write the
    /// Notification Center store. Same quiet rules as a store-backed alert.
    func handleAXSystemBanner(_ banner: GenericNotificationBanner) {
        guard settings.isNotificationEnabled(.system) else { return }
        let resolved = Self.resolveAXBannerApp(texts: banner.texts)
        if settings.isSystemNotificationExcluded(bundleID: resolved.bundleID) { return }
        let content = SystemNotificationContent(
            recordID: -1,
            uuid: banner.occurrenceID.map { "ax:\($0)" } ?? "ax:words:\(banner.identity)",
            bundleID: resolved.bundleID,
            appName: resolved.appName,
            title: banner.title,
            subtitle: nil,
            body: banner.body,
            deliveredAt: Date()
        )
        handleSystemNotification(content)
    }

    /// Match a running app whose name appears on the banner, so exclusion and
    /// tap-to-open still work when the store never recorded a bundle id.
    static func resolveAXBannerApp(texts: [String]) -> (bundleID: String, appName: String) {
        let lowered = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName, let bundleID = app.bundleIdentifier else { continue }
            if lowered.contains(name.lowercased()) {
                return (bundleID, name)
            }
        }
        return ("ax.unknown", texts.first ?? "Notification")
    }

    /// Incoming macOS notification. Applies the quiet rules that need live
    /// app state (lock screen) before it reaches the island.
    private func canPresentSystemNotification(_ content: SystemNotificationContent) -> Bool {
        settings.isNotificationEnabled(.system)
            && !settings.isSystemNotificationExcluded(bundleID: content.bundleID)
            && !screenLockMonitor.shouldSuppress()
    }

    func handleSystemNotification(_ raw: SystemNotificationContent) {
        guard settings.isNotificationEnabled(.system),
              !settings.isSystemNotificationExcluded(bundleID: raw.bundleID) else { return }
        guard canPresentSystemNotification(raw) else {
            if screenLockMonitor.shouldSuppress() {
                if settings.systemNotificationsCatchUp, catchUpSince != nil {
                    handleSkippedSystemNotification(raw, verdict: .stale)
                }
            } else {
                notificationCenter.rememberQuietly(.system(raw))
            }
            return
        }
        notificationRouter.receiveSystem(raw)
    }

    private func presentSystemNotification(_ raw: SystemNotificationContent, coalesceKey: String) -> Bool {
        guard canPresentSystemNotification(raw) else { return false }
        notificationLog.info("presenting \(raw.bundleID, privacy: .public) message=\(raw.isMessage)")
        var content = raw
        if !settings.systemNotificationsShowBody {
            content.actions = []
            content = SystemNotificationContent(
                recordID: raw.recordID, uuid: raw.uuid, bundleID: raw.bundleID, appName: raw.appName,
                title: raw.title, subtitle: raw.subtitle, body: nil, deliveredAt: raw.deliveredAt
            )
            content.actions = raw.actions
            content.categoryID = raw.categoryID
        }
        if !settings.systemNotificationsShowActions { content.actions = [] }
        content.tint = SystemNotificationAppInfo.tint(for: content.bundleID)

        // On a call or sharing the screen, nobody else should read your texts.
        if settings.systemNotificationsHidePreviewsOnCamera, cameraMonitor.cameraInUse {
            content.previewHidden = true
            content.actions = []
            notificationLog.info("preview hidden: camera in use")
        }

        let key = coalesceKey
        guard content.isMessage, !content.previewHidden else {
            routeNotification(.system(content, coalesceKey: key))
            if settings.systemNotificationsHideNativeBanner, !raw.isCall { bannerSuppressor.suppress(raw) }
            return true
        }

        // iMessage: resolve the chat off-main so Reply and the contact photo
        // are ready, then show. A miss still shows the card without Reply.
        let deliveredAt = content.deliveredAt
        let body = content.body
        Task { [weak self] in
            let context = await Task.detached(priority: .userInitiated) {
                MessagesChatResolver.resolve(deliveredAt: deliveredAt, body: body)
            }.value
            guard let self, self.notificationRouter.canFinishPresentation(key: key) else { return }
            guard self.canPresentSystemNotification(raw) else {
                self.notificationRouter.withhold(key: key)
                return
            }
            var resolved = content
            resolved.message = context
            self.routeNotification(.system(resolved, coalesceKey: key))
            if self.settings.systemNotificationsHideNativeBanner { self.bannerSuppressor.suppress(raw) }
        }
        return true
    }

    // MARK: Summaries

    /// A notification the store dropped. Storms and history are summarised;
    /// duplicates and exclusions are simply gone.
    func handleSkippedSystemNotification(_ content: SystemNotificationContent, verdict: SystemNotificationFilter.Verdict) {
        switch verdict {
        case .storm:
            let key = content.bundleID.lowercased()
            let count = (stormBuckets[key]?.count ?? 0) + 1
            stormBuckets[key] = (count, content)
            stormFlush?.cancel()
            stormFlush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.flushStormSummaries()
            }
        case .stale:
            guard settings.systemNotificationsCatchUp, let since = catchUpSince,
                  content.deliveredAt >= since else { return }
            catchUpBucket.append(content)
            catchUpFlush?.cancel()
            catchUpFlush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.flushCatchUp()
            }
        case .show, .duplicate, .excluded:
            break
        }
    }

    private func flushStormSummaries() {
        let buckets = stormBuckets
        stormBuckets.removeAll()
        for (_, bucket) in buckets {
            // The storm filter let the first few through; this card covers the rest.
            var summary = bucket.latest
            summary.summary = SystemNotificationSummary(kind: .storm, count: bucket.count)
            summary.actions = []
            summary.tint = SystemNotificationAppInfo.tint(for: summary.bundleID)
            routeNotification(.system(
                Self.summaryContent(summary, title: "\(bucket.count) more from \(bucket.latest.appName)"),
                coalesceKey: "system:storm:\(bucket.latest.bundleID.lowercased())"
            ))
        }
    }

    private func flushCatchUp() {
        // Still locked: wait for the unlock and the settle window.
        if screenLockMonitor.shouldSuppress() {
            catchUpFlush = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.flushCatchUp()
            }
            return
        }
        let items = catchUpBucket
        catchUpBucket.removeAll()
        catchUpSince = nil
        guard !items.isEmpty, settings.isNotificationEnabled(.system) else { return }
        let apps = Set(items.map { $0.bundleID.lowercased() }).count
        var latest = items.max { $0.deliveredAt < $1.deliveredAt } ?? items[0]
        latest.summary = SystemNotificationSummary(kind: .catchUp, count: items.count)
        latest.actions = []
        latest.tint = nil
        let plural = items.count == 1 ? "notification" : "notifications"
        let title = apps > 1
            ? "\(items.count) \(plural) from \(apps) apps"
            : "\(items.count) \(plural) from \(latest.appName)"
        // Everything becomes history so the Notifications module lists it all.
        for item in items where item.uuid != latest.uuid {
            notificationCenter.rememberQuietly(.system(item))
        }
        routeNotification(.system(Self.summaryContent(latest, title: title), coalesceKey: "system:catchup"))
    }

    /// Rebuilds a summary card around the latest notification it stands for.
    nonisolated static func summaryContent(_ latest: SystemNotificationContent, title: String) -> SystemNotificationContent {
        var content = SystemNotificationContent(
            recordID: latest.recordID,
            uuid: "summary:\(latest.uuid)",
            bundleID: latest.summary?.kind == .catchUp ? "com.nanoapp.Nano.catchup" : latest.bundleID,
            appName: latest.summary?.kind == .catchUp ? "While you were away" : latest.appName,
            title: title,
            subtitle: nil,
            body: latest.summary?.kind == .catchUp
                ? "Latest: \(latest.appName) · \(latest.headline)"
                : latest.detail ?? latest.headline,
            deliveredAt: latest.deliveredAt
        )
        content.summary = latest.summary
        content.tint = latest.tint
        return content
    }

    /// Sleep and lock mark where the catch-up window starts.
    private func installSleepObservers() {
        guard sleepObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.catchUpSince = self?.catchUpSince ?? Date() }
        })
        sleepObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.catchUpSince = self?.catchUpSince ?? Date() }
        })
        sleepObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.catchUpSince = self?.catchUpSince ?? Date() }
        })
    }

    private func removeSleepObservers() {
        for observer in sleepObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        sleepObservers.removeAll()
    }

    // MARK: Actions

    /// Runs one of the app's own banner buttons. The press goes to the macOS
    /// banner through Accessibility; if that banner is already gone, the app
    /// opens instead so the tap is never a dead end.
    func performSystemAction(_ action: SystemNotificationAction, on content: SystemNotificationContent) {
        let pressed = bannerSuppressor.pressAction(titled: action.title, on: content)
        notificationLog.info("action \(action.title, privacy: .public) pressed=\(pressed)")
        if !pressed {
            openSystemNotification(content)
        }
        if let key = notificationRouter.key(for: content) {
            notificationCenter.dismiss(coalesceKey: key)
        }
    }

    /// Reply state for the current iMessage card.
    @Published var systemReplyError: String?
    @Published private(set) var systemReplyInFlight = false

    func beginSystemReply() {
        notificationCenter.holdCurrent()
        systemReplyError = nil
        NotificationCenter.default.post(name: .nanoIslandWantsKeyboard, object: nil)
    }

    func cancelSystemReply() {
        systemReplyError = nil
        notificationCenter.releaseCurrent()
    }

    func sendSystemReply(_ text: String, to content: SystemNotificationContent) {
        guard let chatGUID = content.message?.chatGUID, !systemReplyInFlight else { return }
        // The sample card has no chat. Sending would ask for Automation and
        // fail with a raw AppleScript error, so it only acts out a send.
        if chatGUID == "preview" {
            if notificationCenter.current?.systemContent?.uuid == content.uuid {
                notificationCenter.dismissCurrent()
            }
            return
        }
        systemReplyInFlight = true
        systemReplyError = nil
        Task { [weak self] in
            do {
                try await MessagesReplySender.send(text, to: chatGUID)
                guard let self else { return }
                self.systemReplyInFlight = false
                if self.notificationCenter.current?.systemContent?.uuid == content.uuid {
                    self.notificationCenter.dismissCurrent()
                }
                if self.settings.systemNotificationsMarkReadAfterReply {
                    self.markMessageRead(content)
                }
            } catch {
                guard let self else { return }
                self.systemReplyInFlight = false
                if let failure = error as? MessagesReplySender.Failure, case let .scriptError(message) = failure {
                    self.systemReplyError = message
                } else {
                    self.systemReplyError = "Reply could not be sent."
                }
            }
        }
    }

    func presentAgentAttention(_ request: AgentHookBridge.PendingRequest) {
        guard settings.isEnabled(.agents) else { return }
        guard settings.isNotificationEnabled(.agent) else {
            openModule(.agents)
            return
        }
        routeNotification(.agent(IslandAgentAttention(request)))
    }

    var dockedNotification: IslandNotification? {
        guard phase.showsDashboard, let current = notificationCenter.current,
              current.source.docksBelowDashboard else { return nil }
        return current
    }

    func routeNotification(_ notification: IslandNotification) {
        guard notification.ignoresSourceSettings || settings.isNotificationEnabled(notification.source) else { return }
        if case .agent(let attention) = notification.payload {
            let live = attention.sessionID.flatMap { hookBridge.sessionStates[$0] }
            let session = attention.sessionID.flatMap { id in sessionStore.sessions.first { $0.id == id } }
            let context = AgentProviderRegistry.notificationContext(source: attention.source, host: live?.host,
                explicitBundleID: live?.hostBundleID, sessionTitle: session?.displayName)
            notificationRouter.receiveAgent(attention, context: context)
        }
        if phase.showsDashboard, notification.source.docksBelowDashboard {
            notificationCenter.present(notification)
            return
        }
        // A drag on its way to the tray keeps the island, or the drop lands
        // nowhere. The card waits and shows once the island collapses.
        if phase == .dragTarget {
            notificationCenter.present(notification)
            return
        }
        suspendDashboardForHUDIfNeeded()
        notificationCenter.present(notification)
        phase = .transientHUD
    }

    /// Settings preview. Always shows, even if that source is disabled, so the
    /// HUD can be judged without waiting for a hardware event.
    func previewNotification(_ source: IslandNotificationSource) {
        previewNotification(.preview(for: source))
    }

    func previewNotification(_ notification: IslandNotification) {
        suspendDashboardForHUDIfNeeded()
        cancelPendingTransitions()
        notificationCenter.presentPreview(notification)
        phase = .transientHUD
    }

    private func suspendDashboardForHUDIfNeeded() {
        guard phase.showsDashboard else { return }
        presentationBeforeHUD = (phase, activeModule)
        cancelPendingTransitions()
        deactivateModule(activeModule)
        deactivateDashboardServices()
    }

    func syncNotificationSources() {
        startNotificationMonitoring()
    }

    private var nativeHidingWasEnabled = false

    private func startNotificationMonitoring() {
        notificationCenter.onCurrentChange = { [weak self] in
            self?.syncTransientHUD()
        }
        eventMonitor.onNotification = { [weak self] notification in
            self?.routeNotification(notification)
        }
        notificationStore.onNotification = { [weak self] content in
            self?.handleSystemNotification(content)
        }
        notificationStore.onSkipped = { [weak self] content, verdict in
            self?.handleSkippedSystemNotification(content, verdict: verdict)
        }
        callWatcher.onCallBegan = { [weak self] banner in
            self?.handleIncomingCall(banner)
        }
        callWatcher.onCallEnded = { [weak self] banner in
            self?.notificationCenter.dismiss(coalesceKey: Self.callCoalesceKey(banner))
        }
        callWatcher.onGenericBanner = { [weak self] banner in
            self?.handleAXSystemBanner(banner)
        }

        let sources = Set(settings.enabledNotificationSources.filter(settings.isNotificationEnabled))
        notificationCenter.retainEnabledSources(sources)
        eventMonitor.start(sources: sources.subtracting([.agent, .system]))
        mediaKeyInterceptor.configure(.init(
            volume: settings.hudReplacesSystemHUD && settings.hudReplacesVolumeKeys && sources.contains(.volume),
            brightness: settings.hudReplacesSystemHUD && settings.hudReplacesBrightnessKeys && sources.contains(.brightness),
            feedbackSound: settings.hudVolumeFeedbackSound
        ))

        if !settings.isNotificationEnabled(.agent) || !settings.isEnabled(.agents) { notificationRouter.forgetAgents() }
        if !settings.systemNotificationsHideNativeBanner { bannerSuppressor.cancelAll() }
        notificationStore.excludedBundleIDs = settings.systemNotificationExcludedApps
        if sources.contains(.system) {
            screenLockMonitor.start()
            notificationStore.start()
            callWatcher.start()
            if settings.systemNotificationsHideNativeBanner && !nativeHidingWasEnabled {
                callWatcher.replayVisibleGenericBanners()
            }
            installSleepObservers()
            if settings.systemNotificationsHidePreviewsOnCamera {
                cameraMonitor.start()
            } else {
                cameraMonitor.stop()
            }
        } else {
            callWatcher.stop()
            cameraMonitor.stop()
            removeSleepObservers()
            notificationStore.stop()
            screenLockMonitor.stop()
            bannerSuppressor.cancelAll()
            notificationRouter.reset()
        }

        nativeHidingWasEnabled = settings.systemNotificationsHideNativeBanner
    }

    private func showTransientHUD() {
        guard notificationCenter.current != nil else { return }
        guard !phase.showsDashboard else { return }
        cancelPendingTransitions()
        phase = .transientHUD
    }

    private func syncTransientHUD() {
        guard let current = notificationCenter.current else {
            if phase == .transientHUD { restorePresentationAfterHUD() }
            return
        }
        if phase == .transientHUD, current.source.docksBelowDashboard,
           presentationBeforeHUD != nil {
            restorePresentationAfterHUD()
            return
        }
        showTransientHUD()
    }

    private func restorePresentationAfterHUD() {
        guard let previous = presentationBeforeHUD else {
            phase = .idleCompact
            return
        }

        presentationBeforeHUD = nil
        activeModule = previous.module.flatMap { settings.isEnabled($0) ? $0 : nil }
        phase = previous.phase
        if let module = activeModule {
            activateModule(module)
        } else {
            activateDashboardServices()
        }
    }

    private func syncAgentNotification() {
        notificationCenter.retainPendingAgentRequests(Set(hookBridge.pending.map(\.id)))
    }

    func openAgentSession(_ attention: IslandAgentAttention) {
        guard let sessionID = attention.sessionID,
              let session = sessionStore.sessions.first(where: { $0.id == sessionID })
        else {
            showAgentsModulePreservingNotifications()
            return
        }
        let hostTitle = AgentSessionJump.hostTitle(for: session)
        AgentSessionJump.open(session) { [weak self] result in
            guard let self else { return }
            if let notice = Self.jumpNotice(for: result, hostTitle: hostTitle) {
                agentJumpNotices[attention.requestID] = notice
                // Long enough to read; the card's own timer may end sooner.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    self?.agentJumpNotices[attention.requestID] = nil
                }
            }
            guard Self.shouldDismissAgentAttention(
                respondsThroughBridge: attention.respondsThroughBridge,
                result: result
            ) else { return }
            notificationCenter.dismissAgent(requestID: attention.requestID)
        }
    }

    /// Nil when the session opened, which needs no explaining.
    nonisolated static func jumpNotice(for result: AgentSessionJump.OpenResult, hostTitle: String) -> String? {
        switch result {
        case .opened: nil
        case .hostActivated: "Opened \(hostTitle). Couldn't find this session there, so pick it from the list."
        case .accessibilityRequired: "Nano needs Accessibility access to open the session in \(hostTitle)."
        case .unavailable: "Couldn't open \(hostTitle)."
        }
    }

    /// Permission/question cards stay until answered. Passive completion cards
    /// clear only after the destination reports an exact session selection.
    static func shouldDismissAgentAttention(
        respondsThroughBridge: Bool,
        result: AgentSessionJump.OpenResult
    ) -> Bool {
        !respondsThroughBridge && result == .opened
    }

    private func showAgentsModulePreservingNotifications() {
        guard settings.isEnabled(.agents) else { return }
        cancelPendingTransitions()
        deactivateDashboardServices()
        deactivateModule(activeModule)
        activeModule = .agents
        phase = .pinnedDashboard
        activateModule(.agents)
    }

    func shutdown() {
        mixerStore.stop()
        ambientMonitoringStarted = false
        enabledModuleSnapshot = []
        stopVisibilityTracking()
        eventMonitor.stop()
        mediaKeyInterceptor.stop()
        callWatcher.stop()
        cameraMonitor.stop()
        removeSleepObservers()
        notificationStore.stop()
        screenLockMonitor.stop()
        bannerSuppressor.cancelAll()
        notificationCenter.dismissAll()
        sessionStore.stopMonitoring()
        agentService.deactivate()
        mediaController.deactivate()
        systemStatusService.deactivate()
        voiceDictation.deactivate()
        cameraService.deactivate()
        calendarService.deactivate()
        weatherService.cancel()
        deactivateModule(activeModule)
    }

    private func syncFeatureMonitoring() {
        guard ambientMonitoringStarted else { return }

        let previous = enabledModuleSnapshot
        let current = settings.enabledModules
        enabledModuleSnapshot = current

        if let activeModule, !current.contains(activeModule) {
            deactivateModule(activeModule)
            self.activeModule = nil
            if phase.showsDashboard {
                activateDashboardServices()
            }
        }

        syncAgents(wasEnabled: previous.contains(.agents), isEnabled: current.contains(.agents))
        syncCue(isEnabled: current.contains(.cue))
        syncMixerHotkey(isEnabled: current.contains(.mixer))
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            mixerStore.setEnabled(current.contains(.mixer))
        }

        mediaController.preferredPlayer = settings.preferredMediaPlayer
        if current.contains(.music) {
            if !previous.contains(.music) {
                mediaController.activate()
            }
        } else if previous.contains(.music) {
            mediaController.deactivate()
        }

        let hadSystemStatus = previous.contains(.battery) || previous.contains(.volume) || previous.contains(.mixer)
        let needsSystemStatus = current.contains(.battery) || current.contains(.volume) || current.contains(.mixer)
        if needsSystemStatus, !hadSystemStatus {
            systemStatusService.activate()
        } else if hadSystemStatus, !needsSystemStatus {
            systemStatusService.deactivate()
        }

        if current.contains(.weather) {
            if !previous.contains(.weather) {
                refreshWeather()
            }
        } else if previous.contains(.weather) {
            weatherService.cancel()
        }

        if previous.contains(.calendar), !current.contains(.calendar) {
            calendarService.deactivate()
        }
        if previous.contains(.timer), !current.contains(.timer) {
            timerStore.pause()
        }

        // The shortcut has to work while the island is closed, so this is an
        // ambient service like agents, not something opening the module starts.
        if current.contains(.voiceDictation) {
            if !previous.contains(.voiceDictation) {
                voiceDictation.activate()
            }
        } else if previous.contains(.voiceDictation) {
            voiceDictation.deactivate()
        }
    }

    private func syncAgents(wasEnabled: Bool, isEnabled: Bool) {
        if isEnabled {
            hookBridge.setEnabledProviders(settings.enabledAgentProviders)
            sessionStore.enabledProviders = settings.enabledAgentProviders
        }
        guard wasEnabled != isEnabled else { return }

        if isEnabled {
            agentService.activate(
                providers: settings.enabledAgentProviders,
                usage: settings.usageProviders
            )
            hookBridge.start()
            scanTokenLedger()
            sessionStore.startMonitoring()
            return
        }

        notificationCenter.dismiss(source: .agent)
        sessionStore.stopMonitoring()
        agentService.deactivate()
        hookBridge.stop()
    }

    private func activateDashboardServices() {
        // Seeks made in the player itself may go unannounced, so the clock
        // takes a fresh sample whenever it comes into view.
        if settings.isEnabled(.music) {
            mediaController.refresh()
        }
        if settings.isEnabled(.calendar) {
            calendarService.activate()
        }
        if settings.isEnabled(.weather) {
            refreshWeather()
        }
    }

    func refreshWeather(promptForLocation: Bool = false) {
        switch WeatherRefreshAction.plan(
            usesCurrentLocation: settings.weatherUsesCurrentLocation,
            hasSavedLocation: settings.weatherHasLocation,
            canUseCurrentLocation: weatherService.canUseCurrentLocation,
            promptForLocation: promptForLocation
        ) {
        case .requestCurrentLocation(let promptIfNeeded):
            weatherService.refreshCurrentLocation(
                force: promptForLocation,
                promptIfNeeded: promptIfNeeded
            )
        case .useSavedLocation:
            weatherService.refresh(
                latitude: settings.weatherLatitude,
                longitude: settings.weatherLongitude,
                force: promptForLocation
            )
        case .wait:
            break
        }
    }

    private func deactivateDashboardServices() {
        calendarService.deactivate()
        weatherService.cancel()
    }

    private func cancelPendingTransitions() {
        expansionTask?.cancel()
        collapseTask?.cancel()
        expansionTask = nil
        collapseTask = nil
    }

    private func activateModule(_ module: NanoModuleID) {
        moduleRuntimeRegistry.activate(module)
    }

    private func deactivateModule(_ module: NanoModuleID?) {
        moduleRuntimeRegistry.deactivate(module)
    }
}
