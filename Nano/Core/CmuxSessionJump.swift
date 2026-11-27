import AppKit
import Foundation

/// Opens an agent session in the exact cmux tab that runs it.
///
/// cmux exports `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` to every terminal it
/// owns, and Nano's hook script forwards them, so a session started there says
/// where it lives. cmux also records the same pair for agents it hooks itself,
/// which `cmux sessions --json` reads back by session ID. Either way the jump
/// selects the workspace and focuses the surface over cmux's socket instead of
/// guessing a window by its title.
///
/// On by default; Settings → Agents can turn it off.
enum CmuxSessionJump {
    static let bundleID = "com.cmuxterm.app"
    static let settingKey = "agents.opensSessionsInCmux"

    struct Location: Equatable, Sendable {
        var workspaceID: String
        var surfaceID: String
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    static var isInstalled: Bool {
        cliURL() != nil
    }

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Whether cmux can be holding this session. A tab its hooks reported
    /// says yes. A hook from another app says no: the session was resumed
    /// there, and the old cmux tab, if it is still open, is not where it
    /// lives now. With neither, only cmux's own record can tell.
    static func mayHold(cmuxLocation: Location?, hostBundleID: String?) -> Bool {
        if cmuxLocation != nil { return true }
        guard let hostBundleID else { return true }
        return hostBundleID.lowercased() == bundleID
    }

    static func shouldTry(_ session: AgentSession) -> Bool {
        // Cheapest first: most sessions come from another app and stop here.
        mayHold(cmuxLocation: session.cmuxLocation, hostBundleID: session.hostBundleID)
            && isEnabled && isInstalled
    }

    /// The CLI that ships inside the app, so a missing `cmux` on PATH (Nano is
    /// launched by launchd, not a shell) does not matter.
    static func cliURL(appURL: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)) -> URL? {
        guard let appURL else { return nil }
        let cli = appURL.appendingPathComponent("Contents/Resources/bin/cmux")
        return FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil
    }

    /// The pair a hook reported, when it reported both halves.
    static func location(workspaceID: String?, surfaceID: String?) -> Location? {
        guard let workspaceID = sanitized(workspaceID), let surfaceID = sanitized(surfaceID)
        else { return nil }
        return Location(workspaceID: workspaceID, surfaceID: surfaceID)
    }

    /// Reads `cmux sessions --session <id> --json`. The newest record that
    /// names both a workspace and a surface wins.
    static func location(fromSessionsJSON data: Data, sessionID: String) -> Location? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [[String: Any]]
        else { return nil }
        let matches = sessions
            .filter { ($0["session_id"] as? String)?.lowercased() == sessionID.lowercased() }
            .compactMap { record -> (Location, Double)? in
                guard let found = location(
                    workspaceID: record["workspace_id"] as? String,
                    surfaceID: record["surface_id"] as? String
                ) else { return nil }
                return (found, record["updated_at_unix"] as? Double ?? 0)
            }
        return matches.max { $0.1 < $1.1 }?.0
    }

    /// The commands that bring a surface forward: switch the window to its
    /// workspace, then focus the surface inside it.
    static func focusArguments(for location: Location) -> [[String]] {
        [
            ["select-workspace", "--workspace", location.workspaceID],
            ["focus-panel", "--panel", location.surfaceID, "--workspace", location.workspaceID],
        ]
    }

    /// Finds and focuses the session's tab. Returns false when cmux does not
    /// know the session or refused the request, so the caller can fall back.
    static func focus(sessionID: String, reported: Location?) async -> Bool {
        guard let cli = cliURL() else { return false }
        let found = await Task.detached(priority: .userInitiated) { () -> Bool in
            // cmux's own record comes first: it follows a session resumed in
            // another tab. The pair the hook reported covers agents cmux does
            // not hook itself, and a stale one simply fails to focus.
            var candidates: [Location] = []
            if let sessionID = safeSessionID(sessionID),
               let output = run(cli, ["sessions", "--session", sessionID, "--json"]),
               let recorded = location(fromSessionsJSON: output, sessionID: sessionID) {
                candidates.append(recorded)
            }
            if let reported, !candidates.contains(reported) { candidates.append(reported) }
            return candidates.contains { candidate in
                focusArguments(for: candidate).allSatisfy { run(cli, $0) != nil }
            }
        }.value
        guard found else { return false }
        await MainActor.run {
            _ = NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == bundleID }?
                .activate(options: [.activateAllWindows])
        }
        return true
    }

    /// Runs the CLI and returns stdout when it exits cleanly. A cmux that
    /// doesn't answer within `timeout` is stopped, so a stuck socket falls
    /// back to the usual jump instead of leaving the click hanging.
    static func run(_ cli: URL, _ arguments: [String], timeout: TimeInterval = 2) -> Data? {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let collected = OutputBuffer()
        output.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        defer { output.fileHandleForReading.readabilityHandler = nil }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        output.fileHandleForReading.readabilityHandler = nil
        collected.append(output.fileHandleForReading.readDataToEndOfFile())
        return process.terminationStatus == 0 ? collected.data : nil
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func append(_ chunk: Data) { lock.withLock { storage.append(chunk) } }
        var data: Data { lock.withLock { storage } }
    }

    /// Agent session IDs are UUIDs or simple tokens (`ses_…`). One that could
    /// read as a flag, or holds anything else, is not passed to cmux.
    static func safeSessionID(_ value: String) -> String? {
        guard let first = value.first, first != "-",
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
        else { return nil }
        return value
    }

    /// cmux IDs are UUIDs; anything else is dropped before it reaches argv.
    private static func sanitized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.allSatisfy({ $0.isHexDigit || $0 == "-" })
        else { return nil }
        return value
    }
}
