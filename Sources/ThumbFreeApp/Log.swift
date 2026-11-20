import Foundation

/// The operational log (thumbfree-windows `Log`): states, timings and the kinds of errors, one file a day in
/// ~/Library/Logs/ThumbFree (yyyyMMdd.log), kept for a week. Never pass it transcripts, typed text, window titles or
/// audio. Safe from any thread.
public enum Log {
    /// A log file stops growing at this size.
    static let maxBytes = 5_000_000

    private static let writer = Writer()

    /// Logs to `folder`, in a file named for `now`'s date, and deletes the logs there older than a week. Nothing is
    /// logged before this, or when the folder can't be made.
    public static func start(in folder: String, now: Date = Date()) {
        writer.start(folder, now)
    }

    public static func info(_ message: String) { writer.write("INFO", message) }

    public static func warn(_ message: String) { writer.write("WARN", message) }

    public static func error(_ message: String) { writer.write("ERROR", message) }

    /// An error for a log line, as Windows logs its type: the type and code, or an NSError's domain and code, never
    /// its message, which can hold a file's name or text ("NSCocoaErrorDomain 513", "Failure 2").
    public static func kind(of error: Error) -> String {
        let code = (error as NSError).code
        let type = String(describing: Swift.type(of: error))
        return type == "NSError" ? "\((error as NSError).domain) \(code)" : "\(type) \(code)"
    }

    /// The file being written (tests).
    static var file: String? { writer.file }

    /// Stops logging (tests).
    static func stop() { writer.stop() }

    /// The file and the writes to it, behind a lock.
    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private var path: String?
        private let time = Writer.formatter("HH:mm:ss.SSS")
        private let day = Writer.formatter("yyyyMMdd")

        var file: String? { lock.withLock { path } }

        func start(_ folder: String, _ now: Date) {
            lock.withLock {
                let files = FileManager.default
                do {
                    try files.createDirectory(atPath: folder, withIntermediateDirectories: true)
                    let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)
                    for name in try files.contentsOfDirectory(atPath: folder) where name.hasSuffix(".log") {
                        let old = (folder as NSString).appendingPathComponent(name)
                        if let written = try? files.attributesOfItem(atPath: old)[.modificationDate] as? Date,
                           written < weekAgo {
                            try? files.removeItem(atPath: old)
                        }
                    }

                    path = (folder as NSString).appendingPathComponent(day.string(from: now) + ".log")
                } catch {
                    path = nil
                }
            }
        }

        func stop() {
            lock.withLock { path = nil }
        }

        func write(_ level: String, _ message: String) {
            lock.withLock {
                guard let path else { return }
                let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
                if let size, size.intValue > Log.maxBytes {
                    return
                }

                let line = Data("\(time.string(from: Date())) \(level) \(message)\n".utf8)
                guard let handle = FileHandle(forWritingAtPath: path) else {
                    FileManager.default.createFile(atPath: path, contents: line)
                    return
                }

                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            }
        }

        /// Local time, in digits whatever the language.
        private static func formatter(_ format: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = format
            return formatter
        }
    }
}
