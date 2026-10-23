import AppKit
import SwiftUI
@preconcurrency import AVFoundation
import XCTest
@testable import Nano

/// Quill 1.1: app-aware formatting, languages, correction learning, list
/// import, remote control and early segmentation.
@MainActor
final class VoiceDictationQuillTests: XCTestCase {
    // MARK: Developer Mode

    func testCommandFormatterWritesFlagsAndQuotes() {
        XCTAssertEqual(
            VoiceDictationCommandFormatter.format("Git commit dash m quote fix the build quote."),
            #"git commit -m "fix the build""#
        )
        XCTAssertEqual(
            VoiceDictationCommandFormatter.format("npm install dash dash save dash dev"),
            "npm install --save-dev"
        )
        XCTAssertEqual(
            VoiceDictationCommandFormatter.format("git push dash dash no dash verify"),
            "git push --no-verify"
        )
    }

    func testCommandFormatterGluesPathSymbols() {
        XCTAssertEqual(VoiceDictationCommandFormatter.format("cd tilde slash projects"), "cd ~/projects")
        XCTAssertEqual(VoiceDictationCommandFormatter.format("cat read me dot md"), "cat read me.md")
        XCTAssertEqual(VoiceDictationCommandFormatter.format("ls star dot swift"), "ls *.swift")
        XCTAssertEqual(
            VoiceDictationCommandFormatter.format("curl localhost colon 3000 slash health"),
            "curl localhost:3000/health"
        )
    }

    func testCommandFormatterHonoursSpaceAndCapital() {
        XCTAssertEqual(VoiceDictationCommandFormatter.format("ls dash capital R"), "ls -R")
        XCTAssertEqual(VoiceDictationCommandFormatter.format("ls dash L A"), "ls -l A")
        XCTAssertEqual(VoiceDictationCommandFormatter.format("echo hi space greater than space out dot txt"), "echo hi > out.txt")
        XCTAssertEqual(VoiceDictationCommandFormatter.format("cat log pipe grep error"), "cat log | grep error")
    }

    func testCommandFormatterKeepsWhatTheRecognizerAlreadyWrote() {
        XCTAssertEqual(VoiceDictationCommandFormatter.format("Git commit -m, done."), "git commit -m done")
        XCTAssertEqual(VoiceDictationCommandFormatter.format("README"), "README")
    }

    func testAppContextClassification() {
        XCTAssertEqual(VoiceDictationAppContext.classify(bundleID: "com.apple.Terminal", focusedDescription: nil), .terminal)
        XCTAssertEqual(VoiceDictationAppContext.classify(bundleID: "com.mitchellh.ghostty", focusedDescription: nil), .terminal)
        XCTAssertEqual(
            VoiceDictationAppContext.classify(bundleID: "com.todesktop.230313mzl4w4u92", focusedDescription: "Terminal 1, zsh"),
            .terminal
        )
        XCTAssertEqual(
            VoiceDictationAppContext.classify(bundleID: "com.microsoft.VSCode", focusedDescription: "Editor content"),
            .general
        )
        XCTAssertEqual(VoiceDictationAppContext.classify(bundleID: "com.tinyspeck.slackmacgap", focusedDescription: nil), .chat)
        XCTAssertEqual(VoiceDictationAppContext.classify(bundleID: "com.apple.mail", focusedDescription: nil), .email)
        XCTAssertEqual(VoiceDictationAppContext.classify(bundleID: "com.apple.Notes", focusedDescription: nil), .general)
        XCTAssertEqual(VoiceDictationAppContext.classify(bundleID: nil, focusedDescription: nil), .general)
    }

    func testTerminalTabRunningAnAgentIsAnAgentPrompt() {
        let ghostty = "com.mitchellh.ghostty"
        XCTAssertEqual(VoiceDictationAppContext.classify(bundleID: ghostty, focusedDescription: nil, windowTitle: "✳ Fix the island hover"), .agent)
        XCTAssertEqual(VoiceDictationAppContext.classify(bundleID: ghostty, focusedDescription: nil, windowTitle: "codex — North-Star"), .agent)
        XCTAssertEqual(VoiceDictationAppContext.classify(bundleID: ghostty, focusedDescription: nil, windowTitle: "claude"), .agent)
        XCTAssertEqual(
            VoiceDictationAppContext.classify(bundleID: ghostty, focusedDescription: nil, windowTitle: "~/Coding/North-Star", agentNames: ["North-Star"]),
            .agent,
            "a terminal titled after a project with a live agent session"
        )
        XCTAssertEqual(VoiceDictationAppContext.classify(bundleID: ghostty, focusedDescription: nil, windowTitle: "zsh — ~/Downloads"), .terminal)
        XCTAssertEqual(VoiceDictationAppContext.classify(bundleID: ghostty, focusedDescription: nil, windowTitle: "vim claudette.txt"), .terminal)
        XCTAssertTrue(VoiceDictationAppContext.agent.isTerminal)
    }

    func testChatStyleDropsFullStopOnOneSentenceOnly() {
        XCTAssertEqual(VoiceDictationChatStyle.apply("Sounds good, see you at five."), "Sounds good, see you at five")
        XCTAssertEqual(VoiceDictationChatStyle.apply("Done. Shipping now."), "Done. Shipping now.")
        XCTAssertEqual(VoiceDictationChatStyle.apply("Are you in?"), "Are you in?")
        XCTAssertEqual(VoiceDictationChatStyle.apply("Wait..."), "Wait...")
    }

    // MARK: Numbers and language

    func testNumberFormatterWritesFigures() throws {
        try XCTSkipUnless(VoiceDictationNumberFormatter.isAvailable, "NeMo text processing is not linked")
        let cases: [(String, String)] = [
            ("that costs twenty five dollars and fifty cents", "that costs $25.50"),
            ("there were twenty five people and two hundred and five chairs", "there were 25 people and 205 chairs"),
            ("we met at four thirty pm on march third", "we met at 4:30 PM on March 3"),
            ("we signed on june fifth twenty twenty six", "we signed on June 5, 2026"),
            ("the meeting is on march twenty first", "the meeting is on March 21"),
            ("call four one five five five five zero one nine eight", "call 415-555-0198"),
            ("about fifteen percent of users", "about 15% of users"),
            ("it takes one point five seconds", "it takes 1.5 seconds"),
            ("Twenty twenty six was a good year", "2026 was a good year"),
        ]
        for (spoken, written) in cases {
            XCTAssertEqual(VoiceDictationNumberFormatter.format(spoken), written)
        }
    }

    func testNumberFormatterLeavesProseAlone() throws {
        try XCTSkipUnless(VoiceDictationNumberFormatter.isAvailable, "NeMo text processing is not linked")
        for sentence in [
            "one of the things I want is to go to the store",
            "I have two kids and one dog",
            "the first time I saw it",
            "they may one day return",
            "wait a second",
            "it was a period of growth, period",
            "",
        ] {
            XCTAssertEqual(VoiceDictationNumberFormatter.format(sentence), sentence)
        }
    }

