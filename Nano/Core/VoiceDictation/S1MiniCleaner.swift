import Foundation
import LlamaRuntime

/// S1-mini by Superwhisper, run through llama.cpp from the Q4_K_M GGUF.
///
/// The model card is strict about its input: the exact system prompt, a
/// control line, and an assistant turn that opens with an empty think block.
/// Anything else degrades output. The system prompt is decoded once and kept
/// in the KV cache; each request only pays for its own transcript.
actor S1MiniCleaner: VoiceDictationCleaner {
    static let systemPrompt =
        "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
    /// Only the trained axis values are safe; the card warns that anything
    /// else produces garbled output. The directive's enums are those values.
    nonisolated static func controlLine(for directive: VoiceDictationCleanupDirective) -> String {
        "[Styling: \(directive.styling.rawValue)] [Structure: \(directive.structure.rawValue)] [Context: \(directive.context.rawValue)]"
    }

    private let modelURL: URL
    private var model: LlamaTextModel?

    nonisolated let acceleratorDescription = "GPU (Metal) via llama.cpp"

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    var isLoaded: Bool { model != nil }

    func load() throws {
        guard model == nil else { return }
        do {
            let model = try LlamaTextModel(
                path: modelURL.path,
                contextLength: 4096,
                threads: VoiceDictationEngineFactory.inferenceThreads
            )
            try model.primePrefix(Self.systemTurn)
            self.model = model
        } catch let error as LlamaRuntimeError {
            throw VoiceDictationError.modelLoadFailed(Self.describe(error))
        }
    }

    func unload() {
        model = nil
    }

    func clean(_ transcript: String, directive: VoiceDictationCleanupDirective) throws -> String {
        try load()
        guard let model else {
            throw VoiceDictationError.modelLoadFailed("S1-mini is not loaded.")
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let turn = Self.userTurn(for: trimmed, directive: directive)
        // Output length tracks input length; 1.3× + 32 is the card's ceiling.
        let budget = min(Int(Double(model.tokenCount(of: trimmed)) * 1.3) + 32, 1024)
        do {
            return Self.tidy(try model.generate(turn: turn, maxNewTokens: budget))
        } catch let error as LlamaRuntimeError {
            throw VoiceDictationError.cleanupFailed(Self.describe(error))
        }
    }

    /// Removes a stray think block if the model ever emits one, then trims.
    nonisolated static func tidy(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: "<|im_end|>", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static var systemTurn: String {
        "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
    }

    nonisolated static func userTurn(for transcript: String, directive: VoiceDictationCleanupDirective = .polished) -> String {
        "<|im_start|>user\n\(controlLine(for: directive))\n\(transcript)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    private nonisolated static func describe(_ error: LlamaRuntimeError) -> String {
        switch error {
        case .loadFailed(let message): message
        case .contextFailed: "llama.cpp could not create a context for S1-mini."
        case .tokenizeFailed: "S1-mini could not tokenize the transcript."
        case .decodeFailed(let status): "llama.cpp decode returned \(status)."
        case .promptTooLong: "The transcript is too long for one cleanup pass."
        }
    }
}
