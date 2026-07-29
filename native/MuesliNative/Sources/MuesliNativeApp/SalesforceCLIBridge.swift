import Foundation

enum SalesforceCLIError: Error, LocalizedError {
    case notInstalled
    case noToken
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Salesforce CLI (sf) not found. Install it or use the Connected App method."
        case .noToken:
            return "Couldn't read an access token from the Salesforce CLI. Run `sf org login web` first."
        case .commandFailed(let message):
            return "Salesforce CLI error: \(message)"
        }
    }
}

/// Zero-config credential provider: reuses a locally-installed, already
/// authenticated Salesforce CLI (`sf`). Muesli bundles no credentials and
/// registers no Connected App — it borrows the user's existing CLI session
/// (which itself uses Salesforce's own "Salesforce CLI" Connected App).
///
/// `token()` reads the current access token + instance URL from
/// `sf org display`. `refreshedToken()` forces the CLI to refresh and persist a
/// new token (via a cheap authenticated query) before re-reading it.
@MainActor
final class SalesforceCLIBridge: SalesforceTokenProviding {
    static let shared = SalesforceCLIBridge()

    private init() {}

    struct CLIOrg: Identifiable, Equatable, Sendable {
        let username: String
        let alias: String?
        let isConnected: Bool
        var id: String { username }
        var display: String { alias.map { "\($0) (\(username))" } ?? username }
    }

    /// Common install locations. GUI apps launched from Finder get a minimal
    /// PATH, so `which sf` is unreliable — probe known dirs instead.
    static let cliPath: String? = {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/sf",
            "/usr/local/bin/sf",
            "\(home)/.local/bin/sf",
            "/opt/homebrew/bin/sfdx",
            "/usr/local/bin/sfdx",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isAvailable: Bool { cliPath != nil }

    /// Connected only when the CLI exists and an org has been selected.
    var isConnected: Bool {
        Self.cliPath != nil && !ConfigStore().load().salesforceCLIOrg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedOrg: String {
        ConfigStore().load().salesforceCLIOrg.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// In-memory cache so we don't spawn `sf org display` (a ~1–2s Node process)
    /// on every request. Salesforce access tokens live ~2h; a short TTL keeps
    /// us well inside that, and a 401 forces `refreshedToken()` anyway.
    private var cachedToken: (org: String, accessToken: String, instanceURL: String, fetchedAt: Date)?
    private static let cacheTTL: TimeInterval = 25 * 60

    // MARK: - SalesforceTokenProviding

    func token() async throws -> (accessToken: String, instanceURL: String) {
        let org = selectedOrg
        if let cached = cachedToken,
           cached.org == org,
           Date().timeIntervalSince(cached.fetchedAt) < Self.cacheTTL {
            return (cached.accessToken, cached.instanceURL)
        }
        let fresh = try await fetchToken(org: org)
        cachedToken = (org, fresh.accessToken, fresh.instanceURL, Date())
        return fresh
    }

    func refreshedToken() async throws -> (accessToken: String, instanceURL: String) {
        cachedToken = nil
        let org = selectedOrg
        // Force the CLI to refresh + persist a fresh access token by making a
        // cheap authenticated request; the CLI transparently refreshes on 401.
        var refreshArgs = ["data", "query", "--query", "SELECT Id FROM Organization LIMIT 1", "--json"]
        if !org.isEmpty { refreshArgs += ["--target-org", org] }
        _ = try? await run(refreshArgs)
        let fresh = try await fetchToken(org: org)
        cachedToken = (org, fresh.accessToken, fresh.instanceURL, Date())
        return fresh
    }

    private func fetchToken(org: String) async throws -> (accessToken: String, instanceURL: String) {
        var args = ["org", "display", "--json"]
        if !org.isEmpty { args += ["--target-org", org] }
        let data = try await run(args)
        guard let result = try Self.resultObject(data),
              let accessToken = result["accessToken"] as? String,
              let instanceURL = result["instanceUrl"] as? String,
              !accessToken.isEmpty else {
            throw SalesforceCLIError.noToken
        }
        return (accessToken, instanceURL)
    }

    // MARK: - Org discovery

    func listOrgs() async -> [CLIOrg] {
        guard let data = try? await run(["org", "list", "--json"]),
              let result = try? Self.resultObject(data),
              let nonScratch = result["nonScratchOrgs"] as? [[String: Any]] else {
            return []
        }
        return nonScratch.compactMap { entry in
            guard let username = entry["username"] as? String else { return nil }
            return CLIOrg(
                username: username,
                alias: entry["alias"] as? String,
                isConnected: (entry["connectedStatus"] as? String) == "Connected"
            )
        }
    }

    // MARK: - Process execution

    private static func resultObject(_ data: Data) throws -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["result"] as? [String: Any]
    }

    private func run(_ arguments: [String]) async throws -> Data {
        guard let launchPath = Self.cliPath else { throw SalesforceCLIError.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: outData)
                    } else {
                        // `sf --json` usually reports errors on stdout; fall back to stderr.
                        let message = Self.errorMessage(stdout: outData, stderr: errData)
                        continuation.resume(throwing: SalesforceCLIError.commandFailed(message))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func errorMessage(stdout: Data, stderr: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
           let message = json["message"] as? String {
            return message
        }
        let err = String(data: stderr, encoding: .utf8) ?? ""
        if !err.isEmpty { return err.trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(data: stdout, encoding: .utf8)?.prefix(300).description ?? "sf command failed"
    }
}
