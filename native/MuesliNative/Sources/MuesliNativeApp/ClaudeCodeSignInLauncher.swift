import AppKit
import Foundation

/// Starts `claude auth login` on the user's behalf.
///
/// The login flow is interactive — it prints a URL, opens a browser, and waits
/// on stdin — so it cannot run headlessly from a GUI app. Instead a small
/// `.command` script is written and handed to Launch Services, which opens it in
/// the user's terminal where the flow can complete normally. Muesli then polls
/// `claude auth status --json` until the account appears.
enum ClaudeCodeSignInLauncher {
    enum LaunchError: Error, LocalizedError, Equatable {
        case notInstalled
        case scriptWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return ClaudeCodeCLIError.notInstalled.errorDescription
            case .scriptWriteFailed(let message):
                return "Could not prepare the sign-in step: \(message)"
            }
        }
    }

    /// Wraps a path for safe interpolation into a `sh` script.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func scriptContents(binaryPath: String) -> String {
        let quoted = shellQuoted(binaryPath)
        return """
        #!/bin/sh
        # Opened by Muesli to sign in to Claude Code. Safe to close when finished.
        echo 'Signing in to Claude Code so Muesli can use your Claude subscription.'
        echo
        \(quoted) auth login --claudeai
        status=$?
        echo
        if [ "$status" -eq 0 ]; then
          echo 'Signed in. Return to Muesli — it will detect the account automatically.'
        else
          echo "Sign-in did not complete (exit $status). You can close this window and try again."
        fi
        echo
        echo 'Press return to close.'
        read _ignored
        """
    }

    /// Writes the helper script and opens it in the user's terminal.
    @MainActor
    static func launch(binaryPath: String?) throws {
        guard let binaryPath, !binaryPath.isEmpty else {
            throw LaunchError.notInstalled
        }

        let directory = AppIdentity.supportDirectoryURL
            .appendingPathComponent("claude-code-signin", isDirectory: true)
        let scriptURL = directory.appendingPathComponent("claude-code-sign-in.command")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(scriptContents(binaryPath: binaryPath).utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            throw LaunchError.scriptWriteFailed(error.localizedDescription)
        }

        NSWorkspace.shared.open(scriptURL)
    }
}
