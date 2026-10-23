import AppKit
import ApplicationServices
import AVFoundation
import Contacts
import CoreBluetooth
import CoreLocation
import Darwin
import EventKit
import SwiftUI

enum NanoPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case accessibility
    case calendar
    case camera
    case microphone
    case location
    case bluetooth
    case automation
    case fullDisk
    case contacts
    case screenRecording
    case reminders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .calendar: "Calendar"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .bluetooth: "Bluetooth"
        case .automation: "Automation"
        case .fullDisk: "Full Disk Access"
        case .contacts: "Contacts"
        case .screenRecording: "Screen Recording"
        case .reminders: "Reminders"
        }
    }

    var detail: String {
        switch self {
        case .accessibility: "Paste dictation, jump to an agent session, and hide macOS banners the island already shows."
        case .calendar: "Upcoming events from Apple Calendar in the island."
        case .camera: "A private live preview. Nano never records it."
        case .microphone: "Voice dictation while the shortcut is held. Audio stays on this Mac."
        case .location: "Local weather in the island."
        case .bluetooth: "AirPods and accessory connect alerts."
        case .automation: "Music, Spotify, iMessage replies, and jumping into Cursor or T3 Code."
        case .fullDisk: "macOS notifications in the island, from iMessage, calls, Mail, and every app."
        case .contacts: "Sender photos on iMessage cards."
        case .screenRecording: "Sketch captures what you mark on the screen."
        case .reminders: "Cue syncs with the Reminders lists you link."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "hand.raised.fill"
        case .calendar: "calendar"
        case .camera: "camera.fill"
        case .microphone: "mic.fill"
        case .location: "location.fill"
        case .bluetooth: "wave.3.right"
        case .automation: "arrow.left.arrow.right.circle.fill"
        case .fullDisk: "externaldrive.fill"
        case .contacts: "person.crop.circle.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .reminders: "list.bullet"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .calendar: "Privacy_Calendars"
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .location: "Privacy_LocationServices"
        case .bluetooth: "Privacy_Bluetooth"
        case .automation: "Privacy_Automation"
        case .fullDisk: "Privacy_AllFiles"
        case .contacts: "Privacy_Contacts"
        case .screenRecording: "Privacy_ScreenCapture"
        case .reminders: "Privacy_Reminders"
        }
    }
}

enum NanoPermissionState: Equatable, Sendable {
    case granted
    case needsGrant
    case unavailable
    case partial
    case unknown
}

/// Live permission state for Settings. The sidebar badge, the General banner,
/// and the Permissions page all read this one object, so their counts agree.
@MainActor
final class NanoPermissionMonitor: ObservableObject {
    @Published private var expensiveStates: [NanoPermissionKind: NanoPermissionState] = [:]
    /// Bumped on refresh so views that read the cheap, synchronous states re-render.
    @Published private var generation = 0

    private let viewModel: IslandViewModel
    private var refreshTask: Task<Void, Never>?
    private var bluetoothObserver: NSObjectProtocol?

