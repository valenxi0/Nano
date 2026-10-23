import AppKit
import Foundation

/// The user-facing engine choices. An engine is a *bundle* of model assets
/// plus a processing recipe; the assets themselves are tracked separately so
/// Parakeet + S1-mini can show both of its downloads.
enum VoiceDictationEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case parakeetS1
    case cohereTranscribe
    case whisperTurbo
    case whisperBase
    case whisperTiny

    var id: String { rawValue }

    /// The engines offered in Settings and setup. Cohere Transcribe (slow,
    /// 2 GB, translates on Automatic) and Whisper Tiny (no felt gain over
    /// Base) stay in the code for tests and benchmarks only.
    static let offered: [VoiceDictationEngine] = [.parakeetS1, .whisperTurbo, .whisperBase]

    /// What a saved choice of a retired engine becomes.
    var offeredReplacement: VoiceDictationEngine {
        switch self {
        case .cohereTranscribe: .whisperTurbo
        case .whisperTiny: .whisperBase
        case .parakeetS1, .whisperTurbo, .whisperBase: self
        }
    }

    /// The choice, said as what it is for.
    var choiceTitle: String {
        switch self {
        case .parakeetS1: "English, best quality"
        case .whisperTurbo, .cohereTranscribe: "Many languages"
        case .whisperBase, .whisperTiny: "Small download"
        }
    }

    var title: String {
        switch self {
        case .parakeetS1: "Parakeet + S1-mini"
        case .cohereTranscribe: "Cohere Transcribe"
        case .whisperTurbo: "Whisper Turbo"
        case .whisperBase: "Whisper Base"
        case .whisperTiny: "Whisper Tiny"
        }
    }

    var summary: String {
        switch self {
        case .parakeetS1:
            "Best English results. Parakeet recognizes speech; S1-mini by Superwhisper removes fillers and false starts and writes numbers, dates, and emails properly."
        case .cohereTranscribe:
            "Experimental. Strong on German, French, Spanish, Italian, Portuguese, Dutch, Polish, Greek, Arabic, Japanese, Chinese, Korean and Vietnamese, but takes several seconds per dictation on this Mac. Pick your language below; Whisper Turbo is the faster multilingual choice."
        case .whisperTurbo:
            "Hears which language you speak and writes it, across 99 languages. The multilingual pick: about two seconds per dictation, and a good fit if you switch languages."
        case .whisperBase:
            "Good accuracy for clear English speech with less memory and processing than the best-quality option."
        case .whisperTiny:
            "Fastest and easiest on your Mac, but trades recognition accuracy for its small footprint."
        }
    }

    /// Short, deliberately plain-language guidance shown beside every option.
    var resourceLabel: String {
        switch self {
        case .parakeetS1: "Recommended"
        case .cohereTranscribe: "Experimental"
        case .whisperTurbo: "99 languages"
        case .whisperBase: "English"
        case .whisperTiny: "English"
        }
    }

    /// Model assets that must all be present before this engine can run.
    var requiredModels: [VoiceDictationModelID] {
        switch self {
        case .parakeetS1: [.parakeetTDT06BV3, .s1Mini]
        case .cohereTranscribe: [.cohereTranscribe]
        case .whisperTurbo: [.whisperLargeV3Turbo]
        case .whisperBase: [.whisperBaseEnglish]
        case .whisperTiny: [.whisperTinyEnglish]
        }
    }

    /// Assets that improve the engine when present but are not needed to run.
    var optionalModels: [VoiceDictationModelID] {
        self == .parakeetS1 ? [.parakeetVocabularyBooster] : []
    }

    /// Whether the S1-mini cleanup stage is part of this engine's recipe.
    var appliesCleanup: Bool { self == .parakeetS1 }

    /// Languages the user can pin. Empty means the engine decides on its own
    /// (Parakeet detects among its languages; Whisper .en models are English).
    var selectableLanguages: [VoiceDictationLanguage] {
        switch self {
        case .cohereTranscribe, .whisperTurbo: VoiceDictationLanguage.all
        case .parakeetS1, .whisperBase, .whisperTiny: []
        }
    }

    /// Whether "Automatic" means real detection from the audio.
    var detectsLanguage: Bool {
        self == .whisperTurbo || self == .parakeetS1
    }

    var languageNote: String {
        switch self {
        case .parakeetS1: "Parakeet hears 25 European languages on its own. S1-mini cleanup runs on English; other languages are written as recognized."
        case .cohereTranscribe: "Cohere cannot detect the language: speech in another one comes out translated. Automatic follows your Mac's language."
        case .whisperTurbo: "Automatic detects the language of each dictation."
        case .whisperBase, .whisperTiny: "English-only model (\(rawValueAsset)). Choose Many languages for other languages."
        }
    }

    private var rawValueAsset: String {
        switch self {
        case .whisperBase: "base.en"
        case .whisperTiny: "tiny.en"
        case .parakeetS1, .cohereTranscribe, .whisperTurbo: ""
        }
    }

    /// The language code handed to the recognizer, or nil for detection.
    /// `setting` is `VoiceDictationLanguage.automatic` or an ISO 639-1 code.
    func recognitionLanguage(for setting: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String? {
        switch self {
        case .parakeetS1: return nil
        case .whisperBase, .whisperTiny: return "en"
        case .whisperTurbo:
            return setting == VoiceDictationLanguage.automatic ? nil : setting
        case .cohereTranscribe:
            if setting != VoiceDictationLanguage.automatic { return setting }
            let supported = Set(VoiceDictationLanguage.all.map(\.code))
            for identifier in preferredLanguages {
                let code = Locale(identifier: identifier).language.languageCode?.identifier ?? ""
                if supported.contains(code) { return code }
            }
            return "en"
        }
    }
}

