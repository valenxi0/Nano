import AppKit
import Carbon.HIToolbox
import Foundation

/// System-wide Cue capture shortcut. Carbon hot keys need no Accessibility
/// or Input Monitoring consent, and the chord is claimed exclusively so a
/// clash with another app surfaces as `registrationError` instead of silence.
@MainActor
final class QuickCaptureHotkey {
    var onPress: (() -> Void)?

    private(set) var registeredHotkey: VoiceDictationHotkey?
    private(set) var registrationError: String?

    private let hotKeyID: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4E56_4355 // 'NVCU'

    init(id: UInt32) {
        hotKeyID = id
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    @discardableResult
    func register(_ hotkey: VoiceDictationHotkey) -> Bool {
        if registeredHotkey == hotkey, hotKeyRef != nil { return true }
        unregister()
        guard hotkey.isUsable else {
            registrationError = "Add ⌃, ⌥ or ⌘ to the shortcut."
            return false
        }
        installHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(hotkey.keyCode),
            VoiceDictationHotkeyMonitor.carbonModifiers(for: hotkey.modifiers),
            id,
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
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
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
            guard status == noErr, hotKeyID.signature == QuickCaptureHotkey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let monitor = Unmanaged<QuickCaptureHotkey>.fromOpaque(userData).takeUnretainedValue()
            return MainActor.assumeIsolated {
                // Several instances share the signature; only the one that
                // registered this id consumes the event.
                guard hotKeyID.id == monitor.hotKeyID else {
                    return OSStatus(eventNotHandledErr)
                }
                monitor.onPress?()
                return noErr
            }
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
}

extension Notification.Name {
    /// An island control (like an inline reply field) needs key-window focus.
    static let nanoIslandWantsKeyboard = Notification.Name("Nano.island.wantsKeyboard")
}
