import AppKit
import CryptoKit
import Foundation

/// What Nano keeps after signing in to an MCP server, stored as JSON in the
/// Keychain in place of a pasted token.
struct MCPCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var clientID: String
    var tokenEndpoint: URL
    var resource: String

    var isExpired: Bool { expiresAt.map { $0 <= Date().addingTimeInterval(30) } ?? false }

    func encoded() -> String? {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Nil for a plain pasted token.
    static func decode(_ stored: String) -> MCPCredentials? {
        try? JSONDecoder().decode(MCPCredentials.self, from: Data(stored.utf8))
    }
}

/// MCP's standard sign-in: protected resource metadata, authorization server
/// metadata, dynamic client registration, then authorization code with PKCE
/// in the browser, returning to `nano://cue/oauth`.
@MainActor
enum MCPOAuth {
    static let redirectURI = "nano://cue/oauth"

    enum Failure: LocalizedError {
        case notSupported
        case registration(String)
        case denied(String)
        case stateMismatch
        case timedOut
        case token(String)

        var errorDescription: String? {
            switch self {
            case .notSupported: "The server asked for sign-in but doesn't describe how."
            case let .registration(message): "The server didn't register Nano: \(message)"
            case let .denied(message): "Sign-in didn't finish: \(message)"
            case .stateMismatch: "The sign-in reply didn't match the request, so Nano ignored it."
            case .timedOut: "Sign-in took too long. Try connecting again."
            case let .token(message): "The server didn't issue a token: \(message)"
            }
        }
    }

    struct ServerMetadata {
        var authorizationEndpoint: URL
        var tokenEndpoint: URL
        var registrationEndpoint: URL?
        var scopes: [String]
    }

    /// Nil when the server describes no sign-in.
    static func discover(_ mcpURL: URL, session: URLSession = .shared) async throws -> ServerMetadata? {
        guard var origin = URLComponents(url: mcpURL, resolvingAgainstBaseURL: false) else { return nil }
        origin.path = ""
        origin.query = nil
        guard let base = origin.url else { return nil }

        let path = mcpURL.path
        var resourceMetadata: [String: Any]?
        for suffix in [path.isEmpty || path == "/" ? "" : path, ""] {
            let url = base.appendingPathComponent(".well-known/oauth-protected-resource" + suffix)
            if let object = try await json(from: url, session: session) {
                resourceMetadata = object
                break
            }
        }
        let issuer = (resourceMetadata?["authorization_servers"] as? [String])?.first.flatMap(URL.init(string:)) ?? base
        var server: [String: Any]?
        for name in ["oauth-authorization-server", "openid-configuration"] {
            if let object = try await json(from: issuer.appendingPathComponent(".well-known/\(name)"), session: session) {
                server = object
                break
            }
        }
        guard let server,
              let authorize = (server["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (server["token_endpoint"] as? String).flatMap(URL.init(string:)) else { return nil }
        return ServerMetadata(
            authorizationEndpoint: authorize,
            tokenEndpoint: token,
            registrationEndpoint: (server["registration_endpoint"] as? String).flatMap(URL.init(string:)),
            scopes: (resourceMetadata?["scopes_supported"] as? [String]) ?? (server["scopes_supported"] as? [String]) ?? []
        )
    }

    /// Registers Nano, opens the browser, and waits for `nano://cue/oauth`.
    /// `open` is the browser; tests pass their own.
    static func signIn(
        to mcpURL: URL,
        session: URLSession = .shared,
        open: (URL) -> Void = { NSWorkspace.shared.open($0) },
        timeout: Duration = .seconds(300)
    ) async throws -> MCPCredentials {
        guard let metadata = try await discover(mcpURL, session: session) else { throw Failure.notSupported }
        guard let registration = metadata.registrationEndpoint else { throw Failure.registration("it doesn't accept new apps") }

        let registered = try await post(registration, json: [
            "client_name": "Nano",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ], session: session)
        guard let clientID = registered["client_id"] as? String else {
            throw Failure.registration(registered["error_description"] as? String ?? "no client ID")
        }

        let verifier = randomString(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = randomString(24)
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []
        query += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: mcpURL.absoluteString),
        ]
        if !metadata.scopes.isEmpty { query.append(URLQueryItem(name: "scope", value: metadata.scopes.joined(separator: " "))) }
        components.queryItems = query

        let callback = try await MCPOAuthCallbacks.shared.wait(for: state, timeout: timeout) {
            open(components.url!)
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw Failure.denied(items.first { $0.name == "error_description" }?.value ?? error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw Failure.denied("no code") }

        let token = try await post(metadata.tokenEndpoint, form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
            "resource": mcpURL.absoluteString,
        ], session: session)
        return try credentials(from: token, clientID: clientID, tokenEndpoint: metadata.tokenEndpoint, resource: mcpURL.absoluteString)
    }

    static func refresh(_ old: MCPCredentials, session: URLSession = .shared) async throws -> MCPCredentials {
        guard let refreshToken = old.refreshToken else { throw MCPError.unauthorized }
        let token = try await post(old.tokenEndpoint, form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": old.clientID,
            "resource": old.resource,
        ], session: session)
        var fresh = try credentials(from: token, clientID: old.clientID, tokenEndpoint: old.tokenEndpoint, resource: old.resource)
        if fresh.refreshToken == nil { fresh.refreshToken = refreshToken }
        return fresh
    }

    // MARK: Helpers

    private static func credentials(from token: [String: Any], clientID: String, tokenEndpoint: URL, resource: String) throws -> MCPCredentials {
        guard let access = token["access_token"] as? String else {
            throw Failure.token(token["error_description"] as? String ?? token["error"] as? String ?? "no access token")
        }
        return MCPCredentials(
            accessToken: access,
            refreshToken: token["refresh_token"] as? String,
            expiresAt: (token["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) },
            clientID: clientID,
            tokenEndpoint: tokenEndpoint,
            resource: resource
        )
    }

    private static func json(from url: URL, session: URLSession) async throws -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func post(_ url: URL, json body: [String: Any], session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func post(_ url: URL, form: [String: String], session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let status = (response as? HTTPURLResponse)?.statusCode, status == 400 || status == 401, form["grant_type"] == "refresh_token" {
            throw MCPError.unauthorized
        }
        return object
    }

    private static func randomString(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded()
    }
}

/// Sign-ins waiting for their `nano://cue/oauth` reply, by `state`. Any web
/// page can open a `nano://` link, so a reply is used only if its `state`
/// matches a sign-in Nano started.
@MainActor
final class MCPOAuthCallbacks {
    static let shared = MCPOAuthCallbacks()
    private var waiting: [String: CheckedContinuation<URL, Error>] = [:]

    func wait(for state: String, timeout: Duration, start: () -> Void) async throws -> URL {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(state, with: .failure(MCPOAuth.Failure.timedOut))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[state] = continuation
            start()
        }
    }

    /// True if the link belonged to a sign-in in progress.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let state = items.first(where: { $0.name == "state" })?.value, waiting[state] != nil else { return false }
        finish(state, with: .success(url))
        return true
    }

    private func finish(_ state: String, with result: Result<URL, Error>) {
        waiting.removeValue(forKey: state)?.resume(with: result)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
