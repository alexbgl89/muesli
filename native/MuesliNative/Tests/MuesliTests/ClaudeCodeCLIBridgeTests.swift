import Testing
import Foundation
@testable import MuesliNativeApp

/// Records what it was asked to run and replays a canned result, so argv,
/// environment, and every error branch are testable without a subprocess.
final class FakeLocalCLIRunner: LocalCLIRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var invocations: [LocalCLIInvocation] = []
    private var results: [LocalCLIResult]
    private let error: Error?

    init(results: [LocalCLIResult] = [], error: Error? = nil) {
        self.results = results
        self.error = error
    }

    convenience init(result: LocalCLIResult) {
        self.init(results: [result])
    }

    /// Convenience for the common "one JSON envelope" case.
    convenience init(json: String, exitCode: Int32 = 0, standardError: String = "") {
        self.init(result: LocalCLIResult(
            exitCode: exitCode,
            standardOutput: Data(json.utf8),
            standardError: Data(standardError.utf8)
        ))
    }

    var recorded: [LocalCLIInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    var lastInvocation: LocalCLIInvocation? { recorded.last }

    func run(_ invocation: LocalCLIInvocation) async throws -> LocalCLIResult {
        lock.lock()
        invocations.append(invocation)
        let next = results.isEmpty ? nil : results.removeFirst()
        lock.unlock()
        if let error { throw error }
        guard let next else {
            return LocalCLIResult(exitCode: 0, standardOutput: Data(), standardError: Data())
        }
        return next
    }
}

struct StubBinaryLocator: ClaudeCodeBinaryLocating {
    var result: Result<URL, ClaudeCodeCLIError>

    static let installed = StubBinaryLocator(result: .success(URL(fileURLWithPath: "/opt/homebrew/bin/claude")))
    static let missing = StubBinaryLocator(result: .failure(.notInstalled))

    func locate(override: String) -> Result<URL, ClaudeCodeCLIError> { result }
}

@Suite("Claude Code argument vector")
struct ClaudeCodeArgumentsTests {

    @Test("the hardening flags are all present")
    func hardeningFlagsPresent() {
        let arguments = ClaudeCodeCLIBridge.completionArguments(model: "sonnet", systemPrompt: "SYS")

        #expect(arguments.contains("-p"))
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(adjacentValue(arguments, after: "--output-format") == "json")
        #expect(adjacentValue(arguments, after: "--permission-mode") == "dontAsk")
        #expect(adjacentValue(arguments, after: "--model") == "sonnet")
        #expect(adjacentValue(arguments, after: "--system-prompt") == "SYS")
        #expect(adjacentValue(arguments, after: "--setting-sources") == "")
    }

    @Test("tools are disabled and the flag is last so its variadic parsing cannot eat another argument")
    func toolsDisabledAndTerminal() throws {
        let arguments = ClaudeCodeCLIBridge.completionArguments(model: "opus", systemPrompt: "SYS")

        let index = try #require(arguments.firstIndex(of: "--tools"))
        #expect(adjacentValue(arguments, after: "--tools") == "")
        // `--tools` is variadic and greedily consumes following non-flag argv, so
        // nothing may follow its empty value.
        #expect(index == arguments.count - 2)
    }

    @Test("flags that would break subscription auth or re-open the sandbox are absent")
    func dangerousFlagsAbsent() {
        let arguments = ClaudeCodeCLIBridge.completionArguments(model: "sonnet", systemPrompt: "SYS")

        // --bare forces ANTHROPIC_API_KEY-only auth and never reads OAuth, which
        // defeats the entire point of using the local CLI.
        #expect(!arguments.contains("--bare"))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
        #expect(!arguments.contains("--allow-dangerously-skip-permissions"))
        #expect(!arguments.contains("--add-dir"))
        #expect(!arguments.contains("default"))
    }

    @Test("a fallback model is only added when configured")
    func fallbackModelIsOptional() {
        let without = ClaudeCodeCLIBridge.completionArguments(model: "sonnet", systemPrompt: "SYS")
        #expect(!without.contains("--fallback-model"))

        let blank = ClaudeCodeCLIBridge.completionArguments(model: "sonnet", systemPrompt: "SYS", fallbackModel: "  ")
        #expect(!blank.contains("--fallback-model"))

        let with = ClaudeCodeCLIBridge.completionArguments(model: "opus", systemPrompt: "SYS", fallbackModel: "sonnet")
        #expect(adjacentValue(with, after: "--fallback-model") == "sonnet")
    }

