import XCTest
@testable import Nano

final class VoiceDictationPipelineTests: XCTestCase {
    private func vocab(_ phrase: String, _ replacement: String, enabled: Bool = true) -> VoiceDictationVocabularyEntry {
        VoiceDictationVocabularyEntry(phrase: phrase, replacement: replacement, kind: .vocabulary, isEnabled: enabled)
    }

    private func snippet(_ phrase: String, _ replacement: String) -> VoiceDictationVocabularyEntry {
        VoiceDictationVocabularyEntry(phrase: phrase, replacement: replacement, kind: .snippet)
    }

    func testVocabularyMatchesAcrossCaseHyphenAndCompounding() {
        let pipeline = VoiceDictationTextPipeline(entries: [vocab("north star", "Nano")])
        for heard in ["north star", "North Star", "North-Star", "NorthStar", "NORTH STAR"] {
            let output = pipeline.apply("I opened \(heard) today.")
            XCTAssertEqual(output.text, "I opened Nano today.", heard)
            XCTAssertEqual(output.appliedPhrases, ["north star"], heard)
        }
    }

    func testVocabularyKeepsSurroundingPunctuation() {
        let pipeline = VoiceDictationTextPipeline(entries: [vocab("super whisper", "Superwhisper")])
        XCTAssertEqual(
            pipeline.apply("Compare it to super whisper, then decide.").text,
            "Compare it to Superwhisper, then decide."
        )
        XCTAssertEqual(pipeline.apply("(super whisper)").text, "(Superwhisper)")
    }

    func testVocabularyDoesNotMatchInsideLongerWords() {
        let pipeline = VoiceDictationTextPipeline(entries: [vocab("nano", "Nano")])
        XCTAssertEqual(pipeline.apply("a nanosecond later nano opened").text, "a nanosecond later Nano opened")
    }

    func testLongestPhraseWinsWhenEntriesOverlap() {
        let pipeline = VoiceDictationTextPipeline(entries: [
            vocab("code", "Code"),
            vocab("claude code", "Claude Code"),
        ])
        XCTAssertEqual(pipeline.apply("open claude code and write code").text, "open Claude Code and write Code")
    }

    func testDisabledAndInvalidEntriesAreIgnored() {
        let pipeline = VoiceDictationTextPipeline(entries: [
            vocab("north star", "Nano", enabled: false),
            VoiceDictationVocabularyEntry(phrase: "   ", replacement: "x", kind: .vocabulary),
        ])
        XCTAssertTrue(pipeline.isEmpty)
        XCTAssertEqual(pipeline.apply("north star").text, "north star")
    }

    func testSnippetExpandsInPlace() {
        let pipeline = VoiceDictationTextPipeline(entries: [
            snippet("my sign off", "Best,\nAlex"),
        ])
        let output = pipeline.apply("thanks again my sign off")
        XCTAssertEqual(output.text, "thanks again Best,\nAlex")
        XCTAssertEqual(output.appliedPhrases, ["my sign off"])
    }

    func testProtectSplitsSpeechAroundSnippetsSoCleanupNeverSeesExpansion() {
        let pipeline = VoiceDictationTextPipeline(entries: [
            snippet("insert address", "1 Infinite Loop, Cupertino"),
            vocab("north star", "Nano"),
        ])
        let segments = pipeline.protect("um send it to insert address please, from north star")
        XCTAssertEqual(segments, [
            .speech("um send it to "),
            .expansion("1 Infinite Loop, Cupertino", phrase: "insert address"),
            .speech(" please, from north star"),
        ])
        // Vocabulary is not applied by protect; it runs after cleanup.
        if case .speech(let tail) = segments[2] {
            XCTAssertTrue(tail.contains("north star"))
        }
    }

    func testProtectWithoutSnippetsReturnsWholeTextAsSpeech() {
        let pipeline = VoiceDictationTextPipeline(entries: [vocab("north star", "Nano")])
        XCTAssertEqual(pipeline.protect("hello north star"), [.speech("hello north star")])
    }

    // MARK: - Layout cues

    private func pieces(_ text: String, entries: [VoiceDictationVocabularyEntry] = []) -> [VoiceDictationTextPipeline.Segment] {
        VoiceDictationTextPipeline(entries: entries, layoutCues: true).protect(text)
    }

    private func laidOut(_ text: String) -> String {
        VoiceDictationTextPipeline.join(pieces(text).map { segment in
            switch segment {
            case .speech(let speech): speech
            case .expansion(let expansion, _): expansion
            case .lineBreak(let lineBreak): lineBreak
            }
        })
    }

