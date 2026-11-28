import AppKit
import Foundation

/// Opens an agent session in the exact Warp tab or pane that runs it.
///
/// Warp exports `WARP_TERMINAL_SESSION_UUID` to every shell it runs, and
/// Nano's hook script forwards it, so a session started there says where it
/// lives. Warp registers `warp://session/<id>` (the same URL it exports as
/// `WARP_FOCUS_URL`), which focuses that terminal session. Without it the jump
/// could only bring Warp forward and guess a window by its title.
enum WarpSessionJump {
    static let bundleIDs = ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"]

    /// Whether Warp can be holding this session. A hook from another app
    /// drops the ID, so a session resumed elsewhere is not sent back to an
    /// old Warp tab.
    static func mayHold(warpSessionID: String?, hostBundleID: String?) -> Bool {
        guard warpSessionID != nil else { return false }
        guard let hostBundleID else { return true }
        return bundleIDs.contains { $0.lowercased() == hostBundleID.lowercased() }
    }

    static func shouldTry(_ session: AgentSession) -> Bool {
        mayHold(warpSessionID: session.warpSessionID, hostBundleID: session.hostBundleID)
            && runningApp(preferring: session.hostBundleID) != nil
    }

    /// Warp session IDs are hex UUIDs, with or without dashes. Anything else
    /// is dropped before it reaches a URL.
    static func sessionID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              (8...64).contains(value.count),
              value.allSatisfy({ $0.isHexDigit || $0 == "-" })
        else { return nil }
        return value
    }

    static func focusURL(sessionID: String) -> URL? {
        guard let id = Self.sessionID(sessionID) else { return nil }
        return URL(string: "warp://session/\(id)")
    }

    /// Hands the session URL to the Warp build that ran the agent. Returns
    /// false when Warp is not running or refused the URL, so the caller can
    /// fall back. Warp gives no answer for a tab that has since closed; it
    /// is still the right app to have in front.
    @MainActor
    static func focus(_ session: AgentSession) async -> Bool {
        guard let id = session.warpSessionID,
              let url = focusURL(sessionID: id),
              let app = runningApp(preferring: session.hostBundleID),
              let appURL = app.bundleURL
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
        if opened { app.activate(options: [.activateAllWindows]) }
        return opened
    }

    /// The Warp build named by the hook, else whichever one is running.
    private static func runningApp(preferring hostBundleID: String?) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier?.lowercased() else { return false }
            return bundleIDs.contains { $0.lowercased() == id }
        }
        if let hostBundleID,
           let match = running.first(where: { $0.bundleIdentifier?.lowercased() == hostBundleID.lowercased() }) {
            return match
        }
        return running.first
    }
}
