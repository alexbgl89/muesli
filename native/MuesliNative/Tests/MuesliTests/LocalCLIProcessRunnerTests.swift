import Testing
import Foundation
@testable import MuesliNativeApp

/// Exercises the runner against real `/bin/sh` scripts, since the behaviour under
/// test is process plumbing: stdin closing, concurrent pipe draining, timeouts.
@Suite("Local CLI process runner", .serialized)
struct LocalCLIProcessRunnerTests {

    private func makeScript(_ body: String) throws -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cli-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("script.sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (script, directory)
    }

    private func invocation(
        _ script: URL,
        workingDirectory: URL,
        standardInput: Data = Data(),
        timeout: TimeInterval = 20,
        maxStandardOutputBytes: Int = 4 * 1024 * 1024
    ) -> LocalCLIInvocation {
        LocalCLIInvocation(
            executable: script,
            arguments: [],
            standardInput: standardInput,
            environment: ["PATH": "/usr/bin:/bin", "MUESLI_TEST": "1"],
            workingDirectory: workingDirectory,
            timeout: timeout,
            maxStandardOutputBytes: maxStandardOutputBytes
        )
    }

    @Test("captures stdout, stderr, and the exit code")
    func capturesStreamsAndExitCode() async throws {
        let (script, directory) = try makeScript("""
        echo 'to stdout'
        echo 'to stderr' >&2
        exit 3
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await LocalCLIProcessRunner().run(invocation(script, workingDirectory: directory))

        #expect(result.exitCode == 3)
        #expect(String(decoding: result.standardOutput, as: UTF8.self).contains("to stdout"))
        #expect(String(decoding: result.standardError, as: UTF8.self).contains("to stderr"))
        #expect(!result.timedOut)
    }

    @Test("stdin is delivered and its write end closed so the child sees EOF")
    func deliversStdinAndClosesIt() async throws {
        // `cat` only terminates when stdin reaches EOF; if the write handle were
        // left open this would hang until the timeout instead.
        let (script, directory) = try makeScript("cat")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await LocalCLIProcessRunner().run(invocation(
            script,
            workingDirectory: directory,
            standardInput: Data("hello from stdin".utf8),
            timeout: 10
        ))

        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == "hello from stdin")
    }

    @Test("large stdout and concurrent stderr do not deadlock")
    func concurrentStreamsDoNotDeadlock() async throws {
        // Reading one pipe to EOF before the other deadlocks as soon as the child
        // fills the pipe nobody is draining. Both must be drained concurrently.
        let (script, directory) = try makeScript("""
        i=0
        while [ $i -lt 400 ]; do
          echo "stdout line $i aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          echo "stderr line $i bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" >&2
          i=$((i+1))
        done
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await LocalCLIProcessRunner().run(invocation(script, workingDirectory: directory, timeout: 30))

        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(result.standardOutput.count > 30_000)
        #expect(result.standardError.count > 30_000)
    }

    @Test("a hung child is killed at the timeout")
    func timesOutAndKills() async throws {
        let (script, directory) = try makeScript("sleep 60")
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date()
        let result = try await LocalCLIProcessRunner().run(invocation(script, workingDirectory: directory, timeout: 2))
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.timedOut)
        #expect(elapsed < 20)
    }

    @Test("output beyond the cap is truncated rather than growing without bound")
    func truncatesOversizeOutput() async throws {
        let (script, directory) = try makeScript("""
        i=0
        while [ $i -lt 500 ]; do
          echo "0123456789012345678901234567890123456789012345678901234567890123"
          i=$((i+1))
        done
        """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await LocalCLIProcessRunner().run(invocation(
            script,
            workingDirectory: directory,
            maxStandardOutputBytes: 1024
        ))

        #expect(result.standardOutput.count <= 1024)
        #expect(result.truncatedStandardOutput)
    }

    @Test("the environment is replaced, not merged with the parent's")
    func environmentIsReplaced() async throws {
        let (script, directory) = try makeScript("echo \"MUESLI_TEST=$MUESLI_TEST HOME=[$HOME]\"")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await LocalCLIProcessRunner().run(invocation(script, workingDirectory: directory))
        let output = String(decoding: result.standardOutput, as: UTF8.self)

        #expect(output.contains("MUESLI_TEST=1"))
        // HOME was not in the supplied environment, so the child must not have it.
        #expect(output.contains("HOME=[]"))
    }

    @Test("the child starts in the requested working directory")
    func honoursWorkingDirectory() async throws {
        let (script, directory) = try makeScript("pwd")
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await LocalCLIProcessRunner().run(invocation(script, workingDirectory: directory))
        let output = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(output.hasSuffix(directory.lastPathComponent))
    }

    @Test("a non-executable path fails before launching")
    func rejectsNonExecutable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cli-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plainFile = directory.appendingPathComponent("not-executable.txt")
        try Data("hello".utf8).write(to: plainFile)

        await #expect(throws: LocalCLIRunnerError.self) {
            try await LocalCLIProcessRunner().run(invocation(plainFile, workingDirectory: directory))
        }
    }

    @Test("cancelling the task terminates the child")
    func cancellationTerminatesChild() async throws {
        let (script, directory) = try makeScript("sleep 60")
        defer { try? FileManager.default.removeItem(at: directory) }

        let call = invocation(script, workingDirectory: directory, timeout: 120)
        let task = Task { try await LocalCLIProcessRunner().run(call) }
        try? await Task.sleep(for: .milliseconds(400))
        task.cancel()

        let start = Date()
        let outcome = await task.result
        let elapsed = Date().timeIntervalSince(start)

        // Either a CancellationError or an early return is acceptable; what must
        // not happen is waiting out the full 120s timeout.
        #expect(elapsed < 20)
        if case .success(let result) = outcome {
            #expect(result.exitCode != 0 || result.timedOut)
        }
    }
}
