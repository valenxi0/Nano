import XCTest
@testable import Nano

/// Only Nano's own bridge entries may be re-approved automatically. Every
/// other hook in the file — other tools', managed entries, disabled entries —
/// keeps whatever trust state Codex gave it.
final class CodexHookTrustTests: XCTestCase {
    private let hooksFile = URL(fileURLWithPath: "/Users/test/.codex/hooks.json")
    private let command =
        "/bin/sh -c '[ -x \"/tmp/bin/nano-agent-bridge\" ] && \"/tmp/bin/nano-agent-bridge\" --source codex; exit 0'"

    private func hook(
        key: String = "/Users/test/.codex/hooks.json:permission_request:2:0",
        command: String? = nil,
        source: String = "user",
        sourcePath: String = "/Users/test/.codex/hooks.json",
        enabled: Bool = true,
        isManaged: Bool = false,
        currentHash: String? = "sha256:abc",
        trustStatus: String = "modified"
    ) -> [String: Any] {
        [
            "key": key,
            "eventName": "permissionRequest",
            "handlerType": "command",
            "command": command ?? self.command,
            "sourcePath": sourcePath,
            "source": source,
            "enabled": enabled,
            "isManaged": isManaged,
            "currentHash": currentHash as Any,
            "trustStatus": trustStatus,
        ]
    }

    private func result(cwds: [[[String: Any]]]) -> [String: Any] {
        ["data": cwds.map { ["cwd": "/tmp", "hooks": $0] }]
    }

    func testModifiedAndUntrustedNanoHooksRepair() {
        let modified = result(cwds: [[hook(trustStatus: "modified")]])
        XCTAssertEqual(
            CodexHookTrust.repairs(inHooksList: modified, hooksFile: hooksFile),
            [CodexHookTrust.Repair(
                key: "/Users/test/.codex/hooks.json:permission_request:2:0",
                hash: "sha256:abc"
            )]
        )

        let untrusted = result(cwds: [[hook(trustStatus: "untrusted")]])
        XCTAssertEqual(
            CodexHookTrust.repairs(inHooksList: untrusted, hooksFile: hooksFile).count,
            1
        )
    }

    func testTrustedNanoHookNeedsNoRepair() {
        let list = result(cwds: [[hook(trustStatus: "trusted")]])
        XCTAssertTrue(CodexHookTrust.repairs(inHooksList: list, hooksFile: hooksFile).isEmpty)
    }

    func testOtherToolsHooksAreUntouched() {
        let list = result(cwds: [[hook(
            key: "/Users/test/.codex/hooks.json:permission_request:3:0",
            command: "'/Users/test/.vibe-island/bin/vibe-island-bridge' --source codex"
        )]])
        XCTAssertTrue(CodexHookTrust.repairs(inHooksList: list, hooksFile: hooksFile).isEmpty)
    }

    func testDisabledManagedAndForeignPathHooksAreSkipped() {
        let disabled = result(cwds: [[hook(enabled: false)]])
        XCTAssertTrue(CodexHookTrust.repairs(inHooksList: disabled, hooksFile: hooksFile).isEmpty)

        let managed = result(cwds: [[hook(isManaged: true)]])
        XCTAssertTrue(CodexHookTrust.repairs(inHooksList: managed, hooksFile: hooksFile).isEmpty)

        let project = result(cwds: [[hook(
            key: "/tmp/proj/.codex/hooks.json:permission_request:0:0",
            sourcePath: "/tmp/proj/.codex/hooks.json"
        )]])
        XCTAssertTrue(CodexHookTrust.repairs(inHooksList: project, hooksFile: hooksFile).isEmpty)

        let plugin = result(cwds: [[hook(source: "plugin")]])
        XCTAssertTrue(CodexHookTrust.repairs(inHooksList: plugin, hooksFile: hooksFile).isEmpty)

        let noHash = result(cwds: [[hook(currentHash: nil)]])
        XCTAssertTrue(CodexHookTrust.repairs(inHooksList: noHash, hooksFile: hooksFile).isEmpty)
    }

    func testSameKeyAcrossCwdsDedupesToOneRepair() {
        let list = result(cwds: [[hook()], [hook()]])
        XCTAssertEqual(CodexHookTrust.repairs(inHooksList: list, hooksFile: hooksFile).count, 1)
    }

    func testEmptyAndMalformedResultsGiveNoRepairs() {
        XCTAssertTrue(CodexHookTrust.repairs(inHooksList: [:], hooksFile: hooksFile).isEmpty)
        XCTAssertTrue(CodexHookTrust.repairs(
            inHooksList: ["data": "nope"], hooksFile: hooksFile
        ).isEmpty)
        XCTAssertTrue(CodexHookTrust.repairs(
            inHooksList: ["data": [["cwd": "/tmp", "hooks": [["key": 1]]]]],
            hooksFile: hooksFile
        ).isEmpty)
    }

    func testTrustWriteParamsUpsertsTrustedHashes() {
        let params = CodexHookTrust.trustWriteParams([
            CodexHookTrust.Repair(key: "k1", hash: "sha256:one"),
            CodexHookTrust.Repair(key: "k2", hash: "sha256:two"),
        ])
        XCTAssertEqual(params["keyPath"] as? String, "hooks.state")
        XCTAssertEqual(params["mergeStrategy"] as? String, "upsert")
        let value = params["value"] as? [String: [String: String]]
        XCTAssertEqual(value, [
            "k1": ["trusted_hash": "sha256:one"],
            "k2": ["trusted_hash": "sha256:two"],
        ])
    }
}
