import Foundation

/// Deterministic, local text corrections applied to a transcript.
///
/// Matching is token based and forgiving about the things ASR gets wrong in
/// predictable ways: capitalization, hyphenation, and whether a compound came
/// out as one word or two. `north star`, `North-Star`, and `NorthStar` all
/// match a phrase configured as `North Star`. A phrase never matches inside a
/// longer word, so `nano` does not fire on `nanosecond`.
///
/// Snippets are the same mechanism with one extra guarantee: their expansion
/// is never shown to S1-mini. `protect(_:)` splits the transcript around
/// snippet matches so the cleaner only ever sees the user's speech, and the
/// expansion is spliced back in verbatim.
///
/// Spoken layout ("new line", "new paragraph") is cut out the same way, so a
/// break is placed by rule and never left for a model to notice.
struct VoiceDictationTextPipeline: Sendable {
    struct Output: Equatable, Sendable {
        var text: String
        var appliedPhrases: [String]
    }

    enum Segment: Equatable, Sendable {
        /// Speech to transcribe/clean.
        case speech(String)
        /// A snippet expansion, protected from any further rewriting.
        case expansion(String, phrase: String)
        /// A spoken "new line" (`"\n"`) or "new paragraph" (`"\n\n"`).
        case lineBreak(String)
    }

    let entries: [VoiceDictationVocabularyEntry]
    let layoutCues: Bool
    /// Learned from what the user deletes after a paste.
    let leaveOut: [String]
    let changeOfMindCues: [String]

    init(
        entries: [VoiceDictationVocabularyEntry],
        layoutCues: Bool = false,
        leaveOut: [String] = [],
        changeOfMindCues: [String] = []
    ) {
        self.entries = entries.filter { $0.isEnabled && $0.isValid }
        self.layoutCues = layoutCues
        self.leaveOut = leaveOut
        self.changeOfMindCues = changeOfMindCues
    }

    var isEmpty: Bool { entries.isEmpty }

