import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import Foundation

enum NanoAccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions([
            "AXTrustedCheckOptionPrompt": false
        ] as CFDictionary)
    }

    /// Requests consent only in response to an action that needs it. Keeping
    /// this out of app launch prevents permission prompts from feeling random.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

enum VoiceDictationPasteOutcome: Equatable {
    case requested, accessibilityRequired, noEditableTarget, focusChanged, eventFailed

    var detail: String {
        switch self {
        case .requested: "Copied and paste sent to the focused field"
        case .accessibilityRequired: "Copied. Enable Nano in System Settings → Privacy & Security → Accessibility to paste automatically."
        case .noEditableTarget: "Copied. Focus a text field before starting dictation to paste automatically."
        case .focusChanged: "Copied. Paste skipped because keyboard focus changed."
        case .eventFailed: "Copied. Could not send the paste shortcut."
        }
    }
}

/// The focused editor inside Nano can accept dictation without driving Nano
/// through Accessibility. The controller captures the handler when recording
/// starts, just as it captures the destination process for external apps.
@MainActor
final class NanoVoiceDictationTextTarget {
    static let shared = NanoVoiceDictationTextTarget()

    private var activeID: UUID?
    private var insert: ((String) -> Bool)?

    private init() {}

    func activate(id: UUID, insert: @escaping (String) -> Bool) {
        activeID = id
        self.insert = insert
    }

    func deactivate(id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        insert = nil
    }

    /// A registered handler, or else the text view being edited in Nano's key
    /// window, such as a Cue capture.
    func capturedInsertion() -> ((String) -> Bool)? {
        if let insert { return insert }
        guard let textView = NSApp?.windows.first(where: \.isKeyWindow)?.firstResponder as? NSTextView,
              textView.isEditable else { return nil }
        return { [weak textView] text in
            guard let textView, textView.window != nil else { return false }
            textView.insertText(text, replacementRange: textView.selectedRange())
            return true
        }
    }
}

/// Remembers the destination app when recording starts, then resolves that
/// app's current editable element after transcription. This survives Nano's
/// own UI, permission prompts, and Electron focus changes becoming frontmost
/// while still avoiding a stale AX element captured minutes earlier.
@MainActor
final class VoiceDictationPasteTarget {
    struct EditableTarget {
        let processIdentifier: pid_t
        let insert: (String) -> Bool
        let paste: () -> Bool
        /// The field itself, so Quill can read back what the user fixed.
        var element: AXUIElement? = nil
    }

    private let isAccessibilityTrusted: () -> Bool
    private let requestAccessibility: () -> Void
    private let frontmostProcessIdentifier: () -> pid_t?
    private let editableTarget: (pid_t) -> EditableTarget?
    private var capturedProcessIdentifier: pid_t?
    /// The text field focused at capture. A Sketch puts focus back in it, since
    /// clicks while sketching move focus elsewhere in the app.
    private var capturedEditableElement: AXUIElement?
    private var capturedNanoInsertion: ((String) -> Bool)?
    /// The focused element's accessibility label at capture, used to tell a
    /// terminal pane inside an editor from its code and chat panes.
    private(set) var capturedFocusDescription: String?
    /// The field the last successful delivery went into.
    private(set) var lastDeliveredElement: AXUIElement?
    /// The focused window's title at capture, which names the agent or
    /// project running in a terminal tab.
    private(set) var capturedWindowTitle: String?
    /// The text around the caret when recording started, for fitting the
    /// dictation into it. Nil when the field doesn't report its caret.
    private(set) var capturedSurroundings: VoiceDictationSurroundings?
    /// The app the last delivery went to, for pasting it again.
    private(set) var lastDeliveredProcess: pid_t?