    func testSpokenBreaksSplitTheSpeechAndTakeTheirPunctuationWithThem() {
        XCTAssertEqual(pieces("Hi John, new line, thanks for the update. New paragraph. See you Friday."), [
            .speech("Hi John, "),
            .lineBreak("\n"),
            .speech(" Thanks for the update. "),
            .lineBreak("\n\n"),
            .speech(" See you Friday."),
        ])
        XCTAssertEqual(
            laidOut("Hi John, new line, thanks for the update. New paragraph. See you Friday."),
            "Hi John,\nThanks for the update.\n\nSee you Friday."
        )
    }

    func testAParagraphBreakClosesAHangingComma() {
        XCTAssertEqual(laidOut("that covers the budget, new paragraph, on staffing we are fine"),
                       "that covers the budget.\n\nOn staffing we are fine")
    }

    func testCuesAreOffUnlessAsked() {
        let text = "Hi John. New paragraph. Thanks."
        XCTAssertEqual(VoiceDictationTextPipeline(entries: []).protect(text), [.speech(text)])
    }

    func testNewLineAsOrdinarySpeechIsTyped() {
        for text in [
            "Add a new line at the end of the file.",
            "They launched a new line of products.",
            "The new paragraph reads better.",
            "We need a brand new line item for travel.",
            "Then start the new line of thought here",
            "Press the “new line” key.",
        ] {
            XCTAssertEqual(pieces(text), [.speech(text)], text)
        }
    }

    func testNewLineNeedsAPauseOnOneSideButNewParagraphDoesNot() {
        XCTAssertEqual(laidOut("ship it today new paragraph next topic"), "ship it today\n\nNext topic")
        XCTAssertEqual(laidOut("milk, new line eggs"), "milk,\nEggs")
        XCTAssertEqual(laidOut("new line second item"), "Second item", "a break before any text is dropped")
        XCTAssertEqual(pieces("we drew new line art today"), [.speech("we drew new line art today")])
    }

    func testCuesAndSnippetsCoexist() {
        let result = pieces("regards, new line, my sign off", entries: [snippet("my sign off", "Best,\nAlex")])
        XCTAssertEqual(result, [.speech("regards, "), .lineBreak("\n"), .expansion("Best,\nAlex", phrase: "my sign off")])
    }

    func testJoinKeepsBreaksBetweenPiecesAndListsOnTheirOwnLine() {
        typealias Pipeline = VoiceDictationTextPipeline
        XCTAssertEqual(Pipeline.join(["One.", "\n\n", "\n", "Two."]), "One.\n\nTwo.", "breaks do not stack")
        XCTAssertEqual(Pipeline.join(["\n", "One.", "\n"]), "One.")
        XCTAssertEqual(Pipeline.join(["\n", "One.", "\n\n"], keepingEdgeBreaks: true), "\nOne.\n\n")
        // A segment's kept edge break survives the join across segments.
        XCTAssertEqual(Pipeline.join(["First part.\n\n", "Second part."]), "First part.\n\nSecond part.")
        XCTAssertEqual(Pipeline.join(["Bring:", "- Sunscreen\n- Water"]), "Bring:\n- Sunscreen\n- Water")
        XCTAssertEqual(Pipeline.join(["Steps:", "1. Build\n2. Ship"]), "Steps:\n1. Build\n2. Ship")
        XCTAssertEqual(Pipeline.join(["It cost", "1.5 million."]), "It cost 1.5 million.")
    }

    func testJoinInsertsSingleSpacesAndHugsPunctuation() {
        XCTAssertEqual(
            VoiceDictationTextPipeline.join(["Send it to", "1 Infinite Loop", ", please."]),
            "Send it to 1 Infinite Loop, please."
        )
        XCTAssertEqual(VoiceDictationTextPipeline.join(["", "  ", "only"]), "only")
    }

    func testApplyVocabularyAfterCleanupIsIdempotent() {
        let pipeline = VoiceDictationTextPipeline(entries: [vocab("north star", "Nano")])
        let once = pipeline.applyVocabulary("I use North Star daily.").text
        XCTAssertEqual(once, "I use Nano daily.")
        XCTAssertEqual(pipeline.applyVocabulary(once).text, once)
    }

    func testPromptHintListsVocabularyOnly() {
        let pipeline = VoiceDictationTextPipeline(entries: [
            vocab("north star", "Nano"),
            vocab("kubernetes", "Kubernetes"),
            snippet("my sign off", "Best"),
        ])
        XCTAssertEqual(pipeline.promptHint, "Nano, Kubernetes.")
        XCTAssertNil(VoiceDictationTextPipeline(entries: []).promptHint)
    }

    // MARK: - Chat style (Quill for Windows finish.rs)