    func testTerminalWritesEveryNumberAsDigits() throws {
        try XCTSkipUnless(VoiceDictationNumberFormatter.isAvailable, "NeMo text processing is not linked")
        let spoken = VoiceDictationCommandFormatter.format("tail dash n five server dot log")
        XCTAssertEqual(VoiceDictationNumberFormatter.format(spoken, allDigits: true), "tail -n 5 server.log")
    }

    func testLanguageGuessTrustsTheEngineThenTheText() {
        XCTAssertTrue(VoiceDictationLanguageGuess.isEnglish("Hola", reported: "en"))
        XCTAssertFalse(VoiceDictationLanguageGuess.isEnglish("Hello there", reported: "de"))
        XCTAssertFalse(VoiceDictationLanguageGuess.isEnglish(
            "Hola, ¿cómo estás? Mañana vamos a la playa con mis amigos.", reported: nil
        ))
        XCTAssertTrue(VoiceDictationLanguageGuess.isEnglish(
            "Let's move the standup to Thursday afternoon.", reported: nil
        ))
        XCTAssertTrue(VoiceDictationLanguageGuess.isEnglish("Kubernetes", reported: nil), "too short to judge")
    }

    func testEngineLanguageResolution() {
        XCTAssertNil(VoiceDictationEngine.parakeetS1.recognitionLanguage(for: "de"))
        XCTAssertEqual(VoiceDictationEngine.whisperBase.recognitionLanguage(for: "de"), "en")
        XCTAssertNil(VoiceDictationEngine.whisperTurbo.recognitionLanguage(for: VoiceDictationLanguage.automatic))
        XCTAssertEqual(VoiceDictationEngine.whisperTurbo.recognitionLanguage(for: "fr"), "fr")
        XCTAssertEqual(VoiceDictationEngine.cohereTranscribe.recognitionLanguage(for: "ja"), "ja")
        XCTAssertEqual(
            VoiceDictationEngine.cohereTranscribe.recognitionLanguage(
                for: VoiceDictationLanguage.automatic, preferredLanguages: ["de-DE", "en-US"]
            ),
            "de"
        )
        XCTAssertEqual(
            VoiceDictationEngine.cohereTranscribe.recognitionLanguage(
                for: VoiceDictationLanguage.automatic, preferredLanguages: ["sv-SE"]
            ),
            "en",
            "unsupported system language falls back to English"
        )
    }

    func testEveryEngineHasModelsAndLanguagesAreCohereSupported() {
        for engine in VoiceDictationEngine.allCases {
            XCTAssertFalse(engine.requiredModels.isEmpty, "\(engine)")
        }
        XCTAssertEqual(VoiceDictationLanguage.all.count, 14)
        XCTAssertEqual(VoiceDictationEngine.parakeetS1.optionalModels, [.parakeetVocabularyBooster])
        XCTAssertEqual(VoiceDictationModelManifest.primaryFile(for: .whisperLargeV3Turbo), "ggml-large-v3-turbo-q5_0.bin")
    }

    // MARK: Correction learning

    func testCorrectionDiffFindsMisheardWords() {
        let pairs = VoiceDictationCorrectionDiff.corrections(
            original: "We moved the cooper netties cluster to Postgres.",
            edited: "We moved the Kubernetes cluster to Postgres."
        )
        XCTAssertEqual(pairs, [.init(spoken: "cooper netties", written: "Kubernetes")])
    }

    func testCorrectionDiffFindsCaseFixesButNotSentenceStarts() {
        XCTAssertEqual(
            VoiceDictationCorrectionDiff.corrections(original: "I love using nano every day.", edited: "I love using Nano every day."),
            [.init(spoken: "nano", written: "Nano")]
        )
        XCTAssertEqual(
            VoiceDictationCorrectionDiff.corrections(original: "done. then we ship", edited: "done. Then we ship"),
            []
        )
    }

    func testCorrectionDiffIgnoresRewritesAndCountsDeletions() {
        XCTAssertEqual(
            VoiceDictationCorrectionDiff.corrections(original: "That is a big problem for us.", edited: "That is a large problem for us."),
            [],
            "a synonym is a change of mind, not a misheard word"
        )
        XCTAssertEqual(
            VoiceDictationCorrectionDiff.corrections(original: "Ship it on Thursday please.", edited: "Ship it on Thursday."),
            [.init(kind: .leaveOut, spoken: "please", written: "")],
            "a deleted word is a candidate to leave out; it is only suggested after repeats"
        )
        XCTAssertEqual(
            VoiceDictationCorrectionDiff.corrections(original: "one two three four", edited: "completely different words here"),
            []
        )
    }

    func testCorrectionStoreSuggestsAfterRepeatsAndSkipsKnownTerms() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corrections-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VoiceDictationCorrectionStore(fileURL: url)
        let pair = VoiceDictationCorrectionDiff.Pair(spoken: "cooper netties", written: "Kubernetes")

        store.record([pair])
        XCTAssertTrue(store.suggestions(excluding: []).isEmpty, "one fix is not a pattern")
        store.record([pair])
        XCTAssertEqual(store.suggestions(excluding: []).map(\.written), ["Kubernetes"])

        let known = VoiceDictationVocabularyEntry(phrase: "Cooper Netties", replacement: "Kubernetes", kind: .vocabulary)
        XCTAssertTrue(store.suggestions(excluding: [known]).isEmpty)

        XCTAssertEqual(VoiceDictationCorrectionStore(fileURL: url).corrections.first?.count, 2, "persisted")

