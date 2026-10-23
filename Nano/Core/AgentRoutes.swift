import Foundation

/// The single table of agent home directories, so hook installation and
/// presence detection agree on where each agent lives. Environment overrides
/// win over the defaults, matching how each CLI resolves its own config.
enum AgentRoutes {
    static func root(
        for provider: AgentProviderID,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        switch provider {
        case .claude:
            return environmentDirectory("CLAUDE_CONFIG_DIR", in: environment)
                ?? home.appendingPathComponent(".claude", isDirectory: true)
        case .codex:
            return environmentDirectory("CODEX_HOME", in: environment)
                ?? home.appendingPathComponent(".codex", isDirectory: true)
        case .cursor:
            return home.appendingPathComponent(".cursor", isDirectory: true)
        case .gemini:
            return home.appendingPathComponent(".gemini", isDirectory: true)
        case .grok:
            return environmentDirectory("GROK_HOME", in: environment)
                ?? home.appendingPathComponent(".grok", isDirectory: true)
        case .kimi:
            return home.appendingPathComponent(".kimi-code", isDirectory: true)
        case .opencode:
            return environmentDirectory("OPENCODE_CONFIG_DIR", in: environment)
                ?? home.appendingPathComponent(".config/opencode", isDirectory: true)
        case .pi:
            return home.appendingPathComponent(".pi/agent", isDirectory: true)
        case .devin:
            return home.appendingPathComponent(".config/devin", isDirectory: true)
        case .cline:
            return environmentDirectory("CLINE_DIR", in: environment)
                ?? home.appendingPathComponent(".cline", isDirectory: true)
        case .qwen:
            return environmentDirectory("QWEN_HOME", in: environment)
                ?? home.appendingPathComponent(".qwen", isDirectory: true)
        case .kilo:
            if let xdg = environmentDirectory("XDG_CONFIG_HOME", in: environment) {
                return xdg.appendingPathComponent("kilo", isDirectory: true)
            }
            return home.appendingPathComponent(".config/kilo", isDirectory: true)
        case .goose:
            // GOOSE_PATH_ROOT only counts when it is an absolute path. The
            // check runs on the raw string: a file URL is always absolute, so
            // asking the URL would pass even for relative values.
            if let raw = environment["GOOSE_PATH_ROOT"],
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let expanded = NSString(string: raw).expandingTildeInPath
                if expanded.hasPrefix("/") {
                    return URL(fileURLWithPath: expanded, isDirectory: true)
                }
            }
            if let xdg = environmentDirectory("XDG_CONFIG_HOME", in: environment) {
                return xdg.appendingPathComponent("goose", isDirectory: true)
            }
            return home.appendingPathComponent(".config/goose", isDirectory: true)
        default:
            return home.appendingPathComponent(".\(provider.rawValue)", isDirectory: true)
        }
    }

    /// An env var naming a replacement directory. Whitespace-only values fall
    /// through to the default, same as `ClaudeStatusBridge.defaultConfigDirectory`.
    private static func environmentDirectory(
        _ name: String,
        in environment: [String: String]
    ) -> URL? {
        guard let value = environment[name],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true)
    }
}