    func testChatStyleDropsASingleFullStop() {
        XCTAssertEqual(VoiceDictationChatStyle.apply("Sounds good."), "Sounds good")
        XCTAssertEqual(VoiceDictationChatStyle.apply("Sounds good. See you."), "Sounds good. See you.")
        XCTAssertEqual(VoiceDictationChatStyle.apply("Wait..."), "Wait...")
        XCTAssertEqual(VoiceDictationChatStyle.apply("Line one.\nLine two."), "Line one.\nLine two.")
        XCTAssertEqual(VoiceDictationChatStyle.apply("Really?"), "Really?")
        XCTAssertEqual(VoiceDictationChatStyle.apply("Version 1.5 is out."), "Version 1.5 is out")
    }

    // MARK: - Spoken commands (Quill for Windows spoken.rs)

    func testEmojiNamesBecomeEmoji() {
        typealias Spoken = VoiceDictationSpokenCommands
        XCTAssertEqual(Spoken.emojiNames("Great job fire emoji."), "Great job 🔥.")
        XCTAssertEqual(Spoken.emojiNames("Great job, fire emoji"), "Great job, 🔥")
        XCTAssertEqual(Spoken.emojiNames("Love it heart eyes emoji thumbs up emoji"), "Love it 😍 👍")
        XCTAssertEqual(Spoken.emojiNames("Fire emoji"), "🔥")
        XCTAssertEqual(Spoken.emojiNames("Sounds good\nthumbs up emoji"), "Sounds good\n👍")
        XCTAssertEqual(
            Spoken.emojiNames("Great job on the launch, everyone! Fire emoji."),
            "Great job on the launch, everyone! 🔥."
        )
        XCTAssertEqual(Spoken.emojiNames("(fire emoji)"), "(🔥)")
        XCTAssertEqual(Spoken.emojiNames("one hundred emoji"), "💯")
    }

    func testEmojiMentionsAndOrdinaryWordsStay() {
        typealias Spoken = VoiceDictationSpokenCommands
        XCTAssertEqual(Spoken.emojiNames("The party was fire."), "The party was fire.")
        XCTAssertEqual(Spoken.emojiNames("Send the fire emoji to Sam."), "Send the fire emoji to Sam.")
        XCTAssertEqual(Spoken.emojiNames("I like emoji."), "I like emoji.")
        XCTAssertEqual(Spoken.emojiNames("Add a spreadsheet emoji"), "Add a spreadsheet emoji")
        XCTAssertEqual(Spoken.emojiNames("Emojis are fun"), "Emojis are fun")
        XCTAssertEqual(Spoken.emojiNames("The deadline, fire emoji."), "The deadline, 🔥.")
        XCTAssertEqual(Spoken.emojiNames("thumbs, up emoji"), "thumbs, up emoji", "punctuation inside a name blocks it")
    }

    func testPressEnter() {
        typealias Spoken = VoiceDictationSpokenCommands
        func strip(_ text: String) -> String? {
            let result = Spoken.stripPressEnter(text)
            return result.pressEnter ? result.text : nil
        }
        XCTAssertEqual(strip("Run the tests, press enter."), "Run the tests")
        XCTAssertEqual(strip("Press enter."), "")
        XCTAssertEqual(strip("Ship it. Press Enter"), "Ship it.")
        XCTAssertNil(strip("Then press enter to continue."))
        XCTAssertNil(strip("Don't depress enter"))
        XCTAssertEqual(Spoken.stripPressEnter("No command.").text, "No command.")
    }

    func testShortPastesStayWhole() {
        XCTAssertEqual(VoiceDictationSpokenCommands.pasteChunks("one two"), ["one two"])
        XCTAssertEqual(VoiceDictationSpokenCommands.pasteChunks("a\nb\nc"), ["a\nb\nc"])
        let six = String(repeating: "x", count: 600)
        XCTAssertEqual(VoiceDictationSpokenCommands.pasteChunks(six), [six])
    }