    private func adjacentValue(_ arguments: [String], after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

@Suite("Claude Code child environment")
struct ClaudeCodeEnvironmentTests {

    @Test("non-essential model calls are disabled so only the chosen model sees the transcript")
    func disablesNonEssentialModelCalls() {
        let environment = ClaudeCodeCLIBridge.childEnvironment(parentEnvironment: [:])

        // Without these, a background model call receives the prompt too — a
        // probe showed haiku taking more input tokens than the primary model.
        #expect(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(environment["DISABLE_NON_ESSENTIAL_MODEL_CALLS"] == "1")
        #expect(environment["DISABLE_TELEMETRY"] == "1")
        #expect(environment["DISABLE_ERROR_REPORTING"] == "1")
        #expect(environment["DISABLE_AUTOUPDATER"] == "1")
    }

    @Test("inherited provider credentials and config redirects are stripped")
    func stripsInheritedProviderCredentials() {
        let parent = [
            "ANTHROPIC_API_KEY": "sk-ant-leak",
            "ANTHROPIC_AUTH_TOKEN": "leak",
            "ANTHROPIC_BASE_URL": "https://evil.example",
            "ANTHROPIC_MODEL": "someone-elses-model",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CODE_USE_VERTEX": "1",
            "CLAUDE_CONFIG_DIR": "/tmp/elsewhere",
            "AWS_ACCESS_KEY_ID": "AKIA",
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/creds.json",
            "USER": "abegal",
        ]

        let environment = ClaudeCodeCLIBridge.childEnvironment(
            parentEnvironment: parent,
            homeDirectory: "/Users/abegal",
            userName: "abegal"
        )

        // An inherited API key would silently bill API credits instead of using
        // the subscription; CLAUDE_CONFIG_DIR makes a signed-in user look out.
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(environment["ANTHROPIC_BASE_URL"] == nil)
        #expect(environment["ANTHROPIC_MODEL"] == nil)
        #expect(environment["CLAUDE_CODE_USE_BEDROCK"] == nil)
        #expect(environment["CLAUDE_CODE_USE_VERTEX"] == nil)
        #expect(environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(environment["AWS_ACCESS_KEY_ID"] == nil)
        #expect(environment["GOOGLE_APPLICATION_CREDENTIALS"] == nil)

        // HOME must survive: the CLI needs it for ~/.claude and the keychain ACL.
        #expect(environment["HOME"] == "/Users/abegal")
        #expect(environment["USER"] == "abegal")
    }

    @Test("HOME and USER are set even when the parent environment has neither")
    func alwaysSetsHomeAndUser() {
        // Verified against the real CLI: HOME+PATH alone reports loggedIn=false,
        // and adding USER flips it to true. A launchd-spawned GUI app may have
        // neither, and the failure mode is a misleading "not signed in".
        let environment = ClaudeCodeCLIBridge.childEnvironment(
            parentEnvironment: [:],
            homeDirectory: "/Users/someone",
            userName: "someone"
        )

        #expect(environment["HOME"] == "/Users/someone")
        #expect(environment["USER"] == "someone")
        #expect(environment["LOGNAME"] == "someone")
    }

    @Test("PATH is fixed rather than inherited from a minimal GUI environment")
    func pathIsExplicit() {
        let environment = ClaudeCodeCLIBridge.childEnvironment(parentEnvironment: ["PATH": "/nonsense"])
        let path = environment["PATH"] ?? ""
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
        #expect(!path.contains("/nonsense"))
    }
}

@Suite("Claude Code envelope parsing")
struct ClaudeCodeEnvelopeTests {

    private func parse(
        _ json: String,
        exitCode: Int32 = 0,
        standardError: String = "",
        timedOut: Bool = false
    ) throws -> String {
        try ClaudeCodeCLIBridge.parseEnvelope(
            standardOutput: Data(json.utf8),
            standardError: Data(standardError.utf8),
            exitCode: exitCode,
            timedOut: timedOut,
            timeout: 300
        )
    }

    @Test("a success envelope yields the trimmed result text")
    func parsesSuccess() throws {
        // Extra '#' delimiters: the payload contains `"##`, which would otherwise
        // close a single-hash raw string early.
        let text = try parse(###"{"type":"result","subtype":"success","is_error":false,"result":"## Notes\n- shipped"}"###)
        #expect(text == "## Notes\n- shipped")
    }

    @Test("is_error is honoured even though subtype still says success")
    func errorDetectedDespiteSuccessSubtype() {
        // The CLI reports failures with subtype "success"; branching on subtype
        // silently swallows every error.
        let json = #"{"type":"result","subtype":"success","is_error":true,"api_error_status":404,"result":"There's an issue with the selected model (bogus)."}"#
        #expect(throws: ClaudeCodeCLIError.apiError(
            status: 404,
            message: "There's an issue with the selected model (bogus)."
        )) {
            try parse(json, exitCode: 1)
        }
    }

    @Test("a missing login is surfaced as notSignedIn, not a generic failure")
    func parsesNotSignedIn() {
        let json = #"{"type":"result","subtype":"success","is_error":true,"api_error_status":null,"result":"Not logged in · Please run /login","terminal_reason":"api_error"}"#
        #expect(throws: ClaudeCodeCLIError.notSignedIn) {
            try parse(json, exitCode: 1)
        }
    }

