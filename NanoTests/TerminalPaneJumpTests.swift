import XCTest
@testable import Nano

/// tmux and iTerm2 jumps rest on the IDs a hook forwards from the agent's
/// environment. Both end up in argv or in an AppleScript, so only well-formed
/// IDs may pass.
final class TerminalPaneJumpTests: XCTestCase {
    private let socket = "/private/tmp/tmux-501/default"
    private let itermUUID = "0B2C8E4A-6F1D-4E7B-9A3C-5D8E2F1A4B6C"

    // MARK: tmux

    func testTmuxLocationAcceptsTheRawTmuxValue() {
        XCTAssertEqual(
            TmuxSessionJump.location(socketPath: "\(socket),12345,0", paneID: "%3"),
            .init(socketPath: socket, paneID: "%3")
        )
        XCTAssertEqual(TmuxSessionJump.location(socketPath: socket, paneID: "%42")?.paneID, "%42")
    }

    func testTmuxLocationNeedsBothHalves() {
        XCTAssertNil(TmuxSessionJump.location(socketPath: socket, paneID: nil))
        XCTAssertNil(TmuxSessionJump.location(socketPath: "", paneID: "%3"))
        XCTAssertNil(TmuxSessionJump.location(socketPath: nil, paneID: "%3"))
    }

    func testTmuxLocationRejectsFlagsAndOddPaths() {
        XCTAssertNil(TmuxSessionJump.location(socketPath: "-L evil", paneID: "%3"))
        XCTAssertNil(TmuxSessionJump.location(socketPath: "relative/sock", paneID: "%3"))
        XCTAssertNil(TmuxSessionJump.location(socketPath: "/tmp/../etc/x", paneID: "%3"))
        XCTAssertNil(TmuxSessionJump.location(socketPath: "/tmp/a b", paneID: "%3"))
        XCTAssertNil(TmuxSessionJump.location(socketPath: socket, paneID: "3"))
        XCTAssertNil(TmuxSessionJump.location(socketPath: socket, paneID: "%"))
        XCTAssertNil(TmuxSessionJump.location(socketPath: socket, paneID: "%3;kill-server"))
    }

    func testTmuxChecksThePaneThenSelectsIt() {
        let arguments = TmuxSessionJump.focusArguments(for: .init(socketPath: socket, paneID: "%7"))
        XCTAssertEqual(arguments.check, ["-S", socket, "display-message", "-p", "-t", "%7", "#{pane_id}"])
        XCTAssertEqual(arguments.steps, [
            ["-S", socket, "switch-client", "-t", "%7"],
            ["-S", socket, "select-window", "-t", "%7"],
            ["-S", socket, "select-pane", "-t", "%7"],
        ])
    }

    func testTmuxCLIIsFoundOutsidePATH() throws {
        let missing = "/nonexistent/tmux-\(UUID().uuidString)"
        XCTAssertNil(TmuxSessionJump.cliURL(candidates: [missing]))
        let fake = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tmux-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fake) }
        try Data("#!/bin/sh\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        XCTAssertEqual(TmuxSessionJump.cliURL(candidates: [missing, fake.path])?.path, fake.path)
    }

    // MARK: iTerm2

    func testITermSessionIDIsTheUUIDAfterThePrefix() {
        XCTAssertEqual(ITermSessionJump.sessionID("w0t1p0:\(itermUUID)"), itermUUID)
        XCTAssertEqual(ITermSessionJump.sessionID(itermUUID.lowercased()), itermUUID)
        XCTAssertNil(ITermSessionJump.sessionID("w0t1p0"))
        XCTAssertNil(ITermSessionJump.sessionID(""))
        XCTAssertNil(ITermSessionJump.sessionID(nil))
    }

    func testITermScriptOnlyCarriesAValidatedUUID() throws {
        let script = try XCTUnwrap(ITermSessionJump.focusScript(sessionID: "w0t1p0:\(itermUUID)"))
        XCTAssertTrue(script.contains("is \"\(itermUUID)\""))
        XCTAssertTrue(script.contains("tell application id \"com.googlecode.iterm2\""))
        XCTAssertNil(ITermSessionJump.focusScript(sessionID: "\" & (do shell script \"id\") & \""))
    }

    func testOnlySessionsITermCanHoldAreSentThere() {
        XCTAssertTrue(ITermSessionJump.mayHold(itermSessionID: itermUUID, hostBundleID: "com.googlecode.iterm2"))
        XCTAssertTrue(ITermSessionJump.mayHold(itermSessionID: itermUUID, hostBundleID: nil))
        XCTAssertFalse(ITermSessionJump.mayHold(itermSessionID: nil, hostBundleID: "com.googlecode.iterm2"))
        XCTAssertFalse(ITermSessionJump.mayHold(itermSessionID: itermUUID, hostBundleID: "dev.warp.warp-stable"))
    }

    // MARK: Hook

    @MainActor
    func testHookForwardsTmuxAndITermIntoSessionState() async throws {
        let bridge = AgentHookBridge()
        func send(host: String, tmuxSocket: String, pane: String, iterm: String) async throws {
            let payload: [String: Any] = [
                "source": "claude",
                "host_bundle_id": host,
                "tmux_socket": tmuxSocket,
                "tmux_pane": pane,
                "iterm_session_id": iterm,
                "event": [
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "pane-session",
                    "cwd": "/tmp",
                    "prompt": "hello",
                ],
            ]
            _ = await bridge.handle(try JSONSerialization.data(withJSONObject: payload))
        }
        try await send(host: ITermSessionJump.bundleID, tmuxSocket: socket, pane: "%3", iterm: itermUUID)
        XCTAssertEqual(bridge.sessionStates["pane-session"]?.tmuxLocation, .init(socketPath: socket, paneID: "%3"))
        XCTAssertEqual(bridge.sessionStates["pane-session"]?.itermSessionID, itermUUID)

        // Resumed outside tmux and iTerm2: both are forgotten.
        try await send(host: "com.apple.Terminal", tmuxSocket: "", pane: "", iterm: "")
        XCTAssertNil(bridge.sessionStates["pane-session"]?.tmuxLocation)
        XCTAssertNil(bridge.sessionStates["pane-session"]?.itermSessionID)
    }

    func testBridgeScriptForwardsTmuxAndITerm() {
        let script = AgentHookBridge.bridgeScript
        XCTAssertTrue(script.contains("TMUX_PANE"))
        XCTAssertTrue(script.contains("ITERM_SESSION_ID"))
        XCTAssertTrue(script.contains("\"tmux_socket\":\"%s\",\"tmux_pane\":\"%s\",\"iterm_session_id\":\"%s\""))
    }
}
