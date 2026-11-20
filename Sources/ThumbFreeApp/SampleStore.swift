import Foundation
import ThumbFreeCore

/// The app a dictation went to, as History and samples record it.
public struct TargetApp: Equatable, Sendable {
    /// Its name as macOS shows it ("Mail"), what History and samples record; empty when it couldn't be read.
    public var name: String

    /// Its bundle identifier ("com.apple.mail"), which tells a web browser; nil when it couldn't be read.
    public var bundleIdentifier: String?

    public init(name: String, bundleIdentifier: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

/// How many dictations are kept and their total size.
public struct SampleSummary: Equatable, Sendable {
    public let count: Int
    public let bytes: Int64

    public init(count: Int, bytes: Int64) {
        self.count = count
        self.bytes = bytes
    }
}

/// "Help improve ThumbFree" (PLAN 3.8; off unless switched on), as thumbfree-windows `SampleStore`. Each dictation's
/// audio (a 16 kHz mono WAV) and a note (what was recognised, what was typed, the app's name, the model, the app
/// version and the time) are kept in ~/Library/Application Support/ThumbFree/samples: the newest 300, at most 150 MB.
/// Never from password fields or web browsers (`mayKeep`). Nothing is ever sent anywhere: "Save samples as a zip…"
/// makes a file the person shares however they choose, and "Delete all" removes everything. The same folder layout and
/// note fields as Windows (with "platform": "macos"), so the same tools read both. Saves run on a queue of their own.
public final class SampleStore: @unchecked Sendable {
    public static let maxSamples = 300
    public static let maxBytes: Int64 = 150_000_000

    public let folder: String

    private let enabled: () -> Bool
    private let appVersion: String
    private let clock: () -> Date
    private let timeZone: TimeZone
    private let maxSamples: Int
    private let maxBytes: Int64
    private let changes: DispatchQueue?
    private let observers = Observers<Void>()
    private let work = DispatchQueue(label: "app.thumbfree.mac.samples", qos: .utility)

    /// - Parameters:
    ///   - enabled: The "Help improve ThumbFree" switch, asked at every `save`.
    ///   - clock: The time now, and `timeZone` the zone its folder names and notes are in (this Mac's).
    ///   - changes: Where change handlers run (the app passes the main queue); nil runs them on the store's queue.
    public init(
        folder: String,
        enabled: @escaping () -> Bool,
        appVersion: String,
        clock: @escaping () -> Date = Date.init,
        timeZone: TimeZone = .autoupdatingCurrent,
        maxSamples: Int = SampleStore.maxSamples,
        maxBytes: Int64 = SampleStore.maxBytes,
        changes: DispatchQueue? = nil
    ) {
        self.folder = folder
        self.enabled = enabled
        self.appVersion = appVersion
        self.clock = clock
        self.timeZone = timeZone
        self.maxSamples = maxSamples
        self.maxBytes = maxBytes
        self.changes = changes
    }

    /// Runs `handler` after samples are added or deleted.
    @discardableResult
    public func observe(_ handler: @escaping () -> Void) -> ObservationToken {
        observers.add { _ in handler() }
    }

    /// The privacy rule for samples (PLAN 3.8): never from a password field, and never from a web browser, because a
    /// browser can't reliably say whether a window is private (`Browsers`). Nor from an app that couldn't be read (no
    /// name or no bundle identifier): it might be a browser. Other apps and ThumbFree's own practice boxes (`app`
    /// nil) may be kept.
    public static func mayKeep(_ app: TargetApp?, passwordField: Bool) -> Bool {
        if passwordField {
            return false
        }

        guard let app else { return true }
        guard !DotNet.isNullOrWhiteSpace(app.name), !DotNet.isNullOrWhiteSpace(app.bundleIdentifier) else {
            return false
        }

        return !Browsers.isBrowser(app.bundleIdentifier)
    }

    /// Keeps one dictation, on the store's queue, when "Help improve ThumbFree" is on and `mayKeep` allows it. The host
    /// passes, for every dictation, whether it went into a password field and the app. The note records the app's
    /// name, never its window title.
    /// - Parameters:
    ///   - audio: The recording: 16 kHz mono, -1 to 1.
    ///   - recognized: What the model heard, before formatting.
    ///   - typed: What was typed (or kept for copying).
    ///   - app: The app the text went to; nil for ThumbFree's own practice boxes.
    @discardableResult
    public func save(
        _ audio: [Float], recognized: String, typed: String, model: ModelSpec, passwordField: Bool, app: TargetApp?
    ) -> Bool {
        if !enabled() || !Self.mayKeep(app, passwordField: passwordField) || audio.isEmpty {
            return false
        }

        let time = clock()
        enqueue { [self] in
            do {
                let sample = try newSampleFolder(time)
                try Self.writeWav((sample as NSString).appendingPathComponent("audio.wav"), audio)
                let seconds = (Double(audio.count) / Double(Decoding.sampleRate) * 100).rounded(.toNearestOrEven) / 100
                let note: [(key: String, json: String)] = [
                    ("model", SettingsJSON.quote(model.id)),
                    ("language", SettingsJSON.quote(model.language.settingsName)),
                    ("seconds", SettingsJSON.number(seconds)),
                    ("transcript", SettingsJSON.quote(recognized)),
                    ("typed", SettingsJSON.quote(typed)),
                    ("app", SettingsJSON.quote(app?.name ?? "ThumbFree")),
                    ("app_version", SettingsJSON.quote(appVersion)),
                    ("platform", SettingsJSON.quote("macos")),
                    ("time", SettingsJSON.quote(Self.roundTrip(time, timeZone))),
                ]
                let meta = URL(fileURLWithPath: (sample as NSString).appendingPathComponent("meta.json"))
                try Data(SettingsJSON.object(note, indented: true).utf8).write(to: meta)
                try trim()
            } catch {
                // A full disk must never disturb dictation; the sample is simply not kept.
                Log.warn("sample not saved: \(Log.kind(of: error))")
            }
        }

        return true
    }

    /// How many dictations are kept and their total size.
    public func summary() -> SampleSummary {
        do {
            let samples = try self.samples()
            return SampleSummary(count: samples.count, bytes: try samples.reduce(Int64(0)) { $0 + (try Self.size($1)) })
        } catch {
            return SampleSummary(count: 0, bytes: 0)
        }
    }

    /// Puts every kept dictation into one zip (sample folders inside) and returns how many it holds.
    public func exportZip(to path: String) async throws -> Int {
        try await perform { [self] in
            let samples = try self.samples().sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            var entries: [(name: String, file: String)] = []
            for sample in samples {
                let name = (sample as NSString).lastPathComponent
                for file in try Self.files(in: sample) {
                    entries.append((name: "\(name)/\(file)", file: (sample as NSString).appendingPathComponent(file)))
                }
            }

            let temp = path + ".partial"
            unlink(temp)
            try ZipArchive.write(temp, entries)
            if rename(temp, path) != 0 {
                let code = errno
                unlink(temp)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }

            return samples.count
        }
    }

    /// Deletes every kept dictation (after any that are still being saved).
    public func deleteAll() async throws {
        try await perform { [self] in
            if FileManager.default.fileExists(atPath: folder) {
                try FileManager.default.removeItem(atPath: folder)
            }
        }
    }

    /// Waits up to `timeout` for saves and deletes still running (tests and quitting); false if they haven't finished.
    @discardableResult
    public func flush(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        work.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    /// Writes 16-bit PCM, 16 kHz, mono.
    static func writeWav(_ path: String, _ audio: [Float]) throws {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(44 + audio.count * 2)
        func text(_ value: String) { bytes += Array(value.utf8) }
        func int32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        func int16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }

        let data = UInt32(audio.count * 2)
        let rate = UInt32(Decoding.sampleRate)
        text("RIFF")
        int32(36 + data)
        text("WAVE")
        text("fmt ")
        int32(16)
        int16(1)
        int16(1)
        int32(rate)
        int32(rate * 2)
        int16(2)
        int16(16)
        text("data")
        int32(data)
        for sample in audio {
            // As C#: clamped and scaled in single precision, then rounded half to even.
            let scaled = min(max(sample, -1), 1) * 32767
            int16(UInt16(bitPattern: scaled.isNaN ? 0 : Int16(Double(scaled).rounded(.toNearestOrEven))))
        }

        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }

    /// .NET's round-trip ("o") form of `time` in `zone`: "2026-11-19T18:00:00.1230000+05:30". A Date keeps about a
    /// microsecond, so the seventh digit is 0.
    static func roundTrip(_ time: Date, _ zone: TimeZone) -> String {
        let (wall, micros, offset) = wallClock(time, zone)
        let sign = offset < 0 ? "-" : "+"
        let minutes = abs(offset) / 60
        return String(
            format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld.%07ld%@%02ld:%02ld", wall.year ?? 0, wall.month ?? 0,
            wall.day ?? 0, wall.hour ?? 0, wall.minute ?? 0, wall.second ?? 0, micros * 10, sign, minutes / 60,
            minutes % 60)
    }

    /// The year to the microsecond in `zone`, and its offset from UTC in seconds.
    private static func wallClock(_ time: Date, _ zone: TimeZone) -> (DateComponents, Int, Int) {
        let offset = zone.secondsFromGMT(for: time)
        let local = time.timeIntervalSince1970 + Double(offset)
        var seconds = local.rounded(.down)
        var micros = Int(((local - seconds) * 1_000_000).rounded())
        if micros == 1_000_000 {
            seconds += 1
            micros = 0
        }

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? zone
        let wall = utc.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: seconds))
        return (wall, micros, offset)
    }

