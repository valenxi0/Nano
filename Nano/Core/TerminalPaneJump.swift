import AppKit
import Foundation

/// Opens an agent session in the exact tmux pane that runs it.
///
/// tmux exports `TMUX` (`<socket>,<pid>,<session>`) and `TMUX_PANE` (`%3`) to
/// every pane, and Nano's hook script forwards the socket path and pane, so
/// the jump can select that window and pane on the right server, then bring
/// the terminal that hosts the tmux client forward.
enum TmuxSessionJump {
    struct Location: Equatable, Sendable {
        var socketPath: String
        var paneID: String
    }

    /// The pair a hook reported, when it reported both halves.
    static func location(socketPath: String?, paneID: String?) -> Location? {
        guard let socketPath = sanitizedSocket(socketPath), let paneID = sanitizedPane(paneID)
        else { return nil }
        return Location(socketPath: socketPath, paneID: paneID)
    }

    /// tmux is not on launchd's PATH, so the usual install places are tried.
    static func cliURL(
        candidates: [String] = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/run/current-system/sw/bin/tmux",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nix-profile/bin/tmux").path,
            "/usr/bin/tmux",
        ]
    ) -> URL? {
        candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Checks the pane still exists, then brings it forward: the client
    /// switches to its session, the session to its window, the window to the
    /// pane. A client that is not attached makes `switch-client` fail, which
    /// does not matter; the selection is what the next attach shows.
    static func focusArguments(for location: Location) -> (check: [String], steps: [[String]]) {
        let server = ["-S", location.socketPath]
        let pane = location.paneID
        return (
            server + ["display-message", "-p", "-t", pane, "#{pane_id}"],
            [
                server + ["switch-client", "-t", pane],
                server + ["select-window", "-t", pane],
                server + ["select-pane", "-t", pane],
            ]
        )
    }

    static func shouldTry(_ session: AgentSession) -> Bool {
        session.tmuxLocation != nil && cliURL() != nil
    }

    /// Returns false when tmux is missing, the server is gone or the pane
    /// closed, so the caller can fall back.
    static func focus(_ session: AgentSession) async -> Bool {
        guard let location = session.tmuxLocation, let cli = cliURL() else { return false }
        let selected = await Task.detached(priority: .userInitiated) { () -> Bool in
            let arguments = focusArguments(for: location)
            guard CmuxSessionJump.run(cli, arguments.check) != nil else { return false }
            var paneSelected = false
            for (index, step) in arguments.steps.enumerated() {
                let ok = CmuxSessionJump.run(cli, step) != nil
                if index == arguments.steps.count - 1 { paneSelected = ok }
            }
            return paneSelected
        }.value
        guard selected else { return false }
        await MainActor.run { activateHost(of: session) }
        return true
    }

    /// The terminal the tmux client runs in. The hook's host is the app that
    /// started the tmux server, which is the right one in the usual case;
    /// otherwise any running terminal is better than none.
    @MainActor
    private static func activateHost(of session: AgentSession) {
        let running = NSWorkspace.shared.runningApplications
        let host = session.hostBundleID.flatMap { id in
            running.first { $0.bundleIdentifier?.lowercased() == id.lowercased() }
        } ?? AgentSessionJump.terminalBundleIDs.lazy.compactMap { id in
            running.first { $0.bundleIdentifier == id }
        }.first
        host?.activate(options: [.activateAllWindows])
    }

    /// An absolute path made of ordinary file name characters, never a flag.
    private static func sanitizedSocket(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // The raw `TMUX` value carries `,pid,session` after the path.
        if let comma = value.firstIndex(of: ",") { value = String(value[..<comma]) }
        guard value.hasPrefix("/"), value.count <= 1024, !value.contains(".."),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) })
        else { return nil }
        return value
    }

    /// tmux pane IDs are `%` followed by digits.
    private static func sanitizedPane(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count > 1, value.count <= 12, value.first == "%",
              value.dropFirst().allSatisfy(\.isNumber)
        else { return nil }
        return value
    }
}

/// Opens an agent session in the exact iTerm2 tab and split that runs it.
///
/// iTerm2 exports `ITERM_SESSION_ID` (`w0t1p0:<UUID>`) to every session, and
/// Nano's hook script forwards the UUID. iTerm2's AppleScript dictionary
/// gives each session the same `unique id`, so the jump selects the window,
/// tab and split that hold it. This needs Automation consent for iTerm2.
enum ITermSessionJump {
    static let bundleID = "com.googlecode.iterm2"

    /// The UUID after the `w0t1p0:` prefix, or the bare UUID.
    static func sessionID(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let colon = value.lastIndex(of: ":") { value = String(value[value.index(after: colon)...]) }
        guard UUID(uuidString: value) != nil else { return nil }
        return value.uppercased()
    }

    /// Only a validated UUID is put into the script, so it cannot carry quotes.
    static func focusScript(sessionID: String) -> String? {
        guard let id = Self.sessionID(sessionID) else { return nil }
        return """
        tell application id "\(bundleID)"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if (unique id of aSession as text) is "\(id)" then
                            select aWindow
                            tell aTab to select
                            tell aSession to select
                            activate
                            return "found"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
    }

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// iTerm2 can be holding this session only when its hooks said so; a
    /// hook from another app drops the ID.
    static func mayHold(itermSessionID: String?, hostBundleID: String?) -> Bool {
        guard itermSessionID != nil else { return false }
        guard let hostBundleID else { return true }
        return hostBundleID.lowercased() == bundleID
    }

    static func shouldTry(_ session: AgentSession) -> Bool {
        mayHold(itermSessionID: session.itermSessionID, hostBundleID: session.hostBundleID) && isRunning
    }

    private static let scriptQueue = DispatchQueue(label: "nano.iterm-jump", qos: .userInitiated)

    /// Returns false when iTerm2 no longer has the session, or Automation is
    /// off for it, so the caller can fall back to title matching.
    static func focus(_ session: AgentSession) async -> Bool {
        guard let id = session.itermSessionID, let source = focusScript(sessionID: id) else { return false }
        return await withCheckedContinuation { continuation in
            scriptQueue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil && result?.stringValue == "found")
            }
        }
    }
}
