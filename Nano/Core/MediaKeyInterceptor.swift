import AppKit
import CoreAudio
import CoreGraphics
import Darwin
import Foundation

/// Pure decoding of the NX_SYSDEFINED media-key packet carried in `data1`.
enum MediaKeyPacket {
    struct Decoded: Equatable {
        let code: UInt32
        let isDown: Bool
        let isRepeat: Bool
    }

    static func decode(data1: Int) -> Decoded {
        Decoded(
            code: UInt32((data1 & 0xFFFF0000) >> 16),
            isDown: ((data1 & 0xFF00) >> 8) == 0x0A,
            isRepeat: data1 & 0x1 != 0
        )
    }
}

/// Pure volume math for the intercepted keys. macOS steps by 1/16, or 1/64
/// when Option-Shift is held.
enum MediaKeyVolumeStep {
    static let coarse = 1.0 / 16
    static let fine = 1.0 / 64

    struct State: Equatable {
        var level: Double
        var muted: Bool
    }

    static func apply(_ kind: MediaKeyKind, to state: State, fine: Bool) -> State {
        let step = fine ? Self.fine : Self.coarse
        var next = state
        switch kind {
        case .volumeUp:
            next.level = min(state.level + step, 1)
            next.muted = false
        case .volumeDown:
            next.level = max(state.level - step, 0)
        case .mute:
            next.muted.toggle()
        case .brightnessUp, .brightnessDown:
            break
        }
        return next
    }
}

/// Which presses were left to macOS. A key down Nano could not act on goes
/// through, and its key up has to follow it or macOS sees half a press.
struct MediaKeyPassThrough: Equatable {
    private var codes: Set<UInt32> = []

    /// Returns true when the event must be swallowed. `handled` says whether a
    /// key down changed anything; it is ignored for a key up.
    mutating func swallows(code: UInt32, isDown: Bool, handled: Bool) -> Bool {
        if isDown {
            if handled {
                codes.remove(code)
            } else {
                codes.insert(code)
            }
            return handled
        }
        return codes.remove(code) == nil
    }
}

/// DisplayServices is the private framework Control Center uses for display
/// brightness; there is no public API that works on Apple Silicon. Symbols are
/// resolved once via dlopen so a macOS without them degrades to nil.
enum DisplayBrightnessService {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool

    private nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY
    )
    private static let getBrightness: GetBrightnessFn? = symbol("DisplayServicesGetBrightness")
    private static let setBrightness: SetBrightnessFn? = symbol("DisplayServicesSetBrightness")
    private static let canChange: CanChangeFn? = symbol("DisplayServicesCanChangeBrightness")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// The display brightness keys should drive: the built-in panel when it is
    /// adjustable, otherwise the first display that reports it can change. On a
    /// Mac mini with a fixed external display this is nil and macOS keeps the
    /// keys.
    static var controllableDisplay: CGDirectDisplayID? {
        guard let canChange else { return nil }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var fetched: UInt32 = 0
        guard CGGetActiveDisplayList(count, &displays, &fetched) == .success else { return nil }
        let active = displays.prefix(Int(fetched))
        return active.first(where: { CGDisplayIsBuiltin($0) != 0 && canChange($0) })
            ?? active.first(where: { canChange($0) })
    }

    static func read() -> Double? {
        guard let display = controllableDisplay, let getBrightness else { return nil }
        var level: Float = 0
        return getBrightness(display, &level) == 0 ? Double(level) : nil
    }

    static func write(_ level: Double) -> Bool {
        guard let display = controllableDisplay, let setBrightness else { return false }
        return setBrightness(display, Float(min(max(level, 0), 1))) == 0
    }
}

/// Swallows the volume and brightness media keys with a CGEvent tap so macOS
/// never draws its own HUD, applies the change directly, and routes Nano's HUD.
/// Requires Accessibility; without it `tapCreate` fails and the status surfaces
/// in settings instead of prompting from a global key path.
@MainActor
final class MediaKeyInterceptor: ObservableObject {
    enum Status: Equatable {
        case off, active, needsAccessibility, failed
    }

    struct Configuration: Equatable {
        var volume: Bool
        var brightness: Bool
        var feedbackSound: Bool
    }

    var onNotification: ((IslandNotification) -> Void)?

    @Published private(set) var status: Status = .off

    private var configuration = Configuration(volume: false, brightness: false, feedbackSound: false)
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var feedbackPlayer: NSSound?
    private var passThrough = MediaKeyPassThrough()

