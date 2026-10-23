import ApplicationServices
import Combine
import Foundation

/// Something the user fixed by hand after a dictation, often enough to learn.
struct VoiceDictationCorrection: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A misheard word: `spoken` → `written`.
        case word
        /// A word or short phrase the user keeps deleting: `spoken`.
        case leaveOut
        /// A cue such as "actually" that the user said before restating
        /// themselves, deleting what came before it: `spoken`.
        case changeOfMind
    }

    var kind: Kind = .word
    var spoken: String
    var written: String
    var count: Int
    var dismissed: Bool = false
    var lastSeen: Date
    /// The app the correction was made in; accepting it adds an entry for
    /// that app only. Nil on corrections learned before apps were kept.
    var bundleID: String?
    var appName: String?

    var id: String { Self.key(kind: kind, spoken: spoken, written: written, bundleID: bundleID) }

    static func key(kind: Kind = .word, spoken: String, written: String, bundleID: String? = nil) -> String {
        let base = spoken.lowercased() + "\u{1F}" + written + "\u{1F}" + (bundleID?.lowercased() ?? "")
        return kind == .word ? base : kind.rawValue + "\u{1F}" + base
    }

    init(
        kind: Kind = .word, spoken: String, written: String, count: Int, dismissed: Bool = false,
        lastSeen: Date, bundleID: String? = nil, appName: String? = nil
    ) {
        self.kind = kind
        self.spoken = spoken
        self.written = written
        self.count = count
        self.dismissed = dismissed
        self.lastSeen = lastSeen
        self.bundleID = bundleID
        self.appName = appName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .word
        spoken = try container.decode(String.self, forKey: .spoken)
        written = try container.decode(String.self, forKey: .written)
        count = try container.decode(Int.self, forKey: .count)
        dismissed = try container.decodeIfPresent(Bool.self, forKey: .dismissed) ?? false
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
    }
}

/// Finds what the user fixed between what Quill pasted and what the field
/// holds later:
/// - a short span replaced by a similar-looking one, or a change of case, is
///   a misheard word;
/// - a stretch deleted just before a restatement, with a cue such as
///   "actually" in it, is a change of mind cleanup missed;
/// - one to three words deleted on their own are a candidate to leave out.
/// A rewrite ("big" → "large") or an edit touching more than half the words
/// is the user changing what they meant, and teaches nothing.
enum VoiceDictationCorrectionDiff {
    struct Pair: Equatable, Sendable {
        var kind: VoiceDictationCorrection.Kind = .word
        let spoken: String
        let written: String
    }

    /// Words people say when they restate themselves, longest first.
    static let changeOfMindCues = [
        "let me rephrase", "scratch that", "never mind", "or rather", "i mean",
        "actually", "sorry", "wait", "no",
    ]

    static let minimumSimilarity = 0.45

    static func corrections(original: String, edited: String) -> [Pair] {
        let before = words(original)
        let after = words(edited)
        guard !before.isEmpty, !after.isEmpty, before != after else { return [] }

        let keysBefore = before.map(normalized)
        let keysAfter = after.map(normalized)
        let matches = lcs(keysBefore, keysAfter)
        guard Double(matches.count) >= Double(before.count) * 0.5 else { return [] }

        var pairs: [Pair] = []
        var i = 0
        var j = 0
        for (mi, mj) in matches + [(before.count, after.count)] {
            let removed = Array(before[i ..< mi])
            let added = Array(after[j ..< mj])
            if let pair = substitution(removed, added) {
                pairs.append(pair)
            } else if !removed.isEmpty, added.isEmpty, let pair = deletion(removed) {
                pairs.append(pair)
            }
            if mi < before.count, mj < after.count,
               stripped(before[mi]) != stripped(after[mj]),
               keysBefore[mi].count >= 3,
               !startsSentence(at: mi, in: before) {
                // Same letters, different case: "nano" → "Nano". A capital
                // at the start of a sentence is grammar, not a name.
                pairs.append(Pair(spoken: stripped(before[mi]), written: stripped(after[mj])))
            }
            i = mi + 1
            j = mj + 1
        }
        return pairs
    }

