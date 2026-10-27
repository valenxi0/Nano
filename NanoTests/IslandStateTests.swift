import AppKit
import Combine
import XCTest
import SQLite3
import SwiftUI
@testable import Nano

final class IslandStateTests: XCTestCase {
    @MainActor
    func testAgentSessionTitleDoesNotEscapeAvailableWidth() {
        let measurement = NanoLayoutMeasurement()
        let width: CGFloat = 320
        let host = NSHostingView(rootView:
            NanoLayoutProbe(measurement: measurement) {
                AgentSessionTitleLabel(title: String(repeating: "Long Nano session title ", count: 12))
            }
            .frame(width: width, height: 24)
        )
        host.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        host.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(measurement.size.width, width)
    }

    func testModuleRegistryCoversEveryModuleExactlyOnce() {
        XCTAssertEqual(NanoModuleRegistry.modules.count, NanoModuleID.allCases.count)
        XCTAssertEqual(Set(NanoModuleRegistry.modules.map(\.id)), Set(NanoModuleID.allCases))
        XCTAssertEqual(NanoModuleRegistry.defaultEnabled, [
            .calendar, .timer, .camera, .weather, .agents, .music, .cue,
            .battery, .bluetooth, .volume, .brightness, .tray,
        ])
        XCTAssertEqual(NanoModuleRegistry.primaryFeatures, [
            .music, .weather, .agents, .cue, .tray, .calendar, .timer,
        ])
    }

    func testModuleRegistryOwnsDashboardCompatibility() {
        XCTAssertEqual(DashboardArea.area1.compatibleModules, [
            .music, .weather, .agents, .cue, .tray, .calendar, .timer,
        ])
        XCTAssertTrue(DashboardArea.area3.compatibleModules.contains(.battery))
        XCTAssertTrue(DashboardArea.area3.compatibleModules.contains(.music))
        XCTAssertFalse(DashboardArea.area5.compatibleModules.contains(.music))
    }

    @MainActor
    func testSystemNotificationToggleKeepsSourceVisibleAndDrivesItsModule() {
        let suiteName = "NanoTests.notificationOwner.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)

        XCTAssertEqual(NanoModuleRegistry.module(for: .brightness), .brightness)
        XCTAssertTrue(settings.isNotificationSourceAvailable(.brightness))
        XCTAssertTrue(settings.isNotificationEnabled(.brightness))

        settings.setNotificationEnabled(false, for: .brightness)
        XCTAssertTrue(settings.isNotificationSourceAvailable(.brightness))
        XCTAssertFalse(settings.isNotificationEnabled(.brightness))
        XCTAssertFalse(settings.isEnabled(.brightness))

        settings.setNotificationEnabled(true, for: .brightness)
        XCTAssertTrue(settings.isEnabled(.brightness))
        XCTAssertTrue(settings.isNotificationEnabled(.brightness))
    }

    @MainActor
    func testDisabledFeatureModuleStillHidesItsNotificationSource() {
        let suiteName = "NanoTests.timerNotificationOwner.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)

        XCTAssertTrue(settings.isNotificationSourceAvailable(.timer))
        settings.setEnabled(false, for: .timer)
        XCTAssertFalse(settings.isNotificationSourceAvailable(.timer))
        XCTAssertFalse(settings.isNotificationEnabled(.timer))
    }

    @MainActor
    func testTimerNotificationMigrationEnablesOnceAndRespectsLaterOptOut() {
        let suiteName = "NanoTests.timerNotificationMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([IslandNotificationSource.agent.rawValue], forKey: "notifications.enabledSources")
        defaults.set(true, forKey: "notifications.focusAdded")

        let migrated = NanoSettings(defaults: defaults)
        XCTAssertEqual(NanoModuleRegistry.module(for: .timer), .timer)
        XCTAssertTrue(migrated.isNotificationEnabled(.timer))

        let reloadedAfterMigration = NanoSettings(defaults: defaults)
        XCTAssertTrue(reloadedAfterMigration.isNotificationEnabled(.timer))

        reloadedAfterMigration.setNotificationEnabled(false, for: .timer)
        let reloaded = NanoSettings(defaults: defaults)
        XCTAssertFalse(reloaded.isNotificationEnabled(.timer))
    }

    @MainActor
    func testCLIBatch1MigrationPersistsTokenProvidersAndRespectsOptOut() {
        let suiteName = "NanoTests.cliBatch1Migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // An install that predates the batch: the eight original providers
        // stored, no migration flag set.
        defaults.set(
            ["claude", "codex", "cursor", "gemini", "grok", "kimi", "opencode", "pi"],
            forKey: "agents.enabledProviders"
        )

        let batch: [AgentProviderID] = [.devin, .cline, .qwen, .kilo, .goose]
        let migrated = NanoSettings(defaults: defaults)
        for provider in batch {
            XCTAssertTrue(migrated.enabledAgentProviders.contains(provider))
        }
        // didSet cannot fire inside init; the migration must persist the set
        // itself or the flags outlive the values they unlocked.
        let stored = Set(defaults.stringArray(forKey: "agents.enabledProviders") ?? [])
        for provider in batch {
            XCTAssertTrue(stored.contains(provider.rawValue), "\(provider) was not persisted")
        }
        XCTAssertTrue(defaults.bool(forKey: "agents.trackCLIBatch1b"))

        // A second construction keeps them. Usage is on for the providers
        // that gained adapters (Devin, Cline, Kilo) and stays off for Qwen
        // Code and Goose, which publish no readable quota.
        let reloaded = NanoSettings(defaults: defaults)
        for provider in batch {
            XCTAssertTrue(reloaded.enabledAgentProviders.contains(provider))
        }
        for provider in [AgentProviderID.devin, .cline, .kilo] {
            XCTAssertTrue(reloaded.usageProviders.contains(provider))
        }
        for provider in [AgentProviderID.qwen, .goose] {
            XCTAssertFalse(reloaded.usageProviders.contains(provider))
        }

        // Turning one off after the flag is set must stick across launches.
        reloaded.setAgentProviderEnabled(false, provider: .cline)
        let afterOptOut = NanoSettings(defaults: defaults)
        XCTAssertFalse(afterOptOut.enabledAgentProviders.contains(.cline))
        XCTAssertTrue(afterOptOut.enabledAgentProviders.contains(.devin))
    }

    func testProviderRegistryUsesProviderSpecificDecisionFormats() throws {
        let claude = try XCTUnwrap(AgentProviderRegistry.adapter(for: .claude))
        let codex = try XCTUnwrap(AgentProviderRegistry.adapter(for: .codex))
        let openCode = try XCTUnwrap(AgentProviderRegistry.adapter(for: .opencode))
        let kimi = try XCTUnwrap(AgentProviderRegistry.adapter(for: .kimi))

        for adapter in [claude, codex] {
            let response = try XCTUnwrap(adapter.permissionResponse(allowed: true))
            let output = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
            let decision = try XCTUnwrap(output["decision"] as? [String: Any])
            XCTAssertEqual(decision["behavior"] as? String, "allow")
        }
        XCTAssertEqual(
            openCode.permissionResponse(allowed: false)?["permissionDecision"] as? String,
            "deny"
        )
        XCTAssertNil(kimi.permissionResponse(allowed: true))
        XCTAssertEqual(
            AgentProviderRegistry.adapter(source: "opencode", providerID: "kimi")?.provider,
            .opencode
        )
    }

    func testCodexAdapterIncludesCompletionHook() throws {
        let codex = try XCTUnwrap(AgentProviderRegistry.adapter(for: .codex))
        XCTAssertTrue(codex.hooks.contains { $0.event == "Stop" })
        XCTAssertTrue(codex.hooks.contains { $0.event == "UserPromptSubmit" })
    }

    func testShellBridgeDecodesFoundationJSONInsteadOfScrapingEscapedPaths() {
        XCTAssertTrue(
            AgentHookBridge.bridgeScript.contains("plutil -extract socketPath raw -o -")
        )
        XCTAssertTrue(
            AgentHookBridge.bridgeScript.contains("plutil -extract authToken raw -o -")
        )
        XCTAssertFalse(AgentHookBridge.bridgeScript.contains("sock=$(sed"))
        XCTAssertTrue(AgentHookBridge.bridgeScript.contains("${__CFBundleIdentifier:-}"))
    }

    func testDictationJoinsTheControlBarCentredUnderTheIsland() {
        let island = CGRect(x: 1000, y: 800, width: 700, height: 300)
        let plain = IslandChromeMetrics.layout(belowIsland: island)
        XCTAssertNil(plain.voice)
        XCTAssertEqual(plain.cluster.midX, island.midX, accuracy: 1)

        let live = IslandChromeMetrics.layout(belowIsland: island, showsVoice: true)
        let voice = try! XCTUnwrap(live.voice)
        XCTAssertEqual(voice.width, IslandChromeMetrics.voiceWidth)
        XCTAssertLessThan(voice.maxX, live.pill.minX)
        XCTAssertEqual(live.cluster.midX, island.midX, accuracy: 1)
        XCTAssertEqual(voice.minY, live.pill.minY)
    }

