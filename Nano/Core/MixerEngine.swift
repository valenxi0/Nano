import CoreAudio
import Foundation
import Darwin

enum MixerAudioError: LocalizedError {
    case operation(String, OSStatus)
    case unsupportedFormat
    case noOutput

    var errorDescription: String? {
        switch self {
        case let .operation(operation, status):
            "\(operation) failed (\(status)). Check Nano's system audio access, then retry."
        case .unsupportedFormat:
            "This output's audio format isn't supported. Choose a stereo output, then retry."
        case .noOutput:
            "No output device is available. Connect speakers or headphones, then retry."
        }
    }
}

enum MixerAudio {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        default value: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var property = address(selector, scope: scope)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0)
        }
        try check(status, "Reading audio device")
        return result
    }

    static func objects(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size)) : []
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw MixerAudioError.operation(operation, status) }
    }

    static func isSettable(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var property = address(selector, scope: scope)
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(id, &property, &settable) == noErr && settable.boolValue
    }

    static func write<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws {
        var property = address(selector, scope: scope)
        var value = value
        try check(AudioObjectSetPropertyData(id, &property, 0, nil,
            UInt32(MemoryLayout<T>.size), &value), "Writing audio device")
    }

    static func transport(_ id: AudioObjectID) -> UInt32 {
        (try? read(id, kAudioDevicePropertyTransportType, default: UInt32(0))) ?? 0
    }
}

/// Owns one app's private tap and playback device. Stop playback before releasing
/// the tap so mutedWhenTapped always returns the app to its original audio path.
final class MixerEngine {
    let processes: [AudioObjectID]
    let sourceID: AudioObjectID
    let outputID: AudioObjectID
    private var tapID: AudioObjectID = 0
    private var deviceID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private let gain: MixerGain
    private let ioQueue = DispatchQueue(label: "com.nanoapp.mixer.render", qos: .userInteractive)

    init(processes: [AudioObjectID], sourceID: AudioObjectID, outputID: AudioObjectID, volume: Float) throws {
        self.processes = processes.sorted()
        self.sourceID = sourceID
        self.outputID = outputID
        gain = MixerGain(volume: 1)
        gain.setTarget(volume)
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    func setVolume(_ volume: Float) { gain.setTarget(volume) }

    private func start() throws {
        guard outputID != 0, let outputUID = MixerAudio.string(outputID, kAudioDevicePropertyDeviceUID) else {
            throw MixerAudioError.noOutput
        }
        let description: CATapDescription
        if outputID == sourceID,
           let sourceUID = MixerAudio.string(sourceID, kAudioDevicePropertyDeviceUID) {
            description = CATapDescription(processes: processes, deviceUID: sourceUID, stream: 0)
        } else {
            // Routed to a different output: tap the app's processes wherever they
            // play (the system default), then relay into the target aggregate.
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.name = "Nano Mixer"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try MixerAudio.check(AudioHardwareCreateProcessTap(description, &tapID), "Opening app audio")

        let format = try MixerAudio.read(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard Self.supports(format) else { throw MixerAudioError.unsupportedFormat }
        let specification: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Nano Mixer",
            kAudioAggregateDeviceUIDKey: "com.nanoapp.mixer.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: outputUID,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceOutputChannelsKey: Int(format.mChannelsPerFrame),
            ]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ]
        try MixerAudio.check(AudioHardwareCreateAggregateDevice(specification as CFDictionary, &deviceID), "Preparing audio output")

        // Never guess at physical-input offsets: this aggregate must contain
        // only the tap as input. In particular, do not capture a headset mic.
        // (kAudioSubDeviceInputChannelsKey = 0 does not keep a target's input
        // stream out of the aggregate, and IOProcStreamUsage did not stop the
        // hardware mic, so any extra input stream fails the route instead.)
        let inputs = MixerAudio.objects(deviceID, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
        let outputs = MixerAudio.objects(deviceID, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        guard inputs.count == 1, outputs.count == 1, let input = inputs.first, let output = outputs.first else {
            throw MixerAudioError.unsupportedFormat
        }
        let inputFormat = try MixerAudio.read(input, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
        let outputFormat = try MixerAudio.read(output, kAudioStreamPropertyVirtualFormat, default: AudioStreamBasicDescription())
        guard Self.supports(inputFormat), Self.supports(outputFormat),
              inputFormat.mChannelsPerFrame == outputFormat.mChannelsPerFrame,
              inputFormat.mSampleRate == outputFormat.mSampleRate else {
            throw MixerAudioError.unsupportedFormat
        }
        gain.configure(sampleRate: inputFormat.mSampleRate)
        let renderGain = gain
        try MixerAudio.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, ioQueue) { _, input, _, output, _ in
            renderGain.render(input: input, output: output)
        }, "Preparing app volume")
        try MixerAudio.check(AudioDeviceStart(deviceID, ioProc), "Starting app volume")
    }

    static func supports(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM &&
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0 &&
        format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 &&
        format.mBitsPerChannel == 32 && (1...2).contains(format.mChannelsPerFrame) &&
        format.mBytesPerFrame == format.mChannelsPerFrame * 4 && format.mSampleRate > 0
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
        if deviceID != 0 { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = 0
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        tapID = 0
    }
}

struct MixerRoute: Sendable {
    let id: String
    let processes: [AudioObjectID]
    /// The system default output, where the app actually plays.
    let source: AudioObjectID
    /// The output the app's audio is sent to.
    let output: AudioObjectID
    let gain: Float
}

/// Core Audio may wait for a permission decision or hardware. Keep all route
/// creation and teardown off the main actor, including the first permission probe.
actor MixerRuntime {
    private var engines: [String: MixerEngine] = [:]
    private var failures: [String: String] = [:]
    private var bypassTasks: [String: Task<Void, Never>] = [:]
    private var revision = 0

    func connect(output: AudioObjectID) throws {
        // An empty inclusive tap requests access without intercepting an app,
        // and cannot recursively capture our own aggregate playback process.
        let probe = try MixerEngine(processes: [], sourceID: output, outputID: output, volume: 1)
        probe.stop()
    }

    func apply(_ routes: [MixerRoute], revision nextRevision: Int, rebuild: Bool) -> [String: String] {
        guard nextRevision >= revision else { return failures }
        revision = nextRevision
        if rebuild {
            for task in bypassTasks.values { task.cancel() }
            bypassTasks.removeAll()
            engines.removeAll()
            failures.removeAll()
        }
        let wanted = Set(routes.map(\.id))
        for id in Array(engines.keys) where !wanted.contains(id) && bypassTasks[id] == nil {
            engines[id]?.setVolume(1)
            bypassTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(15))
                guard !Task.isCancelled else { return }
                await self?.finishBypass(id)
            }
        }
        failures = failures.filter { wanted.contains($0.key) }
        for route in routes {
            bypassTasks[route.id]?.cancel()
            bypassTasks[route.id] = nil
            if let existing = engines[route.id],
               existing.outputID != route.output || existing.sourceID != route.source
                || existing.processes != route.processes.sorted() {
                engines[route.id] = nil
                failures[route.id] = nil
            }
            if let existing = engines[route.id] {
                existing.setVolume(route.gain)
            } else if failures[route.id] == nil {
                do {
                    engines[route.id] = try MixerEngine(processes: route.processes,
                        sourceID: route.source, outputID: route.output, volume: route.gain)
                } catch { failures[route.id] = error.localizedDescription }
            }
        }
        return failures
    }

    private func finishBypass(_ id: String) {
        engines[id] = nil
        bypassTasks[id] = nil
    }
}

/// Only the render callback writes current. Control writes target through an
/// atomic integer; the audio thread never waits on a lock or allocates buffers.
final class MixerGain: @unchecked Sendable {
    private var target: Int32
    private var current: Float
    private var step: Float = 1 / 480
    /// Limiter envelope, only touched by the render thread.
    private var envelope: Float = 0
    private var releaseCoef: Float = Float(exp(-1 / (0.08 * 48000)))

