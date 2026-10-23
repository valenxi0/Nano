import AppKit
import CoreAudio
import CoreBluetooth
import Foundation
@preconcurrency import IOBluetooth
import IOKit
import IOKit.graphics
import IOKit.ps

/// Watches public system events and turns them into island notifications.
///
/// Volume and brightness listen for the media-key NSEvent, then read the new
/// value. That avoids standing up CoreAudio's HAL client just to sit idle —
/// the compact strip never needed a live volume readout, and neither does a
/// HUD that only appears when a key is pressed.
///
/// Bluetooth uses IOBluetooth connect/disconnect notifications. Battery uses
/// the IOPS run-loop source so MagSafe is instant instead of the 5s poll.
@MainActor
final class SystemEventMonitor {
    var onNotification: ((IslandNotification) -> Void)?

    private var enabled: Set<IslandNotificationSource> = []
    private var mediaKeyMonitors: [Any] = []
    private var volumeWatcher: OutputVolumeWatcher?
    private var bluetoothWatcher: BluetoothConnectionWatcher?
    private var powerWatcher: PowerSourceWatcher?
    private var lastBattery: BatterySnapshot?
    private var lastMediaKeyAt: [UInt32: Date] = [:]
    private var bluetoothObservers: [NSObjectProtocol] = []

    func start(sources: Set<IslandNotificationSource>) {
        enabled = sources
        observeBluetoothAuthorization()
        syncMediaKeys()
        syncVolumeListener()
        syncBluetooth()
        syncPower()
    }

    func stop() {
        enabled = []
        syncMediaKeys()
        syncVolumeListener()
        syncBluetooth()
        syncPower()
    }

    private func syncMediaKeys() {
        let wantsKeys = enabled.contains(.volume) || enabled.contains(.brightness)
        if wantsKeys, mediaKeyMonitors.isEmpty {
            let note: (NSEvent) -> Void = { [weak self] event in
                Task { @MainActor in
                    self?.handleMediaKey(event)
                }
            }
            if let global = NSEvent.addGlobalMonitorForEvents(
                matching: .systemDefined,
                handler: note
            ) {
                mediaKeyMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { event in
                note(event)
                return event
            }) {
                mediaKeyMonitors.append(local)
            }
        } else if !wantsKeys {
            mediaKeyMonitors.forEach { NSEvent.removeMonitor($0) }
            mediaKeyMonitors.removeAll()
        }
    }

    private func syncVolumeListener() {
        if enabled.contains(.volume) {
            if volumeWatcher == nil {
                let watcher = OutputVolumeWatcher()
                watcher.onChange = { [weak self] level, muted in
                    self?.onNotification?(.volume(level: level, muted: muted))
                }
                watcher.start()
                volumeWatcher = watcher
            }
        } else {
            volumeWatcher?.stop()
            volumeWatcher = nil
        }
    }