    func testClaudeActivityScanReadsOnlyAppendedBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoScan-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        func line(_ object: [String: Any]) -> String {
            String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
        }
        let finished = line(["type": "assistant", "message": ["stop_reason": "end_turn"]])
        // A multi-megabyte image line must not be decoded or break the scan.
        let image = line(["type": "attachment", "data": String(repeating: "A", count: 3_000_000)])
        try (finished + image).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(AgentStatusService.claudeTaskIsActive(in: url))

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(["type": "user", "message": ["content": "go"]]).utf8))
        try handle.close()
        XCTAssertTrue(AgentStatusService.claudeTaskIsActive(in: url))

        // Truncated or replaced: the cached offset is past the end, so rescan.
        try finished.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(AgentStatusService.claudeTaskIsActive(in: url))
    }

    func testCodexCodeModeProgramsShowTheirToolCalls() {
        let program = """
        const results = await Promise.allSettled([
        tools.exec_command({cmd:"git status --short","max_output_tokens":7000}),
        tools.exec_command({cmd:"cat \\"/tmp/a b.md\\"","max_output_tokens":8000}),
        tools.apply_patch("*** Begin Patch\\n*** Update File: /tmp/x/View.swift\\n@@")
        ]);
        """
        let calls = AgentSessionParsers.codexCodeModeCalls(program)
        XCTAssertEqual(calls.map(\.tool), ["exec_command", "exec_command", "apply_patch"])
        XCTAssertEqual(calls[0].input["cmd"] as? String, "git status --short")
        XCTAssertEqual(calls[1].input["cmd"] as? String, "cat \"/tmp/a b.md\"")
        XCTAssertEqual(calls[2].input["file_path"] as? String, "/tmp/x/View.swift")
    }

    func testPromptAndReplyTextIsCleaned() {
        XCTAssertEqual(AgentSessionPromptSummary.line("more issues we're having.&#x20;"), "more issues we're having.")
        XCTAssertEqual(AgentSessionPromptSummary.decodingEntities("a &amp;lt; b &#39;c&#39;"), "a &lt; b 'c'")
        XCTAssertEqual(
            AgentSessionPromptSummary.agentExcerpt("## Done\n\n**Fixed** the `jump`.\n```swift\nlet x = 1\n```\n- Tests pass"),
            "Done Fixed the jump. Tests pass"
        )
        XCTAssertNil(AgentSessionPromptSummary.agentExcerpt("```\ncode only\n```"))
    }

    @MainActor
    func testJumpHostFollowsTheAppThatLaunchedTheAgent() {
        XCTAssertEqual(AgentSessionJump.host(bundleID: "com.t3tools.t3code"), .t3)
        XCTAssertEqual(AgentSessionJump.host(bundleID: "com.anthropic.claudefordesktop"), .claude)
        XCTAssertEqual(AgentSessionJump.host(bundleID: "com.googlecode.iterm2"), .terminal)
        XCTAssertEqual(AgentSessionJump.host(bundleID: "dev.zed.Zed"), .app)

        // Only Claude Desktop's own sessions belong in Claude Desktop.
        XCTAssertEqual(AgentSessionJump.claudeHost(entrypoint: "claude-desktop", sessionID: "x"), .claude)
        XCTAssertEqual(AgentSessionJump.claudeHost(entrypoint: "cli", sessionID: "x"), .terminal)
        XCTAssertEqual(AgentSessionJump.codexHost(originator: "Codex Desktop"), .codex)
        XCTAssertEqual(AgentSessionJump.codexHost(originator: "t3code_desktop"), .t3)
        XCTAssertEqual(AgentSessionJump.codexHost(originator: "codex_cli_rs"), .terminal)

        // Cursor CLI chats cannot be opened by the Cursor app.
        let runtime = AgentSessionJump.Runtime(
            t3Running: false, cursorRunning: true, claudeRunning: false, codexRunning: false,
            t3Installed: false, cursorInstalled: true, claudeInstalled: false, codexInstalled: false,
            terminalRunning: true
        )
        XCTAssertEqual(AgentSessionJump.host(for: .cursorChat, runtime: runtime), .terminal)
        XCTAssertEqual(AgentSessionJump.host(for: .cursorIDE, runtime: runtime), .cursor)

        // T3 stores auto-truncated titles with a literal "..." and shows it.
        let t3Title = "Do you have access to the nano website or mobin m-..."
        let queries = AgentHostReveal.searchQueries(from: [t3Title], maximumLength: nil)
        XCTAssertTrue(AgentHostReveal.matches(t3Title, queries: queries, requiresExactTitle: true))
        XCTAssertFalse(AgentHostReveal.matches(
            "Nano-Website 1m Snooze thread \(t3Title) round-1", queries: queries, requiresExactTitle: true
        ))

        let store = AgentSessionStore()
        let now = Date()
        var state = AgentHookBridge.LiveSessionState(
            sessionID: "claude-in-zed",
            source: "claude",
            firstSeen: now,
            lastEventAt: now,
            isWorking: true
        )
        state.hostBundleID = "dev.zed.zed"
        state.lastUserPrompt = "Fix the build"
        store.applyHookState(["claude-in-zed": state], now: now, t3Runtime: AgentT3RuntimeIndex())
        let session = store.sessions.first { $0.id == "claude-in-zed" }
        XCTAssertEqual(session?.host, .app)
        XCTAssertEqual(session?.hostBundleID, "dev.zed.zed")
        XCTAssertEqual(session.map { AgentSessionJump.host(for: $0) }, .app)
    }

    func testClaudeStructuredQuestionUpdatesOriginalInput() throws {
        let claude = try XCTUnwrap(AgentProviderRegistry.adapter(for: .claude))
        let original: [String: Any] = ["questions": [["question": "Ship?", "options": []]]]
        let response = try XCTUnwrap(claude.questionResponse(
            originalInput: original,
            question: "Ship?",
            answer: "Yes"
        ))
        let output = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        let updated = try XCTUnwrap(output["updatedInput"] as? [String: Any])
        let answers = try XCTUnwrap(updated["answers"] as? [String: Any])
        XCTAssertEqual(answers["Ship?"] as? String, "Yes")
    }

    func testClaudeQuestionParserAcceptsOnlyOneSingleSelectQuestion() throws {
        let parsed = try XCTUnwrap(AgentHookBridge.singleSelectQuestion(from: [
            "questions": [[
                "question": "Which route?",
                "header": "Route",
                "multiSelect": false,
                "options": [["label": "A"], ["label": "B"]],
            ]],
        ]))
        XCTAssertEqual(parsed.question, "Which route?")
        XCTAssertEqual(parsed.header, "Route")
        XCTAssertEqual(parsed.options, ["A", "B"])

        XCTAssertNil(AgentHookBridge.singleSelectQuestion(from: [
            "questions": [[
                "question": "Pick several",
                "multiSelect": true,
                "options": [["label": "A"], ["label": "B"]],
            ]],
        ]))
    }

    func testUnanswerableClaudeQuestionStillSurfacesAsPassiveCard() {
        let request = AgentHookBridge.unanswerableQuestionRequest(
            input: ["questions": [
                ["question": "Which pages?", "multiSelect": true],
                ["question": "Ship now?"],
            ]],
            event: ["cwd": "/tmp/Site"],
            source: "claude",
            sessionID: "s1"
        )
        XCTAssertEqual(request.kind, .question)
        XCTAssertFalse(request.respondsThroughBridge)
        XCTAssertEqual(request.title, "Claude has 2 questions for you")
        XCTAssertEqual(request.detail, "Which pages?")
        XCTAssertEqual(request.sessionID, "s1")
    }

    func testBridgeReportsHookPIDsSoAbandonedPromptsRetract() {
        XCTAssertTrue(AgentHookBridge.bridgeScript.contains("\"hook_pids\":[%s,%s]"))
        XCTAssertTrue(AgentHookBridge.processIsAlive(getpid()))
        XCTAssertFalse(AgentHookBridge.processIsAlive(0))
        XCTAssertFalse(AgentHookBridge.processIsAlive(Int32.max))
    }

    func testHoverPollingSlowsOnlyWhenPointerIsAway() {
        XCTAssertGreaterThanOrEqual(NanoHoverCadence.openDelay, .milliseconds(100))
        XCTAssertLessThanOrEqual(NanoHoverCadence.openDelay, .milliseconds(250))
        XCTAssertEqual(
            NanoHoverCadence.interval(
                hoverEnabled: true,
                nearTop: false,
                pointerInside: false
            ),
            NanoHoverCadence.idle
        )
        XCTAssertEqual(
            NanoHoverCadence.interval(
                hoverEnabled: true,
                nearTop: true,
                pointerInside: false
            ),
            NanoHoverCadence.active
        )
        XCTAssertEqual(
            NanoHoverCadence.interval(
                hoverEnabled: false,
                nearTop: true,
                pointerInside: true
            ),
            NanoHoverCadence.hidden
        )
    }

    func testStreamingSessionWritesDebounceWithoutStarvingRefresh() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            AgentSessionRefreshCadence.fileDelay(burstStartedAt: start, now: start),
            AgentSessionRefreshCadence.fileTrailingDelay
        )
        XCTAssertEqual(
            AgentSessionRefreshCadence.fileDelay(
                burstStartedAt: start,
                now: start.addingTimeInterval(1.4)
            ),
            0.1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            AgentSessionRefreshCadence.fileDelay(
                burstStartedAt: start,
                now: start.addingTimeInterval(2)
            ),
            0
        )
        XCTAssertLessThan(
            AgentSessionRefreshCadence.discoveryDelay,
            AgentSessionRefreshCadence.fileTrailingDelay
        )
    }

    @MainActor
    func testHoverTrackingUsesIslandBoundsWithoutHalo() {
        let view = FirstMouseHostingView(rootView: EmptyView())
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 500)
        let rect = NSRect(x: 230, y: 456, width: 360, height: 44)
        view.islandHitPath = IslandHitGeometry.path(
            in: rect,
            placement: .floating,
            expanded: false
        )
        view.updateTrackingAreas()

        let islandAreas = view.trackingAreas.filter { area in
            (area.owner as AnyObject?) === view
                && area.options.contains(.mouseEnteredAndExited)
        }
        XCTAssertEqual(islandAreas.count, 1)
        XCTAssertTrue(islandAreas[0].options.contains(.activeAlways))
        XCTAssertTrue(islandAreas[0].options.contains(.mouseMoved))
        XCTAssertFalse(
            islandAreas[0].rect.contains(NSPoint(x: 224, y: 478)),
            "The old 6pt halo must not be part of the tracking rect"
        )
    }

    @MainActor
    func testHitTestIgnoresPointsOutsideTheDrawnIsland() {
        let view = FirstMouseHostingView(rootView: EmptyView())
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 500)
        let rect = NSRect(x: 230, y: 456, width: 360, height: 44)
        view.islandHitPath = IslandHitGeometry.path(
            in: rect,
            placement: .floating,
            expanded: false
        )

        XCTAssertNil(view.hitTest(NSPoint(x: 224, y: 478)))
        XCTAssertNil(view.hitTest(NSPoint(x: 180, y: 478)))
        XCTAssertNil(view.hitTest(NSPoint(x: 230, y: 456)))
    }

    func testIslandContextMenuIsOnlyForAnOpenDashboard() {
        XCTAssertTrue(IslandContextMenu.isAvailable(phase: .hoverDashboard))
        XCTAssertTrue(IslandContextMenu.isAvailable(phase: .pinnedDashboard))
        XCTAssertFalse(IslandContextMenu.isAvailable(phase: .idleCompact))
        XCTAssertFalse(IslandContextMenu.isAvailable(phase: .transientHUD))
    }

    @MainActor
    func testIslandContextMenuOffersSettingsAndQuit() {
        let titles = IslandContextMenuController.shared.makeMenu().items.map(\.title)
        XCTAssertEqual(titles, [
            IslandContextMenu.settingsTitle,
            "",
            IslandContextMenu.quitTitle,
        ])
    }

    @MainActor
    func testRightClickMenuIsOfferedOnlyOnTheDrawnIsland() {
        let view = FirstMouseHostingView(rootView: EmptyView())
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 500)
        let rect = NSRect(x: 230, y: 200, width: 360, height: 200)
        view.islandHitPath = IslandHitGeometry.path(
            in: rect,
            placement: .floating,
            expanded: true
        )
        view.onContextMenu = {
            IslandContextMenuController.shared.makeMenu()
        }

        let inside = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 410, y: 300),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        let outside = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        XCTAssertEqual(view.menu(for: inside)?.items.map(\.title).first, IslandContextMenu.settingsTitle)
        XCTAssertNil(view.menu(for: outside))
    }

    func testIslandContextMenuClaimsRightClicksOverDashboardContent() {
        let rightClick = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        let controlClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        let leftClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!

        XCTAssertTrue(IslandContextMenu.claimsEvent(rightClick))
        XCTAssertTrue(IslandContextMenu.claimsEvent(controlClick))
        XCTAssertFalse(IslandContextMenu.claimsEvent(leftClick))
        XCTAssertTrue(
            IslandContextMenu.shouldPresent(
                phase: .hoverDashboard,
                pointerOverIsland: true,
                event: rightClick
            )
        )
        XCTAssertFalse(
            IslandContextMenu.shouldPresent(
                phase: .hoverDashboard,
                pointerOverIsland: true,
                event: leftClick
            ),
            "Play, skip, and calendar days must keep their left-click"
        )
        XCTAssertFalse(
            IslandContextMenu.shouldPresent(
                phase: .idleCompact,
                pointerOverIsland: true,
                event: rightClick
            )
        )
    }

    func testFloatingIslandHitPathMatchesTheRoundedBody() {
        let rect = CGRect(x: 230, y: 456, width: 360, height: 44)

        XCTAssertTrue(
            IslandHitGeometry.contains(
                CGPoint(x: 410, y: 478),
                in: rect,
                placement: .floating,
                expanded: false
            )
        )
        XCTAssertFalse(
            IslandHitGeometry.contains(
                CGPoint(x: 224, y: 478),
                in: rect,
                placement: .floating,
                expanded: false
            ),
            "A point 6pt left of the island must not activate it"
        )
        XCTAssertFalse(
            IslandHitGeometry.contains(
                CGPoint(x: 180, y: 478),
                in: rect,
                placement: .floating,
                expanded: false
            )
        )
        XCTAssertFalse(
            IslandHitGeometry.contains(
                CGPoint(x: 232, y: 498),
                in: rect,
                placement: .floating,
                expanded: false
            ),
            "The top-left bounding-box corner is outside a continuous rounded rect"
        )
    }

    func testScreenSpaceIslandAtTheTopOfADisplayIsHoverable() {
        // Attached panel: island hangs from the top edge of a 1440pt-tall display.
        let rect = CGRect(x: 540, y: 1396, width: 360, height: 44)

        XCTAssertTrue(
            IslandHitGeometry.contains(
                CGPoint(x: 720, y: 1418),
                in: rect,
                placement: .attached,
                expanded: false
            )
        )
        XCTAssertFalse(
            IslandHitGeometry.contains(
                CGPoint(x: 520, y: 1418),
                in: rect,
                placement: .attached,
                expanded: false
            ),
            "The menu bar left of the notch must stay inert"
        )
    }

    func testNotchHitPathMatchesTheDrawnBodyNotTheMenuBar() {
        let rect = CGRect(x: 230, y: 456, width: 360, height: 44)

        XCTAssertTrue(
            IslandHitGeometry.contains(
                CGPoint(x: 410, y: 478),
                in: rect,
                placement: .attached,
                expanded: false
            )
        )
        XCTAssertTrue(
            IslandHitGeometry.contains(
                CGPoint(x: 250, y: 478),
                in: rect,
                placement: .attached,
                expanded: false
            ),
            "The hanging body just inside the left flare is the island"
        )
        XCTAssertTrue(
            IslandHitGeometry.contains(
                CGPoint(x: 410, y: 497),
                in: rect,
                placement: .attached,
                expanded: false
            ),
            "The top edge that meets the screen is part of the drawn notch"
        )
        XCTAssertFalse(
            IslandHitGeometry.contains(
                CGPoint(x: 232, y: 498),
                in: rect,
                placement: .attached,
                expanded: false
            ),
            "The empty top-left flare cutout is menu bar, not the island"
        )
        XCTAssertFalse(
            IslandHitGeometry.contains(
                CGPoint(x: 224, y: 478),
                in: rect,
                placement: .attached,
                expanded: false
            ),
            "The menu bar just left of the island must not activate it"
        )
        XCTAssertFalse(
            IslandHitGeometry.contains(
                CGPoint(x: 235, y: 470),
                in: rect,
                placement: .attached,
                expanded: false
            ),
            "The empty corner left of the hanging body is not the island"
        )
    }

    func testOpenIslandForgivesASmallSlipPastItsEdge() {
        let stayOpen = CGRect(x: 100, y: 500, width: 700, height: 300)
        let bounds = IslandChromeMetrics.exitBounds(stayOpen: stayOpen)
        XCTAssertTrue(bounds.contains(CGPoint(x: 90, y: 600)), "10 pt past the left edge still counts as inside")
        XCTAssertTrue(bounds.contains(CGPoint(x: 400, y: 480)), "20 pt below still counts as inside")
        XCTAssertFalse(bounds.contains(CGPoint(x: 400, y: 470)), "30 pt below has left")
    }

    func testAmbientMotionCapsEveryTimelineBelowDisplayRate() {
        XCTAssertEqual(
            NanoMotionBudget.ambient.interval(1.0 / 60, cost: .light),
            1.0 / 30,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            NanoMotionBudget.ambient.interval(1.0 / 60, cost: .heavy),
            1.0 / 30,
            accuracy: 0.000_001
        )
        XCTAssertEqual(NanoMotionBudget.ambient.interval(1.0 / 20, cost: .light), 1.0 / 20, accuracy: 0.000_001)
        XCTAssertEqual(NanoMotionBudget.hidden.interval(1.0 / 60), 1)
    }

    func testMediaPollingIsAdaptiveAndStopsWithoutAPlayer() {
        XCTAssertNil(MediaController.pollingInterval(hasRunningPlayer: false, isPlaying: false))
        XCTAssertEqual(
            MediaController.pollingInterval(hasRunningPlayer: true, isPlaying: true),
            5
        )
        XCTAssertEqual(
            MediaController.pollingInterval(hasRunningPlayer: true, isPlaying: false),
            30
        )
    }

    func testMediaClockRunsBetweenSamplesAndStopsAtTheEnd() {
        let sampled = Date(timeIntervalSince1970: 1_000)
        let playing = MediaNowPlaying(
            player: .spotify, title: "Apple Pie", artist: "Travis Scott",
            isPlaying: true, position: 67, duration: 218, sampledAt: sampled
        )
        XCTAssertEqual(playing.position(at: sampled.addingTimeInterval(3)), 70, accuracy: 0.001)
        XCTAssertEqual(playing.position(at: sampled.addingTimeInterval(500)), 218)
        XCTAssertEqual(playing.position(at: sampled.addingTimeInterval(-5)), 67)

        let paused = playing.with(isPlaying: false, at: sampled)
        XCTAssertEqual(paused.position(at: sampled.addingTimeInterval(30)), 67)
    }

    func testMediaSampleThatMatchesTheRunningClockIsNotNews() {
        let sampled = Date(timeIntervalSince1970: 1_000)
        let track = MediaNowPlaying(
            player: .spotify, title: "Apple Pie", artist: "Travis Scott",
            isPlaying: true, position: 67, duration: 218, sampledAt: sampled
        )
        let later = sampled.addingTimeInterval(5)
        XCTAssertTrue(track.isContinued(by: track.with(position: 72.4, at: later)))
        XCTAssertFalse(track.isContinued(by: track.with(position: 120, at: later)))
        XCTAssertFalse(track.isContinued(by: track.with(isPlaying: false, at: later)))
        let next = MediaNowPlaying(
            player: .spotify, title: "Power Trip", artist: "J. Cole, Miguel",
            isPlaying: true, position: 72, duration: 241, sampledAt: later
        )
        XCTAssertFalse(track.isContinued(by: next))
    }

    func testLastPlayedReadsAsRelativeTimeAndSurvivesARestart() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(MediaLastPlayed.ago(from: now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(MediaLastPlayed.ago(from: now.addingTimeInterval(-12 * 60), now: now), "12m ago")
        XCTAssertEqual(MediaLastPlayed.ago(from: now.addingTimeInterval(-2 * 3_600), now: now), "2h ago")
        XCTAssertEqual(MediaLastPlayed.ago(from: now.addingTimeInterval(-30 * 3_600), now: now), "yesterday")
        XCTAssertEqual(MediaLastPlayed.ago(from: now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")

        let last = MediaLastPlayed(player: .spotify, title: "Ron Artest", artist: "Babyface Ray", playedAt: now)
        let decoded = try JSONDecoder().decode(MediaLastPlayed.self, from: JSONEncoder().encode(last))
        XCTAssertEqual(decoded, last)
        XCTAssertEqual(decoded.trackID, "spotify|Ron Artest|Babyface Ray")
    }

    func testMediaParsingHandlesUnitsLocalesAndStoppedPlayers() {
        let spotify = MediaController.parseNowPlaying(
            "Apple Pie\u{001F}Travis Scott\u{001F}playing\u{001F}67,5\u{001F}218000",
            player: .spotify
        )
        XCTAssertEqual(spotify?.position, 67.5)
        XCTAssertEqual(spotify?.duration, 218)
        XCTAssertEqual(spotify?.isPlaying, true)

        let music = MediaController.parseNowPlaying(
            "Song\u{001F}Artist\u{001F}paused\u{001F}12.25\u{001F}180.5",
            player: .appleMusic
        )
        XCTAssertEqual(music?.duration, 180.5)
        XCTAssertEqual(music?.isPlaying, false)

        XCTAssertNil(MediaController.parseNowPlaying(
            "\u{001F}\u{001F}stopped\u{001F}0\u{001F}0",
            player: .spotify
        ))
        XCTAssertNil(MediaController.parseNowPlaying("garbage", player: .appleMusic))
    }

    func testCalendarCacheExpiresOnTTLDayBoundaryAndStoreChanges() {
        let calendar = Calendar(identifier: .gregorian)
        let loaded = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 13, hour: 10
        ))!
        let dayStart = calendar.startOfDay(for: loaded)

        XCTAssertFalse(CalendarService.shouldReload(
            lastLoadedAt: loaded,
            loadedDayStart: dayStart,
            now: loaded.addingTimeInterval(299),
            force: false
        ))
        XCTAssertTrue(CalendarService.shouldReload(
            lastLoadedAt: loaded,
            loadedDayStart: dayStart,
            now: loaded.addingTimeInterval(300),
            force: false
        ))
        XCTAssertTrue(CalendarService.shouldReload(
            lastLoadedAt: loaded,
            loadedDayStart: dayStart,
            now: calendar.date(byAdding: .day, value: 1, to: loaded)!,
            force: false
        ))
        XCTAssertTrue(CalendarService.shouldReload(
            lastLoadedAt: loaded,
            loadedDayStart: dayStart,
            now: loaded.addingTimeInterval(10),
            force: true
        ))
    }

    func testLedgerCatchUpUsesSmallerLowPowerBudgets() {
        let normal = TokenScanners.codexBudgets(lowPower: false)
        let lowPower = TokenScanners.codexBudgets(lowPower: true)

        XCTAssertEqual(normal.file, 32_000_000)
        XCTAssertEqual(normal.pass, 64_000_000)
        XCTAssertEqual(lowPower.file, 8_000_000)
        XCTAssertEqual(lowPower.pass, 16_000_000)
        XCTAssertLessThan(lowPower.file, normal.file)
        XCTAssertLessThan(lowPower.pass, normal.pass)
    }

    func testCompactGeometry() {
        XCTAssertEqual(IslandPhase.idleCompact.preferredSize.width, 360)
        XCTAssertEqual(IslandPhase.idleCompact.preferredSize.height, 44)
        XCTAssertFalse(IslandPhase.idleCompact.isExpanded)
    }

    func testCompactAgentActivityGroupsSessionsByProvider() throws {
        let now = Date()
        var codexOne = AgentSession(
            id: "codex-one",
            provider: .codex,
            projectName: "Nano",
            lastActivityAt: now
        )
        var codexTwo = AgentSession(
            id: "codex-two",
            provider: .codex,
            projectName: "Nano",
            lastActivityAt: now
        )
        var cursor = AgentSession(
            id: "cursor-one",
            provider: .cursor,
            projectName: "Nano",
            lastActivityAt: now
        )
        codexOne.isActive = true
        codexTwo.isActive = true
        cursor.isActive = true

        let summary = try XCTUnwrap(CompactAgentActivitySummary.make(
            snapshots: [],
            sessions: [cursor, codexTwo, codexOne],
            enabledProviders: [.codex, .cursor]
        ))

        XCTAssertEqual(summary.totalSessions, 3)
        XCTAssertEqual(summary.providers, [
            .init(provider: .codex, sessionCount: 2),
            .init(provider: .cursor, sessionCount: 1),
        ])
    }

    func testLastWorkingSessionSurvivesPeerCompletionWithIdleProviderSnapshot() throws {
        var working = AgentSession(id: "working", provider: .codex, projectName: "Nano", lastActivityAt: Date())
        working.isActive = true
        var finished = AgentSession(id: "finished", provider: .codex, projectName: "Other", lastActivityAt: Date())
        finished.finishedAt = Date()
        let stale = AgentProviderSnapshot(id: .codex, isConfigured: true, isActive: false,
                                         projectName: nil, lastActivityAt: nil, usage: [], usageMessage: nil)
        let single = CompactAgentActivitySummary.singleActiveSnapshot(
            snapshots: [stale], sessions: [finished, working], enabledProviders: [.codex]
        )
        XCTAssertEqual(single?.id, .codex)
        XCTAssertEqual(single?.isActive, true)
        working.isActive = false
        XCTAssertNil(CompactAgentActivitySummary.singleActiveSnapshot(
            snapshots: [stale], sessions: [finished, working], enabledProviders: [.codex]
        ))
    }

    func testCompactAgentActivityUsesProviderSnapshotAsFallback() throws {
        let snapshot = AgentProviderSnapshot(
            id: .grok,
            isConfigured: true,
            isActive: true,
            projectName: "Nano",
            lastActivityAt: Date(),
            usage: [],
            usageMessage: nil
        )

        let summary = try XCTUnwrap(CompactAgentActivitySummary.make(
            snapshots: [snapshot],
            sessions: [],
            enabledProviders: [.grok]
        ))

        XCTAssertEqual(summary.totalSessions, 1)
        XCTAssertEqual(summary.providers, [.init(provider: .grok, sessionCount: 1)])
        XCTAssertNil(CompactAgentActivitySummary.make(
            snapshots: [snapshot],
            sessions: [],
            enabledProviders: [.codex]
        ))
    }

    func testProviderRippleUsesRestrainedSequentialCadence() {
        XCTAssertEqual(NanoProviderRipple.duration, 2.04, accuracy: 0.001)
        XCTAssertEqual(NanoProviderRipple.itemOffset, 0.08, accuracy: 0.001)
        XCTAssertEqual(NanoProviderRipple.opacity.map(\.doubleValue), [0.72, 1, 0.72, 0.72])
        XCTAssertEqual(NanoProviderRipple.translationY.map(\.doubleValue), [0, -1.5, 0, 0])
        XCTAssertEqual(NanoProviderRipple.scale.map(\.doubleValue), [1, 1.03, 1, 1])

        let keyTimes = NanoProviderRipple.keyTimes.map(\.doubleValue)
        XCTAssertEqual(keyTimes[1] * NanoProviderRipple.duration, 0.25, accuracy: 0.001)
        XCTAssertEqual(keyTimes[2] * NanoProviderRipple.duration, 0.60, accuracy: 0.001)
        XCTAssertEqual(
            NanoProviderRipple.duration
                - (3 * NanoProviderRipple.itemOffset + 0.60),
            1.20,
            accuracy: 0.001
        )
    }

    func testMultiSessionActivityChipUsesAClosedRainbowSpectrum() throws {
        let spectrum = NanoActivityChipPalette.multiSession

        XCTAssertEqual(spectrum.count, 8)
        XCTAssertEqual(try XCTUnwrap(spectrum.first), try XCTUnwrap(spectrum.last))
        XCTAssertEqual(Set(spectrum.dropLast()).count, 7)
    }

    func testExpandedGeometryIsStableAcrossDashboardStates() {
        let expandedStates: [IslandPhase] = [.hoverDashboard, .pinnedDashboard, .dragTarget]
        for state in expandedStates {
            XCTAssertEqual(state.preferredSize.width, 760)
            XCTAssertEqual(state.preferredSize.height, 340)
            XCTAssertTrue(state.isExpanded)
            XCTAssertTrue(state.showsDashboard)
            XCTAssertTrue(state.showsChrome)
        }

        XCTAssertTrue(IslandPhase.transientHUD.isExpanded)
        XCTAssertFalse(IslandPhase.transientHUD.showsDashboard)
        XCTAssertFalse(IslandPhase.transientHUD.showsChrome)
        XCTAssertEqual(IslandPhase.transientHUD.preferredSize.width, 540)
        XCTAssertEqual(IslandPhase.transientHUD.preferredSize.height, 44)
    }

    @MainActor
    func testHoverOpensTheIslandWhenClickToOpenIsOff() async {
        let suiteName = "NanoTests.hoverOpen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)
        XCTAssertFalse(settings.clickToOpen)
        let viewModel = IslandViewModel(settings: settings)

        viewModel.pointerEntered()
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(viewModel.phase, .hoverDashboard)
    }

    @MainActor
    func testBriefPointerPassDoesNotOpenTheIsland() async {
        let suiteName = "NanoTests.briefHover.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.pointerEntered()
        try? await Task.sleep(for: .milliseconds(10))
        viewModel.pointerExited()
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(viewModel.phase, .idleCompact)
    }

    @MainActor
    func testClickToOpenLeavesTheIslandClosedOnHover() async {
        let suiteName = "NanoTests.clickToOpen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)
        settings.clickToOpen = true
        let viewModel = IslandViewModel(settings: settings)

        viewModel.pointerEntered()
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(viewModel.phase, .idleCompact)

        viewModel.togglePinnedDashboard()
        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
    }

    @MainActor
    func testDashboardAndModuleSizesDoNotIncludeDetachedChrome() {
        let suiteName = "NanoTests.bottomChrome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.togglePinnedDashboard()
        XCTAssertNil(viewModel.activeModule)
        XCTAssertEqual(viewModel.preferredSize.height, 300)

        viewModel.openModule(.cue)
        XCTAssertEqual(viewModel.preferredSize.height, 440)

        viewModel.openModule(.calendar)
        XCTAssertEqual(viewModel.preferredSize.height, 340)
    }

    @MainActor
    func testAgentProviderBreakdownDoesNotResizeIsland() {
        let suiteName = "NanoTests.agentProviderBreakdown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.openModule(.agents)
        let collapsed = viewModel.preferredSize.height
        viewModel.setAgentTokenBreakdownHeight(148)

        XCTAssertEqual(viewModel.preferredSize.height, collapsed)

        viewModel.setAgentTokenBreakdownHeight(0)
        XCTAssertEqual(viewModel.preferredSize.height, collapsed)
    }

    @MainActor
    func testLeavingAgentsClearsProviderBreakdownHeight() {
        let suiteName = "NanoTests.agentProviderBreakdownReset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.openModule(.agents)
        viewModel.setAgentTokenBreakdownHeight(148)
        viewModel.openModule(.cue)

        XCTAssertEqual(viewModel.agentTokenBreakdownHeight, 0)
    }

    func testChromePillSitsBelowTheIslandAsItsOwnHitTarget() {
        let island = CGRect(x: 30, y: 230, width: 760, height: 340)
        let chrome = IslandChromeMetrics.layout(belowIsland: island)

        XCTAssertEqual(chrome.pill.width, 128)
        XCTAssertEqual(chrome.pill.height, 44)
        XCTAssertEqual(chrome.utility.width, 88)
        XCTAssertEqual(chrome.utility.height, 44)
        XCTAssertEqual(chrome.cluster.maxY + IslandChromeMetrics.gap, island.minY, accuracy: 0.5)
        XCTAssertEqual(chrome.cluster.midX, island.midX, accuracy: 0.5)
        XCTAssertEqual(chrome.utility.minX, chrome.pill.maxX + IslandChromeMetrics.clusterGap, accuracy: 0.5)

        let pillCenter = CGPoint(x: chrome.pill.midX, y: chrome.pill.midY)
        let utilityCenter = CGPoint(x: chrome.utility.midX, y: chrome.utility.midY)
        XCTAssertTrue(
            IslandHitGeometry.chromePath(in: chrome.pill)
                .contains(pillCenter, using: .winding, transform: .identity)
        )
        XCTAssertTrue(
            IslandHitGeometry.chromePath(in: chrome.utility)
                .contains(utilityCenter, using: .winding, transform: .identity)
        )

        let gap = CGPoint(x: chrome.cluster.midX, y: chrome.cluster.maxY + IslandChromeMetrics.gap / 2)
        XCTAssertFalse(
            IslandHitGeometry.chromePath(in: chrome.pill)
                .contains(gap, using: .winding, transform: .identity)
        )
        XCTAssertFalse(
            IslandHitGeometry.contains(
                gap,
                in: island,
                placement: .floating,
                expanded: true
            )
        )
        XCTAssertTrue(
            IslandChromeMetrics.hoverBridge(islandRect: island, clusterRect: chrome.cluster)
                .contains(gap)
        )
        let sideGap = CGPoint(x: island.minX + 24, y: gap.y)
        XCTAssertTrue(
            IslandChromeMetrics.hoverBridge(islandRect: island, clusterRect: chrome.cluster)
                .contains(sideGap),
            "The corridor to the icons must be as wide as the dashboard"
        )
        XCTAssertTrue(
            IslandChromeMetrics.stayOpenBounds(islandRect: island, clusterRect: chrome.cluster)
                .contains(CGPoint(x: chrome.pill.midX, y: chrome.pill.midY))
        )
        XCTAssertTrue(
            IslandChromeMetrics.clusterBridge(pill: chrome.pill, utility: chrome.utility)
                .contains(CGPoint(x: chrome.pill.maxX + 4, y: chrome.pill.midY))
        )
    }

    func testStageLeavesRoomForTheChromePill() {
        XCTAssertEqual(IslandStage.size.width, 820)
        XCTAssertEqual(
            IslandStage.size.height,
            IslandStage.maxIslandHeight + IslandChromeMetrics.gap
                + IslandStage.maxDockedHeight + 16
        )
    }

    func testDisplayObstructionUsesReportedSafeGeometry() {
        let screen = CGRect(x: 1440, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 1440, y: 945, width: 704, height: 37)
        let right = CGRect(x: 2248, y: 945, width: 704, height: 37)

        let obstruction = NanoDisplayObstruction.measure(
            screenFrame: screen,
            safeAreaInsets: NSEdgeInsets(top: 37, left: 0, bottom: 0, right: 0),
            auxiliaryTopLeftArea: left,
            auxiliaryTopRightArea: right
        )

        XCTAssertEqual(obstruction.width, 104)
        XCTAssertEqual(obstruction.height, 37)
    }

    func testDisplayWithoutAuxiliaryAreasHasNoObstruction() {
        XCTAssertEqual(
            NanoDisplayObstruction.measure(
                screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                safeAreaInsets: NSEdgeInsets(),
                auxiliaryTopLeftArea: nil,
                auxiliaryTopRightArea: nil
            ),
            .none
        )
    }

    @MainActor
    func testNotchedDisplayReservesCompactWingsAndExpandedTopBand() {
        let suiteName = "NanoTests.notchGeometry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)
        settings.placement = .floating
        let viewModel = IslandViewModel(settings: settings)
        viewModel.notchWidth = 104
        viewModel.notchHeight = 37

        XCTAssertEqual(viewModel.preferredSize.width, 392)
        XCTAssertEqual(viewModel.compactSideZone, 132)

        viewModel.togglePinnedDashboard()
        XCTAssertEqual(viewModel.preferredSize.height, 337)
        XCTAssertEqual(viewModel.notchContentClearance, 37)

        viewModel.openModule(.calendar)
        XCTAssertEqual(viewModel.preferredSize.height, 377)
    }

    func testNotificationsReserveTheHardwareGapForEveryPlacement() {
        XCTAssertEqual(NanoNotificationCenterGap.width(notchWidth: 104, minimum: 88), 104)
        XCTAssertEqual(NanoNotificationCenterGap.width(notchWidth: 0, minimum: 88), 88)
        XCTAssertEqual(NanoNotificationCenterGap.width(notchWidth: 104, minimum: 72), 104)
    }

    @MainActor
    func testAgentActivityFlagCanBeSetAndCleared() {
        let suiteName = "NanoTests.agentActivity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.updateAgentActivity(true)
        XCTAssertTrue(viewModel.isAgentActive)

        viewModel.updateAgentActivity(false)
        XCTAssertFalse(viewModel.isAgentActive)
    }

    func testCodexActivityRequiresAnUnfinishedTaskLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("codex-session.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        try [
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call"}}"#,
        ].joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(AgentStatusService.codexTaskIsActive(in: fileURL))

        try [
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
        ].joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertFalse(AgentStatusService.codexTaskIsActive(in: fileURL))
    }

    func testCodexActivityIgnoresRecentlyTouchedIdleSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("codex-idle-session.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        try #"{"type":"event_msg","payload":{"type":"token_count"}}"#
            .write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertFalse(AgentStatusService.codexTaskIsActive(in: fileURL))
    }

    func testCodexTranscriptMarksTaskCompleteAsFinished() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCodexCompletion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sessionID = "01a05693-924c-7a82-a82b-2dec78dc6688"
        let transcript = directory.appendingPathComponent("rollout-\(sessionID).jsonl")
        try [
            #"{"timestamp":"2026-08-31T06:40:00.000Z","type":"session_meta","payload":{"id":"01a05693-924c-7a82-a82b-2dec78dc6688","cwd":"/tmp/Nano"}}"#,
            #"{"timestamp":"2026-08-31T06:40:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"Fix notifications"}}"#,
            #"{"timestamp":"2026-08-31T06:40:02.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-08-31T06:40:03.000Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Done"}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(
            AgentSessionParsers.parseTranscript(at: transcript, provider: .codex)
        )
        XCTAssertEqual(session.id, sessionID)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try XCTUnwrap(formatter.date(from: "2026-08-31T06:40:03.000Z"))
        XCTAssertEqual(session.finishedAt, expected)
    }

    @MainActor
    func testIncrementalTranscriptCompletionIsEmittedOnce() {
        let store = AgentSessionStore()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var working = AgentSession(
            id: "codex-live",
            provider: .codex,
            projectName: "Nano",
            lastActivityAt: startedAt
        )
        working.isActive = true

        var completedIDs: [String] = []
        store.didFinishSession = { completedIDs.append($0.id) }
        store.applyIncrementalSessions([working])
        XCTAssertTrue(completedIDs.isEmpty, "Discovering an existing transcript must not announce history")

        var finished = working
        finished.isActive = false
        finished.lastActivityAt = startedAt.addingTimeInterval(2)
        finished.finishedAt = finished.lastActivityAt
        store.applyIncrementalSessions([finished])
        store.applyIncrementalSessions([finished])

        XCTAssertEqual(completedIDs, ["codex-live"])
    }

    func testClaudeActivityEndsWithTerminalAssistantStopReason() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("claude-session.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        try [
            #"{"type":"user","message":{"role":"user"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}"#,
        ].joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertFalse(AgentStatusService.claudeTaskIsActive(in: fileURL))
    }

    @MainActor
    func testOpeningAndClosingLocalModulePinsDashboard() {
        let suiteName = "NanoTests.moduleRouting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.openModule(.cue)
        XCTAssertEqual(viewModel.activeModule, .cue)
        XCTAssertEqual(viewModel.phase, .pinnedDashboard)

        // Unpinned, closing a module hands the island back to hover: still
        // expanded, but free to collapse once the pointer leaves. Returning
        // `.pinnedDashboard` here would strand it open with the pin button off,
        // because `pointerExited()` only collapses from `.hoverDashboard`.
        viewModel.closeModule()
        XCTAssertNil(viewModel.activeModule)
        XCTAssertEqual(viewModel.phase, .hoverDashboard)
    }

    func testJumpReadsT3ThreadsFromItsNewDatabase() throws {
        // T3 stopped writing state.sqlite; threads now live in statev2.sqlite
        // beside it, keyed to the provider's session by nativeThreadRef.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoJumpV2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = folder.appendingPathComponent("state.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(folder.appendingPathComponent("statev2.sqlite").path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE orchestration_v2_projection_threads (
                thread_id TEXT PRIMARY KEY, title TEXT, deleted_at TEXT
            );
            CREATE TABLE orchestration_v2_projection_provider_threads (
                provider_thread_id TEXT PRIMARY KEY, thread_id TEXT, payload_json TEXT
            );
            INSERT INTO orchestration_v2_projection_threads (thread_id, title)
            VALUES ('thread-1', 'Stress Test Nano App');
            INSERT INTO orchestration_v2_projection_provider_threads (provider_thread_id, thread_id, payload_json)
            VALUES ('p1', 'thread-1', '{"nativeThreadRef":{"nativeId":"claude-session-1"}}');
            """, nil, nil, nil)
        sqlite3_close(db)

        XCTAssertEqual(AgentSessionJump.t3ThreadID(sessionID: "claude-session-1", databaseURL: legacy), "thread-1")
        XCTAssertEqual(AgentSessionJump.t3ResumeThreadID(sessionID: "claude-session-1", databaseURL: legacy), "thread-1")
        XCTAssertEqual(
            AgentSessionJump.t3ThreadTitle(threadID: "thread-1", databaseURL: legacy),
            "Stress Test Nano App"
        )
        XCTAssertNil(AgentSessionJump.t3ResumeThreadID(sessionID: "someone-else", databaseURL: legacy))
    }

    func testOnlyT3sSettledHeaderCountsAsTheCollapsedThreadsToggle() {
        XCTAssertTrue(AgentHostReveal.isCollapsedThreadsToggle("Settled (152)"))
        XCTAssertFalse(AgentHostReveal.isCollapsedThreadsToggle("Settle thread"))
        XCTAssertFalse(AgentHostReveal.isCollapsedThreadsToggle("Settled (152) threads about Nano"))
    }

    func testAJumpThatMissesTheSessionSaysSo() {
        XCTAssertNil(IslandViewModel.jumpNotice(for: .opened, hostTitle: "T3 Code"))
        XCTAssertEqual(
            IslandViewModel.jumpNotice(for: .hostActivated, hostTitle: "T3 Code"),
            "Opened T3 Code. Couldn't find this session there, so pick it from the list."
        )
    }

    func testHostChoresAndInjectedPromptsAreNotTheUsersWork() {
        var chore = AgentSession(id: "title", provider: .codex, projectName: "Nano", lastActivityAt: Date())
        chore.lastUserPrompt = "Generate a title that will help the user recognize this T3 Code thread weeks later."
        XCTAssertTrue(AgentSessionStore.isHostHousekeeping(chore))
        var real = AgentSession(id: "real", provider: .codex, projectName: "Nano", lastActivityAt: Date())
        real.lastUserPrompt = "Fix the island"
        XCTAssertFalse(AgentSessionStore.isHostHousekeeping(real))
        XCTAssertTrue(AgentSessionStore.isHostHousekeepingPrompt(
            "  Generate a title that will help the user recognize this T3 Code thread weeks later."
        ))

        XCTAssertTrue(AgentHookBridge.isHostInjectedPrompt("<task-notification>\n<task-id>1</task-id>"))
        XCTAssertTrue(AgentHookBridge.isHostInjectedPrompt("[SYSTEM NOTIFICATION - NOT USER INPUT]"))
        XCTAssertFalse(AgentHookBridge.isHostInjectedPrompt("Fix the island"))
    }

    func testUpdateVersionsCompareByNumberNotText() {
        XCTAssertTrue(NanoUpdateChecker.isVersion("0.10.0", newerThan: "0.9.2"))
        XCTAssertTrue(NanoUpdateChecker.isVersion("v0.1.1", newerThan: "0.1.0"))
        XCTAssertTrue(NanoUpdateChecker.isVersion("1.0", newerThan: "0.9.9"))
        XCTAssertFalse(NanoUpdateChecker.isVersion("0.1.0", newerThan: "0.1.0"))
        XCTAssertFalse(NanoUpdateChecker.isVersion("0.1", newerThan: "0.1.0"))
        XCTAssertFalse(NanoUpdateChecker.isVersion("0.1.0", newerThan: "0.2.0"))
    }

    func testBugReportLinkPrefillsVersions() throws {
        let components = try XCTUnwrap(URLComponents(url: NanoLinks.reportBug, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/\(NanoLinks.repository)/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["template"], "bug_report.yml")
        XCTAssertEqual(items["version"], "\(NanoAppInfo.version) (\(NanoAppInfo.build))")
        XCTAssertTrue(items["macos-version"]?.hasPrefix("macOS ") == true)
    }

    @MainActor
    func testUpdateCheckerReadsTheLatestGitHubRelease() async throws {
        let suiteName = "NanoTests.updates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubUpdateFeedProtocol.self]
        let checker = NanoUpdateChecker(settings: settings, defaults: defaults, session: URLSession(configuration: configuration))

        func check(_ status: Int, _ body: String) async -> NanoUpdateChecker.Status {
            StubUpdateFeedProtocol.response = (status, Data(body.utf8))
            checker.checkNow()
            for _ in 0..<200 where checker.status == .checking {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return checker.status
        }

        let newer = await check(200, """
        {"tag_name": "v99.0.0", "html_url": "https://github.com/valenxi0/Nano/releases/tag/v99.0.0",
         "body": "Faster tray\\n", "draft": false, "prerelease": false,
         "assets": [
           {"name": "latest.json", "browser_download_url": "https://github.com/valenxi0/Nano/releases/download/v99.0.0/latest.json"},
           {"name": "Nano-99.0.0.dmg", "browser_download_url": "https://github.com/valenxi0/Nano/releases/download/v99.0.0/Nano-99.0.0.dmg"}
         ]}
        """)
        guard case let .available(update) = newer else { return XCTFail("expected an update, got \(newer)") }
        XCTAssertEqual(update.version, "99.0.0")
        XCTAssertEqual(update.downloadURL.lastPathComponent, "Nano-99.0.0.dmg")
        XCTAssertEqual(update.pageURL.lastPathComponent, "v99.0.0")
        XCTAssertEqual(update.notes, "Faster tray")
        XCTAssertNotNil(checker.lastCheckedAt)

        let pageOnly = await check(200, """
        {"tag_name": "99.0.1", "html_url": "https://github.com/valenxi0/Nano/releases/tag/99.0.1", "body": "", "assets": []}
        """)
        guard case let .available(pageUpdate) = pageOnly else { return XCTFail("expected an update, got \(pageOnly)") }
        XCTAssertEqual(pageUpdate.downloadURL, pageUpdate.pageURL)
        XCTAssertNil(pageUpdate.notes)

        let older = await check(200, """
        {"tag_name": "v0.0.1", "html_url": "https://github.com/valenxi0/Nano/releases/tag/v0.0.1", "body": null, "assets": []}
        """)
        guard case .current = older else { return XCTFail("expected up to date, got \(older)") }

        let insecure = await check(200, """
        {"tag_name": "v99.0.0", "html_url": "http://example.com/release", "assets": []}
        """)
        guard case .failed = insecure else { return XCTFail("an http link is refused, got \(insecure)") }

        guard case .noReleases = await check(404, "{}") else { return XCTFail("404 means no feed yet") }
        guard case .failed = await check(200, "<html>") else { return XCTFail("a page that isn't the feed is a failure") }
        guard case .failed = await check(500, "{}") else { return XCTFail("500 is a failure") }
    }

    @MainActor
    func testUpdateCardShowsOncePerReleaseEvenWithNotificationsOff() {
        let suiteName = "NanoTests.updateCard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)
        settings.completeOnboarding()
        for source in IslandNotificationSource.allCases { settings.setNotificationEnabled(false, for: source) }
        let model = IslandViewModel(settings: settings)

        model.announceUpdateIfNew(.available(.preview))
        XCTAssertEqual(model.notificationCenter.current?.coalesceKey, IslandNotification.updateCoalesceKey)
        XCTAssertEqual(settings.announcedUpdateVersion, "1.0.1")

        model.notificationCenter.retainEnabledSources([])
        XCTAssertNotNil(model.notificationCenter.current, "turning sources off keeps Nano's own notice")

        model.dismissUpdateNotice()
        XCTAssertNil(model.notificationCenter.current)
        model.announceUpdateIfNew(.available(.preview))
        XCTAssertNil(model.notificationCenter.current, "the same release is announced once")
    }

    @MainActor
    func testUpdateCardWaitsForSetup() {
        let suiteName = "NanoTests.updateCardSetup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)
        let model = IslandViewModel(settings: settings)
        model.announceUpdateIfNew(.available(.preview))
        XCTAssertNil(model.notificationCenter.current)
        XCTAssertNil(settings.announcedUpdateVersion)
    }

    func testMeetingLinkIsFoundInURLLocationOrNotes() {
        let zoom = URL(string: "https://acme.zoom.us/j/123456")!
        XCTAssertEqual(NanoMeetingLink.find(url: zoom, location: nil, notes: nil), zoom)
        XCTAssertEqual(
            NanoMeetingLink.find(url: nil, location: "https://meet.google.com/abc-defg-hij", notes: nil)?.host,
            "meet.google.com"
        )
        XCTAssertEqual(
            NanoMeetingLink.find(url: URL(string: "https://example.com/agenda"), location: "Room 4",
                                 notes: "Agenda first.\nJoin: https://teams.microsoft.com/l/meetup-join/xyz")?.host,
            "teams.microsoft.com"
        )
        XCTAssertNil(NanoMeetingLink.find(url: URL(string: "https://example.com"), location: "Dr. Lee, Market St", notes: nil))
        XCTAssertFalse(NanoMeetingLink.isMeeting(URL(string: "https://notzoom.us.example.com")!))
    }

    func testEventCountsOnEveryDayItSpans() {
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 22))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 1))!
        let event = NanoCalendarEvent(id: "late", title: "Launch", startDate: start, endDate: end,
                                      isAllDay: false, calendarTitle: "Work", calendarColorHex: "#5B8CFF")
        XCTAssertTrue(event.overlaps(day: start))
        XCTAssertTrue(event.overlaps(day: end))
        XCTAssertFalse(event.overlaps(day: calendar.date(byAdding: .day, value: 2, to: start)!))
    }

    func testTimelineHoursFitTheDayAndLanesStackOverlaps() {
        let calendar = Calendar.current
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28))!
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: .minute, value: hour * 60 + minute, to: day)!
        }
        // An empty day is 9 to 5.
        XCTAssertEqual(NanoTimelineLayout.hourRange(events: [], day: day, now: nil, calendar: calendar), Array(9..<17))
        // Another day fits its events with an hour either side.
        let busy = NanoTimelineLayout.hourRange(
            events: [(at(6, 30), at(7)), (at(21), at(22, 15))], day: day, now: nil, calendar: calendar
        )
        XCTAssertEqual(busy.first, 5)
        XCTAssertEqual(busy.last, 23)
        // Today starts at the current hour and keeps at least six hours.
        let tonight = NanoTimelineLayout.hourRange(
            events: [(at(20, 15), at(20, 45))], day: day, now: at(19, 40), calendar: calendar
        )
        XCTAssertEqual(tonight, Array(18..<24))
        let spans = [(start: at(9), end: at(9, 30)), (start: at(11), end: at(12))]
        XCTAssertEqual(NanoTimelineLayout.nextStart(after: 0, in: spans, lanes: [0, 0]), at(11))

        let lanes = NanoTimelineLayout.lanes([(at(9), at(10)), (at(9, 30), at(10, 30)), (at(10), at(11))])
        XCTAssertEqual(lanes, [0, 1, 0])
    }

    @MainActor
    func testCalendarLayoutPersistsAndIsOfferedOnRightClick() {
        let suiteName = "NanoTests.calendarLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)
        XCTAssertEqual(settings.calendarLayout, .month)
        settings.calendarLayout = .week
        XCTAssertEqual(NanoSettings(defaults: defaults).calendarLayout, .week)

        let viewModel = IslandViewModel(settings: settings)
        let options = DashboardWidgetOptions.featureOptions(for: .calendar, settings: settings, viewModel: viewModel)
        let week = options.first { $0.title == "Week" }
        XCTAssertEqual(week.map { "\($0.kind)" }, "toggle(true)")
        options.first { $0.title == "Month" }?.perform()
        XCTAssertEqual(settings.calendarLayout, .month)
    }

    func testAllDayEventIsOnlyTodayOnItsDay() {
        // The labels format in the current time zone, so the dates are built in it too.
        let calendar = Calendar.current
        func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        let now = date(9, 28, 19, 30)

        // Columbus Day, two weeks out, is not today.
        let columbus = NanoEventTiming.countdown(start: date(10, 12), isAllDay: true, now: now, calendar: calendar)
        XCTAssertNotEqual(columbus, "Today")
        XCTAssertEqual(columbus, date(10, 12).formatted(.dateTime.month(.abbreviated).day()))
        XCTAssertEqual(NanoEventTiming.countdown(start: date(9, 28), isAllDay: true, now: now, calendar: calendar), "Today")
        XCTAssertEqual(NanoEventTiming.countdown(start: date(9, 29), isAllDay: true, now: now, calendar: calendar), "Tomorrow")
        XCTAssertEqual(
            NanoEventTiming.countdown(start: date(10, 1), isAllDay: true, now: now, calendar: calendar),
            date(10, 1).formatted(.dateTime.weekday(.abbreviated))
        )

        XCTAssertEqual(NanoEventTiming.countdown(start: date(9, 28, 19, 50), isAllDay: false, now: now, calendar: calendar), "in 20m")
        XCTAssertEqual(NanoEventTiming.countdown(start: date(9, 28, 22, 0), isAllDay: false, now: now, calendar: calendar), "in 2h")
        XCTAssertEqual(NanoEventTiming.countdown(start: date(9, 28, 19, 0), isAllDay: false, now: now, calendar: calendar), "Now")

        // Rows further down say which day, not only "All day".
        XCTAssertEqual(NanoEventTiming.listLine(start: date(9, 28), isAllDay: true, now: now, calendar: calendar), "All day")
        XCTAssertTrue(NanoEventTiming.listLine(start: date(10, 31), isAllDay: true, now: now, calendar: calendar).hasSuffix(" · All day"))
    }

    func testQuestionCardGrowsWithALongQuestion() {
        func question(_ title: String, options: [String]) -> IslandAgentAttention {
            IslandAgentAttention(AgentHookBridge.PendingRequest(
                id: UUID().uuidString,
                source: "claude",
                kind: .question,
                title: title,
                detail: "Database",
                options: options.enumerated().map { AgentHookBridge.Option(id: $0.offset, label: $0.element) },
                sessionID: nil,
                receivedAt: Date()
            ))
        }
        let long = question(
            "Which database should the new billing service use for invoices, receipts and refunds? (The existing Postgres cluster is shared with analytics, so it may be busy.)",
            options: ["A new Postgres database (Recommended)", "Reuse the shared cluster", "SQLite on each server", "Decide later, don't create"]
        )
        XCTAssertTrue(long.respondsThroughBridge)
        XCTAssertGreaterThan(long.cardHeight, 126 + 4 * 40, "a two-line question needs more than the old fixed height")
        XCTAssertEqual(long.cardHeight, long.measuredCardHeight)

        // Rendered in the test host, even this left the header touching the top edge at 206.
        let short = question("Pick one", options: ["A", "B"])
        XCTAssertEqual(short.cardHeight, short.measuredCardHeight)
        XCTAssertLessThan(short.cardHeight, long.cardHeight)
    }

    @MainActor
    func testNotificationWaitsForAFileDragToFinish() {
        let suiteName = "NanoTests.trayDrag.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)
        settings.setEnabled(true, for: .tray)
        let viewModel = IslandViewModel(settings: settings, trayStorageURL: nil)

        viewModel.beginFileDrag()
        XCTAssertEqual(viewModel.phase, .dragTarget)
        XCTAssertEqual(viewModel.activeModule, .tray)

        viewModel.presentAgentAttention(AgentHookBridge.PendingRequest(
            id: "mid-drag",
            source: "claude",
            kind: .permission,
            title: "Bash",
            detail: "ls",
            options: [AgentHookBridge.Option(id: 1, label: "Allow Once")],
            sessionID: nil,
            receivedAt: Date()
        ))
        XCTAssertEqual(viewModel.phase, .dragTarget, "a card must not pull the tray out from under a drag")

        viewModel.endFileDrag()
        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertNil(viewModel.activeModule)
    }

    @MainActor
    func testTogglingDashboardDuringHUDOpensIt() {
        let suiteName = "NanoTests.hudToggle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.togglePinnedDashboard()
        XCTAssertEqual(viewModel.phase, .pinnedDashboard)

        // Small HUDs dock below an open dashboard now; an agent card still
        // takes the island, which is what this regression test needs.
        viewModel.presentAgentAttention(AgentHookBridge.PendingRequest(
            id: "ask-hud",
            source: "claude",
            kind: .permission,
            title: "Bash",
            detail: "ls",
            options: [
                AgentHookBridge.Option(id: 0, label: "Deny"),
                AgentHookBridge.Option(id: 1, label: "Allow Once"),
            ],
            sessionID: nil,
            receivedAt: Date()
        ))
        XCTAssertEqual(viewModel.phase, .transientHUD)

        viewModel.togglePinnedDashboard()
        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
        XCTAssertNil(viewModel.notificationCenter.current)
    }

    @MainActor
    func testSmallHUDDocksBelowOpenDashboard() {
        let suiteName = "NanoTests.dockedHUD.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.togglePinnedDashboard()
        viewModel.routeNotification(.volume(level: 0.5, muted: false))

        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
        XCTAssertEqual(viewModel.dockedNotification?.source, .volume)
    }

    @MainActor
    func testSmallHUDStillTakesTheIslandWhenIdle() {
        let suiteName = "NanoTests.idleHUD.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.routeNotification(.volume(level: 0.5, muted: false))

        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertNil(viewModel.dockedNotification)
    }

    @MainActor
    func testAgentAttentionStillPreemptsOpenDashboard() {
        let suiteName = "NanoTests.agentHUD.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.togglePinnedDashboard()
        viewModel.presentAgentAttention(AgentHookBridge.PendingRequest(
            id: "ask-1",
            source: "claude",
            kind: .permission,
            title: "Bash",
            detail: "ls",
            options: [
                AgentHookBridge.Option(id: 0, label: "Deny"),
                AgentHookBridge.Option(id: 1, label: "Allow Once"),
            ],
            sessionID: nil,
            receivedAt: Date()
        ))

        XCTAssertEqual(viewModel.phase, .transientHUD)
        XCTAssertEqual(viewModel.notificationCenter.current?.source, .agent)
    }

    @MainActor
    func testQueuedSmallHUDDocksAfterAgentCardDismisses() {
        let suiteName = "NanoTests.queuedHUD.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.togglePinnedDashboard()
        viewModel.presentAgentAttention(AgentHookBridge.PendingRequest(
            id: "ask-2",
            source: "claude",
            kind: .permission,
            title: "Bash",
            detail: "ls",
            options: [
                AgentHookBridge.Option(id: 0, label: "Deny"),
                AgentHookBridge.Option(id: 1, label: "Allow Once"),
            ],
            sessionID: nil,
            receivedAt: Date()
        ))
        XCTAssertEqual(viewModel.phase, .transientHUD)

        viewModel.routeNotification(.volume(level: 0.5, muted: false))
        viewModel.notificationCenter.dismissCurrent()

        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
        XCTAssertEqual(viewModel.dockedNotification?.source, .volume)
    }

    func testDockedHUDRectSitsCenteredBelowIsland() {
        let islandRect = CGRect(x: 100, y: 300, width: 760, height: 340)
        let rect = IslandChromeMetrics.dockedRect(
            belowIsland: islandRect,
            size: CGSize(width: 440, height: 56)
        )

        XCTAssertEqual(rect.midX, 480)
        XCTAssertEqual(rect.maxY, 300 - 10)
    }

    func testDockedHUDMatchesIslandWidth() {
        let size = IslandChromeMetrics.dockedSize(
            for: .volume(level: 0.5, muted: false),
            islandWidth: 720
        )
        XCTAssertEqual(size.width, 720)
    }

    @MainActor
    func testClosingModuleWhilePinnedStaysPinned() {
        let suiteName = "NanoTests.moduleRoutingPinned.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let viewModel = IslandViewModel(settings: NanoSettings(defaults: defaults))

        viewModel.togglePin()
        XCTAssertTrue(viewModel.isPinned)

        viewModel.openModule(.cue)
        viewModel.closeModule()

        // The pin is the one thing that outranks hover, so it survives a module.
        XCTAssertEqual(viewModel.phase, .pinnedDashboard)
    }

    @MainActor
    func testTimerSelectPauseAndReset() {
        let store = FocusTimerStore()

        store.startFocus(minutes: 50)
        XCTAssertEqual(store.mode, .focus)
        XCTAssertEqual(store.state, .running)
        XCTAssertEqual(store.configuredDuration, 50 * 60)

        store.pause()
        XCTAssertEqual(store.state, .paused)
        XCTAssertLessThanOrEqual(store.remaining, 50 * 60)

        store.reset()
        XCTAssertEqual(store.state, .idle)
        XCTAssertEqual(store.remaining, 50 * 60)
    }

    @MainActor
    func testTimerSessionSurvivesQuittingNano() {
        let suiteName = "NanoTests.timer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let start = Date()

        let first = FocusTimerStore(defaults: defaults, now: start)
        first.sessionName = "Nano!"
        first.addTask("Fix calendar bug")
        first.addTask("Push to GitHub")
        first.setDuration(seconds: 191 * 60)
        first.startOrResume()
        first.completeCurrentTask()
        let end = try! XCTUnwrap(first.endsAt)

        // Reopened 40 minutes later: still running, same end, goals kept.
        let reopened = FocusTimerStore(defaults: defaults, now: start.addingTimeInterval(40 * 60))
        XCTAssertEqual(reopened.state, .running)
        XCTAssertEqual(reopened.sessionName, "Nano!")
        XCTAssertEqual(reopened.endsAt, end)
        XCTAssertEqual(reopened.nextTask?.title, "Push to GitHub")
        XCTAssertEqual(reopened.elapsed, 40 * 60, accuracy: 2)
        reopened.pause()

        // A paused session keeps its remaining time.
        let paused = FocusTimerStore(defaults: defaults, now: start.addingTimeInterval(5 * 3600))
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.remaining, reopened.remaining, accuracy: 1)
        paused.startOrResume()

        // One that ran out while Nano was closed comes back finished.
        let later = FocusTimerStore(defaults: defaults, now: Date().addingTimeInterval(5 * 3600))
        XCTAssertEqual(later.state, .completed)
        XCTAssertEqual(later.remaining, 0)
        paused.reset()
        later.reset()

        // Without a store to save to, nothing is kept.
        XCTAssertEqual(FocusTimerStore().state, .idle)
    }

    @MainActor
    func testTimerFinishEarlyAndGoalDone() {
        let store = FocusTimerStore()
        store.addTask("One")
        store.addTask("Two")
        store.startOrResume()
        store.completeCurrentTask()
        XCTAssertEqual(store.nextTask?.title, "Two")
        store.completeCurrentTask()
        XCTAssertNil(store.nextTask)

        store.finishEarly()
        XCTAssertEqual(store.state, .completed)
        XCTAssertEqual(store.completedFocusSessions, 1)
        XCTAssertNil(store.endsAt)
        store.startOrResume()
        XCTAssertEqual(store.remaining, store.configuredDuration)
    }

    @MainActor
    func testTrayCompressesToAZipItHoldsAndClearDeletes() async throws {
        XCTAssertEqual(TrayStore.zipName(for: [URL(fileURLWithPath: "/a/Report.pdf")]), "Report.zip")
        XCTAssertEqual(
            TrayStore.zipName(for: ["Swans.png", "Lyre.png", "Notes"].map { URL(fileURLWithPath: "/x/\($0)") }),
            "Swans and 2 more.zip"
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NanoZipTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one")
        let two = root.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: two.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        let first = one.appendingPathComponent("Swans.txt")
        let second = two.appendingPathComponent("Folder")
        try "swans".write(to: first, atomically: true, encoding: .utf8)
        try "inside".write(to: second.appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)

        let store = TrayStore(storageURL: root.appendingPathComponent("Tray/items.json"))
        store.add([first, second])
        store.selection = Set(store.items.map(\.id))
        store.compressToZip(store.selectedURLs)
        XCTAssertTrue(store.isCompressing)
        for _ in 0..<500 where store.isCompressing {
            try await Task.sleep(for: .milliseconds(10))
        }

        let zip = try XCTUnwrap(store.items.last?.url)
        XCTAssertEqual(zip.lastPathComponent, "Swans and 1 more.zip")
        XCTAssertEqual(zip.deletingLastPathComponent().path, store.clippingsDirectory.standardizedFileURL.path)
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-Z1", zip.path]
        let pipe = Pipe()
        listing.standardOutput = pipe
        try listing.run()
        listing.waitUntilExit()
        let entries = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(entries.contains("Swans.txt"))
        XCTAssertTrue(entries.contains("Folder/inner.txt"), "folders keep their contents: \(entries)")
        // The originals stay put.
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))

        store.clear()
        store.commitDiscard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    @MainActor
    func testEscapeCancelsAShortcutCaptureAndClosesTheIsland() {
        let suiteName = "NanoTests.escape.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)
        settings.setEnabled(true, for: .cue)
        settings.cuePullsSelection = false
        let viewModel = IslandViewModel(settings: settings, trayStorageURL: nil)

        // Opened by the shortcut: Escape discards the cue and closes, whatever has focus.
        viewModel.quickCaptureCue()
        XCTAssertNotNil(viewModel.cueStore.draft)
        XCTAssertTrue(viewModel.phase.isExpanded)
        XCTAssertTrue(viewModel.handleEscape(textIsEditing: false))
        XCTAssertNil(viewModel.cueStore.draft)
        XCTAssertFalse(viewModel.phase.isExpanded)

        // Started from the Cue view's own button: Escape cancels and stays on Cue.
        viewModel.openModule(.cue)
        viewModel.beginCueCapture()
        XCTAssertTrue(viewModel.handleEscape(textIsEditing: true))
        XCTAssertNil(viewModel.cueStore.draft)
        XCTAssertEqual(viewModel.activeModule, .cue)

        // A field being edited keeps its own Escape; otherwise the island closes.
        XCTAssertFalse(viewModel.handleEscape(textIsEditing: true))
        XCTAssertTrue(viewModel.handleEscape(textIsEditing: false))
        XCTAssertFalse(viewModel.phase.isExpanded)
    }

    @MainActor
    func testRightClickOnAViewWithItsOwnMenuShowsThatMenu() async throws {
        let root = HStack(spacing: 0) {
            Button("Todo App") {}.buttonStyle(.plain).frame(width: 100, height: 100)
                .contextMenu { Button("Rename") {}; Button("Delete Folder") {} }
            Color.black.frame(width: 100, height: 100)
        }
        let size = NSSize(width: 200, height: 100)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = FirstMouseHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.islandHitPath = CGPath(rect: host.bounds, transform: nil)
        host.onContextMenu = {
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings…", action: nil, keyEquivalent: "")
            return menu
        }
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))

        func titles(atX x: CGFloat) -> [String] {
            let event = NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: x, y: 50), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            return host.menu(for: event)?.items.map(\.title) ?? []
        }
        XCTAssertEqual(titles(atX: 50), ["Rename", "Delete Folder"])
        XCTAssertEqual(titles(atX: 150), ["Settings…"])
    }

    @MainActor
    func testTrayShelfFitsWhatItHolds() {
        // Dragging in: only room for Hold and AirDrop.
        XCTAssertEqual(IslandViewModel.traySize(itemCount: 3, isDropping: true), CGSize(width: 300, height: 100))
        // Empty: one short line.
        XCTAssertEqual(IslandViewModel.traySize(itemCount: 0, isDropping: false).height, 84)
        // Grows with each item, never past the island's widest.
        let one = IslandViewModel.traySize(itemCount: 1, isDropping: false).width
        let four = IslandViewModel.traySize(itemCount: 4, isDropping: false).width
        XCTAssertEqual(four - IslandViewModel.traySize(itemCount: 3, isDropping: false).width,
                       IslandViewModel.trayItemWidth + IslandViewModel.trayItemSpacing)
        XCTAssertGreaterThanOrEqual(one, 300)
        XCTAssertEqual(IslandViewModel.traySize(itemCount: 40, isDropping: false).width, IslandViewModel.trayMaxWidth)
    }

    @MainActor
    func testTimerSupportsCustomDuration() {
        let store = FocusTimerStore()
        store.setDuration(seconds: 90)
        XCTAssertEqual(store.configuredDuration, 90)
        XCTAssertEqual(store.remaining, 90)
        XCTAssertEqual(store.formattedRemaining, "01:30")
    }

    @MainActor
    func testTrayDeduplicatesAndNeverMovesOriginal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sample.txt")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("sample".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TrayStore()
        XCTAssertEqual(store.add([fileURL, fileURL]), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testTrayClippingsAreFilesTheTrayOwns() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = directory.appendingPathComponent("tray/items.json")
        let original = directory.appendingPathComponent("original.txt")
        try Data("mine".utf8).write(to: original)

        let store = TrayStore(storageURL: storage)
        let clippings = store.clippingsDirectory
        let text = try XCTUnwrap(TrayStore.writeText("Buy milk\nand eggs", into: clippings))
        XCTAssertEqual(text.lastPathComponent, "Buy milk.txt")
        XCTAssertEqual(try String(contentsOf: text, encoding: .utf8), "Buy milk\nand eggs")

        let link = try XCTUnwrap(TrayStore.writeLink(URL(string: "https://example.com/a")!, into: clippings))
        XCTAssertEqual(link.lastPathComponent, "example.com.webloc")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: link))
        XCTAssertEqual(plist["URL"] as? String, "https://example.com/a")
        let again = try XCTUnwrap(TrayStore.writeLink(URL(string: "https://example.com/b")!, into: clippings))
        XCTAssertEqual(again.lastPathComponent, "example.com 2.webloc")

        XCTAssertEqual(store.add([original, text, link, again]), 4)

        // Dragged out: gone from the tray, file kept for the receiver, swept next launch.
        store.remove(urls: [again])
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.path))
        _ = TrayStore(storageURL: storage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.path))

        // Drops: a file stays the original; a pasted-in address becomes a link.
        let photo = directory.appendingPathComponent("photo.jpg")
        try Data("jpeg".utf8).write(to: photo)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NanoTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([photo as NSURL])
        XCTAssertTrue(store.accept(pasteboard))
        XCTAssertTrue(store.items.contains { $0.url == photo.standardizedFileURL })
        pasteboard.clearContents()
        pasteboard.setString("https://nano.app/docs", forType: .string)
        XCTAssertTrue(store.accept(pasteboard))
        XCTAssertTrue(store.items.contains { $0.name == "nano.app.webloc" })

        // Cleared: clippings deleted, the user's own file untouched.
        let reloaded = TrayStore(storageURL: storage)
        XCTAssertEqual(reloaded.items.count, 5)
        reloaded.clear()
        reloaded.commitDiscard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    @MainActor
    func testTrayRemembersHeldFilesAndDropsOnesThatMoved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = directory.appendingPathComponent("kept.txt")
        let moved = directory.appendingPathComponent("moved.txt")
        try Data("a".utf8).write(to: kept)
        try Data("b".utf8).write(to: moved)
        let storage = directory.appendingPathComponent("tray/items.json")

        let first = TrayStore(storageURL: storage)
        XCTAssertEqual(first.add([kept, moved]), 2)

        try FileManager.default.removeItem(at: moved)
        let second = TrayStore(storageURL: storage)
        XCTAssertEqual(second.items.map(\.name), ["kept.txt"])

        second.clear()
        XCTAssertTrue(TrayStore(storageURL: storage).items.isEmpty)
    }

    @MainActor
    func testSettingsPersistModulesProvidersAndWeatherLocation() {
        let suiteName = "NanoTests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NanoSettings(defaults: defaults)
        XCTAssertFalse(settings.clickToOpen)
        settings.clickToOpen = true
        settings.setEnabled(true, for: .agents)
        settings.setAgentProviderEnabled(true, provider: .cursor)
        settings.setWeatherLocation(
            name: "Test City",
            latitude: 34.05,
            longitude: -118.24
        )
        let restored = NanoSettings(defaults: defaults)
        XCTAssertTrue(restored.clickToOpen)
        XCTAssertTrue(restored.isEnabled(.agents))
        XCTAssertTrue(restored.isAgentProviderEnabled(.cursor))
        XCTAssertTrue(restored.weatherHasLocation)
        XCTAssertEqual(restored.weatherLocationName, "Test City")
        XCTAssertEqual(restored.weatherLatitude, 34.05)
        XCTAssertEqual(restored.weatherLongitude, -118.24)
        XCTAssertFalse(restored.weatherUsesCurrentLocation)
    }

    @MainActor
    func testGeneralFeatureCatalogControlsSidebarAndHUDAvailability() {
        let suiteName = "NanoTests.featureAvailability.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NanoSettings(defaults: defaults)
        XCTAssertEqual(NanoModuleID.primaryFeatures, [
            .music, .weather, .agents, .cue, .tray, .calendar, .timer,
        ])
        XCTAssertTrue(SettingsDestination.available(settings: settings).contains(.agents))
        XCTAssertEqual(settings.visibleDashboardFeature(in: .area4), .agents)

        settings.setEnabled(false, for: .agents)

        XCTAssertFalse(SettingsDestination.available(settings: settings).contains(.agents))
        XCTAssertNil(settings.visibleDashboardFeature(in: .area4))
        XCTAssertEqual(
            settings.dashboardFeature(in: .area4),
            .agents,
            "Turning a feature back on should restore its previous HUD placement"
        )

        settings.setEnabled(true, for: .agents)
        XCTAssertEqual(settings.visibleDashboardFeature(in: .area4), .agents)
    }

    @MainActor
    func testSettingsWindowUsesSidebarTitlebarChrome() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowChrome.size),
            styleMask: SettingsWindowChrome.styleMask,
            backing: .buffered,
            defer: false
        )
        SettingsWindowChrome.apply(window)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertFalse(window.isOpaque)
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.standardWindowButton(.closeButton)?.isEnabled ?? false)
        XCTAssertTrue(window.standardWindowButton(.miniaturizeButton)?.isEnabled ?? false)
        XCTAssertFalse(window.standardWindowButton(.zoomButton)?.isEnabled ?? true)
    }

    @MainActor
    func testSettingsHostingViewPassesTrafficLightHitsThrough() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowChrome.size),
            styleMask: SettingsWindowChrome.styleMask,
            backing: .buffered,
            defer: false
        )
        let hosting = SettingsHostingView(
            rootView: Color.red.frame(width: SettingsWindowChrome.size.width, height: SettingsWindowChrome.size.height)
        )
        window.contentView = hosting
        SettingsWindowChrome.apply(window)
        window.layoutIfNeeded()

        guard let close = window.standardWindowButton(.closeButton) else {
            return XCTFail("Settings window should have a close button")
        }
        let point = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: hosting)
        XCTAssertNil(hosting.hitTest(point))
    }

    @MainActor
    func testRestoringHUDLayoutDoesNotTurnDisabledFeaturesBackOn() {
        let suiteName = "NanoTests.disabledHUDDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NanoSettings(defaults: defaults)
        settings.setEnabled(false, for: .music)
        settings.setDashboardFeature(.cue, in: .area1)

        settings.resetDashboardLayout()

        XCTAssertFalse(settings.isEnabled(.music))
        XCTAssertEqual(settings.dashboardFeature(in: .area1), .music)
        XCTAssertNil(settings.visibleDashboardFeature(in: .area1))
    }

    func testDockIconPolicyCoversSettingsAndTemporaryPrompts() {
        XCTAssertFalse(NanoActivationPolicyController.shouldShowDockIcon(
            settingsVisible: false,
            temporaryRequestCount: 0
        ))
        XCTAssertTrue(NanoActivationPolicyController.shouldShowDockIcon(
            settingsVisible: true,
            temporaryRequestCount: 0
        ))
        XCTAssertTrue(NanoActivationPolicyController.shouldShowDockIcon(
            settingsVisible: false,
            temporaryRequestCount: 1
        ))
    }

    @MainActor
    func testRememberedCurrentWeatherLocationKeepsCurrentLocationMode() {
        let suiteName = "NanoTests.weather-remember.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NanoSettings(defaults: defaults)
        XCTAssertTrue(settings.weatherUsesCurrentLocation)
        settings.rememberCurrentWeatherLocation(
            name: "Pasadena",
            latitude: 34.15,
            longitude: -118.14
        )
        XCTAssertTrue(settings.weatherUsesCurrentLocation)
        XCTAssertTrue(settings.weatherHasLocation)

        let restored = NanoSettings(defaults: defaults)
        XCTAssertTrue(restored.weatherUsesCurrentLocation)
        XCTAssertTrue(restored.weatherHasLocation)
        XCTAssertEqual(restored.weatherLocationName, "Pasadena")
        XCTAssertEqual(restored.weatherLatitude, 34.15)
        XCTAssertEqual(restored.weatherLongitude, -118.14)
    }

    @MainActor
    func testWeatherRefreshDoesNotPromptAutomatically() {
        XCTAssertEqual(
            WeatherRefreshAction.plan(
                usesCurrentLocation: true,
                hasSavedLocation: false,
                canUseCurrentLocation: false,
                promptForLocation: false
            ),
            .wait
        )
        XCTAssertEqual(
            WeatherRefreshAction.plan(
                usesCurrentLocation: true,
                hasSavedLocation: true,
                canUseCurrentLocation: false,
                promptForLocation: false
            ),
            .useSavedLocation
        )
        XCTAssertEqual(
            WeatherRefreshAction.plan(
                usesCurrentLocation: true,
                hasSavedLocation: false,
                canUseCurrentLocation: false,
                promptForLocation: true
            ),
            .requestCurrentLocation(promptIfNeeded: true)
        )
        XCTAssertEqual(
            WeatherRefreshAction.plan(
                usesCurrentLocation: true,
                hasSavedLocation: true,
                canUseCurrentLocation: true,
                promptForLocation: false
            ),
            .requestCurrentLocation(promptIfNeeded: false)
        )
        XCTAssertEqual(
            WeatherRefreshAction.plan(
                usesCurrentLocation: false,
                hasSavedLocation: true,
                canUseCurrentLocation: false,
                promptForLocation: false
            ),
            .useSavedLocation
        )
        XCTAssertEqual(
            WeatherRefreshAction.plan(
                usesCurrentLocation: false,
                hasSavedLocation: false,
                canUseCurrentLocation: false,
                promptForLocation: true
            ),
            .wait
        )
    }

    func testAutomationStatusIgnoresAppsThatAreNotRunning() {
        // Screenshot: Music/Spotify/Cursor "open app to check", T3 "not granted" → Check.
        XCTAssertEqual(
            NanoAutomationPermission.aggregate([.unknown, .unknown, .unknown, .needsGrant]),
            .needsGrant
        )
        XCTAssertEqual(
            NanoAutomationPermission.aggregate([.unknown, .unknown, .unknown, .granted]),
            .granted
        )
        XCTAssertEqual(
            NanoAutomationPermission.aggregate([.unknown, .unknown]),
            .needsGrant
        )
        XCTAssertEqual(
            NanoAutomationPermission.aggregate([.granted, .needsGrant, .unknown]),
            .partial
        )
        XCTAssertEqual(
            NanoAutomationPermission.aggregate([.granted, .granted]),
            .granted
        )
        XCTAssertEqual(
            NanoAutomationPermission.aggregate([.needsGrant, .needsGrant]),
            .needsGrant
        )
    }

    func testAutomationPermissionStateMapsAppleEventCodes() {
        XCTAssertEqual(NanoAutomationPermission.permissionState(for: noErr), .granted)
        XCTAssertEqual(
            NanoAutomationPermission.permissionState(for: OSStatus(errAEEventNotPermitted)),
            .needsGrant
        )
        XCTAssertEqual(
            NanoAutomationPermission.permissionState(for: OSStatus(errAEEventWouldRequireUserConsent)),
            .needsGrant
        )
        XCTAssertEqual(
            NanoAutomationPermission.permissionState(for: OSStatus(procNotFound)),
            .unknown
        )
    }

    func testCurrentLocationAuthorizationMatchesMacStatus() {
        XCTAssertTrue(NanoWeatherService.allowsCurrentLocation(.authorizedAlways))
        XCTAssertTrue(NanoWeatherService.allowsCurrentLocation(.authorized))
        XCTAssertFalse(NanoWeatherService.allowsCurrentLocation(.denied))
        XCTAssertFalse(NanoWeatherService.allowsCurrentLocation(.restricted))
        XCTAssertFalse(NanoWeatherService.allowsCurrentLocation(.notDetermined))
    }

    func testPrivacySettingsURLsReachModernPanes() {
        let location = NanoPrivacySettings.urls(for: "Privacy_LocationServices").map(\.absoluteString)
        XCTAssertEqual(
            location.first,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices"
        )
        XCTAssertFalse(
            location.contains { $0.contains("Location-Settings") },
            "Tahoe has no Location-Settings.extension; opening it swallows Grant before the real Privacy pane."
        )
        let automation = NanoPrivacySettings.urls(for: "Privacy_Automation").map(\.absoluteString)
        XCTAssertEqual(
            automation.first,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation"
        )
    }

    func testContactsGrantRequestsWhenUndetermined() {
        XCTAssertEqual(NanoContactsPermission.grantAction(status: .notDetermined), .request)
        XCTAssertEqual(NanoContactsPermission.grantAction(status: .denied), .openSettings)
        XCTAssertEqual(NanoContactsPermission.grantAction(status: .restricted), .openSettings)
        XCTAssertEqual(NanoContactsPermission.grantAction(status: .authorized), .openSettings)
    }

    func testHardenedRuntimeEntitlementsAllowContacts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for name in ["Nano/NanoLocal.entitlements", "Nano/Nano.entitlements"] {
            let url = root.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            let plist = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            )
            XCTAssertEqual(
                plist["com.apple.security.personal-information.addressbook"] as? Bool,
                true,
                "\(name) must allow Contacts under the hardened runtime or Grant never registers Nano in Settings"
            )
        }
    }

    func testLocationGrantAlwaysRequestsWhenUndetermined() {
        XCTAssertEqual(
            NanoLocationPermission.grantAction(status: .notDetermined, servicesEnabled: false),
            .requestAndOpenSettings
        )
        XCTAssertEqual(
            NanoLocationPermission.grantAction(status: .notDetermined, servicesEnabled: true),
            .requestAndOpenSettings
        )
        XCTAssertEqual(
            NanoLocationPermission.grantAction(status: .denied, servicesEnabled: true),
            .openSettings
        )
        XCTAssertEqual(
            NanoLocationPermission.grantAction(status: .restricted, servicesEnabled: true),
            .openSettings
        )
        XCTAssertEqual(
            NanoLocationPermission.grantAction(status: .authorizedAlways, servicesEnabled: true),
            .openSettings
        )
    }

    @MainActor
    func testUsageDisplayModePersistsAndCalculatesBothDirections() {
        let suiteName = "NanoTests.usageDisplay.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let window = NanoUsageWindow(
            id: "test", label: "5h", usedPercent: 72, resetsAt: nil,
            resetAfterSeconds: nil
        )
        let settings = NanoSettings(defaults: defaults)
        XCTAssertEqual(settings.usageDisplayMode, .used)
        XCTAssertEqual(settings.usageDisplayMode.percent(for: window), 72)

        settings.usageDisplayMode = .remaining
        let restored = NanoSettings(defaults: defaults)
        XCTAssertEqual(restored.usageDisplayMode, .remaining)
        XCTAssertEqual(restored.usageDisplayMode.percent(for: window), 28)
        XCTAssertEqual(
            restored.usageDisplayMode.accessibilityDescription(for: window),
            "5h 28 percent remaining"
        )
    }

    @MainActor
    func testProposedSixAreaDashboardIsTheDefault() {
        let suiteName = "NanoTests.dashboardDefault.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NanoSettings(defaults: defaults)

        XCTAssertEqual(settings.dashboardFeature(in: .area1), .music)
        XCTAssertEqual(settings.dashboardFeature(in: .area2), .calendar)
        XCTAssertEqual(settings.dashboardFeature(in: .area3), .weather)
        XCTAssertEqual(settings.dashboardFeature(in: .area4), .agents)
        XCTAssertEqual(settings.dashboardFeature(in: .area5), .camera)
        XCTAssertEqual(settings.dashboardFeature(in: .area6), .timer)
    }

    @MainActor
    func testDashboardAreaAssignmentsPersistAndEnforceCompatibility() {
        let suiteName = "NanoTests.dashboardAreas.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NanoSettings(defaults: defaults)
        settings.setDashboardFeature(.cue, in: .area1)
        settings.setDashboardFeature(.music, in: .area5)
        settings.setDashboardFeature(nil, in: .area4)

        let restored = NanoSettings(defaults: defaults)
        XCTAssertEqual(restored.dashboardFeature(in: .area1), .cue)
        XCTAssertEqual(restored.dashboardFeature(in: .area5), .camera)
        XCTAssertNil(restored.dashboardFeature(in: .area4))
    }

    @MainActor
    func testDashboardFeatureDragMovesSwapsAndRejectsInvalidDrops() {
        let suiteName = "NanoTests.dashboardDrag.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NanoSettings(defaults: defaults)

        XCTAssertTrue(settings.moveDashboardFeature(.music, from: .area1, to: .area2))
        XCTAssertEqual(settings.dashboardFeature(in: .area1), .calendar)
        XCTAssertEqual(settings.dashboardFeature(in: .area2), .music)

        XCTAssertTrue(settings.moveDashboardFeature(.timer, from: .area6, to: .area1))
        XCTAssertNil(settings.dashboardFeature(in: .area6))
        XCTAssertEqual(settings.dashboardFeature(in: .area1), .timer)

        XCTAssertFalse(settings.moveDashboardFeature(.cue, from: nil, to: .area5))
        XCTAssertEqual(settings.dashboardFeature(in: .area5), .camera)

        settings.setEnabled(false, for: .weather)
        XCTAssertFalse(settings.moveDashboardFeature(.weather, from: .area3, to: .area5))
        XCTAssertEqual(settings.dashboardFeature(in: .area3), .weather)
    }

    func testDashboardSlotsAllowCalendarAndTimerStripsAndExplainRefusals() {
        XCTAssertTrue(DashboardArea.area3.compatibleModules.contains(.calendar))
        XCTAssertTrue(DashboardArea.area4.compatibleModules.contains(.timer))
        XCTAssertEqual(NanoModuleRegistry.slots(for: .music), [.wide, .medium, .strip])
        XCTAssertNil(NanoModuleRegistry.unfitReason(for: .music, in: .wide))
        XCTAssertNotNil(NanoModuleRegistry.unfitReason(for: .music, in: .quick))
        XCTAssertNotNil(NanoModuleRegistry.unfitReason(for: .battery, in: .quick))
        for module in NanoModuleID.allCases {
            for slot in DashboardSlot.allCases where !NanoModuleRegistry.slots(for: module).contains(slot) {
                XCTAssertFalse(NanoModuleRegistry.unfitReason(for: module, in: slot)?.isEmpty ?? true)
            }
        }
    }

    @MainActor
    func testDashboardDisplacedFeatureMovesToAnEmptySlotThatFits() {
        let suiteName = "NanoTests.dashboardRehome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)

        // Free a strip slot, then push Calendar out of Medium with Timer.
        settings.setDashboardFeature(nil, in: .area4)
        XCTAssertTrue(settings.moveDashboardFeature(.timer, from: .area6, to: .area2))
        XCTAssertEqual(settings.dashboardFeature(in: .area2), .timer)
        XCTAssertEqual(settings.dashboardFeature(in: .area4), .calendar)
        XCTAssertNil(settings.dashboardFeature(in: .area6))
    }

    @MainActor
    func testBreakIsOfferedAfterASessionAndSizedToIt() {
        XCTAssertEqual(FocusTimerStore.breakLength(after: 25 * 60), 5 * 60)
        XCTAssertEqual(FocusTimerStore.breakLength(after: 60 * 60), 10 * 60)
        XCTAssertEqual(FocusTimerStore.breakLength(after: 191 * 60), 15 * 60)

        let store = FocusTimerStore()
        store.addTask("Push to GitHub")
        store.setDuration(seconds: 60 * 60)
        store.startOrResume()

        // No break while the session runs; one is offered when it ends.
        store.startBreak()
        XCTAssertEqual(store.mode, .focus)
        store.finishEarly()
        store.startBreak()
        XCTAssertEqual(store.mode, .rest)
        XCTAssertEqual(store.state, .running)
        XCTAssertEqual(store.configuredDuration, 10 * 60)

        // Back to it: the same session, goals kept.
        store.backToWork()
        XCTAssertEqual(store.mode, .focus)
        XCTAssertEqual(store.state, .running)
        XCTAssertEqual(store.configuredDuration, 60 * 60)
        XCTAssertEqual(store.nextTask?.title, "Push to GitHub")

        // Keep going: fifteen more minutes of the finished session.
        store.finishEarly()
        store.keepGoing()
        XCTAssertEqual(store.state, .running)
        XCTAssertEqual(store.remaining, 15 * 60, accuracy: 1)

        // Done after a break returns to a blank session of the same length.
        store.finishEarly()
        store.startBreak()
        store.clearSession()
        XCTAssertEqual(store.mode, .focus)
        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.tasks.isEmpty)
        XCTAssertEqual(store.configuredDuration, 60 * 60)
    }

    func testEmptyDashboardSlotsCollapseIntoTheirNeighbours() {
        let width: CGFloat = 704
        let full = Set(DashboardArea.allCases)
        XCTAssertEqual(DashboardLayout.contentHeight(filled: full), 272)
        XCTAssertEqual(DashboardLayout.placements(width: width, filled: full)[.area2]?.slot, .medium)

        // Wide alone spans the row and the empty bottom row collapses.
        let wideOnly = DashboardLayout.placements(width: width, filled: [.area1])
        XCTAssertEqual(wideOnly[.area1]?.frame.width, width)
        XCTAssertEqual(DashboardLayout.contentHeight(filled: [.area1]), 210)

        // Medium alone takes the row with its Wide layout.
        XCTAssertEqual(DashboardLayout.placements(width: width, filled: [.area2, .area3])[.area2]?.slot, .wide)

        // Only the bottom row: a short bar.
        XCTAssertEqual(DashboardLayout.contentHeight(filled: [.area3, .area5]), 54)
        XCTAssertEqual(DashboardLayout.placements(width: width, filled: [.area3, .area5])[.area3]?.frame.minY, 0)

        // One strip takes the strip column; one quick action takes the quick column and widens.
        let mixed = DashboardLayout.placements(width: width, filled: [.area1, .area2, .area4, .area6])
        XCTAssertEqual(mixed[.area4]?.frame.width, mixed[.area1]?.frame.width)
        XCTAssertEqual(mixed[.area6]?.widensQuick, true)

        // A strip alone on the bottom row (Music under the top row) spans it all.
        XCTAssertEqual(DashboardLayout.placements(width: width, filled: [.area1, .area3])[.area3]?.frame.width, width)

        // Quick actions alone share the whole row.
        let quicks = DashboardLayout.placements(width: width, filled: [.area5, .area6])
        XCTAssertEqual(quicks[.area5]?.frame.width, (width - 8) / 2)
        XCTAssertNil(quicks[.area1])

        XCTAssertEqual(DashboardLayout.contentHeight(filled: []), DashboardLayout.emptyHeight)
    }

    @MainActor
    func testIslandHeightFollowsTheFilledDashboardRows() {
        let suiteName = "NanoTests.collapse.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)
        let viewModel = IslandViewModel(settings: settings)
        viewModel.togglePinnedDashboard()
        let fullHeight = viewModel.preferredSize.height

        for area in [DashboardArea.area3, .area4, .area5, .area6] {
            settings.setDashboardFeature(nil, in: area)
        }
        XCTAssertEqual(viewModel.preferredSize.height, fullHeight - 62)
    }

    func testUsagePillShowsResetOnceAWindowIsPastHalf() {
        let quiet = NanoUsageWindow(id: "claude.5h", label: "5h", usedPercent: 40, resetsAt: nil, resetAfterSeconds: 3_600)
        XCTAssertNil(AgentUsagePill.pressingReset([quiet]))

        let busy = NanoUsageWindow(id: "claude.5h", label: "5h", usedPercent: 72, resetsAt: nil, resetAfterSeconds: 4_320)
        let week = NanoUsageWindow(id: "claude.7d", label: "7d", usedPercent: 55, resetsAt: nil, resetAfterSeconds: 300_000)
        let pressing = AgentUsagePill.pressingReset([week, busy])
        XCTAssertEqual(pressing?.0.id, "claude.5h", "the window closest to its limit wins")
        XCTAssertEqual(pressing?.1, "1h12m")
    }

    @MainActor
    func testPlanSummaryReadsTitleAndTopLevelSteps() {
        let plan = AgentPlanSummary.parse("""
        # Add a **reset** countdown

        1. Add `pressingReset` to the pill
           - nested detail stays with its step
        2. Show the countdown past 50%
        - Test it
        """)
        XCTAssertEqual(plan.title, "Add a reset countdown")
        XCTAssertEqual(plan.steps, ["Add pressingReset to the pill", "Show the countdown past 50%", "Test it"])

        let prose = AgentPlanSummary.parse("Refactor the store.\nThen update the tests.")
        XCTAssertNil(prose.title)
        XCTAssertEqual(prose.steps.count, 2, "a plan without a list falls back to its lines")

        XCTAssertEqual(
            AgentHookBridge.preview(tool: "ExitPlanMode", input: ["plan": "1. Do it"]),
            .plan("1. Do it")
        )
    }

    @MainActor
    func testSettingsSearchFindsIndividualSettings() {
        let settings = NanoSettings(defaults: UserDefaults(suiteName: "nano-search-\(UUID().uuidString)")!)
        let results = SettingsSearchItem.search("gradient", settings: settings)
        XCTAssertEqual(results.first?.title, "Gradient midpoint")
        XCTAssertEqual(results.first?.destination, .island)
        XCTAssertEqual(results.first?.anchor, "island.midpoint")
        XCTAssertTrue(SettingsSearchItem.search("wallpaper", settings: settings).contains { $0.title == "Surface opacity" },
                      "help text matches too")
        XCTAssertTrue(SettingsSearchItem.search("", settings: settings).isEmpty)

        settings.setEnabled(false, for: .cue)
        XCTAssertFalse(SettingsSearchItem.search("cue", settings: settings).contains { $0.destination == .cue },
                       "hidden pages aren't offered")
    }

    @MainActor
    func testNewAgentCheckRecordsFirstAndOnlyAnnouncesLaterArrivals() {
        let suite = "nano-agents-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NanoSettings(defaults: defaults)
        settings.completeOnboarding()
        settings.setEnabled(true, for: .agents)
        let viewModel = IslandViewModel(settings: settings)

        XCTAssertNil(settings.knownAgentInstallations)
        viewModel.checkForNewAgents()
        XCTAssertNotNil(settings.knownAgentInstallations, "the first look only records what's there")
        XCTAssertNil(viewModel.notificationCenter.current)

        settings.knownAgentInstallations = []
        viewModel.checkForNewAgents()
        XCTAssertEqual(settings.knownAgentInstallations, Set(AgentHookBridge.installationProviders(
            [.claude, .codex, .gemini, .cursor, .kimi, .pi, .grok, .opencode, .devin]
        )), "every agent found is remembered, so each is offered at most once")
    }

    @MainActor
    func testCalendarFilterAndWidgetOptions() {
        let settings = NanoSettings(defaults: UserDefaults(suiteName: "nano-cal-\(UUID().uuidString)")!)
        let viewModel = IslandViewModel(settings: settings)
        let event = NanoCalendarEvent(id: "1", title: "Standup", startDate: Date(), endDate: Date().addingTimeInterval(900),
                                      isAllDay: false, calendarTitle: "Work", calendarColorHex: "#5e8bff")
        let allDay = NanoCalendarEvent(id: "2", title: "Holiday", startDate: Date(), endDate: Date().addingTimeInterval(86_400),
                                       isAllDay: true, calendarTitle: "Holidays", calendarColorHex: "#34c759")
        XCTAssertTrue(settings.showsOnDashboard(event))
        settings.hiddenCalendars = ["Work"]
        XCTAssertFalse(settings.showsOnDashboard(event))
        settings.calendarShowsAllDay = false
        XCTAssertFalse(settings.showsOnDashboard(allDay))

        let options = DashboardWidgetOptions.sections(for: .agents, in: .area4, settings: settings, viewModel: viewModel)
        let remove = options.flatMap { $0 }.first { $0.title == "Remove from Dashboard" }
        XCTAssertNotNil(remove)
        remove?.perform()
        XCTAssertNil(settings.dashboardFeature(in: .area4))

        let music = DashboardWidgetOptions.featureOptions(for: .music, settings: settings, viewModel: viewModel)
        music.first { $0.title == "Spotify" }?.perform()
        XCTAssertEqual(settings.preferredMediaPlayer, .spotify)
    }

    @MainActor
    func testHUDAppearanceColorsPersist() {
        let suiteName = "NanoTests.hudColors.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = NanoSettings(defaults: defaults)
        settings.surfaceColor = NanoColorValue(red: 0.12, green: 0.23, blue: 0.34)
        settings.glassTintColor = NanoColorValue(red: 0.45, green: 0.56, blue: 0.67)

        let restored = NanoSettings(defaults: defaults)
        XCTAssertEqual(restored.surfaceColor.red, 0.12, accuracy: 0.0001)
        XCTAssertEqual(restored.surfaceColor.green, 0.23, accuracy: 0.0001)
        XCTAssertEqual(restored.surfaceColor.blue, 0.34, accuracy: 0.0001)
        XCTAssertEqual(restored.glassTintColor.red, 0.45, accuracy: 0.0001)
        XCTAssertEqual(restored.glassTintColor.green, 0.56, accuracy: 0.0001)
        XCTAssertEqual(restored.glassTintColor.blue, 0.67, accuracy: 0.0001)
    }

    /// Plan ids arrive as slugs and differ per provider. The label tidies them
    /// into words without renaming the tier.
    func testPlanLabelTidiesProviderSlugs() {
        // OpenAI sells Free, Go, Plus, Pro, Business; Pro's 5x tier reports as
        // `prolite`, which names nothing on its pricing page.
        XCTAssertEqual(AgentModuleView.planLabel("prolite", provider: .codex), "Pro 5x")
        XCTAssertEqual(AgentModuleView.planLabel("plus", provider: .codex), "Plus")

        // Entry tiers carry no label: Cursor's Hobby and Kimi's Adagio are the
        // free ones, and Go sits below Plus.
        XCTAssertNil(AgentModuleView.planLabel("go", provider: .codex))
        XCTAssertNil(AgentModuleView.planLabel("free", provider: .codex))
        XCTAssertNil(AgentModuleView.planLabel("free", provider: .cursor))
        XCTAssertNil(AgentModuleView.planLabel("hobby", provider: .cursor))
        XCTAssertNil(AgentModuleView.planLabel("adagio", provider: .kimi))
        XCTAssertNil(AgentModuleView.planLabel("LEVEL_ADAGIO", provider: .kimi))

        // Cursor calls its paid tiers Pro+, Ultra and Teams.
        XCTAssertEqual(AgentModuleView.planLabel("pro-plus", provider: .cursor), "Pro+")
        XCTAssertEqual(AgentModuleView.planLabel("business", provider: .cursor), "Teams")
        XCTAssertEqual(AgentModuleView.planLabel("ultra", provider: .cursor), "Ultra")

        // Kimi's tempo names need no translation, only tidying.
        XCTAssertEqual(AgentModuleView.planLabel("LEVEL_ALLEGRO", provider: .kimi), "Allegro")
        XCTAssertEqual(AgentModuleView.planLabel("moderato", provider: .kimi), "Moderato")

        XCTAssertEqual(AgentModuleView.planLabel("team_plan", provider: .codex), "Team Plan")
        // Claude reports no plan, and neither does a provider still loading.
        XCTAssertNil(AgentModuleView.planLabel(nil, provider: .claude))
        XCTAssertNil(AgentModuleView.planLabel("   ", provider: .claude))
    }

    func testCodexSessionDetailNormalizesPromptToolsModelContextAndPlan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCodexDetail-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("codex-detail.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let lines = [
            #"{"timestamp":"2026-08-12T10:00:00.000Z","type":"session_meta","payload":{"cwd":"/tmp/Nano","context_window":200000}}"#,
            #"{"timestamp":"2026-08-12T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
            #"{"timestamp":"2026-08-12T10:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"Bring Codex details to parity"}}"#,
            #"{"timestamp":"2026-08-12T10:00:03.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"xcodebuild test"}}"#,
            #"{"timestamp":"2026-08-12T10:00:04.000Z","type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"Parse Codex tools\",\"status\":\"completed\"}]}"}}"#,
            #"{"timestamp":"2026-08-12T10:00:04.500Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","arguments":"{\"task_name\":\"provider_hook_review\",\"message\":\"gAAAAABqkSivFfd8jaO5BXnViFUm2Or10CyW0PYT4v2THW6EZw8upBo3P_kRlbPcS9x6slM2nCJeqazmC0gym1WK\"}"}}"#,
            #"{"timestamp":"2026-08-12T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":200000,"total_token_usage":{"total_tokens":900000},"last_token_usage":{"total_tokens":50000}}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(AgentSessionParsers.parseTranscript(at: url, provider: .codex))
        XCTAssertEqual(session.projectName, "Nano")
        XCTAssertEqual(session.model, "gpt-5.6-sol")
        XCTAssertEqual(session.lastUserPrompt, "Bring Codex details to parity")
        XCTAssertEqual(session.contextWindow, 200_000)
        XCTAssertEqual(session.contextUsed, 50_000)
        XCTAssertEqual(session.contextFraction, 0.25)
        XCTAssertTrue(session.recentActivity.contains { $0.detail.contains("xcodebuild test") })
        XCTAssertEqual(session.todos.first?.title, "Parse Codex tools")
        XCTAssertEqual(session.todos.first?.done, true)
        XCTAssertEqual(session.subagents.first?.displayName, "Provider Hook Review")
    }

    func testCursorSessionUsesSharedClaudeDetailFeatures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCursorDetail-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("cursor-detail.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let lines = [
            #"{"role":"user","message":{"content":[{"type":"text","text":"Review provider parity"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"Shell","input":{"command":"swift test"}},{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Cover Cursor","status":"completed"}]}}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(AgentSessionParsers.parseTranscript(
            at: url, provider: .cursor, projectDirectory: "-tmp-Nano"
        ))
        XCTAssertEqual(session.provider, .cursor)
        XCTAssertEqual(session.lastUserPrompt, "Review provider parity")
        XCTAssertTrue(session.recentActivity.contains { $0.detail == "swift test" })
        XCTAssertEqual(session.todos.first?.title, "Cover Cursor")
    }

    func testOpenCodeSessionLoadsPromptToolsTodosModelAndDiffFromSQLite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoOpenCodeDetail-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("opencode.db")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = #"""
        CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, directory TEXT, model TEXT,
          summary_additions INTEGER, summary_deletions INTEGER, time_created INTEGER,
          time_updated INTEGER, parent_id TEXT, time_archived INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER,
          time_updated INTEGER, data TEXT);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT,
          time_created INTEGER, time_updated INTEGER, data TEXT);
        CREATE TABLE todo (session_id TEXT, content TEXT, status TEXT, priority TEXT,
          position INTEGER, time_created INTEGER, time_updated INTEGER);
        INSERT INTO session VALUES ('ses_test','Provider parity','/tmp/Nano',
          '{"providerID":"kimi-for-coding","id":"k3"}',12,4,1900000000000,
          1900000005000,NULL,NULL);
        INSERT INTO message VALUES ('msg_user','ses_test',1900000001000,1900000001000,
          '{"role":"user"}');
        INSERT INTO message VALUES ('msg_agent','ses_test',1900000002000,1900000002000,
          '{"role":"assistant","providerID":"kimi-for-coding","modelID":"k3"}');
        INSERT INTO part VALUES ('part_text','msg_user','ses_test',1900000001000,1900000001000,
          '{"type":"text","text":"Bring OpenCode to parity"}');
        INSERT INTO part VALUES ('part_tool','msg_agent','ses_test',1900000002000,1900000002000,
          '{"type":"tool","tool":"bash","state":{"input":{"command":"swift test"},"status":"completed"}}');
        INSERT INTO todo VALUES ('ses_test','Cover OpenCode','completed','high',0,
          1900000003000,1900000003000);
        """#
        var error: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, &error), SQLITE_OK,
                       error.map { String(cString: $0) } ?? "SQLite fixture failed")
        if let error { sqlite3_free(error) }
        sqlite3_close(db)
        db = nil

        let session = try XCTUnwrap(
            AgentSessionParsers.parseOpenCodeSession(at: url, sessionID: "ses_test")
        )
        XCTAssertEqual(session.provider, .kimi)
        XCTAssertEqual(session.model, "k3")
        XCTAssertEqual(session.lastUserPrompt, "Bring OpenCode to parity")
        XCTAssertEqual(session.linesAdded, 12)
        XCTAssertEqual(session.linesRemoved, 4)
        XCTAssertTrue(session.recentActivity.contains { $0.detail == "swift test" })
        XCTAssertEqual(session.todos.first?.title, "Cover OpenCode")
        XCTAssertEqual(session.todos.first?.done, true)

        let incremental = AgentSessionParsers.parseIncrementalChanges([
            url.standardizedFileURL.path: .opencode,
        ])
        XCTAssertEqual(incremental.map(\.id), ["ses_test"])
        XCTAssertEqual(incremental.first?.provider, .kimi)
        XCTAssertEqual(incremental.first?.model, "k3")
    }

    @MainActor
    func testHookSessionsKeepProviderIdentityAndSharedDetailFields() throws {
        let now = Date()
        let entry = AgentActivityEntry(kind: .search, detail: "Searched settings", at: now)
        let states = [
            "gemini-session": AgentHookBridge.LiveSessionState(
                sessionID: "gemini-session",
                source: "gemini",
                workingDirectory: "/tmp/Nano",
                recentActivity: [entry],
                lastUserPrompt: "Check all providers",
                model: "gemini-2.5-pro",
                firstSeen: now.addingTimeInterval(-30),
                lastEventAt: now,
                isWorking: true
            ),
            "opencode-kimi": AgentHookBridge.LiveSessionState(
                sessionID: "opencode-kimi",
                source: "opencode",
                providerID: "kimi-for-coding",
                firstSeen: now,
                lastEventAt: now,
                isWorking: true
            ),
        ]

        let store = AgentSessionStore()
        store.applyHookState(states)
        let gemini = try XCTUnwrap(store.sessions.first { $0.id == "gemini-session" })
        XCTAssertEqual(gemini.provider, .gemini)
        XCTAssertEqual(gemini.lastUserPrompt, "Check all providers")
        XCTAssertEqual(gemini.model, "gemini-2.5-pro")
        XCTAssertEqual(gemini.recentActivity.first?.detail, "Searched settings")
        XCTAssertEqual(store.sessions.first { $0.id == "opencode-kimi" }?.provider, .kimi)
    }

    @MainActor
    func testBareSessionStartDoesNotCreateWorkingSessionUntilRealWorkArrives() async throws {
        let bridge = AgentHookBridge()
        let sessionID = "grok-health-check"
        var activitySignalCount = 0
        bridge.didSignalActivity = { _ in activitySignalCount += 1 }

        func payload(eventName: String, prompt: String? = nil) throws -> Data {
            var event: [String: Any] = [
                "hookEventName": eventName,
                "session_id": sessionID,
                "workspaceRoot": FileManager.default.homeDirectoryForCurrentUser.path,
            ]
            if let prompt { event["prompt"] = prompt }
            return try JSONSerialization.data(withJSONObject: [
                "source": "grok",
                "event": event,
            ])
        }

        _ = await bridge.handle(try payload(eventName: "session_start"))
        XCTAssertNil(bridge.sessionStates[sessionID])
        XCTAssertNil(bridge.liveSessions[sessionID])
        XCTAssertEqual(activitySignalCount, 0)

        _ = await bridge.handle(
            try payload(eventName: "user_prompt_submit", prompt: "Do real work")
        )
        XCTAssertEqual(bridge.sessionStates[sessionID]?.lastUserPrompt, "Do real work")
        XCTAssertEqual(bridge.sessionStates[sessionID]?.isWorking, true)
        XCTAssertNotNil(bridge.liveSessions[sessionID])
        XCTAssertEqual(activitySignalCount, 1)
    }

    /// Cursor emits `afterAgentResponse` after every assistant message, so a
    /// turn with tool calls produces several before `stop`. Each one used to
    /// announce "Cursor finished" while the agent was still working.
    @MainActor
    func testCursorAfterAgentResponseDoesNotFinishTurnUntilStop() async throws {
        let bridge = AgentHookBridge()
        let sessionID = "cursor-multi-message-turn"
        var finishedTurns: [String?] = []
        var signals: [AgentHookBridge.ActivitySignal] = []
        var terminalCallbackOrder: [String] = []
        bridge.didFinishTurn = {
            finishedTurns.append($0)
            terminalCallbackOrder.append("finish")
        }
        bridge.didSignalActivity = {
            signals.append($0)
            if case .turnEnded = $0 { terminalCallbackOrder.append("state") }
        }

        func payload(_ eventName: String, extra: [String: Any] = [:]) throws -> Data {
            var event: [String: Any] = [
                "hook_event_name": eventName,
                "conversation_id": sessionID,
                "generation_id": "gen-1",
                "cwd": "/tmp/Nano",
            ]
            extra.forEach { event[$0.key] = $0.value }
            return try JSONSerialization.data(withJSONObject: [
                "source": "cursor",
                "event": event,
            ])
        }

        _ = await bridge.handle(try payload("beforeSubmitPrompt", extra: ["prompt": "Fix the bug"]))
        _ = await bridge.handle(try payload("afterAgentResponse", extra: ["text": "I'll dig into this."]))
        XCTAssertEqual(bridge.sessionStates[sessionID]?.isWorking, true)
        XCTAssertTrue(finishedTurns.isEmpty)

        _ = await bridge.handle(try payload("postToolUse", extra: ["tool_name": "Read"]))
        _ = await bridge.handle(try payload("afterAgentResponse", extra: ["text": "Found it."]))
        XCTAssertEqual(bridge.sessionStates[sessionID]?.isWorking, true)
        XCTAssertTrue(finishedTurns.isEmpty)
        XCTAssertFalse(signals.contains { if case .turnEnded = $0 { true } else { false } })

        _ = await bridge.handle(try payload("stop", extra: ["status": "completed"]))
        XCTAssertEqual(bridge.sessionStates[sessionID]?.isWorking, false)
        XCTAssertEqual(finishedTurns, [sessionID])
        XCTAssertTrue(signals.contains { if case .turnEnded = $0 { true } else { false } })
        XCTAssertEqual(terminalCallbackOrder, ["state", "finish"])
    }

    /// One session finishing must not blank the provider while a sibling of the
    /// same provider is still mid-turn. Host-agnostic: two Cursor windows, two
    /// Claude terminals, or two T3 threads all fold the same way.
    func testProviderStaysActiveWhileAnySessionIsWorking() {
        let now = Date()
        func state(_ id: String, source: String, working: Bool, ago: TimeInterval) -> AgentHookBridge.LiveSessionState {
            AgentHookBridge.LiveSessionState(
                sessionID: id,
                source: source,
                firstSeen: now.addingTimeInterval(-600),
                lastEventAt: now.addingTimeInterval(-ago),
                isWorking: working
            )
        }

        // Newest Cursor event is a stop; an older Cursor session is still working.
        let mixed = AgentStatusService.representativeHookStates([
            "cursor-done": state("cursor-done", source: "cursor", working: false, ago: 1),
            "cursor-busy": state("cursor-busy", source: "cursor", working: true, ago: 30),
            "claude-a": state("claude-a", source: "claude", working: false, ago: 5),
            "claude-b": state("claude-b", source: "claude", working: false, ago: 50),
        ], now: now)
        XCTAssertEqual(mixed[.cursor]?.sessionID, "cursor-busy")
        XCTAssertEqual(mixed[.claude]?.sessionID, "claude-a")

        // Two working sessions: the newest one supplies the detail.
        let bothBusy = AgentStatusService.representativeHookStates([
            "older": state("older", source: "cursor", working: true, ago: 40),
            "newer": state("newer", source: "cursor", working: true, ago: 3),
        ], now: now)
        XCTAssertEqual(bothBusy[.cursor]?.sessionID, "newer")

        // A "working" session whose last event is stale no longer counts, so
        // the newest real event wins again.
        let stale = AgentStatusService.representativeHookStates([
            "stale-busy": state("stale-busy", source: "cursor", working: true, ago: 10 * 60),
            "fresh-done": state("fresh-done", source: "cursor", working: false, ago: 2),
        ], now: now)
        XCTAssertEqual(stale[.cursor]?.sessionID, "fresh-done")
    }

    func testCursorOriginIsRememberedButATranscriptCanStillGainAChatStore() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoOrigin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let id = UUID().uuidString
        let fm = FileManager.default

        XCTAssertEqual(AgentSessionJump.origin(sessionID: id, provider: .cursor, home: home), .unknown)
        let transcript = home
            .appendingPathComponent(".cursor/projects/p/agent-transcripts/\(id)", isDirectory: true)
        try fm.createDirectory(at: transcript, withIntermediateDirectories: true)
        try Data().write(to: transcript.appendingPathComponent("\(id).jsonl"))
        XCTAssertEqual(AgentSessionJump.origin(sessionID: id, provider: .cursor, home: home), .cursorIDE)

        try fm.createDirectory(
            at: home.appendingPathComponent(".cursor/chats/h/\(id)", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(AgentSessionJump.origin(sessionID: id, provider: .cursor, home: home), .cursorChat)
        try fm.removeItem(at: home.appendingPathComponent(".cursor", isDirectory: true))
        XCTAssertEqual(AgentSessionJump.origin(sessionID: id, provider: .cursor, home: home), .cursorChat)
    }

    @MainActor
    func testJumpPicksCursorForIDETranscriptsAndRunningACPHostForStubs() throws {
        let t3Preferred = AgentSessionJump.Runtime(
            t3Running: true, cursorRunning: true, claudeRunning: false, codexRunning: false,
            t3Installed: true, cursorInstalled: true, claudeInstalled: true, codexInstalled: true,
            terminalRunning: false
        )
        let cursorOnly = AgentSessionJump.Runtime(
            t3Running: false, cursorRunning: true, claudeRunning: false, codexRunning: false,
            t3Installed: false, cursorInstalled: true, claudeInstalled: false, codexInstalled: false,
            terminalRunning: false
        )
        let terminalOnly = AgentSessionJump.Runtime(
            t3Running: false, cursorRunning: false, claudeRunning: false, codexRunning: false,
            t3Installed: false, cursorInstalled: false, claudeInstalled: false, codexInstalled: false,
            terminalRunning: true
        )
        XCTAssertEqual(AgentSessionJump.host(for: .cursorIDE, runtime: t3Preferred), .cursor)
        // CLI chats live outside the Cursor app; with no terminal, the folder.
        XCTAssertEqual(AgentSessionJump.host(for: .cursorChat, runtime: t3Preferred), .folder)
        XCTAssertEqual(AgentSessionJump.host(for: .cursorACP, runtime: t3Preferred), .t3)
        XCTAssertEqual(AgentSessionJump.host(for: .cursorACP, runtime: cursorOnly), .cursor)
        XCTAssertEqual(AgentSessionJump.host(for: .claude, runtime: t3Preferred), .claude)
        XCTAssertEqual(AgentSessionJump.host(for: .codex, runtime: t3Preferred), .codex)
        XCTAssertEqual(AgentSessionJump.host(for: .unknown, runtime: t3Preferred), .cursor)
        XCTAssertEqual(AgentSessionJump.host(for: .claude, runtime: cursorOnly), .folder)
        XCTAssertEqual(AgentSessionJump.host(for: .claude, runtime: terminalOnly), .terminal)
        XCTAssertEqual(AgentSessionJump.host(for: .codex, runtime: terminalOnly), .terminal)
        XCTAssertEqual(AgentSessionJump.host(for: .unknown, runtime: terminalOnly), .terminal)
        XCTAssertEqual(AgentSessionJump.host(for: .opencode, runtime: terminalOnly), .terminal)

        let url = AgentSessionJump.editorFileURL(
            scheme: "t3code",
            path: "/Volumes/My Projects/North-Star"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "t3code://file/Volumes/My%20Projects/North-Star"
        )

        var homeSession = AgentSession(
            id: "home-jump",
            provider: .cursor,
            projectName: NSUserName(),
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            lastActivityAt: Date()
        )
        XCTAssertNil(AgentSessionJump.projectDirectory(for: homeSession))
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("North-Star", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project.deletingLastPathComponent()) }
        homeSession.workingDirectory = project.path
        XCTAssertEqual(
            AgentSessionJump.projectDirectory(for: homeSession)?.lastPathComponent,
            "North-Star"
        )

        XCTAssertEqual(
            AgentSessionJump.cursorIDEArguments(folder: URL(fileURLWithPath: "/tmp/project")),
            ["/tmp/project"]
        )
        XCTAssertNil(AgentSessionJump.cursorIDEArguments(folder: nil))
        let cursorArguments = try XCTUnwrap(
            AgentSessionJump.cursorIDEArguments(folder: URL(fileURLWithPath: "/tmp/project"))
        )
        XCTAssertFalse(cursorArguments.contains("--chat"))
        XCTAssertFalse(cursorArguments.contains("--reuse-window"))

        let queries = AgentHostReveal.searchQueries(
            from: [
                "everytime nano relaunched this window pops up, wha…",
                "North-Star",
                "Session",
                ">open settings"
            ],
            ignoring: ["North-Star"]
        )
        XCTAssertEqual(queries.count, 1)
        XCTAssertTrue(queries[0].hasPrefix("everytime nano relaunched"))
        XCTAssertFalse(queries[0].contains("\u{2026}"))
        let exactQueries = AgentHostReveal.searchQueries(
            from: ["Fix Nano notifications and scrolling"],
            maximumLength: nil
        )
        XCTAssertTrue(AgentHostReveal.matches(
            "Fix Nano notifications and scrolling",
            queries: exactQueries,
            requiresExactTitle: true
        ))
        XCTAssertFalse(AgentHostReveal.matches(
            "Fix Nano",
            queries: exactQueries,
            requiresExactTitle: true
        ))
        var t3RevealSession = AgentSession(
            id: "missing-t3-thread-\(UUID().uuidString)",
            provider: .grok,
            projectName: "North-Star",
            lastActivityAt: Date()
        )
        t3RevealSession.lastUserPrompt = "Text that could appear in the composer"
        XCTAssertEqual(AgentSessionJump.revealTitles(for: t3RevealSession, host: .t3), [])
        t3RevealSession.offer("Trusted session title", from: .client)
        XCTAssertEqual(
            AgentSessionJump.revealTitles(for: t3RevealSession, host: .t3),
            ["Trusted session title"]
        )

        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoJump-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: database) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE projection_threads (
                thread_id TEXT PRIMARY KEY,
                title TEXT
            );
            CREATE TABLE projection_thread_sessions (
                thread_id TEXT PRIMARY KEY,
                provider_session_id TEXT
            );
            INSERT INTO projection_threads (thread_id, title)
            VALUES ('t3-thread', 'Tokens + API Prices');
            INSERT INTO projection_thread_sessions (thread_id, provider_session_id)
            VALUES ('mapped-thread', 'acp-session');
            """, nil, nil, nil)
        sqlite3_close(db)
        XCTAssertEqual(AgentSessionJump.t3ThreadID(sessionID: "t3-thread", databaseURL: database), "t3-thread")
        XCTAssertEqual(AgentSessionJump.t3ThreadID(sessionID: "acp-session", databaseURL: database), "mapped-thread")
        XCTAssertEqual(AgentSessionJump.t3ThreadID(sessionID: "unknown", databaseURL: database), "unknown")
        XCTAssertEqual(
            AgentSessionJump.t3ThreadTitle(threadID: "t3-thread", databaseURL: database),
            "Tokens + API Prices"
        )
        XCTAssertNil(AgentSessionJump.t3ThreadTitle(threadID: "missing", databaseURL: database))

        XCTAssertEqual(
            AgentSessionJump.embeddedUUID(
                in: "rollout-2026-03-25T22-46-16-019d25ff-3701-75d1-b331-160b90f8a456"
            ),
            "019d25ff-3701-75d1-b331-160b90f8a456"
        )
        XCTAssertEqual(
            AgentSessionJump.codexThreadURL(sessionID: "rollout-019d25ff-3701-75d1-b331-160b90f8a456")?
                .absoluteString,
            "codex://threads/019d25ff-3701-75d1-b331-160b90f8a456"
        )
        XCTAssertEqual(
            AgentSessionJump.claudeResumeURL(sessionID: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")?
                .absoluteString,
            "claude://resume?session=a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        )
        let cursorURL = AgentSessionJump.cursorConversationURL(
            sessionID: "232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad",
            folder: URL(fileURLWithPath: "/tmp/project")
        )
        XCTAssertEqual(cursorURL?.scheme, "cursor")
        XCTAssertEqual(cursorURL?.host, "nano.cursor-conversation-jump")
        XCTAssertEqual(cursorURL?.path, "/focus-cursor-agent")
        XCTAssertTrue(cursorURL?.query?.contains("conversation=232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad") == true)

        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoT3Jump-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        let runtimeDatabase = runtimeRoot.appendingPathComponent("state.sqlite")
        let runtimeThreadID = "15b6640d-056a-4c8d-ae93-b633cd59ce65"
        let runtimeSessionID = "3ecf801a-e792-46fd-b4d4-f84bb12c1ea1"
        var runtimeDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(runtimeDatabase.path, &runtimeDB), SQLITE_OK)
        sqlite3_exec(runtimeDB, """
            CREATE TABLE projection_threads (
                thread_id TEXT PRIMARY KEY,
                title TEXT
            );
            CREATE TABLE projection_thread_sessions (
                thread_id TEXT PRIMARY KEY,
                provider_session_id TEXT
            );
            INSERT INTO projection_threads (thread_id, title)
            VALUES ('\(runtimeThreadID)', 'Settings UI Rework');
            INSERT INTO projection_thread_sessions (thread_id, provider_session_id)
            VALUES ('\(runtimeThreadID)', '');
            """, nil, nil, nil)
        sqlite3_close(runtimeDB)
        let runtimeLog = runtimeRoot.appendingPathComponent("logs/provider/events.\(runtimeThreadID).log")
        try FileManager.default.createDirectory(
            at: runtimeLog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [2026-09-13T20:30:09.305Z] NTIVE: {"event":{"payload":{"sessionId":"\(runtimeSessionID)"}}}
        """.write(to: runtimeLog, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            AgentSessionJump.t3ThreadID(sessionID: runtimeSessionID, databaseURL: runtimeDatabase),
            runtimeThreadID
        )

        let receiptHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoJumpReceipt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: receiptHome) }
        let receiptDir = AgentSessionJump.cursorJumpReceiptDirectory(home: receiptHome)
        try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "opened": true,
            "conversation": "232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad",
            "workspaces": ["/tmp/project"],
        ]).write(to: receiptDir.appendingPathComponent("cursor-1.json"))
        XCTAssertTrue(
            AgentSessionJump.cursorJumpOpened(
                conversation: "232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad",
                folder: URL(fileURLWithPath: "/tmp/project"),
                home: receiptHome
            )
        )
        XCTAssertFalse(
            AgentSessionJump.cursorJumpOpened(
                conversation: "other-id",
                folder: URL(fileURLWithPath: "/tmp/project"),
                home: receiptHome
            )
        )
    }

    @MainActor
    func testEmptyACPMetaStubsAreNotListedAsSessions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoACPStub-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "cwd": FileManager.default.homeDirectoryForCurrentUser.path,
        ]).write(to: directory.appendingPathComponent("meta.json"))

        XCTAssertNil(AgentSessionParsers.parseCursorStore(at: directory, fullHistory: false))
    }

    @MainActor
    func testCursorClaudeCompatibilityHooksKeepCursorIdentity() async throws {
        let bridge = AgentHookBridge()
        for source in ["cursor", "claude", "cursor", "claude"] {
            let payload: [String: Any] = ["source": source, "event": [
                "conversation_id": "fixture-cursor", "generation_id": "turn-1",
                "hook_event_name": "PostToolUse", "tool_name": "Read",
                "provider": "anthropic", "model": "grok-4.6"
            ]]
            _ = await bridge.handle(try JSONSerialization.data(withJSONObject: payload))
            XCTAssertEqual(bridge.sessionStates["fixture-cursor"]?.source, "cursor")
            XCTAssertNil(bridge.sessionStates["fixture-cursor"]?.providerID)
        }
        XCTAssertFalse(AgentHookBridge.isCursorSession(source: "claude", event: ["session_id": "native-claude"], sessionID: "native-claude"))
        let store = AgentSessionStore()
        store.applyHookState(bridge.sessionStates)
        XCTAssertEqual(store.sessions.filter { $0.id == "fixture-cursor" }.count, 1)
        XCTAssertEqual(store.sessions.first { $0.id == "fixture-cursor" }?.provider, .cursor)
    }

    @MainActor
    func testStoppedT3ACPThreadCannotReappearAsWorking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoT3Stopped-\(UUID().uuidString)", isDirectory: true)
        let directory = root
            .appendingPathComponent(".cursor/acp-sessions/acp-stopped", isDirectory: true)
        let database = root.appendingPathComponent("state.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "cwd": "/tmp/Nano-T3-Stopped",
            "title": "Website Discussion",
        ]).write(to: directory.appendingPathComponent("meta.json"))

        var store: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(directory.appendingPathComponent("store.db").path, &store),
            SQLITE_OK
        )
        sqlite3_close(store)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE projection_threads (
                thread_id TEXT PRIMARY KEY,
                deleted_at TEXT
            );
            CREATE TABLE projection_thread_sessions (
                thread_id TEXT PRIMARY KEY,
                provider_session_id TEXT,
                provider_name TEXT,
                status TEXT,
                active_turn_id TEXT,
                updated_at TEXT
            );
            CREATE TABLE provider_session_runtime (
                thread_id TEXT PRIMARY KEY,
                provider_name TEXT,
                status TEXT,
                last_seen_at TEXT,
                runtime_payload_json TEXT
            );
            INSERT INTO projection_threads (thread_id, deleted_at)
            VALUES ('t3-stopped', NULL);
            INSERT INTO projection_thread_sessions (
                thread_id, provider_session_id, provider_name, status, active_turn_id, updated_at
            ) VALUES (
                't3-stopped', NULL, 'cursor', 'stopped', NULL, '2026-09-02T00:37:00.000Z'
            );
            INSERT INTO provider_session_runtime (
                thread_id, provider_name, status, last_seen_at, runtime_payload_json
            ) VALUES (
                't3-stopped', 'cursor', 'stopped', '2026-09-02T00:37:00.000Z',
                '{"cwd":"/tmp/Nano-T3-Stopped","activeTurnId":null,"lastRuntimeEventAt":"2026-09-02T00:36:55.510Z"}'
            );
            """, nil, nil, nil)
        sqlite3_close(db)

        // A running neighbour in the same repository cannot lend its state to
        // this old transcript, even when T3 has omitted provider_session_id.
        var reopened: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &reopened), SQLITE_OK)
        sqlite3_exec(reopened, """
            INSERT INTO projection_threads VALUES ('t3-running', NULL);
            INSERT INTO projection_thread_sessions VALUES
              ('t3-running', 'acp-running', 'cursor', 'running', 'turn-running', '2026-09-03T00:00:00Z');
            INSERT INTO provider_session_runtime VALUES
              ('t3-running', 'cursor', 'running', '2026-09-03T00:00:00Z',
               '{"cwd":"/tmp/Nano-T3-Stopped","model":"grok-4.6"}');
            """, nil, nil, nil)
        sqlite3_close(reopened)
        let withNeighbour = AgentT3RuntimeIndex.index(databaseURL: database)
        XCTAssertNil(withNeighbour.entry(sessionID: "unrelated", workingDirectory: "/tmp/Nano-T3-Stopped"))
        XCTAssertEqual(withNeighbour.exactEntry(sessionID: "acp-running")?.model, "grok-4.6")
        XCTAssertEqual(withNeighbour.modelsByProviderSessionID["acp-running"], "grok-4.6")
        XCTAssertEqual(withNeighbour.exactEntry(sessionID: "acp-running")?.isWorking, true)
        let threadID = UUID().uuidString
        let acpID = UUID().uuidString
        let logs = root.appendingPathComponent("logs/provider", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let receipt: [String: Any] = ["event": ["provider": "cursor", "threadId": threadID,
            "payload": ["sessionId": acpID]]]
        var receiptData = Data("[timestamp] NTIVE: ".utf8)
        receiptData.append(try JSONSerialization.data(withJSONObject: receipt))
        receiptData.append(Data("\n".utf8))
        try receiptData.write(to: logs.appendingPathComponent("events.\(threadID).log"))
        XCTAssertEqual(sqlite3_open(database.path, &reopened), SQLITE_OK)
        sqlite3_exec(reopened, """
            INSERT INTO projection_threads VALUES ('\(threadID)', NULL);
            INSERT INTO projection_thread_sessions VALUES
              ('\(threadID)', NULL, 'cursor', 'running', 'turn-recovered', '2026-09-03T00:00:00Z');
            """, nil, nil, nil)
        sqlite3_close(reopened)
        XCTAssertEqual(AgentT3RuntimeIndex.index(databaseURL: database).exactEntry(sessionID: acpID)?.threadID, threadID)
        XCTAssertEqual(sqlite3_open(database.path, &reopened), SQLITE_OK)
        sqlite3_exec(reopened, "UPDATE projection_thread_sessions SET status='ready', active_turn_id=NULL WHERE thread_id='\(threadID)';", nil, nil, nil)
        sqlite3_close(reopened)
        XCTAssertEqual(AgentT3RuntimeIndex.index(databaseURL: database).exactEntry(sessionID: acpID)?.isWorking, false)
        let old = try XCTUnwrap(AgentSessionParsers.parseCursorStore(at: directory, t3Runtime: withNeighbour))
        XCTAssertEqual(old.isOpenInClient, false)
        XCTAssertFalse(old.isActive)

        // Restore the stopped-only fixture for the original assertions.
        XCTAssertEqual(sqlite3_open(database.path, &reopened), SQLITE_OK)
        sqlite3_exec(reopened, "DELETE FROM projection_thread_sessions WHERE thread_id='t3-running';", nil, nil, nil)
        sqlite3_close(reopened)

        let runtime = AgentT3RuntimeIndex.index(databaseURL: database)
        XCTAssertNil(
            runtime.entry(
                sessionID: "acp-stopped",
                workingDirectory: "/tmp/Nano-T3-Stopped"
            )
        )
        let session = try XCTUnwrap(
            AgentSessionParsers.parseCursorStore(
                at: directory,
                fullHistory: false,
                t3Runtime: runtime
            )
        )
        XCTAssertEqual(session.displayName, "Website Discussion")
        XCTAssertNotNil(session.finishedAt)
        XCTAssertEqual(session.isOpenInClient, false)
        XCTAssertFalse(session.isActive)
    }

    /// T3 leaves `provider_session_id` empty, so the ACP ID comes from the
    /// thread's event log. A tool result can push one log line past 64KB;
    /// recovery must walk back past it rather than declare the session gone.
    func testT3SessionIDRecoveryWalksBackPastOversizedLogLines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoT3Recover-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs/provider", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("state.sqlite")
        let threadID = UUID().uuidString
        let acpID = UUID().uuidString

        var log = Data()
        let receipt: [String: Any] = ["event": ["provider": "cursor", "threadId": threadID,
            "payload": ["sessionId": acpID, "update": ["sessionUpdate": "tool_call"]]]]
        log.append(Data("[t] NTIVE: ".utf8))
        log.append(try JSONSerialization.data(withJSONObject: receipt))
        log.append(Data("\n".utf8))
        // Three giant tool-result lines after the last receipt, each larger
        // than a scan chunk and with no session ID of their own.
        for _ in 0..<3 {
            let huge: [String: Any] = ["event": ["provider": "cursor", "threadId": threadID,
                "payload": ["result": String(repeating: "x", count: 300 * 1024)]]]
            log.append(Data("[t] NTIVE: ".utf8))
            log.append(try JSONSerialization.data(withJSONObject: huge))
            log.append(Data("\n".utf8))
        }
        try log.write(to: logs.appendingPathComponent("events.\(threadID).log"))

        XCTAssertNil(
            AgentT3RuntimeIndex.providerSessionID(threadID: threadID, databaseURL: database, scanLimit: 64 * 1024),
            "a 64KB tail lands inside the last oversized line"
        )
        XCTAssertEqual(
            AgentT3RuntimeIndex.providerSessionID(threadID: threadID, databaseURL: database),
            acpID
        )
        // Cached: the log can rotate away and the answer holds.
        try FileManager.default.removeItem(at: logs.appendingPathComponent("events.\(threadID).log"))
        XCTAssertEqual(
            AgentT3RuntimeIndex.providerSessionID(threadID: threadID, databaseURL: database),
            acpID
        )
    }

    /// The host's sidebar name is what the user recognises, so it outranks
    /// Cursor's own name for the same ACP conversation. The fixture above has
    /// no `title` column and still indexes, covering the schema fallback.
    @MainActor
    func testT3ThreadTitleNamesTheACPSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoT3Title-\(UUID().uuidString)", isDirectory: true)
        let directory = root
            .appendingPathComponent(".cursor/acp-sessions/acp-titled", isDirectory: true)
        let database = root.appendingPathComponent("state.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "cwd": "/tmp/Nano-T3-Title",
            "title": "Cursor's guess",
        ]).write(to: directory.appendingPathComponent("meta.json"))

        var store: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("store.db").path, &store), SQLITE_OK)
        sqlite3_exec(store, """
            CREATE TABLE meta (value TEXT);
            INSERT INTO meta VALUES ('{"name":"Cursor store name","createdAt":1757000000000}');
            """, nil, nil, nil)
        sqlite3_close(store)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE projection_threads (thread_id TEXT PRIMARY KEY, title TEXT NOT NULL, deleted_at TEXT);
            CREATE TABLE projection_thread_sessions (
                thread_id TEXT PRIMARY KEY, provider_session_id TEXT, provider_name TEXT,
                status TEXT, active_turn_id TEXT, updated_at TEXT
            );
            CREATE TABLE provider_session_runtime (
                thread_id TEXT PRIMARY KEY, provider_name TEXT, status TEXT,
                last_seen_at TEXT, runtime_payload_json TEXT
            );
            INSERT INTO projection_threads VALUES ('t3-titled', '  Reimagine Nano Notes  ', NULL);
            INSERT INTO projection_thread_sessions VALUES
              ('t3-titled', 'acp-titled', 'cursor', 'running', 'turn-1', '2026-09-03T00:00:00Z');
            INSERT INTO provider_session_runtime VALUES
              ('t3-titled', 'cursor', 'running', '2026-09-03T00:00:00Z', '{"cwd":"/tmp/Nano-T3-Title"}');
            """, nil, nil, nil)
        sqlite3_close(db)

        let runtime = AgentT3RuntimeIndex.index(databaseURL: database)
        XCTAssertEqual(runtime.exactEntry(sessionID: "acp-titled")?.title, "Reimagine Nano Notes")

        let session = try XCTUnwrap(
            AgentSessionParsers.parseCursorStore(at: directory, fullHistory: false, t3Runtime: runtime)
        )
        XCTAssertEqual(session.displayName, "Reimagine Nano Notes")
        XCTAssertEqual(session.title?.source, .client)
        XCTAssertTrue(session.isActive)
    }

    func testT3LaunchStopAllDoesNotReviveOldThreads() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoT3StopAll-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: database) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE projection_threads (thread_id TEXT PRIMARY KEY, title TEXT, deleted_at TEXT);
            CREATE TABLE projection_thread_sessions (
                thread_id TEXT PRIMARY KEY, provider_session_id TEXT, provider_name TEXT,
                status TEXT, active_turn_id TEXT, updated_at TEXT
            );
            CREATE TABLE provider_session_runtime (
                thread_id TEXT PRIMARY KEY, provider_name TEXT, status TEXT,
                last_seen_at TEXT, runtime_payload_json TEXT
            );
            INSERT INTO projection_threads VALUES ('t3-old', 'Old thread', NULL);
            INSERT INTO projection_thread_sessions VALUES
              ('t3-old', 'acp-old', 'cursor', 'stopped', NULL, '2026-09-18T05:54:39.785Z');
            INSERT INTO provider_session_runtime VALUES
              ('t3-old', 'cursor', 'stopped', '2026-09-24T05:15:16.899Z',
               '{"cwd":"/tmp/Nano","lastRuntimeEvent":"provider.stopAll","lastRuntimeEventAt":"2026-09-24T05:15:16.899Z"}');
            """, nil, nil, nil)
        sqlite3_close(db)

        let entry = try XCTUnwrap(
            AgentT3RuntimeIndex.index(databaseURL: database).exactEntry(sessionID: "acp-old")
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(entry.lastEventAt, formatter.date(from: "2026-09-18T05:54:39.785Z"))
    }

    @MainActor
    func testT3RuntimeIndexesGrokProviderSessions() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoT3Grok-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: database) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE projection_threads (
                thread_id TEXT PRIMARY KEY,
                title TEXT,
                deleted_at TEXT
            );
            CREATE TABLE projection_thread_sessions (
                thread_id TEXT PRIMARY KEY,
                provider_session_id TEXT,
                provider_name TEXT,
                status TEXT,
                active_turn_id TEXT,
                updated_at TEXT
            );
            CREATE TABLE provider_session_runtime (
                thread_id TEXT PRIMARY KEY,
                provider_name TEXT,
                status TEXT,
                last_seen_at TEXT,
                runtime_payload_json TEXT
            );
            INSERT INTO projection_threads VALUES ('t3-grok-thread', 'Fix Nano', NULL);
            INSERT INTO projection_thread_sessions VALUES
              ('t3-grok-thread', 'grok-session', 'grok', 'running', 'turn-1', '2026-09-19T17:00:00Z');
            INSERT INTO provider_session_runtime VALUES
              ('t3-grok-thread', 'grok', 'running', '2026-09-19T17:00:00Z',
               '{"cwd":"/tmp/Nano","model":"grok-4.6"}');
            """, nil, nil, nil)
        sqlite3_close(db)

        let runtime = AgentT3RuntimeIndex.index(databaseURL: database)
        let entry = try XCTUnwrap(runtime.exactEntry(sessionID: "grok-session"))
        XCTAssertTrue(entry.isWorking)
        XCTAssertEqual(entry.threadID, "t3-grok-thread")
        XCTAssertEqual(entry.provider, .grok)

        let now = Date()
        let store = AgentSessionStore()
        store.applyHookState([
            "grok-session": AgentHookBridge.LiveSessionState(
                sessionID: "grok-session",
                source: "claude",
                model: "grok-4.6",
                firstSeen: now.addingTimeInterval(-30),
                lastEventAt: now,
                isWorking: false
            ),
        ], now: now, t3Runtime: runtime)

        let session = try XCTUnwrap(store.sessions.first { $0.id == "grok-session" })
        XCTAssertEqual(session.provider, .grok)
        XCTAssertEqual(session.host, .t3)
        XCTAssertTrue(session.isActive, "T3's active turn must override an early compatible stop hook")
        let cursorOnly = AgentSessionJump.Runtime(
            t3Running: false, cursorRunning: true, claudeRunning: false, codexRunning: false,
            t3Installed: false, cursorInstalled: true, claudeInstalled: false,
            codexInstalled: false, terminalRunning: false
        )
        XCTAssertEqual(AgentSessionJump.host(for: session, runtime: cursorOnly), .t3)
    }

    @MainActor
    func testMangledCursorProjectPathRecoversDashedFolderName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoPathRecover-\(UUID().uuidString)", isDirectory: true)
        let project = root
            .appendingPathComponent("Coding Projects", isDirectory: true)
            .appendingPathComponent("acme-core-platform", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let mangled = project.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
        let recovered = try XCTUnwrap(AgentSessionParsers.recoverMangledPath(mangled))
        XCTAssertEqual(
            URL(fileURLWithPath: recovered).standardizedFileURL.path,
            project.standardizedFileURL.path
        )
        XCTAssertEqual(URL(fileURLWithPath: recovered).lastPathComponent, "acme-core-platform")
    }

    @MainActor
    func testNoLiveSessionsDoesNotFallBackToIdleHistory() {
        let store = AgentSessionStore()
        let old = Date().addingTimeInterval(-86_400)
        store.applyHookState(["idle": AgentHookBridge.LiveSessionState(
            sessionID: "idle", source: "cursor", lastUserPrompt: "Old completed work",
            firstSeen: old, lastEventAt: old, isWorking: false
        )])
        XCTAssertTrue(store.liveSessions.isEmpty)
    }

    @MainActor
    func testNamelessIdleShellsAreHiddenFromTheIsland() {
        let store = AgentSessionStore()
        let now = Date()
        store.applyHookState([
            "live": AgentHookBridge.LiveSessionState(
                sessionID: "live",
                source: "cursor",
                lastUserPrompt: "Nano Notifications",
                firstSeen: now.addingTimeInterval(-60),
                lastEventAt: now,
                isWorking: true
            ),
            "empty": AgentHookBridge.LiveSessionState(
                sessionID: "empty",
                source: "cursor",
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                firstSeen: now.addingTimeInterval(-30),
                lastEventAt: now,
                isWorking: false
            ),
        ])
        XCTAssertEqual(store.liveSessions.map(\.id), ["live"])
        XCTAssertFalse(store.sessions.contains { $0.displayName == "Session" && $0.hasVisibleWork })
    }

    @MainActor
    func testFinishedCursorTurnRemainsReviewableBesideActiveCursorSession() {
        let store = AgentSessionStore()
        let now = Date()
        store.applyHookState([
            "active": AgentHookBridge.LiveSessionState(
                sessionID: "active",
                source: "cursor",
                lastUserPrompt: "Build the current screen",
                firstSeen: now.addingTimeInterval(-60),
                lastEventAt: now,
                isWorking: true
            ),
            "finished": AgentHookBridge.LiveSessionState(
                sessionID: "finished",
                source: "cursor",
                lastUserPrompt: "A previous Cursor turn",
                firstSeen: now.addingTimeInterval(-120),
                lastEventAt: now.addingTimeInterval(-10),
                isWorking: false
            ),
        ])

        XCTAssertEqual(
            store.liveSessions.filter { $0.provider == .cursor }.map(\.id),
            ["active", "finished"]
        )
    }

    func testImageOutputFollowedByToolKeepsSessionMetadata() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nano-image-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID().uuidString
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/Nano"]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": "Review notification designs"]],
            ["type": "turn_context", "payload": ["model": "gpt-6-astra"]],
            ["type": "response_item", "payload": ["type": "function_call_output", "output": String(repeating: "x", count: 300_000)]],
            ["type": "response_item", "payload": ["type": "function_call", "name": "imagegen", "arguments": "{}"]]
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try data.write(to: url)
        let session = try XCTUnwrap(AgentSessionParsers.parseIncrementalChanges([url.path: .codex]).first)
        XCTAssertEqual(session.lastUserPrompt, "Review notification designs")
        XCTAssertEqual(session.model, "gpt-6-astra")
        XCTAssertFalse(session.recentActivity.isEmpty)
    }

    func testAttachmentPromptUsesTheActualRequest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nano-attachment-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let prompt = "# Files mentioned by the user:\n\n## Screenshot.jpg: /tmp/example.jpg\n\n## My request:\nFix the session panel"
        let records: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": UUID().uuidString, "cwd": "/tmp/Nano"]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": prompt]]
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try data.write(to: url)
        let session = try XCTUnwrap(AgentSessionParsers.parseIncrementalChanges([url.path: .codex]).first)
        XCTAssertEqual(session.lastUserPrompt, "Fix the session panel")
    }

    func testCodexTailUsesThreadDatabaseModelWhenTurnContextIsOutsideTail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCodexModelFallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previousHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", directory.path, 1)
        defer {
            if let previousHome {
                setenv("CODEX_HOME", previousHome, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        let id = "01a055f0-0000-7000-8000-000000000001"
        let transcript = directory.appendingPathComponent("rollout-\(id).jsonl")
        let lines = [
            #"{"timestamp":"2026-08-30T23:00:00.000Z","type":"session_meta","payload":{"id":"01a055f0-0000-7000-8000-000000000001","cwd":"/tmp/Nano"}}"#,
            #"{"type":"response_item","payload":{"type":"message","content":""#
                + String(repeating: "x", count: 300_000) + #""}}"#,
            #"{"timestamp":"2026-08-30T23:00:02.000Z","type":"event_msg","payload":{"type":"user_message","message":"Keep the model label visible"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let database = directory.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE threads (
          id TEXT PRIMARY KEY, name TEXT, model TEXT, updated_at INTEGER NOT NULL
        );
        INSERT INTO threads VALUES ('\(id)', 'Model fallback fixture', 'gpt-5.6-sol', 1788159600);
        """
        var error: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, &error), SQLITE_OK,
                       error.map { String(cString: $0) } ?? "SQLite fixture failed")
        if let error { sqlite3_free(error) }
        sqlite3_close(db)
        db = nil

        let sessions = AgentSessionParsers.parseIncrementalChanges([
            transcript.standardizedFileURL.path: .codex,
        ])
        let session = try XCTUnwrap(sessions.first { $0.id == id })
        XCTAssertEqual(session.model, "gpt-5.6-sol")
    }

    func testCursorHeadersProvideNativeTitleContextAndOpenSessions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCursorHeaders-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("state.vscdb")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = #"""
        CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);
        CREATE TABLE composerHeaders (
          composerId TEXT PRIMARY KEY, lastUpdatedAt INTEGER,
          isArchived INTEGER, isSubagent INTEGER, value TEXT
        );
        INSERT INTO ItemTable VALUES ('cursor/glass.selectedAgent', 'cursor-selected');
        INSERT INTO ItemTable VALUES (
          'glass/cursor.editorPanelVisibility.agent/cursor-visible', '{"visible":true}'
        );
        INSERT INTO composerHeaders VALUES (
          'cursor-selected', 300, 0, 0,
          '{"name":"Website design for Nano","contextUsagePercent":77.376953125}'
        );
        INSERT INTO composerHeaders VALUES (
          'cursor-visible', 200, 0, 0,
          '{"name":"Logo and brand kit ideas","contextUsagePercent":30.95546875}'
        );
        INSERT INTO composerHeaders VALUES (
          'cursor-archived', 100, 1, 0,
          '{"name":"Old Cursor work","contextUsagePercent":42}'
        );
        """#
        var error: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, &error), SQLITE_OK,
                       error.map { String(cString: $0) } ?? "SQLite fixture failed")
        if let error { sqlite3_free(error) }
        sqlite3_close(db)
        db = nil

        let metadata = AgentCursorConversationMetadata.index(databaseURL: database)
        XCTAssertEqual(metadata["cursor-selected"]?.name, "Website design for Nano")
        XCTAssertEqual(metadata["cursor-selected"]?.contextFraction, 0.77376953125)
        XCTAssertEqual(metadata["cursor-selected"]?.isOpenInClient, true)
        XCTAssertEqual(metadata["cursor-visible"]?.name, "Logo and brand kit ideas")
        XCTAssertEqual(metadata["cursor-visible"]?.isOpenInClient, true)
        XCTAssertEqual(metadata["cursor-archived"]?.isOpenInClient, false)

        let transcript = directory.appendingPathComponent("cursor-selected.jsonl")
        let lines = [
            #"{"role":"user","message":{"content":[{"type":"text","text":"Build the site"}]}}"#,
            #"{"type":"turn_ended"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        let session = try XCTUnwrap(
            AgentSessionParsers.parseTranscript(
                at: transcript,
                provider: .cursor,
                cursorMetadata: metadata
            )
        )
        XCTAssertEqual(session.displayName, "Website design for Nano")
        XCTAssertEqual(session.contextFraction, 0.77376953125)
        XCTAssertEqual(session.isOpenInClient, true)
        XCTAssertNil(session.finishedAt)
    }

    func testArchivedCursorHeaderClosesRecentlyWrittenTranscript() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoArchivedCursor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let transcript = directory.appendingPathComponent("cursor-archived.jsonl")
        try #"{"role":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}"#
            .appending("\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let metadata: [String: AgentCursorConversationMetadata.Entry] = [
            "cursor-archived": .init(
                name: "Nano 3D device motion",
                contextFraction: 0.23,
                isOpenInClient: false
            ),
        ]
        let session = try XCTUnwrap(
            AgentSessionParsers.parseTranscript(
                at: transcript,
                provider: .cursor,
                cursorMetadata: metadata
            )
        )

        XCTAssertEqual(session.isOpenInClient, false)
        XCTAssertNotNil(session.finishedAt)
    }

    @MainActor
    func testCursorHookRowsUseNativeHeaderMetadataBeforeTranscriptScan() {
        let metadata: [String: AgentCursorConversationMetadata.Entry] = [
            "cursor-site": .init(
                name: "Website design for Nano",
                contextFraction: 0.77376953125,
                isOpenInClient: true
            ),
            "cursor-brand": .init(
                name: "Logo and brand kit ideas",
                contextFraction: 0.40525390625,
                isOpenInClient: true
            ),
        ]
        let store = AgentSessionStore(cursorMetadata: metadata)
        let now = Date()
        store.applyHookState([
            "cursor-site": AgentHookBridge.LiveSessionState(
                sessionID: "cursor-site",
                source: "cursor",
                firstSeen: now.addingTimeInterval(-60),
                lastEventAt: now,
                isWorking: true
            ),
            "cursor-brand": AgentHookBridge.LiveSessionState(
                sessionID: "cursor-brand",
                source: "cursor",
                firstSeen: now.addingTimeInterval(-120),
                lastEventAt: now.addingTimeInterval(-30),
                isWorking: false
            ),
        ])

        XCTAssertEqual(
            store.liveSessions.map(\.displayName),
            ["Website design for Nano", "Logo and brand kit ideas"]
        )
        XCTAssertEqual(store.sessions.first { $0.id == "cursor-site" }?.contextFraction,
                       0.77376953125)
        XCTAssertEqual(store.sessions.first { $0.id == "cursor-brand" }?.contextFraction,
                       0.40525390625)
    }

    /// Cursor counts every unarchived conversation as open. Two chats left in
    /// its sidebar overnight must not stay on the island the next day.
    @MainActor
    func testOpenCursorConversationsLeaveTheIslandAfterTheLingerWindow() {
        let metadata: [String: AgentCursorConversationMetadata.Entry] = [
            "cursor-overnight": .init(
                name: "Grok refactor from last night",
                contextFraction: 0.5,
                isOpenInClient: true
            ),
            "cursor-now": .init(
                name: "Current Cursor chat",
                contextFraction: 0.1,
                isOpenInClient: true
            ),
        ]
        let store = AgentSessionStore(cursorMetadata: metadata)
        let now = Date()
        store.applyHookState([
            "cursor-overnight": AgentHookBridge.LiveSessionState(
                sessionID: "cursor-overnight",
                source: "cursor",
                lastUserPrompt: "Refactor the parser",
                firstSeen: now.addingTimeInterval(-13 * 3600),
                lastEventAt: now.addingTimeInterval(-12 * 3600),
                isWorking: false
            ),
            "cursor-now": AgentHookBridge.LiveSessionState(
                sessionID: "cursor-now",
                source: "cursor",
                lastUserPrompt: "Fix the footer",
                firstSeen: now.addingTimeInterval(-120),
                lastEventAt: now.addingTimeInterval(-60),
                isWorking: false
            ),
        ], now: now)

        XCTAssertEqual(store.sessions.first { $0.id == "cursor-overnight" }?.isOpenInClient, true)
        XCTAssertEqual(store.liveSessions(at: now).map(\.id), ["cursor-now"])
        // The open chat still leaves once it is quiet past the linger window.
        let later = now.addingTimeInterval(AgentSessionStore.lingerWindow + 60)
        XCTAssertTrue(store.liveSessions(at: later).isEmpty)
    }

    func testOldOpenCursorConversationsDoNotTakeReservedSlots() {
        let now = Date()
        var sessions = (0..<20).map { index in
            AgentSession(
                id: "codex-\(index)",
                provider: .codex,
                projectName: "Nano",
                lastActivityAt: now.addingTimeInterval(Double(-index))
            )
        }
        var stale = AgentSession(
            id: "cursor-stale",
            provider: .cursor,
            projectName: "website-prototype",
            lastActivityAt: now.addingTimeInterval(-2 * 24 * 3600)
        )
        stale.isOpenInClient = true
        sessions.append(stale)

        let limited = AgentSessionParsers.limitRecentSessions(sessions)
        XCTAssertEqual(limited.count, 20)
        XCTAssertFalse(limited.contains { $0.id == "cursor-stale" })
        XCTAssertTrue(limited.contains { $0.id == "codex-19" })
    }

    func testOpenCursorSessionsAreReservedInsideGlobalSessionCap() {
        let now = Date()
        var sessions = (0..<21).map { index in
            AgentSession(
                id: "codex-\(index)",
                provider: .codex,
                projectName: "Nano",
                lastActivityAt: now.addingTimeInterval(Double(-index))
            )
        }
        var site = AgentSession(
            id: "cursor-site",
            provider: .cursor,
            projectName: "website-prototype",
            lastActivityAt: now.addingTimeInterval(-100)
        )
        site.isOpenInClient = true
        var brand = AgentSession(
            id: "cursor-brand",
            provider: .cursor,
            projectName: "website-prototype",
            lastActivityAt: now.addingTimeInterval(-101)
        )
        brand.isOpenInClient = true
        sessions += [site, brand]

        let limited = AgentSessionParsers.limitRecentSessions(sessions)
        XCTAssertEqual(limited.count, 20)
        XCTAssertTrue(limited.contains { $0.id == "cursor-site" })
        XCTAssertTrue(limited.contains { $0.id == "cursor-brand" })
    }

    @MainActor
    func testCursorIDETranscriptsAreDiscoveredBesideACPStores() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCursorIDE-\(UUID().uuidString)", isDirectory: true)
        let sessionID = "232c4a8c-f5ea-4d9a-8a2d-f6aa140b91ad"
        let directory = root
            .appendingPathComponent("acme-core-platform", isDirectory: true)
            .appendingPathComponent("agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        let url = directory.appendingPathComponent("\(sessionID).jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #"{"role":"user","message":{"content":[{"type":"text","text":"Acme project handoff"}]}}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let childDirectory = directory.appendingPathComponent("subagents", isDirectory: true)
        let childURL = childDirectory.appendingPathComponent("child.jsonl")
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        try #"{"role":"user","message":{"content":[{"type":"text","text":"Nested implementation detail"}]}}"#
            .write(to: childURL, atomically: true, encoding: .utf8)

        let found = AgentSessionParsers.cursorTranscriptURLs(in: root)
            .map(\.standardizedFileURL.path)
        XCTAssertEqual(found, [url.standardizedFileURL.path])

        let session = try XCTUnwrap(
            AgentSessionParsers.parseTranscript(
                at: url,
                provider: .cursor,
                projectDirectory: "acme-core-platform"
            )
        )
        XCTAssertEqual(session.provider, .cursor)
        XCTAssertEqual(session.lastUserPrompt, "Acme project handoff")
        XCTAssertEqual(AgentSessionStore.islandVisibleLimit, 8)
        XCTAssertEqual(AgentSessionStore.lingerWindow, 15 * 60)
    }

    func testCursorTurnEndedRecordMarksTranscriptFinished() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCursorEnded-\(UUID().uuidString)", isDirectory: true)
        let sessionID = "36476931-63df-420c-a741-65719cf2ef58"
        let url = directory.appendingPathComponent("\(sessionID).jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let transcript = [
            #"{"timestamp":"2026-08-30T23:00:00.000Z","role":"user","message":{"content":[{"type":"text","text":"Fix Nano"}]}}"#,
            #"{"timestamp":"2026-08-30T23:00:05.000Z","type":"turn_ended"}"#,
        ].joined(separator: "\n") + "\n"
        try transcript.write(to: url, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(
            AgentSessionParsers.parseTranscript(at: url, provider: .cursor)
        )
        XCTAssertEqual(session.lastUserPrompt, "Fix Nano")
        XCTAssertEqual(
            session.finishedAt,
            ISO8601DateFormatter().date(from: "2026-08-30T23:00:05Z")
        )
    }

    @MainActor
    func testHomeDirectoryIsNotUsedAsSessionDisplayName() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = NSUserName()

        var unnamed = AgentSession(
            id: "home-unnamed",
            provider: .codex,
            projectName: user,
            workingDirectory: home,
            lastActivityAt: Date()
        )
        XCTAssertEqual(unnamed.displayName, "Session")
        XCTAssertNotEqual(unnamed.displayName, user)

        unnamed.lastUserPrompt = "Fix the weather prompt"
        XCTAssertEqual(unnamed.displayName, "Fix the weather prompt")

        unnamed.workingDirectory = home + "/Desktop"
        unnamed.projectName = "Desktop"
        unnamed.title = nil
        unnamed.focusLabel = nil
        XCTAssertEqual(unnamed.displayName, "Fix the weather prompt")

        unnamed.lastUserPrompt = nil
        unnamed.workingDirectory = "/Volumes/Projects/North-Star"
        unnamed.projectName = "North-Star"
        XCTAssertEqual(unnamed.displayName, "Session")
        XCTAssertNotEqual(unnamed.displayName, "North-Star")

        unnamed.offer("Icon Relocation Idea", from: .client)
        XCTAssertEqual(unnamed.displayName, "Icon Relocation Idea")
    }

    func testCodexSessionUsesItsSessionIdentityAndPromptInsteadOfRolloutOrFolderName() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCodexSessionName-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = "01a04578-2c94-77a1-a87e-2b5a537ce25d"
        let url = directory.appendingPathComponent(
            "rollout-2026-08-27T16-04-58-\(id).jsonl"
        )
        let lines = [
            #"{"timestamp":"2026-08-27T23:04:58.000Z","type":"session_meta","payload":{"id":"01a04578-2c94-77a1-a87e-2b5a537ce25d","cwd":"/Volumes/Projects/North-Star"}}"#,
            #"{"timestamp":"2026-08-27T23:05:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"Fix Nano session naming"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let database = directory.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, name TEXT, updated_at INTEGER NOT NULL);
        INSERT INTO threads VALUES ('\(id)', 'Repair Nano session titles', 1787872000);
        INSERT INTO threads VALUES ('unnamed', NULL, 1787871000);
        """
        var error: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, &error), SQLITE_OK,
                       error.map { String(cString: $0) } ?? "SQLite fixture failed")
        if let error { sqlite3_free(error) }
        sqlite3_close(db)
        db = nil

        let names = AgentCodexThreadNames.index(databaseURL: database)
        XCTAssertEqual(names, [id: "Repair Nano session titles"])

        let session = try XCTUnwrap(
            AgentSessionParsers.parseTranscript(
                at: url,
                provider: .codex,
                codexThreadNames: names
            )
        )
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.displayName, "Repair Nano session titles")
        XCTAssertNotEqual(session.displayName, "North-Star")
    }

    func testCodexAppServerThreadListSuppliesNativeNameMissingFromSQLite() throws {
        let response = #"{"id":2,"result":{"data":[{"id":"01a01da1-6cec-7df2-ae6d-c6cea4720937","name":"UI Changes"},{"id":"unnamed","name":null}]}}"#
        let names = AgentCodexThreadNames.names(fromAppServerLine: Data(response.utf8), requestID: 2)

        XCTAssertEqual(
            names,
            ["01a01da1-6cec-7df2-ae6d-c6cea4720937": "UI Changes"]
        )
    }

    func testCodexSubagentTranscriptIsNotExposedAsATopLevelSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCodexSubagent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("child-rollout.jsonl")
        let lines = [
            #"{"timestamp":"2026-08-27T23:20:31.000Z","type":"session_meta","payload":{"id":"child","cwd":"/tmp/Nano","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1,"agent_path":"/root/provider_hook_review","agent_nickname":"Meitner"}}}}}"#,
            #"{"timestamp":"2026-08-27T23:20:32.000Z","type":"event_msg","payload":{"type":"user_message","message":"Review provider hooks"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        XCTAssertNil(AgentSessionParsers.parseTranscript(at: url, provider: .codex))
    }

    func testSubagentNameUsesReadableTaskSlugWhenBriefIsOpaque() {
        let codex = AgentSubagent(
            type: "/root/provider_hook_review",
            task: "gAAAAABqkSivFfd8jaO5BXnViFUm2Or10CyW0PYT4v2THW6EZw8upBo3P_kRlbPcS9x6slM2nCJeqazm"
        )
        XCTAssertEqual(codex.displayName, "Provider Hook Review")
        XCTAssertNil(codex.roleLabel)

        let claude = AgentSubagent(type: "Explore", task: "Trace session ownership")
        XCTAssertEqual(claude.displayName, "Trace session ownership")
        XCTAssertEqual(claude.roleLabel, "Research")
    }

    func testCombiningTailRefreshPreservesFullyLoadedSubagents() {
        let id = "parent-session"
        var full = AgentSession(
            id: id,
            provider: .codex,
            projectName: "Nano",
            lastActivityAt: Date(timeIntervalSince1970: 100)
        )
        full.subagents = [
            AgentSubagent(
                type: "/root/provider_hook_review",
                task: "gAAAAABqkSivFfd8jaO5BXnViFUm2Or10CyW0PYT4v2THW6EZw8upBo3P_kRlbPcS9x6slM2nCJeqazm"
            )
        ]
        full.linesAdded = 42
        full.linesRemoved = 7

        var tail = AgentSession(
            id: id,
            provider: .codex,
            projectName: "Nano",
            lastActivityAt: Date(timeIntervalSince1970: 200)
        )
        tail.currentActivity = "Ran tests"

        let merged = AgentSessionParsers.combine(full, tail)

        XCTAssertEqual(merged.currentActivity, "Ran tests")
        XCTAssertEqual(merged.subagents.map(\.displayName), ["Provider Hook Review"])
        XCTAssertEqual(merged.linesAdded, 42)
        XCTAssertEqual(merged.linesRemoved, 7)
    }

    func testSparseRefreshPreservesSessionMetadataInEitherMergeOrder() {
        var full = AgentSession(id: "metadata", provider: .codex, projectName: "Nano",
                                lastActivityAt: Date(timeIntervalSince1970: 100))
        full.gitBranch = "main"
        full.startedAt = Date(timeIntervalSince1970: 50)
        full.contextWindow = 200_000
        full.contextUsed = 12_000
        let sparse = AgentSession(id: full.id, provider: .codex, projectName: "Nano",
                                  lastActivityAt: Date(timeIntervalSince1970: 200))
        for merged in [AgentSessionParsers.combine(full, sparse), AgentSessionParsers.combine(sparse, full)] {
            XCTAssertEqual(merged.lastActivityAt, sparse.lastActivityAt)
            XCTAssertEqual(merged.gitBranch, full.gitBranch)
            XCTAssertEqual(merged.startedAt, full.startedAt)
            XCTAssertEqual(merged.contextWindow, full.contextWindow)
            XCTAssertEqual(merged.contextUsed, full.contextUsed)
        }

        var updated = sparse
        updated.gitBranch = "feature"
        updated.startedAt = Date(timeIntervalSince1970: 60)
        updated.contextWindow = 400_000
        updated.contextUsed = 0
        let merged = AgentSessionParsers.combine(full, updated)
        XCTAssertEqual(merged.gitBranch, updated.gitBranch)
        XCTAssertEqual(merged.startedAt, updated.startedAt)
        XCTAssertEqual(merged.contextWindow, updated.contextWindow)
        XCTAssertEqual(merged.contextUsed, 0, "An explicit zero must replace older usage")
    }

    func testClaudeAndPiUseTheirNativeSessionNames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoProviderSessionNames-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let claudeURL = directory.appendingPathComponent("claude-name.jsonl")
        let claudeLines = [
            #"{"type":"ai-title","aiTitle":"Generated Claude title"}"#,
            #"{"type":"custom-title","customTitle":"User's Claude name"}"#,
            #"{"role":"user","message":{"content":[{"type":"text","text":"A much longer Claude prompt"}]}}"#,
        ]
        try (claudeLines.joined(separator: "\n") + "\n")
            .write(to: claudeURL, atomically: true, encoding: .utf8)

        let piURL = directory.appendingPathComponent("pi-name.jsonl")
        let piLines = [
            #"{"type":"session_info","name":"User's Pi name"}"#,
            #"{"role":"user","message":{"content":[{"type":"text","text":"A much longer Pi prompt"}]}}"#,
        ]
        try (piLines.joined(separator: "\n") + "\n")
            .write(to: piURL, atomically: true, encoding: .utf8)

        let claude = try XCTUnwrap(
            AgentSessionParsers.parseTranscript(at: claudeURL, provider: .claude)
        )
        let pi = try XCTUnwrap(
            AgentSessionParsers.parseTranscript(at: piURL, provider: .pi)
        )
        XCTAssertEqual(claude.displayName, "User's Claude name")
        XCTAssertEqual(pi.displayName, "User's Pi name")
    }

    /// A provider-authored completion must not shorten a row's life. Cursor and
    /// Codex mark turns finished; Claude does not. All three linger the same.
    @MainActor
    func testLiveSessionsKeepFinishedSessionsForLingerWindowAcrossProviders() {
        let now = Date()
        let store = AgentSessionStore()
        store.applyHookState([
            "fresh": AgentHookBridge.LiveSessionState(
                sessionID: "fresh",
                source: "cursor",
                lastUserPrompt: "Just completed",
                firstSeen: now.addingTimeInterval(-120),
                lastEventAt: now.addingTimeInterval(-2),
                isWorking: false
            ),
            "stale": AgentHookBridge.LiveSessionState(
                sessionID: "stale",
                source: "cursor",
                lastUserPrompt: "Completed earlier",
                firstSeen: now.addingTimeInterval(-4 * 60 * 60),
                lastEventAt: now.addingTimeInterval(-130),
                isWorking: false
            ),
            "codex-recent": AgentHookBridge.LiveSessionState(
                sessionID: "codex-recent",
                source: "codex",
                lastUserPrompt: "A recent Codex task",
                firstSeen: now.addingTimeInterval(-120),
                lastEventAt: now.addingTimeInterval(-60),
                isWorking: false
            ),
            "claude-recent": AgentHookBridge.LiveSessionState(
                sessionID: "claude-recent",
                source: "claude",
                lastUserPrompt: "A recent Claude task",
                firstSeen: now.addingTimeInterval(-120),
                lastEventAt: now.addingTimeInterval(-90),
                isWorking: false
            ),
        ], now: now)

        XCTAssertNotNil(store.sessions.first { $0.id == "fresh" }?.finishedAt)
        XCTAssertNil(store.sessions.first { $0.id == "claude-recent" }?.finishedAt)

        let visible = store.liveSessions(at: now).map(\.id)
        // Done before Idle, newest first within each.
        XCTAssertEqual(visible, ["fresh", "stale", "codex-recent", "claude-recent"])
        XCTAssertEqual(store.liveSessions(at: now.addingTimeInterval(125)).map(\.id), visible)

        // Each row leaves lingerWindow after its own last event, regardless of
        // whether its provider reported the completion.
        let linger = AgentSessionStore.lingerWindow
        XCTAssertEqual(
            store.liveSessions(at: now.addingTimeInterval(linger - 100)).map(\.id),
            ["fresh", "codex-recent", "claude-recent"]
        )
        XCTAssertTrue(store.liveSessions(at: now.addingTimeInterval(linger + 1)).isEmpty)
        XCTAssertEqual(AgentSessionStore.completionLingerWindow, 2 * 60)
    }

    /// A finished transcript is a recent row like any other: it stays for
    /// lingerWindow, survives a relaunch inside that window, and then leaves.
    @MainActor
    func testFinishedTranscriptLingersLikeAnyRecentRowAcrossRelaunch() {
        let now = Date()
        var working = AgentSession(
            id: "current-launch",
            provider: .codex,
            projectName: "Nano",
            lastActivityAt: now
        )
        working.lastUserPrompt = "Finish session retention"
        working.isActive = true
        let store = AgentSessionStore()
        store.applyIncrementalSessions([working], now: now)

        var finished = working
        finished.isActive = false
        finished.finishedAt = now.addingTimeInterval(1)
        finished.lastActivityAt = now.addingTimeInterval(1)
        store.applyIncrementalSessions([finished], now: now.addingTimeInterval(1))
        let linger = AgentSessionStore.lingerWindow
        XCTAssertEqual(store.liveSessions(at: now.addingTimeInterval(120)).map(\.id), ["current-launch"])
        XCTAssertEqual(store.liveSessions(at: now.addingTimeInterval(122)).map(\.id), ["current-launch"])
        XCTAssertEqual(store.liveSessions(at: now.addingTimeInterval(linger)).map(\.id), ["current-launch"])
        XCTAssertTrue(store.liveSessions(at: now.addingTimeInterval(linger + 2)).isEmpty)

        let relaunched = AgentSessionStore()
        relaunched.applyIncrementalSessions([finished], now: now.addingTimeInterval(2))
        XCTAssertEqual(relaunched.liveSessions(at: now.addingTimeInterval(2)).map(\.id), ["current-launch"])
        XCTAssertTrue(relaunched.liveSessions(at: now.addingTimeInterval(linger + 2)).isEmpty)
    }

    /// A cleared row stays off the island across a relaunch and comes back by
    /// itself as soon as the session writes again.
    @MainActor
    func testDismissedSessionStaysHiddenUntilItIsActiveAgain() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nano-dismissed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let now = Date()
        var quiet = AgentSession(id: "quiet", provider: .claude, projectName: "Nano", lastActivityAt: now)
        quiet.lastUserPrompt = "Done for now"
        var working = AgentSession(id: "working", provider: .codex, projectName: "Nano", lastActivityAt: now)
        working.lastUserPrompt = "Needs an answer"

        let store = AgentSessionStore(dismissalsURL: url)
        store.applyIncrementalSessions([quiet, working], now: now)
        store.applyLiveSignals([:], waiting: ["working"])

        let later = now.addingTimeInterval(5)
        store.dismiss("quiet", now: later)
        store.dismiss("working", now: later)
        XCTAssertEqual(store.liveSessions(at: later).map(\.id), ["working"])
        XCTAssertEqual(store.dismissedSessionCount, 1)

        // A write from before the dismissal, parsed after it, changes nothing.
        quiet.lastActivityAt = now.addingTimeInterval(3)
        store.applyIncrementalSessions([quiet], now: later)
        XCTAssertEqual(store.liveSessions(at: later).map(\.id), ["working"])

        let relaunched = AgentSessionStore(dismissalsURL: url)
        relaunched.applyIncrementalSessions([quiet, working], now: later)
        XCTAssertEqual(relaunched.liveSessions(at: later).map(\.id), ["working"])
        XCTAssertEqual(relaunched.dismissedSessionCount, 1)

        quiet.lastActivityAt = later.addingTimeInterval(30)
        relaunched.applyIncrementalSessions([quiet], now: later.addingTimeInterval(30))
        XCTAssertEqual(
            Set(relaunched.liveSessions(at: later.addingTimeInterval(30)).map(\.id)),
            ["quiet", "working"]
        )

        store.restoreDismissedSessions()
        XCTAssertEqual(Set(store.liveSessions(at: later).map(\.id)), ["quiet", "working"])
        XCTAssertEqual(store.dismissedSessionCount, 0)
    }

    /// The detail view's conversation and file rows come straight from the
    /// transcript: one turn per real prompt, and each edit counted against
    /// the file it touched.
    func testTranscriptYieldsConversationTurnsAndPerFileChanges() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nano-conversation-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        func record(_ role: String, _ content: Any, id: String? = nil) throws -> String {
            var message: [String: Any] = ["role": role, "content": content]
            if let id { message["id"] = id }
            let data = try JSONSerialization.data(withJSONObject: [
                "timestamp": "2026-10-03T16:00:00.000Z",
                "message": message,
            ])
            return String(decoding: data, as: UTF8.self)
        }
        func edit(_ path: String, old: String, new: String) -> [String: Any] {
            ["type": "tool_use", "name": "Edit",
             "input": ["file_path": path, "old_string": old, "new_string": new]]
        }

        let lines = try [
            // A tail read starts mid-line, so the first line is always dropped.
            "{}",
            record("user", "Fix the pick screen.\nIt loses its selection."),
            record("assistant", [["type": "text", "text": "Looking at the flow."]], id: "a1"),
            record("assistant", [
                ["type": "tool_use", "name": "Read", "input": ["file_path": "/p/Flow.swift"]],
                edit("/p/Flow.swift", old: "a", new: "a\nb\nc"),
            ], id: "a2"),
            record("user", "<system-reminder>not typed by anyone</system-reminder>"),
            record("assistant", [["type": "text", "text": "The pick screen **keeps** its selection."]], id: "a3"),
            record("user", "Now the Agents room."),
            record("assistant", [
                edit("/p/Room.swift", old: "x\ny", new: "z"),
                edit("/p/Flow.swift", old: "c", new: "d"),
            ], id: "a4"),
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(AgentSessionParsers.parseTranscript(at: url, provider: .claude))

        XCTAssertEqual(session.conversation.map(\.prompt), [
            "Fix the pick screen. It loses its selection.",
            "Now the Agents room.",
        ])
        XCTAssertEqual(session.conversation.first?.reply, "The pick screen keeps its selection.")
        XCTAssertEqual(session.conversation.first?.toolSummary, "Edited 1 file, read 1")
        XCTAssertNil(session.conversation.first?.fullReply)
        XCTAssertNil(session.conversation.last?.reply)
        XCTAssertEqual(session.conversation.last?.toolSummary, "Edited 2 files")
        XCTAssertEqual(session.displayedTurns.count, 2)

        XCTAssertEqual(session.changedFiles, [
            AgentFileChange(path: "/p/Room.swift", added: 1, removed: 2),
            AgentFileChange(path: "/p/Flow.swift", added: 4, removed: 2),
        ])
        XCTAssertEqual(session.linesAdded, 5)
        XCTAssertEqual(session.linesRemoved, 4)
    }

    /// Hooks deliver a new prompt before the transcript scan sees it, and a
    /// hook-only provider never yields parsed turns at all.
    func testDisplayedTurnsFollowTheLatestPromptAheadOfTheTranscript() {
        var session = AgentSession(id: "s", provider: .claude, projectName: "Nano", lastActivityAt: Date())
        session.lastUserPrompt = "First question"
        session.lastAgentMessage = "First answer"
        XCTAssertEqual(session.displayedTurns, [
            AgentConversationTurn(prompt: "First question", reply: "First answer"),
        ])

        session.conversation = [AgentConversationTurn(prompt: "First question and more", reply: "First answer")]
        XCTAssertEqual(session.displayedTurns.count, 1)

        session.lastUserPrompt = "Second question"
        session.lastAgentMessage = nil
        XCTAssertEqual(session.displayedTurns.map(\.prompt), ["First question and more", "Second question"])
    }

    func testSessionStatesUseFourWordsAndSortNeedsYouFirst() {
        let now = Date()
        var session = AgentSession(id: "lifecycle", provider: .cursor, projectName: "Nano", lastActivityAt: now)
        session.isActive = true
        XCTAssertEqual(session.statusWord(now: now), "Working")
        session.currentActivity = "Editing VoiceDictationController.swift"
        XCTAssertEqual(session.statusDetail(now: now), "Editing VoiceDictationController.swift")
        session.isActive = false
        session.finishedAt = now.addingTimeInterval(-240)
        XCTAssertEqual(session.statusWord(now: now), "Done 4m ago")
        session.finishedAt = nil
        XCTAssertEqual(session.statusWord(now: now), "Idle")

        var waiting = AgentSession(id: "w", provider: .claude, projectName: "Nano", lastActivityAt: now.addingTimeInterval(-600))
        waiting.needsAttention = true
        var working = AgentSession(id: "a", provider: .claude, projectName: "Nano", lastActivityAt: now)
        working.isActive = true
        var done = AgentSession(id: "d", provider: .claude, projectName: "Nano", lastActivityAt: now)
        done.finishedAt = now
        let idle = AgentSession(id: "i", provider: .claude, projectName: "Nano", lastActivityAt: now)
        XCTAssertEqual([idle, done, working, waiting].sorted(by: AgentSession.byPhase).map(\.id), ["w", "a", "d", "i"])
    }

    @MainActor
    func testReviewNotificationDismissesOnlyAfterVerifiedNavigation() {
        XCTAssertTrue(IslandViewModel.shouldDismissAgentAttention(
            respondsThroughBridge: false,
            result: .opened
        ))
        XCTAssertFalse(IslandViewModel.shouldDismissAgentAttention(
            respondsThroughBridge: false,
            result: .hostActivated
        ))
        XCTAssertFalse(IslandViewModel.shouldDismissAgentAttention(
            respondsThroughBridge: false,
            result: .unavailable
        ))
        XCTAssertFalse(IslandViewModel.shouldDismissAgentAttention(
            respondsThroughBridge: true,
            result: .opened
        ))
        XCTAssertFalse(IslandViewModel.shouldDismissAgentAttention(
            respondsThroughBridge: false,
            result: .accessibilityRequired
        ))
    }

    @MainActor
    func testSessionFilesystemMonitorReportsDirectoryAndFileChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = root.appendingPathComponent("session.jsonl")
        try Data("first\n".utf8).write(to: transcript)
        let directoryChanged = expectation(description: "new session file discovered")
        let fileChanged = expectation(description: "known session file updated")
        var sawDirectory = false
        var sawFile = false
        let monitor = AgentSessionFilesystemMonitor { change in
            switch change {
            case .directory where !sawDirectory:
                sawDirectory = true
                directoryChanged.fulfill()
            case .file where !sawFile:
                sawFile = true
                fileChanged.fulfill()
            default:
                break
            }
        }
        monitor.update(directories: [root], files: [transcript])

        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()
        try Data().write(to: root.appendingPathComponent("new-session.jsonl"))

        await fulfillment(of: [directoryChanged, fileChanged], timeout: 2)
        XCTAssertTrue(sawDirectory)
        XCTAssertTrue(sawFile)
        monitor.stop()
    }

    func testSessionIntegrityScanUsesTwelveMinuteRecoveryInterval() {
        XCTAssertEqual(AgentSessionStore.integrityScanInterval, 12 * 60)
    }

    func testSessionDiscoveryReservesLaterProviderAfterLargeEarlierTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cursor = root.appendingPathComponent("cursor")
        let codex = root.appendingPathComponent("codex")
        let today = codex.appendingPathComponent("2026/09/07")
        try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
        for index in 0..<1_100 {
            try FileManager.default.createDirectory(
                at: cursor.appendingPathComponent("old-\(index)/nested"),
                withIntermediateDirectories: true
            )
        }
        let watched = AgentSessionParsers.filesystemMonitoringDirectories(roots: [cursor, codex])
        XCTAssertLessThanOrEqual(watched.count, 1_024)
        XCTAssertTrue(watched.map(\.path).contains(codex.path), "Every provider must retain discovery coverage")
        XCTAssertTrue(watched.map { $0.resolvingSymlinksInPath().path }.contains(today.resolvingSymlinksInPath().path),
                      "Old Cursor folders must not hide today's Codex sessions")
    }

    func testSessionDiscoveryReservesActiveFolderBeforeArchiveBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = root.appendingPathComponent("provider")
        let active = provider.appendingPathComponent("old/deep/active")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let watched = AgentSessionParsers.filesystemMonitoringDirectories(
            limit: 2, roots: [provider], activeFiles: [active.appendingPathComponent("session.jsonl")]
        )
        XCTAssertEqual(Set(watched.map(\.path)), Set([provider.path, active.path]))
    }

    func testSessionReconciliationDetectsMissedCreationAndMidnightRollover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = ISO8601DateFormatter().date(from: "2026-09-08T08:00:00Z")!
        let targets = AgentSessionParsers.recentCodexDiscoveryDirectories(now: now, base: root)
        let today = root.appendingPathComponent("2026/09/08")
        XCTAssertTrue(targets.contains(today))
        let before = AgentSessionFilesystemSnapshot.capture(directories: targets, files: [])
        try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
        try Data("new session\n".utf8).write(to: today.appendingPathComponent("new.jsonl"))
        let after = AgentSessionFilesystemSnapshot.capture(directories: targets, files: [])
        XCTAssertTrue(after.changes(since: before).contains {
            if case .directory(let url) = $0 { return url == today }
            return false
        })
        XCTAssertTrue(after.changes(since: after).isEmpty)
        XCTAssertEqual(AgentSessionStore.reconciliationInterval, 5)
    }

    func testSessionReconciliationDetectsQuietDirectoryFileAppendAndReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session.jsonl")
        try Data("first\n".utf8).write(to: file)
        let before = AgentSessionFilesystemSnapshot.capture(directories: [root], files: [file])
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("resumed\n".utf8))
        try handle.close()
        let appended = AgentSessionFilesystemSnapshot.capture(directories: [root], files: [file])
        XCTAssertEqual(appended.changes(since: before).count, 1)
        guard case .file(let changed) = appended.changes(since: before).first else {
            return XCTFail("A resumed session must refresh even if its directory did not change")
        }
        XCTAssertEqual(changed, file)
        try Data("replacement\n".utf8).write(to: file, options: .atomic)
        let replaced = AgentSessionFilesystemSnapshot.capture(directories: [root], files: [file])
        XCTAssertTrue(replaced.changes(since: appended).contains {
            if case .file(let url) = $0 { return url == file }
            return false
        })
    }

    @MainActor
    func testSessionReconciliationUsesIndependentCallbackAndStopsCleanly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("session.jsonl")
        try Data("first\n".utf8).write(to: file)
        // Deliberately ignore vnode callbacks, as if the host missed an event.
        let monitor = AgentSessionFilesystemMonitor { _ in }
        var reconciled: [AgentSessionFilesystemChange] = []
        monitor.didReconcile = { reconciled.append($0) }
        monitor.update(directories: [root], files: [file])
        await monitor.reconcile()
        reconciled = []
        await monitor.reconcile()
        XCTAssertTrue(reconciled.isEmpty, "Unchanged ticks must not trigger parsing")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("working\n".utf8))
        try handle.close()
        await monitor.reconcile()
        XCTAssertTrue(reconciled.contains {
            if case .file(let url) = $0 { return url.path == file.path }
            return false
        })
        reconciled = []
        monitor.stop()
        await monitor.reconcile()
        XCTAssertTrue(reconciled.isEmpty)
    }

    func testKnownTranscriptChangeParsesOnlyThatSession() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoIncrementalSession-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let changed = directory.appendingPathComponent("changed.jsonl")
        let untouched = directory.appendingPathComponent("untouched.jsonl")
        let changedLines = [
            #"{"timestamp":"2026-08-25T20:00:00.000Z","type":"session_meta","payload":{"cwd":"/tmp/Nano"}}"#,
            #"{"timestamp":"2026-08-25T20:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"Refresh only me"}}"#,
        ]
        let untouchedLines = [
            #"{"timestamp":"2026-08-25T20:00:00.000Z","type":"session_meta","payload":{"cwd":"/tmp/Other"}}"#,
            #"{"timestamp":"2026-08-25T20:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"Do not parse me"}}"#,
        ]
        try (changedLines.joined(separator: "\n") + "\n")
            .write(to: changed, atomically: true, encoding: .utf8)
        try (untouchedLines.joined(separator: "\n") + "\n")
            .write(to: untouched, atomically: true, encoding: .utf8)

        let result = AgentSessionParsers.parseIncrementalChanges([
            changed.standardizedFileURL.path: .codex,
        ])

        XCTAssertEqual(result.map(\.id), ["changed"])
        XCTAssertEqual(result.first?.lastUserPrompt, "Refresh only me")
        XCTAssertFalse(result.contains { $0.id == "untouched" })
    }

    func testCursorStoreSessionReadsMetaPromptAndTools() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCursorStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let meta: [String: Any] = [
            "schemaVersion": 1,
            "cwd": "/tmp/Nano",
            "title": "Icon Relocation Idea",
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: directory.appendingPathComponent("meta.json"))

        let store = directory.appendingPathComponent("store.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = #"""
        CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO meta VALUES ('0', '{"agentId":"ses-acp","lastUsedModel":"grok-4.6","createdAt":1700000000000}');
        INSERT INTO blobs VALUES ('user', '{"role":"user","content":[{"type":"text","text":"<timestamp>Sunday, Aug 16, 2026, 9:49 PM (UTC-7)</timestamp>\n<user_query>\nMove the top part of these icons\n</user_query>"}]}');
        INSERT INTO blobs VALUES ('asst', '{"role":"assistant","content":[{"type":"tool-call","toolName":"Read","args":{"path":"/tmp/Nano/IslandRootView.swift"}}]}');
        """#
        var error: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, &error), SQLITE_OK,
                       error.map { String(cString: $0) } ?? "SQLite fixture failed")
        if let error { sqlite3_free(error) }
        sqlite3_close(db)
        db = nil

        let session = try XCTUnwrap(AgentSessionParsers.parseCursorStore(at: directory))
        XCTAssertEqual(session.provider, .cursor)
        XCTAssertEqual(session.projectName, "Nano")
        XCTAssertEqual(session.workingDirectory, "/tmp/Nano")
        XCTAssertEqual(session.displayName, "Icon Relocation Idea")
        XCTAssertEqual(session.model, "grok-4.6")
        XCTAssertEqual(session.lastUserPrompt, "Move the top part of these icons")
        XCTAssertEqual(session.startedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(session.recentActivity.contains { $0.detail.contains("IslandRootView.swift") })

        let incremental = AgentSessionParsers.parseIncrementalChanges([
            store.standardizedFileURL.path: .cursor,
        ])
        XCTAssertEqual(incremental.count, 1)
        XCTAssertEqual(incremental.first?.provider, .cursor)
        XCTAssertEqual(incremental.first?.lastUserPrompt, "Move the top part of these icons")
    }

    func testCursorStoreReadsCreatedAtAndSystemModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCursorModel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "cwd": "/tmp/Nano",
            "title": "Hover Activation Issue",
        ]).write(to: directory.appendingPathComponent("meta.json"))

        let store = directory.appendingPathComponent("store.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = #"""
        CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO meta VALUES ('0', '{"agentId":"ses-acp","name":"Hover Activation Issue","createdAt":1786942172965}');
        INSERT INTO blobs VALUES ('sys', '{"role":"system","content":"You are an AI coding assistant, powered by Cursor Grok 4.6. You are an interactive CLI tool."}');
        INSERT INTO blobs VALUES ('user', '{"role":"user","content":[{"type":"text","text":"<user_query>rework hover activation</user_query>"}]}');
        """#
        var error: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, &error), SQLITE_OK,
                       error.map { String(cString: $0) } ?? "SQLite fixture failed")
        if let error { sqlite3_free(error) }
        sqlite3_close(db)
        db = nil

        let session = try XCTUnwrap(AgentSessionParsers.parseCursorStore(at: directory))
        XCTAssertEqual(session.model, "Grok 4.6")
        XCTAssertEqual(AgentModuleView.modelName(session.model ?? ""), "Grok 4.6")
        XCTAssertEqual(AgentModuleView.modelName("Cursor Grok 4.6"), "Grok 4.6")
        XCTAssertEqual(AgentModuleView.modelName("Fable 5 Thinking Medium"), "Fable 5")
        XCTAssertEqual(AgentModuleView.modelName("fable-5-thinking-high"), "Fable 5")
        XCTAssertEqual(AgentModuleView.modelName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(AgentModuleView.modelName("claude-sonnet-4-5-20250929"), "Sonnet 4.5")
        XCTAssertEqual(session.startedAt, Date(timeIntervalSince1970: 1_786_942_172.965))
        XCTAssertEqual(session.lastUserPrompt, "rework hover activation")
    }

    func testCursorStoreListScanFillsPromptAndTools() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCursorList-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "cwd": "/tmp/Nano",
            "title": "Cursor Usage UI",
        ]).write(to: directory.appendingPathComponent("meta.json"))

        let store = directory.appendingPathComponent("store.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = #"""
        CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO meta VALUES ('0', '{"agentId":"ses-acp","createdAt":1700000000000}');
        INSERT INTO blobs VALUES ('user', '{"role":"user","content":[{"type":"text","text":"<user_query>Rework the usage UI</user_query>"}]}');
        INSERT INTO blobs VALUES ('asst', '{"role":"assistant","content":[{"type":"reasoning","text":"looking"},{"type":"tool-call","toolName":"Shell","args":{"command":"xcodebuild -scheme Nano test"}}]}');
        """#
        var error: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, &error), SQLITE_OK,
                       error.map { String(cString: $0) } ?? "SQLite fixture failed")
        if let error { sqlite3_free(error) }
        sqlite3_close(db)
        db = nil

        let session = try XCTUnwrap(
            AgentSessionParsers.parseCursorStore(at: directory, fullHistory: false)
        )
        XCTAssertEqual(session.lastUserPrompt, "Rework the usage UI")
        XCTAssertTrue(session.recentActivity.contains { $0.detail.contains("xcodebuild") })
        XCTAssertEqual(session.currentActivity, session.recentActivity.last?.detail)
    }

    func testHookSessionIDAcceptsProviderSpellings() {
        XCTAssertEqual(
            AgentHookBridge.sessionID(fromHook: [
                "event": ["conversation_id": "conv-cursor", "hook_event_name": "postToolUse"],
            ]),
            "conv-cursor"
        )
        XCTAssertEqual(
            AgentHookBridge.sessionID(fromHook: [
                "event": ["session_id": "ses-claude"],
            ]),
            "ses-claude"
        )
        XCTAssertEqual(
            AgentHookBridge.sessionID(fromHook: [
                "event": ["sessionId": "ses-acp"],
            ]),
            "ses-acp"
        )
        XCTAssertEqual(
            AgentHookBridge.sessionID(fromHook: [
                "sessionID": "top-level",
                "event": [:] as [String: Any],
            ]),
            "top-level"
        )
        XCTAssertNil(AgentHookBridge.sessionID(fromHook: ["event": ["hook_event_name": "stop"]]))
    }

    func testGrokHookEventNamesCanonicalizeAndRetag() {
        XCTAssertEqual(AgentHookBridge.canonicalHookEventName("pre_tool_use"), "PreToolUse")
        XCTAssertEqual(AgentHookBridge.canonicalHookEventName("post_tool_use"), "PostToolUse")
        XCTAssertEqual(AgentHookBridge.canonicalHookEventName("user_prompt_submit"), "UserPromptSubmit")
        XCTAssertEqual(AgentHookBridge.canonicalHookEventName("session_start"), "SessionStart")
        XCTAssertEqual(AgentHookBridge.canonicalHookEventName("stop_cancelled"), "StopCancelled")
        XCTAssertEqual(AgentHookBridge.canonicalHookEventName("permission_denied"), "PermissionDenied")
        XCTAssertEqual(AgentHookBridge.canonicalHookEventName("afterAgentResponse"), "AfterAgentResponse")
        XCTAssertEqual(AgentHookBridge.canonicalHookEventName("AfterAgent"), "AfterAgent")
        XCTAssertEqual(AgentHookBridge.canonicalHookEventName("PostToolUse"), "PostToolUse")

        let grokEvent: [String: Any] = [
            "hookEventName": "pre_tool_use",
            "sessionId": "01a0-grok",
            "workspaceRoot": "/tmp/Nano",
            "toolName": "read_file",
        ]
        XCTAssertTrue(AgentHookBridge.looksLikeGrokHook(grokEvent))
        XCTAssertEqual(
            AgentHookBridge.eventName(fromHook: ["source": "claude", "event": grokEvent]),
            "PreToolUse"
        )
        XCTAssertEqual(
            AgentHookBridge.sessionID(fromHook: ["source": "claude", "event": grokEvent]),
            "01a0-grok"
        )

        XCTAssertFalse(AgentHookBridge.looksLikeGrokHook([
            "hook_event_name": "PostToolUse",
            "session_id": "ses-claude",
            "cwd": "/tmp/Nano",
        ]))
    }

    @MainActor
    func testHookEventPublishesOneUIChange() async throws {
        let bridge = AgentHookBridge()
        var changes = 0
        let observation = bridge.objectWillChange.sink { changes += 1 }
        defer { observation.cancel() }

        let data = try JSONSerialization.data(withJSONObject: [
            "source": "grok",
            "event": [
                "hookEventName": "pre_tool_use",
                "sessionId": "grok-one-update",
                "workspaceRoot": "/tmp/Nano",
                "toolName": "read_file",
            ],
        ])
        _ = await bridge.handle(data)

        XCTAssertEqual(changes, 1)
    }

    func testPiSessionUsesSharedTranscriptParser() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoPiSession-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("pi-session.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let lines = [
            #"{"cwd":"/tmp/Nano","role":"user","message":{"content":[{"type":"text","text":"Watch Pi sessions"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/Nano/README.md"}}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        let session = try XCTUnwrap(
            AgentSessionParsers.parseTranscript(at: url, provider: .pi, projectDirectory: "-tmp-Nano")
        )
        XCTAssertEqual(session.provider, .pi)
        XCTAssertEqual(session.lastUserPrompt, "Watch Pi sessions")
        XCTAssertTrue(session.recentActivity.contains { $0.detail.contains("README.md") })
    }

    func testSessionDiscoveryRootsIncludeCursorStoresAndPi() {
        let roots = AgentSessionParsers.sessionDiscoveryRoots().map(\.path)
        XCTAssertTrue(roots.contains { $0.hasSuffix("/.cursor/acp-sessions") })
        XCTAssertTrue(roots.contains { $0.hasSuffix("/.cursor/chats") })
        XCTAssertTrue(roots.contains { $0.hasSuffix("/.cursor/projects") })
        XCTAssertTrue(roots.contains { $0.hasSuffix("/.pi/agent/sessions") })
        XCTAssertTrue(roots.contains { $0.hasSuffix("/.grok/sessions") })
    }

    func testGrokSessionReadsSummarySignalsAndToolCalls() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoGrokSession-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let summary = """
        {"info":{"id":"01a0-grok","cwd":"/tmp/Nano"},"generated_title":"Wire Grok into Nano","current_model_id":"grok-4.6","created_at":"2026-08-19T15:00:00.000Z"}
        """
        try Data(summary.utf8).write(to: directory.appendingPathComponent("summary.json"))
        let signals = """
        {"contextTokensUsed":265718,"contextWindowTokens":500000,"primaryModelId":"grok-4.6"}
        """
        try Data(signals.utf8).write(to: directory.appendingPathComponent("signals.json"))
        let updates = """
        {"timestamp":1770983427,"method":"session/update","params":{"update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Add Grok CLI tracking"}}}}
        {"timestamp":1770983428,"method":"session/update","params":{"update":{"sessionUpdate":"tool_call","title":"read_file","rawInput":{"target_file":"/tmp/Nano/README.md"},"_meta":{"x.ai/tool":{"name":"read_file","kind":"read"}}}}}
        """
        let updatesURL = directory.appendingPathComponent("updates.jsonl")
        try Data((updates + "\n").utf8).write(to: updatesURL)

        let session = try XCTUnwrap(
            AgentSessionParsers.parseGrokSession(at: directory, fullHistory: true)
        )
        XCTAssertEqual(session.id, "01a0-grok")
        XCTAssertEqual(session.provider, .grok)
        XCTAssertEqual(session.displayName, "Wire Grok into Nano")
        XCTAssertEqual(session.lastUserPrompt, "Add Grok CLI tracking")
        XCTAssertEqual(session.model, "grok-4.6")
        XCTAssertEqual(session.contextUsed, 265718)
        XCTAssertEqual(session.contextWindow, 500000)
        XCTAssertTrue(session.recentActivity.contains { $0.detail.contains("README.md") })

        let incremental = AgentSessionParsers.parseIncrementalChanges([
            updatesURL.standardizedFileURL.path: .grok,
        ])
        XCTAssertEqual(incremental.map(\.id), ["01a0-grok"])
        XCTAssertEqual(incremental.first?.lastUserPrompt, "Add Grok CLI tracking")
    }

    func testCursorHookCoverageDoesNotSuppressFileWatches() {
        let now = Date()
        let states = [
            "conv-cursor": AgentHookBridge.LiveSessionState(
                sessionID: "conv-cursor",
                source: "cursor",
                firstSeen: now,
                lastEventAt: now,
                isWorking: true
            ),
            "ses-claude": AgentHookBridge.LiveSessionState(
                sessionID: "ses-claude",
                source: "claude",
                firstSeen: now,
                lastEventAt: now,
                isWorking: true
            ),
        ]
        XCTAssertFalse(AgentSessionStore.hasRecentHookCoverage(for: .cursor, in: states, now: now))
        XCTAssertTrue(AgentSessionStore.hasRecentHookCoverage(for: .claude, in: states, now: now))
    }

    func testHookSourceMapsEverySupportedAgent() {
        for provider in AgentProviderID.supported {
            XCTAssertEqual(
                AgentProviderID.fromHook(source: provider.rawValue),
                provider,
                provider.rawValue
            )
        }
        XCTAssertEqual(AgentProviderID.fromHook(source: "claude", providerID: "grok"), .grok)
        XCTAssertNil(AgentProviderID.fromHook(source: "unknown-agent"))
    }

    func testHookActivityDetailMatchesTheWorkingChipVocabulary() {
        let now = Date()
        var state = AgentHookBridge.LiveSessionState(
            sessionID: "01a0-grok",
            source: "grok",
            firstSeen: now,
            lastEventAt: now,
            isWorking: true
        )
        XCTAssertEqual(AgentStatusService.hookActivityDetail(from: state), "Writing a response")

        state.lastTool = "read_file"
        state.lastToolInputDescription = "Read README.md"
        XCTAssertEqual(AgentStatusService.hookActivityDetail(from: state), "Reading README.md")

        state.lastToolInputDescription = "Edited IslandRootView.swift"
        XCTAssertEqual(
            AgentStatusService.hookActivityDetail(from: state),
            "Editing IslandRootView.swift"
        )

        state.lastToolInputDescription = nil
        state.lastTool = "run_terminal_command"
        XCTAssertEqual(AgentStatusService.hookActivityDetail(from: state), "Using run_terminal_command")
    }
}

private final class NanoLayoutMeasurement: @unchecked Sendable {
    var size: CGSize = .zero
}

private struct NanoLayoutProbe: Layout {
    let measurement: NanoLayoutMeasurement

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        measurement.size = subviews[0].sizeThatFits(proposal)
        return proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        subviews[0].place(at: bounds.origin, proposal: proposal)
    }
}

/// Answers every request with `response`, standing in for the update feed.
final class StubUpdateFeedProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (Int, Data) = (404, Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.response
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
