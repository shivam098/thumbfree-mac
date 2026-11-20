import Foundation
import ThumbFreeCore

/// Saves the Settings page's changes to settings.json without losing anything in it (thumbfree-windows
/// `SettingsStore`). Each save re-reads the file and replaces only the text of the values that changed
/// (`SettingsJSON.splice`), so comments, formatting, hand edits made while ThumbFree runs, values the page doesn't show
/// (snippets, new-line keys…) and keys this version doesn't know (Windows' own, or a newer ThumbFree's) stay exactly as
/// they are. A file that can't be read is never overwritten: the change still applies until ThumbFree quits, and
/// `lastError` says how to fix the file. Nothing here throws because of what's in the file. Safe from any thread.
public final class SettingsStore: @unchecked Sendable {
    public let path: String

    private let lock = NSRecursiveLock()
    private let observers = Observers<SettingsChange>()
    private var settings: AppSettings
    private var problems: SettingsProblems
    private var saveError: String?

    /// The file couldn't be read at start, so `current` holds defaults rather than what's in it: until ThumbFree
    /// restarts, saving even one value could write a default over the person's own (a dictionary box shows the default
    /// entries), so nothing is saved unless the file is deleted.
    private var readFailed: Bool

    public init(_ settings: AppSettings, path: String) {
        self.settings = settings
        self.path = path
        problems = settings.loadProblems
        readFailed = settings.loadProblems[nil] != nil
    }

    /// The settings the whole app uses.
    public var current: AppSettings { lock.withLock { settings } }

    /// Runs `handler` after each `update` that changed something, on the thread that called it (the main thread),
    /// with the settings it changed. The dictation host applies them without a restart; `AppSettings.readAtStart` are
    /// the exceptions.
    @discardableResult
    public func observe(_ handler: @escaping (SettingsChange) -> Void) -> ObservationToken {
        observers.add(handler)
    }

    /// What's wrong, for Home and Settings to show: why the last change wasn't saved, else the values in the file
    /// that couldn't be used when it was read (those settings kept their defaults). Nil when all is well.
    public var lastError: String? {
        lock.withLock { () -> String? in
            if saveError != nil || problems.isEmpty {
                return saveError
            }

            if let whole = problems[nil] {
                return whole
            }

            let messages = problems.entries.map { $0.message }
            let fix = messages.count == 1 ? "Fix it in the file" : "Fix them in the file"
            return messages.joined(separator: " ") + " \(fix), then restart ThumbFree."
        }
    }

    /// One short line for a notification when ThumbFree starts with a problem in the file; nil when there's none.
    public var problemSummary: String? {
        lock.withLock { () -> String? in
            if problems.isEmpty {
                return nil
            }

            if let whole = problems[nil] {
                return whole
            }

            let keys = problems.entries.prefix(3).map { "“\($0.key?.rawValue ?? "")”" }.joined(separator: ", ")
                + (problems.entries.count > 3 ? "…" : "")
            return "Some values in settings.json can't be used (\(keys)), so ThumbFree uses its defaults for them. "
                + "Settings shows what to fix."
        }
    }

    /// Applies `change` to `current` and saves the settings it changed. False when the file couldn't be written (see
    /// `lastError`); the change applies anyway.
    @discardableResult
    public func update(_ change: (inout AppSettings) -> Void) -> Bool {
        lock.lock()
        let before = snapshot()
        var updated = settings
        change(&updated)
        settings = updated
        let after = snapshot()
        let keys = AppSettings.fields.indices.filter { !DotNet.ordinalEquals(before[$0], after[$0]) }
            .map { AppSettings.fields[$0].key }
        if keys.isEmpty {
            lock.unlock()
            return true
        }

        saveError = tryWrite(keys)
        let saved = saveError == nil
        if saved {
            // The file now holds good values for these keys (and it reads).
            for key in keys {
                problems[key] = nil
            }

            problems[nil] = nil
        }

        lock.unlock()
        if !saved {
            Log.warn("settings change not saved")
        }

        observers.notify(SettingsChange(keys: Set(keys)))
        return saved
    }

