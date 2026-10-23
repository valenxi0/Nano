import AppKit
import SwiftUI

private enum MixerMotion {
    static func quick(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.15)
    }

    static func fast(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.25)
    }

    static func fastOut(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : NanoMotion.smooth(0.25)
    }

    static func rowChange(_ reduceMotion: Bool, inserting: Bool) -> Animation? {
        inserting ? fastOut(reduceMotion) : quick(reduceMotion)
    }
}

private struct MixerRowPhase: ViewModifier {
    var opacity: Double
    var offset: CGFloat
    var blur: CGFloat

    func body(content: Content) -> some View {
        content.opacity(opacity).offset(y: offset).blur(radius: blur)
    }
}

extension AnyTransition {
    static var mixerRow: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: MixerRowPhase(opacity: 0, offset: 8, blur: 2),
                identity: MixerRowPhase(opacity: 1, offset: 0, blur: 0)
            ),
            removal: .opacity
        )
    }

    static var mixerRoutedSubtitle: AnyTransition {
        .modifier(
            active: MixerRowPhase(opacity: 0, offset: 4, blur: 0),
            identity: MixerRowPhase(opacity: 1, offset: 0, blur: 0)
        )
    }
}

struct MixerModuleView: View {
    @ObservedObject var store: MixerStore
    @ObservedObject var system: SystemStatusService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousRowIDs: [String] = []

