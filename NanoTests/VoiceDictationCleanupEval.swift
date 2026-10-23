import XCTest
@testable import Nano

/// Runs the real S1-mini over fixed transcripts and checks each output
/// against a rubric written before the run.
///
/// Skipped unless `NANO_VD_CLEANUP_EVAL=1` and S1-mini is installed in
/// Nano's model directory. Every output, pass or fail, is written to
/// `$NANO_VD_CLEANUP_EVAL_OUT` (default `/tmp/nano-vd/cleanup-eval`), so a
/// change to a control line or to the guard can be read side by side with
/// the last run.
final class VoiceDictationCleanupEval: XCTestCase {
    struct Fixture {
        let id: String
        let directive: VoiceDictationCleanupDirective
        /// What a recognizer hands over: punctuated, fillers and all.
        let transcript: String
        /// Case-insensitive substrings the output must keep.
        var keeps: [String] = []
        /// Case-insensitive substrings the output must not contain.
        var drops: [String] = []
        /// Regular expressions (multi-line) the output must match.
        var matches: [String] = []
        /// Whether the guard is expected to hand back the recognizer's text.
        var guarded = false
    }

    static let fillers = "Um, so I think we should, uh, ship it on Tuesday, no, Thursday, and, um, let the team know before the standup."
    static let numbers = "The invoice came to twenty three thousand four hundred and fifty dollars and it's due on March third twenty twenty six."
    static let counted = "Okay so before the release we need to do three things. First, update the changelog. Second, um, run the full test suite. And third, tag the build and notify the team."
    static let groceries = "For the trip we need to bring sunscreen, a first aid kit, uh, two tents, and enough water for three days."
    static let email = "Hi Priya, um, thanks for sending the report over. I had a look and I think the numbers in section two are off by about ten percent. Can you double check them before Friday? Thanks, Alex."
    static let figures = "Call me back at five five five, zero one nine eight, before the fourteenth. I'm free at four thirty PM."
    static let amounts = "It costs about a hundred dollars a month, so, uh, two and a half times what we paid in nineteen ninety nine for twelve seats."
    static let technical = "We migrated the Kubernetes cluster to Postgres sixteen, rewrote the SwiftUI view in Xcode, and asked Priya Ramaswamy to review it. Email me at alex dot rivera at example dot com."
    static let long = """
        Hi team, quick update on the notch companion work. Over the last week we finished the settings pane for voice dictation, wired the global hotkey through Carbon so it does not need accessibility permission, and moved model downloads onto a background task so the island never stalls. There are three engines to choose from, and none of them download unless you pick one. The default pairs Parakeet with S1 mini, which cleans up fillers and adds punctuation. Whisper base and Whisper tiny are there as fallbacks for smaller machines. History is off unless you turn it on, and when it is on, entries are removed after twenty four hours. Next up is the benchmark on the Mac mini, then a review pass on the failure states, and after that we can talk about shipping it in the next build. Let me know if anything here is unclear.
        """
    static let prose = "I talked to the landlord yesterday and he said the repair is not going to happen until next month, which is, you know, kind of frustrating, but I don't think we should push back yet."