    /// How the user writes their vocabulary terms, for runtimes that can
    /// listen for them. Only an aid: the deterministic pass below is the
    /// correction mechanism.
    var vocabularyTerms: [String] {
        entries
            .filter { $0.kind == .vocabulary }
            .map { $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The terms as Whisper's initial prompt.
    var promptHint: String? {
        VoiceDictationRecognitionRequest(vocabulary: vocabularyTerms).promptHint
    }

    /// Full deterministic pass with no cleanup stage: snippets and vocabulary.
    func apply(_ text: String) -> Output {
        replace(in: applyLearned(text), kinds: [.vocabulary, .snippet])
    }

    /// Vocabulary only. Used after S1-mini, whose output already had snippets
    /// removed by `protect(_:)`.
    func applyVocabulary(_ text: String) -> Output {
        replace(in: applyLearned(text), kinds: [.vocabulary])
    }

    /// Drops what the user taught Quill to drop: a stretch they restated after
    /// a learned cue, and phrases they always delete. Line by line, so breaks
    /// stay where they were.
    func applyLearned(_ text: String) -> String {
        guard !leaveOut.isEmpty || !changeOfMindCues.isEmpty, !text.isEmpty else { return text }
        return text.components(separatedBy: "\n").map { line in
            let leading = line.prefix { $0 == " " }
            let trailing = line.reversed().prefix { $0 == " " }
            var words = line.split(separator: " ").map(String.init)
            guard !words.isEmpty else { return line }
            words = Self.droppingChangesOfMind(words, cues: changeOfMindCues)
            words = Self.leavingOut(words, phrases: leaveOut)
            return String(leading) + words.joined(separator: " ") + String(trailing)
        }.joined(separator: "\n")
    }

    private static func key(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func endsSentence(_ word: String) -> Bool {
        word.last.map { ".!?".contains($0) } ?? false
    }

    private static func matches(_ words: [String], at index: Int, _ phrase: [String]) -> Bool {
        guard index + phrase.count <= words.count else { return false }
        return zip(words[index ..< index + phrase.count], phrase).allSatisfy { key($0) == $1 }
    }

    /// "Send it to John, actually send it to Mary." → "Send it to Mary." Only
    /// when the words after the cue restate the ones before it, so "There is
    /// no way" keeps its "no".
    static func droppingChangesOfMind(_ input: [String], cues: [String]) -> [String] {
        let phrases = cues.map { $0.split(separator: " ").map { key(String($0)) } }.filter { !$0.isEmpty }
        guard !phrases.isEmpty else { return input }
        var words = input
        var index = 1
        while index < words.count {
            guard let cue = phrases.first(where: { matches(words, at: index, $0) }) else {
                index += 1
                continue
            }
            var start = index
            while start > 0, !endsSentence(words[start - 1]) { start -= 1 }
            let before = words[start ..< index].map(key).filter { !$0.isEmpty }
            let afterEnd = min(words.count, index + cue.count + 8)
            let after = words[min(index + cue.count, words.count) ..< afterEnd].map(key).filter { !$0.isEmpty }
            let restates = !before.isEmpty && !after.isEmpty
                && (before.first == after.first || !Set(before.filter { $0.count >= 3 }).isDisjoint(with: after))
            // The restatement usually starts over with the same word; drop
            // from that word's last use, not from the start of the sentence.
            if let first = after.first,
               let restart = (start ..< index).last(where: { key(words[$0]) == first }) {
                start = restart
            }
            guard restates, !endsSentence(words[index - 1]), index - start <= 15 else {
                index += 1
                continue
            }
            let capitalize = words[start].first?.isUppercase == true
            words.removeSubrange(start ..< index + cue.count)
            if capitalize, start < words.count {
                words[start] = words[start].prefix(1).uppercased() + words[start].dropFirst()
            }
            index = max(start, 1)
        }
        return words
    }

    /// Removes each phrase, keeping a sentence's end and its capital.
    static func leavingOut(_ input: [String], phrases: [String]) -> [String] {
        let patterns = phrases.map { $0.split(separator: " ").map { key(String($0)) } }.filter { !$0.isEmpty }
        guard !patterns.isEmpty else { return input }
        var words = input
        var index = 0
        while index < words.count {
            guard let pattern = patterns.first(where: { matches(words, at: index, $0) }) else {
                index += 1
                continue
            }
            let last = words[index + pattern.count - 1]
            let ending = last.reversed().prefix { ".!?".contains($0) }
            let capitalize = words[index].first?.isUppercase == true
                && (index == 0 || endsSentence(words[index - 1]))
            words.removeSubrange(index ..< index + pattern.count)
            if !ending.isEmpty, index > 0 {
                let previous = words[index - 1].trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
                words[index - 1] = previous.hasSuffix(String(ending.reversed())) ? previous : previous + String(ending.reversed())
            }
            if capitalize, index < words.count {
                words[index] = words[index].prefix(1).uppercased() + words[index].dropFirst()
            }
        }
        return words
    }

    /// Splits `text` at snippet triggers and layout cues so a cleaner can run
    /// on the speech segments alone. Vocabulary is not applied here; it runs
    /// after cleanup.
    func protect(_ text: String) -> [Segment] {
        let snippets = entries.filter { $0.kind == .snippet }
        guard !snippets.isEmpty || layoutCues else { return [.speech(text)] }
        let tokens = Self.tokenize(text)
        var segments: [Segment] = []
        var speechStart = text.startIndex
        var index = 0
        var capitalizeNext = false
        func appendSpeech(_ speech: String) {
            guard !speech.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            segments.append(.speech(capitalizeNext ? Self.capitalizingFirstLetter(speech) : speech))
            capitalizeNext = false
        }
        while index < tokens.count {
            if layoutCues, let (lineBreak, length) = Self.layoutCue(at: index, in: tokens) {
                // The cue's own punctuation goes with it. A comma left
                // hanging before a paragraph break becomes a full stop; a
                // line break keeps it, as in "Hi John," then a new line.
                var before = String(text[speechStart ..< tokens[index].range.lowerBound])
                if lineBreak == "\n\n" { before = Self.closingSentence(before) }
                appendSpeech(before)
                segments.append(.lineBreak(lineBreak))
                capitalizeNext = true
                speechStart = tokens[index + length - 1].range.upperBound
                index += length
            } else if let (entry, length) = longestMatch(at: index, in: tokens, among: snippets) {
                let first = tokens[index]
                let last = tokens[index + length - 1]
                appendSpeech(String(text[speechStart ..< first.range.lowerBound]) + first.leadingPunctuation)
                segments.append(.expansion(entry.replacement + last.trailingPunctuation, phrase: entry.phrase))
                capitalizeNext = false
                speechStart = last.range.upperBound
                index += length
            } else {
                index += 1
            }
        }
        appendSpeech(String(text[speechStart...]))
        return segments.isEmpty ? [.speech("")] : segments
    }

    /// Joins pieces back into one string. Line breaks at the edges of a
    /// piece (a spoken "new paragraph") are kept between pieces, at most a
    /// blank line; a piece that opens a list starts on its own line; anything
    /// else gets a single space. Breaks before the first piece and after the
    /// last are dropped unless `keepingEdgeBreaks`, which a caller uses when
    /// its result is itself one piece of a longer text.
    static func join(_ pieces: [String], keepingEdgeBreaks: Bool = false) -> String {
        var result = ""
        var pendingBreaks = 0
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                pendingBreaks = max(pendingBreaks, piece.filter(\.isNewline).count)
                continue
            }
            pendingBreaks = max(pendingBreaks, piece.prefix(while: \.isWhitespace).filter(\.isNewline).count)
            if pendingBreaks > 0, !result.isEmpty || keepingEdgeBreaks {
                result += String(repeating: "\n", count: min(pendingBreaks, 2)) + trimmed
            } else if result.isEmpty {
                result = trimmed
            } else if trimmed.first.map({ ".,;:!?)]}".contains($0) }) == true {
                result += trimmed
            } else if trimmed.range(of: #"^(-|\d+[.)]) "#, options: .regularExpression) != nil {
                result += "\n" + trimmed
            } else {
                result += " " + trimmed
            }
            pendingBreaks = piece.reversed().prefix(while: \.isWhitespace).filter(\.isNewline).count
        }
        if keepingEdgeBreaks, pendingBreaks > 0 {
            result += String(repeating: "\n", count: min(pendingBreaks, 2))
        }
        return result
    }

    // MARK: - Layout cues

    /// Words that make "new line" a thing being talked about, not a command:
    /// "add a new line", "the new paragraph reads better".
    private static let cueBlockers: Set<String> = [
        "a", "an", "the", "this", "that", "another", "each", "every", "one", "any", "no", "per",
        "my", "your", "our", "their", "its", "his", "her", "whole", "entire", "brand",
    ]

    /// Words that continue the phrase: "a new line of products".
    private static let cueContinuations: Set<String> = ["of", "item", "items", "character", "characters", "break", "breaks"]

    /// A spoken layout cue starting at `index`, as the break it stands for
    /// and the number of tokens it covers. "New paragraph" is rarely meant
    /// literally, so it only has to be free of an article before it. "New
    /// line" is common in ordinary speech, so it also has to be set off by a
    /// pause the recognizer wrote as punctuation, or open or close the text.
    private static func layoutCue(at index: Int, in tokens: [Token]) -> (String, Int)? {
        let first = tokens[index]
        let length: Int
        let lineBreak: String
        if first.normalized == "newline" {
            (length, lineBreak) = (1, "\n")
        } else if first.normalized == "new", index + 1 < tokens.count {
            switch tokens[index + 1].normalized {
            case "line": (length, lineBreak) = (2, "\n")
            case "paragraph": (length, lineBreak) = (2, "\n\n")
            default: return nil
            }
        } else {
            return nil
        }
        let last = tokens[index + length - 1]
        let previous = index > 0 ? tokens[index - 1] : nil
        let next = index + length < tokens.count ? tokens[index + length] : nil
        // Quoted ("the 'new line' key") is literal.
        guard first.leadingPunctuation.isEmpty,
              last.trailingPunctuation.allSatisfy({ ".,;:!?".contains($0) }),
              length == 1 || first.trailingPunctuation.isEmpty
        else { return nil }
        if let previous, cueBlockers.contains(previous.normalized), previous.trailingPunctuation.isEmpty { return nil }
        if let next, last.trailingPunctuation.isEmpty, cueContinuations.contains(next.normalized) { return nil }
        if lineBreak == "\n" {
            let setOffBefore = previous == nil || !previous!.trailingPunctuation.isEmpty
            let setOffAfter = next == nil || !last.trailingPunctuation.isEmpty
            guard setOffBefore || setOffAfter else { return nil }
        }
        return (lineBreak, length)
    }

    private static func closingSentence(_ text: String) -> String {
        var body = text[...]
        while let last = body.last, last.isWhitespace { body = body.dropLast() }
        guard let last = body.last, ",;:".contains(last) else { return text }
        return body.dropLast() + "."
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: { $0.isLetter || $0.isNumber }), text[index].isLowercase else { return text }
        return text.replacingCharacters(in: index ... index, with: text[index].uppercased())
    }

