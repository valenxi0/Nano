import FluidAudio
import Foundation
import NaturalLanguage

/// What kind of field a dictation lands in. Decided once, when recording
/// starts, from the frontmost app and the focused element.
enum VoiceDictationAppContext: String, Codable, Sendable {
    /// Prose, cleaned as the user's cleanup level says.
    case general
    /// A shell prompt. Spoken commands come out as commands.
    case terminal
    /// A chat composer. No full stop on a one-line message.
    case chat
    /// A mail composer. A greeting and a sign-off get their own lines.
    case email
    /// A coding agent's prompt in a terminal: Claude Code, Codex and the
    /// like. What is said there is prose, so it is cleaned in the user's
    /// style; it still pastes in pieces like any terminal.
    case agent

    /// Typed into a terminal window, shell or agent.
    var isTerminal: Bool { self == .terminal || self == .agent }

    var title: String {
        switch self {
        case .general: "Prose"
        case .terminal: "Developer Mode"
        case .chat: "Chat"
        case .email: "Email"
        case .agent: "Agent prompt"
        }
    }

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby", "com.termius-dmg.mac",
    ]

    static let chatBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.hnc.Discord", "ru.keepcoder.Telegram",
        "com.tdesktop.Telegram", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "org.whispersystems.signal-desktop", "com.microsoft.teams2", "com.facebook.archon",
    ]

    static let emailBundleIDs: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
        "com.mimestream.Mimestream", "com.freron.MailMate", "it.bloop.airmail2", "org.mozilla.thunderbird",
        "com.canarymail.mac", "ch.protonmail.desktop",
    ]

    /// `focusedDescription` is the focused element's accessibility label.
    /// Editors host terminals as text areas (VS Code and Cursor label
    /// xterm's textarea "Terminal 1, zsh"), which is how a terminal pane
    /// inside an editor is told apart from its code or chat panes.
    ///
    /// A terminal is an agent prompt when its window title names an agent
    /// (Claude Code puts "✳" and its task there) or names one of
    /// `agentNames`, the projects and titles of agent sessions Nano is
    /// tracking in that terminal app.
    static func classify(
        bundleID: String?,
        focusedDescription: String?,
        windowTitle: String? = nil,
        agentNames: [String] = []
    ) -> VoiceDictationAppContext {
        let isTerminal = bundleID.map(terminalBundleIDs.contains) == true
            || focusedDescription?.range(of: #"\bterminal\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        if isTerminal {
            return isAgentWindow(title: windowTitle, agentNames: agentNames) ? .agent : .terminal
        }
        if let bundleID, chatBundleIDs.contains(bundleID) { return .chat }
        if let bundleID, emailBundleIDs.contains(bundleID) { return .email }
        return .general
    }

    static let agentTitlePattern = #"(^|[^\p{L}])(claude|codex|gemini|opencode|aider|cursor-agent|kimi|grok|qwen|amp|droid|goose|crush)([^\p{L}]|$)"#
    /// Characters Claude Code and Codex lead their terminal titles with.
    static let agentTitleMarks: Set<Character> = ["✳", "⠂", "⠐", "✻", "✶", "✢", "✽", "·"]

    static func isAgentWindow(title: String?, agentNames: [String]) -> Bool {
        guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return false }
        if let first = title.first, agentTitleMarks.contains(first), title.count > 2 { return true }
        if title.range(of: agentTitlePattern, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return agentNames.contains { name in
            name.count >= 3 && title.localizedCaseInsensitiveContains(name)
        }
    }
}

/// Turns spoken shell input into the command the user meant:
/// "git commit dash m quote fix the build quote" → `git commit -m "fix the build"`.
///
/// Symbol words glue to their neighbours ("tilde slash projects" → `~/projects`);
/// saying "space" forces a gap where a symbol would otherwise glue. Single
/// letters after a dash are lowercased unless "capital" precedes them, since
/// recognizers capitalize lone letters.
enum VoiceDictationCommandFormatter {
    private struct Symbol {
        let text: String
        let gluesLeft: Bool
        let gluesRight: Bool
    }