    init(viewModel: IslandViewModel) {
        self.viewModel = viewModel
        bluetoothObserver = NotificationCenter.default.addObserver(
            forName: NanoBluetoothPermission.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var rows: [(kind: NanoPermissionKind, state: NanoPermissionState)] {
        _ = generation
        return NanoPermissionKind.allCases.map { ($0, state(for: $0)) }
    }

    /// Permissions that exist on this Mac, are not granted, and are needed by
    /// something that is switched on. A feature that is off asks for nothing,
    /// so it adds nothing to the badge or the General banner.
    var missing: [NanoPermissionKind] {
        rows.filter { $0.state == .needsGrant && isNeeded($0.kind) }.map(\.kind)
    }

    /// "8 of 8 granted, 1 unavailable". Rows this Mac cannot grant, and rows
    /// macOS cannot answer for yet, are named instead of counted as refused.
    var summary: String {
        let states = rows.map(\.state)
        let unavailable = states.filter { $0 == .unavailable }.count
        let unchecked = states.filter { $0 == .unknown }.count
        let granted = states.filter { $0 == .granted }.count
        var text = "\(granted) of \(states.count - unavailable - unchecked) granted"
        if unavailable > 0 { text += ", \(unavailable) unavailable" }
        if unchecked > 0 { text += ", \(unchecked) not checked yet" }
        return text
    }

    /// Whether anything that is switched on uses this permission.
    private func isNeeded(_ kind: NanoPermissionKind) -> Bool {
        let settings = viewModel.settings
        let systemNotifications = settings.isNotificationEnabled(.system)
        switch kind {
        case .accessibility:
            let mediaKeys = settings.hudReplacesSystemHUD
                && (settings.isNotificationEnabled(.volume) || settings.isNotificationEnabled(.brightness))
            return settings.isEnabled(.voiceDictation)
                || settings.isEnabled(.agents)
                || mediaKeys
                || (systemNotifications && settings.systemNotificationsHideNativeBanner)
                || (settings.isEnabled(.cue) && settings.cuePullsSelection)
        case .calendar:
            return settings.isEnabled(.calendar)
        case .camera:
            return settings.isEnabled(.camera)
        case .microphone:
            return settings.isEnabled(.voiceDictation)
        case .location:
            return settings.isEnabled(.weather) && settings.weatherUsesCurrentLocation
        case .bluetooth:
            return settings.isNotificationEnabled(.bluetooth)
        case .automation:
            return settings.isEnabled(.music)
                || settings.isEnabled(.agents)
                || (systemNotifications && settings.systemNotificationsInlineReply)
        case .fullDisk:
            return systemNotifications
        case .contacts:
            return systemNotifications && settings.systemNotificationsContactPhotos
        case .screenRecording:
            return settings.isEnabled(.voiceDictation) && settings.voiceDictationSketchEnabled
        case .reminders:
            return settings.isEnabled(.cue)
                && viewModel.cueSync.state.destinations.contains { $0.kind == RemindersDestination.kind }
        }
    }

    func handle(_ kind: NanoPermissionKind) {
        switch state(for: kind) {
        case .unavailable:
            break
        case .granted, .partial, .unknown:
            openPrivacySettings(kind.settingsAnchor)
        case .needsGrant:
            request(kind)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.refresh()
        }
    }

    func refresh() {
        viewModel.calendarService.refreshAuthorization()
        viewModel.contactPhotos.refreshAuthorization()
        generation += 1
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            let states = await Task.detached(priority: .utility) {
                let fullDisk = NotificationCenterStore.storeIsReadable
                    || NanoFullDiskAccess.hasAccess
                return [
                    NanoPermissionKind.automation: NanoAutomationPermission.state,
                    NanoPermissionKind.fullDisk: fullDisk ? NanoPermissionState.granted : .needsGrant,
                ]
            }.value
            guard !Task.isCancelled else { return }
            self?.expensiveStates = states
        }
    }

    func request(_ kind: NanoPermissionKind) {
        switch kind {
        case .accessibility:
            if NanoAccessibilityPermission.requestIfNeeded() {
                refresh()
            } else {
                openPrivacySettings(kind.settingsAnchor)
            }
        case .calendar:
            if viewModel.calendarService.authorizationStatus == .notDetermined {
                viewModel.calendarService.requestAccess()
            } else {
                openPrivacySettings(kind.settingsAnchor)
            }
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                viewModel.cameraService.requestAccess()
            } else {
                openPrivacySettings(kind.settingsAnchor)
            }
        case .microphone:
            if viewModel.voiceDictation.microphoneAuthorization == .notDetermined {
                viewModel.voiceDictation.requestMicrophoneAccess()
            } else {
                openPrivacySettings(kind.settingsAnchor)
            }
        case .location:
            switch NanoLocationPermission.grantAction(
                status: viewModel.weatherService.authorizationStatus,
                servicesEnabled: CLLocationManager.locationServicesEnabled()
            ) {
            case .requestAndOpenSettings:
                viewModel.weatherService.requestAuthorization()
                openPrivacySettings(kind.settingsAnchor)
            case .openSettings:
                openPrivacySettings(kind.settingsAnchor)
            }
        case .automation:
            if NanoAutomationPermission.requestConsent() {
                refresh()
            } else {
                openPrivacySettings(kind.settingsAnchor)
            }
        case .contacts:
            switch NanoContactsPermission.grantAction(status: viewModel.contactPhotos.authorization) {
            case .request:
                viewModel.contactPhotos.requestAccess()
            case .openSettings:
                openPrivacySettings(kind.settingsAnchor)
            }
        case .screenRecording:
            VoiceDictationSketchSession.requestScreenRecordingAccess()
        case .reminders:
            if RemindersDestination.authorization == .notDetermined {
                Task { [weak self] in
                    _ = await RemindersDestination.requestFullAccess()
                    self?.refresh()
                }
            } else {
                openPrivacySettings(kind.settingsAnchor)
            }
        case .bluetooth:
            NanoBluetoothPermission.request()
        case .fullDisk:
            NanoFullDiskAccess.request()
        }
    }

