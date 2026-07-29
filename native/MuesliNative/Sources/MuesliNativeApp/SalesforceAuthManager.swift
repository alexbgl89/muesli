import AppKit
import CryptoKit
import Foundation
import Network
import Security

enum SalesforceAuthError: Error, LocalizedError {
    case notAuthenticated
    case missingConsumerKey
    case callbackTimeout
    case callbackMissingCode
    case callbackStateMismatch
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case portInUse

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not connected to Salesforce"
        case .missingConsumerKey: return "Enter your Salesforce Connected App consumer key first"
        case .callbackTimeout: return "Sign-in timed out — no response from browser"
        case .callbackMissingCode: return "OAuth callback missing authorization code"
        case .callbackStateMismatch: return "OAuth state mismatch — possible CSRF attack"
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .refreshFailed(let msg): return "Token refresh failed: \(msg)"
        case .portInUse: return "Callback port 1457 is already in use"
        }
    }
}

/// OAuth 2.0 Authorization-Code-with-PKCE for Salesforce, mirroring
/// `ChatGPTAuthManager` / `GoogleCalendarAuthManager`.
///
/// Option B ("bring your own Connected App"): the consumer key (`client_id`) and
/// login host come from the user's `AppConfig`, so Muesli ships **no** bundled
/// credentials. The app is registered as a *public* PKCE client (no client
/// secret), which is why token exchange and refresh send `client_id` only.
///
/// Salesforce differs from the other providers in two ways handled here:
///  1. The token response carries an `instance_url` that every REST call must
///     target — it is stored alongside the tokens and returned by
///     `validAccessToken()`.
///  2. The token response has no `expires_in`, so we cannot pre-compute expiry.
///     Refresh is therefore reactive: the REST client calls `forceRefresh()` on
///     a 401 rather than checking a timestamp.
@MainActor
final class SalesforceAuthManager {
    static let shared = SalesforceAuthManager()

    private static let redirectURI = "http://localhost:1457/callback"
    private static let callbackPort: NWEndpoint.Port = 1457
    private static let scopes = "api refresh_token"
    private static let callbackTimeoutSeconds: TimeInterval = 300 // 5 minutes

    private var tokenFileURL: URL {
        AppIdentity.supportDirectoryURL.appendingPathComponent("salesforce-auth.json")
    }

    private init() {}

    // MARK: - Config-supplied client identity (Option B)