    func testLongPastesSplitAtSpacesAndRejoinExactly() {
        let limit = VoiceDictationSpokenCommands.chunkCharacters
        let text = String(repeating: "word ", count: 300)
        let chunks = VoiceDictationSpokenCommands.pasteChunks(text)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertEqual(chunks.joined(), text)
        for (index, chunk) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(chunk.count, limit)
            XCTAssertTrue(chunk.hasSuffix(" ") || index == chunks.count - 1)
        }
        let lines = "a\nb\nc\nd\ne\nf"
        let lineChunks = VoiceDictationSpokenCommands.pasteChunks(lines)
        XCTAssertEqual(lineChunks.joined(), lines)
        XCTAssertTrue(lineChunks.allSatisfy { $0.filter { $0 == "\n" }.count <= 2 })
        let unbroken = String(repeating: "x", count: 1200)
        XCTAssertEqual(VoiceDictationSpokenCommands.pasteChunks(unbroken).map(\.count), [500, 500, 200])
    }

    // MARK: - Fitting to the cursor (Quill for Windows insertion.rs)

    private func fit(_ text: String, _ before: String, _ after: String, protected: [String] = []) -> String {
        VoiceDictationCursorFit.fit(text, surroundings: VoiceDictationSurroundings(before: before, after: after), protected: protected)
    }

    func testFitLeavesAnEmptyFieldUntouched() {
        XCTAssertEqual(fit("Send it tomorrow.", "", ""), "Send it tomorrow.")
    }

    func testFitMidSentenceLowercasesAndSpaces() {
        XCTAssertEqual(fit("The report is ready.", "I think", ""), " the report is ready.")
        XCTAssertEqual(fit("The report is ready.", "I think ", ""), "the report is ready.")
        XCTAssertEqual(fit("Tomorrow.", "Let's ship it, ", ""), "tomorrow.")
    }

    func testFitAfterASentenceKeepsTheCapitalAndAddsASpace() {
        XCTAssertEqual(fit("Then we ship.", "Done.", ""), " Then we ship.")
        XCTAssertEqual(fit("Then we ship.", "Done.\n", ""), "Then we ship.")
        XCTAssertEqual(fit("Then we ship.", "Note: ", ""), "Then we ship.")
    }

    func testFitKeepsCapitalsOfNamesAndPronouns() {
        XCTAssertEqual(fit("I can do it.", "and ", ""), "I can do it.")
        XCTAssertEqual(fit("I'm in.", "and ", ""), "I'm in.")
        XCTAssertEqual(fit("Tuesday works.", "maybe ", ""), "Tuesday works.")
        XCTAssertEqual(fit("NASA called.", "then ", ""), "NASA called.")
        XCTAssertEqual(fit("Sarah said Sarah would come.", "and ", ""), "Sarah said Sarah would come.")
        XCTAssertEqual(fit("Oruk is ready.", "and ", "", protected: ["Oruk"]), "Oruk is ready.")
        XCTAssertEqual(fit("McDonald called.", "then ", ""), "McDonald called.")
        XCTAssertEqual(fit("May works.", "maybe ", ""), "may works.", "May is not always capitalized")
    }

    func testFitDropsTheFullStopBeforeContinuingText() {
        XCTAssertEqual(fit("Next week.", "We meet ", " to plan"), "next week")
        XCTAssertEqual(fit("Next week.", "We meet ", "to plan"), "next week ")
        XCTAssertEqual(fit("Next week.", "We meet ", " Then we plan."), "next week.")
        XCTAssertEqual(fit("Is it done?", "", "and more"), "Is it done? ")
        XCTAssertEqual(fit("One. Two.", "", " three"), "One. Two.")
    }

    func testFitEdgesNextToPunctuationAndBrackets() {
        XCTAssertEqual(fit("Fine.", "(", ")"), "Fine.")
        XCTAssertEqual(fit("Yes", "He said \"", "\""), "Yes")
        XCTAssertEqual(fit("Done.", "word", ","), " done.")
    }

    func testFitReplacingASelection() {
        func fit(_ text: String, _ s: VoiceDictationSurroundings) -> String {
            VoiceDictationCursorFit.fit(text, surroundings: s, protected: [])
        }
        XCTAssertEqual(fit("Release it.", .init(before: "We should ", after: " soon", selection: "ship it")), "release it")
        XCTAssertEqual(fit("New text.", .init(selection: "old text")), "new text")
        XCTAssertEqual(fit("New sentence.", .init(selection: "Old sentence.")), "New sentence.")
    }

    func testFitKeepsTheStopOnMultiLineText() {
        XCTAssertEqual(fit("Hi.\nBye.", "", " more"), "Hi.\nBye.")
    }

    func testChatStyleThenFit() {
        let chat = VoiceDictationChatStyle.apply("Ship it today.")
        XCTAssertEqual(fit(chat, "We could ", ""), "ship it today")
        XCTAssertEqual(fit("Ship it today.", "We could ", ""), "ship it today.")
    }

    func testPlaceholderTextCountsAsAnEmptyField() {
        let placeholder = VoiceDictationSurroundings(before: "Message #general", after: "")
        XCTAssertEqual(placeholder.ignoringPlaceholder(labels: ["Message #general ", ""]), VoiceDictationSurroundings())
        XCTAssertEqual(placeholder.ignoringPlaceholder(labels: ["Message"]), placeholder)
        XCTAssertEqual(VoiceDictationSurroundings().ignoringPlaceholder(labels: [""]), VoiceDictationSurroundings())
    }

    func testControllerPreviewUsesTheSameMatcher() {
        let entry = vocab("t three code", "T3 Code")
        XCTAssertEqual(
            VoiceDictationController.preview(entry: entry, sample: "open T-three code now"),
            "open T3 Code now"
        )
    }
}
