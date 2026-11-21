import AppKit
import XCTest
@testable import Nano

@MainActor
final class FullScreenHidingTests: XCTestCase {
    private let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// Above and to the right of the primary display, in AppKit coordinates.
    private let external = CGRect(x: 1512, y: 200, width: 2560, height: 1440)
    private let ownPID: pid_t = 4242

    private func window(
        _ bounds: CGRect,
        layer: Int = 0,
        pid: pid_t = 100,
        alpha: Double = 1
    ) -> [String: Any] {
        [
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowLayer as String: layer,
            kCGWindowOwnerPID as String: pid,
            kCGWindowAlpha as String: alpha,
        ]
    }

    private func covered(_ screen: CGRect, by windows: [[String: Any]]) -> Bool {
        NanoFullScreenDetector.isCovered(
            screenFrame: screen,
            primaryScreenFrame: primary,
            windows: windows,
            ownPID: ownPID
        )
    }

    func testFullScreenWindowCoversItsDisplay() {
        XCTAssertTrue(covered(primary, by: [window(primary)]))
    }

    func testZoomedWindowBelowTheMenuBarDoesNot() {
        let zoomed = CGRect(x: 0, y: 37, width: 1512, height: 945)
        XCTAssertFalse(covered(primary, by: [window(zoomed)]))
    }

    func testFullScreenOnAnotherDisplayDoesNotCountHere() {
        // The external display in window-server (top-left) coordinates.
        let externalBounds = CGRect(x: 1512, y: 982 - 1640, width: 2560, height: 1440)
        let windows = [window(externalBounds)]
        XCTAssertTrue(covered(external, by: windows))
        XCTAssertFalse(covered(primary, by: windows))
    }

    func testOverlaysHiddenWindowsAndNanoItselfAreIgnored() {
        XCTAssertFalse(covered(primary, by: [window(primary, layer: 25)]))
        XCTAssertFalse(covered(primary, by: [window(primary, alpha: 0)]))
        XCTAssertFalse(covered(primary, by: [window(primary, pid: ownPID)]))
    }

    func testHidingInFullScreenIsOnByDefaultAndRemembered() {
        let suite = "nano-fullscreen-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = NanoSettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(settings.hidesInFullScreen)

        settings.hidesInFullScreen = false
        XCTAssertFalse(NanoSettings(defaults: UserDefaults(suiteName: suite)!).hidesInFullScreen)
    }
}
