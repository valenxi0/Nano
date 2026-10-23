import AppKit
import Combine
import SwiftUI

enum NanoDiag {
    private static let isEnabled = ProcessInfo.processInfo.environment["NANO_DIAG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("NANO-DIAG %@", message())
    }
}

enum IslandChromeMetrics {
    static let height: CGFloat = 44
    static let pillWidth: CGFloat = 128
    static let utilityWidth: CGFloat = 88
    static let clusterGap: CGFloat = 8
    static let gap: CGFloat = 10
    static let dockedCornerRadius: CGFloat = 22
    /// The dictation pill that joins the cluster while a dictation is live, so
    /// the recording state stays visible over any open module.
    static let voiceWidth: CGFloat = 176

    static var clusterWidth: CGFloat { pillWidth + clusterGap + utilityWidth }

    static func dockedSize(for notification: IslandNotification, islandWidth: CGFloat) -> CGSize {
        CGSize(width: islandWidth, height: notification.contentSize.height + 16)
    }

    static func dockedRect(belowIsland islandRect: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: (islandRect.midX - size.width / 2).rounded(),
            y: islandRect.minY - gap - size.height,
            width: size.width,
            height: size.height
        )
    }

    struct Layout: Equatable {
        var pill: CGRect
        var utility: CGRect
        var voice: CGRect? = nil

        var cluster: CGRect {
            let base = pill.union(utility)
            return voice.map { base.union($0) } ?? base
        }
    }

    /// `showsVoice` must match what `IslandRootView.chromeIsland` draws, or the
    /// pill is visible but not clickable.
    static func layout(belowIsland islandRect: CGRect, showsVoice: Bool = false) -> Layout {
        let y = islandRect.minY - gap - height
        let width = clusterWidth + (showsVoice ? voiceWidth + clusterGap : 0)
        var x = (islandRect.midX - width / 2).rounded()
        var voice: CGRect?
        if showsVoice {
            voice = CGRect(x: x, y: y, width: voiceWidth, height: height)
            x += voiceWidth + clusterGap
        }
        return Layout(
            pill: CGRect(x: x, y: y, width: pillWidth, height: height),
            utility: CGRect(x: x + pillWidth + clusterGap, y: y, width: utilityWidth, height: height),
            voice: voice
        )
    }

    /// Full island width, not just the pill. Otherwise moving down from the
    /// sides of the dashboard drops hover before the icons are reachable.
    static func hoverBridge(islandRect: CGRect, clusterRect: CGRect) -> CGRect {
        let minX = min(islandRect.minX, clusterRect.minX)
        let maxX = max(islandRect.maxX, clusterRect.maxX)
        return CGRect(
            x: minX,
            y: clusterRect.maxY,
            width: maxX - minX,
            height: max(islandRect.minY - clusterRect.maxY, 0)
        )
    }

    static func stayOpenBounds(islandRect: CGRect, clusterRect: CGRect) -> CGRect {
        islandRect.union(clusterRect)
    }

    /// How far outside an open island the pointer can stray before it counts
    /// as leaving. Entering still needs the island itself; this is only the
    /// way out, so a slip past the edge while reading a session is forgiven.
    static let exitMargin: CGFloat = 24

    static func exitBounds(stayOpen: CGRect) -> CGRect {
        stayOpen.insetBy(dx: -exitMargin, dy: -exitMargin)
    }

    static func clusterBridge(pill: CGRect, utility: CGRect) -> CGRect {
        CGRect(
            x: pill.maxX,
            y: pill.minY,
            width: max(utility.minX - pill.maxX, 0),
            height: pill.height
        )
    }
}

enum IslandStage {
    /// Room for the tallest island plus a camera-housing safe band, the
    /// detached chrome pill or docked HUD, its gap, and shadow.
    static let maxIslandHeight: CGFloat = 544
    /// Tallest docked HUD: a Bluetooth card with AirPods battery levels.
    static let maxDockedHeight: CGFloat = 96
    static let size = CGSize(
        width: 820,
        height: maxIslandHeight + IslandChromeMetrics.gap + maxDockedHeight + 16
    )
}

