import Foundation

/// Installs the opt-in Claude Code status-line bridge used for local quota data.
///
/// Claude Code includes the account's rate limits in the JSON sent to its
/// status-line command. Nano keeps an allowlisted subset and delegates the
/// unchanged stdin to the command that was configured before Nano. No
/// credential is read, copied, or stored.
struct ClaudeStatusBridge {
    enum BridgeError: LocalizedError {
        case invalidSettings
        case missingOriginalState
        case settingsChanged

        var errorDescription: String? {
            switch self {
            case .invalidSettings: "Claude settings could not be read."
            case .missingOriginalState: "Nano's saved Claude status-line state is missing."
            case .settingsChanged: "Claude settings changed while Nano was updating them. Please try again."
            }
        }
    }

    struct Status: Equatable {
        let isInstalled: Bool
        let cachedAt: Date?
    }

    private static let marker = "nano-claude-statusline"
    private static let stateVersion = 1

    let settingsURL: URL
    let supportDirectory: URL

    init(
        settingsURL: URL = Self.defaultSettingsURL,
        supportDirectory: URL = NanoStorage.root
            .appendingPathComponent("claude-usage", isDirectory: true)
    ) {
        self.settingsURL = settingsURL
        self.supportDirectory = supportDirectory
    }

    static var defaultConfigDirectory: URL {
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: configured.expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static var defaultSettingsURL: URL {
        defaultConfigDirectory.appendingPathComponent("settings.json")
    }

    var wrapperURL: URL { supportDirectory.appendingPathComponent(Self.marker) }
    var delegateURL: URL { supportDirectory.appendingPathComponent("original-statusline") }
    var cacheURL: URL { supportDirectory.appendingPathComponent("rate-limits.json") }
    var stateURL: URL { supportDirectory.appendingPathComponent("bridge-state.json") }

    func status() -> Status {
        let state = loadState()
        let activeSettingsURL = state.flatMap(Self.stateSettingsURL) ?? settingsURL
        let root = loadSettings(from: activeSettingsURL) ?? [:]
        let command = Self.statusCommand(in: root)
        let installed = state.flatMap(Self.stateManagedCommand).map { command == $0 } ?? false
        let cachedAt = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return Status(isInstalled: installed, cachedAt: cachedAt)
    }

    func install() throws {
        try install(attemptsRemaining: 3)
    }

    private func install(attemptsRemaining: Int) throws {
        if loadState() == nil,
           loadSettings(from: settingsURL)?["_nanoOriginalStatusLine"] != nil {
            try uninstall()
        }
        if let state = loadState(),
           let previousURL = Self.stateSettingsURL(state),
           previousURL.standardizedFileURL != settingsURL.standardizedFileURL {
            try uninstall()
        }

        try createPrivateDirectory()
        guard var root = loadSettings(from: settingsURL) else {
            throw BridgeError.invalidSettings
        }
        let observedRoot = root

        let previousState = loadState()
        let previousManagedCommand = previousState.flatMap(Self.stateManagedCommand)
        let currentCommand = Self.statusCommand(in: root)
        let stillManaged = previousState.flatMap(Self.stateSettingsURL)?.standardizedFileURL
            == settingsURL.standardizedFileURL && currentCommand == previousManagedCommand

        var originalPresent: Bool
        var originalValue: Any?
        if stillManaged, let previousState {
            originalPresent = previousState["present"] as? Bool ?? false
            originalValue = previousState["value"]
        } else {
            originalPresent = root["statusLine"] != nil
            originalValue = root["statusLine"]
        }

        // Nano's wrapper is never the original. With `bridge-state.json` gone
        // and settings still pointing at the wrapper, recording it would make
        // the delegate call the wrapper forever and leave uninstall restoring
        // a dead command. Fall back to the delegate saved by the earlier
        // install, or to no status line at all.
        let wrapperCommands = [wrapperURL.path, Self.shellQuote(wrapperURL.path)]
        if let command = (originalValue as? [String: Any])?["command"] as? String,
           wrapperCommands.contains(command) {
            if let saved = savedDelegateCommand(), !wrapperCommands.contains(saved) {
                var value = originalValue as? [String: Any] ?? [:]
                value["type"] = "command"
                value["command"] = saved
                originalValue = value
                originalPresent = true
            } else {
                originalValue = nil
                originalPresent = false
            }
        }

        let original = originalValue as? [String: Any]
        let originalCommand = original?["command"] as? String
        if let originalCommand, !originalCommand.isEmpty {
            try writePrivate(Self.delegateScript(command: originalCommand), to: delegateURL, mode: 0o700)
        } else {
            try? FileManager.default.removeItem(at: delegateURL)
        }
        try writePrivate(
            wrapperScript(hasDelegate: originalCommand?.isEmpty == false),
            to: wrapperURL,
            mode: 0o700
        )

        // statusLine.command is executed by a shell. The quotes are required
        // because Application Support contains a space.
        let managedCommand = Self.shellQuote(wrapperURL.path)
        var state: [String: Any] = [
            "version": Self.stateVersion,
            "settingsPath": settingsURL.path,
            "present": originalPresent,
            "managedCommand": managedCommand,
        ]
        if let originalValue { state["value"] = originalValue }
        try writePrivateJSON(state, to: stateURL)

        var managed = original ?? [:]
        managed["type"] = "command"
        managed["command"] = managedCommand
        root["statusLine"] = managed
        // Remove the marker used by the first local-bridge prototype. Nano's
        // restoration data now stays in Nano's own private directory.
        root.removeValue(forKey: "_nanoOriginalStatusLine")
        guard settingsStillMatch(observedRoot, at: settingsURL) else {
            guard attemptsRemaining > 0 else { throw BridgeError.settingsChanged }
            try install(attemptsRemaining: attemptsRemaining - 1)
            return
        }
        try writeSettings(root, to: settingsURL)
    }

    func uninstall() throws {
        try uninstall(attemptsRemaining: 3)
    }

    private func uninstall(attemptsRemaining: Int) throws {
        guard let state = loadState(),
              let activeSettingsURL = Self.stateSettingsURL(state),
              let managedCommand = Self.stateManagedCommand(state),
              let wasPresent = state["present"] as? Bool
        else {
            var root = loadSettings(from: settingsURL) ?? [:]
            let observedRoot = root
            if let legacy = root["_nanoOriginalStatusLine"] as? [String: Any],
               let legacyPresent = legacy["present"] as? Bool {
                if legacyPresent {
                    guard let original = legacy["value"] else {
                        throw BridgeError.missingOriginalState
                    }
                    root["statusLine"] = original
                } else {
                    root.removeValue(forKey: "statusLine")
                }
                root.removeValue(forKey: "_nanoOriginalStatusLine")
                guard settingsStillMatch(observedRoot, at: settingsURL) else {
                    guard attemptsRemaining > 0 else { throw BridgeError.settingsChanged }
                    try uninstall(attemptsRemaining: attemptsRemaining - 1)
                    return
                }
                try writeSettings(root, to: settingsURL)
                removeOwnedFiles()
                return
            }
            if [wrapperURL.path, Self.shellQuote(wrapperURL.path)].contains(Self.statusCommand(in: root)) {
                throw BridgeError.missingOriginalState
            }
            removeOwnedFiles()
            return
        }

        guard var root = loadSettings(from: activeSettingsURL) else {
            throw BridgeError.invalidSettings
        }
        let observedRoot = root

        // Only restore when Nano still owns the current command. If the user,
        // `/statusline`, or another app changed it, their newer value wins.
        if Self.statusCommand(in: root) == managedCommand {
            if wasPresent {
                guard let original = state["value"] else {
                    throw BridgeError.missingOriginalState
                }
                root["statusLine"] = original
            } else {
                root.removeValue(forKey: "statusLine")
            }
            guard settingsStillMatch(observedRoot, at: activeSettingsURL) else {
                guard attemptsRemaining > 0 else { throw BridgeError.settingsChanged }
                try uninstall(attemptsRemaining: attemptsRemaining - 1)
                return
            }
            try writeSettings(root, to: activeSettingsURL)
        }
        removeOwnedFiles()
    }

    private func loadSettings(from url: URL) -> [String: Any]? {
        if !FileManager.default.fileExists(atPath: url.path) { return [:] }
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root
    }

    private func loadState() -> [String: Any]? {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              state["version"] as? Int == Self.stateVersion
        else { return nil }
        return state
    }

    private func settingsStillMatch(_ expected: [String: Any], at url: URL) -> Bool {
        guard let current = loadSettings(from: url) else { return false }
        return NSDictionary(dictionary: current).isEqual(to: expected)
    }

    private static func stateSettingsURL(_ state: [String: Any]) -> URL? {
        (state["settingsPath"] as? String).map { URL(fileURLWithPath: $0) }
    }

    private static func stateManagedCommand(_ state: [String: Any]) -> String? {
        state["managedCommand"] as? String
    }

    private static func statusCommand(in root: [String: Any]) -> String? {
        (root["statusLine"] as? [String: Any])?["command"] as? String
    }

    private func createPrivateDirectory() throws {
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: supportDirectory.path
        )
    }