    var body: some View {
        Group {
            if !store.isConfigured {
                MixerConnectionView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                configured
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            system.monitorsVolume = true
            system.refresh()
            store.refresh()
        }
    }

    private var configured: some View {
        VStack(spacing: 10) {
            outputRow
            hairline
            if let error = store.error {
                errorLine(error) { store.retry() }
            }
            appsHeader
            appsList
            if store.inputName != nil {
                hairline
                micRow
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
    }

    private var outputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: currentOutput.kind.symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Menu {
                    ForEach(store.outputs) { output in
                        Button {
                            store.selectOutput(output)
                            system.refresh()
                        } label: {
                            if output.id == store.outputID {
                                Label(output.name, systemImage: "checkmark")
                            } else {
                                Text(output.name)
                            }
                        }
                    }
                } label: {
                    Text(store.outputName)
                        .font(.system(size: 13, weight: .semibold))
                    + Text(" ")
                    + Text(Image(systemName: "chevron.down"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Output device")
                Text(currentOutput.kind.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .help("Change the Mac's output device")

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if let volume = system.outputVolume {
                    MixerFader(
                        value: Binding(get: { system.outputVolume ?? volume },
                                       set: { system.setOutputVolume($0) }),
                        maxValue: 1,
                        muted: system.isMuted,
                        label: "Output volume"
                    )
                    Text(system.isMuted ? "Muted" : "\(Int((volume * 100).rounded()))%")
                        .font(.system(size: 11)).monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                        .contentTransition(.numericText())
                        .animation(MixerMotion.quick(reduceMotion),
                                   value: system.isMuted ? -1 : Int((volume * 100).rounded()))
                    // Matches the route button width in app rows so all fader
                    // tracks end at the same x.
                    Color.clear.frame(width: store.outputs.count > 1 ? 26 : 0, height: 26)
                } else {
                    Text("Volume is set on the device")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                    Color.clear.frame(width: store.outputs.count > 1 ? 26 : 0, height: 26)
                }

                if system.outputMuteSettable {
                    Button { system.setOutputMuted(!system.isMuted) } label: {
                        Image(systemName: system.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(system.isMuted ? Color(red: 1, green: 0.42, blue: 0.4) : .white)
                            .frame(width: 26, height: 26)
                            .background(.white.opacity(0.08), in: Circle())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .animation(MixerMotion.fast(reduceMotion), value: system.isMuted)
                    .accessibilityLabel(system.isMuted ? "Unmute output" : "Mute output")
                } else {
                    Color.clear.frame(width: 26, height: 26)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
    }

    private var currentOutput: MixerOutput {
        store.outputs.first { $0.id == store.outputID }
            ?? MixerOutput(id: store.outputID, uid: "", name: store.outputName, kind: .other)
    }

    private var appsHeader: some View {
        HStack {
            Text("APPS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.4))
            Spacer()
            Button { store.showsAllApps.toggle() } label: {
                Text(store.showsAllApps ? "Active only" : "Show all")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .nanoHoverCapsule()
            }
            .buttonStyle(.plain)
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private var appsList: some View {
        let rowIDs = store.visibleApps.map(\.id)
        Group {
            if store.visibleApps.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("Play something and it shows up here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .transition(.opacity)
            } else {
                let rows = ForEach(store.visibleApps) { app in
                    MixerAppRow(app: app, store: store)
                        .transition(.mixerRow)
                }
                if store.showsAllApps && store.visibleApps.count > 5 {
                    ScrollView {
                        LazyVStack(spacing: 2) { rows }
                    }
                    .scrollIndicators(.never)
                    .frame(height: 5 * 40 + 4 * 2)
                } else {
                    VStack(spacing: 2) { rows }
                }
            }
        }
        .animation(
            MixerMotion.rowChange(reduceMotion, inserting: rowIDs.count > previousRowIDs.count),
            value: rowIDs
        )
        .onChange(of: rowIDs) { _, newIDs in previousRowIDs = newIDs }
    }

    private var micRow: some View {
        HStack(spacing: 10) {
            Image(systemName: store.isMicMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(store.isMicMuted ? Color(red: 1, green: 0.42, blue: 0.4) : .white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .contentTransition(.symbolEffect(.replace))
                .animation(MixerMotion.fast(reduceMotion), value: store.isMicMuted)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.inputName ?? "Microphone")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text("Microphone")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Button { store.toggleMicMute() } label: {
                ZStack {
                    Text("Mute")
                        .opacity(store.isMicMuted ? 0 : 1)
                        .offset(y: store.isMicMuted ? -4 : 0)
                        .blur(radius: store.isMicMuted ? 2 : 0)
                    Text("Muted")
                        .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.45))
                        .opacity(store.isMicMuted ? 1 : 0)
                        .offset(y: store.isMicMuted ? 0 : 4)
                        .blur(radius: store.isMicMuted ? 0 : 2)
                }
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 64, height: 26)
                .background(
                    store.isMicMuted
                        ? Color(red: 1, green: 0.35, blue: 0.32).opacity(0.22)
                        : .white.opacity(0.08),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .animation(MixerMotion.quick(reduceMotion), value: store.isMicMuted)
            .accessibilityLabel(store.isMicMuted ? "Unmute microphone" : "Mute microphone")
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
    }

    private func errorLine(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(message)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Retry", action: retry).buttonStyle(.plain).underline()
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.orange)
    }
}

private struct MixerAppRow: View {
    let app: MixerApp
    @ObservedObject var store: MixerStore
    @State private var isHovered = false
    @State private var draggingVolume = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var routed: Bool { app.preference.outputUID != nil }

    private var appSubtitle: String {
        var parts: [String] = []
        if !app.isRunning { parts.append("Paused") }
        if let uid = app.preference.outputUID {
            let name = store.outputs.first { $0.uid == uid }?.name ?? "another output"
            parts.append("→ \(name)")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Group {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "app.fill").resizable()
                    }
                }
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(app.name).lineLimit(1)
                            .font(.system(size: 12.5, weight: .medium))
                        if app.preference.isPinned {
                            Image(systemName: "pin.fill").font(.system(size: 8))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    if !app.isRunning || routed {
                        Text(appSubtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                            .transition(.mixerRoutedSubtitle)
                    }
                }
                .frame(width: 132, alignment: .leading)
                .animation(MixerMotion.fastOut(reduceMotion), value: routed)

                MixerFader(
                    value: Binding(get: { app.preference.volume },
                                   set: { store.setVolume($0, for: app.id) }),
                    maxValue: 2,
                    muted: app.preference.isMuted,
                    label: "\(app.name) volume"
                ) { draggingVolume = $0 }

                Text("\(Int((app.preference.volume * 100).rounded()))%")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(
                        app.preference.isMuted
                            ? .white.opacity(0.4)
                            : app.preference.volume > 1
                                ? Color(red: 1, green: 0.62, blue: 0.25)
                                : .white
                    )
                    .frame(width: 40, alignment: .trailing)
                    .contentTransition(draggingVolume ? .identity : .numericText())
                    .animation(
                        draggingVolume ? nil : MixerMotion.quick(reduceMotion),
                        value: app.preference.isMuted ? -1 : Int((app.preference.volume * 100).rounded())
                    )

                if store.outputs.count > 1 {
                    routeMenu
                }

                Button { store.toggleMute(app.id) } label: {
                    Image(systemName: app.preference.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(app.preference.isMuted ? Color(red: 1, green: 0.42, blue: 0.4) : .white)
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.08), in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .animation(MixerMotion.fast(reduceMotion), value: app.preference.isMuted)
                .accessibilityLabel("\(app.preference.isMuted ? "Unmute" : "Mute") \(app.name)")
                .help(app.preference.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
            }
            .frame(height: 40)
            .padding(.horizontal, 6)
            .background(.white.opacity(isHovered ? 0.04 : 0), in: RoundedRectangle(cornerRadius: 10))
            .onHover { hovering in
                withAnimation(hovering ? MixerMotion.quick(reduceMotion) : MixerMotion.fast(reduceMotion)) {
                    isHovered = hovering
                }
            }

            if let error = app.error {
                HStack(spacing: 6) {
                    Text(error).lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Retry") { store.retry() }.buttonStyle(.plain).underline()
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
            }
        }
        .contextMenu {
            Button(app.preference.isPinned ? "Unpin app" : "Pin app", systemImage: "pin") { store.togglePin(app.id) }
            Button("Reset volume", systemImage: "arrow.counterclockwise") { store.reset(app.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: app.preference.isPinned ? "Unpin app" : "Pin app") { store.togglePin(app.id) }
        .accessibilityAction(named: "Reset volume") { store.reset(app.id) }
    }

    private var routeMenu: some View {
        Menu {
            Button {
                store.setOutput(nil, for: app.id)
            } label: {
                if routed {
                    Text("System output (\(store.outputName))")
                } else {
                    Label("System output (\(store.outputName))", systemImage: "checkmark")
                }
            }
            ForEach(store.outputs) { output in
                if output.hasInput {
                    Text("\(output.name) (has a microphone)")
                } else {
                    Button {
                        store.setOutput(output.uid, for: app.id)
                    } label: {
                        if app.preference.outputUID == output.uid {
                            Label(output.name, systemImage: "checkmark")
                        } else {
                            Text(output.name)
                        }
                    }
                }
            }
        } label: {
            Text(Image(systemName: "arrow.triangle.branch"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(
                    routed
                        ? Color(red: 1, green: 0.62, blue: 0.25)
                        : .white.opacity(0.4)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 26, height: 26)
        .fixedSize()
        .animation(MixerMotion.fastOut(reduceMotion), value: routed)
        .help("Send \(app.name) to a different output")
        .accessibilityLabel("\(app.name) output")
    }
}

/// Custom fader so boost past 100% can be drawn, snapped to, and announced.
private struct MixerFader: View {
    @Binding var value: Double
    var maxValue: Double = 1
    var muted = false
    let label: String
    var onEditingChanged: ((Bool) -> Void)?

    @State private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var boostTint: Color { Color(red: 1, green: 0.62, blue: 0.25) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat(min(max(value / maxValue, 0), 1))
            let unity = CGFloat(1 / maxValue)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(height: 4)
                if maxValue > 1 {
                    Rectangle()
                        .fill(boostTint.opacity(0.12))
                        .frame(width: width * (1 - unity), height: 4)
                        .offset(x: width * unity)
                    Rectangle()
                        .fill(.white.opacity(0.3))
                        .frame(width: 1, height: 8)
                        .offset(x: width * unity - 0.5)
                }
                if fraction > 0 {
                    Capsule()
                        .fill(.white.opacity(muted ? 0.3 : 0.9))
                        .frame(width: max(width * min(fraction, unity), 4), height: 4)
                    Capsule()
                        .fill(boostTint)
                        .frame(width: max(width * max(fraction - unity, 0), 1), height: 4)
                        .offset(x: width * unity)
                        .opacity(fraction > unity ? 1 : 0)
                }
                Circle()
                    .fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .scaleEffect(dragging && !reduceMotion ? 1.12 : 1)
                    .offset(x: max(min(width * fraction - 7, width - 14), 0))
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .animation(MixerMotion.quick(reduceMotion), value: muted)
            .animation(MixerMotion.quick(reduceMotion), value: fraction > unity)
            .animation(
                dragging ? MixerMotion.fastOut(reduceMotion) : MixerMotion.quick(reduceMotion),
                value: dragging
            )
            // Value tracks the finger 1:1; only non-drag changes animate.
            .animation(dragging ? nil : MixerMotion.quick(reduceMotion), value: value)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging { dragging = true; onEditingChanged?(true) }
                        setFromX(gesture.location.x, width: width)
                    }
                    .onEnded { _ in dragging = false; onEditingChanged?(false) }
            )
        }
        .frame(height: 24)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let step = direction == .left ? -0.05 : direction == .right ? 0.05 : 0
            guard step != 0 else { return }
            value = min(max(value + step, 0), maxValue)
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent\(muted ? ", muted" : "")")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 0.05, maxValue)
            case .decrement: value = max(value - 0.05, 0)
            default: break
            }
        }
        .help(label)
    }

    private func setFromX(_ x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        var next = Double(x / width) * maxValue
        if maxValue > 1, abs(next - 1) < 0.04 { next = 1 }
        value = min(max(next, 0), maxValue)
    }
}

private struct MixerConnectionView: View {
    @ObservedObject var store: MixerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            Text("Give every app its own volume")
                .font(.system(size: 15, weight: .semibold))
            Text("macOS will ask to let Nano access system audio. Audio is adjusted live in memory and never saved or sent.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button(store.isConnecting ? "Connecting…" : "Allow audio access") { store.connect() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white, in: Capsule())
                    .disabled(store.isConnecting || !store.isEnabled)
                Button("Open Privacy Settings") { store.openAudioPrivacy() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if let error = store.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }
}

struct MixerSettingsPane: View {
    @ObservedObject var settings: NanoSettings
    @ObservedObject var store: MixerStore
    @ObservedObject var viewModel: IslandViewModel
    let openMixer: () -> Void
    @StateObject private var hotkeyCapture = VoiceDictationHotkeyCapture()

    private var adjustedApps: [MixerApp] {
        store.apps.filter { $0.preference.needsProcessing || $0.preference.isPinned }
    }

    var body: some View {
        SettingsPage(title: "Mixer", symbol: "slider.vertical.3",
                     subtitle: "Give every app its own volume.") {
            SettingsSection("Mixer", footer: "Apps you adjust in the Mixer appear here.") {
                SettingsToggleRow("Enable Mixer", subtitle: "Per-app volume stays active while Nano runs.",
                    isOn: Binding(get: { settings.isEnabled(.mixer) }, set: { settings.setEnabled($0, for: .mixer) }))
                if settings.isEnabled(.mixer) {
                    SettingsRow("Open Mixer") {
                        Button("Open", action: openMixer).controlSize(.small)
                    }
                }
            }
            SettingsSection("Shortcuts") {
                SettingsRow(
                    "Mute microphone",
                    symbol: "mic.slash",
                    subtitle: micShortcutDetail,
                    subtitleIsWarning: viewModel.mixerMicMuteHotkeyError != nil || micShortcutClashes
                ) {
                    if settings.mixerMicMuteHotkeyEnabled {
                        if settings.mixerMicMuteHotkey != .mixerMicMuteDefault {
                            Button("Reset") { settings.mixerMicMuteHotkey = .mixerMicMuteDefault }
                                .controlSize(.small)
                        }
                        Button {
                            if hotkeyCapture.isCapturing {
                                hotkeyCapture.end()
                            } else {
                                hotkeyCapture.begin { hotkey in
                                    if let hotkey { settings.mixerMicMuteHotkey = hotkey }
                                }
                            }
                        } label: {
                            Text(hotkeyCapture.isCapturing
                                 ? "Recording…"
                                 : settings.mixerMicMuteHotkey.displayString)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .frame(minWidth: 64)
                        }
                        .controlSize(.small)
                    }
                    Toggle("Mute microphone", isOn: $settings.mixerMicMuteHotkeyEnabled)
                        .labelsHidden()
                        .toggleStyle(HeroSwitchToggleStyle(showsLabel: false))
                }
            }
            SettingsSection("Audio access", footer: "Audio is adjusted live in memory. Nothing is recorded or sent.") {
                SettingsRow("System audio",
                            subtitle: store.isConfigured
                                ? "Connected"
                                : "Not connected · macOS asks the first time") {
                    if store.isConfigured {
                        Button("Privacy Settings") { store.openAudioPrivacy() }.controlSize(.small)
                    } else {
                        Button(store.isConnecting ? "Connecting…" : "Allow audio access") { store.connect() }
                            .controlSize(.small)
                            .disabled(store.isConnecting || !settings.isEnabled(.mixer))
                    }
                }
                if let error = store.error, !store.isConfigured {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
            }
            if !adjustedApps.isEmpty {
                SettingsSection("Adjusted apps") {
                    ForEach(adjustedApps) { app in
                        adjustedRow(app)
                    }
                    if adjustedApps.count >= 2 {
                        HStack {
                            Spacer(minLength: 0)
                            Button("Reset all") { adjustedApps.forEach { store.reset($0.id) } }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .onDisappear { hotkeyCapture.end() }
    }

    private var micShortcutClashes: Bool {
        settings.mixerMicMuteHotkeyEnabled
            && (settings.mixerMicMuteHotkey == settings.voiceDictationHotkey
                || settings.mixerMicMuteHotkey == settings.cueQuickCaptureHotkey)
    }

    private var micShortcutDetail: String {
        if hotkeyCapture.isCapturing { return "Press the new shortcut. Esc cancels." }
        if let error = viewModel.mixerMicMuteHotkeyError { return error }
        if micShortcutClashes {
            return settings.mixerMicMuteHotkey == settings.voiceDictationHotkey
                ? "Same as the dictation shortcut. Pick a different one so both work."
                : "Same as the Cue shortcut. Pick a different one so both work."
        }
        return "Mutes every microphone, anywhere"
    }

    private func adjustedRow(_ app: MixerApp) -> some View {
        HStack(spacing: 11) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.fill").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 13, weight: .medium))
                Text(subtitle(for: app))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { store.togglePin(app.id) } label: {
                Image(systemName: app.preference.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(app.preference.isPinned ? "Unpin \(app.name)" : "Pin \(app.name)")
            Button("Reset") { store.reset(app.id) }.controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 42)
    }

    private func subtitle(for app: MixerApp) -> String {
        var parts = [app.preference.isMuted ? "Muted" : "\(Int((app.preference.volume * 100).rounded()))%"]
        if let uid = app.preference.outputUID,
           let output = store.outputs.first(where: { $0.uid == uid }) {
            parts.append("→ \(output.name)")
        }
        if app.preference.isPinned { parts.append("Pinned") }
        return parts.joined(separator: " · ")
    }
}
