import Foundation

protocol ClaudeCodeBinaryLocating: Sendable {
    /// Absolute path to a runnable `claude`, or nil when none is installed.
    /// `override` is the user-supplied path from config, which wins outright.
    func locate(override: String) -> Result<URL, ClaudeCodeCLIError>
}

/// Finds the `claude` executable without consulting `PATH`.
///
/// A GUI app launched from Finder or launchd gets a minimal `PATH`, so
/// `which claude` is unreliable — the same reason `SalesforceCLIBridge` probes
/// fixed directories. Spawning a login shell to resolve `PATH` would execute the
/// user's dotfiles inside our process tree, so it is deliberately not done.
struct ClaudeCodeBinaryLocator: ClaudeCodeBinaryLocating {
    /// Injected so tests can point discovery at a temp directory. A closure
    /// rather than a `FileManager`, which is not `Sendable`.
    private let isExecutableFile: @Sendable (String) -> Bool
    private let homeDirectory: String

    init(
        homeDirectory: String = NSHomeDirectory(),
        isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.homeDirectory = homeDirectory
        self.isExecutableFile = isExecutableFile
    }

    /// Install locations in descending likelihood. The symlink itself is
    /// executed rather than its resolved target, so Homebrew cask upgrades keep
    /// working without a config change.
    static func candidatePaths(homeDirectory: String) -> [String] {
        [
            "\(homeDirectory)/.local/bin/claude",   // official native installer
            "/opt/homebrew/bin/claude",             // Homebrew, Apple Silicon
            "/usr/local/bin/claude",                // Homebrew Intel, or global npm
            "\(homeDirectory)/.claude/local/claude", // legacy migrate-installer
            "\(homeDirectory)/.bun/bin/claude",
            "\(homeDirectory)/.volta/bin/claude",
            "\(homeDirectory)/.npm-global/bin/claude",
        ]
    }

    func locate(override: String) -> Result<URL, ClaudeCodeCLIError> {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // A typo'd override that silently falls back to a different binary is
            // worse than a clear failure, so this never degrades to discovery.
            guard NSString(string: trimmed).isAbsolutePath else {
                return .failure(.invalidBinaryPath("The Claude Code path must be absolute: \(trimmed)"))
            }
            guard isExecutableFile(trimmed) else {
                return .failure(.invalidBinaryPath("No executable found at \(trimmed)"))
            }
            return .success(URL(fileURLWithPath: trimmed))
        }

        for candidate in Self.candidatePaths(homeDirectory: homeDirectory)
        where isExecutableFile(candidate) {
            return .success(URL(fileURLWithPath: candidate))
        }
        return .failure(.notInstalled)
    }
}