    func state(for kind: NanoPermissionKind) -> NanoPermissionState {
        switch kind {
        case .accessibility:
            return NanoAccessibilityPermission.isTrusted ? .granted : .needsGrant
        case .calendar:
            switch viewModel.calendarService.authorizationStatus {
            case .fullAccess: return .granted
            default: return .needsGrant
            }
        case .camera:
            guard NanoCameraPresence.hasDevice else { return .unavailable }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                return NanoCameraPresence.hasDevice ? .granted : .unavailable
            default:
                return .needsGrant
            }
        case .microphone:
            return viewModel.voiceDictation.microphoneAuthorization == .authorized ? .granted : .needsGrant
        case .location:
            switch viewModel.weatherService.authorizationStatus {
            case .authorized, .authorizedAlways, .authorizedWhenInUse: return .granted
            default: return .needsGrant
            }
        case .bluetooth:
            return CBManager.authorization == .allowedAlways ? .granted : .needsGrant
        case .automation:
            return expensiveStates[.automation] ?? .unknown
        case .fullDisk:
            return expensiveStates[.fullDisk] ?? .unknown
        case .contacts:
            switch viewModel.contactPhotos.authorization {
            case .authorized: return .granted
            case .notDetermined: return .needsGrant
            default: return .needsGrant
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .needsGrant
        case .reminders:
            return RemindersDestination.hasAccess ? .granted : .needsGrant
        }
    }
}

/// Keeps a monitor fresh while its view is on screen.
struct NanoPermissionRefresh: ViewModifier {
    @ObservedObject var monitor: NanoPermissionMonitor
    @ObservedObject var viewModel: IslandViewModel

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                monitor.refresh()
            }
            .onChange(of: viewModel.calendarService.authorizationStatus) { _, _ in monitor.refresh() }
            .onChange(of: viewModel.cameraService.availability) { _, _ in monitor.refresh() }
            .onChange(of: viewModel.weatherService.authorizationStatus) { _, _ in monitor.refresh() }
            .onChange(of: viewModel.voiceDictation.microphoneAuthorization) { _, _ in monitor.refresh() }
            .onChange(of: viewModel.contactPhotos.authorization) { _, _ in monitor.refresh() }
    }
}

/// Settings → Permissions.
struct PermissionsSettingsPane: View {
    @ObservedObject var monitor: NanoPermissionMonitor

    var body: some View {
        SettingsPage(
            title: "Permissions",
            symbol: "hand.raised",
            subtitle: "What Nano can reach on this Mac. Nothing it reads leaves it."
        ) {
            SettingsSection(trailing: monitor.summary) {
                ForEach(monitor.rows, id: \.kind) { row in
                    SettingsRow(row.kind.title, symbol: row.kind.symbol, subtitle: row.kind.detail) {
                        status(row.kind, row.state)
                    }
                    .opacity(row.state == .unavailable ? 0.5 : 1)
                    .settingsAnchor("perm.\(row.kind.rawValue)")
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(
                        row.kind == .automation && row.state == .unknown ? Self.automationUnchecked : label(row.state)
                    )
                }
            }
        }
    }

    /// Automation is granted per app, and macOS only answers for an app that
    /// is running.
    private static let automationUnchecked = "Checked when the app is open"

