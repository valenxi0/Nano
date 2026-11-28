import XCTest
@testable import Nano

/// Sessions whose agent started before Nano's hooks are located from the
/// agent process itself. Only one unambiguous process may decide, and only
/// the keys that locate a session are read from its environment.
final class AgentProcessProbeTests: XCTestCase {
    private let warp = "a9288465d1794c2590de5dd32072a5a3"

    private func procArgs(executable: String, arguments: [String], environment: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(arguments.count)) { bytes.append(contentsOf: $0) }
        bytes += Array(executable.utf8) + [0, 0, 0, 0]
        for value in arguments + environment { bytes += Array(value.utf8) + [0] }
        bytes += [0]
        return bytes
    }

    func testProcArgsKeepOnlyTheKeysThatLocateASession() throws {
        let bytes = procArgs(
            executable: "/Users/me/.local/bin/claude",
            arguments: ["claude", "--resume", "abc"],
            environment: [
                "__CFBundleIdentifier=dev.warp.Warp-Stable",
                "WARP_TERMINAL_SESSION_UUID=\(warp)",
                "ANTHROPIC_API_KEY=sk-secret",
                "PATH=/usr/bin",
            ]
        )
        let process = try XCTUnwrap(AgentProcessProbe.parseProcArgs(bytes, pid: 42))
        XCTAssertEqual(process.executable, "/Users/me/.local/bin/claude")
        XCTAssertEqual(process.arguments, ["claude", "--resume", "abc"])
        XCTAssertEqual(process.environment, [
            "__CFBundleIdentifier": "dev.warp.Warp-Stable",
            "WARP_TERMINAL_SESSION_UUID": warp,
        ])
    }

    func testTruncatedProcArgsAreRejected() {
        XCTAssertNil(AgentProcessProbe.parseProcArgs([1, 0], pid: 1))
        var bytes = procArgs(executable: "/bin/x", arguments: ["a", "b"], environment: [])
        bytes = Array(bytes.prefix(12))
        XCTAssertNil(AgentProcessProbe.parseProcArgs(bytes, pid: 1))
    }

    func testALiveProcessIsReadWithoutItsSecrets() throws {
        // macOS hides the environment of Apple platform binaries, which an
        // agent CLI never is. An ad-hoc signed copy behaves like one.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nano-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sleeper = folder.appendingPathComponent("sleeper")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleeper)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", sleeper.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw XCTSkip("codesign is unavailable") }

        let process = Process()
        process.executableURL = sleeper
        process.arguments = ["30"]
        process.environment = [
            "WARP_TERMINAL_SESSION_UUID": warp,
            "NANO_TEST_SECRET": "do-not-read",
        ]
        try process.run()
        defer { process.terminate() }
        let read = try XCTUnwrap(AgentProcessProbe.arguments(of: process.processIdentifier))
        XCTAssertEqual(URL(fileURLWithPath: read.executable).lastPathComponent, "sleeper")
        XCTAssertEqual(read.arguments.last, "30")
        XCTAssertEqual(read.environment["WARP_TERMINAL_SESSION_UUID"], warp)
        XCTAssertNil(read.environment["NANO_TEST_SECRET"])
    }

    func testEnvironmentFillsTheSameFieldsAHookWould() {
        var session = AgentSession(id: "s", provider: .claude, projectName: "p", lastActivityAt: Date())
        session.host = .terminal
        let filled = AgentProcessProbe.applying([
            "__CFBundleIdentifier": "dev.warp.Warp-Stable",
            "WARP_TERMINAL_SESSION_UUID": warp,
            "TMUX": "/private/tmp/tmux-501/default,1,0",
            "TMUX_PANE": "%4",
            "ITERM_SESSION_ID": "w0t0p0:0B2C8E4A-6F1D-4E7B-9A3C-5D8E2F1A4B6C",
        ], to: session)
        XCTAssertEqual(filled.hostBundleID, "dev.warp.warp-stable")
        XCTAssertEqual(filled.host, .terminal)
        XCTAssertEqual(filled.warpSessionID, warp)
        XCTAssertEqual(filled.tmuxLocation, .init(socketPath: "/private/tmp/tmux-501/default", paneID: "%4"))
        XCTAssertEqual(filled.itermSessionID, "0B2C8E4A-6F1D-4E7B-9A3C-5D8E2F1A4B6C")
        XCTAssertFalse(AgentProcessProbe.needsProbe(filled))
    }

    func testHostileEnvironmentValuesAreDropped() {
        let session = AgentSession(id: "s", provider: .claude, projectName: "p", lastActivityAt: Date())
        let filled = AgentProcessProbe.applying([
            "__CFBundleIdentifier": "dev.warp\"; rm -rf ~",
            "WARP_TERMINAL_SESSION_UUID": "../../x",
            "TMUX_PANE": "%1;kill-server",
        ], to: session)
        XCTAssertEqual(filled.hostBundleID, "dev.warprm-rf")
        XCTAssertNil(filled.warpSessionID)
        XCTAssertNil(filled.tmuxLocation)
    }

    func testAHookedSessionIsNotProbed() {
        var session = AgentSession(id: "s", provider: .claude, projectName: "p", lastActivityAt: Date())
        XCTAssertTrue(AgentProcessProbe.needsProbe(session))
        session.hostBundleID = "dev.warp.warp-stable"
        XCTAssertFalse(AgentProcessProbe.needsProbe(session))
    }

    func testOnlyTheProvidersOwnProcessCounts() {
        func process(_ executable: String, _ arguments: [String]) -> AgentProcessProbe.AgentProcess {
            .init(pid: 1, executable: executable, arguments: arguments, environment: [:])
        }
        let claude = AgentProcessProbe.processNames(for: .claude)
        XCTAssertTrue(AgentProcessProbe.matches(process("/Users/me/.local/bin/claude", ["claude"]), names: claude))
        XCTAssertFalse(AgentProcessProbe.matches(process("/bin/zsh", ["-zsh"]), names: claude))
        let codex = AgentProcessProbe.processNames(for: .codex)
        XCTAssertTrue(AgentProcessProbe.matches(process("/opt/homebrew/bin/node", ["node", "/opt/lib/codex"]), names: codex),
                      "a node launcher names the agent in its first argument")
        XCTAssertFalse(AgentProcessProbe.matches(process("/opt/homebrew/bin/node", ["node", "/opt/lib/codex"]), names: claude))
    }

    func testTwoProcessesInOneFolderAreAmbiguous() {
        let a = AgentProcessProbe.AgentProcess(pid: 1, executable: "claude", arguments: ["claude"], environment: [:])
        let b = AgentProcessProbe.AgentProcess(pid: 2, executable: "claude", arguments: ["claude", "--resume", "s-2"], environment: [:])
        XCTAssertEqual(AgentProcessProbe.choose([a], sessionID: "x")?.pid, 1)
        XCTAssertNil(AgentProcessProbe.choose([a, b], sessionID: "x"), "nothing is guessed")
        XCTAssertEqual(AgentProcessProbe.choose([a, b], sessionID: "s-2")?.pid, 2, "the one naming the session wins")
        XCTAssertNil(AgentProcessProbe.choose([], sessionID: "x"))
    }
}
