import Foundation
internal import llama

public enum LlamaRuntimeError: Error, Equatable, Sendable {
    case loadFailed(String)
    case contextFailed
    case tokenizeFailed
    case decodeFailed(Int32)
    case promptTooLong
}

/// A GGUF causal LM driven for one purpose: a fixed system prefix, then
/// short user→assistant turns decoded greedily. The system prefix stays in
/// the KV cache, so each turn only pays for its own tokens.
///
/// Not thread-safe; callers serialize access (Nano wraps it in an actor).
public final class LlamaTextModel: @unchecked Sendable {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let vocab: OpaquePointer?
    private var prefixTokenCount: Int32 = 0

    public init(path: String, contextLength: UInt32 = 4096, threads: Int32 = 4) throws {
        _ = Self.backendReady
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw LlamaRuntimeError.loadFailed(
                "llama.cpp could not open \(URL(fileURLWithPath: path).lastPathComponent)."
            )
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = contextLength
        contextParams.n_batch = 2048
        contextParams.n_ubatch = 512
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaRuntimeError.contextFailed
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        self.model = model
        self.context = context
        self.sampler = sampler!
        vocab = llama_model_get_vocab(model)
    }

    deinit {
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
    }

    /// Decodes `prefix` once and keeps it resident. Any earlier prefix is
    /// discarded.
    public func primePrefix(_ prefix: String) throws {
        llama_memory_clear(llama_get_memory(context), true)
        var tokens = try tokenize(prefix)
        try decode(&tokens)
        prefixTokenCount = Int32(tokens.count)
    }

    /// Feeds `turn` after the primed prefix and greedily generates until an
    /// end-of-generation token or `maxNewTokens`. Returns the raw generated
    /// text; callers strip any chat-template residue.
    public func generate(turn: String, maxNewTokens: Int) throws -> String {
        _ = llama_memory_seq_rm(llama_get_memory(context), 0, prefixTokenCount, -1)

        var tokens = try tokenize(turn)
        guard prefixTokenCount + Int32(tokens.count) < Int32(llama_n_ctx(context)) - 64 else {
            throw LlamaRuntimeError.promptTooLong
        }
        try decode(&tokens)

        var output: [UInt8] = []
        var buffer = [CChar](repeating: 0, count: 256)
        for _ in 0 ..< maxNewTokens {
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
            if length > 0 {
                output.append(contentsOf: buffer[0 ..< Int(length)].map { UInt8(bitPattern: $0) })
            }
            var next = [token]
            try decode(&next)
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Token count for `text`, for length budgeting.
    public func tokenCount(of text: String) -> Int {
        (try? tokenize(text).count) ?? 0
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        var tokens = [llama_token](repeating: 0, count: text.utf8.count + 16)
        var count = text.withCString { pointer in
            llama_tokenize(vocab, pointer, Int32(text.utf8.count), &tokens, Int32(tokens.count), false, true)
        }
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = text.withCString { pointer in
                llama_tokenize(vocab, pointer, Int32(text.utf8.count), &tokens, Int32(tokens.count), false, true)
            }
        }
        guard count >= 0 else { throw LlamaRuntimeError.tokenizeFailed }
        return Array(tokens[0 ..< Int(count)])
    }

    private func decode(_ tokens: inout [llama_token]) throws {
        let status = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard status == 0 else { throw LlamaRuntimeError.decodeFailed(status) }
    }

    private static let backendReady: Bool = {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
        return true
    }()
}
