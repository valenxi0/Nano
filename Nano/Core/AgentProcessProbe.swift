import Darwin
import Foundation

/// Finds where a session runs by reading its agent process.
///
/// An agent started before Nano installed its hooks never calls them: the
/// agent read its hook settings at launch. Nano still sees the session on
/// disk, but not the app or terminal tab it runs in, so a jump could only
/// guess and opened the first terminal in a fixed list. The agent process
/// carries the same environment its hooks would have forwarded
/// (`__CFBundleIdentifier`, Warp, tmux, iTerm2 and cmux IDs), and a process
/// of the same user can be read without extra permissions.
///
/// Only a single agent process of the session's provider in the session's
/// folder counts. Two in one folder are ambiguous unless one names the
/// session on its command line, and then nothing is guessed.
enum AgentProcessProbe {
    struct AgentProcess: Equatable, Sendable {
        var pid: pid_t
        var executable: String
        var arguments: [String]
        var environment: [String: String]
    }

    /// Fills in where the session lives when its hooks never said so.
    static func enriched(_ session: AgentSession) -> AgentSession {
        guard needsProbe(session),
              let folder = session.workingDirectory, !folder.isEmpty,
              let process = agentProcess(for: session, folder: folder)
        else { return session }
        return applying(process.environment, to: session)
    }

    /// A session a hook reported already knows its host and tab.
    static func needsProbe(_ session: AgentSession) -> Bool {
        session.hostBundleID == nil
            && session.cmuxLocation == nil
            && session.warpSessionID == nil
            && session.tmuxLocation == nil
            && session.itermSessionID == nil
    }

    /// The same fields the hook script forwards, read from the agent's own
    /// environment and validated by the same rules.
    static func applying(_ environment: [String: String], to session: AgentSession) -> AgentSession {
        var session = session
        if let bundleID = environment["__CFBundleIdentifier"]?
            .filter({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
           !bundleID.isEmpty {
            session.hostBundleID = bundleID.lowercased()
            // Same rule as hook state: the launching app names the host,
            // unless the session already knows a more exact one.
            if session.host == nil || session.host == .terminal || session.host == .folder {
                session.host = AgentSessionJump.host(bundleID: bundleID)
            }
        }
        session.cmuxLocation = CmuxSessionJump.location(
            workspaceID: environment["CMUX_WORKSPACE_ID"],
            surfaceID: environment["CMUX_SURFACE_ID"]
        )
        session.warpSessionID = WarpSessionJump.sessionID(environment["WARP_TERMINAL_SESSION_UUID"])
        session.tmuxLocation = TmuxSessionJump.location(
            socketPath: environment["TMUX"],
            paneID: environment["TMUX_PANE"]
        )
        session.itermSessionID = ITermSessionJump.sessionID(environment["ITERM_SESSION_ID"])
        return session
    }

    /// The process names an agent CLI runs under. Node launchers run as
    /// `node <path>/codex`, so the script name is checked as well.
    static func processNames(for provider: AgentProviderID) -> Set<String> {
        switch provider {
        case .cursor: ["cursor-agent"]
        case .kilo: ["kilo", "kilocode"]
        default: [provider.rawValue]
        }
    }

    static func matches(_ process: AgentProcess, names: Set<String>) -> Bool {
        let candidates = [process.executable] + process.arguments.prefix(2)
        return candidates.contains { names.contains(URL(fileURLWithPath: $0).lastPathComponent) }
    }

    /// Picks the one process that can be this session.
    static func choose(_ candidates: [AgentProcess], sessionID: String) -> AgentProcess? {
        if candidates.count == 1 { return candidates[0] }
        let naming = candidates.filter { $0.arguments.contains(sessionID) }
        return naming.count == 1 ? naming[0] : nil
    }

    private static func agentProcess(for session: AgentSession, folder: String) -> AgentProcess? {
        let target = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
        let names = processNames(for: session.provider)
        let ownUID = getuid()
        var candidates: [AgentProcess] = []
        for pid in allPIDs() where pid != getpid() {
            // Cheap checks first: owner and working directory, then argv.
            guard uid(of: pid) == ownUID,
                  let cwd = workingDirectory(of: pid),
                  URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path == target,
                  let process = arguments(of: pid),
                  matches(process, names: names)
            else { continue }
            candidates.append(process)
        }
        return choose(candidates, sessionID: session.id)
    }

    // MARK: libproc / sysctl

    private static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    private static func uid(of pid: pid_t) -> uid_t? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbsi_uid
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    static func arguments(of pid: pid_t) -> AgentProcess? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)), pid: pid)
    }

    static let locatingKeys: Set<String> = [
        "__CFBundleIdentifier", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID",
        "WARP_TERMINAL_SESSION_UUID", "TMUX", "TMUX_PANE", "ITERM_SESSION_ID",
    ]

    /// `KERN_PROCARGS2` is `argc` (Int32), the executable path, NUL padding,
    /// then `argc` arguments and the environment, each NUL-terminated.
    static func parseProcArgs(_ bytes: [UInt8], pid: pid_t) -> AgentProcess? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0, argc < 4096 else { return nil }
        var index = MemoryLayout<Int32>.size

        func nextString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return value
        }
        func skipPadding() {
            while index < bytes.count, bytes[index] == 0 { index += 1 }
        }

        guard let executable = nextString() else { return nil }
        skipPadding()
        var arguments: [String] = []
        for _ in 0..<argc {
            guard let argument = nextString() else { return nil }
            arguments.append(argument)
        }
        // Only the keys that locate the session are kept. The rest of the
        // environment (tokens, keys) is never stored.
        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            guard locatingKeys.contains(key) else { continue }
            environment[key] = String(entry[entry.index(after: equals)...])
        }
        return AgentProcess(pid: pid, executable: executable, arguments: arguments, environment: environment)
    }
}