    /// Writes every setting to a new file when there's none (or it's empty), so "Open settings file" always opens
    /// something. An existing file is left alone.
    public func createIfMissing() {
        lock.withLock {
            do {
                if let file = try AppSettings.contents(of: path), !SettingsJSON.isBlank(file) {
                    return
                }

                try writeWholeFile()
            } catch {
                Log.warn("couldn't create the settings file: \(Log.kind(of: error))")
            }
        }
    }

    /// Writes through a temporary file, so a crash or a full disk never leaves half a settings file.
    static func writeAtomically(_ path: String, _ contents: [UInt8]) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let temp = path + ".tmp"
        try Data(contents).write(to: URL(fileURLWithPath: temp))
        if rename(temp, path) != 0 {
            let code = errno
            unlink(temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// A new file holds exactly what's in use, so nothing read from an older one (or its problems) applies any more.
    private func writeWholeFile() throws {
        try settings.save(to: path)
        readFailed = false
        problems.removeAll()
        saveError = nil
    }

    /// Every setting's JSON on one line, to tell which changed.
    private func snapshot() -> [String] { AppSettings.fields.map { $0.json(settings, false) } }

    /// Nil when the change is saved, else why it isn't.
    private func tryWrite(_ keys: [AppSettings.Key]) -> String? {
        do {
            guard let file = try AppSettings.contents(of: path), !SettingsJSON.isBlank(file) else {
                try writeWholeFile()
                return nil
            }

            if readFailed {
                _ = try SettingsJSON.values(file)
                return "This change isn't saved: settings.json couldn't be read when ThumbFree started. Restart "
                    + "ThumbFree to use the file, then make the change again."
            }

            let edits = keys.map { key -> SettingsJSON.Edit in
                let field = AppSettings.field(key)
                return SettingsJSON.Edit(
                    key: key.rawValue, compact: field.json(settings, false), indented: field.json(settings, true))
            }
            let spliced = try SettingsJSON.splice(file, edits)
            try Self.readBack(spliced, edits)
            try Self.writeAtomically(path, spliced)
            return nil
        } catch let mistake as SettingsJSON.Mistake {
            let what = mistake.line.map { "settings.json has a mistake near line \($0 + 1)." } ?? mistake.message
            return "This change isn't saved: \(what) Fix it (Settings › Advanced › Open settings file) or delete the "
                + "file to start again."
        } catch let failure where failure is ReadBackFailure || failure is SettingsJSON.SpliceFailure {
            Log.error("settings save failed: \(Log.kind(of: failure))")
            return "This change isn't saved: ThumbFree couldn't update settings.json. Its log has the details."
        } catch {
            return "This change isn't saved: " + error.localizedDescription
        }
    }

    /// The new file is read back before it replaces the old one: each changed key must hold its new value.
    private static func readBack(_ spliced: [UInt8], _ edits: [SettingsJSON.Edit]) throws {
        let values = try SettingsJSON.values(spliced)
        for edit in edits {
            guard let key = AppSettings.Key(rawValue: edit.key), let value = values[edit.key],
                  let read = AppSettings.field(key).readBack(value), DotNet.ordinalEquals(read, edit.compact)
            else { throw ReadBackFailure() }
        }
    }

    private struct ReadBackFailure: Error {}
}

/// The settings a change touched (thumbfree-windows `SettingsChange`).
public struct SettingsChange: Equatable, Sendable {
    public let keys: Set<AppSettings.Key>

    public init(keys: Set<AppSettings.Key>) {
        self.keys = keys
    }

    /// True for any of `keys`.
    public func has(_ keys: AppSettings.Key...) -> Bool { keys.contains { self.keys.contains($0) } }

    /// Something that is read only when ThumbFree starts changed.
    public var needsRestart: Bool { !keys.isDisjoint(with: AppSettings.readAtStart) }
}