/// Per-display camera-housing geometry reported by AppKit. This deliberately
/// avoids model-name tables: the same MacBook may use its built-in notched
/// display and a notch-free external display during one Nano session.
struct NanoDisplayObstruction: Equatable {
    static let none = NanoDisplayObstruction(width: 0, height: 0)

    let width: CGFloat
    let height: CGFloat

    static func measure(
        screenFrame: CGRect,
        safeAreaInsets: NSEdgeInsets,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) -> NanoDisplayObstruction {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea
        else {
            return .none
        }

        let gap = max(right.minX - left.maxX, 0)
        guard gap > 0 else { return .none }

        return NanoDisplayObstruction(
            width: min(gap, screenFrame.width),
            height: safeAreaInsets.top
        )
    }

    static func measure(screen: NSScreen) -> NanoDisplayObstruction {
        measure(
            screenFrame: screen.frame,
            safeAreaInsets: screen.safeAreaInsets,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }
}

/// The drawn island, in AppKit view coordinates. Hover and clicks use this
/// path — not the bounding rectangle — so the menu bar beside a notch, or the
/// rounded-corner cutouts of a floating island, cannot activate it.
enum IslandHitGeometry {
    static func cornerRadius(expanded: Bool, hud: Bool = false) -> CGFloat {
        if hud { return 22 }
        return expanded ? 28 : 18
    }

    static func notchFlare(expanded: Bool, hud: Bool = false) -> CGFloat {
        if hud { return 12 }
        return expanded ? 14 : 10
    }

    static func path(
        in rect: CGRect,
        placement: IslandPlacement,
        expanded: Bool
    ) -> CGPath {
        guard !rect.isEmpty else {
            return CGPath(rect: .zero, transform: nil)
        }

        let local = CGRect(origin: .zero, size: rect.size)
        let shape: Path = switch placement {
        case .attached:
            NanoNotchShape(
                bottomRadius: cornerRadius(expanded: expanded),
                flare: notchFlare(expanded: expanded)
            ).path(in: local)
        case .floating:
            RoundedRectangle(
                cornerRadius: cornerRadius(expanded: expanded),
                style: .continuous
            ).path(in: local)
        }

        // SwiftUI shapes are y-down. AppKit views are y-up.
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.maxY)
            .scaledBy(x: 1, y: -1)
        return shape.cgPath.copy(using: &transform) ?? CGPath(rect: rect, transform: nil)
    }

    static func contains(
        _ point: CGPoint,
        in rect: CGRect,
        placement: IslandPlacement,
        expanded: Bool
    ) -> Bool {
        path(in: rect, placement: placement, expanded: expanded)
            .contains(point, using: .winding, transform: .identity)
    }

    static func chromePath(in rect: CGRect) -> CGPath {
        guard !rect.isEmpty else {
            return CGPath(rect: .zero, transform: nil)
        }

        let local = CGRect(origin: .zero, size: rect.size)
        let shape = Capsule().path(in: local)
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.maxY)
            .scaledBy(x: 1, y: -1)
        return shape.cgPath.copy(using: &transform) ?? CGPath(rect: rect, transform: nil)
    }

    static func dockedPath(in rect: CGRect) -> CGPath {
        guard !rect.isEmpty else {
            return CGPath(rect: .zero, transform: nil)
        }

        let local = CGRect(origin: .zero, size: rect.size)
        let shape = RoundedRectangle(
            cornerRadius: IslandChromeMetrics.dockedCornerRadius,
            style: .continuous
        ).path(in: local)
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.maxY)
            .scaledBy(x: 1, y: -1)
        return shape.cgPath.copy(using: &transform) ?? CGPath(rect: rect, transform: nil)
    }

    static func combining(_ paths: CGPath...) -> CGPath {
        combining(paths)
    }

    static func combining(_ paths: [CGPath]) -> CGPath {
        let combined = CGMutablePath()
        for path in paths {
            combined.addPath(path)
        }
        return combined
    }
}

final class NanoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape, before anything focused inside sees it. Returns true when handled.
    var onEscape: ((_ textIsEditing: Bool) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           onEscape?(firstResponder is NSTextView) == true {
            return
        }
        super.sendEvent(event)
    }
}

/// Status-item twins for a right-click on the open island.
enum IslandContextMenu {
    static let settingsTitle = "Settings…"
    static let quitTitle = "Quit Nano"

