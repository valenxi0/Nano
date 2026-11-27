import XCTest
@testable import Nano

/// cmux jumps rest on two inputs: the IDs a hook forwards from the agent's
/// environment, and `cmux sessions --json`. Both must land on one surface.
final class CmuxSessionJumpTests: XCTestCase {
    private let workspace = "D15A688A-4751-471B-9329-943C3E7618CB"
    private let surface = "FD7E58DD-32DA-4B56-888F-DC887674E0BD"

    func testReportedLocationNeedsBothHalves() {
        XCTAssertEqual(
            CmuxSessionJump.location(workspaceID: workspace, surfaceID: surface),
            .init(workspaceID: workspace, surfaceID: surface)
        )
        XCTAssertNil(CmuxSessionJump.location(workspaceID: workspace, surfaceID: nil))
        XCTAssertNil(CmuxSessionJump.location(workspaceID: "", surfaceID: surface))
    }

    func testReportedLocationRejectsAnythingButUUIDCharacters() {
        XCTAssertNil(CmuxSessionJump.location(workspaceID: "--window", surfaceID: surface))
        XCTAssertNil(CmuxSessionJump.location(workspaceID: workspace, surfaceID: "surface:2; rm"))
    }

    func testSessionsJSONPicksTheNewestRecordForTheSession() throws {
        let json: [String: Any] = [
            "sessions": [
                [
                    "session_id": "abc",
                    "workspace_id": "11111111-1111-1111-1111-111111111111",
                    "surface_id": "22222222-2222-2222-2222-222222222222",
                    "updated_at_unix": 100.0,
                ],
                [
                    "session_id": "ABC",
                    "workspace_id": workspace,
                    "surface_id": surface,
                    "updated_at_unix": 200.0,
                ],
                [
                    "session_id": "other",
                    "workspace_id": "33333333-3333-3333-3333-333333333333",
                    "surface_id": "44444444-4444-4444-4444-444444444444",
                    "updated_at_unix": 900.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(
            CmuxSessionJump.location(fromSessionsJSON: data, sessionID: "abc"),
            .init(workspaceID: workspace, surfaceID: surface)
        )
    }

    func testSessionsJSONWithoutAMatchFindsNothing() throws {
        let empty = try JSONSerialization.data(withJSONObject: ["sessions": [Any]()])
        XCTAssertNil(CmuxSessionJump.location(fromSessionsJSON: empty, sessionID: "abc"))
        XCTAssertNil(CmuxSessionJump.location(fromSessionsJSON: Data("nope".utf8), sessionID: "abc"))
        let noSurface = try JSONSerialization.data(withJSONObject: [
            "sessions": [["session_id": "abc", "workspace_id": workspace]],
        ])
        XCTAssertNil(CmuxSessionJump.location(fromSessionsJSON: noSurface, sessionID: "abc"))
    }

    func testFocusSelectsTheWorkspaceThenTheSurface() {
        let location = CmuxSessionJump.Location(workspaceID: workspace, surfaceID: surface)
        XCTAssertEqual(CmuxSessionJump.focusArguments(for: location), [
            ["select-workspace", "--workspace", workspace],
            ["focus-panel", "--panel", surface, "--workspace", workspace],
        ])
    }

    func testCLIIsTheOneInsideTheAppBundle() throws {
        let app = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertNil(CmuxSessionJump.cliURL(appURL: app))

        let bin = app.appendingPathComponent("Contents/Resources/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("cmux")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        XCTAssertEqual(CmuxSessionJump.cliURL(appURL: app)?.path, cli.path)
    }

    @MainActor
    func testHookForwardsTheCmuxTabIntoSessionState() async throws {
        let bridge = AgentHookBridge()
        let payload: [String: Any] = [
            "source": "claude",
            "host_bundle_id": CmuxSessionJump.bundleID,
            "cmux_workspace_id": workspace,
            "cmux_surface_id": surface,
            "event": [
                "hook_event_name": "UserPromptSubmit",
                "session_id": "cmux-session",
                "cwd": "/tmp",
                "prompt": "hello",
            ],
        ]
        _ = await bridge.handle(try JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(
            bridge.sessionStates["cmux-session"]?.cmuxLocation,
            .init(workspaceID: workspace, surfaceID: surface)
        )
    }

    @MainActor
    func testHookOutsideCmuxLeavesNoLocation() async throws {
        let bridge = AgentHookBridge()
        let payload: [String: Any] = [
            "source": "claude",
            "cmux_workspace_id": "",
            "cmux_surface_id": "",
            "event": [
                "hook_event_name": "UserPromptSubmit",
                "session_id": "plain-session",
                "cwd": "/tmp",
                "prompt": "hello",
            ],
        ]
        _ = await bridge.handle(try JSONSerialization.data(withJSONObject: payload))
        XCTAssertNotNil(bridge.sessionStates["plain-session"])
        XCTAssertNil(bridge.sessionStates["plain-session"]?.cmuxLocation)
    }

    @MainActor
    func testResumingOutsideCmuxForgetsTheOldTab() async throws {
        let bridge = AgentHookBridge()
        func send(host: String, workspace: String, surface: String) async throws {
            let payload: [String: Any] = [
                "source": "claude",
                "host_bundle_id": host,
                "cmux_workspace_id": workspace,
                "cmux_surface_id": surface,
                "event": [
                    "hook_event_name": "UserPromptSubmit",
                    "session_id": "resumed",
                    "cwd": "/tmp",
                    "prompt": "hello",
                ],
            ]
            _ = await bridge.handle(try JSONSerialization.data(withJSONObject: payload))
        }
        try await send(host: CmuxSessionJump.bundleID, workspace: workspace, surface: surface)
        XCTAssertNotNil(bridge.sessionStates["resumed"]?.cmuxLocation)

        try await send(host: "com.apple.Terminal", workspace: "", surface: "")
        XCTAssertNil(bridge.sessionStates["resumed"]?.cmuxLocation)
        XCTAssertEqual(bridge.sessionStates["resumed"]?.hostBundleID, "com.apple.terminal")
    }

    func testOnlySessionsCmuxCanHoldAreSentThere() {
        let location = CmuxSessionJump.Location(workspaceID: workspace, surfaceID: surface)
        XCTAssertTrue(CmuxSessionJump.mayHold(cmuxLocation: location, hostBundleID: nil))
        XCTAssertTrue(CmuxSessionJump.mayHold(cmuxLocation: nil, hostBundleID: nil),
                      "a disk-discovered session can still be in cmux's own record")
        XCTAssertTrue(CmuxSessionJump.mayHold(cmuxLocation: nil, hostBundleID: "com.cmuxterm.app"))
        XCTAssertFalse(CmuxSessionJump.mayHold(cmuxLocation: nil, hostBundleID: "com.apple.terminal"),
                       "resumed in another app: the old cmux tab is not where it lives")
    }

    func testSessionIDsThatCouldReadAsFlagsAreNotPassedToCmux() {
        XCTAssertEqual(CmuxSessionJump.safeSessionID("0f8e9c1a-2b3c-4d5e-8f90-123456789abc"), "0f8e9c1a-2b3c-4d5e-8f90-123456789abc")
        XCTAssertEqual(CmuxSessionJump.safeSessionID("ses_3aZ9.k"), "ses_3aZ9.k")
        XCTAssertNil(CmuxSessionJump.safeSessionID("--json"))
        XCTAssertNil(CmuxSessionJump.safeSessionID("abc def"))
        XCTAssertNil(CmuxSessionJump.safeSessionID(""))
    }

    func testAStuckCmuxIsStoppedInsteadOfHangingTheJump() throws {
        let cli = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cmux-stuck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cli) }
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let started = Date()
        XCTAssertNil(CmuxSessionJump.run(cli, ["sessions"], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCmuxAnswerIsReadBack() throws {
        let cli = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cmux-ok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cli) }
        try Data("#!/bin/sh\necho \"$1\"\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        XCTAssertEqual(CmuxSessionJump.run(cli, ["hello"]).flatMap { String(data: $0, encoding: .utf8) }, "hello\n")
    }

    @MainActor
    func testOpeningInCmuxIsOnByDefault() throws {
        let suite = "NanoTests.cmuxDefault.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(NanoSettings(defaults: defaults).opensSessionsInCmux)
    }

    func testBridgeScriptForwardsCmuxIDs() {
        let script = AgentHookBridge.bridgeScript
        XCTAssertTrue(script.contains("CMUX_WORKSPACE_ID"))
        XCTAssertTrue(script.contains("CMUX_SURFACE_ID"))
        XCTAssertTrue(script.contains("\"cmux_surface_id\":\"%s\""))
    }
}