    /// Longest phrases first so "dash dash" wins over "dash".
    private static let symbols: [([String], Symbol)] = [
        (["dash", "dash"], Symbol(text: "--", gluesLeft: false, gluesRight: true)),
        (["double", "dash"], Symbol(text: "--", gluesLeft: false, gluesRight: true)),
        (["greater", "than"], Symbol(text: ">", gluesLeft: false, gluesRight: false)),
        (["less", "than"], Symbol(text: "<", gluesLeft: false, gluesRight: false)),
        (["at", "sign"], Symbol(text: "@", gluesLeft: true, gluesRight: true)),
        (["dollar", "sign"], Symbol(text: "$", gluesLeft: false, gluesRight: true)),
        (["question", "mark"], Symbol(text: "?", gluesLeft: true, gluesRight: false)),
        (["exclamation", "mark"], Symbol(text: "!", gluesLeft: true, gluesRight: false)),
        (["open", "paren"], Symbol(text: "(", gluesLeft: false, gluesRight: true)),
        (["close", "paren"], Symbol(text: ")", gluesLeft: true, gluesRight: false)),
        (["open", "bracket"], Symbol(text: "[", gluesLeft: false, gluesRight: true)),
        (["close", "bracket"], Symbol(text: "]", gluesLeft: true, gluesRight: false)),
        (["open", "brace"], Symbol(text: "{", gluesLeft: false, gluesRight: true)),
        (["close", "brace"], Symbol(text: "}", gluesLeft: true, gluesRight: false)),
        (["back", "slash"], Symbol(text: "\\", gluesLeft: true, gluesRight: true)),
        (["dash"], Symbol(text: "-", gluesLeft: false, gluesRight: true)),
        (["hyphen"], Symbol(text: "-", gluesLeft: false, gluesRight: true)),
        (["slash"], Symbol(text: "/", gluesLeft: true, gluesRight: true)),
        (["backslash"], Symbol(text: "\\", gluesLeft: true, gluesRight: true)),
        (["dot"], Symbol(text: ".", gluesLeft: true, gluesRight: true)),
        (["underscore"], Symbol(text: "_", gluesLeft: true, gluesRight: true)),
        (["colon"], Symbol(text: ":", gluesLeft: true, gluesRight: true)),
        (["semicolon"], Symbol(text: ";", gluesLeft: true, gluesRight: false)),
        (["equals"], Symbol(text: "=", gluesLeft: true, gluesRight: true)),
        (["tilde"], Symbol(text: "~", gluesLeft: false, gluesRight: true)),
        (["pipe"], Symbol(text: "|", gluesLeft: false, gluesRight: false)),
        (["ampersand"], Symbol(text: "&", gluesLeft: false, gluesRight: false)),
        (["star"], Symbol(text: "*", gluesLeft: false, gluesRight: true)),
        (["asterisk"], Symbol(text: "*", gluesLeft: false, gluesRight: true)),
        (["comma"], Symbol(text: ",", gluesLeft: true, gluesRight: false)),
    ]

    private enum Piece {
        case word(String)
        case symbol(Symbol)
        case quote(Character, opening: Bool)
        case space
    }

    static func format(_ spoken: String) -> String {
        let words = tokenize(spoken)
        let pieces = parse(words)
        return render(pieces)
    }

