import XCTest
@testable import Nano

/// Cleanup level, transcript chunking, and the cleanup guard. All three are
/// pure; none of them needs a model on disk.
final class VoiceDictationCleanupTests: XCTestCase {
    // MARK: - Cleanup level

    func testControlLineIsTheCardsFormat() {
        XCTAssertEqual(
            S1MiniCleaner.controlLine(for: .polished),
            "[Styling: semi-formal] [Structure: prose] [Context: general]"
        )
        XCTAssertEqual(
            S1MiniCleaner.controlLine(for: .init(styling: .semiCasual, structure: .lists, context: .email)),
            "[Styling: semi-casual] [Structure: lists] [Context: email]"
        )
        XCTAssertTrue(S1MiniCleaner.userTurn(for: "hello").contains(S1MiniCleaner.controlLine(for: .polished)))
    }

    func testDirectiveValuesAreTheTrainedSets() {
        // The card is explicit that untrained axis values garble output.
        XCTAssertEqual(
            VoiceDictationCleanupDirective.Styling.allCases.map(\.rawValue),
            ["casual", "semi-casual", "semi-formal", "formal"]
        )
        XCTAssertEqual(VoiceDictationCleanupDirective.Structure.allCases.map(\.rawValue), ["prose", "lists"])
        XCTAssertEqual(VoiceDictationCleanupDirective.Context.allCases.map(\.rawValue), ["general", "email"])
    }

    func testStylesMapToDirectives() {
        XCTAssertNil(VoiceDictationCleanupLevel.verbatim.directive(), "only Verbatim skips the cleaner")
        XCTAssertEqual(VoiceDictationCleanupLevel.light.directive(), .init(styling: .casual))
        XCTAssertEqual(VoiceDictationCleanupLevel.full.directive(), .polished, "Polished is the original control line")
        XCTAssertEqual(VoiceDictationCleanupLevel.full.directive(lists: true), .init(styling: .semiFormal, structure: .lists))
        XCTAssertEqual(VoiceDictationCleanupLevel.light.directive(lists: true), .init(styling: .casual), "lists only with Polished")
    }

    func testListsAndEmailAdjustTheSentenceStylesOnly() {
        XCTAssertEqual(
            VoiceDictationCleanupLevel.full.directive(lists: true, context: .email),
            .init(styling: .semiFormal, structure: .lists, context: .email)
        )
        XCTAssertEqual(VoiceDictationCleanupLevel.full.directive(context: .chat), .polished)
        XCTAssertEqual(
            VoiceDictationCleanupLevel.light.directive(context: .email),
            .init(styling: .casual),
            "Casual is a text message whatever the app"
        )
        XCTAssertNil(VoiceDictationCleanupLevel.verbatim.directive(lists: true, context: .email))
    }

    @MainActor
    func testComposeAndRetiredEnginesFromOlderSettingsStillLoad() throws {
        XCTAssertEqual(VoiceDictationCleanupLevel.saved("compose"), .full)
        let style = try JSONDecoder().decode(
            VoiceDictationAppStyle.self,
            from: Data(#"{"bundleID":"com.apple.mail","appName":"Mail","level":"compose"}"#.utf8)
        )
        XCTAssertEqual(style.level, .full)
        let suite = "nano-vd-migrate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("compose", forKey: "voiceDictation.cleanupLevel")
        defaults.set("cohereTranscribe", forKey: "voiceDictation.engine")
        let settings = NanoSettings(defaults: defaults)
        XCTAssertEqual(settings.voiceDictationCleanupLevel, .full)
        XCTAssertTrue(settings.voiceDictationStructuresLists, "Compose was Polished with lists")
        XCTAssertEqual(settings.voiceDictationEngine, .whisperTurbo)
        XCTAssertEqual(VoiceDictationEngine.whisperTiny.offeredReplacement, .whisperBase)
        XCTAssertEqual(VoiceDictationEngine.offered, [.parakeetS1, .whisperTurbo, .whisperBase])
    }

    @MainActor
    func testCleanupLevelDefaultsToFullAndRoundTrips() {
        let suite = "nano-vd-cleanup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(NanoSettings(defaults: defaults).voiceDictationCleanupLevel, .full)
        NanoSettings(defaults: defaults).voiceDictationCleanupLevel = .verbatim
        XCTAssertEqual(NanoSettings(defaults: defaults).voiceDictationCleanupLevel, .verbatim)
    }

    // MARK: - Chunker

    private func sentences(_ count: Int, words: Int = 10) -> String {
        (0 ..< count).map { index in
            "Sentence \(index) " + Array(repeating: "word", count: words - 2).joined(separator: " ") + "."
        }.joined(separator: " ")
    }

    func testShortTranscriptIsOneChunk() {
        let text = "Ship it Thursday. Let the team know."
        XCTAssertEqual(VoiceDictationTranscriptChunker.chunk(text), [text])
        XCTAssertEqual(VoiceDictationTranscriptChunker.chunk("   "), [])
    }

    func testLongTranscriptSplitsAtSentenceEndsUnderBudget() {
        let text = sentences(10) // 100 words
        let chunks = VoiceDictationTranscriptChunker.chunk(text, wordBudget: 35)
        XCTAssertEqual(chunks.count, 4, "\(chunks)")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(VoiceDictationTranscriptChunker.wordCount(chunk), 35)
            XCTAssertTrue(chunk.hasSuffix("."), "chunks end on a sentence: \(chunk)")
            XCTAssertTrue(chunk.hasPrefix("Sentence"), "chunks start on a sentence: \(chunk)")
        }
        XCTAssertEqual(chunks.joined(separator: " "), text, "nothing is lost or reordered")
    }

