import CryptoKit
import Foundation
import os
import SQLite3

// Per-provider usage adapters. Every provider reports quota differently — some
// as a used percentage, some as a raw balance — so each adapter normalizes into
// `NanoUsageWindow`, which stores what was used and displays what is left.
//
// All of this runs off the main actor: adapters are plain nonisolated types and
// failures come back as `AgentUsageResult.message`, never as a crash.

/// One provider's answer for a usage refresh.
struct AgentUsageResult: Sendable {
    var windows: [NanoUsageWindow] = []
    /// Why there is nothing to show, when there is nothing to show.
    var message: String?
    /// False when the provider grants no included quota (a `limit` of 0), so the
    /// UI can skip rendering a meaningless "0%".
    var hasQuota = false
    /// Plan as reported by the provider's API, never by local cached state.
    var planName: String?

    static func unavailable(_ message: String) -> Self {
        AgentUsageResult(message: message)
    }
}

enum AgentUsageError: LocalizedError {
    case credentialsMissing(String)
    case unauthorized(String)
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case let .credentialsMissing(message), let .unauthorized(message): message
        case .invalidResponse: "The provider returned an invalid response."
        case let .http(status): "Provider usage request failed (HTTP \(status))."
        }
    }
}

enum NanoUsageFormat {
    /// Labels a window from its length, never from its position in the payload.
    /// A "primary" window is 7 days on some plans and 5 hours on others.
    static func windowLabel(seconds: Int) -> String {
        guard seconds > 0 else { return "Window" }
        if seconds < 172_800, seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)d" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        if seconds % 60 == 0 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }

