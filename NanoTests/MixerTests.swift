import CoreAudio
import XCTest
@testable import Nano

final class MixerTests: XCTestCase {
    /// Opt-in hardware check. Two equal-level test tones at 220/330 Hz must be
    /// routed by the installed Nano at 25/50 percent. Captures only Nano's output
    /// in memory and compares amplitudes, never recording to disk.
    func testLiveInstalledMixerOutputRatio() async throws {
        guard let text = ProcessInfo.processInfo.environment["NANO_MIXER_LIVE_PID"], let pid = pid_t(text) else {
            throw XCTSkip("Set TEST_RUNNER_NANO_MIXER_LIVE_PID to the installed Nano PID with the two test sources running.")
        }
        let amplitudes = try await Task.detached { try MixerLiveAudioCheck.measure(pid: pid) }.value
        XCTAssertGreaterThan(amplitudes.1, 0.001, "The second source must be audible in Nano's output.")
        XCTAssertEqual(amplitudes.0 / amplitudes.1, 0.5, accuracy: 0.06)
        print("Mixer live amplitudes: A=\(amplitudes.0), B=\(amplitudes.1), ratio=\(amplitudes.0 / amplitudes.1)")
    }

    func testIndependentAppGainsPreserveStereoChannels() {
        let music = MixerGain(volume: 0.25)
        let call = MixerGain(volume: 1)
        XCTAssertEqual(render(music, samples: [0.8, -0.4, 0.4, -0.8]), [0.2, -0.1, 0.1, -0.2])
        XCTAssertEqual(render(call, samples: [0.8, -0.4, 0.4, -0.8]), [0.8, -0.4, 0.4, -0.8])
    }

    func testMuteRampsToSilenceAndUnmuteRestoresLevel() {
        let gain = MixerGain(volume: 0.5)
        gain.configure(sampleRate: 48000)
        gain.setTarget(0)
        let muted = render(gain, samples: Array(repeating: 1, count: 2048))
        XCTAssertGreaterThan(muted[0], 0.49)
        XCTAssertEqual(muted[0], muted[1])
        XCTAssertEqual(muted.last!, 0)
        for index in 2..<muted.count {
            XCTAssertLessThanOrEqual(abs(muted[index] - muted[index - 2]), 0.0021)
        }
        gain.setTarget(0.5)
        let restored = render(gain, samples: Array(repeating: 1, count: 2048))
        XCTAssertEqual(restored.last!, 0.5, accuracy: 0.0001)
    }

    func testOutputTailIsSilentWhenInputIsShort() {
        let gain = MixerGain(volume: 0.5)
        XCTAssertEqual(render(gain, samples: [1, -1], outputCount: 6), [0.5, -0.5, 0, 0, 0, 0])
    }

    func testGainBoostsToDoubleAndNeverInverts() {
        XCTAssertEqual(render(MixerGain(volume: 4), samples: [0.25, -0.25]), [0.5, -0.5])
        XCTAssertEqual(render(MixerGain(volume: -2), samples: [0.25, -0.25]), [0, 0])
        XCTAssertEqual(render(MixerGain(volume: .nan), samples: [0.25, -0.25]), [0.25, -0.25])
    }

    func testBoostLimiterKeepsPeaksUnderCeiling() {
        let gain = MixerGain(volume: 2)
        gain.configure(sampleRate: 48000)
        let frames = 4800
        var samples = [Float]()
        samples.reserveCapacity(frames * 2)
        for frame in 0..<frames {
            let s = Float(0.9 * sin(2 * .pi * 440 * Double(frame) / 48000))
            samples.append(s)
            samples.append(s)
        }
        let output = render(gain, samples: samples)
        var peak: Float = 0
        for sample in output {
            XCTAssertLessThanOrEqual(abs(sample), 0.98 + 1e-6)
            peak = max(peak, abs(sample))
        }
        XCTAssertGreaterThan(peak, 0.9, "A limiter that silences the signal is not a boost")
    }