        store.dismiss(store.corrections[0])
        XCTAssertTrue(store.suggestions(excluding: []).isEmpty)
    }

    func testWatcherRegionUsesAnchorsAroundTheDictation() {
        XCTAssertEqual(
            VoiceDictationCorrectionWatcher.region(in: "Hi Sam, the Kubernetes cluster is up. Thanks", prefix: "Hi Sam, ", suffix: " Thanks"),
            "the Kubernetes cluster is up."
        )
        XCTAssertEqual(VoiceDictationCorrectionWatcher.region(in: "whole field", prefix: "", suffix: ""), "whole field")
        XCTAssertNil(VoiceDictationCorrectionWatcher.region(in: "", prefix: "Hi Sam, ", suffix: ""))
    }

    // MARK: Dictionary import

    func testListImportParsesTermsPairsAndDuplicates() {
        let existing = [VoiceDictationVocabularyEntry(phrase: "north star", replacement: "Nano", kind: .vocabulary)]
        let entries = VoiceDictationVocabularyImport.parse(
            """
            Kubernetes, Postgres
            Priya Ramaswamy
            north star → Nano
            jay son -> JSON
            kubernetes

            """,
            existing: existing
        )
        XCTAssertEqual(entries.map(\.phrase), ["Kubernetes", "Postgres", "Priya Ramaswamy", "jay son"])
        XCTAssertEqual(entries.map(\.replacement), ["Kubernetes", "Postgres", "Priya Ramaswamy", "JSON"])
        XCTAssertTrue(entries.allSatisfy { $0.kind == .vocabulary && $0.isEnabled })
    }

    func testImportedTermsReachTheRecognizerRequest() {
        let pipeline = VoiceDictationTextPipeline(entries: VoiceDictationVocabularyImport.parse("Kubernetes\nsnip"))
        XCTAssertEqual(pipeline.vocabularyTerms, ["Kubernetes", "snip"])
        XCTAssertEqual(VoiceDictationRecognitionRequest(vocabulary: pipeline.vocabularyTerms).promptHint, "Kubernetes, snip.")
        XCTAssertEqual(ParakeetVocabularyBooster.usableTerms(["Kubernetes", "kubernetes", "AI", " Postgres "]), ["Kubernetes", "Postgres"])
    }

    // MARK: Remote control

    func testRemoteURLs() {
        XCTAssertEqual(VoiceDictationRemoteControl.command(for: URL(string: "nano://quill/toggle")!), .toggle)
        XCTAssertEqual(VoiceDictationRemoteControl.command(for: URL(string: "nano://quill/start")!), .start)
        XCTAssertEqual(VoiceDictationRemoteControl.command(for: URL(string: "NANO://Quill/Stop")!), .stop)
        XCTAssertEqual(VoiceDictationRemoteControl.command(for: URL(string: "nano://cancel")!), .cancel)
        XCTAssertNil(VoiceDictationRemoteControl.command(for: URL(string: "nano://quill/explode")!))
        XCTAssertNil(VoiceDictationRemoteControl.command(for: URL(string: "https://quill/toggle")!))
    }

    // MARK: Audio segmentation

    func testSegmenterCutsAtAPauseAndNeverMidSpeech() {
        let rate = Int(VoiceDictationAudioRecorder.sampleRate)
        let speech = (0 ..< rate * 3).map { Float(sin(Double($0) * 0.05) * 0.3) }
        let pause = [Float](repeating: 0.001, count: rate / 2)
        let audio = speech + pause + speech
        let cut = VoiceDictationAudioSegmenter.pause(in: audio, range: 0 ..< audio.count)
        XCTAssertNotNil(cut)
        XCTAssertTrue((rate * 3 ..< rate * 3 + rate / 2).contains(cut!), "cut \(cut!) must fall inside the pause")

        XCTAssertNil(VoiceDictationAudioSegmenter.pause(in: speech, range: 0 ..< speech.count), "continuous speech has no pause")
    }

    func testSegmenterSplitsLongAudioIntoBoundedPieces() {
        let rate = Int(VoiceDictationAudioRecorder.sampleRate)
        let audio = [Float](repeating: 0.2, count: rate * 50)
        let pieces = VoiceDictationAudioSegmenter.split(audio, maxSeconds: 20)
        XCTAssertEqual(pieces.map(\.count).reduce(0, +), audio.count)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= rate * 20 })
        XCTAssertEqual(VoiceDictationAudioSegmenter.split([0.1, 0.2], maxSeconds: 20).count, 1)
    }

    // MARK: Recipes and history

    func testRecipeFollowsTheDestinationApp() throws {
        let suite = "quill-recipe-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NanoSettings(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = VoiceDictationController(
            settings: settings,
            modelStore: VoiceDictationModelStore(rootDirectory: root),
            history: VoiceDictationHistoryStore(fileURL: root.appendingPathComponent("history.json")),
            stats: VoiceDictationStatsStore(fileURL: root.appendingPathComponent("stats.json")),
            corrections: VoiceDictationCorrectionStore(fileURL: root.appendingPathComponent("corrections.json"))
        )
        settings.voiceDictationCleanupLevel = .full
        XCTAssertEqual(controller.makeRecipe(appContext: .general).cleanupLevel, .full)
        XCTAssertEqual(controller.makeRecipe(appContext: .chat).directive, .polished, "chat keeps the chosen style")
        XCTAssertEqual(controller.makeRecipe(appContext: .email).directive?.context, .email)
        XCTAssertEqual(controller.makeRecipe(appContext: .terminal).cleanupLevel, .verbatim)
        XCTAssertNil(controller.makeRecipe(appContext: .terminal).directive)
        XCTAssertFalse(controller.makeRecipe(appContext: .terminal).pipeline.layoutCues, "a command is typed as spoken")
        XCTAssertTrue(controller.makeRecipe(appContext: .general).pipeline.layoutCues)
        settings.voiceDictationStructuresLists = true
        XCTAssertEqual(controller.makeRecipe(appContext: .general).directive?.structure, .lists)
        XCTAssertEqual(controller.makeRecipe(appContext: .agent).cleanupLevel, .full, "an agent prompt is prose")
        XCTAssertTrue(controller.makeRecipe(appContext: .agent).pipeline.layoutCues, "spoken line breaks work in agent prompts")
        settings.voiceDictationLayoutCues = false
        XCTAssertFalse(controller.makeRecipe(appContext: .general).pipeline.layoutCues)
        settings.voiceDictationCleanupLevel = .verbatim
        XCTAssertNil(controller.makeRecipe(appContext: .email).directive, "never adds cleanup the user turned off")

        settings.voiceDictationLanguage = "de"
        XCTAssertEqual(controller.makeRecipe(engine: .cohereTranscribe).request.language, "de")
        XCTAssertNil(controller.makeRecipe(engine: .parakeetS1).request.language)
    }

    func testHistoryDecodesEntriesWrittenBeforeQuill() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"hello","engine":"whisperBase","createdAt":0}]"#
        let entries = try JSONDecoder().decode([VoiceDictationHistoryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.first?.text, "hello")
        XCTAssertNil(entries.first?.appName)
        XCTAssertNil(entries.first?.latency)
    }

    func testDefaultsForNewSettings() throws {
        let suite = "quill-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NanoSettings(defaults: defaults)
        XCTAssertEqual(settings.voiceDictationLanguage, VoiceDictationLanguage.automatic)
        XCTAssertTrue(settings.voiceDictationWritesNumbers)
        XCTAssertTrue(settings.voiceDictationAdaptsToApp)
        XCTAssertTrue(settings.voiceDictationLearnsCorrections)
    }
}

/// What came over from Quill for Windows 0.2.2 and 0.3.0, and Sketch.
@MainActor
final class VoiceDictationQuillPortTests: XCTestCase {
    private let rate = Int(VoiceDictationAudioRecorder.sampleRate)

    func testAppEntryOverridesGlobalEntryWithTheSamePhrase() {
        let global = VoiceDictationVocabularyEntry(phrase: "rust", replacement: "Rust", kind: .vocabulary)
        let chat = VoiceDictationVocabularyEntry(
            phrase: "Rust", replacement: "rust", kind: .vocabulary, bundleID: "com.hnc.Discord", appName: "Discord"
        )
        let other = VoiceDictationVocabularyEntry(phrase: "nano", replacement: "Nano", kind: .vocabulary)
        let off = VoiceDictationVocabularyEntry(phrase: "off", replacement: "OFF", kind: .vocabulary, isEnabled: false)
        let all = [global, chat, other, off]

        XCTAssertEqual(VoiceDictationVocabularyEntry.forApp(all, bundleID: "com.hnc.discord").map(\.id), [chat.id, other.id])
        XCTAssertEqual(VoiceDictationVocabularyEntry.forApp(all, bundleID: "com.apple.dt.Xcode").map(\.id), [global.id, other.id])
        XCTAssertEqual(VoiceDictationVocabularyEntry.forApp(all, bundleID: nil).map(\.id), [global.id, other.id])
    }