    func testOversizedSentenceFallsBackToClausesThenWords() {
        let clause = Array(repeating: "w", count: 6).joined(separator: " ")
        let sentence = "\(clause), \(clause), \(clause)."
        let byClause = VoiceDictationTranscriptChunker.chunk(sentence, wordBudget: 12)
        XCTAssertEqual(byClause, ["\(clause), \(clause),", "\(clause)."])

        let noPunctuation = Array(repeating: "w", count: 25).joined(separator: " ")
        let byWords = VoiceDictationTranscriptChunker.chunk(noPunctuation, wordBudget: 10)
        XCTAssertEqual(byWords.map(VoiceDictationTranscriptChunker.wordCount), [10, 10, 5])
        XCTAssertEqual(byWords.joined(separator: " "), noPunctuation)
    }

    func testDefaultBudgetPassesAFewMinutesOfSpeechUntouched() {
        // ~150 words a minute; two minutes fits in one pass.
        let text = sentences(30)
        XCTAssertEqual(VoiceDictationTranscriptChunker.chunk(text), [text])
        // Ten minutes does not.
        XCTAssertGreaterThan(VoiceDictationTranscriptChunker.chunk(sentences(150)).count, 1)
    }

    // MARK: - Guard

    func testCountsMeaningBearingNegations() {
        XCTAssertEqual(VoiceDictationCleanupGuard.negationCount("I'd prefer to never merge this"), 1)
        XCTAssertEqual(VoiceDictationCleanupGuard.negationCount("I haven't and I won't."), 2)
        XCTAssertEqual(VoiceDictationCleanupGuard.negationCount("I haven’t, not once."), 2, "curly apostrophe")
        XCTAssertEqual(VoiceDictationCleanupGuard.negationCount("i dont think so"), 1, "ASR-dropped apostrophe")
        XCTAssertEqual(VoiceDictationCleanupGuard.negationCount("I want the front one."), 0, "not every -nt is a contraction")
        XCTAssertEqual(VoiceDictationCleanupGuard.negationCount("Tuesday, no, Thursday."), 0, "bare no is a correction marker")
    }

    func testRestoresRawWhenCleanupDropsANegation() {
        let raw = "i'd prefer to never merge this"
        let verdict = VoiceDictationCleanupGuard.verify(raw: raw, cleaned: "I'd prefer to merge this.")
        XCTAssertEqual(verdict.text, raw)
        XCTAssertEqual(verdict.reason, .negationDropped(raw: 1, cleaned: 0))
        XCTAssertTrue(verdict.restoredRaw)
    }

    func testKeepsCleanedTextWhenNegationsSurvive() {
        let cleaned = "I'd prefer to never merge this."
        let verdict = VoiceDictationCleanupGuard.verify(raw: "um i'd prefer to uh never merge this", cleaned: cleaned)
        XCTAssertEqual(verdict.text, cleaned)
        XCTAssertNil(verdict.reason)
    }

    func testRegisterChangesDoNotTripTheGuard() {
        // formal ↔ casual rewrites of the same negation are a wash.
        XCTAssertNil(VoiceDictationCleanupGuard.verify(raw: "i do not want that", cleaned: "I don't want that.").reason)
        XCTAssertNil(VoiceDictationCleanupGuard.verify(raw: "i can't do it", cleaned: "I cannot do it.").reason)
        XCTAssertNil(VoiceDictationCleanupGuard.verify(raw: "we cannot ship", cleaned: "We can't ship.").reason)
    }

    func testSelfCorrectionResolutionIsAllowed() {
        // S1-mini's job includes collapsing "Tuesday, no, Thursday".
        let verdict = VoiceDictationCleanupGuard.verify(
            raw: "ship it on tuesday no thursday",
            cleaned: "Ship it on Thursday."
        )
        XCTAssertNil(verdict.reason)
    }

    // MARK: - Guard: figures

    func testReadsFiguresWithSeparatorsClosedUp() {
        XCTAssertEqual(VoiceDictationCleanupGuard.figures(in: "$23,450 by 4:30 on March 3rd, 2026"), ["23450", "4", "30", "3", "2026"])
        XCTAssertEqual(VoiceDictationCleanupGuard.figures(in: "call 555-0198"), ["555", "0198"])
        XCTAssertEqual(VoiceDictationCleanupGuard.figures(in: "rooms 12, 14 and 16"), ["12", "14", "16"])
        XCTAssertEqual(VoiceDictationCleanupGuard.figures(in: "no numbers here"), [])
    }