    private func writeSettings(_ root: [String: Any], to url: URL) throws {
        let existed = FileManager.default.fileExists(atPath: url.path)
        let oldAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let oldMode = (oldAttributes?[.posixPermissions] as? NSNumber)?.intValue
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: existed ? (oldMode ?? 0o600) : 0o600],
            ofItemAtPath: url.path
        )
    }

    private func writePrivateJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writePrivate(_ string: String, to url: URL, mode: Int) throws {
        try Data(string.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func removeOwnedFiles() {
        for url in [wrapperURL, delegateURL, cacheURL, stateURL] {
            try? FileManager.default.removeItem(at: url)
        }
        // Remove the directory only when it is empty. Never recursively delete
        // an unexpected file merely because it shares Nano's directory.
        rmdir(supportDirectory.path)
    }

    private func wrapperScript(hasDelegate: Bool) -> String {
        let directory = Self.shellQuote(supportDirectory.path)
        let cache = Self.shellQuote(cacheURL.path)
        let delegate = Self.shellQuote(delegateURL.path)
        let directDelegation = hasDelegate ? "exec \(delegate)" : "/bin/cat >/dev/null 2>&1 || :"
        let savedDelegation = hasDelegate ? "\(delegate) < \"$nano_input\"" : ":"
        return """
        #!/bin/sh
        # Installed by Nano. Stores only allowlisted Claude Code rate-limit fields.
        umask 077
        nano_dir=\(directory)
        nano_input=$(/usr/bin/mktemp "$nano_dir/status.XXXXXX") || { \(directDelegation); exit 0; }
        trap '/bin/rm -f "$nano_input" "${nano_limits:-}"' EXIT HUP INT TERM
        /bin/cat > "$nano_input"

        if /usr/bin/plutil -convert binary1 -o /dev/null "$nano_input" >/dev/null 2>&1; then
          nano_limits=$(/usr/bin/mktemp "$nano_dir/rate-limits.XXXXXX") || {
            \(savedDelegation)
            exit $?
          }
          /usr/bin/plutil -create binary1 "$nano_limits"
          nano_found=0
          for nano_window in five_hour seven_day; do
            nano_used=$(/usr/bin/plutil -extract "rate_limits.$nano_window.used_percentage" raw -o - "$nano_input" 2>/dev/null) \
              || nano_used=$(/usr/bin/plutil -extract "rate_limits.$nano_window.utilization" raw -o - "$nano_input" 2>/dev/null) \
              || continue
            case "$nano_used" in
              ''|*[!0-9.-]*) continue ;;
            esac
            /usr/bin/plutil -insert "$nano_window" -dictionary "$nano_limits"
            /usr/bin/plutil -insert "$nano_window.used_percentage" -float "$nano_used" "$nano_limits"
            nano_reset=$(/usr/bin/plutil -extract "rate_limits.$nano_window.resets_at" raw -o - "$nano_input" 2>/dev/null) || nano_reset=
            case "$nano_reset" in
              ''|*[!0-9.-]*) ;;
              *) /usr/bin/plutil -insert "$nano_window.resets_at" -float "$nano_reset" "$nano_limits" ;;
            esac
            nano_found=1
          done
          if [ "$nano_found" -eq 1 ]; then
            /usr/bin/plutil -convert json "$nano_limits"
            /bin/chmod 600 "$nano_limits"
            /bin/mv -f "$nano_limits" \(cache)
          else
            /bin/rm -f \(cache)
          fi
        fi
        \(savedDelegation)
        """
    }

    /// The command an earlier install preserved in `original-statusline`.
    private func savedDelegateCommand() -> String? {
        guard let data = try? Data(contentsOf: delegateURL) else { return nil }
        let script = String(decoding: data, as: UTF8.self)
        let header = Self.delegateScript(command: "")
        guard script.hasPrefix(header) else { return nil }
        let command = String(script.dropFirst(header.count))
        return command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command
    }

    private static func delegateScript(command: String) -> String {
        """
        #!/bin/sh
        # Original Claude Code statusLine.command preserved by Nano.
        \(command)
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum ClaudeLocalUsageCache {
    struct Snapshot: Equatable, Sendable {
        struct Window: Equatable, Sendable {
            let usedPercent: Double
            let resetsAt: Date?
        }

        let fiveHour: Window?
        let sevenDay: Window?
        let cachedAt: Date
    }

    /// The status line only runs during a Claude Code turn, so past this the
    /// cache says nothing about the account now and the OAuth path is tried.
    static let maximumAge: TimeInterval = 30 * 60

    static func load(
        from url: URL = ClaudeStatusBridge().cacheURL,
        now: Date = Date(),
        maximumAge: TimeInterval? = nil
    ) -> Snapshot? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cachedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        else { return nil }
        if let maximumAge, now.timeIntervalSince(cachedAt) > maximumAge { return nil }

        let snapshot = Snapshot(
            fiveHour: window(root["five_hour"], now: now),
            sevenDay: window(root["seven_day"], now: now),
            cachedAt: cachedAt
        )
        return snapshot.fiveHour == nil && snapshot.sevenDay == nil ? nil : snapshot
    }

    private static func window(_ raw: Any?, now: Date) -> Snapshot.Window? {
        guard let object = raw as? [String: Any],
              let used = number(object["used_percentage"] ?? object["utilization"]),
              used.isFinite
        else { return nil }
        let reset: Date?
        if let seconds = number(object["resets_at"]) {
            reset = Date(timeIntervalSince1970: seconds)
        } else if let text = object["resets_at"] as? String {
            reset = ISO8601DateFormatter().date(from: text)
        } else {
            reset = nil
        }
        if let reset, reset <= now { return nil }
        return Snapshot.Window(usedPercent: min(100, max(0, used)), resetsAt: reset)
    }

    private static func number(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    static func ageLabel(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

private extension String {
    var expandingTildeInPath: String {
        NSString(string: self).expandingTildeInPath
    }
}
