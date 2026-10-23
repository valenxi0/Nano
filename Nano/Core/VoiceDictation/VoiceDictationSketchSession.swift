import AppKit
import QuartzCore
import ScreenCaptureKit
import SwiftUI

/// The key held to draw with the pointer.
enum VoiceDictationSketchDrawKey: String, CaseIterable, Identifiable, Codable, Sendable {
    case shift, option, control, command, function

    var id: String { rawValue }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .option: .option
        case .control: .control
        case .command: .command
        case .function: .function
        }
    }

    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .option: "⌥"
        case .control: "⌃"
        case .command: "⌘"
        case .function: "fn"
        }
    }

    var title: String {
        switch self {
        case .shift: "Shift ⇧"
        case .option: "Option ⌥"
        case .control: "Control ⌃"
        case .command: "Command ⌘"
        case .function: "fn"
        }
    }

    /// True when this key, and no other modifier, is down.
    func isHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.shift, .control, .option, .command, .function]) == self.flags
    }
}

/// What the Sketch pill shows.
@MainActor
final class VoiceDictationSketchState: ObservableObject {
    @Published var marks = 0
    @Published var screenshots = 0
    @Published var isPenOn = false
    let startedAt = Date()
    let drawKey: VoiceDictationSketchDrawKey
    let finishShortcut: String

    init(drawKey: VoiceDictationSketchDrawKey, finishShortcut: String) {
        self.drawKey = drawKey
        self.finishShortcut = finishShortcut
    }
}

/// The live half of a Sketch: a click-through ink overlay on the display
/// under the pointer, a pill with the controls, and a screenshot per group
/// of marks.
///
/// Hold the draw key and move the pointer to draw, or turn on Draw in the
/// pill and drag. Clicks and scrolls otherwise pass through to the app
/// underneath. Ink fades a moment after it is drawn. A click, a scroll or an
/// app switch means the screen may have changed, so the next mark starts a
/// new screenshot.
@MainActor
final class VoiceDictationSketchSession {
    nonisolated static let maximumFrames = 8
    /// Shorter paths are a key press while typing, not a mark.
    nonisolated static let minimumStrokeLength: CGFloat = 12

    let screenFrame: CGRect
    var scale: CGFloat { screen.backingScaleFactor }
    let state: VoiceDictationSketchState
    var onMarksChanged: ((Int) -> Void)?
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    private let screen: NSScreen
    private let displayID: CGDirectDisplayID
    private let sampleClock: () -> Int
    private var overlay: VoiceDictationSketchOverlay?
    private var pill: VoiceDictationSketchPill?
    private var frames: [VoiceDictationSketchFrame] = []
    private var drawing: [CGPoint] = []
    private var drawingStart = 0
    private var screenChanged = true
    private var monitors: [Any] = []
    private var appObserver: NSObjectProtocol?
    private var captures: [Int: Task<Void, Never>] = [:]
    private var recorder: VoiceDictationSketchRecorder?
    private var recorderStart: Task<Void, Never>?
    private var startShot: Task<CGImage?, Never>?
    private var clicks: [(sample: Int, point: CGPoint, place: VoiceDictationSketchPlace, image: Task<CGImage?, Never>)] = []
    private var startPlace = VoiceDictationSketchPlace()
    /// Where the user was when each screen change began, by its start time.
    private var changePlaces: [CFTimeInterval: VoiceDictationSketchPlace] = [:]
    /// Maps the recorder's clock to audio samples.
    private var clockStart: (time: CFTimeInterval, sample: Int) = (0, 0)

    var markCount: Int { frames.reduce(0) { $0 + $1.strokes.count } }

    init(
        screen: NSScreen,
        drawKey: VoiceDictationSketchDrawKey = .shift,
        finishShortcut: String = "",
        sampleClock: @escaping () -> Int
    ) {
        self.screen = screen
        screenFrame = screen.frame
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
        state = VoiceDictationSketchState(drawKey: drawKey, finishShortcut: finishShortcut)
        self.sampleClock = sampleClock
    }