    @Test("an invalid API key also maps to notSignedIn")
    func invalidKeyMapsToNotSignedIn() {
        let json = #"{"is_error":true,"result":"Invalid API key · Please run /login"}"#
        #expect(throws: ClaudeCodeCLIError.notSignedIn) {
            try parse(json, exitCode: 1)
        }
    }

    @Test("a whitespace-only result is an empty response rather than valid notes")
    func blankResultIsEmpty() {
        #expect(throws: ClaudeCodeCLIError.emptyResult) {
            try parse(#"{"is_error":false,"result":"   \n  "}"#)
        }
    }

    @Test("a timeout wins over whatever was on stdout")
    func timeoutTakesPrecedence() {
        #expect(throws: ClaudeCodeCLIError.timedOut(seconds: 300)) {
            try parse(#"{"is_error":false,"result":"partial"}"#, timedOut: true)
        }
    }

    @Test("unparseable output reports the exit code and the most useful stream")
    func malformedOutput() {
        #expect(throws: ClaudeCodeCLIError.commandFailed(exitCode: 127, message: "claude: command not found")) {
            try parse("", exitCode: 127, standardError: "claude: command not found")
        }
        #expect(throws: ClaudeCodeCLIError.invalidOutput("<html>nope</html>")) {
            try parse("<html>nope</html>")
        }
        #expect(throws: ClaudeCodeCLIError.invalidOutput("No output.")) {
            try parse("")
        }
        #expect(throws: ClaudeCodeCLIError.invalidOutput(#"{"is_error":false,"result":"trunc"#)) {
            try parse(#"{"is_error":false,"result":"trunc"#)
        }
    }

    @Test("sign-in detection is case-insensitive and ignores unrelated messages")
    func signInMessageDetection() {
        #expect(ClaudeCodeCLIBridge.isNotSignedInMessage("NOT LOGGED IN"))
        #expect(ClaudeCodeCLIBridge.isNotSignedInMessage("Please run /login"))
        #expect(ClaudeCodeCLIBridge.isNotSignedInMessage("authentication_error"))
        #expect(!ClaudeCodeCLIBridge.isNotSignedInMessage("Rate limit exceeded"))
        #expect(!ClaudeCodeCLIBridge.isNotSignedInMessage(""))
    }
}

@Suite("Claude Code auth status parsing")
struct ClaudeCodeAuthStatusTests {

    @Test("a signed-in subscription account is reported ready with its details")
    func parsesSignedIn() {
        let json = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"a@b.com","orgName":"Equixly","subscriptionType":"team"}"#
        let availability = ClaudeCodeCLIBridge.parseAuthStatus(Data(json.utf8), binaryPath: "/opt/homebrew/bin/claude")

        #expect(availability.state == .ready)
        #expect(availability.isReady)
        #expect(availability.isInstalled)
        #expect(availability.accountEmail == "a@b.com")
        #expect(availability.organizationName == "Equixly")
        #expect(availability.subscriptionType == "team")
        #expect(availability.authMethod == "claude.ai")
        #expect(availability.binaryPath == "/opt/homebrew/bin/claude")
    }

    @Test("a logged-out install is installed but not ready")
    func parsesLoggedOut() {
        let json = #"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#
        let availability = ClaudeCodeCLIBridge.parseAuthStatus(Data(json.utf8), binaryPath: "/usr/local/bin/claude")

        #expect(availability.state == .notSignedIn)
        #expect(!availability.isReady)
        #expect(availability.isInstalled)
        #expect(availability.accountEmail == nil)
    }

    @Test("unreadable output is treated as not signed in rather than ready")
    func malformedStatusIsNotReady() {
        let availability = ClaudeCodeCLIBridge.parseAuthStatus(Data("not json".utf8), binaryPath: "/x/claude")
        #expect(availability.state == .notSignedIn)
    }
}