    // MARK: - Matching

    private struct Token {
        let range: Range<String.Index>
        let normalized: String
        let leadingPunctuation: String
        let trailingPunctuation: String
    }

    private static let strippable = CharacterSet.punctuationCharacters
        .union(.symbols)
        .subtracting(CharacterSet(charactersIn: "@"))

    static func normalize(_ word: Substring) -> String {
        word.lowercased()
            .unicodeScalars
            .filter { !strippable.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            let word = text[start ..< index]
            var leading = ""
            var trailing = ""
            var core = word
            while let first = core.first, first.isPunctuation || first.isSymbol, first != "@" {
                leading.append(first)
                core = core.dropFirst()
            }
            while let last = core.last, last.isPunctuation || last.isSymbol, last != "@" {
                trailing.insert(last, at: trailing.startIndex)
                core = core.dropLast()
            }
            tokens.append(Token(
                range: start ..< index,
                normalized: normalize(core),
                leadingPunctuation: leading,
                trailingPunctuation: trailing
            ))
        }
        return tokens
    }

    private static func normalizedPhrase(_ phrase: String) -> (joined: String, wordCount: Int) {
        let words = phrase.split(whereSeparator: \.isWhitespace).map(normalize).filter { !$0.isEmpty }
        return (words.joined(), words.count)
    }

