import Foundation

/// One-shot gate for resuming a continuation exactly once.
///
/// The OAuth loopback flows arm several independent callbacks — a timeout work
/// item, `NWListener.stateUpdateHandler`, and a connection's receive handler —
/// which can fire concurrently on different queues. A captured `var resumed`
/// checked and then set is a non-atomic test-and-set: two callbacks can both
/// observe `false` and both resume, and resuming a continuation twice traps at
/// runtime. Claiming through a lock makes exactly-once ordering explicit.
final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFired = false

    /// Returns true for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFired else { return false }
        hasFired = true
        return true
    }
}

/// Carries a value that is safe to use across concurrency domains for the narrow
/// way this code uses it, but whose type predates `Sendable` annotation.
///
/// Used for `DispatchWorkItem`, which is not `Sendable` even though `cancel()`
/// is documented as thread-safe.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
