import AppKit
import ApplicationServices
import Foundation
import os
import SQLite3

/// Opens the host that owns a session and selects that session in the host.
///
/// Cursor jumps through Nano's IDE extension, which asks Cursor's Agents
/// window for the exact agent ID and falls back to a loaded local composer.
/// Claude uses `claude://resume`.
/// Codex uses `codex://threads/<id>`. An already-open terminal is preferred
/// for CLI sessions. T3 has no thread deeplink, so it is only used when the
/// session actually lives there.
enum AgentSessionJump {
    enum OpenResult: Equatable, Sendable {
        /// Nano verified that the requested conversation or thread opened.
        case opened
        /// The owning app or project opened, but the exact session was not verified.
        case hostActivated
        /// Exact navigation needs Accessibility consent from the installed Nano build.
        case accessibilityRequired
        /// Nano could not open either the session or its owning host.
        case unavailable
    }

    enum Origin: String, Equatable, Sendable {
        case cursorIDE
        case cursorACP
        case cursorChat
        case claude
        case codex
        case opencode
        case pi
        case grok
        case unknown
    }

    enum Host: String, Equatable, Sendable {
        case cursor
        case t3
        case claude
        case codex
        case terminal
        case folder
        /// Any other app that launched the agent (Zed, VS Code, Conductor…),
        /// named by the session's `hostBundleID`.
        case app

        var title: String {
            switch self {
            case .cursor: "Cursor"
            case .t3: "T3 Code"
            case .claude: "Claude"
            case .codex: "Codex"
            case .terminal: "Terminal"
            case .folder: "Finder"
            case .app: "App"
            }
        }
    }

    /// The app a hook ran under. macOS sets `__CFBundleIdentifier` for
    /// processes a GUI app launches and children inherit it, so an agent
    /// started by T3, Zed, or a terminal names its own host.
    static func host(bundleID: String) -> Host {
        switch bundleID.lowercased() {
        case t3BundleID.lowercased(): .t3
        case claudeBundleID.lowercased(): .claude
        case cursorBundleID.lowercased(): .cursor
        case codexBundleID.lowercased(): .codex
        case let id where terminalBundleIDs.contains(where: { $0.lowercased() == id }): .terminal
        default: .app
        }
    }

    /// Claude Code stamps every transcript with the client that started it.
    /// Claude Desktop is only the right place for its own sessions; sending
    /// every Claude session there hijacked jumps from other hosts.
    static func claudeHost(entrypoint: String, sessionID: String) -> Host? {
        switch entrypoint {
        case "claude-desktop": return .claude
        case "cli": return .terminal
        default:
            // SDK hosts record `sdk-ts`/`sdk-py`. T3 runs Claude that way.
            return t3ResumeThreadID(sessionID: sessionID) != nil ? .t3 : nil
        }
    }

    /// Codex records its launching client as `originator` in `session_meta`.
    static func codexHost(originator: String) -> Host? {
        let value = originator.lowercased()
        if value == "codex desktop" { return .codex }
        if value.hasPrefix("t3code") { return .t3 }
        if value.hasPrefix("codex_cli") || value.hasPrefix("codex_exec") { return .terminal }
        return nil
    }

