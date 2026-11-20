import Foundation

/// One ThumbFree at a time, as the Windows app's single-instance mutex keeps it (thumbfree-windows App.xaml.cs): two
/// copies would each rewrite history.txt from their own list, dropping the other's entries, and type every dictation
/// twice. The running copy holds an exclusive lock (flock) on a file in ThumbFree's folder; macOS lets go of it when
/// the process ends, however it ends, so a lock is never left behind. A second copy asks the first to show itself
/// (`showRunningCopy`), then quits.
public final class SingleInstance: @unchecked Sendable {
    /// Posted to this user's apps by a second copy: the running one shows itself.
    public static let showNotification = Notification.Name("app.thumbfree.mac.show")

    public let path: String

    private let lock = NSLock()
    private var descriptor: Int32 = -1

    public init(path: String) {
        self.path = path
    }

    deinit {
        release()
    }

    /// Takes the lock: true when this is the only copy (the lock is held until `release` or the process ends), false
    /// when another copy holds it. Throws when the lock file can't be made or opened.
    public func acquire() throws -> Bool {
        try lock.withLock {
            if descriptor >= 0 {
                return true
            }

            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let opened = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard opened >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if flock(opened, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                Darwin.close(opened)
                if code == EWOULDBLOCK {
                    return false
                }

                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }

            descriptor = opened
            return true
        }
    }

    /// Lets go of the lock (closing the file does).
    public func release() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    /// Asks the copy that holds the lock to show itself. It's delivered at once, though that copy isn't the active app.
    public static func showRunningCopy() {
        DistributedNotificationCenter.default().postNotificationName(
            showNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