    static let fixtures: [Fixture] = {
        let casual = VoiceDictationCleanupDirective(styling: .casual)
        let polished = VoiceDictationCleanupDirective.polished
        let formal = VoiceDictationCleanupDirective(styling: .formal)
        let lists = VoiceDictationCleanupDirective(styling: .semiFormal, structure: .lists)
        let mail = VoiceDictationCleanupDirective(styling: .semiFormal, context: .email)
        return [
            Fixture(id: "fillers-polished", directive: polished, transcript: fillers,
                    keeps: ["Thursday", "team", "standup"], drops: ["um", "uh", "Tuesday"]),
            Fixture(id: "fillers-casual", directive: casual, transcript: fillers,
                    keeps: ["Thursday", "team", "standup"], drops: ["Tuesday"]),
            Fixture(id: "fillers-formal", directive: formal, transcript: fillers,
                    keeps: ["Thursday", "team", "standup"], drops: ["um", "uh", "Tuesday"]),
            Fixture(id: "prose-casual", directive: casual, transcript: prose,
                    keeps: ["landlord", "not going to happen", "next month"]),
            Fixture(id: "numbers-casual", directive: casual, transcript: numbers, keeps: ["23,450", "2026"]),
            Fixture(id: "email-formal", directive: .init(styling: .formal, context: .email), transcript: email,
                    keeps: ["Priya", "section", "10", "Friday", "Alex"], drops: ["um"],
                    matches: [#"(?m)^Hi Priya,$"#, #"(?m)^Alex\.?$"#]),
            Fixture(id: "counted-email-lists", directive: .init(styling: .semiFormal, structure: .lists, context: .email),
                    transcript: "Hi team, " + counted + " Thanks, Alex.",
                    keeps: ["changelog", "test suite", "tag the build"],
                    matches: [#"(?m)^Hi team,$"#, #"(?m)^1[.)] "#, #"(?m)^3[.)] "#, #"(?m)^Alex\.?$"#]),
            Fixture(id: "plain-in-email", directive: mail, transcript: prose,
                    keeps: ["landlord", "not going to happen", "next month"], drops: ["\n"]),
            Fixture(id: "phone-time", directive: polished, transcript: figures,
                    keeps: ["555", "0198", "4:30", "14"]),
            Fixture(id: "amounts", directive: polished, transcript: amounts,
                    keeps: ["100", "1999", "12"], matches: ["2\\.5|two and a half"]),
            Fixture(id: "technical", directive: polished, transcript: technical,
                    keeps: ["Kubernetes", "Postgres 16", "SwiftUI", "Priya Ramaswamy", "alex.rivera@example.com"]),
            Fixture(id: "long-polished", directive: polished, transcript: long,
                    keeps: ["Carbon", "three engines", "Whisper", "24 hours", "Mac mini", "unclear"]),
            Fixture(id: "long-lists", directive: lists, transcript: long,
                    keeps: ["Carbon", "Whisper", "24 hours", "Mac mini", "unclear"]),
            Fixture(id: "numbers-polished", directive: polished, transcript: numbers,
                    keeps: ["23,450", "March 3", "2026"]),
            Fixture(id: "numbers-lists", directive: lists, transcript: numbers,
                    keeps: ["23,450", "March 3", "2026"], drops: ["\n"]),
            Fixture(id: "negation-polished", directive: polished, transcript: prose,
                    keeps: ["not going to happen", "next month", "landlord"], drops: ["you know"]),
            Fixture(id: "negation-formal", directive: formal, transcript: prose,
                    keeps: ["next month", "landlord"], drops: ["you know"]),
            Fixture(id: "prose-stays-prose-in-lists", directive: lists, transcript: prose,
                    keeps: ["next month", "landlord"], drops: ["\n", "- ", "1."]),
            Fixture(id: "counted-lists", directive: lists, transcript: counted,
                    keeps: ["changelog", "test suite", "tag the build", "notify the team"],
                    matches: [#"(?m)^1[.)] .*changelog"#, #"(?m)^2[.)] .*test suite"#, #"(?m)^3[.)] .*tag the build"#]),
            Fixture(id: "counted-polished", directive: polished, transcript: counted,
                    keeps: ["changelog", "test suite", "tag the build", "notify the team"], drops: ["\n"]),
            Fixture(id: "groceries-lists", directive: lists, transcript: groceries,
                    keeps: ["sunscreen", "first aid kit", "tents", "water", "three days"],
                    matches: [#"(?m)^- sunscreen"#, #"(?m)^- .*tents"#]),
            Fixture(id: "email-context", directive: mail, transcript: email,
                    keeps: ["Priya", "section", "10", "Friday", "Alex"], drops: ["um"],
                    matches: [#"(?m)^Hi Priya,$"#, #"(?m)^Thanks,$"#, #"(?m)^Alex\.?$"#]),
            Fixture(id: "email-general", directive: polished, transcript: email,
                    keeps: ["Priya", "section", "10", "Friday", "Alex"], drops: ["um", "\n"]),
        ]
    }()

    func testFixturesMeetTheirRubrics() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["NANO_VD_CLEANUP_EVAL"] == "1", "Set NANO_VD_CLEANUP_EVAL=1 to run the cleanup eval.")
        let modelURL = await MainActor.run {
            VoiceDictationModelStore(rootDirectory: VoiceDictationModelStore.defaultRootDirectory)
                .primaryFileURL(for: .s1Mini)
        }
        let url = try XCTUnwrap(modelURL)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "S1-mini is not installed.")

        let cleaner = S1MiniCleaner(modelURL: url)
        try await cleaner.load()
        var records: [[String: Any]] = []
        var failures: [String] = []
        for fixture in Self.fixtures {
            let started = ContinuousClock.now
            let cleaned = try await cleaner.clean(fixture.transcript, directive: fixture.directive)
            let elapsed = started.duration(to: .now)
            let verdict = VoiceDictationCleanupGuard.verify(raw: fixture.transcript, cleaned: cleaned)
            let problems = Self.problems(fixture, cleaned: cleaned, verdict: verdict)
            if !problems.isEmpty { failures.append("\(fixture.id): \(problems.joined(separator: "; "))") }
            records.append([
                "id": fixture.id,
                "control": S1MiniCleaner.controlLine(for: fixture.directive),
                "transcript": fixture.transcript,
                "cleaned": cleaned,
                "guard": verdict.reason.map { "\($0)" } ?? "kept",
                "problems": problems,
                "ms": Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15),
            ])
        }
        await cleaner.unload()

        let out = URL(fileURLWithPath: environment["NANO_VD_CLEANUP_EVAL_OUT"] ?? "/tmp/nano-vd/cleanup-eval", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: out.appendingPathComponent("report.json"))
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(Self.fixtures.count) fixtures missed their rubric:\n" + failures.joined(separator: "\n"))
    }

    static func problems(
        _ fixture: Fixture,
        cleaned: String,
        verdict: VoiceDictationCleanupGuard.Verdict
    ) -> [String] {
        var problems: [String] = []
        if verdict.restoredRaw != fixture.guarded {
            problems.append(fixture.guarded ? "guard should have fired" : "guard fired: \(verdict.reason!)")
        }
        for keep in fixture.keeps where cleaned.range(of: keep, options: .caseInsensitive) == nil {
            problems.append("lost “\(keep)”")
        }
        for drop in fixture.drops where contains(cleaned, word: drop) {
            problems.append("kept “\(drop.replacingOccurrences(of: "\n", with: "\\n"))”")
        }
        for pattern in fixture.matches where cleaned.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil {
            problems.append("no match for \(pattern)")
        }
        return problems
    }

    /// Whole-word match for words, so "um" is not found inside "numbers";
    /// plain substring match for anything else (a newline, a bullet).
    private static func contains(_ text: String, word: String) -> Bool {
        guard word.allSatisfy({ $0.isLetter || $0 == " " }) else { return text.contains(word) }
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