    /// The user's own Connected App consumer key. Read fresh from persisted
    /// config so a change in Settings takes effect without restart.
    private var consumerKey: String {
        ConfigStore().load().salesforceConsumerKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var loginHost: String {
        Self.normalizeHost(ConfigStore().load().salesforceLoginHost)
    }

    private var authURL: String { "https://\(loginHost)/services/oauth2/authorize" }
    private var tokenURL: String { "https://\(loginHost)/services/oauth2/token" }

    /// Strip scheme/path so config can hold `login.salesforce.com`,
    /// `test.salesforce.com`, or a full `https://x.my.salesforce.com/` My Domain URL.
    static func normalizeHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return "login.salesforce.com" }
        host = host.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        return host.isEmpty ? "login.salesforce.com" : host
    }

    // MARK: - Public API

    /// Whether a consumer key has been configured (feature can be connected).
    var isConfigured: Bool { !consumerKey.isEmpty }

    /// Whether the user has completed OAuth and has stored tokens.
    var isAuthenticated: Bool { tokenRead(key: "access_token") != nil }

    func signIn() async throws {
        let clientId = consumerKey
        guard !clientId.isEmpty else { throw SalesforceAuthError.missingConsumerKey }
        let (verifier, challenge) = generatePKCE()
        let code = try await startCallbackServerAndOpenBrowser(codeChallenge: challenge, clientId: clientId)
        let tokens = try await exchangeCodeForTokens(code: code, codeVerifier: verifier, clientId: clientId)
        saveTokens(tokens)
        fputs("[salesforce-auth] connected successfully\n", stderr)
    }

    func signOut() {
        deleteTokens()
        fputs("[salesforce-auth] disconnected\n", stderr)
    }

    /// The currently stored bearer token and the org instance host to call the
    /// REST API against. Does not refresh (Salesforce omits `expires_in`);
    /// callers refresh reactively via `forceRefresh()` on a 401.
    func validAccessToken() throws -> (token: String, instanceURL: String) {
        guard let accessToken = tokenRead(key: "access_token"),
              let instanceURL = tokenRead(key: "instance_url") else {
            throw SalesforceAuthError.notAuthenticated
        }
        return (accessToken, instanceURL)
    }

    /// Exchange the stored refresh token for a fresh access token. Persists any
    /// rotated refresh token and the (possibly updated) instance URL.
    @discardableResult
    func forceRefresh() async throws -> (token: String, instanceURL: String) {
        guard let refreshToken = tokenRead(key: "refresh_token") else {
            throw SalesforceAuthError.notAuthenticated
        }
        fputs("[salesforce-auth] refreshing access token...\n", stderr)
        let tokens = try await refreshAccessToken(refreshToken: refreshToken, clientId: consumerKey)
        saveTokens(tokens)
        return (tokens.accessToken, tokens.instanceURL)
    }

    // MARK: - PKCE (reuses Data.base64URLEncoded() from ChatGPTAuthManager)

    private func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded()
        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = challengeData.base64URLEncoded()
        return (verifier, challenge)
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    // MARK: - OAuth Flow

    private func buildAuthorizationURL(codeChallenge: String, state: String, clientId: String) -> URL? {
        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url
    }

    private func startCallbackServerAndOpenBrowser(codeChallenge: String, clientId: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: Self.callbackPort)

            guard let listener = try? NWListener(using: params) else {
                continuation.resume(throwing: SalesforceAuthError.portInUse)
                return
            }
            // The timeout, the listener state handler, and the receive handler can
            // all fire concurrently; only one of them may resume.
            let gate = OneShotGate()

            let timeoutWork = DispatchWorkItem { [weak listener] in
                guard gate.claim() else { return }
                listener?.cancel()
                continuation.resume(throwing: SalesforceAuthError.callbackTimeout)
            }
            let timeout = UncheckedSendable(timeoutWork)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.callbackTimeoutSeconds,
                execute: timeoutWork
            )

            let expectedState = self.generateState()
            let authURL = self.buildAuthorizationURL(
                codeChallenge: codeChallenge,
                state: expectedState,
                clientId: clientId
            )

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let authURL {
                        DispatchQueue.main.async { NSWorkspace.shared.open(authURL) }
                    }
                case .failed:
                    guard gate.claim() else { return }
                    timeout.value.cancel()
                    continuation.resume(throwing: SalesforceAuthError.portInUse)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    defer {
                        listener.cancel()
                        timeout.value.cancel()
                    }
                    guard gate.claim() else { return }

                    guard let data, let request = String(data: data, encoding: .utf8) else {
                        continuation.resume(throwing: SalesforceAuthError.callbackMissingCode)
                        return
                    }

                    let code = self.extractParam(named: "code", from: request)
                    let callbackState = self.extractParam(named: "state", from: request)

                    guard callbackState == expectedState else {
                        fputs("[salesforce-auth] OAuth state mismatch — possible CSRF\n", stderr)
                        let errorHtml = """
                        HTTP/1.1 400 Bad Request\r
                        Content-Type: text/html\r
                        Connection: close\r
                        \r
                        <!DOCTYPE html><html><body style="font-family:-apple-system,system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a1a;color:#fff"><div style="text-align:center"><h2>Sign-in failed</h2><p>Security validation failed. Please try again.</p></div></body></html>
                        """
                        connection.send(
                            content: errorHtml.data(using: .utf8),
                            completion: .contentProcessed { _ in connection.cancel() }
                        )
                        continuation.resume(throwing: SalesforceAuthError.callbackStateMismatch)
                        return
                    }

                    if let code {
                        let successHtml = """
                        HTTP/1.1 200 OK\r
                        Content-Type: text/html\r
                        Connection: close\r
                        \r
                        <!DOCTYPE html><html><body style="font-family:-apple-system,system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a1a;color:#fff"><div style="text-align:center"><h2>Salesforce connected</h2><p>You can close this window and return to Muesli.</p></div></body></html>
                        """
                        connection.send(
                            content: successHtml.data(using: .utf8),
                            completion: .contentProcessed { _ in connection.cancel() }
                        )
                        continuation.resume(returning: code)
                    } else {
                        let deniedHtml = """
                        HTTP/1.1 400 Bad Request\r
                        Content-Type: text/html\r
                        Connection: close\r
                        \r
                        <!DOCTYPE html><html><body style="font-family:-apple-system,system-ui;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a1a;color:#fff"><div style="text-align:center"><h2>Sign-in failed</h2><p>Access was denied or no authorization code received.</p></div></body></html>
                        """
                        connection.send(
                            content: deniedHtml.data(using: .utf8),
                            completion: .contentProcessed { _ in connection.cancel() }
                        )
                        continuation.resume(throwing: SalesforceAuthError.callbackMissingCode)
                    }
                }
            }

            listener.start(queue: .main)
        }
    }

    /// Pure string parsing with no actor state, called from the listener's
    /// receive handler, so it is deliberately not main-actor isolated.
    private nonisolated func extractParam(named name: String, from httpRequest: String) -> String? {
        guard let pathLine = httpRequest.split(separator: "\r\n").first ?? httpRequest.split(separator: "\n").first,
              let pathPart = pathLine.split(separator: " ").dropFirst().first else {
            return nil
        }
        guard let components = URLComponents(string: String(pathPart)) else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }

    // MARK: - Token Exchange

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String
        let instanceURL: String
    }

    private func exchangeCodeForTokens(code: String, codeVerifier: String, clientId: String) async throws -> TokenResponse {
        // Public PKCE client: no client_secret.
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": codeVerifier,
        ]

        let (data, response) = try await postForm(to: tokenURL, body: body)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SalesforceAuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "unknown error")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let instanceURL = json["instance_url"] as? String else {
            throw SalesforceAuthError.tokenExchangeFailed("missing access_token or instance_url in response")
        }

        guard let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw SalesforceAuthError.tokenExchangeFailed(
                "No refresh token received. Ensure the Connected App grants the 'refresh_token' scope."
            )
        }

        return TokenResponse(accessToken: accessToken, refreshToken: refreshToken, instanceURL: instanceURL)
    }

    private func refreshAccessToken(refreshToken: String, clientId: String) async throws -> TokenResponse {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken,
        ]

        let (data, response) = try await postForm(to: tokenURL, body: body)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown error"
            if let httpResponse = response as? HTTPURLResponse,
               (httpResponse.statusCode == 400 || httpResponse.statusCode == 401),
               errorBody.contains("invalid_grant") {
                throw SalesforceAuthError.notAuthenticated
            }
            throw SalesforceAuthError.refreshFailed(errorBody)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw SalesforceAuthError.refreshFailed("missing access_token in refresh response")
        }

        // Refresh may omit refresh_token (unless rotation is enabled) and instance_url.
        let newRefreshToken = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? refreshToken
        let instanceURL = json["instance_url"] as? String
            ?? tokenRead(key: "instance_url")
            ?? ""

        return TokenResponse(accessToken: accessToken, refreshToken: newRefreshToken, instanceURL: instanceURL)
    }

    private func postForm(to urlString: String, body: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        return try await URLSession.shared.data(for: request)
    }

    // MARK: - File-based Token Storage

    private func saveTokens(_ tokens: TokenResponse) {
        let dict: [String: String] = [
            "access_token": tokens.accessToken,
            "refresh_token": tokens.refreshToken,
            "instance_url": tokens.instanceURL,
        ]
        do {
            let dir = tokenFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
            try data.write(to: tokenFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
            var fileURL = tokenFileURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try fileURL.setResourceValues(resourceValues)
        } catch {
            fputs("[salesforce-auth] failed to save tokens: \(error)\n", stderr)
        }
    }

    private func tokenRead(key: String) -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return dict[key]
    }

    private func deleteTokens() {
        try? FileManager.default.removeItem(at: tokenFileURL)
    }
}