/// A language the multilingual engines can be pinned to. The list is the
/// intersection that Cohere Transcribe supports; Whisper Turbo accepts all of
/// them too.
struct VoiceDictationLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String

    var id: String { code }

    static let automatic = "auto"

    static let all: [VoiceDictationLanguage] = [
        .init(code: "en", name: "English"),
        .init(code: "de", name: "German"),
        .init(code: "fr", name: "French"),
        .init(code: "es", name: "Spanish"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "pl", name: "Polish"),
        .init(code: "el", name: "Greek"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "vi", name: "Vietnamese"),
    ]

    static func name(for code: String) -> String {
        all.first { $0.code == code }?.name
            ?? Locale.current.localizedString(forLanguageCode: code)
            ?? code
    }
}

/// One downloadable, removable model asset with pinned provenance.
enum VoiceDictationModelID: String, CaseIterable, Identifiable, Codable, Sendable {
    case parakeetTDT06BV3
    case parakeetVocabularyBooster
    case s1Mini
    case cohereTranscribe
    case whisperLargeV3Turbo
    case whisperBaseEnglish
    case whisperTinyEnglish

    var id: String { rawValue }
}

/// S1-mini's control line. The cases are the values the model was trained
/// on; the card warns that anything else garbles the output.
struct VoiceDictationCleanupDirective: Equatable, Sendable {
    enum Styling: String, CaseIterable, Sendable {
        case casual
        case semiCasual = "semi-casual"
        case semiFormal = "semi-formal"
        case formal
    }

    enum Structure: String, CaseIterable, Sendable {
        case prose
        case lists
    }

    enum Context: String, CaseIterable, Sendable {
        case general
        case email
    }

    var styling: Styling
    var structure: Structure = .prose
    var context: Context = .general

    static let polished = VoiceDictationCleanupDirective(styling: .semiFormal)
}

