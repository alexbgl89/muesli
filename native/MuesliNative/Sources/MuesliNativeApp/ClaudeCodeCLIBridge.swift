import Foundation
import os

enum ClaudeCodeCLIError: Error, LocalizedError, Equatable {
    case notInstalled
    case invalidBinaryPath(String)
    case notSignedIn
    case launchFailed(String)
    case timedOut(seconds: Int)
    case apiError(status: Int?, message: String)
    case commandFailed(exitCode: Int32, message: String)
    case emptyResult
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude Code isn't installed. Install it from claude.com/product/claude-code, then re-check in Settings."
        case .invalidBinaryPath(let message):
            return message
        case .notSignedIn:
            return "Claude Code isn't signed in. Use Sign In to Claude Code in Settings to connect your Claude account."
        case .launchFailed(let message):
            return "Could not start Claude Code: \(message)"
        case .timedOut(let seconds):
            return "Claude Code did not finish within \(seconds)s."
        case let .apiError(status, message):
            let statusText = status.map { " (status \($0))" } ?? ""
            return "Claude Code reported an error\(statusText): \(message)"
        case let .commandFailed(exitCode, message):
            return "Claude Code exited with code \(exitCode): \(message)"
        case .emptyResult:
            return "Claude Code returned an empty response."
        case .invalidOutput(let message):
            return "Could not read Claude Code's output: \(message)"
        }
    }
}

/// Result of probing the local install. Drives the Settings status row and the
/// readiness gates that decide whether the Summarize button is enabled.
struct ClaudeCodeAvailability: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case missing
        case notSignedIn
        case ready
    }

    let state: State
    let binaryPath: String?
    let accountEmail: String?
    let organizationName: String?
    let subscriptionType: String?
    /// "claude.ai" for a subscription, "apiKey" for console billing.
    let authMethod: String?
    /// Set when discovery failed for a reason worth showing (bad override path).
    let problem: String?

    var isReady: Bool { state == .ready }
    var isInstalled: Bool { state != .missing }

    static let missing = ClaudeCodeAvailability(
        state: .missing,
        binaryPath: nil,
        accountEmail: nil,
        organizationName: nil,
        subscriptionType: nil,
        authMethod: nil,
        problem: nil
    )
}

protocol ClaudeCodeSummarizing: Sendable {
    func complete(
        instructions: String,
        userPrompt: String,
        model: String,
        timeout: TimeInterval,
        config: AppConfig
    ) async throws -> String

    func availability(config: AppConfig, forceRefresh: Bool) async -> ClaudeCodeAvailability
}

