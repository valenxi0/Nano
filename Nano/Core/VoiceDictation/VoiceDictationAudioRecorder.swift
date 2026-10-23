@preconcurrency import AVFoundation
import Foundation

enum VoiceDictationMicrophoneAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted

    static var current: VoiceDictationMicrophoneAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    var title: String {
        switch self {
        case .authorized: "Allowed"
        case .notDetermined: "Not requested"
        case .denied: "Denied"
        case .restricted: "Restricted"
        }
    }
}

/// Captures microphone audio into memory as 16 kHz mono Float32, the input
/// every engine here expects. Audio exists only for the life of one
/// dictation: `stop()` hands the samples to the caller and drops them,
/// `cancel()` drops them unread. Nothing is ever written to disk.
@MainActor
final class VoiceDictationAudioRecorder: ObservableObject {
    nonisolated static let sampleRate: Double = 16_000
    /// Bounds memory for a forgotten toggle: 10 minutes ≈ 38 MB of Float32.
    nonisolated static let maximumDuration: TimeInterval = 600

    @Published private(set) var isRecording = false
    /// Recent input loudness, 0...1, for a live indicator. Updated ~12×/s.
    @Published private(set) var inputLevel: Double = 0

    var didReachMaximumDuration: (() -> Void)?

    private var engine: AVAudioEngine?
    private let sink = SampleSink()
    private var levelTimer: Timer?
    private var configurationObserver: NSObjectProtocol?
    /// Wall-clock start, so a stalled engine cannot hold "Listening" forever:
    /// the sample count stops growing when the input goes away.
    private var startedAt: Date?
    /// Told apart from a late notification that belongs to an earlier recording.
    private var captureGeneration = 0
    private var engineRestarts = 0
    private static let maximumEngineRestarts = 3

    static func requestAccess() async -> Bool {
        switch VoiceDictationMicrophoneAuthorization.current {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    func start() throws {
        guard !isRecording else { return }
        guard VoiceDictationMicrophoneAuthorization.current == .authorized else {
            throw VoiceDictationError.microphoneDenied
        }

        let engine = AVAudioEngine()
        try startCapture(on: engine, keepingAudio: false)

        self.engine = engine
        captureGeneration += 1
        let generation = captureGeneration
        engineRestarts = 0
        startedAt = Date()
        // The engine stops itself when the input device or its format changes
        // (AirPods connecting, a USB microphone unplugged).
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.inputConfigurationChanged(generation: generation)
            }
        }
        isRecording = true
        inputLevel = 0
        startLevelTimer()
    }

    /// Taps the input in its current format and starts the engine. With
    /// `keepingAudio`, what was already captured stays and new audio follows it.
    private func startCapture(on engine: AVAudioEngine, keepingAudio: Bool) throws {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceDictationError.microphoneUnavailable
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw VoiceDictationError.audioCaptureFailed("The input format could not be converted to 16 kHz mono.")
        }

        sink.reset(
            converter: converter,
            targetFormat: targetFormat,
            sourceRate: inputFormat.sampleRate,
            keepingAudio: keepingAudio
        )
        let sink = self.sink
        input.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: inputFormat,
            block: Self.makeTapHandler { [sink] buffer in
                sink.append(buffer)
            }
        )

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceDictationError.audioCaptureFailed(error.localizedDescription)
        }
    }

    /// Continues the same recording on the new input. When that is not
    /// possible the recording ends the way it does at the maximum duration, so
    /// what was captured is still transcribed.
    private func inputConfigurationChanged(generation: Int) {
        guard isRecording, generation == captureGeneration, let engine else { return }
        // Some changes are announced without stopping the engine.
        guard !engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineRestarts += 1
        guard engineRestarts <= Self.maximumEngineRestarts else {
            didReachMaximumDuration?()
            return
        }
        do {
            try startCapture(on: engine, keepingAudio: true)
        } catch {
            didReachMaximumDuration?()
        }
    }

    /// AVAudioEngine invokes tap blocks on a realtime audio queue. Build the
    /// block outside this class's MainActor isolation so Swift does not attach
    /// a main-executor precondition to code that only touches the locked sink.
    nonisolated static func makeTapHandler(
        receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in receive(buffer) }
    }

    /// Stops capture and returns everything recorded since `start()`.
    func stop() -> [Float] {
        tearDown()
        return sink.drain()
    }

    /// Stops capture and discards the audio.
    func cancel() {
        tearDown()
        _ = sink.drain()
    }

    var recordedDuration: TimeInterval {
        Double(sink.sampleCount) / Self.sampleRate
    }

    var recordedSampleCount: Int {
        sink.sampleCount
    }

    /// A copy of the audio from `start` up to now, while recording continues.
    /// Lets long dictations be transcribed in pieces before the user stops.
    func samples(from start: Int) -> [Float] {
        sink.copy(from: start)
    }

    private func tearDown() {
        levelTimer?.invalidate()
        levelTimer = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        startedAt = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isRecording = false
        inputLevel = 0
    }

    private func startLevelTimer() {
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.inputLevel = self.sink.recentLevel
                let elapsed = self.startedAt.map { Date().timeIntervalSince($0) } ?? 0
                if self.recordedDuration >= Self.maximumDuration || elapsed >= Self.maximumDuration {
                    self.didReachMaximumDuration?()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }
}

/// Receives tap buffers on the audio thread, resamples, and accumulates.
/// Lock-protected rather than an actor because the tap callback is
/// synchronous realtime code that cannot await.
private final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var ratio: Double = 1
    private var level: Double = 0

    func reset(
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        sourceRate: Double,
        keepingAudio: Bool = false
    ) {
        lock.withLock {
            if !keepingAudio {
                samples.removeAll(keepingCapacity: true)
                samples.reserveCapacity(Int(VoiceDictationAudioRecorder.sampleRate) * 30)
            }
            self.converter = converter
            self.targetFormat = targetFormat
            ratio = VoiceDictationAudioRecorder.sampleRate / sourceRate
            level = 0
        }
    }

    var sampleCount: Int {
        lock.withLock { samples.count }
    }

    var recentLevel: Double {
        lock.withLock { level }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let converter, let targetFormat else { return }

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // The input block is called synchronously from `convert`; the box is
        // how a Sendable closure gets to remember it has handed the buffer over.
        final class Consumed: @unchecked Sendable { var value = false }
        let consumed = Consumed()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData?[0] else { return }

        let count = Int(output.frameLength)
        guard count > 0 else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))

        var sum: Float = 0
        for index in 0 ..< count {
            sum += channel[index] * channel[index]
        }
        let rms = Double((sum / Float(count)).squareRoot())
        // Map roughly -50 dBFS...0 dBFS onto 0...1 with a little smoothing.
        let decibels = 20 * log10(max(rms, 1e-6))
        let normalized = min(max((decibels + 50) / 50, 0), 1)
        level = level * 0.6 + normalized * 0.4
    }

    func copy(from start: Int) -> [Float] {
        lock.withLock {
            guard start < samples.count else { return [] }
            return Array(samples[max(start, 0)...])
        }
    }

    func drain() -> [Float] {
        lock.withLock {
            let drained = samples
            samples = []
            level = 0
            return drained
        }
    }
}
