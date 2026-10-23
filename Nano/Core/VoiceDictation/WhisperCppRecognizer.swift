import Foundation
import WhisperRuntime

/// Whisper through whisper.cpp (Metal): the English tiny/base models and the
/// multilingual large-v3-turbo. The Core ML encoder path
/// needs a second model artifact and is not part of this build.
actor WhisperCppRecognizer: VoiceDictationRecognizer {
    private let modelURL: URL
    private var model: WhisperModel?

    nonisolated let acceleratorDescription = "GPU (Metal) via whisper.cpp"

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    var isLoaded: Bool { model != nil }

    func load() throws {
        guard model == nil else { return }
        do {
            model = try WhisperModel(path: modelURL.path)
        } catch let error as WhisperRuntimeError {
            throw VoiceDictationError.modelLoadFailed(Self.describe(error))
        }
    }

    func unload() {
        model = nil
    }

    func transcribe(_ samples: [Float], request: VoiceDictationRecognitionRequest) throws -> VoiceDictationRecognition {
        try load()
        guard let model else {
            throw VoiceDictationError.modelLoadFailed("Whisper is not loaded.")
        }
        // whisper.cpp rejects input shorter than one second.
        let audio = VoiceDictationEngineFactory.padded(samples, minimumSeconds: 1.1)
        let options = WhisperModel.Options(
            language: request.language ?? "auto",
            prompt: request.promptHint,
            threads: VoiceDictationEngineFactory.inferenceThreads
        )
        do {
            let output = try model.transcribeDetectingLanguage(audio, options: options)
            return VoiceDictationRecognition(
                text: Self.tidy(output.text),
                language: output.language ?? request.language
            )
        } catch let error as WhisperRuntimeError {
            throw VoiceDictationError.recognitionFailed(Self.describe(error))
        }
    }

    /// What Whisper writes for sound that is not speech, as the whole content
    /// of a bracket pair: "[BLANK_AUDIO]", "(music)", "[ Laughter ]".
    private static let nonSpeechAnnotation: String = {
        let tags = [
            "blank[ _]audio", "no audio", "no speech", "silence", "inaudible",
            "music", "music playing", "upbeat music", "soft music",
            "laughs", "laughter", "laughing", "applause", "clapping",
            "noise", "background noise", "sighs", "coughs", "coughing", "clears throat",
        ].joined(separator: "|")
        return #"\[\s*(?:"# + tags + #")\s*\]|\(\s*(?:"# + tags + #")\s*\)"#
    }()

    /// Whisper marks non-speech with bracketed tags and leaks leading spaces.
    /// Only those known tags go; anything else the user said in brackets or
    /// parentheses stays.
    nonisolated static func tidy(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: nonSpeechAnnotation,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private nonisolated static func describe(_ error: WhisperRuntimeError) -> String {
        switch error {
        case .loadFailed(let message): message
        case .inferenceFailed(let status): "whisper.cpp returned \(status)."
        }
    }
}
