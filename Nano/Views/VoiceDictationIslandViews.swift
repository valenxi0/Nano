import SwiftUI

enum VoiceDictationWaveform {
    static let noiseGate = 0.08
    static let restingHeight: CGFloat = 2

    static func displayLevel(_ rawLevel: Double) -> Double {
        guard rawLevel.isFinite else { return 0 }
        let clamped = min(max(rawLevel, 0), 1)
        guard clamped > noiseGate else { return 0 }
        let gated = min(max((clamped - noiseGate) / (1 - noiseGate), 0), 1)
        // Quiet but real speech sits just above the gate. Linear, it moved
        // the 15pt compact bars by a point or two and read as a flat line.
        return pow(gated, 0.55)
    }

    static func barHeight(for level: Double, maximum: CGFloat) -> CGFloat {
        let clamped = min(max(level, 0), 1)
        return restingHeight + (max(maximum, restingHeight) - restingHeight) * CGFloat(clamped)
    }
}

enum VoiceDictationMicRipple {
    static let ringCount = 2
    static let cycleDuration: TimeInterval = 0.9

    static func progress(at time: TimeInterval, ring: Int) -> Double {
        let ringOffset = Double(ring) / Double(ringCount)
        return (time / cycleDuration + ringOffset).truncatingRemainder(dividingBy: 1)
    }

    static func scale(for progress: Double) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        return 0.78 + CGFloat(clamped) * 0.78
    }

    static func opacity(for progress: Double, displayedLevel: Double) -> Double {
        let clampedProgress = min(max(progress, 0), 1)
        let clampedLevel = min(max(displayedLevel, 0), 1)
        return clampedLevel * 0.34 * (1 - clampedProgress)
    }
}

/// The island's acknowledgement that the user abandoned a dictation: the
/// mic shakes and the island's outline flashes red, then everything fades.
/// Both run on keyframe animators so they play at display rate even in the
/// collapsed strip, where `TimelineView` is budgeted down to 15fps.
enum VoiceDictationCancelMotion {
    /// Hotter than the module's accent so it never reads as the recording dot.
    static let tint = Color(red: 1.0, green: 0.36, blue: 0.34)
    /// Total span of the outline flash; sits inside `cancelHoldInterval`.
    static let outlineDuration: TimeInterval = 1.25
}

enum VoiceDictationFailureLabelPlacement: Equatable {
    case leading
    case trailing
}

enum VoiceDictationCompactLayout {
    static func failureLabelPlacement(notchWidth: CGFloat) -> VoiceDictationFailureLabelPlacement {
        notchWidth > 0 ? .trailing : .leading
    }

    /// Notched displays have one 132pt wing for the status. Keep every error
    /// legible there; Settings retains the full title and recovery detail.
    static func notchedFailureTitle(for error: VoiceDictationError?) -> String {
        switch error {
        case .featureDisabled: "Quill is off"
        case .microphoneDenied: "Microphone denied"
        case .microphoneUnavailable: "No microphone"
        case .audioCaptureFailed: "Recording failed"
        case .modelMissing: "Download engine"
        case .modelLoadFailed: "Engine failed to load"
        case .recognitionFailed: "Recognition failed"
        case .cleanupFailed: "Cleanup failed"
        case .clipboardFailed: "Clipboard failed"
        case .cancelled: "Dictation cancelled"
        case .noSpeech: "Nothing to transcribe"
        case .busy: "Already transcribing"
        case .screenRecordingDenied: "Allow Screen Recording"
        case .screenCaptureFailed: "Screenshot failed"
        case nil: "Failed"
        }
    }
}

