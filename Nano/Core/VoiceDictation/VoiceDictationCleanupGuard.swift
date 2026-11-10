import Foundation

/// Rejects cleanup output that changed what the speaker meant.
///
/// A cleanup model tidying "I'd prefer to never merge this" into "I'd prefer
/// to merge this" is the worst thing dictation can do: the sentence still
/// reads well and says the opposite. The guard compares the recognizer's
/// text with the cleaned text for one chunk and, where the cleaned one has
/// fewer negations, a figure nobody said, or a sentence missing, hands back
/// the recognizer's text for those sentences. Less polished beats wrong. It also catches a chunk the
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
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTrimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedTrimmed.isEmpty,
           VoiceDictationTranscriptChunker.wordCount(raw) >= emptyOutputWordThreshold {
            return Verdict(text: rawTrimmed, reason: .outputEmpty)
        }
        guard let reason = rejection(raw: rawTrimmed, cleaned: cleanedTrimmed) else {
            return Verdict(text: cleaned, reason: nil)
        }
        return Verdict(text: restoringRejected(raw: rawTrimmed, cleaned: cleanedTrimmed), reason: reason)
    }

    private static func rejection(raw: String, cleaned: String) -> Reason? {
        let rawCount = negationCount(raw)
        let cleanedCount = negationCount(cleaned)
        if cleanedCount < rawCount { return .negationDropped(raw: rawCount, cleaned: cleanedCount) }
        if let figure = unspokenFigure(raw: raw, cleaned: cleaned) { return .numberChanged(figure) }
        if let sentence = droppedSentence(raw: raw, cleaned: cleaned) { return .sentenceDropped(sentence) }
        return nil
    }

    // MARK: - Partial restore

    /// The cleaned text with only its rejected sentences put back as said.
    ///
    /// Each cleaned sentence is matched, in order, to the raw sentence it
    /// shares the most words with. Raw sentences nothing matched (merged or
    /// tidied away) join the block before them, so every block pairs a run
    /// of raw sentences with the cleaned sentences made from it. Each block
    /// is checked on its own; a failing one is replaced by its raw text and
    /// the rest keep their cleanup and their line breaks.
    static func restoringRejected(raw: String, cleaned: String) -> String {
        let rawSentences = sentenceRanges(in: raw).map { String(raw[$0]) }
        let units = sentenceRanges(in: cleaned)
        let rawWords = rawSentences.map(matchWords)
        var owners: [Int?] = []
        var floor = 0
        for unit in units {
            let words = matchWords(String(cleaned[unit]))
            var best: Int?
            var bestOverlap = 0
            for index in floor ..< rawWords.count {
                let overlap = words.intersection(rawWords[index]).count
                if overlap > bestOverlap { (best, bestOverlap) = (index, overlap) }
            }
            owners.append(best)
            if let best { floor = best }
        }
        // A unit with nothing to match ("1." of a list item) goes with the next.
        var following: Int?
        for index in owners.indices.reversed() {
            if let owner = owners[index] { following = owner } else { owners[index] = following }
        }
        var preceding: Int?
        for index in owners.indices {
            if let owner = owners[index] { preceding = owner } else { owners[index] = preceding }
        }
        let starts = owners.compactMap { $0 }.reduce(into: [Int]()) { if $0.last != $1 { $0.append($1) } }
        guard starts.count > 1 else { return raw }

        var result = ""
        var unitIndex = 0
        var previousEnd = cleaned.startIndex
        for (block, start) in starts.enumerated() {
            let first = unitIndex
            while unitIndex < units.count, owners[unitIndex] == start { unitIndex += 1 }
            let cleanedRange = units[first].lowerBound ..< units[unitIndex - 1].upperBound
            let rawStart = block == 0 ? 0 : start
            let rawEnd = block + 1 < starts.count ? starts[block + 1] : rawSentences.count
            let rawText = rawSentences[rawStart ..< rawEnd].joined(separator: " ")
            let cleanedText = String(cleaned[cleanedRange])
            result += cleaned[previousEnd ..< cleanedRange.lowerBound]
            result += rejection(raw: rawText, cleaned: cleanedText) == nil ? cleanedText : rawText
            previousEnd = cleanedRange.upperBound
        }
        return result
    }

    /// Sentences and lines, without the space or line break between them.
    private static func sentenceRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        let separator = #"(?<=[.!?])\s+|\s*\n\s*"#
        while let gap = text.range(of: separator, options: .regularExpression, range: start ..< text.endIndex) {
            if start < gap.lowerBound { ranges.append(start ..< gap.lowerBound) }
            start = gap.upperBound
        }
        if start < text.endIndex { ranges.append(start ..< text.endIndex) }
        return ranges
    }

    private static func matchWords(_ text: String) -> Set<String> {
        Set(tokens(in: text).filter { $0.count >= 3 })
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

    /// A stutter counts once: "I'm not, I'm not going" has one negation.
    static func negationCount(_ text: String) -> Int {
        collapsingRepeats(tokens(in: text)).reduce(0) { count, token in
            let isNegation = negationWords.contains(token)
                || token.hasSuffix("n't")
                || apostropheless.contains(token)
            return count + (isNegation ? 1 : 0)
        }
    }

    /// Drops the first copy of a run of one to four words said twice in a row.
    static func collapsingRepeats(_ tokens: [String]) -> [String] {
        var kept: [String] = []
        var index = 0
        while index < tokens.count {
            let repeated = (1 ... 4).reversed().first { length in
                index + 2 * length <= tokens.count
                    && tokens[index ..< index + length] == tokens[index + length ..< index + 2 * length]
            }
            if let repeated {
                index += repeated
            } else {
                kept.append(tokens[index])
                index += 1
            }
        }
        return kept
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