    /// Cursor 3.21 routes `/agent?id=` into its Agents window, which opens
    /// local agents and subagents by ID. The Nano extension's command lookup
    /// no longer finds them there. Older builds reject the path, so this is
    /// feature-detected from Cursor's own deeplink handler.
    static func cursorAgentDeeplink(sessionID: String) -> URL? {
        guard let app = applicationURL(bundleID: cursorBundleID) else { return nil }
        let handler = app.appendingPathComponent(
            "Contents/Resources/app/extensions/cursor-deeplink/dist/main.js"
        )
        guard let source = try? String(contentsOf: handler, encoding: .utf8),
              source.range(of: #""/agent"===\w+\.path|\.path==="/agent""#, options: .regularExpression) != nil
        else { return nil }
        var components = URLComponents()
        components.scheme = "cursor"
        components.host = "anysphere.cursor-deeplink"
        components.path = "/agent"
        components.queryItems = [URLQueryItem(name: "id", value: sessionID)]
        return components.url
    }

    /// T3 keeps a Claude or Codex thread's provider session ID only in its
    /// resume cursor (`resume` for Claude, `threadId` for Codex).
    static func t3ResumeThreadID(
        sessionID: String,
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/state.sqlite")
    ) -> String? {
        if let thread = t3V2ThreadID(sessionID: sessionID, legacyDatabaseURL: databaseURL) {
            return thread
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        return sqliteText(
            db,
            "SELECT thread_id FROM provider_session_runtime WHERE json_extract(resume_cursor_json, '$.resume') = ?1 OR json_extract(resume_cursor_json, '$.threadId') = ?1 LIMIT 1",
            sessionID
        )
    }

    /// T3 moved its state to `statev2.sqlite` (October 2026) and stopped
    /// writing `state.sqlite`. There a provider's own session ID is the
    /// provider thread's `nativeThreadRef.nativeId`.
    static func t3V2DatabaseURL(besideLegacy legacyDatabaseURL: URL) -> URL {
        legacyDatabaseURL.deletingLastPathComponent().appendingPathComponent("statev2.sqlite")
    }

    private static func withT3V2Database<T>(
        besideLegacy legacyDatabaseURL: URL,
        _ body: (OpaquePointer) -> T?
    ) -> T? {
        let url = t3V2DatabaseURL(besideLegacy: legacyDatabaseURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        return body(db)
    }

    static func t3V2ThreadID(sessionID: String, legacyDatabaseURL: URL) -> String? {
        withT3V2Database(besideLegacy: legacyDatabaseURL) { db in
            sqliteText(
                db,
                "SELECT thread_id FROM orchestration_v2_projection_provider_threads WHERE json_extract(payload_json, '$.nativeThreadRef.nativeId') = ?1 LIMIT 1",
                sessionID
            ) ?? sqliteText(
                db,
                "SELECT thread_id FROM orchestration_v2_projection_threads WHERE thread_id = ?1 LIMIT 1",
                sessionID
            )
        }
    }

    static func t3V2ThreadTitle(threadID: String, legacyDatabaseURL: URL) -> String? {
        withT3V2Database(besideLegacy: legacyDatabaseURL) { db in
            sqliteText(
                db,
                "SELECT title FROM orchestration_v2_projection_threads WHERE thread_id = ?1 AND deleted_at IS NULL LIMIT 1",
                threadID
            )
        }
    }

    static func hostTitle(for session: AgentSession) -> String {
        let destination = host(for: session)
        let bundleID: String? = switch destination {
        case .app: session.hostBundleID
        // The terminal that is actually running, not Apple's by name.
        case .terminal: terminalBundleIDs.first { isRunning(bundleID: $0) }
        default: nil
        }
        guard let bundleID, let url = applicationURL(bundleID: bundleID)
        else { return destination.title }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    struct Runtime: Equatable, Sendable {
        var t3Running: Bool
        var cursorRunning: Bool
        var claudeRunning: Bool
        var codexRunning: Bool
        var t3Installed: Bool
        var cursorInstalled: Bool
        var claudeInstalled: Bool
        var codexInstalled: Bool
        var terminalRunning: Bool

        static var current: Runtime {
            Runtime(
                t3Running: isRunning(bundleID: t3BundleID),
                cursorRunning: isRunning(bundleID: cursorBundleID),
                claudeRunning: isRunning(bundleID: claudeBundleID),
                codexRunning: isRunning(bundleID: codexBundleID),
                t3Installed: applicationURL(bundleID: t3BundleID) != nil,
                cursorInstalled: applicationURL(bundleID: cursorBundleID) != nil,
                claudeInstalled: applicationURL(bundleID: claudeBundleID) != nil,
                codexInstalled: applicationURL(bundleID: codexBundleID) != nil,
                terminalRunning: terminalBundleIDs.contains { isRunning(bundleID: $0) }
            )
        }
    }

    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    static let t3BundleID = "com.t3tools.t3code"
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    static let codexBundleID = "com.openai.codex"
    static let cursorExtensionID = "nano.cursor-conversation-jump"
    static let cursorExtensionVersion = "0.1.2"
    static let terminalBundleIDs = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
    ]

    static func origin(for session: AgentSession) -> Origin {
        origin(sessionID: session.id, provider: session.provider)
    }

    static func origin(
        sessionID: String,
        provider: AgentProviderID,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Origin {
        if let found = cursorStoreOrigin(sessionID: sessionID, under: home) { return found }
        switch provider {
        case .claude: return .claude
        case .codex: return .codex
        case .opencode, .kimi: return .opencode
        case .pi: return .pi
        case .grok: return .grok
        default: return .unknown
        }
    }

    /// Cursor stores found on disk, by home and session id.
    ///
    /// Cursor hooks fire several times a second and each merge asked for the
    /// origin, listing every project under `~/.cursor` on the main actor. A
    /// session's store does not move once written. A miss is not kept: the
    /// first hook can arrive before the agent writes its store.
    private static let cursorOrigins = OSAllocatedUnfairLock(initialState: [String: Origin]())

    private static func cursorStoreOrigin(sessionID: String, under home: URL) -> Origin? {
        let key = home.path + "\n" + sessionID
        let known = cursorOrigins.withLock { $0[key] }
        // A transcript alone may yet gain a CLI chat store, which outranks it,
        // so only that cheaper check is repeated.
        if let known, known != .cursorIDE { return known }
        // The Cursor CLI also writes `agent-transcripts`, so its chats looked
        // like IDE conversations and were sent to an app that cannot open
        // them. The CLI chat store never holds IDE conversations; check it first.
        let found: Origin
        if chatExists(sessionID: sessionID, under: home) {
            found = .cursorChat
        } else if known == .cursorIDE {
            return .cursorIDE
        } else if transcriptExists(sessionID: sessionID, under: home) {
            found = .cursorIDE
        } else if acpExists(sessionID: sessionID, under: home) {
            found = .cursorACP
        } else {
            return nil
        }
        cursorOrigins.withLock { $0[key] = found }
        return found
    }

    static func host(for origin: Origin, runtime: Runtime) -> Host {
        switch origin {
        case .cursorIDE:
            return .cursor
        case .cursorChat:
            if runtime.terminalRunning { return .terminal }
            return .folder
        case .cursorACP:
            if runtime.t3Running { return .t3 }
            if runtime.cursorRunning { return .cursor }
            if runtime.t3Installed { return .t3 }
            return .cursor
        case .claude:
            if runtime.claudeInstalled || runtime.claudeRunning { return .claude }
            if runtime.terminalRunning { return .terminal }
            return .folder
        case .codex:
            if runtime.codexInstalled || runtime.codexRunning { return .codex }
            if runtime.terminalRunning { return .terminal }
            return .folder
        case .opencode, .pi, .grok, .unknown:
            if runtime.terminalRunning { return .terminal }
            if runtime.cursorRunning { return .cursor }
            if runtime.t3Running { return .t3 }
            if runtime.cursorInstalled { return .cursor }
            if runtime.t3Installed { return .t3 }
            return .folder
        }
    }

    static func host(for session: AgentSession, runtime: Runtime = .current) -> Host {
        if let host = session.host, host != .app || session.hostBundleID != nil { return host }
        // Cline, Qwen Code, Kilo and Goose are found on disk and only ever
        // run in a terminal. An editor that happens to be open has no such
        // session to show.
        if session.provider != .devin,
           AgentSessionStore.diskDiscoveredProviders.contains(session.provider) {
            return runtime.terminalRunning ? .terminal : .folder
        }
        return host(for: origin(for: session), runtime: runtime)
    }

    static func canJump(_ session: AgentSession, runtime: Runtime = .current) -> Bool {
        let destination = host(for: session, runtime: runtime)
        if destination == .terminal { return runtime.terminalRunning }
        if destination == .app {
            return session.hostBundleID.flatMap { applicationURL(bundleID: $0) } != nil
        }
        if applicationURL(bundleID: bundleID(for: destination)) != nil {
            return true
        }
        if destination == .cursor, cursorConversationURL(session: session) != nil {
            return true
        }
        return projectDirectory(for: session) != nil
    }

    static func editorFileURL(scheme: String, path: String) -> URL? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(scheme)://file\(encoded)")
    }

    static func t3ThreadID(
        sessionID: String,
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/state.sqlite")
    ) -> String? {
        if let thread = t3V2ThreadID(sessionID: sessionID, legacyDatabaseURL: databaseURL) {
            return thread
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return sessionID
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let db else { return sessionID }
        defer { sqlite3_close(db) }

        if let match = sqliteText(
            db,
            "SELECT thread_id FROM projection_threads WHERE thread_id = ? LIMIT 1",
            sessionID
        ) {
            return match
        }
        if let mapped = sqliteText(
            db,
            "SELECT thread_id FROM projection_thread_sessions WHERE provider_session_id = ? LIMIT 1",
            sessionID
        ) {
            return mapped
        }
        if let mapped = t3ResumeThreadID(sessionID: sessionID, databaseURL: databaseURL) {
            return mapped
        }
        if let mapped = t3ThreadIDFromProviderLogs(
            sessionID: sessionID,
            databaseURL: databaseURL,
            database: db
        ) {
            return mapped
        }
        return sessionID
    }

    static func t3ThreadTitle(
        threadID: String,
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata/state.sqlite")
    ) -> String? {
        if let title = t3V2ThreadTitle(threadID: threadID, legacyDatabaseURL: databaseURL) {
            return title
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        return sqliteText(
            db,
            "SELECT title FROM projection_threads WHERE thread_id = ? LIMIT 1",
            threadID
        )
    }

    static func cursorIDEArguments(folder: URL?) -> [String]? {
        // Do not pass --reuse-window. That forces the last focused Cursor
        // window, which is often a different project. Passing only the folder
        // focuses the existing window that already has it.
        // More importantly, never run `cursor` with no arguments: that opens
        // the welcome window instead of restoring the requested conversation.
        guard let folder else { return nil }
        return [folder.path]
    }

    static func cursorJumpReceiptDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".nano/run/ide-extension", isDirectory: true)
    }

    static func cursorJumpOpened(
        conversation: String,
        folder: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let root = cursorJumpReceiptDirectory(home: home)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return files.contains { file in
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["opened"] as? Bool == true,
                  object["conversation"] as? String == conversation
            else { return false }
            guard let folder else { return true }
            let workspaces = (object["workspaces"] as? [String]) ?? []
            let target = folder.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return workspaces.contains { workspace in
                let value = workspace.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return value.caseInsensitiveCompare(target) == .orderedSame
                    || value.lowercased().hasSuffix(target.lowercased())
                    || target.lowercased().hasSuffix(value.lowercased())
            }
        }
    }

    static func cursorConversationURL(
        sessionID: String,
        folder: URL?,
        scheme: String = "cursor"
    ) -> URL? {
        guard !sessionID.isEmpty else { return nil }
        var items = [URLQueryItem(name: "conversation", value: sessionID)]
        if let folder {
            items.append(URLQueryItem(name: "workspace", value: folder.path))
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = cursorExtensionID
        components.path = "/focus-cursor-agent"
        components.queryItems = items
        return components.url
    }

    static func cursorConversationURL(session: AgentSession) -> URL? {
        cursorConversationURL(sessionID: session.id, folder: projectDirectory(for: session))
    }

    static func claudeResumeURL(sessionID: String, folder: URL? = nil) -> URL? {
        guard let id = embeddedUUID(in: sessionID) ?? optionalID(sessionID) else { return nil }
        var items = [URLQueryItem(name: "session", value: id)]
        if let folder {
            items.append(URLQueryItem(name: "cwd", value: folder.path))
        }
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "resume"
        components.queryItems = items
        return components.url
    }

    static func claudeCodeExtensionURL(sessionID: String, scheme: String = "cursor") -> URL? {
        guard let id = embeddedUUID(in: sessionID) ?? optionalID(sessionID) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "anthropic.claude-code"
        components.path = "/open"
        components.queryItems = [URLQueryItem(name: "session", value: id)]
        return components.url
    }

    static func codexThreadURL(sessionID: String) -> URL? {
        guard let id = embeddedUUID(in: sessionID) else { return nil }
        return URL(string: "codex://threads/\(id)")
    }

    static func embeddedUUID(in value: String) -> String? {
        let pattern = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
        return value.matches(of: pattern).last.map { String($0.output) }
    }

    private static func optionalID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func cursorCLIURL(
        appURL: URL? = applicationURL(bundleID: cursorBundleID)
    ) -> URL? {
        guard let appURL else { return nil }
        let embedded = appURL.appendingPathComponent("Contents/Resources/app/bin/cursor")
        return FileManager.default.isExecutableFile(atPath: embedded.path) ? embedded : nil
    }

    static func revealTitles(for session: AgentSession, host: Host) -> [String] {
        if host == .t3 {
            let threadID = t3ThreadID(sessionID: session.id) ?? session.id
            if let title = t3ThreadTitle(threadID: threadID) {
                return [title]
            }
            // T3 has no public deep link. A stored title is the only safe
            // fallback; prompt/display text can also appear in the transcript
            // or composer and is not a navigation receipt.
            return session.title.map { [$0.text] } ?? []
        }
        var titles: [String] = []
        if let title = session.title?.text { titles.append(title) }
        titles.append(session.displayName)
        if let prompt = session.lastUserPrompt { titles.append(prompt) }
        return titles
    }

    @MainActor
    static func open(
        _ session: AgentSession,
        completion reportResult: @escaping @MainActor (OpenResult) -> Void = { _ in }
    ) {
        let source = origin(for: session)
        let runtime = Runtime.current
        // The host the session reported wins over one guessed from its provider.
        let destination = host(for: session, runtime: runtime)
        let completion: @MainActor (OpenResult) -> Void = { result in
            if result == .hostActivated || result == .unavailable {
                NanoJumpMissLog.record(session: session, host: destination, result: result)
            }
            reportResult(result)
        }
        let folder = projectDirectory(for: session)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let prefersTerminal = destination == .terminal || session.host == nil && (
            source == .claude || source == .codex
                || source == .opencode || source == .pi || source == .grok || source == .unknown
        )

        if prefersTerminal, focusOpenTerminal(for: session) {
            completion(.opened)
            return
        }

        switch destination {
        case .cursor:
            if source == .cursorIDE, let url = cursorAgentDeeplink(sessionID: session.id) {
                let opened = NSWorkspace.shared.open(url)
                activate(bundleID: cursorBundleID)
                completion(opened ? .opened : .unavailable)
                return
            }
            _ = NanoCursorJumpExtension.installIfNeeded()
            let launchedProject = launchCursorIDE(folder: folder)
            if !runtime.cursorRunning, !launchedProject,
               let app = applicationURL(bundleID: cursorBundleID) {
                NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            }
            activate(bundleID: cursorBundleID)
            focusCursorConversation(
                session: session,
                folder: folder,
                wasRunning: runtime.cursorRunning,
                completion: completion
            )
            return
        case .t3:
            guard NanoAccessibilityPermission.requestIfNeeded() else {
                activate(bundleID: t3BundleID)
                completion(.accessibilityRequired)
                return
            }
            if !runtime.t3Running {
                if let app = applicationURL(bundleID: t3BundleID), let folder {
                    NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration)
                } else if let app = applicationURL(bundleID: t3BundleID) {
                    NSWorkspace.shared.openApplication(at: app, configuration: configuration)
                }
            }
            activate(bundleID: t3BundleID)
            scheduleReveal(
                session: session,
                host: .t3,
                wasRunning: runtime.t3Running,
                completion: completion
            )
            return
        case .claude:
            if let url = claudeResumeURL(sessionID: session.id, folder: folder) {
                let opened = NSWorkspace.shared.open(url)
                activate(bundleID: claudeBundleID)
                completion(opened ? .opened : .unavailable)
                return
            }
            if runtime.cursorRunning,
               let url = claudeCodeExtensionURL(sessionID: session.id) {
                let opened = NSWorkspace.shared.open(url)
                activate(bundleID: cursorBundleID)
                completion(opened ? .opened : .unavailable)
                return
            }
        case .codex:
            if let url = codexThreadURL(sessionID: session.id) {
                let opened = NSWorkspace.shared.open(url)
                activate(bundleID: codexBundleID)
                completion(opened ? .opened : .unavailable)
                return
            }
        case .terminal:
            if focusOpenTerminal(for: session) {
                completion(.opened)
                return
            }
        case .folder:
            break
        case .app:
            // No session-level route into an arbitrary app; bring its window
            // forward, opening the project if the app is not running yet.
            guard let bundleID = session.hostBundleID, let app = applicationURL(bundleID: bundleID)
            else { break }
            let wasRunning = isRunning(bundleID: bundleID)
            if wasRunning {
                activate(bundleID: bundleID)
            } else if let folder {
                NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration)
            } else {
                NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            }
            // Most agent GUIs list chats by the same title Nano shows; if one
            // exact row matches, open it. Without consent, the app in front
            // is still the right place.
            guard NanoAccessibilityPermission.requestIfNeeded() else {
                completion(.hostActivated)
                return
            }
            scheduleReveal(
                session: session,
                host: .app,
                bundleID: bundleID,
                wasRunning: wasRunning,
                completion: completion
            )
            return
        }

        if let app = applicationURL(bundleID: bundleID(for: destination)), let folder {
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration)
            activate(bundleID: bundleID(for: destination))
            completion(.hostActivated)
            return
        }
        if let folder, let url = editorFileURL(scheme: scheme(for: destination), path: folder.path) {
            if NSWorkspace.shared.open(url) {
                activate(bundleID: bundleID(for: destination))
                completion(.hostActivated)
                return
            }
        }
        if let app = applicationURL(bundleID: bundleID(for: destination)) {
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
            activate(bundleID: bundleID(for: destination))
            completion(.hostActivated)
            return
        }
        if let folder {
            NSWorkspace.shared.open(folder)
            completion(.hostActivated)
        } else {
            completion(.unavailable)
        }
    }

    static func projectDirectory(for session: AgentSession) -> URL? {
        guard let path = session.workingDirectory, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if url.path == home.path { return nil }
        return url
    }

    @MainActor
    private static func focusCursorConversation(
        session: AgentSession,
        folder: URL?,
        wasRunning: Bool,
        completion: @escaping @MainActor (OpenResult) -> Void
    ) {
        let url = cursorConversationURL(session: session)
        let delay: UInt64 = wasRunning ? 220_000_000 : 900_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)

            // A transcript can outlive its project folder. Cursor still keeps
            // that agent in the global Agents sidebar, so select it there
            // before attempting a URI handoff to an arbitrary window.
            if folder == nil,
               await AgentHostReveal.reveal(
                   bundleID: cursorBundleID,
                   titles: revealTitles(for: session, host: .cursor),
                   palette: nil,
                   ignoring: [session.projectName]
               ) {
                completion(.opened)
                return
            }

            for attempt in 0..<5 {
                if let url {
                    NSWorkspace.shared.open(url)
                }
                try? await Task.sleep(nanoseconds: attempt == 0 ? 280_000_000 : 220_000_000)
                if cursorJumpOpened(conversation: session.id, folder: folder) {
                    completion(.opened)
                    return
                }
            }
            let revealed = await AgentHostReveal.reveal(
                bundleID: cursorBundleID,
                titles: revealTitles(for: session, host: .cursor),
                palette: nil,
                ignoring: [session.projectName]
            )
            completion(revealed ? .opened : .hostActivated)
        }
    }

    private static func launchCursorIDE(folder: URL?) -> Bool {
        guard let cli = cursorCLIURL(), let arguments = cursorIDEArguments(folder: folder) else {
            return false
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func scheduleReveal(
        session: AgentSession,
        host: Host,
        bundleID explicitBundleID: String? = nil,
        wasRunning: Bool,
        completion: @escaping @MainActor (OpenResult) -> Void
    ) {
        let titles = revealTitles(for: session, host: host)
        let bundle = explicitBundleID ?? bundleID(for: host)
        let delay: UInt64 = wasRunning ? 280_000_000 : 1_250_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            // T3's command palette offers no success receipt and can accept
            // text in an unrelated focused control. Only an exact visible
            // thread-title click counts as a successful review navigation.
            let revealed = await AgentHostReveal.reveal(
                bundleID: bundle,
                titles: titles,
                palette: nil,
                ignoring: [session.projectName],
                // Unknown apps get the same rule as T3: click only a single,
                // exact title inside a navigable row, or nothing at all.
                requiresExactTitle: host == .t3 || host == .app
            )
            completion(revealed ? .opened : .hostActivated)
        }
    }

    private static func sqliteText(_ db: OpaquePointer, _ sql: String, _ value: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: pointer)
    }

    private static func t3ThreadIDFromProviderLogs(
        sessionID: String,
        databaseURL: URL,
        database: OpaquePointer
    ) -> String? {
        let directory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("logs/provider", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = files
            .filter { $0.lastPathComponent.hasPrefix("events.") && $0.lastPathComponent.contains(".log") }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left > right
            }
            .prefix(64)

        for file in candidates {
            let name = file.lastPathComponent
            guard let logRange = name.range(of: ".log"),
                  name.hasPrefix("events."),
                  fileTailContains(file, needle: sessionID)
            else { continue }
            let start = name.index(name.startIndex, offsetBy: "events.".count)
            let threadID = String(name[start..<logRange.lowerBound])
            if sqliteText(
                database,
                "SELECT thread_id FROM projection_threads WHERE thread_id = ? LIMIT 1",
                threadID
            ) != nil {
                return threadID
            }
        }
        return nil
    }

    private static func fileTailContains(_ url: URL, needle: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        let maximumBytes: UInt64 = 512 * 1_024
        try? handle.seek(toOffset: length > maximumBytes ? length - maximumBytes : 0)
        guard let data = try? handle.readToEnd() else { return false }
        return String(decoding: data, as: UTF8.self).contains(needle)
    }

    private static func activate(bundleID: String) {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .activate(options: [.activateAllWindows])
    }

    static func bundleID(for host: Host) -> String {
        switch host {
        case .cursor: cursorBundleID
        case .t3: t3BundleID
        case .claude: claudeBundleID
        case .codex: codexBundleID
        case .terminal: terminalBundleIDs.first { isRunning(bundleID: $0) } ?? "com.apple.Terminal"
        case .folder, .app: "com.apple.finder"
        }
    }

    static func scheme(for host: Host) -> String {
        switch host {
        case .cursor: "cursor"
        case .t3: "t3code"
        case .claude: "claude"
        case .codex: "codex"
        case .terminal, .folder, .app: "file"
        }
    }

    @MainActor
    private static func focusOpenTerminal(for session: AgentSession) -> Bool {
        let titles = revealTitles(for: session, host: .terminal)
        let queries = AgentHostReveal.searchQueries(
            from: titles,
            ignoring: [session.projectName]
        )
        let cwd = projectDirectory(for: session)?.lastPathComponent
        var all = queries
        if let cwd { all.append(cwd) }
        guard !all.isEmpty else { return false }
        for bundleID in terminalBundleIDs where isRunning(bundleID: bundleID) {
            if AgentHostReveal.focus(bundleID: bundleID, titles: all, ignoring: []) {
                return true
            }
        }
        return false
    }

    private static func transcriptExists(sessionID: String, under home: URL) -> Bool {
        let root = home.appendingPathComponent(".cursor/projects", isDirectory: true)
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return projects.contains { project in
            let file = project
                .appendingPathComponent("agent-transcripts", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("\(sessionID).jsonl")
            return FileManager.default.fileExists(atPath: file.path)
        }
    }

    private static func acpExists(sessionID: String, under home: URL) -> Bool {
        let folder = home
            .appendingPathComponent(".cursor/acp-sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.path)
    }

    private static func chatExists(sessionID: String, under home: URL) -> Bool {
        let root = home.appendingPathComponent(".cursor/chats", isDirectory: true)
        guard let hashes = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return hashes.contains {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(sessionID, isDirectory: true).path
            )
        }
    }

    private static func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    static func applicationURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

enum AgentHostReveal {
    enum Palette: Equatable, Sendable {
        case commandK
    }

    @MainActor
    static func reveal(
        bundleID: String,
        titles: [String],
        palette: Palette?,
        ignoring ignored: [String] = [],
        requiresExactTitle: Bool = false
    ) async -> Bool {
        let queries = searchQueries(
            from: titles,
            ignoring: ignored,
            maximumLength: requiresExactTitle ? nil : 42
        )
        guard !queries.isEmpty else { return false }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else { return false }

        app.activate(options: [.activateAllWindows])
        guard ensureTrusted() else { return false }

        if click(matching: queries, pid: app.processIdentifier, requiresExactTitle: requiresExactTitle) {
            return true
        }
        // T3 folds finished threads under "Settled (n)", where their rows do
        // not exist until it is opened. Open it once and look again.
        if bundleID == AgentSessionJump.t3BundleID,
           expandCollapsedThreads(pid: app.processIdentifier) {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if click(matching: queries, pid: app.processIdentifier, requiresExactTitle: requiresExactTitle) {
                return true
            }
        }
        if let palette, let query = queries.first {
            return await runPalette(palette, query: query)
        }
        return false
    }

    @MainActor
    static func focus(
        bundleID: String,
        titles: [String],
        ignoring ignored: [String] = []
    ) -> Bool {
        let queries = searchQueries(from: titles, ignoring: ignored)
        guard !queries.isEmpty else { return false }
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }) else { return false }
        app.activate(options: [.activateAllWindows])
        guard ensureTrusted() else { return false }
        return click(matching: queries, pid: app.processIdentifier)
    }

    static func searchQueries(
        from titles: [String],
        ignoring ignored: [String] = [],
        maximumLength: Int? = 42
    ) -> [String] {
        let ignoredKeys = Set(
            ignored
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        var seen = Set<String>()
        var queries: [String] = []
        for raw in titles {
            let cleaned = raw
                .replacingOccurrences(of: "\u{2026}", with: "")
                .replacingOccurrences(of: "...", with: "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 4 else { continue }
            if cleaned.hasPrefix(">") { continue }
            if AgentSession.isGenericProjectLabelForJump(cleaned) { continue }
            let query = maximumLength.map { String(cleaned.prefix($0)) } ?? cleaned
            let key = query.lowercased()
            if ignoredKeys.contains(key) { continue }
            if seen.insert(key).inserted {
                queries.append(query)
            }
        }
        return queries
    }

    private static func ensureTrusted() -> Bool {
        NanoAccessibilityPermission.requestIfNeeded()
    }

    private static func click(
        matching queries: [String],
        pid: pid_t,
        requiresExactTitle: Bool = false
    ) -> Bool {
        let root = AXUIElementCreateApplication(pid)
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        var best: (element: AXUIElement, title: String)?
        var exactTargets: [(row: AXUIElement, title: AXUIElement)] = []
        while let (element, depth) = stack.popLast() {
            visited += 1
            // Electron sidebars sit deep: T3's thread titles are 18 levels down.
            if visited > 4000 || depth > 32 { continue }
            if let title = axString(element),
               matches(title, queries: queries, requiresExactTitle: requiresExactTitle) {
                if requiresExactTitle {
                    // T3's pressable row is labelled with the whole row (project,
                    // age, actions, title, branch, PR), so it never equals the
                    // title. The exact title is a static text inside it; press
                    // the row that contains it.
                    if let row = pressableSelfOrAncestor(element),
                       !exactTargets.contains(where: { CFEqual($0.row, row) }) {
                        exactTargets.append((row, element))
                    }
                } else if best == nil || title.count < best!.title.count {
                    best = (element, title)
                }
            }
            for child in axChildren(element).reversed() {
                stack.append((child, depth + 1))
            }
        }
        if requiresExactTitle {
            // Two rows with the same title is ambiguous; do not guess.
            guard exactTargets.count == 1 else { return false }
            // T3 reports AXPress as handled without navigating; its rows only
            // respond to a real click. Click the title itself, and only when it
            // is on screen inside the app's own window.
            return clickVisible(exactTargets[0].title, pid: pid)
        }
        guard let best else { return false }
        return press(best.element, allowMouseFallback: true)
    }

    static func isCollapsedThreadsToggle(_ title: String) -> Bool {
        title.range(of: #"^Settled \(\d+\)$"#, options: .regularExpression) != nil
    }

    /// Clicks T3's "Settled (n)" header. False when there is none on screen.
    private static func expandCollapsedThreads(pid: pid_t) -> Bool {
        let root = AXUIElementCreateApplication(pid)
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast() {
            visited += 1
            if visited > 4000 || depth > 32 { continue }
            if let title = axString(element), isCollapsedThreadsToggle(title),
               supportsPressAction(element) {
                return clickVisible(element, pid: pid)
            }
            for child in axChildren(element).reversed() {
                stack.append((child, depth + 1))
            }
        }
        return false
    }

    static func matches(
        _ title: String,
        queries: [String],
        requiresExactTitle: Bool = false
    ) -> Bool {
        var haystack = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresExactTitle {
            // Queries drop a truncation ellipsis; the on-screen title keeps it.
            haystack = haystack
                .replacingOccurrences(of: "\u{2026}", with: "")
                .replacingOccurrences(of: "...", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard haystack.count >= 4 else { return false }
        let lowered = haystack.lowercased()
        if AgentSession.isGenericProjectLabelForJump(haystack) { return false }
        return queries.contains { query in
            let needle = query.lowercased()
            if requiresExactTitle { return lowered == needle }
            return lowered.contains(needle) || needle.contains(lowered)
        }
    }

    private static func supportsPressAction(_ element: AXUIElement) -> Bool {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let actions = value as? [String]
        else { return false }
        return actions.contains(kAXPressAction as String)
    }

    private static func press(_ element: AXUIElement, allowMouseFallback: Bool = true) -> Bool {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }
        guard allowMouseFallback else { return false }
        var positionValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &positionValue
        ) == .success,
              let positionValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID()
        else { return false }
        var point = CGPoint.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point) else { return false }
        var size = CGSize(width: 8, height: 8)
        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &sizeValue
        ) == .success,
           let sizeValue,
           CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        let click = CGPoint(x: point.x + min(size.width, 24) / 2, y: point.y + min(size.height, 16) / 2)
        return clickMouse(at: click)
    }

    private static func runPalette(_ palette: Palette, query: String) async -> Bool {
        switch palette {
        case .commandK:
            postKey(40, flags: .maskCommand)
        }
        try? await Task.sleep(nanoseconds: 220_000_000)
        typeText(query)
        try? await Task.sleep(nanoseconds: 320_000_000)
        postKey(36, flags: [])
        return true
    }

    private static func typeText(_ text: String) {
        for character in text {
            var utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                continue
            }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
            return
        }
        down.flags = flags
        down.post(tap: .cghidEventTap)
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    private static func clickMouse(at point: CGPoint) -> Bool {
        guard let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left
        ),
        let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left
        ) else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func axString(_ element: AXUIElement) -> String? {
        let attributes = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
        for attribute in attributes {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let string = value as? String
            else { continue }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// The nearest navigable row. Pop-up buttons (T3's "Thread actions" menu
    /// in the open thread's header) also carry the title but open a menu.
    private static func pressableSelfOrAncestor(_ element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let candidate = current else { return nil }
            if supportsPressAction(candidate) {
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &role)
                let navigable = ["AXButton", "AXLink", "AXRow", "AXCell"]
                return navigable.contains(role as? String ?? "") ? candidate : nil
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                candidate, kAXParentAttribute as CFString, &parent
            ) == .success, let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return nil }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func clickVisible(_ element: AXUIElement, pid: pid_t) -> Bool {
        AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
        guard let target = frame(of: element), target.width > 0, target.height > 0 else { return false }
        let point = CGPoint(x: target.minX + min(target.width, 40) / 2, y: target.midY)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &window
        ) == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID(),
              let bounds = frame(of: window as! AXUIElement), bounds.contains(point)
        else { return false }
        return clickMouse(at: point)
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &value
        ) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}