/// Runs the locally installed `claude` CLI in headless print mode so meeting
/// summaries and transcript cleanup can use the user's own Claude subscription
/// without an API key.
///
/// Everything the child is allowed to do is deliberately minimal: no tools, no
/// user settings, no MCP servers, no session files. A meeting transcript is
/// attacker-controlled text — anyone on the call can say "ignore previous
/// instructions" — so the capability is removed rather than the attack detected.
actor ClaudeCodeCLIBridge: ClaudeCodeSummarizing {
    static let shared = ClaudeCodeCLIBridge()

    /// Single source of truth for the label used in errors, the backend picker,
    /// and `MeetingSummaryRetryPolicy.isLocalBackend`.
    static let displayLabel = "Claude Code"
    static let defaultModel = "sonnet"
    static let defaultTimeoutSeconds = 300
    static let minimumTimeoutSeconds = 30
    static let maximumTimeoutSeconds = 900

    private static let logger = Logger(subsystem: "com.muesli.native", category: "ClaudeCode")
    private static let availabilityTTL: TimeInterval = 60

    private let runner: LocalCLIRunning
    private let locator: ClaudeCodeBinaryLocating
    private var cachedAvailability: (value: ClaudeCodeAvailability, override: String, fetchedAt: Date)?

    init(
        runner: LocalCLIRunning = LocalCLIProcessRunner(),
        locator: ClaudeCodeBinaryLocating = ClaudeCodeBinaryLocator()
    ) {
        self.runner = runner
        self.locator = locator
    }

    // MARK: - Availability

    /// Filesystem-only check, cheap enough to call from a SwiftUI body.
    nonisolated func isInstalled(config: AppConfig) -> Bool {
        if case .success = locator.locate(override: config.claudeCodePath) { return true }
        return false
    }

    nonisolated func binaryPath(config: AppConfig) -> String? {
        guard case .success(let url) = locator.locate(override: config.claudeCodePath) else { return nil }
        return url.path
    }

    func invalidateAvailability() {
        cachedAvailability = nil
    }

    /// Probes install + sign-in state. `claude auth status --json` is local and
    /// takes ~250ms, so this never touches the network or burns model tokens.
    func availability(config: AppConfig, forceRefresh: Bool = false) async -> ClaudeCodeAvailability {
        let override = config.claudeCodePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !forceRefresh,
           let cached = cachedAvailability,
           cached.override == override,
           Date().timeIntervalSince(cached.fetchedAt) < Self.availabilityTTL {
            return cached.value
        }

        let executable: URL
        switch locator.locate(override: config.claudeCodePath) {
        case .success(let url):
            executable = url
        case .failure(let error):
            let value: ClaudeCodeAvailability
            if case .invalidBinaryPath(let message) = error {
                value = ClaudeCodeAvailability(
                    state: .missing,
                    binaryPath: nil,
                    accountEmail: nil,
                    organizationName: nil,
                    subscriptionType: nil,
                    authMethod: nil,
                    problem: message
                )
            } else {
                value = .missing
            }
            cachedAvailability = (value, override, Date())
            return value
        }

        var value = ClaudeCodeAvailability(
            state: .notSignedIn,
            binaryPath: executable.path,
            accountEmail: nil,
            organizationName: nil,
            subscriptionType: nil,
            authMethod: nil,
            problem: nil
        )
        do {
            let result = try await runner.run(LocalCLIInvocation(
                executable: executable,
                arguments: ["auth", "status", "--json"],
                environment: Self.childEnvironment(parentEnvironment: ProcessInfo.processInfo.environment),
                workingDirectory: Self.workingDirectory(),
                timeout: 20,
                maxStandardOutputBytes: 64 * 1024
            ))
            value = Self.parseAuthStatus(result.standardOutput, binaryPath: executable.path)
        } catch {
            Self.logger.error("auth status probe failed: \(error.localizedDescription, privacy: .public)")
        }

        cachedAvailability = (value, override, Date())
        return value
    }

    /// Decodes `claude auth status --json`, which exits 0 whether or not the
    /// user is signed in.
    static func parseAuthStatus(_ data: Data, binaryPath: String) -> ClaudeCodeAvailability {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ClaudeCodeAvailability(
                state: .notSignedIn,
                binaryPath: binaryPath,
                accountEmail: nil,
                organizationName: nil,
                subscriptionType: nil,
                authMethod: nil,
                problem: nil
            )
        }
        let loggedIn = (json["loggedIn"] as? Bool) ?? false
        return ClaudeCodeAvailability(
            state: loggedIn ? .ready : .notSignedIn,
            binaryPath: binaryPath,
            accountEmail: json["email"] as? String,
            organizationName: json["orgName"] as? String,
            subscriptionType: json["subscriptionType"] as? String,
            authMethod: json["authMethod"] as? String,
            problem: nil
        )
    }

    // MARK: - Completion

    func complete(
        instructions: String,
        userPrompt: String,
        model: String,
        timeout: TimeInterval,
        config: AppConfig
    ) async throws -> String {
        let executable: URL
        switch locator.locate(override: config.claudeCodePath) {
        case .success(let url):
            executable = url
        case .failure(let error):
            throw error
        }

        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = Self.completionArguments(
            model: resolvedModel.isEmpty ? Self.defaultModel : resolvedModel,
            systemPrompt: instructions
        )

        let result: LocalCLIResult
        do {
            result = try await runner.run(LocalCLIInvocation(
                executable: executable,
                // The prompt carries the transcript, so it goes on stdin: argv is
                // world-readable via `ps` and is capped by ARG_MAX.
                arguments: arguments,
                standardInput: Data(userPrompt.utf8),
                environment: Self.childEnvironment(parentEnvironment: ProcessInfo.processInfo.environment),
                workingDirectory: Self.workingDirectory(),
                timeout: timeout
            ))
        } catch let error as LocalCLIRunnerError {
            // CancellationError is deliberately not translated — it propagates
            // untouched so callers can distinguish it from a backend failure.
            throw ClaudeCodeCLIError.launchFailed(error.localizedDescription)
        }

        do {
            return try Self.parseEnvelope(
                standardOutput: result.standardOutput,
                standardError: result.standardError,
                exitCode: result.exitCode,
                timedOut: result.timedOut,
                timeout: timeout
            )
        } catch let error as ClaudeCodeCLIError {
            if case .notSignedIn = error {
                // A sign-in that lapsed mid-session must not keep serving a
                // stale "ready" status to the UI.
                cachedAvailability = nil
            }
            throw error
        }
    }

    // MARK: - Argument vector

    /// Argument vector for a single headless completion.
    ///
    /// `--tools ""` is the load-bearing flag: with no tool schemas in context
    /// there is nothing for injected transcript text to call. It is variadic and
    /// greedily consumes following non-flag arguments, so it is always emitted
    /// immediately before another `--flag`, and no positional prompt is ever
    /// passed.
    static func completionArguments(
        model: String,
        systemPrompt: String,
        fallbackModel: String? = nil
    ) -> [String] {
        var arguments = [
            "-p",
            "--output-format", "json",
            "--model", model,
            // Replaces Claude Code's coding-agent system prompt outright.
            "--system-prompt", systemPrompt,
            // Disables CLAUDE.md, skills, plugins, hooks, MCP, custom agents —
            // while keeping OAuth auth and model selection working.
            "--safe-mode",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            // No tools exist to permit, but this guarantees the child can never
            // block on a prompt with no TTY and hang until our timeout.
            "--permission-mode", "dontAsk",
            // Keeps transcripts out of ~/.claude session files, which sit
            // outside Muesli's retention and delete-meeting flow.
            "--no-session-persistence",
        ]
        if let fallbackModel, !fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments += ["--fallback-model", fallbackModel]
        }
        arguments += ["--tools", ""]
        return arguments
    }

    // MARK: - Environment

    /// Full replacement environment for the child.
    ///
    /// Inherited provider credentials are stripped rather than forwarded: an
    /// `ANTHROPIC_API_KEY` in the GUI app's launchd environment would silently
    /// bill API credits instead of using the subscription, and a stray
    /// `CLAUDE_CONFIG_DIR` makes a signed-in user look signed out.
    static func childEnvironment(
        parentEnvironment: [String: String],
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName()
    ) -> [String: String] {
        var environment: [String: String] = [
            // HOME and USER are both required to reach the stored credentials:
            // verified that `HOME`+`PATH` alone reports loggedIn=false, and adding
            // `USER` alone flips it to true. They are set explicitly rather than
            // forwarded, because a launchd-spawned GUI app is not guaranteed to
            // have them and the failure mode is a confusing "not signed in".
            "HOME": homeDirectory,
            "USER": userName,
            "LOGNAME": userName,
            "LANG": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            // Without these two, a background non-essential model call receives
            // the prompt: a probe showed claude-haiku-4-5 taking more input
            // tokens than the primary model. For a meeting transcript that is an
            // unacceptable extra recipient, so these are required, not tuning.
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_NON_ESSENTIAL_MODEL_CALLS": "1",
            // Keeps prompt fragments out of analytics and crash payloads.
            "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1",
            // A self-update firing mid-summary is a silent stall or a mid-flight
            // binary swap.
            "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_ENTRYPOINT": "muesli",
        ]
        for key in ["SHELL", "TMPDIR"] {
            if let value = parentEnvironment[key] {
                environment[key] = value
            }
        }
        return environment
    }

    /// Dedicated empty, non-git directory. `--safe-mode` already disables
    /// CLAUDE.md discovery, but an empty cwd makes the isolation structural
    /// instead of flag-dependent.
    static func workingDirectory() -> URL {
        let directory = AppIdentity.supportDirectoryURL.appendingPathComponent("claude-code-cwd", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return FileManager.default.temporaryDirectory
        }
        return directory
    }

    // MARK: - Envelope parsing

    /// Maps a finished run onto the error taxonomy.
    ///
    /// `subtype` stays `"success"` even on failure, so `is_error` is the only
    /// reliable signal. Branching on `subtype` silently swallows every error.
    static func parseEnvelope(
        standardOutput: Data,
        standardError: Data,
        exitCode: Int32,
        timedOut: Bool,
        timeout: TimeInterval
    ) throws -> String {
        if timedOut {
            throw ClaudeCodeCLIError.timedOut(seconds: max(Int(timeout.rounded()), 1))
        }

        guard let json = try? JSONSerialization.jsonObject(with: standardOutput) as? [String: Any] else {
            let detail = diagnosticText(standardOutput: standardOutput, standardError: standardError)
            if exitCode != 0 {
                throw ClaudeCodeCLIError.commandFailed(exitCode: exitCode, message: detail)
            }
            throw ClaudeCodeCLIError.invalidOutput(detail)
        }

        let message = (json["result"] as? String) ?? ""
        let isError = (json["is_error"] as? Bool) ?? (exitCode != 0)

        if isError {
            if isNotSignedInMessage(message) {
                throw ClaudeCodeCLIError.notSignedIn
            }
            let status = json["api_error_status"] as? Int
            let detail = message.isEmpty
                ? diagnosticText(standardOutput: standardOutput, standardError: standardError)
                : message
            throw ClaudeCodeCLIError.apiError(status: status, message: detail)
        }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClaudeCodeCLIError.emptyResult
        }
        return trimmed
    }

    /// The CLI reports a missing login as a normal error envelope rather than a
    /// distinct exit code, so the message is what identifies it.
    static func isNotSignedInMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("not logged in")
            || normalized.contains("please run /login")
            || normalized.contains("invalid api key")
            || normalized.contains("authentication_error")
    }

    private static func diagnosticText(standardOutput: Data, standardError: Data) -> String {
        let errorText = String(decoding: standardError, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorText.isEmpty {
            return String(errorText.prefix(400))
        }
        let outputText = String(decoding: standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !outputText.isEmpty {
            return String(outputText.prefix(400))
        }
        return "No output."
    }

    // MARK: - Config helpers

    static func resolvedTimeout(_ configuredSeconds: Int) -> TimeInterval {
        TimeInterval(min(max(configuredSeconds, minimumTimeoutSeconds), maximumTimeoutSeconds))
    }

    static func resolvedModel(_ configuredModel: String) -> String {
        let trimmed = configuredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }
}