    /// The watcher only starts once Bluetooth is allowed, so macOS asks
    /// when onboarding or Settings does, not at first launch.
    private func observeBluetoothAuthorization() {
        guard bluetoothObservers.isEmpty else { return }
        let center = NotificationCenter.default
        bluetoothObservers = [NanoBluetoothPermission.didChange, NSApplication.didBecomeActiveNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncBluetooth() }
            }
        }
    }

    private func syncBluetooth() {
        if enabled.contains(.bluetooth), CBManager.authorization == .allowedAlways {
            if bluetoothWatcher == nil {
                let watcher = BluetoothConnectionWatcher()
                watcher.onChange = { [weak self] device, connected in
                    Task { @MainActor in
                        self?.handleBluetooth(device, connected: connected)
                    }
                }
                watcher.start()
                bluetoothWatcher = watcher
            }
        } else {
            bluetoothWatcher?.stop()
            bluetoothWatcher = nil
        }
    }

    private func syncPower() {
        if enabled.contains(.battery) {
            if powerWatcher == nil {
                lastBattery = SystemStatusService.readBattery()
                let watcher = PowerSourceWatcher()
                watcher.onChange = { [weak self] in
                    Task { @MainActor in
                        self?.handlePowerChange()
                    }
                }
                watcher.start()
                powerWatcher = watcher
            }
        } else {
            powerWatcher?.stop()
            powerWatcher = nil
            lastBattery = nil
        }
    }

    private func handleMediaKey(_ event: NSEvent) {
        guard let key = MediaKeyEvent.parse(
            subtype: event.subtype.rawValue,
            data1: event.data1
        ) else { return }

        // Holding a key repeats. One HUD update per 80ms is enough.
        let now = Date()
        if let previous = lastMediaKeyAt[key.code], now.timeIntervalSince(previous) < 0.08 {
            return
        }
        lastMediaKeyAt[key.code] = now

        switch key.kind {
        case .volumeUp, .volumeDown, .mute:
            guard enabled.contains(.volume) else { return }
            let reading = SystemStatusService.readOutputVolume()
            guard let level = reading.level else { return }
            onNotification?(.volume(level: level, muted: reading.muted))
        case .brightnessUp, .brightnessDown:
            guard enabled.contains(.brightness) else { return }
            guard let level = Self.readBrightness() else { return }
            onNotification?(.brightness(level: level))
        }
    }

    private func handleBluetooth(_ device: IOBluetoothDevice, connected: Bool) {
        guard enabled.contains(.bluetooth) else { return }
        let name = (device.nameOrAddress as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (name?.isEmpty == false ? name : nil) ?? "Bluetooth device"
        let address = device.addressString ?? resolved
        let category = BluetoothAccessoryCategory.classify(
            name: resolved,
            major: UInt32(device.deviceClassMajor),
            minor: UInt32(device.deviceClassMinor)
        )
        if connected, BluetoothDevicePresentation.resolve(name: resolved, category: category) == .airPodsPro {
            Task { [weak self] in
                let battery = await Task.detached(priority: .utility) {
                    Self.readAirPodsBattery(address: address)
                }.value
                guard let self, self.enabled.contains(.bluetooth), device.isConnected() else { return }
                self.onNotification?(.bluetooth(name: resolved, category: category, connected: true, address: address, battery: battery))
            }
        } else {
            onNotification?(.bluetooth(name: resolved, category: category, connected: connected, address: address))
        }
    }

    nonisolated private static func readAirPodsBattery(address: String) -> AirPodsBatteryLevels? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "3"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? AirPodsBatteryLevels.fromProfiler(data, address: address) : nil
    }

    private func handlePowerChange() {
        guard enabled.contains(.battery) else { return }
        let current = SystemStatusService.readBattery()
        defer { lastBattery = current }
        guard let current, Self.shouldAnnounceBattery(previous: lastBattery, current: current) else {
            return
        }
        onNotification?(.battery(current))
    }

    /// Charging start, or first contact with power. Percentage ticks and
    /// unplugging stay quiet — those are not the laptop-lid moment this HUD is for.
    nonisolated static func shouldAnnounceBattery(previous: BatterySnapshot?, current: BatterySnapshot) -> Bool {
        guard current.isCharging || current.isPluggedIn else { return false }
        guard let previous else { return current.isCharging }
        if !previous.isCharging && current.isCharging { return true }
        if !previous.isPluggedIn && current.isPluggedIn { return true }
        return false
    }

    static func readBrightness() -> Double? {
        if let level = DisplayBrightnessService.read() { return level }
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }
            var brightness: Float = 0
            let status = IODisplayGetFloatParameter(
                service,
                0,
                kIODisplayBrightnessKey as CFString,
                &brightness
            )
            if status == kIOReturnSuccess {
                return Double(brightness)
            }
            service = IOIteratorNext(iterator)
        }
        return nil
    }
}

enum MediaKeyKind: Equatable, Sendable {
    case volumeUp
    case volumeDown
    case mute
    case brightnessUp
    case brightnessDown
}