private extension AgentSession {
    static func isGenericProjectLabelForJump(_ name: String) -> Bool {
        projectLabel(named: name, directory: nil) == nil && name.count < 28
    }
}

enum NanoCursorJumpExtension {
    static func installIfNeeded(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundle: Bundle = .main
    ) -> URL? {
        guard let package = bundle.url(
            forResource: "nano-cursor-jump-package", withExtension: "json"
        ),
        let script = bundle.url(
            forResource: "nano-cursor-jump-extension", withExtension: "js"
        ) else { return nil }

        let folderName = "\(AgentSessionJump.cursorExtensionID)-\(AgentSessionJump.cursorExtensionVersion)"
        let roots = [
            home.appendingPathComponent(".cursor/extensions", isDirectory: true),
            home.appendingPathComponent(".vscode/extensions", isDirectory: true),
        ]
        var installed: URL?
        for root in roots {
            removePreviousCursorJumpInstalls(in: root, keeping: folderName)
            let destination = root.appendingPathComponent(folderName, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let packageDest = destination.appendingPathComponent("package.json")
                let scriptDest = destination.appendingPathComponent("extension.js")
                if FileManager.default.fileExists(atPath: packageDest.path) {
                    try FileManager.default.removeItem(at: packageDest)
                }
                if FileManager.default.fileExists(atPath: scriptDest.path) {
                    try FileManager.default.removeItem(at: scriptDest)
                }
                try FileManager.default.copyItem(at: package, to: packageDest)
                try FileManager.default.copyItem(at: script, to: scriptDest)
                installed = destination
            } catch {
                continue
            }
        }
        return installed
    }

    private static func removePreviousCursorJumpInstalls(in root: URL, keeping folderName: String) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for child in children where child.lastPathComponent.hasPrefix("\(AgentSessionJump.cursorExtensionID)-") {
            guard child.lastPathComponent != folderName else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }
}

/// Local record of jumps that reached the app but not the exact session, so
/// the hosts worth a dedicated route show up from real use rather than guesses.
/// Stays on this Mac; no titles or prompts are written.
enum NanoJumpMissLog {
    private static let limit = 200

    static var fileURL: URL? {
        try? NanoStorage.directory("jumps").appendingPathComponent("misses.jsonl")
    }

    static func record(
        session: AgentSession,
        host: AgentSessionJump.Host,
        result: AgentSessionJump.OpenResult,
        at date: Date = Date()
    ) {
        guard let url = fileURL else { return }
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: date),
            "provider": session.provider.rawValue,
            "host": host.rawValue,
            "hostBundleID": session.hostBundleID ?? AgentSessionJump.bundleID(for: host),
            "result": result == .unavailable ? "unavailable" : "appOnly",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: .sortedKeys),
              let line = String(data: data, encoding: .utf8)
        else { return }
        let existing = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        let lines = Array((existing + [line]).suffix(limit))
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
