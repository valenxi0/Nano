import Foundation

/// What a recognizer may use besides the audio.
struct VoiceDictationRecognitionRequest: Sendable, Equatable {
    /// Terms the user wants written their way. Runtimes that can bias toward
    /// them do (Whisper's prompt, Parakeet's booster); the deterministic
    /// vocabulary pass after recognition is still the correction mechanism.
    var vocabulary: [String] = []
    /// ISO 639-1 code, or nil to let the engine detect or decide.
    var language: String?

    /// Whisper's initial prompt: the terms as a short sentence.
    var promptHint: String? {
        vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", ") + "."
    }
}

struct VoiceDictationRecognition: Sendable, Equatable {
    var text: String
    /// ISO 639-1 code the engine decoded in, when it knows.
    var language: String?
    /// Vocabulary terms the booster wrote in place of what was recognized.
    var boostedTerms: [String] = []
}

/// Speech → verbatim text. One adapter per runtime; the controller only sees
/// this interface, so swapping or adding an engine is a data change.
protocol VoiceDictationRecognizer: Sendable {
    var acceleratorDescription: String { get }
    var isLoaded: Bool { get async }
    /// Loads the model. Idempotent; the cold path.
    func load() async throws
    func transcribe(_ samples: [Float], request: VoiceDictationRecognitionRequest) async throws -> VoiceDictationRecognition
    func unload() async
}

/// Raw transcript → cleaned written text.
protocol VoiceDictationCleaner: Sendable {
    var acceleratorDescription: String { get }
    var isLoaded: Bool { get async }
    func load() async throws
    func clean(_ transcript: String, directive: VoiceDictationCleanupDirective) async throws -> String
    func unload() async
}

enum VoiceDictationEngineFactory {
    @MainActor
    static func recognizer(
        for engine: VoiceDictationEngine,
        store: VoiceDictationModelStore
    ) -> VoiceDictationRecognizer {
        switch engine {
        case .parakeetS1:
            return ParakeetRecognizer(
                directory: store.directory(for: .parakeetTDT06BV3),
                boosterDirectory: store.isInstalled(.parakeetVocabularyBooster)
                    ? store.directory(for: .parakeetVocabularyBooster) : nil
            )
        case .cohereTranscribe:
            return CohereRecognizer(directory: store.directory(for: .cohereTranscribe))
        case .whisperTurbo:
            return WhisperCppRecognizer(modelURL: store.primaryFileURL(for: .whisperLargeV3Turbo)!)
        case .whisperBase:
            return WhisperCppRecognizer(modelURL: store.primaryFileURL(for: .whisperBaseEnglish)!)
        case .whisperTiny:
            return WhisperCppRecognizer(modelURL: store.primaryFileURL(for: .whisperTinyEnglish)!)
        }
    }

    @MainActor
    static func cleaner(
        for engine: VoiceDictationEngine,
        store: VoiceDictationModelStore
    ) -> VoiceDictationCleaner? {
        guard engine.appliesCleanup else { return nil }
        return S1MiniCleaner(modelURL: store.primaryFileURL(for: .s1Mini)!)
    }

    /// Performance cores are what ggml wants; efficiency cores slow it down.
    static var inferenceThreads: Int32 {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return count
        }
        return Int32(max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8)))
    }

    /// Pads short clips with silence; every runtime here wants at least a
    /// second of audio to produce stable output.
    static func padded(_ samples: [Float], minimumSeconds: Double) -> [Float] {
        let minimum = Int(VoiceDictationAudioRecorder.sampleRate * minimumSeconds)
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }
}

/// Finds natural pauses in 16 kHz mono audio so long recordings can be cut
/// where no word is spoken.
enum VoiceDictationAudioSegmenter {
    static let windowSeconds = 0.4

    /// The sample index at the center of the quietest 400 ms window in
    /// `range`, provided it is quiet enough to be a pause between words.
    static func pause(in samples: [Float], range: Range<Int>) -> Int? {
        let window = Int(VoiceDictationAudioRecorder.sampleRate * windowSeconds)
        let hop = window / 4
        guard range.count >= window, range.upperBound <= samples.count else { return nil }
        var quietest: (index: Int, rms: Float)?
        var start = range.lowerBound
        while start + window <= range.upperBound {
            var sum: Float = 0
            for index in start ..< start + window { sum += samples[index] * samples[index] }
            let rms = (sum / Float(window)).squareRoot()
            if quietest == nil || rms < quietest!.rms { quietest = (start + window / 2, rms) }
            start += hop
        }
        guard let quietest else { return nil }
        // Room tone on a laptop mic sits well under 0.01 RMS; speech is far
        // above it. A louder room still counts when the window is far below
        // the stretch's overall level, so a steady talker is never cut mid-word.
        let overall = rms(of: samples, range: range)
        guard quietest.rms < 0.012 || quietest.rms < overall * 0.15 else { return nil }
        return quietest.index
    }

    /// Splits audio into pieces no longer than `maxSeconds`, cutting at pauses
    /// where one exists in the last third of each piece and hard-cutting
    /// otherwise.
    static func split(_ samples: [Float], maxSeconds: Double) -> [ArraySlice<Float>] {
        let maximum = Int(VoiceDictationAudioRecorder.sampleRate * maxSeconds)
        guard samples.count > maximum, maximum > 0 else { return [samples[...]] }
        var pieces: [ArraySlice<Float>] = []
        var start = 0
        while samples.count - start > maximum {
            let searchStart = start + maximum * 2 / 3
            let cut = pause(in: samples, range: searchStart ..< start + maximum) ?? start + maximum
            pieces.append(samples[start ..< cut])
            start = cut
        }
        pieces.append(samples[start...])
        return pieces
    }

    private static func rms(of samples: [Float], range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var sum: Float = 0
        for index in range { sum += samples[index] * samples[index] }
        return (sum / Float(range.count)).squareRoot()
    }
}
