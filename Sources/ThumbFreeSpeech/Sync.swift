import Foundation

/// A flag set from any thread and read from another (the C# code's `volatile bool`).
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}

/// One holder at a time for async code, waiting in order (C#'s `SemaphoreSlim(1, 1)` with `WaitAsync(token)`): a task
/// cancelled while it waits stops waiting with `CancellationError`.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var nextWaiter = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        let id = newWaiter()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if !held {
                    held = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let index = waiters.firstIndex { $0.id == id }
            let waiter = index.map { waiters.remove(at: $0) }
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Hands the gate to the next waiter, or opens it.
    func release() {
        lock.lock()
        guard !waiters.isEmpty else {
            held = false
            lock.unlock()
            return
        }

        let next = waiters.removeFirst()
        lock.unlock()
        next.continuation.resume()
    }

    private func newWaiter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextWaiter += 1
        return nextWaiter
    }
}

/// C copies of strings for a C call that reads a configuration of `const char *` fields (sherpa-onnx copies what it
/// needs), freed when `with` returns.
final class CStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []

    private init() {}

    static func with<Result>(_ body: (CStrings) throws -> Result) rethrows -> Result {
        let strings = CStrings()
        defer { strings.pointers.forEach { free($0) } }
        return try body(strings)
    }

    func callAsFunction(_ text: String) -> UnsafePointer<CChar> {
        guard let pointer = strdup(text) else { preconditionFailure("Out of memory") }
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }
}

/// File-system helpers that behave like the .NET calls the C# code makes.
enum Files {
    /// `File.Exists`: a file, not a folder.
    static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// `Path.Combine`.
    static func combine(_ folder: String, _ name: String) -> String {
        (folder as NSString).appendingPathComponent(name)
    }

    /// `Path.GetDirectoryName`.
    static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

    /// `Path.GetFullPath`: absolute, without "." and "..", "//" or a trailing "/"; symbolic links aren't resolved.
    static func fullPath(_ path: String) -> String {
        let absolute = path.hasPrefix("/") ? path : combine(FileManager.default.currentDirectoryPath, path)
        var parts: [Substring] = []
        for part in absolute.split(separator: "/") where part != "." {
            if part == ".." {
                _ = parts.popLast()
            } else {
                parts.append(part)
            }
        }

        return "/" + parts.joined(separator: "/")
    }

    /// The size and last-write time of a file (not a folder), or nil if there's no such file.
    static func info(_ path: String) -> (bytes: Int64, writeTicks: Int64)? {
        var status = stat()
        // S_IFMT and S_IFREG: the file-type bits, and a regular file.
        guard stat(path, &status) == 0, status.st_mode & 0o170000 == 0o100000 else { return nil }
        return (Int64(status.st_size), ticks(status.st_mtimespec))
    }

    /// .NET ticks (100 ns since 0001-01-01), the unit of the C# index's times: the index file is the same on Windows.
    static func ticks(_ time: timespec) -> Int64 {
        621_355_968_000_000_000 + Int64(time.tv_sec) * 10_000_000 + Int64(time.tv_nsec) / 100
    }
}
