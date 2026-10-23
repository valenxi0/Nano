import Foundation
internal import whisper

public enum WhisperRuntimeError: Error, Equatable, Sendable {
    case loadFailed(String)
    case inferenceFailed(Int32)
}

/// One loaded Whisper model. Not thread-safe; callers serialize access
/// (Nano wraps it in an actor).
public final class WhisperModel: @unchecked Sendable {
    public struct Options: Sendable {
        public var language: String
        public var prompt: String?
        public var threads: Int32

        public init(language: String = "en", prompt: String? = nil, threads: Int32 = 4) {
            self.language = language
            self.prompt = prompt
            self.threads = threads
        }
    }

    private let context: OpaquePointer

    /// Loads a ggml `.bin` model with Metal enabled.
    public init(path: String) throws {
        _ = Self.logsSilenced
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let context = whisper_init_from_file_with_params(path, params) else {
            throw WhisperRuntimeError.loadFailed(
                "whisper.cpp could not open \(URL(fileURLWithPath: path).lastPathComponent)."
            )
        }
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    /// 16 kHz mono Float32 in, joined segment text out. Callers must supply at
    /// least one second of audio; whisper.cpp rejects shorter input.
    public func transcribe(_ samples: [Float], options: Options) throws -> String {
        try transcribeDetectingLanguage(samples, options: options).text
    }

    /// Same as `transcribe`, plus the language whisper.cpp decoded in. Pass
    /// `"auto"` as the language to let a multilingual model detect it.
    public func transcribeDetectingLanguage(
        _ samples: [Float],
        options: Options
    ) throws -> (text: String, language: String?) {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = true
        params.single_segment = false
        params.translate = false
        params.no_context = true
        params.suppress_blank = true
        params.suppress_nst = true
        params.n_threads = options.threads

        return try options.language.withCString { language in
            params.language = language
            return try Self.withOptionalCString(options.prompt) { prompt in
                params.initial_prompt = prompt
                let status = samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
                guard status == 0 else { throw WhisperRuntimeError.inferenceFailed(status) }
                var pieces: [String] = []
                for index in 0 ..< whisper_full_n_segments(context) {
                    if let segment = whisper_full_get_segment_text(context, index) {
                        pieces.append(String(cString: segment))
                    }
                }
                let languageID = whisper_full_lang_id(context)
                let language = languageID >= 0 ? whisper_lang_str(languageID).map { String(cString: $0) } : nil
                return (pieces.joined(separator: " "), language)
            }
        }
    }

    private static func withOptionalCString<R>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) throws -> R
    ) throws -> R {
        guard let string, !string.isEmpty else { return try body(nil) }
        return try string.withCString { try body($0) }
    }

    /// whisper.cpp logs every load to stderr unless told otherwise.
    private static let logsSilenced: Bool = {
        whisper_log_set({ _, _, _ in }, nil)
        return true
    }()
}
