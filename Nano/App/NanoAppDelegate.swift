import AppKit
import SwiftUI

@MainActor
final class NanoActivationPolicyController {
    static let shared = NanoActivationPolicyController()

    private var settingsVisible = false
    private var temporaryRegularRequests: Set<String> = []

    var shouldShowDockIcon: Bool {
        Self.shouldShowDockIcon(
            settingsVisible: settingsVisible,
            temporaryRequestCount: temporaryRegularRequests.count
        )
    }

    nonisolated static func shouldShowDockIcon(
        settingsVisible: Bool,
        temporaryRequestCount: Int
    ) -> Bool {
        settingsVisible || temporaryRequestCount > 0
    }

    func setSettingsVisible(_ visible: Bool) {
        settingsVisible = visible
        apply()
    }

    func beginTemporaryRegularPresentation(_ identifier: String) {
        temporaryRegularRequests.insert(identifier)
        apply()
    }

    func endTemporaryRegularPresentation(_ identifier: String) {
        temporaryRegularRequests.remove(identifier)
        apply()
    }

    private func apply() {
        guard let application = NSApp else { return }
        application.setActivationPolicy(shouldShowDockIcon ? .regular : .accessory)
    }
}

@MainActor
final class NanoAppDelegate: NSObject, NSApplicationDelegate {
    let settings: NanoSettings = {
        // The signed test host is this same app. Give test runs their own
        // defaults suite so constructing NanoSettings does not consume the
        // user's one-time migration flags or read their preferences.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let suiteName = "com.nanoapp.Nano.xctest-host"
            let suite = UserDefaults(suiteName: suiteName)!
            suite.removePersistentDomain(forName: suiteName)
            return NanoSettings(defaults: suite)
        }
        return NanoSettings()
    }()
    lazy var viewModel = IslandViewModel(settings: settings)

    private var islandController: IslandPanelController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var onboardingStage: OnboardingStage?
    private var monitoringStarted = false
    private var settingsObserver: NSObjectProtocol?
    private var onboardingObserver: NSObjectProtocol?
    private var previewObserver: NSObjectProtocol?
    /// Settings was on screen when setup opened over it, so it comes back
    /// when setup closes.
    private var restoresSettingsAfterOnboarding = false
    /// A second copy of Nano that is about to quit. It must not build the
    /// view model, which would take the hook socket from the first copy.
    private var isDuplicateInstance = false

    /// `Nano.previewNotification` shows sample cards and opens setup, and a
    /// distributed notification can be posted by any local process. Debug
    /// builds listen. A Release build (the local signed install is one) only
    /// listens when asked to:
    /// `defaults write com.nanoapp.Nano debug.previewNotifications -bool true`
    /// or by launching with `NanoAllowPreviewNotifications` in the environment.
    private static var allowsPreviewNotifications: Bool {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.environment["NanoAllowPreviewNotifications"] != nil
            || UserDefaults.standard.bool(forKey: "debug.previewNotifications")
        #endif
    }

    /// True when another copy with this bundle identifier is already running.
    /// The test host is skipped; the compile-only host has its own identifier.
    private static func anotherInstanceIsRunning() -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let bundleID = Bundle.main.bundleIdentifier
        else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        // The installer quits the old copy right before it opens the new one,
        // and a copy that is quitting can still be listed for a moment.
        for attempt in 0..<5 {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ownPID && !$0.isTerminated }
            if others.isEmpty { return false }
            if attempt < 4 { usleep(200_000) }
        }
        return true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.anotherInstanceIsRunning() {
            isDuplicateInstance = true
            NSApp.terminate(nil)
            return
        }
        // Launched from an agent inside an Electron host (T3, Codex, Cursor),
        // Nano inherits ELECTRON_RUN_AS_NODE=1 and passes it to every app it
        // opens. Cursor, T3, Codex, and Claude Desktop then start as bare Node
        // and exit, so jumps silently fail to launch the host.
        unsetenv("ELECTRON_RUN_AS_NODE")
        // Info.plist is not an agent app. Hide the Dock until Settings or a
        // permission sheet needs a regular app. Core Location treats LSUIElement
        // binaries as not in use and skips the location prompt entirely.
        NanoActivationPolicyController.shared.setSettingsVisible(false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isDuplicateInstance else { return }
        NanoActivationPolicyController.shared.setSettingsVisible(false)

        islandController = IslandPanelController(
            settings: settings,
            viewModel: viewModel
        )
        applyDockIcon()
        islandController?.show()
        configureStatusItem()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            viewModel.updateChecker.start()
        }

        if settings.onboardingCompleted {
            startAmbientMonitoringIfNeeded()
        } else {
            settings.prepareForFirstRunOnboardingOnce()
            openOnboarding(isReplay: false)
            // The rooms try things live (a volume key, Quill), so the island
            // has to be listening before setup closes. Setup still owns the
            // island: hovering it opens nothing while `onboardingIsland` is set.
            // The test host keeps its old launch, with no services running.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                startAmbientMonitoringIfNeeded()
            }
        }

        settingsObserver = NotificationCenter.default.addObserver(
            forName: .nanoOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // An optional SettingsDestination raw value picks the page to show.
            // The Settings view hears the same notification and switches page
            // itself, so the page is not posted a second time.
            let page = note.object as? String
            Task { @MainActor in
                self?.openSettings(page: page.flatMap(SettingsDestination.init(rawValue:)), routesPage: false)
            }
        }

        onboardingObserver = NotificationCenter.default.addObserver(
            forName: .nanoReplayOnboarding,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.openOnboarding(isReplay: true)
            }
        }

        if Self.allowsPreviewNotifications {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(didReceivePreviewNotification(_:)),
                name: .nanoPreviewNotification,
                object: nil
            )
            previewObserver = self
        }

        // Read-only diagnostics must query this process's TCC identity. A CLI
        // helper calling AXIsProcessTrusted would measure its own consent.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(reportAccessibilityDiagnostic(_:)),
            name: Notification.Name("Nano.accessibilityDiagnostic.request"),
            object: nil
        )
    }

    @objc private func reportAccessibilityDiagnostic(_ notification: Notification) {
        guard let request = notification.object as? String,
              UUID(uuidString: request) != nil,
              let requestedPID = notification.userInfo?["pid"] as? Int,
              requestedPID == Int(ProcessInfo.processInfo.processIdentifier)
        else { return }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("Nano.accessibilityDiagnostic.response"),
            object: request,
            userInfo: [
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
                "executable": Bundle.main.executableURL?.path ?? "",
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "accessibilityTrusted": NanoAccessibilityPermission.isTrusted,
                "permissions": NanoPermissionDiagnostics.snapshot(
                    location: viewModel.weatherService.authorizationStatus
                ),
            ],
            deliverImmediately: true
        )
    }

    /// `nano://cue/...` goes to Cue; `nano://quill/toggle` and friends go to
    /// Quill (see `VoiceDictationRemoteControl`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if CueLink.isCueLink(url) {
                if MCPOAuthCallbacks.shared.handle(url) { continue }
                if let id = CueLink.cueID(from: url) { viewModel.openCue(id) }
            } else {
                VoiceDictationRemoteControl.handle(url)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isDuplicateInstance else { return }
        viewModel.shutdown()
        TokenLedger.flushPendingSave()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let onboardingObserver {
            NotificationCenter.default.removeObserver(onboardingObserver)
        }
        if let previewObserver {
            DistributedNotificationCenter.default().removeObserver(previewObserver)
        }
    }

    /// Tahoe's Icon Composer stack leaves 32–128px slices empty, so the Dock
    /// would otherwise show a dark squircle with no mark. This tile is the
    /// white logo on the dark enclosure, rasterized at a size the Dock uses.
    private func applyDockIcon() {
        guard let icon = NSImage(named: "DockIcon") else { return }
        icon.size = NSSize(width: 128, height: 128)
        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let mark = NSImage(named: "NanoMark") {
            mark.isTemplate = true
            mark.size = NSSize(width: 18, height: 18)
            item.button?.image = mark
            item.button?.imageScaling = .scaleProportionallyDown
        } else {
            item.button?.image = NSImage(
                systemSymbolName: "capsule.fill",
                accessibilityDescription: "Nano"
            )
        }
        item.button?.toolTip = "Nano"
        item.button?.setAccessibilityLabel("Nano")

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt on every open, so a found update shows up without a relaunch.
    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        if let update = viewModel.updateChecker.available {
            menu.addItem(withTitle: "Update Available: Nano \(update.version)…", action: #selector(downloadUpdate), keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Open Nano", action: #selector(toggleDashboard), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: "Report a Bug…", action: #selector(reportBug), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nano", action: #selector(quitNano), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
    }

    @objc private func downloadUpdate() {
        viewModel.updateChecker.download()
    }

    /// Checks, then shows the answer where it lives: Privacy & About.
    @objc private func checkForUpdates() {
        viewModel.updateChecker.checkNow()
        openSettings(page: .privacy)
    }

    @objc private func reportBug() {
        NSWorkspace.shared.open(NanoLinks.reportBug)
    }

    @objc private func toggleDashboard() {
        islandController?.show()
        viewModel.togglePinnedDashboard()
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    @objc private func quitNano() {
        NSApp.terminate(nil)
    }

    @objc private func didReceivePreviewNotification(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        let source = info["source"] as? String
        let name = info["name"] as? String
        let category = info["category"] as? String
        let provider = info["provider"] as? String
        let agentKind = info["agentKind"] as? String
        let connected: Bool
        if let flag = info["connected"] as? Bool {
            connected = flag
        } else if let number = info["connected"] as? NSNumber {
            connected = number.boolValue
        } else if let text = info["connected"] as? String {
            connected = ["0", "false", "no"].contains(text.lowercased()) == false
        } else {
            connected = true
        }
        handlePreviewNotification(
            source: source,
            name: name,
            category: category,
            connected: connected,
            provider: provider,
            agentKind: agentKind
        )
    }

    private func handlePreviewNotification(
        source rawSource: String?,
        name: String?,
        category rawCategory: String?,
        connected: Bool,
        provider rawProvider: String?,
        agentKind rawAgentKind: String?
    ) {
        if rawSource == "onboarding" {
            // `name` picks the screen: opening, pick, a room, or ending.
            if onboardingStage == nil { openOnboarding(isReplay: true) }
            if let name { onboardingStage?.flow.jump(to: name) }
            onboardingStage?.bringForward()
            return
        }
        if rawSource == "update" {
            viewModel.previewNotification(.update(.preview))
            return
        }
        let source = rawSource.flatMap(IslandNotificationSource.init(rawValue:)) ?? .bluetooth
        if source == .agent {
            let provider = rawProvider
                .flatMap(AgentProviderID.init(rawValue:))
                ?? .claude
            let kind = rawAgentKind == "error" ? AgentHookBridge.RequestKind.notification : (rawAgentKind
                .flatMap(AgentHookBridge.RequestKind.init(rawValue:))
                ?? .permission)
            viewModel.previewNotification(.agentPreview(provider: provider, kind: kind, failure: rawAgentKind == "error"))
            return
        }
        guard source == .bluetooth else {
            viewModel.previewNotification(source)
            return
        }

        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = (trimmed?.isEmpty == false ? trimmed : nil) ?? "AirPods Pro"
        let category = rawCategory
            .flatMap(BluetoothAccessoryCategory.init(rawValue:))
            ?? .headphones

        viewModel.previewNotification(
            .bluetooth(
                name: resolvedName,
                category: category,
                connected: connected,
                address: "preview:\(category.rawValue)",
                battery: connected && BluetoothDevicePresentation.resolve(name: resolvedName, category: category) == .airPodsPro
                    ? AirPodsBatteryLevels(left: 85, caseLevel: 91, right: 82) : nil
            )
        )
    }

    /// `routesPage` is false when the request arrived as `.nanoOpenSettings`,
    /// which the Settings view already acted on.
    private func openSettings(page: SettingsDestination? = nil, routesPage: Bool = true) {
        viewModel.collapseIncludingPinned()

        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
            // The view only reads its starting page when it is created. An
            // existing window is told to switch the way everything else does.
            if let page, routesPage {
                NotificationCenter.default.post(name: .nanoOpenSettings, object: page.rawValue)
            }
        } else {
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: SettingsWindowChrome.size.width, height: SettingsWindowChrome.size.height),
                styleMask: SettingsWindowChrome.styleMask,
                backing: .buffered,
                defer: false
            )
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.contentView = SettingsHostingView(
                rootView: NanoSettingsView(settings: settings, viewModel: viewModel, initialDestination: page ?? .general)
            )
            newWindow.center()
            settingsWindow = newWindow
            window = newWindow
        }
        SettingsWindowChrome.apply(window)
        applyDockIcon()

        NanoActivationPolicyController.shared.setSettingsVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func startAmbientMonitoringIfNeeded() {
        guard !monitoringStarted else { return }
        monitoringStarted = true
        viewModel.startAmbientMonitoring()
    }

    private func openOnboarding(isReplay: Bool) {
        viewModel.collapseIncludingPinned()
        if settingsWindow?.isVisible == true { restoresSettingsAfterOnboarding = true }
        settingsWindow?.orderOut(nil)
        onboardingStage?.tearDown()

        let stage = OnboardingStage(settings: settings, viewModel: viewModel, isReplay: isReplay) { [weak self] in
            guard let self else { return }
            self.onboardingStage = nil
            self.startAmbientMonitoringIfNeeded()
            if self.restoresSettingsAfterOnboarding {
                self.restoresSettingsAfterOnboarding = false
                self.settingsWindow?.makeKeyAndOrderFront(nil)
            }
            if self.settingsWindow?.isVisible != true {
                NanoActivationPolicyController.shared.setSettingsVisible(false)
            }
        }
        onboardingStage = stage

        NanoActivationPolicyController.shared.setSettingsVisible(true)
        applyDockIcon()
        stage.begin()
    }

}

