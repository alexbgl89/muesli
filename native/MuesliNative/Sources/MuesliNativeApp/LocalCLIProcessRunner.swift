import Foundation

// Spawning child processes only works because Muesli is not App-Sandboxed —
// there is no `com.apple.security.app-sandbox` key in scripts/Muesli.entitlements.
// Adding that key would break this runner, MeetingHookRunner, and
// ComputerUseBrowserAutomation at the same time.

/// One child-process launch. The environment is a full replacement rather than
/// an overlay, so nothing the GUI app inherited from launchd leaks into the
/// child by accident.
struct LocalCLIInvocation: Sendable {
    let executable: URL
    let arguments: [String]
    let standardInput: Data
    let environment: [String: String]
    let workingDirectory: URL
    let timeout: TimeInterval
    let maxStandardOutputBytes: Int
    let maxStandardErrorBytes: Int

    init(
        executable: URL,
        arguments: [String],
        standardInput: Data = Data(),
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval,
        maxStandardOutputBytes: Int = 4 * 1024 * 1024,
        maxStandardErrorBytes: Int = 64 * 1024
    ) {
        self.executable = executable
        self.arguments = arguments
        self.standardInput = standardInput
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.maxStandardOutputBytes = maxStandardOutputBytes
        self.maxStandardErrorBytes = maxStandardErrorBytes
    }
}

struct LocalCLIResult: Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
    let timedOut: Bool
    let truncatedStandardOutput: Bool

    init(
        exitCode: Int32,
        standardOutput: Data,
        standardError: Data,
        timedOut: Bool = false,
        truncatedStandardOutput: Bool = false
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
        self.truncatedStandardOutput = truncatedStandardOutput
    }
}

enum LocalCLIRunnerError: Error, LocalizedError {
    case notExecutable(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .notExecutable(let path):
            return "\(path) is not an executable file."
        case .launchFailed(let message):
            return "Could not start the command: \(message)"
        }
    }
}

/// Seam so callers can be tested without spawning anything.
protocol LocalCLIRunning: Sendable {
    func run(_ invocation: LocalCLIInvocation) async throws -> LocalCLIResult
}

/// Bounded, thread-safe accumulator for a pipe's output. Keeps the most recent
/// bytes when a child overruns the cap.
private final class BoundedPipeBuffer: @unchecked Sendable {
    private let capacity: Int
    private let lock = NSLock()
    private var data = Data()
    private var didTruncate = false

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > capacity {
            data.removeFirst(data.count - capacity)
            didTruncate = true
        }
    }

    var snapshot: (data: Data, truncated: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, didTruncate)
    }
}

/// Holds the live process so a cancelled Task can terminate it. Mirrors the
/// cancellation box in `ComputerUseBrowserAutomation`.
private final class LocalCLIProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    /// Returns false when cancellation already fired, meaning the caller must
    /// not start the process at all.
    func set(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.process = process
        return true
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        process = nil
    }

    func cancel() {
        lock.lock()
        let running = process
        isCancelled = true
        lock.unlock()
        guard let running, running.isRunning else { return }
        running.terminate()
    }

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

struct LocalCLIProcessRunner: LocalCLIRunning {
    func run(_ invocation: LocalCLIInvocation) async throws -> LocalCLIResult {
        let path = invocation.executable.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw LocalCLIRunnerError.notExecutable(path)
        }

        let box = LocalCLIProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try Self.runSynchronously(invocation, box: box)
                        if box.wasCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(returning: result)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func runSynchronously(
        _ invocation: LocalCLIInvocation,
        box: LocalCLIProcessBox
    ) throws -> LocalCLIResult {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.workingDirectory

        // stdout and stderr are drained concurrently by readability handlers.
        // Reading one to EOF before the other deadlocks as soon as the child
        // fills the pipe we are not reading.
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputBuffer = BoundedPipeBuffer(capacity: invocation.maxStandardOutputBytes)
        let errorBuffer = BoundedPipeBuffer(capacity: invocation.maxStandardErrorBytes)
        attach(pipe: outputPipe, to: outputBuffer)
        attach(pipe: errorPipe, to: errorBuffer)
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe = Pipe()
        process.standardInput = inputPipe

        let termination = DispatchSemaphore(value: 0)
        let statusBox = TerminationStatusBox()
        process.terminationHandler = { finished in
            statusBox.value = finished.terminationStatus
            termination.signal()
        }

        guard box.set(process) else {
            detach(outputPipe, errorPipe)
            throw CancellationError()
        }

        do {
            try process.run()
        } catch {
            detach(outputPipe, errorPipe)
            box.clear()
            throw LocalCLIRunnerError.launchFailed(error.localizedDescription)
        }

        // The child reads stdin to EOF, so the write handle must be closed or it
        // blocks until the timeout.
        writeStandardInput(invocation.standardInput, to: inputPipe)

        var timedOut = false
        let timeoutSeconds = max(Int(invocation.timeout.rounded()), 1)
        if termination.wait(timeout: .now() + .seconds(timeoutSeconds)) == .timedOut {
            timedOut = true
            terminate(process, semaphore: termination)
        }

        detach(outputPipe, errorPipe)
        drain(outputPipe, into: outputBuffer)
        drain(errorPipe, into: errorBuffer)
        box.clear()

        let output = outputBuffer.snapshot
        let errorOutput = errorBuffer.snapshot
        return LocalCLIResult(
            exitCode: statusBox.value,
            standardOutput: output.data,
            standardError: errorOutput.data,
            timedOut: timedOut,
            truncatedStandardOutput: output.truncated
        )
    }

    private static func attach(pipe: Pipe, to buffer: BoundedPipeBuffer) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
        }
    }

    private static func detach(_ pipes: Pipe...) {
        for pipe in pipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private static func drain(_ pipe: Pipe, into buffer: BoundedPipeBuffer) {
        do {
            if let trailing = try pipe.fileHandleForReading.readToEnd(), !trailing.isEmpty {
                buffer.append(trailing)
            }
            try pipe.fileHandleForReading.close()
        } catch {
            // The handle is already closed or the child died mid-read; whatever
            // was buffered is still returned to the caller.
        }
    }

    private static func writeStandardInput(_ data: Data, to pipe: Pipe) {
        if !data.isEmpty {
            // A child that exits before reading stdin turns this write into
            // EPIPE/SIGPIPE, which is expected rather than fatal.
            try? pipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? pipe.fileHandleForWriting.close()
    }

    private static func terminate(_ process: Process, semaphore: DispatchSemaphore) {
        guard process.isRunning else { return }
        process.terminate()
        if semaphore.wait(timeout: .now() + .seconds(1)) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = semaphore.wait(timeout: .now() + .seconds(1))
        }
    }
}

private final class TerminationStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int32 = -1

    var value: Int32 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
