import XCTest
@testable import Nano

/// Hook installation and presence scanning both read this one table, so the
/// per-agent home directory is the contract worth pinning down.
final class AgentRoutesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NanoRouteTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ name: String) -> String {
        root.appendingPathComponent(name).path
    }

    func testEverySupportedProviderRootLivesUnderHome() {
        let expected: [AgentProviderID: String] = [
            .claude: ".claude",
            .codex: ".codex",
            .cursor: ".cursor",
            .gemini: ".gemini",
            .grok: ".grok",
            .kimi: ".kimi-code",
            .opencode: ".config/opencode",
            .pi: ".pi/agent",
            .devin: ".config/devin",
            .cline: ".cline",
            .qwen: ".qwen",
            .kilo: ".config/kilo",
            .goose: ".config/goose",
        ]
        for provider in AgentProviderID.supported {
            XCTAssertEqual(
                AgentRoutes.root(for: provider, home: root, environment: [:]).path,
                path(expected[provider] ?? provider.rawValue),
                "\(provider.rawValue) root"
            )
        }
    }

    func testEnvironmentOverridesRoots() {
        let environment = [
            "CODEX_HOME": path("cx"),
            "GROK_HOME": path("gk"),
            "CLAUDE_CONFIG_DIR": path("cl"),
            "OPENCODE_CONFIG_DIR": path("oc"),
        ]
        for (provider, expected) in [
            (AgentProviderID.codex, "cx"),
            (.grok, "gk"),
            (.claude, "cl"),
            (.opencode, "oc"),
        ] {
            XCTAssertEqual(
                AgentRoutes.root(for: provider, home: root, environment: environment).path,
                path(expected)
            )
        }

        // A stray whitespace-only export must not blank the default root.
        XCTAssertEqual(
            AgentRoutes.root(for: .codex, home: root, environment: ["CODEX_HOME": "   "]).path,
            path(".codex")
        )

        // `~/...` values resolve against the real home, not the injected one.
        XCTAssertEqual(
            AgentRoutes.root(for: .codex, home: root, environment: ["CODEX_HOME": "~/cx"]).path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("cx").path
        )
    }

    func testBatchOneRootsAndOverrides() {
        XCTAssertEqual(
            AgentRoutes.root(for: .cline, home: root, environment: ["CLINE_DIR": path("cln")]).path,
            path("cln")
        )
        XCTAssertEqual(
            AgentRoutes.root(for: .qwen, home: root, environment: ["QWEN_HOME": path("qw")]).path,
            path("qw")
        )
        // XDG_CONFIG_HOME moves the Kilo and Goose roots off ~/.config.
        XCTAssertEqual(
            AgentRoutes.root(for: .kilo, home: root, environment: ["XDG_CONFIG_HOME": path("xdg")]).path,
            path("xdg/kilo")
        )
        XCTAssertEqual(
            AgentRoutes.root(for: .goose, home: root, environment: ["XDG_CONFIG_HOME": path("xdg")]).path,
            path("xdg/goose")
        )
        // GOOSE_PATH_ROOT wins, but only when absolute.
        XCTAssertEqual(
            AgentRoutes.root(for: .goose, home: root, environment: ["GOOSE_PATH_ROOT": path("gr")]).path,
            path("gr")
        )
        XCTAssertEqual(
            AgentRoutes.root(
                for: .goose, home: root, environment: ["GOOSE_PATH_ROOT": "relative/goose"]
            ).path,
            path(".config/goose")
        )
    }
}