@Suite("Claude Code binary discovery")
struct ClaudeCodeBinaryLocatorTests {

    @Test("an absolute executable override wins outright")
    func overrideWins() throws {
        let locator = ClaudeCodeBinaryLocator(
            homeDirectory: "/Users/test",
            isExecutableFile: { $0 == "/custom/claude" || $0 == "/opt/homebrew/bin/claude" }
        )
        let url = try #require(try locator.locate(override: "/custom/claude").get())
        #expect(url.path == "/custom/claude")
    }

    @Test("a bad override fails loudly instead of silently using a different binary")
    func badOverrideDoesNotFallBack() {
        let locator = ClaudeCodeBinaryLocator(
            homeDirectory: "/Users/test",
            isExecutableFile: { $0 == "/opt/homebrew/bin/claude" }
        )

        switch locator.locate(override: "/typo/claude") {
        case .success:
            Issue.record("a non-existent override must not fall back to discovery")
        case .failure(let error):
            guard case .invalidBinaryPath = error else {
                Issue.record("expected invalidBinaryPath, got \(error)")
                return
            }
        }

        switch locator.locate(override: "relative/claude") {
        case .success:
            Issue.record("a relative override must be rejected")
        case .failure(let error):
            guard case .invalidBinaryPath = error else {
                Issue.record("expected invalidBinaryPath, got \(error)")
                return
            }
        }
    }

    @Test("discovery prefers the native installer path, then Homebrew")
    func discoveryOrder() throws {
        let both = ClaudeCodeBinaryLocator(
            homeDirectory: "/Users/test",
            isExecutableFile: { $0 == "/Users/test/.local/bin/claude" || $0 == "/opt/homebrew/bin/claude" }
        )
        #expect(try both.locate(override: "").get().path == "/Users/test/.local/bin/claude")

        let brewOnly = ClaudeCodeBinaryLocator(
            homeDirectory: "/Users/test",
            isExecutableFile: { $0 == "/opt/homebrew/bin/claude" }
        )
        #expect(try brewOnly.locate(override: "").get().path == "/opt/homebrew/bin/claude")
    }

    @Test("no install reports notInstalled")
    func noInstall() {
        let locator = ClaudeCodeBinaryLocator(homeDirectory: "/Users/test", isExecutableFile: { _ in false })
        #expect(locator.locate(override: "") == .failure(.notInstalled))
    }

    @Test("candidate paths cover the documented install layouts")
    func candidatesCoverKnownLayouts() {
        let candidates = ClaudeCodeBinaryLocator.candidatePaths(homeDirectory: "/Users/test")
        #expect(candidates.contains("/Users/test/.local/bin/claude"))
        #expect(candidates.contains("/opt/homebrew/bin/claude"))
        #expect(candidates.contains("/usr/local/bin/claude"))
        #expect(candidates.contains("/Users/test/.claude/local/claude"))
        // PATH is never consulted: a GUI app gets a minimal one, and a login
        // shell would execute the user's dotfiles in our process tree.
        #expect(!candidates.contains("claude"))
    }
}

@Suite("Claude Code bridge invocation")
struct ClaudeCodeBridgeInvocationTests {

    private func config(model: String = "", timeout: Int = 300) -> AppConfig {
        var config = AppConfig()
        config.claudeCodeModel = model
        config.claudeCodeTimeoutSeconds = timeout
        return config
    }

