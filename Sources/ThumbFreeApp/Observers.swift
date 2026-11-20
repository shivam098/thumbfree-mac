import Foundation

/// A store's change handlers, like a C# event: each one runs, in the order added, until its token is cancelled.
/// Safe from any thread.
final class Observers<Change>: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [(id: Int, handler: (Change) -> Void)] = []
    private var lastId = 0

    func add(_ handler: @escaping (Change) -> Void) -> ObservationToken {
        let id: Int = lock.withLock {
            lastId += 1
            handlers.append((id: lastId, handler: handler))
            return lastId
        }

        return ObservationToken { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.handlers.removeAll { $0.id == id } }
        }
    }

    /// Runs the handlers with `change`: right here when `queue` is nil, else on `queue`.
    func notify(_ change: Change, on queue: DispatchQueue? = nil) {
        let current = lock.withLock { handlers.map { $0.handler } }
        if current.isEmpty {
            return
        }

        guard let queue else {
            current.forEach { $0(change) }
            return
        }

        queue.async {
            current.forEach { $0(change) }
        }
    }
}

/// Keeps a change handler: it runs until `cancel()`.
public final class ObservationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        let action = lock.withLock { () -> (() -> Void)? in
            defer { onCancel = nil }
            return onCancel
        }

        action?()
    }
}