    func testAppStyleOverridesTheDefaultStyle() {
        let styles = [VoiceDictationAppStyle(bundleID: "com.hnc.Discord", appName: "Discord", level: .light)]
        XCTAssertEqual(VoiceDictationAppStyle.level(default: .full, styles: styles, bundleID: "com.hnc.discord"), .light)
        XCTAssertEqual(VoiceDictationAppStyle.level(default: .full, styles: styles, bundleID: "com.apple.mail"), .full)
        XCTAssertEqual(VoiceDictationAppStyle.level(default: .full, styles: styles, bundleID: nil), .full)
    }

    func testMakeRecipeUsesTheAppsStyleButTerminalsStayVerbatim() {
        let defaults = UserDefaults(suiteName: "nano-port-\(UUID().uuidString)")!
        let settings = NanoSettings(defaults: defaults)
        settings.voiceDictationAppStyles = [
            VoiceDictationAppStyle(bundleID: "com.hnc.Discord", appName: "Discord", level: .light),
            VoiceDictationAppStyle(bundleID: "com.apple.Terminal", appName: "Terminal", level: .full),
        ]
        let controller = VoiceDictationController(settings: settings)
        XCTAssertEqual(controller.makeRecipe(appContext: .chat, bundleID: "com.hnc.Discord").cleanupLevel, .light)
        XCTAssertEqual(controller.makeRecipe(appContext: .general, bundleID: "com.apple.mail").cleanupLevel, settings.voiceDictationCleanupLevel)
        XCTAssertEqual(controller.makeRecipe(appContext: .terminal, bundleID: "com.apple.Terminal").cleanupLevel, .verbatim)
        XCTAssertFalse(controller.makeRecipe(appContext: .terminal).emojiNames)
    }

    func testFinishStripsPressEnterThenAppliesChatStyleThenFitsTheCursor() {
        let controller = VoiceDictationController(settings: NanoSettings(defaults: UserDefaults(suiteName: "nano-port-\(UUID().uuidString)")!))
        var recipe = controller.makeRecipe(appContext: .chat)
        recipe.spokenEnter = true
        let sent = VoiceDictationController.finish("Sounds good. Press enter.", recipe: recipe)
        XCTAssertEqual(sent.text, "Sounds good")
        XCTAssertTrue(sent.pressEnter)

        recipe.spokenEnter = false
        XCTAssertEqual(
            VoiceDictationController.finish("Sounds good. Press enter.", recipe: recipe).text,
            "Sounds good. Press enter.",
            "off, the words are typed; two sentences keep their stops in chat"
        )

        var prose = controller.makeRecipe(appContext: .general)
        prose.surroundings = VoiceDictationSurroundings(before: "I think we should", after: " today.")
        XCTAssertEqual(VoiceDictationController.finish("Ship it.", recipe: prose).text, " ship it")
    }

    func testPreviewCaptionKeepsTheNewestWordsWhole() {
        XCTAssertEqual(VoiceDictationController.previewCaption("  hello there "), "hello there")
        let long = (1 ... 60).map { "word\($0)" }.joined(separator: " ")
        let caption = VoiceDictationController.previewCaption(long, limit: 40)
        XCTAssertTrue(caption.hasPrefix("…word"))
        XCTAssertTrue(caption.hasSuffix("word60"))
        XCTAssertLessThanOrEqual(caption.count, 41)
    }

    // MARK: Sketch

    /// Loud "speech" with silence over `quiet` (in seconds).
    private func speech(seconds: Double, quiet: [ClosedRange<Double>]) -> [Float] {
        (0 ..< Int(seconds * Double(rate))).map { index in
            let time = Double(index) / Double(rate)
            if quiet.contains(where: { $0.contains(time) }) { return 0 }
            return Float(sin(Double(index) * 0.07) * 0.3)
        }
    }

    func testSketchMarkLandsInThePauseBeforeItsStroke() {
        let samples = speech(seconds: 4, quiet: [1.0 ... 1.5])
        let cuts = VoiceDictationSketchText.cuts(marks: [(number: 1, sample: Int(1.7 * Double(rate)))], samples: samples)
        XCTAssertEqual(cuts.count, 1)
        XCTAssertEqual(cuts[0].marks, [1])
        XCTAssertGreaterThanOrEqual(cuts[0].sample, rate)
        XCTAssertLessThanOrEqual(cuts[0].sample, Int(1.5 * Double(rate)))
    }

