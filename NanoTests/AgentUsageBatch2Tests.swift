import XCTest
@testable import Nano

/// Covers the second usage batch: Devin, Kilo Code, Gemini, Cline, and
/// OpenCode. Every test drives the adapters with stub transport and fixture
/// credentials - no live calls, no real keychain, no vendor files touched.
final class AgentUsageBatch2Tests: XCTestCase {
    private func stubbed(
        _ handler: @escaping (URLRequest) throws -> (Int, Data)
    ) -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            let (status, data) = try handler(request)
            return (data, HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!)
        }
    }

    private func temporaryHome() -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoUsageBatch2-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func iso(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Devin

    func testDevinCredentialsPreferEnvTokenAndTomlHost() throws {
        let home = temporaryHome()
        try write(
            """
            windsurf_api_key = "file-token"
            devin_webapp_host = "https://staging.devin.example/"
            """,
            to: home.appendingPathComponent(".local/share/devin/credentials.toml")
        )

        let file = try XCTUnwrap(
            DevinUsageAdapter.credentials(environment: [:], home: home))
        XCTAssertEqual(file.token, "file-token")
        XCTAssertEqual(file.host, "staging.devin.example")

        let env = try XCTUnwrap(DevinUsageAdapter.credentials(
            environment: ["DEVIN_BEARER_TOKEN": "env-token"], home: home))
        XCTAssertEqual(env.token, "env-token")
        XCTAssertEqual(env.host, "staging.devin.example")

        let bare = try XCTUnwrap(DevinUsageAdapter.credentials(
            environment: ["DEVIN_BEARER_TOKEN": "env-token"],
            home: temporaryHome()))
        XCTAssertEqual(bare.host, "app.devin.ai")

        XCTAssertNil(DevinUsageAdapter.credentials(environment: [:], home: temporaryHome()))
    }

    func testDevinSelectsPrimaryOrganizationThenQuotaPath() async throws {
        let home = temporaryHome()
        var requested: [URLRequest] = []
        let result = await DevinUsageAdapter.fetch(
            environment: ["DEVIN_BEARER_TOKEN": "token"],
            home: home,
            load: stubbed { request in
                requested.append(request)
                if request.url!.path == "/api/organizations" {
                    return (200, Data(#"""
                    [
                      {"org_id": "org-first", "display_name": "First", "is_primary_org": false},
                      {"org_id": "org-main", "display_name": "Main", "is_primary_org": true}
                    ]
                    """#.utf8))
                }
                XCTAssertEqual(
                    request.url!.path, "/api/org-main/billing/quota/usage")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-cog-org-id"), "org-main")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
                return (200, Data(#"""
                {
                  "is_quota_plan": true,
                  "daily_percentage": 0,
                  "weekly_percentage": 100,
                  "daily_reset_at": "2026-08-13T00:00:00Z",
                  "weekly_reset_at": "2026-08-18T00:00:00Z",
                  "plan_name": "acme"
                }
                """#.utf8))
            })

        XCTAssertEqual(requested.count, 2)
        XCTAssertEqual(result.planName, "acme")
        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.windows.count, 2)
        XCTAssertEqual(result.windows[0].usedPercent, 0)
        XCTAssertEqual(
            result.windows[0].resetsAt,
            iso("2026-08-13T00:00:00Z"))
        XCTAssertEqual(result.windows[1].usedPercent, 100)
        XCTAssertEqual(
            result.windows[1].resetsAt,
            iso("2026-08-18T00:00:00Z"))
    }

    func testDevinUsesFirstOrganizationWhenNoneMarkedPrimary() async throws {
        var quotaPath: String?
        _ = await DevinUsageAdapter.fetch(
            environment: ["DEVIN_BEARER_TOKEN": "token"],
            home: temporaryHome(),
            load: stubbed { request in
                if request.url!.path == "/api/organizations" {
                    return (200, Data(#"""
                    [{"org_id": "org-a"}, {"org_id": "org-b"}]
                    """#.utf8))
                }
                quotaPath = request.url!.path
                return (200, Data(#"{"is_quota_plan": false}"#.utf8))
            })
        XCTAssertEqual(quotaPath, "/api/org-a/billing/quota/usage")
    }

    func testDevinNoOrgDetailIsNotASignedOutError() async throws {
        var requests = 0
        let result = await DevinUsageAdapter.fetch(
            environment: ["DEVIN_BEARER_TOKEN": "token"],
            home: temporaryHome(),
            load: stubbed { _ in
                requests += 1
                return (403, Data(
                    #"{"detail":"No organizations found for auth1 user"}"#.utf8))
            })
        // The quota request must never fire without an org, and the result is
        // a quiet no-data state rather than a sign-in failure.
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertFalse(result.hasQuota)
        XCTAssertEqual(result.message, "No Devin organization on this account.")
    }

    func testDevinFlatPercentagesAreAlwaysPoints() throws {
        // Live 2026-09-23 response sent weekly_percentage: 100 - the flat
        // fields are percentage points, never fractions.
        var result = try DevinUsageAdapter.parse(Data(#"""
        {"daily_percentage": 0, "weekly_percentage": 100, "is_quota_plan": true}
        """#.utf8))
        XCTAssertEqual(result.windows[0].usedPercent, 0, accuracy: 0.001)
        XCTAssertEqual(result.windows[1].usedPercent, 100, accuracy: 0.001)

        result = try DevinUsageAdapter.parse(Data(#"""
        {"daily_percentage": 1, "weekly_percentage": 0.5, "is_quota_plan": true}
        """#.utf8))
        XCTAssertEqual(result.windows[0].usedPercent, 1, accuracy: 0.001)
        XCTAssertEqual(result.windows[1].usedPercent, 0.5, accuracy: 0.001)

        result = try DevinUsageAdapter.parse(Data(#"""
        {"weekly_percentage": 42, "is_quota_plan": true}
        """#.utf8))
        XCTAssertEqual(result.windows.map(\.id), ["devin.weekly"])
        XCTAssertEqual(result.windows[0].usedPercent, 42, accuracy: 0.001)
    }

    func testDevinNestedFallbackKeepsFractionHeuristic() throws {
        // Unverified nested shapes keep CodexBar's <= 1 fraction rule; the
        // remaining_percent variant inverts to used.
        let result = try DevinUsageAdapter.parse(Data(#"""
        {"is_quota_plan": true,
         "quota_usage": {"daily_quota": {"remaining_percent": 0.25}}}
        """#.utf8))
        XCTAssertEqual(result.windows.map(\.id), ["devin.daily"])
        XCTAssertEqual(result.windows[0].usedPercent, 75, accuracy: 0.001)
    }

    func testDevinHideDailyOmitsTheDailyWindow() throws {
        let result = try DevinUsageAdapter.parse(Data(#"""
        {
          "is_quota_plan": true,
          "hide_daily_quota": true,
          "daily_percentage": 0.5,
          "weekly_percentage": 0.1
        }
        """#.utf8))
        XCTAssertEqual(result.windows.map(\.id), ["devin.weekly"])
    }

    func testDevinNonQuotaPlanIsValidEmptyState() throws {
        let result = try DevinUsageAdapter.parse(Data(#"""
        {"is_quota_plan": false, "plan_name": "core"}
        """#.utf8))
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertFalse(result.hasQuota)
        XCTAssertEqual(result.planName, "core")
        XCTAssertNotNil(result.message)
    }

    // MARK: - Kilo Code

    func testKiloCredentialReadsAuthJSONAndHonorsExpiry() throws {
        let home = temporaryHome()
        let future = Int(Date().timeIntervalSince1970 * 1000) + 86_400_000
        try write(
            #"{"kilo":{"access":"kilo-token","accountId":"acct-1","expires":\#(future)}}"#,
            to: home.appendingPathComponent(".local/share/kilo/auth.json")
        )

        let credential = try XCTUnwrap(
            KiloUsageAdapter.credential(environment: [:], home: home))
        XCTAssertEqual(credential.token, "kilo-token")
        XCTAssertEqual(credential.accountID, "acct-1")

        let env = try XCTUnwrap(KiloUsageAdapter.credential(
            environment: ["KILO_API_KEY": "env-key"], home: home))
        XCTAssertEqual(env.token, "env-key")

        let expired = Int(Date().timeIntervalSince1970 * 1000) - 1000
        try write(
            #"{"kilo":{"access":"kilo-token","expires":\#(expired)}}"#,
            to: home.appendingPathComponent(".local/share/kilo/auth.json")
        )
        XCTAssertNil(KiloUsageAdapter.credential(environment: [:], home: home))
    }

    func testKiloFetchSendsBearerAndAccountHeaders() async throws {
        let home = temporaryHome()
        try write(
            #"{"kilo":{"access":"kilo-token","accountId":"acct-9"}}"#,
            to: home.appendingPathComponent(".local/share/kilo/auth.json")
        )

        var captured: URLRequest?
        _ = await KiloUsageAdapter.fetch(
            environment: [:],
            home: home,
            load: stubbed { req in
                captured = req
                return (200, Data(#"[{"result":{"data":{"json":null}}}]"#.utf8))
            })

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url!.host, "app.kilo.ai")
        XCTAssertTrue(request.url!.path.contains(
            "user.getCreditBlocks,kiloPass.getState"))
        XCTAssertTrue(request.url!.query?.contains("batch=1") == true)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"), "Bearer kilo-token")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-KILOCODE-ORGANIZATIONID"), "acct-9")
    }

    func testKiloParsesPassWindowAndCreditBlocks() throws {
        // CodexBar fixture shape: tRPC batch, data under result.data, pass
        // subscription at index 1, credit blocks at index 0.
        let result = try KiloUsageAdapter.parse(Data(#"""
        [
          {"result":{"data":{"creditBlocks":[
            {"id":"cb-1","amount_mUsd":19000000,"balance_mUsd":19000000}
          ],"totalBalance_mUsd":19000000}}},
          {"result":{"data":{"subscription":{
            "tier":"tier_19",
            "currentPeriodUsageUsd":0,
            "currentPeriodBaseCreditsUsd":19.0,
            "currentPeriodBonusCreditsUsd":9.5,
            "nextBillingAt":"2026-03-28T04:00:00.000Z"
          }}}}
        ]
        """#.utf8))

        XCTAssertEqual(result.planName, "Starter")
        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.windows.count, 2)

        let pass = try XCTUnwrap(result.windows.first { $0.id == "kilo.pass" })
        XCTAssertEqual(pass.usedPercent, 0, accuracy: 0.001)
        XCTAssertEqual(pass.resetsAt, iso("2026-03-28T04:00:00.000Z"))

        let credits = try XCTUnwrap(result.windows.first { $0.id == "kilo.credits" })
        XCTAssertEqual(credits.usedPercent, 0, accuracy: 0.001)
    }

    func testKiloExhaustedBalanceReportsFullUsage() throws {
        let result = try KiloUsageAdapter.parse(Data(#"""
        [
          {"result":{"data":{"creditBlocks":[],"totalBalance_mUsd":0}}},
          {"result":{"data":{"subscription":{"tier":"tier_49"}}}}
        ]
        """#.utf8))
        XCTAssertEqual(result.planName, "Pro")
        let credits = try XCTUnwrap(result.windows.first { $0.id == "kilo.credits" })
        XCTAssertEqual(credits.usedPercent, 100, accuracy: 0.001)
    }

    func testKiloUnauthorizedEntryIsSignOut() async throws {
        let home = temporaryHome()
        try write(
            #"{"kilo":{"access":"kilo-token"}}"#,
            to: home.appendingPathComponent(".local/share/kilo/auth.json")
        )
        let result = await KiloUsageAdapter.fetch(
            environment: [:],
            home: home,
            load: stubbed { _ in
                (200, Data(#"[{"error":{"json":{"data":{"code":"UNAUTHORIZED"}}}}]"#.utf8))
            })
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.message?.contains("expired") == true)
    }

    // MARK: - Gemini

    func testGeminiBucketSelectionPicksLowestRemainingPerTier() throws {
        let result = try GeminiUsageAdapter.parse(Data(#"""
        {"buckets":[
          {"modelId":"gemini-2.5-pro","remainingFraction":0.25,"resetTime":"2026-08-13T00:00:00Z"},
          {"modelId":"gemini-2.0-pro-exp","remainingFraction":0.5},
          {"modelId":"gemini-2.5-flash","remainingFraction":0.9,"resetTime":"2026-08-12T12:00:00Z"},
          {"modelId":"gemini-2.5-flash-lite","remainingFraction":1.0}
        ]}
        """#.utf8))

        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.windows.map(\.id),
                       ["gemini.pro", "gemini.flash", "gemini.flashLite"])
        // Remaining fraction inverts to used percent.
        XCTAssertEqual(result.windows[0].usedPercent, 75, accuracy: 0.001)
        XCTAssertEqual(result.windows[0].label, "Pro · 24h")
        XCTAssertEqual(
            result.windows[0].resetsAt, iso("2026-08-13T00:00:00Z"))
        XCTAssertEqual(result.windows[1].usedPercent, 10, accuracy: 0.001)
        XCTAssertEqual(result.windows[2].usedPercent, 0, accuracy: 0.001)
    }

    func testGeminiExpiredTokenRefreshesWithExtractedClient() async throws {
        let home = temporaryHome()
        try write(
            #"{"access_token":"old-access","refresh_token":"refresh-1","expiry_date":1}"#,
            to: home.appendingPathComponent(".gemini/oauth_creds.json")
        )
        let cache = temporaryHome().appendingPathComponent("gemini-cache.json")

        var sawRefresh = false
        var projectBody = ""
        let result = await GeminiUsageAdapter.fetch(
            environment: [
                "GEMINI_OAUTH_CLIENT_ID": "client-id",
                "GEMINI_OAUTH_CLIENT_SECRET": "client-secret",
            ],
            home: home,
            cacheFile: cache,
            load: stubbed { request in
                switch request.url!.absoluteString {
                case "https://oauth2.googleapis.com/token":
                    sawRefresh = true
                    let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                    XCTAssertTrue(body.contains("grant_type=refresh_token"))
                    XCTAssertTrue(body.contains("refresh_token=refresh-1"))
                    XCTAssertTrue(body.contains("client_id=client-id"))
                    return (200, Data(#"""
                    {"access_token":"new-access","expires_in":3600}
                    """#.utf8))
                case let url where url.contains("loadCodeAssist"):
                    return (200, Data(#"""
                    {"cloudaicompanionProject":"proj-1","paidTier":{"name":"Google AI Pro"}}
                    """#.utf8))
                case let url where url.contains("retrieveUserQuota"):
                    projectBody = String(
                        data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                    XCTAssertEqual(
                        request.value(forHTTPHeaderField: "Authorization"),
                        "Bearer new-access")
                    return (200, Data(#"""
                    {"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.5}]}
                    """#.utf8))
                default:
                    return (404, Data())
                }
            })

        XCTAssertTrue(sawRefresh)
        XCTAssertTrue(projectBody.contains("proj-1"))
        XCTAssertEqual(result.planName, "Google AI Pro")
        XCTAssertEqual(result.windows.first?.usedPercent ?? -1, 50, accuracy: 0.001)

        // The vendor file is never written; the refreshed token landed in
        // Nano's own cache.
        let vendorFile = try String(
            contentsOf: home.appendingPathComponent(".gemini/oauth_creds.json"),
            encoding: .utf8)
        XCTAssertTrue(vendorFile.contains("old-access"))
        let cached = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertTrue(cached.contains("new-access"))
    }

    func testGeminiNoCredentialsYieldsNoData() async throws {
        var calls = 0
        let result = await GeminiUsageAdapter.fetch(
            environment: [:],
            home: temporaryHome(),
            cacheFile: temporaryHome().appendingPathComponent("missing.json"),
            load: stubbed { _ in calls += 1; return (200, Data()) })
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertFalse(result.hasQuota)
    }

    func testGeminiOAuthFileExtraction() throws {
        let file = temporaryHome().appendingPathComponent("oauth2.js")
        try write(
            """
            const OAUTH_CLIENT_ID = '12345.apps.googleusercontent.com';
            const OAUTH_CLIENT_SECRET = 'GOCSPX-secret-value';
            """,
            to: file)
        let credentials = try XCTUnwrap(
            GeminiUsageAdapter.oauthCredentials(inFile: file.path))
        XCTAssertEqual(credentials.id, "12345.apps.googleusercontent.com")
        XCTAssertEqual(credentials.secret, "GOCSPX-secret-value")
    }

    // MARK: - Cline

    func testClineCredentialOrderAndClineOnlyEntries() throws {
        let home = temporaryHome()

        // A providers.json carrying only another provider's key must not leak.
        try write(
            #"{"providers":{"openrouter":{"settings":{"apiKey":"other-key"}}}}"#,
            to: home.appendingPathComponent(".cline/data/settings/providers.json")
        )
        XCTAssertNil(ClineUsageAdapter.apiKey(environment: [:], home: home))

        // clineApiKey in secrets.json is the CLI's stored key.
        try write(#"{"clineApiKey":"secret-key"}"#,
                  to: home.appendingPathComponent(".cline/data/secrets.json"))
        XCTAssertEqual(
            ClineUsageAdapter.apiKey(environment: [:], home: home), "secret-key")

        // providers.json auth.accessToken beats secrets.json.
        try write(
            #"{"providers":{"cline":{"settings":{"auth":{"accessToken":"tok-1"},"apiKey":"key-1"}}}}"#,
            to: home.appendingPathComponent(".cline/data/settings/providers.json")
        )
        XCTAssertEqual(
            ClineUsageAdapter.apiKey(environment: [:], home: home), "tok-1")

        // Environment always wins, CLINE_API_KEY first.
        XCTAssertEqual(
            ClineUsageAdapter.apiKey(
                environment: ["CLINEPASS_API_KEY": "pass"], home: home), "pass")
        XCTAssertEqual(
            ClineUsageAdapter.apiKey(
                environment: ["CLINE_API_KEY": "api", "CLINEPASS_API_KEY": "pass"],
                home: home), "api")
    }

    func testClineParsesFixtureLimits() throws {
        // CodexBarTests/ClinePassPluginTests.swift fixture shape.
        let result = try ClineUsageAdapter.parse(Data(#"""
        {"success":true,"data":{"limits":[
          {"type":"five_hour","percentUsed":12.5,"resetsAt":"2026-07-16T10:20:30Z"},
          {"type":"weekly","percentUsed":34,"resetsAt":"2026-07-20T00:00:00Z"},
          {"type":"monthly","percentUsed":56.75,"resetsAt":"2026-08-01T00:00:00Z"},
          {"type":"experimental_pool","percentUsed":77,"resetsAt":"2026-07-16T15:00:00Z"}
        ]}}
        """#.utf8))

        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.windows.map(\.id),
                       ["cline.fiveHour", "cline.weekly", "cline.monthly"])
        XCTAssertEqual(result.windows.map(\.label), ["5h", "7d", "30d"])
        XCTAssertEqual(result.windows[0].usedPercent, 12.5, accuracy: 0.001)
        XCTAssertEqual(
            result.windows[0].resetsAt, iso("2026-07-16T10:20:30Z"))
        XCTAssertEqual(result.windows[2].usedPercent, 56.75, accuracy: 0.001)
    }

    func testClineEmptyLimitsIsNoQuotaPlan() throws {
        let result = try ClineUsageAdapter.parse(Data(#"""
        {"success":true,"data":{"limits":[]}}
        """#.utf8))
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertFalse(result.hasQuota)
    }

    func testClineRejectsNonNumericPercent() throws {
        XCTAssertThrowsError(try ClineUsageAdapter.parse(Data(#"""
        {"success":true,"data":{"limits":[{"type":"weekly","percentUsed":"forty"}]}}
        """#.utf8)))
    }

    // MARK: - OpenCode Go

    func testOpenCodeIgnoresVendorEntriesAndPrefersGoKey() throws {
        let home = temporaryHome()
        let auth = home.appendingPathComponent(".local/share/opencode/auth.json")

        // Vendor keys stored alongside are not OpenCode credentials.
        try write(
            #"{"moonshotai":{"type":"api","key":"sk-moon"},"kimi-for-coding":{"type":"api","key":"sk-kimi"}}"#,
            to: auth)
        XCTAssertNil(OpenCodeUsageAdapter.apiKey(environment: [:], home: home))

        // Non-api entries are skipped.
        try write(
            #"{"opencode-go":{"type":"oauth","key":"oauth-key"},"opencode":{"type":"api","key":"oc-key"}}"#,
            to: auth)
        XCTAssertEqual(
            OpenCodeUsageAdapter.apiKey(environment: [:], home: home), "oc-key")

        // opencode-go wins over the shared opencode entry.
        try write(
            #"{"opencode":{"type":"api","key":"oc-key"},"opencode-go":{"type":"api","key":"go-key"}}"#,
            to: auth)
        XCTAssertEqual(
            OpenCodeUsageAdapter.apiKey(environment: [:], home: home), "go-key")

        XCTAssertEqual(
            OpenCodeUsageAdapter.apiKey(
                environment: ["OPENCODE_API_KEY": "env-key"], home: home),
            "env-key")
    }

    func testOpenCodeParsesRollingWeeklyMonthly() throws {
        // CodexBarTests/OpenCodeGoUsageFetcherErrorTests.swift fixture shape:
        // percent is already whole points, resetsAt ISO.
        let result = try OpenCodeUsageAdapter.parse(Data(#"""
        {"usage":{
          "rolling":{"percent":42,"resetsAt":"2026-08-12T20:00:00Z"},
          "weekly":{"percent":17,"resetsAt":"2026-08-18T00:00:00Z"},
          "monthly":{"percent":3,"resetsAt":"2026-09-01T00:00:00Z"}
        }}
        """#.utf8))

        XCTAssertTrue(result.hasQuota)
        XCTAssertEqual(result.planName, "OpenCode Go")
        XCTAssertEqual(result.windows.map(\.id),
                       ["opencode.rolling", "opencode.weekly", "opencode.monthly"])
        XCTAssertEqual(result.windows.map(\.label), ["5h", "7d", "30d"])
        XCTAssertEqual(result.windows[0].usedPercent, 42, accuracy: 0.001)
        XCTAssertEqual(
            result.windows[0].resetsAt, iso("2026-08-12T20:00:00Z"))
    }

    func testOpenCodeMissingUsageMeansNoSubscription() throws {
        for body in [#"{}"#, #"{"usage":null}"#] {
            let result = try OpenCodeUsageAdapter.parse(Data(body.utf8))
            XCTAssertTrue(result.windows.isEmpty)
            XCTAssertFalse(result.hasQuota)
        }
    }

    func testOpenCode401And403AreDistinctStates() async throws {
        let home = temporaryHome()
        try write(
            #"{"opencode-go":{"type":"api","key":"go-key"}}"#,
            to: home.appendingPathComponent(".local/share/opencode/auth.json")
        )

        for (status, expected) in [
            (401, "OpenCode sign-in expired"),
            (403, "No OpenCode Go quota"),
        ] {
            var request: URLRequest?
            let result = await OpenCodeUsageAdapter.fetch(
                environment: [:],
                home: home,
                load: stubbed { req in request = req; return (status, Data()) })
            XCTAssertEqual(
                request?.value(forHTTPHeaderField: "Authorization"), "Bearer go-key")
            XCTAssertTrue(result.windows.isEmpty)
            XCTAssertTrue(result.message?.contains(expected) == true,
                          "HTTP \(status) gave \(result.message ?? "nil")")
        }
    }

    // MARK: - Wiring

    @MainActor
    func testUsageBatch1MigrationEnablesNewProvidersAndRespectsOptOut() {
        let suiteName = "NanoTests.usageBatch1.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // An install that predates the usage batch: only the original
        // usage-capable providers are stored, flag unset.
        defaults.set(
            ["claude", "codex", "cursor", "grok", "kimi"],
            forKey: "agents.usageProviders")

        let batch: [AgentProviderID] = [.devin, .kilo, .gemini, .cline, .opencode]
        let migrated = NanoSettings(defaults: defaults)
        for provider in batch {
            XCTAssertTrue(migrated.usageProviders.contains(provider),
                          "\(provider) missing after migration")
        }
        XCTAssertTrue(defaults.bool(forKey: "agents.trackUsageBatch1"))
        // Persisted, not just in memory.
        let stored = Set(defaults.stringArray(forKey: "agents.usageProviders") ?? [])
        for provider in batch {
            XCTAssertTrue(stored.contains(provider.rawValue))
        }
        // Pi, Goose, and Qwen stay out - no quota exists for them.
        for provider in [AgentProviderID.pi, .goose, .qwen] {
            XCTAssertFalse(migrated.usageProviders.contains(provider))
        }

        // Opting out after the flag is set must stick across relaunches.
        migrated.setUsageEnabled(false, provider: .devin)
        let reloaded = NanoSettings(defaults: defaults)
        XCTAssertFalse(reloaded.usageProviders.contains(.devin))
        XCTAssertTrue(reloaded.usageProviders.contains(.kilo))
    }

    func testDisabledUsageTooltipsAreProviderSpecific() {
        XCTAssertEqual(
            AgentProviderID.pi.usageUnavailableHelp,
            "Pi runs on your own provider keys — their quota shows under that provider.")
        XCTAssertEqual(
            AgentProviderID.goose.usageUnavailableHelp,
            "Goose runs on your own provider keys — their quota shows under that provider.")
        XCTAssertEqual(
            AgentProviderID.qwen.usageUnavailableHelp,
            "Qwen Code does not publish a quota Nano can read.")
        XCTAssertEqual(
            AgentProviderID.windsurf.usageUnavailableHelp,
            "Windsurf does not publish a quota Nano can read")
    }
}
