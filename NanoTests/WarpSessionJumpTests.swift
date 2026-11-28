import XCTest
@testable import Nano

/// Warp jumps rest on one input: the terminal session ID a hook forwards from
/// the agent's environment, turned into `warp://session/<id>`.
final class WarpSessionJumpTests: XCTestCase {
    private let warpSession = "a9288465d1794c2590de5dd32072a5a3"

    func testSessionIDAcceptsOnlyHexUUIDs() {
        XCTAssertEqual(WarpSessionJump.sessionID(warpSession), warpSession)
        XCTAssertEqual(
            WarpSessionJump.sessionID("D15A688A-4751-471B-9329-943C3E7618CB"),
            "D15A688A-4751-471B-9329-943C3E7618CB"
        )
        XCTAssertNil(WarpSessionJump.sessionID(nil))
        XCTAssertNil(WarpSessionJump.sessionID(""))
        XCTAssertNil(WarpSessionJump.sessionID("abc"))
        XCTAssertNil(WarpSessionJump.sessionID("a9288465/../../settings"))
        XCTAssertNil(WarpSessionJump.sessionID("a9288465d1794c25?x=1"))
    }

    func testFocusURLNamesTheSession() {
        XCTAssertEqual(
            WarpSessionJump.focusURL(sessionID: warpSession)?.absoluteString,
            "warp://session/\(warpSession)"
        )
        XCTAssertNil(WarpSessionJump.focusURL(sessionID: "not a session"))
    }

    func testOnlySessionsWarpCanHoldAreSentThere() {
        XCTAssertTrue(WarpSessionJump.mayHold(warpSessionID: warpSession, hostBundleID: "dev.warp.warp-stable"))
        XCTAssertTrue(WarpSessionJump.mayHold(warpSessionID: warpSession, hostBundleID: "dev.warp.Warp-Preview"))
        XCTAssertTrue(WarpSessionJump.mayHold(warpSessionID: warpSession, hostBundleID: nil))
        XCTAssertFalse(WarpSessionJump.mayHold(warpSessionID: nil, hostBundleID: "dev.warp.warp-stable"),
                       "without an ID only the title guess is left")
        XCTAssertFalse(WarpSessionJump.mayHold(warpSessionID: warpSession, hostBundleID: "com.apple.terminal"))
    }

    @MainActor
    func testHookForwardsTheWarpSessionIntoSessionState() async throws {
        let bridge = AgentHookBridge()
        func send(host: String, warp: String) async throws {
            let payload: [String: Any] = [
                "source": "claude",
                "host_bundle_id": host,
                "warp_session_id": warp,
                "event": [
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "warp-session",
                    "cwd": "/tmp",
                    "prompt": "hello",
                ],
            ]
            _ = await bridge.handle(try JSONSerialization.data(withJSONObject: payload))
        }
        try await send(host: "dev.warp.Warp-Stable", warp: warpSession)
        XCTAssertEqual(bridge.sessionStates["warp-session"]?.warpSessionID, warpSession)

        // Resumed in another terminal: the old Warp tab is forgotten.
        try await send(host: "com.apple.Terminal", warp: "")
        XCTAssertNil(bridge.sessionStates["warp-session"]?.warpSessionID)
    }

    func testBridgeScriptForwardsTheWarpSession() {
        let script = AgentHookBridge.bridgeScript
        XCTAssertTrue(script.contains("WARP_TERMINAL_SESSION_UUID"))
        XCTAssertTrue(script.contains("\"warp_session_id\":\"%s\""))
        // Every %s in the reply format has its own argument, so adding a
        // field cannot shift the others.
        let lines = script.split(separator: "\n")
        let format = lines.first { $0.contains("reply=$(printf") }
        let arguments = lines.first { $0.contains("\"$token\" \"$source\"") }
        XCTAssertNotNil(format)
        XCTAssertNotNil(arguments)
        XCTAssertEqual(
            format.map { $0.components(separatedBy: "%s").count - 1 },
            // Only what printf takes, not `nc -U "$sock"` after the pipe.
            arguments.map { $0.prefix { $0 != "|" }.components(separatedBy: "\"$").count - 1 }
        )
    }
}