    /// The sample folders.
    private func samples() throws -> [String] {
        guard FileManager.default.fileExists(atPath: folder) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder)
            .map { (folder as NSString).appendingPathComponent($0) }
            .filter { Self.isFolder($0) }
    }

    /// The files in a sample folder, by name.
    private static func files(in sample: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: sample)
            .filter { !isFolder((sample as NSString).appendingPathComponent($0)) }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func size(_ sample: String) throws -> Int64 {
        try files(in: sample).reduce(Int64(0)) { total, file in
            let path = (sample as NSString).appendingPathComponent(file)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private static func isFolder(_ path: String) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// yyyyMMdd-HHmmss-fff in the clock's own zone, so names sort oldest first (as on Android and Windows).
    private func newSampleFolder(_ time: Date) throws -> String {
        let (wall, micros, _) = Self.wallClock(time, timeZone)
        let name = String(
            format: "%04ld%02ld%02ld-%02ld%02ld%02ld-%03ld", wall.year ?? 0, wall.month ?? 0, wall.day ?? 0,
            wall.hour ?? 0, wall.minute ?? 0, wall.second ?? 0, micros / 1000)
        var path = (folder as NSString).appendingPathComponent(name)
        var i = 2
        while FileManager.default.fileExists(atPath: path) {
            path = (folder as NSString).appendingPathComponent("\(name)-\(i)")
            i += 1
        }

        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Keeps the newest samples within `maxSamples` and `maxBytes`.
    private func trim() throws {
        var bytes: Int64 = 0
        let newestFirst = try samples().sorted { $1.utf8.lexicographicallyPrecedes($0.utf8) }
        for (i, sample) in newestFirst.enumerated() {
            bytes += try Self.size(sample)
            if i >= maxSamples || bytes > maxBytes {
                try FileManager.default.removeItem(atPath: sample)
            }
        }
    }

    /// Runs `job` after the saves and deletes before it, then tells the handlers.
    private func enqueue(_ job: @escaping () -> Void) {
        work.async { [self] in
            job()
            observers.notify((), on: changes)
        }
    }

    /// `enqueue`, returning what `job` returns or throwing what it throws.
    private func perform<Value>(_ job: @escaping () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            work.async { [self] in
                let result = Result { try job() }
                observers.notify((), on: changes)
                continuation.resume(with: result)
            }
        }
    }
}