    func testSketchMarksCloseTogetherShareOnePlaceAndEdgesSnap() {
        let samples = speech(seconds: 4, quiet: [])
        let cuts = VoiceDictationSketchText.cuts(
            marks: [(number: 2, sample: rate * 2 + 1000), (number: 1, sample: rate * 2), (number: 3, sample: 100)],
            samples: samples
        )
        XCTAssertEqual(cuts.map(\.marks), [[3], [1, 2]])
        XCTAssertEqual(cuts[0].sample, 0)
        let pieces = VoiceDictationSketchText.pieces(of: samples, at: cuts)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces.map(\.count).reduce(0, +), samples.count)
    }

    private func plainImage(_ gray: CGFloat, size: Int = 64) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    func testSketchTextListsEachScreenshotWithItsTimeTagAndWords() {
        let rate = Int(VoiceDictationAudioRecorder.sampleRate)
        let stroke = { (number: Int, sample: Int) in
            VoiceDictationSketchStroke(points: [.zero, CGPoint(x: 20, y: 0)], startSample: sample, number: number)
        }
        let moments = [
            VoiceDictationSketchMoment(kind: .marks, sample: rate * 3, image: plainImage(0.2), strokes: [stroke(1, rate * 3)]),
            VoiceDictationSketchMoment(
                kind: .click, sample: rate * 9, image: plainImage(0.5), click: .zero,
                place: VoiceDictationSketchPlace(app: "Safari", window: "GitHub", element: "link “Pull requests”")
            ),
            VoiceDictationSketchMoment(kind: .marks, sample: rate * 15, image: plainImage(0.8), strokes: [stroke(2, rate * 15), stroke(3, rate * 18)]),
        ]
        let anchors = VoiceDictationSketchPicker.anchors(for: moments)
        XCTAssertEqual(anchors.map(\.label), [nil, nil, "[1]", "[2]"])
        let cuts = anchors.enumerated().map { VoiceDictationSketchCut(sample: $0.element.sample, marks: [$0.offset]) }
        let text = VoiceDictationSketchText.compose(
            pieces: ["Look at", "This button. It's off.", "Now the menu opens.", "And this header", "Should be bold."],
            cuts: cuts,
            anchors: anchors,
            frames: moments.map { (time: Double($0.sample) / Double(rate), tag: $0.tag, place: $0.place.description) }
        )
        XCTAssertEqual(text, """
        - #1 (0:03) “Look at this button. It's off.”
        - #2 (0:09) in Safari “GitHub” [clicked link “Pull requests”] “Now the menu opens.”
        - #3 (0:15) “[1] And this header [2] should be bold.”
        """)
        XCTAssertEqual(VoiceDictationSketchPlace(app: "Nano", window: "Nano").description, "in Nano")
        XCTAssertNil(VoiceDictationSketchPlace().description)
        XCTAssertEqual(
            VoiceDictationSketchText.header(duration: 42, folder: nil, display: (CGSize(width: 1512, height: 982), 2)),
            "[Sketch 0:42 · 1512×982 pt display at 2x]"
        )
        XCTAssertEqual(
            VoiceDictationSketchText.compose(pieces: ["Just talking"], cuts: [], anchors: [], frames: [] as [(time: Double, tag: String?, place: String?)]),
            "Just talking"
        )
        XCTAssertEqual(VoiceDictationSketchText.header(duration: 72.4, folder: nil), "[Sketch 1:12]")
    }

    func testPickerDropsRepeatsOfTheSameScreenButNeverMarks() {
        let rate = Int(VoiceDictationAudioRecorder.sampleRate)
        let mark = VoiceDictationSketchStroke(points: [.zero, CGPoint(x: 20, y: 0)], startSample: rate * 4, number: 1)
        let picked = VoiceDictationSketchPicker.pick([
            VoiceDictationSketchMoment(kind: .start, sample: rate / 2, image: plainImage(0.2)),
            VoiceDictationSketchMoment(kind: .marks, sample: rate * 4, image: plainImage(0.2), strokes: [mark]),
            VoiceDictationSketchMoment(kind: .change, sample: rate * 6, image: plainImage(0.9)),
            VoiceDictationSketchMoment(kind: .click, sample: rate * 8, image: plainImage(0.9), click: .zero),
        ], seconds: 10)
        XCTAssertEqual(picked.map(\.kind), [.marks, .click], "the start matched the marked screen, the change matched the click")
    }

    func testPickerKeepsMarksAndClicksOverChangesWhenOverBudget() {
        let rate = Int(VoiceDictationAudioRecorder.sampleRate)
        var moments: [VoiceDictationSketchMoment] = (0 ..< 10).map { index in
            VoiceDictationSketchMoment(kind: .change, sample: rate * index * 2, image: plainImage(CGFloat(index) / 10))
        }
        moments.append(VoiceDictationSketchMoment(kind: .click, sample: rate * 3, image: plainImage(0.95), click: .zero))
        let mark = VoiceDictationSketchStroke(points: [.zero, CGPoint(x: 20, y: 0)], startSample: rate * 5, number: 1)
        moments.append(VoiceDictationSketchMoment(kind: .marks, sample: rate * 5, image: plainImage(0.05), strokes: [mark]))
        let picked = VoiceDictationSketchPicker.pick(moments, seconds: 20)
        XCTAssertEqual(picked.count, VoiceDictationSketchPicker.budget(seconds: 20))
        XCTAssertTrue(picked.contains { $0.kind == .marks })
        XCTAssertTrue(picked.contains { $0.kind == .click })
        XCTAssertEqual(picked.map(\.sample), picked.map(\.sample).sorted())
        XCTAssertEqual(VoiceDictationSketchPicker.budget(seconds: 100), 9)
        XCTAssertEqual(VoiceDictationSketchPicker.budget(seconds: 1000), 10)
    }

    func testLearnedCorrectionIsRememberedEverywhereUnlessAsked() {
        let defaults = UserDefaults(suiteName: "nano-port-\(UUID().uuidString)")!
        let settings = NanoSettings(defaults: defaults)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = VoiceDictationController(settings: settings, corrections: VoiceDictationCorrectionStore(fileURL: url))
        let correction = VoiceDictationCorrection(
            spoken: "clover", written: "Clova", count: 2, lastSeen: Date(), bundleID: "com.hnc.Discord", appName: "Discord"
        )
        controller.acceptCorrection(correction)
        XCTAssertNil(settings.voiceDictationVocabulary.last?.bundleID)
        controller.acceptCorrection(correction, onlyInItsApp: true)
        XCTAssertEqual(settings.voiceDictationVocabulary.last?.bundleID, "com.hnc.Discord")
    }

    func testZoomCropFramesTheInkAndSkipsWholeScreenMarks() throws {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let rendered = plainImage(0.5, size: 2000)
        // 2000 px wide for 1000 pt, so 2x; a 40 pt mark near the top left.
        let ink = [CGPoint(x: 100, y: 500), CGPoint(x: 140, y: 520)]
        let crop = try XCTUnwrap(VoiceDictationSketchRenderer.crop(rendered, around: ink, screenFrame: screen))
        XCTAssertEqual(crop.width, 720)
        XCTAssertLessThan(crop.height, 2000)
        let everywhere = [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 600)]
        XCTAssertNil(VoiceDictationSketchRenderer.crop(rendered, around: everywhere, screenFrame: screen))
    }

    func testContactSheetPutsScreenshotsTwoToARow() throws {
        func solid(_ width: Int, _ height: Int) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try XCTUnwrap(context.makeImage())
        }
        let one = try solid(1600, 1000)
        XCTAssertTrue(VoiceDictationSketchRenderer.contactSheet([one]) === one)
        let sheet = try XCTUnwrap(VoiceDictationSketchRenderer.contactSheet([one, one, one], maximumWidth: 1208))
        XCTAssertEqual(sheet.width, 1208)
        // Two rows of 592 x 370 cells, with 8 px gutters around them.
        XCTAssertEqual(sheet.height, 8 + 370 + 8 + 370 + 8)
    }

    func testSketchRendererDrawsInkWherePointsWere() throws {
        let width = 400, height = 200
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        // A 200 × 100 pt display at 2x, placed off the origin.
        let screen = CGRect(x: 1000, y: 500, width: 200, height: 100)
        let stroke = VoiceDictationSketchStroke(
            points: [CGPoint(x: 1020, y: 520), CGPoint(x: 1180, y: 520)], startSample: 0, number: 1
        )
        let rendered = try XCTUnwrap(VoiceDictationSketchRenderer.render(image, strokes: [stroke], screenFrame: screen))
        XCTAssertEqual(rendered.width, width)
        let data = try XCTUnwrap(VoiceDictationSketchRenderer.pngData(rendered))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        // Bitmap rows run top-down; the stroke is 20 pt (40 px) up from the bottom.
        let ink = try XCTUnwrap(bitmap.colorAt(x: 200, y: height - 40)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(ink.redComponent, 0.9)
        XCTAssertLessThan(ink.greenComponent, 0.5)
        // Red only: just outside the stroke the dark screenshot shows through.
        let rim = try XCTUnwrap(bitmap.colorAt(x: 200, y: height - 40 + 6)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(rim.greenComponent, 0.15)
        let blank = try XCTUnwrap(bitmap.colorAt(x: 200, y: 20)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(blank.redComponent, 0.1)
    }

    func testSketchStrokeLengthIgnoresAShiftTap() {
        XCTAssertEqual(VoiceDictationSketchSession.length(of: [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4), CGPoint(x: 3, y: 10)]), 11)
        XCTAssertLessThan(VoiceDictationSketchSession.length(of: [CGPoint(x: 5, y: 5)]), VoiceDictationSketchSession.minimumStrokeLength)
    }

    // MARK: Voice activity

    func testVADFindsSpeechAndPadsItsEdges() {
        let chunk = VoiceDictationVAD.chunk
        let probabilities: [Float] = [0.01, 0.02, 0.9, 0.95, 0.4, 0.02, 0.01, 0.01]
        let all = 0 ..< probabilities.count * chunk
        XCTAssertTrue(VoiceDictationVAD.hasSpeech(probabilities, in: all))
        XCTAssertFalse(VoiceDictationVAD.hasSpeech(probabilities, in: 5 * chunk ..< 8 * chunk))
        let speech = VoiceDictationVAD.speech(probabilities, in: all)!
        XCTAssertEqual(speech.lowerBound, 2 * chunk - Int(0.3 * Double(rate)))
        XCTAssertEqual(speech.upperBound, 4 * chunk + Int(0.45 * Double(rate)))
        XCTAssertNil(VoiceDictationVAD.speech([0.01, 0.02], in: 0 ..< 2 * chunk))
        // Audio not classified yet is never called silent.
        XCTAssertTrue(VoiceDictationVAD.hasSpeech([0.01], in: 0 ..< 3 * chunk))
    }

    func testBundledVADLoadsAndCallsSilenceSilent() async throws {
        let loaded = await VoiceDictationVAD.load()
        let vad = try XCTUnwrap(loaded)
        let silence = [Float](repeating: 0, count: rate * 2)
        await vad.feed(silence, final: true)
        let silent = await vad.hasSpeech(in: 0 ..< silence.count)
        XCTAssertFalse(silent)
    }

    /// Run `say -o /tmp/nano-vad-speech.wav --data-format=LEF32@16000 "…"`
    /// first; skipped otherwise.
    func testBundledVADHearsSpeech() async throws {
        let url = URL(fileURLWithPath: "/tmp/nano-vad-speech.wav")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("No speech fixture") }
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let padded = [Float](repeating: 0, count: rate) + samples + [Float](repeating: 0, count: rate * 2)
        let loaded = await VoiceDictationVAD.load()
        let vad = try XCTUnwrap(loaded)
        await vad.feed(padded, final: true)
        let heard = await vad.hasSpeech(in: 0 ..< padded.count)
        XCTAssertTrue(heard)
        let speech = await vad.speech(in: 0 ..< padded.count)
        let range = try XCTUnwrap(speech)
        XCTAssertLessThan(range.upperBound, padded.count - rate, "trailing silence is trimmed")
        XCTAssertGreaterThan(range.lowerBound, rate / 4, "leading silence is trimmed")
    }

    // MARK: Stored data from before

    func testEntriesSavedBeforeAppScopesStillDecode() throws {
        let old = #"[{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","phrase":"north star","replacement":"Nano","kind":"vocabulary","isEnabled":true}]"#
        let entries = try JSONDecoder().decode([VoiceDictationVocabularyEntry].self, from: Data(old.utf8))
        XCTAssertNil(entries[0].bundleID)
        let history = #"{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","text":"Hi","engine":"parakeetS1","createdAt":0}"#
        let entry = try JSONDecoder().decode(VoiceDictationHistoryEntry.self, from: Data(history.utf8))
        XCTAssertNil(entry.raw)
        let correction = #"{"spoken":"nano","written":"Nano","count":2,"dismissed":false,"lastSeen":0}"#
        XCTAssertNil(try JSONDecoder().decode(VoiceDictationCorrection.self, from: Data(correction.utf8)).bundleID)
    }

    func testCorrectionsKeepTheirAppAndSuggestAgainstThatAppsVocabulary() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corrections-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VoiceDictationCorrectionStore(fileURL: url)
        let pair = VoiceDictationCorrectionDiff.Pair(spoken: "rust", written: "Rust")
        store.record([pair], app: ("com.apple.dt.Xcode", "Xcode"))
        store.record([pair], app: ("com.apple.dt.Xcode", "Xcode"))
        store.record([pair], app: ("com.hnc.Discord", "Discord"))
        XCTAssertEqual(store.suggestions(excluding: []).map(\.bundleID), ["com.apple.dt.Xcode"])
        let discordOnly = VoiceDictationVocabularyEntry(
            phrase: "rust", replacement: "Rust", kind: .vocabulary, bundleID: "com.hnc.Discord", appName: "Discord"
        )
        XCTAssertEqual(store.suggestions(excluding: [discordOnly]).count, 1, "an entry in another app doesn't cover it")
        let xcode = VoiceDictationVocabularyEntry(
            phrase: "rust", replacement: "Rust", kind: .vocabulary, bundleID: "com.apple.dt.Xcode", appName: "Xcode"
        )
        XCTAssertTrue(store.suggestions(excluding: [xcode]).isEmpty)
    }
}

