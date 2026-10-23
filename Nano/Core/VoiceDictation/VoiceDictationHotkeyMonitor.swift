import AppKit
import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut with separate press and release events, which is
/// what push-to-talk needs. Carbon's `RegisterEventHotKey` delivers both
/// without Accessibility or Input Monitoring permission, unlike an
/// `NSEvent` global key monitor, so the feature works the moment it is turned
/// on. The shortcut is claimed exclusively; if another app already owns it,
/// registration fails and `registrationError` says so.
@MainActor
final class VoiceDictationHotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fired when the bare Escape key is pressed while `registerCancelKey()`
    /// is in effect.
    var onCancel: (() -> Void)?

    private(set) var registeredHotkey: VoiceDictationHotkey?
    private(set) var registrationError: String?
    private(set) var isCancelKeyRegistered = false

    private var hotKeyRef: EventHotKeyRef?
    private var cancelKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isDown = false
    private static let signature: OSType = 0x4E56_4443 // 'NVDC'
    private static let dictationHotKeyID: UInt32 = 1
    private static let cancelHotKeyID: UInt32 = 2
    static let escapeKeyCode: UInt32 = 53

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let cancelKeyRef { UnregisterEventHotKey(cancelKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    @discardableResult
    func register(_ hotkey: VoiceDictationHotkey) -> Bool {
        unregister()
        guard hotkey.isUsable else {
            registrationError = "Add ⌃, ⌥ or ⌘ to the shortcut."
            return false
        }
        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.dictationHotKeyID)
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            Self.carbonModifiers(for: hotkey.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            registrationError = status == OSStatus(eventHotKeyExistsErr)
                ? "\(hotkey.displayString) is already used by another app. Choose a different shortcut."
                : "The shortcut could not be registered (error \(status))."
            return false
        }
        hotKeyRef = reference
        registeredHotkey = hotkey
        registrationError = nil
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredHotkey = nil
        isDown = false
    }

    /// Claims the unmodified Escape key system-wide so a dictation in flight
    /// can be abandoned from any app. Because this steals Escape from every
    /// other app, callers must hold it only while a dictation is actually
    /// busy and release it the moment the controller returns to idle.
    /// Failure (another app owns bare Escape) is silent: cancel is a
    /// convenience and must never surface as a hotkey problem.
    @discardableResult
    func registerCancelKey() -> Bool {
        guard cancelKeyRef == nil else { return true }
        installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.cancelHotKeyID)
        let status = RegisterEventHotKey(
            Self.escapeKeyCode,
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        cancelKeyRef = reference
        isCancelKeyRegistered = true
        return true
    }

    func unregisterCancelKey() {
        if let cancelKeyRef {
            UnregisterEventHotKey(cancelKeyRef)
            self.cancelKeyRef = nil
        }
        isCancelKeyRegistered = false
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let handler: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == VoiceDictationHotkeyMonitor.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let monitor = Unmanaged<VoiceDictationHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
            let kind = GetEventKind(event)
            // Carbon dispatches hot key events on the main thread's run loop.
            MainActor.assumeIsolated {
                switch (hotKeyID.id, kind) {
                case (VoiceDictationHotkeyMonitor.dictationHotKeyID, UInt32(kEventHotKeyPressed)):
                    monitor.handlePress()
                case (VoiceDictationHotkeyMonitor.dictationHotKeyID, UInt32(kEventHotKeyReleased)):
                    monitor.handleRelease()
                case (VoiceDictationHotkeyMonitor.cancelHotKeyID, UInt32(kEventHotKeyPressed)):
                    monitor.onCancel?()
                default:
                    break
                }
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            types.count,
            &types,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func handlePress() {
        guard !isDown else { return }
        isDown = true
        onPress?()
    }

    private func handleRelease() {
        guard isDown else { return }
        isDown = false
        onRelease?()
    }

    static func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}

/// Turns the next key press in the Settings window into a hotkey. Local
/// monitor only: it listens while the window is key, never globally.
@MainActor
final class VoiceDictationHotkeyCapture: ObservableObject {
    @Published private(set) var isCapturing = false

    private var monitor: Any?

    func begin(_ completion: @escaping @MainActor (VoiceDictationHotkey?) -> Void) {
        end()
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Escape cancels
                self.end()
                completion(nil)
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .help])
            let hotkey = VoiceDictationHotkey(keyCode: event.keyCode, modifierFlags: flags.rawValue)
            guard hotkey.isUsable else { return nil }
            self.end()
            completion(hotkey)
            return nil
        }
    }

    func end() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isCapturing = false
    }
}