    init(
        isAccessibilityTrusted: @MainActor @escaping () -> Bool = { NanoAccessibilityPermission.isTrusted },
        requestAccessibility: @MainActor @escaping () -> Void = { NanoAccessibilityPermission.requestIfNeeded() },
        frontmostProcessIdentifier: @MainActor @escaping () -> pid_t? = VoiceDictationPasteTarget.frontmostPID,
        editableTarget: @MainActor @escaping (pid_t) -> EditableTarget? = VoiceDictationPasteTarget.currentEditableTarget
    ) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.requestAccessibility = requestAccessibility
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.editableTarget = editableTarget
    }

    func captureFocusedTarget() {
        capturedNanoInsertion = NanoVoiceDictationTextTarget.shared.capturedInsertion()
        capturedProcessIdentifier = frontmostProcessIdentifier()
        lastDeliveredElement = nil
        capturedFocusDescription = nil
        capturedSurroundings = nil
        capturedWindowTitle = nil
        capturedEditableElement = nil
        if capturedNanoInsertion == nil, isAccessibilityTrusted(), let capturedProcessIdentifier {
            capturedEditableElement = editableTarget(capturedProcessIdentifier)?.element
            capturedFocusDescription = Self.focusDescription(processIdentifier: capturedProcessIdentifier)
            capturedWindowTitle = Self.focusedWindowTitle(processIdentifier: capturedProcessIdentifier)
            if let element = Self.focusedElement(processIdentifier: capturedProcessIdentifier) {
                capturedSurroundings = Self.surroundings(of: element)
            }
        }
    }

    /// Whether the app captured at the start has a text field focused.
    var capturedTargetIsEditable: Bool {
        if capturedNanoInsertion != nil || capturedEditableElement != nil { return true }
        guard isAccessibilityTrusted(), let capturedProcessIdentifier else { return false }
        return editableTarget(capturedProcessIdentifier) != nil
    }

    var canPasteAutomatically: Bool {
        isAccessibilityTrusted()
    }

    /// The app the dictation was started in, for Insights. Read before paste,
    /// which clears the capture.
    var capturedApplication: (bundleID: String, name: String)? {
        guard let capturedProcessIdentifier,
              let app = NSRunningApplication(processIdentifier: capturedProcessIdentifier),
              let bundleID = app.bundleIdentifier else { return nil }
        return (bundleID, app.localizedName ?? bundleID)
    }

    /// Accessibility consent is requested only from an explicit Settings
    /// action. Dictation itself must remain usable as copy-only and must not
    /// reopen the system prompt every time a signing or TCC mismatch exists.
    func requestAutomaticPasteAccess() {
        guard !isAccessibilityTrusted() else { return }
        requestAccessibility()
    }

    func clearCapturedTarget() {
        capturedNanoInsertion = nil
        capturedProcessIdentifier = nil
        capturedEditableElement = nil
        capturedFocusDescription = nil
        capturedSurroundings = nil
    }

    /// The live delivery: like `pasteIntoFocusedTarget`, but a terminal paste
    /// can go in pieces through Command-V, and Return can follow. The full
    /// text is left on the clipboard.
    func deliver(_ text: String, chunks: [String], pressEnter: Bool) async -> VoiceDictationPasteOutcome {
        guard chunks.count > 1 || pressEnter else { return pasteIntoFocusedTarget(text) }
        defer { clearCapturedTarget() }
        if capturedNanoInsertion?(text) == true { return .requested }
        guard isAccessibilityTrusted() else { return .accessibilityRequired }
        let candidates = [capturedProcessIdentifier, frontmostProcessIdentifier()].compactMap { $0 }
        guard let processIdentifier = candidates.first(where: { editableTarget($0) != nil }),
              let target = editableTarget(processIdentifier)
        else { return .noEditableTarget }

        if chunks.count > 1 {
            for (index, chunk) in chunks.enumerated() {
                if index > 0 { try? await Task.sleep(for: .milliseconds(150)) }
                guard VoiceDictationController.copyToClipboard(chunk), target.paste() else { return .eventFailed }
            }
            try? await Task.sleep(for: .milliseconds(150))
            _ = VoiceDictationController.copyToClipboard(text)
        } else if !text.isEmpty, !(target.insert(text) || target.paste()) {
            return .eventFailed
        }
        lastDeliveredElement = target.element
        lastDeliveredProcess = processIdentifier
        if pressEnter {
            try? await Task.sleep(for: .milliseconds(120))
            guard Self.sendKey(36, flags: [], to: processIdentifier) else { return .eventFailed }
        }
        return .requested
    }

    /// Pastes text again into the app the last dictation went to.
    func pasteAgain(_ text: String) async -> VoiceDictationPasteOutcome {
        guard isAccessibilityTrusted() else { return .accessibilityRequired }
        guard let processIdentifier = lastDeliveredProcess ?? frontmostProcessIdentifier() else {
            return .noEditableTarget
        }
        Self.bringForward(processIdentifier)
        try? await Task.sleep(for: .milliseconds(250))
        guard VoiceDictationController.copyToClipboard(text) else { return .eventFailed }
        return Self.sendPasteShortcut(to: processIdentifier) ? .requested : .eventFailed
    }

    /// A Sketch goes back to the field it was started in, even after the user
    /// clicked around other apps: screenshots first, then the text. A GUI
    /// composer takes PNG data as an attachment; a terminal agent such as
    /// Claude Code takes a pasted image path.
    func pasteSketch(images: [Data], paths: [URL], text: String, terminal: Bool) async -> VoiceDictationPasteOutcome {
        defer { clearCapturedTarget() }
        guard isAccessibilityTrusted() else { return .accessibilityRequired }
        guard let processIdentifier = capturedProcessIdentifier else { return .noEditableTarget }
        Self.bringForward(processIdentifier)
        try? await Task.sleep(for: .milliseconds(300))
        if let field = capturedEditableElement {
            Self.refocus(field)
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard editableTarget(processIdentifier) != nil else { return .noEditableTarget }
        let pasteboard = NSPasteboard.general
        let attachments: [(NSPasteboard) -> Bool] = terminal
            ? paths.map { url in { $0.setString(url.path, forType: .string) } }
            : images.map { data in { $0.setData(data, forType: .png) } }
        for write in attachments {
            pasteboard.clearContents()
            guard write(pasteboard), Self.sendPasteShortcut(to: processIdentifier) else { return .eventFailed }
            // Electron reads the clipboard after the key event; give it time
            // before the clipboard changes under it.
            try? await Task.sleep(for: .milliseconds(terminal ? 250 : 400))
        }
        if terminal, !attachments.isEmpty {
            // Separates the last path from the text.
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard VoiceDictationController.copyToClipboard(text),
              Self.sendPasteShortcut(to: processIdentifier)
        else { return .eventFailed }
        lastDeliveredProcess = processIdentifier
        return .requested
    }

    /// Raises the field's window and puts the caret back in the field.
    static func refocus(_ field: AXUIElement) {
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
            let element = window as! AXUIElement
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Makes an app frontmost from the background. Accessibility does this
    /// reliably where `NSRunningApplication.activate` can be refused.
    static func bringForward(_ processIdentifier: pid_t) {
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(processIdentifier),
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        NSRunningApplication(processIdentifier: processIdentifier)?.activate()
    }

    private static func focusedWindowTitle(processIdentifier: pid_t) -> String? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(processIdentifier), kAXFocusedWindowAttribute as CFString, &window
        ) == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return title as? String
    }

    /// Up to 300 characters before the caret, 40 after, and the selection.
    /// A field showing only its placeholder counts as empty.
    private static func surroundings(of element: AXUIElement) -> VoiceDictationSurroundings? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var selected = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selected), selected.location >= 0 else { return nil }
        let total = characterCount(of: element) ?? (selected.location + selected.length)
        let beforeStart = max(0, selected.location - 300)
        let afterStart = selected.location + selected.length
        let afterLength = max(0, min(40, total - afterStart))
        guard let before = string(of: element, location: beforeStart, length: selected.location - beforeStart),
              let selection = string(of: element, location: selected.location, length: selected.length),
              let after = string(of: element, location: afterStart, length: afterLength)
        else { return nil }
        let labels = [kAXPlaceholderValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { attribute -> String? in
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
                    ? value as? String : nil
            }
        return VoiceDictationSurroundings(before: before, after: after, selection: selection)
            .ignoringPlaceholder(labels: labels)
    }

    private static func string(of element: AXUIElement, location: Int, length: Int) -> String? {
        guard length > 0 else { return "" }
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success else { return nil }
        return value as? String
    }

    func pasteIntoFocusedTarget(_ text: String) -> VoiceDictationPasteOutcome {
        defer { clearCapturedTarget() }
        if capturedNanoInsertion?(text) == true { return .requested }
        guard isAccessibilityTrusted() else { return .accessibilityRequired }

        var candidates: [pid_t] = []
        if let capturedProcessIdentifier {
            candidates.append(capturedProcessIdentifier)
        }
        if let current = frontmostProcessIdentifier(), !candidates.contains(current) {
            candidates.append(current)
        }

        for processIdentifier in candidates {
            guard let target = editableTarget(processIdentifier) else { continue }
            let outcome = Self.deliveryOutcome(
                accessibilityTrusted: true,
                hasFocusedEditableTarget: true,
                insertText: { target.insert(text) },
                sendPasteShortcut: target.paste
            )
            if outcome == .requested {
                lastDeliveredElement = target.element
                lastDeliveredProcess = processIdentifier
            }
            return outcome
        }
        return .noEditableTarget
    }

    /// Pure delivery policy used by the runtime and regression tests. Direct
    /// accessibility insertion is deterministic when an editor supports it;
    /// Command-V remains the compatibility fallback for other text controls.
    static func deliveryOutcome(
        accessibilityTrusted: Bool,
        hasFocusedEditableTarget: Bool,
        insertText: () -> Bool,
        sendPasteShortcut: () -> Bool
    ) -> VoiceDictationPasteOutcome {
        guard accessibilityTrusted else { return .accessibilityRequired }
        guard hasFocusedEditableTarget else { return .noEditableTarget }
        if insertText() || sendPasteShortcut() { return .requested }
        return .eventFailed
    }

    /// Chromium (Cursor, T3 Code, Electron, Chrome) reports `AXSelectedText`
    /// as settable and returns `.success` from the write while inserting
    /// nothing. A return code alone therefore cannot be trusted; the insert
    /// counts as done only when the element's character count moved by the
    /// expected amount. Anything unverifiable returns false so Command-V,
    /// which those apps do honor, runs instead.
    private static func insert(_ text: String, into element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success,
              settable.boolValue,
              let before = characterCount(of: element)
        else { return false }
        let selectedLength = selectedRangeLength(of: element) ?? 0

        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success,
              let after = characterCount(of: element)
        else { return false }

        return insertionConfirmed(
            charactersBefore: before,
            charactersAfter: after,
            replacedLength: selectedLength,
            insertedLength: text.utf16.count
        )
    }

    /// Pure check shared with tests: an accessibility insert is real only
    /// when the text length changed by exactly what was written minus what
    /// it replaced. An unchanged count is the Chromium false-success case.
    static func insertionConfirmed(
        charactersBefore: Int,
        charactersAfter: Int,
        replacedLength: Int,
        insertedLength: Int
    ) -> Bool {
        guard insertedLength > 0 else { return false }
        return charactersAfter == charactersBefore - replacedLength + insertedLength
    }

    private static func characterCount(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &value
        ) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    private static func selectedRangeLength(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.length
    }

    private static func sendPasteShortcut(to processIdentifier: pid_t) -> Bool {
        sendKey(pasteKeyCode(), flags: .maskCommand, to: processIdentifier)
    }

    private static func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags, to processIdentifier: pid_t) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: false
        ) else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(processIdentifier)
        up.postToPid(processIdentifier)
        return true
    }

    /// The key that types "v" with Command held in the current keyboard
    /// layout. Key code 9 is V only on QWERTY; on Dvorak it is K. Layouts
    /// with no Latin "v" keep 9, which is where their Command-V lives.
    static func pasteKeyCode() -> CGKeyCode {
        let ansiV: CGKeyCode = 9
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return ansiV }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return ansiV }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        let keyboardType = UInt32(LMGetKbdType())
        for keyCode in UInt16(0) ..< 128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                commandState,
                keyboardType,
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &characters
            )
            if status == noErr, length == 1, characters[0] == 0x76 { // "v"
                return keyCode
            }
        }
        return ansiV
    }

    private static func frontmostPID() -> pid_t? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return nil }
        return application.processIdentifier
    }

    private static func currentEditableTarget(processIdentifier: pid_t) -> EditableTarget? {
        guard let focused = focusedElement(processIdentifier: processIdentifier),
              isEditable(focused)
        else { return nil }
        return EditableTarget(
            processIdentifier: processIdentifier,
            insert: { insert($0, into: focused) },
            paste: { sendPasteShortcut(to: processIdentifier) },
            element: focused
        )
    }

    private static func focusDescription(processIdentifier: pid_t) -> String? {
        guard let focused = focusedElement(processIdentifier: processIdentifier) else { return nil }
        let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXRoleDescriptionAttribute].compactMap { attribute in
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(focused, attribute as CFString, &value) == .success
                ? value as? String : nil
        }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }

    private static func focusedElement(processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var enabledValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXEnabledAttribute as CFString,
            &enabledValue
        ) == .success,
           let enabled = enabledValue as? Bool,
           !enabled {
            return false
        }

        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        ) == .success,
           subroleValue as? String == "AXSecureTextField" {
            return false
        }

        var roleValue: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success ? roleValue as? String : nil
        if let role, [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            "AXSearchField",
            kAXComboBoxRole as String,
        ].contains(role) {
            return true
        }
        // Chromium reports the whole page as accepting `AXSelectedText`. When
        // the web area itself is focused, no input is; a real field would be
        // the focused element instead.
        if role == "AXWebArea" { return false }

        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }
}

