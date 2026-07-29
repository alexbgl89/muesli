import Foundation

/// How Muesli obtains Salesforce credentials.
enum SalesforceAuthMode: String {
    /// Bring-your-own Connected App via the built-in OAuth PKCE flow.
    case app
    /// Zero-config: reuse a locally-installed, already-authenticated Salesforce CLI (`sf`).
    case cli
}

/// Abstraction over credential acquisition so `SalesforceClient` can work with
/// either the built-in OAuth flow or the Salesforce CLI without caring which.
@MainActor
protocol SalesforceTokenProviding: AnyObject {
    /// Best-effort, synchronous check of whether this provider can produce a token.
    var isConnected: Bool { get }
    /// The current access token and the org instance URL to target.
    func token() async throws -> (accessToken: String, instanceURL: String)
    /// Force a fresh access token (called after an HTTP 401).
    func refreshedToken() async throws -> (accessToken: String, instanceURL: String)
}

extension SalesforceAuthManager: SalesforceTokenProviding {
    var isConnected: Bool { isAuthenticated }

    func token() async throws -> (accessToken: String, instanceURL: String) {
        let value = try validAccessToken()
        return (value.token, value.instanceURL)
    }

    func refreshedToken() async throws -> (accessToken: String, instanceURL: String) {
        let value = try await forceRefresh()
        return (value.token, value.instanceURL)
    }
}