    @MainActor
    func testMutePersistsWithoutLosingVolumeAndResetBypassesProcessing() throws {
        let suite = "NanoTests.mixer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = "test.nano.mixer.fixture"
        let original = MixerPreference(volume: 0.37, isMuted: false, isPinned: true, name: "Fixture player")
        defaults.set(try JSONEncoder().encode([id: original]), forKey: "mixer.apps")
        let store = MixerStore(defaults: defaults)
        store.setEnabled(true)
        defer { store.setEnabled(false) }
        store.toggleMute(id)
        let muted = try XCTUnwrap(store.apps.first { $0.id == id })
        XCTAssertTrue(muted.preference.isMuted)
        XCTAssertEqual(muted.preference.volume, 0.37)
        XCTAssertEqual(muted.preference.gain, 0)

        let relaunched = MixerStore(defaults: defaults)
        relaunched.setEnabled(true)
        defer { relaunched.setEnabled(false) }
        XCTAssertTrue(try XCTUnwrap(relaunched.apps.first { $0.id == id }).preference.isMuted)
        relaunched.toggleMute(id)
        XCTAssertEqual(try XCTUnwrap(relaunched.apps.first { $0.id == id }).preference.gain, 0.37)
        relaunched.reset(id)
        let reset = try XCTUnwrap(relaunched.apps.first { $0.id == id })
        XCTAssertEqual(reset.preference.volume, 1)
        XCTAssertFalse(reset.preference.needsProcessing)
        XCTAssertTrue(reset.preference.isPinned)
    }

    @MainActor
    func testBoostAndOutputRoutePreferencesPersist() throws {
        let suite = "NanoTests.mixer.boost.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = "test.nano.mixer.boost"
        defaults.set(try JSONEncoder().encode(
            [id: MixerPreference(volume: 1, isMuted: false, isPinned: true, name: "Boosted")]
        ), forKey: "mixer.apps")
        let store = MixerStore(defaults: defaults)
        store.setEnabled(true)
        defer { store.setEnabled(false) }

        store.setVolume(1.8, for: id)
        let preference = try XCTUnwrap(store.apps.first { $0.id == id }).preference
        XCTAssertEqual(preference.volume, 1.8)
        XCTAssertTrue(preference.needsProcessing)

        store.setVolume(3, for: id)
        XCTAssertEqual(try XCTUnwrap(store.apps.first { $0.id == id }).preference.volume, 2)

        store.setVolume(1.8, for: id)
        store.setOutput("test.output.uid", for: id)

        let relaunched = MixerStore(defaults: defaults)
        relaunched.setEnabled(true)
        defer { relaunched.setEnabled(false) }
        let restored = try XCTUnwrap(relaunched.apps.first { $0.id == id }).preference
        XCTAssertEqual(restored.volume, 1.8)
        XCTAssertEqual(restored.outputUID, "test.output.uid")
        XCTAssertTrue(restored.needsProcessing)

        let legacy = try JSONDecoder().decode([String: MixerPreference].self, from: Data(
            #"{"test.nano.mixer.legacy":{"volume":0.5,"isMuted":true,"isPinned":false,"name":"Old"}}"#.utf8))
        XCTAssertNil(legacy["test.nano.mixer.legacy"]?.outputUID)
        XCTAssertEqual(legacy["test.nano.mixer.legacy"]?.isMuted, true)
    }

    func testMicFirstOutputsAreHiddenUnlessDefault() {
        XCTAssertFalse(MixerStore.isListedOutput(name: "fifine Microphone", hasInput: true, isDefault: false))
        XCTAssertTrue(MixerStore.isListedOutput(name: "fifine Microphone", hasInput: true, isDefault: true))
        XCTAssertTrue(MixerStore.isListedOutput(name: "AirPods Pro", hasInput: true, isDefault: false))
        XCTAssertTrue(MixerStore.isListedOutput(name: "USB Headset", hasInput: true, isDefault: false))
        XCTAssertTrue(MixerStore.isListedOutput(name: "Mac mini Speakers", hasInput: false, isDefault: false))
        XCTAssertFalse(MixerStore.isListedOutput(name: "Blue Yeti Mic", hasInput: true, isDefault: false))
        XCTAssertTrue(MixerStore.isListedOutput(name: "Microsoft Speakers", hasInput: false, isDefault: false))
    }

    func testBackgroundProcessesAreHiddenUnlessAdjusted() {
        XCTAssertTrue(MixerStore.isListedApp(isRegular: true, hasSavedPreference: false))
        XCTAssertFalse(MixerStore.isListedApp(isRegular: false, hasSavedPreference: false))
        XCTAssertTrue(MixerStore.isListedApp(isRegular: false, hasSavedPreference: true))
        XCTAssertTrue(MixerStore.isListedApp(isRegular: true, hasSavedPreference: true))
    }

    @MainActor
    func testMixerIsOptInAndItsSettingsFollowTheToggle() {
        let suite = "NanoTests.mixer.module.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NanoSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled(.mixer))
        XCTAssertFalse(SettingsDestination.available(settings: settings).contains(.mixer))
        settings.setEnabled(true, for: .mixer)
        XCTAssertTrue(SettingsDestination.available(settings: settings).contains(.mixer))
        XCTAssertTrue(SettingsDestination.search("headphones", settings: settings).contains { $0.0 == .mixer })
        settings.setEnabled(false, for: .mixer)
        XCTAssertFalse(SettingsDestination.available(settings: settings).contains(.mixer))
    }

    private func render(_ gain: MixerGain, samples: [Float], outputCount: Int? = nil) -> [Float] {
        var samples = samples
        var output = [Float](repeating: 42, count: outputCount ?? samples.count)
        let sourceCount = samples.count
        let destinationCount = output.count
        samples.withUnsafeMutableBytes { source in
            output.withUnsafeMutableBytes { destination in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                    mDataByteSize: UInt32(sourceCount * 4), mData: source.baseAddress))
                var result = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2,
                    mDataByteSize: UInt32(destinationCount * 4), mData: destination.baseAddress))
                gain.render(input: &input, output: &result)
            }
        }
        return output
    }
}