/// Renders each Quill settings tab to /tmp/nano-shots for a visual check.
/// `TEST_RUNNER_NANO_SNAPSHOTS=1 xcodebuild … -only-testing:NanoTests/VoiceDictationSettingsSnapshots`
@MainActor
final class VoiceDictationSettingsSnapshots: XCTestCase {
    func testRenderTabs() throws {
        guard ProcessInfo.processInfo.environment["NANO_SNAPSHOTS"] == "1" else { throw XCTSkip("Snapshots run on request") }
        let defaults = UserDefaults(suiteName: "nano-shots-\(UUID().uuidString)")!
        let settings = NanoSettings(defaults: defaults)
        settings.setEnabled(true, for: .voiceDictation)
        settings.voiceDictationVocabulary = [
            VoiceDictationVocabularyEntry(phrase: "north star", replacement: "Nano", kind: .vocabulary),
            VoiceDictationVocabularyEntry(phrase: "rust", replacement: "rust", kind: .vocabulary, bundleID: "com.hnc.Discord", appName: "Discord"),
            VoiceDictationVocabularyEntry(phrase: "my sign off", replacement: "Thanks,\nAlex", kind: .snippet),
        ]
        settings.voiceDictationAppStyles = [VoiceDictationAppStyle(bundleID: "com.hnc.Discord", appName: "Discord", level: .light)]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nano-shots-\(UUID().uuidString)")
        let controller = VoiceDictationController(
            settings: settings,
            modelStore: VoiceDictationModelStore(rootDirectory: root.appendingPathComponent("Models")),
            history: VoiceDictationHistoryStore(fileURL: root.appendingPathComponent("h.json")),
            stats: VoiceDictationStatsStore(fileURL: root.appendingPathComponent("s.json"))
        )
        let out = URL(fileURLWithPath: "/tmp/nano-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for tab in VoiceDictationTab.allCases {
            let view = VoiceDictationSettingsPane(settings: settings, controller: controller, initialTab: tab)
                .padding(20)
                .frame(width: 760, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .darkAqua)
            let fitted = hosting.fittingSize
            let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 760, height: fitted.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(tab.rawValue).png"))
            window.orderOut(nil)
        }

        // Settings → Support Nano.
        let support = NSHostingView(rootView: SupportSettingsPane()
            .padding(20)
            .frame(width: 760, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark))
        support.appearance = NSAppearance(named: .darkAqua)
        let supportWindow = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 760, height: support.fittingSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
        supportWindow.appearance = NSAppearance(named: .darkAqua)
        supportWindow.contentView = support
        supportWindow.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let supportRep = try XCTUnwrap(support.bitmapImageRepForCachingDisplay(in: support.bounds))
        support.cacheDisplay(in: support.bounds, to: supportRep)
        try XCTUnwrap(supportRep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("support.png"))
        supportWindow.orderOut(nil)

        // The Sketch bar, and a screenshot with two marks and its badge.
        let state = VoiceDictationSketchState(drawKey: .shift, finishShortcut: "⌃⌥S")
        state.marks = 1
        let pill = NSHostingView(rootView: VoiceDictationSketchPillView(
            state: state,
            actions: VoiceDictationSketchPillActions(togglePen: {}, undo: {}, cancel: {}, finish: {})
        ).frame(width: 560, height: 52))
        let pillWindow = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 560, height: 52), styleMask: [.borderless], backing: .buffered, defer: false)
        pillWindow.contentView = pill
        pillWindow.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let pillRep = try XCTUnwrap(pill.bitmapImageRepForCachingDisplay(in: pill.bounds))
        pill.cacheDisplay(in: pill.bounds, to: pillRep)
        try XCTUnwrap(pillRep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("pill.png"))
        pillWindow.orderOut(nil)

        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.15, green: 0.16, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        context.setFillColor(CGColor(red: 0.3, green: 0.32, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 200, y: 500, width: 500, height: 200))
        let screenshot = try XCTUnwrap(context.makeImage())
        let circle = (0 ... 40).map { step -> CGPoint in
            let angle = Double(step) / 40 * 2 * .pi
            return CGPoint(x: 225 + cos(angle) * 140, y: 300 + sin(angle) * 60)
        }
        let underline = (0 ... 20).map { CGPoint(x: 500 + Double($0) * 8, y: 180 + sin(Double($0)) * 2) }
        let frame = try XCTUnwrap(VoiceDictationSketchRenderer.render(
            screenshot,
            strokes: [
                VoiceDictationSketchStroke(points: circle, startSample: 0, number: 1),
                VoiceDictationSketchStroke(points: underline, startSample: 0, number: 2),
            ],
            screenFrame: CGRect(x: 0, y: 0, width: 800, height: 500),
            badge: "#1  0:03"
        ))
        let sheet = try XCTUnwrap(VoiceDictationSketchRenderer.contactSheet([frame, frame, frame]))
        try XCTUnwrap(VoiceDictationSketchRenderer.pngData(sheet)).write(to: out.appendingPathComponent("sheet.png"))

        // Sketch in use: a mock app screen, a mark with its tag, the bar.
        let screen = try XCTUnwrap(CGContext(
            data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        screen.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.16, alpha: 1))
        screen.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        screen.setFillColor(CGColor(red: 0.17, green: 0.18, blue: 0.24, alpha: 1))
        screen.fill(CGRect(x: 0, y: 0, width: 300, height: 1000))
        for row in 0 ..< 6 {
            screen.fill(CGRect(x: 380, y: 760 - row * 110, width: 820 - (row % 3) * 140, height: 70))
        }
        screen.setFillColor(CGColor(red: 0.04, green: 0.52, blue: 1, alpha: 1))
        screen.fill(CGRect(x: 1250, y: 760, width: 220, height: 70))
        let backdrop = try XCTUnwrap(screen.makeImage())
        let ring = (0 ... 48).map { step -> CGPoint in
            let angle = Double(step) / 48 * 2 * .pi
            return CGPoint(x: 680 + cos(angle) * 82, y: 397 + sin(angle) * 30)
        }
        let marked = try XCTUnwrap(VoiceDictationSketchRenderer.render(
            backdrop,
            strokes: [VoiceDictationSketchStroke(points: ring, startSample: 0, number: 1)],
            screenFrame: CGRect(x: 0, y: 0, width: 800, height: 500)
        ))
        let scene = try XCTUnwrap(CGContext(
            data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        scene.draw(marked, in: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        // The recording glow, as the overlay draws it (44 pt at 2x).
        let ink = VoiceDictationSketchRenderer.inkColor
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            colors: [ink.copy(alpha: 0.26)!, ink.copy(alpha: 0.07)!, ink.copy(alpha: 0)!] as CFArray,
            locations: [0, 0.35, 1]
        )!
        let depth: CGFloat = 88
        for (start, end) in [
            (CGPoint(x: 0, y: 1000), CGPoint(x: 0, y: 1000 - depth)),
            (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: depth)),
            (CGPoint(x: 0, y: 0), CGPoint(x: depth, y: 0)),
            (CGPoint(x: 1600, y: 0), CGPoint(x: 1600 - depth, y: 0)),
        ] {
            scene.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
        let tag = NSAttributedString(string: "0:03", attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.white])
        let tagSize = tag.size()
        let tagBox = CGRect(x: 1200 - tagSize.width - 32, y: 862, width: tagSize.width + 32, height: tagSize.height + 16)
        scene.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 0.9))
        scene.addPath(CGPath(roundedRect: tagBox, cornerWidth: tagBox.height / 2, cornerHeight: tagBox.height / 2, transform: nil))
        scene.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: scene, flipped: false)
        tag.draw(at: CGPoint(x: tagBox.minX + 16, y: tagBox.minY + 8))
        NSGraphicsContext.restoreGraphicsState()
        if let pillImage = pillRep.cgImage {
            let width = CGFloat(pillImage.width), height = CGFloat(pillImage.height)
            scene.draw(pillImage, in: CGRect(x: (1600 - width) / 2, y: 56, width: width, height: height))
        }
        try XCTUnwrap(VoiceDictationSketchRenderer.pngData(try XCTUnwrap(scene.makeImage())))
            .write(to: out.appendingPathComponent("in-use.png"))
    }
}

