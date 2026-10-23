import CoreML
import FluidAudio
import Foundation

/// Silero voice activity detection, bundled with Nano (MIT, about 1 MB).
/// Fed 256 ms chunks while the user talks, so on release it already knows
/// where the speech is: a recording with none ends without running the
/// recognizer, and the silence at the end is trimmed before recognition.
actor VoiceDictationVAD {
    nonisolated static let chunk = VadManager.chunkSize
    /// A chunk this likely to be speech counts toward "there was speech".
    /// Kept low: dropping a real dictation is far worse than transcribing
    /// a silent one.
    nonisolated static let presenceThreshold: Float = 0.3
    /// Chunks this likely to be speech set where the speech starts and ends.
    nonisolated static let edgeThreshold: Float = 0.5
    nonisolated static let padBefore = 0.3
    nonisolated static let padAfter = 0.45

    private let manager: VadManager
    private var state: VadStreamState
    private var probabilities: [Float] = []

    private init(manager: VadManager) async {
        self.manager = manager
        state = await manager.makeStreamState()
    }

    static func load() async -> VoiceDictationVAD? {
        guard let url = Bundle.main.url(forResource: "silero-vad-unified-256ms-v6.2.1", withExtension: "mlmodelc") else {
            return nil
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { return nil }
        return await VoiceDictationVAD(manager: VadManager(vadModel: model))
    }

    /// Samples already classified.
    var processedSamples: Int { probabilities.count * Self.chunk }

    func reset() async {
        state = await manager.makeStreamState()
        probabilities = []
    }

    /// Classifies every whole chunk in `samples`, which must start at
    /// `processedSamples`. With `final`, a partial last chunk is padded and
    /// classified too.
    func feed(_ samples: [Float], final: Bool = false) async {
        var start = 0
        while start + Self.chunk <= samples.count || (final && start < samples.count) {
            var piece = Array(samples[start ..< min(start + Self.chunk, samples.count)])
            if piece.count < Self.chunk { piece += [Float](repeating: 0, count: Self.chunk - piece.count) }
            guard let result = try? await manager.processStreamingChunk(piece, state: state) else {
                // A failed chunk counts as speech so it is never dropped.
                probabilities.append(1)
                start += Self.chunk
                continue
            }
            state = result.state
            probabilities.append(result.probability)
            start += Self.chunk
        }
    }

    func hasSpeech(in range: Range<Int>) -> Bool {
        Self.hasSpeech(probabilities, in: range)
    }

    /// The speech inside `range`, padded, or nil when there is none.
    func speech(in range: Range<Int>) -> Range<Int>? {
        Self.speech(probabilities, in: range)
    }

    nonisolated static func chunks(_ probabilities: [Float], in range: Range<Int>) -> Range<Int> {
        let first = max(0, range.lowerBound / chunk)
        let last = min(probabilities.count, (range.upperBound + chunk - 1) / chunk)
        return first ..< max(first, last)
    }

    nonisolated static func hasSpeech(_ probabilities: [Float], in range: Range<Int>) -> Bool {
        let indices = chunks(probabilities, in: range)
        // Audio not yet classified is assumed to be speech.
        if range.upperBound > probabilities.count * chunk { return true }
        return indices.contains { probabilities[$0] >= presenceThreshold }
    }

    nonisolated static func speech(_ probabilities: [Float], in range: Range<Int>) -> Range<Int>? {
        guard hasSpeech(probabilities, in: range) else { return nil }
        let indices = chunks(probabilities, in: range)
        let rate = VoiceDictationAudioRecorder.sampleRate
        guard let first = indices.first(where: { probabilities[$0] >= edgeThreshold }),
              let last = indices.last(where: { probabilities[$0] >= edgeThreshold })
        else { return range }
        let start = max(range.lowerBound, first * chunk - Int(rate * padBefore))
        let end = min(range.upperBound, (last + 1) * chunk + Int(rate * padAfter))
        return start < end ? start ..< end : range
    }
}