private enum MixerLiveAudioCheck {
    static func measure(pid: pid_t) throws -> (Double, Double) {
        let process = try XCTUnwrap(MixerAudio.objects(MixerAudio.system, kAudioHardwarePropertyProcessObjectList).first {
            (try? MixerAudio.read($0, kAudioProcessPropertyPID, default: pid_t(0))) == pid
        })
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap: AudioObjectID = 0
        try MixerAudio.check(AudioHardwareCreateProcessTap(description, &tap), "Opening test capture")
        defer { AudioHardwareDestroyProcessTap(tap) }
        let format = try MixerAudio.read(tap, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let spec: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Nano Mixer verification",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        var device: AudioObjectID = 0
        try MixerAudio.check(AudioHardwareCreateAggregateDevice(spec as CFDictionary, &device), "Opening test device")
        defer { AudioHardwareDestroyAggregateDevice(device) }
        let measurement = MixerToneMeasurement(sampleRate: format.mSampleRate)
        var io: AudioDeviceIOProcID?
        let queue = DispatchQueue(label: "nano.mixer.test.capture")
        try MixerAudio.check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue) { _, input, _, _, _ in
            measurement.consume(input)
        }, "Preparing test capture")
        defer { AudioDeviceDestroyIOProcID(device, io!) }
        try MixerAudio.check(AudioDeviceStart(device, io), "Starting test capture")
        Thread.sleep(forTimeInterval: 2)
        AudioDeviceStop(device, io)
        let amplitudes = measurement.amplitudes()
        return amplitudes
    }
}

private final class MixerToneMeasurement: @unchecked Sendable {
    private let sampleRate: Double
    private let lock = NSLock()
    private var frame = 0
    private var count = 0
    private var aReal = 0.0
    private var aImag = 0.0
    private var bReal = 0.0
    private var bImag = 0.0

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    func consume(_ input: UnsafePointer<AudioBufferList>) {
        lock.lock()
        defer { lock.unlock() }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = buffers.first, let data = buffer.mData, buffer.mNumberChannels > 0 else { return }
        let samples = data.assumingMemoryBound(to: Float.self)
        let channels = Int(buffer.mNumberChannels)
        for index in 0..<(Int(buffer.mDataByteSize) / 4 / channels) {
            defer { frame += 1 }
            guard Double(frame) > sampleRate * 0.2 else { continue }
            let sample = Double(samples[index * channels])
            let time = Double(frame) / sampleRate
            aReal += sample * cos(2 * .pi * 220 * time)
            aImag += sample * sin(2 * .pi * 220 * time)
            bReal += sample * cos(2 * .pi * 330 * time)
            bImag += sample * sin(2 * .pi * 330 * time)
            count += 1
        }
    }

    func amplitudes() -> (Double, Double) {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return (0, 0) }
        return (2 * hypot(aReal, aImag) / Double(count), 2 * hypot(bReal, bImag) / Double(count))
    }
}
