import AppKit
import Combine
import CoreAudio
import Darwin

struct MixerPreference: Equatable {
    var volume: Double = 1
    var isMuted = false
    var isPinned = false
    var name: String = ""
    /// nil follows the system output; a device UID pins the app to that output.
    var outputUID: String?

    var gain: Float { isMuted ? 0 : Float(volume.isFinite ? min(2, max(0, volume)) : 1) }
    var needsProcessing: Bool { isMuted || gain != 1 || outputUID != nil }
}

extension MixerPreference: Codable {
    private enum CodingKeys: String, CodingKey {
        case volume, isMuted, isPinned, name, outputUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        outputUID = try container.decodeIfPresent(String.self, forKey: .outputUID)
    }
}

struct MixerApp: Identifiable {
    let id: String
    var name: String
    var icon: NSImage?
    var processes: [AudioObjectID]
    var isRunning: Bool
    var preference: MixerPreference
    var error: String?
}

struct MixerOutput: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let kind: Kind
    /// Devices with input streams (headsets) cannot be per-app route targets:
    /// their physical mic stream joins the aggregate and the mic would run.
    var hasInput: Bool = false

    enum Kind: Equatable {
        case builtIn, bluetooth, usb, hdmi, displayPort, airPlay, virtual, aggregate, other

        init(transport: UInt32) {
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeUSB: self = .usb
            case kAudioDeviceTransportTypeHDMI: self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
            case kAudioDeviceTransportTypeAirPlay: self = .airPlay
            case kAudioDeviceTransportTypeVirtual: self = .virtual
            case kAudioDeviceTransportTypeAggregate: self = .aggregate
            default: self = .other
            }
        }

        var label: String {
            switch self {
            case .builtIn: "Built-in"
            case .bluetooth: "Bluetooth"
            case .usb: "USB"
            case .hdmi: "HDMI"
            case .displayPort: "DisplayPort"
            case .airPlay: "AirPlay"
            case .virtual: "Virtual"
            case .aggregate: "Aggregate"
            case .other: "Audio device"
            }
        }

        var symbol: String {
            switch self {
            case .builtIn: "speaker.wave.2.fill"
            case .bluetooth: "headphones"
            case .usb: "cable.connector"
            case .hdmi, .displayPort: "display"
            case .airPlay: "airplayaudio"
            case .virtual: "waveform"
            case .aggregate: "square.stack.3d.up"
            case .other: "hifispeaker.fill"
            }
        }
    }
}

@MainActor
final class MixerStore: ObservableObject {
    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var outputs: [MixerOutput] = []
    @Published private(set) var outputID: AudioObjectID = 0
    @Published private(set) var error: String?
    @Published private(set) var isEnabled = false
    @Published private(set) var isConfigured: Bool
    @Published private(set) var isConnecting = false
    @Published private(set) var inputName: String?
    @Published private(set) var isMicMuted = false
    @Published var showsAllApps = false