    @Test("the transcript travels on stdin, never in argv")
    func transcriptOnStdin() async throws {
        let runner = FakeLocalCLIRunner(json: #"{"is_error":false,"result":"notes"}"#)
        let bridge = ClaudeCodeCLIBridge(runner: runner, locator: StubBinaryLocator.installed)
        let secret = "SENSITIVE-TRANSCRIPT-MARKER"
        let transcript = String(repeating: "\(secret) filler text. ", count: 20_000)

        _ = try await bridge.complete(
            instructions: "SYS",
            userPrompt: transcript,
            model: "sonnet",
            timeout: 300,
            config: config()
        )

        let invocation = try #require(runner.lastInvocation)
        #expect(String(decoding: invocation.standardInput, as: UTF8.self).contains(secret))
        // argv is world-readable through `ps`, and is capped by ARG_MAX.
        #expect(!invocation.arguments.contains { $0.contains(secret) })
        #expect(invocation.standardInput.count > 400_000)
    }

    @Test("the child runs in an empty working directory with a replaced environment")
    func isolatedWorkingDirectoryAndEnvironment() async throws {
        let runner = FakeLocalCLIRunner(json: #"{"is_error":false,"result":"notes"}"#)
        let bridge = ClaudeCodeCLIBridge(runner: runner, locator: StubBinaryLocator.installed)

        _ = try await bridge.complete(
            instructions: "SYS",
            userPrompt: "prompt",
            model: "sonnet",
            timeout: 120,
            config: config()
        )

        let invocation = try #require(runner.lastInvocation)
        #expect(invocation.workingDirectory.lastPathComponent == "claude-code-cwd")
        #expect(invocation.environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(invocation.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(invocation.timeout == 120)
    }

    @Test("a missing install surfaces before anything is spawned")
    func missingInstallShortCircuits() async {
        let runner = FakeLocalCLIRunner(json: #"{"is_error":false,"result":"notes"}"#)
        let bridge = ClaudeCodeCLIBridge(runner: runner, locator: StubBinaryLocator.missing)

        await #expect(throws: ClaudeCodeCLIError.notInstalled) {
            try await bridge.complete(
                instructions: "SYS",
                userPrompt: "prompt",
                model: "sonnet",
                timeout: 60,
                config: config()
            )
        }
        #expect(runner.recorded.isEmpty)
    }

    @Test("an empty configured model falls back to the default alias")
    func emptyModelUsesDefault() async throws {
        let runner = FakeLocalCLIRunner(json: #"{"is_error":false,"result":"notes"}"#)
        let bridge = ClaudeCodeCLIBridge(runner: runner, locator: StubBinaryLocator.installed)

        _ = try await bridge.complete(
            instructions: "SYS",
            userPrompt: "prompt",
            model: "",
            timeout: 60,
            config: config()
        )

        let invocation = try #require(runner.lastInvocation)
        let index = try #require(invocation.arguments.firstIndex(of: "--model"))
        #expect(invocation.arguments[index + 1] == ClaudeCodeCLIBridge.defaultModel)
    }

    @Test("availability probes auth status locally, without a completion request")
    func availabilityUsesAuthStatus() async throws {
        let runner = FakeLocalCLIRunner(json: #"{"loggedIn":true,"authMethod":"claude.ai","email":"a@b.com","subscriptionType":"max"}"#)
        let bridge = ClaudeCodeCLIBridge(runner: runner, locator: StubBinaryLocator.installed)

        let availability = await bridge.availability(config: config(), forceRefresh: true)

        #expect(availability.state == .ready)
        #expect(availability.subscriptionType == "max")
        let invocation = try #require(runner.lastInvocation)
        #expect(invocation.arguments == ["auth", "status", "--json"])
        #expect(!invocation.arguments.contains("-p"))
    }

    @Test("availability is cached within its TTL and refreshed on demand")
    func availabilityCaching() async {
        let signedIn = LocalCLIResult(
            exitCode: 0,
            standardOutput: Data(#"{"loggedIn":true,"email":"a@b.com"}"#.utf8),
            standardError: Data()
        )
        let runner = FakeLocalCLIRunner(results: [signedIn, signedIn])
        let bridge = ClaudeCodeCLIBridge(runner: runner, locator: StubBinaryLocator.installed)

        _ = await bridge.availability(config: config(), forceRefresh: false)
        _ = await bridge.availability(config: config(), forceRefresh: false)
        #expect(runner.recorded.count == 1)

        _ = await bridge.availability(config: config(), forceRefresh: true)
        #expect(runner.recorded.count == 2)
    }

    @Test("a missing binary reports missing without spawning a probe")
    func availabilityWhenMissing() async {
        let runner = FakeLocalCLIRunner(json: "{}")
        let bridge = ClaudeCodeCLIBridge(runner: runner, locator: StubBinaryLocator.missing)

        let availability = await bridge.availability(config: config(), forceRefresh: true)

        #expect(availability.state == .missing)
        #expect(!availability.isInstalled)
        #expect(runner.recorded.isEmpty)
    }

    @Test("a rejected override path is explained in the status")
    func availabilitySurfacesBadOverride() async {
        let bridge = ClaudeCodeCLIBridge(
            runner: FakeLocalCLIRunner(json: "{}"),
            locator: StubBinaryLocator(result: .failure(.invalidBinaryPath("No executable found at /typo/claude")))
        )

        let availability = await bridge.availability(config: config(), forceRefresh: true)

        #expect(availability.state == .missing)
        #expect(availability.problem == "No executable found at /typo/claude")
    }

    @Test("configured timeouts are clamped to a sane range")
    func timeoutClamping() {
        #expect(ClaudeCodeCLIBridge.resolvedTimeout(300) == 300)
        #expect(ClaudeCodeCLIBridge.resolvedTimeout(0) == TimeInterval(ClaudeCodeCLIBridge.minimumTimeoutSeconds))
        #expect(ClaudeCodeCLIBridge.resolvedTimeout(-5) == TimeInterval(ClaudeCodeCLIBridge.minimumTimeoutSeconds))
        #expect(ClaudeCodeCLIBridge.resolvedTimeout(99_999) == TimeInterval(ClaudeCodeCLIBridge.maximumTimeoutSeconds))
    }

    @Test("model resolution trims and defaults")
    func modelResolution() {
        #expect(ClaudeCodeCLIBridge.resolvedModel("") == ClaudeCodeCLIBridge.defaultModel)
        #expect(ClaudeCodeCLIBridge.resolvedModel("   ") == ClaudeCodeCLIBridge.defaultModel)
        #expect(ClaudeCodeCLIBridge.resolvedModel("  opus ") == "opus")
    }
}

@Suite("Claude Code sign-in launcher")
struct ClaudeCodeSignInLauncherTests {

    @Test("the binary path is shell-quoted so odd paths cannot break out")
    func quotesPaths() {
        #expect(ClaudeCodeSignInLauncher.shellQuoted("/opt/homebrew/bin/claude") == "'/opt/homebrew/bin/claude'")
        #expect(ClaudeCodeSignInLauncher.shellQuoted("/tmp/my claude") == "'/tmp/my claude'")
        #expect(ClaudeCodeSignInLauncher.shellQuoted("/tmp/it's") == #"'/tmp/it'\''s'"#)
    }

    @Test("the script runs the subscription login flow with the quoted binary")
    func scriptRunsSubscriptionLogin() {
        let script = ClaudeCodeSignInLauncher.scriptContents(binaryPath: "/opt/homebrew/bin/claude")

        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains("'/opt/homebrew/bin/claude' auth login --claudeai"))
        // --console would bill API usage instead of using the subscription.
        #expect(!script.contains("--console"))
    }

    @Test("an injection attempt in the path stays inside the quoted argument")
    func scriptResistsInjection() {
        let script = ClaudeCodeSignInLauncher.scriptContents(binaryPath: "/tmp/x'; rm -rf ~; echo '")
        #expect(!script.contains("; rm -rf ~; echo ;"))
        #expect(script.contains(#"'/tmp/x'\''; rm -rf ~; echo '\'''"#))
    }
}

@Suite("Claude Code summary integration")
struct ClaudeCodeSummaryIntegrationTests {

    /// Stands in for the bridge at the `MeetingSummaryClient` seam.
    private final class StubBridge: ClaudeCodeSummarizing, @unchecked Sendable {
        let text: String
        let error: Error?
        private let lock = NSLock()
        private var capturedInstructions: [String] = []
        private var capturedPrompts: [String] = []
        private var capturedModels: [String] = []

        init(text: String = "## Notes\n- ok", error: Error? = nil) {
            self.text = text
            self.error = error
        }

        var instructions: [String] { lock.lock(); defer { lock.unlock() }; return capturedInstructions }
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return capturedPrompts }
        var models: [String] { lock.lock(); defer { lock.unlock() }; return capturedModels }

        func complete(
            instructions: String,
            userPrompt: String,
            model: String,
            timeout: TimeInterval,
            config: AppConfig
        ) async throws -> String {
            lock.lock()
            capturedInstructions.append(instructions)
            capturedPrompts.append(userPrompt)
            capturedModels.append(model)
            lock.unlock()
            if let error { throw error }
            return text
        }

        func availability(config: AppConfig, forceRefresh: Bool) async -> ClaudeCodeAvailability {
            ClaudeCodeAvailability(
                state: .ready,
                binaryPath: "/opt/homebrew/bin/claude",
                accountEmail: nil,
                organizationName: nil,
                subscriptionType: nil,
                authMethod: "claude.ai",
                problem: nil
            )
        }
    }

    private func claudeCodeConfig() -> AppConfig {
        var config = AppConfig()
        config.meetingSummaryBackend = MeetingSummaryBackendOption.claudeCode.backend
        config.meetingSummaryRetryCount = 0
        return config
    }

    @Test("the claude_code backend routes to the bridge with the template prompt")
    func routesToClaudeCode() async throws {
        let stub = StubBridge()
        MeetingSummaryClient.claudeCodeBridgeForTests = stub
        defer { MeetingSummaryClient.claudeCodeBridgeForTests = nil }

        let notes = try await MeetingSummaryClient.summarize(
            transcript: "Alice: ship Thursday.",
            meetingTitle: "Release sync",
            config: claudeCodeConfig()
        )

        #expect(notes.contains("## Notes"))
        #expect(stub.prompts.count == 1)
        #expect(stub.prompts[0].contains("Alice: ship Thursday."))
        #expect(stub.prompts[0].contains("Release sync"))
        // Instructions carry the shared template contract, same as every backend.
        #expect(stub.instructions[0].contains("meeting notes assistant"))
        #expect(stub.models[0] == ClaudeCodeCLIBridge.defaultModel)
    }

    @Test("the configured alias is passed through")
    func usesConfiguredModel() async throws {
        let stub = StubBridge()
        MeetingSummaryClient.claudeCodeBridgeForTests = stub
        defer { MeetingSummaryClient.claudeCodeBridgeForTests = nil }

        var config = claudeCodeConfig()
        config.claudeCodeModel = "opus"
        _ = try await MeetingSummaryClient.summarize(
            transcript: "text",
            meetingTitle: "t",
            config: config
        )

        #expect(stub.models[0] == "opus")
    }

    @Test("a CLI failure surfaces as a Claude Code summary error, not an OpenAI one")
    func mapsErrorsToBackendLabel() async {
        let stub = StubBridge(error: ClaudeCodeCLIError.notSignedIn)
        MeetingSummaryClient.claudeCodeBridgeForTests = stub
        defer { MeetingSummaryClient.claudeCodeBridgeForTests = nil }

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "text",
                meetingTitle: "t",
                config: claudeCodeConfig()
            )
            Issue.record("expected the summary to fail")
        } catch let error as MeetingSummaryError {
            guard case let .backendFailed(backend, _, message) = error else {
                Issue.record("expected backendFailed, got \(error)")
                return
            }
            #expect(backend == ClaudeCodeCLIBridge.displayLabel)
            #expect(message.contains("isn't signed in"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("an empty CLI result maps to emptyResponse so the retry policy can act")
    func emptyResultMapsToEmptyResponse() async {
        let stub = StubBridge(error: ClaudeCodeCLIError.emptyResult)
        MeetingSummaryClient.claudeCodeBridgeForTests = stub
        defer { MeetingSummaryClient.claudeCodeBridgeForTests = nil }

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "text",
                meetingTitle: "t",
                config: claudeCodeConfig()
            )
            Issue.record("expected the summary to fail")
        } catch let error as MeetingSummaryError {
            guard case .emptyResponse(let backend) = error else {
                Issue.record("expected emptyResponse, got \(error)")
                return
            }
            #expect(backend == ClaudeCodeCLIBridge.displayLabel)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("title generation uses the bridge and returns nil on failure")
    func titleGeneration() async {
        let stub = StubBridge(text: "Release Sync Planning")
        MeetingSummaryClient.claudeCodeBridgeForTests = stub
        defer { MeetingSummaryClient.claudeCodeBridgeForTests = nil }

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Alice: ship Thursday.",
            config: claudeCodeConfig()
        )
        #expect(title == "Release Sync Planning")

        MeetingSummaryClient.claudeCodeBridgeForTests = StubBridge(error: ClaudeCodeCLIError.notInstalled)
        let failed = await MeetingSummaryClient.generateTitle(
            transcript: "Alice: ship Thursday.",
            config: claudeCodeConfig()
        )
        #expect(failed == nil)
    }

    @Test("Claude Code takes the capped local retry budget")
    func retryBudgetIsLocal() {
        // Each retry is a fresh process launch plus subscription tokens.
        #expect(MeetingSummaryRetryPolicy.effectiveRetryCount(
            configuredCount: 5,
            after: MeetingSummaryError.emptyResponse(backend: ClaudeCodeCLIBridge.displayLabel)
        ) == 1)
    }
}