    private static func substitution(_ removed: [String], _ added: [String]) -> Pair? {
        guard (1 ... 3).contains(removed.count), (1 ... 3).contains(added.count) else { return nil }
        let spoken = removed.map(stripped).joined(separator: " ")
        let written = added.map(stripped).joined(separator: " ")
        guard !spoken.isEmpty, !written.isEmpty,
              written.contains(where: \.isLetter),
              !written.allSatisfy({ $0.isNumber || $0.isWhitespace })
        else { return nil }
        let a = normalized(spoken)
        let b = normalized(written)
        guard a != b, similarity(a, b) >= minimumSimilarity else { return nil }
        return Pair(spoken: spoken, written: written)
    }

    private static func deletion(_ removed: [String]) -> Pair? {
        let keys = removed.map(normalized).filter { !$0.isEmpty }
        guard !keys.isEmpty else { return nil }
        if keys.count >= 2, let cue = cue(in: keys) {
            return Pair(kind: .changeOfMind, spoken: cue, written: "")
        }
        guard (1 ... 3).contains(keys.count), keys.allSatisfy({ $0.count >= 2 }) else { return nil }
        return Pair(kind: .leaveOut, spoken: keys.joined(separator: " "), written: "")
    }

    /// The restatement cue in a deleted stretch, if it holds one.
    static func cue(in keys: [String]) -> String? {
        for cue in changeOfMindCues {
            let words = cue.split(separator: " ").map(String.init)
            guard words.count <= keys.count else { continue }
            for start in 0 ... keys.count - words.count where Array(keys[start ..< start + words.count]) == words {
                return cue
            }
        }
        return nil
    }

    private static func startsSentence(at index: Int, in words: [String]) -> Bool {
        guard index > 0 else { return true }
        return words[index - 1].last.map { ".!?".contains($0) } ?? false
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Trailing and leading sentence punctuation removed, inner kept (`Node.js`).
    static func stripped(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]{}“”‘’"))
    }

    static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(Array(a), Array(b))) / Double(longest)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0 ... b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Index pairs of a longest common subsequence, in order.
    private static func lcs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}

/// Word fixes seen so far, kept on this Mac. A fix seen twice becomes a
/// suggestion to add to the dictionary.
@MainActor
final class VoiceDictationCorrectionStore: ObservableObject {
    static let suggestionThreshold = 2

    @Published private(set) var corrections: [VoiceDictationCorrection] = []

    let fileURL: URL

    static var defaultFileURL: URL {
        NanoStorage.root
            .appendingPathComponent("VoiceDictation", isDirectory: true)
            .appendingPathComponent("corrections.json")
    }

    init(fileURL: URL = VoiceDictationCorrectionStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            corrections = (try? JSONDecoder().decode([VoiceDictationCorrection].self, from: data)) ?? []
        }
    }

    /// Suggestions not already covered by what Quill knows.
    func suggestions(
        excluding vocabulary: [VoiceDictationVocabularyEntry],
        leaveOut: [String] = [],
        cues: [String] = []
    ) -> [VoiceDictationCorrection] {
        corrections
            .filter { $0.count >= Self.suggestionThreshold && !$0.dismissed }
            .filter { correction in
                switch correction.kind {
                case .word:
                    let known = Set(VoiceDictationVocabularyEntry.forApp(vocabulary, bundleID: correction.bundleID)
                        .map { VoiceDictationTextPipeline.normalize(Substring($0.phrase)) })
                    return !known.contains(VoiceDictationTextPipeline.normalize(Substring(correction.spoken)))
                case .leaveOut:
                    return !leaveOut.map { $0.lowercased() }.contains(correction.spoken.lowercased())
                case .changeOfMind:
                    return !cues.map { $0.lowercased() }.contains(correction.spoken.lowercased())
                }
            }
            .sorted { $0.count == $1.count ? $0.lastSeen > $1.lastSeen : $0.count > $1.count }
    }

    func record(
        _ pairs: [VoiceDictationCorrectionDiff.Pair],
        app: (bundleID: String, name: String)? = nil,
        at date: Date = Date()
    ) {
        guard !pairs.isEmpty else { return }
        for pair in pairs {
            let key = VoiceDictationCorrection.key(
                kind: pair.kind, spoken: pair.spoken, written: pair.written, bundleID: app?.bundleID
            )
            if let index = corrections.firstIndex(where: { $0.id == key }) {
                corrections[index].count += 1
                corrections[index].lastSeen = date
            } else {
                corrections.append(VoiceDictationCorrection(
                    kind: pair.kind, spoken: pair.spoken, written: pair.written, count: 1, lastSeen: date,
                    bundleID: app?.bundleID, appName: app?.name
                ))
            }
        }
        save()
    }

    func dismiss(_ correction: VoiceDictationCorrection) {
        guard let index = corrections.firstIndex(where: { $0.id == correction.id }) else { return }
        corrections[index].dismissed = true
        save()
    }

    func remove(_ correction: VoiceDictationCorrection) {
        corrections.removeAll { $0.id == correction.id }
        save()
    }

    func clear() {
        corrections = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(corrections).write(to: fileURL, options: [.atomic])
        } catch {
            // Learning is a convenience; a failed write only loses a count.
        }
    }
}

