import Foundation

/// Where ThumbFree keeps its files on this Mac (docs/mac.md), in the same formats as ThumbFree for Windows so they can
/// move between the two: thumbfree-windows `AppPaths`. Windows splits them between %APPDATA% (settings) and
/// %LOCALAPPDATA% (the rest); the Mac keeps them together. Tests use folders of their own.
public struct AppPaths: Equatable, Sendable {
    /// ~/Library/Application Support/ThumbFree: settings, History, samples, models and the state flags.
    public var data: String

    /// ~/Library/Logs/ThumbFree, where Console finds the logs.
    public var logs: String

    public init(data: String, logs: String) {
        self.data = data
        self.logs = logs
    }

    /// This Mac's folders.
    public static var standard: AppPaths {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (library as NSString).appendingPathComponent("Application Support")
        return AppPaths(
            data: (support as NSString).appendingPathComponent("ThumbFree"),
            logs: (library as NSString).appendingPathComponent("Logs/ThumbFree"))
    }

    /// settings.json, in the Windows app's format.
    public var settingsFile: String { file("settings.json") }

    /// History: the text of recent dictations (30 days, at most 500), on this Mac only.
    public var historyFile: String { file("history.txt") }

    /// "Help improve ThumbFree": dictations kept to share by hand, only while that switch is on.
    public var samplesFolder: String { file("samples") }

    /// Where downloaded models go (ThumbFreeSpeech's `ModelStore.defaultFolder`).
    public var modelsFolder: String { file("models") }

    /// Present while the dictation key is paused.
    public var pausedFlag: String { file("paused") }

    /// Present while the pill is shown all the time (by default it appears only while it has something to say).
    public var pillPinnedFlag: String { file("overlay-pinned") }

    private func file(_ name: String) -> String { (data as NSString).appendingPathComponent(name) }
}

/// Bits of app state (paused, the pill pinned) remembered as empty flag files, apart from settings.json.
public enum StateFlags {
    public static func isSet(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Creates or deletes the flag file; a failure is logged, never thrown.
    public static func set(_ path: String, _ on: Bool) {
        do {
            if on {
                try FileManager.default.createDirectory(
                    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data().write(to: URL(fileURLWithPath: path))
            } else if unlink(path) != 0 && errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            Log.warn("couldn't save \((path as NSString).lastPathComponent): \(Log.kind(of: error))")
        }
    }
}
