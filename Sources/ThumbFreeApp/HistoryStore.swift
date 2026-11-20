import Foundation
import ThumbFreeCore

/// History (PLAN 3.11): the text of recent dictations, kept only on this Mac in
/// ~/Library/Application Support/ThumbFree/Dictations.noindex/history.txt, out of Spotlight (`AppPaths`) and Time
/// Machine backups, so one can be copied again (thumbfree-windows `HistoryStore`). 30 days and at most 500, in the
/// shared format of `History`, so every platform reads it alike. Reads and edits happen in memory and are safe from
/// any thread; the file is written on a queue of its own. While "Keep history" is off nothing is kept.
public final class HistoryStore: @unchecked Sendable {
    private let path: String
    private let enabled: () -> Bool
    private let clock: () -> Date
    private let changes: DispatchQueue?
    private let observers = Observers<Void>()
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "app.thumbfree.mac.history", qos: .utility)
    private var loaded: [HistoryEntry]?
    private var writeQueued = false
    private var unreadable = false

    /// - Parameters:
    ///   - path: history.txt.
    ///   - enabled: "Keep history", asked at every `add`.
    ///   - clock: The time now (tests).
    ///   - changes: Where change handlers run (the app passes the main queue); nil runs them on the thread that made
    ///     the change, as C# does without a UI thread.
    public init(
        path: String, enabled: @escaping () -> Bool, clock: @escaping () -> Date = Date.init,
        changes: DispatchQueue? = nil
    ) {
        self.path = path
        self.enabled = enabled
        self.clock = clock
        self.changes = changes
    }

    /// Runs `handler` after every change.
    @discardableResult
    public func observe(_ handler: @escaping () -> Void) -> ObservationToken {
        observers.add { _ in handler() }
    }

    /// Newest first, without anything older than 30 days.
    public func entries() -> [HistoryEntry] {
        lock.withLock {
            let found = loaded ?? read()
            let kept = History.prune(found, now: now)
            loaded = kept
            if kept.count != found.count {
                queueWrite()
            }

            return kept
        }
    }

    /// Keeps a dictation: the final text (typed, sent to the tap-to-copy notification, or cut short) and the name of
    /// the app it was for (may be empty). Nothing is kept while Keep history is off, for blank text, or when
    /// `passwordField` is true: the host passes true for every dictation into a password field, so none is ever stored.
    public func add(_ text: String, app: String?, passwordField: Bool) {
        if passwordField || DotNet.isNullOrWhiteSpace(text) || !enabled() {
            return
        }

        lock.withLock {
            let time = now
            let entry = HistoryEntry(time: time, app: app ?? "", text: text)
            loaded = History.prune([entry] + (loaded ?? read()), now: time)
            queueWrite()
        }

        raiseChanged()
    }

    public func delete(_ entry: HistoryEntry) {
        lock.withLock {
            loaded = (loaded ?? read()).filter { !Self.same($0, entry) }
            queueWrite()
        }

        raiseChanged()
    }

    /// Deletes every entry (Clear history, or Keep history turned off).
    public func clear() {
        lock.withLock {
            loaded = []
            unreadable = false
            queueWrite()
        }

        raiseChanged()
    }

    /// Waits up to `timeout` for the file to catch up (at quit, and in tests); false if it hasn't.
    @discardableResult
    public func flush(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        writer.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Unix milliseconds, as History keeps them.
    private var now: Int64 { Int64((clock().timeIntervalSince1970 * 1000).rounded(.down)) }

    /// The file's entries (a damaged line is skipped). A file that can't be read is never replaced with what this
    /// session adds.
    private func read() -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        do {
            var data = try Data(contentsOf: URL(fileURLWithPath: path))
            if data.starts(with: [0xEF, 0xBB, 0xBF]) {
                data.removeFirst(3)
            }

            // As .NET's File.ReadAllLines reads it: bytes that aren't UTF-8 become U+FFFD.
            return DotNet.lines(String(decoding: data, as: UTF8.self)).compactMap(History.decode)
        } catch {
            Log.warn("history unreadable: \(Log.kind(of: error))")
            unreadable = true
            return []
        }
    }

    private func queueWrite() {
        if writeQueued || unreadable {
            return
        }

        writeQueued = true
        writer.async { [self] in write() }
    }

    private func write() {
        let snapshot: [HistoryEntry] = lock.withLock {
            writeQueued = false
            return loaded ?? []
        }

        let temp = path + ".tmp"
        do {
            if snapshot.isEmpty {
                if unlink(path) != 0 && errno != ENOENT {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }

                return
            }

            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(snapshot.map(History.encode).joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: temp))

            // Windows keeps it out of the search index (the Mac's folder does that); the Mac keeps it out of backups
            // too (PLAN 3.11).
            var url = URL(fileURLWithPath: temp)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            if rename(temp, path) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            unlink(temp)
            Log.warn("history not saved: \(Log.kind(of: error))")
        }
    }

    private func raiseChanged() {
        observers.notify((), on: changes)
    }

    /// The same entry, as C# records compare: the time, and the app and text ordinally.
    private static func same(_ a: HistoryEntry, _ b: HistoryEntry) -> Bool {
        a.time == b.time && DotNet.ordinalEquals(a.app, b.app) && DotNet.ordinalEquals(a.text, b.text)
    }
}

