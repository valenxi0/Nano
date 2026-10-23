import AppKit
@preconcurrency import AVFoundation
import XCTest
@testable import Nano

private final class AudioTapInvocation: @unchecked Sendable {
    let handler: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer
    let time: AVAudioTime

    init(handler: @escaping AVAudioNodeTapBlock, buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        self.handler = handler
        self.buffer = buffer
        self.time = time
    }
}

private final class AudioTapProbe: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
}

private final class MutablePIDBox: @unchecked Sendable {
    var value: pid_t?

    init(_ value: pid_t?) {
        self.value = value
    }
}

@MainActor
final class VoiceDictationControllerTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        suite = "nano-vd-controller-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nano-vd-controller-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func makeController(enabled: Bool = true) -> VoiceDictationController {
        let settings = NanoSettings(defaults: defaults)
        settings.setEnabled(enabled, for: .voiceDictation)
        return VoiceDictationController(
            settings: settings,
            modelStore: VoiceDictationModelStore(rootDirectory: root.appendingPathComponent("Models")),
            history: VoiceDictationHistoryStore(fileURL: root.appendingPathComponent("history.json")),
            stats: VoiceDictationStatsStore(fileURL: root.appendingPathComponent("stats.json"))
        )
    }

    func testReadinessReportsMissingModelsBeforeAnythingElse() {
        let controller = makeController()
        XCTAssertEqual(controller.readiness, .missingModels([.parakeetTDT06BV3, .s1Mini]))
        controller.settings.voiceDictationEngine = .whisperTiny
        XCTAssertEqual(controller.readiness, .missingModels([.whisperTinyEnglish]))
    }

    func testReadinessIsDisabledWhenTheFeatureIsOff() {
        XCTAssertEqual(makeController(enabled: false).readiness, .disabled)
    }

    func testStartingWithoutModelsFailsWithAnActionableErrorAndNoRecording() {
        let controller = makeController()
        controller.hotkeyPressed()
        XCTAssertEqual(controller.phase, .failed)
        XCTAssertEqual(controller.lastError, .modelMissing(.parakeetS1, [.parakeetTDT06BV3, .s1Mini]))
        XCTAssertFalse(controller.recorder.isRecording)
        XCTAssertTrue(controller.lastError!.detail.contains("Settings"))
        XCTAssertNil(controller.lastResult)
    }

    func testPushToTalkStartsOnPressAndStopsOnRelease() {
        XCTAssertEqual(VoiceDictationActivationMode.pushToTalk.action(for: .pressed, phase: .idle), .start)
        XCTAssertEqual(VoiceDictationActivationMode.pushToTalk.action(for: .released, phase: .recording), .stop)
        XCTAssertEqual(VoiceDictationActivationMode.pushToTalk.action(for: .released, phase: .idle), .ignore)
        XCTAssertEqual(VoiceDictationActivationMode.pushToTalk.action(for: .pressed, phase: .transcribing), .ignore)
    }

    func testToggleStartsAndStopsOnSuccessivePressesAndIgnoresRelease() {
        XCTAssertEqual(VoiceDictationActivationMode.toggle.action(for: .pressed, phase: .idle), .start)
        XCTAssertEqual(VoiceDictationActivationMode.toggle.action(for: .released, phase: .recording), .ignore)
        XCTAssertEqual(VoiceDictationActivationMode.toggle.action(for: .pressed, phase: .recording), .stop)
        XCTAssertEqual(VoiceDictationActivationMode.toggle.action(for: .pressed, phase: .transcribing), .ignore)
    }

    func testEscapeCancelsOnlyWhileADictationIsBusy() {
        for mode in [VoiceDictationActivationMode.pushToTalk, .toggle] {
            XCTAssertEqual(mode.action(for: .escape, phase: .recording), .cancel, "\(mode)")
            XCTAssertEqual(mode.action(for: .escape, phase: .transcribing), .cancel, "\(mode)")
            XCTAssertEqual(mode.action(for: .escape, phase: .cleaning), .cancel, "\(mode)")
            XCTAssertEqual(mode.action(for: .escape, phase: .idle), .ignore, "\(mode)")
            XCTAssertEqual(mode.action(for: .escape, phase: .completed), .ignore, "\(mode)")
            XCTAssertEqual(mode.action(for: .escape, phase: .failed), .ignore, "\(mode)")
            XCTAssertEqual(mode.action(for: .escape, phase: .cancelled), .ignore, "\(mode)")
            XCTAssertEqual(mode.action(for: .pressed, phase: .cancelled), .start, "a new dictation may start during the acknowledgement")
        }
    }

    func testCancelledIsAShortNonBusyAcknowledgement() {
        XCTAssertFalse(VoiceDictationPhase.cancelled.isBusy)
        XCTAssertEqual(VoiceDictationPhase.cancelled.title, "Cancelled")
        let controller = makeController()
        XCTAssertLessThan(controller.cancelHoldInterval, controller.completionHoldInterval)
    }

    func testEscapeWhileIdleOrFailedIsHarmless() {
        let controller = makeController()
        controller.escapePressed()
        XCTAssertEqual(controller.phase, .idle)

        controller.hotkeyPressed()
        XCTAssertEqual(controller.phase, .failed)
        controller.escapePressed()
        XCTAssertEqual(controller.phase, .failed, "Escape does not dismiss a failure; the hold timer does")
        XCTAssertNotNil(controller.lastError)
    }

    func testCancelKeyIsOnlyHeldWhileRegistered() {
        let monitor = VoiceDictationHotkeyMonitor()
        XCTAssertFalse(monitor.isCancelKeyRegistered)
        // Bare Escape may already be claimed on a developer machine; what
        // matters is that a second call is a no-op and unregister is clean.
        let first = monitor.registerCancelKey()
        XCTAssertEqual(monitor.registerCancelKey(), first)
        XCTAssertEqual(monitor.isCancelKeyRegistered, first)
        monitor.unregisterCancelKey()
        XCTAssertFalse(monitor.isCancelKeyRegistered)
        monitor.unregisterCancelKey()
        XCTAssertFalse(monitor.isCancelKeyRegistered)
    }

    func testFailureClearsAfterTheHoldInterval() async {
        let controller = makeController()
        controller.failureHoldInterval = .milliseconds(50)
        controller.hotkeyPressed()
        XCTAssertEqual(controller.phase, .failed)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNotNil(controller.lastError, "the error stays readable in Settings")
    }

    func testCancelFromIdleIsHarmless() {
        let controller = makeController()
        controller.cancel()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.loadedEngine)
    }

    func testWarmUpDoesNothingWithoutModels() {
        let controller = makeController()
        controller.warmEngineIfNeeded()
        XCTAssertFalse(controller.isLoadingEngine)
        XCTAssertNil(controller.loadedEngine)
    }

    func testActivateAndDeactivateAreIdempotentAndRegisterTheHotkey() {
        let controller = makeController()
        controller.activate()
        controller.activate()
        // Registration either succeeds or reports the chord is taken; both are
        // legitimate on a developer machine. What matters is no crash and a
        // clean unregister.
        _ = controller.hotkeyProblem
        controller.deactivate()
        controller.deactivate()
        XCTAssertNil(controller.hotkeyProblem)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testTurningHistoryOffClearsStoredTranscripts() async {
        let controller = makeController()
        controller.settings.voiceDictationHistoryEnabled = true
        controller.activate()
        controller.history.record("keep me", engine: .whisperBase)
        XCTAssertEqual(controller.history.entries.count, 1)

        controller.settings.voiceDictationHistoryEnabled = false
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(controller.history.entries.isEmpty)
        controller.deactivate()
    }

    func testHistoryConsentIsRecheckedWhenPendingTranscriptCompletes() {
        let controller = makeController()
        controller.settings.voiceDictationHistoryEnabled = true
        let historyWasEnabled = controller.settings.voiceDictationHistoryEnabled
        controller.settings.voiceDictationHistoryEnabled = false

        controller.recordCompletedTranscript("pending private transcript", engine: .whisperBase,
                                             historyWasEnabled: historyWasEnabled)
        XCTAssertTrue(controller.history.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("history.json").path))

        controller.settings.voiceDictationHistoryEnabled = true
        controller.recordCompletedTranscript("started while disabled", engine: .whisperBase,
                                             historyWasEnabled: false)
        XCTAssertTrue(controller.history.entries.isEmpty)

        controller.recordCompletedTranscript("explicitly retained", engine: .whisperBase,
                                             historyWasEnabled: true)
        XCTAssertEqual(controller.history.entries.count, 1)
        XCTAssertEqual(VoiceDictationHistoryStore(fileURL: root.appendingPathComponent("history.json")).entries.count, 1)
    }

    func testSilenceDetection() {
        XCTAssertFalse(VoiceDictationController.containsSpeech([Float](repeating: 0, count: 16_000)))
        XCTAssertFalse(VoiceDictationController.containsSpeech([Float](repeating: 0.004, count: 16_000)))
        var quietRoomWithAWord = [Float](repeating: 0.002, count: 16_000)
        quietRoomWithAWord[8_000] = -0.2
        XCTAssertTrue(VoiceDictationController.containsSpeech(quietRoomWithAWord))
    }

    func testWhisperSilenceReflexIsNotCopied() {
        let quiet = [Float](repeating: 0.002, count: 16_000) // about -54 dBFS
        let spoken = [Float](repeating: 0.2, count: 16_000) // about -14 dBFS
        XCTAssertTrue(VoiceDictationController.isLikelyHallucination("you", samples: quiet))
        XCTAssertTrue(VoiceDictationController.isLikelyHallucination(" Thank you. ", samples: quiet))
        XCTAssertFalse(VoiceDictationController.isLikelyHallucination("you", samples: spoken), "a real, audible 'you' stays")
        XCTAssertFalse(VoiceDictationController.isLikelyHallucination("Open the calendar.", samples: quiet))
    }

    func testVoiceWaveformBarsHaveAFloorAndGrowWithLevel() {
        XCTAssertEqual(VoiceDictationWaveform.barHeight(for: 0, maximum: 17), 2)
        XCTAssertGreaterThan(VoiceDictationWaveform.barHeight(for: 0.75, maximum: 17), 2)
    }

    func testVoiceWaveformClampsInvalidAndOutOfRangeLevels() {
        XCTAssertEqual(VoiceDictationWaveform.displayLevel(-1), 0)
        XCTAssertEqual(VoiceDictationWaveform.displayLevel(.nan), 0)
        XCTAssertEqual(VoiceDictationWaveform.displayLevel(2), 1)
    }

    func testMicrophoneRippleIsInvisibleDuringSilence() {
        let progress = VoiceDictationMicRipple.progress(at: 0.2, ring: 0)

        XCTAssertEqual(
            VoiceDictationMicRipple.opacity(for: progress, displayedLevel: 0),
            0
        )
    }

    func testMicrophoneRippleExpandsAndFadesAcrossSpeechCycle() {
        let earlyProgress = 0.1
        let lateProgress = 0.8

        XCTAssertLessThan(
            VoiceDictationMicRipple.scale(for: earlyProgress),
            VoiceDictationMicRipple.scale(for: lateProgress)
        )
        XCTAssertGreaterThan(
            VoiceDictationMicRipple.opacity(for: earlyProgress, displayedLevel: 0.7),
            VoiceDictationMicRipple.opacity(for: lateProgress, displayedLevel: 0.7)
        )
        XCTAssertGreaterThan(
            VoiceDictationMicRipple.opacity(for: earlyProgress, displayedLevel: 0.7),
            0
        )
    }

    func testMicrophoneRippleRingsAreStaggered() {
        XCTAssertNotEqual(
            VoiceDictationMicRipple.progress(at: 0.1, ring: 0),
            VoiceDictationMicRipple.progress(at: 0.1, ring: 1)
        )
    }

    func testFailureLabelMovesAcrossTheHardwareNotch() {
        XCTAssertEqual(
            VoiceDictationCompactLayout.failureLabelPlacement(notchWidth: 0),
            .leading
        )
        XCTAssertEqual(
            VoiceDictationCompactLayout.failureLabelPlacement(notchWidth: 104),
            .trailing
        )
    }

    func testEveryNotchedFailureTitleFitsItsWing() {
        let failures: [VoiceDictationError] = [
            .featureDisabled,
            .microphoneDenied,
            .microphoneUnavailable,
            .audioCaptureFailed("test"),
            .modelMissing(.parakeetS1, [.parakeetTDT06BV3]),
            .modelLoadFailed("test"),
            .recognitionFailed("test"),
            .cleanupFailed("test"),
            .clipboardFailed,
            .cancelled,
            .noSpeech,
            .busy,
        ]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        ]

        for failure in failures {
            let title = VoiceDictationCompactLayout.notchedFailureTitle(for: failure)
            let width = (title as NSString).size(withAttributes: attributes).width
            XCTAssertLessThanOrEqual(width, 132, "\(title) must fit the notched wing")
        }
    }

    func testClipboardWriteReplacesContents() {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let before { pasteboard.setString(before, forType: .string) }
        }
        XCTAssertTrue(VoiceDictationController.copyToClipboard("Nano dictation test"))
        XCTAssertEqual(pasteboard.string(forType: .string), "Nano dictation test")
    }

    func testFocusedPasteUsesDirectInsertionWhenAvailable() {
        var events: [String] = []
        let outcome = VoiceDictationPasteTarget.deliveryOutcome(
            accessibilityTrusted: true,
            hasFocusedEditableTarget: true,
            insertText: {
                events.append("insert")
                return true
            },
            sendPasteShortcut: {
                events.append("shortcut")
                return true
            }
        )

        XCTAssertEqual(outcome, .requested)
        XCTAssertEqual(events, ["insert"])
    }

    func testFocusedPasteFallsBackToCommandV() {
        var events: [String] = []
        let outcome = VoiceDictationPasteTarget.deliveryOutcome(
            accessibilityTrusted: true,
            hasFocusedEditableTarget: true,
            insertText: {
                events.append("insert")
                return false
            },
            sendPasteShortcut: {
                events.append("shortcut")
                return true
            }
        )

        XCTAssertEqual(outcome, .requested)
        XCTAssertEqual(events, ["insert", "shortcut"])
    }

    func testFocusedPasteRemainsCopyOnlyWithoutEditableTarget() {
        var attemptedDelivery = false
        let outcome = VoiceDictationPasteTarget.deliveryOutcome(
            accessibilityTrusted: true,
            hasFocusedEditableTarget: false,
            insertText: {
                attemptedDelivery = true
                return true
            },
            sendPasteShortcut: {
                attemptedDelivery = true
                return true
            }
        )

        XCTAssertEqual(outcome, .noEditableTarget)
        XCTAssertFalse(attemptedDelivery)
    }

    func testFocusedPasteReportsAccessibilityBeforeAttemptingDelivery() {
        var attemptedDelivery = false
        let outcome = VoiceDictationPasteTarget.deliveryOutcome(
            accessibilityTrusted: false,
            hasFocusedEditableTarget: true,
            insertText: {
                attemptedDelivery = true
                return true
            },
            sendPasteShortcut: {
                attemptedDelivery = true
                return true
            }
        )

        XCTAssertEqual(outcome, .accessibilityRequired)
        XCTAssertFalse(attemptedDelivery)
    }

    /// Chromium returns success from the `AXSelectedText` write without
    /// inserting anything. An unchanged character count must be rejected so
    /// the Command-V fallback still runs.
    func testAccessibilityInsertIsRejectedWhenCharacterCountDoesNotMove() {
        XCTAssertFalse(VoiceDictationPasteTarget.insertionConfirmed(
            charactersBefore: 12,
            charactersAfter: 12,
            replacedLength: 0,
            insertedLength: "hello world".utf16.count
        ))
    }

    func testAccessibilityInsertIsConfirmedWhenTextGrowsByInsertedLength() {
        XCTAssertTrue(VoiceDictationPasteTarget.insertionConfirmed(
            charactersBefore: 12,
            charactersAfter: 23,
            replacedLength: 0,
            insertedLength: "hello world".utf16.count
        ))
    }

    func testAccessibilityInsertAccountsForReplacedSelection() {
        // "12 chars" with 5 selected, replaced by 11 → 18.
        XCTAssertTrue(VoiceDictationPasteTarget.insertionConfirmed(
            charactersBefore: 12,
            charactersAfter: 18,
            replacedLength: 5,
            insertedLength: 11
        ))
        XCTAssertFalse(VoiceDictationPasteTarget.insertionConfirmed(
            charactersBefore: 12,
            charactersAfter: 12,
            replacedLength: 5,
            insertedLength: 11
        ))
    }

    func testFocusedPasteReportsFailureWhenBothDeliveryPathsFail() {
        let outcome = VoiceDictationPasteTarget.deliveryOutcome(
            accessibilityTrusted: true,
            hasFocusedEditableTarget: true,
            insertText: { false },
            sendPasteShortcut: { false }
        )

        XCTAssertEqual(outcome, .eventFailed)
    }

    func testDictationPastesIntoTheTargetCapturedWhenRecordingStarted() {
        let frontmostPID = MutablePIDBox(101)
        var requestedAccessibility = false
        var deliveries: [pid_t] = []
        let target = VoiceDictationPasteTarget(
            isAccessibilityTrusted: { true },
            requestAccessibility: { requestedAccessibility = true },
            frontmostProcessIdentifier: { frontmostPID.value },
            editableTarget: { pid in
                VoiceDictationPasteTarget.EditableTarget(
                    processIdentifier: pid,
                    insert: { _ in
                        deliveries.append(pid)
                        return true
                    },
                    paste: { false }
                )
            }
        )

        target.captureFocusedTarget()
        frontmostPID.value = 202

        XCTAssertEqual(target.pasteIntoFocusedTarget("Captured target"), .requested)
        XCTAssertEqual(deliveries, [101])
        XCTAssertFalse(requestedAccessibility)
    }

    func testSketchKeepsTheFieldItStartedInAfterFocusMoves() {
        var focusedFieldIsEditable = true
        let field = AXUIElementCreateApplication(getpid())
        let target = VoiceDictationPasteTarget(
            isAccessibilityTrusted: { true },
            requestAccessibility: {},
            frontmostProcessIdentifier: { 101 },
            editableTarget: { pid in
                focusedFieldIsEditable
                    ? VoiceDictationPasteTarget.EditableTarget(processIdentifier: pid, insert: { _ in true }, paste: { true }, element: field)
                    : nil
            }
        )

        target.captureFocusedTarget()
        focusedFieldIsEditable = false

        XCTAssertTrue(target.capturedTargetIsEditable, "a click while sketching must not lose the message box")
        target.clearCapturedTarget()
        XCTAssertFalse(target.capturedTargetIsEditable)
    }

    func testDictationInsertsIntoCapturedNanoTextTargetWithoutAccessibility() {
        var inserted: [String] = []
        let targetID = UUID()
        NanoVoiceDictationTextTarget.shared.activate(id: targetID) { text in
            inserted.append(text)
            return true
        }
        defer { NanoVoiceDictationTextTarget.shared.deactivate(id: targetID) }

        let target = VoiceDictationPasteTarget(
            isAccessibilityTrusted: { false },
            requestAccessibility: {},
            frontmostProcessIdentifier: { nil },
            editableTarget: { _ in nil }
        )

        target.captureFocusedTarget()

        XCTAssertEqual(target.pasteIntoFocusedTarget("Written inside Nano"), .requested)
        XCTAssertEqual(inserted, ["Written inside Nano"])
    }

    func testStartingDictationDoesNotRepeatedlyRequestAccessibility() {
        var requestedAccessibility = false
        let target = VoiceDictationPasteTarget(
            isAccessibilityTrusted: { false },
            requestAccessibility: { requestedAccessibility = true },
            frontmostProcessIdentifier: { 101 },
            editableTarget: { _ in nil }
        )

        target.captureFocusedTarget()

        XCTAssertFalse(requestedAccessibility)
        XCTAssertEqual(target.pasteIntoFocusedTarget("Clipboard remains authoritative"), .accessibilityRequired)
    }

    func testExplicitAutomaticPasteSetupRequestsAccessibility() {
        var requestedAccessibility = false
        let target = VoiceDictationPasteTarget(
            isAccessibilityTrusted: { false },
            requestAccessibility: { requestedAccessibility = true },
            frontmostProcessIdentifier: { 101 },
            editableTarget: { _ in nil }
        )

        target.requestAutomaticPasteAccess()

        XCTAssertTrue(requestedAccessibility)
    }

    func testExplicitAutomaticPasteSetupDoesNotPromptWhenAlreadyTrusted() {
        var requestedAccessibility = false
        let target = VoiceDictationPasteTarget(
            isAccessibilityTrusted: { true },
            requestAccessibility: { requestedAccessibility = true },
            frontmostProcessIdentifier: { 101 },
            editableTarget: { _ in nil }
        )

        target.requestAutomaticPasteAccess()

        XCTAssertFalse(requestedAccessibility)
    }

    func testRemoteStartNeedsTheOptIn() {
        let controller = makeController()
        XCTAssertFalse(controller.remoteLinksAllowed)
        XCTAssertFalse(controller.allowsRemote(.start))
        XCTAssertFalse(controller.allowsRemote(.toggle))
        XCTAssertTrue(controller.allowsRemote(.stop))
        XCTAssertTrue(controller.allowsRemote(.cancel))
        XCTAssertFalse(controller.perform(.start))
        XCTAssertEqual(controller.phase, .idle, "a blocked link must not reach the recorder")

        controller.remoteLinksAllowed = true
        XCTAssertTrue(controller.allowsRemote(.start))
        // No engine is downloaded here, so the start is allowed but fails.
        XCTAssertFalse(controller.perform(.start))
        XCTAssertEqual(controller.phase, .failed)
    }

    func testDeactivateClearsAHeldFailure() {
        let controller = makeController()
        controller.activate()
        controller.beginRecording()
        XCTAssertEqual(controller.phase, .failed)
        controller.deactivate()
        XCTAssertEqual(controller.phase, .idle)
    }

    func testShortcutNeedsCommandControlOrOption() {
        let shift = NSEvent.ModifierFlags.shift.rawValue
        let function = NSEvent.ModifierFlags.function.rawValue
        let controlFunction = NSEvent.ModifierFlags([.control, .function]).rawValue
        XCTAssertFalse(VoiceDictationHotkey(keyCode: 46, modifierFlags: shift).isUsable)
        XCTAssertFalse(VoiceDictationHotkey(keyCode: 123, modifierFlags: function).isUsable)
        XCTAssertTrue(VoiceDictationHotkey(keyCode: 123, modifierFlags: controlFunction).isUsable)
    }

    func testCommonSystemShortcutsAreRecognized() {
        let command = NSEvent.ModifierFlags.command.rawValue
        let commandShift = NSEvent.ModifierFlags([.command, .shift]).rawValue
        XCTAssertTrue(VoiceDictationHotkey.isCommonSystemShortcut(VoiceDictationHotkey(keyCode: 17, modifierFlags: command)))
        XCTAssertTrue(VoiceDictationHotkey.isCommonSystemShortcut(VoiceDictationHotkey(keyCode: 49, modifierFlags: command)))
        XCTAssertFalse(VoiceDictationHotkey.isCommonSystemShortcut(VoiceDictationHotkey(keyCode: 17, modifierFlags: commandShift)))
        XCTAssertFalse(VoiceDictationHotkey.isCommonSystemShortcut(.default))
    }

    func testWhisperTidyStripsOnlyNonSpeechTags() {
        XCTAssertEqual(
            WhisperCppRecognizer.tidy(" [BLANK_AUDIO] hello (Music) world [ laughter ]"),
            "hello world"
        )
        XCTAssertEqual(
            WhisperCppRecognizer.tidy("call f(x) (the helper) [draft]"),
            "call f(x) (the helper) [draft]"
        )
    }

    func testPhaseVocabulary() {
        XCTAssertTrue(VoiceDictationPhase.recording.isBusy)
        XCTAssertTrue(VoiceDictationPhase.cleaning.isBusy)
        XCTAssertFalse(VoiceDictationPhase.completed.isBusy)
        XCTAssertEqual(VoiceDictationPhase.completed.title, "Copied")
    }

    func testAudioRecorderAcceptsBuffersFromCoreAudioQueue() async throws {
        guard VoiceDictationMicrophoneAuthorization.current == .authorized else {
            throw XCTSkip("Nano needs microphone permission for the live audio callback regression test.")
        }

        let recorder = VoiceDictationAudioRecorder()
        try recorder.start()
        try await Task.sleep(for: .milliseconds(500))
        _ = recorder.stop()

        XCTAssertFalse(recorder.isRecording)
    }

    func testAudioTapHandlerRunsOffMainActor() {
        let probe = AudioTapProbe()
        let handler = VoiceDictationAudioRecorder.makeTapHandler { [probe] _ in
            probe.semaphore.signal()
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        let invocation = AudioTapInvocation(
            handler: handler,
            buffer: buffer,
            time: AVAudioTime(sampleTime: 0, atRate: 16_000)
        )

        DispatchQueue(label: "com.nanoapp.tests.audio-tap").async {
            invocation.handler(invocation.buffer, invocation.time)
        }

        XCTAssertEqual(probe.semaphore.wait(timeout: .now() + 1), .success)
    }
}
