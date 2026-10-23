import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v3 through FluidAudio's Core ML pipeline. FluidAudio is
/// held in offline mode: Nano downloads and verifies every file itself, and a
/// missing file surfaces as an error instead of a surprise network fetch.
///
/// Parakeet takes no text prompt, so vocabulary reaches it through the
/// optional booster: a small CTC model scores the audio for each term and
/// FluidAudio's rescorer swaps in a term where the acoustics back it up.
actor ParakeetRecognizer: VoiceDictationRecognizer {
    private let directory: URL
    private let boosterDirectory: URL?
    private var manager: AsrManager?
    private var decoderLayers = 2
    /// The booster's CTC model, loaded and warmed with the engine so neither
    /// the load nor the one-time Neural Engine compile lands in a dictation.
    private var boosterModels: ParakeetVocabularyBooster.Models?
    private var booster: ParakeetVocabularyBooster?

    nonisolated let acceleratorDescription = "Neural Engine (Core ML) via FluidAudio"

    init(directory: URL, boosterDirectory: URL?) {
        self.directory = directory
        self.boosterDirectory = boosterDirectory
    }

    var isLoaded: Bool { manager != nil }

    func load() async throws {
        guard manager == nil else { return }
        ModelHub.offlineMode = true
        do {
            let models = try await AsrModels.load(from: directory, version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            decoderLayers = await manager.decoderLayerCount
            self.manager = manager
        } catch {
            throw VoiceDictationError.modelLoadFailed(
                "Parakeet failed to load: \(error.localizedDescription)"
            )
        }
        // Optional: a booster that fails to load only costs the boost.
        if let boosterDirectory, boosterModels == nil {
            boosterModels = try? await ParakeetVocabularyBooster.Models.loadWarm(from: boosterDirectory)
        }
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
        booster = nil
        boosterModels = nil
    }

    func transcribe(_ samples: [Float], request: VoiceDictationRecognitionRequest) async throws -> VoiceDictationRecognition {
        try await load()
        guard let manager else {
            throw VoiceDictationError.modelLoadFailed("Parakeet is not loaded.")
        }
        let audio = VoiceDictationEngineFactory.padded(samples, minimumSeconds: 1.0)
        let booster = await booster(for: request.vocabulary)
        // The booster's acoustic pass needs only the audio, so it runs
        // alongside recognition instead of after it.
        async let spotted = booster?.spot(audio)
        let result: ASRResult
        do {
            result = try await Self.recognize(audio, manager: manager, decoderLayers: decoderLayers)
        } catch {
            _ = await spotted
            throw VoiceDictationError.recognitionFailed(
                "Parakeet failed: \(error.localizedDescription)"
            )
        }
        var recognition = VoiceDictationRecognition(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let booster, let spot = await spotted,
           let timings = result.tokenTimings, !timings.isEmpty,
           let boosted = booster.rescore(text: recognition.text, timings: timings, spot: spot) {
            recognition.text = boosted.text
            recognition.boostedTerms = boosted.terms
        }
        return recognition
    }

    private static func recognize(_ audio: [Float], manager: AsrManager, decoderLayers: Int) async throws -> ASRResult {
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        return try await manager.transcribe(audio, decoderState: &state)
    }

    /// Rebuilt when the term list changes; the model underneath is reused.
    private func booster(for terms: [String]) async -> ParakeetVocabularyBooster? {
        guard let boosterDirectory, let boosterModels else { return nil }
        let usable = ParakeetVocabularyBooster.usableTerms(terms)
        guard !usable.isEmpty else { return nil }
        if let booster, booster.terms == usable { return booster }
        booster = try? await ParakeetVocabularyBooster(models: boosterModels, directory: boosterDirectory, terms: usable)
        return booster
    }
}

/// FluidAudio's CTC keyword spotter plus constrained rescoring, assembled from
/// its public pieces so the CTC model is read from Nano's verified model
/// directory rather than FluidAudio's own cache.
struct ParakeetVocabularyBooster: Sendable {
    let terms: [String]
    private let vocabulary: CustomVocabularyContext
    private let spotter: CtcKeywordSpotter
    private let rescorer: VocabularyRescorer
    private let sizeConfig: ContextBiasingConstants.VocabSizeConfig

    /// A dictation dictionary is a handful of names, which is FluidAudio's
    /// short-vocabulary case: the acoustic "rescue" pass, which may swap in a
    /// term the transcript does not resemble, turned "Open the" into "Nano"
    /// and "Um, so" into "Kubernetes" in the benchmark. With it off, a term
    /// must also look like what was recognized. Short terms get a tapered
    /// boost so they cannot beat a correctly heard common word on boost alone.
    static let rescorerConfig = VocabularyRescorer.Config(
        shortTermCbwTaperPivot: 5,
        spotterRescueEnabled: false
    )

    /// Terms shorter than three letters match everything ("or" → "VR").
    static func usableTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.filter(\.isLetter).count >= 3 && seen.insert($0.lowercased()).inserted }
    }

    /// The CTC model and tokenizer, independent of the term list.
    struct Models: Sendable {
        let ctc: CtcModels
        let tokenizer: CtcTokenizer

        /// Loads, then runs one second of silence through the model so the
        /// Neural Engine compile happens now rather than in a dictation.
        static func loadWarm(from directory: URL) async throws -> Models {
            let ctc = try await CtcModels.loadDirect(from: directory, variant: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(from: directory)
            let spotter = CtcKeywordSpotter(models: ctc, blankId: ctc.vocabulary.count)
            _ = try? await spotter.spotKeywordsWithLogProbs(
                audioSamples: [Float](repeating: 0, count: Int(VoiceDictationAudioRecorder.sampleRate)),
                customVocabulary: CustomVocabularyContext(terms: []),
                minScore: nil
            )
            return Models(ctc: ctc, tokenizer: tokenizer)
        }
    }

    init(models: Models, directory: URL, terms: [String]) async throws {
        let tokenized = terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = models.tokenizer.encode(term)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: ids)
        }
        self.terms = terms
        vocabulary = CustomVocabularyContext(terms: tokenized)
        spotter = CtcKeywordSpotter(models: models.ctc, blankId: models.ctc.vocabulary.count)
        sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: tokenized.count)
        rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: vocabulary,
            config: Self.rescorerConfig,
            ctcModelDirectory: directory
        )
    }

    /// The acoustic half: CTC log-probabilities for the audio.
    func spot(_ audio: [Float]) async -> CtcKeywordSpotter.SpotKeywordsResult? {
        guard let result = try? await spotter.spotKeywordsWithLogProbs(
            audioSamples: audio,
            customVocabulary: vocabulary,
            minScore: nil
        ), !result.logProbs.isEmpty else { return nil }
        return result
    }

    func rescore(
        text: String,
        timings: [TokenTiming],
        spot: CtcKeywordSpotter.SpotKeywordsResult
    ) -> (text: String, terms: [String])? {
        let output = rescorer.ctcTokenRescore(
            transcript: text,
            tokenTimings: timings,
            logProbs: spot.logProbs,
            frameDuration: spot.frameDuration,
            cbw: sizeConfig.cbw,
            marginSeconds: 0.5,
            minSimilarity: max(sizeConfig.minSimilarity, vocabulary.minSimilarity)
        )
        guard output.wasModified else { return nil }
        let applied = output.replacements
            .filter(\.shouldReplace)
            .compactMap(\.replacementWord)
        return (output.text, applied)
    }
}
