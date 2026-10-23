import AVFoundation
import AppKit
import Combine
import CoreBluetooth
import EventKit
import SwiftUI

enum OnboardingFeature: String, CaseIterable, Identifiable, Sendable {
    case agents
    case quill
    case cue
    case mixer
    case music
    case weather
    case calendar
    case timer
    case camera
    case battery
    case tray
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .quill: "Quill"
        case .cue: "Cue"
        case .mixer: "Mixer"
        case .music: "Music"
        case .weather: "Weather"
        case .calendar: "Calendar"
        case .timer: "Timer"
        case .camera: "Camera"
        case .battery: "Battery"
        case .tray: "Tray"
        case .notifications: "Notifications"
        }
    }

    func line(word: String) -> String {
        switch self {
        case .agents: "Approve Claude Code, Codex, Cursor and others from the \(word)."
        case .quill: "Hold a key, talk, and Nano types it for you."
        case .cue: "A to-do list for each project, one hover away."
        case .mixer: "Set the volume of each app on its own."
        case .music: "See what's playing. Play, pause, skip."
        case .weather: "Today's forecast, one hover away."
        case .calendar: "Your next event and the week ahead."
        case .timer: "Focus sessions with a countdown in the \(word)."
        case .camera: "Check your face before a call. The camera is off until you open it."
        case .battery: "Your Mac's charge at a glance."
        case .tray: "Drop files on the \(word), AirDrop them later."
        case .notifications: "Volume, AirPods, messages and app alerts in the \(word)."
        }
    }

    var placeholderLine: String {
        switch self {
        case .cue: "Your next steps, one hover away"
        case .mixer: "A slider for every app"
        case .camera: "A mirror, one hover away"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .agents: "sparkles"
        case .quill: "waveform"
        case .cue: "checklist"
        case .mixer: "slider.vertical.3"
        case .music: "music.note"
        case .weather: "cloud.sun.fill"
        case .calendar: "calendar"
        case .timer: "timer"
        case .camera: "camera"
        case .battery: "battery.75percent"
        case .tray: "tray.fill"
        case .notifications: "speaker.wave.2.fill"
        }
    }

    var clip: String? {
        switch self {
        case .agents: "agent-approval"
        case .quill: "voice-dictation"
        case .music: "music"
        case .weather: "weather"
        case .calendar: "calendar"
        case .timer: "timer"
        case .battery: "battery"
        case .tray: "tray"
        case .notifications: "airpods"
        case .cue, .mixer, .camera: nil
        }
    }

    var module: NanoModuleID? {
        switch self {
        case .agents: .agents
        case .quill: .voiceDictation
        case .cue: .cue
        case .mixer: .mixer
        case .music: .music
        case .weather: .weather
        case .calendar: .calendar
        case .timer: .timer
        case .camera: .camera
        case .battery: .battery
        case .tray: .tray
        case .notifications: nil
        }
    }

    var isDashboardModule: Bool {
        [.music, .weather, .calendar, .timer, .camera, .battery].contains(self)
    }

    var permission: NanoPermissionKind? {
        switch self {
        case .music: .automation
        case .weather: .location
        case .calendar: .calendar
        case .camera: .camera
        default: nil
        }
    }

    static let hudSources: [IslandNotificationSource] = [.volume, .brightness, .bluetooth, .battery]

    @MainActor
    static var offered: [OnboardingFeature] {
        allCases.filter { $0 != .battery || SystemStatusService.hasBattery }
    }
}

enum OnboardingRoom: String, CaseIterable, Identifiable, Codable, Sendable {
    case notifications
    case agents
    case voice
    case sketch
    case cue
    case mixer
    case dashboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notifications: "Notifications"
        case .agents: "Agents"
        case .voice: "Quill"
        case .sketch: "Sketch"
        case .cue: "Cue"
        case .mixer: "Mixer"
        case .dashboard: "Dashboard"
        }
    }
}

@MainActor
final class OnboardingFlow: ObservableObject {
    enum ArrivalStage: Hashable { case quiet, greeting, prompt }
    enum FinaleStage: Hashable { case folding, goodbye, fading }

    enum Step: Hashable {
        case arrival(ArrivalStage)
        case resume
        case welcome
        case pick
        case room(Int)
        case summary
        case finale(FinaleStage)
    }

