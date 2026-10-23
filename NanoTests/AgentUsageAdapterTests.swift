import XCTest
@testable import Nano

final class AgentUsageAdapterTests: XCTestCase {
    @MainActor
    func testUsageSelectionKeepsProviderIdentityWhenSnapshotsReorder() {
        let firstOrder: [AgentProviderID] = [.codex, .cursor, .claude]
        let secondOrder: [AgentProviderID] = [.claude, .codex, .cursor]

        XCTAssertEqual(
            AgentUsagePill.selectedProviderID(
                storedRawValue: AgentProviderID.cursor.rawValue,
                availableProviderIDs: firstOrder
            ),
            .cursor
        )
        XCTAssertEqual(
            AgentUsagePill.selectedProviderID(
                storedRawValue: AgentProviderID.cursor.rawValue,
                availableProviderIDs: secondOrder
            ),
            .cursor
        )
    }

    @MainActor
    func testUsageSelectionFallsBackAndCyclesFromTheDisplayedProvider() {
        let available: [AgentProviderID] = [.claude, .cursor, .codex]

        XCTAssertEqual(
            AgentUsagePill.selectedProviderID(
                storedRawValue: AgentProviderID.grok.rawValue,
                availableProviderIDs: available
            ),
            .claude
        )
        XCTAssertEqual(
            AgentUsagePill.nextProviderID(
                storedRawValue: AgentProviderID.grok.rawValue,
                availableProviderIDs: available
            ),
            .cursor
        )
        XCTAssertNil(
            AgentUsagePill.selectedProviderID(
                storedRawValue: AgentProviderID.cursor.rawValue,
                availableProviderIDs: []
            )
        )
    }

    func testCursorWorkingStateUsesTheUnfinishedTranscriptTurn() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCursorActivity-\(UUID().uuidString)", isDirectory: true)
        let transcript = directory.appendingPathComponent("active.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try [
            #"{"role":"user","message":{"content":[{"type":"text","text":"Fix Nano"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"path":"Nano.swift"}}]}}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        XCTAssertTrue(AgentStatusService.cursorTaskIsActive(in: transcript))

        try [
            #"{"role":"user","message":{"content":[{"type":"text","text":"Fix Nano"}]}}"#,
            #"{"role":"assistant","message":{"content":[{"type":"text","text":"Done"}]}}"#,
            #"{"type":"turn_ended","status":"success"}"#,
        ].joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)

