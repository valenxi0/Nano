import Foundation

/// Rejects cleanup output that changed what the speaker meant.
///
/// A cleanup model tidying "I'd prefer to never merge this" into "I'd prefer
/// to merge this" is the worst thing dictation can do: the sentence still
/// reads well and says the opposite. The guard compares the recognizer's
/// text with the cleaned text for one chunk and hands back the recognizer's
/// text when the cleaned one has fewer negations, a figure nobody said, or a
/// sentence missing. Less polished beats wrong. It also catches a chunk the
/// model returned empty when there was clearly speech in it.
///
/// Bare "no" is deliberately not counted: in speech it is usually a
/// self-correction marker ("Tuesday, no, Thursday") that the cleaner is
/// meant to resolve.
enum VoiceDictationCleanupGuard {
    enum Reason: Equatable, Sendable {
        case negationDropped(raw: Int, cleaned: Int)
        /// A figure in the cleaned text that the speaker never said.
        case numberChanged(String)
        /// A sentence of the recognizer's text with almost none of its
        /// words left in the cleaned text.
        case sentenceDropped(String)
        case outputEmpty
    }

    struct Verdict: Equatable, Sendable {
        /// The text to use for this chunk.
        var text: String
        /// Set when `text` is the raw chunk rather than the cleaned one.
        var reason: Reason?

        var restoredRaw: Bool { reason != nil }
    }

    /// A chunk this long that cleans to nothing was not all filler.
    static let emptyOutputWordThreshold = 12