    enum AgentPhase { case pick, connecting, test, done }

    @Published private(set) var step: Step = .arrival(.quiet)
    @Published private(set) var picks: Set<OnboardingFeature>
    @Published var showcaseIndex = 0
    @Published private(set) var agentPhase: AgentPhase
    @Published private(set) var hookFailures: [URL] = []
    @Published private(set) var detectedAgents: Set<AgentProviderID> = []
    @Published private(set) var installedHooks: [URL] = []
    @Published private(set) var accessibilityTrusted = NanoAccessibilityPermission.isTrusted
    @Published private(set) var fullDiskAccess = false
    @Published private(set) var bluetoothAuthorization = CBManager.authorization
    @Published private(set) var screenRecordingGranted = VoiceDictationSketchSession.hasScreenRecordingAccess
    @Published private(set) var remindersAuthorization = RemindersDestination.authorization
    @Published private(set) var deferredPermissions: Set<NanoPermissionKind> = []
    @Published private(set) var savedProgress: NanoOnboardingProgress?

    let settings: NanoSettings
    let viewModel: IslandViewModel
    let isReplay: Bool
    let permissions: NanoPermissionMonitor
    private let onComplete: () -> Void

    private var closed = false
    private var seededAgents = false
    private var opensSettingsWhenClosed = false
    private var remindersPrompt: EKEventStore?
    private var appliedPicks: Set<OnboardingFeature>?
    /// Asked off the main thread and kept, because the check sends Apple
    /// Events and the card reads it on every render.
    @Published private var automationState: NanoPermissionState = .unknown
    private var cancellables: Set<AnyCancellable> = []
    private var timers: [Task<Void, Never>] = []

    var screenHeight: CGFloat = 982
    /// The menu bar and the Dock, which the card stays clear of.
    var menuBarHeight: CGFloat = 24
    var dockHeight: CGFloat = 0

    static let windowWidth: CGFloat = 560
    static let restingTop: CGFloat = 96
    static let tether: CGFloat = 28