/// How S1-mini rewrites a dictation. Filler removal and self-correction
/// resolution are always on once the model runs, so "keep every word" means
/// not running it. The raw values predate the style names and are what
/// settings and history have stored.
enum VoiceDictationCleanupLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    /// No S1-mini. Punctuation and casing come from the recognizer; every
    /// word the user said stays, including fillers and list numbering.
    case verbatim
    /// S1-mini in its casual register, which writes like a text message:
    /// lowercase, little punctuation, hesitations left in.
    case light
    /// S1-mini in its semi-formal register. The original behavior.
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verbatim: "Verbatim"
        case .light: "Casual"
        case .full: "Polished"
        }
    }

    /// One line for a settings row.
    var shortDetail: String {
        switch self {
        case .verbatim: "Every word as said, punctuated by the recognizer"
        case .light: "Like a text message, lowercase and light punctuation"
        case .full: "Removes fillers, writes numbers, punctuates sentences"
        }
    }

    var detail: String {
        switch self {
        case .verbatim:
            "Keeps every word you said. Punctuation and capitalization only, straight from the recognizer. Lists keep the numbers you spoke."
        case .light:
            "Writes like a text message: lowercase, light punctuation, your wording left as spoken. Corrections are still resolved and numbers written as figures."
        case .full:
            "Removes fillers and false starts, writes numbers, dates, and emails properly, and punctuates as sentences. The default."
        }
    }

    /// What S1-mini is asked for, or nil when it does not run. A mail
    /// composer gets the email layout.
    /// `lists` turns spoken enumerations into lists; S1-mini was trained on
    /// that only with its semi-formal register, so Polished alone takes it.
    func directive(
        lists: Bool = false,
        context: VoiceDictationAppContext = .general
    ) -> VoiceDictationCleanupDirective? {
        var directive: VoiceDictationCleanupDirective
        switch self {
        case .verbatim: return nil
        case .light: directive = VoiceDictationCleanupDirective(styling: .casual)
        case .full: directive = .polished
        }
        if lists, self == .full { directive.structure = .lists }
        if context == .email, self != .light { directive.context = .email }
        return directive
    }

    /// Reads a saved style, mapping Compose (now Polished with lists) to
    /// Polished so older settings, app styles and history still load.
    static func saved(_ raw: String?) -> VoiceDictationCleanupLevel? {
        guard let raw else { return nil }
        return raw == "compose" ? .full : VoiceDictationCleanupLevel(rawValue: raw)
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let level = Self.saved(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown style \(raw)"))
        }
        self = level
    }
}

enum VoiceDictationActivationMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case pushToTalk
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushToTalk: "Push to talk"
        case .toggle: "Toggle"
        }
    }

    var detail: String {
        switch self {
        case .pushToTalk: "Hold the shortcut while you speak. Release to finish."
        case .toggle: "Press the shortcut once to start and again to finish."
        }
    }
}

/// A global keyboard shortcut. Stored as a virtual key code plus
/// device-independent modifier flags so it survives keyboard layout changes
/// the way macOS's own shortcuts do.
struct VoiceDictationHotkey: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags.deviceIndependentFlagsMask` bits only.
    var modifierFlags: UInt

    /// Control-Option-M. Nano had no keyboard shortcuts before this feature,
    /// and neither macOS nor the common dictation tools claim this chord by
    /// default; it is a starting point, not a requirement.
    static let `default` = VoiceDictationHotkey(
        keyCode: 46, // kVK_ANSI_M
        modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue
    )

    /// Control-Option-C for a Cue capture. Same family as the dictation
    /// chord, so the two are easy to remember together.
    static let cueQuickCaptureDefault = VoiceDictationHotkey(
        keyCode: 8, // kVK_ANSI_C
        modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue
    )

    /// Control-Option-S starts and finishes a Sketch.
    static let sketchDefault = VoiceDictationHotkey(
        keyCode: 1, // kVK_ANSI_S
        modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue
    )

    /// Control-Option-Command-M mutes the microphone. The Command keeps it
    /// clear of the dictation chord (Control-Option-M).
    static let mixerMicMuteDefault = VoiceDictationHotkey(
        keyCode: 46, // kVK_ANSI_M
        modifierFlags: NSEvent.ModifierFlags([.control, .option, .command]).rawValue
    )

    init(keyCode: UInt16, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue
    }

    /// `"keyCode:modifierFlags"`, the form stored in UserDefaults.
    var storageValue: String { "\(keyCode):\(modifierFlags)" }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let keyCode = UInt16(parts[0]),
              let flags = UInt(parts[1]) else { return nil }
        self.init(keyCode: keyCode, modifierFlags: flags)
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
    }

    /// A shortcut without Command, Control or Option would swallow ordinary
    /// typing. Shift alone is a capital letter, and the function flag alone
    /// is what a bare arrow, F-key, Home, End or Delete carries.
    var isUsable: Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    /// Whether `hotkey` is a Command shortcut nearly every app relies on
    /// (copy, paste, new tab, 1 to 9 and so on). A global hotkey claims the
    /// chord everywhere, so the recorder accepts it but says what it replaces.
    static func isCommonSystemShortcut(_ hotkey: VoiceDictationHotkey) -> Bool {
        let held = hotkey.modifiers.intersection([.command, .control, .option, .shift])
        return held == .command && commonCommandKeyCodes.contains(hotkey.keyCode)
    }

    /// C V X Z A S Q W T N F P R L, Tab, Space, 1 to 9.
    private static let commonCommandKeyCodes: Set<UInt16> = [
        8, 9, 7, 6, 0, 1, 12, 13, 17, 45, 3, 35, 15, 37, 48, 49,
        18, 19, 20, 21, 23, 22, 26, 28, 25,
    ]

    var displayString: String {
        var parts = ""
        if modifiers.contains(.control) { parts += "⌃" }
        if modifiers.contains(.option) { parts += "⌥" }
        if modifiers.contains(.shift) { parts += "⇧" }
        if modifiers.contains(.command) { parts += "⌘" }
        if modifiers.contains(.function) { parts += "fn" }
        return parts + VoiceDictationKeyNames.name(for: keyCode)
    }
}

/// Human-readable names for virtual key codes. Letters and digits follow the
/// ANSI layout, which is what the key code space is defined against.
enum VoiceDictationKeyNames {
    private static let special: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let ansi: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
        50: "`",
    ]

    static func name(for keyCode: UInt16) -> String {
        special[keyCode] ?? ansi[keyCode] ?? "Key \(keyCode)"
    }
}