/// Left side of the compact island while a dictation is in flight. Recording
/// uses only the live microphone; busy and failure states keep a short label.
/// Completed is just the checkmark — the status string sits on the trailing wing.
struct VoiceDictationCompactLeading: View {
    @ObservedObject var controller: VoiceDictationController
    let failureLabelPlacement: VoiceDictationFailureLabelPlacement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        controller: VoiceDictationController,
        failureLabelPlacement: VoiceDictationFailureLabelPlacement = .leading
    ) {
        self.controller = controller
        self.failureLabelPlacement = failureLabelPlacement
    }

    var body: some View {
        ZStack(alignment: .leading) {
            leadingContent
                .id(phaseKey)
                .transition(phaseTransition)
        }
        .animation(phaseAnimation, value: phaseKey)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quill: \(title)")
    }

    @ViewBuilder
    private var leadingContent: some View {
        if controller.phase == .recording {
            VoiceDictationListeningMic(recorder: controller.recorder)
        } else {
            HStack(spacing: 7) {
                switch controller.phase {
                case .transcribing, .cleaning:
                    NanoThinkingOrb(scale: .inline, tint: .white)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)
                case .failed:
                    VoiceDictationFailureMic()
                case .cancelled:
                    VoiceDictationCancelledMic()
                case .recording, .idle:
                    EmptyView()
                }

                if shouldShowLeadingTitle {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
        }
    }

    private var title: String {
        switch controller.phase {
        case .failed: controller.lastError?.title ?? "Failed"
        default: controller.deliveryTitle
        }
    }

    /// Completed status lives on the trailing wing so the checkmark and
    /// "Paste sent" / "Copied only" stay balanced. Failures and cancellation
    /// still use `failureLabelPlacement` so notched Macs keep the title off
    /// the camera.
    private var shouldShowLeadingTitle: Bool {
        switch controller.phase {
        case .completed: false
        case .failed, .cancelled: failureLabelPlacement == .leading
        case .recording, .transcribing, .cleaning, .idle: true
        }
    }

    private var phaseKey: String {
        "\(controller.phase.title):\(controller.lastError?.title ?? "")"
    }

    private var phaseAnimation: Animation? {
        guard !reduceMotion else { return .easeOut(duration: 0.15) }
        return NanoMotion.smooth(0.25)
    }

    private var phaseTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -4)),
            removal: .opacity
        )
    }
}

/// Right side: engine stage while busy, or the completion status.
struct VoiceDictationCompactTrailing: View {
    @ObservedObject var controller: VoiceDictationController
    let maxWidth: CGFloat
    let failureLabelPlacement: VoiceDictationFailureLabelPlacement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        controller: VoiceDictationController,
        maxWidth: CGFloat,
        failureLabelPlacement: VoiceDictationFailureLabelPlacement = .leading
    ) {
        self.controller = controller
        self.maxWidth = maxWidth
        self.failureLabelPlacement = failureLabelPlacement
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            trailingContent
                .id(phaseKey)
                .transition(phaseTransition)
        }
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .animation(phaseAnimation, value: phaseKey)
    }

    @ViewBuilder
    private var trailingContent: some View {
        switch controller.phase {
        case .recording:
            VoiceDictationFlowWaveform(recorder: controller.recorder, width: 48, height: 17)
        case .transcribing:
            NanoActivityChip(symbol: "waveform", text: engineTitle, maxWidth: maxWidth)
        case .cleaning:
            NanoActivityChip(symbol: "sparkles", text: "S1-mini", maxWidth: maxWidth)
        case .completed:
            Text(controller.deliveryTitle)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: maxWidth, alignment: .trailing)
                .accessibilityHidden(true)
        case .failed:
            if failureLabelPlacement == .trailing {
                Text(VoiceDictationCompactLayout.notchedFailureTitle(for: controller.lastError))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: maxWidth, alignment: .trailing)
            }
        case .cancelled:
            if failureLabelPlacement == .trailing {
                Text(controller.phase.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: maxWidth, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        case .idle:
            EmptyView()
        }
    }

    private var phaseKey: String {
        "\(controller.phase.title):\(controller.lastError?.title ?? "")"
    }

    private var phaseAnimation: Animation? {
        guard !reduceMotion else { return .easeOut(duration: 0.15) }
        return NanoMotion.smooth(0.25)
    }

    private var phaseTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -4)),
            removal: .opacity
        )
    }

    private var engineTitle: String {
        switch controller.settings.voiceDictationEngine {
        case .parakeetS1: "Parakeet"
        case .cohereTranscribe: "Cohere"
        case .whisperTurbo: "Whisper Turbo"
        case .whisperBase: "Whisper Base"
        case .whisperTiny: "Whisper Tiny"
        }
    }
}