@MainActor
final class VoiceDictationCaptionPanelTests: XCTestCase {
    func testCaptionKeepsItsBottomEdgeAsTheTextGrows() async throws {
        let panel = VoiceDictationCaptionPanel()
        defer { panel.hide() }
        var text = ""
        var bottoms: [CGFloat] = []
        var heights: [CGFloat] = []
        for index in 0..<12 {
            text += "word\(index) some more speech here "
            panel.show(VoiceDictationController.previewCaption(text))
            try await Task.sleep(for: .milliseconds(120))
            let frame = try XCTUnwrap(panel.currentFrame)
            if index > 0 { bottoms.append(frame.minY) }
            heights.append(frame.height)
        }
        XCTAssertEqual(Set(bottoms).count, 1, "the caption drifted: \(bottoms)")
        XCTAssertGreaterThan(heights.max() ?? 0, heights.min() ?? 0, "it grows with more lines")
    }

    func testDraggingTheCaptionMovesItAndItStaysThere() async throws {
        let key = "voiceDictation.captionOrigin"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let panel = VoiceDictationCaptionPanel()
        panel.show("Drag me somewhere else")
        try await Task.sleep(for: .milliseconds(400))
        let view = try XCTUnwrap(panel.dragView)
        let window = try XCTUnwrap(view.window)
        let start = window.frame.origin

        func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        view.mouseDown(with: event(.leftMouseDown, at: CGPoint(x: 40, y: 20)))
        view.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 140, y: 80)))
        view.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 140, y: 80)))

        XCTAssertEqual(window.frame.origin.x, start.x + 100, accuracy: 0.5)
        XCTAssertEqual(window.frame.origin.y, start.y + 60, accuracy: 0.5)
        panel.show("Drag me somewhere else, and keep talking")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(window.frame.origin.x, start.x + 100, accuracy: 0.5, "a text update doesn't snap it back")
        let remembered = try XCTUnwrap(UserDefaults.standard.array(forKey: key) as? [Double])
        XCTAssertEqual(remembered[0], Double(start.x + 100), accuracy: 0.5)
        panel.hide()
    }
}