    /// The entry whose phrase covers the most tokens starting at `index`.
    /// Compound spellings are handled by comparing the space-free join of a
    /// window of tokens, so a phrase of two words can match one or two tokens.
    private func longestMatch(
        at index: Int,
        in tokens: [Token],
        among candidates: [VoiceDictationVocabularyEntry]
    ) -> (VoiceDictationVocabularyEntry, Int)? {
        var best: (VoiceDictationVocabularyEntry, Int)?
        for entry in candidates {
            let target = Self.normalizedPhrase(entry.phrase)
            guard !target.joined.isEmpty else { continue }
            // A phrase of N words may span 1...N tokens (merged) or more if the
            // ASR split a word; allow a little slack above N.
            let maxSpan = min(tokens.count - index, target.wordCount + 2)
            var joined = ""
            for length in 1 ... max(maxSpan, 1) {
                guard index + length - 1 < tokens.count else { break }
                joined += tokens[index + length - 1].normalized
                if joined.count > target.joined.count { break }
                if joined == target.joined {
                    if best == nil || length > best!.1 {
                        best = (entry, length)
                    }
                    break
                }
            }
        }
        return best
    }

    private func replace(in text: String, kinds: Set<VoiceDictationVocabularyEntry.Kind>) -> Output {
        let candidates = entries.filter { kinds.contains($0.kind) }
        guard !candidates.isEmpty, !text.isEmpty else {
            return Output(text: text, appliedPhrases: [])
        }
        let tokens = Self.tokenize(text)
        var result = ""
        var applied: [String] = []
        var cursor = text.startIndex
        var index = 0
        while index < tokens.count {
            if let (entry, length) = longestMatch(at: index, in: tokens, among: candidates) {
                let first = tokens[index]
                let last = tokens[index + length - 1]
                result += text[cursor ..< first.range.lowerBound]
                result += first.leadingPunctuation + entry.replacement + last.trailingPunctuation
                cursor = last.range.upperBound
                applied.append(entry.phrase)
                index += length
            } else {
                index += 1
            }
        }
        result += text[cursor...]
        return Output(text: result, appliedPhrases: applied)
    }
}

/// Turns a pasted list into dictionary entries. One term per line or comma;
/// `spoken → written` (also `->`, `=>`, `=` or a tab) sets how a phrase is
/// written. A bare term is written exactly as typed whenever it is heard, in
/// any case or spacing.
enum VoiceDictationVocabularyImport {
    private static let separators = ["→", "->", "=>", "\t", "="]

    static func parse(_ text: String, existing: [VoiceDictationVocabularyEntry] = []) -> [VoiceDictationVocabularyEntry] {
        var seen = Set(existing.map { VoiceDictationTextPipeline.normalize(Substring($0.phrase)) })
        var entries: [VoiceDictationVocabularyEntry] = []
        for line in text.components(separatedBy: .newlines) {
            let pairs: [(String, String)]
            if let separator = separators.first(where: { line.contains($0) }),
               let range = line.range(of: separator) {
                pairs = [(String(line[..<range.lowerBound]), String(line[range.upperBound...]))]
            } else {
                pairs = line.split(separator: ",").map { (String($0), String($0)) }
            }
            for (spoken, written) in pairs {
                let phrase = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = written.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = VoiceDictationTextPipeline.normalize(Substring(phrase))
                guard !phrase.isEmpty, !replacement.isEmpty, !key.isEmpty, seen.insert(key).inserted else { continue }
                entries.append(VoiceDictationVocabularyEntry(phrase: phrase, replacement: replacement, kind: .vocabulary))
            }
        }
        return entries
    }
}