/// Readable names for the apps dictations were for (thumbfree-windows `AppNames`). The Mac records an app's name as
/// macOS shows it ("Mail"), which is kept as it is; entries from Windows have process names ("WINWORD" → "Word").
public enum AppNames {
    private static let known: [[Unicode.Scalar]: String] = {
        let names = [
            "OUTLOOK": "Outlook", "olk": "Outlook", "HxOutlook": "Mail", "WINWORD": "Word", "EXCEL": "Excel",
            "POWERPNT": "PowerPoint", "ONENOTE": "OneNote", "ms-teams": "Teams", "Teams": "Teams", "msedge": "Edge",
            "chrome": "Chrome", "firefox": "Firefox", "brave": "Brave", "opera": "Opera", "vivaldi": "Vivaldi",
            "Code": "VS Code", "devenv": "Visual Studio", "notepad": "Notepad", "WhatsApp": "WhatsApp",
            "WhatsApp.Root": "WhatsApp", "slack": "Slack", "Discord": "Discord", "Telegram": "Telegram",
            "Signal": "Signal", "Zoom": "Zoom", "thunderbird": "Thunderbird", "Obsidian": "Obsidian",
            "Notion": "Notion", "WindowsTerminal": "Terminal", "explorer": "File Explorer", "ThumbFree": "ThumbFree",
        ]
        return Dictionary(names.map { (DotNet.ordinalIgnoreCase($0.key), $0.value) }, uniquingKeysWith: { $1 })
    }()

    /// The known name, else the name with a capital first letter; "" for none.
    public static func friendly(_ app: String?) -> String {
        guard let app, !DotNet.isNullOrWhiteSpace(app) else { return "" }
        return known[DotNet.ordinalIgnoreCase(app)] ?? DotNet.upperFirst(app)
    }
}

/// "just now", "2 minutes ago", "yesterday", then the date: how History says when (thumbfree-windows `RelativeTime`).
public enum RelativeTime {
    /// - Parameter calendar: Whose days count for "yesterday" (this Mac's).
    public static func describe(_ time: Date, now: Date, calendar: Calendar = .current) -> String {
        let age = now.timeIntervalSince(time)
        if age < 60 {
            return "just now"
        }

        if age < 3600 {
            let minutes = Int(age / 60)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }

        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: time), to: calendar.startOfDay(for: now)).day ?? 0
        if age < 12 * 3600 || days == 0 {
            let hours = Int(age / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }

        switch days {
        case 1:
            return "yesterday"
        case ..<7:
            return "\(days) days ago"
        default:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "d MMM"
            return formatter.string(from: time)
        }
    }

    /// "Outlook · 2 minutes ago", or "2 minutes ago" when the app isn't known.
    public static func caption(_ entry: HistoryEntry, now: Date, calendar: Calendar = .current) -> String {
        let when = describe(Date(timeIntervalSince1970: Double(entry.time) / 1000), now: now, calendar: calendar)
        let app = AppNames.friendly(entry.app)
        return app.isEmpty ? DotNet.upperFirst(when) : "\(app) · \(when)"
    }
}