    func configure(_ configuration: Configuration) {
        self.configuration = configuration
        if configuration.volume || configuration.brightness {
            if tap == nil {
                installTap()
            } else {
                status = .active
            }
        } else {
            removeTap()
            status = .off
        }
    }

    func stop() {
        removeTap()
        status = .off
    }

    private func installTap() {
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << 14), // NX_SYSDEFINED
            callback: Self.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            status = NanoAccessibilityPermission.isTrusted ? .failed : .needsAccessibility
            return
        }
        tap = created
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        status = .active
    }

    private func removeTap() {
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
            self.tapSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        // CGEvent is not Sendable, so it crosses into the main-actor hop as a
        // raw pointer. The tap's run-loop source lives on the main run loop, so
        // this callback always executes on the main thread.
        let typeRaw = type.rawValue
        let eventAddress = UInt(bitPattern: Unmanaged.passUnretained(event).toOpaque())
        let consumed = MainActor.assumeIsolated {
            interceptor.handle(
                type: typeRaw,
                event: Unmanaged<CGEvent>.fromOpaque(
                    UnsafeMutableRawPointer(bitPattern: eventAddress)!
                ).takeUnretainedValue()
            )
        }
        return consumed ? nil : Unmanaged.passUnretained(event)
    }

    /// Returns true when the event was handled and must be swallowed.
    private func handle(type: UInt32, event: CGEvent) -> Bool {
        if type == CGEventType.tapDisabledByTimeout.rawValue
            || type == CGEventType.tapDisabledByUserInput.rawValue
        {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == 14, // NX_SYSDEFINED
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8
        else {
            return false
        }
        let packet = MediaKeyPacket.decode(data1: nsEvent.data1)
        guard let kind = interceptedKind(for: packet.code) else {
            return false
        }
        let handled = packet.isDown && perform(
            kind,
            fine: nsEvent.modifierFlags.contains(.option) && nsEvent.modifierFlags.contains(.shift)
        )
        // Both halves are swallowed so macOS never sees the press. When the
        // level cannot be read or written (an output with no main volume),
        // both halves go through instead, so the key still does something.
        return passThrough.swallows(code: packet.code, isDown: packet.isDown, handled: handled)
    }

    private func interceptedKind(for code: UInt32) -> MediaKeyKind? {
        switch code {
        case 0: return configuration.volume ? .volumeUp : nil
        case 1: return configuration.volume ? .volumeDown : nil
        case 7: return configuration.volume ? .mute : nil
        case 2: return interceptsBrightness ? .brightnessUp : nil
        case 3: return interceptsBrightness ? .brightnessDown : nil
        default: return nil
        }
    }

    private var interceptsBrightness: Bool {
        configuration.brightness && DisplayBrightnessService.controllableDisplay != nil
    }

    /// Returns false when nothing could be changed, so the key is left to macOS.
    private func perform(_ kind: MediaKeyKind, fine: Bool) -> Bool {
        switch kind {
        case .volumeUp, .volumeDown, .mute:
            let reading = SystemStatusService.readOutputVolume()
            guard let level = reading.level else { return false }
            let next = MediaKeyVolumeStep.apply(
                kind,
                to: .init(level: level, muted: reading.muted),
                fine: fine
            )
            guard SystemStatusService.writeOutputVolume(next.level) else { return false }
            if next.muted != reading.muted {
                _ = SystemStatusService.writeOutputMuted(next.muted)
            }
            if configuration.feedbackSound { playFeedback() }
            onNotification?(.volume(level: next.level, muted: next.muted))
            return true
        case .brightnessUp, .brightnessDown:
            guard let level = DisplayBrightnessService.read() else { return false }
            let step = fine ? MediaKeyVolumeStep.fine : MediaKeyVolumeStep.coarse
            let next = min(max(level + (kind == .brightnessUp ? step : -step), 0), 1)
            guard DisplayBrightnessService.write(next) else { return false }
            onNotification?(.brightness(level: next))
            return true
        }
    }

    private func playFeedback() {
        if feedbackPlayer == nil {
            let path = "/System/Library/CoreServices/OSDUIHelper.app/Contents/Resources/volume.aiff"
            feedbackPlayer = FileManager.default.fileExists(atPath: path)
                ? NSSound(contentsOfFile: path, byReference: true)
                : NSSound(named: NSSound.Name("Tink"))
        }
        feedbackPlayer?.stop()
        feedbackPlayer?.play()
    }
}