struct MediaKeyEvent: Equatable, Sendable {
    let kind: MediaKeyKind
    let code: UInt32

    /// `NSEvent.systemDefined` packing used by the volume and brightness keys.
    /// Key-up is ignored so one press becomes one HUD.
    static func parse(subtype: Int16, data1: Int) -> Self? {
        guard subtype == 8 else { return nil }
        let code = UInt32((data1 & 0xFFFF0000) >> 16)
        let keyState = (data1 & 0x0000FF00) >> 8
        // 0x0A is key-down. Some firmware also delivers 0x0B-only repeats;
        // accept either so a press is never silent.
        guard keyState == 0x0A || keyState == 0x0B else { return nil }

        let kind: MediaKeyKind
        switch code {
        case 0: kind = .volumeUp
        case 1: kind = .volumeDown
        case 2: kind = .brightnessUp
        case 3: kind = .brightnessDown
        case 7: kind = .mute
        default: return nil
        }
        return MediaKeyEvent(kind: kind, code: code)
    }
}

/// IOBluetooth delivers connect events through an Objective-C selector.
///
/// `register(forConnectNotifications:)` immediately replays every device that
/// is already connected. Those are not new, so launch must not announce them.
enum BluetoothLaunchFilter {
    static func shouldAnnounceConnect(address: String, knownAtStart: inout Set<String>) -> Bool {
        if knownAtStart.contains(address) {
            knownAtStart.remove(address)
            return false
        }
        return true
    }
}

private final class BluetoothConnectionWatcher: NSObject, @unchecked Sendable {
    var onChange: ((IOBluetoothDevice, Bool) -> Void)?

    private let registrationQueue = DispatchQueue(
        label: "com.nanoapp.bluetooth-notifications",
        qos: .utility
    )
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var knownAtStart: Set<String> = []
    private var announceConnectsAfter = Date.distantPast

    func start() {
        // Initializing IOBluetooth's CoreBluetooth coordinator can wait on an
        // internal semaphore for several seconds. Never let that initialization
        // hold Nano's main actor, where the island and agent events are handled.
        registrationQueue.async { [weak self] in
            self?.startRegistration()
        }
    }

    private func startRegistration() {
        // IOBluetooth replays already-connected devices after registration.
        // Let those callbacks establish disconnect watches, but suppress their
        // connect announcements during startup. Calling `pairedDevices()` here
        // can block inside CoreBluetooth initialization and freeze Nano's main
        // thread, which would also stop agent notifications from being handled.
        knownAtStart.removeAll()
        announceConnectsAfter = Date().addingTimeInterval(2)
        connectNote = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(didConnect(_:device:))
        )
    }

    func stop() {
        onChange = nil
        registrationQueue.async { [weak self] in
            guard let self else { return }
            connectNote?.unregister()
            connectNote = nil
            disconnectNotes.values.forEach { $0.unregister() }
            disconnectNotes.removeAll()
        }
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        let key = Self.address(of: device) ?? UUID().uuidString
        guard disconnectNotes[key] == nil else { return }
        disconnectNotes[key] = device.register(
            forDisconnectNotification: self,
            selector: #selector(didDisconnect(_:device:))
        )
    }

    @objc
    private func didConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        registrationQueue.async { [weak self] in
            self?.handleConnect(device)
        }
    }

    private func handleConnect(_ device: IOBluetoothDevice) {
        watchDisconnect(device)
        let address = Self.address(of: device) ?? ""
        guard BluetoothLaunchFilter.shouldAnnounceConnect(
            address: address,
            knownAtStart: &knownAtStart
        ) else { return }
        // Late replay from the stack, or a burst while Nano is still coming up.
        guard Date() >= announceConnectsAfter else { return }
        onChange?(device, true)
    }

    @objc
    private func didDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        registrationQueue.async { [weak self] in
            self?.handleDisconnect(device)
        }
    }

    private func handleDisconnect(_ device: IOBluetoothDevice) {
        let key = Self.address(of: device)
        if let key, let note = disconnectNotes.removeValue(forKey: key) {
            note.unregister()
        }
        onChange?(device, false)
    }

    private static func address(of device: IOBluetoothDevice) -> String? {
        if let address = device.addressString, !address.isEmpty {
            return address
        }
        let name = (device.nameOrAddress as String?)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name : nil
    }

}