    init(settings: NanoSettings, viewModel: IslandViewModel, isReplay: Bool, onComplete: @escaping () -> Void) {
        self.settings = settings
        self.viewModel = viewModel
        self.isReplay = isReplay
        self.onComplete = onComplete
        permissions = NanoPermissionMonitor(viewModel: viewModel)
        let saved = isReplay ? nil : settings.onboardingProgress
        savedProgress = saved
        if let saved {
            let restored = Set(saved.picks.compactMap(OnboardingFeature.init(rawValue:)))
            picks = restored
            switch saved.step {
            case .welcome, .pick: appliedPicks = nil
            case .room, .summary: appliedPicks = restored
            }
        } else {
            let startingPicks = Self.initialPicks(settings: settings, isReplay: isReplay)
            picks = startingPicks
            appliedPicks = isReplay ? startingPicks : nil
        }
        let hooks = AgentHookBridge.installedHookConfigURLs()
        agentPhase = (isReplay || saved != nil) && !hooks.isEmpty ? .done : .pick
        installedHooks = hooks
        detectedAgents = Set(AgentHookBridge.installationProviders(Set(NanoOnboardingPlan.agentProviders)))

        viewModel.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
        viewModel.voiceDictation.modelStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
        permissions.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
        viewModel.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                Task { @MainActor in self?.islandPhaseChanged(phase) }
            }
            .store(in: &cancellables)
    }

    private static func initialPicks(settings: NanoSettings, isReplay: Bool) -> Set<OnboardingFeature> {
        guard isReplay else { return [] }
        var picks = Set(OnboardingFeature.offered.filter { $0.module.map(settings.isEnabled) ?? false })
        if OnboardingFeature.hudSources.contains(where: settings.isNotificationEnabled) {
            picks.insert(.notifications)
        }
        return picks
    }

    var word: String { settings.placement == .attached ? "notch" : "island" }

    var orderedPicks: [OnboardingFeature] { OnboardingFeature.offered.filter(picks.contains) }

    var dashboardPicks: [OnboardingFeature] { orderedPicks.filter(\.isDashboardModule) }

    var rooms: [OnboardingRoom] {
        var rooms: [OnboardingRoom] = []
        if picks.contains(.notifications) { rooms.append(.notifications) }
        if picks.contains(.agents) { rooms.append(.agents) }
        if picks.contains(.quill) { rooms += [.voice, .sketch] }
        if picks.contains(.cue) { rooms.append(.cue) }
        if picks.contains(.mixer) { rooms.append(.mixer) }
        if !dashboardPicks.isEmpty { rooms.append(.dashboard) }
        return rooms
    }

    var currentRoom: OnboardingRoom? {
        guard case let .room(index) = step, rooms.indices.contains(index) else { return nil }
        return rooms[index]
    }

    var windowShown: Bool {
        switch step {
        case .resume, .welcome, .pick, .room, .summary: true
        default: false
        }
    }

    var progressCount: Int { rooms.count + Self.stepsBesideRooms }

    private static let stepsBesideRooms = [Step.welcome, .pick, .summary].count

    var progressIndex: Int {
        switch step {
        case .welcome: 0
        case .pick: 1
        case let .room(index): index + 2
        case .summary: progressCount - 1
        default: 0
        }
    }

    @Published var windowHeight: CGFloat = 600

    var windowTop: CGFloat {
        let tethered = currentRoom == .agents && agentPhase == .test
        guard tethered, viewModel.phase != .idleCompact else {
            return max(lowestTop, min(Self.restingTop, screenHeight - dockHeight - windowHeight - 16))
        }
        let chrome: CGFloat = viewModel.phase.showsChrome ? 44 : 0
        let wanted = max(Self.restingTop, viewModel.preferredSize.height + chrome + Self.tether)
        return max(Self.restingTop, min(wanted, screenHeight - dockHeight - windowHeight - 12))
    }

    /// Just under the resting island, and under the menu bar.
    private var lowestTop: CGFloat {
        let gap: CGFloat = settings.placement == .floating ? 8 : 0
        let island = viewModel.phase == .idleCompact
            ? viewModel.preferredSize.height
            : IslandPhase.idleCompact.preferredSize.height
        return max(menuBarHeight, gap + island) + 12
    }

    /// The tallest the card can be and still sit between the island and the Dock.
    var maxWindowHeight: CGFloat {
        screenHeight - dockHeight - 16 - lowestTop
    }

    var dimOpacity: Double {
        switch step {
        case .arrival(.quiet): 0
        case .arrival: 0.55
        case .resume, .welcome, .pick, .room, .summary: 0.5
        case .finale(.fading): 0
        case .finale: 0.4
        }
    }

    var auroraStrength: Double {
        switch step {
        case .arrival(.quiet), .finale(.fading): 0
        case .arrival, .finale: 1
        case .resume, .welcome, .pick, .room, .summary: 0.4
        }
    }

    static let auroraFade: Double = 2.4

    var showsArrivalPrompt: Bool { step == .arrival(.prompt) }

    func start() {
        guard savedProgress == nil else {
            step = .resume
            syncIsland()
            return
        }
        viewModel.onOnboardingHover = { [weak self] in
            guard let self, self.step == .arrival(.greeting) || self.step == .arrival(.prompt) else { return }
            self.openWindow()
        }
        syncIsland()
        later(0.7) { [weak self] in
            guard let self, self.step == .arrival(.quiet) else { return }
            self.step = .arrival(.greeting)
            self.syncIsland()
        }
        later(2.9) { [weak self] in
            guard let self, self.step == .arrival(.greeting) else { return }
            self.step = .arrival(.prompt)
            self.syncIsland()
        }
    }

    func openWindow() {
        guard case .arrival = step else { return }
        cancelTimers()
        viewModel.collapseIncludingPinned()
        enter(.welcome)
    }

    func setUpLater() {
        guard step != .summary, !isFinale else { return }
        cancelTimers()
        leaveRoom()
        settings.completeOnboarding()
        viewModel.onboardingIsland = nil
        fadeOut()
    }

    private var isFinale: Bool {
        if case .finale = step { return true }
        return false
    }

    private func islandPhaseChanged(_ phase: IslandPhase) {
        if currentRoom == .agents, agentPhase == .test, phase != .transientHUD {
            agentPhase = .done
        }
    }

    var resumeTarget: Step {
        guard let saved = savedProgress else { return .welcome }
        switch saved.step {
        case .welcome: return .welcome
        case .pick: return .pick
        case .summary: return .summary
        case let .room(room): return rooms.firstIndex(of: room).map(Step.room) ?? .summary
        }
    }

    var resumeTitle: String {
        switch resumeTarget {
        case .welcome: "Welcome"
        case .pick: "Pick"
        case .summary: "Summary"
        case let .room(index): rooms[index].title
        default: "Setup"
        }
    }

    func continueSetup() {
        let target = resumeTarget
        savedProgress = nil
        enter(target)
    }

    func startOver() {
        savedProgress = nil
        enter(.welcome)
    }

    func turnOnLoginItemOnce() {
        guard !isReplay, !settings.defaults.bool(forKey: "onboarding.loginItemOffered") else { return }
        settings.defaults.set(true, forKey: "onboarding.loginItemOffered")
        if !viewModel.loginItem.isEnabled, !viewModel.loginItem.needsApproval {
            viewModel.loginItem.setEnabled(true)
        }
    }

    func isPicked(_ feature: OnboardingFeature) -> Bool { picks.contains(feature) }

    func stepShowcase(by offset: Int) {
        guard step == .pick else { return }
        let count = OnboardingFeature.offered.count
        showcaseIndex = (showcaseIndex + offset + count) % count
    }

    func toggle(_ feature: OnboardingFeature) {
        if picks.contains(feature) {
            picks.remove(feature)
        } else {
            picks.insert(feature)
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let index = showcaseIndex
            later(0.55) { [weak self] in
                guard let self, self.step == .pick, self.showcaseIndex == index else { return }
                self.showcaseIndex = (index + 1) % OnboardingFeature.offered.count
            }
        }
        saveProgress()
    }

    func startRooms() {
        guard !picks.isEmpty else { return }
        applyPicks()
        enter(rooms.isEmpty ? .summary : .room(0))
    }

    func justTheIsland() {
        picks.removeAll()
        applyPicks()
        enter(.summary)
    }

    private func applyPicks() {
        let changed = appliedPicks.map { picks.symmetricDifference($0) } ?? Set(OnboardingFeature.allCases)
        appliedPicks = picks
        if changed.contains(.notifications) {
            let batteryModuleOn = settings.isEnabled(.battery)
            let picked = picks.contains(.notifications)
            for source in OnboardingFeature.hudSources {
                settings.setNotificationEnabled(picked, for: source)
            }
            set(.battery, batteryModuleOn)
        }
        for feature in OnboardingFeature.allCases where changed.contains(feature) {
            guard let module = feature.module else { continue }
            set(module, picks.contains(feature) && (feature != .camera || NanoCameraPresence.hasDevice))
        }
        arrangeDashboard(only: changed)
    }

    private func set(_ module: NanoModuleID, _ enabled: Bool) {
        if settings.isEnabled(module) != enabled { settings.setEnabled(enabled, for: module) }
    }

    func next() {
        switch step {
        case .welcome: enter(.pick)
        case let .room(index): enter(index < rooms.count - 1 ? .room(index + 1) : .summary)
        default: break
        }
    }

    func back() {
        switch step {
        case .pick: enter(.welcome)
        case let .room(index): enter(index > 0 ? .room(index - 1) : .pick)
        case .summary: enter(rooms.isEmpty ? .pick : .room(rooms.count - 1))
        default: break
        }
    }

    func turnOffSketchAndContinue() {
        settings.voiceDictationSketchEnabled = false
        next()
    }

    private func enter(_ destination: Step) {
        leaveRoom()
        step = destination
        syncIsland()
        refreshSystemState()
        saveProgress()
    }

    private func leaveRoom() {
        if agentPhase == .test { skipAgentTest() }
    }

    private func saveProgress() {
        guard !isReplay, savedProgress == nil else { return }
        let stop: NanoOnboardingStop
        switch step {
        case .welcome: stop = .welcome
        case .pick: stop = .pick
        case .summary: stop = .summary
        case .room: stop = currentRoom.map(NanoOnboardingStop.room) ?? .summary
        default: return
        }
        settings.onboardingProgress = NanoOnboardingProgress(
            step: stop,
            picks: picks.map(\.rawValue).sorted(),
            savedAt: Date()
        )
    }

    func refreshSystemState() {
        installedHooks = AgentHookBridge.installedHookConfigURLs()
        accessibilityTrusted = NanoAccessibilityPermission.isTrusted
        bluetoothAuthorization = CBManager.authorization
        screenRecordingGranted = VoiceDictationSketchSession.hasScreenRecordingAccess
        remindersAuthorization = RemindersDestination.authorization
        viewModel.calendarService.refreshAuthorization()
        viewModel.voiceDictation.refreshMicrophoneAuthorization()
        permissions.refresh()
        Task { [weak self] in
            let checked = await Task.detached(priority: .utility) {
                (
                    fullDisk: NotificationCenterStore.storeIsReadable || NanoFullDiskAccess.hasAccess,
                    automation: NanoAutomationPermission.state
                )
            }.value
            self?.fullDiskAccess = checked.fullDisk
            self?.automationState = checked.automation
        }
    }

    /// Asked again shortly after a request, once macOS has answered.
    private func refreshSoon() {
        later(0.6) { [weak self] in self?.refreshSystemState() }
        later(2.0) { [weak self] in self?.refreshSystemState() }
    }

    func requestAccessibility() {
        if !NanoAccessibilityPermission.requestIfNeeded() {
            NanoPrivacySettings.open(NanoPermissionKind.accessibility.settingsAnchor)
        }
        refreshSoon()
    }

    func setSystemCards(_ on: Bool) {
        settings.hudReplacesSystemHUD = on
        if on, !accessibilityTrusted { requestAccessibility() }
    }

    var bluetoothDenied: Bool { [.denied, .restricted].contains(bluetoothAuthorization) }

    func requestBluetooth() {
        if bluetoothAuthorization == .notDetermined {
            NotificationCenter.default.publisher(for: NanoBluetoothPermission.didChange)
                .first()
                .sink { [weak self] _ in self?.refreshSystemState() }
                .store(in: &cancellables)
        }
        NanoBluetoothPermission.request()
        refreshSoon()
    }

    var selectedAgents: Set<AgentProviderID> {
        settings.enabledAgentProviders.intersection(NanoOnboardingPlan.agentProviders)
    }

    var offeredAgents: [AgentProviderID] {
        NanoOnboardingPlan.agentProviders.filter(detectedAgents.contains)
    }

    var connectableAgents: [AgentProviderID] {
        AgentHookBridge.installationProviders(selectedAgents)
    }

    func isConnected(_ provider: AgentProviderID) -> Bool {
        let installed = Set(installedHooks.map(\.standardizedFileURL))
        let files = AgentHookBridge.installationConfigURLs(for: [provider]).map(\.standardizedFileURL)
        return !files.isEmpty && files.allSatisfy(installed.contains)
    }

    var connectedCount: Int { offeredAgents.filter(isConnected).count }

    func toggleAgent(_ provider: AgentProviderID) {
        settings.setAgentProviderEnabled(!settings.isAgentProviderEnabled(provider), provider: provider)
    }

    func seedAgentsIfNeeded() {
        guard !seededAgents else { return }
        seededAgents = true
        guard !isReplay, !detectedAgents.isEmpty, installedHooks.isEmpty else { return }
        for provider in NanoOnboardingPlan.agentProviders {
            settings.setAgentProviderEnabled(detectedAgents.contains(provider), provider: provider)
        }
    }

    func connectAgents() {
        agentPhase = .connecting
        hookFailures = []
        let chosen = Set(connectableAgents)
        viewModel.hookBridge.installHooks(for: chosen)
        let expected = AgentHookBridge.installationConfigURLs(for: chosen)
        let installed = Set(AgentHookBridge.installedHookConfigURLs().map(\.standardizedFileURL))
        let missing = expected.filter { !installed.contains($0.standardizedFileURL) }
        later(0.6) { [weak self] in
            guard let self else { return }
            self.installedHooks = AgentHookBridge.installedHookConfigURLs()
            guard missing.isEmpty else {
                self.hookFailures = missing
                self.agentPhase = .pick
                return
            }
            self.agentPhase = .test
            self.viewModel.previewNotification(.agentPreview(provider: self.testAgent, kind: .permission))
        }
    }

    var testAgent: AgentProviderID {
        NanoOnboardingPlan.agentProviders.first(where: connectableAgents.contains) ?? .claude
    }

    func skipAgentTest() {
        viewModel.collapse()
        agentPhase = .done
    }

    func setConnected(_ provider: AgentProviderID, _ connected: Bool) {
        if connected {
            settings.setAgentProviderEnabled(true, provider: provider)
            viewModel.hookBridge.installHooks(for: [provider])
        } else {
            viewModel.hookBridge.uninstallHooks(for: [provider])
            settings.setAgentProviderEnabled(false, provider: provider)
        }
        installedHooks = AgentHookBridge.installedHookConfigURLs()
    }

    func requestMicrophone() {
        let dictation = viewModel.voiceDictation
        if dictation.microphoneAuthorization == .notDetermined {
            dictation.requestMicrophoneAccess()
        } else {
            NanoPrivacySettings.open(NanoPermissionKind.microphone.settingsAnchor)
        }
        refreshSoon()
    }

    func requestScreenRecording() {
        guard !screenRecordingGranted else { return }
        VoiceDictationSketchSession.requestScreenRecordingAccess()
        refreshSoon()
    }

    var remindersGranted: Bool { remindersAuthorization == .fullAccess }

    func requestReminders() {
        guard remindersAuthorization == .notDetermined else {
            NanoPrivacySettings.open("Privacy_Reminders")
            return refreshSoon()
        }
        let store = EKEventStore()
        remindersPrompt = store
        Task { [weak self] in
            _ = await RemindersDestination.requestFullAccess(with: store)
            self?.refreshSystemState()
        }
    }

    func connectMixer() {
        let store = viewModel.mixerStore
        store.setEnabled(true)
        store.connect()
    }

    private static let defaultAreas: [NanoModuleID: [DashboardArea]] = [
        .music: [.area1, .area2],
        .calendar: [.area2, .area1, .area3, .area4],
        .weather: [.area3, .area4, .area2],
        .timer: [.area4, .area3, .area5, .area6],
        .camera: [.area5, .area6, .area3, .area4],
        .battery: [.area3, .area4],
    ]

    private func arrangeDashboard(only changed: Set<OnboardingFeature>? = nil) {
        for feature in dashboardPicks where changed?.contains(feature) ?? true {
            guard let module = feature.module, settings.isEnabled(module) else { continue }
            guard !DashboardArea.allCases.contains(where: { settings.dashboardFeature(in: $0) == module }) else { continue }
            let free = Self.defaultAreas[module]?.first { area in
                settings.visibleDashboardFeature(in: area) == nil && area.compatibleModules.contains(module)
            }
            if let free { settings.setDashboardFeature(module, in: free) }
        }
    }

    var pendingPermissions: [(feature: OnboardingFeature, kind: NanoPermissionKind)] {
        dashboardPicks.compactMap { feature in
            guard let kind = feature.permission, let module = feature.module,
                  settings.isEnabled(module), needsGrant(kind) else { return nil }
            return (feature, kind)
        }
    }

    var currentPermission: (feature: OnboardingFeature, kind: NanoPermissionKind)? {
        pendingPermissions.first { !deferredPermissions.contains($0.kind) }
    }

    func deferPermission(_ kind: NanoPermissionKind) {
        deferredPermissions.insert(kind)
    }

    func needsGrant(_ kind: NanoPermissionKind) -> Bool {
        switch kind {
        case .calendar: viewModel.calendarService.authorizationStatus != .fullAccess
        case .location:
            ![.authorized, .authorizedAlways].contains(viewModel.weatherService.authorizationStatus)
        case .camera:
            NanoCameraPresence.hasDevice && AVCaptureDevice.authorizationStatus(for: .video) != .authorized
        // Unknown means no player is open to ask, which is not a refusal.
        case .automation: automationState == .needsGrant || automationState == .partial
        default: false
        }
    }

    func requestPermission(_ kind: NanoPermissionKind) {
        switch kind {
        case .calendar:
            if viewModel.calendarService.authorizationStatus == .notDetermined {
                viewModel.calendarService.requestAccess()
            } else {
                NanoPrivacySettings.open(kind.settingsAnchor)
            }
        case .location:
            if viewModel.weatherService.authorizationStatus == .notDetermined {
                viewModel.weatherService.requestAuthorization()
            } else {
                NanoPrivacySettings.open(kind.settingsAnchor)
            }
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                viewModel.cameraService.requestAccess()
            } else {
                NanoPrivacySettings.open(kind.settingsAnchor)
            }
        case .automation:
            if !NanoAutomationPermission.requestConsent() {
                NanoPrivacySettings.open(kind.settingsAnchor)
            }
        default:
            NanoPrivacySettings.open(kind.settingsAnchor)
        }
        refreshSoon()
    }

    var enabledSummary: [String] {
        var items = ["\(settings.placement.title), \(settings.appearance.title)"]
        if picks.contains(.notifications) {
            items.append(settings.hudReplacesSystemHUD ? "Volume cards" : "Notifications")
        }
        if picks.contains(.agents) {
            let count = connectedCount
            items.append(count == 0 ? "Agents" : "\(count) agent\(count == 1 ? "" : "s")")
        }
        if picks.contains(.quill) { items.append("Quill") }
        if picks.contains(.quill), settings.voiceDictationSketchEnabled { items.append("Sketch") }
        for feature in orderedPicks where ![.notifications, .agents, .quill].contains(feature) {
            items.append(feature.title)
        }
        return items
    }

    var missingPermissions: [NanoPermissionKind] { permissions.missing }

    func allow(_ kind: NanoPermissionKind) {
        permissions.handle(kind)
        refreshSoon()
    }

    func finish(openingSettings: Bool = false) {
        guard windowShown else { return }
        leaveRoom()
        if step == .pick { applyPicks() }
        settings.completeOnboarding()
        opensSettingsWhenClosed = openingSettings
        step = .finale(.folding)
        syncIsland()
        later(0.65) { [weak self] in
            self?.step = .finale(.goodbye)
            self?.syncIsland()
        }
        later(2.4) { [weak self] in self?.fadeOut() }
    }

    private func fadeOut() {
        step = .finale(.fading)
        later(Self.auroraFade) { [weak self] in self?.close() }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        cancelTimers()
        viewModel.onboardingIsland = nil
        viewModel.onOnboardingHover = nil
        cancellables.removeAll()
        let opensSettings = opensSettingsWhenClosed
        onComplete()
        if opensSettings {
            NotificationCenter.default.post(name: .nanoOpenSettings, object: SettingsDestination.general.rawValue)
        }
    }

    func tearDown() {
        cancelTimers()
        viewModel.onboardingIsland = nil
        viewModel.onOnboardingHover = nil
        cancellables.removeAll()
    }

    func jump(to target: String) {
        cancelTimers()
        leaveRoom()
        viewModel.collapseIncludingPinned()
        switch target {
        case "opening":
            savedProgress = nil
            step = .arrival(.quiet)
            start()
        case "welcome":
            step = .welcome
            syncIsland()
        case "pick":
            step = .pick
            syncIsland()
        case "resume":
            savedProgress = NanoOnboardingProgress(step: .room(.voice),
                                                   picks: OnboardingFeature.offered.map(\.rawValue),
                                                   savedAt: Date().addingTimeInterval(-86_400))
            picks = Set(OnboardingFeature.offered)
            appliedPicks = picks
            step = .resume
            syncIsland()
        case "summary":
            step = .summary
            syncIsland()
        case "ending":
            step = .summary
            finish()
        default:
            picks = Set(OnboardingFeature.offered)
            appliedPicks = picks
            agentPhase = .pick
            step = .room(rooms.firstIndex { $0.rawValue == target } ?? 0)
            syncIsland()
            refreshSystemState()
        }
    }

    private func syncIsland() {
        let content: OnboardingIslandContent?
        let home = settings.placement == .attached ? "around the notch" : "under the menu bar"
        switch step {
        case .arrival(.greeting), .arrival(.prompt):
            content = isReplay
                ? .greeting(title: "Welcome back.", detail: nil)
                : .greeting(title: "Hi, I'm Nano.", detail: "I live up here, \(home).")
        case .resume: content = .greeting(title: "Welcome back.", detail: nil)
        case .welcome, .pick, .room, .summary: content = .watching
        case .finale(.goodbye): content = .done
        default: content = nil
        }
        viewModel.onboardingIsland = content
    }

    private func later(_ seconds: Double, _ action: @escaping @MainActor () -> Void) {
        timers.append(Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            action()
        })
    }

    private func cancelTimers() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
    }
}