/// A text-targeted correction. Vocabulary entries fix how a term is written
/// (`cloud code` → `Claude Code`); snippets expand a deliberate trigger phrase into
/// longer text the user chose. Neither touches audio or trains anything.
struct VoiceDictationVocabularyEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case vocabulary
        case snippet

        var id: String { rawValue }

        var title: String {
            switch self {
            case .vocabulary: "Vocabulary"
            case .snippet: "Snippet"
            }
        }
    }

    var id: UUID
    var phrase: String
    var replacement: String
    var kind: Kind
    var isEnabled: Bool
    /// Set when the entry applies in one app only. An app entry overrides a
    /// global entry with the same phrase.
    var bundleID: String?
    var appName: String?

    init(
        id: UUID = UUID(),
        phrase: String,
        replacement: String,
        kind: Kind,
        isEnabled: Bool = true,
        bundleID: String? = nil,
        appName: String? = nil
    ) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
        self.kind = kind
        self.isEnabled = isEnabled
        self.bundleID = bundleID
        self.appName = appName
    }

    /// The entries in effect in an app: its own, plus global entries whose
    /// phrase it doesn't override.
    static func forApp(_ entries: [Self], bundleID: String?) -> [Self] {
        let active = entries.filter(\.isEnabled)
        guard let bundleID = bundleID?.lowercased(), !bundleID.isEmpty else {
            return active.filter { $0.bundleID == nil }
        }
        let scoped = active.filter { $0.bundleID?.lowercased() == bundleID }
        let overridden = Set(scoped.map(\.phraseKey))
        return active.filter { entry in
            if let entryApp = entry.bundleID { return entryApp.lowercased() == bundleID }
            return !overridden.contains(entry.phraseKey)
        }
    }

    var phraseKey: String {
        phrase.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var isValid: Bool {
        !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !replacement.isEmpty
    }
}

enum VoiceDictationError: Error, Equatable, Sendable {
    case featureDisabled
    case microphoneDenied
    case microphoneUnavailable
    case audioCaptureFailed(String)
    case modelMissing(VoiceDictationEngine, [VoiceDictationModelID])
    case modelLoadFailed(String)
    case recognitionFailed(String)
    case cleanupFailed(String)
    case clipboardFailed
    case cancelled
    case noSpeech
    case busy
    case screenRecordingDenied
    case screenCaptureFailed