    static func isAvailable(phase: IslandPhase) -> Bool {
        phase.showsDashboard
    }

    /// Dashboard widgets would otherwise eat the click. We take the whole
    /// drawn island, including cards and the Home/pin chrome.
    static func claimsEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            true
        case .leftMouseDown, .leftMouseUp:
            event.modifierFlags.contains(.control)
        default:
            false
        }
    }

    static func shouldPresent(
        phase: IslandPhase,
        pointerOverIsland: Bool,
        event: NSEvent
    ) -> Bool {
        isAvailable(phase: phase) && pointerOverIsland && claimsEvent(event)
    }
}

@MainActor
final class IslandContextMenuController: NSObject {
    static let shared = IslandContextMenuController()

    /// `widgetItems` lead the menu when the click landed on a dashboard widget.
    func makeMenu(widgetItems: [NSMenuItem] = []) -> NSMenu {
        let menu = NSMenu()
        for item in widgetItems {
            menu.addItem(item)
        }
        if !widgetItems.isEmpty {
            menu.addItem(.separator())
        }
        // Targets are set on Nano's own items only. Leading items bring their
        // own, and the system Share item breaks if its target is replaced.
        menu.addItem(
            withTitle: IslandContextMenu.settingsTitle,
            action: #selector(openSettings),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: IslandContextMenu.quitTitle,
            action: #selector(quitNano),
            keyEquivalent: ""
        ).target = self
        return menu
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .nanoOpenSettings, object: nil)
    }

    @objc private func quitNano() {
        NSApp.terminate(nil)
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onPrimaryClick: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    var onContextMenuPresentation: ((Bool) -> Void)?
    var onPointerSample: ((NSPoint) -> Void)?

    var islandHitPath: CGPath = CGPath(rect: .zero, transform: nil) {
        didSet { updateTrackingAreas() }
    }

    /// Hover can include the gap between the main island and the chrome pill
    /// so reaching for Home does not collapse the dashboard. Clicks still use
    /// `islandHitPath`, so that gap stays click-through.
    var islandHoverPath: CGPath? {
        didSet { updateTrackingAreas() }
    }

    private var islandTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard islandHitPath.contains(point, using: .winding, transform: .identity) else {
            return nil
        }
        if let event = NSApp.currentEvent, IslandContextMenu.claimsEvent(event) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), presentContextMenu(with: event) {
            return
        }
        onPrimaryClick?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if presentContextMenu(with: event) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard islandHitPath.contains(point, using: .winding, transform: .identity) else {
            return super.menu(for: event)
        }
        return viewMenu(for: event) ?? onContextMenu?() ?? super.menu(for: event)
    }

    /// The `.contextMenu` of the SwiftUI view under the event, such as a Cue
    /// folder's Rename and Delete. It wins over the island's own menu.
    func viewMenu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event), !menu.items.isEmpty else { return nil }
        return menu
    }

    @discardableResult
    private func presentContextMenu(with event: NSEvent) -> Bool {
        guard let menu = menu(for: event) else { return false }
        onContextMenuPresentation?(true)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        onContextMenuPresentation?(false)
        return true
    }

    override func updateTrackingAreas() {
        if let islandTrackingArea {
            removeTrackingArea(islandTrackingArea)
        }

        let rect = (islandHoverPath ?? islandHitPath).boundingBoxOfPath
        if !rect.isNull, !rect.isInfinite, !rect.isEmpty {
            // Bounding box only — enter/exit/moved are hints. The controller
            // then tests the drawn path, so the empty corners stay inert.
            let trackingArea = NSTrackingArea(
                rect: rect.intersection(bounds.isEmpty ? rect : bounds),
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .activeAlways,
                    .enabledDuringMouseDrag,
                ],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            islandTrackingArea = trackingArea
        } else {
            islandTrackingArea = nil
        }

        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        samplePointer(event)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        samplePointer(event)
        super.mouseExited(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        samplePointer(event)
        super.mouseMoved(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        samplePointer(event)
        super.mouseDragged(with: event)
    }

    private func samplePointer(_ event: NSEvent) {
        onPointerSample?(convert(event.locationInWindow, from: nil))
    }
}

@MainActor
final class IslandPanelController {
    private let settings: NanoSettings
    private let viewModel: IslandViewModel
    private let panel: NanoPanel
    private let hostingView: FirstMouseHostingView<IslandRootView>
    private var cancellables: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?
    private var pointerMonitors: [Any] = []
    private var notificationObservers: [NSObjectProtocol] = []
    /// Stored, so "Follow the active display" off still means the same
    /// display after a relaunch.
    private var pinnedScreenID: CGDirectDisplayID? {
        get { settings.pinnedScreenID }
        set { settings.pinnedScreenID = newValue }
    }
    private var outsideClickGraceUntil = Date.distantPast
    private var isPointerInside = false
    private var lastHitSignature: HitSignature?
    private var hoverTimer: Timer?
    /// The drag pasteboard's count while the button was last up. A different
    /// count with the button held means a drag began since. It is taken on
    /// release and on every poll with the button up, not on mouse-down: a
    /// mouse-down handler that ran late would record the drag's own count.
    private var dragCountWhileUp = NSPasteboard(name: .drag).changeCount
    private var holdableDragCheck: (count: Int, isHoldable: Bool)?
    private var fileDragEndScheduled = false
    private var hitTargetUpdateScheduled = false
    private var isShowingContextMenu = false

    private let stageSize = IslandStage.size

    private var showsVoiceChrome: Bool {
        settings.isEnabled(.voiceDictation) && viewModel.voiceDictation.phase != .idle
    }

    private struct HitSignature: Equatable {
        var rect: NSRect
        var pillRect: NSRect?
        var utilityRect: NSRect?
        var voiceRect: NSRect?
        var dockedRect: NSRect?
        var placement: IslandPlacement
        var expanded: Bool
    }

    init(settings: NanoSettings, viewModel: IslandViewModel) {
        self.settings = settings
        self.viewModel = viewModel

        panel = NanoPanel(
            contentRect: NSRect(origin: .zero, size: stageSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak viewModel] textIsEditing in
            viewModel?.handleEscape(textIsEditing: textIsEditing) ?? false
        }
        panel.isMovable = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true

        hostingView = FirstMouseHostingView(
            rootView: IslandRootView(settings: settings, viewModel: viewModel)
        )
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        hostingView.onPrimaryClick = { [weak viewModel] in
            guard viewModel?.phase == .idleCompact else { return }
            viewModel?.togglePinnedDashboard()
        }
        hostingView.onContextMenu = { [weak self] in
            guard let self, IslandContextMenu.isAvailable(phase: self.viewModel.phase) else {
                return nil
            }
            return IslandContextMenuController.shared.makeMenu(widgetItems: self.widgetMenuItems())
        }
        hostingView.onContextMenuPresentation = { [weak self] presenting in
            guard let self else { return }
            self.isShowingContextMenu = presenting
            if !presenting {
                self.updateHoverState()
            }
        }
        hostingView.onPointerSample = { [weak self] _ in
            self?.updateHoverState()
        }
        panel.contentView = hostingView
        hostingView.postsFrameChangedNotifications = true

        observeChanges()
        installPointerMonitors()
        installContextMenuMonitor()
        installHoverTimer()
        installOutsideClickMonitor()
        installQuickCaptureObserver()
    }

    deinit {
        MainActor.assumeIsolated {
            hoverTimer?.invalidate()
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
            }
            pointerMonitors.forEach { NSEvent.removeMonitor($0) }
            notificationObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    private func observeChanges() {
        viewModel.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                guard let self else { return }
                if phase.isExpanded {
                    outsideClickGraceUntil = Date().addingTimeInterval(0.75)
                }
                scheduleHoverPoll(after: phase == .idleCompact
                    ? NanoHoverCadence.active
                    : NanoHoverCadence.idle)
                if phase == .hoverDashboard {
                    DispatchQueue.main.async {
                        self.isPointerInside = self.pointerIsOverIsland()
                        if !self.isPointerInside {
                            self.viewModel.pointerExited()
                        }
                    }
                }
            }
            .store(in: &cancellables)

        viewModel.$isPinned
            .removeDuplicates()
            .sink { [weak self] pinned in
                guard let self, !pinned else { return }
                DispatchQueue.main.async {
                    self.isPointerInside = self.pointerIsOverIsland()
                    if !self.isPointerInside {
                        self.viewModel.pointerExited()
                    }
                }
            }
            .store(in: &cancellables)

        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleHitTargetUpdate()
            }
            .store(in: &cancellables)

        // The dictation pill joins the control bar; its hit area has to follow.
        viewModel.voiceDictation.$phase
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleHitTargetUpdate()
            }
            .store(in: &cancellables)

        settings.$placement
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.reposition()
                }
            }
            .store(in: &cancellables)

        settings.$followActiveDisplay
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.reposition()
                }
            }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.reposition() }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: hostingView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.scheduleHitTargetUpdate() }
            }
        )

        notificationObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard self?.viewModel.phase == .idleCompact else { return }
                    self?.reposition()
                }
            }
        )
    }

    private func updateHoverState() {
        guard panel.isVisible else { return }
        let inside = pointerIsOverIsland() || pointerIsWithinExitMargin()
        // Cue's list takes image files itself ("Drop to save as a cue").
        // Switching to the tray here took that drop target away mid-drag.
        let cueTakesDrops = viewModel.phase.showsDashboard && viewModel.activeModule == .cue
        if inside, viewModel.phase != .dragTarget, !cueTakesDrops, isDraggingHoldable() {
            viewModel.beginFileDrag()
        }
        setPointerInside(inside)
    }

    /// Cursor vs the drawn island in screen space. View-coordinate conversion
    /// was fighting tracking-area events and cancelling the hover open.
    /// The dashboard widget under the pointer, worked out from the same
    /// layout the dashboard draws with.
    private func widgetMenuItems() -> [NSMenuItem] {
        // An open feature, like Calendar or Music, offers its own options.
        if viewModel.phase.showsDashboard, let module = viewModel.activeModule {
            let options = DashboardWidgetOptions.featureOptions(for: module, settings: settings, viewModel: viewModel)
            return DashboardWidgetOptions.menuItems(options.isEmpty ? [] : [options])
        }
        return dashboardWidgetUnderPointer().map { module, area in
            DashboardWidgetOptions.menuItems(
                DashboardWidgetOptions.sections(for: module, in: area, settings: settings, viewModel: viewModel)
            )
        } ?? []
    }

    private func dashboardWidgetUnderPointer() -> (NanoModuleID, DashboardArea)? {
        guard viewModel.phase.showsDashboard, viewModel.activeModule == nil else { return nil }
        let island = islandScreenRect
        let mouse = NSEvent.mouseLocation
        let flare = settings.placement == .attached ? IslandHitGeometry.notchFlare(expanded: true) : 0
        let point = CGPoint(
            x: mouse.x - island.minX - flare - DashboardLayout.inset,
            y: island.maxY - mouse.y - viewModel.notchContentClearance - DashboardLayout.inset
        )
        let width = island.width - flare * 2 - DashboardLayout.inset * 2
        let placements = DashboardLayout.placements(width: width, filled: DashboardLayout.filledAreas(settings))
        guard let area = placements.first(where: { $0.value.frame.contains(point) })?.key,
              let module = settings.visibleDashboardFeature(in: area) else { return nil }
        return (module, area)
    }

    private func pointerIsOverIsland() -> Bool {
        let mouse = NSEvent.mouseLocation
        let island = islandScreenRect
        if IslandHitGeometry.contains(
            mouse,
            in: island,
            placement: settings.placement,
            expanded: viewModel.phase.isExpanded
        ) {
            return true
        }

        if let dockedNotification = viewModel.dockedNotification {
            let docked = IslandChromeMetrics.dockedRect(
                belowIsland: island,
                size: IslandChromeMetrics.dockedSize(
                    for: dockedNotification,
                    islandWidth: island.width
                )
            )
            return IslandChromeMetrics.stayOpenBounds(
                islandRect: island,
                clusterRect: docked
            ).contains(mouse)
        }

        guard viewModel.phase.showsChrome else { return false }

        // Same screen-space math as the island — not view conversion, which
        // placed the icon pill in the wrong place and collapsed on the way down.
        let chrome = IslandChromeMetrics.layout(belowIsland: island, showsVoice: showsVoiceChrome)
        return IslandChromeMetrics.stayOpenBounds(
            islandRect: island,
            clusterRect: chrome.cluster
        ).contains(mouse)
    }

    /// True while the island is open, the pointer was inside, and it is still
    /// within `exitMargin` of the island or the chrome under it.
    private func pointerIsWithinExitMargin() -> Bool {
        guard isPointerInside, viewModel.phase.isExpanded else { return false }
        let island = islandScreenRect
        var stayOpen = island
        if let dockedNotification = viewModel.dockedNotification {
            stayOpen = stayOpen.union(IslandChromeMetrics.dockedRect(
                belowIsland: island,
                size: IslandChromeMetrics.dockedSize(for: dockedNotification, islandWidth: island.width)
            ))
        } else if viewModel.phase.showsChrome {
            stayOpen = stayOpen.union(
                IslandChromeMetrics.layout(belowIsland: island, showsVoice: showsVoiceChrome).cluster
            )
        }
        return IslandChromeMetrics.exitBounds(stayOpen: stayOpen).contains(NSEvent.mouseLocation)
    }

    /// Measured against the hosting view as it is, not the stage constant:
    /// AppKit grows the panel when the island is taller than the stage, and a
    /// rect computed from the constant left the top of a tall island (and of
    /// every card shown afterwards) outside the click region.
    private var islandViewRect: NSRect {
        let size = viewModel.preferredSize
        let stage = hostingView.bounds.size == .zero ? stageSize : hostingView.bounds.size
        return NSRect(
            x: ((stage.width - size.width) / 2).rounded(),
            y: (stage.height - size.height).rounded(),
            width: size.width,
            height: size.height
        )
    }

    private var islandScreenRect: NSRect {
        let size = viewModel.preferredSize
        let frame = panel.frame
        return NSRect(
            x: (frame.midX - size.width / 2).rounded(),
            y: (frame.maxY - size.height).rounded(),
            width: size.width,
            height: size.height
        )
    }

    private func setPointerInside(_ inside: Bool) {
        if isShowingContextMenu, !inside { return }
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        NanoDiag.log("hover \(inside ? "enter" : "exit") phase=\(viewModel.phase)")

        if inside {
            viewModel.pointerEntered()
        } else {
            viewModel.pointerExited()
        }
    }

    private func installPointerMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]

        let note: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.updateHoverState()
            }
        }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: note) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            note(event)
            return event
        }) {
            pointerMonitors.append(local)
        }

        let released: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.noteButtonUp() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: released) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { event in
            released(event)
            return event
        }) {
            pointerMonitors.append(local)
        }
    }

    /// True while something the tray can hold is being dragged: files from
    /// Finder, or a link, an image, or text from any other app.
    private func isDraggingHoldable() -> Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            noteButtonUp()
            return false
        }
        let pasteboard = NSPasteboard(name: .drag)
        let count = pasteboard.changeCount
        guard count != dragCountWhileUp else { return false }
        if let check = holdableDragCheck, check.count == count { return check.isHoldable }
        let isHoldable = pasteboard.types?.contains(where: TrayStore.holdableTypes.contains) == true
        holdableDragCheck = (count, isHoldable)
        return isHoldable
    }

    private func noteButtonUp() {
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        dragCountWhileUp = NSPasteboard(name: .drag).changeCount
    }

    /// A held file's quick actions, when the click landed on one. Found by
    /// walking the views, because the hosting view answers every context-menu
    /// hit test with itself.
    private func trayItemMenuItems(at event: NSEvent) -> [NSMenuItem]? {
        func dragSource(in view: NSView) -> TrayFileDragView? {
            for subview in view.subviews.reversed() where !subview.isHidden {
                if let source = subview as? TrayFileDragView,
                   source.bounds.contains(source.convert(event.locationInWindow, from: nil)) {
                    return source
                }
                if let source = dragSource(in: subview) { return source }
            }
            return nil
        }
        return dragSource(in: hostingView)?.menuItems?()
    }

    /// A file drag ends with the button's release, wherever that is. The drop
    /// itself is delivered just after, so give it a moment to land.
    private func finishFileDrag() {
        guard !fileDragEndScheduled else { return }
        fileDragEndScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            fileDragEndScheduled = false
            viewModel.endFileDrag()
        }
    }

    /// Music/Calendar (and other SwiftUI controls) swallow `rightMouseDown`
    /// before the hosting view sees it. Catch the click here instead.
    private func installContextMenuMonitor() {
        let mask: NSEvent.EventTypeMask = [.rightMouseDown, .leftMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            let consumed = MainActor.assumeIsolated {
                self.consumeContextMenuIfNeeded()
            }
            return consumed ? nil : event
        }) {
            pointerMonitors.append(local)
        }
    }

    /// Uses `NSApp.currentEvent` so the monitor does not hop an `NSEvent`
    /// across actors (it is not Sendable).
    private func consumeContextMenuIfNeeded() -> Bool {
        guard let event = NSApp.currentEvent else { return false }
        guard IslandContextMenu.shouldPresent(
            phase: viewModel.phase,
            pointerOverIsland: pointerIsOverIsland(),
            event: event
        ) else { return false }
        guard !isShowingContextMenu else { return true }

        isShowingContextMenu = true
        // A view's own menu first (Cue folders and items, agent sessions), then
        // a held file's, then the island's with the feature's options.
        let menu = hostingView.viewMenu(for: event)
            ?? IslandContextMenuController.shared.makeMenu(
                widgetItems: trayItemMenuItems(at: event) ?? widgetMenuItems()
            )
        NSMenu.popUpContextMenu(menu, with: event, for: hostingView)
        isShowingContextMenu = false
        updateHoverState()
        return true
    }

    /// Tracking areas on a click-through panel drop enter events. A cheap poll
    /// while the cursor is in the top band is what actually makes hover work.
    private func installHoverTimer() {
        scheduleHoverPoll(after: 0.05)
    }

    private func scheduleHoverPoll(after interval: TimeInterval) {
        hoverTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let next = self.pollHover()
                self.scheduleHoverPoll(after: next)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    @discardableResult
    private func pollHover() -> TimeInterval {
        guard panel.isVisible else { return NanoHoverCadence.hidden }
        let mouse = NSEvent.mouseLocation
        let screen = panel.screen ?? targetScreen()
        let nearTop = mouse.y >= screen.frame.maxY - 96
        noteButtonUp()
        if viewModel.phase == .dragTarget, NSEvent.pressedMouseButtons & 1 == 0 {
            finishFileDrag()
        }
        // A file on its way to the island opens it from any state, HUDs and
        // pinned modules included, so those are polled while one is dragged.
        let draggingFile = nearTop && viewModel.phase != .dragTarget && isDraggingHoldable()
        let hoverEnabled = viewModel.phase == .idleCompact
            || viewModel.phase == .hoverDashboard
            || viewModel.phase == .dragTarget
            || draggingFile
        if hoverEnabled, nearTop || isPointerInside || viewModel.phase == .hoverDashboard {
            updateHoverState()
        }
        return NanoHoverCadence.interval(
            hoverEnabled: hoverEnabled,
            nearTop: nearTop,
            pointerInside: isPointerInside
        )
    }

    private func installQuickCaptureObserver() {
        for name in [Notification.Name.nanoIslandWantsKeyboard] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // Keystrokes must land in the island, not the app that had focus.
                    NSApp.activate(ignoringOtherApps: true)
                    self.outsideClickGraceUntil = Date().addingTimeInterval(0.75)
                    self.panel.makeKeyAndOrderFront(nil)
                }
            }
            notificationObservers.append(observer)
        }
    }

    private func installOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self, self.viewModel.phase.isExpanded else { return }
                guard !self.viewModel.isPinned else { return }
                // An open capture holds the island without flipping the pin.
                guard self.viewModel.cueStore.draft == nil else { return }
                guard Date() >= self.outsideClickGraceUntil else { return }
                if !self.pointerIsOverIsland() {
                    self.viewModel.collapseIncludingPinned()
                }
            }
        }
    }

    private func reposition() {
        let screen = targetScreen()
        let obstruction = NanoDisplayObstruction.measure(screen: screen)
        let topGap: CGFloat = settings.placement == .floating ? 8 : 0
        let origin = NSPoint(
            x: (screen.frame.midX - stageSize.width / 2).rounded(),
            y: (screen.frame.maxY - topGap - stageSize.height).rounded()
        )

        viewModel.notchWidth = obstruction.width
        viewModel.notchHeight = obstruction.height
        panel.setFrame(NSRect(origin: origin, size: stageSize), display: true)
        updateIslandHitTarget()
    }

    private func updateIslandHitTarget() {
        let rect = islandViewRect
        let docked = viewModel.dockedNotification.map {
            IslandChromeMetrics.dockedRect(
                belowIsland: rect,
                size: IslandChromeMetrics.dockedSize(for: $0, islandWidth: rect.width)
            )
        }
        let chrome = docked == nil && viewModel.phase.showsChrome
            ? IslandChromeMetrics.layout(belowIsland: rect, showsVoice: showsVoiceChrome)
            : nil
        let signature = HitSignature(
            rect: rect,
            pillRect: chrome?.pill,
            utilityRect: chrome?.utility,
            voiceRect: chrome?.voice,
            dockedRect: docked,
            placement: settings.placement,
            expanded: viewModel.phase.isExpanded
        )
        if lastHitSignature != signature {
            lastHitSignature = signature
            let islandPath = IslandHitGeometry.path(
                in: rect,
                placement: signature.placement,
                expanded: signature.expanded
            )
            if let docked {
                let dockedPath = IslandHitGeometry.dockedPath(in: docked)
                hostingView.islandHitPath = IslandHitGeometry.combining(
                    islandPath,
                    dockedPath
                )
                hostingView.islandHoverPath = IslandHitGeometry.combining(
                    islandPath,
                    dockedPath,
                    CGPath(rect: IslandChromeMetrics.hoverBridge(
                        islandRect: rect,
                        clusterRect: docked
                    ), transform: nil)
                )
            } else if let chrome {
                let pillPath = IslandHitGeometry.chromePath(in: chrome.pill)
                let utilityPath = IslandHitGeometry.chromePath(in: chrome.utility)
                var hitPaths = [islandPath, pillPath, utilityPath]
                var hoverPaths = [
                    islandPath,
                    pillPath,
                    utilityPath,
                    CGPath(rect: IslandChromeMetrics.hoverBridge(
                        islandRect: rect,
                        clusterRect: chrome.cluster
                    ), transform: nil),
                    CGPath(rect: IslandChromeMetrics.clusterBridge(
                        pill: chrome.pill,
                        utility: chrome.utility
                    ), transform: nil),
                ]
                if let voice = chrome.voice {
                    let voicePath = IslandHitGeometry.chromePath(in: voice)
                    hitPaths.append(voicePath)
                    hoverPaths.append(voicePath)
                    hoverPaths.append(CGPath(rect: IslandChromeMetrics.clusterBridge(
                        pill: voice,
                        utility: chrome.pill
                    ), transform: nil))
                }
                hostingView.islandHitPath = IslandHitGeometry.combining(hitPaths)
                hostingView.islandHoverPath = IslandHitGeometry.combining(hoverPaths)
            } else {
                hostingView.islandHitPath = islandPath
                hostingView.islandHoverPath = nil
            }
        }
        // Geometry changes are rare and can move the boundary across a still
        // pointer without producing an AppKit enter/exit event.
        updateHoverState()
    }

    /// Agent streaming can publish several unrelated changes in one run-loop
    /// turn. Geometry only needs the latest state, so enqueue at most one update.
    private func scheduleHitTargetUpdate() {
        guard !hitTargetUpdateScheduled else { return }
        hitTargetUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hitTargetUpdateScheduled = false
            updateIslandHitTarget()
        }
    }

    private func targetScreen() -> NSScreen {
        if !settings.followActiveDisplay,
           let pinnedScreenID,
           let screen = NSScreen.screens.first(where: { $0.displayID == pinnedScreenID }) {
            return screen
        }

        let pointer = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
        let target = pointerScreen ?? NSScreen.main ?? NSScreen.screens[0]

        if !settings.followActiveDisplay {
            pinnedScreenID = target.displayID
        }
        return target
    }
}

enum NanoHoverCadence {
    static let active: TimeInterval = 0.05
    static let idle: TimeInterval = 0.25
    static let hidden: TimeInterval = 0.75
    static let openDelay: Duration = .milliseconds(150)

    static func interval(
        hoverEnabled: Bool,
        nearTop: Bool,
        pointerInside: Bool
    ) -> TimeInterval {
        guard hoverEnabled else { return hidden }
        return nearTop || pointerInside ? active : idle
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}
