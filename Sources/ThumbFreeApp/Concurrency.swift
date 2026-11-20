import Foundation

/// A value several threads read and write, behind a lock: C#'s volatile fields and Interlocked.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value

    init(_ value: Value) {
        current = value
    }

    var value: Value {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// Sets `newValue` and returns what was there (Interlocked.Exchange).
    func exchange(_ newValue: Value) -> Value {
        lock.withLock {
            let old = current
            current = newValue
            return old
        }
    }

    /// Changes the value in place, returning what `change` returns.
    @discardableResult
    func update<T>(_ change: (inout Value) -> T) -> T {
        lock.withLock { change(&current) }
    }
}

/// The result of work running elsewhere (C#'s Task): wait for it, or have it handed on once it's ready. It may be
/// cancelled instead, when the thread it was for is shutting down.
final class Pending<Value>: @unchecked Sendable {
    private enum State {
        case waiting
        case done(Value)
        case cancelled
    }

    private let condition = NSCondition()
    private var state = State.waiting
    private var continuations: [(Value) -> Void] = []

    init() {}

    /// Already done (C#'s Task.FromResult).
    init(_ value: Value) {
        state = .done(value)
    }

    /// Runs `work` on `queue` (C#'s Task.Run).
    static func run(on queue: DispatchQueue = .global(qos: .userInitiated), _ work: @escaping () -> Value) -> Pending {
        let pending = Pending()
        queue.async { pending.resolve(work()) }
        return pending
    }

    func resolve(_ value: Value) {
        condition.lock()
        guard case .waiting = state else {
            condition.unlock()
            return
        }

        state = .done(value)
        let waiting = continuations
        continuations = []
        condition.broadcast()
        condition.unlock()
        waiting.forEach { $0(value) }
    }

    /// It will never be done: `wait` returns nil, and the handlers given to `then` never run.
    func cancel() {
        condition.lock()
        if case .waiting = state {
            state = .cancelled
            continuations = []
        }

        condition.broadcast()
        condition.unlock()
    }

    /// Waits until it's done; nil when it was cancelled.
    func wait() -> Value? {
        condition.lock()
        defer { condition.unlock() }
        while case .waiting = state {
            condition.wait()
        }

        if case .done(let value) = state {
            return value
        }

        return nil
    }

    /// Waits `timeout` at most; nil when it wasn't done by then, or was cancelled.
    func wait(timeout: TimeInterval) -> Value? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while case .waiting = state {
            if !condition.wait(until: deadline) {
                break
            }
        }

        if case .done(let value) = state {
            return value
        }

        return nil
    }

    /// Runs `handler` with the value once it's done, on the thread that finished it, or now if it is.
    func then(_ handler: @escaping (Value) -> Void) {
        condition.lock()
        switch state {
        case .waiting:
            continuations.append(handler)
            condition.unlock()
        case .done(let value):
            condition.unlock()
            handler(value)
        case .cancelled:
            condition.unlock()
        }
    }
}

/// The handler the app gives one of an object's events (a C# event with one subscriber), safe to set and call from
/// any thread.
final class Handler<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var body: ((Value) -> Void)?

    var handler: ((Value) -> Void)? {
        get { lock.withLock { body } }
        set { lock.withLock { body = newValue } }
    }

    func callAsFunction(_ value: Value) {
        handler?(value)
    }
}

/// Runs `body` on the main thread: now when this is it, else as soon as the main thread is free.
func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
    }
}
