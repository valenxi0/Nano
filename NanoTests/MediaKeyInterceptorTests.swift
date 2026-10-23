import XCTest
@testable import Nano

final class MediaKeyInterceptorTests: XCTestCase {
    func testMediaKeyPacketDecodesKeyDown() {
        let decoded = MediaKeyPacket.decode(data1: 0x0A00)
        XCTAssertEqual(decoded.code, 0)
        XCTAssertTrue(decoded.isDown)
        XCTAssertFalse(decoded.isRepeat)
    }

    func testMediaKeyPacketDecodesKeyUp() {
        let decoded = MediaKeyPacket.decode(data1: 0x0B00)
        XCTAssertEqual(decoded.code, 0)
        XCTAssertFalse(decoded.isDown)
        XCTAssertFalse(decoded.isRepeat)
    }

    func testMediaKeyPacketDecodesRepeatingMute() {
        let decoded = MediaKeyPacket.decode(data1: (7 << 16) | 0x0A00 | 1)
        XCTAssertEqual(decoded.code, 7)
        XCTAssertTrue(decoded.isDown)
        XCTAssertTrue(decoded.isRepeat)
    }

    func testVolumeUpCoarseStepUnmutes() {
        let next = MediaKeyVolumeStep.apply(
            .volumeUp,
            to: .init(level: 0.5, muted: false),
            fine: false
        )
        XCTAssertEqual(next.level, 0.5625, accuracy: 0.0001)
        XCTAssertFalse(next.muted)
    }

    func testVolumeUpFineStep() {
        let next = MediaKeyVolumeStep.apply(
            .volumeUp,
            to: .init(level: 0.5, muted: false),
            fine: true
        )
        XCTAssertEqual(next.level, 0.515625, accuracy: 0.0001)
    }

    func testVolumeUpFromMutedUnmutesAndSteps() {
        let next = MediaKeyVolumeStep.apply(
            .volumeUp,
            to: .init(level: 0.3, muted: true),
            fine: false
        )
        XCTAssertEqual(next.level, 0.3625, accuracy: 0.0001)
        XCTAssertFalse(next.muted)
    }

    func testVolumeDownClampsAtZeroAndKeepsMute() {
        let next = MediaKeyVolumeStep.apply(
            .volumeDown,
            to: .init(level: 0.03, muted: true),
            fine: false
        )
        XCTAssertEqual(next.level, 0, accuracy: 0.0001)
        XCTAssertTrue(next.muted)
    }

    func testVolumeUpClampsAtOne() {
        let next = MediaKeyVolumeStep.apply(
            .volumeUp,
            to: .init(level: 0.98, muted: false),
            fine: false
        )
        XCTAssertEqual(next.level, 1, accuracy: 0.0001)
    }

    func testMuteToggles() {
        let state = MediaKeyVolumeStep.State(level: 0.5, muted: false)
        XCTAssertTrue(MediaKeyVolumeStep.apply(.mute, to: state, fine: false).muted)
        XCTAssertFalse(MediaKeyVolumeStep.apply(.mute, to: .init(level: 0.5, muted: true), fine: false).muted)
    }

    func testBrightnessKindsLeaveVolumeStateAlone() {
        let state = MediaKeyVolumeStep.State(level: 0.4, muted: true)
        XCTAssertEqual(MediaKeyVolumeStep.apply(.brightnessUp, to: state, fine: false), state)
        XCTAssertEqual(MediaKeyVolumeStep.apply(.brightnessDown, to: state, fine: true), state)
    }

    func testHandledPressIsSwallowedOnBothHalves() {
        var passThrough = MediaKeyPassThrough()
        XCTAssertTrue(passThrough.swallows(code: 0, isDown: true, handled: true))
        XCTAssertTrue(passThrough.swallows(code: 0, isDown: false, handled: false))
    }

    func testUnhandledPressGoesToMacOSOnBothHalves() {
        var passThrough = MediaKeyPassThrough()
        XCTAssertFalse(passThrough.swallows(code: 1, isDown: true, handled: false))
        // A repeat while the key is held is still left alone.
        XCTAssertFalse(passThrough.swallows(code: 1, isDown: true, handled: false))
        XCTAssertFalse(passThrough.swallows(code: 1, isDown: false, handled: false))
        // The next press starts clean: a key up with no passed key down is swallowed.
        XCTAssertTrue(passThrough.swallows(code: 1, isDown: false, handled: false))
    }

    func testPassThroughIsTrackedPerKey() {
        var passThrough = MediaKeyPassThrough()
        XCTAssertFalse(passThrough.swallows(code: 0, isDown: true, handled: false))
        XCTAssertTrue(passThrough.swallows(code: 2, isDown: true, handled: true))
        XCTAssertTrue(passThrough.swallows(code: 2, isDown: false, handled: false))
        XCTAssertFalse(passThrough.swallows(code: 0, isDown: false, handled: false))
    }

    @MainActor
    func testMediaKeySettingsDefaults() {
        let suiteName = "NanoTests.mediaKeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)

        XCTAssertFalse(settings.hudReplacesSystemHUD)
        XCTAssertTrue(settings.hudReplacesVolumeKeys)
        XCTAssertTrue(settings.hudReplacesBrightnessKeys)
        XCTAssertFalse(settings.hudVolumeFeedbackSound)
    }
}