@Suite("Claude Code backend registration")
struct ClaudeCodeBackendRegistrationTests {

    @Test("the summary backend is registered and resolvable")
    func summaryBackendRegistered() {
        #expect(MeetingSummaryBackendOption.claudeCode.backend == "claude_code")
        #expect(MeetingSummaryBackendOption.claudeCode.label == "Claude Code")
        #expect(MeetingSummaryBackendOption.all.contains(MeetingSummaryBackendOption.claudeCode))
        #expect(MeetingSummaryBackendOption.resolved("claude_code") == .claudeCode)
    }

    @Test("the cleanup backend is registered through LLMBackendOption")
    func cleanupBackendRegistered() {
        #expect(LLMBackendOption.claudeCode.backend == "claude_code")
        #expect(LLMBackendOption.resolved("claude_code") == .claudeCode)
        // TranscriptCleanupBackendOption.all derives from LLMBackendOption.all.
        #expect(TranscriptCleanupBackendOption.resolved("claude_code").llmBackend == .claudeCode)
        #expect(TranscriptCleanupBackendOption.all.contains { $0.llmBackend == .claudeCode })
    }

    @Test("backend labels stay unique because menu selection round-trips through them")
    func labelsAreUnique() {
        let summaryLabels = MeetingSummaryBackendOption.all.map(\.label)
        #expect(Set(summaryLabels).count == summaryLabels.count)
        let cleanupLabels = TranscriptCleanupBackendOption.all.map(\.label)
        #expect(Set(cleanupLabels).count == cleanupLabels.count)
    }