    /// Words with the recognizer's own sentence punctuation removed. Symbols
    /// the recognizer already wrote (`-m`, `file.txt`) stay inside their word.
    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            var word = Substring(raw)
            while let last = word.last, ",.?!;".contains(last) { word = word.dropLast() }
            while let first = word.first, ",".contains(first) { word = word.dropFirst() }
            return word.isEmpty ? nil : String(word)
        }
    }

    private static func parse(_ words: [String]) -> [Piece] {
        var pieces: [Piece] = []
        var index = 0
        var capitalizeNext = false
        var openQuotes: [Character] = []
        let lowered = words.map { $0.lowercased() }

        func matches(_ phrase: [String]) -> Bool {
            guard index + phrase.count <= lowered.count else { return false }
            return Array(lowered[index ..< index + phrase.count]) == phrase
        }

        while index < words.count {
            let word = lowered[index]
            if word == "space" {
                pieces.append(.space)
                index += 1
                continue
            }
            if word == "capital" || word == "uppercase" {
                capitalizeNext = true
                index += 1
                continue
            }
            if let (character, length, opens) = quoteMark(at: index, in: lowered) {
                let isOpen = openQuotes.last == character
                let closing = opens == false || (opens == nil && isOpen)
                if closing {
                    if isOpen { openQuotes.removeLast() }
                } else {
                    openQuotes.append(character)
                }
                pieces.append(.quote(character, opening: !closing))
                index += length
                continue
            }
            if let (phrase, symbol) = symbols.first(where: { matches($0.0) }) {
                pieces.append(.symbol(symbol))
                index += phrase.count
                continue
            }
            var text = words[index]
            if capitalizeNext {
                text = text.prefix(1).uppercased() + text.dropFirst()
                capitalizeNext = false
            } else if text.count == 1, case .symbol(let previous)? = pieces.last, previous.text.hasSuffix("-") {
                text = text.lowercased()
            }
            pieces.append(.word(text))
            index += 1
        }
        return pieces
    }

    /// (character, words consumed, opens?) where `opens` is nil for a bare
    /// "quote", which toggles.
    private static func quoteMark(at index: Int, in words: [String]) -> (Character, Int, Bool?)? {
        let next = index + 1 < words.count ? words[index + 1] : nil
        switch words[index] {
        case "open" where next == "quote": return ("\"", 2, true)
        case "close" where next == "quote", "end" where next == "quote": return ("\"", 2, false)
        case "unquote": return ("\"", 1, false)
        case "single" where next == "quote": return ("'", 2, nil)
        case "quote": return ("\"", 1, nil)
        default: return nil
        }
    }

    private static func render(_ pieces: [Piece]) -> String {
        var output = ""
        var glueNext = false
        var forceGap = false

        func append(_ text: String, gluesLeft: Bool) {
            let glue = (gluesLeft || glueNext) && !forceGap
            if !output.isEmpty, !glue { output += " " }
            output += text
            forceGap = false
        }

        for piece in pieces {
            switch piece {
            case .space:
                forceGap = true
                glueNext = false
            case .word(let word):
                append(word, gluesLeft: false)
                glueNext = false
            case .symbol(let symbol):
                // A dash inside a flag ("no dash verify") joins both sides.
                let insideFlag = symbol.text == "-" && output.split(separator: " ").last?.hasPrefix("-") == true
                append(symbol.text, gluesLeft: symbol.gluesLeft || insideFlag)
                glueNext = symbol.gluesRight
            case .quote(let character, let opening):
                append(String(character), gluesLeft: !opening)
                glueNext = opening
            }
        }
        return lowercasingCommandName(output)
    }

    /// Recognizers capitalize the first word of a sentence ("Git commit").
    /// Only an initial capital followed by lowercase is undone, so `README`
    /// and `Makefile`-style names keep their case when that is all they have.
    private static func lowercasingCommandName(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        let firstWord = text.prefix { !$0.isWhitespace }
        guard firstWord.count > 1, firstWord.dropFirst().allSatisfy({ !$0.isUppercase }) else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

/// Chat apps: a one-sentence message goes out without the full stop, the way
/// people type in a composer. A `.`, `!` or `?` only ends a sentence when
/// whitespace follows, so "Version 1.5 is out." is one sentence.
enum VoiceDictationChatStyle {
    static func apply(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix(".."), !trimmed.contains(where: \.isNewline) else { return trimmed }
        let body = trimmed.dropLast()
        guard !VoiceDictationText.hasSentenceBreak(body, ends: [".", "!", "?"]) else { return trimmed }
        return String(body)
    }
}

/// Character helpers shared by the finishing rules, matching Rust's `char`
/// predicates closely enough for dictated text.
enum VoiceDictationText {
    static func isAlphanumeric(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    static func isLineBreak(_ c: Character) -> Bool { c == "\n" || c == "\r" || c == "\r\n" }

    /// Whether any of `ends` is followed by whitespace inside `text`.
    static func hasSentenceBreak(_ text: Substring, ends: Set<Character>) -> Bool {
        var previous: Character?
        for c in text {
            if let previous, ends.contains(previous), c.isWhitespace { return true }
            previous = c
        }
        return false
    }

    static func trimmingEnd(_ text: Substring, while drop: (Character) -> Bool) -> Substring {
        var t = text
        while let last = t.last, drop(last) { t = t.dropLast() }
        return t
    }

    static func trimmingStart(_ text: Substring, while drop: (Character) -> Bool) -> Substring {
        var t = text
        while let first = t.first, drop(first) { t = t.dropFirst() }
        return t
    }
}

/// Small spoken commands applied to finished text: emoji names, a closing
/// "press enter", and splitting long pastes for terminal apps.
enum VoiceDictationSpokenCommands {
    /// Spoken names, longest first within a family.
    static let emoji: [(name: String, emoji: String)] = [
        ("crying laughing", "😂"), ("laughing crying", "😂"), ("tears of joy", "😂"), ("laughing", "😂"), ("joy", "😂"),
        ("loudly crying", "😭"), ("sob", "😭"), ("crying", "😢"), ("sad", "😢"),
        ("red heart", "❤️"), ("heart", "❤️"), ("heart eyes", "😍"), ("broken heart", "💔"),
        ("thumbs up", "👍"), ("thumbs down", "👎"), ("ok hand", "👌"), ("okay hand", "👌"),
        ("clapping", "👏"), ("clap", "👏"), ("praying hands", "🙏"), ("folded hands", "🙏"), ("pray", "🙏"),
        ("raised hands", "🙌"), ("waving hand", "👋"), ("wave", "👋"), ("muscle", "💪"), ("flexed biceps", "💪"),
        ("smiling face", "😊"), ("smiley", "😊"), ("smile", "😊"), ("grinning", "😀"), ("wink", "😉"), ("winking face", "😉"),
        ("thinking face", "🤔"), ("thinking", "🤔"), ("eyes", "👀"), ("sunglasses", "😎"), ("cool", "😎"),
        ("upside down face", "🙃"), ("upside down", "🙃"), ("grimacing", "😬"), ("grimace", "😬"), ("melting face", "🫠"),
        ("saluting face", "🫡"), ("salute", "🫡"), ("pleading face", "🥺"), ("pleading", "🥺"), ("smirk", "😏"),
        ("shrug", "🤷"), ("facepalm", "🤦"), ("face palm", "🤦"), ("angry", "😠"), ("rage", "😡"), ("nerd face", "🤓"), ("nerd", "🤓"),
        ("skull", "💀"), ("ghost", "👻"), ("robot", "🤖"), ("poop", "💩"), ("brain", "🧠"), ("bug", "🐛"),
        ("fire", "🔥"), ("rocket", "🚀"), ("party popper", "🎉"), ("party", "🎉"), ("tada", "🎉"), ("sparkles", "✨"), ("star", "⭐"),
        ("hundred", "💯"), ("one hundred", "💯"), ("100", "💯"), ("check mark", "✅"), ("checkmark", "✅"), ("check", "✅"),
        ("cross mark", "❌"), ("warning", "⚠️"), ("light bulb", "💡"), ("lightbulb", "💡"), ("trophy", "🏆"),
        ("coffee", "☕"), ("pizza", "🍕"), ("beer", "🍺"), ("cake", "🎂"), ("gift", "🎁"), ("money", "💰"),
        ("chart", "📈"), ("calendar", "📅"), ("memo", "📝"), ("pin", "📌"), ("pushpin", "📌"), ("link", "🔗"),
        ("lock", "🔒"), ("key", "🔑"), ("bell", "🔔"), ("sun", "☀️"), ("rainbow", "🌈"), ("dog", "🐶"), ("cat", "🐱"),
    ]

    /// Words before a name that make it a mention, not a request ("the fire emoji").
    static let determiners: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "their", "our", "its",
    ]

    /// Terminal apps collapse a long paste into a placeholder. Pastes above
    /// these limits are sent in pieces.
    static let chunkCharacters = 500
    static let chunkNewlines = 2

    /// "Great job fire emoji" → "Great job 🔥". Only an emoji name directly
    /// followed by the word "emoji" changes. Line by line.
    static func emojiNames(_ text: String) -> String {
        guard text.lowercased().contains("emoji") else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { emojiLine(Substring($0)) }
            .joined(separator: "\n")
    }

    private static func bare(_ word: Substring) -> String {
        let notAlnum = { !VoiceDictationText.isAlphanumeric($0) }
        return String(VoiceDictationText.trimmingEnd(VoiceDictationText.trimmingStart(word, while: notAlnum), while: notAlnum)).lowercased()
    }

    private static func emojiLine(_ line: Substring) -> String {
        var out: [Substring] = []
        for word in line.split(separator: " ", omittingEmptySubsequences: false) {
            let startsWithLetter = VoiceDictationText.trimmingStart(word, while: \.isWhitespace).first?.isLetter == true
            guard bare(word) == "emoji", startsWithLetter else {
                out.append(word)
                continue
            }
            // The longest name ending right before "emoji", without punctuation inside it.
            var matched: (length: Int, emoji: String)?
            for length in stride(from: 3, through: 1, by: -1) where out.count >= length {
                let nameWords = out[(out.count - length)...]
                let clean = nameWords.enumerated().allSatisfy { k, w in
                    let core = VoiceDictationText.trimmingStart(w, while: { !VoiceDictationText.isAlphanumeric($0) })
                    return core.allSatisfy(VoiceDictationText.isAlphanumeric) && (k == 0 || core.count == w.count)
                }
                guard clean else { continue }
                let name = nameWords.map(bare).joined(separator: " ")
                if let entry = emoji.first(where: { $0.name == name }) {
                    matched = (length, entry.emoji)
                    break
                }
            }
            guard let (length, symbol) = matched else {
                out.append(word)
                continue
            }
            let determinerIndex = out.count - length - 1
            if determinerIndex >= 0, determiners.contains(bare(out[determinerIndex])) {
                out.append(word)
                continue
            }
            let lead = out[out.count - length].prefix { !VoiceDictationText.isAlphanumeric($0) }
            out.removeLast(length)
            let trail = word.drop(while: VoiceDictationText.isAlphanumeric)
            out.append(Substring(String(lead) + symbol + String(trail)))
        }
        return out.joined(separator: " ")
    }

    /// A dictation ending in "press enter": the text without it, and whether
    /// it ended that way. The remainder may be empty.
    static func stripPressEnter(_ text: String) -> (text: String, pressEnter: Bool) {
        let t = VoiceDictationText.trimmingEnd(
            VoiceDictationText.trimmingEnd(Substring(text), while: \.isWhitespace),
            while: { ".!,".contains($0) }
        )
        let command = "press enter"
        guard t.count >= command.count, t.suffix(command.count).lowercased() == command else { return (text, false) }
        let head = t.dropLast(command.count)
        if let last = head.last, VoiceDictationText.isAlphanumeric(last) { return (text, false) }
        let rest = VoiceDictationText.trimmingEnd(
            VoiceDictationText.trimmingEnd(VoiceDictationText.trimmingEnd(head, while: \.isWhitespace), while: { ",;:".contains($0) }),
            while: \.isWhitespace
        )
        return (String(rest), true)
    }

    /// Pieces that concatenate back to `text` exactly, each at most
    /// `chunkCharacters` characters and `chunkNewlines` line breaks, split
    /// after whitespace. Text within 600 characters and two line breaks
    /// stays whole.
    static func pasteChunks(_ text: String) -> [String] {
        let chars = Array(text)
        let newlines = chars.filter(VoiceDictationText.isLineBreak).count
        if chars.count <= chunkCharacters + 100, newlines <= chunkNewlines { return [text] }
        var chunks: [String] = []
        var start = 0
        while start < chars.count {
            var end = start
            var breaks = 0
            var lastSpace: Int?
            while end < chars.count, end - start < chunkCharacters {
                if VoiceDictationText.isLineBreak(chars[end]) {
                    if breaks == chunkNewlines { break }
                    breaks += 1
                }
                if chars[end].isWhitespace { lastSpace = end }
                end += 1
            }
            // Cut after the last space, unless the rest fits or there is none.
            if end < chars.count, !VoiceDictationText.isLineBreak(chars[end]), let lastSpace, lastSpace > start {
                end = lastSpace + 1
            }
            chunks.append(String(chars[start ..< end]))
            start = end
        }
        return chunks
    }
}

/// Text read from the focused field at recording start.
struct VoiceDictationSurroundings: Equatable, Sendable {
    /// Up to a few hundred characters before the caret or selection.
    var before: String
    /// A few characters after it.
    var after: String
    /// The selected text the dictation replaces, if any.
    var selection: String

    init(before: String = "", after: String = "", selection: String = "") {
        self.before = before
        self.after = after
        self.selection = selection
    }

    /// An empty field can report its placeholder ("Message #general") as its
    /// text. Text equal to one of the field's `labels` (name, help text)
    /// counts as an empty field.
    func ignoringPlaceholder(labels: [String]) -> VoiceDictationSurroundings {
        let whole = (before + selection + after).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty,
              labels.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == whole })
        else { return self }
        return VoiceDictationSurroundings()
    }
}