    init(volume: Float) {
        let volume = Self.clamp(volume)
        current = volume
        target = Int32(volume * 10000)
    }

    static func clamp(_ volume: Float) -> Float {
        volume.isFinite ? min(2, max(0, volume)) : 1
    }

    private static func releaseCoefficient(sampleRate: Double) -> Float {
        Float(exp(-1 / (0.08 * sampleRate)))
    }

    func configure(sampleRate: Double) {
        step = 1 / Float(sampleRate * 0.01)
        releaseCoef = Self.releaseCoefficient(sampleRate: sampleRate)
    }

    func setTarget(_ volume: Float) {
        let next = Int32(Self.clamp(volume) * 10000)
        var old = OSAtomicAdd32Barrier(0, &target)
        while !OSAtomicCompareAndSwap32Barrier(old, next, &target) {
            old = OSAtomicAdd32Barrier(0, &target)
        }
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard let source = inputs.first, let destination = outputs.first,
              source.mNumberChannels == destination.mNumberChannels,
              source.mNumberChannels > 0,
              let sourceData = source.mData, let destinationData = destination.mData else { return }
        let count = Int(min(source.mDataByteSize, destination.mDataByteSize)) / MemoryLayout<Float>.size
        let channels = Int(source.mNumberChannels)
        let sourceSamples = sourceData.assumingMemoryBound(to: Float.self)
        let destinationSamples = destinationData.assumingMemoryBound(to: Float.self)
        let requested = Float(OSAtomicAdd32Barrier(0, &target)) / 10000
        // Above unity a linked-stereo peak limiter keeps boosted output under
        // the clip ceiling; at or below unity the path stays bit-exact gain.
        let boosting = requested > 1 || current > 1
        for frame in 0..<(count / channels) {
            current += min(step, max(-step, requested - current))
            if boosting {
                var peak = Float(0)
                for channel in 0..<channels {
                    peak = max(peak, abs(sourceSamples[frame * channels + channel] * current))
                }
                envelope = max(peak, envelope * releaseCoef)
                let scale = envelope > 0.98 ? 0.98 / envelope : 1
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    destinationSamples[index] = sourceSamples[index] * current * scale
                }
            } else {
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    destinationSamples[index] = sourceSamples[index] * current
                }
            }
        }
    }
}