    func testRestoresRawWhenCleanupWritesAFigureNobodySaid() {
        let raw = "call me back at five five five zero one nine eight before the fourteenth"
        XCTAssertNil(VoiceDictationCleanupGuard.verify(raw: raw, cleaned: "Call me back at 555-0198 before the 14th.").reason)
        let verdict = VoiceDictationCleanupGuard.verify(raw: raw, cleaned: "Call me back at 555-0189 before the 14th.")
        XCTAssertEqual(verdict.reason, .numberChanged("0189"))
        XCTAssertEqual(verdict.text, raw)
        XCTAssertEqual(
            VoiceDictationCleanupGuard.verify(raw: "the meeting is at four thirty", cleaned: "The meeting is at 5:30.").reason,
            .numberChanged("5")
        )
    }

    func testFiguresThatWereSpokenPass() {
        let cases: [(String, String)] = [
            ("ship it at three no four", "Ship it at 4."),
            ("it's about a hundred dollars", "It's about $100."),
            ("we raised a million dollars", "We raised $1 million."),
            ("two and a half hours", "2.5 hours"),
            ("the meeting is at four thirty pm", "The meeting is at 4:30 PM."),
            ("version 3 point 2 is out", "Version 3.2 is out."),
            ("room 204 on the 3rd floor", "Room 204 on the third floor."),
            ("first update the changelog, then run the tests, finally tag the build",
             "1. Update the changelog.\n2. Run the tests.\n3. Tag the build."),
        ]
        for (raw, cleaned) in cases {
            XCTAssertNil(VoiceDictationCleanupGuard.verify(raw: raw, cleaned: cleaned).reason, "\(raw) → \(cleaned)")
        }
    }

    func testFiguresTheFormatterComposesPass() throws {
        try XCTSkipUnless(VoiceDictationNumberFormatter.isAvailable, "number formatter not in this build")
        let cases: [(String, String)] = [
            ("the invoice came to twenty three thousand four hundred and fifty dollars", "The invoice came to $23,450."),
            ("it's due on march third twenty twenty six", "It's due on March 3, 2026."),
            ("about ten percent of the forty two users", "About 10% of the 42 users."),
        ]
        for (raw, cleaned) in cases {
            XCTAssertNil(VoiceDictationCleanupGuard.verify(raw: raw, cleaned: cleaned).reason, "\(raw) → \(cleaned)")
        }
    }

    // MARK: - Guard: dropped sentences

    func testRestoresRawWhenASentenceGoesMissing() {
        let raw = "We migrated the cluster to Postgres last night. The landlord said the repair happens next month. Priya will review the pull request tomorrow."
        let cleaned = "We migrated the cluster to Postgres last night. Priya will review the pull request tomorrow."
        let verdict = VoiceDictationCleanupGuard.verify(raw: raw, cleaned: cleaned)
        XCTAssertEqual(verdict.reason, .sentenceDropped("The landlord said the repair happens next month."))
        XCTAssertEqual(verdict.text, raw)
        // Cut short by the token budget: the tail is what is missing.
        XCTAssertEqual(
            VoiceDictationCleanupGuard.verify(raw: raw, cleaned: "We migrated the cluster to Postgres last night.").reason,
            .sentenceDropped("The landlord said the repair happens next month.")
        )
    }

    func testOrdinaryTidyingIsNotADroppedSentence() {
        let cases: [(String, String)] = [
            ("Um, so I think we should, uh, ship it on Tuesday, no, Thursday, and, um, let the team know before the standup.",
             "So I think we should ship it on Thursday, and let the team know before the standup."),
            ("Let's meet on Tuesday. Actually, scratch that. Let's meet on Thursday.", "Let's meet on Thursday."),
            ("You know, like, basically, I mean, whatever, right. The build is green.", "The build is green."),
            ("Email me at alex dot rivera at example dot com about the Kubernetes migration.",
             "Email me at alex.rivera@example.com about the Kubernetes migration."),
            ("For the trip we need to bring sunscreen, a first aid kit, two tents, and enough water.",
             "For the trip we need to bring:\n- Sunscreen\n- A first aid kit\n- Two tents\n- Enough water"),
        ]
        for (raw, cleaned) in cases {
            XCTAssertNil(VoiceDictationCleanupGuard.verify(raw: raw, cleaned: cleaned).reason, "\(raw) → \(cleaned)")
        }
    }

    func testEmptyOutputForRealSpeechRestoresRaw() {
        let raw = "the answer to question one is a and the answer to question two is agreed with caveats"
        XCTAssertEqual(VoiceDictationCleanupGuard.verify(raw: raw, cleaned: "").reason, .outputEmpty)
        // Pure filler cleaning to nothing is correct behavior.
        XCTAssertNil(VoiceDictationCleanupGuard.verify(raw: "um uh hmm", cleaned: "").reason)
    }
}