    @Test("config round-trips the Claude Code keys as snake_case")
    func configRoundTrip() throws {
        var config = AppConfig()
        #expect(config.claudeCodePath.isEmpty)
        #expect(config.claudeCodeModel.isEmpty)
        #expect(config.claudeCodeTimeoutSeconds == ClaudeCodeCLIBridge.defaultTimeoutSeconds)

        config.claudeCodePath = "/opt/homebrew/bin/claude"
        config.claudeCodeModel = "opus"
        config.claudeCodeTimeoutSeconds = 420
        config.postProcessorClaudeCodeModel = "sonnet"

        let encoded = try JSONEncoder().encode(config)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["claude_code_path"] as? String == "/opt/homebrew/bin/claude")
        #expect(json["claude_code_model"] as? String == "opus")
        #expect(json["claude_code_timeout_seconds"] as? Int == 420)
        #expect(json["post_processor_claude_code_model"] as? String == "sonnet")

        let decoded = try JSONDecoder().decode(AppConfig.self, from: encoded)
        #expect(decoded.claudeCodePath == "/opt/homebrew/bin/claude")
        #expect(decoded.claudeCodeModel == "opus")
        #expect(decoded.claudeCodeTimeoutSeconds == 420)
        #expect(decoded.postProcessorClaudeCodeModel == "sonnet")
    }

    @Test("an out-of-range persisted timeout is clamped at decode")
    func decodeClampsTimeout() throws {
        let tiny = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"claude_code_timeout_seconds": 1}"#.utf8)
        )
        #expect(tiny.claudeCodeTimeoutSeconds == ClaudeCodeCLIBridge.minimumTimeoutSeconds)

        let huge = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"claude_code_timeout_seconds": 100000}"#.utf8)
        )
        #expect(huge.claudeCodeTimeoutSeconds == ClaudeCodeCLIBridge.maximumTimeoutSeconds)
    }

    @Test("configs written before this feature keep working")
    func legacyConfigDecodes() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"dark_mode": true}"#.utf8))
        #expect(decoded.claudeCodePath.isEmpty)
        #expect(decoded.claudeCodeTimeoutSeconds == ClaudeCodeCLIBridge.defaultTimeoutSeconds)
    }

    @Test("the model presets are aliases so they survive model releases")
    func presetsAreAliases() {
        let ids = SummaryModelPreset.claudeCodeModels.map(\.id)
        #expect(ids.contains("sonnet"))
        #expect(ids.contains("opus"))
        #expect(ids.first == ClaudeCodeCLIBridge.defaultModel)
        // A dated id would quietly retire; aliases keep tracking the latest.
        #expect(!ids.contains { $0.contains("-2024") || $0.contains("-2025") })
    }
}