        XCTAssertFalse(AgentStatusService.cursorTaskIsActive(in: transcript))
    }

    func testCursorActivityDiscoveryIgnoresNewerMCPMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCursorDiscovery-\(UUID().uuidString)", isDirectory: true)
        let sessionID = UUID().uuidString
        let transcriptDirectory = root
            .appendingPathComponent("projects/demo/agent-transcripts", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        let transcript = transcriptDirectory.appendingPathComponent("\(sessionID).jsonl")
        let finishedID = UUID().uuidString
        let finishedDirectory = root
            .appendingPathComponent("projects/demo/agent-transcripts", isDirectory: true)
            .appendingPathComponent(finishedID, isDirectory: true)
        let finished = finishedDirectory.appendingPathComponent("\(finishedID).jsonl")
        let unrelated = root.appendingPathComponent("projects/demo/mcps/tool.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: transcriptDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: unrelated.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: finishedDirectory,
            withIntermediateDirectories: true
        )
        try #"{"role":"user","message":{"content":[{"type":"text","text":"Keep working"}]}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        try [
            #"{"role":"user"}"#,
            #"{"type":"turn_ended","status":"success"}"#,
        ].joined(separator: "\n")
            .write(to: finished, atomically: true, encoding: .utf8)
        try #"{"name":"browser_click"}"#
            .write(to: unrelated, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: finished.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: unrelated.path
        )

        XCTAssertEqual(
            AgentStatusService.newestCursorActivityFile(in: root)?.standardizedFileURL,
            transcript.standardizedFileURL
        )
    }

    func testEverySupportedProviderHasADistinctAccent() {
        let accents = AgentProviderID.supported.map(\.accentComponents)

        XCTAssertEqual(Set(accents).count, AgentProviderID.supported.count)
    }

    func testPartialCursorHooksDoNotDisableTranscriptActivityFallback() {
        XCTAssertEqual(
            AgentStatusService.providersWithCompleteHookCoverage([.cursor, .claude]),
            [.claude]
        )
    }

    func testCursorParseMapsTheTwoMonthlyPoolsAndDropsTheOldBars() throws {
        let result = try CursorUsageAdapter.parse(fixture(
            membership: "ultra",
            auto: 1.2,
            api: 17.4,
            total: 9.8,
            limit: 400,
            cycleEnd: "2099-09-16T00:00:00.000Z"
        ))

        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.planName, "ultra")
        XCTAssertEqual(result.windows.map(\.id), ["cursor.models", "cursor.other"])
        XCTAssertEqual(result.windows.map(\.label), ["Cursor Models", "Other Models"])
        XCTAssertEqual(result.windows[0].usedPercent, 1.2, accuracy: 0.001)
        XCTAssertEqual(result.windows[1].usedPercent, 17.4, accuracy: 0.001)

        let ids = Set(result.windows.map(\.id))
        XCTAssertFalse(ids.contains("cursor.total"))
        XCTAssertFalse(ids.contains("cursor.auto"))
        XCTAssertFalse(ids.contains("cursor.api"))
        XCTAssertFalse(ids.contains("cursor.cycle"))
        XCTAssertFalse(result.windows.contains { $0.label.lowercased().contains("week") })

        XCTAssertNotNil(result.windows[0].resetsAt)
        XCTAssertEqual(result.windows[0].resetsAt, result.windows[1].resetsAt)
        XCTAssertNotNil(result.windows[0].resetAfterSeconds)
        if let remaining = result.windows[0].resetAfterSeconds {
            XCTAssertGreaterThan(remaining, 0)
        }
    }

    func testCursorParseTreatsAZeroLimitPlanAsHavingNoQuota() throws {
        let result = try CursorUsageAdapter.parse(fixture(
            membership: "hobby",
            auto: 0,
            api: 0,
            total: 0,
            limit: 0,
            cycleEnd: "2026-09-16T00:00:00.000Z"
        ))

        XCTAssertFalse(result.hasQuota)
        XCTAssertEqual(result.message, "No included quota on this plan.")
    }

    func testCursorParseReadsTeamDisplayMessagesWhenPlanIsMissing() throws {
        let json = """
        {
          "billingCycleEnd": "2026-09-16T00:00:00.000Z",
          "membershipType": "enterprise",
          "autoModelSelectedDisplayMessage": "You've used 42% of your included total usage",
          "namedModelSelectedDisplayMessage": "You've used 7.5% of your included API usage"
        }
        """
        let result = try CursorUsageAdapter.parse(Data(json.utf8))

        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.planName, "enterprise")
        XCTAssertEqual(result.windows.map(\.id), ["cursor.models", "cursor.other"])
        XCTAssertEqual(result.windows[0].usedPercent, 42, accuracy: 0.001)
        XCTAssertEqual(result.windows[1].usedPercent, 7.5, accuracy: 0.001)
    }

    func testCursorParseIgnoresASingleTeamMessageSoItCannotInventAPool() throws {
        let json = """
        {
          "membershipType": "enterprise",
          "autoModelSelectedDisplayMessage": "You've used 42% of your included total usage"
        }
        """
        let result = try CursorUsageAdapter.parse(Data(json.utf8))

        XCTAssertFalse(result.hasQuota)
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testCursorParseMarksUnlimitedPlansAsHavingNoQuota() throws {
        let json = """
        {
          "membershipType": "enterprise",
          "isUnlimited": true,
          "individualUsage": {
            "plan": {
              "limit": 400,
              "autoPercentUsed": 12,
              "apiPercentUsed": 8
            }
          }
        }
        """
        let result = try CursorUsageAdapter.parse(Data(json.utf8))

        XCTAssertFalse(result.hasQuota)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.message, "Unlimited included usage.")
    }

    @MainActor
    func testCursorPillKeepsPoolNamesAndShowsOneSharedMonthlyReset() {
        let reset = 31 * 86_400
        let windows = [
            NanoUsageWindow(
                id: "cursor.other",
                label: "Other Models",
                usedPercent: 17,
                resetsAt: Date().addingTimeInterval(TimeInterval(reset)),
                resetAfterSeconds: reset
            ),
            NanoUsageWindow(
                id: "cursor.models",
                label: "Cursor Models",
                usedPercent: 1,
                resetsAt: Date().addingTimeInterval(TimeInterval(reset)),
                resetAfterSeconds: reset
            ),
        ]

        XCTAssertEqual(AgentUsagePill.canonicalLabel(windows[0]), "Other Models")
        XCTAssertEqual(AgentUsagePill.canonicalLabel(windows[1]), "Cursor Models")
        XCTAssertEqual(AgentUsagePill.ordered(windows).map(\.id), ["cursor.models", "cursor.other"])
        XCTAssertEqual(AgentUsagePill.sharedReset(windows), "31d")
    }

    @MainActor
    func testSharedResetStaysOffWhenWindowsAlreadyNameTheirOwnPeriod() {
        let windows = [
            NanoUsageWindow(
                id: "codex.primary",
                label: "5h",
                usedPercent: 10,
                resetsAt: nil,
                resetAfterSeconds: 3_600
            ),
            NanoUsageWindow(
                id: "codex.secondary",
                label: "7d",
                usedPercent: 20,
                resetsAt: nil,
                resetAfterSeconds: 6 * 86_400
            ),
        ]

        XCTAssertNil(AgentUsagePill.sharedReset(windows))
        XCTAssertEqual(AgentUsagePill.ordered(windows).map(\.label), ["5h", "7d"])
    }

    func testResetCountdownFollowsTheResetDateNotTheFetchTimeFigure() {
        let moving = NanoUsageWindow(
            id: "codex.primary",
            label: "5h",
            usedPercent: 10,
            resetsAt: Date().addingTimeInterval(1_800),
            resetAfterSeconds: 3_600
        )
        XCTAssertEqual(moving.resetCountdown, "30m")

        let alreadyReset = NanoUsageWindow(
            id: "codex.primary",
            label: "5h",
            usedPercent: 10,
            resetsAt: Date().addingTimeInterval(-60),
            resetAfterSeconds: 3_600
        )
        XCTAssertNil(alreadyReset.resetCountdown)
    }

    func testCountdownOmitsZeroRemainders() {
        XCTAssertEqual(NanoUsageFormat.countdown(seconds: 31 * 86_400), "31d")
        XCTAssertEqual(NanoUsageFormat.countdown(seconds: 5 * 86_400 + 3_600), "5d1h")
        XCTAssertEqual(NanoUsageFormat.countdown(seconds: 3 * 3_600), "3h")
        XCTAssertEqual(NanoUsageFormat.countdown(seconds: 3 * 3_600 + 240), "3h4m")
        XCTAssertEqual(NanoUsageFormat.countdown(seconds: 12 * 60), "12m")
    }

    func testClaudeParseReadsLegacyUtilizationWindows() throws {
        let json = """
        {
          "five_hour": { "utilization": 12.5, "resets_at": "2026-08-17T06:00:00Z" },
          "seven_day": { "utilization": 40, "resets_at": 1786665600 },
          "seven_day_opus": { "used_percentage": 8 }
        }
        """
        let result = try ClaudeUsageAdapter.parse(Data(json.utf8))
        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.windows.map(\.id), ["claude.five_hour", "claude.seven_day", "claude.opus"])
        XCTAssertEqual(result.windows[0].usedPercent, 12.5, accuracy: 0.001)
        XCTAssertEqual(result.windows[1].usedPercent, 40, accuracy: 0.001)
        XCTAssertEqual(result.windows[2].usedPercent, 8, accuracy: 0.001)
        XCTAssertEqual(result.windows[0].label, "5h")
        XCTAssertEqual(result.windows[1].label, "7d")
    }

    func testClaudeParseKeepsOnePercentUtilization() throws {
        let json = """
        { "five_hour": { "utilization": 1.0, "resets_at": "2026-08-17T06:00:00.528743+00:00" } }
        """
        let result = try ClaudeUsageAdapter.parse(Data(json.utf8))
        XCTAssertEqual(result.windows[0].usedPercent, 1, accuracy: 0.001)
    }

    func testClaudeAccessTokenSkipsEmptyKeychainEnvelope() {
        XCTAssertNil(ClaudeUsageAdapter.accessToken(in: [
            "claudeAiOauth": [
                "accessToken": "",
                "refreshToken": "",
                "expiresAt": 0,
            ]
        ]))
        XCTAssertEqual(
            ClaudeUsageAdapter.accessToken(in: [
                "claudeAiOauth": ["accessToken": "sk-ant-oat01-test"]
            ]),
            "sk-ant-oat01-test"
        )
    }

    func testClaudeCredentialsIgnoreRefreshTokenAndReportExpiry() throws {
        // A refresh token alone is not usable: Nano never spends Claude Code's.
        XCTAssertNil(ClaudeUsageAdapter.credentials(in: [
            "claudeAiOauth": ["accessToken": "", "refreshToken": "refresh-test"] as [String: Any]
        ]))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = try XCTUnwrap(ClaudeUsageAdapter.credentials(in: [
            "claudeAiOauth": [
                "accessToken": "access-test",
                "refreshToken": "refresh-test",
                "expiresAt": (now.timeIntervalSince1970 - 10) * 1000,
            ] as [String: Any]
        ]))
        XCTAssertTrue(expired.isExpired(now: now))

        let live = try XCTUnwrap(ClaudeUsageAdapter.credentials(in: [
            "claudeAiOauth": [
                "accessToken": "access-test",
                "expiresAt": (now.timeIntervalSince1970 + 3_600) * 1000,
            ] as [String: Any]
        ]))
        XCTAssertFalse(live.isExpired(now: now))

        let noExpiry = try XCTUnwrap(ClaudeUsageAdapter.credentials(in: ["accessToken": "access-test"]))
        XCTAssertFalse(noExpiry.isExpired(now: now))
    }

    func testClaudeParseReadsLiveKindAndPercentLimits() throws {
        let json = """
        {
          "five_hour": { "utilization": 0.0, "resets_at": null },
          "seven_day": { "utilization": 8.0, "resets_at": "2026-08-20T18:00:00.057648+00:00" },
          "limits": [
            {
              "kind": "session",
              "percent": 0,
              "resets_at": null,
              "is_active": false
            },
            {
              "kind": "weekly_all",
              "percent": 8,
              "resets_at": "2026-08-20T18:00:00.057648+00:00",
              "is_active": true
            }
          ]
        }
        """
        let result = try ClaudeUsageAdapter.parse(Data(json.utf8))
        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.windows.map(\.id), ["claude.five_hour", "claude.seven_day"])
        XCTAssertEqual(result.windows[0].usedPercent, 0, accuracy: 0.001)
        XCTAssertEqual(result.windows[1].usedPercent, 8, accuracy: 0.001)
        XCTAssertEqual(result.windows[0].label, "5h")
        XCTAssertEqual(result.windows[1].label, "7d")
        XCTAssertNotNil(result.windows[1].resetsAt)
    }

    func testClaudeParseFallsBackToLegacyBucketsWhenLimitsAreUnrecognized() throws {
        let json = """
        {
          "five_hour": { "utilization": 3 },
          "seven_day": { "utilization": 11 },
          "limits": [{ "kind": "unknown_pool", "percent": 99 }]
        }
        """
        let result = try ClaudeUsageAdapter.parse(Data(json.utf8))
        XCTAssertEqual(result.windows.map(\.id), ["claude.five_hour", "claude.seven_day"])
        XCTAssertEqual(result.windows[0].usedPercent, 3, accuracy: 0.001)
        XCTAssertEqual(result.windows[1].usedPercent, 11, accuracy: 0.001)
    }

    func testClaudeParseReadsLimitsArray() throws {
        let json = """
        {
          "limits": [
            { "type": "session", "utilization": 22, "resets_at": "2026-08-17T06:00:00Z" },
            { "type": "weekly_all", "used_percentage": 31 }
          ]
        }
        """
        let result = try ClaudeUsageAdapter.parse(Data(json.utf8))
        XCTAssertEqual(result.windows.map(\.id), ["claude.five_hour", "claude.seven_day"])
        XCTAssertEqual(result.windows[0].usedPercent, 22, accuracy: 0.001)
        XCTAssertEqual(result.windows[1].usedPercent, 31, accuracy: 0.001)
    }

    @MainActor
    func testDisplayableKeepsEnabledProvidersWithoutQuotaNumbers() {
        let suiteName = "NanoTests.displayable.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = NanoSettings(defaults: defaults)

        let claude = AgentProviderSnapshot(
            id: .claude,
            isConfigured: true,
            isActive: false,
            projectName: nil,
            lastActivityAt: nil,
            usage: [],
            usageMessage: nil,
            hasQuota: false
        )
        let cursor = AgentProviderSnapshot(
            id: .cursor,
            isConfigured: true,
            isActive: false,
            projectName: nil,
            lastActivityAt: nil,
            usage: [
                NanoUsageWindow(
                    id: "cursor.models",
                    label: "Cursor Models",
                    usedPercent: 1,
                    resetsAt: nil,
                    resetAfterSeconds: nil
                )
            ],
            usageMessage: nil,
            hasQuota: true
        )

        let visible = AgentUsagePill.displayable([cursor, claude], settings: settings)
        XCTAssertEqual(Set(visible.map(\.id)), [.claude, .cursor])
    }

    func testGrokParseMapsCreditWindowAndDropsZeroLimits() throws {
        let json = """
        {
          "billingCycle": {
            "billingPeriodStart": "2026-08-01T00:00:00Z",
            "billingPeriodEnd": "2026-09-01T00:00:00Z"
          },
          "monthlyLimit": { "val": 99900 },
          "usage": {
            "includedUsed": { "val": 12345 },
            "totalUsed": { "val": 12345 }
          }
        }
        """
        let result = try GrokUsageAdapter.parse(Data(json.utf8))
        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].id, "grok.credits")
        XCTAssertEqual(result.windows[0].usedPercent, 12345.0 / 99900.0 * 100, accuracy: 0.001)
        XCTAssertNotNil(result.windows[0].resetsAt)

        let empty = try GrokUsageAdapter.parse(Data(#"{"monthlyLimit":{"val":0},"usage":{"totalUsed":{"val":10}}}"#.utf8))
        XCTAssertFalse(empty.hasQuota)
        XCTAssertTrue(empty.windows.isEmpty)
    }

    func testGrokParseReadsCliChatProxyCreditsConfig() throws {
        let json = """
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2026-08-16T00:08:40.207189+00:00",
              "end": "2026-08-23T00:08:40.207189+00:00"
            },
            "creditUsagePercent": 1.0,
            "productUsage": [
              { "product": "GrokBuild", "usagePercent": 1.0 },
              { "product": "GrokChat" }
            ],
            "billingPeriodStart": "2026-08-16T00:08:40.207189+00:00",
            "billingPeriodEnd": "2026-08-23T00:08:40.207189+00:00"
          }
        }
        """
        let result = try GrokUsageAdapter.parse(Data(json.utf8))
        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].id, "grok.credits")
        XCTAssertEqual(result.windows[0].label, "Weekly")
        XCTAssertEqual(result.windows[0].usedPercent, 1.0, accuracy: 0.001)
        XCTAssertNotNil(result.windows[0].resetsAt)
    }

    func testGrokParseTreatsOmittedWeeklyPercentAsZeroUsage() throws {
        let json = """
        {
          "config": {
            "currentPeriod": {
              "type": "USAGE_PERIOD_TYPE_WEEKLY",
              "start": "2099-08-16T00:08:40Z",
              "end": "2099-08-23T00:08:40Z"
            },
            "isUnifiedBillingUser": true,
            "onDemandCap": {},
            "onDemandUsed": {},
            "prepaidBalance": {}
          }
        }
        """
        let result = try GrokUsageAdapter.parse(Data(json.utf8))
        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].label, "Weekly")
        XCTAssertEqual(result.windows[0].usedPercent, 0, accuracy: 0.001)
        XCTAssertNotNil(result.windows[0].resetsAt)
    }

    private func fixture(
        membership: String,
        auto: Double,
        api: Double,
        total: Double,
        limit: Double,
        cycleEnd: String
    ) -> Data {
        Data("""
        {
          "billingCycleStart": "2026-08-16T00:00:00.000Z",
          "billingCycleEnd": "\(cycleEnd)",
          "membershipType": "\(membership)",
          "isUnlimited": false,
          "individualUsage": {
            "plan": {
              "enabled": true,
              "used": 20,
              "limit": \(limit),
              "remaining": 380,
              "autoPercentUsed": \(auto),
              "apiPercentUsed": \(api),
              "totalPercentUsed": \(total)
            },
            "onDemand": { "enabled": false, "used": 0 }
          }
        }
        """.utf8)
    }
}