private struct VoiceDictationListeningMic: View {
    @ObservedObject var recorder: VoiceDictationAudioRecorder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nanoMotionBudget) private var budget

    var body: some View {
        let level = VoiceDictationWaveform.displayLevel(recorder.inputLevel)

        TimelineView(
            .animation(
                minimumInterval: budget.interval(1.0 / 30, cost: .light),
                paused: budget.isPaused || reduceMotion || level == 0
            )
        ) { context in
            ZStack {
                if !reduceMotion && !budget.isPaused && level > 0 {
                    ForEach(0..<VoiceDictationMicRipple.ringCount, id: \.self) { ring in
                        let progress = VoiceDictationMicRipple.progress(
                            at: context.date.timeIntervalSinceReferenceDate,
                            ring: ring
                        )

                        Circle()
                            .stroke(
                                .white.opacity(
                                    VoiceDictationMicRipple.opacity(
                                        for: progress,
                                        displayedLevel: level
                                    )
                                ),
                                lineWidth: 0.9
                            )
                            .frame(width: 18, height: 18)
                            .scaleEffect(VoiceDictationMicRipple.scale(for: progress))
                    }
                }

                Image(systemName: "mic")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88 + level * 0.12))
                    .scaleEffect(1 + level * 0.03)
            }
            .frame(width: 30, height: 30)
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

private struct VoiceDictationFailureMic: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shakeTrigger = 0

    var body: some View {
        Image(systemName: "mic.slash")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.orange)
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: shakeTrigger) { content, offset in
                content.offset(x: offset)
            } keyframes: { _ in
                CubicKeyframe(-1.7, duration: 0.10)
                CubicKeyframe(1.7, duration: 0.10)
                CubicKeyframe(-1.7, duration: 0.10)
                CubicKeyframe(1.7, duration: 0.10)
                CubicKeyframe(0, duration: 0.20)
            }
            .onAppear {
                guard !reduceMotion else { return }
                shakeTrigger += 1
            }
    }
}

/// The island's outline flashes red while the controller sits in
/// `.cancelled`. Only the outline: a hairline plus a soft blurred halo so it
/// reads as an edge, never a fill. Observes the controller itself so the
/// root view does not re-render on every dictation state change.
struct VoiceDictationCancelOutline<S: Shape>: View {
    @ObservedObject var controller: VoiceDictationController
    let shape: S
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if controller.phase == .cancelled {
            VoiceDictationCancelOutlineFlash(shape: shape, reduceMotion: reduceMotion)
                .transition(.identity)
        }
    }
}

private struct VoiceDictationCancelOutlineFlash<S: Shape>: View {
    let shape: S
    let reduceMotion: Bool
    @State private var flashTrigger = 0

    var body: some View {
        ZStack {
            shape.stroke(VoiceDictationCancelMotion.tint.opacity(0.95), lineWidth: 1.2)
            if !reduceMotion {
                shape.stroke(VoiceDictationCancelMotion.tint.opacity(0.35), lineWidth: 3)
                    .blur(radius: 2.5)
            }
        }
        // Snaps in over 100 ms, holds, then fades out over the back half.
        .keyframeAnimator(initialValue: 0.0, trigger: flashTrigger) { content, opacity in
            content.opacity(opacity)
        } keyframes: { _ in
            LinearKeyframe(1.0, duration: 0.10)
            LinearKeyframe(1.0, duration: 0.45)
            CubicKeyframe(0.0, duration: VoiceDictationCancelMotion.outlineDuration - 0.55)
        }
        .onAppear { flashTrigger += 1 }
    }
}

/// Red slashed mic that shakes once when the user cancels. The outline flash
/// on the island itself lives in the root view.
private struct VoiceDictationCancelledMic: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shakeTrigger = 0

    var body: some View {
        Image(systemName: "mic.slash")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(VoiceDictationCancelMotion.tint)
            // A decaying swing: harder than the failure shake because the
            // user asked for this and should see the island react.
            .keyframeAnimator(initialValue: CGFloat.zero, trigger: shakeTrigger) { content, offset in
                content.offset(x: offset)
            } keyframes: { _ in
                CubicKeyframe(-2.6, duration: 0.055)
                CubicKeyframe(2.3, duration: 0.11)
                CubicKeyframe(-1.8, duration: 0.11)
                CubicKeyframe(1.2, duration: 0.11)
                CubicKeyframe(-0.6, duration: 0.11)
                CubicKeyframe(0, duration: 0.12)
            }
            .onAppear {
                guard !reduceMotion else { return }
                shakeTrigger += 1
            }
    }
}

