import Foundation

/// Splits a long transcript into pieces S1-mini can clean whole.
///
/// S1-mini's output budget is capped, and a single pass over a ten-minute
/// dictation would silently lose its tail. Chunks break at sentence ends
/// first, then clause punctuation, then plain word boundaries, so the model
/// always sees a complete thought and never half a sentence. Short
/// transcripts come back as one chunk and take the same path as before.
enum VoiceDictationTranscriptChunker {
    /// About 600 tokens of ordinary English: comfortably under the cleaner's
    /// ceiling after the 1.3× output allowance, and short enough that each
    /// pass stays in the range where the model is fastest.
    static let defaultWordBudget = 400

    static func chunk(_ text: String, wordBudget: Int = defaultWordBudget) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard wordCount(trimmed) > wordBudget else { return [trimmed] }

        var chunks: [String] = []
        var current: [String] = []
        var currentWords = 0

        for sentence in split(trimmed, on: sentenceEnd) {
            let words = wordCount(sentence)
            if words > wordBudget {
                // Flush what we have, then break the oversized sentence on
                // its own without merging it into neighbors.
                flush(&current, &currentWords, into: &chunks)
                chunks.append(contentsOf: splitOversized(sentence, wordBudget: wordBudget))
                continue
            }
            if currentWords + words > wordBudget, !current.isEmpty {
                flush(&current, &currentWords, into: &chunks)
            }
            current.append(sentence)
            currentWords += words
        }
        flush(&current, &currentWords, into: &chunks)
        return chunks
    }

    // MARK: - Helpers

    private static let sentenceEnd = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+"#)
    private static let clauseEnd = try! NSRegularExpression(pattern: #"(?<=[,;:])\s+"#)

    private static func flush(_ current: inout [String], _ words: inout Int, into chunks: inout [String]) {
        guard !current.isEmpty else { return }
        chunks.append(current.joined(separator: " "))
        current.removeAll()
        words = 0
    }

    /// A sentence over budget is split at clause punctuation; a clause still
    /// over budget is cut at word boundaries.
    private static func splitOversized(_ sentence: String, wordBudget: Int) -> [String] {
        var result: [String] = []
        var current: [String] = []
        var currentWords = 0
        for clause in split(sentence, on: clauseEnd) {
            let words = wordCount(clause)
            if words > wordBudget {
                flush(&current, &currentWords, into: &result)
                let tokens = clause.split(whereSeparator: \.isWhitespace).map(String.init)
                var start = 0
                while start < tokens.count {
                    let end = min(start + wordBudget, tokens.count)
                    result.append(tokens[start ..< end].joined(separator: " "))
                    start = end
                }
                continue
            }
            if currentWords + words > wordBudget, !current.isEmpty {
                flush(&current, &currentWords, into: &result)
            }
            current.append(clause)
            currentWords += words
        }
        flush(&current, &currentWords, into: &result)
        return result
    }

    private static func split(_ text: String, on regex: NSRegularExpression) -> [String] {
        let ns = text as NSString
        var pieces: [String] = []
        var start = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: NSRange(location: start, length: match.range.location - start))
            if !piece.isEmpty { pieces.append(piece) }
            start = match.range.location + match.range.length
        }
        let tail = ns.substring(from: start)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }
}