enum VoiceDictationPhase: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case cleaning
    /// Held briefly after a copy so the island can show a confirmation.
    case completed
    case failed
    /// Held briefly after the user abandons a dictation.
    case cancelled

    var isBusy: Bool {
        switch self {
        case .recording, .transcribing, .cleaning: true
        case .idle, .completed, .failed, .cancelled: false
        }
    }

    var title: String {
        switch self {
        case .idle: "Ready"
        case .recording: "Listening"
        case .transcribing: "Transcribing"
        case .cleaning: "Cleaning up"
        case .completed: "Copied"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

enum VoiceDictationHotkeyEvent: Sendable {
    case pressed
    case released
    /// Bare Escape, delivered only while the cancel key is registered.
    case escape
}

enum VoiceDictationHotkeyAction: Equatable, Sendable {
    case start
    case stop
    case cancel
    case ignore
}

extension VoiceDictationActivationMode {
    func action(for event: VoiceDictationHotkeyEvent, phase: VoiceDictationPhase) -> VoiceDictationHotkeyAction {
        switch (self, event) {
        case (_, .escape):
            // Escape abandons whatever is in flight regardless of mode. Once
            // the controller is idle, completed or failed there is nothing
            // to abandon, and the key is not even registered.
            return phase.isBusy ? .cancel : .ignore
        case (.pushToTalk, .pressed):
            return phase.isBusy ? .ignore : .start
        case (.pushToTalk, .released):
            return phase == .recording ? .stop : .ignore
        case (.toggle, .pressed):
            if phase == .recording { return .stop }
            return phase.isBusy ? .ignore : .start
        case (.toggle, .released):
            return .ignore
        }
    }
}

/// Where the selected engine stands with respect to what is on disk and
/// what the system allows.
enum VoiceDictationReadiness: Equatable, Sendable {
    case ready
    case disabled
    case missingModels([VoiceDictationModelID])
    case microphoneDenied
    case microphoneUndetermined

    var isReady: Bool { self == .ready }
}

/// One place owns the hotkey, the recorder, the engines and the clipboard.
///
/// Every stage after "stop" runs on the engine actors; this object only
/// forwards state changes to the UI. Audio lives in `process(...)`'s
/// parameters and nowhere else.
@MainActor
final class VoiceDictationController: ObservableObject {
    /// The Escape cancel key is claimed system-wide, so it exists only for
    /// the exact span in which a dictation can be abandoned.
    @Published private(set) var phase: VoiceDictationPhase = .idle {
        didSet {
            guard phase.isBusy != oldValue.isBusy else { return }
            if phase.isBusy {
                hotkeyMonitor.registerCancelKey()
            } else {
                hotkeyMonitor.unregisterCancelKey()
                lastEscape = nil
                livePreview = ""
            }
        }
    }
    /// The words heard so far, while recording with live preview on.
    @Published private(set) var livePreview = "" {
        didSet {
            guard livePreview != oldValue else { return }
            livePreview.isEmpty ? captionPanel.hide() : captionPanel.show(livePreview)
        }
    }
    private let captionPanel = VoiceDictationCaptionPanel()
    /// Marks drawn in the Sketch being recorded; nil when not sketching.
    @Published private(set) var sketchMarks: Int?
    @Published private(set) var sketchHotkeyProblem: String?
    @Published private(set) var lastResult: VoiceDictationResult?
    @Published private(set) var lastPasteOutcome: VoiceDictationPasteOutcome?

    var deliveryTitle: String {
        guard phase == .completed else { return phase.title }
        return lastPasteOutcome == .requested ? "Paste sent" : "Copied only"
    }
    @Published private(set) var lastError: VoiceDictationError?
    @Published private(set) var loadedEngine: VoiceDictationEngine?
    @Published private(set) var isLoadingEngine = false
    @Published private(set) var hotkeyProblem: String?
    @Published private(set) var modelManagementError: String?
    @Published private(set) var microphoneAuthorization: VoiceDictationMicrophoneAuthorization

    let settings: NanoSettings
    let modelStore: VoiceDictationModelStore
    let history: VoiceDictationHistoryStore
    let stats: VoiceDictationStatsStore
    let corrections: VoiceDictationCorrectionStore
    private let correctionWatcher = VoiceDictationCorrectionWatcher()

    var canPasteAutomatically: Bool {
        pasteTarget.canPasteAutomatically
    }

    func requestAutomaticPasteAccess() {
        pasteTarget.requestAutomaticPasteAccess()
        objectWillChange.send()
    }
    let recorder: VoiceDictationAudioRecorder

    /// How long an engine stays resident after its last use. Long enough
    /// that a burst of dictations is all warm; short enough that Nano does
    /// not hold a gigabyte of weights through an afternoon of silence.
    var idleUnloadInterval: Duration = .seconds(10 * 60)
    /// How long "Copied" stays on the island.
    var completionHoldInterval: Duration = .seconds(1.6)
    /// How long a failure stays on the island.
    var failureHoldInterval: Duration = .seconds(3)
    /// How long "Cancelled" stays on the island. Shorter than "Copied": the
    /// user asked for this and wants the island out of the way.
    var cancelHoldInterval: Duration = .seconds(1.3)

    private let hotkeyMonitor = VoiceDictationHotkeyMonitor()
    private let sketchHotkey = QuickCaptureHotkey(id: 3)
    private let sketchUndoHotkey = QuickCaptureHotkey(id: 4)
    private var sketch: VoiceDictationSketchSession?
    private var lastEscape: ContinuousClock.Instant?
    private var livePreviewTask: Task<Void, Never>?
    private var vad: VoiceDictationVAD?
    private var vadLoad: Task<Void, Never>?
    private var vadFeeder: Task<Void, Never>?
    /// Projects and titles of the agent sessions running in each app, keyed
    /// by lowercased bundle ID. Set by the island, which owns the sessions.
    var agentSessionNames: () -> [String: [String]] = { [:] }
    /// The app the watched field belongs to, so a learned correction keeps it.
    private var correctionApp: (bundleID: String, name: String)?
    private let pasteTarget: VoiceDictationPasteTarget
    private var recognizer: VoiceDictationRecognizer?
    private var cleaner: VoiceDictationCleaner?
    private var enginesFor: VoiceDictationEngine?
    private var processingTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var settingsObserver: AnyCancellable?
    private var storeObserver: AnyCancellable?
    private var selectedEngineWasReady = false
    private var isActive = false
    private var recordingStartedAt: ContinuousClock.Instant?
    /// Bumped whenever a session ends early. A `process(...)` task that is
    /// stuck inside a non-cancellable engine call wakes up later and must not
    /// touch state that now belongs to a newer session.
    private var sessionGeneration: UInt64 = 0
    /// Bumped whenever a warm-up starts or the engines are dropped, so a
    /// cancelled load that finishes late cannot write over newer state.
    private var loadGeneration: UInt64 = 0

    init(
        settings: NanoSettings,
        modelStore: VoiceDictationModelStore? = nil,
        history: VoiceDictationHistoryStore? = nil,
        stats: VoiceDictationStatsStore? = nil,
        corrections: VoiceDictationCorrectionStore? = nil,
        recorder: VoiceDictationAudioRecorder? = nil,
        pasteTarget: VoiceDictationPasteTarget? = nil
    ) {
        self.settings = settings
        self.modelStore = modelStore ?? VoiceDictationModelStore()
        self.history = history ?? VoiceDictationHistoryStore()
        self.stats = stats ?? VoiceDictationStatsStore()
        self.corrections = corrections ?? VoiceDictationCorrectionStore()
        self.recorder = recorder ?? VoiceDictationAudioRecorder()
        self.pasteTarget = pasteTarget ?? VoiceDictationPasteTarget()
        microphoneAuthorization = VoiceDictationMicrophoneAuthorization.current

        hotkeyMonitor.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeyMonitor.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeyMonitor.onCancel = { [weak self] in self?.escapePressed() }
        sketchHotkey.onPress = { [weak self] in self?.sketchHotkeyPressed() }
        sketchUndoHotkey.onPress = { [weak self] in self?.sketch?.undo() }
        self.recorder.didReachMaximumDuration = { [weak self] in self?.finishRecording() }
        correctionWatcher.onCorrections = { [weak self] pairs in
            guard let self, self.settings.voiceDictationLearnsCorrections else { return }
            self.corrections.record(pairs, app: self.correctionApp)
            self.applyLearnedIfAutomatic()
        }

        for child in [self.modelStore.objectWillChange, self.history.objectWillChange,
                      self.recorder.objectWillChange, self.corrections.objectWillChange] as [ObservableObjectPublisher] {
            child
                .sink { [weak self] _ in
                    Task { @MainActor in self?.objectWillChange.send() }
                }
                .store(in: &cancellables)
        }

        // Timers do not run through sleep, so a transcript could outlive its
        // 24 hours on a Mac that slept past the purge.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.history.purgeExpired() }
            }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    /// Called when the module is enabled. Idempotent.
    func activate() {
        guard !isActive else { return }
        isActive = true
        Self.current = self
        history.purgeExpired()
        if !settings.voiceDictationHistoryEnabled { history.clear() }
        syncHotkey()
        if vad == nil, vadLoad == nil {
            vadLoad = Task { [weak self] in
                let loaded = await VoiceDictationVAD.load()
                self?.vad = loaded
            }
        }

        settingsObserver = settings.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    // NanoSettings publishes before the new value lands.
                    await Task.yield()
                    self?.settingsDidChange()
                }
            }
        selectedEngineWasReady = modelStore.isReady(settings.voiceDictationEngine)
        storeObserver = modelStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    await Task.yield()
                    self?.modelStoreDidChange()
                }
            }
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        if Self.current === self { Self.current = nil }
        correctionWatcher.finish()
        settingsObserver = nil
        storeObserver = nil
        hotkeyMonitor.unregister()
        hotkeyProblem = nil
        sketchHotkey.unregister()
        sketchHotkeyProblem = nil
        cancel()
        // Turning the module off is not a dictation the user abandoned;
        // nothing should linger on the island.
        holdTask?.cancel()
        if phase != .idle { phase = .idle }
        unloadEngines()
        // The 24 hour limit holds while Quill is off: purge now and leave the
        // store's timer scheduled for what remains.
        history.purgeExpired()
    }

    private func settingsDidChange() {
        guard isActive else { return }
        syncHotkey()
        downloadBoosterIfNeeded()
        if !settings.voiceDictationHistoryEnabled, !history.entries.isEmpty {
            history.clear()
        }
        if let enginesFor, enginesFor != settings.voiceDictationEngine, !phase.isBusy {
            unloadEngines()
        }
    }

    /// The moment the selected engine's last file lands, load it once. Core ML
    /// compiles Parakeet for the Neural Engine on first load (tens of seconds,
    /// cached by the OS afterwards); better spent while the user is still in
    /// Settings than on their first hotkey press.
    private func modelStoreDidChange() {
        guard isActive else { return }
        if let pending = pendingEngine, modelStore.isReady(pending), !phase.isBusy {
            pendingEngine = nil
            // Only if the user is still on the starter engine.
            if settings.voiceDictationEngine == .whisperBase {
                settings.voiceDictationEngine = pending
            }
        }
        let isReady = modelStore.isReady(settings.voiceDictationEngine)
        defer { selectedEngineWasReady = isReady }
        if isReady, !selectedEngineWasReady, !phase.isBusy {
            warmEngineIfNeeded()
        }
    }

    private func syncHotkey() {
        let hotkey = settings.voiceDictationHotkey
        if hotkey != hotkeyMonitor.registeredHotkey || hotkeyProblem != nil {
            hotkeyMonitor.register(hotkey)
            hotkeyProblem = hotkeyMonitor.registrationError
        }
        if settings.voiceDictationSketchEnabled {
            let sketchKey = settings.voiceDictationSketchHotkey
            if sketchKey == hotkey {
                sketchHotkey.unregister()
                sketchHotkeyProblem = "Sketch needs a different shortcut from dictation."
            } else if sketchKey != sketchHotkey.registeredHotkey || sketchHotkeyProblem != nil {
                sketchHotkey.register(sketchKey)
                sketchHotkeyProblem = sketchHotkey.registrationError
            }
        } else {
            sketchHotkey.unregister()
            sketchHotkeyProblem = nil
        }
    }

    /// While Settings is recording a new shortcut, the live one must not fire
    /// — and Carbon would otherwise swallow the chord before the recorder
    /// sees it.
    func suspendHotkey() {
        hotkeyMonitor.unregister()
        sketchHotkey.unregister()
    }

    func resumeHotkey() {
        guard isActive else { return }
        syncHotkey()
    }

    // MARK: Readiness

    var readiness: VoiceDictationReadiness {
        guard settings.isEnabled(.voiceDictation) else { return .disabled }
        let missing = modelStore.missingModels(for: settings.voiceDictationEngine)
        if !missing.isEmpty { return .missingModels(missing) }
        switch microphoneAuthorization {
        case .authorized: return .ready
        case .denied, .restricted: return .microphoneDenied
        case .notDetermined: return .microphoneUndetermined
        }
    }

    func refreshMicrophoneAuthorization() {
        microphoneAuthorization = VoiceDictationMicrophoneAuthorization.current
    }

    func requestMicrophoneAccess() {
        Task { @MainActor in
            _ = await VoiceDictationAudioRecorder.requestAccess()
            refreshMicrophoneAuthorization()
        }
    }

    func downloadModels(for engine: VoiceDictationEngine) {
        modelManagementError = nil
        modelStore.download(engine)
    }

    /// The booster is what lets Parakeet hear dictionary terms while it
    /// listens. It comes down by itself, once, when the first term is added.
    private func downloadBoosterIfNeeded() {
        let booster = VoiceDictationModelID.parakeetVocabularyBooster
        let key = "voiceDictation.boosterAutoDownloaded"
        guard settings.voiceDictationEngine == .parakeetS1,
              !settings.defaults.bool(forKey: key),
              settings.voiceDictationVocabulary.contains(where: { $0.kind == .vocabulary && $0.isEnabled }),
              !modelStore.state(of: booster).isDownloaded,
              !modelStore.state(of: booster).isDownloading
        else { return }
        settings.defaults.set(true, forKey: key)
        modelStore.download(booster)
    }

    /// The engine Quill moves to once its download lands, after starting on
    /// the small one. Kept in defaults so a relaunch mid-download keeps it.
    private var pendingEngine: VoiceDictationEngine? {
        get { settings.defaults.string(forKey: "voiceDictation.pendingEngine").flatMap(VoiceDictationEngine.init(rawValue:)) }
        set { settings.defaults.set(newValue?.rawValue, forKey: "voiceDictation.pendingEngine") }
    }

    /// First setup: Parakeet + S1-mini is 968 MB and a long first compile, so
    /// the 148 MB Whisper Base comes down alongside it and Quill uses that
    /// until Parakeet is ready, then switches on its own.
    func downloadForFirstUse(_ engine: VoiceDictationEngine) {
        modelManagementError = nil
        let starter = VoiceDictationEngine.whisperBase
        guard engine != starter, !modelStore.isReady(engine), !VoiceDictationEngine.offered.contains(where: modelStore.isReady)
        else {
            settings.voiceDictationEngine = engine
            modelStore.download(engine)
            return
        }
        pendingEngine = engine
        settings.voiceDictationEngine = starter
        modelStore.download(starter)
        modelStore.download(engine)
    }

    func removeModels(for engine: VoiceDictationEngine) {
        guard !phase.isBusy else { return }
        modelManagementError = nil
        unloadEngines()
        do {
            try modelStore.remove(engine)
        } catch {
            modelManagementError = "Nano could not remove \(engine.title): \(error.localizedDescription)"
            modelStore.refresh()
        }
    }

    func removeModel(_ id: VoiceDictationModelID) {
        guard !phase.isBusy else { return }
        modelManagementError = nil
        unloadEngines()
        do {
            try modelStore.remove(id)
        } catch {
            let title = VoiceDictationModelManifest.descriptor(for: id).title
            modelManagementError = "Nano could not remove \(title): \(error.localizedDescription)"
            modelStore.refresh()
        }
    }

    // MARK: Hotkey handling

    func hotkeyPressed() {
        handleHotkey(.pressed)
    }

    func hotkeyReleased() {
        handleHotkey(.released)
    }

    /// Two separate presses of Escape within a second cancel, so a stray
    /// Escape meant for another app doesn't throw a dictation away.
    func escapePressed() {
        let now = ContinuousClock.now
        if let lastEscape, lastEscape.duration(to: now) < Self.escapeWindow {
            self.lastEscape = nil
            handleHotkey(.escape)
        } else {
            lastEscape = now
        }
    }

    nonisolated static let escapeWindow: Duration = .seconds(1)

    private func handleHotkey(_ event: VoiceDictationHotkeyEvent) {
        switch settings.voiceDictationActivationMode.action(for: event, phase: phase) {
        case .start: beginRecording()
        case .stop: finishRecording()
        case .cancel: cancel()
        case .ignore: break
        }
    }

    // MARK: Session control

    /// Everything a dictation decided when it started, so a settings change
    /// mid-sentence cannot mix two recipes in one transcript.
    struct Recipe: Sendable {
        var engine: VoiceDictationEngine
        var pipeline: VoiceDictationTextPipeline
        var cleanupLevel: VoiceDictationCleanupLevel
        /// What the cleaner is asked for; nil when it does not run.
        var directive: VoiceDictationCleanupDirective?
        var context: VoiceDictationAppContext
        var request: VoiceDictationRecognitionRequest
        var writesNumbers: Bool
        var recordHistory: Bool
        /// "thumbs up emoji" types the emoji.
        var emojiNames = false
        var spokenEnter = false
        /// The text around the caret at the start, when fitting to it is on.
        var surroundings: VoiceDictationSurroundings?
    }

    /// One transcribed and processed stretch of audio.
    struct SegmentOutput: Sendable {
        var raw = ""
        var text = ""
        var applied: [String] = []
        var guardedChunks = 0
        var cleanupFallbacks = 0
        var cleaned = false
        var language: String?
        var boostedTerms: [String] = []
        var transcription: Double = 0
        var cleanup: Double = 0
        var modelLoad: Double = 0
        var wasColdStart = false
    }

    /// Long dictations are cut at a pause once this much audio is waiting,
    /// and the piece is transcribed and cleaned while the user keeps talking.
    nonisolated static let earlySegmentMinimumSeconds = 12.0
    /// Only the most recent stretch is searched for a pause, so the cut lands
    /// close to "now" and the search stays cheap as the recording grows.
    nonisolated static let earlySegmentSearchSeconds = 6.0

    private var recipe: Recipe?
    private var committedSamples = 0
    private var segmentTasks: [Task<SegmentOutput, Error>] = []
    private var segmentMonitor: Task<Void, Never>?

    func makeRecipe(
        engine: VoiceDictationEngine? = nil,
        appContext: VoiceDictationAppContext = .general,
        bundleID: String? = nil,
        level requestedLevel: VoiceDictationCleanupLevel? = nil
    ) -> Recipe {
        let engine = engine ?? settings.voiceDictationEngine
        // A shell command is typed as spoken: no cleanup, no layout cues.
        let layoutCues = settings.voiceDictationLayoutCues && appContext != .terminal
        // A shell command keeps every word it was given.
        let learns = appContext != .terminal
        let pipeline = VoiceDictationTextPipeline(
            entries: VoiceDictationVocabularyEntry.forApp(settings.voiceDictationVocabulary, bundleID: bundleID),
            layoutCues: layoutCues,
            leaveOut: learns ? settings.voiceDictationLeaveOutPhrases : [],
            changeOfMindCues: learns ? settings.voiceDictationChangeOfMindCues : []
        )
        let chosen = requestedLevel ?? VoiceDictationAppStyle.level(
            default: settings.voiceDictationCleanupLevel,
            styles: settings.voiceDictationAppStyles,
            bundleID: bundleID
        )
        let level = appContext == .terminal ? .verbatim : chosen
        var recipe = Recipe(
            engine: engine,
            pipeline: pipeline,
            cleanupLevel: level,
            directive: level.directive(lists: settings.voiceDictationStructuresLists, context: appContext),
            context: appContext,
            request: VoiceDictationRecognitionRequest(
                vocabulary: pipeline.vocabularyTerms,
                language: engine.recognitionLanguage(for: settings.voiceDictationLanguage)
            ),
            writesNumbers: settings.voiceDictationWritesNumbers,
            recordHistory: settings.voiceDictationHistoryEnabled
        )
        recipe.emojiNames = layoutCues
        recipe.spokenEnter = settings.voiceDictationSpokenEnter
        return recipe
    }

    func beginRecording() {
        guard !phase.isBusy else { return }
        holdTask?.cancel()
        lastError = nil
        refreshMicrophoneAuthorization()

        switch readiness {
        case .ready:
            break
        case .disabled:
            fail(.featureDisabled)
            return
        case .missingModels(let models):
            fail(.modelMissing(settings.voiceDictationEngine, models))
            return
        case .microphoneDenied:
            fail(.microphoneDenied)
            return
        case .microphoneUndetermined:
            // First use: the system prompt appears; the user presses again after.
            requestMicrophoneAccess()
            return
        }

        // The next paste may land in the field being watched; settle it first.
        correctionWatcher.finish()
        lastPasteOutcome = nil
        pasteTarget.captureFocusedTarget()
        let context = settings.voiceDictationAdaptsToApp
            ? VoiceDictationAppContext.classify(
                bundleID: pasteTarget.capturedApplication?.bundleID,
                focusedDescription: pasteTarget.capturedFocusDescription,
                windowTitle: pasteTarget.capturedWindowTitle,
                agentNames: pasteTarget.capturedApplication.map { agentSessionNames()[$0.bundleID.lowercased()] ?? [] } ?? []
            )
            : .general
        do {
            try recorder.start()
        } catch let error as VoiceDictationError {
            fail(error)
            return
        } catch {
            fail(.audioCaptureFailed(error.localizedDescription))
            return
        }
        recordingStartedAt = .now
        var recipe = makeRecipe(appContext: context, bundleID: pasteTarget.capturedApplication?.bundleID)
        if settings.voiceDictationFitsToCursor, !context.isTerminal {
            recipe.surroundings = pasteTarget.capturedSurroundings
        }
        self.recipe = recipe
        committedSamples = 0
        segmentTasks = []
        phase = .recording
        idleUnloadTask?.cancel()
        // Overlap the model load with the user talking.
        warmEngineIfNeeded()
        startVADFeeder()
        // A Sketch is cut where its marks were drawn, not at pauses.
        if sketch == nil {
            startSegmentMonitor(generation: sessionGeneration)
        }
        if settings.voiceDictationLivePreview {
            startLivePreview(generation: sessionGeneration)
        }
    }

    func finishRecording() {
        guard phase == .recording, let recipe else { return }
        let stoppedAt = ContinuousClock.now
        let recordedSeconds = recorder.recordedDuration
        let samples = recorder.stop()
        recordingStartedAt = nil
        segmentMonitor?.cancel()
        segmentMonitor = nil
        livePreviewTask?.cancel()
        livePreviewTask = nil

        if let session = sketch {
            sketch = nil
            sketchUndoHotkey.unregister()
            phase = .transcribing
            let generation = sessionGeneration
            processingTask = Task { [weak self] in
                await self?.processSketch(
                    session: session,
                    samples: samples,
                    recipe: recipe,
                    stoppedAt: stoppedAt,
                    recordedSeconds: recordedSeconds,
                    generation: generation
                )
            }
            return
        }

        guard recordedSeconds >= 0.25, Self.containsSpeech(samples) else {
            discardSegments()
            fail(.noSpeech)
            return
        }

        phase = .transcribing
        let generation = sessionGeneration
        let early = segmentTasks
        let tail = Array(samples[min(committedSamples, samples.count)...])
        segmentTasks = []
        processingTask = Task { [weak self] in
            await self?.process(
                samples: samples,
                earlySegments: early,
                tail: tail,
                recipe: recipe,
                stoppedAt: stoppedAt,
                recordedSeconds: recordedSeconds,
                generation: generation,
                usesVAD: true
            )
        }
    }

    /// Runs already-captured audio through the exact stop-to-clipboard path,
    /// as if the hotkey had just been released. Used by the benchmark harness
    /// so measured numbers are the numbers users get. Returns the result or
    /// the failure.
    func processCapturedAudio(
        _ samples: [Float],
        engine: VoiceDictationEngine,
        appContext: VoiceDictationAppContext = .general
    ) async -> Result<VoiceDictationResult, VoiceDictationError> {
        guard !phase.isBusy else { return .failure(.busy) }
        let stoppedAt = ContinuousClock.now
        idleUnloadTask?.cancel()
        phase = .transcribing
        lastError = nil
        lastResult = nil
        await process(
            samples: samples,
            earlySegments: [],
            tail: samples,
            recipe: makeRecipe(engine: engine, appContext: appContext),
            stoppedAt: stoppedAt,
            recordedSeconds: Double(samples.count) / VoiceDictationAudioRecorder.sampleRate,
            generation: sessionGeneration
        )
        if let lastError { return .failure(lastError) }
        guard let lastResult else { return .failure(.recognitionFailed("No result was produced.")) }
        return .success(lastResult)
    }

    /// Drops the current recording or in-flight transcription. Nothing is
    /// copied and nothing is recorded. Reached from the island's Cancel
    /// button and from Escape while a dictation is busy.
    func cancel() {
        guard phase.isBusy else { return }
        sessionGeneration &+= 1
        processingTask?.cancel()
        processingTask = nil
        segmentMonitor?.cancel()
        segmentMonitor = nil
        livePreviewTask?.cancel()
        livePreviewTask = nil
        vadFeeder?.cancel()
        vadFeeder = nil
        endSketch()
        discardSegments()
        if phase == .recording {
            recorder.cancel()
        }
        recordingStartedAt = nil
        pasteTarget.clearCapturedTarget()
        phase = .cancelled
        hold(for: cancelHoldInterval, leaving: .cancelled)
        scheduleIdleUnload()
    }

    private func discardSegments() {
        segmentTasks.forEach { $0.cancel() }
        segmentTasks = []
        committedSamples = 0
    }

    /// While recording, cuts finished stretches of a long dictation at a
    /// pause and processes them in order, so on release only the last few
    /// seconds are left to do.
    private func startSegmentMonitor(generation: UInt64) {
        segmentMonitor?.cancel()
        segmentMonitor = Task { [weak self] in
            let rate = VoiceDictationAudioRecorder.sampleRate
            let minimum = Int(rate * Self.earlySegmentMinimumSeconds)
            let window = Int(rate * Self.earlySegmentSearchSeconds)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.phase == .recording,
                      self.sessionGeneration == generation, let recipe = self.recipe
                else { return }
                let pending = self.recorder.recordedSampleCount - self.committedSamples
                guard pending >= minimum else { continue }
                let audio = self.recorder.samples(from: self.committedSamples)
                let searchStart = max(minimum - window, audio.count - window)
                guard let cut = VoiceDictationAudioSegmenter.pause(in: audio, range: searchStart ..< audio.count)
                else { continue }
                let piece = Array(audio[..<cut])
                let pieceStart = self.committedSamples
                self.committedSamples += cut
                guard Self.containsSpeech(piece) else { continue }
                if let vad = self.vad, !(await vad.hasSpeech(in: pieceStart ..< pieceStart + cut)) { continue }
                self.enqueueSegment(piece, recipe: recipe, generation: generation)
            }
        }
    }

    private func enqueueSegment(_ samples: [Float], recipe: Recipe, generation: UInt64) {
        let previous = segmentTasks.last
        segmentTasks.append(Task { [weak self] in
            // One at a time and in order: the engines are single actors and
            // the transcript is stitched by position.
            _ = try? await previous?.value
            guard let self else { throw CancellationError() }
            return try await self.processSegment(samples, recipe: recipe, generation: generation)
        })
    }

    /// Loads the selected engine without recording, so the first dictation is
    /// warm. Safe to call repeatedly; a no-op when models are missing.
    func warmEngineIfNeeded() {
        guard loadTask == nil, processingTask == nil else { return }
        let engine = settings.voiceDictationEngine
        guard modelStore.missingModels(for: engine).isEmpty, loadedEngine != engine else { return }
        let (recognizer, cleaner) = engines(for: engine)
        isLoadingEngine = true
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            var failure: VoiceDictationError?
            do {
                try await recognizer.load()
                try await cleaner?.load()
            } catch {
                failure = (error as? VoiceDictationError)
                    ?? .modelLoadFailed(error.localizedDescription)
            }
            // `unloadEngines()` or a newer warm-up owns the state now.
            guard let self, self.loadGeneration == generation else { return }
            if let failure {
                // Reported by the dictation that needs it; a warm-up should
                // not flash a failure while the user is still talking.
                self.lastError = failure
            } else {
                self.loadedEngine = engine
            }
            self.isLoadingEngine = false
            self.loadTask = nil
            self.scheduleIdleUnload()
        }
    }

    func unloadEngines() {
        idleUnloadTask?.cancel()
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        let recognizer = self.recognizer
        let cleaner = self.cleaner
        self.recognizer = nil
        self.cleaner = nil
        enginesFor = nil
        loadedEngine = nil
        isLoadingEngine = false
        Task.detached(priority: .utility) {
            await recognizer?.unload()
            await cleaner?.unload()
        }
    }

    func copyLastResult() {
        guard let lastResult else { return }
        _ = Self.copyToClipboard(lastResult.finalText)
    }

    /// Runs one entry through the same matcher the live path uses so the
    /// settings "Test" button reports exactly what would happen.
    nonisolated static func preview(entry: VoiceDictationVocabularyEntry, sample: String) -> String {
        VoiceDictationTextPipeline(entries: [entry]).apply(sample).text
    }

    // MARK: Remote control (URL scheme, Shortcuts)

    enum RemoteCommand: String, CaseIterable, Sendable {
        case start, stop, toggle, cancel, sketch
        case pasteLast = "paste-last"
    }

    /// The controller of the running app, while Quill is on. App Intents and
    /// `nano://quill/...` links reach dictation through it.
    private(set) static weak var current: VoiceDictationController?

    /// Whether links and Shortcuts may start the microphone. Off by default:
    /// any web page or local process can open a `nano://` link.
    var remoteLinksAllowed: Bool {
        get { settings.defaults.bool(forKey: VoiceDictationRemoteControl.linksAllowedKey) }
        set {
            objectWillChange.send()
            settings.defaults.set(newValue, forKey: VoiceDictationRemoteControl.linksAllowedKey)
        }
    }

    /// Stopping and cancelling are always allowed. Anything that would turn
    /// the microphone on needs `remoteLinksAllowed`.
    func allowsRemote(_ command: RemoteCommand) -> Bool {
        switch command {
        case .stop, .cancel: true
        case .start, .pasteLast: remoteLinksAllowed
        case .toggle: phase == .recording || remoteLinksAllowed
        case .sketch: sketchMarks != nil || remoteLinksAllowed
        }
    }

    /// Start and stop behave the same whatever the activation mode: there is
    /// no key to hold when a launcher or a Shortcut is driving. Returns false
    /// when the command did nothing, including a start that did not begin
    /// recording (links not allowed, engine missing, microphone denied).
    @discardableResult
    func perform(_ command: RemoteCommand) -> Bool {
        guard allowsRemote(command) else { return false }
        switch command {
        case .start:
            guard !phase.isBusy else { return false }
            beginRecording()
            return phase == .recording
        case .stop:
            guard phase == .recording else { return false }
            finishRecording()
        case .toggle:
            if phase == .recording {
                finishRecording()
            } else if !phase.isBusy {
                beginRecording()
                return phase == .recording
            } else {
                return false
            }
        case .sketch:
            let wasSketching = sketchMarks != nil
            sketchHotkeyPressed()
            return wasSketching || sketchMarks != nil
        case .pasteLast:
            guard lastResult != nil, !phase.isBusy else { return false }
            pasteLastResult()
        case .cancel:
            guard phase.isBusy else { return false }
            cancel()
        }
        return true
    }

    // MARK: Correction learning

    var correctionSuggestions: [VoiceDictationCorrection] {
        corrections.suggestions(
            excluding: settings.voiceDictationVocabulary,
            leaveOut: settings.voiceDictationLeaveOutPhrases,
            cues: settings.voiceDictationChangeOfMindCues
        )
    }

    /// Most learned corrections are names, which are right everywhere, so
    /// that is the default; `onlyInItsApp` keeps it to the app it came from.
    func acceptCorrection(_ correction: VoiceDictationCorrection, onlyInItsApp: Bool = false) {
        switch correction.kind {
        case .word:
            settings.voiceDictationVocabulary.append(VoiceDictationVocabularyEntry(
                phrase: correction.spoken,
                replacement: correction.written,
                kind: .vocabulary,
                bundleID: onlyInItsApp ? correction.bundleID : nil,
                appName: onlyInItsApp ? correction.appName : nil
            ))
        case .leaveOut:
            settings.voiceDictationLeaveOutPhrases.append(correction.spoken)
        case .changeOfMind:
            settings.voiceDictationChangeOfMindCues.append(correction.spoken)
        }
        corrections.remove(correction)
    }

    /// With automatic learning on, every new suggestion is taken as it appears.
    func applyLearnedIfAutomatic() {
        guard settings.voiceDictationAppliesLearnedAutomatically else { return }
        for correction in correctionSuggestions { acceptCorrection(correction) }
    }

    func dismissCorrection(_ correction: VoiceDictationCorrection) {
        corrections.dismiss(correction)
    }

    // MARK: Processing

    private func engines(
        for engine: VoiceDictationEngine
    ) -> (VoiceDictationRecognizer, VoiceDictationCleaner?) {
        if let recognizer, enginesFor == engine {
            return (recognizer, cleaner)
        }
        unloadEngines()
        let recognizer = VoiceDictationEngineFactory.recognizer(for: engine, store: modelStore)
        let cleaner = VoiceDictationEngineFactory.cleaner(for: engine, store: modelStore)
        self.recognizer = recognizer
        self.cleaner = cleaner
        enginesFor = engine
        return (recognizer, cleaner)
    }

    /// Recognition plus every text stage for one stretch of audio.
    ///
    /// Snippets are cut out before any rewriting and spliced back verbatim.
    /// Speech is then cleaned by S1-mini (English only, never in a terminal)
    /// or, without a cleaner, has its numbers written as figures; a terminal
    /// also gets command formatting. Vocabulary runs last so nothing re-cases
    /// a term.
    private func processSegment(
        _ samples: [Float],
        recipe: Recipe,
        generation: UInt64
    ) async throws -> SegmentOutput {
        let isCurrent = { [weak self] in self?.sessionGeneration == generation }
        let (recognizer, loadedCleaner) = engines(for: recipe.engine)
        let clock = ContinuousClock()
        var output = SegmentOutput()

        var wasLoaded = await recognizer.isLoaded
        if let loadedCleaner, wasLoaded { wasLoaded = await loadedCleaner.isLoaded }
        if !wasLoaded {
            let loadStart = clock.now
            try await recognizer.load()
            try await loadedCleaner?.load()
            output.modelLoad = Self.seconds(loadStart.duration(to: clock.now))
            output.wasColdStart = true
            if isCurrent() { loadedEngine = recipe.engine }
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }

        let transcribeStart = clock.now
        let recognition = try await recognizer.transcribe(samples, request: recipe.request)
        output.transcription = Self.seconds(transcribeStart.duration(to: clock.now))
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        var processed = try await processText(
            recognition.text, language: recognition.language, recipe: recipe, isCurrent: isCurrent
        )
        processed.transcription = output.transcription
        processed.modelLoad = output.modelLoad
        processed.wasColdStart = output.wasColdStart
        processed.boostedTerms = recognition.boostedTerms
        return processed
    }

    /// Every text stage after recognition, for one stretch of speech.
    private func processText(
        _ recognized: String,
        language: String?,
        recipe: Recipe,
        isCurrent: () -> Bool
    ) async throws -> SegmentOutput {
        let (_, loadedCleaner) = engines(for: recipe.engine)
        if let loadedCleaner, recipe.directive != nil, !(await loadedCleaner.isLoaded) {
            try await loadedCleaner.load()
        }
        let clock = ContinuousClock()
        var output = SegmentOutput()
        output.raw = recognized
        guard !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return output }
        let recognition = (text: recognized, language: language)

        let isEnglish = VoiceDictationLanguageGuess.isEnglish(recognition.text, reported: recognition.language)
        output.language = recognition.language ?? VoiceDictationLanguageGuess.language(of: recognition.text)
        let cleaner = recipe.directive != nil && isEnglish ? loadedCleaner : nil
        if cleaner != nil, isCurrent(), phase == .transcribing { phase = .cleaning }

        var pieces: [String] = []
        let cleanupStart = clock.now
        for segment in recipe.pipeline.protect(recognition.text) {
            switch segment {
            case .speech(let speech):
                var text = speech
                if let cleaner, let directive = recipe.directive {
                    var cleanedChunks: [String] = []
                    for chunk in VoiceDictationTranscriptChunker.chunk(speech) {
                        let cleaned: String
                        do {
                            cleaned = try await cleaner.clean(chunk, directive: directive)
                        } catch VoiceDictationError.cleanupFailed {
                            // One bad chunk must not lose the whole
                            // dictation; the recognizer's text stands.
                            cleaned = chunk
                            output.cleanupFallbacks += 1
                        }
                        let verdict = VoiceDictationCleanupGuard.verify(raw: chunk, cleaned: cleaned)
                        if verdict.restoredRaw { output.guardedChunks += 1 }
                        cleanedChunks.append(verdict.text)
                        try Task.checkCancellation()
                        guard isCurrent() else { throw CancellationError() }
                    }
                    text = VoiceDictationTextPipeline.join(cleanedChunks)
                    output.cleaned = true
                }
                if recipe.context == .terminal {
                    // Symbols first, so "dash n fifty" is a flag and a count.
                    text = VoiceDictationCommandFormatter.format(text)
                }
                if cleaner == nil, recipe.writesNumbers, isEnglish {
                    text = VoiceDictationNumberFormatter.format(text, allDigits: recipe.context == .terminal)
                }
                if recipe.emojiNames {
                    text = VoiceDictationSpokenCommands.emojiNames(text)
                }
                let vocabulary = recipe.pipeline.applyVocabulary(text)
                output.applied.append(contentsOf: vocabulary.appliedPhrases)
                pieces.append(vocabulary.text)
            case .expansion(let text, let phrase):
                pieces.append(text)
                output.applied.append(phrase)
            case .lineBreak(let lineBreak):
                pieces.append(lineBreak)
            }
        }
        if output.cleaned { output.cleanup = Self.seconds(cleanupStart.duration(to: clock.now)) }
        output.text = VoiceDictationTextPipeline.join(pieces, keepingEdgeBreaks: true)
        return output
    }

    private func process(
        samples: [Float],
        earlySegments: [Task<SegmentOutput, Error>],
        tail: [Float],
        recipe: Recipe,
        stoppedAt: ContinuousClock.Instant,
        recordedSeconds: Double,
        generation: UInt64,
        usesVAD: Bool = false
    ) async {
        // Engine calls are not cooperatively cancellable, so a cancelled
        // session can resurface here long after the user moved on. Anything
        // it learns then belongs to nobody.
        let isCurrent = { [weak self] in self?.sessionGeneration == generation }
        let (recognizer, loadedCleaner) = engines(for: recipe.engine)
        let cleanerRuns = recipe.directive != nil && loadedCleaner != nil
        var metrics = VoiceDictationMetrics(audioDuration: recordedSeconds)
        metrics.accelerator = ([recognizer.acceleratorDescription]
            + (cleanerRuns ? [loadedCleaner!.acceleratorDescription] : []))
            .joined(separator: " + ")
        let clock = ContinuousClock()

        do {
            var tail = tail
            if usesVAD, let vad = await finishVAD(samples: samples) {
                if earlySegments.isEmpty, !(await vad.hasSpeech(in: 0 ..< samples.count)) {
                    throw VoiceDictationError.noSpeech
                }
                let tailStart = samples.count - tail.count
                if let speech = await vad.speech(in: tailStart ..< samples.count) {
                    tail = Array(samples[speech])
                } else if !earlySegments.isEmpty {
                    tail = []
                }
            }
            var outputs: [SegmentOutput] = []
            for task in earlySegments {
                outputs.append(try await task.value)
            }
            if Self.containsSpeech(tail) || outputs.isEmpty {
                outputs.append(try await processSegment(tail, recipe: recipe, generation: generation))
            }
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }

            let raw = VoiceDictationTextPipeline.join(outputs.map(\.raw))
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !Self.isLikelyHallucination(raw, samples: samples)
            else {
                throw VoiceDictationError.noSpeech
            }

            let postStart = clock.now
            let finished = Self.finish(VoiceDictationTextPipeline.join(outputs.map(\.text)), recipe: recipe)
            let finalText = finished.text
            metrics.postProcessing = Self.seconds(postStart.duration(to: clock.now))
            metrics.transcription = outputs.reduce(0) { $0 + $1.transcription }
            metrics.cleanup = outputs.reduce(0) { $0 + $1.cleanup }
            metrics.modelLoad = outputs.reduce(0) { $0 + $1.modelLoad }
            metrics.wasColdStart = outputs.contains(where: \.wasColdStart)

            guard !finalText.isEmpty || finished.pressEnter else { throw VoiceDictationError.noSpeech }
            let targetApp = pasteTarget.capturedApplication
            lastTargetBundleID = targetApp?.bundleID
            var result = VoiceDictationResult(
                rawTranscript: raw,
                finalText: finalText,
                engine: recipe.engine,
                cleanupApplied: outputs.contains(where: \.cleaned),
                appliedReplacements: outputs.flatMap(\.applied),
                metrics: metrics,
                completedAt: Date(),
                cleanupLevel: recipe.cleanupLevel,
                guardedChunks: outputs.reduce(0) { $0 + $1.guardedChunks },
                cleanupFallbacks: outputs.reduce(0) { $0 + $1.cleanupFallbacks },
                language: outputs.compactMap(\.language).first,
                appContext: recipe.context,
                boostedTerms: outputs.flatMap(\.boostedTerms),
                segmentsProcessedEarly: earlySegments.count
            )
            // The clipboard holds the text before any paste is tried, so a
            // failed paste never loses it.
            guard finalText.isEmpty || Self.copyToClipboard(finalText) else {
                lastResult = result
                throw VoiceDictationError.clipboardFailed
            }
            let chunks = recipe.context.isTerminal
                ? VoiceDictationSpokenCommands.pasteChunks(finalText)
                : [finalText]
            lastPasteOutcome = await pasteTarget.deliver(finalText, chunks: chunks, pressEnter: finished.pressEnter)
            metrics.stopToClipboard = Self.seconds(stoppedAt.duration(to: clock.now))
            result.metrics = metrics
            lastResult = result

            if lastPasteOutcome == .requested, settings.voiceDictationLearnsCorrections,
               let element = pasteTarget.lastDeliveredElement {
                correctionApp = targetApp
                correctionWatcher.begin(element: element, inserted: finalText)
            }
            recordCompletedTranscript(
                finalText, engine: recipe.engine, historyWasEnabled: recipe.recordHistory,
                app: targetApp, audioSeconds: recordedSeconds, latency: metrics.stopToClipboard,
                raw: raw, level: recipe.cleanupLevel, context: recipe.context
            )
            recordStats(raw: raw, final: finalText, applied: result.appliedReplacements, metrics: metrics, app: targetApp)
            // A warm-up that failed while the user was talking is moot now.
            lastError = nil
            phase = .completed
            hold(for: completionHoldInterval, leaving: .completed)
        } catch is CancellationError {
            // `cancel()` already moved the controller to idle and may have
            // started a newer session; a stale task must leave it alone.
            if isCurrent(), phase.isBusy { phase = .idle }
        } catch let error as VoiceDictationError {
            if isCurrent() { fail(error) }
        } catch {
            if isCurrent() { fail(.recognitionFailed(error.localizedDescription)) }
        }
        guard isCurrent() else { return }
        processingTask = nil
        self.recipe = nil
        committedSamples = 0
        scheduleIdleUnload()
    }

    /// The stages that run on the whole joined text: a trailing "press
    /// enter", chat style, then fitting to the text around the caret.
    nonisolated static func finish(_ joined: String, recipe: Recipe) -> (text: String, pressEnter: Bool) {
        var text = joined
        var pressEnter = false
        if recipe.spokenEnter {
            (text, pressEnter) = VoiceDictationSpokenCommands.stripPressEnter(text)
        }
        if recipe.context == .chat {
            text = VoiceDictationChatStyle.apply(text)
        }
        if let surroundings = recipe.surroundings, !recipe.context.isTerminal, !text.isEmpty {
            let protected = recipe.pipeline.entries.filter(\.isEnabled).map(\.replacement)
            text = VoiceDictationCursorFit.fit(text, surroundings: surroundings, protected: protected)
        }
        return (text, pressEnter)
    }

    // MARK: Sketch

    func sketchHotkeyPressed() {
        if sketch != nil {
            if phase == .recording { finishRecording() }
            return
        }
        guard settings.voiceDictationSketchEnabled, !phase.isBusy else { return }
        beginSketch()
    }

    /// Records a dictation while the user marks up the screen. Finishes on
    /// the same shortcut; Escape twice cancels.
    func beginSketch() {
        guard sketch == nil, !phase.isBusy else { return }
        guard VoiceDictationSketchSession.hasScreenRecordingAccess else {
            VoiceDictationSketchSession.requestScreenRecordingAccess()
            holdTask?.cancel()
            fail(.screenRecordingDenied)
            return
        }
        guard let screen = VoiceDictationSketchSession.screenUnderPointer() else { return }
        let session = VoiceDictationSketchSession(
            screen: screen,
            drawKey: settings.voiceDictationSketchDrawKey,
            finishShortcut: settings.voiceDictationSketchHotkey.displayString
        ) { [weak self] in
            self?.recorder.recordedSampleCount ?? 0
        }
        session.onFinish = { [weak self] in
            guard let self, self.sketch === session, self.phase == .recording else { return }
            self.finishRecording()
        }
        session.onCancel = { [weak self] in
            guard let self, self.sketch === session else { return }
            self.cancel()
        }
        session.onMarksChanged = { [weak self] count in
            guard let self, self.sketch === session else { return }
            self.sketchMarks = count
        }
        sketch = session
        sketchMarks = 0
        beginRecording()
        guard phase == .recording, sketch === session else {
            endSketch()
            return
        }
        session.start()
        sketchUndoHotkey.register(VoiceDictationHotkey(
            keyCode: 6, // kVK_ANSI_Z
            modifierFlags: NSEvent.ModifierFlags.command.rawValue
        ))
    }

    private func endSketch() {
        sketch?.cancel()
        sketch = nil
        sketchMarks = nil
        sketchUndoHotkey.unregister()
    }

    /// Transcribes the pieces between marks, stitches them with the mark
    /// numbers, draws the marks onto their screenshots, and pastes both into
    /// the field the Sketch was started from.
    private func processSketch(
        session: VoiceDictationSketchSession,
        samples: [Float],
        recipe: Recipe,
        stoppedAt: ContinuousClock.Instant,
        recordedSeconds: Double,
        generation: UInt64
    ) async {
        let isCurrent = { [weak self] in self?.sessionGeneration == generation }
        let clock = ContinuousClock()
        var metrics = VoiceDictationMetrics(audioDuration: recordedSeconds)
        do {
            let capture = await session.finish()
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            // Marks, clicks and settled screen changes, cut down to the
            // screenshots worth sending.
            let moments = await Task.detached(priority: .userInitiated) {
                VoiceDictationSketchPicker.pick(capture.moments, seconds: recordedSeconds)
            }.value
            let strokes = moments.flatMap(\.strokes)
            let anchors = VoiceDictationSketchPicker.anchors(for: moments)
            let cuts = VoiceDictationSketchText.cuts(
                marks: anchors.enumerated().map { (number: $0.offset, sample: $0.element.sample) },
                samples: samples
            )
            let minimum = Int(VoiceDictationAudioRecorder.sampleRate * 0.25)
            let vad = await finishVAD(samples: samples)
            var outputs: [SegmentOutput] = []
            var pieceStart = 0
            for piece in VoiceDictationSketchText.pieces(of: samples, at: cuts) {
                let range = pieceStart ..< pieceStart + piece.count
                pieceStart += piece.count
                let voiced: Bool
                if let vad { voiced = await vad.hasSpeech(in: range) } else { voiced = true }
                if piece.count >= minimum, voiced, Self.containsSpeech(piece) {
                    outputs.append(try await processSegment(piece, recipe: recipe, generation: generation))
                } else {
                    outputs.append(SegmentOutput())
                }
            }
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }

            let raw = VoiceDictationTextPipeline.join(outputs.map(\.raw))
            let spoke = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !Self.isLikelyHallucination(raw, samples: samples)
            guard spoke || !strokes.isEmpty else { throw VoiceDictationError.noSpeech }
            let rate = VoiceDictationAudioRecorder.sampleRate
            // A single screenshot of an untouched screen needs no list.
            let listed = moments.count > 1 || moments.contains { $0.kind != .start }
            let body = VoiceDictationSketchText.compose(
                pieces: spoke ? outputs.map(\.text) : outputs.map { _ in "" },
                cuts: cuts,
                anchors: anchors,
                frames: listed ? moments.map { (time: Double($0.sample) / rate, tag: $0.tag, place: $0.place.description) } : []
            )

            // Each screenshot gets its ink and a "#N 0:15" badge; they go out
            // as one contact sheet, with the full-size frames saved beside it.
            let screenFrame = session.screenFrame
            // Every screenshot full size, each marked one followed by a crop
            // around its ink; the sheet of all of them is saved as well.
            let rendered: (sheet: Data?, images: [(name: String, data: Data)]) = await Task.detached(priority: .userInitiated) {
                var frames: [CGImage] = []
                var images: [(name: String, data: Data)] = []
                for (index, moment) in moments.enumerated() {
                    let badge = listed
                        ? "#\(index + 1)  \(VoiceDictationSketchText.clock(Double(moment.sample) / rate))"
                        : nil
                    guard let frame = VoiceDictationSketchRenderer.render(
                        moment.image, strokes: moment.strokes, screenFrame: screenFrame, click: moment.click, badge: badge
                    ) else { continue }
                    frames.append(frame)
                    if let data = VoiceDictationSketchRenderer.pngData(frame) {
                        images.append(("frame-\(index + 1).png", data))
                    }
                    let ink = moment.strokes.flatMap(\.points)
                    if !ink.isEmpty,
                       let crop = VoiceDictationSketchRenderer.crop(frame, around: ink, screenFrame: screenFrame),
                       let data = VoiceDictationSketchRenderer.pngData(crop) {
                        images.append(("frame-\(index + 1)-zoom.png", data))
                    }
                }
                let sheet = VoiceDictationSketchRenderer.contactSheet(frames).flatMap(VoiceDictationSketchRenderer.pngData)
                return (sheet, images)
            }.value
            let saved = rendered.sheet.flatMap {
                try? VoiceDictationSketchStorage.save(sheet: $0, images: rendered.images, video: capture.video)
            }
            if saved?.video == nil, let video = capture.video { try? FileManager.default.removeItem(at: video) }
            let header = VoiceDictationSketchText.header(
                duration: recordedSeconds, folder: saved?.folder, hasVideo: saved?.video != nil,
                display: (session.screenFrame.size, session.scale)
            )
            let text = listed
                ? header + "\n" + VoiceDictationSketchText.preamble + "\n" + body
                : header + "\n" + body
            guard isCurrent() else { throw CancellationError() }

            // Copied first, with the screenshot folder in the text, so nothing
            // is lost if the paste can't happen.
            guard Self.copyToClipboard(text) else { throw VoiceDictationError.clipboardFailed }
            let copied = text
            let images = rendered.images.map(\.data)
            let urls = saved?.images ?? []
            let targetApp = pasteTarget.capturedApplication
            if pasteTarget.capturedTargetIsEditable {
                lastPasteOutcome = await pasteTarget.pasteSketch(
                    images: images, paths: urls, text: text, terminal: recipe.context.isTerminal
                )
            } else {
                pasteTarget.clearCapturedTarget()
                lastPasteOutcome = .noEditableTarget
            }
            if lastPasteOutcome != .requested { _ = Self.copyToClipboard(copied) }
            metrics.stopToClipboard = Self.seconds(stoppedAt.duration(to: clock.now))
            metrics.transcription = outputs.reduce(0) { $0 + $1.transcription }
            metrics.cleanup = outputs.reduce(0) { $0 + $1.cleanup }
            metrics.modelLoad = outputs.reduce(0) { $0 + $1.modelLoad }
            metrics.wasColdStart = outputs.contains(where: \.wasColdStart)

            lastResult = VoiceDictationResult(
                rawTranscript: raw,
                finalText: text,
                engine: recipe.engine,
                cleanupApplied: outputs.contains(where: \.cleaned),
                appliedReplacements: outputs.flatMap(\.applied),
                metrics: metrics,
                completedAt: Date(),
                cleanupLevel: recipe.cleanupLevel,
                guardedChunks: outputs.reduce(0) { $0 + $1.guardedChunks },
                cleanupFallbacks: outputs.reduce(0) { $0 + $1.cleanupFallbacks },
                language: outputs.compactMap(\.language).first,
                appContext: recipe.context,
                boostedTerms: outputs.flatMap(\.boostedTerms),
                segmentsProcessedEarly: 0
            )
            recordCompletedTranscript(
                text, engine: recipe.engine, historyWasEnabled: recipe.recordHistory,
                app: targetApp, audioSeconds: recordedSeconds, latency: metrics.stopToClipboard,
                raw: raw, level: recipe.cleanupLevel, context: recipe.context
            )
            if spoke {
                recordStats(raw: raw, final: text, applied: lastResult?.appliedReplacements ?? [], metrics: metrics, app: targetApp)
            }
            sketchMarks = nil
            lastError = nil
            if images.isEmpty {
                fail(.screenCaptureFailed)
            } else {
                phase = .completed
                hold(for: completionHoldInterval, leaving: .completed)
            }
        } catch is CancellationError {
            if isCurrent(), phase.isBusy { phase = .idle }
        } catch let error as VoiceDictationError {
            if isCurrent() { fail(error) }
        } catch {
            if isCurrent() { fail(.recognitionFailed(error.localizedDescription)) }
        }
        guard isCurrent() else { return }
        sketchMarks = nil
        processingTask = nil
        self.recipe = nil
        scheduleIdleUnload()
    }

    // MARK: Voice activity

    /// Classifies the recording in 256 ms chunks as it grows.
    private func startVADFeeder() {
        vadFeeder?.cancel()
        guard let vad else { return }
        let recorder = recorder
        vadFeeder = Task {
            await vad.reset()
            while !Task.isCancelled {
                let processed = await vad.processedSamples
                let available = await MainActor.run { recorder.recordedSampleCount }
                if available - processed >= VoiceDictationVAD.chunk {
                    let audio = await MainActor.run { recorder.samples(from: processed) }
                    await vad.feed(audio)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Stops the feeder and classifies what is left. Nil when the model
    /// isn't available, in which case nothing is skipped or trimmed.
    private func finishVAD(samples: [Float]) async -> VoiceDictationVAD? {
        guard let vad, let feeder = vadFeeder else { return nil }
        vadFeeder = nil
        feeder.cancel()
        await feeder.value
        let processed = await vad.processedSamples
        guard processed <= samples.count else { return nil }
        await vad.feed(Array(samples[processed...]), final: true)
        return vad
    }

    // MARK: Live preview

    /// While recording, decodes the newest stretch of audio and shows the
    /// words. Display only: the pasted text comes from the whole recording.
    private func startLivePreview(generation: UInt64) {
        livePreviewTask?.cancel()
        livePreviewTask = Task { [weak self] in
            let rate = VoiceDictationAudioRecorder.sampleRate
            var wait: Duration = .milliseconds(900)
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard let self, !Task.isCancelled, self.phase == .recording,
                      self.sessionGeneration == generation, let recipe = self.recipe,
                      let recognizer = self.recognizer, self.enginesFor == recipe.engine,
                      await recognizer.isLoaded
                else {
                    wait = .milliseconds(300)
                    continue
                }
                let available = self.recorder.recordedSampleCount
                let start = max(self.committedSamples, available - Int(rate * Self.livePreviewSeconds))
                var audio = self.recorder.samples(from: start)
                guard Self.containsSpeech(audio) else {
                    wait = .milliseconds(300)
                    continue
                }
                if audio.count < Int(rate) {
                    audio += [Float](repeating: 0, count: Int(rate) - audio.count)
                }
                let began = ContinuousClock.now
                let text = (try? await recognizer.transcribe(audio, request: recipe.request))?.text ?? ""
                guard !Task.isCancelled, self.phase == .recording, self.sessionGeneration == generation else { return }
                // A pause can transcribe to nothing; keep the last words up
                // rather than blinking the caption off and on.
                let caption = Self.previewCaption(text)
                if !caption.isEmpty { self.livePreview = caption }
                wait = max(began.duration(to: .now), .milliseconds(700))
            }
        }
    }

    nonisolated static let livePreviewSeconds = 15.0

    /// The last 140 characters, cut at a word.
    nonisolated static func previewCaption(_ text: String, limit: Int = 140) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let tail = trimmed.suffix(limit)
        let word = tail.firstIndex(where: \.isWhitespace).map { tail[tail.index(after: $0)...] } ?? tail
        return "…" + word
    }

    // MARK: Again and redo

    /// Pastes the last transcript again into the app it went to.
    func pasteLastResult() {
        guard let text = lastResult?.finalText, !phase.isBusy else { return }
        Task { [weak self] in
            guard let self else { return }
            self.lastPasteOutcome = await self.pasteTarget.pasteAgain(text)
        }
    }

    /// Cleans a history entry's raw transcript again in another style and
    /// copies the result. Needs S1-mini for every style but Verbatim.
    func redo(_ entry: VoiceDictationHistoryEntry, as level: VoiceDictationCleanupLevel) async throws -> String {
        guard let raw = entry.raw, !raw.isEmpty else {
            throw VoiceDictationError.recognitionFailed("This entry was saved before Quill kept what it heard.")
        }
        return try await redo(raw: raw, context: entry.context ?? .general, bundleID: entry.bundleID, as: level)
    }

    /// The last dictation again in another style, copied. Offered in the
    /// island right after a cleanup that came out wrong.
    func redoLast(as level: VoiceDictationCleanupLevel) async throws -> String {
        guard let last = lastResult, !last.rawTranscript.isEmpty else { throw VoiceDictationError.noSpeech }
        let text = try await redo(raw: last.rawTranscript, context: last.appContext, bundleID: lastTargetBundleID, as: level)
        lastResult?.finalText = text
        lastResult?.cleanupLevel = level
        return text
    }

    /// The bundle ID of the app the last dictation went to.
    private var lastTargetBundleID: String?

    private func redo(
        raw: String,
        context: VoiceDictationAppContext,
        bundleID: String?,
        as level: VoiceDictationCleanupLevel
    ) async throws -> String {
        guard !phase.isBusy else { throw VoiceDictationError.busy }
        let engine = settings.voiceDictationEngine
        if level != .verbatim, !engine.appliesCleanup {
            throw VoiceDictationError.cleanupFailed("Redoing in \(level.title) needs Parakeet + S1-mini.")
        }
        let recipe = makeRecipe(engine: engine, appContext: context, bundleID: bundleID, level: level)
        defer { scheduleIdleUnload() }
        let output = try await processText(raw, language: nil, recipe: recipe, isCurrent: { true })
        let text = Self.finish(output.text, recipe: recipe).text
        guard Self.copyToClipboard(text) else { throw VoiceDictationError.clipboardFailed }
        return text
    }

    /// Recheck consent at the write boundary: transcription may outlive a
    /// change to the history setting. Enabling it later is not retroactive.
    func recordCompletedTranscript(
        _ text: String,
        engine: VoiceDictationEngine,
        historyWasEnabled: Bool,
        app: (bundleID: String, name: String)? = nil,
        audioSeconds: Double? = nil,
        latency: Double? = nil,
        raw: String? = nil,
        level: VoiceDictationCleanupLevel? = nil,
        context: VoiceDictationAppContext? = nil
    ) {
        guard historyWasEnabled, settings.voiceDictationHistoryEnabled else { return }
        history.record(
            text, engine: engine, app: app, audioSeconds: audioSeconds, latency: latency,
            raw: raw, level: level, context: context
        )
    }

    /// Counts only; the text is read here and nothing of it is kept.
    private func recordStats(
        raw: String,
        final: String,
        applied: [String],
        metrics: VoiceDictationMetrics,
        app: (bundleID: String, name: String)?
    ) {
        guard settings.voiceDictationInsightsEnabled else { return }
        let appliedPhrases = Set(applied.map { $0.lowercased() })
        stats.record(
            words: VoiceDictationTranscriptChunker.wordCount(final),
            seconds: metrics.audioDuration,
            fillersRemoved: VoiceDictationStatsStore.fillersRemoved(raw: raw, final: final),
            dictionaryEntryIDs: settings.voiceDictationVocabulary
                .filter { appliedPhrases.contains($0.phrase.lowercased()) }
                .map(\.id),
            latency: metrics.stopToClipboard,
            app: app
        )
    }

    private func fail(_ error: VoiceDictationError) {
        vadFeeder?.cancel()
        vadFeeder = nil
        livePreviewTask?.cancel()
        livePreviewTask = nil
        endSketch()
        lastError = error
        phase = .failed
        recordingStartedAt = nil
        pasteTarget.clearCapturedTarget()
        hold(for: failureHoldInterval, leaving: .failed)
        // `beginRecording` cancelled the idle unload; a press that ends here
        // must not leave the engine loaded for good.
        scheduleIdleUnload()
    }

    private func hold(for interval: Duration, leaving expected: VoiceDictationPhase) {
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled, self.phase == expected else { return }
            self.phase = .idle
        }
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        guard recognizer != nil else { return }
        idleUnloadTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.idleUnloadInterval)
            guard !Task.isCancelled, !self.phase.isBusy, self.processingTask == nil else { return }
            self.unloadEngines()
        }
    }

    // MARK: Helpers

    /// A clip whose peak never clears this is the room, not a voice. Skips
    /// the model entirely and keeps Whisper from inventing text for silence.
    nonisolated static func containsSpeech(_ samples: [Float], threshold: Float = 0.01) -> Bool {
        samples.contains { abs($0) >= threshold }
    }

    /// Whisper's known reflex on near-silence: a lone "you", "Thank you." or
    /// similar. Nothing a person dictates in one breath is one of these words
    /// at a whisper, so a quiet clip that yields only this is treated as no
    /// speech rather than copied.
    nonisolated static func isLikelyHallucination(_ transcript: String, samples: [Float]) -> Bool {
        let normalized = transcript
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
        guard hallucinationPhrases.contains(normalized) else { return false }
        guard !samples.isEmpty else { return true }
        let meanSquare = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let decibels = 20 * log10(max(meanSquare.squareRoot(), 1e-6))
        return decibels < -40
    }

    private nonisolated static let hallucinationPhrases: Set<String> = [
        "you", "thank you", "thanks", "thank you for watching", "thanks for watching",
        "bye", "the", "so", "okay", "hmm", "mm",
    ]

    nonisolated static func copyToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    nonisolated private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