/// Fitting a dictation into the text around the caret: casing, spaces, and
/// the closing full stop. Runs last, on the final text.
enum VoiceDictationCursorFit {
    private static let openers: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "@", "#", "$", "-", "_", "`"]
    private static let closers: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'", "”", "’", "%"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
    /// Words that keep their capital wherever they land.
    private static let alwaysCapital: Set<String> = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "January", "February",
        "March", "April", "June", "July", "August", "September", "October", "November", "December", "English",
    ]

    /// Fit `text` between the caret's neighbours. `protected` holds vocabulary
    /// and snippet output that must keep its casing.
    static func fit(_ text: String, surroundings: VoiceDictationSurroundings, protected: [String]) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return text }
        let before = surroundings.before
        let after = surroundings.after
        let selection = surroundings.selection

        // Casing. A replaced selection that started lowercase continues a sentence.
        let selectionLower = VoiceDictationText.trimmingStart(Substring(selection), while: \.isWhitespace).first?.isLowercase == true
        if continuesSentence(before) || selectionLower, lowercasable(out, protected: protected) {
            out = out.prefix(1).lowercased() + out.dropFirst()
        }

        // The closing full stop.
        let next = after.first
        let continuesAfter = VoiceDictationText.trimmingStart(Substring(after), while: { $0 == " " || $0 == "\t" }).first
            .map { $0.isLowercase || ($0.isASCII && $0.isNumber) } == true
        let trimmedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectionUnpunctuated = !trimmedSelection.isEmpty
            && !(VoiceDictationText.trimmingEnd(Substring(selection), while: \.isWhitespace).last.map(sentenceEnds.contains) ?? false)
        if continuesAfter || selectionUnpunctuated, singleSentenceWithStop(out) {
            out.removeLast()
        }

        // Spaces at both edges.
        if let p = before.last, let f = out.first, !p.isWhitespace, !openers.contains(p), !closers.contains(f) {
            out.insert(" ", at: out.startIndex)
        }
        if let n = next, let l = out.last, !n.isWhitespace, !closers.contains(n), !openers.contains(l), !l.isWhitespace {
            out.append(" ")
        }
        return out
    }

    /// Whether `before` leaves the caret inside a sentence.
    static func continuesSentence(_ before: String) -> Bool {
        let trimmed = VoiceDictationText.trimmingEnd(Substring(before), while: { $0 == " " || $0 == "\t" })
        // An opening quote starts quoted speech, which takes a capital.
        guard let last = trimmed.last, !VoiceDictationText.isLineBreak(last), !"\"“‘".contains(last) else { return false }
        // Only an opening bracket or quote before the caret: nil.
        guard let c = VoiceDictationText.trimmingEnd(trimmed, while: { $0 == "(" || $0 == "[" }).last else { return false }
        return !sentenceEnds.contains(c) && c != ":"
    }

    /// Whether lowercasing the first word's initial is safe: an ordinary
    /// capitalized word, not "I", an acronym, a weekday, or a word the
    /// dictation capitalizes again mid-sentence (likely a name).
    static func lowercasable(_ text: String, protected: [String]) -> Bool {
        let word = String(text.prefix { VoiceDictationText.isAlphanumeric($0) || $0 == "'" || $0 == "’" })
        let letters = word.filter(\.isLetter)
        guard let first = letters.first, first.isUppercase, !letters.dropFirst().contains(where: \.isUppercase) else { return false }
        let bare = String(VoiceDictationText.trimmingEnd(Substring(word), while: { "'’s".contains($0) }))
        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") || alwaysCapital.contains(bare) { return false }
        if protected.contains(where: { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) == word }) { return false }
        // The same word capitalized after the first word: a name.
        let words = text.split(whereSeparator: \.isWhitespace)
        return !zip(words.dropFirst(), words).contains { w, previous in
            let notAlnum = { !VoiceDictationText.isAlphanumeric($0) }
            let core = VoiceDictationText.trimmingEnd(VoiceDictationText.trimmingStart(w, while: notAlnum), while: notAlnum)
            return core == word && !(previous.last.map(sentenceEnds.contains) ?? false)
        }
    }

    /// One sentence ending in a single full stop.
    private static func singleSentenceWithStop(_ text: String) -> Bool {
        let t = VoiceDictationText.trimmingEnd(Substring(text), while: \.isWhitespace)
        guard t.hasSuffix("."), !t.hasSuffix(".."), !t.contains(where: VoiceDictationText.isLineBreak) else { return false }
        return !VoiceDictationText.hasSentenceBreak(t.dropLast(), ends: sentenceEnds)
    }
}