final class VoiceDictationLearnedCleanupTests: XCTestCase {
    func testDeletedWordsAreLearned() {
        let leaveOut = VoiceDictationCorrectionDiff.corrections(
            original: "I think you know we should ship it today",
            edited: "I think we should ship it today"
        )
        XCTAssertEqual(leaveOut, [.init(kind: .leaveOut, spoken: "you know", written: "")])

        let changeOfMind = VoiceDictationCorrectionDiff.corrections(
            original: "Send the file to John, actually send it to Mary tomorrow morning please",
            edited: "Send it to Mary tomorrow morning please"
        )
        XCTAssertEqual(changeOfMind.first?.kind, .changeOfMind)
        XCTAssertEqual(changeOfMind.first?.spoken, "actually")
    }

    func testChangeOfMindDropsTheRestatedStretch() {
        let pipeline = VoiceDictationTextPipeline(entries: [], changeOfMindCues: ["actually", "no"])
        XCTAssertEqual(pipeline.applyLearned("Send it to John, actually send it to Mary."), "Send it to Mary.")
        XCTAssertEqual(pipeline.applyLearned("There is no way to do it."), "There is no way to do it.")
        XCTAssertEqual(pipeline.applyLearned("I think, actually, we should go."), "I think, actually, we should go.")
        XCTAssertEqual(
            pipeline.applyLearned("We met on Monday. Move it to Friday, no, move it to Thursday."),
            "We met on Monday. Move it to Thursday."
        )
    }

    func testLeaveOutKeepsSentencesIntact() {
        let pipeline = VoiceDictationTextPipeline(entries: [], leaveOut: ["you know", "basically"])
        XCTAssertEqual(pipeline.applyLearned("I think, you know, it works."), "I think, it works.")
        XCTAssertEqual(pipeline.applyLearned("Basically we ship today."), "We ship today.")
        XCTAssertEqual(pipeline.applyLearned("It works, you know."), "It works.")
        XCTAssertEqual(pipeline.applyLearned("Line one\nyou know line two"), "Line one\nline two")
    }

    @MainActor
    func testAutomaticLearningAddsSuggestionsWithoutAsking() throws {
        let suite = "NanoTests.learn.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NanoSettings(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("learn-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceDictationCorrectionStore(fileURL: root.appendingPathComponent("corrections.json"))
        let controller = VoiceDictationController(
            settings: settings,
            modelStore: VoiceDictationModelStore(rootDirectory: root.appendingPathComponent("Models")),
            history: VoiceDictationHistoryStore(fileURL: root.appendingPathComponent("history.json")),
            stats: VoiceDictationStatsStore(fileURL: root.appendingPathComponent("stats.json")),
            corrections: store
        )
        let pairs: [VoiceDictationCorrectionDiff.Pair] = [
            .init(kind: .word, spoken: "cloud", written: "Claude"),
            .init(kind: .leaveOut, spoken: "you know", written: ""),
            .init(kind: .changeOfMind, spoken: "actually", written: ""),
        ]
        store.record(pairs)
        store.record(pairs)
        XCTAssertEqual(controller.correctionSuggestions.count, 3)

        controller.applyLearnedIfAutomatic()
        XCTAssertEqual(controller.correctionSuggestions.count, 3, "off by default: Nano asks first")

        settings.voiceDictationAppliesLearnedAutomatically = true
        controller.applyLearnedIfAutomatic()
        XCTAssertTrue(controller.correctionSuggestions.isEmpty)
        XCTAssertTrue(settings.voiceDictationVocabulary.contains { $0.phrase == "cloud" && $0.replacement == "Claude" })
        XCTAssertEqual(settings.voiceDictationLeaveOutPhrases, ["you know"])
        XCTAssertEqual(settings.voiceDictationChangeOfMindCues, ["actually"])
    }
}

@MainActor
final class QuillSuggestionNoticeTests: XCTestCase {
    func testNanoAsksAtMostOnceADay() throws {
        let suite = "NanoTests.quillNotice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NanoSettings(defaults: defaults)
        settings.completeOnboarding()
        settings.setEnabled(true, for: .voiceDictation)
        let model = IslandViewModel(settings: settings, trayStorageURL: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quill-notice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VoiceDictationCorrectionStore(fileURL: root.appendingPathComponent("corrections.json"))
        model.voiceDictation = VoiceDictationController(
            settings: settings,
            modelStore: VoiceDictationModelStore(rootDirectory: root.appendingPathComponent("Models")),
            history: VoiceDictationHistoryStore(fileURL: root.appendingPathComponent("history.json")),
            stats: VoiceDictationStatsStore(fileURL: root.appendingPathComponent("stats.json")),
            corrections: store
        )
        let pair = VoiceDictationCorrectionDiff.Pair(kind: .leaveOut, spoken: "you know", written: "")
        store.record([pair])
        store.record([pair])

        let start = Date()
        model.offerQuillSuggestionIfDue(now: start)
        XCTAssertEqual(model.notificationCenter.current?.coalesceKey, IslandNotification.quillSuggestionCoalesceKey)

        model.dismissQuillSuggestion()
        model.offerQuillSuggestionIfDue(now: start.addingTimeInterval(3600))
        XCTAssertNil(model.notificationCenter.current, "Not now waits until tomorrow")

        model.offerQuillSuggestionIfDue(now: start.addingTimeInterval(25 * 3600))
        XCTAssertNotNil(model.notificationCenter.current)
        let shown = try XCTUnwrap({ if case let .quillSuggestion(c) = model.notificationCenter.current?.payload { return c } else { return nil } }())
        model.rememberQuillSuggestion(shown)
        XCTAssertEqual(settings.voiceDictationLeaveOutPhrases, ["you know"])
        XCTAssertNil(model.notificationCenter.current)
    }
}