    static func screenUnderPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    }

    static var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }

    private static var askedForScreenRecording = false

    /// The first time, adds Nano to the Screen Recording list and shows the
    /// system prompt. macOS asks only once, so after that it opens the pane.
    /// On macOS 27 only ScreenCaptureKit's own check adds the app to the
    /// list; `CGRequestScreenCaptureAccess` does not.
    static func requestScreenRecordingAccess() {
        guard !askedForScreenRecording else { return openScreenRecordingSettings() }
        askedForScreenRecording = true
        Task.detached {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        let overlay = VoiceDictationSketchOverlay(screen: screen)
        overlay.ink.onPen = { [weak self] phase, point in self?.pen(phase, at: point) }
        overlay.fadeIn()
        self.overlay = overlay

        let pill = VoiceDictationSketchPill(
            state: state,
            screen: screen,
            actions: VoiceDictationSketchPillActions(
                togglePen: { [weak self] in self?.setPen(!(self?.state.isPenOn ?? false)) },
                undo: { [weak self] in self?.undo() },
                cancel: { [weak self] in self?.onCancel?() },
                finish: { [weak self] in self?.onFinish?() }
            )
        )
        pill.orderFrontRegardless()
        self.pill = pill

        clockStart = (CACurrentMediaTime(), sampleClock())
        let recorder = VoiceDictationSketchRecorder(
            videoURL: VoiceDictationSketchStorage.directory.appendingPathComponent("recording-\(UUID().uuidString).mp4")
        )
        recorder.onChange = { [weak self] time in
            Task { @MainActor in
                self?.changePlaces[time] = Self.frontPlace()
                self?.screenMayHaveChanged()
            }
        }
        startPlace = Self.frontPlace()
        self.recorder = recorder
        let displayID = displayID
        let size = pixelSize
        recorderStart = Task {
            try? await recorder.start(displayID: displayID, pixelSize: size)
        }
        // The screen before anything happens, for words said before the
        // first mark or click.
        startShot = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            return await self?.snapshot()
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .flagsChanged, .leftMouseDown, .rightMouseDown, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenMayHaveChanged() }
        }
    }

    func setPen(_ on: Bool) {
        guard state.isPenOn != on else { return }
        if !on { endDrawing() }
        state.isPenOn = on
        overlay?.setPen(on)
    }

    /// Removes the most recent mark.
    func undo() {
        guard let frameIndex = frames.lastIndex(where: { !$0.strokes.isEmpty }) else { return }
        frames[frameIndex].strokes.removeLast()
        if frames[frameIndex].strokes.isEmpty {
            captures[frameIndex]?.cancel()
            captures[frameIndex] = nil
            frames.remove(at: frameIndex)
            if frames.isEmpty { screenChanged = true }
        }
        overlay?.ink.removeLastMark()
        publish()
    }

    struct Capture: Sendable {
        var moments: [VoiceDictationSketchMoment]
        var video: URL?
    }

    /// Ends the session and returns every screenshot worth considering, and
    /// the recording.
    func finish() async -> Capture {
        endDrawing()
        stop()
        for task in captures.values { await task.value }
        var moments: [VoiceDictationSketchMoment] = []
        if let image = await startShot?.value {
            moments.append(VoiceDictationSketchMoment(kind: .start, sample: clockStart.sample, image: image, place: startPlace))
        }
        for click in clicks {
            guard let image = await click.image.value else { continue }
            moments.append(VoiceDictationSketchMoment(
                kind: .click, sample: click.sample, image: image, click: click.point, place: click.place
            ))
        }
        let fallback = await snapshot()
        for frame in frames where !frame.strokes.isEmpty {
            guard let image = frame.image ?? fallback else { continue }
            moments.append(VoiceDictationSketchMoment(
                kind: .marks, sample: frame.startSample, image: image, strokes: frame.strokes, place: frame.place
            ))
        }
        await recorderStart?.value
        let recorded = await recorder?.stop()
        for change in recorded?.changes ?? [] {
            moments.append(VoiceDictationSketchMoment(
                kind: .change, sample: sample(at: change.time), image: change.image,
                place: changePlaces[change.time] ?? VoiceDictationSketchPlace()
            ))
        }
        if moments.isEmpty, let fallback {
            moments.append(VoiceDictationSketchMoment(kind: .start, sample: clockStart.sample, image: fallback))
        }
        return Capture(moments: moments, video: recorded?.video)
    }

    func cancel() {
        stop()
        captures.values.forEach { $0.cancel() }
        startShot?.cancel()
        frames = []
        clicks = []
        let recorder = recorder
        Task {
            if let video = await recorder?.stop().video { try? FileManager.default.removeItem(at: video) }
        }
    }

    private func sample(at time: CFTimeInterval) -> Int {
        clockStart.sample + Int((time - clockStart.time) * VoiceDictationAudioRecorder.sampleRate)
    }

    /// The screen now, from the recording, or a one-off screenshot before
    /// the recording has its first frame.
    private func snapshot() async -> CGImage? {
        if let image = await recorder?.snapshot() { return image }
        return await Self.screenshot(displayID: displayID, pixelSize: pixelSize)
    }

    private func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        if state.isPenOn { overlay?.setPen(false) }
        overlay?.fadeOut()
        overlay = nil
        pill?.orderOut(nil)
        pill = nil
    }

    private var pixelSize: CGSize {
        CGSize(width: screenFrame.width * screen.backingScaleFactor, height: screenFrame.height * screen.backingScaleFactor)
    }

    private func publish() {
        state.marks = markCount
        state.screenshots = frames.count
        onMarksChanged?(markCount)
    }

    // MARK: Input

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved:
            guard !state.isPenOn, state.drawKey.isHeld(NSEvent.modifierFlags) else {
                if !drawing.isEmpty, !state.isPenOn { endDrawing() }
                return
            }
            let point = NSEvent.mouseLocation
            guard NSMouseInRect(point, screenFrame, false) else {
                endDrawing()
                return
            }
            add(point)
        case .flagsChanged:
            if !state.isPenOn, !drawing.isEmpty, !state.drawKey.isHeld(event.modifierFlags) {
                endDrawing()
            }
        case .leftMouseDown, .rightMouseDown, .scrollWheel:
            // A click on the pill doesn't change what is being marked.
            if let window = event.window, window === pill { return }
            guard !state.isPenOn else { return }
            screenMayHaveChanged()
            let point = NSEvent.mouseLocation
            if event.type == .leftMouseDown, NSMouseInRect(point, screenFrame, false), clicks.count < 40 {
                // What was clicked, as it looked at the click.
                clicks.append((sampleClock(), point, Self.place(at: point), Task { [weak self] in await self?.snapshot() }))
            }
        default:
            break
        }
    }

    private func pen(_ phase: VoiceDictationSketchInkView.PenPhase, at point: CGPoint) {
        switch phase {
        case .began:
            endDrawing()
            add(point)
        case .moved:
            add(point)
        case .ended:
            add(point)
            endDrawing()
        }
    }

    private func add(_ point: CGPoint) {
        if drawing.isEmpty {
            drawingStart = sampleClock()
        } else if let last = drawing.last, hypot(last.x - point.x, last.y - point.y) < 0.75 {
            return
        }
        drawing.append(point)
        overlay?.ink.setLive(drawing)
    }

    private func endDrawing() {
        let points = drawing
        drawing = []
        overlay?.ink.setLive([])
        guard Self.length(of: points) >= Self.minimumStrokeLength else { return }

        if screenChanged || frames.isEmpty, frames.count < Self.maximumFrames {
            frames.append(VoiceDictationSketchFrame(image: nil, strokes: []))
            screenChanged = false
        }
        let index = frames.count - 1
        let stroke = VoiceDictationSketchStroke(points: points, startSample: drawingStart, number: markCount + 1)
        frames[index].strokes.append(stroke)
        if frames[index].strokes.count == 1 {
            var place = Self.place(at: points[points.count / 2])
            place.element = nil
            frames[index].place = place
        }
        let seconds = Double(drawingStart - clockStart.sample) / VoiceDictationAudioRecorder.sampleRate
        overlay?.ink.commit(points, label: VoiceDictationSketchText.clock(seconds), showsLabel: true)
        publish()
        recapture(frame: index)
    }

    private func screenMayHaveChanged() {
        screenChanged = true
    }

    /// Each new mark retakes its group's screenshot, so the image is the
    /// screen as it looked when the last of those marks was drawn.
    private func recapture(frame index: Int) {
        let previous = captures[index]
        captures[index] = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let image = await self?.snapshot(), let self, index < self.frames.count
            else { return }
            self.frames[index].image = image
        }
    }

    // MARK: Where things happen

    /// The app in front and its focused window's title.
    static func frontPlace() -> VoiceDictationSketchPlace {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return VoiceDictationSketchPlace() }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        return VoiceDictationSketchPlace(
            app: app.localizedName,
            window: attribute(element, kAXFocusedWindowAttribute).flatMap { title(of: $0) }
        )
    }

    /// The app, window and element under a global AppKit point, read from
    /// Accessibility. Nothing is read from secure fields.
    static func place(at point: CGPoint) -> VoiceDictationSketchPlace {
        guard let primary = NSScreen.screens.first else { return frontPlace() }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(primary.frame.maxY - point.y), &hit
        ) == .success, let hit else { return frontPlace() }
        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return frontPlace() }
        return VoiceDictationSketchPlace(
            app: NSRunningApplication(processIdentifier: pid)?.localizedName,
            window: attribute(hit, kAXWindowAttribute).flatMap { title(of: $0) },
            element: describe(hit)
        )
    }

    /// "button “Save”": the role and the first label found on the element
    /// or, for an unlabelled icon or text run, on up to two parents.
    private static func describe(_ element: AXUIElement) -> String? {
        var current: AXUIElement? = element
        var role: String?
        for _ in 0 ..< 3 {
            guard let node = current else { break }
            if (attribute(node, kAXSubroleAttribute) as? String) == "AXSecureTextField" { return "password field" }
            let nodeRole = attribute(node, kAXRoleDescriptionAttribute) as? String
            role = role ?? nodeRole
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
                .compactMap { attribute(node, $0) as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.contains("\n") && $0.count <= 60 }
            if let label = labels.first {
                return "\(nodeRole ?? role ?? "element") “\(label)”"
            }
            current = attribute(node, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        return role
    }

    private static func title(of window: CFTypeRef) -> String? {
        guard CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return attribute(window as! AXUIElement, kAXTitleAttribute) as? String
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    nonisolated static func length(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// The display without any of Nano's windows: no island, no ink, no pill.
    nonisolated static func screenshot(displayID: CGDirectDisplayID, pixelSize: CGSize) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { return nil }
        let nano = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: nano, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixelSize.width)
        configuration.height = Int(pixelSize.height)
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

// MARK: Overlay

/// A transparent window over one display. Click-through unless Draw is on.
@MainActor
final class VoiceDictationSketchOverlay: NSPanel {
    let ink: VoiceDictationSketchInkView

    init(screen: NSScreen) {
        ink = VoiceDictationSketchInkView(origin: screen.frame.origin)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        sharingType = .none
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ink.frame = NSRect(origin: .zero, size: screen.frame.size)
        contentView = ink
        setFrame(screen.frame, display: false)
    }

    /// The red edge light is already at the edges and only fades in.
    func fadeIn() {
        alphaValue = 0
        ink.layoutSubtreeIfNeeded()
        ink.layer?.layoutIfNeeded()
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.7
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [self] in
            MainActor.assumeIsolated { orderOut(nil) }
        })
    }

    func setPen(_ on: Bool) {
        ignoresMouseEvents = !on
        ink.setPen(on)
        if on { NSCursor.crosshair.push() } else { NSCursor.pop() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Ink as Core Animation shape layers: the live stroke updates per pointer
/// event without redrawing the screen, and finished strokes fade on the GPU.
@MainActor
final class VoiceDictationSketchInkView: NSView {
    enum PenPhase { case began, moved, ended }

    /// How long a finished mark stays before it fades.
    static let holdSeconds: CFTimeInterval = 1.4
    static let fadeSeconds: CFTimeInterval = 0.5

    var onPen: ((PenPhase, CGPoint) -> Void)?
    private let origin: CGPoint
    private let live = CAShapeLayer()
    private let glow = CALayer()
    private var glowEdges: [CAGradientLayer] = []
    private var marks: [CALayer] = []

    init(origin: CGPoint) {
        self.origin = origin
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(glow)
        for (start, end) in [((0.5, 1.0), (0.5, 0.0)), ((0.5, 0.0), (0.5, 1.0)), ((0.0, 0.5), (1.0, 0.5)), ((1.0, 0.5), (0.0, 0.5))] {
            let edge = CAGradientLayer()
            edge.startPoint = CGPoint(x: start.0, y: start.1)
            edge.endPoint = CGPoint(x: end.0, y: end.1)
            glow.addSublayer(edge)
            glowEdges.append(edge)
        }
        setGlow(strong: false)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // A slow breath says "recording" without pulling the eye.
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.55
            breathe.toValue = 1
            breathe.duration = 1.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glow.add(breathe, forKey: "breathe")
        }
        Self.style(live)
        layer?.addSublayer(live)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        let depth = glowDepth
        if glowEdges.count == 4 {
            glowEdges[0].frame = CGRect(x: 0, y: bounds.height - depth, width: bounds.width, height: depth)
            glowEdges[1].frame = CGRect(x: 0, y: 0, width: bounds.width, height: depth)
            glowEdges[2].frame = CGRect(x: 0, y: 0, width: depth, height: bounds.height)
            glowEdges[3].frame = CGRect(x: bounds.width - depth, y: 0, width: depth, height: bounds.height)
        }
        live.frame = bounds
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static func style(_ shape: CAShapeLayer) {
        shape.fillColor = nil
        shape.strokeColor = VoiceDictationSketchRenderer.inkColor
        shape.lineWidth = VoiceDictationSketchRenderer.inkWidth
        shape.lineCap = .round
        shape.lineJoin = .round
    }

    func setPen(_ on: Bool) {
        setGlow(strong: on)
    }

    private var glowDepth: CGFloat = 44

    /// A soft red light fading in from every edge of the display. Stronger
    /// while Draw is on, since clicks no longer reach the apps.
    private func setGlow(strong: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glowDepth = strong ? 64 : 44
        let edge = VoiceDictationSketchRenderer.inkColor.copy(alpha: strong ? 0.42 : 0.26)!
        let middle = VoiceDictationSketchRenderer.inkColor.copy(alpha: strong ? 0.12 : 0.07)!
        let clear = VoiceDictationSketchRenderer.inkColor.copy(alpha: 0)!
        for layer in glowEdges {
            layer.colors = [edge, middle, clear]
            layer.locations = [0, 0.35, 1]
        }
        CATransaction.commit()
        needsLayout = true
    }

    func setLive(_ points: [CGPoint]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live.path = points.count > 1 ? VoiceDictationSketchRenderer.smoothPath(points.map(local)) : nil
        CATransaction.commit()
    }

    /// Keeps a finished mark for a moment with its "#N 0:15" tag, then fades it.
    func commit(_ points: [CGPoint], label: String, showsLabel: Bool) {
        guard let host = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let group = CALayer()
        group.frame = bounds
        let shape = CAShapeLayer()
        Self.style(shape)
        shape.frame = bounds
        shape.path = VoiceDictationSketchRenderer.smoothPath(points.map(local))
        group.addSublayer(shape)
        if showsLabel, let start = points.first.map(local) {
            group.addSublayer(tag(label, near: start))
        }
        host.addSublayer(group)
        marks.append(group)
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + Self.holdSeconds
        fade.duration = Self.fadeSeconds
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        group.add(fade, forKey: "fade")
        Task { [weak self, weak group] in
            try? await Task.sleep(for: .seconds(Self.holdSeconds + Self.fadeSeconds))
            guard let group else { return }
            group.removeFromSuperlayer()
            self?.marks.removeAll { $0 === group }
        }
    }

    func removeLastMark() {
        marks.popLast()?.removeFromSuperlayer()
    }

    private func tag(_ text: String, near point: CGPoint) -> CALayer {
        let font = NSFont.systemFont(ofSize: 12, weight: .bold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let box = CGSize(width: size.width + 16, height: size.height + 8)
        let background = CALayer()
        background.frame = CGRect(
            x: min(max(point.x - box.width - 6, 4), bounds.width - box.width - 4),
            y: min(max(point.y + 8, 4), bounds.height - box.height - 4),
            width: box.width, height: box.height
        )
        background.backgroundColor = CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 0.9)
        background.cornerRadius = box.height / 2
        let label = CATextLayer()
        label.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.alignmentMode = .center
        label.frame = CGRect(x: 0, y: 4, width: box.width, height: size.height)
        background.addSublayer(label)
        return background
    }

    private func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    private func global(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }

    override func mouseDown(with event: NSEvent) { onPen?(.began, global(event)) }
    override func mouseDragged(with event: NSEvent) { onPen?(.moved, global(event)) }
    override func mouseUp(with event: NSEvent) { onPen?(.ended, global(event)) }
}

// MARK: Pill

struct VoiceDictationSketchPillActions {
    var togglePen: () -> Void
    var undo: () -> Void
    var cancel: () -> Void
    var finish: () -> Void
}

/// The Sketch controls, floating at the bottom of the display being marked
/// up, clear of the island and the notch.
@MainActor
final class VoiceDictationSketchPill: NSPanel {
    init(state: VoiceDictationSketchState, screen: NSScreen, actions: VoiceDictationSketchPillActions) {
        let size = CGSize(width: 560, height: 52)
        let frame = CGRect(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.minY + 28,
            width: size.width,
            height: size.height
        )
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        sharingType = .none
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = VoiceDictationSketchPillHost(rootView: VoiceDictationSketchPillView(state: state, actions: actions))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons work on the first click without making Nano the active app.
private final class VoiceDictationSketchPillHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct VoiceDictationSketchPillView: View {
    @ObservedObject var state: VoiceDictationSketchState
    let actions: VoiceDictationSketchPillActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                    .modifier(PulseModifier(active: !reduceMotion))
                TimelineView(.periodic(from: state.startedAt, by: 1)) { context in
                    Text(VoiceDictationSketchText.clock(context.date.timeIntervalSince(state.startedAt)))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .padding(.leading, 6)

            Divider().frame(height: 22).overlay(Color.white.opacity(0.15))

            Button(action: actions.togglePen) {
                Label("Draw", systemImage: "pencil.tip")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(state.isPenOn ? Color.red : Color.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(state.isPenOn ? "Drag to draw. Click to go back to using the screen." : "Turn on to draw by dragging")

            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: actions.undo) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(state.marks == 0)
            .opacity(state.marks == 0 ? 0.4 : 1)
            .help("Undo the last mark (⌘Z)")

            Button("Cancel", action: actions.cancel)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 4)

            Button(action: actions.finish) {
                Text("Finish")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .help(state.finishShortcut.isEmpty ? "Finish" : "Finish (\(state.finishShortcut))")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.09, green: 0.09, blue: 0.1).opacity(0.96), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    private var hint: String {
        if state.isPenOn { return "Drag to draw" }
        let marks = state.marks == 0 ? "" : " · \(state.marks) mark\(state.marks == 1 ? "" : "s")"
        return "Hold \(state.drawKey.symbol) and move to draw\(marks)"
    }
}

private struct PulseModifier: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