    static func verify(raw: String, cleaned: String) -> Verdict {
        let cleanedTrimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedTrimmed.isEmpty,
           VoiceDictationTranscriptChunker.wordCount(raw) >= emptyOutputWordThreshold {
            return Verdict(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), reason: .outputEmpty)
        }
        let rawCount = negationCount(raw)
        let cleanedCount = negationCount(cleanedTrimmed)
        if cleanedCount < rawCount {
            return Verdict(
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                reason: .negationDropped(raw: rawCount, cleaned: cleanedCount)
            )
        }
        if let figure = unspokenFigure(raw: raw, cleaned: cleanedTrimmed) {
            return Verdict(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), reason: .numberChanged(figure))
        }
        if let sentence = droppedSentence(raw: raw, cleaned: cleanedTrimmed) {
            return Verdict(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), reason: .sentenceDropped(sentence))
        }
        return Verdict(text: cleaned, reason: nil)
    }

    // MARK: - Figures

    /// The first figure in `cleaned` that cannot be traced to `raw`.
    ///
    /// The cleaner turns "twenty three thousand" into "23,000", so the raw
    /// side is read three ways: digits already there, digits after the
    /// number formatter, and each number word on its own. A cleaned figure
    /// passes when it is one of those, or runs through them in order
    /// ("555-0198" from seven spoken digits). Figures that vanish are fine:
    /// "at three, no, four" is meant to lose the three. Numbering the cleaner
    /// puts in front of list items is not a figure.
    static func unspokenFigure(raw: String, cleaned: String) -> String? {
        let unnumbered = cleaned.replacingOccurrences(of: #"(?m)^\s*\d+[.)]\s"#, with: "", options: .regularExpression)
        let figures = Self.figures(in: unnumbered)
        guard !figures.isEmpty else { return nil }
        let wordValues = tokens(in: raw).compactMap { numberWords[$0] }
        let sources = [
            Self.figures(in: raw),
            Self.figures(in: VoiceDictationNumberFormatter.format(raw, allDigits: true)),
            wordValues,
        ]
        var known = Set(sources.joined())
        // "A hundred", "a million": the one is implied.
        if tokens(in: raw).contains(where: scaleWords.contains) { known.insert("1") }
        let streams = sources.map { $0.joined() }
        return figures.first { figure in
            !known.contains(figure) && !(figure.count >= 3 && streams.contains { $0.contains(figure) })
        }
    }

    /// Runs of digits, with thousands separators closed up and leading
    /// zeros kept: "$23,450 by 4:30" is ["23450", "4", "30"].
    static func figures(in text: String) -> [String] {
        let closed = text.replacingOccurrences(of: #"(?<=\d),(?=\d{3}\b)"#, with: "", options: .regularExpression)
        var figures: [String] = []
        var current = ""
        for character in closed {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                figures.append(current)
                current = ""
            }
        }
        if !current.isEmpty { figures.append(current) }
        return figures
    }

    private static let scaleWords: Set<String> = ["hundred", "thousand", "million", "billion"]

    private static let numberWords: [String: String] = {
        let cardinals = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        ]
        let ordinals = [
            "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
            "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
            "eighteenth", "nineteenth",
        ]
        var words: [String: String] = [
            "oh": "0", "hundred": "100", "thousand": "1000", "million": "1000000", "billion": "1000000000",
            "half": "5", "quarter": "25",
        ]
        for (value, word) in cardinals.enumerated() { words[word] = String(value) }
        for (value, word) in ordinals.enumerated() { words[word] = String(value + 1) }
        for (index, word) in ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"].enumerated() {
            words[word] = String((index + 2) * 10)
        }
        words["twentieth"] = "20"
        words["thirtieth"] = "30"
        return words
    }()

    // MARK: - Dropped sentences

    /// A sentence needs this many distinct content words before its absence
    /// can be told apart from a false start being tidied away.
    static let droppedSentenceMinimumWords = 5

    /// The first sentence of `raw` whose content words are almost all
    /// missing from `cleaned`. Catches the cleaner skipping a sentence and
    /// its output being cut short by the token budget.
    static func droppedSentence(raw: String, cleaned: String) -> String? {
        let squashed = String(cleaned.lowercased().filter { $0.isLetter || $0.isNumber })
        let sentences = raw.replacingOccurrences(of: #"(?<=[.!?])\s+"#, with: "\n", options: .regularExpression)
            .split(whereSeparator: \.isNewline)
        for sentence in sentences {
            // Contractions are skipped: a register change rewrites them.
            let words = Set(tokens(in: String(sentence)).filter { !$0.contains("'") }.filter(isContentWord))
            guard words.count >= droppedSentenceMinimumWords else { continue }
            // A stem is enough: "migrated" still counts when it became "migrating".
            let kept = words.filter { squashed.contains($0.count > 6 ? String($0.prefix(5)) : $0) }
            if kept.count * 4 < words.count { return String(sentence) }
        }
        return nil
    }

    private static func isContentWord(_ word: String) -> Bool {
        word.count >= 4 && !fillerWords.contains(word) && numberWords[word] == nil
            && word.allSatisfy(\.isLetter) && !negationWords.contains(word) && !apostropheless.contains(word)
    }

    /// Words a cleaner removes or reshapes as a matter of course, so their
    /// absence says nothing about whether a sentence survived.
    private static let fillerWords: Set<String> = [
        "like", "know", "just", "really", "actually", "basically", "literally", "kind", "sort", "mean",
        "well", "okay", "yeah", "right", "that", "this", "with", "have", "what", "when", "then", "they",
        "them", "there", "here", "were", "been", "will", "would", "could", "should", "about", "from",
        "into", "your", "their", "which", "because", "think", "going", "gonna", "wanna", "thing", "things",
        "some", "very", "also", "still", "wait", "sorry", "scratch", "dollars",
        "dollar", "percent", "cents", "point",
    ]

    /// Meaning-bearing negations. "cannot" and "can not" both count once, and
    /// "do not" ↔ "don't" is a wash, so a register change never trips this.
    private static let negationWords: Set<String> = [
        "not", "never", "cannot", "neither", "nor", "none", "nothing", "nobody", "nowhere",
    ]

    static func negationCount(_ text: String) -> Int {
        tokens(in: text).reduce(0) { count, token in
            let isNegation = negationWords.contains(token)
                || token.hasSuffix("n't")
                || apostropheless.contains(token)
            return count + (isNegation ? 1 : 0)
        }
    }

    /// Words, lowercased, with surrounding punctuation removed but internal
    /// apostrophes kept so contractions survive. Curly apostrophes are
    /// normalized to straight ones.
    private static func tokens(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .map { word -> String in
                var core = Substring(word)
                while let first = core.first, !first.isLetter, !first.isNumber { core = core.dropFirst() }
                while let last = core.last, !last.isLetter, !last.isNumber { core = core.dropLast() }
                return String(core)
            }
            .filter { !$0.isEmpty }
    }

    /// An ASR sometimes drops the apostrophe: "dont", "cant", "wont". Only the
    /// common closed set counts, so "want" and "front" do not.
    private static let apostropheless: Set<String> = [
        "dont", "doesnt", "didnt", "cant", "couldnt", "wont", "wouldnt", "shouldnt",
        "isnt", "arent", "wasnt", "werent", "hasnt", "havent", "hadnt", "mustnt", "neednt", "aint",
    ]
}