@MainActor
enum SettingsWindowChrome {
    static let size = NSSize(width: 920, height: 680)
    /// Space under the traffic lights so sidebar titles never sit on the buttons.
    static let titlebarClearance: CGFloat = 32
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]

    static func apply(_ window: NSWindow) {
        window.styleMask = styleMask
        window.title = "Nano Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.isOpaque = false
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        // Background dragging would steal every drag gesture in the content
        // (the dashboard editor's drag and drop). The top strip moves the
        // window instead; see SettingsHostingView.
        window.isMovableByWindowBackground = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.minSize = size
        window.maxSize = size
        window.setContentSize(size)
    }

    static func trafficLightsFrame(in view: NSView, window: NSWindow) -> NSRect {
        let buttons = [
            window.standardWindowButton(.closeButton),
            window.standardWindowButton(.miniaturizeButton),
            window.standardWindowButton(.zoomButton)
        ].compactMap { $0 }
        guard let first = buttons.first else {
            return NSRect(x: 0, y: view.bounds.maxY - titlebarClearance, width: 88, height: titlebarClearance)
        }
        var union = first.convert(first.bounds, to: view)
        for button in buttons.dropFirst() {
            union = union.union(button.convert(button.bounds, to: view))
        }
        return union.insetBy(dx: -8, dy: -8)
    }
}

/// Lets close/minimize receive clicks even though the content view fills that corner.
final class SettingsHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let window, SettingsWindowChrome.trafficLightsFrame(in: self, window: window).contains(point) {
            return nil
        }
        return super.hitTest(point)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The strip under the hidden title bar still moves the window, like a
    /// normal title bar. Everywhere else, drags belong to the content.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inTitleStrip = isFlipped
            ? point.y <= SettingsWindowChrome.titlebarClearance
            : point.y >= bounds.maxY - SettingsWindowChrome.titlebarClearance
        if inTitleStrip, let window {
            window.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

extension NanoAppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard notification.object is NSWindow, onboardingStage == nil else { return }
        NanoActivationPolicyController.shared.setSettingsVisible(false)
    }
}

extension Notification.Name {
    static let nanoOpenSettings = Notification.Name("Nano.openSettings")
    static let nanoPreviewNotification = Notification.Name("Nano.previewNotification")
    static let nanoReplayOnboarding = Notification.Name("Nano.replayOnboarding")
}

extension NanoAppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }
}
