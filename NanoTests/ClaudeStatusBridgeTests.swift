import XCTest
@testable import Nano

final class ClaudeStatusBridgeTests: XCTestCase {
    private var root: URL!
    private var settingsURL: URL!
    private var supportURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoClaudeStatusTests.\(UUID().uuidString)", isDirectory: true)
        settingsURL = root.appendingPathComponent(".claude/settings.json")
        supportURL = root.appendingPathComponent("Library/Application Support/Nano/claude-usage")
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testInstallCachesOnlyRateLimitsDelegatesUnchangedInputAndRestoresStatusLine() throws {
        let originalStatusLine: [String: Any] = [
            "type": "command",
            "command": "/usr/bin/sed 's/^/original:/'",
            "padding": 2,
            "refreshInterval": 17,
        ]
        let original: [String: Any] = [
            "model": "opus",
            "permissions": ["allow": ["Bash"]],
            "statusLine": originalStatusLine,
        ]
        try writeJSON(original, to: settingsURL)

        let bridge = ClaudeStatusBridge(settingsURL: settingsURL, supportDirectory: supportURL)
        try bridge.install()

        XCTAssertTrue(bridge.status().isInstalled)
        XCTAssertEqual(permissions(bridge.stateURL), 0o600)
        XCTAssertEqual(permissions(bridge.wrapperURL), 0o700)
        XCTAssertEqual(permissions(bridge.delegateURL), 0o700)
        XCTAssertEqual(permissions(supportURL), 0o700)

        let installedSettings = try json(settingsURL)
        XCTAssertNil(installedSettings["_nanoOriginalStatusLine"])
        let installedCommand = try XCTUnwrap(
            (installedSettings["statusLine"] as? [String: Any])?["command"] as? String
        )
        XCTAssertTrue(installedCommand.hasPrefix("'"))

        let payload = #"{"session_id":"secret-session","model":{"display_name":"Opus"},"rate_limits":{"private_future_field":"discard-me","five_hour":{"used_percentage":21,"resets_at":1900000000,"future":"discard-me"},"seven_day":{"used_percentage":64,"resets_at":1900500000}}}"#
        let output = try runShell(installedCommand, stdin: payload)
        XCTAssertEqual(output, "original:\(payload)")

        let cache = try json(bridge.cacheURL)
        XCTAssertEqual(Set(cache.keys), ["five_hour", "seven_day"])
        XCTAssertNil(cache["session_id"])
        XCTAssertNil(cache["model"])
        XCTAssertNil(cache["private_future_field"])
        XCTAssertEqual(
            Set(try XCTUnwrap(cache["five_hour"] as? [String: Any]).keys),
            ["used_percentage", "resets_at"]
        )
        XCTAssertEqual(permissions(bridge.cacheURL), 0o600)

        let snapshot = try XCTUnwrap(ClaudeLocalUsageCache.load(from: bridge.cacheURL))
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 21)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 64)

        try bridge.uninstall()
        let restored = try json(settingsURL)
        XCTAssertEqual(restored["model"] as? String, "opus")
        XCTAssertNotNil(restored["permissions"])
        XCTAssertTrue(NSDictionary(dictionary: restored["statusLine"] as! [String: Any])
            .isEqual(to: originalStatusLine))
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportURL.path))
    }

    func testUninstallKeepsFilesTheBridgeDoesNotOwn() throws {
        try writeJSON(["model": "opus"], to: settingsURL)
        let bridge = ClaudeStatusBridge(settingsURL: settingsURL, supportDirectory: supportURL)
        try bridge.install()
        let oauthCache = supportURL.appendingPathComponent("oauth-cache.json")
        try Data("{}".utf8).write(to: oauthCache)

        try bridge.uninstall()
        XCTAssertTrue(FileManager.default.fileExists(atPath: oauthCache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.cacheURL.path))
    }

    func testInstallCachesUtilizationWhenUsedPercentageIsAbsent() throws {
        try writeJSON(
            ["statusLine": ["type": "command", "command": "/bin/cat"]],
            to: settingsURL
        )
        let bridge = ClaudeStatusBridge(settingsURL: settingsURL, supportDirectory: supportURL)
        try bridge.install()
        let command = try XCTUnwrap(
            (try json(settingsURL)["statusLine"] as? [String: Any])?["command"] as? String
        )

        _ = try runShell(
            command,
            stdin: #"{"rate_limits":{"five_hour":{"utilization":18,"resets_at":1900000000},"seven_day":{"utilization":7}}}"#
        )
        let snapshot = try XCTUnwrap(ClaudeLocalUsageCache.load(from: bridge.cacheURL))
        XCTAssertEqual(snapshot.fiveHour?.usedPercent, 18)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 7)
    }

    func testValidPayloadWithoutRateLimitsClearsStaleCache() throws {
        let bridge = ClaudeStatusBridge(settingsURL: settingsURL, supportDirectory: supportURL)
        try writeJSON(["statusLine": ["type": "command", "command": "/bin/cat"]], to: settingsURL)
        try bridge.install()
        let command = try XCTUnwrap(
            (try json(settingsURL)["statusLine"] as? [String: Any])?["command"] as? String
        )

        _ = try runShell(command, stdin: #"{"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":1900000000}}}"#)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.cacheURL.path))

        let payload = #"{"model":{"display_name":"Opus"}}"#
        XCTAssertEqual(try runShell(command, stdin: payload), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.cacheURL.path))
    }

    func testCacheFailureStillRunsOriginalStatusLine() throws {
        try writeJSON(
            ["statusLine": ["type": "command", "command": "/usr/bin/sed 's/^/kept:/'"]],
            to: settingsURL
        )
        let bridge = ClaudeStatusBridge(settingsURL: settingsURL, supportDirectory: supportURL)
        try bridge.install()
        let command = try XCTUnwrap(
            (try json(settingsURL)["statusLine"] as? [String: Any])?["command"] as? String
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: supportURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportURL.path) }

        let payload = #"{"rate_limits":{"five_hour":{"used_percentage":25}}}"#
        XCTAssertEqual(try runShell(command, stdin: payload), "kept:\(payload)")
    }

    func testUninstallPreservesAStatusLineChangedAfterNanoInstalled() throws {
        try writeJSON(
            ["statusLine": ["type": "command", "command": "/bin/echo original"]],
            to: settingsURL
        )
        let bridge = ClaudeStatusBridge(settingsURL: settingsURL, supportDirectory: supportURL)
        try bridge.install()

        var changed = try json(settingsURL)
        changed["statusLine"] = ["type": "command", "command": "/bin/echo newer"]
        try writeJSON(changed, to: settingsURL)
        try bridge.uninstall()

        let restored = try json(settingsURL)
        XCTAssertEqual(
            (restored["statusLine"] as? [String: Any])?["command"] as? String,
            "/bin/echo newer"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportURL.path))
    }

    func testInstallAndUninstallRestoresMissingStatusLine() throws {
        try writeJSON(["model": "sonnet"], to: settingsURL)
        let bridge = ClaudeStatusBridge(settingsURL: settingsURL, supportDirectory: supportURL)

        try bridge.install()
        XCTAssertTrue(bridge.status().isInstalled)
        try bridge.uninstall()

        let restored = try json(settingsURL)
        XCTAssertEqual(restored["model"] as? String, "sonnet")
        XCTAssertNil(restored["statusLine"])
        XCTAssertNil(restored["_nanoOriginalStatusLine"])
    }

    func testUninstallMigratesThePrototypeRestorationMarker() throws {
        let original: [String: Any] = ["type": "command", "command": "/bin/echo original"]
        try writeJSON([
            "statusLine": ["type": "command", "command": supportURL.appendingPathComponent("nano-claude-statusline").path],
            "_nanoOriginalStatusLine": ["present": true, "value": original],
        ], to: settingsURL)

        let bridge = ClaudeStatusBridge(settingsURL: settingsURL, supportDirectory: supportURL)
        try bridge.uninstall()

        let restored = try json(settingsURL)
        XCTAssertTrue(NSDictionary(dictionary: restored["statusLine"] as! [String: Any])
            .isEqual(to: original))
        XCTAssertNil(restored["_nanoOriginalStatusLine"])
    }

    /// `bridge-state.json` lost while settings still point at the wrapper:
    /// the wrapper must not be recorded as the command it delegates to.
    func testInstallOverItsOwnWrapperWithoutStateDoesNotDelegateToItself() throws {
        let bridge = ClaudeStatusBridge(settingsURL: settingsURL, supportDirectory: supportURL)
        let wrapperCommand = "'" + bridge.wrapperURL.path + "'"
        try writeJSON(
            ["model": "opus", "statusLine": ["type": "command", "command": wrapperCommand]],
            to: settingsURL
        )

        try bridge.install()
        XCTAssertTrue(bridge.status().isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.delegateURL.path))
        let state = try json(bridge.stateURL)
        XCTAssertEqual(state["present"] as? Bool, false)
        XCTAssertNil(state["value"])

        // Returns instead of calling itself until the process table fills.
        let payload = #"{"rate_limits":{"five_hour":{"used_percentage":25}}}"#
        XCTAssertEqual(try runShell(wrapperCommand, stdin: payload), "")

        try bridge.uninstall()
        let restored = try json(settingsURL)
        XCTAssertEqual(restored["model"] as? String, "opus")
        XCTAssertNil(restored["statusLine"])
    }

    func testInstallOverItsOwnWrapperKeepsTheSavedOriginal() throws {
        let bridge = ClaudeStatusBridge(settingsURL: settingsURL, supportDirectory: supportURL)
        let wrapperCommand = "'" + bridge.wrapperURL.path + "'"
        try writeJSON(
            ["statusLine": ["type": "command", "command": wrapperCommand, "padding": 2]],
            to: settingsURL
        )
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        let saved = "#!/bin/sh\n# Original Claude Code statusLine.command preserved by Nano.\n"
            + "/usr/bin/sed 's/^/original:/'"
        try Data(saved.utf8).write(to: bridge.delegateURL)

        try bridge.install()
        let payload = #"{"model":{"display_name":"Opus"}}"#
        XCTAssertEqual(try runShell(wrapperCommand, stdin: payload), "original:\(payload)")

        try bridge.uninstall()
        let restored = try XCTUnwrap(try json(settingsURL)["statusLine"] as? [String: Any])
        XCTAssertEqual(restored["command"] as? String, "/usr/bin/sed 's/^/original:/'")
        XCTAssertEqual(restored["padding"] as? Int, 2)
    }

    func testLocalCacheOlderThanTheAgeCapIsIgnored() throws {
        let url = root.appendingPathComponent("aged.json")
        try writeJSON(["five_hour": ["used_percentage": 30]], to: url)
        let written = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )
        let cap = ClaudeLocalUsageCache.maximumAge

        XCTAssertNotNil(ClaudeLocalUsageCache.load(
            from: url, now: written.addingTimeInterval(cap - 60), maximumAge: cap
        ))
        XCTAssertNil(ClaudeLocalUsageCache.load(
            from: url, now: written.addingTimeInterval(cap + 60), maximumAge: cap
        ))
    }

    func testAgeLabelOmitsUpdatedPrefix() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(ClaudeLocalUsageCache.ageLabel(since: now.addingTimeInterval(-185), now: now), "3m ago")
        XCTAssertEqual(ClaudeLocalUsageCache.ageLabel(since: now.addingTimeInterval(-7_300), now: now), "2h ago")
    }

    func testExpiredWindowsAreNotDisplayed() throws {
        let url = root.appendingPathComponent("expired.json")
        try writeJSON([
            "five_hour": ["used_percentage": 80, "resets_at": 9_000],
            "seven_day": ["used_percentage": 40, "resets_at": 20_000],
        ], to: url)

        let snapshot = try XCTUnwrap(
            ClaudeLocalUsageCache.load(from: url, now: Date(timeIntervalSince1970: 10_000))
        )
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.sevenDay?.usedPercent, 40)
    }

    @MainActor
    func testAllSupportedProvidersTrackTokensAndUsageByDefault() {
        let name = "NanoTests.claudeLocalDefault.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = NanoSettings(defaults: defaults)
        for provider in AgentProviderID.supported {
            XCTAssertTrue(
                settings.isAgentProviderEnabled(provider),
                "\(provider.title) tokens should be on"
            )
            if provider.supportsUsage {
                XCTAssertTrue(
                    settings.isUsageEnabled(provider),
                    "\(provider.title) usage should be on"
                )
            } else {
                XCTAssertFalse(settings.isUsageEnabled(provider))
            }
        }
    }

    @MainActor
    func testTrackAllSupportedMigrationEnablesPreviouslyOffProviders() {
        let name = "NanoTests.trackAllSupported.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(["claude", "codex"], forKey: "agents.enabledProviders")
        defaults.set(["codex", "cursor"], forKey: "agents.usageProviders")
        defaults.set(true, forKey: "agents.claudeLocalUsageMigration")

        let settings = NanoSettings(defaults: defaults)
        XCTAssertTrue(settings.isAgentProviderEnabled(.gemini))
        XCTAssertTrue(settings.isAgentProviderEnabled(.kimi))
        XCTAssertTrue(settings.isAgentProviderEnabled(.opencode))
        XCTAssertTrue(settings.isAgentProviderEnabled(.pi))
        XCTAssertTrue(settings.isUsageEnabled(.claude))
        XCTAssertTrue(settings.isUsageEnabled(.kimi))
        XCTAssertTrue(settings.isUsageEnabled(.cursor))
    }

    @MainActor
    func testGrokMigrationEnablesTokensAndUsageOnExistingInstalls() {
        let name = "NanoTests.trackGrok.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(["claude", "codex"], forKey: "agents.enabledProviders")
        defaults.set(["codex", "cursor"], forKey: "agents.usageProviders")
        defaults.set(true, forKey: "agents.claudeLocalUsageMigration")
        defaults.set(true, forKey: "agents.trackAllSupported")

        let settings = NanoSettings(defaults: defaults)
        XCTAssertTrue(settings.isAgentProviderEnabled(.grok))
        XCTAssertTrue(settings.isUsageEnabled(.grok))
        XCTAssertFalse(settings.isAgentProviderEnabled(.gemini))
    }

    @MainActor
    func testCustomClaudeConfigurationDirectoryPersists() {
        let name = "NanoTests.claudeConfigDirectory.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = NanoSettings(defaults: defaults)
        settings.claudeConfigDirectoryPath = "~/Claude Work"
        let restored = NanoSettings(defaults: defaults)
        XCTAssertEqual(restored.claudeConfigDirectoryPath, "~/Claude Work")
        XCTAssertTrue(restored.claudeSettingsURL.path.hasSuffix("/Claude Work/settings.json"))
    }

    @MainActor
    func testUsageProviderChangesApplyToTheRunningService() {
        let service = AgentStatusService()
        service.activate(providers: [.claude], usage: [])
        service.updateUsageProviders([.claude])
        XCTAssertEqual(service.configuredUsageProviders, [.claude])
        service.deactivate()
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
    }

    private func json(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func permissions(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?
            .intValue ?? -1
    }

    private func runShell(_ command: String, stdin: String) throws -> String {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