    @ViewBuilder
    private func status(_ kind: NanoPermissionKind, _ state: NanoPermissionState) -> some View {
        switch state {
        case .granted:
            Button {
                monitor.handle(kind)
            } label: {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open \(kind.title) in System Settings")
        case .needsGrant:
            Button("Grant") { monitor.handle(kind) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .unavailable:
            Text("Unavailable").foregroundStyle(.tertiary)
        case .unknown where kind == .automation:
            Button {
                monitor.handle(kind)
            } label: {
                Text(Self.automationUnchecked)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open \(kind.title) in System Settings")
        case .partial, .unknown:
            Button(label(state)) { monitor.handle(kind) }
                .controlSize(.small)
        }
    }

    private func label(_ state: NanoPermissionState) -> String {
        switch state {
        case .granted: "Granted"
        case .needsGrant: "Not granted"
        case .unavailable: "Unavailable"
        case .partial: "Some granted"
        case .unknown: "Check"
        }
    }
}

func openPrivacySettings(_ anchor: String) {
    NanoPrivacySettings.open(anchor)
}

enum NanoPrivacySettings {
    static func open(_ anchor: String) {
        for url in urls(for: anchor) where NSWorkspace.shared.open(url) {
            return
        }
    }

    static func urls(for anchor: String) -> [URL] {
        [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
        ].compactMap(URL.init(string:))
    }
}

enum NanoContactsPermission {
    enum GrantAction: Equatable {
        case request
        case openSettings
    }

    static func grantAction(status: CNAuthorizationStatus) -> GrantAction {
        switch status {
        case .notDetermined: return .request
        default: return .openSettings
        }
    }
}

enum NanoLocationPermission {
    enum GrantAction: Equatable {
        case requestAndOpenSettings
        case openSettings
    }

    static func grantAction(
        status: CLAuthorizationStatus,
        servicesEnabled: Bool
    ) -> GrantAction {
        _ = servicesEnabled
        switch status {
        case .notDetermined: return .requestAndOpenSettings
        default: return .openSettings
        }
    }
}

enum NanoFullDiskAccess {
    /// macOS never adds an app to Full Disk Access by itself, so this opens
    /// the list with a small window beside it holding Nano's icon to drag in.
    @MainActor
    static func request() {
        NanoPrivacySettings.open(NanoPermissionKind.fullDisk.settingsAnchor)
        NanoDragToGrantPanel.shared.show(app: installedApp) { hasAccess }
    }

    /// The copy in Applications. A Nano opened straight from the DMG or a
    /// download runs from a temporary copy that isn't worth dragging.
    static var installedApp: URL {
        let applications = URL(fileURLWithPath: "/Applications/Nano.app")
        return FileManager.default.fileExists(atPath: applications.path) ? applications : Bundle.main.bundleURL
    }

    static var hasAccess: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = NotificationCenterStore.candidatePaths + [
            URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"),
            home.appendingPathComponent("Library/Messages/chat.db"),
            home.appendingPathComponent("Library/Safari/Bookmarks.plist"),
            home.appendingPathComponent("Library/Mail"),
        ]
        return probes.contains { canOpen($0) }
    }

    private static func canOpen(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue {
            return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
        }
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}

enum NanoCameraPresence {
    static var hasDevice: Bool {
        !AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera,
                .deskViewCamera,
            ],
            mediaType: .video,
            position: .unspecified
        ).devices.isEmpty
    }
}

enum NanoPermissionDiagnostics {
    static func snapshot(location: CLAuthorizationStatus) -> [String: Any] {
        [
            "calendar": EKEventStore.authorizationStatus(for: .event).rawValue,
            "reminders": EKEventStore.authorizationStatus(for: .reminder).rawValue,
            "camera": AVCaptureDevice.authorizationStatus(for: .video).rawValue,
            "microphone": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "location": location.rawValue,
            "bluetooth": CBManager.authorization.rawValue,
            "contacts": CNContactStore.authorizationStatus(for: .contacts).rawValue,
            "fullDiskReadable": NanoFullDiskAccess.hasAccess,
            "automation": Dictionary(uniqueKeysWithValues: NanoAutomationPermission.targetStatuses.map {
                ($0.name, Int($0.status))
            }),
        ]
    }
}

enum NanoAutomationPermission {
    struct TargetStatus {
        let name: String
        let bundleID: String
        let status: OSStatus
    }

    static func permissionState(for status: OSStatus) -> NanoPermissionState {
        switch status {
        case noErr: .granted
        case OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent): .needsGrant
        default: .unknown
        }
    }

    static func aggregate(_ states: [NanoPermissionState]) -> NanoPermissionState {
        guard !states.isEmpty else { return .unavailable }
        let known = states.filter { $0 == .granted || $0 == .needsGrant }
        if known.isEmpty { return .needsGrant }
        if known.allSatisfy({ $0 == .granted }) { return .granted }
        if known.contains(.granted) { return .partial }
        return .needsGrant
    }

    static var state: NanoPermissionState {
        let states = targetStatuses.map { permissionState(for: $0.status) }
        // No target app is running, so macOS has no answer yet. That is not a
        // refusal: nothing reads "Grant" and nothing is counted as missing.
        if !states.isEmpty, states.allSatisfy({ $0 == .unknown }) { return .unknown }
        return aggregate(states)
    }

