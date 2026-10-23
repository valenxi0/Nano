import AppIntents
import Foundation

/// Starting Quill without its shortcut: `nano://quill/toggle` links for
/// launchers (Raycast, Alfred, Stream Deck) and Shortcuts actions.
enum VoiceDictationRemoteControl {
    static let scheme = "nano"
    static let host = "quill"
    /// UserDefaults key for "Allow links and Shortcuts to start Quill".
    /// Read through `VoiceDictationController.remoteLinksAllowed`.
    static let linksAllowedKey = "voiceDictation.remoteLinksAllowed"

    /// `nano://quill/start`, `/stop`, `/toggle`, `/cancel`, `/sketch`,
    /// `/paste-last`. Also accepts the
    /// command as the host (`nano://toggle`) since launchers often drop paths.
    static func command(for url: URL) -> VoiceDictationController.RemoteCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = url.host?.lowercased() ?? ""
        let path = url.pathComponents.filter { $0 != "/" }.first?.lowercased()
        if host == Self.host { return path.flatMap(VoiceDictationController.RemoteCommand.init(rawValue:)) }
        return VoiceDictationController.RemoteCommand(rawValue: host)
    }

    @MainActor
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard let command = command(for: url) else { return false }
        return VoiceDictationController.current?.perform(command) ?? false
    }

    @MainActor
    static func run(_ command: VoiceDictationController.RemoteCommand) throws {
        guard let controller = VoiceDictationController.current else {
            throw QuillIntentError(localizedStringResource: "Quill is off. Turn it on in Nano's Settings.")
        }
        guard controller.allowsRemote(command) else {
            throw QuillIntentError(
                localizedStringResource: "Starting Quill from Shortcuts is off. Turn on Allow links and Shortcuts to start Quill in Nano's Settings."
            )
        }
        let starts = command == .start || (command == .toggle && controller.phase != .recording)
        let wasBusy = controller.phase.isBusy
        guard controller.perform(command) else {
            if starts, !wasBusy {
                throw QuillIntentError(
                    localizedStringResource: "Quill could not start. Check the engine and microphone in Nano's Settings."
                )
            }
            throw QuillIntentError(localizedStringResource: "Quill is busy with another dictation.")
        }
    }
}

struct QuillIntentError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
}

struct StartQuillDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription("Starts a Quill dictation. The text goes to the field you're in.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try VoiceDictationRemoteControl.run(.start)
        return .result()
    }
}

struct StopQuillDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Dictation"
    static let description = IntentDescription("Stops the current Quill dictation and pastes the text.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try VoiceDictationRemoteControl.run(.stop)
        return .result()
    }
}

struct ToggleQuillDictationIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let description = IntentDescription("Starts a Quill dictation, or stops the one in progress.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try VoiceDictationRemoteControl.run(.toggle)
        return .result()
    }
}

struct QuillShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleQuillDictationIntent(),
            phrases: ["Toggle dictation in \(.applicationName)"],
            shortTitle: "Toggle Dictation",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: StartQuillDictationIntent(),
            phrases: ["Start dictation in \(.applicationName)"],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopQuillDictationIntent(),
            phrases: ["Stop dictation in \(.applicationName)"],
            shortTitle: "Stop Dictation",
            systemImageName: "stop.circle"
        )
    }
}