/// The expanded module: status, the shortcut, and the last transcript with a
/// copy button for when the clipboard has since been overwritten.
struct VoiceDictationModuleView: View {
    @ObservedObject var controller: VoiceDictationController
    @State private var redoing: VoiceDictationCleanupLevel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(controller.settings.voiceDictationHotkey.displayString)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(10)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))

            if controller.phase.isBusy {
                Button("Cancel") { controller.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if let suggestion = controller.correctionSuggestions.first, !controller.phase.isBusy {
                VStack(alignment: .leading, spacing: 7) {
                    Group {
                        switch suggestion.kind {
                        case .word:
                            Text("You changed ")
                                + Text("“\(suggestion.spoken)”").foregroundColor(.white.opacity(0.6))
                                + Text(" to ")
                                + Text("“\(suggestion.written)”").bold()
                                + Text(" \(suggestion.count) times. Remember it?")
                        case .leaveOut:
                            Text("You deleted ") + Text("“\(suggestion.spoken)”").bold()
                                + Text(" \(suggestion.count) times. Leave it out from now on?")
                        case .changeOfMind:
                            Text("You said ") + Text("“\(suggestion.spoken)”").bold()
                                + Text(" and deleted what came before it \(suggestion.count) times. Treat it as changing your mind?")
                        }
                    }
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Remember") { controller.acceptCorrection(suggestion) }
                            .buttonStyle(.borderedProminent)
                        Button("Not now") { controller.dismissCorrection(suggestion) }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
                .padding(10)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
            }

            // A failure is cleared when the next dictation starts, so when one
            // is present it is newer than the transcript below it.
            if let error = controller.lastError {
                VStack(alignment: .leading, spacing: 3) {
                    Text(error.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(error.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let result = controller.lastResult {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Last transcript")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Button {
                            controller.pasteLastResult()
                        } label: {
                            Label("Paste again", systemImage: "arrow.uturn.down")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.nanoPress)
                        .foregroundStyle(.white.opacity(0.7))
                        .disabled(controller.phase.isBusy)
                        .help("Paste it again into the app it went to")
                        Button {
                            controller.copyLastResult()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.nanoPress)
                        .foregroundStyle(.white.opacity(0.7))
                    }
                    Text(result.finalText)
                        .font(.system(size: 12))
                        .lineLimit(5)
                        .textSelection(.enabled)
                    if controller.settings.voiceDictationEngine.appliesCleanup, !result.rawTranscript.isEmpty,
                       !controller.phase.isBusy {
                        HStack(spacing: 6) {
                            Text("Redo as")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                            ForEach(VoiceDictationCleanupLevel.allCases.filter { $0 != result.cleanupLevel }) { level in
                                Button {
                                    redoing = level
                                    Task {
                                        _ = try? await controller.redoLast(as: level)
                                        redoing = nil
                                    }
                                } label: {
                                    Text(redoing == level ? "…" : level.title)
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 8)
                                        .frame(height: 20)
                                        .background(.white.opacity(0.1), in: Capsule())
                                }
                                .buttonStyle(.nanoPress)
                                .disabled(redoing != nil)
                                .help("Clean it up again as \(level.title) and copy it")
                            }
                        }
                    }
                    Text(metricsLine(result))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                }
                .padding(10)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
            } else if controller.lastError == nil {
                Text(controller.settings.voiceDictationActivationMode.detail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var statusColor: Color {
        switch controller.phase {
        case .idle: controller.readiness.isReady ? .green : .white.opacity(0.22)
        case .recording: .red
        case .transcribing, .cleaning: .yellow
        case .completed: .green
        case .failed: .orange
        case .cancelled: VoiceDictationCancelMotion.tint
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .idle:
            switch controller.readiness {
            case .ready: "Ready · \(controller.settings.voiceDictationEngine.title)"
            case .disabled: "Off"
            case .missingModels: "Engine not downloaded"
            case .microphoneDenied: "Microphone access denied"
            case .microphoneUndetermined: "Microphone access needed"
            }
        default:
            controller.phase == .completed ? (controller.lastPasteOutcome?.detail ?? controller.deliveryTitle) : controller.phase.title
        }
    }

    private func metricsLine(_ result: VoiceDictationResult) -> String {
        let metrics = result.metrics
        var parts = [
            String(format: "%.0f ms stop→clipboard", metrics.stopToClipboard * 1000),
            String(format: "asr %.0f ms", metrics.transcription * 1000),
        ]
        if result.cleanupApplied {
            parts.append(String(format: "cleanup %.0f ms", metrics.cleanup * 1000))
            if result.guardedChunks > 0 {
                parts.append("kept wording ×\(result.guardedChunks)")
            }
            if result.cleanupFallbacks > 0 {
                parts.append("cleanup skipped ×\(result.cleanupFallbacks)")
            }
        }
        if metrics.wasColdStart {
            parts.append(String(format: "load %.1f s", metrics.modelLoad))
        }
        if result.appContext != .general {
            parts.append(result.appContext.title.lowercased())
        }
        if let language = result.language, language != "en" {
            parts.append(VoiceDictationLanguage.name(for: language))
        }
        if !result.boostedTerms.isEmpty {
            parts.append("heard \(result.boostedTerms.joined(separator: ", "))")
        }
        if result.segmentsProcessedEarly > 0 {
            parts.append("\(result.segmentsProcessedEarly) early")
        }
        return parts.joined(separator: " · ")
    }
}

/// Dictation's place in the control bar under the expanded island. The compact
/// island's recording indicator disappears as soon as a module opens; this
/// keeps "the mic is on" visible over Cue, sessions, or anything else.
/// Draws nothing while idle, and its width must match
/// `IslandChromeMetrics.voiceWidth`, which the hit area is built from.
struct VoiceDictationChromeSlot<Surface: View>: View {
    @ObservedObject var controller: VoiceDictationController
    let surface: () -> Surface
    let borderOpacity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    private static var recordingTint: Color { Color(red: 1.0, green: 0.36, blue: 0.34) }

    var body: some View {
        if controller.phase != .idle {
            content
                .padding(.horizontal, 7)
                .frame(width: IslandChromeMetrics.voiceWidth, height: IslandChromeMetrics.height)
                .background { surface() }
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(
                        controller.phase == .recording
                            ? Self.recordingTint.opacity(0.45)
                            : .white.opacity(borderOpacity),
                        lineWidth: 0.75
                    )
                }
                .shadow(color: .black.opacity(0.34), radius: 9, y: 4)
                .foregroundStyle(.white)
                .transition(.nanoRise(reduceMotion: reduceMotion))
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: controller.phase)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Quill, \(controller.phase.title)")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .recording:
            HStack(spacing: 0) {
                circleButton("xmark", help: "Cancel dictation", filled: false) { controller.cancel() }
                Spacer(minLength: 4)
                HStack(spacing: 7) {
                    Circle()
                        .fill(Self.recordingTint)
                        .frame(width: 7, height: 7)
                        .nanoBreathe(active: !reduceMotion)
                    VoiceDictationFlowWaveform(recorder: controller.recorder, width: 84, height: 20)
                }
                Spacer(minLength: 4)
                circleButton("checkmark", help: "Finish dictation", filled: true) { controller.finishRecording() }
            }
        case .transcribing, .cleaning:
            HStack(spacing: 8) {
                Circle()
                    .fill(.white.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(controller.phase == .cleaning ? "Cleaning up" : "Transcribing")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 0)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            .padding(.leading, 8)
        case .completed:
            HStack(spacing: 6) {
                Circle()
                    .fill(.white.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(controller.lastResult?.finalText ?? controller.deliveryTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let text = controller.lastResult?.finalText, !text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.1), in: Circle())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.nanoPress)
                    .help("Copy transcript")
                }
            }
            .padding(.leading, 8)
            .onDisappear { copied = false }
        case .failed, .cancelled:
            HStack(spacing: 7) {
                Image(systemName: controller.phase == .cancelled ? "xmark" : "mic.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VoiceDictationCancelMotion.tint)
                Text(controller.phase == .cancelled
                    ? "Cancelled"
                    : (controller.lastError?.title ?? "Dictation failed"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
        case .idle:
            EmptyView()
        }
    }

    private func circleButton(
        _ symbol: String,
        help: String,
        filled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(filled ? Color.black.opacity(0.85) : .white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.white.opacity(0.12)), in: Circle())
        }
        .buttonStyle(.nanoPress)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The compact island's right-hand badge while dictation shares the island
/// with running agents: a live recorder in the same capsule shape as the
/// "Working" chip it replaces.
struct VoiceDictationRecordingBadge: View {
    @ObservedObject var controller: VoiceDictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var tint: Color { Color(red: 1.0, green: 0.36, blue: 0.34) }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Self.tint)
                .frame(width: 6, height: 6)
                .nanoBreathe(active: !reduceMotion)
            VoiceDictationFlowWaveform(recorder: controller.recorder, width: 52, height: 15)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .overlay(Capsule().stroke(Self.tint.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictation recording")
    }
}

/// A scrolling history of the voice level (after ElevenLabs' waveform): the
/// newest sample enters on the right and older ones drift left and fade out.
///
/// Cost: one `Canvas` redraw per level update, which the recorder publishes
/// at 12Hz and only while recording. No timeline, no animation loop.
struct VoiceDictationFlowWaveform: View {
    @ObservedObject var recorder: VoiceDictationAudioRecorder
    var width: CGFloat
    var height: CGFloat
    @Environment(\.nanoMotionBudget) private var budget

    var body: some View {
        // Per-frame drawing lives in its own host so the island isn't laid
        // out again every frame. Environment doesn't cross that boundary, so
        // the budget is passed in.
        NanoIsolatedHost(side: width, height: height) {
            VoiceDictationFlowWaveformCanvas(recorder: recorder, width: width, height: height, isHidden: budget.isPaused)
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// Bars scroll left as levels arrive. Levels come 12 times a second; stepping
/// the strip once per level read as stutter, so between levels the strip
/// slides continuously and the newest bar grows into place.
private struct VoiceDictationFlowWaveformCanvas: View {
    @ObservedObject var recorder: VoiceDictationAudioRecorder
    var width: CGFloat
    var height: CGFloat
    var isHidden: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var samples: [Double] = []
    @State private var sampledAt = Date()

    private static let barWidth: CGFloat = 2.4
    private static let gap: CGFloat = 1.6
    /// The recorder's level interval.
    private static let tick: Double = 1.0 / 12.0

    private var capacity: Int { max(Int(width / (Self.barWidth + Self.gap)), 4) }

    var body: some View {
        // While recording this is where the user is looking, so it runs at
        // display rate; it stops when recording ends or nothing can see it.
        TimelineView(.animation(
            minimumInterval: isHidden ? 1 : 1.0 / 60,
            paused: isHidden || reduceMotion || !recorder.isRecording
        )) { context in
            let elapsed = context.date.timeIntervalSince(sampledAt)
            let progress = reduceMotion ? 1 : min(max(elapsed / Self.tick, 0), 1)
            Canvas { canvas, size in
                draw(in: &canvas, size: size, progress: progress)
            }
        }
        .frame(width: width, height: height)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.3),
                    .init(color: .white, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .onChange(of: recorder.inputLevel, initial: true) { _, level in
            var next = samples
            next.append(VoiceDictationWaveform.displayLevel(level))
            if next.count > capacity + 1 { next.removeFirst(next.count - capacity - 1) }
            samples = next
            sampledAt = Date()
        }
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, progress: Double) {
        let step = Self.barWidth + Self.gap
        // One bar more than fits: the newest one slides in from the right edge.
        let count = capacity + 1
        let padded = Array(repeating: 0.0, count: max(count - samples.count, 0)) + samples.suffix(count)
        // Ease out, so each shift settles rather than moving at a constant rate.
        let eased = 1 - pow(1 - progress, 3)
        for (index, level) in padded.enumerated() {
            let isNewest = index == padded.count - 1
            let shown = isNewest ? level * eased : level
            let barHeight = VoiceDictationWaveform.barHeight(for: shown, maximum: size.height)
            let x = (CGFloat(index) - CGFloat(eased)) * step
            guard x > -step, x < size.width else { continue }
            let rect = CGRect(x: x, y: (size.height - barHeight) / 2, width: Self.barWidth, height: barHeight)
            canvas.fill(Path(roundedRect: rect, cornerRadius: Self.barWidth / 2), with: .color(.white.opacity(0.88)))
        }
    }
}

/// Live preview: the words heard so far, in a caption above the Dock while
/// recording. Drag it anywhere; it stays where it was put. It never takes
/// focus from the app being dictated into.
@MainActor
final class VoiceDictationCaptionPanel {
    private var panel: NSPanel?
    private var controller: NSHostingController<VoiceDictationCaption>?
    private var container: CaptionDragView?
    private var isShowing = false

    static let width: CGFloat = 560
    var currentFrame: CGRect? { panel?.frame }
    var dragView: CaptionDragView? { container }
    private static let originKey = "voiceDictation.captionOrigin"

    func show(_ text: String) {
        guard !text.isEmpty, let screen = NSScreen.main else {
            hide()
            return
        }
        let panel = panel ?? makePanel(text: text)
        let caption = VoiceDictationCaption(text: text)
        controller?.rootView = caption
        // Measured from the new text, not read back from the view, which
        // still has the old layout at this point.
        let fitted = controller?.sizeThatFits(in: CGSize(width: Self.width, height: 400)).height ?? 44
        let size = CGSize(width: Self.width, height: ceil(fitted))

        guard !isShowing else {
            // Grows upward from its bottom edge as lines are added.
            guard panel.frame.size != size, !(container?.isDragging ?? false) else { return }
            var frame = panel.frame
            frame.size = size
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
            return
        }
        isShowing = true
        let frame = CGRect(origin: origin(for: size, on: screen), size: size)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        place(panel, reduceMotion ? frame : frame.offsetBy(dx: 0, dy: -6))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
    }

    func hide() {
        guard let panel, isShowing else { return }
        isShowing = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.isShowing == false else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func makePanel(text: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Inside a plain container the hosting view can't resize the window
        // itself; only `show` sizes it, so the bottom edge stays put.
        let controller = NSHostingController(rootView: VoiceDictationCaption(text: text))
        controller.sizingOptions = []
        let container = CaptionDragView(frame: CGRect(x: 0, y: 0, width: Self.width, height: 44))
        container.onDragEnded = { [weak self] in self?.remember() }
        controller.view.frame = container.bounds
        controller.view.autoresizingMask = [.width, .height]
        container.addSubview(controller.view)
        panel.contentView = container
        self.panel = panel
        self.controller = controller
        self.container = container
        return panel
    }

    private func place(_ panel: NSPanel, _ frame: CGRect) {
        panel.setFrame(frame, display: true)
    }

    /// Where the user last dragged it, if that is still on a screen;
    /// otherwise centred just above the Dock.
    private func origin(for size: CGSize, on screen: NSScreen) -> CGPoint {
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], saved.count == 2 {
            let point = CGPoint(x: saved[0], y: saved[1])
            let frame = CGRect(origin: point, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame.insetBy(dx: size.width / 3, dy: 0)) }) {
                return point
            }
        }
        let visible = screen.visibleFrame
        return CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 28)
    }

    private func remember() {
        guard let origin = panel?.frame.origin else { return }
        UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: Self.originKey)
    }
}

/// Takes every click on the caption and moves its window with the pointer.
/// The panel never becomes key, so the window server's own background drag
/// doesn't apply; the move is done here.
final class CaptionDragView: NSView {
    var onDragEnded: (() -> Void)?
    private(set) var isDragging = false
    private var grab = CGPoint.zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        isDragging = true
        grab = event.locationInWindow
        window.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let window else { return }
        let pointer = CGPoint(
            x: window.frame.minX + event.locationInWindow.x,
            y: window.frame.minY + event.locationInWindow.y
        )
        window.setFrameOrigin(CGPoint(x: pointer.x - grab.x, y: pointer.y - grab.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        window?.invalidateCursorRects(for: self)
        onDragEnded?()
    }
}

struct VoiceDictationCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.94))
            .lineLimit(3)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(width: VoiceDictationCaptionPanel.width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.84))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.1))
                }
        }
        .help("Drag to move")
    }
}