    private let defaults: UserDefaults
    private var preferences: [String: MixerPreference]
    private let runtime = MixerRuntime()
    private var routeRevision = 0
    private var rebuildRoutes = false
    private var lastActive: [String: Date] = [:]
    private var activityExpiry: Task<Void, Never>?
    private var routeLingerExpiry: Task<Void, Never>?
    /// How long a quiet app's route stays up. See `reconcile()`.
    static let routeLinger: TimeInterval = 120
    private var listeners: [MixerAudioListener] = []
    private var processListeners: [MixerAudioListener] = []
    private var observedProcesses: Set<AudioObjectID> = []
    private var observedOutput: AudioObjectID = 0
    private var outputListeners: [MixerAudioListener] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var sleeping = false
    private var failures: [String: String] = [:]
    /// Prior input state Nano set while holding a mic mute, restored on unmute.
    /// Keyed by device UID and saved, so a mute outlives a crash or a kill
    /// only until the next launch puts the inputs back.
    private var heldMutes: [String: HeldInput] = [:]
    private enum HeldInput: Codable, Equatable {
        case mute(UInt32)
        case volume(Float)
    }
    private static let preferencesKey = "mixer.apps"
    private static let configuredKey = "mixer.configured"
    private static let heldMutesKey = "mixer.heldMicMutes"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = defaults.data(forKey: Self.preferencesKey)
            .flatMap { try? JSONDecoder().decode([String: MixerPreference].self, from: $0) } ?? [:]
        preferences = preferences.mapValues { preference in
            var preference = preference
            preference.volume = preference.volume.isFinite ? min(2, max(0, preference.volume)) : 1
            return preference
        }.filter { $0.value.needsProcessing || $0.value.isPinned }
        isConfigured = defaults.bool(forKey: Self.configuredKey)
    }

    var outputName: String { outputs.first { $0.id == outputID }?.name ?? "Choose output" }
    var visibleApps: [MixerApp] {
        let selected = apps.filter {
            showsAllApps || $0.isRunning || $0.preference.isPinned || $0.error != nil ||
            Date().timeIntervalSince(lastActive[$0.id] ?? .distantPast) < 8
        }
        return showsAllApps ? selected : Array(selected.prefix(4))
    }

    func setEnabled(_ enabled: Bool) {
        if !isEnabled { restorePersistedMutes() }
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            startMonitoring()
            refresh()
        } else {
            stop()
        }
    }

    func connect() {
        guard isEnabled, !isConnecting else { return }
        isConnecting = true
        error = nil
        // Allow the button state to draw before macOS presents its permission sheet.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { isConnecting = false }
            guard isEnabled else { return }
            do {
                try await runtime.connect(output: outputID)
                guard isEnabled else { return }
                isConfigured = true
                defaults.set(true, forKey: Self.configuredKey)
                retry()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func setVolume(_ value: Double, for id: String) {
        update(id) { preference in
            preference.volume = value.isFinite ? min(2, max(0, value)) : 1
            preference.isMuted = false
        }
    }

    func toggleMute(_ id: String) { update(id) { $0.isMuted.toggle() } }
    func togglePin(_ id: String) { update(id) { $0.isPinned.toggle() } }
    func setOutput(_ uid: String?, for id: String) { update(id) { $0.outputUID = uid } }

    func reset(_ id: String) {
        update(id) { $0.volume = 1; $0.isMuted = false; $0.outputUID = nil }
    }

    private func update(_ id: String, change: (inout MixerPreference) -> Void) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        var preference = apps[index].preference
        change(&preference)
        preference.name = apps[index].name
        // Only what differs from the default is worth keeping; otherwise
        // every app ever touched stayed in the stored list for good.
        if preference.needsProcessing || preference.isPinned {
            preferences[id] = preference
        } else {
            preferences.removeValue(forKey: id)
        }
        apps[index].preference = preference
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.preferencesKey) }
        failures[id] = nil
        reconcile()
    }

    func toggleMicMute() {
        if !heldMutes.isEmpty {
            restoreInputs()
        } else if let input = Self.defaultInput, Self.readsMuted(input) {
            // Muted by something else, and Nano holds nothing to put back:
            // muting a muted mic would record "muted" as the state to restore.
            try? MixerAudio.write(input, kAudioDevicePropertyMute, UInt32(0),
                scope: kAudioDevicePropertyScopeInput)
        } else {
            holdInputs()
        }
        updateInputState()
    }

    /// Mutes every input Nano is not already holding, remembering what to restore.
    private func holdInputs() {
        var changed = false
        for device in Self.inputDevices {
            guard let uid = MixerAudio.string(device, kAudioDevicePropertyDeviceUID),
                  heldMutes[uid] == nil else { continue }
            if MixerAudio.isSettable(device, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput) {
                let prior = (try? MixerAudio.read(device, kAudioDevicePropertyMute,
                    default: UInt32(0), scope: kAudioDevicePropertyScopeInput)) ?? 0
                try? MixerAudio.write(device, kAudioDevicePropertyMute, UInt32(1),
                    scope: kAudioDevicePropertyScopeInput)
                heldMutes[uid] = .mute(prior)
                changed = true
            } else if MixerAudio.isSettable(device, kAudioDevicePropertyVolumeScalar,
                                           scope: kAudioDevicePropertyScopeInput) {
                let prior = (try? MixerAudio.read(device, kAudioDevicePropertyVolumeScalar,
                    default: Float(1), scope: kAudioDevicePropertyScopeInput)) ?? 1
                try? MixerAudio.write(device, kAudioDevicePropertyVolumeScalar, Float(0),
                    scope: kAudioDevicePropertyScopeInput)
                heldMutes[uid] = .volume(prior)
                changed = true
            }
        }
        if changed { saveHeldMutes() }
    }

    private func restoreInputs() {
        guard !heldMutes.isEmpty else { return }
        var devices: [String: AudioObjectID] = [:]
        for device in Self.inputDevices {
            if let uid = MixerAudio.string(device, kAudioDevicePropertyDeviceUID) { devices[uid] = device }
        }
        for (uid, held) in heldMutes {
            guard let device = devices[uid] else { continue }
            switch held {
            case let .mute(prior):
                try? MixerAudio.write(device, kAudioDevicePropertyMute, prior,
                    scope: kAudioDevicePropertyScopeInput)
            case let .volume(prior):
                try? MixerAudio.write(device, kAudioDevicePropertyVolumeScalar, prior,
                    scope: kAudioDevicePropertyScopeInput)
            }
        }
        heldMutes.removeAll()
        saveHeldMutes()
    }

    private func saveHeldMutes() {
        if heldMutes.isEmpty {
            defaults.removeObject(forKey: Self.heldMutesKey)
        } else if let data = try? JSONEncoder().encode(heldMutes) {
            defaults.set(data, forKey: Self.heldMutesKey)
        }
    }

    /// A mute held when Nano was killed is still on the hardware. Put the
    /// inputs back, as a normal quit does.
    private func restorePersistedMutes() {
        guard heldMutes.isEmpty, let data = defaults.data(forKey: Self.heldMutesKey) else { return }
        guard let saved = try? JSONDecoder().decode([String: HeldInput].self, from: data) else {
            defaults.removeObject(forKey: Self.heldMutesKey)
            return
        }
        heldMutes = saved
        restoreInputs()
    }

    private static var defaultInput: AudioObjectID? {
        let device = (try? MixerAudio.read(MixerAudio.system,
            kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(0))) ?? 0
        return device == 0 ? nil : device
    }

    private static func readsMuted(_ device: AudioObjectID) -> Bool {
        ((try? MixerAudio.read(device, kAudioDevicePropertyMute,
            default: UInt32(0), scope: kAudioDevicePropertyScopeInput)) ?? 0) != 0
    }

    private static var inputDevices: [AudioObjectID] {
        MixerAudio.objects(MixerAudio.system, kAudioHardwarePropertyDevices).filter { id in
            guard let uid = MixerAudio.string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("com.nanoapp.mixer.") else { return false }
            return !MixerAudio.objects(id, kAudioDevicePropertyStreams,
                scope: kAudioDevicePropertyScopeInput).isEmpty
        }
    }

    private func updateInputState() {
        // A mic connected while a mute is held joins it, so "Muted" stays true.
        if !heldMutes.isEmpty { holdInputs() }
        let devices = Self.inputDevices
        let defaultInput = Self.defaultInput ?? 0
        let named = devices.contains(defaultInput) ? defaultInput : devices.first
        inputName = named.flatMap { MixerAudio.string($0, kAudioObjectPropertyName) }
        let defaultReadsMuted = defaultInput != 0 && Self.readsMuted(defaultInput)
        isMicMuted = !heldMutes.isEmpty || defaultReadsMuted
    }

    func selectOutput(_ output: MixerOutput) {
        var address = MixerAudio.address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = output.id
        do {
            try MixerAudio.check(AudioObjectSetPropertyData(MixerAudio.system, &address, 0, nil,
                UInt32(MemoryLayout<AudioObjectID>.size), &device), "Switching output")
            refresh(rebuild: true)
        } catch { self.error = error.localizedDescription }
    }

    func retry() {
        error = nil
        failures.removeAll()
        refresh(rebuild: true)
    }

    func openAudioPrivacy() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func refresh(rebuild: Bool = false) {
        guard isEnabled, !sleeping else { return }
        if rebuild { rebuildRoutes = true }
        let nextOutput = (try? MixerAudio.read(MixerAudio.system, kAudioHardwarePropertyDefaultOutputDevice,
                                             default: AudioObjectID(0))) ?? 0
        if nextOutput != outputID {
            rebuildRoutes = true
            failures.removeAll()
            outputID = nextOutput
        }
        outputs = MixerAudio.objects(MixerAudio.system, kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = MixerAudio.string(id, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("com.nanoapp.mixer."),
                  !MixerAudio.objects(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput).isEmpty
            else { return nil }
            let name = MixerAudio.string(id, kAudioObjectPropertyName) ?? "Audio output"
            let hasInput = !MixerAudio.objects(id, kAudioDevicePropertyStreams,
                scope: kAudioDevicePropertyScopeInput).isEmpty
            guard Self.isListedOutput(name: name, hasInput: hasInput, isDefault: id == nextOutput) else { return nil }
            return MixerOutput(id: id, uid: uid, name: name,
                kind: MixerOutput.Kind(transport: MixerAudio.transport(id)), hasInput: hasInput)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let processes = MixerAudio.objects(MixerAudio.system, kAudioHardwarePropertyProcessObjectList)
        var discovered: [String: MixerApp] = [:]
        for process in processes {
            guard let pid = try? MixerAudio.read(process, kAudioProcessPropertyPID, default: pid_t(0)),
                  pid != getpid(), pid > 0 else { continue }
            let running = NSRunningApplication(processIdentifier: pid)
            let bundle = Self.containingApp(running?.bundleURL) ?? Self.containingApp(Self.executableURL(pid))
            let bundleID = bundle?.bundleIdentifier ?? running?.bundleIdentifier
                ?? MixerAudio.string(process, kAudioProcessPropertyBundleID)
            guard let bundleID, !bundleID.isEmpty, !bundleID.hasPrefix("com.nanoapp.Nano"),
                  bundle != nil || running != nil else { continue }
            // `running` is this process's app; helpers resolve the containing
            // app's bundle to find a regular front-facing owner.
            let isRegular = running?.activationPolicy == .regular
                || NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                    .contains { $0.activationPolicy == .regular }
            let saved = preferences[bundleID]
            guard Self.isListedApp(isRegular: isRegular,
                hasSavedPreference: saved?.needsProcessing == true || saved?.isPinned == true)
            else { continue }
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? running?.localizedName ?? bundleID
            let active = (try? MixerAudio.read(process, kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) == 1
            if var app = discovered[bundleID] {
                app.processes.append(process)
                app.isRunning = app.isRunning || active
                discovered[bundleID] = app
            } else {
                discovered[bundleID] = MixerApp(id: bundleID, name: name,
                    icon: bundle.map { NSWorkspace.shared.icon(forFile: $0.bundleURL.path) } ?? running?.icon,
                    processes: [process], isRunning: active,
                    preference: preferences[bundleID] ?? MixerPreference(), error: failures[bundleID])
            }
        }
        for (id, preference) in preferences where discovered[id] == nil && (preference.isPinned || preference.needsProcessing) {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            discovered[id] = MixerApp(id: id, name: preference.name.isEmpty ? id : preference.name,
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }, processes: [],
                isRunning: false, preference: preference, error: nil)
        }
        // Preserve row positions across activity and process changes, including during a drag.
        let oldOrder = Dictionary(uniqueKeysWithValues: apps.enumerated().map { ($0.element.id, $0.offset) })
        apps = discovered.values.sorted {
            let left = oldOrder[$0.id] ?? Int.max
            let right = oldOrder[$1.id] ?? Int.max
            return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left < right
        }
        for app in apps where app.isRunning { lastActive[app.id] = Date() }
        activityExpiry?.cancel()
        if apps.contains(where: { !$0.isRunning && Date().timeIntervalSince(lastActive[$0.id] ?? .distantPast) < 8 }) {
            activityExpiry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.objectWillChange.send()
            }
        }
        observeProcesses(Set(processes))
        observeOutput()
        updateInputState()
        reconcile()
    }

    /// Outputs that are really microphones with a monitoring jack (for example a
    /// "fifine Microphone") are hidden from the picker unless they are the
    /// current system default, so the current row never goes blank.
    nonisolated static func isListedOutput(name: String, hasInput: Bool, isDefault: Bool) -> Bool {
        if isDefault || !hasInput { return true }
        let words = name.lowercased().split { !$0.isLetter }
        return !words.contains { ["mic", "microphone", "mics"].contains($0) }
    }

    /// Background-only helpers (Control Center, universalaccessd) stay hidden
    /// unless the user already adjusted or pinned them.
    nonisolated static func isListedApp(isRegular: Bool, hasSavedPreference: Bool) -> Bool {
        isRegular || hasSavedPreference
    }

    static func containingApp(_ url: URL?) -> Bundle? {
        guard var url else { return nil }
        var outer: URL?
        while url.path != "/" {
            if url.pathExtension == "app" { outer = url }
            url.deleteLastPathComponent()
        }
        return outer.flatMap(Bundle.init(url:))
    }

    private func reconcile() {
        routeRevision += 1
        let revision = routeRevision
        let rebuild = rebuildRoutes
        rebuildRoutes = false
        // An app that just went quiet keeps its route for a while. Rebuilding
        // the tap takes long enough that the start of the next sound (a
        // message ding) played at full volume, even from a muted app. The
        // linger is bounded because a running route keeps the output awake.
        let now = Date()
        var lingering = false
        let routes: [MixerRoute] = isEnabled && isConfigured && !sleeping ? apps.filter { app in
            guard app.preference.needsProcessing, !app.processes.isEmpty else { return false }
            if app.isRunning { return true }
            let quiet = now.timeIntervalSince(lastActive[app.id] ?? .distantPast)
            guard quiet < Self.routeLinger else { return false }
            lingering = true
            return true
        }.map { app in
            // A pinned output that disappeared falls back to the system default.
            let target = app.preference.outputUID
                .flatMap { uid in outputs.first { $0.uid == uid }?.id } ?? outputID
            return MixerRoute(id: app.id, processes: app.processes, source: outputID,
                output: target, gain: app.preference.gain)
        } : []
        routeLingerExpiry?.cancel()
        if lingering {
            routeLingerExpiry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.routeLinger))
                guard !Task.isCancelled else { return }
                self?.reconcile()
            }
        }
        Task { @MainActor [weak self, runtime] in
            let failures = await runtime.apply(routes, revision: revision, rebuild: rebuild)
            guard let self, routeRevision == revision else { return }
            self.failures = failures
            for index in apps.indices { apps[index].error = failures[apps[index].id] }
        }
    }

    private static func executableURL(_ pid: pid_t) -> URL? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    private func scheduleRefresh(rebuild: Bool = false) {
        if rebuild { rebuildRoutes = true; failures.removeAll() }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func startMonitoring() {
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            listeners.append(MixerAudioListener(object: MixerAudio.system, selector: selector) { [weak self] in
                self?.scheduleRefresh()
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.rebuildRoutes = true; self?.reconcile() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.scheduleRefresh(rebuild: true) }
        })
    }

    private func observeProcesses(_ processes: Set<AudioObjectID>) {
        guard processes != observedProcesses else { return }
        observedProcesses = processes
        processListeners = processes.map { process in
            MixerAudioListener(object: process, selector: kAudioProcessPropertyIsRunningOutput) { [weak self] in
                self?.scheduleRefresh()
            }
        }
    }

    private func observeOutput() {
        guard outputID != observedOutput else { return }
        observedOutput = outputID
        outputListeners = [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive,
                           kAudioDevicePropertyStreamConfiguration].map { selector in
            MixerAudioListener(object: outputID, selector: selector,
                scope: selector == kAudioDevicePropertyStreamConfiguration ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.scheduleRefresh(rebuild: true)
            }
        }
    }

    func stop() {
        activityExpiry?.cancel()
        activityExpiry = nil
        routeLingerExpiry?.cancel()
        routeLingerExpiry = nil
        lastActive.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
        rebuildRoutes = true
        isEnabled = false
        reconcile()
        listeners.removeAll()
        processListeners.removeAll()
        outputListeners.removeAll()
        observedProcesses.removeAll()
        observedOutput = 0
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        failures.removeAll()
        apps = []
        outputs = []
        error = nil
        restoreInputs()
        inputName = nil
        isMicMuted = false
    }
}

private final class MixerAudioListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    @MainActor
    init(object: AudioObjectID, selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         changed: @escaping @MainActor () -> Void) {
        self.object = object
        address = MixerAudio.address(selector, scope: scope)
        block = { _, _ in Task { @MainActor in changed() } }
        AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
    }

    deinit { AudioObjectRemovePropertyListenerBlock(object, &address, .main, block) }
}