/// Spoken numbers, dates and money to figures, span by span. English only.
///
/// Only runs of number words are touched, and each run is converted on its
/// own by FluidAudio's inverse text normalization (NeMo grammars), so the
/// rest of the sentence can never be rewritten. Style follows common prose
/// guides: one to nine stay words unless they carry a unit, a time or a date
/// ("two kids", "5 PM", "March 3"); larger amounts become figures ("25
/// people", "$25.50", "2026"). Ten spoken digits become a phone number. With
/// `allDigits` (terminals) every number becomes figures.
enum VoiceDictationNumberFormatter {
    static var isAvailable: Bool { TextNormalizer.shared.isNativeAvailable }

    private static let digits: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teensAndTens: Set<String> = [
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    ]
    private static let tens: Set<String> = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let scales: Set<String> = ["hundred", "thousand", "million", "billion"]
    private static let ordinals: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth", "twentieth", "thirtieth",
    ]
    private static let units: Set<String> = ["dollars", "dollar", "cents", "cent", "percent", "euros", "euro", "pounds", "pound"]
    private static let meridiems: [String: String] = ["am": "AM", "a.m": "AM", "pm": "PM", "p.m": "PM"]
    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]

    private struct Token {
        var text: String
        var key: String
        var trailing: String
    }

    static func format(_ text: String, allDigits: Bool = false) -> String {
        guard isAvailable, !text.isEmpty else { return text }
        // Line by line, so a dictated list or paragraph break survives.
        return text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { formatLine(String($0), allDigits: allDigits) }
            .joined(separator: "\n")
    }

    private static func formatLine(_ text: String, allDigits: Bool) -> String {
        guard !text.isEmpty else { return text }
        let spaced = text.replacingOccurrences(
            of: #"\b(twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)-(one|two|three|four|five|six|seven|eight|nine|first|third|fourth|fifth|sixth|seventh|eighth|ninth)\b"#,
            with: "$1 $2",
            options: [.regularExpression, .caseInsensitive]
        )
        let tokens = spaced.split(whereSeparator: \.isWhitespace).map { raw -> Token in
            var core = Substring(raw)
            var trailing = ""
            while let last = core.last, ",;:!?".contains(last) || (last == "." && !core.lowercased().hasSuffix("a.m.") && !core.lowercased().hasSuffix("p.m.")) {
                trailing.insert(last, at: trailing.startIndex)
                core = core.dropLast()
            }
            let key = core.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".\"'"))
            return Token(text: String(core), key: key, trailing: trailing)
        }

        var output: [String] = []
        var index = 0
        while index < tokens.count {
            guard let (length, written) = span(at: index, in: tokens, allDigits: allDigits) else {
                output.append(tokens[index].text + tokens[index].trailing)
                index += 1
                continue
            }
            output.append(written + tokens[index + length - 1].trailing)
            index += length
        }
        return output.joined(separator: " ")
    }

    private static func isNumberWord(_ key: String) -> Bool {
        digits[key] != nil || teensAndTens.contains(key) || scales.contains(key)
    }

    /// The number span starting at `index`, as (tokens consumed, written form).
    private static func span(at index: Int, in tokens: [Token], allDigits: Bool) -> (Int, String)? {
        let first = tokens[index].key
        // "March third", "March twenty first twenty twenty six".
        if months.contains(first), index + 1 < tokens.count {
            let next = tokens[index + 1].key
            // "May" and "march" are also verbs ("they may one day"), so
            // they only start a date with an ordinal ("May first").
            let verbLike = first == "may" || first == "march"
            guard isNumberWord(next) || ordinals.contains(next) else { return nil }
            var end = index + 1
            while end < tokens.count, isNumberWord(tokens[end].key) || ordinals.contains(tokens[end].key),
                  end == index + 1 || tokens[end - 1].trailing.isEmpty {
                end += 1
            }
            let words = tokens[index + 1 ..< end].map(\.key)
            guard !verbLike || words.contains(where: ordinals.contains) else { return nil }
            // Day, then an optional year: "twenty first" / "twenty twenty six".
            let dayEnd = words.firstIndex(where: ordinals.contains).map { $0 + 1 }
                ?? (words.count >= 2 && tens.contains(words[0]) && digits[words[1]] != nil ? 2 : 1)
            let day = TextNormalizer.shared.normalize(words[..<dayEnd].joined(separator: " "))
                .filter(\.isNumber)
            guard let dayValue = Int(day), (1 ... 31).contains(dayValue) else { return nil }
            let month = tokens[index].text.prefix(1).uppercased() + tokens[index].text.dropFirst().lowercased()
            var written = "\(month) \(dayValue)"
            if dayEnd < words.count {
                let year = TextNormalizer.shared.normalize(words[dayEnd...].joined(separator: " "))
                if year.count == 4, year.allSatisfy(\.isNumber) {
                    written += ", " + year
                } else {
                    return (dayEnd + 1, written)
                }
            }
            return (end - index, written)
        }

        guard isNumberWord(first) || (tens.contains(first)) else { return nil }
        var end = index
        while end < tokens.count {
            let key = tokens[end].key
            let previous = end > index ? tokens[end - 1] : nil
            if previous.map({ !$0.trailing.isEmpty }) == true { break }
            if isNumberWord(key) {
                end += 1
            } else if key == "and", let previous, scales.contains(previous.key),
                      end + 1 < tokens.count, isNumberWord(tokens[end + 1].key) {
                end += 1
            } else if key == "point", end + 1 < tokens.count, digits[tokens[end + 1].key] != nil {
                end += 1
            } else if ordinals.contains(key), key != "second", let previous, tens.contains(previous.key) {
                // "second" is also a unit: "a thirty second timeout" is 30
                // seconds, not the 32nd.
                end += 1
                break
            } else {
                break
            }
        }
        let words = tokens[index ..< end].map(\.key)

        // Phone numbers and codes: a run of single digits.
        if words.count >= 3, words.allSatisfy({ digits[$0] != nil }) {
            return (end - index, grouped(words.compactMap { digits[$0] }.map(String.init).joined()))
        }

        // Units and money: "twenty five dollars and fifty cents".
        var unitEnd = end
        if unitEnd < tokens.count, units.contains(tokens[unitEnd].key), tokens[unitEnd - 1].trailing.isEmpty {
            unitEnd += 1
            if unitEnd + 1 < tokens.count, tokens[unitEnd].key == "and", tokens[unitEnd - 1].trailing.isEmpty {
                var centsEnd = unitEnd + 1
                while centsEnd < tokens.count, isNumberWord(tokens[centsEnd].key) { centsEnd += 1 }
                if centsEnd < tokens.count, ["cents", "cent"].contains(tokens[centsEnd].key), centsEnd > unitEnd + 1 {
                    unitEnd = centsEnd + 1
                }
            }
        }
        if unitEnd > end {
            let spoken = tokens[index ..< unitEnd].map(\.key).joined(separator: " ")
            let written = TextNormalizer.shared.normalize(spoken).replacingOccurrences(of: " %", with: "%")
            if written != spoken, written.contains(where: \.isNumber) { return (unitEnd - index, written) }
        }

        // Times: "four thirty pm" → "4:30 PM".
        if end < tokens.count, let meridiem = meridiems[tokens[end].key], tokens[end - 1].trailing.isEmpty,
           let hour = digits[words[0]] ?? hourValue(words[0]), (1 ... 12).contains(hour) {
            let minuteWords = words.dropFirst()
            var minutes = 0
            if !minuteWords.isEmpty {
                let normalized = TextNormalizer.shared.normalize(minuteWords.joined(separator: " "))
                guard let value = Int(normalized.filter(\.isNumber)), (0 ... 59).contains(value) else { return nil }
                minutes = value
            }
            let time = minutes == 0 ? "\(hour) \(meridiem)" : String(format: "%d:%02d %@", hour, minutes, meridiem)
            return (end + 1 - index, time)
        }

        // A lone one to nine stays a word in prose.
        if !allDigits, words.count == 1, digits[words[0]] != nil { return nil }
        if words.count == 1, let value = digits[words[0]] { return (1, String(value)) }
        guard words.contains(where: { $0 != "and" && $0 != "point" }) else { return nil }
        let spoken = words.joined(separator: " ")
        let written = TextNormalizer.shared.normalize(spoken)
        guard written != spoken, written.contains(where: \.isNumber),
              !written.contains(where: { $0.isLetter && !"stndrh".contains($0) })
        else { return nil }
        return (end - index, written)
    }

    private static func hourValue(_ word: String) -> Int? {
        ["ten": 10, "eleven": 11, "twelve": 12][word]
    }

    /// 10 digits → 415-555-0198, 11 starting with 1 → 1-415-555-0198. Any
    /// other run stays plain digits: seven of them are as likely a code or an
    /// ID as a phone number.
    private static func grouped(_ digits: String) -> String {
        let characters = Array(digits)
        switch characters.count {
        case 10: return String(characters[0 ..< 3]) + "-" + String(characters[3 ..< 6]) + "-" + String(characters[6...])
        case 11 where characters[0] == "1":
            return "1-" + String(characters[1 ..< 4]) + "-" + String(characters[4 ..< 7]) + "-" + String(characters[7...])
        default: return digits
        }
    }
}

enum VoiceDictationLanguageGuess {
    /// Whether English-only stages (S1-mini, number formatting) may touch
    /// `text`. Trusts the engine when it reported a language. Otherwise a
    /// short or ambiguous transcript counts as English; only a confident
    /// non-English reading of a real sentence turns the stages off.
    static func isEnglish(_ text: String, reported: String?) -> Bool {
        if let reported { return reported == "en" }
        return language(of: text).map { $0 == "en" } ?? true
    }

    /// ISO 639-1 code NaturalLanguage is confident about, or nil.
    static func language(of text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.8
        else { return nil }
        return language.rawValue
    }
}