    /// Compact countdown: "5d1h", "31d", "3h4m", "12m".
    static func countdown(seconds: Int) -> String {
        let total = max(0, seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d\(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }
}

extension NanoUsageWindow {
    /// Counts down to the absolute reset date, measured against now.
    /// `resetAfterSeconds` was true at fetch time only, so preferring it froze
    /// the countdown until the next refresh; it is the fallback for a window
    /// that carries no date. A reset already in the past has no countdown.
    var resetCountdown: String? {
        let seconds: Int
        if let resetsAt {
            seconds = Int(resetsAt.timeIntervalSinceNow.rounded(.up))
        } else if let resetAfterSeconds {
            seconds = resetAfterSeconds
        } else {
            return nil
        }
        guard seconds > 0 else { return nil }
        // Under a minute still reads as "1m", never "0m".
        return NanoUsageFormat.countdown(seconds: max(seconds, 60))
    }
}

enum CodexUsageAdapter {
    static func fetch() async throws -> AgentUsageResult {
        let root = ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)

        guard let data = try? Data(contentsOf: root.appendingPathComponent("auth.json")),
              let rootJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = rootJSON["tokens"] as? [String: Any],
              let accessToken = (tokens["access_token"] ?? tokens["accessToken"]) as? String,
              !accessToken.isEmpty
        else {
            return .unavailable("Run Codex once to sign in.")
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Nano", forHTTPHeaderField: "User-Agent")
        if let accountID = (tokens["account_id"] ?? tokens["accountId"]) as? String {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let responseData: Data
        do {
            responseData = try await usageData(request, expiredMessage: "Codex sign-in expired.")
        } catch {
            return .unavailable(error.localizedDescription)
        }

        let decoded = try JSONDecoder().decode(CodexUsageEnvelope.self, from: responseData)

        // The account's own limits only. `additional_rate_limits` carries
        // per-feature pools - Codex-Spark has its own quota that does not count
        // against these - and mixing them into one row makes the pill read as
        // two competing 7d windows.
        let windows = decoded.rateLimit.map { usageWindows(from: $0, id: "codex", name: nil) } ?? []

        return AgentUsageResult(
            windows: windows,
            message: windows.isEmpty ? "No rate limits reported." : nil,
            hasQuota: !windows.isEmpty,
            planName: decoded.planType
        )
    }

    /// `secondary_window` is null on plans that only have one window, so both
    /// slots are treated as optional and labelled from their own length.
    private static func usageWindows(
        from limit: CodexUsageEnvelope.RateLimit,
        id: String,
        name: String?
    ) -> [NanoUsageWindow] {
        [("primary", limit.primaryWindow), ("secondary", limit.secondaryWindow)]
            .compactMap { slot, window -> NanoUsageWindow? in
                guard let window else { return nil }
                let derived = window.limitWindowSeconds.map(NanoUsageFormat.windowLabel(seconds:))
                    ?? "Window"
                return NanoUsageWindow(
                    id: "\(id).\(slot)",
                    label: name.map { "\($0) · \(derived)" } ?? derived,
                    usedPercent: min(100, max(0, window.usedPercent)),
                    // A payload with only the relative figure is pinned to a
                    // date here, at fetch time, so the countdown keeps moving.
                    resetsAt: window.resetAt.map { Date(timeIntervalSince1970: $0) }
                        ?? window.resetAfterSeconds.map { Date().addingTimeInterval(TimeInterval($0)) },
                    resetAfterSeconds: window.resetAfterSeconds
                )
            }
    }
}

enum ClaudeUsageAdapter {
    /// Same local-sign-in pattern as Codex and Cursor. Claude Code 2.1+ on
    /// macOS keeps the live token in Keychain; `~/.claude/.credentials.json`
    /// is often a leftover with an expired access token. The status-line
    /// cache only fills after a Claude Code turn, so the pill used to stay
    /// empty even when Usage was on.
    static func fetch() async throws -> AgentUsageResult {
        // Status-line cache is written by the installed Claude hook/bridge on
        // the next turn. Read it first so a 429 on the OAuth path cannot hide
        // numbers the user already earned locally.
        if let local = fromLocalCache() { return local }
        if let cached = cachedResult() { return cached }
        if isOauthCoolingOff() {
            return lastGoodOAuthResult()
                ?? .unavailable("Claude usage is rate-limited. Retrying shortly.")
        }

        // Nano never refreshes Claude Code's token: spending its refresh token
        // here rotates the grant and signs the CLI out. An expired token waits
        // for Claude Code to renew it; the next poll reads the new one.
        let credentials = loadCredentials()
        if let current = credentials, !current.isExpired() {
            switch await fetchOAuth(token: current.accessToken, plan: current.subscriptionType) {
            case .success(var result):
                if result.planName == nil { result.planName = current.subscriptionType }
                storeCache(result)
                return result
            case .failure(let error):
                // The endpoint is shared by every usage tool signed in to this
                // account, so a 429 is routine. Numbers from a few minutes ago
                // beat an error line.
                if isRateLimited(error) { markOauthCoolingOff() }
                if isRateLimited(error) || isUnauthorized(error), let stale = lastGoodOAuthResult() {
                    return stale
                }
                // Say why: a signed-out CLI and a throttled endpoint need
                // different actions, and one generic line hid both.
                if isRateLimited(error) {
                    return .unavailable("Claude usage is rate-limited. Retrying shortly.")
                }
                return .unavailable(error.localizedDescription)
            }
        }

        if credentials != nil {
            return lastGoodOAuthResult()
                ?? .unavailable("Claude sign-in expired. Open Claude Code to renew it.")
        }
        return .unavailable("Sign in to Claude Code to show usage.")
    }

    static func parse(_ data: Data) throws -> AgentUsageResult {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let root else { throw AgentUsageError.invalidResponse }
        let windows = windows(from: root)
        guard !windows.isEmpty else { throw AgentUsageError.invalidResponse }
        return AgentUsageResult(windows: windows, hasQuota: true)
    }

    /// Non-empty `claudeAiOauth.accessToken` only. Current Claude Code still
    /// writes the Keychain envelope with blank token strings.
    static func accessToken(in object: [String: Any]) -> String? {
        let oauth = object["claudeAiOauth"] as? [String: Any] ?? object
        if let token = (oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String),
           !token.isEmpty {
            return token
        }
        return nil
    }

    private static func fetchOAuth(token: String, plan: String?) async -> Result<AgentUsageResult, Error> {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Unrecognized clients are rate-limited on this endpoint.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let data = try await usageData(request, expiredMessage: "Claude sign-in expired. Run /login in Claude Code.")
            let result = try parse(data)
            storeLastGood(response: data, plan: plan)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private static func fromLocalCache() -> AgentUsageResult? {
        guard let snapshot = ClaudeLocalUsageCache.load(
            maximumAge: ClaudeLocalUsageCache.maximumAge
        ) else { return nil }
        let windows = [
            snapshot.fiveHour.map { window(id: "claude.five_hour", label: "5h", $0) },
            snapshot.sevenDay.map { window(id: "claude.seven_day", label: "7d", $0) },
        ].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return AgentUsageResult(
            windows: windows,
            message: ClaudeLocalUsageCache.ageLabel(since: snapshot.cachedAt),
            hasQuota: true
        )
    }

    private static func windows(from root: [String: Any]) -> [NanoUsageWindow] {
        if let limits = root["limits"] as? [[String: Any]] {
            let parsed = limits.compactMap(window(fromLimit:))
            if !parsed.isEmpty { return parsed }
        }

        return [
            ("five_hour", "5h", "claude.five_hour"),
            ("seven_day", "7d", "claude.seven_day"),
            ("seven_day_opus", "Opus", "claude.opus"),
        ].compactMap { key, label, id in
            guard let object = root[key] as? [String: Any],
                  let used = usedPercent(in: object)
            else { return nil }
            let reset = reset(in: object)
            return NanoUsageWindow(
                id: id,
                label: label,
                usedPercent: used,
                resetsAt: reset?.date,
                resetAfterSeconds: reset?.seconds
            )
        }
    }

    private static func window(fromLimit limit: [String: Any]) -> NanoUsageWindow? {
        guard let used = usedPercent(in: limit) else { return nil }
        let type = (
            (limit["kind"] as? String) ?? (limit["type"] as? String) ?? ""
        ).lowercased()
        let (id, label): (String, String)
        switch type {
        case "session", "five_hour": (id, label) = ("claude.five_hour", "5h")
        case "weekly_all", "seven_day", "weekly": (id, label) = ("claude.seven_day", "7d")
        case "weekly_scoped", "seven_day_opus": (id, label) = ("claude.opus", "Opus")
        default: return nil
        }
        let reset = reset(in: limit)
        return NanoUsageWindow(
            id: id,
            label: label,
            usedPercent: used,
            resetsAt: reset?.date,
            resetAfterSeconds: reset?.seconds
        )
    }

    private static func usedPercent(in object: [String: Any]) -> Double? {
        if let used = number(object["used_percentage"]) ?? number(object["percent"]) {
            return min(100, max(0, used))
        }
        // Claude Code reports utilization on 0...100. Treating values ≤ 1 as
        // fractions turned a real 1% window into 100%.
        guard let used = number(object["utilization"]) else { return nil }
        return min(100, max(0, used))
    }

    private static func reset(in object: [String: Any]) -> (date: Date, seconds: Int)? {
        if let raw = number(object["resets_at"]), raw > 0 {
            let seconds = raw >= 1e11 ? raw / 1000 : raw
            let date = Date(timeIntervalSince1970: seconds)
            return (date, Int(date.timeIntervalSinceNow))
        }
        if let text = object["resets_at"] as? String, let date = parseISO8601(text) {
            return (date, Int(date.timeIntervalSinceNow))
        }
        return nil
    }

    private static func number(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    private static func window(
        id: String,
        label: String,
        _ source: ClaudeLocalUsageCache.Snapshot.Window
    ) -> NanoUsageWindow {
        let resetsAt = source.resetsAt
        return NanoUsageWindow(
            id: id,
            label: label,
            usedPercent: source.usedPercent,
            resetsAt: resetsAt,
            resetAfterSeconds: resetsAt.map { Int($0.timeIntervalSinceNow) }
        )
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (result: AgentUsageResult, at: Date)?
    nonisolated(unsafe) private static var oauthCoolOffUntil: Date?
    nonisolated(unsafe) private static var oauthFailures = 0
    private static let cacheTTL: TimeInterval = 300
    private static let oauthCoolOff: TimeInterval = 300

    private static func isOauthCoolingOff() -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let oauthCoolOffUntil else { return false }
        return oauthCoolOffUntil > Date()
    }

    /// Doubles per consecutive 429, capped at 30 minutes, so Nano stops
    /// adding to the traffic that is getting the account throttled.
    private static func markOauthCoolingOff() {
        cacheLock.lock()
        oauthFailures += 1
        let delay = min(1_800, oauthCoolOff * pow(2, Double(min(oauthFailures, 4) - 1)))
        oauthCoolOffUntil = Date().addingTimeInterval(delay)
        cacheLock.unlock()
    }

    private static func cachedResult() -> AgentUsageResult? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cache, Date().timeIntervalSince(cache.at) < cacheTTL else { return nil }
        return cache.result
    }

    private static func storeCache(_ result: AgentUsageResult) {
        cacheLock.lock()
        cache = (result, Date())
        oauthFailures = 0
        cacheLock.unlock()
    }

    /// Outside `claude-usage/`, which is watched: writing there would trigger
    /// another refresh.
    private static var lastGoodURL: URL? {
        try? NanoStorage.directory("usage-cache").appendingPathComponent("claude-oauth.json")
    }

    private static func storeLastGood(response: Data, plan: String?) {
        guard let url = lastGoodURL,
              let object = try? JSONSerialization.jsonObject(with: response),
              let data = try? JSONSerialization.data(
                  withJSONObject: ["response": object, "plan": plan ?? NSNull()]
              )
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The last successful answer, persisted so a relaunch during a 429 still
    /// has numbers. Windows that have reset since are dropped, not shown stale.
    static func lastGoodOAuthResult(now: Date = Date()) -> AgentUsageResult? {
        guard let url = lastGoodURL,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = root["response"],
              let responseData = try? JSONSerialization.data(withJSONObject: response),
              var result = try? parse(responseData),
              let savedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate
        else { return nil }
        result.windows.removeAll { ($0.resetsAt ?? .distantFuture) <= now }
        guard !result.windows.isEmpty else { return nil }
        result.planName = root["plan"] as? String
        result.message = ClaudeLocalUsageCache.ageLabel(since: savedAt, now: now)
        return result
    }

    private static let userAgentLock = NSLock()
    nonisolated(unsafe) private static var cachedUserAgent: String?

    private static var userAgent: String {
        userAgentLock.lock()
        defer { userAgentLock.unlock() }
        if let cachedUserAgent { return cachedUserAgent }
        let value = "claude-code/\(installedClaudeVersion() ?? "2.1.80")"
        cachedUserAgent = value
        return value
    }

    private static func installedClaudeVersion() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let version = text.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first
        guard let version, version.contains("."), version.allSatisfy({ $0.isNumber || $0 == "." }) else {
            return nil
        }
        return String(version)
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if let usageError = error as? AgentUsageError, case .unauthorized = usageError {
            return true
        }
        return false
    }

    private static func isRateLimited(_ error: Error) -> Bool {
        if let usageError = error as? AgentUsageError, case let .http(status) = usageError {
            return status == 429
        }
        return false
    }

    /// Access token only. Claude Code's refresh token is never read: using it
    /// would rotate the grant out from under the CLI.
    struct ClaudeCredentials {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?

        /// A minute early, so a request never goes out on a token that lapses
        /// in flight.
        func isExpired(now: Date = Date()) -> Bool {
            guard !accessToken.isEmpty else { return true }
            guard let expiresAt else { return false }
            return expiresAt.addingTimeInterval(-60) < now
        }
    }

    private static func loadCredentials() -> ClaudeCredentials? {
        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
           !token.isEmpty {
            return ClaudeCredentials(accessToken: token)
        }
        _ = removeOAuthTokenCache
        // Whichever of Claude Code's Keychain entry and its credentials file
        // still has a live access token; otherwise the expired one, so the
        // caller can say the sign-in lapsed rather than that it is missing.
        let keychain = keychainCredentials()
        if let keychain, !keychain.isExpired() { return keychain }
        let file = credentialsFromFiles()
        if let file, !file.isExpired() { return file }
        return keychain ?? file
    }

    /// Nano used to keep its own refreshed copy of Claude Code's tokens. Delete
    /// it, and the copy in its old location, once per launch.
    private static let removeOAuthTokenCache: Void = {
        let root = NanoStorage.root
        for path in ["usage-cache/claude-oauth-cache.json", "claude-usage/oauth-cache.json"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
        }
    }()

    private static func credentialsFromFiles() -> ClaudeCredentials? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = [home.appendingPathComponent(".claude", isDirectory: true)]
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !configured.isEmpty {
            roots.insert(URL(fileURLWithPath: configured, isDirectory: true), at: 0)
        }
        if let configured = ProcessInfo.processInfo.environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"],
           !configured.isEmpty {
            roots.insert(URL(fileURLWithPath: configured, isDirectory: true), at: 0)
        }

        for root in roots {
            let url = root.appendingPathComponent(".credentials.json")
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let credentials = credentials(in: object)
            else { continue }
            return credentials
        }
        return nil
    }

    private static func keychainCredentials() -> ClaudeCredentials? {
        guard let data = keychainPassword(),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return credentials(in: object)
    }

    static func credentials(in object: [String: Any]) -> ClaudeCredentials? {
        let oauth = object["claudeAiOauth"] as? [String: Any] ?? object
        guard let access = accessToken(in: object) else { return nil }

        var expiresAt: Date?
        if let raw = number(oauth["expiresAt"] ?? oauth["expires_at"]), raw > 0 {
            let seconds = raw >= 1e11 ? raw / 1000 : raw
            expiresAt = Date(timeIntervalSince1970: seconds)
        }

        return ClaudeCredentials(
            accessToken: access,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    private static func keychainPassword() -> Data? {
        let service = keychainServiceName()
        let account = keychainAccount()
        return securityPassword(service: service, account: account)
            ?? securityPassword(service: service, account: nil)
    }

    private static func keychainServiceName() -> String {
        let environment = ProcessInfo.processInfo.environment
        let configured = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"]
            ?? environment["CLAUDE_CONFIG_DIR"]
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true).path
        guard let configured, !configured.isEmpty else {
            return "Claude Code-credentials"
        }
        let resolved = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL.path
        let defaultResolved = URL(fileURLWithPath: defaultPath, isDirectory: true).standardizedFileURL.path
        guard resolved != defaultResolved else {
            return "Claude Code-credentials"
        }
        let digest = SHA256.hash(data: Data(resolved.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-\(hex.prefix(8))"
    }

    private static func keychainAccount() -> String {
        let user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        if user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil {
            return user
        }
        return "claude-code-user"
    }

    private static func securityPassword(service: String, account: String?) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var arguments = ["find-generic-password", "-s", service]
        if let account, !account.isEmpty {
            arguments += ["-a", account]
        }
        arguments.append("-w")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }
}

enum CursorUsageAdapter {
    /// Cursor stores its own session token in the editor's key/value store, so
    /// Nano never has to touch browser cookies. The token is a JWT whose `sub`
    /// claim is the other half of the session cookie the web API expects.
    static func fetch() async throws -> AgentUsageResult {
        guard let cookie = sessionCookieHeader() else {
            if databaseURL() == nil {
                return .unavailable("Cursor is not installed for this user.")
            }
            return .unavailable("Sign in to Cursor once to read usage.")
        }

        var request = URLRequest(url: URL(string: "https://cursor.com/api/usage-summary")!)
        request.timeoutInterval = 20
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Nano", forHTTPHeaderField: "User-Agent")

        let responseData: Data
        do {
            responseData = try await usageData(request, expiredMessage: "Cursor sign-in expired.")
        } catch {
            return .unavailable(error.localizedDescription)
        }

        do {
            return try parse(responseData)
        } catch {
            return .unavailable("The provider returned an invalid response.")
        }
    }

    /// Cursor's dashboard bills two monthly pools, not a weekly window and not
    /// a single combined percentage.
    ///
    /// `autoPercentUsed` is Cursor Models (Composer, Cursor Grok). Overflow
    /// lands in Other Models or on-demand. `apiPercentUsed` is Other Models
    /// (Claude, Codex, and the rest). Overflow is on-demand only. Both reset
    /// on `billingCycleEnd`. `totalPercentUsed` is kept off the pill: Cursor
    /// dropped the combined bar because the pools overflow differently.
    static func parse(_ data: Data) throws -> AgentUsageResult {
        result(from: try JSONDecoder().decode(CursorUsageEnvelope.self, from: data))
    }

    private static func result(from decoded: CursorUsageEnvelope) -> AgentUsageResult {
        if decoded.isUnlimited == true {
            return AgentUsageResult(
                windows: [],
                message: "Unlimited included usage.",
                hasQuota: false,
                planName: decoded.membershipType
            )
        }

        let reset = billingReset(decoded)
        let plan = decoded.individualUsage?.plan
        var cursorPercent = plan?.autoPercentUsed
        var otherPercent = plan?.apiPercentUsed

        // Team seats often omit `individualUsage.plan`. The two pool
        // percentages still arrive as the dashboard's display strings.
        if cursorPercent == nil || otherPercent == nil,
           let auto = percent(in: decoded.autoModelSelectedDisplayMessage),
           let named = percent(in: decoded.namedModelSelectedDisplayMessage) {
            cursorPercent = cursorPercent ?? auto
            otherPercent = otherPercent ?? named
        }

        var windows: [NanoUsageWindow] = []
        if let cursorPercent {
            windows.append(poolWindow(
                id: "cursor.models",
                label: "Cursor Models",
                usedPercent: cursorPercent,
                reset: reset
            ))
        }
        if let otherPercent {
            windows.append(poolWindow(
                id: "cursor.other",
                label: "Other Models",
                usedPercent: otherPercent,
                reset: reset
            ))
        }

        // A free plan reports `limit: 0`. The percent fields are present but
        // they measure nothing, so the snapshot is marked as having no quota.
        // Team payloads have no limit field; the parsed pools are the quota.
        let hasQuota: Bool
        if let limit = plan?.limit {
            hasQuota = limit > 0 && !windows.isEmpty
        } else {
            hasQuota = !windows.isEmpty
        }

        return AgentUsageResult(
            windows: windows,
            message: hasQuota ? nil : "No included quota on this plan.",
            hasQuota: hasQuota,
            planName: decoded.membershipType
        )
    }

    private static func poolWindow(
        id: String,
        label: String,
        usedPercent: Double,
        reset: (date: Date, seconds: Int)?
    ) -> NanoUsageWindow {
        NanoUsageWindow(
            id: id,
            label: label,
            usedPercent: min(100, max(0, usedPercent)),
            resetsAt: reset?.date,
            resetAfterSeconds: reset?.seconds
        )
    }

    private static func billingReset(_ decoded: CursorUsageEnvelope) -> (date: Date, seconds: Int)? {
        guard let end = parseISO8601(decoded.billingCycleEnd) else { return nil }
        return (end, Int(end.timeIntervalSinceNow))
    }

    /// "You've used 42% of your included total usage" → 42.
    private static func percent(in message: String?) -> Double? {
        guard let message else { return nil }
        guard let match = message.range(of: #"(\d+(?:\.\d+)?)\s*%"#, options: .regularExpression)
        else { return nil }
        let digits = message[match].filter { $0.isNumber || $0 == "." }
        return Double(digits)
    }

    /// Standard install first, then the XDG locations Cursor honors on other
    /// setups. Never assume one path exists.
    private static func databaseURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let suffix = "Cursor/User/globalStorage/state.vscdb"
        var roots = [home.appendingPathComponent("Library/Application Support", isDirectory: true)]
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            roots.append(URL(fileURLWithPath: xdg, isDirectory: true))
        }
        roots.append(home.appendingPathComponent(".config", isDirectory: true))

        return roots
            .map { $0.appendingPathComponent(suffix) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Read-only, and `immutable=1` on the retry so a running Cursor holding the
    /// database open never blocks a refresh.
    private static func readItem(_ key: String, from database: URL) -> String? {
        var handle: OpaquePointer?
        var opened = sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil)
        if opened != SQLITE_OK {
            sqlite3_close(handle)
            handle = nil
            opened = sqlite3_open_v2(
                "\(database.absoluteString)?immutable=1",
                &handle,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                nil
            )
        }
        guard opened == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = '\(key)' LIMIT 1;"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One billed Cursor request, already mapped into Nano's token buckets.
    struct TokenEvent: Equatable, Sendable {
        var id: String
        var timestampMs: Int64
        var model: String
        var counts: NanoTokenCounts
        /// Cursor Agent window id. Transcripts never name the model; this is
        /// how the session list learns it.
        var conversationID: String?
    }

    /// Result of paging the dashboard feed. `truncated` means there is older
    /// history still on the server; the next scan should walk further back.
    struct EventFetch: Sendable {
        var events: [TokenEvent] = []
        var truncated = false
        var failed = false
    }

    /// Pages the dashboard usage-event feed with the same session cookie as
    /// the quota pill. `sinceMs` nil or 0 means every event the API still
    /// has, not a rolling 14-day window. Failures return `failed` so a
    /// Cursor outage cannot block Codex/Claude scans or mark history done.
    static func fetchTokenEvents(
        sinceMs: Int64?,
        untilMs: Int64? = nil,
        maxPages: Int = 80
    ) async -> EventFetch {
        guard let cookie = sessionCookieHeader() else {
            return EventFetch(failed: true)
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let startMs = max(sinceMs ?? 0, 0)
        let endMs = untilMs ?? nowMs
        var events: [TokenEvent] = []
        var truncated = false

        for page in 1...max(maxPages, 1) {
            var request = URLRequest(
                url: URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
            )
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
            request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Nano", forHTTPHeaderField: "User-Agent")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "startDate": "\(startMs)",
                "endDate": "\(endMs)",
                "page": page,
                "pageSize": 100,
            ])

            let pageEvents: [TokenEvent]
            do {
                let data = try await usageData(request, expiredMessage: "Cursor sign-in expired.")
                pageEvents = parseTokenEvents(data)
            } catch {
                return EventFetch(events: events, truncated: true, failed: true)
            }
            if pageEvents.isEmpty {
                return EventFetch(events: events, truncated: false)
            }
            events.append(contentsOf: pageEvents)
            if pageEvents.count < 100 {
                return EventFetch(events: events, truncated: false)
            }
            if page == maxPages {
                truncated = true
            }
        }
        return EventFetch(events: events, truncated: truncated)
    }

    static func parseTokenEvents(_ data: Data) -> [TokenEvent] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["usageEventsDisplay"] as? [[String: Any]]
        else { return [] }
        return list.compactMap(event(from:))
    }

    static func event(from raw: [String: Any]) -> TokenEvent? {
        let model = ((raw["model"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !isPassthroughCLI(model) else { return nil }

        let usage = raw["tokenUsage"] as? [String: Any] ?? [:]
        let input = intField(usage["inputTokens"] ?? usage["input_tokens"])
        let output = intField(usage["outputTokens"] ?? usage["output_tokens"])
        let cacheWrite = intField(usage["cacheWriteTokens"] ?? usage["cache_write_tokens"])
        let cacheRead = intField(
            usage["cacheReadTokens"] ?? usage["cache_read_tokens"] ?? usage["cachedTokens"]
        )
        let counts = NanoTokenCounts(
            freshInput: input,
            cacheRead: cacheRead,
            cacheWrite5m: cacheWrite,
            output: output
        )
        guard counts.total > 0 else { return nil }

        let timestampMs = timestampField(raw["timestamp"])
        guard timestampMs > 0 else { return nil }

        let id = (raw["requestId"] as? String)
            ?? (raw["id"] as? String)
            ?? "\(timestampMs)|\(model)|\(input)|\(output)|\(cacheRead)|\(cacheWrite)"
        let conversation = ((raw["conversationId"] as? String)
            ?? (raw["conversation_id"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TokenEvent(
            id: id,
            timestampMs: timestampMs,
            model: model,
            counts: counts,
            conversationID: (conversation?.isEmpty == false) ? conversation : nil
        )
    }

    /// Cursor sometimes reports a routing lane instead of the model that ran.
    /// Replace it only when the host has an exact model for the same ACP
    /// conversation. A folder or provider-wide fallback is not identity.
    static func resolvedModel(
        reportedModel: String,
        conversationID: String?,
        authoritativeModels: [String: String]
    ) -> String {
        guard isRoutingLabel(reportedModel),
              let conversationID,
              let candidate = authoritativeModels[conversationID]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              !isRoutingLabel(candidate)
        else { return reportedModel }
        return candidate
    }

    static func isRoutingLabel(_ model: String) -> Bool {
        let slug = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return slug == "grok-bot" || slug.hasPrefix("grok-bot-")
    }

    /// Local Claude/Codex CLIs already bank under those providers. Cursor's
    /// feed still names those wrappers when a terminal CLI was launched from
    /// the editor; counting them here would double the row.
    static func isPassthroughCLI(_ model: String) -> Bool {
        let slug = model.lowercased()
        return slug.contains("codex-cli")
            || slug.contains("claude-code")
            || slug.contains("claude-cli")
    }

    private static func sessionCookieHeader() -> String? {
        guard let database = databaseURL(),
              let accessToken = readItem("cursorAuth/accessToken", from: database),
              !accessToken.isEmpty,
              let subject = jwtSubject(accessToken)
        else { return nil }
        let encodedSubject = subject
            .addingPercentEncoding(withAllowedCharacters: .nanoCookieValue) ?? subject
        return "WorkosCursorSessionToken=\(encodedSubject)%3A%3A\(accessToken)"
    }

    private static func intField(_ value: Any?) -> Int {
        switch value {
        case let number as Int: return max(number, 0)
        case let number as Double: return max(Int(number), 0)
        case let number as NSNumber: return max(number.intValue, 0)
        case let text as String: return max(Int(text) ?? 0, 0)
        default: return 0
        }
    }

    private static func timestampField(_ value: Any?) -> Int64 {
        switch value {
        case let number as Int64: return number
        case let number as Int: return Int64(number)
        case let number as Double: return Int64(number)
        case let number as NSNumber: return number.int64Value
        case let text as String: return Int64(text) ?? 0
        default: return 0
        }
    }

    private static func jwtSubject(_ token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var encoded = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)

        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = payload["sub"] as? String,
              !subject.isEmpty
        else {
            return nil
        }
        return subject
    }
}

private extension CharacterSet {
    /// RFC 3986 unreserved set, matching what Cursor's own client encodes with.
    static let nanoCookieValue = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

/// Cursor Agent transcripts never name the model. Usage events do, keyed by
/// `conversationId`, which is the same UUID as the transcript folder.
enum CursorConversationModels {
    static func record(
        _ events: [CursorUsageAdapter.TokenEvent],
        authoritativeModels: [String: String] = [:]
    ) {
        guard !events.isEmpty else { return }
        var map = loadModels()
        for (id, model) in latestModels(
            from: events,
            authoritativeModels: authoritativeModels
        ) {
            map[id] = model
        }
        var contexts = loadContexts()
        for (id, used) in latestContextUsed(from: events) {
            contexts[id] = used
        }
        saveModels(map)
        saveContexts(contexts)
    }

    static func model(for sessionID: String) -> String? {
        loadModels()[sessionID]
    }

    static func contextUsed(for sessionID: String) -> Int? {
        loadContexts()[sessionID]
    }

    static func routingConversationIDs() -> Set<String> {
        routingConversationIDs(in: loadModels())
    }

    static func routingConversationIDs(in models: [String: String]) -> Set<String> {
        Set(models.compactMap { id, model in
            CursorUsageAdapter.isRoutingLabel(model) ? id : nil
        })
    }

    /// Newest event wins. The dashboard feed is newest-first, so walking
    /// oldest-to-newest leaves the model the session is on now.
    static func latestModels(
        from events: [CursorUsageAdapter.TokenEvent],
        authoritativeModels: [String: String] = [:]
    ) -> [String: String] {
        var map: [String: String] = [:]
        for event in events.reversed() {
            guard let id = event.conversationID, !id.isEmpty else { continue }
            map[id] = CursorUsageAdapter.resolvedModel(
                reportedModel: event.model,
                conversationID: id,
                authoritativeModels: authoritativeModels
            )
        }
        return map
    }

    static func latestContextUsed(from events: [CursorUsageAdapter.TokenEvent]) -> [String: Int] {
        var map: [String: Int] = [:]
        for event in events.reversed() {
            guard let id = event.conversationID, !id.isEmpty else { continue }
            map[id] = event.counts.total
        }
        return map
    }

    static func apply(to sessions: inout [AgentSession]) {
        apply(loadModels(), contextUsed: loadContexts(), to: &sessions)
    }

    static func apply(
        _ map: [String: String],
        contextUsed: [String: Int] = [:],
        to sessions: inout [AgentSession]
    ) {
        guard !map.isEmpty || !contextUsed.isEmpty else { return }
        for index in sessions.indices {
            guard sessions[index].provider == .cursor else { continue }
            let id = sessions[index].id
            if sessions[index].model == nil, let model = map[id] {
                sessions[index].model = model
            }
            if let used = contextUsed[id] {
                sessions[index].contextUsed = used
            }
            if sessions[index].contextWindow == nil {
                sessions[index].contextWindow = AgentSession.inferredContextWindow(
                    for: sessions[index].model
                )
            }
        }
    }

    private struct ModelSnapshot: Sendable {
        let modified: Date
        let size: Int64
        let models: [String: String]
    }

    /// Cursor hooks ask for a session's model several times a second, on the
    /// main actor. The file only changes when usage is recorded, so it is
    /// decoded once per write; a stat is enough to tell.
    private static let modelSnapshot = OSAllocatedUnfairLock<ModelSnapshot?>(initialState: nil)

    private static func loadModels() -> [String: String] {
        guard let url = modelFileURL() else { return [:] }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? Int64) ?? 0
        if let modified, let cached = modelSnapshot.withLock({ $0 }),
           cached.modified == modified, cached.size == size {
            return cached.models
        }
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        if let modified {
            modelSnapshot.withLock { $0 = ModelSnapshot(modified: modified, size: size, models: map) }
        }
        return map
    }

    private static func loadContexts() -> [String: Int] {
        guard let url = contextFileURL(),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return map
    }

    private static func saveModels(_ map: [String: String]) {
        guard let url = modelFileURL(),
              let data = try? JSONEncoder().encode(map)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func saveContexts(_ map: [String: Int]) {
        guard let url = contextFileURL(),
              let data = try? JSONEncoder().encode(map)
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func modelFileURL() -> URL? {
        try? NanoStorage.directory("tokens").appendingPathComponent("cursor-conversations.json")
    }

    private static func contextFileURL() -> URL? {
        try? NanoStorage.directory("tokens")
            .appendingPathComponent("cursor-conversation-context.json")
    }
}

enum KimiUsageAdapter {
    /// Kimi for Coding reports quota from the same endpoint its CLI uses.
    /// The API key lives in opencode's auth store — Nano reads it there and
    /// never copies it into Nano storage.
    static func fetch() async throws -> AgentUsageResult {
        guard let key = apiKey(), !key.isEmpty else {
            return .unavailable("Sign in to Kimi for Coding to see usage.")
        }

        var request = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/usages")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Nano", forHTTPHeaderField: "User-Agent")

        let responseData: Data
        do {
            responseData = try await usageData(request, expiredMessage: "Kimi sign-in expired.")
        } catch {
            return .unavailable(error.localizedDescription)
        }

        let decoded = try JSONDecoder().decode(KimiUsageEnvelope.self, from: responseData)
        var windows: [NanoUsageWindow] = []
        if let usage = decoded.usage {
            windows.append(NanoUsageWindow(
                id: "kimi.weekly",
                label: "Weekly",
                usedPercent: usage.usedPercent,
                resetsAt: parseISO8601(usage.resetTime),
                resetAfterSeconds: parseISO8601(usage.resetTime).map { Int($0.timeIntervalSinceNow) }
            ))
        }
        for (index, limit) in (decoded.limits ?? []).enumerated() {
            guard let detail = limit.detail else { continue }
            windows.append(NanoUsageWindow(
                id: "kimi.limit\(index)",
                label: limit.windowSeconds.map { NanoUsageFormat.windowLabel(seconds: $0) } ?? "Window",
                usedPercent: detail.usedPercent,
                resetsAt: parseISO8601(detail.resetTime),
                resetAfterSeconds: parseISO8601(detail.resetTime).map { Int($0.timeIntervalSinceNow) }
            ))
        }

        return AgentUsageResult(
            windows: windows,
            message: windows.isEmpty ? "No rate limits reported." : nil,
            hasQuota: !windows.isEmpty,
            planName: Self.planName(decoded.user?.membership?.level)
        )
    }

    private static func apiKey() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let key = environment["KIMI_API_KEY"], !key.isEmpty { return key }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = environment["OPENCODE_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        guard let data = try? Data(contentsOf: base.appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["kimi-for-coding"] as? [String: Any]
        else { return nil }
        return entry["key"] as? String
    }

    private static func planName(_ level: String?) -> String? {
        guard let level else { return nil }
        return level.replacingOccurrences(of: "LEVEL_", with: "").capitalized
    }
}

private func usageData(_ request: URLRequest, expiredMessage: String) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw AgentUsageError.invalidResponse
    }
    guard (200...299).contains(http.statusCode) else {
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AgentUsageError.unauthorized(expiredMessage)
        }
        throw AgentUsageError.http(http.statusCode)
    }
    return data
}

private func parseISO8601(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    return NanoISO8601.date(raw)
}

// The keys below match the live APIs. Codex's local session files use plural
// forms for some of the same concepts — those do not apply here.
private struct KimiUsageEnvelope: Decodable {
    var usage: Detail?
    var limits: [RateLimit]?
    var user: User?

    struct Detail: Decodable {
        var limit: String?
        var used: String?
        var remaining: String?
        var resetTime: String?

        /// Quota figures arrive as decimal strings ("limit": "100").
        var usedPercent: Double {
            guard let limit, let limitValue = Double(limit), limitValue > 0,
                  let used, let usedValue = Double(used)
            else { return 0 }
            return min(100, max(0, usedValue / limitValue * 100))
        }
    }

    struct RateLimit: Decodable {
        var window: Window?
        var detail: Detail?

        struct Window: Decodable {
            var duration: Int?
            var timeUnit: String?
        }

        var windowSeconds: Int? {
            guard let duration = window?.duration else { return nil }
            switch window?.timeUnit {
            case "TIME_UNIT_HOUR": return duration * 3_600
            case "TIME_UNIT_DAY": return duration * 86_400
            default: return duration * 60
            }
        }
    }

    struct User: Decodable {
        var membership: Membership?

        struct Membership: Decodable {
            var level: String?
        }
    }
}

private struct CodexUsageEnvelope: Decodable {
    let planType: String?
    let rateLimit: RateLimit?
    let additionalRateLimits: [AdditionalRateLimit]?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct AdditionalRateLimit: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Int?
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }
}

private struct CursorUsageEnvelope: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let isUnlimited: Bool?
    let autoModelSelectedDisplayMessage: String?
    let namedModelSelectedDisplayMessage: String?
    let individualUsage: IndividualUsage?

    struct IndividualUsage: Decodable {
        let plan: Plan?
        let onDemand: OnDemand?
    }

    struct Plan: Decodable {
        let enabled: Bool?
        let used: Double?
        let limit: Double?
        let remaining: Double?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }

    struct OnDemand: Decodable {
        let enabled: Bool?
        let used: Double?
        let limit: Double?
        let remaining: Double?
    }
}

enum GrokUsageAdapter {
    /// SuperGrok credits from the same cli-chat-proxy billing the TUI `/usage`
    /// command hits. `grok agent stdio` `x.ai/billing` is TUI-owned on 1.0.5
    /// and times out here, so the HTTP path is the one that actually fills
    /// the pill. Token counting still reads session logs and does not depend
    /// on this.
    static func fetch() async throws -> AgentUsageResult {
        guard accessToken() != nil else {
            return .unavailable("Sign in with grok login to see usage.")
        }

        do {
            let data = try await billingResultJSON()
            var result = try parse(data)
            if result.planName == nil {
                result.planName = planNameFromAuth()
            }
            return result
        } catch AgentUsageError.invalidResponse {
            return .unavailable("This Grok CLI build does not publish credits Nano can read.")
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func parse(_ data: Data) throws -> AgentUsageResult {
        let decoded = try JSONDecoder().decode(GrokBillingEnvelope.self, from: data)
        if decoded.disabledByConfig == true {
            return AgentUsageResult(message: "Grok billing is disabled in this configuration.")
        }

        if let window = creditWindow(from: decoded) {
            return AgentUsageResult(windows: [window], hasQuota: true)
        }

        return AgentUsageResult(
            message: "No included credits on this plan.",
            planName: nil
        )
    }

    private static func creditWindow(from decoded: GrokBillingEnvelope) -> NanoUsageWindow? {
        if let config = decoded.config {
            let percent = config.creditUsagePercent
                ?? config.productUsage?.first(where: {
                    ($0.product ?? "").localizedCaseInsensitiveContains("grokbuild")
                })?.usagePercent
            if let percent {
                let end = config.currentPeriod?.end ?? config.billingPeriodEnd
                return creditWindow(
                    usedPercent: percent,
                    resetsAt: parseISO8601(end),
                    periodType: config.currentPeriod?.type
                )
            }
            // GetGrokCreditsConfig is protobuf-backed. Its JSON form omits a
            // zero-valued percentage, but a valid current period still proves
            // that the account has an included quota window at 0% used.
            if let period = config.currentPeriod,
               let resetsAt = parseISO8601(period.end),
               resetsAt > Date() {
                return creditWindow(
                    usedPercent: 0,
                    resetsAt: resetsAt,
                    periodType: period.type
                )
            }
        }

        let limit = decoded.monthlyLimit?.val ?? 0
        let used = decoded.usage?.totalUsed?.val ?? decoded.usage?.includedUsed?.val ?? 0
        guard limit > 0 else { return nil }
        return creditWindow(
            usedPercent: Double(used) / Double(limit) * 100,
            resetsAt: parseISO8601(decoded.billingCycle?.billingPeriodEnd),
            periodType: nil
        )
    }

    private static func creditWindow(
        usedPercent: Double,
        resetsAt: Date?,
        periodType: String?
    ) -> NanoUsageWindow {
        NanoUsageWindow(
            id: "grok.credits",
            label: creditLabel(periodType: periodType, resetsAt: resetsAt),
            usedPercent: min(100, max(0, usedPercent)),
            resetsAt: resetsAt,
            resetAfterSeconds: resetsAt.map { Int($0.timeIntervalSinceNow) }
        )
    }

    private static func creditLabel(periodType: String?, resetsAt: Date?) -> String {
        if let periodType {
            let type = periodType.lowercased()
            if type.contains("week") { return "Weekly" }
            if type.contains("month") { return "Monthly" }
            if type.contains("day") { return "Daily" }
        }
        guard let resetsAt else { return "Credits" }
        let seconds = resetsAt.timeIntervalSinceNow
        if seconds > 20 * 86_400, seconds < 40 * 86_400 { return "Monthly" }
        if seconds > 5 * 86_400, seconds < 10 * 86_400 { return "Weekly" }
        return "Credits"
    }

    private static func grokHome() -> URL {
        if let configured = ProcessInfo.processInfo.environment["GROK_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }

    /// `auth_mode` is the only identity field worth showing; tokens stay in
    /// the CLI's file and are never copied into Nano storage.
    private static func planNameFromAuth() -> String? {
        guard let data = try? Data(contentsOf: grokHome().appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for value in root.values {
            guard let entry = value as? [String: Any],
                  let mode = entry["auth_mode"] as? String,
                  !mode.isEmpty
            else { continue }
            if mode.lowercased() == "oidc" { return "SuperGrok" }
            return mode
        }
        return nil
    }

    /// Same `key` the CLI sends as `Authorization: Bearer`. Never copied out
    /// of `auth.json`.
    private static func accessToken() -> String? {
        guard let data = try? Data(contentsOf: grokHome().appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for value in root.values {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String,
                  !key.isEmpty
            else { continue }
            return key
        }
        return nil
    }

    private static func billingURL() -> URL? {
        var base = ProcessInfo.processInfo.environment["GROK_CLI_CHAT_PROXY_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if base.isEmpty { base = "https://cli-chat-proxy.grok.com/v1" }
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: "\(base)/billing?format=credits")
    }

    private static func billingResultJSON() async throws -> Data {
        guard let token = accessToken(), let url = billingURL() else {
            throw AgentUsageError.credentialsMissing("Sign in with grok login to see usage.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        if let userID = authValue("user_id") {
            request.setValue(userID, forHTTPHeaderField: "x-userid")
        }
        request.setValue("headless", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Nano", forHTTPHeaderField: "User-Agent")
        return try await usageData(
            request,
            expiredMessage: "Grok sign-in expired. Run grok login."
        )
    }

    private static func authValue(_ key: String) -> String? {
        guard let data = try? Data(contentsOf: grokHome().appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for value in root.values {
            guard let entry = value as? [String: Any],
                  let value = entry[key] as? String,
                  !value.isEmpty
            else { continue }
            return value
        }
        return nil
    }
}

private struct GrokBillingEnvelope: Decodable {
    let config: Config?
    let billingCycle: Cycle?
    let monthlyLimit: Amount?
    let disabledByConfig: Bool?
    let usage: Usage?

    struct Config: Decodable {
        let currentPeriod: Period?
        let creditUsagePercent: Double?
        let productUsage: [ProductUsage]?
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
    }

    struct Period: Decodable {
        let type: String?
        let start: String?
        let end: String?
    }

    struct ProductUsage: Decodable {
        let product: String?
        let usagePercent: Double?
    }

    struct Cycle: Decodable {
        let billingPeriodStart: String?
        let billingPeriodEnd: String?
    }

    struct Amount: Decodable {
        let val: Int?
    }

    struct Usage: Decodable {
        let includedUsed: Amount?
        let onDemandUsed: Amount?
        let totalUsed: Amount?
    }
}

// MARK: - Second usage batch
//
// Devin, Kilo Code, Gemini, Cline, and OpenCode all expose a real quota, each
// behind credentials the vendor's own CLI already keeps on disk. Credentials
// are read in place and never copied into Nano storage; refreshed OAuth tokens
// land in a Nano-private cache instead of the vendor's file.
//
// Each adapter takes the process environment, home directory, and transport as
// parameters so tests can point them at fixtures instead of this Mac.

/// The transport signature every fetch path shares. Production passes
/// `URLSession.shared.data(for:)`; tests stub it.
private func usageHTTP(
    _ request: URLRequest,
    load: (URLRequest) async throws -> (Data, URLResponse)
) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await load(request)
    guard let http = response as? HTTPURLResponse else {
        throw AgentUsageError.invalidResponse
    }
    return (data, http)
}

enum DevinUsageAdapter {
    /// The Devin CLI stores its login as `windsurf_api_key` in credentials.toml.
    /// Devin Desktop keeps the browser session in localStorage, which Nano
    /// never reads - the CLI key is the only credential source here.
    static func fetch() async throws -> AgentUsageResult {
        await fetch(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        ) { try await URLSession.shared.data(for: $0) }
    }

    struct Credentials: Sendable {
        let token: String
        let host: String

        func url(_ path: String) -> URL? {
            URL(string: "https://\(host)/\(path)")
        }
    }

    static func fetch(
        environment: [String: String],
        home: URL,
        load: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> AgentUsageResult {
        guard let credentials = credentials(environment: environment, home: home),
              let organizationsURL = credentials.url("api/organizations")
        else {
            return .unavailable("Sign in to the Devin CLI to see usage.")
        }

        do {
            let organizationID = try await fetchOrganizationID(
                credentials: credentials, url: organizationsURL, load: load)
            guard let organizationID,
                  let quotaURL = credentials.url("api/\(organizationID)/billing/quota/usage")
            else {
                return .unavailable("No Devin organization on this account.")
            }

            var request = URLRequest(url: quotaURL)
            request.timeoutInterval = 15
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(organizationID, forHTTPHeaderField: "x-cog-org-id")
            request.setValue("Nano", forHTTPHeaderField: "User-Agent")

            let (data, http) = try await usageHTTP(request, load: load)
            if http.statusCode == 401 || http.statusCode == 403 {
                if isMissingOrganization(data) {
                    return .unavailable("No Devin organization on this account.")
                }
                return .unavailable("Devin sign-in expired. Run devin login.")
            }
            guard http.statusCode == 200 else {
                return .unavailable("Provider usage request failed (HTTP \(http.statusCode)).")
            }
            return try parse(data)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// `DEVIN_BEARER_TOKEN` wins over the CLI's credentials.toml. The file is
    /// flat `key = "value"` TOML; `devin_webapp_host` picks the API host for
    /// self-hosted deployments.
    static func credentials(environment: [String: String], home: URL) -> Credentials? {
        let toml = credentialsFile(environment: environment, home: home)
        let values = toml.flatMap { parseTOML($0) } ?? [:]

        let envToken = environment["DEVIN_BEARER_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token = envToken.flatMap { $0.isEmpty ? nil : $0 }
            ?? values["windsurf_api_key"]
        guard let token else { return nil }

        var host = values["devin_webapp_host"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.isEmpty { host = "app.devin.ai" }
        for prefix in ["https://", "http://"] where host.hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty else { return nil }
        return Credentials(token: token, host: host)
    }

    private static func credentialsFile(environment: [String: String], home: URL) -> URL? {
        let base = environment["XDG_DATA_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        let file = base.appendingPathComponent("devin/credentials.toml")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Flat `key = "value"` pairs only - enough for Devin's generated file,
    /// which carries no tables or multiline strings.
    private static func parseTOML(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("["),
                  let separator = trimmed.firstIndex(of: "=")
            else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            var value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !value.isEmpty else { continue }
            values[key] = value
        }
        return values
    }

    /// Primary org first, first entry otherwise - the order Devin's own web
    /// app resolves the active organization.
    private static func fetchOrganizationID(
        credentials: Credentials,
        url: URL,
        load: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Nano", forHTTPHeaderField: "User-Agent")

        let (data, http) = try await usageHTTP(request, load: load)
        guard http.statusCode == 200 else {
            if http.statusCode == 401 || http.statusCode == 403 {
                if isMissingOrganization(data) { return nil }
                throw AgentUsageError.unauthorized("Devin sign-in expired. Run devin login.")
            }
            throw AgentUsageError.http(http.statusCode)
        }

        guard let organizations = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw AgentUsageError.invalidResponse }
        func orgID(_ entry: [String: Any]) -> String? {
            ((entry["org_id"] ?? entry["id"]) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return organizations.first(where: { ($0["is_primary_org"] as? Bool) == true })
            .flatMap(orgID) ?? organizations.first.flatMap(orgID)
    }

    private static func isMissingOrganization(_ data: Data) -> Bool {
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"]
            as? String
        return detail == "No organizations found for auth1 user"
    }

    /// `daily_percentage`/`weekly_percentage` are always percentage points:
    /// the live 2026-09-23 response sent `weekly_percentage: 100`, which a
    /// fraction heuristic would have read as fully used at any value above 0.
    /// Only the unverified nested fallback shapes keep the <= 1 scaling.
    static func parse(_ data: Data) throws -> AgentUsageResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AgentUsageError.invalidResponse }

        // Accounts without a quota plan are a valid state, not an error.
        if (root["is_quota_plan"] as? Bool) == false {
            return AgentUsageResult(
                message: "No quota plan on this Devin account.",
                planName: planName(in: root)
            )
        }

        var windows: [NanoUsageWindow] = []
        if (root["hide_daily_quota"] as? Bool) != true {
            let daily = number(root["daily_percentage"]).map {
                (usedPercent: min(100, max(0, $0)), resetsAt: date(root["daily_reset_at"]))
            } ?? findWindow(in: root, matching: isDailyKey)
            if let daily {
                windows.append(NanoUsageWindow(
                    id: "devin.daily",
                    label: "Daily",
                    usedPercent: daily.usedPercent,
                    resetsAt: daily.resetsAt,
                    resetAfterSeconds: daily.resetsAt.map { Int($0.timeIntervalSinceNow) }
                ))
            }
        }
        let weekly = number(root["weekly_percentage"]).map {
            (usedPercent: min(100, max(0, $0)), resetsAt: date(root["weekly_reset_at"]))
        } ?? findWindow(in: root, matching: isWeeklyKey)
        if let weekly {
            windows.append(NanoUsageWindow(
                id: "devin.weekly",
                label: "Weekly",
                usedPercent: weekly.usedPercent,
                resetsAt: weekly.resetsAt,
                resetAfterSeconds: weekly.resetsAt.map { Int($0.timeIntervalSinceNow) }
            ))
        }
        guard !windows.isEmpty else { throw AgentUsageError.invalidResponse }
        return AgentUsageResult(windows: windows, hasQuota: true, planName: planName(in: root))
    }

    /// CodexBar's recursive fallback: find a `daily`- or `weekly`-keyed value
    /// anywhere in the payload and read a window out of it. These nested
    /// shapes are unverified against the live API, so they keep CodexBar's
    /// fraction heuristic - values at or below 1 scale to percent.
    private static func findWindow(
        in object: Any,
        matching keyMatches: (String) -> Bool
    ) -> (usedPercent: Double, resetsAt: Date?)? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary where keyMatches(key) {
                if let window = nestedWindow(from: value) { return window }
            }
            for value in dictionary.values {
                if let found = findWindow(in: value, matching: keyMatches) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findWindow(in: value, matching: keyMatches) { return found }
            }
        }
        return nil
    }

    private static func nestedWindow(
        from object: Any
    ) -> (usedPercent: Double, resetsAt: Date?)? {
        guard let dictionary = object as? [String: Any] else {
            guard let percent = nestedPercent(from: object) else { return nil }
            return (min(100, max(0, percent)), nil)
        }
        if let percent = nestedPercent(from: dictionary) {
            return (min(100, max(0, percent)), resetDate(in: dictionary))
        }
        for value in dictionary.values {
            if let nested = nestedWindow(from: value) { return nested }
        }
        return nil
    }

    private static func nestedPercent(from object: Any) -> Double? {
        if let value = number(object) {
            return value <= 1 ? value * 100 : value
        }
        guard let dictionary = object as? [String: Any] else { return nil }

        for key in ["used_percent", "usedPercent", "usage_percent", "usagePercent",
                    "percent_used", "percentUsed", "percent"] {
            if let value = number(dictionary[key]) {
                return value <= 1 ? value * 100 : value
            }
        }
        for key in ["remaining_percent", "remainingPercent",
                    "percent_remaining", "percentRemaining"] {
            if let value = number(dictionary[key]) {
                return 100 - (value <= 1 ? value * 100 : value)
            }
        }

        let used = firstNumber(in: dictionary,
                               keys: ["used", "usage", "used_count", "usedCount", "consumed"])
        let limit = firstNumber(in: dictionary,
                                keys: ["limit", "quota", "total", "max", "available"])
        if let used, let limit, limit > 0 { return used / limit * 100 }
        let remaining = firstNumber(in: dictionary, keys: ["remaining", "left", "available"])
        if let remaining, let limit, limit > 0 {
            return (limit - remaining) / limit * 100
        }
        return nil
    }

    private static func isDailyKey(_ raw: String) -> Bool {
        let key = raw.lowercased()
        return !key.contains("hide") && (key.contains("daily") || key.contains("day"))
    }

    private static func isWeeklyKey(_ raw: String) -> Bool {
        let key = raw.lowercased()
        return !key.contains("hide") && (key.contains("weekly") || key.contains("week"))
    }

    private static func resetDate(in dictionary: [String: Any]) -> Date? {
        for (key, value) in dictionary
        where key.localizedCaseInsensitiveContains("reset") {
            if let reset = date(value) { return reset }
        }
        return nil
    }

    private static func firstNumber(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = number(dictionary[key]) { return value }
        }
        return nil
    }

    private static func planName(in root: [String: Any]) -> String? {
        for key in ["plan_name", "planName", "plan", "tier", "subscription_tier", "subscriptionTier"] {
            if let value = (root[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as NSNumber:
            CFGetTypeID(value) == CFBooleanGetTypeID() ? nil : value.doubleValue
        case let value as String:
            Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func date(_ raw: Any?) -> Date? {
        if let text = raw as? String { return parseISO8601(text) }
        if let value = number(raw), value > 0 {
            let seconds = value > 10_000_000_000 ? value / 1000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

enum KiloUsageAdapter {
    /// Kilo's CLI keeps the device-flow token in `~/.local/share/kilo/auth.json`
    /// (`kilo.access`); there is no refresh endpoint - the vendor's device auth
    /// stores one token for about a year. `KILO_API_KEY` wins when set.
    static func fetch() async throws -> AgentUsageResult {
        await fetch(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        ) { try await URLSession.shared.data(for: $0) }
    }

    struct Credential: Sendable {
        let token: String
        let accountID: String?
    }

    static func fetch(
        environment: [String: String],
        home: URL,
        load: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> AgentUsageResult {
        guard let credential = credential(environment: environment, home: home),
              let url = batchURL()
        else {
            return .unavailable("Sign in to Kilo Code to see usage.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Nano", forHTTPHeaderField: "User-Agent")
        if let accountID = credential.accountID {
            request.setValue(accountID, forHTTPHeaderField: "X-KILOCODE-ORGANIZATIONID")
        }

        do {
            let (data, http) = try await usageHTTP(request, load: load)
            if http.statusCode == 401 || http.statusCode == 403 {
                return .unavailable("Kilo Code sign-in expired. Run kilo auth login.")
            }
            guard http.statusCode == 200 else {
                return .unavailable("Provider usage request failed (HTTP \(http.statusCode)).")
            }
            return try parse(data)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func credential(environment: [String: String], home: URL) -> Credential? {
        if let key = environment["KILO_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty
        {
            return Credential(token: key, accountID: nil)
        }

        let dataDir = environment["XDG_DATA_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        let file = dataDir.appendingPathComponent("kilo/auth.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["kilo"] as? [String: Any],
              let access = (entry["access"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty
        else { return nil }

        // The token is also the refresh token and lives about a year; an
        // expired `expires` means signed out, not silently stale data.
        if let expires = number(entry["expires"]), expires > 0,
           Date(timeIntervalSince1970: expires / 1000) < Date()
        {
            return nil
        }

        let accountID = (entry["accountId"] as? String ?? entry["accountID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Credential(token: access, accountID: accountID?.isEmpty == false ? accountID : nil)
    }

    /// One tRPC batch fetches the credit balance and the Kilo Pass state.
    static func batchURL() -> URL? {
        var components = URLComponents(
            string: "https://app.kilo.ai/api/trpc/user.getCreditBlocks,kiloPass.getState"
        )
        components?.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: #"{"0":{"json":null},"1":{"json":null}}"#),
        ]
        return components?.url
    }

    static func parse(_ data: Data) throws -> AgentUsageResult {
        guard let root = try? JSONSerialization.jsonObject(with: data)
        else { throw AgentUsageError.invalidResponse }

        let entries = try entriesByIndex(from: root)
        var payloads: [Int: Any] = [:]
        for index in 0...1 {
            guard let entry = entries[index] else { continue }
            if let error = entry["error"] as? [String: Any] {
                let code = string(at: ["json", "data", "code"], in: error)
                    ?? string(at: ["data", "code"], in: error)
                    ?? error["code"] as? String
                let message = string(at: ["json", "message"], in: error)
                    ?? error["message"] as? String
                let combined = [code, message].compactMap { $0?.lowercased() }.joined(separator: " ")
                if combined.contains("unauthorized") || combined.contains("forbidden") {
                    throw AgentUsageError.unauthorized(
                        "Kilo Code sign-in expired. Run kilo auth login.")
                }
                throw AgentUsageError.invalidResponse
            }
            if let payload = resultPayload(from: entry) {
                payloads[index] = payload
            }
        }

        var windows: [NanoUsageWindow] = []
        var planName: String?

        // Kilo Pass is the primary quota; credit blocks are the fallback meter.
        if let subscription = subscriptionData(from: payloads[1]) {
            planName = (subscription["tier"] as? String).map(planNameForTier(_:)) ?? "Kilo Pass"
            let used = number(subscription["currentPeriodUsageUsd"]).map { max(0, $0) }
            let base = number(subscription["currentPeriodBaseCreditsUsd"]).map { max(0, $0) }
            let bonus = max(0, number(subscription["currentPeriodBonusCreditsUsd"]) ?? 0)
            if let total = base.map({ $0 + bonus }) {
                let usedPercent = total > 0 ? min(100, max(0, (used ?? 0) / total * 100)) : 100
                let reset = ["nextBillingAt", "nextRenewalAt", "renewsAt", "renewAt"]
                    .lazy.compactMap { kiloDate(subscription[$0]) }.first
                windows.append(NanoUsageWindow(
                    id: "kilo.pass",
                    label: "Kilo Pass",
                    usedPercent: usedPercent,
                    resetsAt: reset,
                    resetAfterSeconds: reset.map { Int($0.timeIntervalSinceNow) }
                ))
            }
        }
        planName = planName ?? fallbackPlanName(from: payloads[1])

        if let credits = creditFields(from: payloads[0]) {
            let usedPercent: Double
            if let total = credits.total {
                usedPercent = total > 0
                    ? min(100, max(0, (credits.used ?? 0) / total * 100))
                    : 100
            } else {
                usedPercent = 0
            }
            windows.append(NanoUsageWindow(
                id: "kilo.credits",
                label: "Credits",
                usedPercent: usedPercent,
                resetsAt: nil,
                resetAfterSeconds: nil
            ))
        }

        return AgentUsageResult(
            windows: windows,
            message: windows.isEmpty ? "No Kilo credits or pass on this account." : nil,
            hasQuota: !windows.isEmpty,
            planName: planName
        )
    }

    /// tRPC batches arrive as a positional array; some transports wrap the
    /// same entries under numeric string keys. Entries beyond the two
    /// requested procedures are ignored.
    private static func entriesByIndex(from root: Any) throws -> [Int: [String: Any]] {
        if let entries = root as? [[String: Any]] {
            return Dictionary(
                uniqueKeysWithValues: entries.prefix(2).enumerated().map { ($0.offset, $0.element) }
            )
        }
        if let dictionary = root as? [String: Any] {
            if dictionary["result"] != nil || dictionary["error"] != nil {
                return [0: dictionary]
            }
            let indexed = dictionary.compactMap { key, value -> (Int, [String: Any])? in
                guard let index = Int(key), index >= 0, index < 2,
                      let entry = value as? [String: Any]
                else { return nil }
                return (index, entry)
            }
            if !indexed.isEmpty {
                return Dictionary(uniqueKeysWithValues: indexed)
            }
        }
        throw AgentUsageError.invalidResponse
    }

    private static func resultPayload(from entry: [String: Any]) -> Any? {
        guard let result = entry["result"] as? [String: Any] else { return nil }
        if let data = result["data"] as? [String: Any] {
            if let json = data["json"] { return json is NSNull ? nil : json }
            return data
        }
        if let json = result["json"] { return json is NSNull ? nil : json }
        return nil
    }

    /// `subscription` may be absent (no pass) or null; the pass fields also
    /// appear at payload top level on some responses.
    private static func subscriptionData(from payload: Any?) -> [String: Any]? {
        guard let dictionary = payload as? [String: Any] else { return nil }
        if let subscription = dictionary["subscription"] as? [String: Any] { return subscription }
        if dictionary["subscription"] is NSNull { return nil }
        let shaped = dictionary["currentPeriodUsageUsd"] != nil
            || dictionary["currentPeriodBaseCreditsUsd"] != nil
            || dictionary["currentPeriodBonusCreditsUsd"] != nil
            || dictionary["tier"] != nil
        return shaped ? dictionary : nil
    }

    private static func creditFields(
        from payload: Any?
    ) -> (used: Double?, total: Double?, remaining: Double?)? {
        guard let payload else { return nil }
        let contexts = dictionaryContexts(from: payload)

        if let blocks = firstArray(["creditBlocks"], in: contexts) {
            var total = 0.0
            var remaining = 0.0
            var sawTotal = false
            var sawRemaining = false
            for case let block as [String: Any] in blocks {
                if let amount = number(block["amount_mUsd"]) {
                    total += amount / 1_000_000
                    sawTotal = true
                }
                if let balance = number(block["balance_mUsd"]) {
                    remaining += balance / 1_000_000
                    sawRemaining = true
                }
            }
            if sawTotal || sawRemaining {
                let resolvedTotal = sawTotal ? max(0, total) : nil
                let resolvedRemaining = sawRemaining ? max(0, remaining) : nil
                let used = resolvedTotal.flatMap { t in
                    resolvedRemaining.map { max(0, t - $0) }
                }
                return (used, resolvedTotal, resolvedRemaining)
            }
        }

        let usedKeys = ["usedCredits", "used", "creditsUsed", "consumed", "spent"]
        let totalKeys = ["totalCredits", "total", "creditsTotal", "limit"]
        let remainingKeys = ["remainingCredits", "remaining", "creditsRemaining"]

        var used = firstDouble(usedKeys, in: contexts)
        var total = firstDouble(totalKeys, in: contexts)
        var remaining = firstDouble(remainingKeys, in: contexts)

        if total == nil, let used, let remaining { total = used + remaining }
        if used == nil, let total, let remaining { used = max(0, total - remaining) }
        if remaining == nil, let total, let used { remaining = max(0, total - used) }

        if used == nil, total == nil, remaining == nil,
           let balance = firstDouble(["totalBalance_mUsd"], in: contexts)
        {
            // Zero-balance accounts return an empty creditBlocks list; keep
            // the exhausted state visible instead of reporting no data.
            if balance == 0 { return (0, 0, 0) }
            let dollars = max(0, balance / 1_000_000)
            return (0, dollars, dollars)
        }

        guard used != nil || total != nil || remaining != nil else { return nil }
        return (used, total, remaining)
    }

    private static func fallbackPlanName(from payload: Any?) -> String? {
        guard let payload else { return nil }
        let contexts = dictionaryContexts(from: payload)
        if let name = firstString(
            ["planName", "tier", "tierName", "passName", "subscriptionName"], in: contexts)
        {
            return name
        }
        for path in [["plan", "name"], ["subscription", "plan", "name"],
                     ["subscription", "name"], ["pass", "name"], ["state", "name"], ["state"]] {
            for context in contexts {
                if let value = string(at: path, in: context), !value.isEmpty { return value }
            }
        }
        if let name = firstString(["name"], in: contexts),
           name.lowercased().contains("pass")
        {
            return name
        }
        return nil
    }

    private static func planNameForTier(_ tier: String) -> String {
        switch tier.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "tier_19": "Starter"
        case "tier_49": "Pro"
        case "tier_199": "Expert"
        case let other: other.isEmpty ? "Kilo Pass" : other
        }
    }

    /// Payloads nest under `json`/`data`/`subscription`; collect the root and
    /// nested dictionaries to depth 2, matching CodexBar's tolerance.
    private static func dictionaryContexts(from payload: Any) -> [[String: Any]] {
        guard let dictionary = payload as? [String: Any] else { return [] }
        var contexts: [[String: Any]] = []
        var queue: [(dictionary: [String: Any], depth: Int)] = [(dictionary, 0)]
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            contexts.append(current)
            guard depth < 2 else { continue }
            for value in current.values {
                if let nested = value as? [String: Any] {
                    queue.append((nested, depth + 1))
                } else if let array = value as? [Any] {
                    for case let nested as [String: Any] in array {
                        queue.append((nested, depth + 1))
                    }
                }
            }
        }
        return contexts
    }

    private static func firstArray(_ keys: [String], in contexts: [[String: Any]]) -> [Any]? {
        for context in contexts {
            for key in keys where context[key] is [Any] {
                return context[key] as? [Any]
            }
        }
        return nil
    }

    private static func firstDouble(_ keys: [String], in contexts: [[String: Any]]) -> Double? {
        for context in contexts {
            for key in keys {
                if let value = number(context[key]) { return value }
            }
        }
        return nil
    }

    private static func firstString(_ keys: [String], in contexts: [[String: Any]]) -> String? {
        for context in contexts {
            for key in keys {
                if let value = (context[key] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
                {
                    return value
                }
            }
        }
        return nil
    }

    private static func string(at path: [String], in dictionary: [String: Any]) -> String? {
        var cursor: Any = dictionary
        for key in path {
            guard let next = (cursor as? [String: Any])?[key] else { return nil }
            cursor = next
        }
        return cursor as? String
    }

    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as NSNumber:
            CFGetTypeID(value) == CFBooleanGetTypeID() ? nil : value.doubleValue
        case let value as String:
            Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func kiloDate(_ raw: Any?) -> Date? {
        if let text = raw as? String { return parseISO8601(text) }
        if let value = number(raw), value > 0 {
            let seconds = value > 1_000_000_000_000 ? value / 1000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

enum GeminiUsageAdapter {
    /// Gemini CLI's OAuth sign-in is the only supported source; API-key and
    /// Vertex users have no quota endpoint. `~/.gemini/oauth_creds.json` is
    /// read in place and never written - a refreshed token lands in Nano's own
    /// cache the way Claude's does.
    static func fetch() async throws -> AgentUsageResult {
        await fetch(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        ) { try await URLSession.shared.data(for: $0) }
    }

    struct Credentials: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiryDate: Date?
        var idToken: String?

        var needsRefresh: Bool {
            accessToken.isEmpty || expiryDate.map { $0 < Date() } == true
        }
    }

    static func fetch(
        environment: [String: String],
        home: URL,
        cacheFile: URL? = nil,
        load: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> AgentUsageResult {
        let cacheFile = cacheFile ?? defaultCacheURL()
        guard var credentials = fileCredentials(home: home)
            ?? cachedCredentials(from: cacheFile),
            !credentials.accessToken.isEmpty || credentials.refreshToken != nil
        else {
            return .unavailable("Sign in to Gemini CLI once to see usage.")
        }

        if credentials.needsRefresh {
            if await refresh(&credentials, environment: environment, home: home, load: load) {
                persist(credentials, to: cacheFile)
            } else if let cached = cachedCredentials(from: cacheFile), !cached.needsRefresh {
                credentials = cached
            } else {
                return .unavailable("Gemini sign-in expired. Run gemini once.")
            }
        }

        let token = credentials.accessToken
        guard !token.isEmpty else {
            return .unavailable("Gemini sign-in expired. Run gemini once.")
        }

        do {
            // The Code Assist companion project scopes quota to the account's
            // tier; without it the quota endpoint still answers, so a failed
            // loadCodeAssist degrades to an unscoped request.
            let assist = await loadCodeAssist(
                token: token,
                hostedDomain: jwtClaim("hd", in: credentials.idToken),
                load: load
            )

            var request = URLRequest(
                url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
            )
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = assist.projectID
                .map { Data(#"{"project":"\#($0)"}"#.utf8) } ?? Data("{}".utf8)

            let (data, http) = try await usageHTTP(request, load: load)
            if http.statusCode == 401 || http.statusCode == 403 {
                return .unavailable("Gemini sign-in expired. Run gemini once.")
            }
            guard http.statusCode == 200 else {
                return .unavailable("Provider usage request failed (HTTP \(http.statusCode)).")
            }

            var result = try parse(data)
            result.planName = assist.plan
            return result
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// `buckets[]` reports `remainingFraction` per model; Nano displays used,
    /// so each bucket inverts to (1 - fraction) x 100. Duplicates collapse to
    /// the lowest fraction, then the lowest Pro bucket is the primary window
    /// and the lowest Flash (and Flash Lite) follow - CodexBar's grouping.
    static func parse(_ data: Data) throws -> AgentUsageResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = root["buckets"] as? [[String: Any]]
        else { throw AgentUsageError.invalidResponse }

        var lowest: [String: (fraction: Double, reset: Date?)] = [:]
        for bucket in buckets {
            guard let model = bucket["modelId"] as? String,
                  let fraction = number(bucket["remainingFraction"])
            else { continue }
            let reset = (bucket["resetTime"] as? String).flatMap(parseISO8601)
            if let existing = lowest[model], existing.fraction <= fraction { continue }
            lowest[model] = (fraction, reset)
        }
        guard !lowest.isEmpty else { throw AgentUsageError.invalidResponse }

        func window(_ tier: String, id: String, match: (String) -> Bool) -> NanoUsageWindow? {
            lowest
                .filter { match($0.key.lowercased()) }
                .min { $0.value.fraction < $1.value.fraction }
                .map { _, entry in
                    NanoUsageWindow(
                        id: "gemini.\(id)",
                        label: "\(tier) · 24h",
                        usedPercent: min(100, max(0, (1 - entry.fraction) * 100)),
                        resetsAt: entry.reset,
                        resetAfterSeconds: entry.reset.map { Int($0.timeIntervalSinceNow) }
                    )
                }
        }

        let windows = [
            window("Pro", id: "pro") { $0.contains("pro") },
            window("Flash", id: "flash") { $0.contains("flash") && !$0.contains("flash-lite") },
            window("Flash Lite", id: "flashLite") { $0.contains("flash-lite") },
        ].compactMap { $0 }

        return AgentUsageResult(
            windows: windows,
            message: windows.isEmpty ? "No quota buckets reported." : nil,
            hasQuota: !windows.isEmpty
        )
    }

    private struct CodeAssist {
        var projectID: String?
        var plan: String?
    }

    private static func loadCodeAssist(
        token: String,
        hostedDomain: String?,
        load: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> CodeAssist {
        var request = URLRequest(
            url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)

        guard let (data, http) = try? await usageHTTP(request, load: load),
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return CodeAssist() }

        let project: String? = (json["cloudaicompanionProject"] as? String)
            ?? (json["cloudaicompanionProject"] as? [String: Any]).flatMap {
                ($0["id"] ?? $0["projectId"]) as? String
            }
        let tier = json["currentTier"] as? [String: Any]
        let paidName = ((json["paidTier"] as? [String: Any])?["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tierName = (tier?["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let plan = paidName.flatMap { $0.isEmpty ? nil : $0 }
            ?? tierName.flatMap { $0.isEmpty ? nil : $0 }
            ?? planName(tierID: tier?["id"] as? String, hostedDomain: hostedDomain)
        return CodeAssist(projectID: project, plan: plan)
    }

    /// Tier ids come from loadCodeAssist; a hosted domain marks a Workspace
    /// account even on the free tier (CodexBar's resolveAccountPlan).
    private static func planName(tierID: String?, hostedDomain: String?) -> String? {
        switch tierID {
        case "standard-tier": "Paid"
        case "free-tier": hostedDomain != nil ? "Workspace" : "Free"
        case "legacy-tier": "Legacy"
        default: nil
        }
    }

    static func fileCredentials(home: URL) -> Credentials? {
        let file = home.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return credentials(in: json)
    }

    private static func credentials(in json: [String: Any]) -> Credentials? {
        let access = (json["access_token"] as? String) ?? ""
        let refresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard !access.isEmpty || refresh != nil else { return nil }
        return Credentials(
            accessToken: access,
            refreshToken: refresh,
            expiryDate: number(json["expiry_date"]).map { Date(timeIntervalSince1970: $0 / 1000) },
            idToken: json["id_token"] as? String
        )
    }

    private static func cachedCredentials(from url: URL?) -> Credentials? {
        guard let url,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Credentials(
            accessToken: (json["accessToken"] as? String) ?? "",
            refreshToken: (json["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            expiryDate: number(json["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) },
            idToken: nil
        )
    }

    private static func defaultCacheURL() -> URL? {
        try? NanoStorage.directory("gemini-usage").appendingPathComponent("oauth-cache.json")
    }

    /// Nano-private cache only. Gemini CLI owns oauth_creds.json; writing it
    /// could rotate a grant out from under the CLI.
    private static func persist(_ credentials: Credentials, to url: URL?) {
        guard let url else { return }
        var object: [String: Any] = ["accessToken": credentials.accessToken]
        if let refreshToken = credentials.refreshToken {
            object["refreshToken"] = refreshToken
        }
        if let expiryDate = credentials.expiryDate {
            object["expiresAt"] = Int(expiryDate.timeIntervalSince1970 * 1000)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? NanoStorage.writePrivate(data, to: url)
    }

    private static func refresh(
        _ credentials: inout Credentials,
        environment: [String: String],
        home: URL,
        load: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> Bool {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty,
              let client = clientCredentials(environment: environment, home: home)
        else { return false }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = [
            ("client_id", client.id),
            ("client_secret", client.secret),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token"),
        ].map { key, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(escaped)"
        }.joined(separator: "&").data(using: .utf8)

        guard let (data, http) = try? await usageHTTP(request, load: load),
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty
        else { return false }

        credentials.accessToken = access
        if let rotated = json["refresh_token"] as? String, !rotated.isEmpty {
            credentials.refreshToken = rotated
        }
        if let expiresIn = number(json["expires_in"]), expiresIn > 0 {
            credentials.expiryDate = Date().addingTimeInterval(expiresIn)
        }
        if let idToken = json["id_token"] as? String {
            credentials.idToken = idToken
        }
        return true
    }

    /// The OAuth client pair lives in the installed CLI's oauth2.js - the same
    /// constants Gemini CLI itself ships. Order follows CodexBar's probe:
    /// environment override, explicit path, the resolved `gemini` binary's
    /// package, then the common global install roots.
    static func clientCredentials(environment: [String: String], home: URL) -> (id: String, secret: String)? {
        let envID = environment["GEMINI_OAUTH_CLIENT_ID"]?.trimmingCharacters(in: .whitespaces)
        let envSecret = environment["GEMINI_OAUTH_CLIENT_SECRET"]?.trimmingCharacters(in: .whitespaces)
        if let envID, let envSecret, !envID.isEmpty, !envSecret.isEmpty {
            return (envID, envSecret)
        }

        if let configured = environment["GEMINI_OAUTH2_JS_PATH"]?.trimmingCharacters(in: .whitespaces),
           !configured.isEmpty,
           let credentials = oauthCredentials(inFile: configured)
        {
            return credentials
        }

        if let credentials = credentialsFromInstalledCLI(environment: environment) {
            return credentials
        }
        return credentialsFromKnownInstallPaths(home: home)
    }

    private static func credentialsFromInstalledCLI(
        environment: [String: String]
    ) -> (id: String, secret: String)? {
        guard let geminiPath = resolveOnPath("gemini", in: environment["PATH"]) else { return nil }
        let resolved = URL(fileURLWithPath: geminiPath).resolvingSymlinksInPath().path

        let binDir = (resolved as NSString).deletingLastPathComponent
        let baseDir = (binDir as NSString).deletingLastPathComponent
        let oauthFile = "dist/src/code_assist/oauth2.js"
        let corePath = "node_modules/@google/gemini-cli-core/\(oauthFile)"
        for path in [
            "\(baseDir)/libexec/lib/node_modules/@google/gemini-cli/\(corePath)",
            "\(baseDir)/lib/node_modules/@google/gemini-cli/\(corePath)",
            "\(baseDir)/share/gemini-cli/\(corePath)",
            "\(baseDir)/../gemini-cli-core/\(oauthFile)",
            "\(baseDir)/\(corePath)",
        ] {
            if let credentials = oauthCredentials(inFile: path) { return credentials }
        }

        if let packageRoot = geminiPackageRoot(startingAt: resolved),
           let credentials = oauthCredentials(inPackage: packageRoot)
        {
            return credentials
        }
        return nil
    }

    private static func credentialsFromKnownInstallPaths(home: URL) -> (id: String, secret: String)? {
        let oauthFile = "dist/src/code_assist/oauth2.js"
        let nested =
            "node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/\(oauthFile)"
        for path in [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli-core/\(oauthFile)",
            "/opt/homebrew/lib/\(nested)",
            "/usr/local/lib/node_modules/@google/gemini-cli-core/\(oauthFile)",
            "/usr/local/lib/\(nested)",
            "\(home.path)/.npm-global/lib/node_modules/@google/gemini-cli-core/\(oauthFile)",
            "\(home.path)/.npm-global/lib/\(nested)",
        ] {
            if let credentials = oauthCredentials(inFile: path) { return credentials }
        }

        // Homebrew Cellar/opt libexec layouts keep the package root one level
        // deeper; fnm keeps one copy per installed Node version.
        var roots: [String] = []
        for prefix in ["/opt/homebrew", "/usr/local"] {
            roots.append("\(prefix)/opt/gemini-cli")
            if let versions = try? FileManager.default.contentsOfDirectory(
                atPath: "\(prefix)/Cellar/gemini-cli")
            {
                roots += versions.sorted().map { "\(prefix)/Cellar/gemini-cli/\($0)" }
            }
        }
        for fnmRoot in [
            "\(home.path)/.local/share/fnm/node-versions",
            "\(home.path)/Library/Application Support/fnm/node-versions",
        ] {
            if let versions = try? FileManager.default.contentsOfDirectory(atPath: fnmRoot) {
                roots += versions.sorted().map {
                    "\(fnmRoot)/\($0)/installation/lib/node_modules/@google/gemini-cli"
                }
            }
        }
        for root in roots {
            let packageRoot = root.hasSuffix("gemini-cli")
                ? root
                : "\(root)/libexec/lib/node_modules/@google/gemini-cli"
            if FileManager.default.fileExists(atPath: packageRoot),
               let credentials = oauthCredentials(inPackage: packageRoot)
            {
                return credentials
            }
        }
        return nil
    }

    /// Walk up from the resolved binary to the package whose package.json is
    /// `@google/gemini-cli`, checking the npm-global and Homebrew sublayouts on
    /// the way (CodexBar's findGeminiPackageRoot).
    private static func geminiPackageRoot(startingAt path: String) -> String? {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory)
            || !isDirectory.boolValue
        {
            current.deleteLastPathComponent()
        }

        for _ in 0...8 {
            for candidate in [
                current.path,
                "\(current.path)/lib/node_modules/@google/gemini-cli",
                "\(current.path)/libexec/lib/node_modules/@google/gemini-cli",
            ] {
                let packageJSON = "\(candidate)/package.json"
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: packageJSON)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["name"] as? String == "@google/gemini-cli"
                else { continue }
                return candidate
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }

    /// oauth2.js sits at dist/src/code_assist inside the package (or its
    /// gemini-cli-core dependency); bundle builds scatter it across bundle/*.js.
    private static func oauthCredentials(inPackage root: String) -> (id: String, secret: String)? {
        let oauthFile = "dist/src/code_assist/oauth2.js"
        for path in [
            "\(root)/\(oauthFile)",
            "\(root)/node_modules/@google/gemini-cli-core/\(oauthFile)",
        ] {
            if let credentials = oauthCredentials(inFile: path) { return credentials }
        }
        guard let bundle = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root).appendingPathComponent("bundle", isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return nil }
        for file in bundle where file.pathExtension == "js" {
            if let credentials = oauthCredentials(inFile: file.path) { return credentials }
        }
        return nil
    }

    static func oauthCredentials(inFile path: String) -> (id: String, secret: String)? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        func extract(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                      in: content, range: NSRange(content.startIndex..., in: content)),
                  let range = Range(match.range(at: 1), in: content)
            else { return nil }
            return String(content[range])
        }
        guard let id = extract(#"(?:const|let|var)?\s*OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]\s*;"#),
              let secret = extract(
                  #"(?:const|let|var)?\s*OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]\s*;"#)
        else { return nil }
        return (id, secret)
    }

    private static func resolveOnPath(_ executable: String, in path: String?) -> String? {
        guard let path else { return nil }
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(executable).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func jwtClaim(_ name: String, in token: String?) -> String? {
        guard let segments = token?.split(separator: "."), segments.count >= 2 else { return nil }
        var encoded = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return payload[name] as? String
    }

    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as NSNumber:
            CFGetTypeID(value) == CFBooleanGetTypeID() ? nil : value.doubleValue
        case let value as String:
            Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }
}

enum ClineUsageAdapter {
    /// The ClinePass subscription endpoint accepts the same credential the
    /// Cline CLI stores for its own `cline` provider - an API key or the
    /// account access token, sent raw as the Bearer the way Cline's own
    /// account service does.
    static func fetch() async throws -> AgentUsageResult {
        await fetch(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        ) { try await URLSession.shared.data(for: $0) }
    }

    static func fetch(
        environment: [String: String],
        home: URL,
        load: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> AgentUsageResult {
        guard let token = apiKey(environment: environment, home: home) else {
            return .unavailable("Sign in to Cline to see usage.")
        }

        var request = URLRequest(
            url: URL(string: "https://api.cline.bot/api/v1/users/me/plan/usage-limits")!
        )
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Nano", forHTTPHeaderField: "User-Agent")

        do {
            let (data, http) = try await usageHTTP(request, load: load)
            if http.statusCode == 401 || http.statusCode == 403 {
                return .unavailable("Cline sign-in expired. Run cline auth.")
            }
            guard http.statusCode == 200 else {
                return .unavailable("Provider usage request failed (HTTP \(http.statusCode)).")
            }
            return try parse(data)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// Mirrors the Cline SDK's own resolution order
    /// (sdk/packages/core/src/auth/provider-auth-registry.ts getApiKey):
    /// auth.accessToken first, then apiKey, then auth.apiKey under
    /// providers.cline.settings. Paths follow
    /// sdk/packages/shared/src/storage/paths.ts.
    static func apiKey(environment: [String: String], home: URL) -> String? {
        for key in ["CLINE_API_KEY", "CLINEPASS_API_KEY"] {
            if let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty
            {
                return value
            }
        }

        let dataDir: URL = environment["CLINE_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? environment["CLINE_DIR"]
                .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("data") }
            ?? home.appendingPathComponent(".cline/data", isDirectory: true)

        let providersFile = environment["CLINE_PROVIDER_SETTINGS_PATH"]
            .map { URL(fileURLWithPath: $0) }
            ?? dataDir.appendingPathComponent("settings/providers.json")
        if let data = try? Data(contentsOf: providersFile),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let providers = root["providers"] as? [String: Any],
           let cline = providers["cline"] as? [String: Any],
           let settings = cline["settings"] as? [String: Any]
        {
            let auth = settings["auth"] as? [String: Any]
            for candidate in [
                auth?["accessToken"] as? String,
                settings["apiKey"] as? String,
                auth?["apiKey"] as? String,
            ] {
                if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty
                {
                    return value
                }
            }
        }

        if let data = try? Data(contentsOf: dataDir.appendingPathComponent("secrets.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = (root["clineApiKey"] as? String)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty
        {
            return key
        }
        return nil
    }

    /// `data.limits[]` carries the five-hour, weekly, and monthly windows as
    /// percent-used; unknown window types are ignored rather than guessed.
    static func parse(_ data: Data) throws -> AgentUsageResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["success"] as? Bool) == true,
              let limits = (root["data"] as? [String: Any])?["limits"] as? [[String: Any]]
        else { throw AgentUsageError.invalidResponse }

        let windows = try limits.compactMap { limit -> NanoUsageWindow? in
            let type = ((limit["type"] as? String) ?? "").lowercased()
            let (id, seconds): (String, Int)
            switch type {
            case "five_hour": (id, seconds) = ("cline.fiveHour", 5 * 3_600)
            case "weekly": (id, seconds) = ("cline.weekly", 7 * 86_400)
            case "monthly": (id, seconds) = ("cline.monthly", 30 * 86_400)
            default: return nil
            }
            // A known window with a malformed percent invalidates the
            // response rather than silently disappearing.
            guard let percent = limit["percentUsed"] as? NSNumber,
                  CFGetTypeID(percent) != CFBooleanGetTypeID()
            else { throw AgentUsageError.invalidResponse }
            let reset = (limit["resetsAt"] as? String).flatMap(parseISO8601)
            return NanoUsageWindow(
                id: id,
                label: NanoUsageFormat.windowLabel(seconds: seconds),
                usedPercent: min(100, max(0, percent.doubleValue)),
                resetsAt: reset,
                resetAfterSeconds: reset.map { Int($0.timeIntervalSinceNow) }
            )
        }

        return AgentUsageResult(
            windows: windows,
            message: windows.isEmpty ? "No quota plan on this Cline account." : nil,
            hasQuota: !windows.isEmpty
        )
    }
}

enum OpenCodeUsageAdapter {
    /// OpenCode Go subscription quota, read with the `opencode-go` (or shared
    /// `opencode`) API key the CLI writes into its auth store. Other entries in
    /// auth.json are vendor keys, not OpenCode credentials.
    static func fetch() async throws -> AgentUsageResult {
        await fetch(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        ) { try await URLSession.shared.data(for: $0) }
    }

    static func fetch(
        environment: [String: String],
        home: URL,
        load: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> AgentUsageResult {
        guard let key = apiKey(environment: environment, home: home) else {
            return .unavailable("Sign in to OpenCode to see usage.")
        }

        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Nano", forHTTPHeaderField: "User-Agent")

        do {
            let (data, http) = try await usageHTTP(request, load: load)
            switch http.statusCode {
            case 200:
                break
            case 401:
                return .unavailable("OpenCode sign-in expired. Run opencode auth login.")
            case 403:
                // A valid key on an account without Go gets 403, not 401.
                return .unavailable("No OpenCode Go quota on this account.")
            default:
                return .unavailable("Provider usage request failed (HTTP \(http.statusCode)).")
            }
            return try parse(data)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func apiKey(environment: [String: String], home: URL) -> String? {
        if let key = environment["OPENCODE_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty
        {
            return key
        }
        let dataDir = environment["OPENCODE_DATA_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        guard let data = try? Data(contentsOf: dataDir.appendingPathComponent("auth.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        for name in ["opencode-go", "opencode"] {
            guard let entry = root[name] as? [String: Any],
                  let key = (entry["key"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty,
                  (entry["type"] as? String).map({ $0 == "api" }) ?? true
            else { continue }
            return key
        }
        return nil
    }

    /// `usage.{rolling,weekly,monthly}` report `percent` in whole points with
    /// ISO `resetsAt` (CodexBar's fetchAPIUsage mapping). A payload without a
    /// `usage` object means the account has no Go subscription - a valid
    /// no-quota state, not an error.
    static func parse(_ data: Data) throws -> AgentUsageResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AgentUsageError.invalidResponse }
        guard let usage = root["usage"] as? [String: Any] else {
            return AgentUsageResult(
                message: "No OpenCode Go subscription on this account.",
                planName: nil
            )
        }
        guard let rolling = usage["rolling"] as? [String: Any],
              let rollingWindow = window(rolling, id: "opencode.rolling", seconds: 5 * 3_600)
        else { throw AgentUsageError.invalidResponse }

        let windows = [
            rollingWindow,
            (usage["weekly"] as? [String: Any]).flatMap {
                window($0, id: "opencode.weekly", seconds: 7 * 86_400)
            },
            (usage["monthly"] as? [String: Any]).flatMap {
                window($0, id: "opencode.monthly", seconds: 30 * 86_400)
            },
        ].compactMap { $0 }

        return AgentUsageResult(
            windows: windows,
            hasQuota: true,
            planName: "OpenCode Go"
        )
    }

    private static func window(
        _ dict: [String: Any],
        id: String,
        seconds: Int
    ) -> NanoUsageWindow? {
        var percent = firstDouble(
            ["usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent",
             "used_percent", "utilization", "utilizationPercent", "utilization_percent"],
            in: dict)
        if percent == nil {
            let used = firstDouble(["used", "usage", "consumed", "count"], in: dict)
            let limit = firstDouble(["limit", "total", "quota", "max", "cap"], in: dict)
            if let used, let limit, limit > 0 { percent = used / limit * 100 }
        }
        guard let percent else { return nil }

        var resetsAt: Date?
        var resetSeconds: Int?
        if let within = firstInt(
            ["resetInSec", "resetInSeconds", "resetSeconds", "reset_sec", "reset_in_sec",
             "resetsInSec", "resetsInSeconds", "resetIn", "resetSec"],
            in: dict)
        {
            resetSeconds = max(0, within)
            resetsAt = Date().addingTimeInterval(TimeInterval(resetSeconds ?? 0))
        } else {
            for key in ["resetAt", "resetsAt", "reset_at", "resets_at",
                        "nextReset", "next_reset", "renewAt", "renew_at"] {
                if let date = dateValue(dict[key]) {
                    resetsAt = date
                    resetSeconds = max(0, Int(date.timeIntervalSinceNow))
                    break
                }
            }
        }

        return NanoUsageWindow(
            id: id,
            label: NanoUsageFormat.windowLabel(seconds: seconds),
            usedPercent: min(100, max(0, percent)),
            resetsAt: resetsAt,
            resetAfterSeconds: resetSeconds
        )
    }

    private static func firstDouble(_ keys: [String], in dict: [String: Any]) -> Double? {
        for key in keys {
            if let value = number(dict[key]), value.isFinite { return value }
        }
        return nil
    }

    private static func firstInt(_ keys: [String], in dict: [String: Any]) -> Int? {
        for key in keys {
            if let value = dict[key] {
                if let number = value as? NSNumber,
                   CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
                if let text = value as? String,
                   let number = Int(text.trimmingCharacters(in: .whitespaces)) { return number }
            }
        }
        return nil
    }

    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let value as NSNumber:
            CFGetTypeID(value) == CFBooleanGetTypeID() ? nil : value.doubleValue
        case let value as String:
            Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func dateValue(_ raw: Any?) -> Date? {
        if let text = raw as? String { return parseISO8601(text) }
        if let value = number(raw), value > 1_000_000_000 {
            let seconds = value > 1_000_000_000_000 ? value / 1000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
