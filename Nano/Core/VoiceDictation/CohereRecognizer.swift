import FluidAudio
import Foundation

/// Cohere Transcribe 03-2026 (INT8 encoder, cache-external decoder) through
/// FluidAudio's Core ML pipeline. The model is told its language up front
/// and cannot detect one, so the request always carries a code.
actor CohereRecognizer: VoiceDictationRecognizer {
    /// The decoder's cache holds 108 tokens per window, prompt included. A
    /// 25 s piece of the benchmark's dictation already ran out mid-word
    /// ("which cle"), so pieces are cut at pauses by 20 s.
    static let maximumPieceSeconds = 20.0

    private let directory: URL
    private let pipeline = CoherePipeline()
    private var models: CoherePipeline.LoadedModels?

    nonisolated let acceleratorDescription = "Neural Engine (Core ML) via FluidAudio"

    init(directory: URL) {
        self.directory = directory
    }

    var isLoaded: Bool { models != nil }

    /// Loading takes tens of seconds and the actor is reentrant, so a warm-up
    /// and a dictation arriving together share one load instead of holding
    /// two 2 GB copies.
    private var loading: Task<CoherePipeline.LoadedModels, Error>?

    func load() async throws {
        guard models == nil else { return }
        let task = loading ?? Task { [directory, pipeline] in
            try await Self.loadWarm(directory: directory, pipeline: pipeline)
        }
        loading = task
        do {
            models = try await task.value
            loading = nil
        } catch {
            loading = nil
            throw VoiceDictationError.modelLoadFailed(
                "Cohere Transcribe failed to load: \(error.localizedDescription)"
            )
        }
    }

    private static func loadWarm(directory: URL, pipeline: CoherePipeline) async throws -> CoherePipeline.LoadedModels {
        let weights = directory.appendingPathComponent("q8", isDirectory: true)
        // `.all`, not Neural Engine only: `.cpuAndNeuralEngine` settled at
        // ~2 s per call on an M4 but took the whole process down (no crash
        // report, exit 0) on one of the benchmark clips, every time. `.all`
        // is stable at 5–20 s per call, which is why the engine is labelled
        // experimental.
        let models = try await CoherePipeline.loadModels(
            encoderDir: weights,
            decoderDir: weights,
            vocabDir: directory,
            decoderVariant: .v2,
            computeUnits: .all
        )
        // Core ML specializes the model over its first predictions (the first
        // call took 159 s on an M4). Pay that here, during load, which the
        // controller overlaps with speech or runs right after a download.
        let silence = [Float](repeating: 0, count: Int(VoiceDictationAudioRecorder.sampleRate))
        for _ in 0 ..< 2 {
            _ = try? await pipeline.transcribe(audio: silence, models: models, language: .english, maxNewTokens: 4)
        }
        return models
    }

    func unload() {
        loading?.cancel()
        loading = nil
        models = nil
    }

    func transcribe(_ samples: [Float], request: VoiceDictationRecognitionRequest) async throws -> VoiceDictationRecognition {
        try await load()
        guard let models else {
            throw VoiceDictationError.modelLoadFailed("Cohere Transcribe is not loaded.")
        }
        let language = request.language.flatMap(CohereAsrConfig.Language.init(rawValue:)) ?? .english
        var pieces: [String] = []
        do {
            for piece in VoiceDictationAudioSegmenter.split(samples, maxSeconds: Self.maximumPieceSeconds) {
                let audio = VoiceDictationEngineFactory.padded(Array(piece), minimumSeconds: 1.0)
                let result = try await pipeline.transcribe(audio: audio, models: models, language: language)
                pieces.append(Self.tidy(result.text))
            }
        } catch {
            throw VoiceDictationError.recognitionFailed(
                "Cohere Transcribe failed: \(error.localizedDescription)"
            )
        }
        return VoiceDictationRecognition(
            text: VoiceDictationTextPipeline.join(pieces),
            language: language.rawValue
        )
    }

    /// Drops any special token the detokenizer leaves behind.
    nonisolated static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