    @discardableResult
    static func requestConsent() -> Bool {
        var asked = false
        for target in targetStatuses {
            let state = permissionState(for: target.status)
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).isEmpty
            guard running, state != .granted else { continue }
            _ = status(for: target.bundleID, askUserIfNeeded: true)
            asked = true
        }
        return asked
    }

    static var targetStatuses: [TargetStatus] {
        let targets = [
            ("Music", "com.apple.Music"),
            ("Spotify", "com.spotify.client"),
            ("Cursor", AgentSessionJump.cursorBundleID),
            ("T3 Code", AgentSessionJump.t3BundleID),
        ]
        return targets.compactMap { name, bundleID in
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else { return nil }
            return TargetStatus(
                name: name,
                bundleID: bundleID,
                status: status(for: bundleID, askUserIfNeeded: false)
            )
        }
    }

    private static let missingProcess: OSStatus = OSStatus(procNotFound)

    private static func status(for bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            let target = NSAppleEventDescriptor(processIdentifier: running.processIdentifier)
            if let aeDesc = target.aeDesc {
                let result = AEDeterminePermissionToAutomateTarget(
                    aeDesc,
                    typeWildCard,
                    typeWildCard,
                    askUserIfNeeded
                )
                if result != missingProcess { return result }
            }
        }

        // Addressing an app that is not running by bundle ID can block
        // indefinitely (Cursor did, freezing Nano's main thread and every
        // jump with it). A closed app's consent is unknown until it runs.
        return missingProcess
    }
}

/// A small floating window beside System Settings with Nano's icon, for
/// dragging into a privacy list macOS won't add Nano to by itself. It closes
/// once access is granted, or with its close button.
@MainActor
final class NanoDragToGrantPanel {
    static let shared = NanoDragToGrantPanel()

    private var panel: NSPanel?
    private var watch: Timer?
    private var placed = false

    func show(app: URL, isGranted: @escaping @MainActor () -> Bool) {
        close()
        let size = NSSize(width: 232, height: 196)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: NanoDragToGrantView(app: app).frame(width: size.width, height: size.height))
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(size)
        self.panel = panel
        placed = false
        place()
        panel.orderFrontRegardless()

        var ticks = 0
        watch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ticks += 1
                if !self.placed { self.place() }
                // Granted, or the user gave up: two minutes is plenty.
                if isGranted() || ticks > 240 { self.close() }
            }
        }
    }

    func close() {
        watch?.invalidate()
        watch = nil
        panel?.close()
        panel = nil
    }

    /// Beside System Settings once its window is up, else low on the screen.
    private func place() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        var origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 40)
        if let settings = Self.settingsWindowFrame(on: screen) {
            placed = true
            let right = settings.maxX + 16
            let x = right + size.width <= visible.maxX ? right : settings.minX - size.width - 16
            origin = NSPoint(x: max(visible.minX, x), y: settings.maxY - size.height - 40)
        }
        panel.setFrameOrigin(origin)
    }

    /// System Settings' main window, in AppKit coordinates. Window bounds
    /// are readable without Screen Recording; titles are not needed.
    private static func settingsWindowFrame(on screen: NSScreen) -> NSRect? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frames = info.compactMap { window -> NSRect? in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"],
                  w > 300, h > 200
            else { return nil }
            return NSRect(x: x, y: primaryHeight - y - h, width: w, height: h)
        }
        return frames.max { $0.width * $0.height < $1.width * $1.height }
    }
}

private struct NanoDragToGrantView: View {
    let app: URL

    var body: some View {
        VStack(spacing: 10) {
            NanoDraggableAppIcon(app: app)
                .frame(width: 72, height: 72)
            Text("Drag Nano into the list")
                .font(.system(size: 13, weight: .semibold))
            Text("Then turn it on. Nano reopens when macOS asks.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }
}

/// The app's icon as a real file drag, the way Finder hands it over.
private struct NanoDraggableAppIcon: NSViewRepresentable {
    let app: URL

    func makeNSView(context: Context) -> DragView { DragView(app: app) }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView, NSDraggingSource {
        let app: URL
        private let icon: NSImage

        init(app: URL) {
            self.app = app
            icon = NSWorkspace.shared.icon(forFile: app.path)
            super.init(frame: .zero)
            toolTip = "Drag into the Full Disk Access list"
        }

        required init?(coder: NSCoder) { nil }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            icon.draw(in: bounds)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            let item = NSDraggingItem(pasteboardWriter: app as NSURL)
            item.setDraggingFrame(bounds, contents: icon)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}