/// After a paste, reads the same field back a little later to see what the
/// user changed. Anchors on the text around the dictation so edits elsewhere
/// in the document are ignored. Nothing is read from secure fields (they are
/// never paste targets) and nothing but the word pairs is kept.
@MainActor
final class VoiceDictationCorrectionWatcher {
    /// The last read wins; a field cleared by sending a message keeps what
    /// was seen before it was cleared.
    static let checkDelays: [Duration] = [.seconds(12), .seconds(45)]
    static let anchorLength = 40

    var onCorrections: (([VoiceDictationCorrectionDiff.Pair]) -> Void)?

    private struct Watch {
        let element: AXUIElement
        let inserted: String
        var prefix: String = ""
        var suffix: String = ""
        var anchored = false
        var latestEdit: String?
    }

    private var watch: Watch?
    private var task: Task<Void, Never>?

    func begin(element: AXUIElement, inserted: String) {
        finish()
        watch = Watch(element: element, inserted: inserted)
        task = Task { [weak self] in
            // Command-V lands asynchronously; give the app a moment.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.anchor()
            var elapsed: Duration = .milliseconds(600)
            for delay in Self.checkDelays {
                try? await Task.sleep(for: delay - elapsed)
                guard !Task.isCancelled else { return }
                elapsed = delay
                self?.observe()
            }
            self?.finish()
        }
    }

    /// Reports what was seen and stops. Called when a new dictation starts,
    /// since the next paste may land in the same field.
    func finish() {
        task?.cancel()
        task = nil
        guard let current = watch else { return }
        watch = nil
        guard current.anchored, let edited = current.latestEdit else { return }
        let pairs = VoiceDictationCorrectionDiff.corrections(original: current.inserted, edited: edited)
        if !pairs.isEmpty { onCorrections?(pairs) }
    }

    private func anchor() {
        guard var current = watch, let value = Self.value(of: current.element),
              let range = value.range(of: current.inserted, options: .backwards)
        else { return }
        current.prefix = String(value[..<range.lowerBound].suffix(Self.anchorLength))
        current.suffix = String(value[range.upperBound...].prefix(Self.anchorLength))
        current.anchored = true
        watch = current
    }

    private func observe() {
        guard var current = watch, current.anchored,
              let value = Self.value(of: current.element),
              let edited = Self.region(in: value, prefix: current.prefix, suffix: current.suffix),
              edited.count <= current.inserted.count * 3 + 20
        else { return }
        current.latestEdit = edited
        watch = current
    }

    /// The text between the anchors, or nil when either anchor is gone.
    nonisolated static func region(in value: String, prefix: String, suffix: String) -> String? {
        let start: String.Index
        if prefix.isEmpty {
            start = value.startIndex
        } else if let range = value.range(of: prefix) {
            start = range.upperBound
        } else {
            return nil
        }
        let end: String.Index
        if suffix.isEmpty {
            end = value.endIndex
        } else if let range = value.range(of: suffix, range: start ..< value.endIndex) {
            end = range.lowerBound
        } else {
            return nil
        }
        return String(value[start ..< end])
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
