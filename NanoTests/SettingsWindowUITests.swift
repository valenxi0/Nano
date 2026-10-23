import AppKit
import SwiftUI
import XCTest
@testable import Nano

/// Drives Settings through a real window with real mouse events.
///
/// Offscreen renders can't catch window-level bugs: the dashboard editor's
/// drag and drop once broke because the window moved on background drags,
/// and every rendering test still passed. Controls are found by
/// accessibility identifier, not screen position, so layout changes don't
/// break these tests.
@MainActor
final class SettingsWindowUITests: XCTestCase {
    private var suite: String!
    private var window: NSWindow?

    override func setUp() async throws {
        try await super.setUp()
        suite = "nano-ui-\(UUID().uuidString)"
        NanoTestProbe.frames = [:]
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
        UserDefaults().removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    // MARK: Harness

    /// A locked screen stops macOS delivering synthetic drags to SwiftUI, so
    /// drag tests only mean something while someone is at the Mac.
    ///
    /// Drag tests are reliable on their own but not after the rest of the
    /// suite has run in the same process, so they run as a separate step:
    /// `TEST_RUNNER_NANO_UI_TESTS=1 xcodebuild … test -only-testing:NanoTests/SettingsWindowUITests`
    private func skipIfScreenLocked() throws {
        if ProcessInfo.processInfo.environment["NANO_UI_TESTS"] != "1" {
            throw XCTSkip("Drag tests run as their own step; set TEST_RUNNER_NANO_UI_TESTS=1.")
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? Bool) == true
            || (session?["CGSSessionScreenIsLocked"] as? Int) == 1
        if locked {
            throw XCTSkip("The screen is locked; drag tests need an unlocked session.")
        }
    }

    /// Hosts `root` exactly the way the app hosts Settings.
    private func present<Root: View>(_ root: Root, size: NSSize) -> (NSWindow, SettingsHostingView<Root>) {
        let hosting = SettingsHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 160, y: 160), size: size),
            styleMask: SettingsWindowChrome.styleMask,
            backing: .buffered,
            defer: false
        )
        // Earlier test classes leave windows (islands, panels) in this process;
        // any of them can sit over this one or hold key status.
        for other in NSApp.windows where other.isVisible {
            other.orderOut(nil)
        }
        window.contentView = hosting
        SettingsWindowChrome.apply(window)
        window.setContentSize(size)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        settle(1.0)
        return (window, hosting)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Window-space center of a control tagged with `testProbe(id)`.
    private func center(of id: String, in window: NSWindow) -> NSPoint? {
        guard let frame = NanoTestProbe.frames[id], let content = window.contentView else { return nil }
        // Probe frames use a top-left origin; window events use bottom-left.
        return NSPoint(x: frame.midX, y: content.bounds.height - frame.midY)
    }

    private func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow) {
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        // Tests run in parallel processes whose windows can take focus;
        // take it back right before the gesture starts.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        settle(0.2)
        window.sendEvent(event(.leftMouseDown, start))
        for step in 1...14 {
            let t = CGFloat(step) / 14
            window.sendEvent(event(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)))
            settle(0.02)
        }
        window.sendEvent(event(.leftMouseUp, end))
        settle(0.4)
    }

    private func slotCenter(_ area: DashboardArea, in window: NSWindow) throws -> NSPoint {
        try XCTUnwrap(center(of: "dashboard.slot.\(area.rawValue)", in: window), "slot \(area.rawValue) not found")
    }

    private func makeEditor() -> (NanoSettings, NSWindow) {
        let settings = NanoSettings(defaults: UserDefaults(suiteName: suite)!)
        let viewModel = IslandViewModel(settings: settings)
        let root = DashboardEditor(settings: settings, viewModel: viewModel)
            .frame(width: 606)
            .padding(20)
        let (window, _) = present(root, size: NSSize(width: 646, height: 780))
        return (settings, window)
    }

    // MARK: Tests

    func testDashboardEditorDragSwapsFeaturesInTheRealWindow() throws {
        try skipIfScreenLocked()
        let (settings, window) = makeEditor()
        let origin = window.frame.origin
        XCTAssertEqual(settings.dashboardFeature(in: .area1), .music)
        XCTAssertEqual(settings.dashboardFeature(in: .area2), .calendar)

        drag(from: try slotCenter(.area1, in: window), to: try slotCenter(.area2, in: window), in: window)

        XCTAssertEqual(settings.dashboardFeature(in: .area2), .music)
        XCTAssertEqual(settings.dashboardFeature(in: .area1), .calendar)
        XCTAssertEqual(window.frame.origin, origin, "dragging content must not move the window")
    }

    func testDraggingAFeatureOffTheDashboardRemovesIt() throws {
        try skipIfScreenLocked()
        let (settings, window) = makeEditor()
        XCTAssertEqual(settings.dashboardFeature(in: .area3), .weather)

        let start = try slotCenter(.area3, in: window)
        drag(from: start, to: NSPoint(x: start.x, y: 12), in: window)

        XCTAssertNil(settings.dashboardFeature(in: .area3))
    }

    func testDropOnAnIncompatibleSlotChangesNothing() throws {
        try skipIfScreenLocked()
        let (settings, window) = makeEditor()
        drag(from: try slotCenter(.area1, in: window), to: try slotCenter(.area5, in: window), in: window)

        XCTAssertEqual(settings.dashboardFeature(in: .area1), .music, "Music can't be a quick action")
        XCTAssertEqual(settings.dashboardFeature(in: .area5), .camera)
    }

    func testEverySettingsPageOpensWithItsTitle() throws {
        let settings = NanoSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.setEnabled(true, for: .agents)
        settings.setEnabled(true, for: .cue)
        settings.setEnabled(true, for: .voiceDictation)
        let viewModel = IslandViewModel(settings: settings)
        for destination in SettingsDestination.allCases {
            let (window, _) = present(
                NanoSettingsView(settings: settings, viewModel: viewModel, initialDestination: destination),
                size: SettingsWindowChrome.size
            )
            XCTAssertNotNil(NanoTestProbe.frames["settings.page.title.\(destination.title)"], "\(destination.title) has no page title")
            window.orderOut(nil)
        }
    }

    func testTopStripStillMovesTheWindow() throws {
        let settings = NanoSettings(defaults: UserDefaults(suiteName: suite)!)
        let viewModel = IslandViewModel(settings: settings)
        let (window, hosting) = present(
            NanoSettingsView(settings: settings, viewModel: viewModel),
            size: SettingsWindowChrome.size
        )
        XCTAssertFalse(window.isMovableByWindowBackground, "background drags belong to the content")
        XCTAssertFalse(hosting.mouseDownCanMoveWindow)
    }
}