/// Listens to the default output device so Control Center and the menu-bar
/// slider also drive the HUD, not only the media keys.
@MainActor
private final class OutputVolumeWatcher: @unchecked Sendable {
    var onChange: ((Double, Bool) -> Void)?

    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var seeded = false
    private var last: (Double, Bool)?
    private var volumeBlock: AudioObjectPropertyListenerBlock?
    private var muteBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?

    func start() {
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.attachToDefaultDevice()
            }
        }
        defaultDeviceBlock = defaultBlock
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            defaultBlock
        )
        attachToDefaultDevice()
    }

    func stop() {
        detachFromDevice()
        if let defaultDeviceBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                defaultDeviceBlock
            )
        }
        defaultDeviceBlock = nil
        onChange = nil
        seeded = false
        last = nil
    }

    private func attachToDefaultDevice() {
        detachFromDevice()
        guard let next = SystemStatusService.defaultOutputDevice() else { return }
        deviceID = next

        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.publish() }
        }
        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.publish() }
        }
        self.volumeBlock = volumeBlock
        self.muteBlock = muteBlock

        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListenerBlock(deviceID, &volumeAddress, DispatchQueue.main, volumeBlock)
        _ = AudioObjectAddPropertyListenerBlock(deviceID, &muteAddress, DispatchQueue.main, muteBlock)
        publish()
    }

    private func detachFromDevice() {
        guard deviceID != kAudioObjectUnknown else { return }
        if let volumeBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, volumeBlock)
        }
        if let muteBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, muteBlock)
        }
        volumeBlock = nil
        muteBlock = nil
        deviceID = AudioDeviceID(kAudioObjectUnknown)
    }

    private func publish() {
        let reading = SystemStatusService.readOutputVolume()
        guard let level = reading.level else { return }
        if let last, abs(last.0 - level) < 0.004, last.1 == reading.muted {
            return
        }
        last = (level, reading.muted)
        // The first read is just the baseline so launching Nano does not
        // flash a volume HUD.
        guard seeded else {
            seeded = true
            return
        }
        onChange?(level, reading.muted)
    }
}

private final class PowerCallbackBox {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}

private final class PowerSourceWatcher {
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?
    private var box: PowerCallbackBox?

    func start() {
        let box = PowerCallbackBox { [weak self] in self?.onChange?() }
        self.box = box
        let unmanaged = Unmanaged.passRetained(box)
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerCallbackBox>.fromOpaque(context).takeUnretainedValue().handler()
        }, unmanaged.toOpaque())?.takeRetainedValue() else {
            unmanaged.release()
            self.box = nil
            return
        }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if box != nil {
            // Balanced against passRetained in start().
            Unmanaged.passUnretained(box!).release()
        }
        source = nil
        box = nil
        onChange = nil
    }
}

/// Creating a Bluetooth manager is what makes macOS ask for access.
@MainActor
enum NanoBluetoothPermission {
    nonisolated static let didChange = Notification.Name("NanoBluetoothAuthorizationChanged")

    private static var manager: CBCentralManager?
    private static let delegate = PromptDelegate()

    static func request() {
        guard CBManager.authorization == .notDetermined else {
            NanoPrivacySettings.open(NanoPermissionKind.bluetooth.settingsAnchor)
            return
        }
        manager = CBCentralManager(delegate: delegate, queue: nil)
    }

    private final class PromptDelegate: NSObject, CBCentralManagerDelegate {
        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            guard CBManager.authorization != .notDetermined else { return }
            NotificationCenter.default.post(name: NanoBluetoothPermission.didChange, object: nil)
        }
    }
}