    var title: String {
        switch self {
        case .featureDisabled: "Quill is off"
        case .microphoneDenied: "Microphone access denied"
        case .microphoneUnavailable: "No microphone available"
        case .audioCaptureFailed: "Recording failed"
        case .modelMissing: "Engine not downloaded"
        case .modelLoadFailed: "Engine failed to load"
        case .recognitionFailed: "Recognition failed"
        case .cleanupFailed: "Cleanup failed"
        case .clipboardFailed: "Could not copy to the clipboard"
        case .cancelled: "Dictation cancelled"
        case .noSpeech: "Nothing to transcribe"
        case .busy: "Already transcribing"
        case .screenRecordingDenied: "Screen Recording needed"
        case .screenCaptureFailed: "Screenshot failed"
        }
    }

    var detail: String {
        switch self {
        case .featureDisabled:
            "Turn Quill on in Settings → General."
        case .microphoneDenied:
            "Allow Nano in System Settings → Privacy & Security → Microphone, then try again."
        case .microphoneUnavailable:
            "Connect or select an input device in System Settings → Sound."
        case let .audioCaptureFailed(message):
            message
        case let .modelMissing(engine, models):
            "\(engine.title) needs \(models.count == 1 ? "a download" : "\(models.count) downloads") before it can run. Open Settings → Quill to download it."
        case let .modelLoadFailed(message), let .recognitionFailed(message), let .cleanupFailed(message):
            message
        case .clipboardFailed:
            "The transcript is kept in Nano. Open Quill in the island and press Copy."
        case .cancelled:
            "Nothing was transcribed or copied."
        case .noSpeech:
            "The recording was empty or too short. Hold the shortcut while you speak."
        case .busy:
            "Wait for the current dictation to finish."
        case .screenRecordingDenied:
            "Sketch takes screenshots. Allow Nano in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        case .screenCaptureFailed:
            "Nano could not take a screenshot. The transcript was copied."
        }
    }

}

/// A cleanup style for one app, such as Casual in Discord.
struct VoiceDictationAppStyle: Codable, Equatable, Hashable, Identifiable, Sendable {
    var bundleID: String
    var appName: String
    var level: VoiceDictationCleanupLevel

    var id: String { bundleID }

    /// The first style matching the app, else the default.
    static func level(
        default level: VoiceDictationCleanupLevel,
        styles: [Self],
        bundleID: String?
    ) -> VoiceDictationCleanupLevel {
        guard let bundleID = bundleID?.lowercased(), !bundleID.isEmpty else { return level }
        return styles.first { $0.bundleID.lowercased() == bundleID }?.level ?? level
    }
}

/// Timing broken out per stage so a cold model load is never reported as
/// dictation latency.
struct VoiceDictationMetrics: Equatable, Sendable {
    var audioDuration: TimeInterval = 0
    var modelLoad: TimeInterval = 0
    var transcription: TimeInterval = 0
    var cleanup: TimeInterval = 0
    var postProcessing: TimeInterval = 0
    /// From the moment recording stopped to the clipboard write returning.
    var stopToClipboard: TimeInterval = 0
    var wasColdStart = false
    var accelerator = ""
}

struct VoiceDictationResult: Equatable, Sendable {
    /// Verbatim ASR output. Never rewritten by S1-mini.
    var rawTranscript: String
    /// What reached the clipboard.
    var finalText: String
    var engine: VoiceDictationEngine
    var cleanupApplied: Bool
    /// Phrases that matched a vocabulary entry or snippet, in order.
    var appliedReplacements: [String]
    var metrics: VoiceDictationMetrics
    var completedAt: Date
    var cleanupLevel: VoiceDictationCleanupLevel = .full
    /// Chunks where the cleanup guard rejected S1-mini's output and kept the
    /// recognizer's text instead. Non-zero means the user got a less polished
    /// sentence rather than a changed one.
    var guardedChunks: Int = 0
    /// Chunks where S1-mini failed outright and the raw text was used.
    var cleanupFallbacks: Int = 0
    /// ISO 639-1 code of what was heard, when the engine or text told us.
    var language: String?
    /// How the destination app shaped the text.
    var appContext: VoiceDictationAppContext = .general
    /// Words the vocabulary booster corrected in the recognizer's output.
    var boostedTerms: [String] = []
    /// Pieces transcribed while the user was still talking.
    var segmentsProcessedEarly: Int = 0
}
